#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:---all}"

TOTAL=0
FAILED=0
CURRENT_GROUP=""

group() {
  CURRENT_GROUP="$1"
  printf '\n%s\n' "$CURRENT_GROUP"
}

pass() {
  TOTAL=$((TOTAL + 1))
  printf '  [PASS] %s\n' "$1"
}

fail() {
  TOTAL=$((TOTAL + 1))
  FAILED=$((FAILED + 1))
  printf '  [FAIL] %s\n' "$1"
  if [ -n "${2:-}" ]; then
    printf '         %s\n' "$2"
  fi
}

assert_file_exists() {
  [ -e "$1" ]
}

assert_file_absent() {
  [ ! -e "$1" ]
}

assert_log_contains() {
  local pattern="$1"
  grep -F -- "$pattern" "$FAKE_LOG" >/dev/null 2>&1
}

assert_log_not_contains() {
  local pattern="$1"
  ! grep -F -- "$pattern" "$FAKE_LOG" >/dev/null 2>&1
}

assert_repo_contains() {
  local file="$1"
  local pattern="$2"
  grep -F -- "$pattern" "$ROOT_DIR/$file" >/dev/null 2>&1
}

run_case() {
  local name="$1"
  shift
  reset_case
  if "$@"; then
    pass "$name"
  else
    fail "$name" "See ${FAKE_LOG#$ROOT_DIR/} for the command trace from the last case."
  fi
}

make_fake_bin() {
  local bin="$1"
  local body="$2"
  printf '%s\n' "$body" > "$FAKE_BIN/$bin"
  chmod +x "$FAKE_BIN/$bin"
}

setup_case() {
  TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/hyprsunset-tests.XXXXXX")"
  TEST_HOME="$TEST_TMP/home"
  FAKE_BIN="$TEST_TMP/bin"
  FAKE_LOG="$TEST_TMP/fake.log"
  ROFI_QUEUE="$TEST_TMP/rofi.queue"
  mkdir -p "$TEST_HOME/.config/hyprsunset" "$TEST_HOME/.local/bin" "$TEST_HOME/Pictures/Wallpapers" "$FAKE_BIN"
  : > "$FAKE_LOG"
  echo 3500 > "$TEST_HOME/.config/hyprsunset/temperature"
  echo auto > "$TEST_HOME/.config/hyprsunset/mode"
  touch "$TEST_HOME/Pictures/Wallpapers/test.png"

  cat > "$TEST_HOME/.local/bin/hyprsunset-coords" <<'SH'
#!/usr/bin/env bash
echo "51.5N 0.1W"
SH
  chmod +x "$TEST_HOME/.local/bin/hyprsunset-coords"
  cp "$ROOT_DIR/dot_local/bin/executable_hyprsunset-apply" "$TEST_HOME/.local/bin/hyprsunset-apply"
  chmod +x "$TEST_HOME/.local/bin/hyprsunset-apply"

  make_fake_bin hyprsunset '#!/usr/bin/env bash
printf "hyprsunset %s\n" "$*" >> "$FAKE_LOG"
'
  make_fake_bin notify-send '#!/usr/bin/env bash
printf "notify-send %s\n" "$*" >> "$FAKE_LOG"
'
  make_fake_bin pkill '#!/usr/bin/env bash
printf "pkill %s\n" "$*" >> "$FAKE_LOG"
if [ "${FAKE_PKILL_FAIL_WAYBAR:-0}" = "1" ] && printf "%s\n" "$*" | grep -F "waybar" >/dev/null 2>&1; then
  exit 1
fi
exit 0
'
  make_fake_bin pgrep '#!/usr/bin/env bash
printf "pgrep %s\n" "$*" >> "$FAKE_LOG"
if [ "${FAKE_PGREP_MATCH:-}" = "${*: -1}" ]; then
  echo 1234
  exit 0
fi
exit 1
'
  make_fake_bin sunwait '#!/usr/bin/env bash
printf "sunwait %s\n" "$*" >> "$FAKE_LOG"
if [ "${1:-}" = "poll" ]; then
  echo "${FAKE_SUNWAIT_POLL:-DAY}"
elif [ "${1:-}" = "report" ]; then
  printf "%s\n" "${FAKE_SUNWAIT_REPORT:-Day with twilight: 08:03 to 16:03}"
fi
'
  make_fake_bin timedatectl '#!/usr/bin/env bash
if [ "${FAKE_TIME_DATE_CTL_FAIL:-0}" = "1" ]; then
  exit 1
fi
echo "${FAKE_TIMEZONE:-Europe/London}"
'
  make_fake_bin rofi '#!/usr/bin/env bash
printf "rofi %s\n" "$*" >> "$FAKE_LOG"
stdin="$(cat)"
if [ -n "$stdin" ]; then
  printf "rofi-stdin %s\n" "$stdin" >> "$FAKE_LOG"
fi
if [ ! -s "$ROFI_QUEUE" ]; then
  exit 1
fi
args="$*"
selected_row=0
on_selection_changed=""
while [ "$#" -gt 0 ]; do
  case "${1:-}" in
    -selected-row)
      selected_row="${2:-0}"
      shift 2
      ;;
    -on-selection-changed)
      on_selection_changed="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
max_row="$(printf "%s\n" "$stdin" | /usr/bin/awk '\''END { if (NR > 0) print NR - 1; else print 0 }'\'')"

run_selection_changed() {
  [ -n "$on_selection_changed" ] || return 0
  entry="$(printf "%s\n" "$stdin" | sed -n "$((selected_row + 1))p")"
  [ -n "$entry" ] || return 0
  printf "rofi-on-selection %s\n" "$entry" >> "$FAKE_LOG"
  cmd="${on_selection_changed//\{entry\}/$entry}"
  eval "$cmd"
}

if [ "${FAKE_ROFI_INITIAL_SELECTION_FIRST:-0}" = "1" ]; then
  requested_selected_row="$selected_row"
  selected_row=0
  run_selection_changed
  selected_row="$requested_selected_row"
  run_selection_changed
fi

while [ -s "$ROFI_QUEUE" ]; do
  line="$(sed -n "1p" "$ROFI_QUEUE")"
  sed -n "2,\$p" "$ROFI_QUEUE" > "$ROFI_QUEUE.next"
  mv "$ROFI_QUEUE.next" "$ROFI_QUEUE"

  case "$line" in
    __ESC__)
      exit 1
      ;;
    __DOWN__)
      if [ "$selected_row" -lt "$max_row" ]; then
        selected_row="$((selected_row + 1))"
      fi
      run_selection_changed
      ;;
    __UP__)
      if [ "$selected_row" -gt 0 ]; then
        selected_row="$((selected_row - 1))"
      fi
      run_selection_changed
      ;;
    __ENTER__)
      printf "%s\n" "$selected_row"
      exit 0
      ;;
    *)
      if printf "%s\n" "$args" | grep -F -- "-format i" >/dev/null 2>&1; then
        index="$(printf "%s\n" "$stdin" | /usr/bin/awk -v target="$line" '\''$0 == target { print NR - 1; found=1; exit } END { if (!found) exit 1 }'\'')"
        if [ -n "$index" ]; then
          selected_row="$index"
          run_selection_changed
          printf "%s\n" "$index"
          exit 0
        fi
      fi
      printf "%s\n" "$line"
      exit 0
      ;;
  esac
done

exit 1
'
  make_fake_bin grep '#!/usr/bin/env bash
if [ "${1:-}" = "-oP" ]; then
  perl -ne "while (/(\\d+)(?=K)/g) { print \"\$1\n\" }"
  exit 0
fi
exec /usr/bin/grep "$@"
'
  make_fake_bin flock '#!/usr/bin/env bash
printf "flock %s\n" "$*" >> "$FAKE_LOG"
exit 0
'
  make_fake_bin checkupdates '#!/usr/bin/env bash
printf "checkupdates %s\n" "$*" >> "$FAKE_LOG"
if [ -n "${FAKE_CHECKUPDATES:-}" ]; then
  printf "%s\n" "$FAKE_CHECKUPDATES"
fi
'
  make_fake_bin yay '#!/usr/bin/env bash
printf "yay %s\n" "$*" >> "$FAKE_LOG"
if [ "${1:-}" = "-Qua" ] && [ -n "${FAKE_YAY_UPDATES:-}" ]; then
  printf "%s\n" "$FAKE_YAY_UPDATES"
fi
'
  make_fake_bin ps '#!/usr/bin/env bash
printf "ps %s\n" "$*" >> "$FAKE_LOG"
case "$*" in
  *"--sort=-pcpu"*) printf "22.5 compile\n3.0 idle\n" ;;
  *"--sort=-rss"*) printf "2097152 browser\n1048576 shell\n" ;;
esac
'
  make_fake_bin awk '#!/usr/bin/env bash
if printf "%s\n" "$*" | grep -F "/proc/meminfo" >/dev/null 2>&1; then
  echo "8000000 4000000"
else
  /usr/bin/awk "$@"
fi
'
  make_fake_bin awww '#!/usr/bin/env bash
printf "awww %s\n" "$*" >> "$FAKE_LOG"
'
  make_fake_bin awww-daemon '#!/usr/bin/env bash
printf "awww-daemon %s\n" "$*" >> "$FAKE_LOG"
'
  make_fake_bin git '#!/usr/bin/env bash
printf "git %s\n" "$*" >> "$FAKE_LOG"
'
  make_fake_bin hyprctl '#!/usr/bin/env bash
printf "hyprctl %s\n" "$*" >> "$FAKE_LOG"
if [ "${1:-}" = "cursorpos" ]; then
  echo "100,200"
elif [ "${1:-}" = "-j" ] && [ "${2:-}" = "binds" ]; then
  printf "%s\n" "[{\"modmask\":64,\"key\":\"Return\",\"dispatcher\":\"exec\",\"arg\":\"uwsm app -- ghostty\"},{\"modmask\":65,\"key\":\"B\",\"dispatcher\":\"exec\",\"arg\":\"uwsm app -- flatpak run app.zen_browser.zen\"}]"
