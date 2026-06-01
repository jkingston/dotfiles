# Dotfiles

Chezmoi source for Jack's Linux and macOS dotfiles.

## Install

Fresh installs:

```bash
chezmoi init --apply jkingston/dotfiles
```

Updates:

```bash
chezmoi update
```

When editing on this machine, work from the chezmoi source:

```bash
cd ~/.local/share/chezmoi
chezmoi diff
chezmoi apply
```

## Bitwarden and SSH

Linux installs use `rbw` plus `rbw-agent` as the SSH agent. Configure rbw from:

```bash
rbw-menu
```

SSH uses the rbw agent socket through shell and user-session environment:

```text
SSH_AUTH_SOCK=${XDG_RUNTIME_DIR}/rbw/ssh-agent-socket
```

Host config is intentionally local. The committed `~/.ssh/config` only includes:

```sshconfig
Include ~/.ssh/config.local
```

Use `ssh-hosts` to generate `~/.ssh/config.local` and public key selector files from Bitwarden:

```bash
ssh-hosts template
ssh-hosts sync
ssh-hosts list
ssh-hosts test nas
ssh-hosts menu
```

Default Bitwarden source:

```text
item:  ssh/hosts
field: config
```

Config shape:

```json
{
  "hosts": [
    {
      "alias": "nas",
      "hostname": "nas.local",
      "user": "jack",
      "key": "nas",
      "port": 22
    }
  ],
  "keys": [
    {
      "name": "nas",
      "item": "ssh/keys/nas",
      "field": "public key"
    }
  ]
}
```

After syncing, normal SSH commands work:

```bash
ssh nas
```

Private keys stay in Bitwarden/rbw-agent. Only public key selector files are written under `~/.ssh/rbw`.
