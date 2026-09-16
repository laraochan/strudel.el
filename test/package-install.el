;;; package-install.el --- Verify the distributable in isolation -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: AGPL-3.0-or-later
(require 'package)
(require 'cl-lib)

(let* ((archive (expand-file-name (pop command-line-args-left)))
       (temporary (make-temp-file "strudel-package-test-" t))
       (user-emacs-directory (file-name-as-directory temporary))
       (package-user-dir (expand-file-name "elpa/" temporary))
       (package-archives nil)
       (package-check-signature nil))
  (unwind-protect
      (progn
        (package-initialize)
        (package-install-file archive)
        ;; Compilation can load the package while resolving ob-strudel.
        ;; Check autoloads in a fresh process with only the installed tar.
        (with-temp-buffer
          (let ((exit-code
                 (call-process
                  (expand-file-name invocation-name invocation-directory) nil t nil
                  "-Q" "--batch" "--eval"
                  (prin1-to-string
                   `(progn
                      (require 'package)
                      (require 'cl-lib)
                      (setq user-emacs-directory ,user-emacs-directory
                            package-user-dir ,package-user-dir)
                      (package-initialize)
                      (cl-assert (autoloadp (symbol-function 'strudel-start)))
                      (require 'ob-strudel)
                      (find-file (expand-file-name "examples/song.org" strudel--directory))
                      (cl-assert (eq major-mode 'org-mode))
                      (cl-assert (file-in-directory-p strudel--directory package-user-dir)))))))
            (princ (buffer-string))
            (cl-assert (eq exit-code 0))))
        (require 'ob-strudel)
        (find-file (expand-file-name "examples/song.org" strudel--directory))
        (cl-assert (eq major-mode 'org-mode))
        (cl-assert (file-in-directory-p buffer-file-name package-user-dir))
        (cl-assert (file-in-directory-p strudel--directory package-user-dir))
        (cl-assert (file-in-directory-p strudel-runtime-directory user-emacs-directory))
        (cl-assert (not (file-in-directory-p strudel-runtime-directory strudel--directory)))
        (cl-assert (not (file-exists-p (expand-file-name "runtime/" strudel--directory))))
        (dolist (file '("web/index.html" "web/player.mjs" "web/style.css"
                        "LICENSE" "README.org" "examples/samples/kick.wav"))
          (cl-assert (file-readable-p (expand-file-name file strudel--directory))))
        (cl-assert (= 3 (hash-table-count
                        (strudel--sample-map (expand-file-name "examples/samples/" strudel--directory)))))
        (cl-assert (fboundp 'org-babel-execute:strudel))
        (message "Installed tar: autoloads, Org, web assets, samples and cache location OK"))
    (delete-directory temporary t)))
