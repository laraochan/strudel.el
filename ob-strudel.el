;;; ob-strudel.el --- Org Babel support for Strudel -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:
;; Execute source blocks in the same persistent session as normal buffers.
;; Org's standard evaluation confirmation remains enabled.

;;; Code:
(require 'ob)
(require 'strudel)

(defvar org-babel-default-header-args:strudel '((:results . "silent"))
  "Default header arguments for Strudel source blocks.")

(add-to-list 'org-src-lang-modes '("strudel" . strudel-js))
(add-to-list 'org-babel-tangle-lang-exts '("strudel" . "strudel"))

(defun org-babel-execute:strudel (body params)
  "Evaluate Strudel BODY with PARAMS in the shared player.
Supports :dir and standard noweb expansion.  Separate sessions, :var,
and result capture are not supported by the initial live player."
  (when (or (assq :var params)
            (let ((session (cdr (assq :session params))))
              (and session (not (equal session "none")))))
    (user-error "Strudel uses one live session and does not support :var"))
  ;; Babel already binds default-directory to the expanded :dir.  Expanding
  ;; a relative :dir again would accidentally descend into it twice.
  (let ((directory default-directory))
    (when (file-remote-p directory) (user-error "Strudel requires a local project"))
    (strudel-eval-string body directory
                        (format "%s:%d" (or buffer-file-name (buffer-name)) (line-number-at-pos))))
  nil)

(provide 'ob-strudel)
;;; ob-strudel.el ends here
