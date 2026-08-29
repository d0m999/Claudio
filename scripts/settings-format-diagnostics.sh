#!/usr/bin/env bash

settings_format_normalize_diagnostics() {
    local raw_output="$1"
    local normalized_output="$2"

    # A diagnostic's line and column move when unrelated edits add or remove surrounding lines.
    # Keep path, severity, rule, and message as its stable identity. Do not deduplicate: repeated
    # identities are separate occurrences, so the sorted files form multisets for comm.
    LC_ALL=C awk \
        '/^[^:]+:[0-9]+:[0-9]+: (error|warning|note): / { print }' \
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
