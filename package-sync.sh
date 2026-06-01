#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=package-sets.sh
source "$SCRIPT_DIR/package-sets.sh"

ACTION="${1:-}"
PROFILE=""
CONFIRM=false
DRY_RUN=false

usage() {
    cat <<USAGE
Usage:
  $0 install [--profile framework12|minipc]
  $0 diff [--profile framework12|minipc]
  $0 clean --dry-run [--profile framework12|minipc]
  $0 clean --confirm [--profile framework12|minipc]

Notes:
  clean defaults to report-only and includes orphaned dependency packages.
USAGE
}

shift_action() {
    [ -n "$ACTION" ] || { usage; exit 1; }
    shift || true
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --profile)
                PROFILE="${2:-}"
                [ -n "$PROFILE" ] || error "--profile requires a value"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --confirm)
                CONFIRM=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error "Unknown argument: $1"
                ;;
        esac
    done
}

detect_platform() {
    case "$(uname -s)" in
        Linux)
            command -v pacman >/dev/null 2>&1 || error "Unsupported Linux system: pacman not found"
            printf '%s\n' arch
            ;;
        Darwin)
            printf '%s\n' macos
            ;;
        *)
            error "Unsupported OS: $(uname -s)"
            ;;
    esac
}

default_arch_profile() {
    local host
    host="$(hostname 2>/dev/null || true)"
    case "$host" in
        fw12) printf '%s\n' framework12 ;;
        minipc) printf '%s\n' minipc ;;
        *) printf '%s\n' minipc ;;
    esac
}

arch_microcode_for_profile() {
    case "$1" in
        framework12) printf '%s\n' intel-ucode ;;
        minipc) printf '%s\n' amd-ucode ;;
        *) error "Unknown Arch profile: $1" ;;
    esac
}

array_contains() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

arch_repo_package_array() {
    local profile="$1" microcode
    microcode="$(arch_microcode_for_profile "$profile")"
    mapfile -t ARCH_REPO_WANTED < <(arch_repo_packages "$profile" "$microcode" | sort -u)
}

arch_install_yay() {
    command -v yay >/dev/null 2>&1 && return
    info "Installing yay-bin AUR helper..."
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN
    git clone https://aur.archlinux.org/yay-bin.git "$tmpdir/yay-bin"
    (cd "$tmpdir/yay-bin" && makepkg -si --noconfirm)
}

arch_install() {
    local profile="$1"
    arch_repo_package_array "$profile"

    info "Installing Arch repository packages..."
    sudo pacman -Syu --needed --noconfirm "${ARCH_REPO_WANTED[@]}"

    arch_install_yay
    info "Installing AUR packages..."
    yay -S --needed --noconfirm "${ARCH_AUR_PACKAGES[@]}"

    info "Installing Flatpak apps..."
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    flatpak install --system -y flathub "${ARCH_FLATPAK_PACKAGES[@]}"
}

macos_install() {
    command -v brew >/dev/null 2>&1 || error "Homebrew is required. Install it from https://brew.sh/ and re-run this script."
    info "Installing Homebrew CLI packages..."
    brew install "${MACOS_BREW_PACKAGES[@]}"
}

print_missing() {
    local label="$1"
    shift
    local wanted=("$@")
    local pkg missing=0
    printf '%s\n' "$label"
    for pkg in "${wanted[@]}"; do
        if ! command -v "$CHECK_PACKAGE_FN" >/dev/null 2>&1; then
            return 1
        fi
        if ! "$CHECK_PACKAGE_FN" "$pkg"; then
            printf '  %s\n' "$pkg"
            missing=1
        fi
    done
    [ "$missing" -eq 1 ] || printf '  none\n'
}

check_arch_repo_pkg() { pacman -Q "$1" >/dev/null 2>&1; }
check_arch_aur_pkg() { pacman -Q "$1" >/dev/null 2>&1; }
check_arch_flatpak() { flatpak list --system --app --columns=application 2>/dev/null | grep -Fx "$1" >/dev/null 2>&1; }
check_brew_pkg() { brew list --formula "$1" >/dev/null 2>&1; }

arch_diff() {
    local profile="$1"
    arch_repo_package_array "$profile"
    CHECK_PACKAGE_FN=check_arch_repo_pkg print_missing "Missing Arch repository packages:" "${ARCH_REPO_WANTED[@]}"
    CHECK_PACKAGE_FN=check_arch_aur_pkg print_missing "Missing AUR packages:" "${ARCH_AUR_PACKAGES[@]}"
    CHECK_PACKAGE_FN=check_arch_flatpak print_missing "Missing Flatpak apps:" "${ARCH_FLATPAK_PACKAGES[@]}"
}

macos_diff() {
    command -v brew >/dev/null 2>&1 || error "Homebrew is required. Install it from https://brew.sh/ and re-run this script."
    CHECK_PACKAGE_FN=check_brew_pkg print_missing "Missing Homebrew packages:" "${MACOS_BREW_PACKAGES[@]}"
}

