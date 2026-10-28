#!/bin/bash
# 安装到 ~/Applications/DockLaunchers 并加入程序坞
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/build/DockLaunchers"
[ -d "$SRC" ] || { echo "未找到构建产物，先执行 build.sh"; exit 1; }
DEST="$HOME/Applications/DockLaunchers"
echo "==> 安装到 $DEST"
mkdir -p "$DEST"

pkill -f "$DEST/.*/Contents/MacOS/ui" 2>/dev/null || true

rm -rf "$DEST"/*.app
cp -R "$SRC"/*.app "$DEST"/

mkdir -p "$DEST/lists"
for f in "$SRC"/lists/*.txt; do
  base=$(basename "$f")
  [ -f "$DEST/lists/$base" ] || cp "$f" "$DEST/lists/$base"
done

xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
for app in "$DEST"/*.app; do
  codesign --force --deep --sign - "$app" >/dev/null 2>&1 || true
done
mdimport "$DEST" 2>/dev/null || true

URLS=(
"file://$HOME/Applications/DockLaunchers/%E5%B7%A5%E4%BD%9C%E7%BB%84.app"
"file://$HOME/Applications/DockLaunchers/%E8%81%8A%E5%A4%A9%E7%BB%84.app"
"file://$HOME/Applications/DockLaunchers/%E5%A4%96%E7%BD%91%E7%BB%84.app"
"file://$HOME/Applications/DockLaunchers/%E5%BD%B1%E9%9F%B3%E7%BB%84.app"
"file://$HOME/Applications/DockLaunchers/Ai%E7%BB%84.app"
"file://$HOME/Applications/DockLaunchers/Docker%E7%BB%84.app"
"file://$HOME/Applications/DockLaunchers/%E5%B7%A5%E5%85%B7%E7%BB%84.app"
)
EXISTING=$(defaults read com.apple.dock persistent-apps 2>/dev/null || true)
for u in "${URLS[@]}"; do
  if ! printf '%s' "$EXISTING" | grep -qF "$u"; then
    defaults write com.apple.dock persistent-apps -array-add "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>$u</string><key>_CFURLStringType</key><integer>0</integer></dict></dict><key>tile-type</key><string>file-tile</string></dict>"
  fi
done
killall Dock 2>/dev/null || true

echo ""
echo "✅ 完成：7 个分组已安装并加入程序坞"
echo "   修改分组：打开窗口用 + / −，或编辑 $DEST/lists/*.txt"
