# Agent Workflow

- Treat this repo as the chezmoi source. On this PC, `chezmoi source-path` should be `/home/jack/dotfiles`.
- Edit source files here, then run `chezmoi diff` and `chezmoi apply`.
- If a live dotfile under `$HOME` changed first, import it with `chezmoi re-add <path>`.
- Commit and push source changes from this repo.
- Keep machine-local values in `~/.config/chezmoi/chezmoi.toml`; keep the committed config shape in `.chezmoi.toml.tmpl`.
- Fresh installs should use `chezmoi init --apply`; updates should use `chezmoi update`.
