#!/bin/bash
# Builds Platoon.app (release, universal if possible) into port/build/.
set -euo pipefail
cd "$(dirname "$0")"
CONFIG=${CONFIG:-release}
ARCHS=${ARCHS:-"arm64 x86_64"}
ARCHFLAGS=""; for a in $ARCHS; do ARCHFLAGS="$ARCHFLAGS --arch $a"; done
swift build -c "$CONFIG" $ARCHFLAGS --product Platoon
BIN=$(swift build -c "$CONFIG" $ARCHFLAGS --product Platoon --show-bin-path)/Platoon
APP=build/Platoon.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Platoon"
ADF=../re/platoon_darc.adf
[ -f "$ADF" ] && cp "$ADF" "$APP/Contents/Resources/Platoon.adf"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Platoon</string>
  <key>CFBundleDisplayName</key><string>Platoon</string>
  <key>CFBundleIdentifier</key><string>im.paul.platoon</string>
  <key>CFBundleExecutable</key><string>Platoon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.action-games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>GCSupportsControllerUserInteraction</key><true/>
  <key>NSHumanReadableCopyright</key><string>Platoon © 1987 Ocean Software / Hemdale. Native macOS port.</string>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
