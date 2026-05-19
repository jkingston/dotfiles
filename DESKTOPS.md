# Desktop Package Model

This repo supports multiple graphical desktops. Package ownership should be
clear: common packages are the shared user environment; desktop packages provide
the desktop session and its native GUI apps.

## Rules

1. Keep personal workflow tools common.
   Examples: `ghostty`, `neovim`, `starship`, `lazygit`, `librewolf-bin`.

2. Let integrated desktops solve desktop problems.
   GNOME and KDE should use their native panels, notifications, settings,
   launchers, screenshots, power tools, and system-control UIs.

3. Treat Hyprland differently.
   Hyprland is assembled from smaller tools, so it needs explicit packages for
   notifications, launcher, panel, lock screen, screenshots, clipboard, and
   TUI-oriented system controls.

4. Do not confuse backends with frontends.
   `networkmanager`, `bluez`, and `pipewire` are service backends.
   `impala`, GNOME Settings, and `plasma-nm` are frontends.

5. A shared backend does not automatically belong in `COMMON_PACKAGES`.
   If a desktop needs a service and the installer enables it, that desktop must
   install the service package explicitly or prove that its desktop package set
   already installs it.

## Package Tiers

| Tier | Meaning | Examples | Owner |
| --- | --- | --- | --- |
| Base system | Boot, install, admin, system policy | `base`, `linux`, `sudo`, `ufw` | Common |
| Personal workflow | Same tools across desktops | `ghostty`, `neovim`, `starship` | Common |
| Shared backend | Daemon used by desktop frontends | `networkmanager`, `bluez`, `pipewire` | Common or per-desktop, after testing |
| Desktop infrastructure | Session, shell, login, panel, notifications, lock, portals | `hyprland`, `gnome`, `plasma-meta`, `gdm`, `sddm` | Desktop-specific |
| DE-native task app | GUI app where desktop integration matters | `nautilus`, `dolphin`, `okular`, `ark` | Desktop-specific |
| Optional workload app | Useful for specific workflows only | `pipewire-jack`, `kdeconnect`, `partitionmanager` | Optional/profile-specific |

## Capability Ownership

| Capability | Hyprland | GNOME | KDE / Plasma |
| --- | --- | --- | --- |
| Session | `hyprland` | `gnome-shell` | KWin via `plasma-meta` |
| Login | `greetd` | `gdm` | `sddm` |
| Launcher | `rofi-wayland` | GNOME Overview | KRunner / Kickoff |
| Notifications | `mako` | GNOME Shell | Plasma |
| Panel | `waybar` | GNOME Shell | Plasma Panel |
| Lock | `hyprlock` | GNOME Shell / GDM | Plasma locker |
| Idle / power | `hypridle` and scripts | GNOME Settings Daemon | `powerdevil` |
| Screenshots | `grim`, `slurp`, `swappy`, `grimblast-git` | GNOME screenshot tools | `spectacle` |
| Clipboard | `wl-clipboard`, `cliphist` | GNOME Shell | Plasma clipboard |
| Network UI | `impala` / CLI | GNOME Settings | `plasma-nm` |
| Bluetooth UI | `bluetui` / CLI | GNOME Settings | `bluedevil` |
| Audio UI | `pulsemixer`, Waybar | GNOME Settings | `plasma-pa` |
| File manager | `nautilus` | `nautilus` | `dolphin` |
| PDF viewer | Optional/browser | `papers` from `gnome` | `okular` |
| Image viewer | Optional/browser | `loupe` from `gnome` | `gwenview` |
| Archive manager | CLI `unzip` | GNOME archive tooling | `ark` |
| Calculator | Optional/CLI | `gnome-calculator` from `gnome` | `kcalc` |
| Terminal | `ghostty` | `ghostty` | `ghostty` |
| Editor | `neovim` | `neovim` | `neovim` |
| Browser | `librewolf-bin` | `librewolf-bin` | `librewolf-bin` |

## Common Packages

These should stay common because they are base system or personal workflow:

```bash
base linux linux-firmware "$MICROCODE"
mkinitcpio iptables-nft
git neovim sudo base-devel chezmoi
ghostty starship fzf zoxide bat eza
btop ripgrep fd jq tree unzip ncdu duf procs tldr git-delta
github-cli direnv lazygit lazydocker
ttf-jetbrains-mono-nerd ttf-cascadia-code-nerd noto-fonts
ufw pacman-contrib bc libnotify
```

Notes:

- `ghostty` is common, so do not install `konsole` or `gnome-console` by default.
- `neovim` is common, so do not install `kate` by default unless KDE becomes a
  GUI-complete profile.
- `librewolf-bin` is the shared browser for interactive installs, so do not add
  `falkon` or GNOME Web by default.
- `unzip` is CLI archive support. It does not replace GUI archive apps like
  `ark`.
