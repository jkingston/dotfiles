#!/usr/bin/env bash

# Shared package inventory for install.sh and package-sync.sh.

ARCH_COMMON_PACKAGES=(
    base linux linux-firmware
    mkinitcpio iptables-nft
    networkmanager iw bluez bluez-utils
    git neovim sudo base-devel chezmoi
    flatpak
    plymouth
    pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber
    ghostty starship fzf zoxide bat eza
    btop ripgrep fd jq tree unzip ncdu duf procs tldr git-delta
    github-cli direnv mise lazygit lazydocker openssh rbw rofi-rbw wtype gum
    ttf-jetbrains-mono-nerd ttf-cascadia-code-nerd noto-fonts noto-fonts-emoji
    ufw pacman-contrib bc libnotify
)

ARCH_HYPRLAND_PACKAGES=(
    hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk
    uwsm waybar mako hyprlock hypridle awww
    rofi-wayland rofimoji wl-clipboard cliphist
    grim slurp swappy hyprpicker
    playerctl brightnessctl
    greetd greetd-tuigreet
    nautilus
    swayosd bluetui pulsemixer rofi-calc hyprsunset impala
)

ARCH_PROFILE_FRAMEWORK12_PACKAGES=(
    intel-media-driver fwupd upower iio-sensor-proxy power-profiles-daemon
)

ARCH_PROFILE_MINIPC_PACKAGES=()

ARCH_AUR_PACKAGES=(
    grimblast-git waypaper wvkbd rofi-power-menu catppuccin-gtk-theme-mocha sunwait
)

ARCH_FLATPAK_PACKAGES=(
    app.zen_browser.zen
    org.localsend.localsend_app
)

MACOS_BREW_PACKAGES=(
    git neovim starship fzf zoxide bat eza
    btop ripgrep fd jq tree unzip ncdu duf procs tldr git-delta
    gh direnv mise lazygit lazydocker openssh gum chezmoi
)

ARCH_PROTECTED_PACKAGES=(
    base linux linux-firmware mkinitcpio pacman sudo filesystem bash coreutils
    systemd glibc gcc-libs shadow util-linux
)

MACOS_PROTECTED_PACKAGES=(
    bash git openssl ca-certificates
)

arch_profile_packages() {
    case "$1" in
        framework12)
            printf '%s\n' "${ARCH_PROFILE_FRAMEWORK12_PACKAGES[@]}"
            ;;
        minipc)
            if [ "${#ARCH_PROFILE_MINIPC_PACKAGES[@]}" -gt 0 ]; then
                printf '%s\n' "${ARCH_PROFILE_MINIPC_PACKAGES[@]}"
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

arch_repo_packages() {
    local profile="$1"
    local microcode="$2"

    printf '%s\n' "${ARCH_COMMON_PACKAGES[@]}" "$microcode" "${ARCH_HYPRLAND_PACKAGES[@]}"
    arch_profile_packages "$profile"
}
