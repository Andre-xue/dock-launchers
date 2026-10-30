#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/DockLaunchers控制台.app"
[ -d "$APP" ] || { echo "先执行 ./build_center.sh"; exit 1; }
VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "1.0")
STAGE="/tmp/dmg-stage-docklaunchers"
DMG="$ROOT/DockLaunchers控制台-${VER}.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
cat > "$STAGE/安装说明.txt" <<'TXT'
DockLaunchers 控制台

安装：
1. 把 DockLaunchers控制台.app 拖到「应用程序」或 ~/Applications。
2. 首次打开如提示“无法验证开发者”，请右键应用选择「打开」，或在终端执行：
   xattr -dr com.apple.quarantine "/Applications/DockLaunchers控制台.app"
3. 按应用内提示授予必要权限。

说明：
本应用为本地工具，数据保存在本机，不上传。
TXT
ln -s /Applications "$STAGE/Applications"
SIGN_ID="DockLaunchers Local Code Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  codesign --force --deep --sign "$SIGN_ID" "$APP" >/dev/null 2>&1 || true
else
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi
hdiutil create -volname "DockLaunchers控制台" -srcfolder "$STAGE" -ov -format UDZO -imagekey zlib-level=9 "$DMG" >/dev/null
echo "built $DMG"
