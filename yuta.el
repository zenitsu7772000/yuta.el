;;; yuta.el --- Yuta fuzzy finder + IDE command system -*- lexical-binding: t -*-

;; Author: Zenitsu
;; Version: 1.0.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: files, search, navigation, fuzzy
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Yuta: native fuzzy UX + fzf-level speed + Emacs extensibility.
;;
;; Architecture:
;;   - FZF MODE  : for large datasets (files, grep, git) — Emacs gets final result only
;;   - EMACS MODE: for buffers, LSP, small lists — full Yuta UI with preview
;;
;; External tools: fzf, rg (ripgrep), fd, git, bat (optional)
;; No Vertico, Ivy, Helm, Consult, or Orderless.
;;
;; Key bindings (inside Yuta UI):
;;   RET   → open file / execute
;;   C-v   → open in vertical split
;;   C-x   → open in horizontal split
;;   C-c   → copy path
;;   C-n   → next candidate
;;   C-p   → previous candidate
;;   C-g   → quit

;;; Code:

;;;; ─── Dependencies ────────────────────────────────────────────────────────────

(require 'cl-lib)
(require 'subr-x)
(require 'project)
(require 'face-remap)
(require 'ansi-color)

;;;; ─── Customization ───────────────────────────────────────────────────────────

(defgroup yuta nil
  "Yuta fuzzy finder and command system."
  :group 'tools
  :prefix "yuta-")

(defcustom yuta-fzf-executable "fzf"
  "Path to the fzf executable."
  :type 'string
  :group 'yuta)

(defcustom yuta-rg-executable "rg"
  "Path to the ripgrep executable."
  :type 'string
  :group 'yuta)

(defcustom yuta-fd-executable "fd"
  "Path to the fd executable."
  :type 'string
  :group 'yuta)

(defcustom yuta-bat-executable "bat"
  "Path to the bat executable for syntax-highlighted previews."
  :type 'string
  :group 'yuta)

(defcustom yuta-preview-width 0.45
  "Fraction of the frame width used for the preview pane (0.0–1.0)."
  :type 'float
  :group 'yuta)

(defcustom yuta-popup-width 0.90
  "Fraction of the frame width used for the Yuta popup."
  :type 'float
  :group 'yuta)

(defcustom yuta-popup-height 0.72
  "Fraction of the frame height used for the Yuta popup."
  :type 'float
  :group 'yuta)

(defcustom yuta-use-child-frame t
  "If non-nil, render Yuta in a child frame popup.
Keep this nil for maximum stability with Evil/window-manager setups."
  :type 'boolean
  :group 'yuta)

(defcustom yuta-global-prefix-key (kbd "C-c y")
  "Global prefix key used for Yuta command bindings."
  :type 'key-sequence
  :group 'yuta)

(defcustom yuta-lsp-auto-complete-delay 0.15
  "Idle seconds before Yuta triggers native LSP completion."
  :type 'float
  :group 'yuta)

(defcustom yuta-lsp-min-prefix-length 2
  "Minimum symbol length before auto completion triggers."
  :type 'integer
  :group 'yuta)

(defcustom yuta-lsp-min-request-interval 0.12
  "Minimum seconds between two auto-completion requests in a buffer."
  :type 'float
  :group 'yuta)

(defcustom yuta-lsp-max-buffer-size 400000
  "Disable Yuta auto LSP completion in buffers larger than this many chars."
  :type 'integer
  :group 'yuta)

(defcustom yuta-lsp-popup-max-candidates 8
  "Maximum number of candidates shown in the Yuta LSP popup."
  :type 'integer
  :group 'yuta)

(defcustom yuta-lsp-popup-min-width 34
  "Minimum character width for the Yuta LSP popup panel."
  :type 'integer
  :group 'yuta)

(defcustom yuta-lsp-autocomplete-default-enabled t
  "If non-nil, enable Yuta native LSP autocomplete automatically on load."
  :type 'boolean
  :group 'yuta)

(defcustom yuta-enable-icons nil
  "If non-nil, show icons in Yuta LSP entries."
  :type 'boolean
  :group 'yuta)

(defcustom yuta-icon-style 'none
  "Icon style for Yuta: one of `auto', `nerd', `ascii', or `none'."
  :type '(choice (const :tag "Auto" auto)
                 (const :tag "Nerd Font" nerd)
                 (const :tag "ASCII fallback" ascii)
                 (const :tag "None" none))
  :group 'yuta)

(defcustom yuta-debounce-delay 0.12
  "Seconds to wait after last keystroke before issuing a new search."
  :type 'float
  :group 'yuta)

(defcustom yuta-max-emacs-mode-candidates 500
  "Candidate count threshold: above this Yuta switches to FZF mode."
  :type 'integer
  :group 'yuta)

(defcustom yuta-preview-lines 60
  "Maximum lines to show in the preview buffer."
  :type 'integer
  :group 'yuta)

(defcustom yuta-live-grep-max-results 220
  "Maximum number of lines returned for each live-grep query."
  :type 'integer
  :group 'yuta)

(defcustom yuta-fzf-opts
  '("--ansi" "--layout=reverse" "--border=none" "--info=inline"
    "--pointer=▶" "--marker=✓" "--bind=ctrl-a:select-all")
  "Extra options passed to fzf."
  :type '(repeat string)
  :group 'yuta)

;;;; ─── Internal state ──────────────────────────────────────────────────────────

(defvar yuta--frame nil
  "The child frame used for the Yuta popup (nil = use window-split fallback).")
(defvar yuta--parent-frame nil
  "Parent frame used to launch Yuta child frame.")
(defvar yuta--parent-window nil
  "Selected window in parent frame before Yuta opens.")
(defvar yuta--saved-window-config nil
  "Window configuration captured before opening Yuta.")

(defvar yuta--input-buffer nil  "The minibuffer-like prompt buffer.")
(defvar yuta--list-buffer  nil  "The candidates list buffer.")
(defvar yuta--preview-buffer nil "The file-preview buffer.")

(defvar yuta--input-window   nil)
(defvar yuta--list-window    nil)
(defvar yuta--preview-window nil)

(defvar yuta--candidates     '()  "Current candidate list (strings).")
(defvar yuta--filtered        '()  "Filtered candidates after Emacs-mode scoring.")
(defvar yuta--selected-index  0    "Index of currently highlighted candidate.")

(defvar yuta--debounce-timer  nil  "Timer handle for debounced refresh.")
(defvar yuta--async-process   nil  "Handle for the running async search process.")
(defvar yuta--process-output  ""   "Accumulated stdout from the async process.")

(defvar yuta--current-action  nil  "Callback to invoke on selection (function of 1 arg).")
(defvar yuta--mode            nil  "Current mode: \\='fzf or \\='emacs.")
(defvar yuta--source-type     nil  "Symbol: files | grep | buffers | commands | git.")
(defvar yuta--project-root    nil  "Project root for the current session.")
(defvar yuta--dynamic-source-fn nil
  "Optional function that builds async command from current input.")
(defvar-local yuta--face-cookie nil
  "Face remap cookie used for Yuta glass-style popups.")
(defvar-local yuta--lsp-complete-timer nil
  "Idle timer used for native Yuta LSP completion.")
(defvar-local yuta--lsp-last-complete-time 0.0
  "Last timestamp (float seconds) when Yuta requested CAPF completion.")
(defvar-local yuta--lsp-popup-overlay nil
  "Overlay used to render Yuta LSP suggestions.")
(defvar-local yuta--lsp-popup-candidates nil
  "Current candidate strings shown in Yuta LSP popup.")
(defvar-local yuta--lsp-popup-index 0
  "Selected candidate index in Yuta LSP popup.")
(defvar-local yuta--lsp-popup-beg nil
  "Completion start position for the active Yuta LSP popup.")
(defvar-local yuta--lsp-popup-end nil
  "Completion end position for the active Yuta LSP popup.")

(defvar-local yuta--input-pane-p nil
  "Non-nil in the editable input pane; nil for read-only panes.")

(defvar yuta--child-focus-guard-enabled nil
  "Non-nil when Yuta child-frame focus guard is active.")

(defvar yuta--keymap
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-n")   #'yuta--next-candidate)
    (define-key m (kbd "C-p")   #'yuta--prev-candidate)
    (define-key m (kbd "<down>") #'yuta--next-candidate)
    (define-key m (kbd "<up>") #'yuta--prev-candidate)
    (define-key m (kbd "M-j") #'yuta--next-candidate)
    (define-key m (kbd "M-k") #'yuta--prev-candidate)
    (define-key m (kbd "RET")   #'yuta--confirm-selection)
    (define-key m (kbd "C-v")   #'yuta--open-vsplit)
    (define-key m (kbd "C-x")   #'yuta--open-hsplit)
    (define-key m (kbd "C-c")   #'yuta--copy-path)
    (define-key m (kbd "C-g")   #'yuta-abort)
    (define-key m (kbd "<escape>") #'yuta-quit)
    (define-key m (kbd "M-<up>") #'yuta-popup-grow-height)
    (define-key m (kbd "M-<down>") #'yuta-popup-shrink-height)
    (define-key m (kbd "M-<right>") #'yuta-popup-grow-width)
    (define-key m (kbd "M-<left>") #'yuta-popup-shrink-width)
    (define-key m (kbd "q") #'yuta-abort)
    m)
  "Keymap active inside the Yuta input buffer.")

(defvar yuta--child-mouse-ignore-map
  (let ((m (make-sparse-keymap)))
    (dolist (k '(mouse-1 down-mouse-1 drag-mouse-1 double-mouse-1 triple-mouse-1
                 mouse-2 down-mouse-2 drag-mouse-2 double-mouse-2 triple-mouse-2
                 mouse-3 down-mouse-3 drag-mouse-3 double-mouse-3 triple-mouse-3
                 wheel-up wheel-down))
      (define-key m (vector k) #'ignore))
    m)
  "Mouse-ignore map used in child-frame display-only buffers.")

(defun yuta--child-focus-guard ()
  "Keep keyboard focus on Yuta parent frame when child-frame mode is active."
  (when (and yuta--child-focus-guard-enabled
             yuta--frame
             (frame-live-p yuta--frame)
             yuta--parent-frame
             (frame-live-p yuta--parent-frame)
             (eq (selected-frame) yuta--frame))
    (redirect-frame-focus yuta--frame yuta--parent-frame)
    (select-frame-set-input-focus yuta--parent-frame)
    (when (and yuta--input-window (window-live-p yuta--input-window))
      (select-window yuta--input-window))))

(defun yuta--enable-evil-nav-bindings ()
  "Force Yuta navigation bindings in Evil state maps for current buffer."
  (when (featurep 'evil)
    (dolist (state '(normal insert visual motion))
      (evil-local-set-key state (kbd "C-n") #'yuta--next-candidate)
      (evil-local-set-key state (kbd "C-p") #'yuta--prev-candidate)
      (evil-local-set-key state (kbd "<down>") #'yuta--next-candidate)
      (evil-local-set-key state (kbd "<up>") #'yuta--prev-candidate)
      (evil-local-set-key state (kbd "j") #'yuta--next-candidate)
      (evil-local-set-key state (kbd "k") #'yuta--prev-candidate)
      (evil-local-set-key state (kbd "C-j") #'yuta--next-candidate)
      (evil-local-set-key state (kbd "C-k") #'yuta--prev-candidate)
      (evil-local-set-key state (kbd "RET") #'yuta--confirm-selection)
      (evil-local-set-key state (kbd "q") #'yuta-abort)
      (evil-local-set-key state (kbd "<escape>") #'yuta-abort))))

;;;; ─── Utility helpers ─────────────────────────────────────────────────────────

(defun yuta--executable-p (name)
  "Return non-nil if NAME is found on PATH."
  (executable-find name))

(defun yuta--project-root ()
  "Return the project root for the *current* `default-directory'."
  (or (when-let ((proj (project-current nil)))
        (project-root proj))
      (locate-dominating-file default-directory ".git")
      default-directory))

(defun yuta--bat-cmd (file &optional line)
  "Return a shell command string to preview FILE with bat or cat.
If LINE is given, centre the preview around that line number."
  (if (yuta--executable-p yuta-bat-executable)
      (concat yuta-bat-executable
              " --color=never --style=numbers,header --line-range "
              (if line
                  (format "%d:%d" (max 1 (- line 10))
                          (+ line yuta-preview-lines))
                (format "1:%d" yuta-preview-lines))
              (when line (format " --highlight-line %d" line))
              " -- " (shell-quote-argument file))
    (if line
        (format "sed -n '%d,%dp' %s"
                (max 1 (- line 5))
                (+ line yuta-preview-lines)
                (shell-quote-argument file))
      (format "head -n %d %s"
              yuta-preview-lines
              (shell-quote-argument file)))))

(defun yuta--kill-async ()
  "Kill the running async search process if any."
  (when (and yuta--async-process
             (process-live-p yuta--async-process))
    (delete-process yuta--async-process))
  (setq yuta--async-process nil
        yuta--process-output ""))

(defun yuta--cancel-debounce ()
  "Cancel any pending debounce timer."
  (when yuta--debounce-timer
    (cancel-timer yuta--debounce-timer)
    (setq yuta--debounce-timer nil)))

;;;; ─── UI Layout ───────────────────────────────────────────────────────────────

(defun yuta--make-buffer (name)
  "Return a fresh buffer called NAME."
  (let ((buf (get-buffer-create name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)))
    buf))

(defun yuta--setup-ui ()
  "Create the Yuta split-window UI layout.
Tries a child frame first; falls back to a window layout."
  (setq yuta--parent-frame (selected-frame)
        yuta--parent-window (selected-window)
        yuta--saved-window-config (current-window-configuration))
  ;; Child frames are unstable on some WM/Evil setups; default to window mode.
  (if (and yuta-use-child-frame
           (fboundp 'make-frame)
           (display-graphic-p)
           (>= emacs-major-version 27))
      (condition-case nil
          (yuta--setup-frame-ui)
        (error (yuta--setup-window-ui)))
    (yuta--setup-window-ui)))

(defun yuta--frame-geometry ()
  "Return (LEFT TOP WIDTH HEIGHT) for the centred popup frame in pixels."
  (let* ((fw  (frame-pixel-width))
         (fh  (frame-pixel-height))
         (pw  (round (* fw yuta-popup-width)))
         (ph  (round (* fh yuta-popup-height)))
         (px  (/ (- fw pw) 2))
         (py  (/ (- fh ph) 2)))
    (list px py pw ph)))

(defun yuta--setup-frame-ui ()
  "Build a safe child-frame layout (display-only child frame + parent input)."
  (cl-destructuring-bind (px py pw ph) (yuta--frame-geometry)
    (setq yuta--parent-frame (selected-frame))
    (let* ((char-w  (frame-char-width))
           (char-h  (frame-char-height))
           (cols    (/ pw char-w))
           (rows    (/ ph char-h))
           (preview-cols (round (* cols yuta-preview-width)))
           (list-cols   (- cols preview-cols 1)))

      (setq yuta--input-buffer   (yuta--make-buffer " *yuta-input*")
            yuta--list-buffer    (yuta--make-buffer " *yuta-list*")
            yuta--preview-buffer (yuta--make-buffer " *yuta-preview*"))

      (when (and yuta--frame (frame-live-p yuta--frame))
        (delete-frame yuta--frame))

      (setq yuta--frame
            (make-frame
             `((parent-frame     . ,yuta--parent-frame)
               (left             . ,px)
               (top              . ,py)
               (width            . ,cols)
               (height           . ,rows)
               (min-width        . 20)
               (min-height       . 5)
               (internal-border-width . 2)
               (child-frame-border-width . 1)
               (undecorated      . t)
               (no-accept-focus  . t)
               (no-focus-on-map  . t)
               (unsplittable     . t)
               (no-other-frame   . t)
               (cursor-type      . nil)
               (drag-with-mode-line . t)
               (drag-internal-border . t)
               (left-fringe      . 0)
               (right-fringe     . 0)
               (vertical-scroll-bars . nil)
               (horizontal-scroll-bars . nil)
               (menu-bar-lines   . 0)
               (tool-bar-lines   . 0)
               (tab-bar-lines    . 0)
               (background-color . ,(face-attribute 'default :background))
               (foreground-color . ,(face-attribute 'default :foreground)))))

      ;; Parent frame keeps the editable input pane.
      (with-selected-frame yuta--parent-frame
        (let ((input-win (split-window (selected-window) -3 'below)))
          (set-window-buffer input-win yuta--input-buffer)
          (setq yuta--input-window input-win)
          (set-window-fringes input-win 4 4)
          (set-window-parameter input-win 'mode-line-format 'none)))

      ;; Child frame is display-only: list + preview panes.
      (with-selected-frame yuta--frame
        (let* ((list-win (selected-window))
               (preview-win (split-window list-win list-cols 'right)))
          (set-window-buffer list-win yuta--list-buffer)
          (set-window-buffer preview-win yuta--preview-buffer)
          (setq yuta--list-window list-win
                yuta--preview-window preview-win)
          (dolist (w (list list-win preview-win))
            (set-window-fringes w 4 4)
            (set-window-parameter w 'mode-line-format 'none)
            (set-window-parameter w 'no-other-window t)
            (set-window-dedicated-p w t))))

      (with-current-buffer yuta--list-buffer
        (use-local-map yuta--child-mouse-ignore-map))
      (with-current-buffer yuta--preview-buffer
        (use-local-map yuta--child-mouse-ignore-map))

      ;; Guard focus like mature child-frame packages on Wayland.
      (redirect-frame-focus yuta--frame yuta--parent-frame)
      (add-hook 'pre-command-hook #'yuta--child-focus-guard)
      (setq yuta--child-focus-guard-enabled t)
      (select-frame-set-input-focus yuta--parent-frame)
      (select-window yuta--input-window)
      (yuta--init-input-buffer))))

(defun yuta--clamp (n minv maxv)
  "Clamp N to [MINV, MAXV]."
  (max minv (min maxv n)))

(defun yuta--refresh-popup-geometry ()
  "Rebuild Yuta UI with updated geometry customizations."
  (interactive)
  (when (and yuta--input-buffer (buffer-live-p yuta--input-buffer))
    (let ((input (yuta--current-input))
          (selected (yuta--selected-candidate)))
      (yuta--setup-ui)
      (when input
        (with-current-buffer yuta--input-buffer
          (insert input)
          (goto-char (point-max))))
      (setq yuta--filtered (yuta--emacs-filter (or input "") yuta--candidates))
      (setq yuta--selected-index
            (if (and selected yuta--filtered)
                (or (cl-position selected yuta--filtered :test #'equal) 0)
              0))
      (yuta--render-candidates)
      (yuta--update-preview (yuta--selected-candidate)))))

(defun yuta-popup-grow-height ()
  "Increase popup height."
  (interactive)
  (setq yuta-popup-height (yuta--clamp (+ yuta-popup-height 0.03) 0.30 0.95))
  (yuta--refresh-popup-geometry))

(defun yuta-popup-shrink-height ()
  "Decrease popup height."
  (interactive)
  (setq yuta-popup-height (yuta--clamp (- yuta-popup-height 0.03) 0.30 0.95))
  (yuta--refresh-popup-geometry))

(defun yuta-popup-grow-width ()
  "Increase popup width."
  (interactive)
  (setq yuta-popup-width (yuta--clamp (+ yuta-popup-width 0.03) 0.40 0.98))
  (yuta--refresh-popup-geometry))

(defun yuta-popup-shrink-width ()
  "Decrease popup width."
  (interactive)
  (setq yuta-popup-width (yuta--clamp (- yuta-popup-width 0.03) 0.40 0.98))
  (yuta--refresh-popup-geometry))

(defun yuta--setup-window-ui ()
  "Build a centered Yuta glass-card layout using standard windows."
  (delete-other-windows)

  (setq yuta--input-buffer   (yuta--make-buffer " *yuta-input*")
        yuta--list-buffer    (yuta--make-buffer " *yuta-list*")
        yuta--preview-buffer (yuta--make-buffer " *yuta-preview*"))

  (let* ((total-h (window-total-height))
         (popup-h (round (* total-h yuta-popup-height)))
         (total-w (window-total-width))
         (popup-w (max 80 (round (* total-w yuta-popup-width))))
         (side-w  (max 2 (/ (- total-w popup-w) 2)))
         (prev-w  (round (* total-w yuta-preview-width))))
    ;; Vertical placement (card in lower/middle area).
    (let ((popup-row (split-window (selected-window)
                                   (- total-h popup-h)
                                   'below)))
      (select-window popup-row)
      ;; Horizontal centering: left spacer | popup card | right spacer.
      (let* ((right-spacer (split-window popup-row (- side-w) 'right))
             (left-plus-center popup-row)
             (center-win (split-window left-plus-center side-w 'right))
             (left-spacer left-plus-center))
        ;; Keep only the center area active for Yuta.
        (dolist (sp (list left-spacer right-spacer))
          (set-window-parameter sp 'mode-line-format 'none)
          (set-window-parameter sp 'no-other-window t)
          (set-window-dedicated-p sp t))
        (select-window center-win)
        ;; Input at top of the center card.
        (let ((input-win center-win))
          (set-window-buffer input-win yuta--input-buffer)
          (setq yuta--input-window input-win)
          ;; List + preview below input.
          (let ((lower-win (split-window input-win 3 'below)))
            (let ((preview-win (split-window lower-win
                                             (- (window-total-width lower-win)
                                                prev-w)
                                             'right)))
              (set-window-buffer lower-win   yuta--list-buffer)
              (set-window-buffer preview-win yuta--preview-buffer)
              (setq yuta--list-window    lower-win
                    yuta--preview-window preview-win)))
          (select-window yuta--input-window)
          (yuta--init-input-buffer))))))

(defun yuta--init-input-buffer ()
  "Prepare the input buffer and activate the Yuta minor mode."
  (with-current-buffer yuta--input-buffer
    (kill-all-local-variables)
    (setq-local yuta--input-pane-p t)
    (setq-local header-line-format
                (propertize "  YUTA  " 'face '(:weight bold :height 1.1)))
    (use-local-map yuta--keymap)
    (setq buffer-read-only nil)
    (add-hook 'after-change-functions #'yuta--on-input-change nil t)
    (yuta--enable-evil-nav-bindings)
    (when (fboundp 'evil-insert-state)
      (evil-insert-state))
    (insert "")
    (goto-char (point-max)))
  (dolist (buf (list yuta--list-buffer yuta--preview-buffer))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq-local yuta--input-pane-p nil)
        (if (and yuta--frame (frame-live-p yuta--frame))
            (use-local-map yuta--child-mouse-ignore-map)
          (use-local-map yuta--keymap))
        (setq buffer-read-only t)
        (setq-local cursor-type nil)
        (unless (and yuta--frame (frame-live-p yuta--frame))
          (yuta--enable-evil-nav-bindings)))))
  (yuta--apply-glassmorphism-style))

(defun yuta--apply-glassmorphism-style ()
  "Apply a glass-like visual style to active Yuta buffers."
  (dolist (buf (list yuta--input-buffer yuta--list-buffer yuta--preview-buffer))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq-local line-spacing 0.15)
        (setq-local mode-line-format nil)
        (setq-local left-margin-width 1)
        (setq-local right-margin-width 1)
        (when yuta--face-cookie
          (face-remap-remove-relative yuta--face-cookie))
        (setq yuta--face-cookie
              (face-remap-add-relative
               'default
               :background "#1a1d21"
               :foreground "#d6d8dc")))))
  (when (and yuta--frame (frame-live-p yuta--frame))
    (set-frame-parameter yuta--frame 'internal-border-width 2)
    (set-frame-parameter yuta--frame 'internal-border-color "#3b4149")
    (when (display-graphic-p yuta--frame)
      (set-frame-parameter yuta--frame 'alpha-background 92))))

(defun yuta--teardown-ui ()
  "Destroy all Yuta buffers and frame/windows."
  (let ((child yuta--frame)
        (parent yuta--parent-frame)
        (parent-win yuta--parent-window)
        (saved-conf yuta--saved-window-config))
    (unwind-protect
        (progn
          (remove-hook 'pre-command-hook #'yuta--child-focus-guard)
          (setq yuta--child-focus-guard-enabled nil)
          (yuta--cancel-debounce)
          (yuta--kill-async)
          ;; Clear emergency overrides that can hijack all keys.
          (setq overriding-terminal-local-map nil
                overriding-local-map nil)
          ;; Always return to parent frame first.
          (when (and parent (frame-live-p parent))
            (ignore-errors
              (select-frame-set-input-focus parent)
              (select-frame parent)))
          ;; If the popup frame still exists, force-delete it after focus handoff.
          (when (and child (frame-live-p child))
            (ignore-errors (redirect-frame-focus child nil))
            (ignore-errors (delete-frame child t)))
          ;; Restore pre-Yuta window layout.
          (when (window-configuration-p saved-conf)
            (ignore-errors (set-window-configuration saved-conf)))
          (when (and parent-win (window-live-p parent-win))
            (ignore-errors (select-window parent-win))))
      ;; Final defensive reset: avoid stuck modal/transient states.
      (discard-input)
      (deactivate-mark)
      (when (fboundp 'evil-force-normal-state)
        (ignore-errors (evil-force-normal-state)))
      (dolist (b (list yuta--input-buffer yuta--list-buffer yuta--preview-buffer))
        (when (buffer-live-p b)
          (ignore-errors (kill-buffer b))))
      (setq yuta--frame          nil
            yuta--input-buffer   nil
            yuta--list-buffer    nil
            yuta--preview-buffer nil
            yuta--input-window   nil
            yuta--list-window    nil
            yuta--preview-window nil
            yuta--parent-frame   nil
            yuta--parent-window  nil
            yuta--saved-window-config nil
            yuta--project-root   nil
            yuta--dynamic-source-fn nil
            yuta--candidates     '()
            yuta--filtered       '()
            yuta--selected-index 0))))

(defun yuta-abort ()
  "Abort Yuta safely without leaving Emacs in a quit state."
  (interactive)
  (let ((inhibit-quit t))
    (setq quit-flag nil
          unread-command-events nil)
    (yuta--teardown-ui)))

;;;; ─── Input handling & debounce ──────────────────────────────────────────────

(defun yuta--on-input-change (&rest _)
  "Called after every edit in the input buffer; schedules a debounced refresh."
  (yuta--cancel-debounce)
  (setq yuta--debounce-timer
        (run-with-timer
         yuta-debounce-delay nil
         (if yuta--dynamic-source-fn
             #'yuta--refresh-dynamic
           #'yuta--refresh))))

(defun yuta--current-input ()
  "Return the text in the input buffer."
  (when (buffer-live-p yuta--input-buffer)
    (with-current-buffer yuta--input-buffer
      (buffer-substring-no-properties (point-min) (point-max)))))

;;;; ─── Mode selection ──────────────────────────────────────────────────────────

(defun yuta--select-mode (source-type candidates-hint)
  "Set `yuta--mode' based on SOURCE-TYPE and CANDIDATES-HINT (count or nil)."
  (setq yuta--mode
        (cond
         ((memq source-type '(buffers commands)) 'emacs)
         ((and candidates-hint
               (< candidates-hint yuta-max-emacs-mode-candidates)) 'emacs)
         (t 'fzf))))

;;;; ─── Async process wrapper ───────────────────────────────────────────────────

(defun yuta--run-async (cmd callback)
  "Run CMD (a shell command string) asynchronously.
Call CALLBACK with the full output string when done."
  (yuta--kill-async)
  (setq yuta--process-output "")
  (let* ((buf (generate-new-buffer " *yuta-proc*"))
         (proc (start-process-shell-command "yuta-search" buf cmd)))
    (setq yuta--async-process proc)
    (set-process-sentinel
     proc
     (lambda (p _event)
       (when (eq (process-status p) 'exit)
         (let ((out (with-current-buffer (process-buffer p)
                      (buffer-string))))
           (when (buffer-live-p (process-buffer p))
             (kill-buffer (process-buffer p)))
           (funcall callback (ansi-color-filter-apply out))))))
    proc))

;;;; ─── Emacs-mode fuzzy scoring ────────────────────────────────────────────────

(defun yuta--score-candidate (pattern candidate)
  "Return a numeric score for CANDIDATE against PATTERN (higher = better match).
Returns nil if there is no match."
  (let* ((p (downcase pattern))
         (c (downcase candidate))
         (plen (length p))
         (clen (length c)))
    (if (zerop plen)
        0
      (let ((pi 0) (ci 0) (score 0) (consecutive 0) (last-match -1))
        (while (and (< pi plen) (< ci clen))
          (when (char-equal (aref p pi) (aref c ci))
            (cl-incf score (+ 1 consecutive))
            (when (= (- ci last-match) 1)
              (cl-incf score 3))
            (setq consecutive (1+ consecutive)
                  last-match ci)
            (cl-incf pi))
          (cl-incf ci))
        (if (= pi plen) score nil)))))

(defun yuta--emacs-filter (pattern candidates)
  "Return CANDIDATES filtered and sorted by fuzzy match against PATTERN."
  (if (string-empty-p pattern)
      candidates
    (let (scored)
      (dolist (c candidates)
        (when-let ((s (yuta--score-candidate pattern c)))
          (push (cons s c) scored)))
      (mapcar #'cdr
              (sort scored (lambda (a b) (> (car a) (car b))))))))

;;;; ─── Candidate list renderer ────────────────────────────────────────────────

(defface yuta-selected-face
  '((t (:background "#2a2f36" :foreground "#f6f7f8" :weight bold)))
  "Face for the selected candidate.")

(defface yuta-candidate-face
  '((t (:inherit default :foreground "#d6d8dc")))
  "Face for unselected candidates.")

(defface yuta-match-face
  '((t (:foreground "#f0c674" :weight bold)))
  "Face for matched characters in candidates.")

(defface yuta-header-face
  '((t (:foreground "#d9dde3" :weight semibold)))
  "Face for the header line.")

(defun yuta--render-candidates ()
  "Redraw the candidate list buffer."
  (when (buffer-live-p yuta--list-buffer)
    (with-current-buffer yuta--list-buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (setq-local header-line-format
                    (propertize
                     (format "  %d candidates  [mode:%s]"
                             (length yuta--filtered)
                             (symbol-name (or yuta--mode 'emacs)))
                     'face 'yuta-header-face))
        (let ((idx 0))
          (dolist (c yuta--filtered)
            (let ((selected (= idx yuta--selected-index))
                  (display-str (if (> (length c) 200) (substring c 0 200) c)))
              (insert (propertize
                       (concat (if selected " ▶ " "   ")
                               (yuta--source-icon)
                               display-str
                               "\n")
                       'face (if selected 'yuta-selected-face 'yuta-candidate-face)
                       'yuta-idx idx)))
            (cl-incf idx)))
        (goto-char (point-min))
        ;; Scroll to selected
        (when (> yuta--selected-index 0)
          (forward-line yuta--selected-index))))))

;;;; ─── Preview pane ────────────────────────────────────────────────────────────

(defun yuta--update-preview (candidate)
  "Update the preview buffer for CANDIDATE (a path or grep result)."
  (unless (buffer-live-p yuta--preview-buffer)
    (cl-return-from yuta--update-preview))
  (with-current-buffer yuta--preview-buffer
    (let ((inhibit-read-only t))
      (erase-buffer)
      (let ((cand (yuta--strip-ui-prefix candidate)))
      (when (and cand (not (string-empty-p cand)))
        (cond
         ;; grep result: file:line:content
         ((string-match "^\\([^:]+\\):\\([0-9]+\\):" cand)
          (let* ((file (match-string 1 cand))
                 (line (string-to-number (match-string 2 cand)))
                 (full (expand-file-name file (yuta--project-root))))
            (setq-local header-line-format
                        (propertize (format "  %s:%d" (file-name-nondirectory file) line)
                                    'face 'yuta-header-face))
            (if (file-readable-p full)
                (let ((cmd (yuta--bat-cmd full line)))
                  (call-process-shell-command cmd nil t nil))
              (insert (propertize "File not readable." 'face 'warning)))))

         ;; plain file path
         ((file-exists-p (expand-file-name cand (yuta--project-root)))
          (let* ((full (expand-file-name cand (yuta--project-root))))
            (setq-local header-line-format
                        (propertize (format "  %s" (file-name-nondirectory full))
                                    'face 'yuta-header-face))
            (if (file-readable-p full)
                (let ((cmd (yuta--bat-cmd full)))
                  (call-process-shell-command cmd nil t nil))
              (insert (propertize "Binary or unreadable." 'face 'warning)))))

         ;; buffer name
         ((get-buffer cand)
          (setq-local header-line-format
                      (propertize (format "  buffer: %s" cand) 'face 'yuta-header-face))
          (insert (with-current-buffer cand
                    (buffer-substring-no-properties
                     (point-min)
                     (min (point-max) (* yuta-preview-lines 80))))))

         (t
          (insert (propertize cand 'face 'default))))
        (goto-char (point-min)))))))

;;;; ─── Refresh cycle ───────────────────────────────────────────────────────────

(defun yuta--refresh ()
  "Main refresh: filter candidates and re-render."
  (let ((input (or (yuta--current-input) "")))
    (if (eq yuta--mode 'fzf)
        ;; FZF mode: nothing to filter here; fzf handled it externally
        (yuta--render-candidates)
      ;; Emacs mode: apply in-process scoring
      (setq yuta--filtered  (yuta--emacs-filter input yuta--candidates)
            yuta--selected-index 0)
      (yuta--render-candidates)
      (yuta--update-preview (car yuta--filtered)))))

(defun yuta--refresh-dynamic ()
  "Refresh candidates from a command generated from current input."
  (let ((input (string-trim (or (yuta--current-input) ""))))
    (if (string-empty-p input)
        (progn
          (yuta--kill-async)
          (setq yuta--candidates '()
                yuta--filtered '()
                yuta--selected-index 0)
          (yuta--render-candidates)
          (yuta--update-preview nil))
      (let ((cmd (funcall yuta--dynamic-source-fn input)))
        (yuta--run-async
         cmd
         (lambda (output)
           (let ((lines (cl-remove-if #'string-empty-p
                                      (split-string output "\n"))))
             (setq yuta--candidates lines
                   yuta--filtered lines
                   yuta--selected-index 0)
             (yuta--render-candidates)
             (yuta--update-preview (car yuta--filtered)))))))))

;;;; ─── Navigation ──────────────────────────────────────────────────────────────

(defun yuta--next-candidate ()
  "Move selection down one."
  (interactive)
  (when (and (buffer-live-p yuta--input-buffer)
             (not yuta--input-pane-p))
    (select-window yuta--input-window))
  (when yuta--filtered
    (setq yuta--selected-index
          (min (1+ yuta--selected-index) (1- (length yuta--filtered))))
    (yuta--render-candidates)
    (yuta--update-preview (nth yuta--selected-index yuta--filtered))))

(defun yuta--prev-candidate ()
  "Move selection up one."
  (interactive)
  (when (and (buffer-live-p yuta--input-buffer)
             (not yuta--input-pane-p))
    (select-window yuta--input-window))
  (when yuta--filtered
    (setq yuta--selected-index
          (max (1- yuta--selected-index) 0))
    (yuta--render-candidates)
    (yuta--update-preview (nth yuta--selected-index yuta--filtered))))

(defun yuta--selected-candidate ()
  "Return the currently selected candidate string."
  (nth yuta--selected-index yuta--filtered))

;;;; ─── Actions ─────────────────────────────────────────────────────────────────

(defun yuta--resolve-location (candidate)
  "Return (FILE . LINE) from CANDIDATE, handling grep format FILE:LINE:CONTENT."
  (let ((cand (yuta--strip-ui-prefix candidate)))
    (if (string-match "^\\([^:]+\\):\\([0-9]+\\):" cand)
        (cons (match-string 1 cand)
              (string-to-number (match-string 2 cand)))
      (cons cand nil)))
  )

(defun yuta--open-file (candidate &optional split)
  "Open CANDIDATE.  SPLIT can be \\='vsplit, \\='hsplit, or nil (current window)."
  (let* ((loc  (yuta--resolve-location candidate))
         (file (expand-file-name (car loc) (yuta--project-root)))
         (line (cdr loc)))
    (yuta--teardown-ui)
    (pcase split
      ('vsplit (split-window-right) (other-window 1))
      ('hsplit (split-window-below) (other-window 1)))
    (find-file file)
    (when line
      (goto-char (point-min))
      (forward-line (1- line)))))

(defun yuta--confirm-selection ()
  "Execute the default action on the selected candidate."
  (interactive)
  (when-let ((c (yuta--selected-candidate)))
    (if yuta--current-action
        (progn (yuta--teardown-ui) (funcall yuta--current-action c))
      (yuta--open-file c))))

(defun yuta--open-vsplit ()
  "Open selected candidate in a vertical split."
  (interactive)
  (when-let ((c (yuta--selected-candidate)))
    (yuta--open-file c 'vsplit)))

(defun yuta--open-hsplit ()
  "Open selected candidate in a horizontal split."
  (interactive)
  (when-let ((c (yuta--selected-candidate)))
    (yuta--open-file c 'hsplit)))

(defun yuta--copy-path ()
  "Copy selected candidate path to the kill ring."
  (interactive)
  (when-let ((c (yuta--selected-candidate)))
    (let* ((loc  (yuta--resolve-location c))
           (file (expand-file-name (car loc) (yuta--project-root))))
      (kill-new file)
      (message "Yuta: copied %s" file))))

;;;; ─── Session launcher ────────────────────────────────────────────────────────

(defun yuta--launch (source-type candidates-or-cmd &optional action-fn dynamic-source-fn)
  "Start a Yuta session.

SOURCE-TYPE   – symbol describing what we're searching.
CANDIDATES-OR-CMD – either a list of strings (Emacs mode) or a shell
                    command string whose stdout provides the candidates.
ACTION-FN     – optional; overrides the default open-file action.
DYNAMIC-SOURCE-FN – optional function of input string to shell command."
  (setq yuta--source-type    source-type
        yuta--project-root   (yuta--project-root)
        yuta--current-action action-fn
        yuta--dynamic-source-fn dynamic-source-fn
        yuta--selected-index 0)

  (cond
   ;; Pre-built list → Emacs mode
   ((listp candidates-or-cmd)
    (setq yuta--candidates candidates-or-cmd
          yuta--filtered    candidates-or-cmd)
    (yuta--select-mode source-type (length candidates-or-cmd))
    (yuta--setup-ui)
    (yuta--render-candidates)
    (yuta--update-preview (car yuta--filtered)))

   ;; Shell command → async, decide mode after results arrive
   ((stringp candidates-or-cmd)
    (yuta--select-mode source-type nil)
    (yuta--setup-ui)
    (with-current-buffer yuta--list-buffer
      (let ((inhibit-read-only t))
        (insert (propertize "  Searching…\n" 'face 'font-lock-comment-face))))
    (yuta--run-async
     candidates-or-cmd
     (lambda (output)
       (let ((lines (cl-remove-if #'string-empty-p
                                  (split-string output "\n"))))
         (setq yuta--candidates    lines
               yuta--filtered      lines
               yuta--selected-index 0)
         (yuta--select-mode source-type (length lines))
         ;; In Emacs mode apply any input already typed
         (when (eq yuta--mode 'emacs)
           (setq yuta--filtered
                 (yuta--emacs-filter (or (yuta--current-input) "")
                                     yuta--candidates)))
         (yuta--render-candidates)
         (yuta--update-preview (car yuta--filtered))))))))

;;;; ─── FZF direct mode (large datasets) ──────────────────────────────────────

(defun yuta--launch-fzf (source-cmd &optional prompt action-fn)
  "Launch a pure fzf session for SOURCE-CMD.
The user interacts with fzf in a terminal buffer; on exit Emacs receives
the selection and calls ACTION-FN (or opens the file)."
  (let* ((result-file (make-temp-file "yuta-fzf-"))
         (fzf-opts    (mapconcat #'identity yuta-fzf-opts " "))
         (full-cmd    (format "%s | %s %s --prompt '%s> ' > %s"
                              source-cmd
                              yuta-fzf-executable
                              fzf-opts
                              (or prompt "yuta")
                              result-file))
         (term-buf    (generate-new-buffer "*yuta-fzf*")))
    (with-current-buffer term-buf
      (term-mode)
      (term-exec term-buf "yuta-fzf" "bash" nil (list "-c" full-cmd)))
    (switch-to-buffer term-buf)
    (set-process-sentinel
     (get-buffer-process term-buf)
     (lambda (_p _e)
       (let ((result (when (file-exists-p result-file)
                       (string-trim
                        (with-temp-buffer
                          (insert-file-contents result-file)
                          (buffer-string))))))
         (kill-buffer term-buf)
         (delete-file result-file)
         (when (and result (not (string-empty-p result)))
           (if action-fn
               (funcall action-fn result)
             (yuta--open-file result))))))))

;;;; ─── Public commands ─────────────────────────────────────────────────────────

;;;###autoload
(defun yuta-find-file ()
  "Find files using fd + fuzzy UI.
Uses fzf for large repos, Emacs mode for small ones."
  (interactive)
  (let* ((root (yuta--project-root))
         (cmd  (if (yuta--executable-p yuta-fd-executable)
                   (format "fd --type f --hidden --follow --exclude .git . %s"
                           (shell-quote-argument root))
                 (format "find %s -type f -not -path '*/.git/*'"
                         (shell-quote-argument root)))))
    (yuta--launch 'files cmd)))

;;;###autoload
(defun yuta-git-files ()
  "Find files tracked by git."
  (interactive)
  (let* ((root (yuta--project-root))
         (cmd  (format "git -C %s ls-files" (shell-quote-argument root))))
    (yuta--launch 'files cmd)))

;;;###autoload
(defun yuta-recent-files ()
  "Browse recently visited files (recentf)."
  (interactive)
  (require 'recentf)
  (unless recentf-mode (recentf-mode 1))
  (recentf-cleanup)
  (let* ((open-files (delq nil (mapcar #'buffer-file-name (buffer-list))))
         (recent (append open-files recentf-list))
         (files (delete-dups
                 (cl-remove-if-not #'file-exists-p recent))))
    (yuta--launch 'files files
                  (lambda (c) (find-file c)))))

;;;###autoload
(defun yuta-live-grep ()
  "Live grep in Yuta popup (type query directly in the popup input)."
  (interactive)
  (let ((root (yuta--project-root)))
    (yuta--launch
     'grep
     '()
     nil
     (lambda (pattern)
       (if (yuta--executable-p yuta-rg-executable)
           (format "rg --color=never --line-number --no-heading -S -e %s %s | head -n %d"
                   (shell-quote-argument pattern)
                   (shell-quote-argument root)
                   yuta-live-grep-max-results)
         (format "grep -rn %s %s | head -n %d"
                 (shell-quote-argument pattern)
                 (shell-quote-argument root)
                 yuta-live-grep-max-results))))))

;;;###autoload
(defun yuta-switch-buffer ()
  "Switch to an open buffer using Yuta Emacs-mode UI."
  (interactive)
  (let ((bufs (cl-remove-if
               (lambda (b) (string-prefix-p " " (buffer-name b)))
               (buffer-list))))
    (yuta--launch 'buffers
                  (mapcar #'buffer-name bufs)
                  (lambda (name)
                    (when-let ((b (get-buffer name)))
                      (switch-to-buffer b))))))

;;;###autoload
(defun yuta-command-palette ()
  "VSCode-style command palette: fuzzy-find and execute any Emacs command."
  (interactive)
  (let ((cmds (all-completions "" obarray #'commandp)))
    (yuta--launch 'commands cmds
                  (lambda (name)
                    (let ((sym (intern-soft name)))
                      (when (and sym (commandp sym))
                        (call-interactively sym)))))))

;;;###autoload
(defun yuta-quit ()
  "Quit Yuta and restore the previous window configuration."
  (interactive)
  (yuta-abort))

;;;; ─── LSP integration (optional) ─────────────────────────────────────────────

(defun yuta--lsp-available-p ()
  "Return non-nil if eglot is active in the current buffer."
  (and (featurep 'eglot) (bound-and-true-p eglot--managed-mode)))

(defun yuta--icon (key)
  "Return icon string for KEY using configured icon style."
  (if (or (not yuta-enable-icons)
          (eq yuta-icon-style 'none))
      ""
    (let* ((use-nerd
            (pcase yuta-icon-style
              ('nerd t)
              ('ascii nil)
              ('auto (char-displayable-p ?󰈞))
              (_ nil))))
      (if use-nerd
          (pcase key
            ('definition "󰈞 ")
            ('reference "󰈇 ")
            ('function "󰊕 ")
            ('method "󰊕 ")
            ('class "󰠱 ")
            ('interface "󰜰 ")
            ('variable "󰀫 ")
            ('constant "󰏿 ")
            ('module "󰅩 ")
            ('property "󰆧 ")
            ('enum "󰒻 ")
            ('struct "󰙅 ")
            ('diagnostic "󰅚 ")
            ('file "󰈔 ")
            ('grep "󰍉 ")
            ('buffer "󰈙 ")
            ('command "󰘳 ")
            ('symbols "󰘦 ")
            ('recent "󱋡 ")
            (_ ""))
        (pcase key
          ('definition "[D] ")
          ('reference "[R] ")
          ('function "[F] ")
          ('method "[M] ")
          ('class "[C] ")
          ('interface "[I] ")
          ('variable "[V] ")
          ('constant "[K] ")
          ('module "[Mod] ")
          ('property "[P] ")
          ('enum "[E] ")
          ('struct "[S] ")
          ('diagnostic "[!] ")
          ('file "[File] ")
          ('grep "[Grep] ")
          ('buffer "[Buf] ")
          ('command "[Cmd] ")
          ('symbols "[Sym] ")
          ('recent "[Rec] ")
          (_ ""))))))

(defun yuta--source-icon ()
  "Return icon prefix for current Yuta source type."
  (pcase yuta--source-type
    ('files (yuta--icon 'file))
    ('grep (yuta--icon 'grep))
    ('buffers (yuta--icon 'buffer))
    ('commands (yuta--icon 'command))
    ;; LSP sources often embed per-item icons already.
    ('symbols "")
    ('definitions "")
    ('references "")
    ('diagnostics "")
    ('recent (yuta--icon 'recent))
    (_ "")))

(defun yuta--strip-ui-prefix (s)
  "Strip visual icon prefix from candidate string S."
  (replace-regexp-in-string "^[^[:alnum:]_./~-]+\\s-*" "" (or s "")))

(defun yuta--lsp-kind-icon (kind)
  "Return icon prefix for LSP symbol KIND numeric value."
  (pcase kind
    (5 (yuta--icon 'class))
    (6 (yuta--icon 'method))
    (7 (yuta--icon 'property))
    (8 (yuta--icon 'field))
    (12 (yuta--icon 'function))
    (13 (yuta--icon 'variable))
    (14 (yuta--icon 'constant))
    (2 (yuta--icon 'module))
    (10 (yuta--icon 'enum))
    (23 (yuta--icon 'struct))
    (_ "")))

(defun yuta--xref-candidates (kind)
  "Return xref candidates formatted for Yuta from KIND (`definitions' or `references')."
  (let* ((backend (ignore-errors (xref-find-backend)))
         (identifier (and backend (ignore-errors (xref-backend-identifier-at-point backend))))
         (items (pcase kind
                  ('definitions (and backend identifier
                                     (ignore-errors (xref-backend-definitions backend identifier))))
                  ('references (and backend identifier
                                    (ignore-errors (xref-backend-references backend identifier))))
                  (_ nil)))
         (root (yuta--project-root))
         (icon (if (eq kind 'definitions)
                   (yuta--icon 'definition)
                 (yuta--icon 'reference))))
    (mapcar
     (lambda (x)
       (let* ((loc (xref-item-location x))
              (group (or (ignore-errors (xref-location-group loc)) ""))
              (line (or (ignore-errors (xref-location-line loc)) 1))
              (file (if (and (stringp group) (file-name-absolute-p group))
                        (file-relative-name group root)
                      group))
              (summary (string-trim (or (ignore-errors (xref-item-summary x)) ""))))
         (format "%s%s:%d: %s" icon file line summary)))
     items)))

;;;###autoload
(defun yuta-lsp-definitions ()
  "Jump to LSP definitions using Yuta UI."
  (interactive)
  (if (not (yuta--lsp-available-p))
      (message "Yuta: no active LSP session (eglot not running).")
    (let ((cands (yuta--xref-candidates 'definitions)))
      (if (null cands)
          (message "Yuta: no definitions found.")
        (yuta--launch 'definitions cands)))))

;;;###autoload
(defun yuta-lsp-references ()
  "Show LSP references using Yuta UI."
  (interactive)
  (if (not (yuta--lsp-available-p))
      (message "Yuta: no active LSP session.")
    (let ((cands (yuta--xref-candidates 'references)))
      (if (null cands)
          (message "Yuta: no references found.")
        (yuta--launch 'references cands)))))

;;;###autoload
(defun yuta-lsp-symbols ()
  "Fuzzy-find workspace symbols via LSP."
  (interactive)
  (if (not (yuta--lsp-available-p))
      (message "Yuta: no active LSP session.")
    (let ((syms '()))
      (when-let ((server (eglot-current-server)))
        (let ((resp (jsonrpc-request
                     server :workspace/symbol
                     `(:query ,(read-string "Symbol query: ")))))
          (when resp
            (setq syms
                  (mapcar (lambda (s)
                            (format "%s%s  [%s]  %s:%d"
                                    (yuta--lsp-kind-icon (plist-get s :kind))
                                    (plist-get s :name)
                                    (plist-get s :kind)
                                    (thread-first s
                                      (plist-get :location)
                                      (plist-get :uri)
                                      (eglot--uri-to-path)
                                      (file-relative-name (yuta--project-root)))
                                    (thread-first s
                                      (plist-get :location)
                                      (plist-get :range)
                                      (plist-get :start)
                                      (plist-get :line))))
                          resp)))))
      (if (null syms)
          (message "Yuta: no symbols found.")
        (yuta--launch 'symbols syms
                      (lambda (entry)
                        ;; entry format: "NAME  [KIND]  FILE:LINE"
                        (when (string-match "\\([^:]+\\):\\([0-9]+\\)$" entry)
                          (let ((file (match-string 1 entry))
                                (line (string-to-number (match-string 2 entry))))
                            (find-file (expand-file-name file (yuta--project-root)))
                            (goto-char (point-min))
                            (forward-line (1- line))))))))))

;;;###autoload
(defun yuta-lsp-diagnostics ()
  "Show project-wide LSP diagnostics in Yuta."
  (interactive)
  (if (not (yuta--lsp-available-p))
      (message "Yuta: no active LSP session.")
    (let (diags)
      (dolist (buf (buffer-list))
        (with-current-buffer buf
          (when (yuta--lsp-available-p)
            (let ((flychk (flymake-diagnostics)))
              (dolist (d flychk)
                (push (format "%s:%d: [%s] %s"
                              (concat (yuta--icon 'diagnostic)
                                      (buffer-file-name buf))
                              (line-number-at-pos (flymake-diagnostic-beg d))
                              (flymake-diagnostic-type d)
                              (flymake-diagnostic-text d))
                      diags))))))
      (if (null diags)
          (message "Yuta: no diagnostics found.")
        (yuta--launch 'diagnostics (nreverse diags))))))

;;;; ─── Project-aware variants ─────────────────────────────────────────────────

;;;###autoload
(defun yuta-project-grep ()
  "Like `yuta-live-grep' but always anchored to project root."
  (interactive)
  (let ((default-directory (yuta--project-root)))
    (yuta-live-grep)))

;;;###autoload
(defun yuta-project-find-file ()
  "Like `yuta-find-file' but always anchored to project root."
  (interactive)
  (let ((default-directory (yuta--project-root)))
    (yuta-find-file)))

;;;; ─── Suggested key bindings (user sets these) ───────────────────────────────

;;  Example — add to your init.el:
;;
;;  (with-eval-after-load 'yuta
;;    (define-key global-map (kbd "C-c f")   #'yuta-find-file)
;;    (define-key global-map (kbd "C-c g")   #'yuta-git-files)
;;    (define-key global-map (kbd "C-c r")   #'yuta-live-grep)
;;    (define-key global-map (kbd "C-c b")   #'yuta-switch-buffer)
;;    (define-key global-map (kbd "C-c p")   #'yuta-command-palette)
;;    (define-key global-map (kbd "C-c d")   #'yuta-recent-files)
;;    (define-key global-map (kbd "C-c C-f") #'yuta-project-find-file)
;;    (define-key global-map (kbd "C-c C-g") #'yuta-project-grep))

;;;; ─── Minor mode for global activation ───────────────────────────────────────

(defvar yuta-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c y f")   #'yuta-find-file)
    (define-key m (kbd "C-c y g")   #'yuta-git-files)
    (define-key m (kbd "C-c y r")   #'yuta-live-grep)
    (define-key m (kbd "C-c y b")   #'yuta-switch-buffer)
    (define-key m (kbd "C-c y p")   #'yuta-command-palette)
    (define-key m (kbd "C-c y d")   #'yuta-recent-files)
    (define-key m (kbd "C-c y s")   #'yuta-lsp-symbols)
    (define-key m (kbd "C-c y x")   #'yuta-lsp-diagnostics)
    m)
  "Keymap for `yuta-mode'.")

(defvar yuta-command-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "f") #'yuta-find-file)
    (define-key m (kbd "g") #'yuta-git-files)
    (define-key m (kbd "r") #'yuta-live-grep)
    (define-key m (kbd "b") #'yuta-switch-buffer)
    (define-key m (kbd "p") #'yuta-command-palette)
    (define-key m (kbd "d") #'yuta-recent-files)
    (define-key m (kbd "s") #'yuta-lsp-symbols)
    (define-key m (kbd "x") #'yuta-lsp-diagnostics)
    m)
  "Prefix command map for Yuta.")

(defun yuta--enable-global-bindings ()
  "Enable global key prefix for Yuta commands."
  (define-key global-map yuta-global-prefix-key yuta-command-map))

(defun yuta--disable-global-bindings ()
  "Disable global key prefix for Yuta commands."
  (define-key global-map yuta-global-prefix-key nil))

(defface yuta-lsp-popup-face
  '((t (:background "#1a1d21" :foreground "#d6d8dc")))
  "Face used for Yuta LSP popup lines.")

(defface yuta-lsp-popup-selected-face
  '((t (:background "#2a2f36" :foreground "#f6f7f8" :weight bold)))
  "Face used for selected candidate in Yuta LSP popup.")

(defun yuta--lsp-popup-clear ()
  "Hide and reset Yuta LSP popup in current buffer."
  (when (overlayp yuta--lsp-popup-overlay)
    (delete-overlay yuta--lsp-popup-overlay))
  (setq yuta--lsp-popup-overlay nil
        yuta--lsp-popup-candidates nil
        yuta--lsp-popup-index 0
        yuta--lsp-popup-beg nil
        yuta--lsp-popup-end nil))

(defun yuta--lsp-popup-render ()
  "Render current LSP candidates in an inline Yuta popup."
  (if (or (null yuta--lsp-popup-candidates) (null yuta--lsp-popup-beg))
      (yuta--lsp-popup-clear)
    (let ((lines '())
          (maxw yuta-lsp-popup-min-width)
          (i 0))
      (dolist (c yuta--lsp-popup-candidates)
        (setq maxw (max maxw (+ 3 (string-width c)))))
      (dolist (c yuta--lsp-popup-candidates)
        (let* ((prefix (if (= i yuta--lsp-popup-index) " ▶ " "   "))
               (raw (concat prefix c))
               (line (truncate-string-to-width raw maxw nil ?\s))
               (padded (concat line "\n")))
          (push (propertize
                 padded
                 'cursor 0
                 'rear-nonsticky t
                 'front-sticky t
                 'line-prefix ""
                 'wrap-prefix ""
                 'face (if (= i yuta--lsp-popup-index)
                           'yuta-lsp-popup-selected-face
                         'yuta-lsp-popup-face))
                lines))
        (setq i (1+ i)))
      (unless (overlayp yuta--lsp-popup-overlay)
        (setq yuta--lsp-popup-overlay (make-overlay yuta--lsp-popup-end yuta--lsp-popup-end)))
      (move-overlay yuta--lsp-popup-overlay yuta--lsp-popup-end yuta--lsp-popup-end)
      (overlay-put yuta--lsp-popup-overlay
                   'after-string
                   (propertize (concat "\n" (apply #'concat (nreverse lines)))
                               'cursor 0
                               'line-prefix ""
                               'wrap-prefix ""))
      (overlay-put yuta--lsp-popup-overlay 'priority 1200))))

(defun yuta--lsp-popup-move (delta)
  "Move Yuta LSP popup selection by DELTA."
  (interactive)
  (when yuta--lsp-popup-candidates
    (setq yuta--lsp-popup-index
          (mod (+ yuta--lsp-popup-index delta)
               (max 1 (length yuta--lsp-popup-candidates))))
    (yuta--lsp-popup-render)))

(defun yuta--lsp-popup-next ()
  "Select next candidate in Yuta LSP popup."
  (interactive)
  (yuta--lsp-popup-move 1))

(defun yuta--lsp-popup-prev ()
  "Select previous candidate in Yuta LSP popup."
  (interactive)
  (yuta--lsp-popup-move -1))

(defun yuta--lsp-popup-accept ()
  "Accept selected Yuta LSP popup candidate, or fallback to CAPF."
  (interactive)
  (if (and yuta--lsp-popup-candidates
           yuta--lsp-popup-beg
           yuta--lsp-popup-end)
      (let ((cand (nth yuta--lsp-popup-index yuta--lsp-popup-candidates)))
        (when cand
          (delete-region yuta--lsp-popup-beg yuta--lsp-popup-end)
          (goto-char yuta--lsp-popup-beg)
          (insert cand))
        (yuta--lsp-popup-clear))
    (completion-at-point)))

(defun yuta--lsp-popup-post-command-cleanup ()
  "Clear popup when point/context moved away from tracked completion range."
  (when (and yuta--lsp-popup-candidates
             (or (not (yuta--eglot-active-p))
                 (not (integerp yuta--lsp-popup-beg))
                 (not (integerp yuta--lsp-popup-end))
                 (< (point) yuta--lsp-popup-beg)
                 (> (point) yuta--lsp-popup-end)))
    (yuta--lsp-popup-clear)))

(defun yuta--eglot-instant-completion-setup ()
  "Enable instant completion + TAB accept in eglot-managed buffers."
  (setq-local tab-always-indent 'complete)
  (setq-local completion-auto-help 'always)
  (setq-local completion-cycle-threshold 1)
  (local-set-key (kbd "TAB") #'yuta--lsp-popup-accept)
  (local-set-key (kbd "<tab>") #'yuta--lsp-popup-accept)
  (local-set-key (kbd "C-i") #'yuta--lsp-popup-accept)
  (local-set-key (kbd "C-n") #'yuta--lsp-popup-next)
  (local-set-key (kbd "C-p") #'yuta--lsp-popup-prev)
  (local-set-key (kbd "<down>") #'yuta--lsp-popup-next)
  (local-set-key (kbd "<up>") #'yuta--lsp-popup-prev)
  (when (fboundp 'corfu-mode)
    (setq-local corfu-auto t
                corfu-auto-delay 0.0
                corfu-auto-prefix 1)
    (corfu-mode 1))
  (when (fboundp 'company-mode)
    (setq-local company-idle-delay 0.0
                company-minimum-prefix-length 1
                company-selection-wrap-around t)
    (company-mode 1))
  ;; Built-in fallback when Corfu/Company is unavailable.
  (unless (or (bound-and-true-p corfu-mode)
              (bound-and-true-p company-mode))
    (when (fboundp 'completion-preview-mode)
      (completion-preview-mode 1)))
  (add-hook 'post-self-insert-hook #'yuta--lsp-auto-complete-schedule nil t)
  (add-hook 'post-command-hook #'yuta--lsp-popup-post-command-cleanup nil t))

(defun yuta--eglot-active-p ()
  "Return non-nil when current buffer is managed by Eglot."
  (or (and (fboundp 'eglot-managed-p) (eglot-managed-p))
      (bound-and-true-p eglot--managed-mode)
      (bound-and-true-p eglot-managed-mode)))

(defun yuta--lsp-auto-complete-cancel ()
  "Cancel pending native LSP completion timer in current buffer."
  (when (timerp yuta--lsp-complete-timer)
    (cancel-timer yuta--lsp-complete-timer)
    (setq yuta--lsp-complete-timer nil)))

(defun yuta--lsp-capf-prefix-len ()
  "Return current CAPF prefix length, or nil if unavailable."
  (let* ((capf (yuta--lsp-capf-resolve))
         (beg (nth 0 capf))
         (end (nth 1 capf)))
    (when (and (integerp beg) (integerp end) (<= beg end))
      (- end beg))))

(defun yuta--lsp-capf-resolve ()
  "Resolve the active CAPF list at point without invoking completion UI."
  (let ((result nil))
    (catch 'done
      (dolist (fn completion-at-point-functions)
        (let ((r (ignore-errors (funcall fn))))
          (when (and (listp r) (>= (length r) 3))
            (setq result r)
            (throw 'done r)))))
    result))

(defun yuta--lsp-capf-data ()
  "Return (BEG END CANDS) from CAPF at point, or nil."
  (let* ((capf (yuta--lsp-capf-resolve))
         (beg (nth 0 capf))
         (end (nth 1 capf))
         (table (nth 2 capf))
         (props (nthcdr 3 capf))
         (pred (plist-get props :predicate)))
    (when (and (integerp beg) (integerp end) table (<= beg end))
      (let* ((input (buffer-substring-no-properties beg end))
             (raw (or (ignore-errors
                        (completion-all-completions input table pred (length input)))
                      (ignore-errors (all-completions input table pred))
                      '()))
             (all (cl-remove-if-not #'stringp raw))
             (clean (delete-dups (mapcar #'substring-no-properties all)))
             (cands (cl-subseq clean 0 (min yuta-lsp-popup-max-candidates (length clean)))))
        (list beg end cands)))))

(defun yuta--lsp-auto-complete-run (buf)
  "Run native CAPF completion in BUF if conditions still match."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq yuta--lsp-complete-timer nil)
      (when (and (yuta--eglot-active-p)
                 (not (minibufferp))
                 (not (active-minibuffer-window))
                 (not (bound-and-true-p isearch-mode))
                 (<= (buffer-size) yuta-lsp-max-buffer-size)
                 (not (file-remote-p default-directory))
                 (or (not (numberp yuta--lsp-last-complete-time))
                     (>= (- (float-time) yuta--lsp-last-complete-time)
                         yuta-lsp-min-request-interval)))
        (let ((prefix-len (ignore-errors (yuta--lsp-capf-prefix-len))))
          (when (and prefix-len
                     (>= prefix-len yuta-lsp-min-prefix-length))
            (setq yuta--lsp-last-complete-time (float-time))
            (pcase-let ((`(,beg ,end ,cands)
                         (or (yuta--lsp-capf-data) (list nil nil nil))))
              (if (and cands (> (length cands) 0))
                  (progn
                    (setq yuta--lsp-popup-beg beg
                          yuta--lsp-popup-end end
                          yuta--lsp-popup-candidates cands
                          yuta--lsp-popup-index 0)
                    (yuta--lsp-popup-render))
                (yuta--lsp-popup-clear)))))))))

(defun yuta--lsp-auto-complete-schedule ()
  "Schedule native Yuta LSP completion after idle delay."
  (when (and (yuta--eglot-active-p)
             (or (eq this-command 'self-insert-command)
                 (eq this-command 'org-self-insert-command)))
    (yuta--lsp-auto-complete-cancel)
    (setq yuta--lsp-complete-timer
          (run-with-idle-timer yuta-lsp-auto-complete-delay nil
                               #'yuta--lsp-auto-complete-run
                               (current-buffer)))))

;;;###autoload
(defun yuta-enable-lsp-autocomplete ()
  "Enable immediate LSP completion popups and TAB completion for Eglot buffers."
  (interactive)
  (add-hook 'eglot-managed-mode-hook #'yuta--eglot-instant-completion-setup)
  (with-eval-after-load 'eglot
    (add-hook 'eglot-managed-mode-hook #'yuta--eglot-instant-completion-setup))
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (yuta--eglot-active-p)
        (yuta--eglot-instant-completion-setup))))
  (message "Yuta: LSP autocomplete enabled (instant popup + TAB completion)."))

(defun yuta--auto-enable-lsp-autocomplete ()
  "Enable Yuta LSP autocomplete silently when configured."
  (when yuta-lsp-autocomplete-default-enabled
    (let ((inhibit-message t)
          (message-log-max nil))
      (yuta-enable-lsp-autocomplete))))

;;;###autoload
(defun yuta-lsp-completion-self-test ()
  "Print whether Eglot/CAPF completion is available at point."
  (interactive)
  (let* ((managed (yuta--eglot-active-p))
         (capf (ignore-errors
                 (run-hook-wrapped 'completion-at-point-functions
                                   #'completion--capf-wrapper)))
         (beg (nth 0 capf))
         (end (nth 1 capf))
         (table (nth 2 capf)))
    (message "Yuta LSP test: managed=%s capf=%s range=%s..%s table=%s"
             managed
             (if capf "yes" "no")
             beg end
             (if table "yes" "no"))))

;;;###autoload
(define-minor-mode yuta-mode
  "Global minor mode providing Yuta fuzzy-finder bindings."
  :global t
  :lighter " Yuta"
  :keymap yuta-mode-map
  (if yuta-mode
      (yuta--enable-global-bindings)
    (yuta--disable-global-bindings)))

;;;###autoload
(defun yuta-setup ()
  "Convenience entry-point: enable `yuta-mode'."
  (interactive)
  (yuta-mode 1)
  (yuta-enable-lsp-autocomplete)
  (message "Yuta: activated. Use your Yuta prefix key then command key."))

;; Install global prefix bindings as soon as yuta is loaded.
(yuta--enable-global-bindings)
(yuta--auto-enable-lsp-autocomplete)

(provide 'yuta)
;;; yuta.el ends here
