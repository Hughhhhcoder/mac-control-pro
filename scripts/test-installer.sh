#!/bin/bash
# Identity and archive checks only. Never runs package scripts, sudo, or Installer.
set -euo pipefail
ROOT="$(cd "$(/usr/bin/dirname "$0")/.." && pwd)"
. "$ROOT/scripts/installer/console-user.sh"
validate_control_identity 501 alice 501
validate_control_identity 502 bob 502
validate_control_identity 1600000123 directoryuser 1600000123
validate_control_identity 3000000123 directoryuser 3000000123
if [[ "$(/usr/bin/id -u)" -ge 501 ]]; then validate_control_uid "$(/usr/bin/id -u)"; fi
for invalid in 0 1 201 500 0501 4294967294 4294967295 9999999999 -1 '501;id' ''; do
  if validate_control_identity "$invalid" alice "$invalid"; then echo "Accepted unsafe identity: $invalid" >&2; exit 1; fi
done
for account in root nobody loginwindow _mbsetupuser _daemon ''; do
  if validate_control_identity 501 "$account" 501; then echo 'Accepted a system account.' >&2; exit 1; fi
done
if validate_control_identity 501 alice 502; then echo 'Accepted mismatched directory identity.' >&2; exit 1; fi
if validate_control_uid 0; then echo 'Root must not be authorized as the console account.' >&2; exit 1; fi
/bin/bash -n "$ROOT/scripts/install-helper.sh" "$ROOT/scripts/uninstall-helper.sh" "$ROOT/scripts/installer/preinstall" "$ROOT/scripts/installer/postinstall"
if [[ "$#" -eq 0 ]]; then echo 'Installer identity and script checks passed. No system files were changed.'; exit 0; fi
[[ "$#" -eq 2 && "$1" == *.pkg && "$2" == *.zip ]] || { echo 'Usage: test-installer.sh [FULL.pkg APP.zip]' >&2; exit 64; }
CHECK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/mac-control-installer-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
/usr/sbin/pkgutil --expand-full "$1" "$CHECK_DIR/full"
/usr/bin/ditto -x -k "$2" "$CHECK_DIR/zip"
/usr/sbin/installer -showChoicesXML -target / -pkg "$1" > "$CHECK_DIR/choices.plist"
APP="$CHECK_DIR/zip/Mac Control Pro.app"
/usr/bin/codesign --verify --deep --strict "$APP"
[[ -f "$APP/Contents/Resources/Install Fan Helper.pkg" && -f "$APP/Contents/Resources/Uninstall Fan Helper.pkg" ]]
/usr/sbin/pkgutil --expand-full "$APP/Contents/Resources/Install Fan Helper.pkg" "$CHECK_DIR/helper"
/usr/sbin/pkgutil --expand-full "$APP/Contents/Resources/Uninstall Fan Helper.pkg" "$CHECK_DIR/remove"
/usr/bin/codesign --verify --deep --strict "$CHECK_DIR/full/component.pkg/Payload/Applications/Mac Control Pro.app"
/usr/bin/python3 - "$CHECK_DIR" <<'PY'
import pathlib, plistlib, subprocess, sys, xml.etree.ElementTree as ET
base=pathlib.Path(sys.argv[1])
for name in ('full','helper'):
    stage=base/name
    dist=ET.parse(stage/'Distribution').getroot()
    opts=dist.find('options')
    assert opts is not None and opts.get('hostArchitectures'), 'Installer omits supported architecture metadata'
    domains=dist.find('domains')
    assert domains is not None and domains.get('enable_currentUserHome')=='false' and domains.get('enable_anywhere')=='false', 'Installer allows relocation to an unsafe domain'
    scripts=list(stage.glob('**/Scripts/postinstall'))
    assert len(scripts)==1, 'Missing or ambiguous native installer script'
    folder=scripts[0].parent
    post=scripts[0].read_text()
    assert 'console_control_uid' in post and '--uid "$CONTROL_UID"' in post and post.count('install-helper.sh')==1, 'Package uses a fixed user identity'
    assert (folder/'MacControlHelper').is_file() and (folder/'console-user.sh').is_file() and (folder/'lock.sh').is_file() and (folder/'install-helper.sh').is_file(), 'Package omits helper setup assets'
    assert 'SUDO_UID' not in post, 'Native Installer must not depend on sudo environment'
remove=base/'remove'
post=next(remove.glob('**/Scripts/postinstall'))
assert 'uninstall-helper.sh' in post.read_text(), 'Missing native removal entry point'
remove_script=post.parent/'uninstall-helper.sh'
assert remove_script.is_file() and 'leases.json' in remove_script.read_text() and (post.parent/'lock.sh').is_file(), 'Removal package omits recovery safeguards'
full=base/'full' 
info=ET.parse(next(full.glob('**/PackageInfo'))).getroot()
bundle=info.find('.//bundle')
assert bundle is not None and bundle.get('path')=='./Applications/Mac Control Pro.app', 'Unexpected application destination'
assert info.get('relocatable')=='false' and not info.findall('.//relocate/*'), 'Application must not be relocatable'
dist=ET.parse(full/'Distribution').getroot()
assert dist.find('.//must-close/app').get('id')=='io.github.hughhhhcoder.MacControlPro', 'Installer does not request closing the app'
assert full.joinpath('component.pkg/Payload/Applications/Mac Control Pro.app/Contents/MacOS/MacControlPro').is_file(), 'Full package omits application payload'
embedded=next((base/'helper').glob('**/Scripts/MacControlHelper'))
actual=base/'zip/Mac Control Pro.app/Contents/Library/LaunchServices/MacControlHelper'
assert embedded.read_bytes()==actual.read_bytes(), 'Embedded Installer helper differs from application helper'
architectures=set(subprocess.check_output(['/usr/bin/lipo','-archs',str(actual)],text=True).split())
for name in ('full','helper'):
    dist=ET.parse(base/name/'Distribution').getroot()
    assert set(dist.find('options').get('hostArchitectures').split(','))==architectures, 'Installer architecture requirements differ from helper binary'
print('Native packages contain the matching helper, console-user setup and fixed Applications destination.')
PY
/bin/echo 'Installer archive checks passed. Packages were extracted but not installed.'
