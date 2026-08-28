#!/usr/bin/env bash
# 本地走查用的 ad-hoc claudi0.app —— release.yml「Assemble claudi0.app」的单架构等价物。
# CI 那份用 lipo 合双架构；走查只需要本机这一个架构。
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"
source "$script_dir/pinned-output-directory.sh"
cd "$repo_root"

REQUESTED_VERSION="${CLAUDIO_VERSION:-}"
if [[ -n "$REQUESTED_VERSION" && ! "$REQUESTED_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "❌ CLAUDIO_VERSION must be an unprefixed MAJOR.MINOR.PATCH value" >&2
    exit 2
fi

GUI_NATIVE_HOST_CARD_PROBE=false
if [[ $# -eq 1 && "$1" == "--native-host-card-probe" ]]; then
    GUI_NATIVE_HOST_CARD_PROBE=true
elif [[ $# -ne 0 ]]; then
    echo "usage: $0 [--native-host-card-probe]" >&2
    exit 2
fi

gui_build() {
    if [[ "$GUI_NATIVE_HOST_CARD_PROBE" == true ]]; then
        swift build -c release --package-path "$repo_root/gui" --product ClaudioGUI \
            -Xswiftc -DCLAUDIO_NATIVE_HOST_CARD_PROBE "$@"
    else
        swift build -c release --package-path "$repo_root/gui" --product ClaudioGUI "$@"
    fi
}

find_unique_gui_resource_bundle() {
  local search_dir="$1"
  local -a candidates=()
  shopt -s nullglob
  candidates=("$search_dir"/*_ClaudioGUI.bundle)
  shopt -u nullglob
  if [[ ${#candidates[@]} -ne 1 || ! -d "${candidates[0]:-}" ]]; then
    echo "❌ expected exactly one *_ClaudioGUI.bundle in $search_dir; found ${#candidates[@]}" >&2
    return 1
  fi
  printf '%s\n' "${candidates[0]}"
}

find_unique_localization_bundle() {
  local search_dir="$1"
  local -a candidates=()
  shopt -s nullglob
  candidates=("$search_dir"/*_ClaudioLocalization.bundle)
  shopt -u nullglob
  if [[ ${#candidates[@]} -ne 1 || ! -d "${candidates[0]:-}" ]]; then
    echo "❌ expected exactly one *_ClaudioLocalization.bundle in $search_dir; found ${#candidates[@]}" >&2
    return 1
  fi
  printf '%s\n' "${candidates[0]}"
}

assemble_dev_bundle() {
    local APP="claudi0.app"
    local LEGACY_APP="Claudio.app"
    local BUNDLE_VERSION
    local GUI_BIN_DIR
    local GUI_RESOURCE_BUNDLE
    local HELPER_BINARY
    local HELPER_BIN_DIR
    local LOCALIZATION_BUNDLE

    # 建之前先清旧 bundle：若下面任一 `swift build` 因编译错误退出（set -e），旧 app
    # 不能留在原地——否则走查者会 `open` 到上一次成功构建的旧二进制，却以为测的是这次改动。
    rm -rf "$APP" "$LEGACY_APP"

    # 两个 `--product` 都不是可省的修饰：裸 `swift build -c release` 会连各自的测试
    # executable 一起建，而测试会引用 `#if DEBUG` 门控的 fixture，Release 下编译不过。
    gui_build
    swift build -c release --package-path "$repo_root/helper" --product claudio

    GUI_BIN_DIR="$(gui_build --show-bin-path)"
    GUI_RESOURCE_BUNDLE="$(find_unique_gui_resource_bundle "$GUI_BIN_DIR")"
    LOCALIZATION_BUNDLE="$(find_unique_localization_bundle "$GUI_BIN_DIR")"

    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" \
        "$APP/Contents/Resources/packs"
    cp "$GUI_BIN_DIR/ClaudioGUI" "$APP/Contents/MacOS/claudi0-app"
    cp -R "$GUI_RESOURCE_BUNDLE" "$APP/Contents/Resources/$(basename "$GUI_RESOURCE_BUNDLE")"
    cp -R "$LOCALIZATION_BUNDLE" "$APP/Contents/Resources/$(basename "$LOCALIZATION_BUNDLE")"
    HELPER_BIN_DIR="$(swift build -c release --package-path "$repo_root/helper" \
        --product claudio --show-bin-path)"
    HELPER_BINARY="$HELPER_BIN_DIR/claudio"
    BUNDLE_VERSION="$("$HELPER_BINARY" --version)"
    if [[ "$BUNDLE_VERSION" != "0.0.0-dev" \
        && ! "$BUNDLE_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
        echo "❌ helper returned an invalid embedded version: $BUNDLE_VERSION" >&2
        return 1
    fi
    if [[ -n "$REQUESTED_VERSION" && "$BUNDLE_VERSION" != "$REQUESTED_VERSION" ]]; then
        echo "❌ helper version mismatch: requested=$REQUESTED_VERSION embedded=$BUNDLE_VERSION" >&2
        return 1
    fi
    cp "$HELPER_BINARY" "$APP/Contents/Resources/bin/claudi0"
    # 旧入口继续可执行，但只保留一个 helper Mach-O；相对链接在 app/DMG 搬动后仍然成立。
    ln -s claudi0 "$APP/Contents/Resources/bin/claudio"
    bash "$repo_root/scripts/copy-bundled-packs.sh" "$repo_root/packs" \
        "$APP/Contents/Resources/packs"
    cp "$repo_root/assets/branding/claudi0.icns" "$APP/Contents/Resources/claudi0.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>claudi0</string>
  <key>CFBundleDisplayName</key><string>claudi0</string>
  <key>CFBundleIdentifier</key><string>com.claudio.app</string>
  <key>CFBundleVersion</key><string>$BUNDLE_VERSION</string>
  <key>CFBundleShortVersionString</key><string>$BUNDLE_VERSION</string>
  <key>CFBundleExecutable</key><string>claudi0-app</string>
  <key>CFBundleIconFile</key><string>claudi0.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSFocusStatusUsageDescription</key><string>claudi0 uses only whether Focus is active to temporarily quiet automatic sounds. It never stores the Focus name.</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
    printf 'APPL????' > "$APP/Contents/PkgInfo"

    strip -x "$APP/Contents/MacOS/claudi0-app" "$APP/Contents/Resources/bin/claudi0"
    bash "$repo_root/scripts/check-release-size.sh" "$APP"

    codesign \
        --force \
        --deep \
        --entitlements "$repo_root/gui/ClaudioGUI.entitlements" \
        --sign - \
        "$APP"
    codesign --verify --verbose "$APP"
    echo "✅ dist/${APP}（$(uname -m)）—— 用 open dist/${APP} 启动（菜单栏出现 Orbit Zero 图标）"
}

claudio_with_pinned_output_directory "$repo_root" "dist" assemble_dev_bundle
