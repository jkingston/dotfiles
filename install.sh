#!/usr/bin/env bash
set -euo pipefail

# Arch Linux automated installer
# Run from the Arch live ISO:
#   curl -sL https://raw.githubusercontent.com/jkingston/dotfiles/main/install.sh | bash -s -- <profile>
# Or locally:
#   ./install.sh <profile>

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- Machine profiles ---
declare -A PROFILE_HOSTNAME PROFILE_IS_LAPTOP PROFILE_IS_VM PROFILE_MONITOR PROFILE_SCALE
declare -A PROFILE_GAPS_INNER PROFILE_GAPS_OUTER PROFILE_BORDER PROFILE_GPU PROFILE_DISK
declare -A PROFILE_LUKS PROFILE_EXTRA_PACKAGES PROFILE_MICROCODE

# Framework 13 (12th gen Intel)
PROFILE_HOSTNAME[framework12]="fw12"
PROFILE_IS_LAPTOP[framework12]=true
PROFILE_IS_VM[framework12]=false
PROFILE_MONITOR[framework12]="eDP-1"
PROFILE_SCALE[framework12]="1.25"
PROFILE_GAPS_INNER[framework12]=5
PROFILE_GAPS_OUTER[framework12]=5
PROFILE_BORDER[framework12]=2
PROFILE_GPU[framework12]="intel"
PROFILE_DISK[framework12]="/dev/nvme0n1"
PROFILE_LUKS[framework12]=true
PROFILE_MICROCODE[framework12]="intel-ucode"
PROFILE_EXTRA_PACKAGES[framework12]="intel-media-driver fwupd upower iio-sensor-proxy power-profiles-daemon"

# Beelink SER5 Pro (AMD)
PROFILE_HOSTNAME[minipc]="minipc"
PROFILE_IS_LAPTOP[minipc]=false
PROFILE_IS_VM[minipc]=false
PROFILE_MONITOR[minipc]=""
PROFILE_SCALE[minipc]="1.66666666"
PROFILE_GAPS_INNER[minipc]=5
PROFILE_GAPS_OUTER[minipc]=10
PROFILE_BORDER[minipc]=2
PROFILE_GPU[minipc]="amd"
PROFILE_DISK[minipc]="/dev/nvme0n1"
PROFILE_LUKS[minipc]=true
PROFILE_MICROCODE[minipc]="amd-ucode"
PROFILE_EXTRA_PACKAGES[minipc]=""

# --- Parse arguments ---
PROFILE="${1:-}"
if [ -z "$PROFILE" ] || [ -z "${PROFILE_HOSTNAME[$PROFILE]:-}" ]; then
    echo "Usage: $0 <profile>"
    echo ""
    echo "Available profiles:"
    for p in "${!PROFILE_HOSTNAME[@]}"; do
        echo "  $p"
    done
    exit 1
fi

HOSTNAME="${PROFILE_HOSTNAME[$PROFILE]}"
IS_LAPTOP="${PROFILE_IS_LAPTOP[$PROFILE]}"
IS_VM="${PROFILE_IS_VM[$PROFILE]}"
MONITOR="${PROFILE_MONITOR[$PROFILE]}"
SCALE="${PROFILE_SCALE[$PROFILE]}"
GAPS_INNER="${PROFILE_GAPS_INNER[$PROFILE]}"
GAPS_OUTER="${PROFILE_GAPS_OUTER[$PROFILE]}"
BORDER="${PROFILE_BORDER[$PROFILE]}"
GPU="${PROFILE_GPU[$PROFILE]}"
DISK="${PROFILE_DISK[$PROFILE]}"
USE_LUKS="${PROFILE_LUKS[$PROFILE]}"
MICROCODE="${PROFILE_MICROCODE[$PROFILE]}"
EXTRA_PACKAGES="${PROFILE_EXTRA_PACKAGES[$PROFILE]}"
USERNAME="jack"

info "Installing Arch Linux with profile: $PROFILE"
info "Hostname: $HOSTNAME | Disk: $DISK | LUKS: $USE_LUKS | GPU: $GPU"

