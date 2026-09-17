;;; strudel.el --- Offline Strudel in an Emacs WebKit buffer -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: AGPL-3.0-or-later
;; Author: larao <me@larao.dev>
;; Maintainer: larao <me@larao.dev>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: multimedia

;;; Commentary:
;; Run `strudel-setup' once to install the pinned JavaScript runtime.
;; Evaluate a buffer or Org source block to start playback automatically.  Playback and samples stay on this computer.

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'strudel-server)

(defgroup strudel nil "Offline live coding with Strudel." :group 'multimedia)
(defconst strudel--directory (file-name-directory (or load-file-name buffer-file-name)))
(defconst strudel-runtime-version "1.3.0")
(defcustom strudel-runtime-directory
  (expand-file-name "var/strudel/runtime/1.3.0/" user-emacs-directory)
  "Directory containing the pinned @strudel/web distribution.
Kept outside the package so upgrades do not remove downloaded assets."
  :type 'directory)
(defconst strudel--runtime-files
  '(("dist/index.mjs" . "50beb01abd04589333a10e078dce182c82e2de75b43e9bbe81a34bd069948931")
    ("dist/assets/clockworker-ZDiUtESR.js" . "effd682665d000035c72c378e9b6338ab996c0a13d847910caaaef0fec20984a")
    ("LICENSE" . "0d96a4ff68ad6d4b6f1f30f713b18d5184912ba8dd389f86aa7710db079abcb0")))
(defvar strudel--buffer nil)
(defvar strudel--widget nil)
(defvar strudel--project nil)
(defvar strudel--poll-timer nil)
(defvar strudel--poll-pending nil)
(defvar strudel--state "off")
(defvar strudel--pending-eval nil
  "Latest (CODE DIRECTORY SOURCE) waiting for the runtime to become ready.")
(defvar strudel--request-id 0)
(defvar strudel--sources (make-hash-table :test #'eql))

(declare-function xwidget-webkit-new-session "xwidget" (url))
(declare-function xwidget-webkit-current-session "xwidget" ())
(declare-function xwidget-webkit-execute-script "xwidget.c" (xwidget script &optional fun))
(declare-function set-xwidget-query-on-exit-flag "xwidget.c" (xwidget flag))

(defun strudel--sha256 (file)
  "Compute FILE's SHA256 over its literal bytes."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

;;;###autoload
(defun strudel-setup ()
  "Download and verify the pinned Strudel runtime once.
No package scripts or npm install are run.  Later playback is offline."
  (interactive)
  (require 'url-handlers)
  (dolist (entry strudel--runtime-files)
    (let ((target (expand-file-name (car entry) strudel-runtime-directory)))
      (unless (and (file-exists-p target) (equal (strudel--sha256 target) (cdr entry)))
        (make-directory (file-name-directory target) t)
        (let ((temporary (make-temp-file (concat target ".download-"))))
          (unwind-protect
              (progn
                (url-copy-file (format "https://unpkg.com/@strudel/web@%s/%s"
                                       strudel-runtime-version (car entry)) temporary t)
                (unless (equal (strudel--sha256 temporary) (cdr entry))
                  (error "Strudel checksum mismatch: %s" (car entry)))
                (rename-file temporary target t))
            (when (file-exists-p temporary) (delete-file temporary)))))))
  (message "Strudel %s installed; evaluate a buffer or Org block to play" strudel-runtime-version))

(defun strudel--log (text)
  "Append TEXT to the Strudel error buffer."
  (with-current-buffer (get-buffer-create "*Strudel errors*")
    (let ((inhibit-read-only t))
      (goto-char (point-max)) (insert text "\n") (special-mode)))
  (message "Strudel: %s" text))

(defun strudel--receive (widget payload)
  "Process JSON PAYLOAD from WIDGET, ignoring callbacks from old sessions."
  (when (eq widget strudel--widget)
    (setq strudel--poll-pending nil)
    (when (and (stringp payload) (not (equal payload "null")))
      (condition-case err
          (let* ((data (json-parse-string payload :object-type 'alist :array-type 'list))
                 (state (alist-get 'state data)))
            (when (or (equal state "error")
                      (cl-find "stopped" (alist-get 'events data)
                               :key (lambda (event) (alist-get 'type event)) :test #'equal))
              (setq strudel--pending-eval nil))
            (when (and state (not (equal state strudel--state)))
              (setq strudel--state state)
              (force-mode-line-update t)
              (cond
               ((equal state "loaded")
                (strudel--send '((type . "enable"))))
               ((equal state "enable-audio")
                (display-buffer strudel--buffer)
                (message "Strudel: WebKit needs a click on Enable audio"))
               ((equal state "ready")
                (if strudel--pending-eval
                    (let ((pending strudel--pending-eval))
                      (setq strudel--pending-eval nil)
                      (apply #'strudel-eval-string pending))
                  (message "Strudel ready")))))
            (dolist (event (alist-get 'events data))
              (let* ((id (alist-get 'id event))
                     (source (gethash id strudel--sources))
                     (text (alist-get 'message event)))
                (when (equal (alist-get 'type event) "error")
                  (strudel--log (format "%s%s" (if source (concat source ": ") "") text)))
                (when id (remhash id strudel--sources)))))
        (error (strudel--log (error-message-string err)))))))

(defun strudel--poll ()
  "Retrieve state and asynchronous errors from the persistent runtime."
  (when (and strudel--widget (buffer-live-p strudel--buffer))
    (dolist (error (reverse strudel--server-errors)) (strudel--log error))
    (setq strudel--server-errors nil)
    (unless strudel--poll-pending
      (let ((widget strudel--widget))
        (setq strudel--poll-pending t)
        (condition-case err
            (xwidget-webkit-execute-script
             widget "JSON.stringify(window.strudelEmacs ? window.strudelEmacs.drain() : null)"
             (lambda (payload) (strudel--receive widget payload)))
          (error (setq strudel--poll-pending nil)
                 (strudel--log (error-message-string err))))))))

(defun strudel--cleanup ()
  "Release the singleton session when its WebKit buffer is killed."
  (when (timerp strudel--poll-timer) (cancel-timer strudel--poll-timer))
  (setq strudel--poll-timer nil strudel--poll-pending nil strudel--pending-eval nil
        strudel--widget nil strudel--buffer nil strudel--project nil strudel--state "off")
  (clrhash strudel--sources)
  (strudel--server-stop)
  (force-mode-line-update t))

;;;###autoload
(defun strudel-start (&optional directory)
  "Start Strudel in the background for DIRECTORY or `default-directory'.