extras_from_lists() {
    local installed_file="$1"
    shift
    local allowed=("$@")
    local pkg
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        array_contains "$pkg" "${allowed[@]}" || printf '%s\n' "$pkg"
    done < "$installed_file"
}

print_or_remove() {
    local label="$1" remover="$2" extras_file="$3"
    local -a extras=()
    if [ ! -s "$extras_file" ]; then
        printf '%s\n  none\n' "$label"
        return
    fi

    printf '%s\n' "$label"
    sed 's/^/  /' "$extras_file"
    if [ "$ACTION" = clean ] && [ "$CONFIRM" = true ]; then
        mapfile -t extras < "$extras_file"
        case "$remover" in
            arch-repo) sudo pacman -Rns --noconfirm "${extras[@]}" ;;
            aur) yay -Rns --noconfirm "${extras[@]}" ;;
            orphan) sudo pacman -Rns --noconfirm "${extras[@]}" ;;
            flatpak) flatpak uninstall --system -y "${extras[@]}" ;;
            brew) brew uninstall "${extras[@]}" ;;
            *) error "Unknown remover: $remover" ;;
        esac
    fi
}

arch_clean() {
    local profile="$1" tmp explicit_all foreign_all explicit_repo aur flatpaks repo_extras aur_extras flatpak_extras orphans
    arch_repo_package_array "$profile"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    explicit_all="$tmp/explicit-all"
    foreign_all="$tmp/foreign-all"
    explicit_repo="$tmp/explicit-repo"
    aur="$tmp/aur"
    flatpaks="$tmp/flatpaks"
    repo_extras="$tmp/repo-extras"
    aur_extras="$tmp/aur-extras"
    flatpak_extras="$tmp/flatpak-extras"
    orphans="$tmp/orphans"

    pacman -Qqet | sort -u > "$explicit_all"
    pacman -Qqm 2>/dev/null | sort -u > "$foreign_all" || : > "$foreign_all"
    comm -23 "$explicit_all" "$foreign_all" > "$explicit_repo"
    comm -12 "$explicit_all" "$foreign_all" > "$aur"
    flatpak list --system --app --columns=application 2>/dev/null | sort -u > "$flatpaks" || : > "$flatpaks"
    pacman -Qqdt 2>/dev/null | sort -u > "$orphans" || : > "$orphans"

    extras_from_lists "$explicit_repo" "${ARCH_REPO_WANTED[@]}" "${ARCH_PROTECTED_PACKAGES[@]}" yay-bin > "$repo_extras"
    extras_from_lists "$aur" "${ARCH_AUR_PACKAGES[@]}" yay-bin "${ARCH_PROTECTED_PACKAGES[@]}" > "$aur_extras"
    extras_from_lists "$flatpaks" "${ARCH_FLATPAK_PACKAGES[@]}" > "$flatpak_extras"

    print_or_remove "Extra explicit Arch repository packages:" arch-repo "$repo_extras"
    print_or_remove "Extra AUR packages:" aur "$aur_extras"
    print_or_remove "Extra Flatpak apps:" flatpak "$flatpak_extras"
    print_or_remove "Orphaned dependency packages:" orphan "$orphans"
}

macos_clean() {
    command -v brew >/dev/null 2>&1 || error "Homebrew is required. Install it from https://brew.sh/ and re-run this script."
    local tmp leaves extras
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    leaves="$tmp/leaves"
    extras="$tmp/extras"

    brew leaves | sort -u > "$leaves"
    extras_from_lists "$leaves" "${MACOS_BREW_PACKAGES[@]}" "${MACOS_PROTECTED_PACKAGES[@]}" > "$extras"
    print_or_remove "Extra Homebrew leaves:" brew "$extras"
}

shift_action "$@"
PLATFORM="$(detect_platform)"

if [ "$PLATFORM" = arch ]; then
    PROFILE="${PROFILE:-$(default_arch_profile)}"
fi

case "$ACTION:$PLATFORM" in
    install:arch) arch_install "$PROFILE" ;;
    install:macos) macos_install ;;
    diff:arch) arch_diff "$PROFILE" ;;
    diff:macos) macos_diff ;;
    clean:arch)
        if [ "$CONFIRM" != true ]; then
            DRY_RUN=true
        fi
        [ "$DRY_RUN" = true ] || [ "$CONFIRM" = true ] || error "clean requires --dry-run or --confirm"
        [ "$CONFIRM" = true ] || warn "Report-only cleanup. Re-run with clean --confirm to remove these packages."
        arch_clean "$PROFILE"
        ;;
    clean:macos)
        if [ "$CONFIRM" != true ]; then
            DRY_RUN=true
        fi
        [ "$DRY_RUN" = true ] || [ "$CONFIRM" = true ] || error "clean requires --dry-run or --confirm"
        [ "$CONFIRM" = true ] || warn "Report-only cleanup. Re-run with clean --confirm to remove these packages."
        macos_clean
        ;;
    *)
        usage
        exit 1
        ;;
esac
