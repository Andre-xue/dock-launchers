#!/bin/bash
# 启动速度 / 内存 / 存储 基准测试（需先执行 build.sh）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/DockLaunchers/影音组.app"
UI="$APP/Contents/MacOS/ui"
[ -x "$UI" ] || { echo "先运行 build.sh"; exit 1; }

echo "== 启动耗时（进程内，窗口可见）=="
for i in 1 2 3 4 5; do
  DOCKLAUNCHER_BENCH=1 "$UI" 2>&1 | grep VISIBLE
done

echo ""
echo "== 选中应用后调用 open 的耗时 =="
tmp=$(mktemp -d)
mkdir -p "$tmp/lists"
printf '计算器|Calculator\n' > "$tmp/lists/测试.txt"
cp -R "$ROOT/build/DockLaunchers/工作组.app" "$tmp/测试.app"
cp "$UI" "$tmp/测试.app/Contents/MacOS/ui"
DOCKLAUNCHER_TEST=1 "$tmp/测试.app/Contents/MacOS/ui" 2>&1 | grep OPEN_CALL
sleep 1; pkill -f Calculator.app 2>/dev/null || true
rm -rf "$tmp"

echo ""
echo "== 内存（窗口打开时的 RSS）=="
tmp2=$(mktemp -d); mkdir -p "$tmp2/lists"
cp -R "$APP" "$tmp2/测试.app"; cp "$UI" "$tmp2/测试.app/Contents/MacOS/ui"
cp "$ROOT/lists/影音组.txt" "$tmp2/lists/测试.txt"
DOCKLAUNCHER_MEM=1 "$tmp2/测试.app/Contents/MacOS/ui" 2>&1 | grep RSS
rm -rf "$tmp2"

echo ""
echo "== 存储 =="
du -sh "$ROOT/build/DockLaunchers"
du -sh "$ROOT/build/DockLaunchers/lists" 2>/dev/null || true
