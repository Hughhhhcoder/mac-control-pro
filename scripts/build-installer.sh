#!/bin/bash
# Build native Installer products without installing them or changing system files.
set -euo pipefail
[[ "$#" -eq 4 && ( "$1" == helper || "$1" == full || "$1" == remove ) ]] || { echo 'Usage: build-installer.sh helper|full|remove APP VERSION OUTPUT.pkg' >&2; exit 64; }
MODE="$1"
APP="$2"
VERSION="$3"
OUTPUT="$4"
ROOT="$(cd "$(/usr/bin/dirname "$0")/.." && pwd)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid package version.' >&2; exit 64; }
[[ "$APP" == /* && -d "$APP" && ! -L "$APP" && "$OUTPUT" == /* && "$OUTPUT" == *.pkg ]] || { echo 'Use absolute application and package paths.' >&2; exit 64; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == io.github.hughhhhcoder.MacControlPro ]] || { echo 'Unexpected application identifier.' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$VERSION" ]] || { echo 'Package and application versions must match.' >&2; exit 1; }
HELPER="$APP/Contents/Library/LaunchServices/MacControlHelper"
[[ -f "$HELPER" && ! -L "$HELPER" ]] || { echo 'Embedded helper is missing.' >&2; exit 1; }
/usr/bin/codesign --verify --strict "$HELPER"
STAGE="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/mac-control-pkg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
SCRIPTS="$STAGE/scripts"
RESOURCES="$STAGE/resources"
/bin/mkdir -p "$SCRIPTS" "$RESOURCES"
/bin/cp "$ROOT/scripts/installer/preinstall" "$ROOT/scripts/installer/console-user.sh" "$ROOT/scripts/installer/lock.sh" "$SCRIPTS/"
if [[ "$MODE" == remove ]]; then
  /bin/cp "$ROOT/scripts/uninstall-helper.sh" "$SCRIPTS/"
  /bin/cat > "$SCRIPTS/postinstall" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
[[ "$EUID" -eq 0 && "${3:-/}" == / ]] || exit 1
/bin/bash "$(/usr/bin/dirname "$0")/uninstall-helper.sh"
SCRIPT
else
  /bin/cp "$ROOT/scripts/installer/postinstall" "$ROOT/scripts/install-helper.sh" "$HELPER" "$SCRIPTS/"
fi
/bin/chmod 755 "$SCRIPTS/"*
/usr/bin/xattr -cr "$SCRIPTS"
COMPONENT="$STAGE/component.pkg"
if [[ "$MODE" == remove ]]; then
  IDENTIFIER=io.github.hughhhhcoder.MacControlPro.helper-remover
  TITLE='Uninstall Fan Helper'
  /usr/bin/pkgbuild --nopayload --scripts "$SCRIPTS" --identifier "$IDENTIFIER" --version "$VERSION" --install-location / "$COMPONENT"
  /bin/cat > "$RESOURCES/Welcome.html" <<'HTML'
<!doctype html><meta charset="utf-8"><h2>卸载风扇控制辅助服务</h2><p>此安装器请求助手恢复自动控制并停止服务，确认恢复日志为空后移除助手系统文件。应用、偏好设置和导出的文件会保留。macOS 将请求管理员验证。</p><hr><h2>Remove fan control service</h2><p>Requests automatic recovery, stops the helper and removes its system files only after the recovery journal is empty. The app, preferences and exports remain. macOS will request administrator authorization.</p>
HTML
elif [[ "$MODE" == helper ]]; then
  IDENTIFIER=io.github.hughhhhcoder.MacControlPro.helper-installer
  TITLE='Install Fan Helper'
  /usr/bin/pkgbuild --nopayload --scripts "$SCRIPTS" --identifier "$IDENTIFIER" --version "$VERSION" --install-location / "$COMPONENT"
  /bin/cat > "$RESOURCES/Welcome.html" <<'HTML'
<!doctype html><meta charset="utf-8"><h2>安装风扇控制辅助服务</h2><p>此安装器为当前登录的用户安装 Mac Control Pro 风扇控制服务。macOS 将请求管理员验证。</p><p>普通监控不需要此服务。安装完成后回到 Mac Control Pro，检查设备能力及服务状态。固件可能限制手动调速。</p><hr><h2>Install fan control service</h2><p>Installs the Mac Control Pro fan helper for the currently signed-in user. macOS will request administrator authorization.</p><p>Monitoring works without the helper. After installation, return to the app to check hardware capabilities and helper status. Firmware may restrict manual fan control.</p>
HTML
else
  /usr/bin/codesign --verify --deep --strict "$APP"
  IDENTIFIER=io.github.hughhhhcoder.MacControlPro.installer
  TITLE='Mac Control Pro'
  PAYLOAD="$STAGE/payload"
  /bin/mkdir -p "$PAYLOAD/Applications"
  /usr/bin/ditto --norsrc --noextattr --noacl "$APP" "$PAYLOAD/Applications/Mac Control Pro.app"
  /usr/bin/xattr -cr "$PAYLOAD"
  /usr/bin/codesign --verify --deep --strict "$PAYLOAD/Applications/Mac Control Pro.app"
  /bin/cat > "$STAGE/components.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><array><dict>
<key>RootRelativeBundlePath</key><string>Applications/Mac Control Pro.app</string>
<key>BundleIsRelocatable</key><false/>
<key>BundleIsVersionChecked</key><true/>
<key>BundleHasStrictIdentifier</key><true/>
<key>BundleOverwriteAction</key><string>upgrade</string>
</dict></array></plist>
PLIST
  /usr/bin/pkgbuild --root "$PAYLOAD" --component-plist "$STAGE/components.plist" --scripts "$SCRIPTS" --identifier "$IDENTIFIER" --version "$VERSION" --install-location / --ownership recommended "$COMPONENT"
  /bin/cat > "$RESOURCES/Welcome.html" <<'HTML'
<!doctype html><meta charset="utf-8"><h2>安装 Mac Control Pro</h2><p>将应用安装到「应用程序」，并为当前登录的用户安装风扇控制服务。macOS 将请求管理员验证。</p><p>安装完成后从「应用程序」打开 Mac Control Pro。风扇读取和写入能力取决于机型与系统固件；无风扇机型只能监控。</p><hr><h2>Install Mac Control Pro</h2><p>Installs the app in Applications and the fan control helper for the currently signed-in user. macOS will request administrator authorization.</p><p>Open Mac Control Pro from Applications after installation. Hardware and firmware determine available fan controls; fanless Macs support monitoring.</p>
HTML
fi
# Explicit arm64 requirements prevent Installer from evaluating the product under Rosetta.
PACKAGE_ARCHS="$(/usr/bin/lipo -archs "$HELPER")"
/usr/bin/python3 - "$STAGE/requirements.plist" "$PACKAGE_ARCHS" <<'PY'
import plistlib, sys
architectures=sys.argv[2].split()
if not architectures or any(a not in ('arm64','x86_64') for a in architectures):
    raise SystemExit('Unsupported helper architecture')
with open(sys.argv[1],'wb') as out:
    plistlib.dump({'os':['14.0'],'arch':architectures,'home':False},out)
PY
/usr/bin/productbuild --synthesize --product "$STAGE/requirements.plist" --package "$COMPONENT" "$STAGE/Distribution.xml"
/usr/bin/python3 - "$STAGE/Distribution.xml" "$TITLE" "$MODE" <<'PY'
import sys, xml.etree.ElementTree as ET
path,title,mode=sys.argv[1:]
tree=ET.parse(path);root=tree.getroot()
for node in list(root):
    if node.tag in ('title','welcome','domains'):root.remove(node)
ET.SubElement(root,'title').text=title
ET.SubElement(root,'welcome',{'file':'Welcome.html'})
ET.SubElement(root,'domains',{'enable_localSystem':'true','enable_currentUserHome':'false','enable_anywhere':'false'})
# The full product replaces a running app only after Installer asks the user to close it.
if mode=='full':
    ref=next((n for n in root.findall('pkg-ref') if n.text and n.text.strip()),None)
    if ref is not None:
        close_ref=ET.SubElement(root,'pkg-ref',{'id':ref.get('id')})
        close=ET.SubElement(close_ref,'must-close')
        ET.SubElement(close,'app',{'id':'io.github.hughhhhcoder.MacControlPro'})
tree.write(path,encoding='utf-8',xml_declaration=True)
PY
product_args=(--distribution "$STAGE/Distribution.xml" --package-path "$STAGE" --resources "$RESOURCES" --identifier "$IDENTIFIER" --version "$VERSION")
if [[ -n "${INSTALLER_SIGN_IDENTITY:-}" ]]; then product_args+=(--sign "$INSTALLER_SIGN_IDENTITY" --timestamp); fi
/bin/mkdir -p "$(/usr/bin/dirname "$OUTPUT")"
/usr/bin/productbuild "${product_args[@]}" "$OUTPUT"
/bin/echo "Native installer ready: $OUTPUT"
