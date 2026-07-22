#!/bin/zsh
set -eu
setopt pipefail

readonly TARGET_USER="${1:-${SUDO_USER:-}}"
readonly LABEL="org.shaycli.guard"
readonly PLIST="/Library/LaunchDaemons/$LABEL.plist"
readonly STATE_DIR="/var/db/shay"

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
readonly LEGACY_CLI="$TARGET_HOME/.local/bin/shay"

print "[1/3] Unloading the safety guard…"
/bin/launchctl bootout system "$PLIST" >/dev/null 2>&1 || true

print "[2/3] Restoring and verifying normal sleep…"
/usr/bin/pmset -a disablesleep 0
[[ "$(/usr/bin/pmset -g | /usr/bin/awk '$1 == "SleepDisabled" {print $2; found=1} END {if (!found) print "unknown"}')" == "0" ]] || {
  print -u2 "could not verify normal sleep; refusing to uninstall"
  exit 1
}

print "[3/3] Removing exact installed paths…"
/bin/unlink "$PLIST" 2>/dev/null || true
/bin/unlink /usr/local/bin/shay 2>/dev/null || true
/bin/unlink /usr/local/libexec/shay-core 2>/dev/null || true
/bin/unlink /usr/local/libexec/shay-root 2>/dev/null || true
/bin/unlink /usr/local/libexec/shay-thermal 2>/dev/null || true
/bin/unlink "/etc/sudoers.d/shay-$TARGET_USER" 2>/dev/null || true

if [[ -L "$LEGACY_CLI" && "$(/usr/bin/readlink "$LEGACY_CLI")" == "/usr/local/bin/shay" ]]; then
  /bin/unlink "$LEGACY_CLI"
fi

/bin/unlink "$STATE_DIR/enabled" 2>/dev/null || true
/bin/unlink "$STATE_DIR/expires_at" 2>/dev/null || true
/bin/unlink "$STATE_DIR/last_reason" 2>/dev/null || true
/bin/unlink "$STATE_DIR/last_check_epoch" 2>/dev/null || true
/bin/rmdir "$STATE_DIR" 2>/dev/null || true
if [[ -f /var/run/shay.lock && ! -L /var/run/shay.lock && "$(/usr/bin/stat -f '%u' /var/run/shay.lock)" == "0" ]]; then
  /bin/unlink /var/run/shay.lock
fi

print "✓ Shay removed; normal macOS sleep is active"
