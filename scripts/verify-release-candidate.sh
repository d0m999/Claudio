#!/usr/bin/env bash
# Verify the identity and bytes of a downloaded workflow_dispatch RC artifact. This does not
# replace the signing/notarization checks performed from the mounted DMG inside release.yml; it
# proves that the downloaded container is the exact artifact and checksum that workflow verified.
set -euo pipefail

usage() {
    echo "usage: $0 --artifact-dir <path> --run-id <id> --run-url <url>" \
        "--artifact-name <name> --commit-sha <sha> --version <version>" >&2
}

artifact_dir=""
expected_run_id=""
expected_run_url=""
expected_artifact_name=""
expected_commit_sha=""
expected_version=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --artifact-dir)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            artifact_dir="$2"
            shift 2
            ;;
        --run-id)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            expected_run_id="$2"
            shift 2
            ;;
        --run-url)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            expected_run_url="$2"
            shift 2
            ;;
        --artifact-name)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            expected_artifact_name="$2"
            shift 2
            ;;
        --commit-sha)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            expected_commit_sha="$2"
            shift 2
            ;;
        --version)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            expected_version="$2"
            shift 2
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

if [[ -z "$artifact_dir" || -z "$expected_run_id" || -z "$expected_run_url" \
    || -z "$expected_artifact_name" || -z "$expected_commit_sha" || -z "$expected_version" ]]; then
    usage
    exit 2
fi
if [[ ! -d "$artifact_dir" || -L "$artifact_dir" ]]; then
    echo "❌ artifact directory must be a real directory: $artifact_dir" >&2
    exit 1
fi
if [[ ! "$expected_run_id" =~ ^[1-9][0-9]*$ ]]; then
    echo "❌ run ID must be a positive decimal integer" >&2
    exit 1
fi
if [[ ! "$expected_commit_sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "❌ commit SHA must be exactly 40 lowercase hexadecimal characters" >&2
    exit 1
fi
if [[ "$expected_version" != "0.1.0" ]]; then
    echo "❌ the first RC verifier is fixed to version 0.1.0" >&2
    exit 1
fi
canonical_run_url="https://github.com/d0m999/Claudio/actions/runs/$expected_run_id"
if [[ "$expected_run_url" != "$canonical_run_url" ]]; then
    echo "❌ run URL does not match the Claudio repository and run ID" >&2
    exit 1
fi
canonical_artifact_name="claudi0-rc-$expected_commit_sha"
if [[ "$expected_artifact_name" != "$canonical_artifact_name" ]]; then
    echo "❌ artifact name does not match the target commit" >&2
    exit 1
fi

gh_bin="${CLAUDIO_GH_BIN:-gh}"
if ! command -v "$gh_bin" >/dev/null 2>&1; then
    echo "❌ GitHub CLI is required to bind the downloaded artifact to a live workflow run" >&2
    exit 1
fi
if ! run_json="$(
    "$gh_bin" run view "$expected_run_id" \
        --repo d0m999/Claudio \
        --json conclusion,event,headSha,url,workflowName
)"; then
    echo "❌ unable to read the expected GitHub Actions run" >&2
    exit 1
fi
if ! jq -e \
    --arg run_url "$expected_run_url" \
    --arg commit_sha "$expected_commit_sha" '
        type == "object"
        and .conclusion == "success"
        and .event == "workflow_dispatch"
        and .headSha == $commit_sha
        and .url == $run_url
        and .workflowName == "Release"
    ' <<< "$run_json" >/dev/null; then
    echo "❌ live workflow run does not match the successful RC identity" >&2
    exit 1
fi
if ! artifacts_json="$(
    "$gh_bin" api "repos/d0m999/Claudio/actions/runs/$expected_run_id/artifacts"
)"; then
    echo "❌ unable to read artifacts for the expected GitHub Actions run" >&2
    exit 1
fi
if ! artifact_record="$(jq -cer \
    --arg artifact_name "$expected_artifact_name" \
    --arg commit_sha "$expected_commit_sha" '
        [.artifacts[] | select(.name == $artifact_name)] as $matches
        | if (($matches | length) == 1
            and ($matches[0].id | type == "number" and . > 0)
            and ($matches[0].digest | type == "string" and test("^sha256:[0-9a-f]{64}$"))
            and $matches[0].expired == false
            and $matches[0].workflow_run.head_sha == $commit_sha)
          then $matches[0]
          else error("artifact identity mismatch")
          end
    ' <<< "$artifacts_json")"; then
    echo "❌ live artifact identity is missing, expired, duplicated, or bound to another commit" >&2
    exit 1
fi

