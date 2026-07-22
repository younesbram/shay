#!/bin/zsh
set -eu
setopt pipefail
unsetopt BG_NICE

readonly PROJECT_DIR="${0:A:h}"
readonly -a CORE_SOURCES=(
  "$PROJECT_DIR/src/Controller.swift"
  "$PROJECT_DIR/src/Models.swift"
  "$PROJECT_DIR/src/Renderer.swift"
  "$PROJECT_DIR/src/StateStore.swift"
  "$PROJECT_DIR/src/SystemClient.swift"
)
readonly TARGET_USER="${1:-${SUDO_USER:-}}"
readonly LABEL="org.shaycli.guard"
readonly PLIST="/Library/LaunchDaemons/$LABEL.plist"
readonly PLIST_SOURCE="$PROJECT_DIR/$LABEL.plist"
readonly STATE_DIR="/var/db/shay"
readonly CORE="/usr/local/libexec/shay-core"
readonly CLI="/usr/local/bin/shay"
readonly PROTOCOL_VERSION=5

(( EUID == 0 )) || {
  print -u2 "usage: sudo $0 [macOS-user]"
  exit 1
}

[[ -n "$TARGET_USER" && "$TARGET_USER" =~ '^[A-Za-z0-9._-]+$' ]] || {
  print -u2 "invalid or missing macOS user"
  exit 1
}

/usr/bin/id "$TARGET_USER" >/dev/null 2>&1 || {
  print -u2 "unknown macOS user: $TARGET_USER"
  exit 1
}

readonly TARGET_HOME=$(/usr/bin/dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory | /usr/bin/awk '{print $2}')
readonly TARGET_GROUP=$(/usr/bin/id -gn "$TARGET_USER")
readonly LEGACY_CLI="$TARGET_HOME/.local/bin/shay"
readonly STAGE=$(/usr/bin/mktemp -d /private/tmp/shay-install.XXXXXX)
typeset -gi ACTIVE_PID=0

