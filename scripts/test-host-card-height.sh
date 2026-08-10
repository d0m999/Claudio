#!/usr/bin/env bash
# Native regression probe for the two host cards in the menu-bar panel.
#
# This intentionally exercises the real release bundle and the real AppKit popover. The
# screenshot detector reads the two card border rows from the real popover window, so a
# source-only build cannot make this check pass by accident.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_PATH="${CLAUDIO_TEST_APP_PATH:-$PWD/dist/claudi0.app}"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/claudi0-app"
DEFAULTS_DOMAIN="com.claudio.app"
TEXT_SIZE_KEY="Claudio.InterfaceTextSize"
APPEARANCE_KEY="AppleInterfaceStyle"
TEST_HOST_CARD_STATE="${CLAUDIO_TEST_HOST_CARD_STATE:-unequal}"
TEST_TEXT_SIZE="${CLAUDIO_TEST_TEXT_SIZE:-maximum}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/claudio-host-card-height.XXXXXX")"
SCREENSHOT_PATH="$TEST_DIR/panel.png"
TEST_PID=""
PREVIOUS_TEXT_SIZE=""
HAD_TEXT_SIZE=false
PREVIOUS_APPEARANCE=""
HAD_APPEARANCE=false
STATE_SNAPSHOT_COMPLETE=false
OLD_PIDS=()

restore_test_state() {
    set +e
    if [[ -n "$TEST_PID" ]] && kill -0 "$TEST_PID" 2>/dev/null; then
        kill -TERM "$TEST_PID" 2>/dev/null
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
            kill -0 "$TEST_PID" 2>/dev/null || break
            sleep 0.1
        done
    fi
    if [[ "$STATE_SNAPSHOT_COMPLETE" != true ]]; then
        rm -rf "$TEST_DIR"
        return
    fi
    if [[ "$HAD_TEXT_SIZE" == true ]]; then
        defaults write "$DEFAULTS_DOMAIN" "$TEXT_SIZE_KEY" -string "$PREVIOUS_TEXT_SIZE"
    else
        defaults delete "$DEFAULTS_DOMAIN" "$TEXT_SIZE_KEY" >/dev/null 2>&1
    fi
    if [[ "$HAD_APPEARANCE" == true ]]; then
        defaults write "$DEFAULTS_DOMAIN" "$APPEARANCE_KEY" -string "$PREVIOUS_APPEARANCE"
    else
        defaults delete "$DEFAULTS_DOMAIN" "$APPEARANCE_KEY" >/dev/null 2>&1
    fi
    rm -rf "$TEST_DIR"
}
trap restore_test_state EXIT INT TERM

case "$TEST_TEXT_SIZE" in
    standard|large|maximum) ;;
    *)
        echo "FAIL: unsupported Claudio interface text size: $TEST_TEXT_SIZE" >&2
        exit 1
        ;;
esac

case "$TEST_HOST_CARD_STATE" in
    unequal) ;;
    *)
        echo "FAIL: unsupported host-card probe state: $TEST_HOST_CARD_STATE" >&2
        exit 1
        ;;
esac

if PREVIOUS_TEXT_SIZE="$(defaults read "$DEFAULTS_DOMAIN" "$TEXT_SIZE_KEY" 2>/dev/null)"; then
    HAD_TEXT_SIZE=true
fi
if PREVIOUS_APPEARANCE="$(defaults read "$DEFAULTS_DOMAIN" "$APPEARANCE_KEY" 2>/dev/null)"; then
    HAD_APPEARANCE=true
fi
STATE_SNAPSHOT_COMPLETE=true

if [[ -f "$APP_EXECUTABLE" ]]; then
    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        OLD_PIDS+=("$pid")
        kill -TERM "$pid" 2>/dev/null || true
    done < <(pgrep -f "$APP_EXECUTABLE" || true)
fi

for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
    old_pid_alive=false
    if [[ ${#OLD_PIDS[@]} -gt 0 ]]; then
        for pid in "${OLD_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                old_pid_alive=true
                break
            fi
        done
    fi
    [[ "$old_pid_alive" == false ]] && break
    sleep 0.1
done
if [[ ${#OLD_PIDS[@]} -gt 0 ]]; then
    for pid in "${OLD_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "FAIL: previous claudi0-app PID $pid did not exit after SIGTERM" >&2
            exit 1
        fi
    done
fi

bash scripts/dev-bundle.sh --native-host-card-probe
defaults write "$DEFAULTS_DOMAIN" "$TEXT_SIZE_KEY" -string "$TEST_TEXT_SIZE"
defaults write "$DEFAULTS_DOMAIN" "$APPEARANCE_KEY" -string "Light"
CLAUDIO_TEST_HOST_CARD_STATE="$TEST_HOST_CARD_STATE" \
    "$APP_EXECUTABLE" >"$TEST_DIR/app.log" 2>&1 &
TEST_PID=$!

if ! kill -0 "$TEST_PID" 2>/dev/null; then
    echo "FAIL: claudi0-app did not start" >&2
    exit 1
fi
if ! ps -p "$TEST_PID" -o command= | rg -F -q "$APP_EXECUTABLE"; then
    echo "FAIL: launched PID $TEST_PID is not the requested claudi0-app bundle" >&2
    exit 1
fi

MENU_BAR_READY=false
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if osascript -e 'tell application "System Events" to tell process "claudi0-app" to count of menu bars' 2>/dev/null | rg -q '^2$'; then
        MENU_BAR_READY=true
        break
    fi
    sleep 0.25
done
if [[ "$MENU_BAR_READY" != true ]]; then
    echo "FAIL: claudi0-app did not publish its expected menu bar" >&2
    exit 1
fi

osascript -e 'tell application "System Events" to tell process "claudi0-app" to perform action "AXPress" of menu bar item 1 of menu bar 2'

POPUP_WINDOW_ID=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    POPUP_WINDOW_ID="$({
        swift -e 'import CoreGraphics; let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]; for item in list { let owner = item[kCGWindowOwnerName as String] as? String ?? ""; if owner == "claudi0", let number = item[kCGWindowNumber as String] as? Int { print(number); break } }'
    } 2>/dev/null | head -n 1)"
    if [[ -n "$POPUP_WINDOW_ID" ]]; then
        break
    fi
    sleep 0.25
done
if [[ -z "$POPUP_WINDOW_ID" ]]; then
    echo "FAIL: could not locate the visible claudi0 popover window" >&2
    exit 1
fi

# Capture the popover itself. The host session can have multiple Spaces/displays, while the
# window ID is an unambiguous native AppKit target and still gives us a retina screenshot.
screencapture -x -T 0 -l "$POPUP_WINDOW_ID" "$SCREENSHOT_PATH"

STATUS_GEOMETRY="$({
    osascript <<'APPLESCRIPT'
tell application "System Events"
  tell process "claudi0-app"
    tell menu bar item 1 of menu bar 2
      set p to position
      set s to size
      return ((item 1 of p) as text) & "," & ((item 2 of p) as text) & "," & ((item 1 of s) as text) & "," & ((item 2 of s) as text)
    end tell
  end tell
end tell
APPLESCRIPT
} 2>/dev/null)"

if [[ -z "$STATUS_GEOMETRY" ]]; then
    echo "FAIL: could not locate claudi0 status item" >&2
    exit 1
fi

swift scripts/scan-host-card-height.swift "$SCREENSHOT_PATH"