artifact_id="$(jq -er '.id | tostring' <<< "$artifact_record")"
expected_archive_digest="$(jq -er '.digest | sub("^sha256:"; "")' <<< "$artifact_record")"
verification_temp="$(mktemp -d "${TMPDIR:-/tmp}/claudio-rc-verify.XXXXXX")"
cleanup_verification_temp() {
    rm -rf -- "$verification_temp"
}
trap cleanup_verification_temp EXIT
official_archive="$verification_temp/artifact.zip"
official_contents="$verification_temp/contents"
mkdir "$official_contents"
if ! "$gh_bin" api "repos/d0m999/Claudio/actions/artifacts/$artifact_id/zip" \
    > "$official_archive"; then
    echo "❌ unable to download the live GitHub Actions artifact archive" >&2
    exit 1
fi
actual_archive_digest="$(shasum -a 256 "$official_archive" | awk '{print $1}')"
if [[ "$actual_archive_digest" != "$expected_archive_digest" ]]; then
    echo "❌ downloaded artifact archive does not match GitHub's SHA-256 digest" >&2
    exit 1
fi
if ! /usr/bin/ditto -x -k "$official_archive" "$official_contents"; then
    echo "❌ unable to extract the digest-verified artifact archive" >&2
    exit 1
fi
if ! diff -qr "$official_contents" "$artifact_dir" >/dev/null; then
    echo "❌ supplied artifact directory differs from the digest-verified GitHub download" >&2
    exit 1
fi

dmg_name="claudi0-$expected_version.dmg"
manifest_path="$artifact_dir/RC_MANIFEST.json"
checksum_path="$artifact_dir/SHA256SUMS.txt"
dmg_path="$artifact_dir/$dmg_name"
for required_file in "$manifest_path" "$checksum_path" "$dmg_path"; do
    if [[ ! -f "$required_file" || -L "$required_file" || ! -s "$required_file" ]]; then
        echo "❌ required artifact file is missing, empty, or a symlink: $required_file" >&2
        exit 1
    fi
done

shopt -s nullglob dotglob
artifact_entries=("$artifact_dir"/*)
shopt -u nullglob dotglob
if [[ ${#artifact_entries[@]} -ne 3 ]]; then
    echo "❌ artifact directory must contain exactly the DMG, checksum, and RC manifest" >&2
    exit 1
fi
for artifact_entry in "${artifact_entries[@]}"; do
    artifact_basename="$(basename "$artifact_entry")"
    case "$artifact_basename" in
        "$dmg_name"|SHA256SUMS.txt|RC_MANIFEST.json) ;;
        *)
            echo "❌ unexpected artifact entry: $artifact_entry" >&2
            exit 1
            ;;
    esac
done

if ! jq -e \
    --arg run_id "$expected_run_id" \
    --arg run_url "$expected_run_url" \
    --arg artifact_name "$expected_artifact_name" \
    --arg commit_sha "$expected_commit_sha" \
    --arg version "$expected_version" \
    --arg dmg_name "$dmg_name" '
        type == "object"
        and keys == [
            "artifact_name",
            "authorization_attested",
            "commit_sha",
            "dmg_name",
            "dmg_sha256",
            "schema",
            "version",
            "workflow_event",
            "workflow_name",
            "workflow_run_id",
            "workflow_run_url"
        ]
        and .schema == 1
        and .workflow_name == "Release"
        and .workflow_event == "workflow_dispatch"
        and .workflow_run_id == $run_id
        and .workflow_run_url == $run_url
        and .artifact_name == $artifact_name
        and .commit_sha == $commit_sha
        and .version == $version
        and .dmg_name == $dmg_name
        and (.dmg_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
        and .authorization_attested == true
    ' "$manifest_path" >/dev/null; then
    echo "❌ RC manifest does not match the expected run and artifact identity" >&2
    exit 1
fi

expected_dmg_sha256="$(jq -er '.dmg_sha256' "$manifest_path")"
checksum_line="$(<"$checksum_path")"
expected_checksum_line="$expected_dmg_sha256  $dmg_name"
checksum_byte_count="$(wc -c < "$checksum_path" | tr -d ' ')"
expected_checksum_byte_count=$((${#expected_checksum_line} + 1))
if [[ "$checksum_line" != "$expected_checksum_line" \
    || "$checksum_byte_count" != "$expected_checksum_byte_count" ]]; then
    echo "❌ SHA256SUMS.txt does not exactly match the manifest" >&2
    exit 1
fi
actual_dmg_sha256="$(shasum -a 256 "$dmg_path" | awk '{print $1}')"
if [[ "$actual_dmg_sha256" != "$expected_dmg_sha256" ]]; then
    echo "❌ downloaded DMG SHA-256 does not match the manifest" >&2
    exit 1
fi

echo "✅ verified RC artifact:" \
    "run=$expected_run_id artifact=$expected_artifact_name commit=$expected_commit_sha" \
    "dmg=$dmg_name sha256=$actual_dmg_sha256"