fi
'
  make_fake_bin shuf '#!/usr/bin/env bash
sed -n "1p"
'
  make_fake_bin wvkbd-mobintl '#!/usr/bin/env bash
printf "wvkbd-mobintl %s\n" "$*" >> "$FAKE_LOG"
'
  make_fake_bin iio-hyprland '#!/usr/bin/env bash
printf "iio-hyprland %s\n" "$*" >> "$FAKE_LOG"
'
  make_fake_bin nwg-drawer '#!/usr/bin/env bash
printf "nwg-drawer %s\n" "$*" >> "$FAKE_LOG"
'
  make_fake_bin cliphist '#!/usr/bin/env bash
printf "cliphist %s\n" "$*" >> "$FAKE_LOG"
case "${1:-}" in
  list) echo "clip-entry" ;;
  decode) cat ;;
esac
'
  make_fake_bin wl-copy '#!/usr/bin/env bash
input="$(cat)"
printf "wl-copy %s\n%s\n" "$*" "$input" >> "$FAKE_LOG"
'
  make_fake_bin wl-paste '#!/usr/bin/env bash
printf "%s" "${FAKE_WL_PASTE:-}"
'
  make_fake_bin rbw '#!/usr/bin/env bash
printf "rbw %s\n" "$*" >> "$FAKE_LOG"
case "${1:-} ${2:-}" in
  "get ssh/hosts")
    if [ "${3:-}" = "--field" ] && [ "${4:-}" = "config" ]; then
      if [ "${FAKE_RBW_MISSING_CONFIG:-0}" = "1" ]; then
        printf "%s\n" "rbw get: no entry found for ssh/hosts" >&2
        exit 1
      fi
      cat <<'"'"'JSON'"'"'
{"hosts":[{"alias":"nas","hostname":"nas.local","user":"jack","key":"nas","port":2222,"extra":{"ForwardAgent":"no"}}],"keys":[{"name":"nas","item":"ssh/keys/nas","field":"public key"}]}
JSON
    fi
    ;;
  "get ssh/keys/nas")
    if [ "${3:-}" = "--field" ] && [ "${4:-}" = "public key" ]; then
      printf "%s\n" "ssh-ed25519 AAAATEST nas"
    fi
    ;;
  "unlocked ")
    [ "${FAKE_RBW_UNLOCKED:-0}" = "1" ]
    ;;
  "config show")
    printf "%s\n" "{\"email\":\"${FAKE_RBW_EMAIL:-user@example.com}\",\"base_url\":${FAKE_RBW_BASE_URL_JSON:-null}}"
    ;;
  "config set")
    if [ "${3:-}" = "email" ]; then
      mkdir -p "$HOME/.config/rbw"
      printf "{}\n" > "$HOME/.config/rbw/config.json"
    fi
    ;;
esac
'
  make_fake_bin rofi-rbw '#!/usr/bin/env bash
printf "rofi-rbw %s\n" "$*" >> "$FAKE_LOG"
'
  make_fake_bin wtype '#!/usr/bin/env bash
printf "wtype %s\n" "$*" >> "$FAKE_LOG"
'
  make_fake_bin gum '#!/usr/bin/env bash
printf "gum %s\n" "$*" >> "$FAKE_LOG"
case "${1:-}" in
  choose) sed -n "1p" ;;
  style) shift; while [ "${1:-}" = "--foreground" ]; do shift 2; done; printf "%s\n" "$*" ;;
esac
'
  make_fake_bin ssh '#!/usr/bin/env bash
printf "ssh %s\n" "$*" >> "$FAKE_LOG"
printf "ssh-auth-sock %s\n" "${SSH_AUTH_SOCK:-}" >> "$FAKE_LOG"
'
  make_fake_bin uwsm '#!/usr/bin/env bash
printf "uwsm %s\n" "$*" >> "$FAKE_LOG"
'
  make_fake_bin pidof '#!/usr/bin/env bash
printf "pidof %s\n" "$*" >> "$FAKE_LOG"
if [ "${FAKE_PIDOF_MATCH:-}" = "${*: -1}" ]; then
  echo 1234
  exit 0
fi
exit 1
'
  make_fake_bin hyprlock '#!/usr/bin/env bash
printf "hyprlock %s\n" "$*" >> "$FAKE_LOG"
'
  make_fake_bin systemctl '#!/usr/bin/env bash
printf "systemctl %s\n" "$*" >> "$FAKE_LOG"
'
  make_fake_bin loginctl '#!/usr/bin/env bash
printf "loginctl %s\n" "$*" >> "$FAKE_LOG"
'
  make_fake_bin sudo '#!/usr/bin/env bash
printf "sudo %s\n" "$*" >> "$FAKE_LOG"
"$@"
'
  make_fake_bin pacman '#!/usr/bin/env bash
printf "pacman %s\n" "$*" >> "$FAKE_LOG"
case "$*" in
  "-Q ghostty"|"-Q grimblast-git"|"-Q app.zen_browser.zen") exit 0 ;;
  "-Qqet") printf "%s\n" ghostty extra-native catppuccin-gtk-theme-mocha extra-aur; exit 0 ;;
  "-Qqm") printf "%s\n" catppuccin-gtk-theme-mocha extra-aur; exit 0 ;;
  "-Qqdt") printf "%s\n" orphan-lib orphan-tool; exit 0 ;;
esac
if [ "${1:-}" = "-Syu" ] || [ "${1:-}" = "-Rns" ]; then
  exit 0
fi
exit 1
'
  make_fake_bin flatpak '#!/usr/bin/env bash
printf "flatpak %s\n" "$*" >> "$FAKE_LOG"
if [ "$*" = "list --system --app --columns=application" ]; then
  printf "%s\n" app.zen_browser.zen org.extra.App
fi
'
  make_fake_bin brew '#!/usr/bin/env bash
printf "brew %s\n" "$*" >> "$FAKE_LOG"
case "${1:-}" in
  list)
    case "${3:-}" in
      git|neovim) exit 0 ;;
    esac
    exit 1
    ;;
  leaves)
    printf "%s\n" git extra-brew
    ;;
esac
'
  make_fake_bin uname '#!/usr/bin/env bash
printf "%s\n" "${FAKE_UNAME:-Linux}"
'
  make_fake_bin hostname '#!/usr/bin/env bash
printf "%s\n" "${FAKE_HOSTNAME:-minipc}"
'

  export HOME="$TEST_HOME"
  export XDG_STATE_HOME="$TEST_HOME/.local/state"
  export PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
  export FAKE_LOG ROFI_QUEUE
  unset FAKE_PKILL_FAIL_WAYBAR FAKE_PGREP_MATCH FAKE_PIDOF_MATCH FAKE_SUNWAIT_POLL FAKE_SUNWAIT_REPORT FAKE_TIME_DATE_CTL_FAIL FAKE_TIMEZONE FAKE_CHECKUPDATES FAKE_YAY_UPDATES FAKE_RBW_UNLOCKED FAKE_RBW_EMAIL FAKE_RBW_BASE_URL_JSON FAKE_RBW_MISSING_CONFIG FAKE_WL_PASTE RBW_MENU_FORCE_MISSING
}

reset_case() {
  setup_case
}

run_script() {
  bash "$ROOT_DIR/$1"
}

run_script_capture() {
  bash "$ROOT_DIR/$1" 2>"$TEST_TMP/stderr"
}

test_toggle_auto_to_on() {
  run_script dot_local/bin/executable_hyprsunset-toggle &&
    [ "$(cat "$HOME/.config/hyprsunset/mode")" = "on" ] &&
    assert_log_contains "hyprctl hyprsunset temperature 3500" &&
    assert_log_contains "notify-send -t 1500 Night Light: ON (3500K)" &&
    assert_log_contains "pkill -SIGRTMIN+10 waybar"
}

test_toggle_on_to_off() {
  echo on > "$HOME/.config/hyprsunset/mode"
  run_script dot_local/bin/executable_hyprsunset-toggle &&
    [ "$(cat "$HOME/.config/hyprsunset/mode")" = "off" ] &&
    assert_log_contains "hyprctl hyprsunset identity" &&
    assert_log_contains "notify-send -t 1500 Night Light: OFF"
}

test_toggle_off_to_auto_day() {
  export FAKE_SUNWAIT_POLL=DAY
  echo off > "$HOME/.config/hyprsunset/mode"
  run_script dot_local/bin/executable_hyprsunset-toggle &&
    [ "$(cat "$HOME/.config/hyprsunset/mode")" = "auto" ] &&
    assert_log_contains "sunwait poll 51.5N 0.1W" &&
    assert_log_contains "hyprctl hyprsunset identity" &&
    assert_log_contains "notify-send -t 1500 Night Light: Auto (OFF)"
}

test_toggle_off_to_auto_night() {
  export FAKE_SUNWAIT_POLL=NIGHT
  echo off > "$HOME/.config/hyprsunset/mode"
  run_script dot_local/bin/executable_hyprsunset-toggle &&
    [ "$(cat "$HOME/.config/hyprsunset/mode")" = "auto" ] &&
    assert_log_contains "hyprctl hyprsunset temperature 3500" &&
    assert_log_contains "notify-send -t 1500 Night Light: Auto (ON (3500K))"
}

test_toggle_uses_configured_temp() {
  echo 2800 > "$HOME/.config/hyprsunset/temperature"
  run_script dot_local/bin/executable_hyprsunset-toggle &&
    assert_log_contains "hyprctl hyprsunset temperature 2800" &&
    assert_log_contains "notify-send -t 1500 Night Light: ON (2800K)"
}

test_toggle_falls_back_to_default_temp() {
  rm -f "$HOME/.config/hyprsunset/temperature"
  run_script dot_local/bin/executable_hyprsunset-toggle &&
    assert_log_contains "hyprctl hyprsunset temperature 3500"
}

