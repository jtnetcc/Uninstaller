#!/bin/bash
# 构建并打包 App Uninstaller.app
#
# 用法:
#   ./build.sh                      # release 单架构构建 + 打包 + ad-hoc 签名
#   ./build.sh --clean              # 先清理 .build 与 dist
#   ./build.sh --universal          # arm64 + x86_64 双架构（Intel Mac 可用）
#   ./build.sh --no-build           # 跳过编译，仅用已有产物重新组装 .app（CI 用）
#   ./build.sh --unsigned           # 跳过签名（仅调试）
#
# 环境变量:
#   VERSION   覆盖 Info.plist 的 CFBundleShortVersionString（如 1.2.0）
#   BUILD     覆盖 Info.plist 的 CFBundleVersion（如 42）
#
# 产物: dist/App Uninstaller.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_CONFIG="release"
DIST="$ROOT/dist"
APP="$DIST/App Uninstaller.app"
# 受限终端（沙盒化 IDE/CI）中 SwiftPM 自身的 sandbox-exec 可能不可用
CACHE_FLAG="--disable-sandbox"

CLEAN=false
UNIVERSAL=false
NO_BUILD=false
SIGN=true

for arg in "$@"; do
  case "$arg" in
    --clean)     CLEAN=true ;;
    --universal) UNIVERSAL=true ;;
    --no-build)  NO_BUILD=true ;;
    --unsigned)  SIGN=false ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "!! 未知参数: $arg"; exit 2 ;;
  esac
done

cd "$ROOT"

if [ "$CLEAN" = true ]; then
  echo "==> 清理构建产物"
  rm -rf "$ROOT/.build" "$DIST"
fi

# ---- 构建 ----
ARCH_ARGS=()
if [ "$UNIVERSAL" = true ]; then
  ARCH_ARGS=(--arch arm64 --arch x86_64)
  echo "==> 编译 (${BUILD_CONFIG}, universal)"
else
  echo "==> 编译 (${BUILD_CONFIG})"
fi

if [ "$NO_BUILD" = false ]; then
  swift build --package-path "$ROOT" $CACHE_FLAG -c "$BUILD_CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
fi

# ---- 定位产物（不再写死 .build/release，兼容新版 SwiftPM 的 .build/out/Products）----
BIN_DIR="$(swift build --package-path "$ROOT" $CACHE_FLAG -c "$BUILD_CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path | tail -1)"
BIN="$BIN_DIR/AppUninstaller"
if [ ! -f "$BIN" ]; then
  echo "!! 未找到可执行文件: $BIN"
  echo "   可执行文件搜索路径: $BIN_DIR"
  exit 1
fi
echo "==> 产物: $BIN"
file -b "$BIN" | sed 's/^/   /'

# ---- 可选：注入版本号 ----
PLIST_SRC="$ROOT/Resources/Info.plist"
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST_SRC"
  echo "==> 版本号: $VERSION"
fi
if [ -n "${BUILD:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST_SRC"
fi

# ---- 组装 .app ----
echo "==> 组装 .app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AppUninstaller"
cp "$PLIST_SRC" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# ---- 签名 ----
if [ "$SIGN" = true ]; then
  IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
  echo "==> 签名 (ad-hoc, $IDENTIFIER)"
  codesign --force --timestamp=none --sign - --identifier "$IDENTIFIER" "$APP" >/dev/null 2>&1 || \
    echo "   (ad-hoc 签名失败，应用仍可本机运行)"
else
  echo "==> 跳过签名"
fi

echo "==> 完成: $APP"
du -sh "$APP" | awk '{print "   体积: " $1}'
