#!/bin/bash
# 一键构建：编译 Swift 源 → 生成图标 → 组装 DSH.app
#
# 与原 build.sh 的区别：那里 .app 只是个 3 行 shell 薄壳（真正的逻辑在仓库脚本里），
# 这里编译产出就是应用本体，双击即用，不依赖仓库目录存在。
set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

APP_NAME="DSH"
APP="$HERE/build/$APP_NAME.app"
EXECUTABLE="DSHLauncher"
DEPLOYMENT_TARGET="14.0"

# Swift 编译要写模块缓存，默认落在 ~/Library；指到本目录，避免污染用户目录
export CLANG_MODULE_CACHE_PATH="$HERE/.build/module-cache"
export SWIFT_MODULE_CACHE_PATH="$HERE/.build/module-cache"
mkdir -p "$HERE/.build"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "找不到 swiftc。请安装 Xcode 命令行工具：xcode-select --install" >&2
  exit 1
fi

# Apple Silicon 机器上如果 shell 跑在 Rosetta 下（uname -m 报 x86_64），
# swiftc 会按 x86_64 编译，而 SDK 里没有对应的 Swift 模块接口，
# 报 "failed to build module 'Swift'"。显式用 arch -arm64 走原生即可。
SWIFTC=(swiftc)
TARGET_FLAG=()
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ]; then
  TARGET_FLAG=(-target "arm64-apple-macos${DEPLOYMENT_TARGET}")
  if [ "$(uname -m)" != "arm64" ]; then
    echo "    检测到 shell 运行在 Rosetta 下，改用 arch -arm64 swiftc"
    SWIFTC=(arch -arm64 swiftc)
  fi
fi

# 构建类型：release（默认）| debug
#   release：全模块优化（跨文件内联）+ 剥离符号，产物更小更快
#   debug：保留符号、不剥离，便于用 lldb 排查
BUILD_TYPE="${BUILD_TYPE:-release}"
if [ "$BUILD_TYPE" = "debug" ]; then
  OPT_FLAGS=(-Onone -g)
  echo "==> 编译 $EXECUTABLE（debug：保留符号）"
else
  # 注意：剥离符号用构建后的 `strip` 命令做，而不是 -Xlinker -strip_all
  # （后者不是合法的 ld 标志，且不同链接器版本支持不一）
  OPT_FLAGS=(-O -wmo -Xlinker -dead_strip)
  echo "==> 编译 $EXECUTABLE（release：全模块优化 + 剥离符号）"
fi

"${SWIFTC[@]}" \
  "${OPT_FLAGS[@]}" -swift-version 5 \
  "${TARGET_FLAG[@]}" \
  -framework Cocoa -framework WebKit \
  -o "$HERE/.build/$EXECUTABLE" \
  "$HERE"/Sources/*.swift

if [ "$BUILD_TYPE" != "debug" ]; then
  # 去掉调试符号表，产出更小（链接已完成，这一步不会影响运行）
  strip -x "$HERE/.build/$EXECUTABLE" 2>/dev/null || true
fi

if [ -f "$HERE/Resources/icons/app-icon-mac.png" ]; then
  echo "==> 生成应用图标 AppIcon.icns"
  ICONSET="$HERE/.build/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$HERE/Resources/icons/app-icon-mac.png" \
      --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$HERE/Resources/icons/app-icon-mac.png" \
      --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$HERE/.build/AppIcon.icns"
fi

echo "==> 组装 $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/icons"
cp "$HERE/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$HERE/.build/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
chmod +x "$APP/Contents/MacOS/$EXECUTABLE"

if [ -f "$HERE/.build/AppIcon.icns" ]; then
  cp "$HERE/.build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
# 菜单栏图标随包分发，应用不再依赖源码目录
cp "$HERE/Resources/icons/tray-iconTemplate.png" \
   "$HERE/Resources/icons/tray-iconTemplate@2x.png" \
   "$APP/Contents/Resources/icons/"

plutil -lint "$APP/Contents/Info.plist" >/dev/null
# 让 Finder/Dock 立刻感知 bundle 变化
touch "$APP"

echo "==> 完成：$APP"
echo "    安装：cp -R \"$APP\" /Applications/"
echo "    自检：\"$APP/Contents/MacOS/$EXECUTABLE\" --print-decision"
