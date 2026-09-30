#!/bin/bash
# Builds Platoon.app (release, universal if possible) into port/build/.
#   CONFIG=release|debug   ARCHS="arm64 x86_64" (default universal)
#   SCRATCH=/tmp/dir       SwiftPM scratch path (default .build)
#   OUT=dir                where Platoon.app goes (default build)
#   DIST=1                 distribution build: no game disk inside the app (the player imports their own .adf,
#                          Game > Import Disk Image... or drop it on the window / the Dock icon)
set -euo pipefail
cd "$(dirname "$0")"
CONFIG=${CONFIG:-release}
ARCHS=${ARCHS:-"arm64 x86_64"}
DIST=${DIST:-0}
OUT=${OUT:-build}
ARCHFLAGS=""; for a in $ARCHS; do ARCHFLAGS="$ARCHFLAGS --arch $a"; done
SCRATCHFLAGS=""; [ -n "${SCRATCH:-}" ] && SCRATCHFLAGS="--scratch-path $SCRATCH"
swift build -c "$CONFIG" $ARCHFLAGS $SCRATCHFLAGS --product Platoon
BIN=$(swift build -c "$CONFIG" $ARCHFLAGS $SCRATCHFLAGS --product Platoon --show-bin-path)/Platoon
APP=$OUT/Platoon.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Platoon"
ADF=../re/platoon_port.adf
if [ "$DIST" != 1 ] && [ -f "$ADF" ]; then cp "$ADF" "$APP/Contents/Resources/Platoon.adf"; fi
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# user guide (Help menu)
cp ENHANCEMENTS_GUIDE.md "$APP/Contents/Resources/"
[ -f ../README.md ] && cp ../README.md "$APP/Contents/Resources/README.md"
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
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>Amiga Disk File</string>
    <key>CFBundleTypeExtensions</key><array><string>adf</string></array>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
  </dict></array>
  <key>NSHumanReadableCopyright</key><string>Platoon © 1987 Ocean Software / Hemdale. Native macOS port.</string>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
echo "Built $APP$([ "$DIST" = 1 ] && echo ' (distribution: no game disk inside)')"
