# Desktop Package Model

This repo supports one graphical desktop: Hyprland. Common packages provide the
base system and personal workflow tools; Hyprland packages provide the graphical
session, login flow, applets, and desktop-specific controls.

## Rules

1. Keep personal workflow tools common.
   Examples: `ghostty`, `neovim`, `starship`, `lazygit`, `librewolf-bin`.

2. Keep Hyprland explicit.
   Hyprland is assembled from smaller tools, so the package set lists
   notifications, launcher, panel, lock screen, screenshots, clipboard, and
   system-control frontends directly.

3. Do not confuse backends with frontends.
   `networkmanager`, `bluez`, and `pipewire` are service backends. `impala`,
   `bluetui`, and `pulsemixer` are user-facing frontends.

## Common Packages

```bash
base linux linux-firmware "$MICROCODE"
mkinitcpio iptables-nft
networkmanager bluez bluez-utils
git neovim sudo base-devel chezmoi
plymouth
pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber
ghostty starship fzf zoxide bat eza
btop ripgrep fd jq tree unzip ncdu duf procs tldr git-delta
github-cli direnv lazygit lazydocker
ttf-jetbrains-mono-nerd ttf-cascadia-code-nerd noto-fonts noto-fonts-emoji
ufw pacman-contrib bc libnotify
```

## Hyprland Packages

```bash
hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk
uwsm waybar mako hyprlock hypridle swww
rofi-wayland rofimoji wl-clipboard cliphist
grim slurp swappy hyprpicker
playerctl brightnessctl
greetd greetd-tuigreet
nautilus
swayosd bluetui pulsemixer rofi-calc hyprsunset impala
```

Hyprland-specific AUR packages:

```bash
grimblast-git waypaper wvkbd rofi-power-menu catppuccin-gtk-theme-mocha sunwait
```

## Verification

```bash
chezmoi verify
pacman -Q ghostty neovim starship ufw libnotify
pacman -Q networkmanager bluez bluez-utils
pacman -Q pipewire pipewire-pulse pipewire-alsa wireplumber pipewire-jack
systemctl is-enabled NetworkManager
systemctl is-enabled bluetooth
pacman -Q hyprland greetd waybar mako rofi-wayland hyprlock hypridle
pacman -Q xdg-desktop-portal-hyprland xdg-desktop-portal-gtk
systemctl is-enabled greetd
test -f ~/.config/hypr/hyprland.conf
```
