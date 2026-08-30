#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/settings-format-diagnostics.sh"

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/claudio-format-test.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT

baseline_raw="$temporary_root/baseline.txt"
shifted_raw="$temporary_root/shifted.txt"
added_raw="$temporary_root/added.txt"
unparseable_raw="$temporary_root/unparseable.txt"

printf '%s\n' \
    'gui/A.swift:10:3: error: [Indentation] indent by 4 spaces' \
    'gui/A.swift:20:3: error: [Indentation] indent by 4 spaces' \
    >"$baseline_raw"
printf '%s\n' \
    'gui/A.swift:110:9: error: [Indentation] indent by 4 spaces' \
    'gui/A.swift:120:9: error: [Indentation] indent by 4 spaces' \
    >"$shifted_raw"
printf '%s\n' \
    'gui/A.swift:110:9: error: [Indentation] indent by 4 spaces' \
    'gui/A.swift:120:9: error: [Indentation] indent by 4 spaces' \
    'gui/A.swift:130:9: error: [Indentation] indent by 4 spaces' \
    >"$added_raw"
printf '%s\n' 'swift-format stopped before emitting a diagnostic' >"$unparseable_raw"

for fixture in baseline shifted added unparseable; do
    settings_format_normalize_diagnostics \
        "$temporary_root/$fixture.txt" \
        "$temporary_root/$fixture.normalized"
done

settings_format_compare_diagnostics \
    "$temporary_root/baseline.normalized" \
    "$temporary_root/shifted.normalized" \
    "$temporary_root/shifted.new"
if [[ -s "$temporary_root/shifted.new" ]]; then
    echo "❌ line and column drift was treated as a new diagnostic" >&2
    exit 1
fi

settings_format_compare_diagnostics \
    "$temporary_root/baseline.normalized" \
    "$temporary_root/added.normalized" \
    "$temporary_root/added.new"
added_count="$(wc -l <"$temporary_root/added.new" | tr -d ' ')"
if [[ "$added_count" != 1 ]]; then
    echo "❌ expected one added duplicate diagnostic occurrence, got $added_count" >&2
    exit 1
fi

if settings_format_validate_diagnostics \
    1 \
    "$unparseable_raw" \
    "$temporary_root/unparseable.normalized" \
    >/dev/null 2>&1
then
    echo "❌ unparseable failing lint output was accepted" >&2
    exit 1
fi

echo "✅ settings format diagnostic regressions passed"