test_toggle_waybar_absent_does_not_fail() {
  export FAKE_PKILL_FAIL_WAYBAR=1
  run_script dot_local/bin/executable_hyprsunset-toggle
}

test_toggle_invalid_mode_defaults_to_auto() {
  echo broken > "$HOME/.config/hyprsunset/mode"
  run_script dot_local/bin/executable_hyprsunset-toggle &&
    [ "$(cat "$HOME/.config/hyprsunset/mode")" = "on" ] &&
    assert_log_contains "notify-send -t 1500 Night Light: ON (3500K)"
}

test_apply_on_forces_nightlight() {
  echo on > "$HOME/.config/hyprsunset/mode"
  run_script dot_local/bin/executable_hyprsunset-apply &&
    [ "$(cat "$HOME/.config/hyprsunset/applied-state")" = "on" ] &&
    assert_log_not_contains "sunwait" &&
    assert_log_contains "hyprctl hyprsunset temperature 3500"
}

test_apply_off_forces_daylight() {
  echo off > "$HOME/.config/hyprsunset/mode"
  run_script dot_local/bin/executable_hyprsunset-apply &&
    [ "$(cat "$HOME/.config/hyprsunset/applied-state")" = "off" ] &&
    assert_log_not_contains "sunwait" &&
    assert_log_contains "hyprctl hyprsunset identity"
}

test_apply_day_clears_night() {
  export FAKE_SUNWAIT_POLL=DAY
  run_script dot_local/bin/executable_hyprsunset-apply &&
    [ "$(cat "$HOME/.config/hyprsunset/applied-state")" = "off" ] &&
    assert_log_contains "sunwait poll 51.5N 0.1W" &&
    assert_log_contains "hyprctl hyprsunset identity" &&
    assert_log_contains "pkill -SIGRTMIN+10 waybar"
}

test_apply_day_already_off_noop() {
  export FAKE_SUNWAIT_POLL=DAY
  run_script dot_local/bin/executable_hyprsunset-apply &&
    assert_log_contains "hyprctl hyprsunset identity"
}

test_apply_night_enables() {
  export FAKE_SUNWAIT_POLL=NIGHT
  run_script dot_local/bin/executable_hyprsunset-apply &&
    [ "$(cat "$HOME/.config/hyprsunset/applied-state")" = "on" ] &&
    assert_log_contains "hyprctl hyprsunset temperature 3500"
}

test_apply_night_already_on_noop() {
  export FAKE_SUNWAIT_POLL=NIGHT
  export FAKE_PIDOF_MATCH=hyprsunset
  run_script dot_local/bin/executable_hyprsunset-apply &&
    assert_log_contains "hyprctl hyprsunset temperature 3500"
}

test_apply_invalid_mode_defaults_to_auto() {
  export FAKE_SUNWAIT_POLL=NIGHT
  echo broken > "$HOME/.config/hyprsunset/mode"
  run_script dot_local/bin/executable_hyprsunset-apply &&
    assert_log_contains "sunwait poll 51.5N 0.1W" &&
    assert_log_contains "hyprctl hyprsunset temperature 3500"
}

status_json() {
  bash "$ROOT_DIR/dot_local/bin/executable_hyprsunset-status" > "$TEST_TMP/status.json"
  jq -e . "$TEST_TMP/status.json" >/dev/null
}

test_status_auto_off_json() {
  export FAKE_SUNWAIT_POLL=DAY
  status_json &&
    jq -e '.tooltip | contains("Night light: Auto (OFF)") and (contains("Mode:") | not)' "$TEST_TMP/status.json" >/dev/null
}

test_status_auto_on_json() {
  export FAKE_SUNWAIT_POLL=NIGHT
  export FAKE_PIDOF_MATCH=hyprsunset
  status_json &&
    jq -e '.tooltip | contains("Night light: Auto (ON (3500K))") and (contains("Mode:") | not)' "$TEST_TMP/status.json" >/dev/null
}

test_status_forced_on_json() {
  echo on > "$HOME/.config/hyprsunset/mode"
  export FAKE_PIDOF_MATCH=hyprsunset
  status_json &&
    jq -e '.tooltip | contains("Night light: ON") and (contains("Mode:") | not)' "$TEST_TMP/status.json" >/dev/null
}

test_status_forced_off_json() {
  echo off > "$HOME/.config/hyprsunset/mode"
  status_json &&
    jq -e '.tooltip | contains("Night light: OFF") and (contains("Mode:") | not)' "$TEST_TMP/status.json" >/dev/null
}

test_status_expected_on_when_process_absent() {
  export FAKE_SUNWAIT_POLL=NIGHT
  status_json &&
    jq -e '.tooltip | contains("Night light: Auto (ON") and (contains("Mode:") | not) and (contains("Expected:") | not)' "$TEST_TMP/status.json" >/dev/null
}

test_status_expected_off_when_process_present() {
  export FAKE_SUNWAIT_POLL=DAY
  export FAKE_PIDOF_MATCH=hyprsunset
  status_json &&
    jq -e '.tooltip | contains("Night light: Auto (OFF)") and (contains("Mode:") | not) and (contains("Expected:") | not)' "$TEST_TMP/status.json" >/dev/null
}

test_status_malformed_sunwait_still_json() {
  export FAKE_SUNWAIT_REPORT="not daylight data"
  status_json
}

test_status_uses_daylight_not_astronomical_twilight() {
  FAKE_SUNWAIT_REPORT='Target Information ...
             Day with twilight: 04:59 to 21:00

General Information (no offset) ...

 Times ...         Daylight: 04:59 to 21:00
        with Civil twilight: 04:20 to 21:39
     with Nautical twilight: 03:21 to 22:39
 with Astronomical twilight: 02:16 to 23:43'
  export FAKE_SUNWAIT_REPORT
  status_json &&
    jq -e '.tooltip | contains("☀️ 04:59  🌙 21:00") and (contains("02:16") | not)' "$TEST_TMP/status.json" >/dev/null
}

test_status_timedatectl_fallback() {
  export FAKE_TIME_DATE_CTL_FAIL=1
  status_json &&
    jq -e '.tooltip | contains("Europe/London")' "$TEST_TMP/status.json" >/dev/null
}

test_picker_first_selection_previews_without_save() {
  printf '__UP__\n__UP__\n__ESC__\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_hyprsunset-temp-picker &&
    assert_log_contains "hyprctl hyprsunset temperature 3500" &&
    assert_log_contains "hyprctl hyprsunset temperature 3000" &&
    assert_log_contains "hyprctl hyprsunset temperature 2500" &&
    [ "$(cat "$HOME/.config/hyprsunset/temperature")" = "3500" ]
}

test_picker_same_selection_confirms() {
  echo on > "$HOME/.config/hyprsunset/mode"
  printf 'Warm (2500K)\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_hyprsunset-temp-picker &&
    assert_log_contains "hyprctl hyprsunset temperature 2500" &&
    [ "$(cat "$HOME/.config/hyprsunset/temperature")" = "2500" ] &&
    assert_log_contains "notify-send -t 1500 Temperature: 2500K"
}

test_picker_opens_at_current_live_temp() {
  echo on > "$HOME/.config/hyprsunset/mode"
  echo 3500 > "$HOME/.config/hyprsunset/temperature"
  echo 2500 > "$HOME/.config/hyprsunset/current-temperature"
  printf '__ENTER__\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_hyprsunset-temp-picker &&
    assert_log_contains "rofi -dmenu -p Temperature (Enter save, Esc cancel) -i -format i -selected-row 3" &&
    assert_log_not_contains "hyprctl hyprsunset temperature 3500" &&
    [ "$(cat "$HOME/.config/hyprsunset/temperature")" = "2500" ]
}

test_picker_same_current_preview_noop() {
  echo 3000 > "$HOME/.config/hyprsunset/current-temperature"
  run_script dot_local/bin/executable_hyprsunset-temp-picker --preview "Cozy (3000K)" &&
    assert_log_not_contains "hyprctl hyprsunset temperature 3000"
}

test_picker_ignores_rofi_initial_first_row_preview() {
  export FAKE_ROFI_INITIAL_SELECTION_FIRST=1
  echo 3000 > "$HOME/.config/hyprsunset/temperature"
  echo 3000 > "$HOME/.config/hyprsunset/current-temperature"
  printf '__ESC__\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_hyprsunset-temp-picker &&
    assert_log_contains "rofi-on-selection Extreme (1000K)" &&
    assert_log_not_contains "hyprctl hyprsunset temperature 1000"
}

test_picker_different_selections_preview_each() {
  printf '__UP__\n__UP__\n__ESC__\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_hyprsunset-temp-picker &&
    assert_log_contains "hyprctl hyprsunset temperature 3000" &&
    assert_log_contains "hyprctl hyprsunset temperature 2500"
}

test_picker_cancel_restores_previous_when_on() {
  echo on > "$HOME/.config/hyprsunset/mode"
  printf '__UP__\n__UP__\n__ESC__\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_hyprsunset-temp-picker &&
    assert_log_contains "hyprctl hyprsunset temperature 3000" &&
    assert_log_contains "hyprctl hyprsunset temperature 2500" &&
    assert_log_contains "hyprctl hyprsunset temperature 3500" &&
    [ "$(cat "$HOME/.config/hyprsunset/temperature")" = "3500" ]
}

test_picker_cancel_inactive_does_not_restore() {
  echo off > "$HOME/.config/hyprsunset/mode"
  printf '__UP__\n__ESC__\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_hyprsunset-temp-picker &&
    assert_log_contains "hyprctl hyprsunset temperature 3500" &&
    assert_log_contains "hyprctl hyprsunset temperature 3000" &&
    assert_log_contains "hyprctl hyprsunset identity"
}

