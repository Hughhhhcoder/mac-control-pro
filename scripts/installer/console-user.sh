#!/bin/bash
# Shared by the native package and the explicit sudo installer. No root mutations.
validate_control_identity() {
  local candidate="${1:-}" account="${2:-}" resolved="${3:-}"
  [[ "$candidate" =~ ^[1-9][0-9]{2,9}$ ]] || return 1
  [[ "$candidate" -ge 501 && "$candidate" -le 4294967293 ]] || return 1
  [[ -n "$account" && "$account" != root && "$account" != nobody && "$account" != loginwindow && "$account" != _* ]] || return 1
  [[ "$resolved" == "$candidate" ]]
}

validate_control_uid() {
  local candidate="${1:-}" account resolved
  [[ "$candidate" =~ ^[1-9][0-9]{2,9}$ && "$candidate" -ge 501 && "$candidate" -le 4294967293 ]] || return 1
  account="$(/usr/bin/id -un "$candidate" 2>/dev/null)" || return 1
  resolved="$(/usr/bin/id -u "$account" 2>/dev/null)" || return 1
  validate_control_identity "$candidate" "$account" "$resolved"
}

console_control_uid() {
  local candidate
  candidate="$(/usr/bin/stat -f '%u' /dev/console)" || return 1
  validate_control_uid "$candidate" || {
    echo 'A signed-in local console user is required. Sign in normally, then run this installer again.' >&2
    return 1
  }
  /bin/echo "$candidate"
}
