#!/bin/bash
# Explicit opt-in: install the privileged fan controller for the invoking user.
set -euo pipefail
[[ "$EUID" -eq 0 ]] || { echo 'Run with sudo from your normal user account.' >&2; exit 1; }
APP="${1:-/Applications/Mac Control Pro.app}"
UID_ALLOWED="${SUDO_UID:-$(id -u)}"
[[ "$UID_ALLOWED" =~ ^[0-9]+$ && "$UID_ALLOWED" -ge 501 ]] || { echo 'Run sudo from the user account that will control fans.' >&2; exit 1; }
[[ "$APP" = /* && "$APP" == *.app && -d "$APP" && ! -L "$APP" ]] || { echo 'Provide an absolute, non-symlink .app path.' >&2; exit 1; }
SOURCE="$APP/Contents/Library/LaunchServices/MacControlHelper"
[[ -f "$SOURCE" && -x "$SOURCE" && ! -L "$SOURCE" ]] || { echo 'Embedded helper not found, or is a symlink.' >&2; exit 1; }
[[ ! -L "$APP/Contents" && ! -L "$APP/Contents/Library" && ! -L "$APP/Contents/Library/LaunchServices" ]] || { echo 'Bundle directories must not be symlinks.' >&2; exit 1; }
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
[[ "$BUNDLE_ID" == io.github.hughhhhcoder.MacControlPro ]] || { echo 'Unexpected application bundle identifier.' >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$APP"
LABEL=io.github.hughhhhcoder.MacControlPro.helper
DEST="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
[[ ! -L /Library/PrivilegedHelperTools && ! -L /Library/LaunchDaemons ]] || { echo 'System install directories must not be symlinks.' >&2; exit 1; }
/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools /Library/LaunchDaemons
# Stage a root-owned copy and verify the copy before any root execution.
STAGED="$(mktemp "/Library/PrivilegedHelperTools/.mac-control-helper.XXXXXX")"
trap 'rm -f "$STAGED"' EXIT
/usr/bin/install -o root -g wheel -m 755 "$SOURCE" "$STAGED"
/usr/bin/codesign --verify --strict "$STAGED"
/usr/bin/file "$STAGED" | /usr/bin/grep -q 'Mach-O' || { echo 'Helper is not a Mach-O executable.' >&2; exit 1; }
OLD_PID="$(/bin/launchctl print "system/$LABEL" 2>/dev/null | /usr/bin/awk '/pid =/ { print $3; exit }' || true)"
/bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
# bootout may return while SIGTERM cleanup is still restoring fan modes.
if [[ "$OLD_PID" =~ ^[0-9]+$ ]]; then
  for attempt in {1..50}; do
    /bin/kill -0 "$OLD_PID" 2>/dev/null || break
    /bin/sleep 0.1
  done
  if /bin/kill -0 "$OLD_PID" 2>/dev/null; then
    echo 'Helper has not finished stopping; existing files are preserved.' >&2
    exit 1
  fi
fi
/bin/mv -f "$STAGED" "$DEST"
TMP_PLIST="$(mktemp /Library/LaunchDaemons/.mac-control.XXXXXX)"
trap 'rm -f "$STAGED" "$TMP_PLIST"' EXIT
cat > "$TMP_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$DEST</string><string>--uid</string><string>$UID_ALLOWED</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ProcessType</key><string>Interactive</string>
<key>ThrottleInterval</key><integer>5</integer>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$TMP_PLIST"
/usr/sbin/chown root:wheel "$TMP_PLIST"
/bin/chmod 644 "$TMP_PLIST"
/bin/mv -f "$TMP_PLIST" "$PLIST"
/bin/launchctl bootstrap system "$PLIST"
echo "Fan helper installed for user ID $UID_ALLOWED. Reopen Mac Control Pro."
echo 'Remove with: sudo ./scripts/uninstall-helper.sh'
