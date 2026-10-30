#!/bin/bash
# 需要：Apple Developer Program、Developer ID Application 证书、公证凭据
# 用法：
#   export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#   export NOTARY_PROFILE="docklaunchers-notary"   # 先执行 notarytool store-credentials 创建
#   ./scripts/notarize.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/DockLaunchers控制台.app"
DMG="$ROOT/DockLaunchers控制台-1.76.0.dmg"
: "${DEVELOPER_ID:?请设置 DEVELOPER_ID，例如 Developer ID Application: Name (TEAMID)}"
: "${NOTARY_PROFILE:?请设置 NOTARY_PROFILE}"
if ! security find-identity -v -p codesigning | grep -q "$DEVELOPER_ID"; then
  echo "找不到 Developer ID 证书：$DEVELOPER_ID"
  echo "请先安装 Apple Developer ID Application 证书。"
  exit 1
fi
./build_center.sh
codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
codesign --verify --deep --strict "$APP"
./make_dmg.sh
codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG" 2>/dev/null || true
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
echo "已公证并装订：$DMG"
