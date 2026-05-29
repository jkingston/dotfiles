#!/usr/bin/env bash
set -euo pipefail

# Automated QEMU VM test for the Arch Linux installer
# Prerequisites: brew install qemu expect
# Usage: ./test-vm.sh <profile> [--keep-disk]
#
# Example:
#   ./test-vm.sh framework12 --keep-disk

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[TEST]${NC} $*"; }
warn() { echo -e "${YELLOW}[TEST]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }

PROFILE="${1:-}"
DESKTOP="hyprland"
KEEP_DISK=false
[[ "${2:-}" == "--keep-disk" ]] && KEEP_DISK=true

if [ -z "$PROFILE" ]; then
    echo "Usage: $0 <profile> [--keep-disk]"
    echo "  profile: framework12, minipc"
    exit 1
fi

if [ $# -gt 2 ] || { [ $# -eq 2 ] && [ "${2:-}" != "--keep-disk" ]; }; then
    echo "Desktop selection has been removed; only hyprland is supported"
    echo "Usage: $0 <profile> [--keep-disk]"
    exit 1
fi

CACHE_DIR="${TEST_CACHE_DIR:-$HOME/.cache/dotfiles-test}"
DISK_IMG="/tmp/dotfiles-test-${PROFILE}-${DESKTOP}.qcow2"
DISK_SIZE="20G"
VM_RAM="4096"
VM_CPUS="2"
VM_PASSWORD="testpass"
SSH_PORT="${TEST_SSH_PORT:-2222}"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

QEMU_CMD="qemu-system-x86_64"
EXPECT_CMD="expect"

# --- Check prerequisites ---
for cmd in "$QEMU_CMD" "$EXPECT_CMD" qemu-img curl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Missing: $cmd"
        echo "Install with: brew install qemu expect"
        exit 1
    fi
done

# Detect UEFI firmware path
OVMF_CODE=""
for path in \
    /opt/homebrew/share/qemu/edk2-x86_64-code.fd \
    /usr/local/share/qemu/edk2-x86_64-code.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/edk2/x64/OVMF_CODE.fd; do
    if [ -f "$path" ]; then
        OVMF_CODE="$path"
        break
    fi
done
[ -z "$OVMF_CODE" ] && { echo "UEFI firmware not found. Install qemu with: brew install qemu"; exit 1; }

# Detect acceleration
ACCEL="tcg"
if "$QEMU_CMD" -accel help 2>/dev/null | grep -q '^hvf$'; then
    ACCEL="hvf"
fi

# --- Download Arch ISO ---
mkdir -p "$CACHE_DIR"
MIRROR="https://geo.mirror.pkgbuild.com/iso/latest"

get_latest_iso() {
    local iso_name
    iso_name=$(curl -sL "$MIRROR/" | grep -oE 'archlinux-[0-9]{4}\.[0-9]{2}\.[0-9]{2}-x86_64\.iso' | head -1)
    if [ -z "$iso_name" ] && curl -fsI "$MIRROR/archlinux-x86_64.iso" >/dev/null; then
        iso_name="archlinux-x86_64.iso"
    fi
    echo "$iso_name"
}

ISO_NAME=$(get_latest_iso)
if [ -z "$ISO_NAME" ]; then
    # Fall back to any cached ISO
    ISO_NAME=$(find "$CACHE_DIR" -maxdepth 1 -name 'archlinux-*.iso' -print 2>/dev/null | head -1 | xargs basename 2>/dev/null || true)
    [ -z "$ISO_NAME" ] && { echo "Could not determine Arch ISO name and no cached ISO found"; exit 1; }
    warn "Using cached ISO: $ISO_NAME"
fi

ISO_PATH="$CACHE_DIR/$ISO_NAME"
if [ ! -f "$ISO_PATH" ]; then
    info "Downloading $ISO_NAME..."
    curl -L -o "$ISO_PATH.part" "$MIRROR/$ISO_NAME"
    mv "$ISO_PATH.part" "$ISO_PATH"
    info "Downloaded."
else
    info "Using cached ISO: $ISO_NAME"
fi

ISO_UUID=$(bsdtar -tf "$ISO_PATH" | sed -n 's#^boot/\(.*\)\.uuid$#\1#p' | head -1)
[ -z "$ISO_UUID" ] && { echo "Could not determine Arch ISO UUID"; exit 1; }
KERNEL_PATH="$CACHE_DIR/${ISO_NAME%.iso}-vmlinuz-linux"
INITRD_PATH="$CACHE_DIR/${ISO_NAME%.iso}-initramfs-linux.img"
if [ ! -f "$KERNEL_PATH" ] || [ ! -f "$INITRD_PATH" ]; then
    info "Extracting kernel and initramfs..."
    bsdtar -xOf "$ISO_PATH" arch/boot/x86_64/vmlinuz-linux > "$KERNEL_PATH"
    bsdtar -xOf "$ISO_PATH" arch/boot/x86_64/initramfs-linux.img > "$INITRD_PATH"
fi

# --- Create disk image ---
info "Creating ${DISK_SIZE} disk image..."
qemu-img create -f qcow2 "$DISK_IMG" "$DISK_SIZE" >/dev/null

# --- Prepare expect script ---
EXPECT_SCRIPT=$(mktemp /tmp/dotfiles-test-expect.XXXXXX)
trap 'rm -f "$EXPECT_SCRIPT"; [ "$KEEP_DISK" = false ] && rm -f "$DISK_IMG"' EXIT

cat > "$EXPECT_SCRIPT" <<'EXPECTEOF'
#!/usr/bin/env expect -f

set timeout 600
set profile [lindex $argv 0]
set desktop [lindex $argv 1]
set password [lindex $argv 2]
set ssh_port [lindex $argv 3]
set qemu [lindex $argv 4]
set sep [lsearch -exact $argv "--"]
if { $sep < 0 } {
    puts "\n\[FAIL\] Missing QEMU argument separator"
    exit 1
}
set install_qemu_args [lrange $argv 5 [expr {$sep - 1}]]
set boot_qemu_args [lrange $argv [expr {$sep + 1}] end]

log_user 1

proc expect_marker {marker desc} {
    expect {
        -re $marker {}
        eof {
            puts "\n\[FAIL\] QEMU exited while waiting for $desc"
            exit 1
        }
        timeout {
            puts "\n\[FAIL\] Timed out waiting for $desc"
            exit 1
        }
    }
}

# Start QEMU and drive its serial console.
spawn $qemu {*}$install_qemu_args

# Wait for the Arch live ISO to boot to a root prompt
expect {
    "archiso login:" {
        send "root\r"
        expect_marker {# } "root shell prompt"
    }
    -re {# } {}
    eof {
        puts "\n\[FAIL\] QEMU exited before Arch ISO booted"
        exit 1
    }
    timeout {
        puts "\n\[FAIL\] Timed out waiting for Arch ISO boot"
        exit 1
    }
}

puts "\n\[TEST\] Arch ISO booted. Setting up install..."
sleep 2

# Mount the 9p shared repo
send "mkdir -p /dotfiles && mount -t 9p -o trans=virtio dotfiles /dotfiles && echo MOUNT_OK\r"
expect_marker {MOUNT_OK} "repo mount"
sleep 1

# Run the installer in unattended mode
send "export UNATTENDED=1 PASSWORD=$password INSTALL_DISK=/dev/vda INSTALL_SERIAL=1 DOTFILES_SOURCE=/dotfiles; echo ENV_OK\r"
expect_marker {ENV_OK} "installer environment"
send "/dotfiles/install.sh $profile\r"

# Wait for installation to complete (can take 10+ minutes)
set timeout 1800
expect {
    "Installation complete!" {
        puts "\n\[PASS\] Installation completed successfully"
    }
    "ERROR" {
        puts "\n\[FAIL\] Installation failed"
        exit 1
    }
    eof {
        puts "\n\[FAIL\] QEMU exited during installation"
        exit 1
    }
    timeout {
        puts "\n\[FAIL\] Installation timed out (30 min)"
        exit 1
    }
}

# Give it a moment, then power off. The install boot uses the live ISO kernel
# directly, so smoke tests need a fresh QEMU process that boots from disk.
sleep 3
send "poweroff\r"
expect {
    eof {}
    timeout {
        puts "\n\[FAIL\] Timed out waiting for install VM poweroff"
        exit 1
    }
}

puts "\n\[TEST\] Booting installed system..."
spawn $qemu {*}$boot_qemu_args

# Wait for the installed system to boot
set timeout 900
expect {
    -re {Enter passphrase for .*:} {
        sleep 1
        send -- "$password\r\n"
        exp_continue
    }
    -re {A password is required to access .*:} {
        sleep 1
        send -- "$password\r\n"
        exp_continue
    }
    "login:" {
        puts "\n\[TEST\] System rebooted to login prompt"
    }
    eof {
        puts "\n\[FAIL\] QEMU exited before reboot completed"
        exit 1
    }
    timeout {
        puts "\n\[FAIL\] Timed out waiting for reboot"
        exit 1
    }
}

# Log in
sleep 2
send "jack\r"
expect "Password:"
send "$password\r"
sleep 2
send "echo LOGIN_OK\r"
expect_marker {LOGIN_OK} "user login shell"

puts "\n\[TEST\] Logged in. Running smoke tests..."
sleep 2

# --- Smoke tests ---
set failures 0

proc check {desc cmd} {
    upvar failures f
    send "$cmd >/tmp/dotfiles-check.out 2>&1; rc=\$?; cat /tmp/dotfiles-check.out; echo __CHECK_STATUS__\$rc; echo __CHECK_DONE__\r"
    expect {
        -re {__CHECK_STATUS__([0-9]+)} {
            if { $expect_out(1,string) eq "0" } {
                puts "\[PASS\] $desc"
            } else {
                puts "\[FAIL\] $desc"
                incr f
            }
        }
        timeout {
            puts "\[FAIL\] $desc"
            incr f
        }
    }
    expect_marker {__CHECK_DONE__} "$desc completion"
}

check "chezmoi initialized" "test -f ~/.config/chezmoi/chezmoi.toml && test -d ~/.local/share/chezmoi"
check "ghostty installed" "pacman -Q ghostty"
check "neovim installed" "pacman -Q neovim"
check "starship installed" "pacman -Q starship"
check "mise installed" "pacman -Q mise"
check "plymouth installed" "pacman -Q plymouth"
check "plymouth initramfs hook configured" "grep -Eq '^HOOKS=.*plymouth' /etc/mkinitcpio.conf"
check "bashrc exists" "test -f ~/.bashrc"
check "bashrc managed by chezmoi" "grep -F 'starship init bash' ~/.bashrc"
check "ghostty config exists" "test -f ~/.config/ghostty/config"
check "starship config exists" "test -f ~/.config/starship/starship.toml"
check "gitconfig exists" "test -f ~/.gitconfig"
check "boot partition private" "findmnt -no OPTIONS /boot | grep -Eq '(^|,)fmask=0077(,|$)' && findmnt -no OPTIONS /boot | grep -Eq '(^|,)dmask=0077(,|$)'"
check "NetworkManager active" "systemctl is-active NetworkManager"
check "bluetooth enabled" "systemctl is-enabled bluetooth"

# Desktop-specific checks
if { $desktop eq "hyprland" } {
    check "greetd enabled" "systemctl is-enabled greetd"
    check "greetd starts arch hyprland desktop entry" "grep -F 'command = \"uwsm start hyprland.desktop\"' /etc/greetd/config.toml"
    check "hyprland installed" "pacman -Q hyprland"
    check "waybar installed" "pacman -Q waybar"
    check "hyprlock installed" "pacman -Q hyprlock"
    check "hypridle installed" "pacman -Q hypridle"
    check "hyprsunset installed" "pacman -Q hyprsunset"
    check "sunwait installed" "pacman -Q sunwait"
    check "rofi-wayland installed" "pacman -Q rofi-wayland"
    check "rofi-calc installed" "pacman -Q rofi-calc"
    check "rofi-power-menu installed" "pacman -Q rofi-power-menu"
    check "mako installed" "pacman -Q mako"
    check "swayosd installed" "pacman -Q swayosd"
    check "wl-clipboard installed" "pacman -Q wl-clipboard"
    check "cliphist installed" "pacman -Q cliphist"
    check "swww installed" "pacman -Q swww"
    check "waypaper installed" "pacman -Q waypaper"
    check "wvkbd installed" "pacman -Q wvkbd"
    check "hyprpicker installed" "pacman -Q hyprpicker"
    check "grimblast installed" "pacman -Q grimblast-git"
    check "playerctl installed" "pacman -Q playerctl"
    check "brightnessctl installed" "pacman -Q brightnessctl"
    check "bluetui installed" "pacman -Q bluetui"
    check "pulsemixer installed" "pacman -Q pulsemixer"
    check "impala installed" "pacman -Q impala"
    check "bc installed for coordinate parsing" "pacman -Q bc"
    check "libnotify installed for applet notifications" "pacman -Q libnotify"
    check "hyprland config exists" "test -f ~/.config/hypr/hyprland.conf"
    check "hypridle config exists" "test -f ~/.config/hypr/hypridle.conf"
    check "hyprlock config exists" "test -f ~/.config/hypr/hyprlock.conf"
    check "mako config exists" "test -f ~/.config/mako/config"
    check "rofi config exists" "test -f ~/.config/rofi/config.rasi"
    check "waypaper config exists" "test -f ~/.config/waypaper/config.ini"
    check "hyprland starts waybar" "grep -F 'exec-once = uwsm app -- waybar' ~/.config/hypr/hyprland.conf"
    check "hyprland starts mako" "grep -F 'exec-once = uwsm app -- mako' ~/.config/hypr/hyprland.conf"
    check "hyprland starts swayosd" "grep -F 'exec-once = uwsm app -- swayosd-server' ~/.config/hypr/hyprland.conf"
    check "hyprland starts clipboard text history" "grep -F 'exec-once = wl-paste --watch cliphist store' ~/.config/hypr/hyprland.conf"
    check "hyprland starts clipboard image history" "grep -F 'exec-once = wl-paste --type image --watch cliphist store' ~/.config/hypr/hyprland.conf"
    check "hyprland starts wallpaper daemon" "grep -F 'exec-once = swww-daemon && ~/.local/bin/wallpaper-random' ~/.config/hypr/hyprland.conf"
    check "hyprland enables environment timers" "grep -F 'exec-once = systemctl --user daemon-reload && systemctl --user enable --now hyprsunset-check.timer wallpaper-rotate.timer' ~/.config/hypr/hyprland.conf"
    check "hyprland applies nightlight on session start" "grep -F 'exec-once = ~/.local/bin/hyprsunset-apply' ~/.config/hypr/hyprland.conf"
    check "hyprland super bind exists" "grep -F 'bind = \$mod, RETURN, exec, uwsm app -- ghostty' ~/.config/hypr/hyprland.conf"
    check "hyprland launcher bind exists" "grep -F 'bind = \$mod, SPACE, exec, uwsm app -- rofi -show drun' ~/.config/hypr/hyprland.conf"
    check "hyprland clipboard bind exists" "grep -F 'bind = \$mod_ctrl, V, exec, ~/.local/bin/rofi-clipboard' ~/.config/hypr/hyprland.conf"
    check "hyprland lock bind exists" "grep -F 'bind = \$mod_ctrl, I, exec, hyprlock' ~/.config/hypr/hyprland.conf"
    check "hyprland screenshot bind exists" "grep -F 'bind = , Print, exec, grimblast edit area' ~/.config/hypr/hyprland.conf"
    check "hyprland colour picker bind exists" "grep -F 'bind = \$mod, Print, exec, hyprpicker -a' ~/.config/hypr/hyprland.conf"
    check "hyprland wallpaper bind exists" "grep -F 'bind = \$mod_alt, W, exec, ~/.local/bin/wallpaper-random' ~/.config/hypr/hyprland.conf"
    check "hyprland keybind help bind exists" "grep -F 'bind = \$mod, slash, exec, ~/.local/bin/keybind-help' ~/.config/hypr/hyprland.conf"
    check "hyprland power menu bind exists" "grep -F 'bind = \$mod, ESCAPE, exec, uwsm app -- ~/.local/bin/hypr-power-menu' ~/.config/hypr/hyprland.conf"
    check "hyprland media keys use swayosd" "grep -F 'swayosd-client --output-volume raise' ~/.config/hypr/hyprland.conf"
    check "hyprland media keys use playerctl" "grep -F 'playerctl play-pause' ~/.config/hypr/hyprland.conf"
    check "hypridle locks before suspend" "grep -F 'before_sleep_cmd = loginctl lock-session' ~/.config/hypr/hypridle.conf"
    check "hypridle starts hyprlock once" "grep -F 'lock_cmd = pidof hyprlock || hyprlock' ~/.config/hypr/hypridle.conf"
    check "hypridle reapplies nightlight after wake" "grep -F '~/.local/bin/hyprsunset-apply' ~/.config/hypr/hypridle.conf"
    check "hypridle locks after idle timeout" "grep -F 'timeout = 300' ~/.config/hypr/hypridle.conf"
    check "hypridle turns display off after lock" "grep -F 'timeout = 330' ~/.config/hypr/hypridle.conf"
    check "hypridle suspends later" "grep -F 'systemctl suspend' ~/.config/hypr/hypridle.conf"
    check "hyprlock uses screenshot background" "grep -F 'path = screenshot' ~/.config/hypr/hyprlock.conf"
    check "hyprlock blurs background" "grep -F 'blur_passes = 3' ~/.config/hypr/hyprlock.conf"
    check "hyprlock hides cursor" "grep -F 'hide_cursor = true' ~/.config/hypr/hyprlock.conf"
    check "hyprsunset config directory exists" "test -d ~/.config/hyprsunset"
    check "hyprsunset default temperature exists" "grep -Fx '3500' ~/.config/hyprsunset/temperature"
    check "hyprsunset default mode exists" "grep -Fx 'auto' ~/.config/hyprsunset/mode"
    check "hyprsunset toggle script executable" "test -x ~/.local/bin/hyprsunset-toggle"
    check "hyprsunset apply script executable" "test -x ~/.local/bin/hyprsunset-apply"
    check "hyprsunset status script executable" "test -x ~/.local/bin/hyprsunset-status"
    check "hyprsunset temp picker executable" "test -x ~/.local/bin/hyprsunset-temp-picker"
    check "hyprsunset coords script executable" "test -x ~/.local/bin/hyprsunset-coords"
    check "hyprsunset settings script executable" "test -x ~/.local/bin/hyprsunset-settings"
    check "arch updates check script executable" "test -x ~/.local/bin/arch-updates-check"
    check "arch update menu script executable" "test -x ~/.local/bin/arch-update-menu"
    check "arch update script executable" "test -x ~/.local/bin/arch-update"
    check "sysmon script executable" "test -x ~/.local/bin/waybar-sysmon"
    check "wallpaper random script executable" "test -x ~/.local/bin/wallpaper-random"
    check "osk toggle script executable" "test -x ~/.local/bin/osk-toggle"
    check "clipboard picker script executable" "test -x ~/.local/bin/rofi-clipboard"
    check "keybind help script executable" "test -x ~/.local/bin/keybind-help"
    check "power menu script executable" "test -x ~/.local/bin/hypr-power-menu"
    check "power menu lock action uses hyprlock" "grep -F 'pidof hyprlock >/dev/null 2>&1 || hyprlock' ~/.local/bin/hypr-power-menu"
    check "waybar nightlight module configured" "grep -F '\"custom/nightlight\"' ~/.config/waybar/config"
    check "waybar nightlight returns json" "grep -F '\"return-type\": \"json\"' ~/.config/waybar/config"
    check "waybar nightlight status command configured" "grep -F '\"exec\": \"~/.local/bin/hyprsunset-status\"' ~/.config/waybar/config"
    check "waybar nightlight left click configured" "grep -F '\"on-click\": \"~/.local/bin/hyprsunset-toggle\"' ~/.config/waybar/config"
    check "waybar nightlight right click configured" "grep -F '\"on-click-right\": \"~/.local/bin/hyprsunset-settings\"' ~/.config/waybar/config"
    check "waybar nightlight signal configured" "grep -F '\"signal\": 10' ~/.config/waybar/config"
    check "waybar updates module configured" "grep -F '\"custom/updates\"' ~/.config/waybar/config"
    check "waybar updates command configured" "grep -F '\"exec\": \"~/.local/bin/arch-updates-check\"' ~/.config/waybar/config"
    check "waybar updates menu configured" "grep -F '\"on-click-right\": \"~/.local/bin/arch-update-menu\"' ~/.config/waybar/config"
    check "waybar updates signal configured" "grep -F '\"signal\": 12' ~/.config/waybar/config"
    check "waybar sysmon module configured" "grep -F '\"custom/sysmon\"' ~/.config/waybar/config"
    check "waybar sysmon command configured" "grep -F '\"exec\": \"~/.local/bin/waybar-sysmon\"' ~/.config/waybar/config"
    check "waybar idle inhibitor configured" "grep -F '\"idle_inhibitor\"' ~/.config/waybar/config"
    check "waybar bluetooth applet configured" "grep -F '\"on-click\": \"ghostty --class=com.floating.tui -e bluetui\"' ~/.config/waybar/config"
    check "waybar network applet configured" "grep -F '\"on-click\": \"ghostty --class=com.floating.tui -e impala\"' ~/.config/waybar/config"
    check "waybar audio applet configured" "grep -F '\"on-click\": \"ghostty --class=com.floating.tui -e pulsemixer\"' ~/.config/waybar/config"
    check "waybar battery opens power menu" "grep -F '\"on-click\": \"~/.local/bin/hypr-power-menu\"' ~/.config/waybar/config"
    check "hyprsunset user service installed" "test -f ~/.config/systemd/user/hyprsunset-check.service"
    check "hyprsunset user timer installed" "test -f ~/.config/systemd/user/hyprsunset-check.timer"
    check "hyprsunset user timer enabled" "systemctl --user is-enabled hyprsunset-check.timer"
    check "wallpaper rotate service installed" "test -f ~/.config/systemd/user/wallpaper-rotate.service"
    check "wallpaper rotate timer installed" "test -f ~/.config/systemd/user/wallpaper-rotate.timer"
    check "wallpaper checkout populated images" "find ~/Pictures/Wallpapers -type f \\( -name '*.jpg' -o -name '*.jpeg' -o -name '*.png' -o -name '*.webp' \\) -print -quit | grep -q ."
    check "wallpaper sync service absent" "test ! -f ~/.config/systemd/user/wallpaper-sync.service"
    check "wallpaper sync timer absent" "test ! -f ~/.config/systemd/user/wallpaper-sync.timer"
    check "hyprsunset coords command runs" "~/.local/bin/hyprsunset-coords | grep -Eq '^\[.0-9]+\[NS] \[.0-9]+\[EW]$'"
    check "hyprsunset status emits waybar json" "~/.local/bin/hyprsunset-status | jq -e 'has(\"text\") and has(\"tooltip\")'"
    check "waybar sysmon emits waybar json" "~/.local/bin/waybar-sysmon | jq -e 'has(\"text\") and has(\"tooltip\")'"
}

# Print summary
if { $failures > 0 } {
    puts "\n\[FAIL\] $failures test(s) failed"
    exit 1
} else {
    puts "\n\[PASS\] All tests passed"
    exit 0
}
EXPECTEOF

chmod +x "$EXPECT_SCRIPT"

# --- Launch QEMU with expect driving the serial console ---
info "Launching QEMU VM (profile=$PROFILE, desktop=$DESKTOP, accel=$ACCEL)..."
info "This will take 10-30 minutes depending on network speed."
echo ""

# Build QEMU command
NIC_ARG="user,model=virtio-net-pci"
if [ "$SSH_PORT" != "0" ]; then
    NIC_ARG="${NIC_ARG},hostfwd=tcp::${SSH_PORT}-:22"
fi

QEMU_ARGS=(
    -machine q35
    -accel "$ACCEL"
    -m "$VM_RAM"
    -smp "$VM_CPUS"
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
    -drive "file=$DISK_IMG,format=qcow2,if=virtio"
    -cdrom "$ISO_PATH"
    -kernel "$KERNEL_PATH"
    -initrd "$INITRD_PATH"
    -append "archisobasedir=arch archisosearchuuid=$ISO_UUID console=ttyS0,115200n8"
    -nic "$NIC_ARG"
    -nographic
    -virtfs "local,path=$REPO_DIR,mount_tag=dotfiles,security_model=mapped-xattr"
)

BOOT_QEMU_ARGS=(
    -machine q35
    -accel "$ACCEL"
    -m "$VM_RAM"
    -smp "$VM_CPUS"
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
    -drive "file=$DISK_IMG,format=qcow2,if=virtio"
    -nic "$NIC_ARG"
    -nographic
)

# Run expect as the controller for QEMU's serial console.
"$EXPECT_CMD" "$EXPECT_SCRIPT" "$PROFILE" "$DESKTOP" "$VM_PASSWORD" "$SSH_PORT" "$QEMU_CMD" "${QEMU_ARGS[@]}" -- "${BOOT_QEMU_ARGS[@]}" &
EXPECT_PID=$!

cleanup() {
    local status=$?

    if kill -0 "$EXPECT_PID" 2>/dev/null; then
        kill "$EXPECT_PID" 2>/dev/null || true
    fi

    rm -f "$EXPECT_SCRIPT"
    if [ "$KEEP_DISK" = false ]; then
        rm -f "$DISK_IMG"
    fi

    return "$status"
}

handle_signal() {
    cleanup
    exit 130
}

trap cleanup EXIT
trap handle_signal INT TERM

wait $EXPECT_PID
EXIT_CODE=$?

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    info "VM test completed successfully."
    if [ "$KEEP_DISK" = true ]; then
        info "Disk image kept at: $DISK_IMG"
        info "Boot manually: qemu-system-x86_64 -machine q35 -accel $ACCEL -m $VM_RAM -drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE -drive file=$DISK_IMG,format=qcow2,if=virtio -nic user,model=virtio-net-pci -display cocoa"
    fi
else
    fail "VM test failed with exit code $EXIT_CODE"
fi

exit $EXIT_CODE