cleanup() {
  if (( ACTIVE_PID > 0 )); then
    /bin/kill "$ACTIVE_PID" 2>/dev/null || true
    local attempts=0
    while /bin/kill -0 "$ACTIVE_PID" 2>/dev/null && (( attempts < 20 )); do
      /bin/sleep 0.1
      (( attempts += 1 ))
    done
    /bin/kill -9 "$ACTIVE_PID" 2>/dev/null || true
    wait "$ACTIVE_PID" 2>/dev/null || true
  fi
  # Installation and every failure path end in the safe policy state.
  /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1 || true
  /bin/rm -rf "$STAGE"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

run_with_progress() {
  local label="$1" log_file="$2"
  shift 2
  local started=$SECONDS elapsed=0 result_code=0 frame=1
  local -a frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

  "$@" >"$log_file" 2>&1 &
  ACTIVE_PID=$!

  if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
    while /bin/kill -0 "$ACTIVE_PID" 2>/dev/null; do
      elapsed=$(( SECONDS - started ))
      printf '\r  %s %s · %ss' "$frames[$frame]" "$label" "$elapsed"
      frame=$(( frame % ${#frames} + 1 ))
      /bin/sleep 0.1
    done
  else
    print "  • $label"
  fi

  wait "$ACTIVE_PID" || result_code=$?
  ACTIVE_PID=0
  elapsed=$(( SECONDS - started ))

  if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
    printf '\r\033[2K'
  fi
  if (( result_code != 0 )); then
    print -u2 "  ✗ $label failed after ${elapsed}s"
    /bin/cat "$log_file" >&2
    return "$result_code"
  fi
  print "  ✓ $label · ${elapsed}s"
}

print "[1/5] Building and validating…"
/usr/bin/xcrun --find swiftc >/dev/null 2>&1 || {
  print -u2 "Xcode Command Line Tools are required for source installation"
  print -u2 "install them with: xcode-select --install"
  exit 1
}
print "  ✓ Swift compiler found"
run_with_progress "Compiling native core" "$STAGE/swiftc.log" \
  /usr/bin/xcrun swiftc -O -warnings-as-errors \
  -target "$(/usr/bin/uname -m)-apple-macosx13.0" \
  -module-cache-path "$STAGE/module-cache" \
  "${CORE_SOURCES[@]}" "$PROJECT_DIR/src/main.swift" \
  -o "$STAGE/shay-core"
print "  • Signing and hashing binary"
/usr/bin/codesign --force --sign - --identifier org.shaycli.core "$STAGE/shay-core"
readonly CORE_SHA256=$(/usr/bin/shasum -a 256 "$STAGE/shay-core" | /usr/bin/awk '{print $1}')
print "  ✓ Binary signature and SHA-256 ready"
print "  • Validating sudo, launchd, protocol, and self-test"
{
  print -r -- "$TARGET_USER ALL=(root) NOPASSWD: sha256:$CORE_SHA256 $CORE on"
  print -r -- "$TARGET_USER ALL=(root) NOPASSWD: sha256:$CORE_SHA256 $CORE on-expiring"
  print -r -- "$TARGET_USER ALL=(root) NOPASSWD: sha256:$CORE_SHA256 $CORE off"
} > "$STAGE/sudoers"
/usr/sbin/visudo -cf "$STAGE/sudoers"
/usr/bin/plutil -lint "$PLIST_SOURCE"
/usr/bin/codesign --verify --strict "$STAGE/shay-core"
"$STAGE/shay-core" selftest
[[ "$("$STAGE/shay-core" protocol-version)" == "$PROTOCOL_VERSION" ]] || {
  print -u2 "native helper protocol validation failed"
  exit 1
}
print "  ✓ All preflight validations passed"

print "[2/5] Forcing fail-safe OFF state…"
/bin/launchctl bootout system "$PLIST" >/dev/null 2>&1 || true
/usr/bin/pmset -a disablesleep 0
[[ "$(/usr/bin/pmset -g | /usr/bin/awk '$1 == "SleepDisabled" {print $2; found=1} END {if (!found) print "unknown"}')" == "0" ]] || {
  print -u2 "could not verify normal sleep; refusing to upgrade"
  exit 1
}
if [[ -d /var/run/shay.lock && ! -L /var/run/shay.lock ]]; then
  [[ "$(/usr/bin/stat -f '%u' /var/run/shay.lock)" == "0" ]] || {
    print -u2 "unsafe legacy lock ownership; refusing to migrate"
    exit 1
  }
  /bin/unlink /var/run/shay.lock/pid 2>/dev/null || true
  /bin/rmdir /var/run/shay.lock || {
    print -u2 "could not remove legacy lock directory"
    exit 1
  }
fi

print "[3/5] Installing root-owned components…"
/usr/bin/install -d -o root -g wheel -m 0755 /usr/local/bin /usr/local/libexec "$STATE_DIR"
/usr/bin/install -o root -g wheel -m 0755 "$STAGE/shay-core" "$CORE"
/bin/unlink "$CLI" 2>/dev/null || true
/bin/ln -s "$CORE" "$CLI"
/usr/sbin/chown -h root:wheel "$CLI"
/usr/bin/install -o root -g wheel -m 0644 "$PLIST_SOURCE" "$PLIST"
/usr/bin/install -o root -g wheel -m 0440 "$STAGE/sudoers" "/etc/sudoers.d/shay-$TARGET_USER"
/bin/unlink /usr/local/libexec/shay-root 2>/dev/null || true
/bin/unlink /usr/local/libexec/shay-thermal 2>/dev/null || true
/bin/unlink "$STATE_DIR/enabled" 2>/dev/null || true
/bin/unlink "$STATE_DIR/expires_at" 2>/dev/null || true
/bin/unlink "$STATE_DIR/last_check_epoch" 2>/dev/null || true
print -r -- "installer_reset" >| "$STATE_DIR/last_reason"
/usr/sbin/chown root:wheel "$STATE_DIR/last_reason"
/bin/chmod 0644 "$STATE_DIR/last_reason"

if [[ -e "$LEGACY_CLI" || -L "$LEGACY_CLI" ]]; then
  [[ ! -d "$LEGACY_CLI" || -L "$LEGACY_CLI" ]] || {
    print -u2 "legacy CLI path is a directory; refusing to replace it: $LEGACY_CLI"
    exit 1
  }
  /bin/unlink "$LEGACY_CLI"
  /bin/ln -s /usr/local/bin/shay "$LEGACY_CLI"
  /usr/sbin/chown -h "$TARGET_USER:$TARGET_GROUP" "$LEGACY_CLI"
fi

print "[4/5] Loading the launchd safety guard…"
/bin/launchctl bootstrap system "$PLIST"
/bin/launchctl enable "system/$LABEL"
/bin/launchctl print "system/$LABEL" >/dev/null

print "[5/5] Verifying installation…"
/usr/bin/pmset -a disablesleep 0
[[ "$(/usr/bin/pmset -g | /usr/bin/awk '$1 == "SleepDisabled" {print $2; found=1} END {if (!found) print "unknown"}')" == "0" ]] || {
  print -u2 "final normal-sleep verification failed"
  exit 1
}
/usr/local/libexec/shay-core selftest
[[ "$(/usr/local/libexec/shay-core protocol-version)" == "$PROTOCOL_VERSION" ]] || {
  print -u2 "installed helper protocol is incorrect"
  exit 1
}
/usr/sbin/visudo -cf "/etc/sudoers.d/shay-$TARGET_USER"
/usr/bin/cmp -s "$STAGE/shay-core" "$CORE" || {
  print -u2 "installed helper does not match source"
  exit 1
}
/usr/bin/codesign --verify --strict "$CORE"
[[ "$(/usr/bin/stat -f '%Su:%Sg %Lp' "$CORE")" == "root:wheel 755" ]] || {
  print -u2 "installed helper ownership or mode is unsafe"
  exit 1
}
[[ "$("$CORE" status | /usr/bin/head -n 1)" == *"shay"* ]] || {
  print -u2 "status verification failed"
  exit 1
}

print ""
print "✓ shay installed safely at /usr/local/bin/shay"
print "  shay -on [--for 4h | --until 23:00] | shay -off | shay -status"