# --- Get passwords ---
echo ""
read -s -p "Enter password (user + LUKS): " PASSWORD
echo ""
read -s -p "Confirm password: " PASSWORD_CONFIRM
echo ""

[ "$PASSWORD" = "$PASSWORD_CONFIRM" ] || error "Passwords do not match"

# --- Verify boot mode ---
[ -d /sys/firmware/efi/efivars ] || error "Not booted in UEFI mode"

# --- Partition disk ---
info "Partitioning $DISK..."
wipefs -af "$DISK"
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"ESP" "$DISK"
sgdisk -n 2:0:0 -t 2:8309 -c 2:"LUKS" "$DISK"
partprobe "$DISK"
sleep 1

PART1="${DISK}p1"
PART2="${DISK}p2"

# Handle non-nvme disks (e.g. /dev/sda1 vs /dev/nvme0n1p1)
if [[ "$DISK" != *nvme* ]] && [[ "$DISK" != *mmcblk* ]]; then
    PART1="${DISK}1"
    PART2="${DISK}2"
fi

# --- Format ---
info "Formatting ESP..."
mkfs.fat -F 32 "$PART1"

if [ "$USE_LUKS" = true ]; then
    info "Setting up LUKS encryption..."
    echo -n "$PASSWORD" | cryptsetup luksFormat "$PART2" --key-file=-
    echo -n "$PASSWORD" | cryptsetup open "$PART2" cryptroot --key-file=-
    ROOT_DEV="/dev/mapper/cryptroot"
else
    ROOT_DEV="$PART2"
fi

info "Formatting root..."
mkfs.ext4 -F "$ROOT_DEV"

# --- Mount ---
info "Mounting filesystems..."
mount "$ROOT_DEV" /mnt
mount --mkdir "$PART1" /mnt/boot

# --- Base packages ---
BASE_PACKAGES=(
    base linux linux-firmware "$MICROCODE"
    mkinitcpio iptables-nft
    networkmanager bluez bluez-utils
    git neovim sudo base-devel chezmoi
    pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber
    # Desktop
    hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk
    uwsm waybar mako hyprlock hypridle swww
    rofi-wayland rofimoji wl-clipboard cliphist
    grim slurp swappy hyprpicker
    playerctl brightnessctl
    greetd greetd-tuigreet
    nautilus
    # Terminal & tools
    ghostty starship fzf zoxide bat eza
    btop ripgrep fd jq tree unzip ncdu duf procs tldr git-delta
    github-cli direnv
    swayosd bluetui pulsemixer rofi-calc hyprsunset
    lazygit lazydocker
    # Fonts
    ttf-jetbrains-mono-nerd ttf-cascadia-code-nerd noto-fonts
    # Misc
    ufw pacman-contrib bc libnotify
)

# Add extra packages for this profile
read -ra EXTRAS <<< "$EXTRA_PACKAGES"
BASE_PACKAGES+=("${EXTRAS[@]}")

info "Installing base system (this will take a while)..."
pacstrap -K --noconfirm /mnt "${BASE_PACKAGES[@]}"

# --- Generate fstab ---
info "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# --- Get LUKS UUID before chroot ---
LUKS_UUID=""
if [ "$USE_LUKS" = true ]; then
    LUKS_UUID=$(blkid -s UUID -o value "$PART2")
fi

# --- Chroot configuration ---
info "Configuring system in chroot..."

arch-chroot /mnt bash -c "
set -e

# Timezone & locale
ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime
hwclock --systohc
echo 'en_GB.UTF-8 UTF-8' > /etc/locale.gen
locale-gen
echo 'LANG=en_GB.UTF-8' > /etc/locale.conf
echo 'KEYMAP=uk' > /etc/vconsole.conf
echo '$HOSTNAME' > /etc/hostname

# mkinitcpio
if [ '$USE_LUKS' = true ]; then
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
fi
mkinitcpio -P

# Bootloader
bootctl install
cat > /boot/loader/loader.conf <<LOADER
default arch.conf
timeout 3
console-mode max
LOADER

if [ '$USE_LUKS' = true ]; then
    CRYPT_OPT=\"cryptdevice=UUID=${LUKS_UUID}:cryptroot:allow-discards \"
else
    CRYPT_OPT=''
