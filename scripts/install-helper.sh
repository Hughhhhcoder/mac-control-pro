#!/bin/bash
# The native Installer package supplies --helper and --uid; sudo users may pass an app.
set -euo pipefail
[[ "$EUID" -eq 0 ]] || { echo 'Administrator authorization is required.' >&2; exit 1; }
SCRIPT_DIRECTORY="$(cd "$(/usr/bin/dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIRECTORY/installer/console-user.sh" ]]; then
  . "$SCRIPT_DIRECTORY/installer/console-user.sh"
  . "$SCRIPT_DIRECTORY/installer/lock.sh"
else
  . "$SCRIPT_DIRECTORY/console-user.sh"
  . "$SCRIPT_DIRECTORY/lock.sh"
fi
APP='/Applications/Mac Control Pro.app'
SOURCE=''
UID_ALLOWED=''
APP_SET=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --uid) [[ "$#" -ge 2 ]] || { echo '--uid needs a value.' >&2; exit 64; }; UID_ALLOWED="$2"; shift 2 ;;
    --helper) [[ "$#" -ge 2 ]] || { echo '--helper needs a path.' >&2; exit 64; }; SOURCE="$2"; shift 2 ;;
    --*) echo "Unknown option: $1" >&2; exit 64 ;;
    *) [[ "$APP_SET" -eq 0 ]] || { echo 'Only one application path is accepted.' >&2; exit 64; }; APP="$1"; APP_SET=1; shift ;;
  esac
done
if [[ -z "$UID_ALLOWED" ]]; then
  if [[ -n "${SUDO_UID:-}" ]]; then UID_ALLOWED="$SUDO_UID"; else UID_ALLOWED="$(console_control_uid)"; fi