test_picker_save_while_off_restores_off_state() {
  echo off > "$HOME/.config/hyprsunset/mode"
  printf 'Warm (2500K)\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_hyprsunset-temp-picker &&
    assert_log_contains "hyprctl hyprsunset temperature 3500" &&
    assert_log_contains "hyprctl hyprsunset identity" &&
    [ "$(cat "$HOME/.config/hyprsunset/temperature")" = "2500" ] &&
    [ "$(cat "$HOME/.config/hyprsunset/applied-state")" = "off" ]
}

test_picker_missing_config_dir_saves() {
  rm -rf "$HOME/.config/hyprsunset"
  printf 'Warm (2500K)\n' > "$ROFI_QUEUE"
  run_script_capture dot_local/bin/executable_hyprsunset-temp-picker &&
    [ -f "$HOME/.config/hyprsunset/temperature" ] &&
    [ "$(cat "$HOME/.config/hyprsunset/temperature")" = "2500" ]
}

test_settings_launches_picker_and_signals_waybar() {
  cp "$ROOT_DIR/dot_local/bin/executable_hyprsunset-temp-picker" "$HOME/.local/bin/hyprsunset-temp-picker"
  chmod +x "$HOME/.local/bin/hyprsunset-temp-picker"
  printf 'Warm (2500K)\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_hyprsunset-settings &&
    [ "$(cat "$HOME/.config/hyprsunset/temperature")" = "2500" ] &&
    assert_log_contains "pkill -SIGRTMIN+10 waybar"
}

test_true_highlight_preview_before_confirm() {
  printf '__UP__\n__UP__\n__DOWN__\n__ENTER__\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_hyprsunset-temp-picker &&
    assert_log_contains "hyprctl hyprsunset temperature 3000" &&
    assert_log_contains "hyprctl hyprsunset temperature 2500" &&
    [ "$(cat "$HOME/.config/hyprsunset/temperature")" = "3000" ]
}

json_output_from() {
  bash "$ROOT_DIR/$1" > "$TEST_TMP/output.json"
  jq -e . "$TEST_TMP/output.json" >/dev/null
}

test_updates_check_disabled_json() {
  mkdir -p "$HOME/.cache/arch-updates"
  touch "$HOME/.cache/arch-updates/disabled"
  json_output_from dot_local/bin/executable_arch-updates-check &&
    jq -e '.class == "disabled" and (.tooltip | contains("disabled"))' "$TEST_TMP/output.json" >/dev/null
}

test_updates_check_counts_official_and_aur() {
  export FAKE_CHECKUPDATES="linux 1 -> 2
pacman 1 -> 2"
  export FAKE_YAY_UPDATES="aurpkg 1 -> 2"
  json_output_from dot_local/bin/executable_arch-updates-check &&
    jq -e '.text | contains("3")' "$TEST_TMP/output.json" >/dev/null &&
    jq -e '.tooltip | contains("2 official, 1 AUR")' "$TEST_TMP/output.json" >/dev/null
}

test_updates_check_uses_fresh_cache() {
  mkdir -p "$HOME/.cache/arch-updates"
  printf '%s\n' '{"text":"cached","tooltip":"cached","class":"cached"}' > "$HOME/.cache/arch-updates/status.json"
  date +%s > "$HOME/.cache/arch-updates/last-check"
  json_output_from dot_local/bin/executable_arch-updates-check &&
    jq -e '.text == "cached"' "$TEST_TMP/output.json" >/dev/null &&
    assert_log_not_contains "checkupdates"
}

test_updates_check_force_ignores_fresh_cache() {
  mkdir -p "$HOME/.cache/arch-updates"
  printf '%s\n' '{"text":"cached","tooltip":"cached","class":"cached"}' > "$HOME/.cache/arch-updates/status.json"
  date +%s > "$HOME/.cache/arch-updates/last-check"
  export FAKE_CHECKUPDATES="linux 1 -> 2"
  bash "$ROOT_DIR/dot_local/bin/executable_arch-updates-check" --force > "$TEST_TMP/output.json" &&
    jq -e . "$TEST_TMP/output.json" >/dev/null &&
    jq -e '.text | contains("1")' "$TEST_TMP/output.json" >/dev/null &&
    assert_log_contains "checkupdates"
}

test_update_menu_check_now() {
  mkdir -p "$HOME/.cache/arch-updates"
  touch "$HOME/.cache/arch-updates/last-check"
  printf 'Check now\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_arch-update-menu &&
    [ ! -f "$HOME/.cache/arch-updates/last-check" ] &&
    assert_log_contains "pkill -RTMIN+12 waybar" &&
    assert_log_contains "notify-send -t 2000 Checking for updates..."
}

test_update_menu_toggle_disables_and_signals() {
  printf 'Toggle auto-check\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_arch-update-menu &&
    [ -f "$HOME/.cache/arch-updates/disabled" ] &&
    assert_log_contains "pkill -RTMIN+12 waybar" &&
    assert_log_contains "notify-send -t 2000 Update checking disabled"
}

test_update_menu_toggle_enables_and_signals() {
  mkdir -p "$HOME/.cache/arch-updates"
  touch "$HOME/.cache/arch-updates/disabled"
  printf 'Toggle auto-check\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_arch-update-menu &&
    [ ! -f "$HOME/.cache/arch-updates/disabled" ] &&
    assert_log_contains "pkill -RTMIN+12 waybar" &&
    assert_log_contains "notify-send -t 2000 Update checking enabled"
}

test_sysmon_emits_waybar_json() {
  json_output_from dot_local/bin/executable_waybar-sysmon &&
    jq -e '.text and (.tooltip | contains("compile") and contains("browser"))' "$TEST_TMP/output.json" >/dev/null
}

test_osk_toggle_starts_when_absent() {
  run_script dot_local/bin/executable_osk-toggle &&
    assert_log_contains "pgrep -x wvkbd-mobintl" &&
    assert_log_contains "wvkbd-mobintl --landscape --opacity 0.98 --rounding 10 --hidden" &&
    assert_log_contains "pkill -SIGRTMIN -x wvkbd-mobintl"
}

test_osk_toggle_signals_when_present() {
  export FAKE_PGREP_MATCH=wvkbd-mobintl
  run_script dot_local/bin/executable_osk-toggle &&
    assert_log_not_contains "wvkbd-mobintl --landscape --opacity 0.98 --rounding 10 --hidden" &&
    assert_log_contains "pkill -SIGRTMIN -x wvkbd-mobintl"
}

test_app_launcher_prefers_touch_drawer() {
  run_script dot_local/bin/executable_app-launcher &&
    assert_log_contains "nwg-drawer"
}

test_tablet_mode_enters_tablet_state() {
  FW12_TABLET_DISPLAY=eDP-1 FW12_TABLET_DISABLE_DEVICES=framework-keyboard bash "$ROOT_DIR/dot_local/bin/executable_fw12-tablet-mode" tablet &&
    [ "$(cat "$HOME/.local/state/fw12-tablet-mode/mode")" = "tablet" ] &&
    assert_log_contains "hyprctl --batch keyword input:touchdevice:enabled true" &&
    assert_log_contains "hyprctl --batch keyword device[framework-keyboard]:enabled false" &&
    assert_log_contains "wvkbd-mobintl --landscape --opacity 0.98 --rounding 10 --hidden" &&
    assert_log_contains "pkill -SIGUSR2 -x wvkbd-mobintl" &&
    assert_log_contains "iio-hyprland --transform 0,1,2,3 eDP-1" &&
    assert_log_contains "pkill -SIGRTMIN+13 waybar" &&
    assert_log_contains "notify-send -t 1500 Tablet mode Touch and on-screen keyboard enabled"
}

test_tablet_mode_returns_to_laptop_state() {
  FW12_TABLET_DISPLAY=eDP-1 FW12_TABLET_DISABLE_DEVICES=framework-keyboard bash "$ROOT_DIR/dot_local/bin/executable_fw12-tablet-mode" laptop &&
    [ "$(cat "$HOME/.local/state/fw12-tablet-mode/mode")" = "laptop" ] &&
    assert_log_contains "hyprctl --batch keyword monitor eDP-1,preferred,auto,auto,transform,0" &&
    assert_log_contains "pkill -SIGUSR1 -x wvkbd-mobintl" &&
    assert_log_contains "hyprctl --batch keyword device[framework-keyboard]:enabled true" &&
    assert_log_contains "hyprctl --batch keyword input:touchdevice:enabled false" &&
    assert_log_contains "pkill -SIGRTMIN+14 waybar" &&
    assert_log_contains "notify-send -t 1500 Laptop mode Touch disabled and rotation reset"
}

test_tablet_mode_rotation_lock_status() {
  FW12_TABLET_DISPLAY=eDP-1 bash "$ROOT_DIR/dot_local/bin/executable_fw12-tablet-mode" toggle-rotation &&
    [ -f "$HOME/.local/state/fw12-tablet-mode/rotation-locked" ] &&
    assert_log_contains "hyprctl --batch keyword monitor eDP-1,preferred,auto,auto,transform,0" &&
    assert_log_contains "notify-send -t 1500 Rotation locked" &&
    bash "$ROOT_DIR/dot_local/bin/executable_fw12-tablet-mode" rotation-status > "$TEST_TMP/output.json" &&
    jq -e '.class == "locked"' "$TEST_TMP/output.json" >/dev/null
}

test_tablet_mode_status_emits_waybar_json() {
  mkdir -p "$HOME/.local/state/fw12-tablet-mode"
  printf 'tablet\n' > "$HOME/.local/state/fw12-tablet-mode/mode"
  bash "$ROOT_DIR/dot_local/bin/executable_fw12-tablet-mode" status > "$TEST_TMP/output.json" &&
    jq -e '(.class | index("tablet")) and (.tooltip | contains("Tablet mode"))' "$TEST_TMP/output.json" >/dev/null
}

test_wallpaper_random_applies_image() {
  run_script dot_local/bin/executable_wallpaper-random &&
    assert_log_contains "awww query" &&
    assert_log_contains "hyprctl cursorpos" &&
    assert_log_contains "awww img $HOME/Pictures/Wallpapers/test.png" &&
    assert_log_contains "--transition-pos 100,200" &&
    assert_log_contains "--transition-type grow"
}

