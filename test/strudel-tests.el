;;; strudel-tests.el --- Strudel regression tests -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: AGPL-3.0-or-later
(require 'ert)
(require 'strudel)
(require 'ob-strudel)

(ert-deftest strudel-assets-stay-inside-root ()
  (let ((root (make-temp-file "strudel-test-" t))
        (outside (make-temp-file "strudel-outside-")))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "kick.wav" root) (insert "audio"))
          (make-symbolic-link outside (expand-file-name "escape.wav" root))
          (should (strudel--safe-file root "kick.wav"))
          (should-not (strudel--safe-file root "../secret"))
          (should-not (strudel--safe-file root outside))
          (should-not (strudel--safe-file root "escape.wav")))
      (delete-directory root t) (delete-file outside))))

(ert-deftest strudel-manifest-order-and-validation ()
  (let ((root (make-temp-file "strudel-samples-" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "drums" root))
          (dolist (name '("drums/z.wav" "drums/a.wav" "日本語.wav"))
            (with-temp-file (expand-file-name name root) (insert "audio")))
          (let ((map (strudel--sample-map root)))
            (should (equal (gethash "drums" map) ["drums/a.wav" "drums/z.wav"]))
            (should (equal (gethash "日本語" map) ["日本語.wav"])))
          (with-temp-file (expand-file-name "strudel.json" root)
            (insert "{\"kick\":\"https://example.com/kick.wav\"}"))
          (should-error (strudel--sample-map root))
          (with-temp-file (expand-file-name "strudel.json" root)
            (insert "{\"kick\":\"missing.wav\"}"))
          (should-error (strudel--sample-map root)))
      (delete-directory root t))))

(defun strudel-test--get (path &optional method split)
  "Request PATH from the running server, optionally using METHOD or SPLIT."
  (let ((response "") (closed nil)
        (port (process-contact strudel--server :service)))
    (let ((client (make-network-process
                   :name "strudel-test-client" :host "127.0.0.1" :service port
                   :family 'ipv4 :coding 'binary :noquery t
                   :filter (lambda (_process chunk) (setq response (concat response chunk)))
                   :sentinel (lambda (_process _event) (setq closed t)))))
      (unwind-protect
          (progn
            (process-send-string client (concat (or method "GET") " " path " HTTP/1.1\r\n"))
            (when split (accept-process-output nil 0.02))
            (process-send-string client "Host: 127.0.0.1\r\n\r\n")
            (let ((deadline (+ (float-time) 3)))
              (while (and (not closed) (< (float-time) deadline))
                (accept-process-output nil 0.01)))
            response)
        (when (process-live-p client) (delete-process client))))))

