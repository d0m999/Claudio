#!/usr/bin/env bash
# Assemble the macOS 12 compatibility LoginItem. Signing is intentionally owned by the caller so
# dev ad-hoc and release Developer ID flows can apply their distinct identities in inside-out order.
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <login-item-binary> <parent-app> <bundle-version>" >&2
    exit 2
fi

readonly binary="$1"
readonly parent_app="$2"
readonly bundle_version="$3"
readonly login_item_app="$parent_app/Contents/Library/LoginItems/claudi0 LoginItem.app"

fail() {
    echo "❌ $*" >&2
    exit 1
}

if [[ ! -f "$binary" || -L "$binary" || ! -x "$binary" ]]; then
    fail "LoginItem executable is missing, linked, or not executable: $binary"
fi
if [[ ! -d "$parent_app/Contents" || -L "$parent_app" ]]; then
    fail "parent app Contents directory is missing or unsafe: $parent_app"
fi
if [[ ! "$bundle_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ \
    && "$bundle_version" != "0.0.0-dev" ]]; then
    fail "LoginItem bundle version is invalid: $bundle_version"
fi
if [[ -e "$login_item_app" ]]; then
    fail "unexpected pre-existing LoginItem bundle: $login_item_app"
fi

mkdir -p "$login_item_app/Contents/MacOS"
cp "$binary" "$login_item_app/Contents/MacOS/claudi0-login-item"
chmod +x "$login_item_app/Contents/MacOS/claudi0-login-item"
cat > "$login_item_app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>claudi0 LoginItem</string>
  <key>CFBundleIdentifier</key><string>com.claudio.app.login-item</string>
  <key>CFBundleVersion</key><string>$bundle_version</string>
  <key>CFBundleShortVersionString</key><string>$bundle_version</string>
  <key>CFBundleExecutable</key><string>claudi0-login-item</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$login_item_app/Contents/PkgInfo"

plutil -lint "$login_item_app/Contents/Info.plist" >/dev/null \
    || fail "assembled LoginItem Info.plist is invalid"
