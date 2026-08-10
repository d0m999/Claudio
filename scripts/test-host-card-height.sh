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
TEST_TEXT_SIZE="${CLAUDIO_TEST_TEXT_SIZE:-maximum}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/claudio-host-card-height.XXXXXX")"
SCREENSHOT_PATH="$TEST_DIR/panel.png"
TEST_PID=""
PREVIOUS_TEXT_SIZE=""
HAD_TEXT_SIZE=false

restore_test_state() {
    set +e
    if [[ -n "$TEST_PID" ]] && kill -0 "$TEST_PID" 2>/dev/null; then
        kill -TERM "$TEST_PID" 2>/dev/null
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$TEST_PID" 2>/dev/null || break
            sleep 0.1
        done
    fi
    if [[ "$HAD_TEXT_SIZE" == true ]]; then
        defaults write "$DEFAULTS_DOMAIN" "$TEXT_SIZE_KEY" -string "$PREVIOUS_TEXT_SIZE"
    else
        defaults delete "$DEFAULTS_DOMAIN" "$TEXT_SIZE_KEY" >/dev/null 2>&1
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

if [[ -f "$APP_EXECUTABLE" ]]; then
    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        kill -TERM "$pid" 2>/dev/null || true
    done < <(pgrep -f "$APP_EXECUTABLE" || true)
fi

if PREVIOUS_TEXT_SIZE="$(defaults read "$DEFAULTS_DOMAIN" "$TEXT_SIZE_KEY" 2>/dev/null)"; then
    HAD_TEXT_SIZE=true
fi

bash scripts/dev-bundle.sh
defaults write "$DEFAULTS_DOMAIN" "$TEXT_SIZE_KEY" -string "$TEST_TEXT_SIZE"
open "$APP_PATH"

for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if TEST_PID="$(pgrep -f "$APP_EXECUTABLE" | head -n 1)" && [[ -n "$TEST_PID" ]]; then
        break
    fi
    sleep 0.25
done
if [[ -z "$TEST_PID" ]]; then
    echo "FAIL: claudi0-app did not start" >&2
    exit 1
fi

for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if osascript -e 'tell application "System Events" to tell process "claudi0-app" to count of menu bars' 2>/dev/null | rg -q '^2$'; then
        break
    fi
    sleep 0.25
done

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

python3 - "$SCREENSHOT_PATH" <<'PY'
import sys

try:
    from PIL import Image
except ImportError:
    print("FAIL: native host-card probe requires Python Pillow", file=sys.stderr)
    raise SystemExit(1)

image_path = sys.argv[1]
image = Image.open(image_path).convert("RGB")
image_width, image_height = image.size

def neutral_runs(y: int, minimum_length: int):
    runs = []
    start = None
    for x in range(image_width):
        red, green, blue = image.getpixel((x, y))
        is_neutral = max(red, green, blue) - min(red, green, blue) <= 12 and 200 <= red <= 245
        if is_neutral and start is None:
            start = x
        if (not is_neutral or x == image_width - 1) and start is not None:
            end = x if is_neutral and x == image_width - 1 else x - 1
            if end - start + 1 >= minimum_length:
                runs.append((start, end))
            start = None
    return runs

# The first row containing two long neutral runs is the two-card top border. This derives the
# card x-ranges from the captured window rather than assuming a particular Retina scale or
# desktop coordinate. The later border scan then remains sensitive to unequal bottom rows.
minimum_run = max(100, round(image_width * 0.10))
candidate_groups = []
for y in range(80, image_height):
    runs = neutral_runs(y, minimum_run)
    if len(runs) < 2:
        continue
    if not candidate_groups or y != candidate_groups[-1][-1][0] + 1:
        candidate_groups.append([(y, runs)])
    else:
        candidate_groups[-1].append((y, runs))

if not candidate_groups:
    print("FAIL: could not locate the two host card top borders", file=sys.stderr)
    raise SystemExit(1)

top_group = candidate_groups[0]
top_runs = sorted(top_group[0][1], key=lambda run: run[1] - run[0], reverse=True)[:2]
top_runs.sort()
if len(top_runs) != 2:
    print("FAIL: could not separate the two host card top borders", file=sys.stderr)
    raise SystemExit(1)

card_regions = []
for top_run in top_runs:
    left = max(0, min(run[0] for _, runs in top_group for run in runs if abs((run[0] + run[1]) / 2 - (top_run[0] + top_run[1]) / 2) < image_width * 0.20) - 8)
    right = min(image_width, max(run[1] for _, runs in top_group for run in runs if abs((run[0] + run[1]) / 2 - (top_run[0] + top_run[1]) / 2) < image_width * 0.20) + 9)
    card_regions.append((left, right))

def border_rows(left: int, right: int):
    width = right - left
    row_hits = []
    for y in range(top_group[-1][0] + 4, min(image_height, top_group[-1][0] + round(image_height * 0.45))):
        hits = 0
        for x in range(left, right):
            red, green, blue = image.getpixel((x, y))
            if max(red, green, blue) - min(red, green, blue) <= 12 and 200 <= red <= 245:
                hits += 1
        if hits >= max(20, round(width * 0.55)):
            row_hits.append(y)

    groups = []
    for y in row_hits:
        if not groups or y != groups[-1][-1] + 1:
            groups.append([y])
        else:
            groups[-1].append(y)
    return groups

card_bottoms = []
for left, right in card_regions:
    groups = border_rows(left, right)
    if not groups:
        print(f"FAIL: could not detect a host card bottom in x={left}:{right}", file=sys.stderr)
        raise SystemExit(1)
    card_bottoms.append(groups[-1][-1])

if len(card_bottoms) != 2:
    print("FAIL: could not detect both host card bottoms", file=sys.stderr)
    raise SystemExit(1)

claude_bottom, codex_bottom = card_bottoms
delta = abs(claude_bottom - codex_bottom)
print(
    f"Claude Code card bottom={claude_bottom}px, "
    f"Codex card bottom={codex_bottom}px, delta={delta}px"
)
if delta > 2:
    print(
        f"FAIL: host card bottoms differ by {delta}px (allowed <= 2px)",
        file=sys.stderr,
    )
    raise SystemExit(1)
print("PASS: host card bottoms are aligned within 2px")
PY
