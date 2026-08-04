#!/usr/bin/env bash
# 本地走查用的 ad-hoc claudi0.app —— release.yml「Assemble claudi0.app」的单架构等价物。
# CI 那份用 lipo 合双架构；走查只需要本机这一个架构。
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/claudi0.app"
LEGACY_APP="dist/Claudio.app"

# 建之前先清旧 bundle：若下面任一 `swift build` 因编译错误退出（set -e），旧 dist/claudi0.app
# 不能留在原地——否则走查者会 `open` 到上一次成功构建的旧二进制，却以为测的是这次改动。
rm -rf "$APP" "$LEGACY_APP"

# 两个 `--product` 都不是可省的修饰：裸 `swift build -c release` 会连各自的测试
# executable 一起建，而测试会引用 `#if DEBUG` 门控的 fixture，Release 下编译不过。
swift build -c release --package-path gui --product ClaudioGUI
swift build -c release --package-path helper --product claudio

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Resources/packs"
cp "$(swift build -c release --package-path gui --product ClaudioGUI --show-bin-path)/ClaudioGUI" \
   "$APP/Contents/MacOS/claudi0-app"
cp "$(swift build -c release --package-path helper --product claudio --show-bin-path)/claudio" \
   "$APP/Contents/Resources/bin/claudi0"
cp "$(swift build -c release --package-path helper --product claudio --show-bin-path)/claudio" \
   "$APP/Contents/Resources/bin/claudio"
cp -R packs/minimal-chime "$APP/Contents/Resources/packs/minimal-chime"
cp assets/branding/claudi0.icns "$APP/Contents/Resources/claudi0.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>claudi0</string>
  <key>CFBundleDisplayName</key><string>claudi0</string>
  <key>CFBundleIdentifier</key><string>com.claudio.app</string>
  <key>CFBundleVersion</key><string>0.0.0-dev</string>
  <key>CFBundleShortVersionString</key><string>0.0.0-dev</string>
  <key>CFBundleExecutable</key><string>claudi0-app</string>
  <key>CFBundleIconFile</key><string>claudi0.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"
echo "✅ ${APP}（$(uname -m)）—— 用 open ${APP} 启动（菜单栏出现 Orbit Zero 图标）"
