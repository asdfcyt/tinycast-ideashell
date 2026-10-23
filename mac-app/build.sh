#!/bin/bash
# 编译并打包成 拾忆.app（不需要完整 Xcode，只要命令行工具 CLT）
# 用法：./build.sh [run|install]
#   run     编译后直接从 build/ 里打开
#   install 编译后安装到 /Applications/拾忆.app 并打开
set -euo pipefail
cd "$(dirname "$0")"

OUT=build
APP="$OUT/拾忆.app"
mkdir -p "$OUT/obj"

SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find Sources -name '*.swift' | sort)

# 用 macOS 26.5 SDK 编译：它带 SwiftUI 原生液态玻璃 API。
# 命令行工具里的 27.0 SDK 依赖 Xcode 才有的 SwiftUIMacros 插件（@State 等会报错），26.0 SDK 有重复模块映射的老毛病，26.5 没有这两个问题。
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
[ -d "$SDK" ] || SDK="$(xcrun --show-sdk-path)"

# 不开优化：Swift 6.4 的 -O 编译出来的版本启动即崩（swift_Concurrency 里 pure virtual call），关掉优化稳定，这个 App 性能无影响。
swiftc -Onone -parse-as-library -swift-version 5 -sdk "$SDK" \
    -target arm64-apple-macos14.0 \
    -module-name Shiyi \
    "${SOURCES[@]}" -o "$OUT/Shiyi"

# 应用图标：取自安卓端 ic_launcher_foreground.xml；Resources/AppIcon.icns 不存在时才重新生成
if [ ! -f Resources/AppIcon.icns ]; then
    mkdir -p Resources "$OUT/AppIcon.iconset"
    swiftc -O -sdk "$SDK" -target arm64-apple-macos14.0 Tools/make-icon.swift -o "$OUT/make-icon"
    "$OUT/make-icon" "$OUT/icon-1024.png"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$OUT/icon-1024.png" --out "$OUT/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) "$OUT/icon-1024.png" --out "$OUT/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$OUT/AppIcon.iconset" -o Resources/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/Shiyi" "$APP/Contents/MacOS/Shiyi"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>拾忆</string>
    <key>CFBundleDisplayName</key><string>拾忆</string>
    <key>CFBundleIdentifier</key><string>com.carpe.shiyi.mac</string>
    <key>CFBundleExecutable</key><string>Shiyi</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key><dict><key>default</key><string>记到拾忆</string></dict>
            <key>NSMessage</key><string>captureService</string>
            <key>NSPortName</key><string>拾忆</string>
            <key>NSSendTypes</key>
            <array>
                <string>NSStringPboardType</string>
                <string>public.png</string>
                <string>public.tiff</string>
            </array>
            <key>NSSendFileTypes</key>
            <array>
                <string>public.image</string>
                <string>public.plain-text</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "已生成：$PWD/$APP"

if [ "${1:-}" = "run" ]; then
    pkill -x Shiyi 2>/dev/null || true
    open "$APP"
fi

if [ "${1:-}" = "install" ]; then
    pkill -x Shiyi 2>/dev/null || true
    sleep 1
    rm -rf "/Applications/拾忆.app"
    ditto "$APP" "/Applications/拾忆.app"
    echo "已安装：/Applications/拾忆.app"
    open "/Applications/拾忆.app"
fi
