#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/build/DockLaunchers控制台.app"
xcrun clang -fobjc-arc -framework Cocoa -framework IOKit -arch arm64 -arch x86_64 -o /tmp/docklaunchers_center_ui "$ROOT/src/center_app.m"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp /tmp/docklaunchers_center_ui "$OUT/Contents/MacOS/menu"
cp "$ROOT/resources/icons/控制台.icns" "$OUT/Contents/Resources/AppIcon2.icns"
cp "$ROOT/resources/icons/控制台-menubar.png" "$OUT/Contents/Resources/menubar.png"
cat > "$OUT/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>DockLaunchers控制台</string>
<key>CFBundleDisplayName</key><string>DockLaunchers控制台</string>
<key>CFBundleIdentifier</key><string>com.docklaunchers.center</string>
<key>CFBundleExecutable</key><string>menu</string>
<key>CFBundleIconFile</key><string>AppIcon2</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
codesign --force --deep --sign - "$OUT" >/dev/null 2>&1
echo "built $OUT"
