#!/bin/bash
# Builds Sahba.app for Apple Silicon (M1 and later).
#   ./build.sh            build, install to ~/Applications and open it (for development)
#   ./build.sh --release  build and pack build/release/Sahba-<version>.zip (+ .sha256) for the installer
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
VERSION="$(tr -d '[:space:]' < VERSION)"
APP="$ROOT/build/Sahba.app"
LOG="$ROOT/build/build.log"
mkdir -p "$ROOT/build"

echo "  building Sahba $VERSION ..."
if ! swift build -c release --arch arm64 > "$LOG" 2>&1; then
  echo "  build failed. first errors:"
  sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -E 'error:' | sort -u | head -5 | cut -c1-160
  exit 1
fi
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Sahba"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Sahba"
cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# The display name is written as XML character references so this script stays plain ASCII.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>app.sahba.Sahba</string>
  <key>CFBundleName</key><string>Sahba</string>
  <key>CFBundleDisplayName</key><string>&#x633;&#x62D;&#x628;&#x629;</string>
  <key>CFBundleExecutable</key><string>Sahba</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>CFBundleDevelopmentRegion</key><string>ar</string>
  <key>CFBundleLocalizations</key><array><string>ar</string><string>en</string></array>
  <key>CFBundleAllowMixedLocalizations</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --sign - "$APP" >/dev/null

if [[ "${1:-}" == "--release" ]]; then
  OUT="$ROOT/build/release"
  mkdir -p "$OUT"
  ZIP="$OUT/Sahba-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP" "$ZIP"
  shasum -a 256 "$ZIP" | awk '{print $1}' > "$ZIP.sha256"
  # Pin this version and fingerprint in the installer.
  sed -i '' -e "s/^VERSION=\".*\"/VERSION=\"$VERSION\"/" -e "s/^ZIP_SHA=\".*\"/ZIP_SHA=\"$(cat "$ZIP.sha256")\"/" install.sh
  echo "  release: $ZIP"
  echo "  sha256:  $(cat "$ZIP.sha256") (written into install.sh)"
  exit 0
fi

mkdir -p "$HOME/Applications"
pkill -x Sahba 2>/dev/null || true
# Wait for the old copy to quit, or the new one sees it and closes itself.
for _ in $(seq 50); do pgrep -x Sahba >/dev/null || break; sleep 0.1; done
rm -rf "$HOME/Applications/Sahba.app"
cp -R "$APP" "$HOME/Applications/"
open "$HOME/Applications/Sahba.app"
echo "  installed and opened: $HOME/Applications/Sahba.app"
