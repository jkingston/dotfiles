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
  make_fake_bin swww '#!/usr/bin/env bash
printf "swww %s\n" "$*" >> "$FAKE_LOG"
'
  make_fake_bin git '#!/usr/bin/env bash
printf "git %s\n" "$*" >> "$FAKE_LOG"
'
  make_fake_bin hyprctl '#!/usr/bin/env bash
printf "hyprctl %s\n" "$*" >> "$FAKE_LOG"
if [ "${1:-}" = "cursorpos" ]; then
  echo "100,200"
elif [ "${1:-}" = "-j" ] && [ "${2:-}" = "binds" ]; then
  printf "%s\n" "[{\"modmask\":64,\"key\":\"Return\",\"dispatcher\":\"exec\",\"arg\":\"uwsm app -- ghostty\"},{\"modmask\":65,\"key\":\"B\",\"dispatcher\":\"exec\",\"arg\":\"uwsm app -- librewolf\"}]"
fi
'
  make_fake_bin shuf '#!/usr/bin/env bash
sed -n "1p"
'
  make_fake_bin wvkbd-mobintl '#!/usr/bin/env bash
printf "wvkbd-mobintl %s\n" "$*" >> "$FAKE_LOG"
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

  export HOME="$TEST_HOME"
  export PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
  export FAKE_LOG ROFI_QUEUE
  unset FAKE_PKILL_FAIL_WAYBAR FAKE_PGREP_MATCH FAKE_PIDOF_MATCH FAKE_SUNWAIT_POLL FAKE_SUNWAIT_REPORT FAKE_TIME_DATE_CTL_FAIL FAKE_TIMEZONE FAKE_CHECKUPDATES FAKE_YAY_UPDATES
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
    assert_log_contains "wvkbd-mobintl --landscape --opacity 0.98 --rounding 10 --hidden"
}

test_osk_toggle_stops_when_present() {
  export FAKE_PGREP_MATCH=wvkbd-mobintl
  run_script dot_local/bin/executable_osk-toggle &&
    assert_log_contains "pkill -x wvkbd-mobintl"
}

test_wallpaper_random_applies_image() {
  run_script dot_local/bin/executable_wallpaper-random &&
    assert_log_contains "hyprctl cursorpos" &&
    assert_log_contains "swww img $HOME/Pictures/Wallpapers/test.png" &&
    assert_log_contains "--transition-type grow"
}

test_wallpaper_sync_skips_when_image_exists() {
  run_script dot_local/bin/executable_wallpaper-sync &&
    assert_log_not_contains "git clone"
}

test_wallpaper_sync_clones_when_empty() {
  rm -f "$HOME/Pictures/Wallpapers/test.png"
  run_script dot_local/bin/executable_wallpaper-sync &&
    assert_log_contains "git clone --depth 1 https://github.com/Gingeh/wallpapers.git $HOME/Pictures/Wallpapers/catppuccin"
}

test_rofi_clipboard_decodes_to_wl_copy() {
  printf 'clip-entry\n' > "$ROFI_QUEUE"
  run_script dot_local/bin/executable_rofi-clipboard &&
    assert_log_contains "cliphist list" &&
    assert_log_contains "cliphist decode" &&
    assert_log_contains "wl-copy" &&
    assert_log_contains "clip-entry"
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
  assert_repo_contains dot_config/hypr/hyprland.conf.tmpl "exec-once = uwsm app -- waybar" &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl "exec-once = uwsm app -- mako" &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl "exec-once = uwsm app -- swayosd-server" &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl "exec-once = wl-paste --watch cliphist store" &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl "exec-once = hypridle" &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl "wallpaper-sync.timer" &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl "exec-once = swww-daemon && ~/.local/bin/wallpaper-random"
}

test_hyprland_keybind_contract() {
  assert_repo_contains dot_config/hypr/hyprland.conf.tmpl 'bind = $mod, SPACE, exec, uwsm app -- rofi -show drun' &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl "bind = , Print, exec, grimblast edit area" &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl 'bind = $mod_ctrl, V, exec, ~/.local/bin/rofi-clipboard' &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl 'bind = $mod_ctrl, I, exec, hyprlock' &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl 'bind = $mod, ESCAPE, exec, uwsm app -- ~/.local/bin/hypr-power-menu' &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl "bindel = , XF86MonBrightnessUp, exec, swayosd-client --brightness raise" &&
    assert_repo_contains dot_config/hypr/hyprland.conf.tmpl "bindl = , switch:on:Lid Switch, exec, loginctl lock-session"
}

