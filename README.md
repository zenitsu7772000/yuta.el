# Yuta

Yuta is a fast, native fuzzy finder and command palette for Emacs, built to work with plain Emacs + external CLI tools.

It provides:
- Project file search
- Git-tracked file search
- Live grep in a popup
- Buffer switching
- Command palette
- Recent files picker
- Optional LSP helpers (Eglot)
- Native lightweight LSP autocomplete automation (no Corfu/Company required)
- Yuta-native LSP popup suggestions

## Features

- Dual mode architecture:
  - Emacs mode for interactive in-Emacs filtering
  - FZF mode for large datasets
- Split popup UI with:
  - Input pane
  - Candidate list pane
  - Preview pane
- Live preview for files and grep hits
- Evil-friendly navigation keys
- Async process pipeline for responsive searching
- Glass-style popup visual treatment
- Native LSP autocomplete automation via CAPF + Eglot (Yuta-managed)
- LSP definitions/references shown in Yuta popup (same navigation flow)

## Requirements

- Emacs `27.1+`
- Recommended CLI tools:
  - `rg` (ripgrep)
  - `fd`
  - `fzf`
  - `git`
  - `bat` (optional; falls back to `head`/`sed` if missing)

## Installation

### Manual

1. Place `yuta.el` somewhere in your load-path.
2. Add to your init file:

```elisp
(add-to-list 'load-path "/path/to/yuta")
(require 'yuta)
(yuta-mode 1)
```

### use-package

```elisp
(use-package yuta
  :load-path "/path/to/yuta"
  :commands (yuta-find-file
             yuta-git-files
             yuta-live-grep
             yuta-switch-buffer
             yuta-command-palette
             yuta-recent-files)
  :init
  (yuta-mode 1))
```

## Default Keybindings

Global keys provided by `yuta-mode`:

- `C-c y f` -> `yuta-find-file`
- `C-c y g` -> `yuta-git-files`
- `C-c y r` -> `yuta-live-grep`
- `C-c y b` -> `yuta-switch-buffer`
- `C-c y p` -> `yuta-command-palette`
- `C-c y d` -> `yuta-recent-files`
- `C-c y s` -> `yuta-lsp-symbols`
- `C-c y x` -> `yuta-lsp-diagnostics`

### Inside Yuta popup

- `RET` confirm
- `C-n` / `C-p` move selection
- `Down` / `Up` move selection
- `M-j` / `M-k` move selection
- `C-j` / `C-k` move selection
- `C-v` open in vertical split
- `C-x` open in horizontal split
- `C-c` copy selected path
- `M-<up/down/left/right>` resize popup
- `C-g`, `Esc`, `q` quit popup safely

### Evil users

In Evil states (`normal/insert/visual/motion`), Yuta maps:

- `j` / `k` navigation
- `C-j` / `C-k` navigation
- `RET` confirm
- `Esc` / `q` quit

## Commands

- `M-x yuta-find-file`
  - Search project files (fd/find backend)
- `M-x yuta-git-files`
  - Search git-tracked files
- `M-x yuta-live-grep`
  - Open popup and type pattern directly in input
- `M-x yuta-switch-buffer`
  - Fuzzy switch among open buffers
- `M-x yuta-command-palette`
  - Run any Emacs command by name
- `M-x yuta-recent-files`
  - Browse recently opened files + currently open file buffers
- `M-x yuta-enable-lsp-autocomplete`
  - Turn on Yuta's native auto LSP completion for Eglot buffers
- `M-x yuta-lsp-completion-self-test`
  - Verify if Eglot/CAPF completion is available at point
- `M-x yuta-lsp-definitions`
  - List definitions in Yuta popup and jump on select
- `M-x yuta-lsp-references`
  - List references in Yuta popup and jump on select

## Important Behavior

- Yuta resolves project root from current `default-directory` each time.
- `yuta-recent-files` now merges:
  - open buffer file paths
  - `recentf-list`
  - filters to existing files only
  - deduplicates results

## Customization

You can customize these variables:

- `yuta-fzf-executable`
- `yuta-rg-executable`
- `yuta-fd-executable`
- `yuta-bat-executable`
- `yuta-preview-width`
- `yuta-popup-width`
- `yuta-popup-height`
- `yuta-live-grep-max-results`
- `yuta-lsp-auto-complete-delay`
- `yuta-lsp-min-prefix-length`
- `yuta-lsp-min-request-interval`
- `yuta-lsp-max-buffer-size`
- `yuta-lsp-autocomplete-default-enabled`
- `yuta-lsp-popup-max-candidates`
- `yuta-enable-icons`
- `yuta-icon-style` (`auto`, `nerd`, `ascii`, `none`) ; default is `none`
- `yuta-debounce-delay`
- `yuta-max-emacs-mode-candidates`
- `yuta-preview-lines`
- `yuta-fzf-opts`
- `yuta-use-child-frame`

Example:

```elisp
(setq yuta-popup-width 0.92
      yuta-popup-height 0.75
      yuta-preview-width 0.50
      yuta-live-grep-max-results 220
      yuta-lsp-auto-complete-delay 0.15
      yuta-lsp-min-prefix-length 2
      yuta-lsp-min-request-interval 0.12
      yuta-lsp-max-buffer-size 400000
      yuta-lsp-popup-max-candidates 8
      yuta-enable-icons nil
      yuta-icon-style 'none
      yuta-use-child-frame t)
```

## Performance Profile (Default)

Yuta now ships with a balanced performance preset:

- LSP autocomplete is throttled (idle + min interval)
- Auto trigger starts at 2+ chars
- Auto completion is skipped for:
  - very large buffers
  - remote files (TRAMP)
- Live grep result count is capped (`220` by default)
- LSP autocomplete is enabled by default on load (`yuta-lsp-autocomplete-default-enabled`)
- LSP popup list is bounded (`yuta-lsp-popup-max-candidates`) for low latency
- Icon system is off by default for a cleaner UI (`yuta-enable-icons nil`)

If you want a faster but heavier feel:

```elisp
(setq yuta-lsp-auto-complete-delay 0.08
      yuta-lsp-min-prefix-length 1
      yuta-lsp-min-request-interval 0.05
      yuta-live-grep-max-results 300)
```

## Child-frame vs Window mode

- `yuta-use-child-frame` = `nil` (default): most stable
- `yuta-use-child-frame` = `t`: floating child frame UI (depends on WM/Evil setup)

If your editor becomes unresponsive after popup close, keep child-frame mode disabled.

## Support / Donate

If this project helps you, you can support development:

- TRC20: `TR7s5Edfdh9wkYw4xEyk7uAVyV7Qm9yA1X`
- ERC20: `0xe1c6864fdddcef5b5c63b2ea62af91395b569e36`
- BTC: `1Eu1bniUn1oot55RcRCj2q5QJwa4GtBkk7`

## License

GPL-3.0-or-later
