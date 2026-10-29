#!/bin/bash
# 安装到 ~/Applications/DockLaunchers，加入程序坞，并建立本机备份与一键恢复脚本
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/build/DockLaunchers"
[ -d "$SRC" ] || { echo "未找到构建产物，先执行 build.sh"; exit 1; }
DEST="$HOME/Applications/DockLaunchers"
BACKUP="$HOME/Library/Application Support/DockLaunchers/backup/DockLaunchers"
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

# 用 App 自身的 --restore-dock 模式补齐/修正 Dock 条目（含标签与 bundle id）
RESTORE_BIN="$(ls "$DEST"/*.app/Contents/MacOS/ui 2>/dev/null | head -1)"
if [ -n "$RESTORE_BIN" ]; then
  "$RESTORE_BIN" --restore-dock || true
fi
killall -KILL Dock 2>/dev/null || true

# ===== 本机备份 + 桌面一键恢复脚本 =====
echo "==> 建立本机备份"
rm -rf "$BACKUP"
mkdir -p "$BACKUP"
cp -R "$DEST"/*.app "$BACKUP"/
[ -d "$DEST/lists" ] && cp -R "$DEST/lists" "$BACKUP/lists"

RECOVER="$HOME/Desktop/恢复Dock分组.command"
cat > "$RECOVER" <<'EOS'
#!/bin/bash
set -u
SRC="$HOME/Library/Application Support/DockLaunchers/backup/DockLaunchers"
DST="$HOME/Applications/DockLaunchers"
if [ ! -d "$SRC" ]; then
  echo "找不到本机备份：$SRC"
  echo "（备份可能也被删除；如有 GitHub 网络可重新下载安装包）"
  read -n1
  exit 1
fi
mkdir -p "$DST"
pkill -f "/DockLaunchers/.*/Contents/MacOS/ui" 2>/dev/null
cp -R "$SRC"/*.app "$DST"/ 2>/dev/null
[ -d "$SRC/lists" ] && cp -R "$SRC/lists" "$DST/"
mdimport "$DST" 2>/dev/null
for app in "$DST"/*.app; do
  codesign --force --deep --sign - "$app" >/dev/null 2>&1
done
BIN="$(ls "$DST"/*.app/Contents/MacOS/ui 2>/dev/null | head -1)"
[ -n "$BIN" ] && "$BIN" --restore-dock
sleep 0.3
killall -KILL Dock 2>/dev/null
echo "已恢复 Dock 分组：$DST"
read -n1
EOS
chmod +x "$RECOVER"

# 另做一个更显眼的 App 版恢复器（拖到 Dock/应用程序里也能用）
RECOVER_APP="$HOME/Applications/恢复Dock分组.app"
rm -rf "$RECOVER_APP"
mkdir -p "$RECOVER_APP/Contents/MacOS"
cat > "$RECOVER_APP/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>恢复Dock分组</string>
<key>CFBundleDisplayName</key><string>恢复Dock分组</string>
<key>CFBundleIdentifier</key><string>com.docklaunchers.recover</string>
<key>CFBundleExecutable</key><string>run</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
cat > "$RECOVER_APP/Contents/MacOS/run" <<'EOR'
#!/bin/bash
SRC="$HOME/Library/Application Support/DockLaunchers/backup/DockLaunchers"
DST="$HOME/Applications/DockLaunchers"
if [ ! -d "$SRC" ]; then
  osascript -e 'display dialog "找不到本机备份。如有网络可从 GitHub 重新下载安装包。" with title "恢复Dock分组" buttons {"好"} default button 1'
  exit 1
fi
mkdir -p "$DST"
pkill -f "/DockLaunchers/.*/Contents/MacOS/ui" 2>/dev/null
cp -R "$SRC"/*.app "$DST"/ 2>/dev/null
[ -d "$SRC/lists" ] && cp -R "$SRC/lists" "$DST/"
mdimport "$DST" 2>/dev/null
for app in "$DST"/*.app; do codesign --force --deep --sign - "$app" >/dev/null 2>&1; done
BIN="$(ls "$DST"/*.app/Contents/MacOS/ui 2>/dev/null | head -1)"
[ -n "$BIN" ] && "$BIN" --restore-dock
sleep 0.3
killall -KILL Dock 2>/dev/null
osascript -e 'display dialog "已恢复全部 Dock 分组图标。" with title "恢复Dock分组" buttons {"好"} default button 1'
EOR
chmod +x "$RECOVER_APP/Contents/MacOS/run"
codesign --force --deep --sign - "$RECOVER_APP" >/dev/null 2>&1 || true

echo ""
echo "✅ 完成：7 个分组已安装并加入程序坞"
echo "   本机备份：${BACKUP}"
echo "   一键恢复：${RECOVER}（桌面双击即可，无需网络）"
echo "   修改分组：打开窗口用 + / −，或编辑 $DEST/lists/*.txt"
