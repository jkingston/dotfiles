# Neovim Config

Minimal config for Neovim 0.12+ using `vim.pack`.

## Setup

Chezmoi manages this Neovim config and `~/.config/mise/config.toml`.

On machines with `mise` installed, chezmoi automatically runs:

```bash
mise install --yes --cd "$HOME"
```

That installs the LSP servers and formatters expected by `init.lua`, including
LuaLS, Pyright, Ruff, rust-analyzer, rustfmt, Stylua, Prettier, Zig, ZLS, and
Tree-sitter.

## Plugins

| Plugin | Purpose |
| --- | --- |
| nvim-treesitter | Syntax highlighting |
| nvim-lspconfig | LSP configurations |
| catppuccin | Colorscheme |
| gitsigns.nvim | Git gutter signs |
| lualine.nvim | Status line |
| conform.nvim | Format on save |
| which-key.nvim | Keybinding hints popup |

## Keybindings Cheatsheet

Leader key: `<Space>`

### General

| Key | Action |
| --- | --- |
| `<Esc>` | Clear search highlight |
| `<leader>qq` | Quit all |
| `<leader>?` | Show this cheatsheet |

### Files

| Key | Action |
| --- | --- |
| `<leader>w` | Save file |
| `<leader>fn` | New file |

### Buffers

| Key | Action |
| --- | --- |
| `H` | Previous buffer |
| `L` | Next buffer |
| `<leader>bd` | Delete buffer |

### Windows

| Key | Action |
| --- | --- |
| `<leader>-` | Split below |
| `<leader>\|` | Split right |
| `<leader>wd` | Close window |
| `<C-h/j/k/l>` | Navigate windows |

### LSP / Code

| Key | Action |
| --- | --- |
| `gd` | Go to definition |
| `gD` | Go to declaration |
| `gr` | Go to references |
| `gi` | Go to implementation |
| `K` | Hover documentation |
| `<leader>ca` | Code action |
| `<leader>cr` | Rename symbol |
| `<leader>cf` | Format file |
| `<leader>cd` | Line diagnostics |

### Diagnostics

| Key | Action |
| --- | --- |
| `[d` / `]d` | Prev/next diagnostic |
| `[q` / `]q` | Prev/next quickfix |
| `<leader>xq` | Open quickfix list |
| `<leader>xl` | Open location list |

### Git

| Key | Action |
| --- | --- |
| `[c` / `]c` | Prev/next git hunk |
| `<leader>gb` | Git blame line |
| `<leader>gp` | Preview hunk |
| `<leader>gr` | Reset hunk |
