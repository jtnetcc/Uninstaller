#!/bin/bash
# 项目验收脚本：构建 → 自测 → 打包 → 产物校验 → 启动
# 用法: ./scripts/verify.sh [--no-open]
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/dist/App Uninstaller.app"

echo "== 1. 构建 =="
swift build --package-path "$ROOT" --disable-sandbox -c release

echo "== 2. 自测（34 项） =="
"$ROOT/.build/release/AppUninstaller" --selftest

echo "== 3. 打包 =="
"$ROOT/build.sh"

echo "== 4. 产物校验 =="
fail() { echo "  ✗ $1"; exit 1; }
pass() { echo "  ✓ $1"; }

[ -x "$APP/Contents/MacOS/AppUninstaller" ] || fail "缺少可执行文件"
pass "可执行文件存在"
[ -f "$APP/Contents/Info.plist" ] || fail "缺少 Info.plist"
pass "Info.plist 存在"
plutil -lint "$APP/Contents/Info.plist" >/dev/null || fail "Info.plist 格式非法"
pass "Info.plist 格式合法"
codesign -dv "$APP" 2>&1 | grep -q "Identifier=com.jt.AppUninstaller" || fail "签名标识不符"
pass "签名标识正确"
plutil -p "$APP/Contents/Info.plist" | grep -q "LSMinimumSystemVersion" || fail "缺少最低系统版本"
pass "最低系统版本已声明"
[ -f "$APP/Contents/Resources/AppIcon.icns" ] || echo "  ! 未找到图标（不影响功能）"

echo "== 5. 架构 =="
file "$APP/Contents/MacOS/AppUninstaller" | sed 's/^/  /'

if [ "${1:-}" != "--no-open" ]; then
  echo "== 6. 启动 =="
  open "$APP"
fi

echo ""
echo "全部检查通过。"
