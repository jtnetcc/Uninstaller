#!/bin/bash
# 将版本号写入 Resources/Info.plist
# 用法: ./scripts/set-version.sh <marketing-version> [build-number]
# 示例: ./scripts/set-version.sh 1.2.0 42
set -euo pipefail

VERSION="${1:-}"
BUILD="${2:-1}"

if [ -z "$VERSION" ]; then
  echo "用法: $0 <marketing-version> [build-number]" >&2
  exit 2
fi

# 校验语义化版本（允许预发布后缀，如 1.2.0-beta.1）
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$ ]]; then
  echo "!! 版本号格式非法: $VERSION（应为 MAJOR.MINOR.PATCH）" >&2
  exit 2
fi
if ! [[ "$BUILD" =~ ^[0-9]+$ ]]; then
  echo "!! 构建号必须为整数: $BUILD" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/Resources/Info.plist"
PB=/usr/libexec/PlistBuddy

[ -f "$PLIST" ] || { echo "!! 未找到 $PLIST" >&2; exit 1; }

set_key() {
  local key="$1" value="$2"
  if $PB -c "Print :$key" "$PLIST" >/dev/null 2>&1; then
    $PB -c "Set :$key $value" "$PLIST"
  else
    $PB -c "Add :$key string $value" "$PLIST"
  fi
}

set_key CFBundleShortVersionString "$VERSION"
set_key CFBundleVersion "$BUILD"

echo "Info.plist 已更新:"
echo "  CFBundleShortVersionString = $($PB -c 'Print :CFBundleShortVersionString' "$PLIST")"
echo "  CFBundleVersion            = $($PB -c 'Print :CFBundleVersion' "$PLIST")"