(ert-deftest strudel-http-framing-and-access ()
  (let ((root (make-temp-file "strudel-http-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "index.html" root) (insert "hello"))
          (with-temp-file (expand-file-name "secret.org" root) (insert "private"))
          (strudel--server-start root root root)
          (let* ((prefix (concat "/" strudel--token "/"))
                 (response (strudel-test--get (concat prefix "index.html") nil t)))
            (should (string-prefix-p "HTTP/1.1 200" response))
            (should (string-suffix-p "\r\n\r\nhello" response))
            (should (string-match-p "connect-src 'self'" response))
            (should (string-prefix-p "HTTP/1.1 404" (strudel-test--get "/index.html")))
            (should (string-prefix-p "HTTP/1.1 404"
                                     (strudel-test--get (concat prefix "samples/secret.org"))))
            (should (string-prefix-p "HTTP/1.1 404"
                                     (strudel-test--get (concat prefix "%2e%2e/secret.org"))))
            (should (string-prefix-p "HTTP/1.1 405"
                                     (strudel-test--get (concat prefix "index.html") "POST")))
            (should (string-match-p "_base" (strudel-test--get (concat prefix "samples/strudel.json"))))))
      (strudel--server-stop) (delete-directory root t))))

(ert-deftest strudel-code-is-json-not-script-interpolation ()
  (let ((strudel--widget 'test) (strudel--buffer (current-buffer)) captured
        (code "s(\"kick\")\n// 日本語 '); throw Error('injected');"))
    (cl-letf (((symbol-function 'xwidget-webkit-execute-script)
               (lambda (_widget script &optional _callback) (setq captured script))))
      (strudel--send `((type . "eval") (code . ,code)))
      (let* ((json (substring captured (length "window.strudelEmacs.command(") (- (length "); null"))))
             (decoded (json-parse-string json)))
        (should (equal (gethash "code" decoded) code))))))

(ert-deftest strudel-babel-expands-noweb-and-dir ()
  (let ((root (make-temp-file "strudel-org-" t)) captured)
    (unwind-protect
        (progn
          (make-directory (expand-file-name "song" root))
          (with-temp-buffer
            (org-mode)
            (setq default-directory (file-name-as-directory root))
            (insert "#+name: rhythm\n#+begin_src strudel\ns(\"kick\")\n#+end_src\n\n"
                    "#+begin_src strudel :dir song :noweb yes :results silent\n<<rhythm>>\n#+end_src\n")
            (goto-char (point-max)) (forward-line -2)
            (let ((org-confirm-babel-evaluate nil)) ; Test fixture only.
              (cl-letf (((symbol-function 'strudel-eval-string)
                         (lambda (code dir &optional _source) (setq captured (list code dir)))))
                (org-babel-execute-src-block)))
            (should (string-match-p "s(\"kick\")" (car captured)))
            (should (equal (cadr captured) (expand-file-name "song/" root)))
            (should-not (string-match-p "^#\\+RESULTS:" (buffer-string)))))
      (delete-directory root t))))

(ert-deftest strudel-rejects-unsupported-babel-session ()
  (should-error (org-babel-execute:strudel "s('kick')" '((:session . "other"))) :type 'user-error))

(ert-deftest strudel-import-copies-without-overwriting ()
  (let ((source (make-temp-file "strudel-import-source-" t))
        (project (make-temp-file "strudel-import-project-" t)))
    (unwind-protect
        (let ((default-directory (file-name-as-directory project)))
          (with-temp-file (expand-file-name "kick.wav" source) (insert "original"))
          (strudel-import-samples source)
          (should (equal (with-temp-buffer
                           (insert-file-contents (expand-file-name "samples/kick.wav" project))
                           (buffer-string)) "original"))
          (should-error (strudel-import-samples source) :type 'user-error)
          (should (file-exists-p (expand-file-name "kick.wav" source))))
      (delete-directory source t) (delete-directory project t))))

(ert-deftest strudel-ignores-old-session-callback ()
  (let ((strudel--widget 'new) (strudel--state "ready"))
    (strudel--receive 'old "{\"state\":\"error\",\"events\":[]}")
    (should (equal strudel--state "ready"))))

(ert-deftest strudel-quit-does-not-prompt-for-owned-widget ()
  (let* ((buffer (generate-new-buffer " *strudel-quit-test*"))
         (strudel--buffer buffer) (strudel--widget 'test-widget)
         (strudel--poll-timer nil) (strudel--server nil)
         (strudel--clients nil) (disabled nil))
    (unwind-protect
        (cl-letf (((symbol-function 'set-xwidget-query-on-exit-flag)
                   (lambda (widget flag)
                     (should (eq widget 'test-widget))
                     (should-not flag)
                     (setq disabled t))))
          (with-current-buffer buffer
            (add-hook 'kill-buffer-query-functions (lambda () (should disabled)) nil t))
          (strudel-quit)
          (should-not (buffer-live-p buffer))
          (should-not strudel--widget))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest strudel-enables-once-and-shows-only-on-fallback ()
  (let ((strudel--widget 'test) (strudel--buffer (current-buffer))
        (strudel--state "loading") sent shown)
    (cl-letf (((symbol-function 'strudel--send)
               (lambda (command) (push command sent)))
              ((symbol-function 'display-buffer)
               (lambda (buffer &rest _) (push buffer shown))))
      (dotimes (_ 2)
        (strudel--receive 'test "{\"state\":\"loaded\",\"events\":[]}"))
      (should (equal sent '(((type . "enable")))))
      (strudel--receive 'test "{\"state\":\"ready\",\"events\":[]}")
      (should-not shown)
      (strudel--receive 'test "{\"state\":\"enable-audio\",\"events\":[]}")
      (should (equal shown (list (current-buffer)))))))

;;; strudel-tests.el ends here