test_wallpaper_checkout_runs_after_chezmoi_apply() {
  assert_repo_contains run_onchange_after_checkout-wallpapers.sh.tmpl 'git clone --depth 1 "$WALLPAPER_REPO" "$TARGET_DIR"' &&
    assert_repo_contains run_onchange_after_checkout-wallpapers.sh.tmpl 'git -C "$TARGET_DIR" pull --ff-only' &&
    assert_repo_contains run_onchange_after_checkout-wallpapers.sh.tmpl 'https://github.com/zhichaoh/catppuccin-wallpapers.git' &&
    assert_file_absent "$ROOT_DIR/dot_config/systemd/user/wallpaper-sync.service" &&
    assert_file_absent "$ROOT_DIR/dot_config/systemd/user/wallpaper-sync.timer" &&
    assert_file_absent "$ROOT_DIR/dot_local/bin/executable_wallpaper-sync" &&
    assert_repo_contains run_onchange_after_remove-wallpaper-sync.sh.tmpl 'systemctl --user disable --now wallpaper-sync.timer' &&
    assert_repo_contains run_onchange_after_remove-wallpaper-sync.sh.tmpl '$HOME/.config/systemd/user/wallpaper-sync.service' &&
    assert_repo_contains run_onchange_after_remove-wallpaper-sync.sh.tmpl '$HOME/.config/systemd/user/wallpaper-sync.timer' &&
    assert_repo_contains run_onchange_after_remove-wallpaper-sync.sh.tmpl '$HOME/.local/bin/wallpaper-sync'
}

test_rofi_clipboard_decodes_to_wl_copy() {
  printf 'clip-entry\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_rofi-clipboard &&
    assert_log_contains "cliphist list" &&
    assert_log_contains "cliphist decode" &&
    assert_log_contains "wl-copy" &&
    assert_log_contains "clip-entry"
}

test_rbw_menu_locked_shows_setup_actions() {
  printf '__ESC__\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_rbw-menu &&
    assert_log_contains "rofi -dmenu -i -p Vault" &&
    assert_log_contains "Set email (current: unset)" &&
    assert_log_contains "Set server (current: official cloud)" &&
    assert_log_contains "Login" &&
    assert_log_not_contains "Credentials"
}

test_rbw_menu_configured_locked_orders_common_actions_first() {
  mkdir -p "$HOME/.config/rbw"
  printf '{}\n' > "$HOME/.config/rbw/config.json"
  printf '__ESC__\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_rbw-menu &&
    assert_log_contains $'rofi-stdin Unlock vault\nSync vault\nLogin\nStatus\nSet email'
}

test_rbw_menu_unlocked_shows_credentials_and_config() {
  mkdir -p "$HOME/.config/rbw"
  printf '{}\n' > "$HOME/.config/rbw/config.json"
  export FAKE_RBW_UNLOCKED=1
  printf '__ESC__\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_rbw-menu &&
    assert_log_contains "systemctl --user start rbw-agent.service" &&
    assert_log_contains "Credentials" &&
    assert_log_contains "Set email (current: user@example.com)" &&
    assert_log_contains "Set server (current: official cloud)" &&
    assert_log_contains "Lock vault"
}

test_rbw_menu_unlocked_orders_common_actions_first() {
  mkdir -p "$HOME/.config/rbw"
  printf '{}\n' > "$HOME/.config/rbw/config.json"
  export FAKE_RBW_UNLOCKED=1
  printf '__ESC__\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_rbw-menu &&
    assert_log_contains $'rofi-stdin Credentials\nSync vault\nLock vault\nStatus\nSet email'
}

test_rbw_menu_credentials_launches_rofi_rbw() {
  mkdir -p "$HOME/.config/rbw"
  printf '{}\n' > "$HOME/.config/rbw/config.json"
  export FAKE_RBW_UNLOCKED=1
  printf 'Credentials\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_rbw-menu &&
    assert_log_contains "rofi-rbw --selector rofi --clipboarder wl-copy --typer wtype --action copy --target menu --prompt Vault --selector-args=-i --clear-after 45"
}

test_rbw_menu_set_email_configures_defaults() {
  printf 'Set email (current: unset)\nuser@example.com\n__ESC__\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_rbw-menu &&
    assert_log_contains "rbw config set email user@example.com" &&
    assert_log_contains "rbw config set pinentry $HOME/.local/bin/rbw-pinentry" &&
    assert_log_contains "rbw config set lock_timeout 3600" &&
    assert_log_contains "rbw config set sync_interval 3600" &&
    assert_log_contains "systemctl --user enable --now rbw-agent.service" &&
    assert_log_contains $'rofi-stdin Unlock vault\nSync vault\nLogin\nStatus'
}

test_rbw_menu_reports_missing_rbw_on_config_action() {
  export RBW_MENU_FORCE_MISSING=rbw
  printf 'Set email (current: unset)\nuser@example.com\n__ESC__\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_rbw-menu &&
    assert_log_contains "notify-send -t 3000 rbw Missing rbw; install rbw and rofi-rbw" &&
    assert_log_not_contains "rbw config set email"
}

test_rbw_menu_set_server_configures_base_url() {
  printf 'Set server (current: official cloud)\nhttps://vault.example.com/\n__ESC__\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_rbw-menu &&
    assert_log_contains "rbw config set base_url https://vault.example.com" &&
    assert_log_contains "rbw stop-agent" &&
    assert_log_contains "systemctl --user restart rbw-agent.service"
}

test_rbw_menu_reset_server_unsets_urls() {
  export FAKE_RBW_BASE_URL_JSON='"https://vault.example.com"'
  mkdir -p "$HOME/.config/rbw"
  printf '{}\n' > "$HOME/.config/rbw/config.json"
  printf 'Use official cloud\n__ESC__\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_rbw-menu &&
    assert_log_contains "rbw config unset base_url" &&
    assert_log_contains "rbw config unset identity_url" &&
    assert_log_contains "rbw config unset ui_url" &&
    assert_log_contains "rbw config unset notifications_url"
}

test_rbw_clipboard_wrapper_marks_sensitive() {
  export WL_COPY_BIN="$FAKE_BIN/wl-copy"
  export RBW_CLIPBOARD_CLEAR_AFTER=0
  printf 'secret-value' | bash "$ROOT_DIR/dot_local/lib/rbw-clipboard/executable_wl-copy" &&
    assert_log_contains "wl-copy --sensitive" &&
    assert_log_contains "secret-value"
}

test_keybind_help_uses_hyprctl_and_rofi() {
  printf '__ESC__\n' > "$ROFI_QUEUE"
  run_script_capture dot_local/bin/executable_keybind-help
  assert_log_contains "hyprctl -j binds" &&
    assert_log_contains "rofi -dmenu -p Keybindings" &&
    assert_log_contains "ghostty"
}

test_power_menu_lock_runs_hyprlock() {
  printf 'Lock\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_hypr-power-menu &&
    assert_log_contains "rofi -dmenu -p Power menu" &&
    assert_log_contains "pidof hyprlock" &&
    assert_log_contains "hyprlock"
}

test_power_menu_lock_is_noop_when_already_locked() {
  export FAKE_PIDOF_MATCH=hyprlock
  printf 'Lock\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_hypr-power-menu &&
    assert_log_contains "pidof hyprlock" &&
    assert_log_not_contains "hyprlock "
}

test_power_menu_suspend_runs_system_suspend() {
  printf 'Suspend\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_hypr-power-menu &&
    assert_log_contains "systemctl suspend"
}

test_power_menu_logout_requires_confirmation() {
  export XDG_SESSION_ID=7
  printf 'Log out\nYes, log out\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_hypr-power-menu &&
    assert_log_contains "rofi -dmenu -p Confirm" &&
    assert_log_contains "loginctl terminate-session 7"
}

test_power_menu_logout_cancel_does_nothing() {
  export XDG_SESSION_ID=7
  printf 'Log out\nNo, cancel\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_hypr-power-menu &&
    assert_log_contains "rofi -dmenu -p Confirm" &&
    assert_log_not_contains "loginctl terminate-session"
}

test_power_menu_reboot_requires_confirmation() {
  printf 'Reboot\nYes, reboot\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_hypr-power-menu &&
    assert_log_contains "systemctl reboot"
}

test_power_menu_shutdown_requires_confirmation() {
  printf 'Shut down\nYes, shut down\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_hypr-power-menu &&
    assert_log_contains "systemctl poweroff"
}

test_power_menu_escape_does_nothing() {
  printf '__ESC__\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_hypr-power-menu &&
    assert_log_not_contains "hyprlock" &&
    assert_log_not_contains "systemctl" &&
    assert_log_not_contains "loginctl"
}

test_hyprland_autostart_contract() {
  assert_repo_contains dot_config/hypr/hyprland.conf.tmpl "exec-once = systemctl --user start waybar.service" &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl "exec-once = uwsm app -- mako" &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl "exec-once = uwsm app -- swayosd-server" &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl "rbw-agent.service" &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl "exec-once = wl-paste --watch cliphist store" &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl "exec-once = hypridle" &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl "wallpaper-rotate.timer" &&
    ! grep -F "wallpaper-sync.timer" "$ROOT_DIR/dot_config/hypr/hyprland.conf.tmpl" >/dev/null 2>&1 &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl "exec-once = ~/.local/bin/wallpaper-random"
}

