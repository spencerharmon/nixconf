;; ===================================
;; ELPA Hack
;; ===================================
;; Enables basic packaging support

;; Hack for using a different set of repositories when ELPA is down
(setq package-archives
      '(("melpa" . "https://raw.githubusercontent.com/d12frosted/elpa-mirror/master/melpa/")
        ("org"   . "https://raw.githubusercontent.com/d12frosted/elpa-mirror/master/org/")
        ("gnu"   . "https://raw.githubusercontent.com/d12frosted/elpa-mirror/master/gnu/")))
;; (setq package-check-signature nil) ;; probably not necessary
(package-initialize)

;; ===================================
;; MELPA Package Support
;; ===================================
;; Enables basic packaging support
(require 'package)


(add-to-list 'package-archives
             '("melpa-stable" . "https://stable.melpa.org/packages/"))
(add-to-list 'package-archives
             '("gnu" . "https://elpa.gnu.org/packages/"))
(add-to-list 'package-archives
             '("melpa" . "http://melpa.org/packages/"))


(package-initialize)

;; If there are no archived package contents, refresh them
(when (not package-archive-contents)
  (package-refresh-contents))


;; list package names
(defvar myPackages
  '(better-defaults                 ;; Set up some better Emacs defaults
    elpy                            ;; Emacs Lisp Python Environment
    flycheck
    py-autopep8
    material-theme
    flyspell-correct-ivy
    per-buffer-theme
    yaml-mode
    yaml-tomato
    )
  )

;; Scans the list in myPackages
;; If the package listed is not already installed, install it
;; Tolerate failures (missing from archives, no network, etc.) so that
;; emacs still comes up — important because EXWM is emacs.
(mapc (lambda (package)
        (condition-case err
            (unless (package-installed-p package)
              (package-install package))
          (error (message "Failed to install %s: %s" package err))))
      myPackages)

;; =============
;; Sound
;; =============
(setq ring-bell-function 'ignore) ;; bell off :)

;; ====================================
;; Aesthetic
;; ====================================

;; disable toolbar
;; enable custom theme
(load-theme 'spencer t)

;; emoji support (depends on fonts-noto)
(set-fontset-font "fontset-default" 'symbol "Noto Color Emoji")

;; ====================================
;; Terminal Setup
;; ====================================

;; set per-buffer theme, esp for term
;; best setup is to have multiple emacs instances,
;; one dedicated to term. This will keep the theme from
;; changing back-and-forth.
;; Then, run tmux on bastion host.
(require 'per-buffer-theme nil 'noerror)
;; NOTE: variable names changed in newer per-buffer-theme.el
;; use hyphenated variable names (not slashes) and proper alist format.
(setq per-buffer-theme-use-timer t)
(setq per-buffer-theme-timer-idle-delay 0.1)
(setq per-buffer-theme-default-theme 'spencer)
(setq per-buffer-theme-themes-alist
      '(((:theme . spencer-dark)
         (:font . nil)
         (:buffernames . ("*terminal*"))
         (:modes . (term-mode)))))
(per-buffer-theme-mode)

;; yank in term (kill-ing)
(defun term-yank-kill-ring ()
  (interactive)
  ;; extra paste from within term: could get us in trouble.
  (term-paste)
  (flet ((insert-for-yank (string) (term-send-raw-string string)))
    (yank)))
;; yank-pop un term (kill-ring)
(defun term-yank-pop-kill-ring ()
  (interactive)
  (dotimes (i (- (point) (mark t)))
    (term-send-backspace))
  (process-send-string
   (get-buffer-process (current-buffer))
   (current-kill 1)))

(defun term-send-keys (keys)
  (interactive)
  (term-send-raw-string keys))

(defun term-C-y () (interactive)
       (term-send-raw-string "\C-y"))

(defun term-M-y () (interactive)
       (term-send-raw-meta)
       (term-send-raw-string "y")
       (term-send-backspace))

(defun term-C-w () (interactive)
       (term-send-raw-string "\C-w"))

(defun term-M-w () (interactive)
       (term-send-raw-meta)
       (term-send-raw-string "w")
       (term-send-backspace))

(defun term-C-SPC () (interactive)
       (term-send-raw-string "\C-\ "))

(defun double-kill () (interactive)
       (term-send-raw-string "\C-k")
       (kill-line))


;; C-y is paste in term (i.e. yank)
;; C-k sends literal sequence to terminal
;; C-c C-b does list-buffers instead of the ido version
;; C-M-y to switch to emacs-in-emacs bindings
(defun terminal-in-emacs-keybindings ()
  (interactive)
  (with-eval-after-load "term"
    (message "terminal-in-emacs")
    (define-key term-raw-map (kbd "C-y") 'term-yank-kill-ring)
    (define-key term-raw-map (kbd "M-y") 'term-yank-pop-kill-ring)
    (define-key term-raw-map (kbd "C-k") 'double-kill)
    (define-key term-raw-map (kbd "C-c C-b") 'list-buffers)
    (define-key term-raw-map (kbd "M-w") nil)
    (define-key term-raw-map (kbd "C-w") nil)
    (define-key term-raw-map (kbd "C-M-y") 'emacs-in-emacs-keybindings)))


(defun emacs-in-emacs-keybindings ()
  (interactive)
    (message "Emacs-in-emacs")
    (define-key term-raw-map (kbd "C-y") 'term-C-y)
    (define-key term-raw-map (kbd "M-y") 'term-M-y)
    (define-key term-raw-map (kbd "C-w") 'term-C-w)
    (define-key term-raw-map (kbd "M-w") 'term-M-w)
    (define-key term-raw-map (kbd "C-SPC") 'term-C-SPC)
    (define-key term-raw-map (kbd "C-M-y") 'terminal-in-emacs-keybindings))


(add-hook 'term-mode-hook 'terminal-in-emacs-keybindings)
(remove-hook 'term-mode-hook 'hidepw-mode)
;; linum-mode deprecated
;;(remove-hook 'term-mode-hook
;;          '(lambda () (interactive) (linum-mode 0)))

;; ====================================
;; Python Setup
;; ====================================

;; Enable elpy
(elpy-enable)

;; Enable pyenv

(use-package pyvenv
  :ensure t
  :config
  (pyvenv-mode t)

  ;; Set correct Python interpreter
  (setq pyvenv-post-activate-hooks
        (list (lambda ()
                (setq python-shell-interpreter (concat pyvenv-virtual-env "bin/python3")))))
  (setq pyvenv-post-deactivate-hooks
        (list (lambda ()
                (setq python-shell-interpreter "python3")))))


;; disable python vertical lines
(add-hook 'elpy-mode-hook (lambda () (highlight-indentation-mode -1)))

;; C-S-t does unit tests
(global-set-key (kbd "C-S-t")
 (lambda () (interactive) (comint-send-string
   (get-buffer-process (shell))
   "python -m unittest --verbose\n")))

;; Enable Flycheck
(when (require 'flycheck nil t)
  (setq elpy-modules (delq 'elpy-module-flymake elpy-modules))
  (add-hook 'elpy-mode-hook 'flycheck-mode))

;; Enable autopep8

(require 'py-autopep8 nil 'noerror)
(add-hook 'elpy-mode-hook 'py-autopep8-mode)


;; set python to python3 for wrong-ubuntu
(setq elpy-rpc-python-command "python3")

;; ===================================
;; agent-shell
;; ===================================

(use-package agent-shell
    :ensure t
    :ensure-system-package
    ())

;; qwen code
  (setq agent-shell-qwen-authentication
        (agent-shell-qwen-make-authentication :none t))

;; ===================================
;; magit
;; ===================================
(setq global-auto-revert-mode 1)

;; ===================================
;; Basic Customization
;; ===================================

(server-start)
(setq inhibit-startup-message t)    ;; Hide the startup message
(setq require-final-newline nil)  ;; don't require newline at EOF
(add-hook 'window-setup-hook
          '(lambda () (global-display-line-numbers-mode 0)))   ;; No global linum mode

(global-font-lock-mode 1) ;;enables syntax highlighting
(setq font-lock-maximum-decoration t) ;; makes it really really highlighted?

(setq search-invisible t) ;;makes replace-regexp work on org-mode links

;; no tabs!
(setq-default indent-tabs-mode nil)

;; Enable syntax highlighting for Emacs Lisp (disabled, this may be wrong)
;;(add-hook 'emacs-lisp-mode-hook 'font-lock-mode)

;; flyspell
(require 'flyspell-correct-ivy nil 'noerror)
(define-key flyspell-mode-map (kbd "C-;") 'flyspell-correct-wrapper)
(add-hook 'text-mode-hook 'flyspell-mode)
(add-hook 'prog-mode-hook 'flyspell-prog-mode)

;; hide passwords
;;(require 'hidepw)
;;(setq hidepw-patterns '("\\(ignoreme\\)"
;;                        "\\(\"spharmon\"\\)"
;;                        ))
(remove-hook 'text-mode-hook 'hidepw-mode)

;; yaml syntax highlighting
(require 'yaml-mode nil 'noerror)
(add-to-list 'auto-mode-alist '("\\.yml\\'" . yaml-mode))
(add-to-list 'auto-mode-alist '("\\.yaml\\'" . yaml-mode))

(custom-set-variables
 ;; custom-set-variables was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 '(ansi-color-faces-vector
   [default bold shadow italic underline bold bold-italic bold])
 '(ansi-color-names-vector
   ["#212121" "#B71C1C" "#558b2f" "#FFA000" "#2196f3" "#4527A0" "#00796b" "#FAFAFA"])
 '(custom-safe-themes
   '("2b487223d9f93d9eb9c884481558f2bcc109a20fffb0a469d2124e4cd14bb51d" "4239d554caec7dd88b3779d91cb205708003a0e7b2dfca00276b462f0a78c4c9" "c54bc50c01a8415fcdae1e3b0ecd2aba481696ae111d559b8c52435d8e1b4c7a" "4707b932af6477af309fd45950d45554d01028809569d302c4598256e53697e1" "1dba383b19b641f50ac0180c7ea3338162c14fda4e3fa902d7293732f2591c18" "b75a93f97ec4c82a11c9ac1e9a60228e9d536f0ead7ec983f17743c48c3bb7bc" "4b13f92f31f41cccc7e3f684f892c384f8669a11ee94ae5377a41be68e8e6073" "0c97bf23063c02593e4ab258567033bd2b426f23f8917d51bcd96fe93528389a" default))
 '(org-file-apps
   '((auto-mode . emacs)
     ("\\.mm\\'" . default)
     ("\\.x?html?\\'" . "/mnt/c/Program\\ Files/Google/Chrome/Application/chrome.exe")
     ("\\.pdf\\'" . default)))
 '(package-selected-packages
   '(outline-indent groovy-mode erc-image circe hidepw per-buffer-theme go-mode terraform-mode flycheck-yamllint poly-ansible flyspell-correct-ivy magit use-package py-autopep8 material-theme flycheck elpy edit-server better-defaults yaml-mode nix-mode)))
(custom-set-faces
 ;; custom-set-faces was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 )
;; ubuntu emacs has ibuffer by default for some reason. Maybe it's better, but it doesn't work as
;; a drop-in replacement for list-buffers from a ux perspective (i.e. missing 'o' hotkey, et c..)
(global-set-key (kbd "C-x C-b") 'list-buffers)

;; removing more ubuntu "improvements" I hhhhhhhhhhhhhhhhhhhhate ido-mode.
(ido-mode -1)

;; disable stupid ubuntu gconf stuff
(define-key special-event-map [config-changed-event] #'ignore)
(put 'upcase-region 'disabled nil)


;; disable ScrLock (because of ensure-scroll-lock powershell script)
(define-key input-decode-map [scroll-lock] nil)
(global-set-key (kbd "<scroll-lock>") nil)

;; =====
;; EXWM (yoga only — depends on running under X as the window manager)
;; =====
(when (string= (system-name) "yoga")
  (condition-case err
      (progn
        (require 'exwm)
        (require 'exwm-config)
        (require 'exwm-systemtray)
        (exwm-systemtray-enable)
        (exwm-config-default)
        (exwm-enable)
        (require 'exwm-firefox-core nil 'noerror)
        (setq exwm-systemtray-height 100)
        (setq exwm-input-global-keys
              `(,(kbd "s-&") .
                (lambda (command)
                  (interactive (list (read-shell-command "$ ")))
                  (start-process-shell-command command nil command))))
        (setq exwm-input-global-keys
              `(,(kbd "s-f") . (start-process-shell-command "firefox" nil "firefox")))
        (when (fboundp 'auto-sudoedit-mode) (auto-sudoedit-mode 1)))
    (error (message "EXWM setup failed: %s" err))))
