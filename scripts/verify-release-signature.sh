#!/usr/bin/env bash
# Verify one signed release executable, app, or DMG against the approved Developer ID team.
set -euo pipefail

usage() {
    echo "usage: $0 <executable|app|dmg> <expected-team-id> <artifact>" >&2
}

fail() {
    echo "❌ $*" >&2
    exit 1
}

if [[ $# -ne 3 ]]; then
    usage
    exit 2
fi

artifact_kind="$1"
expected_team_id="$2"
artifact="$3"

if [[ ! "$expected_team_id" =~ ^[A-Z0-9]{10}$ ]]; then
    fail "expected team ID must contain exactly 10 uppercase letters or digits"
fi
if [[ ! -e "$artifact" || -L "$artifact" ]]; then
    fail "signature artifact must exist and must not be a symlink: $artifact"
fi

case "$artifact_kind" in
    executable)
        verify_arguments=(--verify --strict --verbose=2)
        requires_runtime=true
        ;;
    app)
        verify_arguments=(--verify --deep --strict --verbose=2)
        requires_runtime=true
        ;;
    dmg)
        verify_arguments=(--verify --verbose=2)
        requires_runtime=false
        ;;
    *)
        usage
        exit 2
        ;;
esac

codesign_bin="${CLAUDIO_CODESIGN_BIN:-codesign}"
if ! command -v "$codesign_bin" >/dev/null 2>&1; then
    fail "codesign is required to verify release signatures"
fi
if ! "$codesign_bin" "${verify_arguments[@]}" "$artifact"; then
    fail "codesign verification failed for $artifact_kind artifact"
fi
if ! signature_details="$("$codesign_bin" -d --verbose=4 "$artifact" 2>&1)"; then
    fail "unable to inspect signature details for $artifact_kind artifact"
fi
if ! grep -Fq "Authority=Developer ID Application:" <<< "$signature_details"; then
    fail "$artifact_kind artifact is not signed by a Developer ID Application identity"
fi
if ! grep -Fq "TeamIdentifier=$expected_team_id" <<< "$signature_details"; then
    fail "$artifact_kind artifact is signed by an unexpected Developer ID team"
fi
if [[ "$requires_runtime" == "true" ]] \
    && ! grep -Fq "flags=0x10000(runtime)" <<< "$signature_details"; then
    fail "hardened runtime is missing from $artifact_kind artifact"
fi
if ! grep -Fq "Timestamp=" <<< "$signature_details" \
    || grep -Fq "Timestamp=none" <<< "$signature_details"; then
    fail "secure timestamp is missing from $artifact_kind artifact"
fi

echo "✅ verified $artifact_kind Developer ID signature"
