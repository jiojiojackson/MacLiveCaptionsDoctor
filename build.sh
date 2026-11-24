#!/bin/bash
# 编译并启动「实时字幕语言诊断」
set -o pipefail
cd "$(dirname "$0")"
APP="LiveCaptionsDoctor.app"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "⚠️  需要先安装 Xcode 命令行工具（免费，约几分钟）。正在弹出安装窗口…"
  xcode-select --install 2>/dev/null || true
  echo "安装完成后，再运行一次：bash build.sh"
  exit 1
fi

ARCH=$(uname -m)
SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
echo "▶︎ macOS $(sw_vers -productVersion)  |  SDK $(xcrun --sdk macosx --show-sdk-version)  |  $ARCH"
echo "▶︎ 正在编译…"

rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp Info.plist "${APP}/Contents/Info.plist"

# 如果系统里有 SwiftUI 宏插件（装了 Xcode 时才有），就加上；没有也能编译
PLUGIN_ARGS=()
for dir in "$(xcode-select -p 2>/dev/null)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" \
           "$(xcode-select -p 2>/dev/null)/usr/lib/swift/host/plugins" \
           "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"; do
  if [ -d "$dir" ]; then PLUGIN_ARGS+=(-plugin-path "$dir"); fi
done

if ! xcrun swiftc -parse-as-library -O "${PLUGIN_ARGS[@]+"${PLUGIN_ARGS[@]}"}" \
    -target "${ARCH}-apple-macos26.0" -sdk "$SDK_PATH" \
    main.swift -o "${APP}/Contents/MacOS/LiveCaptionsDoctor" > build.log 2>&1; then
  cat build.log
  { echo "【编译失败】macOS $(sw_vers -productVersion) / SDK $(xcrun --sdk macosx --show-sdk-version) / $ARCH"; cat build.log; } | pbcopy
  echo ""
  echo "❌ 编译失败。错误信息已自动复制到剪贴板，直接粘贴给 Quick 即可。"
  exit 1
fi

codesign --force --deep -s - "${APP}" >/dev/null 2>&1 || true
echo "✅ 编译完成：$(pwd)/${APP}"
echo "▶︎ 正在启动…（以后可直接双击 ${APP}，或拖到「应用程序」文件夹）"
open "${APP}"