test_hyprland_keybind_contract() {
  assert_repo_contains dot_config/hypr/hyprland.conf.tmpl 'bind = $mod, SPACE, exec, uwsm app -- ~/.local/bin/app-launcher' &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl 'bind = $mod_shift, B, exec, uwsm app -- flatpak run app.zen_browser.zen' &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl 'bind = $mod_ctrl, S, exec, uwsm app -- flatpak run org.localsend.localsend_app' &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl 'bind = $mod_shift, P, exec, uwsm app -- ~/.local/bin/rbw-menu' &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl "bind = , Print, exec, grimblast edit area" &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl 'bind = $mod_ctrl, V, exec, ~/.local/bin/rofi-clipboard' &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl 'bind = $mod_ctrl, I, exec, hyprlock' &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl 'bind = $mod, ESCAPE, exec, uwsm app -- ~/.local/bin/hypr-power-menu' &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl 'bind = $mod_alt, K, exec, FW12_TABLET_DISPLAY={{ $tablet_display }} ~/.local/bin/osk-toggle' &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl "bind = \$mod_alt, R, exec, FW12_TABLET_DISPLAY={{ \$tablet_display }} FW12_TABLET_DISABLE_DEVICES='{{ \$tablet_disable_devices }}' ~/.local/bin/fw12-tablet-mode toggle-rotation" &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl "bindel = , XF86MonBrightnessUp, exec, swayosd-client --brightness raise" &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl "bindl = , switch:on:Lid Switch, exec, loginctl lock-session"
}

test_hyprland_tablet_mode_contract() {
  assert_repo_contains dot_config/hypr/hyprland.conf.tmpl 'touchdevice {' &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl 'enabled = false' &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl 'workspace_swipe_touch = true' &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl "FW12_TABLET_DISABLE_DEVICES='{{ \$tablet_disable_devices }}'" &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl 'bindl = , switch:on:{{ $tablet_switch_name }}, exec, FW12_TABLET_DISPLAY={{ $tablet_display }}' &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl 'bindl = , switch:off:{{ $tablet_switch_name }}, exec, FW12_TABLET_DISPLAY={{ $tablet_display }}'
}

test_framework12_tablet_mode_initramfs_contract() {
  assert_repo_contains install.sh '/etc/mkinitcpio.conf.d/99-framework-12-tablet-mode.conf' &&
    assert_repo_contains install.sh 'MODULES+=(pinctrl_tigerlake soc_button_array)' &&
    assert_repo_contains run_onchange_after_configure-framework12-tablet-mode.sh.tmpl '/etc/mkinitcpio.conf.d/99-framework-12-tablet-mode.conf' &&
    assert_repo_contains run_onchange_after_configure-framework12-tablet-mode.sh.tmpl 'MODULES+=(pinctrl_tigerlake soc_button_array)' &&
    assert_repo_contains run_onchange_after_configure-framework12-tablet-mode.sh.tmpl 'sudo mkinitcpio -P' &&
    assert_repo_contains run_onchange_after_configure-framework12-tablet-mode.sh.tmpl 'CHEZMOI_SKIP_SYSTEM_POWER'
}

test_hypridle_lock_sleep_contract() {
  assert_repo_contains dot_config/hypr/hypridle.conf "lock_cmd = pidof hyprlock || hyprlock" &&
    assert_repo_contains dot_config/hypr/hypridle.conf "before_sleep_cmd = pidof hyprlock || hyprlock &" &&
    assert_repo_contains dot_config/hypr/hypridle.conf "after_sleep_cmd = hyprctl dispatch dpms on && systemctl --user restart waybar && ~/.local/bin/hyprsunset-apply" &&
    assert_repo_contains dot_config/hypr/hypridle.conf "timeout = 300" &&
    assert_repo_contains dot_config/hypr/hypridle.conf "timeout = 330" &&
    assert_repo_contains dot_config/hypr/hypridle.conf "timeout = 600" &&
    assert_repo_contains dot_config/hypr/hypridle.conf "on-timeout = systemctl suspend-then-hibernate"
}

test_hyprlock_contract() {
  assert_repo_contains dot_config/hypr/hyprlock.conf "disable_loading_bar = true" &&
    assert_repo_contains dot_config/hypr/hyprlock.conf "path = screenshot" &&
    assert_repo_contains dot_config/hypr/hyprlock.conf "blur_passes = 3" &&
    assert_repo_contains dot_config/hypr/hyprlock.conf "hide_cursor = true" &&
    assert_repo_contains dot_config/hypr/hyprlock.conf "placeholder_text = Enter Password"
}

test_waybar_environment_modules_contract() {
  assert_repo_contains dot_config/waybar/config.tmpl "\"custom/launcher\"" &&
    assert_repo_contains dot_config/waybar/config.tmpl "\"custom/tablet-mode\"" &&
    assert_repo_contains dot_config/waybar/config.tmpl "\"custom/osk\"" &&
    assert_repo_contains dot_config/waybar/config.tmpl "\"custom/rotation\"" &&
    assert_repo_contains dot_config/waybar/config.tmpl "\"custom/updates\"" &&
    assert_repo_contains dot_config/waybar/config.tmpl "\"custom/sysmon\"" &&
    assert_repo_contains dot_config/waybar/config.tmpl "\"idle_inhibitor\"" &&
    assert_repo_contains dot_config/waybar/config.tmpl "\"backlight\"" &&
    assert_repo_contains dot_config/waybar/config.tmpl "\"custom/battery\"" &&
    assert_repo_contains dot_config/waybar/config.tmpl "\"on-click\": \"ghostty --class=com.floating.tui -e pulsemixer\"" &&
    assert_repo_contains dot_config/waybar/config.tmpl "\"on-click-right\": \"wpctl set-mute @DEFAULT_SINK@ toggle\"" &&
    assert_repo_contains dot_config/waybar/config.tmpl "\"on-click\": \"~/.local/bin/hypr-power-menu\"" &&
    assert_repo_contains dot_config/waybar/config.tmpl "\"on-click\": \"~/.local/bin/osk-toggle\"" &&
    assert_repo_contains dot_config/waybar/config.tmpl "\"on-click\": \"~/.local/bin/fw12-tablet-mode toggle-rotation\"" &&
    assert_repo_contains dot_config/waybar/config.tmpl "\"on-scroll-up\": \"swayosd-client --brightness raise\""
}

test_rofi_mako_style_contract() {
  assert_repo_contains dot_config/rofi/config.rasi "modi: \"drun,run,calc\"" &&
    assert_repo_contains dot_config/rofi/config.rasi "terminal: \"ghostty\"" &&
    assert_repo_contains dot_config/rofi/config.rasi "border-radius: 18px" &&
    assert_repo_contains dot_config/mako/config "anchor=top-right" &&
    assert_repo_contains dot_config/mako/config "layer=overlay" &&
    assert_repo_contains dot_config/mako/config "font=Caskaydia Cove Nerd Font 10"
}

test_neovim_toolchain_contract() {
  assert_repo_contains dot_config/nvim/init.lua 'vim.lsp.enable({ "lua_ls", "pyright", "rust_analyzer", "zls" })' &&
    assert_repo_contains dot_config/nvim/init.lua 'python = { "ruff_format" }' &&
    assert_repo_contains dot_config/mise/config.toml 'lua-language-server = "3"' &&
    assert_repo_contains dot_config/mise/config.toml '"npm:pyright" = "latest"' &&
    assert_repo_contains dot_config/mise/config.toml 'ruff = "latest"' &&
    assert_repo_contains dot_config/mise/config.toml 'rust = "stable"' &&
    assert_repo_contains run_onchange_after_install-mise-tools.sh.tmpl 'mise install --yes --cd "$HOME" node' &&
    assert_repo_contains run_onchange_after_install-mise-tools.sh.tmpl 'mise install --yes --cd "$HOME"' &&
    assert_repo_contains run_onchange_after_install-mise-tools.sh.tmpl 'include "dot_config/mise/config.toml" | sha256sum' &&
    assert_repo_contains dot_bashrc 'mise activate bash'
}

test_chezmoi_platform_contract() {
  assert_repo_contains .chezmoi.toml.tmpl 'desktop = "hyprland"' &&
    assert_repo_contains .chezmoi.toml.tmpl 'desktop = "none"' &&
    assert_repo_contains .chezmoiignore.tmpl '{{ if ne .chezmoi.os "linux" }}' &&
    assert_repo_contains .chezmoiignore.tmpl 'dot_config/hypr/**' &&
    assert_repo_contains .chezmoiignore.tmpl 'dot_config/environment.d/**' &&
    assert_repo_contains .chezmoiignore.tmpl 'dot_local/bin/executable_rbw-menu' &&
    assert_repo_contains .chezmoiignore.tmpl 'dot_local/bin/executable_rbw-pinentry' &&
    ! grep -F 'gnome' "$ROOT_DIR/.chezmoi.toml.tmpl" >/dev/null 2>&1 &&
    ! grep -F 'kde' "$ROOT_DIR/.chezmoi.toml.tmpl" >/dev/null 2>&1
}

test_dark_mode_applied_on_session_start() {
  assert_repo_contains dot_local/bin/executable_set-dark-mode 'gsettings set org.gnome.desktop.interface color-scheme prefer-dark' &&
    assert_repo_contains dot_local/bin/executable_set-dark-mode 'systemctl --user try-restart xdg-desktop-portal.service xdg-desktop-portal-gtk.service' &&
    assert_repo_contains run_onchange_after_set-dark-mode.sh.tmpl '"$HOME/.local/bin/set-dark-mode"' &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl 'exec-once = ~/.local/bin/set-dark-mode'
}

test_chezmoi_workflow_contract() {
  assert_repo_contains AGENTS.md 'chezmoi source-path' &&
    assert_repo_contains AGENTS.md 'chezmoi diff' &&
    assert_repo_contains AGENTS.md 'chezmoi apply' &&
    assert_repo_contains AGENTS.md 'chezmoi re-add' &&
    assert_repo_contains AGENTS.md 'source changes' &&
    assert_repo_contains install.sh 'chezmoi init --apply' &&
    assert_repo_contains install.sh "--promptString 'hostname=\$HOSTNAME'" &&
    assert_repo_contains install.sh "--promptBool 'is_laptop=\$IS_LAPTOP'" &&
    assert_repo_contains install.sh "--promptString 'gpu (intel, amd, or none)=\$GPU'" &&
    assert_repo_contains install.sh "--promptInt 'border_size=\$BORDER'" &&
    assert_repo_contains install.sh "--promptBool 'tablet_mode_enabled=\$TABLET_MODE_ENABLED'" &&
    assert_repo_contains install.sh "--promptString 'tablet_disable_devices (space-separated hyprctl device names)=\$TABLET_DISABLE_DEVICES'" &&
    assert_repo_contains .chezmoi.toml.tmpl 'tablet_switch_name = {{ promptString "tablet_switch_name (e.g. gpio-keys)" | quote }}'
}

