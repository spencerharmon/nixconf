;; ===================================
;; PATH / exec-path
;; ===================================
;; ~/.local/bin holds user-managed wrappers (e.g. caveman). Prepend
;; early so anything in init that calls `executable-find' can find them.
(let ((local-bin (expand-file-name "~/.local/bin")))
  (when (file-directory-p local-bin)
    (setenv "PATH" (concat local-bin ":" (getenv "PATH")))
    (add-to-list 'exec-path local-bin)))

;; ===================================
;; Package system
;; ===================================
;; All packages provided by nix via home-manager (programs.emacs.extraPackages).
;; No ELPA/MELPA bootstrap — emacs is the WM on yoga; offline-deterministic.
(require 'package)
(package-initialize)

;; =============
;; Sound
;; =============
(setq ring-bell-function 'ignore) ;; bell off :)

;; ====================================
;; Aesthetic
;; ====================================

;; disable chrome (toolbar, menu bar, scroll bars, tooltips)
;; guarded for tty / -nw startup where these may be nil
(when (fboundp 'tool-bar-mode)   (tool-bar-mode -1))
(when (fboundp 'menu-bar-mode)   (menu-bar-mode -1))
(when (fboundp 'scroll-bar-mode) (scroll-bar-mode -1))
(when (fboundp 'tooltip-mode)    (tooltip-mode -1))

;; enable custom theme
(add-to-list 'custom-theme-load-path
             (expand-file-name "~/.emacs.d/"))
(load-theme 'soft-paper t)

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
(when (require 'per-buffer-theme nil 'noerror)
  ;; NOTE: variable names changed in newer per-buffer-theme.el
  ;; use hyphenated variable names (not slashes) and proper alist format.
  (setq per-buffer-theme-use-timer t)
  (setq per-buffer-theme-timer-idle-delay 0.1)
  (setq per-buffer-theme-default-theme 'soft-paper)
  (setq per-buffer-theme-themes-alist
        '(((:theme . spencer-dark)
           (:font . nil)
           (:buffernames . ("*terminal*"))
           (:modes . (term-mode)))))
  (per-buffer-theme-mode))

(defun spencer-open-startup-shell ()
  "Start in a shell buffer occupying the whole frame."
  (condition-case err
      (progn
        (let ((buf (shell "*shell*")))
          (switch-to-buffer buf)
          (delete-other-windows)))
    (error (message "startup shell skipped: %s" err))))
(add-hook 'emacs-startup-hook #'spencer-open-startup-shell)

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
;; cavemacs
;; ===================================
;; Wrap in condition-case: if caveman binary isn't built yet
;; (~/git-repos/caveman-code requires manual npm install/build),
;; cavemacs signals an error on load. Don't let that abort the
;; rest of init — EXWM lives further down and must come up.
(condition-case err
    (progn
      (setq cavemacs-default-model "github-copilot/gpt-5.5")
      (let ((bin (executable-find "caveman")))
        (when bin (setq cavemacs-binary bin)))
      (require 'cavemacs nil 'noerror))
  (error (message "cavemacs setup skipped: %s" err)))

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
 '(package-selected-packages nil))
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
        ;; Battery in modeline. sysfs backend works on yoga's eMMC/SD
        ;; layout where /sys/class/power_supply/BAT0 is the canonical
        ;; source.
        (setq battery-status-function #'battery-linux-sysfs)
        (display-battery-mode 1)
        (require 'exwm)
        (require 'exwm-systemtray)
        (exwm-systemtray-mode 1)
        (exwm-wm-mode 1)
        (require 'exwm-firefox-core nil 'noerror)
        (setq exwm-systemtray-height 100)
        ;; Global keys. The variable expects an alist; previously two
        ;; separate setq calls overwrote each other and only the last
        ;; binding took effect.
        (setq exwm-input-global-keys
              `((,(kbd "s-&") .
                 (lambda (command)
                   (interactive (list (read-shell-command "$ ")))
                   (start-process-shell-command command nil command)))
                (,(kbd "s-f") .
                 (lambda ()
                   (interactive)
                   (start-process-shell-command "firefox" nil "firefox")))
                (,(kbd "s-l") .
                 (lambda ()
                   (interactive)
                   (start-process-shell-command "slock" nil "slock")))))
        (when (fboundp 'auto-sudoedit-mode) (auto-sudoedit-mode 1)))
    (error (message "EXWM setup failed: %s" err))))

