#!/bin/zsh
set -eu
setopt pipefail

readonly PROJECT_DIR="${0:A:h:h}"
readonly MOCK_ROOT=$(/usr/bin/mktemp -d /private/tmp/shay-mock.XXXXXX)
readonly MOCK_BIN="$MOCK_ROOT/bin"
readonly STATE_DIR="$MOCK_ROOT/state"
readonly LOCK_PATH="$MOCK_ROOT/lock"
readonly SHAY_BINARY="${SHAY_BINARY:-/private/tmp/shay-native-test}"
trap '/bin/rm -rf "$MOCK_ROOT"' EXIT INT TERM

/bin/mkdir -p "$MOCK_BIN"
for command in pmset thermal launchctl; do
  /bin/ln -s "$PROJECT_DIR/tests/mock-command" "$MOCK_BIN/$command"
done

fail() {
  print -u2 -r -- "mock test failed: $*"
  exit 1
}

assert_file_value() {
  local path="$1" expected="$2"
  [[ -r "$path" ]] || fail "missing file: $path"
  [[ "$(<"$path")" == "$expected" ]] || fail "$path did not contain $expected"
}

run_helper() {
  /usr/bin/env \
    SHAY_TEST_MODE=1 \
    SHAY_PMSET="$MOCK_BIN/pmset" \
    SHAY_THERMAL="$MOCK_BIN/thermal" \
    SHAY_LAUNCHCTL="$MOCK_BIN/launchctl" \
    SHAY_STATE_DIR="$STATE_DIR" \
    SHAY_LOCK_PATH="$LOCK_PATH" \
    SHAY_MOCK_ROOT="$MOCK_ROOT" \
    "$SHAY_BINARY" "$@"
}

reset_fixture() {
  /bin/rm -rf "$STATE_DIR"
  /bin/rm -f "$LOCK_PATH"
  /bin/mkdir -p "$STATE_DIR"
  print -r -- "80" >| "$MOCK_ROOT/battery"
  print -r -- "Battery Power" >| "$MOCK_ROOT/power_source"
  print -r -- "0 nominal" >| "$MOCK_ROOT/thermal"
  print -r -- "0" >| "$MOCK_ROOT/sleep_disabled"
  print -r -- "1" >| "$MOCK_ROOT/guard_loaded"
  /bin/rm -f "$MOCK_ROOT"/fail_set_*(N) "$MOCK_ROOT"/ignore_set_*(N)
}

# Healthy enable/disable transition.
reset_fixture
run_helper on >/dev/null
assert_file_value "$MOCK_ROOT/sleep_disabled" "1"
[[ -e "$STATE_DIR/enabled" ]] || fail "enable marker missing"
run_helper off >/dev/null
assert_file_value "$MOCK_ROOT/sleep_disabled" "0"
[[ ! -e "$STATE_DIR/enabled" ]] || fail "enable marker survived off"

# Optional expiry persists, renders, and restores sleep when due.
reset_fixture
future=$(( $(/bin/date +%s) + 3600 ))
print -r -- "$future" | run_helper on-expiring >/dev/null
assert_file_value "$STATE_DIR/expires_at" "$future"
expiry_status=$(NO_COLOR=1 run_helper status)
[[ "$expiry_status" == *"Expiry"* && "$expiry_status" != *"Expiry      never"* ]] || fail "expiry status rendering"
print -r -- "$(( $(/bin/date +%s) - 1 ))" >| "$STATE_DIR/expires_at"
run_helper guard
assert_file_value "$MOCK_ROOT/sleep_disabled" "0"
assert_file_value "$STATE_DIR/last_reason" "expired"
[[ ! -e "$STATE_DIR/expires_at" ]] || fail "expired deadline survived guard"

# Corrupt expiry state fails closed.
reset_fixture
run_helper on >/dev/null
print -r -- "corrupt" >| "$STATE_DIR/expires_at"
run_helper guard
assert_file_value "$MOCK_ROOT/sleep_disabled" "0"
assert_file_value "$STATE_DIR/last_reason" "expiry_reading_unavailable"

