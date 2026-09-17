;;; strudel-webkit-smoke.el --- Real WebKit/audio check -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: AGPL-3.0-or-later
;; Load after starting Strudel in examples.  Audio is low volume.
;; Run M-x strudel-test-webkit, then M-x strudel-test-webkit-result.
(require 'strudel)
(defconst strudel-test--directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defun strudel-test-webkit ()
  "Exercise the actual pinned runtime inside the current WebKit player."
  (interactive)
  (unless strudel--widget (user-error "Start the example project's Strudel player first"))
  (xwidget-webkit-execute-script
   strudel--widget
   (with-temp-buffer
     (insert-file-contents (expand-file-name "strudel-webkit-smoke.js" strudel-test--directory))
     (buffer-string)))
  (message "WebKit audio check started; inspect result in about 15 seconds"))

(defvar strudel-test-webkit-result nil)
(defun strudel-test-webkit-result ()
  "Read the asynchronous WebKit check result."
  (interactive)
  (xwidget-webkit-execute-script
   strudel--widget "JSON.stringify(window.strudelSmokeResult || null)"
   (lambda (result)
     (setq strudel-test-webkit-result result)
     (message "WebKit check: %s" result))))
;;; strudel-webkit-smoke.el ends here
