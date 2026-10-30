#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
./build_center.sh >/dev/null
BIN="$ROOT/build/DockLaunchers控制台.app/Contents/MacOS/DockLaunchers"
echo "==> 运行内部回归自测"
DOCKLAUNCHERS_CENTER_SELFTEST=1 DOCKLAUNCHERS_CENTER_SKIP_DOCK=1 "$BIN" 2>&1 | tee /tmp/docklaunchers-selftest.log