- `libnotify` stays common because local scripts call `notify-send`.

## Backends To Review

These are currently common, but should be tested before deciding whether they
remain common or move into per-desktop package sets:

| Package | Current concern | Likely outcome |
| --- | --- | --- |
| `networkmanager` | Installer enables `NetworkManager`. GNOME/KDE frontends may not install the daemon package. | Keep installed wherever the service is enabled. |
| `bluez` | Installer enables `bluetooth`. GNOME/KDE integrate Bluetooth, but the daemon must still exist. | Keep installed wherever Bluetooth is enabled. |
| `bluez-utils` | Mainly provides CLI tools like `bluetoothctl`. | Probably Hyprland/debugging, not required for GNOME/KDE. |
| `pipewire`, `pipewire-pulse`, `pipewire-alsa`, `wireplumber` | Defines the audio stack. GNOME/KDE may pull only subsets or libraries. | Keep common unless VM tests prove per-desktop ownership is cleaner. |
| `pipewire-jack` | JACK compatibility is workload-specific. | Move to optional unless JACK apps are baseline. |

## Desktop Package Sets

### Hyprland

Hyprland should explicitly install the pieces that GNOME and KDE get from their
desktop environments:

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

Rationale:

- `waybar`, `mako`, `rofi-wayland`, `hyprlock`, and `hypridle` are desktop
  infrastructure.
- `impala`, `bluetui`, and `pulsemixer` are TUI/control frontends matching the
  Hyprland profile.
- `nautilus` fills the file-manager slot because Hyprland has no native file
  manager.

### GNOME

GNOME should rely on the `gnome` group for the integrated desktop and native
task apps.

```bash
gnome gdm
gnome-tweaks gnome-shell-extensions gnome-browser-connector
xdg-desktop-portal-gnome
xdg-user-dirs dconf
power-profiles-daemon
```

Rationale:

- `gnome` owns the shell, settings, panel, notifications, file manager, and
  GNOME task apps.
- `gdm` is explicit because the installer enables it.
- `dconf` and `xdg-user-dirs` support repo-managed GNOME configuration.
- `gnome-tweaks`, extensions, and browser connector are deliberate GNOME
  customization tools.

### KDE / Plasma

KDE should use Plasma-native infrastructure and a small set of native task apps.

Recommended package set:

```bash
KDE_PACKAGES=(
    plasma-meta
    sddm

    dolphin
    dolphin-plugins
    kio-admin
    kio-extras
    kio-fuse
    ffmpegthumbs
    kdegraphics-thumbnailers

    okular
    gwenview
    ark
    kcalc
)
```

Rationale:

- `plasma-meta` owns the KDE desktop: KWin, panels, notifications, System
  Settings, PowerDevil, Spectacle, Discover, portal integration, network/audio/
  Bluetooth frontends, and GTK integration.
- `sddm` is explicit because the installer should enable a known display
  manager.
- `dolphin` and KIO/thumbnail packages make file management complete.
- `okular`, `gwenview`, `ark`, and `kcalc` are small DE-native task apps.

Do not install by default:

| Package | Why not |
| --- | --- |
| `konsole` | Duplicates `ghostty`. |
| `kate` | Duplicates `neovim`; add only if KDE should be GUI-complete. |
| `falkon` | Duplicates `librewolf-bin`. |
| `kde-applications-meta` | Too broad. |
| `kde-system-meta` | Less intentional than listing the exact packages. |
| `kdeconnect` | Useful, but phone integration is optional. |
| `partitionmanager`, `ksystemlog`, `kcron` | Admin tools, not baseline desktop requirements. |

## Verification

Before moving backends out of `COMMON_PACKAGES`, run VM tests and check what is
actually installed.

All desktops:

```bash
chezmoi verify
pacman -Q ghostty neovim starship ufw libnotify
systemctl is-enabled ufw
```

Backend checks:

```bash
pacman -Q networkmanager bluez bluez-utils
pacman -Q pipewire pipewire-pulse pipewire-alsa wireplumber pipewire-jack
systemctl is-enabled NetworkManager
systemctl is-enabled bluetooth
```

Hyprland:

```bash
pacman -Q hyprland greetd waybar mako rofi-wayland hyprlock hypridle
pacman -Q xdg-desktop-portal-hyprland xdg-desktop-portal-gtk
systemctl is-enabled greetd
test -f ~/.config/hypr/hyprland.conf
```

GNOME:

```bash
pacman -Q gnome gdm gnome-tweaks gnome-shell-extensions
pacman -Q xdg-desktop-portal-gnome dconf
systemctl is-enabled gdm
test -f ~/.config/dconf/user.conf
```

KDE:

```bash
pacman -Q plasma-meta sddm dolphin okular gwenview ark kcalc
pacman -Q plasma-nm bluedevil plasma-pa xdg-desktop-portal-kde
systemctl is-enabled sddm
```