;; =====
;; Wifi picker (wpa_supplicant backend). M-x wifi.
;; Declarative networks come from profiles/wifi-yoga.nix.
;; Ad-hoc networks are added via wpa_cli + save_config and persist
;; to the imperative wpa_supplicant config (gated by
;; networking.wireless.allowAuxiliaryImperativeNetworks = true in
;; profiles/wifi-yoga.nix; the spencer user must be in the
;; wpa_supplicant group, set in users.nix).
;; =====
(defvar wifi-iface "wlp2s0")

(defun wifi--wpa (&rest args)
  (with-output-to-string
    (with-current-buffer standard-output
      (apply #'call-process "wpa_cli" nil t nil "-i" wifi-iface args))))

(defun wifi--known-networks ()
  "List configured networks as ((id . ssid) ...)."
  (let ((out (wifi--wpa "list_networks"))
        result)
    (dolist (line (cdr (split-string out "\n" t)))
      (when (string-match "^\\([0-9]+\\)\t\\([^\t]*\\)" line)
        (push (cons (match-string 1 line) (match-string 2 line)) result)))
    (nreverse result)))

(defun wifi--scan-results ()
  "Return list of visible SSIDs (deduped, non-empty)."
  (wifi--wpa "scan")
  (sleep-for 2)
  (let ((out (wifi--wpa "scan_results"))
        ssids)
    (dolist (line (cdr (split-string out "\n" t)))
      ;; bssid / freq / sigl / flags / ssid (tab-separated)
      (let ((cols (split-string line "\t")))
        (when (>= (length cols) 5)
          (let ((ssid (nth 4 cols)))
            (unless (or (string-empty-p ssid) (member ssid ssids))
              (push ssid ssids))))))
    (nreverse ssids)))

(defun wifi--add-network (ssid psk)
  "Add SSID with PSK to wpa_supplicant and persist via save_config.
Returns the new network id as string, or signals on failure."
  (let* ((id (string-trim (wifi--wpa "add_network"))))
    (unless (string-match-p "^[0-9]+$" id)
      (user-error "add_network failed: %s" id))
    ;; wpa_cli quoting: ssid/psk values must be wrapped in literal
    ;; double-quotes inside the argument.
    (wifi--wpa "set_network" id "ssid" (format "\"%s\"" ssid))
    (if (string-empty-p psk)
        (wifi--wpa "set_network" id "key_mgmt" "NONE")
      (wifi--wpa "set_network" id "psk" (format "\"%s\"" psk)))
    (wifi--wpa "enable_network" id)
    (let ((saved (string-trim (wifi--wpa "save_config"))))
      (unless (string-match-p "OK" saved)
        (message "wifi: save_config returned %s (network is active but not persisted)" saved)))
    id))

(defun wifi ()
  "Pick a wifi network. Known networks select immediately;
unknown visible networks prompt for PSK, add, and persist."
  (interactive)
  (let* ((known (wifi--known-networks))
         (known-ssids (mapcar #'cdr known))
         (visible (wifi--scan-results))
         (all (delete-dups (append known-ssids visible)))
         (_ (unless all (user-error "No networks found")))
         (ssid (completing-read "Network: " all nil nil))
         (entry (rassoc ssid known)))
    (cond
     (entry
      (wifi--wpa "select_network" (car entry))
      (message "wifi: selected known network %s (id %s)" ssid (car entry)))
     (t
      (let* ((psk (read-passwd (format "Password for %s (empty for open): " ssid)))
             (id (wifi--add-network ssid psk)))
        (wifi--wpa "select_network" id)
        (message "wifi: added and selected %s (id %s)" ssid id))))))