test_flatpak_package_contract() {
  assert_repo_contains package-sets.sh 'app.zen_browser.zen' &&
    assert_repo_contains package-sets.sh 'org.localsend.localsend_app' &&
    assert_repo_contains DESKTOPS.md 'org.localsend.localsend_app' &&
    ! grep -F 'com.bitwarden.desktop' "$ROOT_DIR/package-sets.sh" >/dev/null 2>&1
}

test_rbw_package_contract() {
  assert_repo_contains package-sets.sh 'github-cli direnv mise lazygit lazydocker openssh rbw rofi-rbw wtype gum' &&
    assert_repo_contains DESKTOPS.md 'pacman -Q openssh rbw rofi-rbw wtype gum' &&
    assert_repo_contains dot_bashrc 'SSH_AUTH_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/rbw/ssh-agent-socket"' &&
    assert_repo_contains dot_config/environment.d/rbw-ssh-agent.conf 'SSH_AUTH_SOCK=${XDG_RUNTIME_DIR}/rbw/ssh-agent-socket' &&
    assert_repo_contains dot_config/systemd/user/rbw-agent.service 'ExecStart=/usr/bin/rbw-agent --no-daemonize' &&
    assert_repo_contains dot_config/systemd/user/rbw-agent.service 'ConditionPathExists=%h/.config/rbw/config.json' &&
    assert_repo_contains dot_local/bin/executable_rbw-menu 'rofi-rbw' &&
    assert_repo_contains dot_local/bin/executable_rbw-menu '--typer wtype' &&
    assert_repo_contains dot_local/bin/executable_rbw-menu 'rbw config set pinentry "$HOME/.local/bin/rbw-pinentry"' &&
    assert_repo_contains dot_local/bin/executable_rbw-pinentry.tmpl 'GDK_SCALE="${PINENTRY_GDK_SCALE:-{{ if ge .monitor_scale "1.5" }}2{{ else }}1{{ end }}}"' &&
    assert_repo_contains dot_local/bin/executable_rbw-menu 'Missing $command; install rbw and rofi-rbw' &&
    assert_repo_contains dot_local/bin/executable_rbw-menu 'Set server (current: %s)' &&
    assert_repo_contains dot_local/bin/executable_rbw-menu 'rbw config set base_url "$url"' &&
    assert_repo_contains dot_local/bin/executable_rbw-menu 'rbw config unset base_url' &&
    assert_repo_contains dot_local/lib/rbw-clipboard/executable_wl-copy '--sensitive'
}

test_package_inventory_contract() {
  assert_repo_contains package-sets.sh 'ARCH_COMMON_PACKAGES=' &&
    assert_repo_contains package-sets.sh 'ARCH_HYPRLAND_PACKAGES=' &&
    assert_repo_contains package-sets.sh 'ARCH_PROFILE_FRAMEWORK12_PACKAGES=' &&
    assert_repo_contains package-sets.sh 'ARCH_AUR_PACKAGES=' &&
    assert_repo_contains package-sets.sh 'ARCH_FLATPAK_PACKAGES=' &&
    assert_repo_contains package-sets.sh 'MACOS_BREW_PACKAGES=' &&
    assert_repo_contains install.sh 'load_package_sets' &&
    assert_repo_contains install.sh 'mapfile -t BASE_PACKAGES < <(arch_repo_packages "$PROFILE" "$MICROCODE")' &&
    assert_repo_contains package-sync.sh 'clean --dry-run' &&
    assert_repo_contains package-sync.sh 'pacman -Qqet' &&
    assert_repo_contains package-sync.sh 'brew leaves'
}

test_package_sync_arch_install_uses_shared_sets() {
  bash "$ROOT_DIR/package-sync.sh" install --profile minipc &&
    assert_log_contains "sudo pacman -Syu --needed --noconfirm" &&
    assert_log_contains "pacman -Syu --needed --noconfirm" &&
    assert_log_contains "amd-ucode" &&
    assert_log_contains "hyprland" &&
    assert_log_contains "nwg-drawer" &&
    assert_log_contains "yay -S --needed --noconfirm grimblast-git waypaper wvkbd rofi-power-menu catppuccin-gtk-theme-mocha sunwait iio-hyprland-git" &&
    assert_log_contains "flatpak install --system -y flathub app.zen_browser.zen org.localsend.localsend_app"
}

test_package_sync_arch_clean_dry_run_reports_only() {
  bash "$ROOT_DIR/package-sync.sh" clean --dry-run --profile minipc >"$TEST_TMP/stdout" 2>"$TEST_TMP/stderr" &&
    grep -F 'extra-native' "$TEST_TMP/stdout" >/dev/null &&
    grep -F 'extra-aur' "$TEST_TMP/stdout" >/dev/null &&
    grep -F 'org.extra.App' "$TEST_TMP/stdout" >/dev/null &&
    grep -F 'orphan-lib' "$TEST_TMP/stdout" >/dev/null &&
    grep -F 'orphan-tool' "$TEST_TMP/stdout" >/dev/null &&
    assert_log_not_contains "pacman -Rns" &&
    assert_log_not_contains "yay -Rns" &&
    assert_log_not_contains "flatpak uninstall"
}

test_package_sync_arch_clean_confirm_removes_extras() {
  bash "$ROOT_DIR/package-sync.sh" clean --confirm --profile minipc >"$TEST_TMP/stdout" 2>"$TEST_TMP/stderr" &&
    assert_log_contains "sudo pacman -Rns --noconfirm extra-native" &&
    assert_log_contains "yay -Rns --noconfirm extra-aur" &&
    assert_log_contains "flatpak uninstall --system -y org.extra.App" &&
    assert_log_contains "sudo pacman -Rns --noconfirm orphan-lib orphan-tool"
}

test_package_sync_macos_install_uses_homebrew_cli_set() {
  FAKE_UNAME=Darwin bash "$ROOT_DIR/package-sync.sh" install &&
    assert_log_contains "brew install git neovim starship fzf zoxide bat eza btop ripgrep fd jq tree unzip ncdu duf procs tldr git-delta gh direnv mise lazygit lazydocker openssh gum chezmoi" &&
    assert_log_not_contains "pacman -Syu" &&
    assert_log_not_contains "flatpak install"
}

test_ssh_hosts_contract() {
  assert_repo_contains private_dot_ssh/config 'Include ~/.ssh/config.local' &&
    assert_repo_contains private_dot_ssh/config 'AddKeysToAgent no' &&
    assert_repo_contains dot_local/bin/executable_ssh-hosts 'CONFIG_ITEM="${SSH_HOSTS_CONFIG_ITEM:-ssh/hosts}"' &&
    assert_repo_contains dot_local/bin/executable_ssh-hosts 'gum choose' &&
    assert_repo_contains dot_local/bin/executable_ssh-hosts 'IdentityFile ~/.ssh/rbw/' &&
    assert_repo_contains dot_local/bin/executable_ssh-hosts 'IdentitiesOnly yes' &&
    assert_repo_contains dot_local/bin/executable_ssh-hosts 'setup|init) setup' &&
    assert_repo_contains .chezmoiignore.tmpl 'dot_local/bin/executable_ssh-hosts'
}

test_ssh_hosts_template_is_valid() {
  bash "$ROOT_DIR/dot_local/bin/executable_ssh-hosts" template | jq -e '.hosts[0].alias == "nas" and .keys[0].field == "public key"' >/dev/null
}

test_ssh_hosts_sync_generates_local_config_and_keys() {
  bash "$ROOT_DIR/dot_local/bin/executable_ssh-hosts" sync &&
    assert_log_contains "rbw get ssh/hosts --field config" &&
    assert_log_contains "rbw get ssh/keys/nas --field public key" &&
    assert_file_exists "$HOME/.ssh/config.local" &&
    assert_file_exists "$HOME/.ssh/rbw/nas.pub" &&
    grep -F "Host nas" "$HOME/.ssh/config.local" >/dev/null &&
    grep -F "HostName nas.local" "$HOME/.ssh/config.local" >/dev/null &&
    grep -F "User jack" "$HOME/.ssh/config.local" >/dev/null &&
    grep -F "Port 2222" "$HOME/.ssh/config.local" >/dev/null &&
    grep -F "IdentityFile ~/.ssh/rbw/nas.pub" "$HOME/.ssh/config.local" >/dev/null &&
    grep -F "IdentitiesOnly yes" "$HOME/.ssh/config.local" >/dev/null &&
    grep -F "ForwardAgent no" "$HOME/.ssh/config.local" >/dev/null &&
    grep -F "ssh-ed25519 AAAATEST nas" "$HOME/.ssh/rbw/nas.pub" >/dev/null
}

test_ssh_hosts_missing_config_prints_setup_hint() {
  FAKE_RBW_MISSING_CONFIG=1 bash "$ROOT_DIR/dot_local/bin/executable_ssh-hosts" sync >"$TEST_TMP/stdout" 2>"$TEST_TMP/stderr"
  [ "$?" -ne 0 ] &&
    grep -F "no entry found for ssh/hosts" "$TEST_TMP/stderr" >/dev/null &&
    grep -F "Missing Bitwarden SSH host config." "$TEST_TMP/stderr" >/dev/null &&
    grep -F "ssh-hosts template" "$TEST_TMP/stderr" >/dev/null
}

