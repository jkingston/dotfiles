#!/usr/bin/env bash
set -euo pipefail

# Automated QEMU VM test for the Arch Linux installer
# Prerequisites: brew install qemu expect
# Usage: ./test-vm.sh <profile> <desktop> [--keep-disk]
#
# Example:
#   ./test-vm.sh framework12 gnome
#   ./test-vm.sh framework12 hyprland --keep-disk

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[TEST]${NC} $*"; }
warn() { echo -e "${YELLOW}[TEST]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }

PROFILE="${1:-}"
DESKTOP="${2:-hyprland}"
KEEP_DISK=false
[[ "${3:-}" == "--keep-disk" ]] && KEEP_DISK=true

if [ -z "$PROFILE" ]; then
    echo "Usage: $0 <profile> [desktop] [--keep-disk]"
    echo "  profile: framework12, minipc"
    echo "  desktop: hyprland (default), gnome"
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
send "/dotfiles/install.sh $profile $desktop\r"

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

proc check {desc cmd expected} {
    upvar failures f
    send "$cmd; echo __CHECK_DONE__\r"
    expect {
        -re $expected {
            puts "\[PASS\] $desc"
        }
        timeout {
            puts "\[FAIL\] $desc"
            incr f
        }
    }
    expect_marker {__CHECK_DONE__} "$desc completion"
}

check "chezmoi applied" "chezmoi verify && echo CHEZMOI_OK" "CHEZMOI_OK"
check "ghostty installed" "pacman -Q ghostty && echo PKG_OK" "PKG_OK"
check "starship installed" "pacman -Q starship && echo PKG_OK" "PKG_OK"
check "bashrc exists" "test -f ~/.bashrc && echo FILE_OK" "FILE_OK"
check "NetworkManager active" "systemctl is-active NetworkManager" "active"
check "bluetooth active" "systemctl is-active bluetooth" "active"

# Desktop-specific checks
if { $desktop eq "gnome" } {
    check "gdm enabled" "systemctl is-enabled gdm" "enabled"
    check "gnome-shell installed" "pacman -Q gnome-shell && echo PKG_OK" "PKG_OK"
    check "gnome-tweaks installed" "pacman -Q gnome-tweaks && echo PKG_OK" "PKG_OK"
    check "dconf config exists" "test -f ~/.config/dconf/user.conf && echo FILE_OK" "FILE_OK"
} elseif { $desktop eq "hyprland" } {
    check "greetd enabled" "systemctl is-enabled greetd" "enabled"
    check "hyprland installed" "pacman -Q hyprland && echo PKG_OK" "PKG_OK"
    check "waybar installed" "pacman -Q waybar && echo PKG_OK" "PKG_OK"
    check "hyprland config exists" "test -f ~/.config/hypr/hyprland.conf && echo FILE_OK" "FILE_OK"
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

# Forward signals to clean up
trap 'kill $EXPECT_PID 2>/dev/null; rm -f "$EXPECT_SCRIPT"; [ "$KEEP_DISK" = false ] && rm -f "$DISK_IMG"' EXIT INT TERM

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
