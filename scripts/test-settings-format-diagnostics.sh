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
absolute_baseline_raw="$temporary_root/absolute-baseline.txt"
absolute_head_raw="$temporary_root/absolute-head.txt"

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
printf '%s\n' \
    '/tmp/old-checkout/gui/A.swift:10:3: error: [Indentation] indent by 4 spaces' \
    >"$absolute_baseline_raw"
printf '%s\n' \
    '/tmp/new-checkout/gui/A.swift:110:9: error: [Indentation] indent by 4 spaces' \
    >"$absolute_head_raw"

for fixture in baseline shifted added unparseable; do
    settings_format_normalize_diagnostics \
        "$temporary_root/$fixture.txt" \
        "$temporary_root/$fixture.normalized"
done

settings_format_normalize_diagnostics \
    "$absolute_baseline_raw" \
    "$temporary_root/absolute-baseline.normalized" \
    /tmp/old-checkout
settings_format_normalize_diagnostics \
    "$absolute_head_raw" \
    "$temporary_root/absolute-head.normalized" \
    /tmp/new-checkout
settings_format_compare_diagnostics \
    "$temporary_root/absolute-baseline.normalized" \
    "$temporary_root/absolute-head.normalized" \
    "$temporary_root/absolute.new"
if [[ -s "$temporary_root/absolute.new" ]]; then
    echo "❌ checkout path drift was treated as a new diagnostic" >&2
    exit 1
fi

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

printf '%s\n' 'gui/A.swift' >"$temporary_root/changed-paths.txt"
printf '%s\n' \
    'gui/A.swift: error: [Indentation] indent by 4 spaces' \
    'gui/B.swift: warning: [TrailingComma] add trailing comma' \
    'gui/A.swift: error: [Indentation] indent by 4 spaces' \
    >"$temporary_root/mixed-diagnostics.txt"
settings_format_keep_changed_diagnostics \
    "$temporary_root/mixed-diagnostics.txt" \
    "$temporary_root/changed-paths.txt" \
    "$temporary_root/changed-diagnostics.txt"
if [[ "$(wc -l <"$temporary_root/changed-diagnostics.txt" | tr -d ' ')" != 2 ]]; then
    echo "❌ changed-file diagnostics did not retain duplicate occurrences" >&2
    exit 1
fi
if rg -q 'gui/B.swift' "$temporary_root/changed-diagnostics.txt"; then
    echo "❌ unchanged-file lint drift was treated as a regression" >&2
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
