#!/bin/bash
# Serializes setup and removal; sourcing this file performs no mutations.
acquire_control_install_lock() {
  CONTROL_INSTALL_LOCK=/var/run/io.github.hughhhhcoder.MacControlPro.install.lock
  local previous_pid
  if ! /bin/mkdir -m 700 "$CONTROL_INSTALL_LOCK" 2>/dev/null; then
    [[ ! -L "$CONTROL_INSTALL_LOCK" && -d "$CONTROL_INSTALL_LOCK" && "$(/usr/bin/stat -f '%u' "$CONTROL_INSTALL_LOCK")" == 0 && "$(/usr/bin/stat -f '%Lp' "$CONTROL_INSTALL_LOCK")" == 700 && -f "$CONTROL_INSTALL_LOCK/pid" && ! -L "$CONTROL_INSTALL_LOCK/pid" && "$(/usr/bin/stat -f '%u' "$CONTROL_INSTALL_LOCK/pid")" == 0 ]] || { echo 'An unexpected installer lock was preserved.' >&2; return 1; }
    previous_pid="$(/bin/cat "$CONTROL_INSTALL_LOCK/pid")"
    [[ "$previous_pid" =~ ^[0-9]+$ ]] || { echo 'An invalid installer lock was preserved.' >&2; return 1; }
    /bin/kill -0 "$previous_pid" 2>/dev/null && { echo 'Another helper setup or removal is running.' >&2; return 1; }
    /bin/rm -f "$CONTROL_INSTALL_LOCK/pid"
    /bin/rmdir "$CONTROL_INSTALL_LOCK"
    /bin/mkdir -m 700 "$CONTROL_INSTALL_LOCK" || return 1
  fi
  /bin/echo "$$" > "$CONTROL_INSTALL_LOCK/pid"
}
release_control_install_lock() {
  [[ -n "${CONTROL_INSTALL_LOCK:-}" && -f "$CONTROL_INSTALL_LOCK/pid" && ! -L "$CONTROL_INSTALL_LOCK/pid" && "$(/bin/cat "$CONTROL_INSTALL_LOCK/pid")" == "$$" ]] || return 0
  /bin/rm -f "$CONTROL_INSTALL_LOCK/pid"
  /bin/rmdir "$CONTROL_INSTALL_LOCK" 2>/dev/null || true
}