test_ssh_hosts_test_uses_rbw_agent_socket() {
  XDG_RUNTIME_DIR=/run/user/1000 bash "$ROOT_DIR/dot_local/bin/executable_ssh-hosts" test nas &&
    assert_log_contains "ssh -o BatchMode=yes -T nas" &&
    assert_log_contains "ssh-auth-sock /run/user/1000/rbw/ssh-agent-socket"
}

run_unit_tests() {
  group "Unit/script tests"
  run_case "toggle: auto -> on" test_toggle_auto_to_on
  run_case "toggle: on -> off" test_toggle_on_to_off
  run_case "toggle: off -> auto during day" test_toggle_off_to_auto_day
  run_case "toggle: off -> auto during night" test_toggle_off_to_auto_night
  run_case "toggle: uses configured temperature" test_toggle_uses_configured_temp
  run_case "toggle: missing temperature falls back to 3500K" test_toggle_falls_back_to_default_temp
  run_case "toggle: absent waybar does not fail" test_toggle_waybar_absent_does_not_fail
  run_case "toggle: invalid mode defaults to auto" test_toggle_invalid_mode_defaults_to_auto

  run_case "apply: mode on forces nightlight" test_apply_on_forces_nightlight
  run_case "apply: mode off forces daylight" test_apply_off_forces_daylight
  run_case "apply: auto day disables nightlight" test_apply_day_clears_night
  run_case "apply: auto day already off reapplies daylight" test_apply_day_already_off_noop
  run_case "apply: auto night enables nightlight" test_apply_night_enables
  run_case "apply: auto night already on reapplies temperature" test_apply_night_already_on_noop
  run_case "apply: invalid mode defaults to auto" test_apply_invalid_mode_defaults_to_auto

  run_case "status: auto off emits valid JSON" test_status_auto_off_json
  run_case "status: auto on emits valid JSON" test_status_auto_on_json
  run_case "status: forced on mode" test_status_forced_on_json
  run_case "status: forced off mode" test_status_forced_off_json
  run_case "status: desired on ignores absent process" test_status_expected_on_when_process_absent
  run_case "status: desired off ignores identity process" test_status_expected_off_when_process_present
  run_case "status: malformed sunwait report still emits JSON" test_status_malformed_sunwait_still_json
  run_case "status: daylight line wins over astronomical twilight" test_status_uses_daylight_not_astronomical_twilight
  run_case "status: timedatectl fallback timezone" test_status_timedatectl_fallback
  run_case "neovim: mise-managed toolchain contract" test_neovim_toolchain_contract
  run_case "chezmoi: linux hyprland and mac shared config contract" test_chezmoi_platform_contract
  run_case "chezmoi: dark mode applies on graphical session start" test_dark_mode_applied_on_session_start
  run_case "chezmoi: idiomatic workflow and installer contract" test_chezmoi_workflow_contract
  run_case "flatpak: package install contract" test_flatpak_package_contract
  run_case "rbw: package and config contract" test_rbw_package_contract
  run_case "packages: shared inventory contract" test_package_inventory_contract
  run_case "packages: Arch install uses shared sets" test_package_sync_arch_install_uses_shared_sets
  run_case "packages: Arch clean dry-run reports only" test_package_sync_arch_clean_dry_run_reports_only
  run_case "packages: Arch clean confirm removes extras" test_package_sync_arch_clean_confirm_removes_extras
  run_case "packages: macOS install uses Homebrew CLI set" test_package_sync_macos_install_uses_homebrew_cli_set
  run_case "ssh hosts: package and config contract" test_ssh_hosts_contract
  run_case "ssh hosts: template is valid JSON" test_ssh_hosts_template_is_valid
}

run_gui_tests() {
  group "GUI/preview diagnostic tests"
  run_case "picker: accepted value previews without saving" test_picker_first_selection_previews_without_save
  run_case "picker: same value twice confirms and saves" test_picker_same_selection_confirms
  run_case "picker: opens at current live temperature" test_picker_opens_at_current_live_temp
  run_case "picker: same current preview is no-op" test_picker_same_current_preview_noop
  run_case "picker: ignores rofi startup first-row preview" test_picker_ignores_rofi_initial_first_row_preview
  run_case "picker: different accepted values preview each" test_picker_different_selections_preview_each
  run_case "picker: cancel restores previous temp when active" test_picker_cancel_restores_previous_when_on
  run_case "picker: cancel while inactive does not restore" test_picker_cancel_inactive_does_not_restore
  run_case "picker: save while off restores off state" test_picker_save_while_off_restores_off_state
  run_case "picker: missing config dir can save" test_picker_missing_config_dir_saves
  run_case "settings: launches picker and signals waybar" test_settings_launches_picker_and_signals_waybar
  run_case "picker: highlight navigation previews before confirmation" test_true_highlight_preview_before_confirm
}

run_hyprland_environment_tests() {
  group "Hyprland environment tests"
  run_case "updates: disabled emits JSON" test_updates_check_disabled_json
  run_case "updates: counts official and AUR updates" test_updates_check_counts_official_and_aur
  run_case "updates: fresh cache avoids package checks" test_updates_check_uses_fresh_cache
  run_case "updates: force ignores fresh cache" test_updates_check_force_ignores_fresh_cache
  run_case "updates menu: check now invalidates cache and signals waybar" test_update_menu_check_now
  run_case "updates menu: toggle disables auto-check" test_update_menu_toggle_disables_and_signals
  run_case "updates menu: toggle enables auto-check" test_update_menu_toggle_enables_and_signals
  run_case "sysmon: emits Waybar JSON" test_sysmon_emits_waybar_json
  run_case "osk: starts when absent" test_osk_toggle_starts_when_absent
  run_case "osk: signals when present" test_osk_toggle_signals_when_present
  run_case "app launcher: prefers touch drawer" test_app_launcher_prefers_touch_drawer
  run_case "tablet mode: enters tablet state" test_tablet_mode_enters_tablet_state
  run_case "tablet mode: returns to laptop state" test_tablet_mode_returns_to_laptop_state
  run_case "tablet mode: toggles rotation lock" test_tablet_mode_rotation_lock_status
  run_case "tablet mode: emits Waybar JSON" test_tablet_mode_status_emits_waybar_json
  run_case "wallpaper: random image applies via awww" test_wallpaper_random_applies_image
  run_case "wallpaper: checkout runs after chezmoi apply" test_wallpaper_checkout_runs_after_chezmoi_apply
  run_case "clipboard: rofi selection is decoded to wl-copy" test_rofi_clipboard_decodes_to_wl_copy
  run_case "rbw menu: locked state shows setup actions" test_rbw_menu_locked_shows_setup_actions
  run_case "rbw menu: configured locked state orders common actions first" test_rbw_menu_configured_locked_orders_common_actions_first
  run_case "rbw menu: unlocked state shows credentials and config" test_rbw_menu_unlocked_shows_credentials_and_config
  run_case "rbw menu: unlocked state orders common actions first" test_rbw_menu_unlocked_orders_common_actions_first
  run_case "rbw menu: credentials launches rofi-rbw" test_rbw_menu_credentials_launches_rofi_rbw
  run_case "rbw menu: set email configures defaults" test_rbw_menu_set_email_configures_defaults
  run_case "rbw menu: reports missing rbw on config action" test_rbw_menu_reports_missing_rbw_on_config_action
  run_case "rbw menu: set server configures base url" test_rbw_menu_set_server_configures_base_url
  run_case "rbw menu: reset server unsets urls" test_rbw_menu_reset_server_unsets_urls
  run_case "rbw clipboard: marks copied secrets sensitive" test_rbw_clipboard_wrapper_marks_sensitive
  run_case "ssh hosts: sync generates local config and keys" test_ssh_hosts_sync_generates_local_config_and_keys
  run_case "ssh hosts: missing config prints setup hint" test_ssh_hosts_missing_config_prints_setup_hint
  run_case "ssh hosts: test uses rbw agent socket" test_ssh_hosts_test_uses_rbw_agent_socket
  run_case "keybind help: reads Hyprland binds and opens rofi" test_keybind_help_uses_hyprctl_and_rofi
  run_case "power menu: lock runs hyprlock" test_power_menu_lock_runs_hyprlock
  run_case "power menu: lock is no-op when already locked" test_power_menu_lock_is_noop_when_already_locked
  run_case "power menu: suspend runs system suspend" test_power_menu_suspend_runs_system_suspend
  run_case "power menu: log out requires confirmation" test_power_menu_logout_requires_confirmation
  run_case "power menu: log out cancel does nothing" test_power_menu_logout_cancel_does_nothing
  run_case "power menu: reboot requires confirmation" test_power_menu_reboot_requires_confirmation
  run_case "power menu: shut down requires confirmation" test_power_menu_shutdown_requires_confirmation
  run_case "power menu: escape does nothing" test_power_menu_escape_does_nothing
  run_case "hyprland: autostart contract" test_hyprland_autostart_contract
  run_case "hyprland: keybind contract" test_hyprland_keybind_contract
  run_case "hyprland: tablet mode contract" test_hyprland_tablet_mode_contract
  run_case "framework12: tablet mode initramfs contract" test_framework12_tablet_mode_initramfs_contract
  run_case "hypridle: lock/sleep contract" test_hypridle_lock_sleep_contract
  run_case "hyprlock: lock screen contract" test_hyprlock_contract
  run_case "waybar: environment modules contract" test_waybar_environment_modules_contract
  run_case "rofi/mako: style contract" test_rofi_mako_style_contract
}

case "$MODE" in
  --unit)
    run_unit_tests
    ;;
  --gui)
    run_gui_tests
    ;;
  --all)
    run_unit_tests
    run_gui_tests
    run_hyprland_environment_tests
    ;;
  *)
    echo "Usage: $0 [--all|--unit|--gui]" >&2
    exit 2
    ;;
esac

printf '\n%d tests, %d failed\n' "$TOTAL" "$FAILED"
[ "$FAILED" -eq 0 ]