fi
ROOT_UUID=\$(findmnt -no UUID /)
cat > /boot/loader/entries/arch.conf <<BOOTEOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /${MICROCODE}.img
initrd  /initramfs-linux.img
options \${CRYPT_OPT}root=UUID=\${ROOT_UUID} rw quiet splash
BOOTEOF

# User
useradd -m -G wheel,video,audio,input,network -s /bin/bash $USERNAME
echo '$USERNAME:$PASSWORD' | chpasswd
echo 'root:$PASSWORD' | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Services
systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable fstrim.timer
systemctl enable greetd
systemctl enable ufw

# Laptop services
if [ '$IS_LAPTOP' = true ]; then
    systemctl enable power-profiles-daemon || true
    systemctl enable upower || true
fi

# Greetd
cat > /etc/greetd/config.toml <<GREETD
[terminal]
vt = 1

[default_session]
command = \"uwsm start hyprland-uwsm.desktop\"
user = \"$USERNAME\"
GREETD

# Logind - let hypridle handle lid
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/lid.conf <<LID
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
LID

# Intel graphics env
if [ '$GPU' = 'intel' ]; then
    echo 'LIBVA_DRIVER_NAME=iHD' > /etc/environment
fi

# UFW rules (will error in chroot but rules are saved)
ufw default deny incoming 2>/dev/null || true
ufw allow 22/tcp 2>/dev/null || true
ufw allow 53317 2>/dev/null || true
ufw --force enable 2>/dev/null || true
"

# --- AUR packages ---
info "Installing AUR helper and packages..."

# Temp passwordless sudo for AUR builds
echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" > /mnt/etc/sudoers.d/temp-aur

arch-chroot /mnt su - "$USERNAME" -c "
cd /tmp
git clone https://aur.archlinux.org/yay-bin.git
cd yay-bin && makepkg -si --noconfirm
cd /tmp && rm -rf yay-bin
yay -S --noconfirm librewolf-bin localsend-bin grimblast-git waypaper wvkbd rofi-power-menu catppuccin-gtk-theme-mocha
"

# Remove temp sudo
rm -f /mnt/etc/sudoers.d/temp-aur

# --- Chezmoi dotfiles ---
info "Setting up dotfiles with chezmoi..."

# Write chezmoi config for this machine
mkdir -p "/mnt/home/$USERNAME/.config/chezmoi"
cat > "/mnt/home/$USERNAME/.config/chezmoi/chezmoi.toml" <<CHEZCONF
[data]
    hostname = "$HOSTNAME"
    is_laptop = $IS_LAPTOP
    is_vm = $IS_VM
    monitor_name = "$MONITOR"
    monitor_scale = "$SCALE"
    gaps_inner = $GAPS_INNER
    gaps_outer = $GAPS_OUTER
    border_size = $BORDER
    gpu = "$GPU"
CHEZCONF

# Clone dotfiles and apply
arch-chroot /mnt su - "$USERNAME" -c "
chezmoi init --apply https://github.com/jkingston/dotfiles.git
"

# Fix ownership
chown -R 1000:1000 "/mnt/home/$USERNAME"

# --- Create wallpaper directory ---
mkdir -p "/mnt/home/$USERNAME/Pictures/Wallpapers"
mkdir -p "/mnt/home/$USERNAME/.config/hyprsunset"
echo "3500" > "/mnt/home/$USERNAME/.config/hyprsunset/temperature"
chown -R 1000:1000 "/mnt/home/$USERNAME/Pictures"
chown -R 1000:1000 "/mnt/home/$USERNAME/.config/hyprsunset"

# --- Done ---
info ""
info "============================================"
info "  Installation complete!"
info "============================================"
info ""
info "After reboot:"
info "  1. Connect to wifi: nmtui"
info "  2. Download wallpapers:"
info "     git clone https://github.com/Gingeh/wallpapers.git ~/Pictures/Wallpapers/catppuccin"
info "  3. Authenticate GitHub CLI: gh auth login"
info ""
info "Unmounting and ready to reboot."

umount -R /mnt
[ "$USE_LUKS" = true ] && cryptsetup close cryptroot

info "Remove the USB drive and reboot: reboot"
