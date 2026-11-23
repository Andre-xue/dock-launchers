#!/bin/bash
# DockLaunchers 控制台安装脚本（单启动器 + .dockgroup 分组文件）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/build.noindex/DockLaunchers控制台.app"
DEST="$HOME/Applications/DockLaunchers控制台.app"
SIGN_ID="DockLaunchers Local Code Signing"

if [ ! -d "$SRC" ]; then
  echo "未找到构建产物，正在构建…"
  (cd "$ROOT" && bash build_center.sh)
fi
[ -d "$SRC" ] || { echo "构建失败：$SRC 不存在"; exit 1; }

sign_app() {
  local app="$1"
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    codesign --force --deep --sign "$SIGN_ID" "$app" >/dev/null 2>&1 || codesign --force --deep --sign - "$app" >/dev/null 2>&1 || true
  else
    codesign --force --deep --sign - "$app" >/dev/null 2>&1 || true
  fi
}

echo "==> 安装控制台到 $DEST"
pkill -f "$DEST/Contents/MacOS/DockLaunchers" 2>/dev/null || true
sleep 1
osascript -e "tell application \"Finder\" to delete POSIX file \"$DEST\"" >/dev/null 2>&1 || true
mkdir -p "$HOME/Applications"
cp -R "$SRC" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
sign_app "$DEST"
codesign --verify --deep --strict "$DEST" && echo "签名校验通过"

# 开机自动启动控制台
AGENT="$HOME/Library/LaunchAgents/com.docklaunchers.center.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.docklaunchers.center</string>
<key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-g</string><string>-a</string><string>$DEST</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><false/>
</dict></plist>
PLIST
launchctl unload "$AGENT" 2>/dev/null || true
launchctl load "$AGENT" 2>/dev/null || true

open "$DEST"
echo "==> 完成：控制台已启动。分组以 .dockgroup 文件放在 ~/Applications/DockLaunchers.noindex，不再生成分组 App。"
