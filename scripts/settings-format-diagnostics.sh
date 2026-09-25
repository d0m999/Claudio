#!/usr/bin/env bash

settings_format_normalize_diagnostics() {
    local raw_output="$1"
    local normalized_output="$2"
    local source_root="${3:-}"

    # A diagnostic's line and column move when unrelated edits add or remove surrounding lines.
    # Keep path, severity, rule, and message as its stable identity. Do not deduplicate: repeated
    # identities are separate occurrences, so the sorted files form multisets for comm.
    LC_ALL=C awk -v root="$source_root" \
        '/^[^:]+:[0-9]+:[0-9]+: (error|warning|note): / {
            line = $0
            if (root != "" && substr(line, 1, length(root) + 1) == root "/") {
                line = substr(line, length(root) + 2)
            }
            print line
        }' \
        "$raw_output" \
        | LC_ALL=C sed -E 's/^([^:]+):[0-9]+:[0-9]+: /\1: /' \
        | LC_ALL=C sort >"$normalized_output"
}

settings_format_validate_diagnostics() {
    local lint_status="$1"
    local raw_output="$2"
    local normalized_output="$3"

    if [[ $lint_status -ne 0 && ! -s "$normalized_output" ]]; then
        cat "$raw_output" >&2
        echo "❌ swift format lint failed without parseable diagnostics" >&2
        return 1
    fi
}

settings_format_compare_diagnostics() {
    local baseline_diagnostics="$1"
    local head_diagnostics="$2"
    local new_diagnostics="$3"

    LC_ALL=C comm -13 "$baseline_diagnostics" "$head_diagnostics" >"$new_diagnostics"
}

settings_format_keep_changed_diagnostics() {
    local diagnostics="$1"
    local changed_paths="$2"
    local output="$3"

    # Recursive lint can emit inconsistent diagnostics for byte-identical files between runs.
    # Only a changed Swift file can introduce a source-format regression when .swift-format is
    # unchanged. Keep duplicate occurrences so a new warning in a changed file still fails.
    LC_ALL=C awk '
        NR == FNR { changed[$0] = 1; next }
        {
            path = $0
            sub(/: (error|warning|note): .*/, "", path)
            if (path in changed) print
        }
    ' "$changed_paths" "$diagnostics" >"$output"
}