# Boundary and thermal checks fail closed before activation.
reset_fixture
print -r -- "25" >| "$MOCK_ROOT/battery"
if run_helper on >/dev/null 2>&1; then fail "enabled at the 25% cutoff"; fi
assert_file_value "$MOCK_ROOT/sleep_disabled" "0"

reset_fixture
print -r -- "2 serious" >| "$MOCK_ROOT/thermal"
if run_helper on >/dev/null 2>&1; then fail "enabled under serious thermal pressure"; fi
assert_file_value "$MOCK_ROOT/sleep_disabled" "0"

# Missing launchd guard blocks activation.
reset_fixture
print -r -- "0" >| "$MOCK_ROOT/guard_loaded"
if run_helper on >/dev/null 2>&1; then fail "enabled without a loaded guard"; fi

# Low battery and failed sensors trip an already-active guard.
reset_fixture
run_helper on >/dev/null
print -r -- "25" >| "$MOCK_ROOT/battery"
run_helper guard
assert_file_value "$MOCK_ROOT/sleep_disabled" "0"
assert_file_value "$STATE_DIR/last_reason" "battery_25_percent"

reset_fixture
run_helper on >/dev/null
print -r -- "fail" >| "$MOCK_ROOT/thermal"
run_helper guard
assert_file_value "$MOCK_ROOT/sleep_disabled" "0"
assert_file_value "$STATE_DIR/last_reason" "thermal_reading_unavailable"

# A failed restore preserves the marker so launchd can retry next interval.
reset_fixture
run_helper on >/dev/null
print -r -- "25" >| "$MOCK_ROOT/battery"
/usr/bin/touch "$MOCK_ROOT/fail_set_0"
if run_helper guard >/dev/null 2>&1; then fail "guard reported success after restore failure"; fi
[[ -e "$STATE_DIR/enabled" ]] || fail "restore failure removed retry marker"
assert_file_value "$MOCK_ROOT/sleep_disabled" "1"
/bin/rm -f "$MOCK_ROOT/fail_set_0"
run_helper guard
assert_file_value "$MOCK_ROOT/sleep_disabled" "0"

# A successful command with a wrong postcondition is rejected.
reset_fixture
/usr/bin/touch "$MOCK_ROOT/ignore_set_1"
if run_helper on >/dev/null 2>&1; then fail "accepted an unverifiable enable"; fi
[[ ! -e "$STATE_DIR/enabled" ]] || fail "failed enable left a marker"

# External policy drift is reasserted while active.
reset_fixture
run_helper on >/dev/null
print -r -- "0" >| "$MOCK_ROOT/sleep_disabled"
run_helper guard
assert_file_value "$MOCK_ROOT/sleep_disabled" "1"
assert_file_value "$STATE_DIR/last_reason" "active_reasserted"

# A symlink cannot redirect the privileged lock operation.
/bin/rm -f "$LOCK_PATH"
/bin/ln -s "$MOCK_ROOT/attacker-lock" "$LOCK_PATH"
if run_helper guard >/dev/null 2>&1; then fail "accepted a symlink lock"; fi
/bin/rm -f "$LOCK_PATH"

# Rendering honors NO_COLOR and emits ANSI when explicitly requested.
plain_status=$(NO_COLOR=1 run_helper status)
[[ "$plain_status" == *"Expiry"* && "$plain_status" == *"Watchdog"* && "$plain_status" == *"O.O"* && "$plain_status" == *"╔════════════╗"* && "$plain_status" == *"┌────────┐"* && "$plain_status" != *$'\e['* ]] || fail "plain rendering"
color_status=$(SHAY_FORCE_COLOR=1 run_helper status)
[[ "$color_status" == *$'\e['* && "$color_status" == *"O.O"* ]] || fail "colored rendering"

print -r -- "0" >| "$MOCK_ROOT/sleep_disabled"
degraded_status=$(NO_COLOR=1 run_helper status)
[[ "$degraded_status" == *"!.!"* ]] || fail "degraded face rendering"

run_helper off >/dev/null
sleeping_status=$(NO_COLOR=1 run_helper status)
[[ "$sleeping_status" == *"-_-"* ]] || fail "sleeping face rendering"

print "mock safety tests passed"
