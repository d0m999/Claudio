#!/usr/bin/env bash
# 本地走查用的 ad-hoc Claudio.app —— release.yml「Assemble Claudio.app」的单架构等价物。
# CI 那份用 lipo 合双架构；走查只需要本机这一个架构。
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/Claudio.app"

# 建之前先清旧 bundle：若下面任一 `swift build` 因编译错误退出（set -e），旧 dist/Claudio.app
# 不能留在原地——否则走查者会 `open` 到上一次成功构建的旧二进制，却以为测的是这次改动。
rm -rf "$APP"

# `--product ClaudioGUI` 不是可省的修饰：裸 `swift build -c release` 会连 claudio-gui-tests
# 一起建，而它引用 `#if DEBUG` 门控的 PreviewFixtures，Release 下编译不过（gui/Package.swift:18-23）。
swift build -c release --package-path gui --product ClaudioGUI
swift build -c release --package-path helper

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Resources/packs"
cp "$(swift build -c release --package-path gui --product ClaudioGUI --show-bin-path)/ClaudioGUI" \
   "$APP/Contents/MacOS/Claudio"
cp "$(swift build -c release --package-path helper --show-bin-path)/claudio" \
   "$APP/Contents/Resources/bin/claudio"
cp -R packs/minimal-chime "$APP/Contents/Resources/packs/minimal-chime"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claudio</string>
  <key>CFBundleDisplayName</key><string>Claudio</string>
  <key>CFBundleIdentifier</key><string>com.claudio.app</string>
  <key>CFBundleVersion</key><string>0.0.0-dev</string>
  <key>CFBundleShortVersionString</key><string>0.0.0-dev</string>
  <key>CFBundleExecutable</key><string>Claudio</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"
echo "✅ $APP（$(uname -m)）—— 用 open $APP 启动（菜单栏出现波形图标，无 Dock 图标）"
