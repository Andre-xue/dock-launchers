#!/bin/bash
# 从源码构建全部 7 个分组 App，输出到 build/DockLaunchers
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/build/DockLaunchers"
UI="$ROOT/build/ui"

echo "==> 编译通用二进制（arm64 + x86_64）"
mkdir -p "$ROOT/build"
xcrun clang -fobjc-arc -framework Cocoa \
  -arch arm64 -arch x86_64 \
  -o "$UI" "$ROOT/src/launcher.m"

rm -rf "$OUT"
mkdir -p "$OUT/lists"

build_one() {
  local NAME="$1" DISPLAY="$2" IDENT="$3" ICON="$4"
  local APP="$OUT/$NAME.app"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$UI" "$APP/Contents/MacOS/ui"
  chmod +x "$APP/Contents/MacOS/ui"
  cp "$ROOT/resources/icons/${ICON:-$NAME}.icns" "$APP/Contents/Resources/AppIcon.icns"
  cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY</string>
  <key>CFBundleIdentifier</key><string>com.docklaunchers.$IDENT</string>
  <key>CFBundleExecutable</key><string>ui</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
  echo "  构建 $NAME.app ($DISPLAY)"
}

build_one "工作" "工作" "gongzuo" "工作组"
build_one "聊天" "聊天" "liaotian" "聊天组"
build_one "外网" "外网" "waiwang" "外网组"
build_one "影音" "影音" "yingyin" "影音组"
build_one "Ai"   "Ai"   "ai"       "Ai组"
build_one "Docker" "Docker" "docker" "Docker组"
build_one "工具" "工具" "gongju" "工具组"

cp "$ROOT/lists/"*.txt "$OUT/lists/" 2>/dev/null || true
echo "==> 完成：$OUT"
echo "   安装：bash install.command"