fi
validate_control_uid "$UID_ALLOWED" || { echo 'The authorized UID must identify a human account (UID 501 or greater).' >&2; exit 1; }
if [[ -z "$SOURCE" ]]; then
  [[ "$APP" = /* && "$APP" == *.app && -d "$APP" && ! -L "$APP" ]] || { echo 'Provide an absolute, non-symlink .app path.' >&2; exit 1; }
  [[ ! -L "$APP/Contents" && ! -L "$APP/Contents/Library" && ! -L "$APP/Contents/Library/LaunchServices" ]] || { echo 'Bundle directories must not be symlinks.' >&2; exit 1; }
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
  [[ "$BUNDLE_ID" == io.github.hughhhhcoder.MacControlPro ]] || { echo 'Unexpected application bundle identifier.' >&2; exit 1; }
  /usr/bin/codesign --verify --deep --strict "$APP"
  SOURCE="$APP/Contents/Library/LaunchServices/MacControlHelper"
fi
[[ "$SOURCE" = /* && -f "$SOURCE" && -x "$SOURCE" && ! -L "$SOURCE" ]] || { echo 'A regular, executable helper file is required.' >&2; exit 1; }
LABEL=io.github.hughhhhcoder.MacControlPro.helper
DEST="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
RUNTIME=/var/run/mac-control-pro
STAGED=''
TMP_PLIST=''
BACKUP=''
OLD_STOPPED=0
OLD_LOADED=0
COMMITTED=0

secure_directory() {
  local directory="$1" permissions
  [[ ! -L "$directory" ]] || { echo "Refusing symlink directory: $directory" >&2; return 1; }
  if [[ ! -e "$directory" ]]; then /usr/bin/install -d -o root -g wheel -m 755 "$directory"; fi
  [[ -d "$directory" && "$(/usr/bin/stat -f '%u' "$directory")" == 0 ]] || return 1
  permissions="$(/usr/bin/stat -f '%Lp' "$directory")"
  [[ "$permissions" =~ ^[0-7]+$ && $((8#$permissions & 022)) -eq 0 ]] || {
    echo "Directory is writable by another account: $directory" >&2; return 1;
  }
}
secure_existing_file() {
  local path="$1" permissions
  [[ ! -L "$path" ]] || { echo "Refusing symlink file: $path" >&2; return 1; }
  [[ ! -e "$path" ]] && return 0
  [[ -f "$path" && "$(/usr/bin/stat -f '%u' "$path")" == 0 ]] || return 1
  permissions="$(/usr/bin/stat -f '%Lp' "$path")"
  [[ "$permissions" =~ ^[0-7]+$ && $((8#$permissions & 022)) -eq 0 ]]
}
service_pid() { /bin/launchctl print "system/$LABEL" 2>/dev/null | /usr/bin/awk '/pid =/ {print $3; exit}' || true; }
wait_for_exit() {
  local process_id="${1:-}" attempt
  [[ "$process_id" =~ ^[0-9]+$ ]] || return 0
  for attempt in {1..100}; do
    /bin/kill -0 "$process_id" 2>/dev/null || return 0
    /bin/sleep 0.1
  done
  return 1
}
remove_stale_socket() {
  [[ -e "$RUNTIME/control.sock" || -L "$RUNTIME/control.sock" ]] || return 0
  secure_directory "$RUNTIME"
  [[ ! -L "$RUNTIME/control.sock" && -S "$RUNTIME/control.sock" ]] || {
    echo 'An unexpected file occupies the helper socket path; it was preserved.' >&2; return 1;
  }
  /usr/bin/pgrep -x MacControlHelper >/dev/null && {
    echo 'A helper process is still running; the socket was preserved.' >&2; return 1;
  }
  /bin/rm -f "$RUNTIME/control.sock"
}
finish() {
  local result=$? new_pid
  trap - EXIT
  if [[ "$result" -ne 0 && "$OLD_STOPPED" -eq 1 && "$COMMITTED" -eq 0 ]]; then
    new_pid="$(service_pid)"
    /bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
    if wait_for_exit "$new_pid"; then
      if [[ -f "$BACKUP/helper" ]]; then /bin/mv -f "$BACKUP/helper" "$DEST"; else /bin/rm -f "$DEST"; fi
      if [[ -f "$BACKUP/service.plist" ]]; then /bin/mv -f "$BACKUP/service.plist" "$PLIST"; else /bin/rm -f "$PLIST"; fi
      remove_stale_socket || true
      if [[ "$OLD_LOADED" -eq 1 && -f "$PLIST" ]]; then /bin/launchctl bootstrap system "$PLIST" 2>/dev/null || true; fi
      echo 'Installation failed; the previous helper files were restored.' >&2
    else
      echo 'Installation failed while the helper was stopping. Recovery files were preserved.' >&2
      BACKUP=''
    fi
  fi
  [[ -z "$STAGED" ]] || /bin/rm -f "$STAGED"
  [[ -z "$TMP_PLIST" ]] || /bin/rm -f "$TMP_PLIST"
  [[ -z "$BACKUP" ]] || /bin/rm -rf "$BACKUP"
  release_control_install_lock
  exit "$result"
}
# A concurrent setup or removal must not interrupt fan recovery.
acquire_control_install_lock
trap finish EXIT
secure_directory /Library/PrivilegedHelperTools
secure_directory /Library/LaunchDaemons
secure_directory "$RUNTIME"
secure_existing_file "$DEST"
secure_existing_file "$PLIST"
STAGED="$(/usr/bin/mktemp /Library/PrivilegedHelperTools/.mac-control-helper.XXXXXX)"
/usr/bin/install -o root -g wheel -m 755 "$SOURCE" "$STAGED"
/usr/bin/codesign --verify --strict "$STAGED"
/usr/bin/file "$STAGED" | /usr/bin/grep -q 'Mach-O' || { echo 'Helper is not a Mach-O executable.' >&2; exit 1; }
BACKUP="$(/usr/bin/mktemp -d /Library/PrivilegedHelperTools/.mac-control-backup.XXXXXX)"
[[ ! -f "$DEST" ]] || /bin/cp -p "$DEST" "$BACKUP/helper"
[[ ! -f "$PLIST" ]] || /bin/cp -p "$PLIST" "$BACKUP/service.plist"
if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then OLD_LOADED=1; fi
OLD_PID="$(service_pid)"
/bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
wait_for_exit "$OLD_PID" || { echo 'The old helper has not finished recovering automatic mode; existing files were preserved.' >&2; exit 1; }
OLD_STOPPED=1
remove_stale_socket
/bin/mv -f "$STAGED" "$DEST"
STAGED=''
TMP_PLIST="$(/usr/bin/mktemp /Library/LaunchDaemons/.mac-control.XXXXXX)"
/bin/cat > "$TMP_PLIST" <<PLIST
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
TMP_PLIST=''
/bin/launchctl enable "system/$LABEL"
/bin/launchctl bootstrap system "$PLIST"
for attempt in {1..50}; do
  READY_PID="$(service_pid)"
  if [[ "$READY_PID" =~ ^[0-9]+$ && -S "$RUNTIME/control.sock" && ! -L "$RUNTIME/control.sock" && "$(/usr/bin/stat -f '%u' "$RUNTIME/control.sock")" == "$UID_ALLOWED" && "$(/usr/bin/stat -f '%Lp' "$RUNTIME/control.sock")" == 600 ]]; then
    COMMITTED=1
    /bin/echo "Fan helper installed for $(/usr/bin/id -un "$UID_ALLOWED") (UID $UID_ALLOWED)."
    exit 0
  fi
  /bin/sleep 0.1
done
echo 'The helper did not become ready; restoring the previous installation.' >&2
exit 1
