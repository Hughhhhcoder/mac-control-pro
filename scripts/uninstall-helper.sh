#!/bin/bash
# Stop the helper first so its termination handler can restore automatic control.
set -euo pipefail
[[ "$EUID" -eq 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
SCRIPT_DIRECTORY="$(cd "$(/usr/bin/dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIRECTORY/installer/lock.sh" ]]; then . "$SCRIPT_DIRECTORY/installer/lock.sh"; else . "$SCRIPT_DIRECTORY/lock.sh"; fi
acquire_control_install_lock
trap release_control_install_lock EXIT
for directory in /Library/PrivilegedHelperTools /Library/LaunchDaemons /var/run/mac-control-pro; do
  [[ ! -L "$directory" ]] || { echo 'An unexpected system-directory symlink was preserved.' >&2; exit 1; }
  if [[ -e "$directory" ]]; then
    permissions="$(/usr/bin/stat -f '%Lp' "$directory")"
    [[ -d "$directory" && "$(/usr/bin/stat -f '%u' "$directory")" == 0 && "$permissions" =~ ^[0-7]+$ && $((8#$permissions & 022)) -eq 0 ]] || { echo 'A system directory has unsafe ownership or permissions; no files were removed.' >&2; exit 1; }
  fi
done
LABEL=io.github.hughhhhcoder.MacControlPro.helper
for protected in "/Library/PrivilegedHelperTools/$LABEL" "/Library/LaunchDaemons/$LABEL.plist"; do
  [[ ! -L "$protected" ]] || { echo 'An unexpected helper-file symlink was preserved.' >&2; exit 1; }
  if [[ -e "$protected" ]]; then
    permissions="$(/usr/bin/stat -f '%Lp' "$protected")"
    [[ -f "$protected" && "$(/usr/bin/stat -f '%u' "$protected")" == 0 && "$permissions" =~ ^[0-7]+$ && $((8#$permissions & 022)) -eq 0 ]] || { echo 'A helper file has unsafe ownership or permissions; no files were removed.' >&2; exit 1; }
  fi
done
OLD_PID="$(/bin/launchctl print "system/$LABEL" 2>/dev/null | /usr/bin/awk '/pid =/ { print $3; exit }' || true)"
/bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
# bootout may return while SIGTERM cleanup is still restoring fan modes.
if [[ "$OLD_PID" =~ ^[0-9]+$ ]]; then
  for attempt in {1..100}; do
    /bin/kill -0 "$OLD_PID" 2>/dev/null || break
    /bin/sleep 0.1
  done
  if /bin/kill -0 "$OLD_PID" 2>/dev/null; then
    echo 'Helper has not finished stopping; existing files are preserved.' >&2
    exit 1
  fi
fi
if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
  echo 'The helper is still loaded; no files were removed.' >&2
  exit 1
fi
JOURNAL=/var/run/mac-control-pro/leases.json
if [[ -L /var/run/mac-control-pro || -L "$JOURNAL" ]]; then
  echo 'Unexpected runtime symlink; files are preserved for inspection.' >&2
  exit 1
fi
if [[ -e "$JOURNAL" ]]; then
  [[ -f "$JOURNAL" && "$(/usr/bin/stat -f '%u' "$JOURNAL")" == 0 ]] || { echo 'An unsafe recovery journal was preserved.' >&2; exit 1; }
  # The helper writes an array of remaining fan IDs. Only [] means recovered.
  if [[ ! -f "$JOURNAL" || "$(/usr/bin/tr -d '[:space:]' < "$JOURNAL")" != '[]' ]]; then
    echo 'A recovery journal still records unresolved fan control. No files were removed.' >&2
    /bin/launchctl bootstrap system "/Library/LaunchDaemons/$LABEL.plist" 2>/dev/null || true
    echo "Restart the Mac, or retry recovery with: sudo launchctl bootstrap system /Library/LaunchDaemons/$LABEL.plist" >&2
    exit 1
  fi
fi
/bin/rm -f "/Library/LaunchDaemons/$LABEL.plist" "/Library/PrivilegedHelperTools/$LABEL"
if [[ -d /var/run/mac-control-pro && ! -L /var/run/mac-control-pro ]]; then
  /bin/rm -f /var/run/mac-control-pro/control.sock "$JOURNAL"
  /bin/rmdir /var/run/mac-control-pro 2>/dev/null || true
fi
echo 'Helper removed. Verify fan mode in the app.'
