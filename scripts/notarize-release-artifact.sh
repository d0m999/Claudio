#!/usr/bin/env bash
# Submit one signed app or DMG to Apple's notary service, require acceptance, and staple the
# resulting ticket. release.yml owns signing and invokes this helper once for each container.
set -euo pipefail

usage() {
    echo "usage: $0 <signed-app-or-dmg>" >&2
}

if [[ $# -ne 1 ]]; then
    usage
    exit 2
fi

artifact="$1"
if [[ ! -e "$artifact" || -L "$artifact" ]]; then
    echo "❌ notarization artifact must exist and must not be a symlink: $artifact" >&2
    exit 1
fi

case "$artifact" in
    *.app)
        artifact_kind="app"
        prepare_submission() {
            submission="$notary_temp/$(basename "$artifact").zip"
            ditto -c -k --keepParent "$artifact" "$submission"
        }
        assess_artifact() {
            codesign --verify --deep --strict --verbose=2 "$artifact"
            spctl --assess --type execute --verbose=4 "$artifact"
        }
        ;;
    *.dmg)
        artifact_kind="dmg"
        prepare_submission() {
            :
        }
        assess_artifact() {
            codesign --verify --verbose=2 "$artifact"
            spctl --assess \
                --type open \
                --context context:primary-signature \
                --verbose=4 \
                "$artifact"
        }
        ;;
    *)
        echo "❌ notarization artifact must be an .app or .dmg: $artifact" >&2
        exit 1
        ;;
esac

missing=()
for variable_name in NOTARY_KEY_PATH NOTARY_KEY_ID NOTARY_ISSUER_ID; do
    if [[ -z "${!variable_name:-}" ]]; then
        missing+=("$variable_name")
    fi
done
if [[ ${#missing[@]} -ne 0 ]]; then
    echo "❌ missing required notarization environment: ${missing[*]}" >&2
    exit 1
fi

notary_temp="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/claudio-notary.XXXXXX")"
cleanup_notary_temp() {
    rm -rf -- "$notary_temp"
}
trap cleanup_notary_temp EXIT

submission="$artifact"
prepare_submission

result_path="$notary_temp/result.json"
log_path="$notary_temp/log.json"
xcrun notarytool submit "$submission" \
    --key "$NOTARY_KEY_PATH" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" \
    --wait \
    --output-format json > "$result_path"

status="$(jq -er '.status' "$result_path")"
submission_id="$(jq -er '.id' "$result_path")"
if [[ "$status" != "Accepted" ]]; then
    echo "❌ $artifact_kind notarization was not accepted: $status" >&2
    exit 1
fi

xcrun notarytool log "$submission_id" "$log_path" \
    --key "$NOTARY_KEY_PATH" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID"
jq . "$log_path"
xcrun stapler staple "$artifact"
xcrun stapler validate "$artifact"
assess_artifact