The project samples/ directory is registered automatically.  Starting a
different project closes the previous session.  Requires GUI Xwidgets."
  (interactive)
  (unless (and (display-graphic-p) (featurep 'xwidget-internal))
    (user-error "Strudel requires a graphical Emacs built with Xwidgets"))
  (let ((directory (or directory default-directory)))
    (when (file-remote-p directory) (user-error "Strudel requires a local project"))
    (setq directory (file-name-as-directory (file-truename directory)))
    (unless (file-directory-p directory) (user-error "No project directory: %s" directory))
    (if (and (equal directory strudel--project) (buffer-live-p strudel--buffer))
        (message "Strudel: %s" strudel--state)
      (dolist (entry strudel--runtime-files)
        (let ((file (expand-file-name (car entry) strudel-runtime-directory)))
          (unless (and (file-exists-p file) (equal (strudel--sha256 file) (cdr entry)))
            (user-error "Strudel runtime missing or modified; run M-x strudel-setup"))))
      (strudel-quit)
      (require 'xwidget)
      (condition-case err
          (progn
            (strudel--server-start (expand-file-name "web/" strudel--directory)
                                   strudel-runtime-directory (expand-file-name "samples/" directory))
            (setq strudel--project directory strudel--state "loading")
            ;; Realize the WebKit view once: an undisplayed macOS view cannot
            ;; start audio.  Then restore the editor and keep the player alive.
            (save-window-excursion
              (xwidget-webkit-new-session (concat strudel--base-url "index.html"))
              (setq strudel--buffer (current-buffer)
                    strudel--widget (xwidget-webkit-current-session))
              (set-xwidget-query-on-exit-flag strudel--widget nil)
              (setq-local default-directory directory)
              (setq-local xwidget-webkit-buffer-name-format "*Strudel*")
              (rename-buffer "*Strudel*" t)
              (add-hook 'kill-buffer-hook #'strudel--cleanup nil t)
              (redisplay t))
            (setq strudel--poll-timer (run-at-time 0.2 0.3 #'strudel--poll))
            (message "Starting Strudel in the background..."))
        (error (strudel-quit) (signal (car err) (cdr err)))))))

;;;###autoload
(defun strudel-show ()
  "Show the player controls without restarting the audio session."
  (interactive)
  (unless (buffer-live-p strudel--buffer)
    (user-error "Start Strudel with M-x strudel-start first"))
  (pop-to-buffer strudel--buffer))

;;;###autoload
(defun strudel-quit ()
  "Close the Strudel runtime and local asset server."
  (interactive)
  (when strudel--widget (set-xwidget-query-on-exit-flag strudel--widget nil))
  (when (buffer-live-p strudel--buffer) (kill-buffer strudel--buffer))
  (strudel--cleanup))

(defun strudel--send (command)
  "Send COMMAND as JSON, never interpolating source code as JavaScript."
  (unless (and strudel--widget (buffer-live-p strudel--buffer))
    (user-error "Start Strudel with M-x strudel-start first"))
  (xwidget-webkit-execute-script
   strudel--widget
   (concat "window.strudelEmacs.command(" (json-serialize command) "); null")))

(defun strudel-eval-string (code &optional directory source)
  "Evaluate CODE for DIRECTORY with SOURCE identifying errors.
Start the runtime automatically if needed.  While starting, retain only
the latest evaluation.  The last evaluation replaces the complete pattern."
  (setq directory (or directory default-directory)
        source (or source (buffer-name)))
  (when (file-remote-p directory) (user-error "Strudel requires a local project"))
  (setq directory (file-name-as-directory (file-truename directory)))
  (unless (and (equal directory strudel--project) (buffer-live-p strudel--buffer))
    (strudel-start directory))
  (if (member strudel--state '("loading" "loaded" "starting-audio" "enable-audio"))
      (progn
        (setq strudel--pending-eval (list code directory source))
        (message "Strudel: waiting for audio; latest evaluation will play when ready"))
    (let ((id (cl-incf strudel--request-id)))
      (puthash id source strudel--sources)
      (strudel--send `((type . "eval") (id . ,id) (code . ,code))))))

;;;###autoload
(defun strudel-eval-buffer ()
  "Evaluate the entire current buffer as a Strudel pattern."
  (interactive)
  (strudel-eval-string (buffer-substring-no-properties (point-min) (point-max))))

(defun strudel-eval-region (begin end)
  "Evaluate the region from BEGIN to END, replacing the complete pattern."
  (interactive "r")
  (strudel-eval-string (buffer-substring-no-properties begin end)))

;;;###autoload
(defun strudel-stop ()
  "Stop playback, including an evaluation that is still pending."
  (interactive)
  (setq strudel--pending-eval nil)
  ;; No code has been sent during startup; do not interrupt its handshake.
  (when (and (buffer-live-p strudel--buffer)
             (member strudel--state '("ready" "playing" "stopped" "error")))
    (strudel--send '((type . "stop")))))

;;;###autoload
(defun strudel-import-samples (directory)
  "Copy audio from DIRECTORY into this project's samples/ directory.
Never overwrite existing assets.  A manifest in DIRECTORY is preserved.
Restart the player after importing to register the new sounds."
  (interactive "DImport sounds folder: ")
  (when (file-remote-p directory) (user-error "Choose a local samples directory"))
  (when (file-remote-p default-directory) (user-error "Choose a local project directory"))
  (let ((target (expand-file-name "samples/" default-directory)))
    (when (file-exists-p target) (user-error "samples/ already exists; manage it with Dired"))
    ;; Validate before copying, and avoid following links outside the source.
    (let ((map (strudel--sample-map directory)))
      (unless (> (hash-table-count map) 0) (user-error "No audio files found")))
    (let* ((files (directory-files-recursively directory "."))
           (staging (make-temp-file (expand-file-name ".strudel-import-" default-directory) t)))
      (unwind-protect
          (progn
            (dolist (file files)
              (when (or (equal (file-name-nondirectory file) "strudel.json")
                        (member (downcase (or (file-name-extension file) ""))
                                '("wav" "mp3" "ogg" "flac" "m4a" "aif" "aiff")))
                (let* ((relative (file-relative-name file directory))
                       (destination (expand-file-name relative staging)))
                  (unless (strudel--safe-file directory relative) (error "Unsafe sample: %s" file))
                  (make-directory (file-name-directory destination) t)
                  (copy-file file destination nil))))
            (rename-file staging (directory-file-name target)))
        (when (file-directory-p staging) (delete-directory staging t))))
    (message "Samples copied to %s; restart Strudel to register them" target)))

(defvar strudel-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'strudel-eval-buffer)
    (define-key map (kbd "C-c C-r") #'strudel-eval-region)
    (define-key map (kbd "C-c C-s") #'strudel-stop)
    (define-key map (kbd "C-c C-z") #'strudel-start)
    map))

;;;###autoload
(define-minor-mode strudel-mode
  "Edit Strudel using the existing JavaScript major mode."
  :lighter (:eval (concat " Strudel:" strudel--state))
  :keymap strudel-mode-map)

;;;###autoload
(define-derived-mode strudel-js-mode js-mode "Strudel"
  "JavaScript editing for Strudel files and Org source edit buffers."
  (strudel-mode 1))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.\\(strudel\\|str\\)\\'" . strudel-js-mode))

(add-hook 'kill-emacs-hook #'strudel--server-stop)
(provide 'strudel)
;;; strudel.el ends here
