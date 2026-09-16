;;; strudel-server.el --- Local assets for Strudel -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:
;; A loopback-only, GET-only static server.  Only explicitly mounted files
;; are served; there is no directory listing or access to project documents.

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'url-util)

(defvar strudel--server nil)
(defvar strudel--clients nil)
(defvar strudel--mounts nil)
(defvar strudel--token nil)
(defvar strudel--base-url nil)
(defvar strudel--sample-map nil)
(defvar strudel--server-errors nil)

(defun strudel--safe-file (root relative)
  "Resolve RELATIVE within ROOT, rejecting traversal and escaping symlinks."
  (let* ((root (file-name-as-directory (file-truename root)))
         (file (file-truename (expand-file-name relative root))))
    (when (and (not (file-name-absolute-p relative))
               (not (member ".." (split-string relative "/")))
               (file-in-directory-p file root)
               (file-regular-p file))
      file)))

(defun strudel--sample-map (directory)
  "Read DIRECTORY's strudel.json, or generate a stable map of local audio.
An existing manifest may use relative paths only; its _base is replaced."
  (let ((map (make-hash-table :test #'equal))
        (manifest (expand-file-name "strudel.json" directory)))
    (when (file-directory-p directory)
      (if (file-exists-p manifest)
          (setq map (json-parse-string
                     (with-temp-buffer
                       (insert-file-contents manifest) (buffer-string))
                     :object-type 'hash-table))
        (dolist (file (sort (directory-files-recursively
                            directory "\\.\\(wav\\|mp3\\|ogg\\|flac\\|m4a\\|aiff?\\)\\'")
                           #'string<))
          (let* ((relative (file-relative-name file directory))
                 (parent (directory-file-name
                          (or (file-name-directory relative) "")))
                 (name (if (equal parent "") (file-name-base file)
                         (replace-regexp-in-string "/" "_" parent))))
            (puthash name (vconcat (gethash name map) (vector relative)) map)))))
    (remhash "_base" map)
    (cl-labels ((check (value)
                 (cond
                  ((stringp value)
                   (unless (and (not (string-match-p "[:?#]" value))
                                (strudel--safe-file directory value))
                     (error "Missing or non-local sample: %s" value)))
                  ((vectorp value) (mapc #'check value))
                  ((hash-table-p value)
                   (maphash (lambda (_key item) (check item)) value))
                  (t (error "Invalid sample manifest value: %S" value)))))
      (maphash (lambda (_name value) (check value)) map))
    map))

(defun strudel--http-response (client status body &optional type)
  "Send STATUS and binary BODY of TYPE to CLIENT, then close it."
  (when (process-live-p client)
    (process-send-string
     client
     (concat (format "HTTP/1.1 %s\r\nContent-Length: %d\r\n" status (string-bytes body))
             "Connection: close\r\nCache-Control: no-store\r\n"
             "X-Content-Type-Options: nosniff\r\n"
             ;; Eval and blob worklets are required by Strudel.  External
             ;; fetches are deliberately excluded from the offline player.
             "Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-eval' blob: data:; worker-src 'self' blob: data:; connect-src 'self'; media-src 'self' blob:; style-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'\r\n"
             "Content-Type: " (or type "text/plain; charset=utf-8") "\r\n\r\n"
             body))
    (process-send-eof client)))

(defun strudel--serve (client request)
  "Handle one HTTP REQUEST from CLIENT."
  (if (not (string-match "\\`GET \\([^ ]+\\) HTTP/1\\.[01]\r\n" request))
      (strudel--http-response client "405 Method Not Allowed" "GET only")
    (let* ((path (decode-coding-string
                  (url-unhex-string (car (split-string (match-string 1 request) "?")))
                  'utf-8))
           (prefix (concat "/" strudel--token "/"))
           (relative (and (string-prefix-p prefix path) (substring path (length prefix))))
           (mount (and relative
                       (cl-find-if (lambda (entry) (string-prefix-p (car entry) relative))
                                   strudel--mounts)))
           (file (and mount (strudel--safe-file
                             (cdr mount) (substring relative (length (car mount)))))))
      (cond
       ((equal relative "samples/strudel.json")
        (let ((map (copy-hash-table strudel--sample-map)))
          (puthash "_base" (concat strudel--base-url "samples/") map)
          (strudel--http-response client "200 OK"
                                  (encode-coding-string (json-serialize map) 'utf-8)
                                  "application/json")))
       ((and file (or (not (equal (car mount) "samples/"))
                      (member (downcase (or (file-name-extension file) ""))
                              '("wav" "mp3" "ogg" "flac" "m4a" "aif" "aiff"))))
        (strudel--http-response
         client "200 OK"
         ;; ponytail: one sample per response buffer; stream large assets
         ;; if long recordings make this block interactive editing.
         (with-temp-buffer (set-buffer-multibyte nil)
                           (insert-file-contents-literally file) (buffer-string))
         (or (cdr (assoc (downcase (or (file-name-extension file) ""))
                         '(("html" . "text/html; charset=utf-8")
                           ("mjs" . "text/javascript") ("js" . "text/javascript")
                           ("css" . "text/css") ("wav" . "audio/wav")
                           ("mp3" . "audio/mpeg") ("ogg" . "audio/ogg")
                           ("flac" . "audio/flac") ("m4a" . "audio/mp4"))))
             "application/octet-stream")))
       (t
        (when relative (push (format "Missing asset: %s" relative) strudel--server-errors))
        (strudel--http-response client "404 Not Found" "Asset not found"))))))

(defun strudel--http-filter (client chunk)
  "Accumulate HTTP headers from CLIENT CHUNK, including split deliveries."
  (unless (process-get client 'answered)
    (let ((request (concat (process-get client 'request) chunk)))
      (process-put client 'request request)
      (cond
       ((> (length request) 16384)
        (process-put client 'answered t)
        (strudel--http-response client "431 Request Header Fields Too Large" "Header too large"))
       ((string-match-p "\r\n\r\n" request)
        (process-put client 'answered t)
        (condition-case err (strudel--serve client request)
          (error
           (push (error-message-string err) strudel--server-errors)
           (strudel--http-response client "500 Internal Server Error" "Asset read failed"))))))))

(defun strudel--server-stop ()
  "Close the asset server and its accepted connections."
  (dolist (client strudel--clients)
    (when (process-live-p client) (delete-process client)))
  (setq strudel--clients nil)
  (when (process-live-p strudel--server) (delete-process strudel--server))
  (setq strudel--server nil))

(defun strudel--server-start (app runtime samples)
  "Serve APP, RUNTIME and SAMPLES on a loopback-only ephemeral port."
  (strudel--server-stop)
  (setq strudel--sample-map (strudel--sample-map samples)
        strudel--server-errors nil
        strudel--token (substring (secure-hash 'sha256 (format "%s%s%s" (random) (current-time) (emacs-pid))) 0 32)
        strudel--mounts `(("runtime/" . ,runtime) ("samples/" . ,samples) ("" . ,app))
        strudel--server
        (make-network-process
         :name "strudel-assets" :server t :host "127.0.0.1" :service t
         :family 'ipv4 :coding 'binary :noquery t
         :filter #'strudel--http-filter
         :log (lambda (_server client _message)
                (push client strudel--clients)
                (set-process-query-on-exit-flag client nil)
                (set-process-sentinel
                 client (lambda (process _event)
                          (unless (process-live-p process)
                            (setq strudel--clients (delq process strudel--clients)))))
                (run-at-time 10 nil (lambda ()
                                     (when (process-live-p client) (delete-process client)))))))
  (setq strudel--base-url
        (format "http://127.0.0.1:%d/%s/" (process-contact strudel--server :service) strudel--token)))

(provide 'strudel-server)
;;; strudel-server.el ends here
