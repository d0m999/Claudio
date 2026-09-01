#!/usr/bin/env bash
# Verify the current-architecture ad-hoc app used for local inspection.
set -euo pipefail

usage() {
    echo "usage: $0 <app>" >&2
}

fail() {
    echo "❌ $*" >&2
    exit 1
}

if [[ $# -ne 1 ]]; then
    usage
    exit 2
fi

app="$1"
if [[ ! -d "$app" || -L "$app" ]]; then
    fail "dev bundle must exist and must not be a symlink: $app"
fi

codesign_bin="${CLAUDIO_CODESIGN_BIN:-codesign}"
if ! command -v "$codesign_bin" >/dev/null 2>&1; then
    fail "codesign is required to verify the dev bundle"
fi

if ! app_entitlements="$("$codesign_bin" -d --entitlements :- "$app" 2>/dev/null)"; then
    fail "unable to inspect dev bundle entitlements"
fi
if [[ -n "$app_entitlements" ]]; then
    fail "local ad-hoc app must not contain entitlements"
fi
if ! "$codesign_bin" --verify --deep --strict --verbose=2 "$app"; then
    fail "codesign verification failed for dev bundle"
fi

echo "✅ verified launch-compatible ad-hoc dev bundle signature"