test_hypridle_lock_sleep_contract() {
  assert_repo_contains dot_config/hypr/hypridle.conf "lock_cmd = pidof hyprlock || hyprlock" &&
    assert_repo_contains dot_config/hypr/hypridle.conf "before_sleep_cmd = loginctl lock-session" &&
    assert_repo_contains dot_config/hypr/hypridle.conf "after_sleep_cmd = hyprctl dispatch dpms on && systemctl --user restart waybar && ~/.local/bin/hyprsunset-apply" &&
    assert_repo_contains dot_config/hypr/hypridle.conf "timeout = 300" &&
    assert_repo_contains dot_config/hypr/hypridle.conf "timeout = 330" &&
    assert_repo_contains dot_config/hypr/hypridle.conf "timeout = 600" &&
    assert_repo_contains dot_config/hypr/hypridle.conf "on-timeout = systemctl suspend"
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
    assert_repo_contains dot_config/waybar/config.tmpl "\"custom/updates\"" &&
    assert_repo_contains dot_config/waybar/config.tmpl "\"custom/sysmon\"" &&
    assert_repo_contains dot_config/waybar/config.tmpl "\"idle_inhibitor\"" &&
    assert_repo_contains dot_config/waybar/config.tmpl "\"backlight\"" &&
    assert_repo_contains dot_config/waybar/config.tmpl "\"battery\"" &&
    assert_repo_contains dot_config/waybar/config.tmpl "\"on-click\": \"ghostty --class=com.floating.tui -e pulsemixer\"" &&
    assert_repo_contains dot_config/waybar/config.tmpl "\"on-click-right\": \"wpctl set-mute @DEFAULT_SINK@ toggle\"" &&
    assert_repo_contains dot_config/waybar/config.tmpl "\"on-click\": \"~/.local/bin/hypr-power-menu\"" &&
    assert_repo_contains dot_config/waybar/config.tmpl "\"on-scroll-up\": \"swayosd-client --brightness raise\""
}

test_rofi_mako_style_contract() {
  assert_repo_contains dot_config/rofi/config.rasi "modi: \"drun,run,calc\"" &&
    assert_repo_contains dot_config/rofi/config.rasi "terminal: \"ghostty\"" &&
    assert_repo_contains dot_config/rofi/config.rasi "border-radius: 0px" &&
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
    assert_repo_contains run_onchange_after_install-mise-tools.sh.tmpl 'mise install --yes --cd "$HOME"' &&
    assert_repo_contains run_onchange_after_install-mise-tools.sh.tmpl 'include "dot_config/mise/config.toml" | sha256sum' &&
    assert_repo_contains dot_bashrc 'mise activate bash'
}

test_chezmoi_platform_contract() {
  assert_repo_contains .chezmoi.toml.tmpl 'desktop = "hyprland"' &&
    assert_repo_contains .chezmoi.toml.tmpl 'desktop = "none"' &&
    assert_repo_contains .chezmoiignore.tmpl '{{ if ne .chezmoi.os "linux" }}' &&
    assert_repo_contains .chezmoiignore.tmpl 'dot_config/hypr/**' &&
    ! grep -F 'gnome' "$ROOT_DIR/.chezmoi.toml.tmpl" >/dev/null 2>&1 &&
    ! grep -F 'kde' "$ROOT_DIR/.chezmoi.toml.tmpl" >/dev/null 2>&1
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
  run_case "updates menu: check now invalidates cache and signals waybar" test_update_menu_check_now
  run_case "updates menu: toggle disables auto-check" test_update_menu_toggle_disables_and_signals
  run_case "updates menu: toggle enables auto-check" test_update_menu_toggle_enables_and_signals
  run_case "sysmon: emits Waybar JSON" test_sysmon_emits_waybar_json
  run_case "osk: starts when absent" test_osk_toggle_starts_when_absent
  run_case "osk: stops when present" test_osk_toggle_stops_when_present
  run_case "wallpaper: random image applies via swww" test_wallpaper_random_applies_image
  run_case "wallpaper: sync skips when image exists" test_wallpaper_sync_skips_when_image_exists
  run_case "wallpaper: sync clones when empty" test_wallpaper_sync_clones_when_empty
  run_case "clipboard: rofi selection is decoded to wl-copy" test_rofi_clipboard_decodes_to_wl_copy
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
