#!/usr/bin/env bash
# Build outside the timed process, then measure the Release benchmark executable directly.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "machine_model=$(sysctl -n hw.model 2>/dev/null || echo unknown)"
echo "cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
echo "architecture=$(uname -m)"
echo "filesystem=$(diskutil info / 2>/dev/null | awk -F: '/File System Personality/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')"

swift build -c release --package-path gui --product claudio-sound-pack-benchmark
BIN_PATH="$(swift build -c release --package-path gui --show-bin-path)"
/usr/bin/time -l "$BIN_PATH/claudio-sound-pack-benchmark"
