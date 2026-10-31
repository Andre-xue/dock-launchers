#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/build/DockLaunchers控制台.app"
xcrun clang -O2 -fobjc-arc -framework Cocoa -framework IOKit -framework Quartz -framework CoreServices -framework QuickLookThumbnailing -framework Photos -framework Vision -framework PDFKit -framework NaturalLanguage -framework Carbon -framework Security -framework AVFoundation -framework CoreMedia -arch arm64 -arch x86_64 -o /tmp/docklaunchers_center_ui "$ROOT/src/center_app.m"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp /tmp/docklaunchers_center_ui "$OUT/Contents/MacOS/DockLaunchers"
cp "$ROOT/resources/icons/控制台.icns" "$OUT/Contents/Resources/AppIcon2.icns"
mkdir -p "$OUT/Contents/Resources/GroupIcons"
for ic in 工作组 聊天组 外网组 影音组 Ai组 Docker组 工具组; do
  cp "$ROOT/resources/icons/$ic.icns" "$OUT/Contents/Resources/GroupIcons/$ic.icns"
done
cp "$ROOT/resources/icons/控制台-menubar.png" "$OUT/Contents/Resources/menubar.png"
PLVER=$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || true)
PLVER=${PLVER#v}
PLVER=${PLVER:-1.70.0}
cat > "$OUT/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>DockLaunchers控制台</string>
<key>CFBundleDisplayName</key><string>DockLaunchers控制台</string>
<key>CFBundleIdentifier</key><string>com.docklaunchers.center</string>
<key>CFBundleExecutable</key><string>DockLaunchers</string>
<key>CFBundleIconFile</key><string>AppIcon2</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPhotoLibraryUsageDescription</key><string>用于读取照片图库中的照片和视频，仅在本机「文件管理」中展示，不上传、不修改。</string>
</dict></plist>
PL
sed -i '' "s|<string>0.1</string>|<string>${PLVER}</string>|" "$OUT/Contents/Info.plist"
SIGN_ID="DockLaunchers Local Code Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  codesign --force --deep --sign "$SIGN_ID" "$OUT" >/dev/null 2>&1 || codesign --force --deep --sign - "$OUT" >/dev/null 2>&1
else
  codesign --force --deep --sign - "$OUT" >/dev/null 2>&1
fi
echo "built $OUT"
