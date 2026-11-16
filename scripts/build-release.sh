#!/bin/bash
# Build and package from source. Requires Xcode Command Line Tools on macOS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.2.0}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"
ARCHS="${ARCHS:-arm64 x86_64}"
IDENTITY="${CODE_SIGN_IDENTITY:--}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'VERSION must be a numeric version such as 0.1.0.' >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || { echo 'Build on macOS.' >&2; exit 1; }
if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
  [[ "$IDENTITY" != '-' && -n "${INSTALLER_SIGN_IDENTITY:-}" ]] || { echo 'Notarization requires application and installer signing identities.' >&2; exit 1; }
fi
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
# Stage outside synced Documents: file providers may attach FinderInfo during signing.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/mac-control-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Mac Control Pro.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchServices"
app_bins=()
helper_bins=()
cli_bins=()
count=0
for arch in $ARCHS; do
  case "$arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
  scratch="$ROOT/.build-release/$arch"
  swift build --package-path "$ROOT" --scratch-path "$scratch" -c release --arch "$arch"
  bin="$(swift build --package-path "$ROOT" --scratch-path "$scratch" -c release --arch "$arch" --show-bin-path)"
  app_bins+=("$bin/MacControlPro")
  helper_bins+=("$bin/MacControlHelper")
  cli_bins+=("$bin/MacControlCLI")
  count=$((count + 1))
done
[[ "$count" -gt 0 ]] || { echo 'ARCHS must contain at least one architecture.' >&2; exit 1; }
if [[ "$count" -gt 1 ]]; then
  lipo -create "${app_bins[@]}" -output "$APP/Contents/MacOS/MacControlPro"
  lipo -create "${helper_bins[@]}" -output "$APP/Contents/Library/LaunchServices/MacControlHelper"
  lipo -create "${cli_bins[@]}" -output "$APP/Contents/MacOS/MacControlCLI"
  suffix=universal
else
  cp "${app_bins[0]}" "$APP/Contents/MacOS/MacControlPro"
  cp "${helper_bins[0]}" "$APP/Contents/Library/LaunchServices/MacControlHelper"
  cp "${cli_bins[0]}" "$APP/Contents/MacOS/MacControlCLI"
  suffix="$ARCHS"
fi
chmod 755 "$APP/Contents/MacOS/MacControlPro" "$APP/Contents/Library/LaunchServices/MacControlHelper" "$APP/Contents/MacOS/MacControlCLI"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MacControlPro</string>
<key>CFBundleIdentifier</key><string>io.github.hughhhhcoder.MacControlPro</string>
<key>CFBundleName</key><string>Mac Control Pro</string>
<key>CFBundleDisplayName</key><string>Mac Control Pro</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Mac Control Pro contributors. MIT License.</string>
</dict></plist>
PLIST
for icon in "$ROOT/Resources/AppIcon.icns" "$ROOT/Sources/MacControlPro/Resources/AppIcon.icns"; do
  if [[ -f "$icon" ]]; then cp "$icon" "$APP/Contents/Resources/AppIcon.icns"; break; fi
done
# SwiftPM resource bundles (if present) must travel with the executable.
for bundle in "${app_bins[0]%/*}"/*.bundle; do
  [[ -d "$bundle" ]] && ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done
# Finder metadata inherited from local files can invalidate otherwise valid app signing.
/usr/bin/xattr -cr "$APP"
sign_args=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != '-' ]]; then sign_args+=(--options runtime --timestamp); fi
codesign "${sign_args[@]}" "$APP/Contents/Library/LaunchServices/MacControlHelper"
codesign "${sign_args[@]}" "$APP/Contents/MacOS/MacControlCLI"
# The embedded helper-only package lets the GUI use native Installer without source checkout.
"$ROOT/scripts/build-installer.sh" helper "$APP" "$VERSION" "$APP/Contents/Resources/Install Fan Helper.pkg"
"$ROOT/scripts/build-installer.sh" remove "$APP" "$VERSION" "$APP/Contents/Resources/Uninstall Fan Helper.pkg"
if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
  xcrun notarytool submit "$APP/Contents/Resources/Install Fan Helper.pkg" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
  xcrun stapler staple "$APP/Contents/Resources/Install Fan Helper.pkg"
  xcrun notarytool submit "$APP/Contents/Resources/Uninstall Fan Helper.pkg" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
  xcrun stapler staple "$APP/Contents/Resources/Uninstall Fan Helper.pkg"
fi
codesign "${sign_args[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
name="Mac-Control-Pro-$VERSION-$suffix"
ZIP="$OUTPUT_DIR/$name.zip"
DMG="$OUTPUT_DIR/$name.dmg"
PKG="$OUTPUT_DIR/$name.pkg"
rm -f "$ZIP" "$DMG" "$PKG"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
  [[ "$IDENTITY" != '-' ]] || { echo 'Notarization requires CODE_SIGN_IDENTITY.' >&2; exit 1; }
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
fi
# Recommended first-install product installs the app and matching helper together.
"$ROOT/scripts/build-installer.sh" full "$APP" "$VERSION" "$PKG"
if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
  xcrun notarytool submit "$PKG" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
  xcrun stapler staple "$PKG"
fi
DMG_ROOT="$STAGE/dmg"
mkdir -p "$DMG_ROOT"
ditto "$APP" "$DMG_ROOT/Mac Control Pro.app"
ln -s /Applications "$DMG_ROOT/Applications"
cp "$ROOT/LICENSE" "$DMG_ROOT/LICENSE.txt"
cp "$PKG" "$DMG_ROOT/Install Mac Control Pro.pkg"
hdiutil create -volname 'Mac Control Pro' -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG"
if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi
(cd "$OUTPUT_DIR" && shasum -a 256 "$name.zip" "$name.dmg" "$name.pkg" > "$name.sha256")
# Keep the directly launchable app next to its archives for local verification.
rm -rf "$OUTPUT_DIR/Mac Control Pro.app"
ditto "$APP" "$OUTPUT_DIR/Mac Control Pro.app"
echo "Release ready: $ZIP"
echo "Disk image: $DMG"
echo "Native installer: $PKG"
