;;; soft-paper-theme.el --- Easy-on-the-eyes warm light theme -*- lexical-binding: t; -*-

;; Author: Spencer
;; Version: 0.1.0
;; Keywords: faces, theme, light

;;; Commentary:
;; Warm paper background (#EFE9E3), cool blue active modeline (#E4EAF0),
;; soft pink comment highlight (#F0E4E4). Low-contrast, muted accents
;; tuned for long reading sessions.

;;; Code:

(deftheme soft-paper
  "Warm low-contrast light theme designed for eye comfort.")

(let ((bg              "#EFE9E3")
      (bg-alt          "#E8E2DC")
      (bg-dim          "#DCD5CC")
      (bg-hl           "#E8E2DC")
      (bg-region       "#D8D0C5")
      (bg-modeline     "#E4EAF0")
      (bg-modeline-i   "#E8E4DE")
      (bg-pink         "#F0E4E4")
      (bg-fringe       "#EFE9E3")
      (fg              "#3A3635")
      (fg-dim          "#6B6660")
      (fg-faint        "#9A9289")
      (fg-modeline     "#2F3A4A")
      (fg-modeline-i   "#8A857F")
      (fg-comment      "#9A4A4A")
      (fg-linum        "#B0A89E")
      (fg-linum-cur    "#5A5450")
      (cursor          "#4A4540")
      (keyword         "#6A4A8A")
      (string          "#5A7A4A")
      (function        "#3A5A8A")
      (type            "#8A5A3A")
      (constant        "#8A4A5A")
      (builtin         "#5A6A8A")
      (variable        "#3A3635")
      (preproc         "#7A5A3A")
      (doc             "#7A6A5A")
      (warning         "#B85C00")
      (error-c         "#B83232")
      (success         "#4A7A3A")
      (link            "#3A5A8A")
      (match           "#D6CFA8"))

  (custom-theme-set-faces
   'soft-paper

   ;; Base
   `(default                       ((t (:background ,bg :foreground ,fg))))
   `(cursor                        ((t (:background ,cursor))))
   `(fringe                        ((t (:background ,bg-fringe :foreground ,fg-faint))))
   `(vertical-border               ((t (:foreground ,bg-dim))))
   `(window-divider                ((t (:foreground ,bg-dim))))
   `(window-divider-first-pixel    ((t (:foreground ,bg-dim))))
   `(window-divider-last-pixel     ((t (:foreground ,bg-dim))))
   `(highlight                     ((t (:background ,bg-hl))))
   `(hl-line                       ((t (:background ,bg-alt))))
   `(region                        ((t (:background ,bg-region :extend t))))
   `(secondary-selection           ((t (:background ,match))))
   `(trailing-whitespace           ((t (:background ,bg-pink))))
   `(minibuffer-prompt             ((t (:foreground ,function :weight bold))))
   `(escape-glyph                  ((t (:foreground ,warning))))
   `(error                         ((t (:foreground ,error-c :weight bold))))
   `(warning                       ((t (:foreground ,warning))))
   `(success                       ((t (:foreground ,success))))
   `(shadow                        ((t (:foreground ,fg-faint))))
   `(link                          ((t (:foreground ,link :underline t))))
   `(link-visited                  ((t (:foreground ,keyword :underline t))))
   `(match                         ((t (:background ,match))))
   `(isearch                       ((t (:background ,match :foreground ,fg))))
   `(isearch-fail                  ((t (:background ,bg-pink :foreground ,error-c))))
   `(lazy-highlight                ((t (:background ,bg-modeline))))
   `(show-paren-match              ((t (:background ,match :weight bold))))
   `(show-paren-mismatch           ((t (:background ,error-c :foreground ,bg))))

   ;; Modeline
   `(mode-line                     ((t (:background ,bg-modeline :foreground ,fg-modeline
                                        :box (:line-width 1 :color ,bg-dim)))))
   `(mode-line-inactive            ((t (:background ,bg-modeline-i :foreground ,fg-modeline-i
                                        :box (:line-width 1 :color ,bg-dim)))))
   `(mode-line-highlight           ((t (:background ,bg-hl))))
   `(mode-line-buffer-id           ((t (:foreground ,fg-modeline :weight bold))))
   `(header-line                   ((t (:background ,bg-alt :foreground ,fg-dim))))

   ;; Line numbers
   `(line-number                   ((t (:background ,bg :foreground ,fg-linum))))
   `(line-number-current-line      ((t (:background ,bg-alt :foreground ,fg-linum-cur :weight bold))))
   `(fill-column-indicator         ((t (:foreground ,bg-dim))))

   ;; Font-lock
   `(font-lock-comment-face            ((t (:foreground ,fg-comment :slant italic))))
   `(font-lock-comment-delimiter-face  ((t (:foreground ,fg-comment))))
   `(font-lock-doc-face                ((t (:foreground ,fg-comment :slant italic))))
   `(font-lock-string-face             ((t (:foreground ,string))))
   `(font-lock-keyword-face            ((t (:foreground ,keyword))))
   `(font-lock-builtin-face            ((t (:foreground ,builtin))))
   `(font-lock-function-name-face      ((t (:foreground ,function :weight semi-bold))))
   `(font-lock-variable-name-face      ((t (:foreground ,variable))))
   `(font-lock-type-face               ((t (:foreground ,type))))
   `(font-lock-constant-face           ((t (:foreground ,constant))))
   `(font-lock-preprocessor-face       ((t (:foreground ,preproc))))
   `(font-lock-warning-face            ((t (:foreground ,warning :weight bold))))
   `(font-lock-negation-char-face      ((t (:foreground ,error-c))))
   `(font-lock-regexp-grouping-backslash ((t (:foreground ,preproc))))
   `(font-lock-regexp-grouping-construct ((t (:foreground ,keyword))))

   ;; Tree-sitter common
   `(font-lock-property-face       ((t (:foreground ,variable))))
   `(font-lock-property-use-face   ((t (:foreground ,variable))))
   `(font-lock-operator-face       ((t (:foreground ,fg-dim))))
   `(font-lock-bracket-face        ((t (:foreground ,fg-dim))))
   `(font-lock-delimiter-face      ((t (:foreground ,fg-dim))))
   `(font-lock-number-face         ((t (:foreground ,constant))))
   `(font-lock-punctuation-face    ((t (:foreground ,fg-dim))))
   `(font-lock-escape-face         ((t (:foreground ,preproc))))
   `(font-lock-misc-punctuation-face ((t (:foreground ,fg-dim))))
   `(font-lock-function-call-face  ((t (:foreground ,function))))
   `(font-lock-variable-use-face   ((t (:foreground ,variable))))

   ;; ANSI / term
   `(ansi-color-black              ((t (:foreground "#3A3635" :background "#3A3635"))))
   `(ansi-color-red                ((t (:foreground ,error-c :background ,error-c))))
   `(ansi-color-green              ((t (:foreground ,success :background ,success))))
   `(ansi-color-yellow             ((t (:foreground ,warning :background ,warning))))
   `(ansi-color-blue               ((t (:foreground ,function :background ,function))))
   `(ansi-color-magenta            ((t (:foreground ,keyword :background ,keyword))))
   `(ansi-color-cyan               ((t (:foreground ,builtin :background ,builtin))))
   `(ansi-color-white              ((t (:foreground ,fg :background ,fg))))

   ;; Org
   `(org-level-1                   ((t (:foreground ,function :weight bold :height 1.15))))
   `(org-level-2                   ((t (:foreground ,keyword :weight bold :height 1.1))))
   `(org-level-3                   ((t (:foreground ,type    :weight bold :height 1.05))))
   `(org-level-4                   ((t (:foreground ,constant :weight bold))))
   `(org-level-5                   ((t (:foreground ,builtin :weight bold))))
   `(org-level-6                   ((t (:foreground ,success :weight bold))))
   `(org-level-7                   ((t (:foreground ,preproc :weight bold))))
   `(org-level-8                   ((t (:foreground ,fg-dim  :weight bold))))
   `(org-document-title            ((t (:foreground ,fg :weight bold :height 1.3))))
   `(org-document-info             ((t (:foreground ,fg-dim))))
   `(org-block                     ((t (:background ,bg-alt :extend t))))
   `(org-block-begin-line          ((t (:background ,bg-alt :foreground ,fg-faint :extend t))))
   `(org-block-end-line            ((t (:background ,bg-alt :foreground ,fg-faint :extend t))))
   `(org-code                      ((t (:background ,bg-alt :foreground ,type))))
   `(org-verbatim                  ((t (:background ,bg-alt :foreground ,string))))
   `(org-todo                      ((t (:foreground ,error-c :weight bold))))
   `(org-done                      ((t (:foreground ,success :weight bold))))
   `(org-link                      ((t (:foreground ,link :underline t))))
   `(org-table                     ((t (:foreground ,fg :background ,bg-alt))))
   `(org-meta-line                 ((t (:foreground ,fg-faint))))
   `(org-special-keyword           ((t (:foreground ,preproc))))
   `(org-drawer                    ((t (:foreground ,fg-faint))))
   `(org-date                      ((t (:foreground ,builtin :underline t))))
   `(org-checkbox                  ((t (:foreground ,function :weight bold))))
   `(org-headline-done             ((t (:foreground ,fg-faint :strike-through t))))

   ;; Markdown
   `(markdown-header-face-1        ((t (:foreground ,function :weight bold :height 1.15))))
   `(markdown-header-face-2        ((t (:foreground ,keyword :weight bold :height 1.1))))
   `(markdown-header-face-3        ((t (:foreground ,type    :weight bold :height 1.05))))
   `(markdown-header-face-4        ((t (:foreground ,constant :weight bold))))
   `(markdown-code-face            ((t (:background ,bg-alt :foreground ,type))))
   `(markdown-inline-code-face     ((t (:background ,bg-alt :foreground ,type))))
   `(markdown-pre-face             ((t (:background ,bg-alt :foreground ,fg))))
   `(markdown-link-face            ((t (:foreground ,link :underline t))))
   `(markdown-url-face             ((t (:foreground ,builtin))))
   `(markdown-blockquote-face      ((t (:foreground ,fg-dim :slant italic))))

   ;; Diff / magit
   `(diff-added                    ((t (:background "#E0EBD8" :foreground ,fg))))
   `(diff-removed                  ((t (:background ,bg-pink :foreground ,fg))))
   `(diff-changed                  ((t (:background "#EFE6CC" :foreground ,fg))))
   `(diff-context                  ((t (:foreground ,fg-dim))))
   `(diff-file-header              ((t (:background ,bg-alt :weight bold))))
   `(diff-header                   ((t (:background ,bg-alt :foreground ,fg-dim))))
   `(diff-hunk-header              ((t (:background ,bg-modeline :foreground ,fg-modeline))))
   `(diff-refine-added             ((t (:background "#C8DDB8"))))
   `(diff-refine-removed           ((t (:background "#E5C0C0"))))
   `(magit-section-heading         ((t (:foreground ,keyword :weight bold))))
   `(magit-section-highlight       ((t (:background ,bg-alt))))
   `(magit-diff-added              ((t (:background "#E0EBD8" :foreground ,fg))))
   `(magit-diff-added-highlight    ((t (:background "#D5E3CB" :foreground ,fg))))
   `(magit-diff-removed            ((t (:background ,bg-pink :foreground ,fg))))
   `(magit-diff-removed-highlight  ((t (:background "#E5CACA" :foreground ,fg))))
   `(magit-diff-context            ((t (:foreground ,fg-dim))))
   `(magit-diff-context-highlight  ((t (:background ,bg-alt :foreground ,fg-dim))))
   `(magit-diff-hunk-heading       ((t (:background ,bg-modeline-i :foreground ,fg-dim))))
   `(magit-diff-hunk-heading-highlight ((t (:background ,bg-modeline :foreground ,fg-modeline))))
   `(magit-branch-local            ((t (:foreground ,function))))
   `(magit-branch-remote           ((t (:foreground ,success))))
   `(magit-hash                    ((t (:foreground ,fg-faint))))

   ;; Completion (company / corfu / vertico / consult / orderless)
   `(company-tooltip               ((t (:background ,bg-alt :foreground ,fg))))
   `(company-tooltip-selection     ((t (:background ,bg-region))))
   `(company-tooltip-common        ((t (:foreground ,function :weight bold))))
   `(company-tooltip-annotation    ((t (:foreground ,fg-dim))))
   `(company-scrollbar-bg          ((t (:background ,bg-alt))))
   `(company-scrollbar-fg          ((t (:background ,bg-dim))))
   `(corfu-default                 ((t (:background ,bg-alt :foreground ,fg))))
   `(corfu-current                 ((t (:background ,bg-region))))
   `(corfu-bar                     ((t (:background ,bg-dim))))
   `(corfu-border                  ((t (:background ,bg-dim))))
   `(vertico-current               ((t (:background ,bg-region :extend t))))
   `(marginalia-documentation      ((t (:foreground ,fg-dim :slant italic))))
   `(orderless-match-face-0        ((t (:foreground ,function :weight bold))))
   `(orderless-match-face-1        ((t (:foreground ,keyword :weight bold))))
   `(orderless-match-face-2        ((t (:foreground ,type :weight bold))))
   `(orderless-match-face-3        ((t (:foreground ,constant :weight bold))))
   `(consult-file                  ((t (:foreground ,fg))))
   `(consult-line-number           ((t (:foreground ,fg-linum))))

   ;; Ivy / helm
   `(ivy-current-match             ((t (:background ,bg-region :foreground ,fg))))
   `(ivy-minibuffer-match-face-1   ((t (:foreground ,fg-dim))))
   `(ivy-minibuffer-match-face-2   ((t (:foreground ,function :weight bold))))
   `(ivy-minibuffer-match-face-3   ((t (:foreground ,keyword :weight bold))))
   `(ivy-minibuffer-match-face-4   ((t (:foreground ,type :weight bold))))
   `(helm-selection                ((t (:background ,bg-region))))
   `(helm-source-header            ((t (:background ,bg-modeline :foreground ,fg-modeline :weight bold))))
   `(helm-match                    ((t (:foreground ,function :weight bold))))

   ;; Flycheck / flymake
   `(flycheck-error                ((t (:underline (:style wave :color ,error-c)))))
   `(flycheck-warning              ((t (:underline (:style wave :color ,warning)))))
   `(flycheck-info                 ((t (:underline (:style wave :color ,function)))))
   `(flymake-error                 ((t (:underline (:style wave :color ,error-c)))))
   `(flymake-warning               ((t (:underline (:style wave :color ,warning)))))
   `(flymake-note                  ((t (:underline (:style wave :color ,function)))))

   ;; Dired
   `(dired-directory               ((t (:foreground ,function :weight bold))))
   `(dired-symlink                 ((t (:foreground ,builtin :slant italic))))
   `(dired-ignored                 ((t (:foreground ,fg-faint))))
   `(dired-flagged                 ((t (:foreground ,error-c))))
   `(dired-marked                  ((t (:foreground ,warning :weight bold))))
   `(dired-header                  ((t (:foreground ,keyword :weight bold))))

   ;; Eshell / term
   `(eshell-prompt                 ((t (:foreground ,function :weight bold))))
   `(eshell-ls-directory           ((t (:foreground ,function :weight bold))))
   `(eshell-ls-executable          ((t (:foreground ,success))))
   `(eshell-ls-symlink             ((t (:foreground ,builtin :slant italic))))
   `(eshell-ls-archive             ((t (:foreground ,constant))))
   `(eshell-ls-backup              ((t (:foreground ,fg-faint))))
   `(eshell-ls-missing             ((t (:foreground ,error-c))))
   `(term-color-black              ((t (:foreground "#3A3635"))))
   `(term-color-red                ((t (:foreground ,error-c))))
   `(term-color-green              ((t (:foreground ,success))))
   `(term-color-yellow             ((t (:foreground ,warning))))
   `(term-color-blue               ((t (:foreground ,function))))
   `(term-color-magenta            ((t (:foreground ,keyword))))
   `(term-color-cyan               ((t (:foreground ,builtin))))
   `(term-color-white              ((t (:foreground ,fg))))

   ;; which-key
   `(which-key-key-face            ((t (:foreground ,function :weight bold))))
   `(which-key-group-description-face ((t (:foreground ,keyword))))
   `(which-key-command-description-face ((t (:foreground ,fg))))
   `(which-key-separator-face      ((t (:foreground ,fg-faint))))

   ;; tab-bar / tab-line
   `(tab-bar                       ((t (:background ,bg-alt :foreground ,fg-dim))))
   `(tab-bar-tab                   ((t (:background ,bg :foreground ,fg :weight bold
                                        :box (:line-width 1 :color ,bg-dim)))))
   `(tab-bar-tab-inactive          ((t (:background ,bg-alt :foreground ,fg-dim
                                        :box (:line-width 1 :color ,bg-dim)))))

   ;; misc
   `(widget-field                  ((t (:background ,bg-alt :foreground ,fg))))
   `(button                        ((t (:foreground ,link :underline t))))
   `(custom-button                 ((t (:background ,bg-alt :foreground ,fg
                                        :box (:line-width 1 :color ,bg-dim)))))
   `(custom-group-tag              ((t (:foreground ,keyword :weight bold :height 1.1))))
   `(custom-variable-tag           ((t (:foreground ,function :weight bold))))
   `(custom-state                  ((t (:foreground ,success))))

   `(tooltip                       ((t (:background ,bg-alt :foreground ,fg))))))

;;;###autoload
(when (and (boundp 'custom-theme-load-path) load-file-name)
  (add-to-list 'custom-theme-load-path
               (file-name-as-directory (file-name-directory load-file-name))))

(provide-theme 'soft-paper)

;;; soft-paper-theme.el ends here
