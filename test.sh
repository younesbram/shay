#!/bin/zsh
set -eu
setopt pipefail

readonly PROJECT_DIR="${0:A:h}"
readonly STAGE=$(/usr/bin/mktemp -d /private/tmp/shay-test.XXXXXX)
readonly -a CORE_SOURCES=(
  "$PROJECT_DIR/src/Controller.swift"
  "$PROJECT_DIR/src/Models.swift"
  "$PROJECT_DIR/src/Renderer.swift"
  "$PROJECT_DIR/src/StateStore.swift"
  "$PROJECT_DIR/src/SystemClient.swift"
)
trap '/bin/rm -rf "$STAGE"' EXIT INT TERM

/usr/bin/plutil -lint "$PROJECT_DIR/org.shaycli.guard.plist"
/bin/zsh -n "$PROJECT_DIR/install.sh"
/bin/zsh -n "$PROJECT_DIR/uninstall.sh"
/usr/bin/xcrun swiftc -warnings-as-errors \
  -target "$(/usr/bin/uname -m)-apple-macosx13.0" \
  "${CORE_SOURCES[@]}" "$PROJECT_DIR/src/main.swift" \
  -o "$STAGE/shay"
"$STAGE/shay" selftest
[[ "$("$STAGE/shay" protocol-version)" == "5" ]] || {
  print -u2 "helper protocol version test failed"
  exit 1
}
[[ "$("$STAGE/shay" --version)" =~ '^shay [0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]+$' ]] || {
  print -u2 "release version mismatch"
  exit 1
}
/usr/bin/xcrun swiftc -warnings-as-errors -parse-as-library \
  -target "$(/usr/bin/uname -m)-apple-macosx13.0" \
  "${CORE_SOURCES[@]}" "$PROJECT_DIR/tests/native.swift" \
  -o "$STAGE/native-tests"
"$STAGE/native-tests"

case $(/usr/bin/xcrun swift -e 'import Foundation; print(ProcessInfo.processInfo.thermalState.rawValue)') in
  0) thermal="nominal" ;;
  1) thermal="fair" ;;
  2) thermal="serious" ;;
  3) thermal="critical" ;;
  *) thermal="unknown" ;;
esac

battery=$(/usr/bin/pmset -g batt | /usr/bin/sed -nE 's/.*[[:space:]]([0-9]+)%;.*/\1/p' | /usr/bin/head -n 1)
if [[ -n "$battery" ]]; then
  [[ "$battery" == <-> ]] && (( battery >= 0 && battery <= 100 )) || {
    print -u2 "invalid battery output: $battery"
    exit 1
  }
else
  battery="unavailable"
fi

{
  print -r -- "testuser ALL=(root) NOPASSWD: sha256:0000000000000000000000000000000000000000000000000000000000000000 /usr/local/libexec/shay-core on"
  print -r -- "testuser ALL=(root) NOPASSWD: sha256:0000000000000000000000000000000000000000000000000000000000000000 /usr/local/libexec/shay-core on-expiring"
  print -r -- "testuser ALL=(root) NOPASSWD: sha256:0000000000000000000000000000000000000000000000000000000000000000 /usr/local/libexec/shay-core off"
} > "$STAGE/sudoers"
/usr/sbin/visudo -cf "$STAGE/sudoers"

typeset -gi ACTIVE_PID=0
unsetopt BG_NICE
source <(/usr/bin/sed -n '/^run_with_progress()/,/^}/p' "$PROJECT_DIR/install.sh")
progress=$(run_with_progress "Progress test" "$STAGE/progress.log" /usr/bin/true)
[[ "$progress" == *"✓ Progress test"* ]] || {
  print -u2 "installer progress success test failed"
  exit 1
}
progress_code=0
run_with_progress "Expected failure" "$STAGE/progress-failure.log" /usr/bin/false >/dev/null 2>&1 || progress_code=$?
[[ "$progress_code" == "1" ]] || {
  print -u2 "installer progress failure test failed"
  exit 1
}
print "installer progress tests passed"

SHAY_BINARY="$STAGE/shay" /bin/zsh "$PROJECT_DIR/tests/mock-safety.sh"

if /usr/bin/grep -R -n -E '/Users/[[:alnum:]_.-]+/' \
  "$PROJECT_DIR/src" "$PROJECT_DIR/tests" "$PROJECT_DIR/README.md" "$PROJECT_DIR"/*.sh \
  "$PROJECT_DIR"/*.plist; then
  print -u2 "personal hardcoding detected"
  exit 1
fi

[[ "$battery" == "unavailable" ]] && battery_summary="unavailable" || battery_summary="${battery}%"
print "tests passed (battery=${battery_summary}, thermal=${thermal})"
