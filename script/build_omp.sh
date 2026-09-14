#!/usr/bin/env bash
set -euo pipefail

# Local OMP Usage build, based on OpenUsage. Separate identity, no upstream icon,
# updater feed, telemetry project, or iCloud entitlement. Leaves the official app alone.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$ROOT_DIR/dist/OMP Usage.app"
IDENTITY="${CODESIGN_IDENTITY:--}"
cd "$ROOT_DIR"
swift build -c "$CONFIG"
BUILD_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
# SwiftPM resource bundles can contain read-only files; stage cleanly instead of overwriting them.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BUILD_DIR/OpenUsage" "$APP/Contents/MacOS/OpenUsage"
cp "$BUILD_DIR/openusage-cli" "$APP/Contents/Helpers/openusage"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/Helpers/openusage"
shopt -s nullglob
for bundle in "$BUILD_DIR"/*.bundle; do
  cp -R "$bundle" "$APP/Contents/Resources/"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>OpenUsage</string>
  <key>CFBundleIdentifier</key><string>dev.arthurlin.omp-usage</string>
  <key>CFBundleName</key><string>OMP Usage</string>
  <key>CFBundleDisplayName</key><string>OMP Usage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.7.12-omp.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSEnvironment</key><dict>
    <key>OPENUSAGE_POSTHOG_TOKEN</key><string>phc_REPLACE_ME</string>
  </dict>
</dict></plist>
PLIST
"$ROOT_DIR/script/embed_sparkle.sh" "$APP" "$APP/Contents/MacOS/OpenUsage" "$IDENTITY" '--options runtime'
codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/Helpers/openusage"
codesign --force --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
printf 'Built %s\n' "$APP"
