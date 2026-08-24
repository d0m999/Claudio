#!/usr/bin/env bash
# Verify a downloaded workflow_dispatch RC against the repository's single release acceptance
# ledger, live GitHub metadata, the official artifact archive, and the downloaded DMG bytes.
set -euo pipefail

usage() {
    echo "usage: $0 --artifact-dir <path> --ledger <release-acceptance.md>" >&2
}

fail() {
    echo "❌ $*" >&2
    exit 1
}

artifact_dir=""
ledger_path=""
readonly maximum_metadata_bytes=131072
readonly maximum_checksum_bytes=256
readonly maximum_artifact_bytes=26214400

while [[ $# -gt 0 ]]; do
    case "$1" in
        --artifact-dir)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            artifact_dir="$2"
            shift 2
            ;;
        --ledger)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            ledger_path="$2"
            shift 2
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

if [[ -z "$artifact_dir" || -z "$ledger_path" ]]; then
    usage
    exit 2
fi
if [[ ! -d "$artifact_dir" || -L "$artifact_dir" ]]; then
    fail "artifact directory must be a real directory: $artifact_dir"
fi
if [[ ! -f "$ledger_path" || -L "$ledger_path" || ! -s "$ledger_path" ]]; then
    fail "release acceptance ledger must be a non-empty regular file: $ledger_path"
fi
ledger_byte_count="$(wc -c < "$ledger_path" | tr -d ' ')"
if [[ ! "$ledger_byte_count" =~ ^[0-9]+$ \
    || "$ledger_byte_count" -gt "$maximum_metadata_bytes" ]]; then
    fail "release acceptance ledger exceeds the 128 KiB verification limit"
fi

ledger_value() {
    local field="$1"
    local value
    local -a matches=()
    while IFS= read -r value; do
        matches+=("$value")
    done < <(
        awk -F '|' -v expected_field="$field" '
            function trim(input) {
                sub(/^[[:space:]]+/, "", input)
                sub(/[[:space:]]+$/, "", input)
                return input
            }
            NF == 4 && trim($2) == expected_field { print trim($3) }
        ' "$ledger_path"
    )
    if [[ ${#matches[@]} -ne 1 ]]; then
        echo "❌ ledger field must appear exactly once: $field" >&2
        return 1
    fi
    value="${matches[0]}"
    if [[ ${#value} -ge 2 && "${value:0:1}" == '`' && "${value: -1}" == '`' ]]; then
        value="${value:1:$((${#value} - 2))}"
    fi
    printf '%s\n' "$value"
}

read_ledger_value() {
    local destination_name="$1"
    local field="$2"
    local resolved_value
    if ! resolved_value="$(ledger_value "$field")"; then
        exit 1
    fi
    printf -v "$destination_name" '%s' "$resolved_value"
}

read_ledger_value expected_version "RC version"
read_ledger_value expected_workflow_path "Release workflow path"
read_ledger_value expected_workflow_id "Release workflow ID"
read_ledger_value expected_workflow_ref "Workflow ref"
read_ledger_value expected_workflow_inputs "Workflow inputs"
read_ledger_value expected_commit_sha "Commit SHA"
read_ledger_value expected_run_url "GitHub Actions run URL"
read_ledger_value expected_run_id "GitHub Actions run ID"
read_ledger_value expected_artifact_name "Actions artifact 名称"
read_ledger_value expected_dmg_name "DMG 文件名"
read_ledger_value expected_dmg_sha256 "DMG SHA-256"

if [[ "$expected_version" != "0.1.0" ]]; then
    fail "the first RC verifier requires ledger version 0.1.0"
fi
if [[ "$expected_workflow_path" != ".github/workflows/release.yml" ]]; then
    fail "ledger release workflow path is not the canonical release workflow"
fi
if [[ ! "$expected_workflow_id" =~ ^[1-9][0-9]*$ ]]; then
    fail "ledger release workflow ID must be a positive decimal integer"
fi
if [[ "$expected_workflow_ref" != "refs/heads/main" ]]; then
    fail "ledger workflow ref must be refs/heads/main"
fi
if [[ ! "$expected_commit_sha" =~ ^[0-9a-f]{40}$ ]]; then
    fail "ledger commit SHA must be exactly 40 lowercase hexadecimal characters"
fi
if [[ ! "$expected_run_id" =~ ^[1-9][0-9]*$ ]]; then
    fail "ledger run ID must be a positive decimal integer"
fi
canonical_run_url="https://github.com/d0m999/Claudio/actions/runs/$expected_run_id"
if [[ "$expected_run_url" != "$canonical_run_url" ]]; then
    fail "ledger run URL does not match the Claudio repository and run ID"
fi
canonical_artifact_name="claudi0-rc-$expected_commit_sha"
if [[ "$expected_artifact_name" != "$canonical_artifact_name" ]]; then
    fail "ledger artifact name does not match the target commit"
fi
canonical_dmg_name="claudi0-$expected_version.dmg"
if [[ "$expected_dmg_name" != "$canonical_dmg_name" ]]; then
    fail "ledger DMG name does not match the RC version"
fi
if [[ ! "$expected_dmg_sha256" =~ ^[0-9a-f]{64}$ ]]; then
    fail "ledger DMG SHA-256 must be exactly 64 lowercase hexadecimal characters"
fi
canonical_workflow_inputs="$(printf \
    '{"version":"%s","target_commit":"%s","release_authorized":true}' \
    "$expected_version" "$expected_commit_sha")"
if [[ "$expected_workflow_inputs" != "$canonical_workflow_inputs" ]]; then
    fail "ledger workflow inputs must be the unique canonical dispatch JSON"
fi
if ! jq -e \
    --arg version "$expected_version" \
    --arg target_commit "$expected_commit_sha" '
        type == "object"
        and keys == ["release_authorized", "target_commit", "version"]
        and .version == $version
        and .target_commit == $target_commit
        and .release_authorized == true
    ' <<< "$expected_workflow_inputs" >/dev/null; then
    fail "ledger workflow inputs do not match the approved RC identity"
fi

gh_bin="${CLAUDIO_GH_BIN:-gh}"
if ! command -v "$gh_bin" >/dev/null 2>&1; then
    fail "GitHub CLI is required to bind the downloaded artifact to live workflow metadata"
fi
if ! run_json="$(
    "$gh_bin" run view "$expected_run_id" \
        --repo d0m999/Claudio \
        --json conclusion,event,headBranch,headSha,url,workflowDatabaseId,workflowName
)"; then
    fail "unable to read the expected GitHub Actions run"
fi
if ! jq -e \
    --arg run_url "$expected_run_url" \
    --arg commit_sha "$expected_commit_sha" \
    --argjson workflow_id "$expected_workflow_id" '
        type == "object"
        and .conclusion == "success"
        and .event == "workflow_dispatch"
        and .headBranch == "main"
        and .headSha == $commit_sha
        and .url == $run_url
        and .workflowDatabaseId == $workflow_id
        and .workflowName == "Release"
    ' <<< "$run_json" >/dev/null; then
    fail "live workflow run does not match the ledger-approved RC identity"
fi
if ! workflow_json="$(
    "$gh_bin" api "repos/d0m999/Claudio/actions/workflows/$expected_workflow_id"
)"; then
    fail "unable to read the expected release workflow metadata"
fi
if ! jq -e \
    --arg workflow_path "$expected_workflow_path" \
    --argjson workflow_id "$expected_workflow_id" '
        type == "object"
        and .id == $workflow_id
        and .name == "Release"
        and .path == $workflow_path
        and .state == "active"
    ' <<< "$workflow_json" >/dev/null; then
    fail "live release workflow does not match the ledger workflow identity"
fi
if ! artifacts_json="$(
    "$gh_bin" api "repos/d0m999/Claudio/actions/runs/$expected_run_id/artifacts"
)"; then
    fail "unable to read artifacts for the expected GitHub Actions run"
fi
if ! artifact_record="$(jq -cer \
    --arg artifact_name "$expected_artifact_name" \
    --arg commit_sha "$expected_commit_sha" \
    --argjson maximum_artifact_bytes "$maximum_artifact_bytes" '
        [.artifacts[] | select(.name == $artifact_name)] as $matches
        | if (($matches | length) == 1
            and ($matches[0].id | type == "number" and . > 0)
            and ($matches[0].digest | type == "string" and test("^sha256:[0-9a-f]{64}$"))
            and ($matches[0].size_in_bytes | type == "number")
            and $matches[0].size_in_bytes > 0
            and $matches[0].size_in_bytes <= $maximum_artifact_bytes
            and $matches[0].expired == false
            and $matches[0].workflow_run.head_sha == $commit_sha)
          then $matches[0]
          else error("artifact identity mismatch")
          end
    ' <<< "$artifacts_json")"; then
    fail "live artifact identity is invalid, expired, over 25 MiB, duplicated, or commit-mismatched"
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
    fail "unable to download the live GitHub Actions artifact archive"
fi
actual_archive_digest="$(shasum -a 256 "$official_archive" | awk '{print $1}')"
actual_archive_byte_count="$(wc -c < "$official_archive" | tr -d ' ')"
if [[ ! "$actual_archive_byte_count" =~ ^[0-9]+$ \
    || "$actual_archive_byte_count" -gt "$maximum_artifact_bytes" ]]; then
    fail "downloaded artifact archive exceeds the 25 MiB verification limit"
fi
if [[ "$actual_archive_digest" != "$expected_archive_digest" ]]; then
    fail "downloaded artifact archive does not match GitHub's SHA-256 digest"
fi
if ! /usr/bin/ditto -x -k "$official_archive" "$official_contents"; then
    fail "unable to extract the digest-verified artifact archive"
fi
if ! diff -qr "$official_contents" "$artifact_dir" >/dev/null; then
    fail "supplied artifact directory differs from the digest-verified GitHub download"
fi

manifest_path="$artifact_dir/RC_MANIFEST.json"
checksum_path="$artifact_dir/SHA256SUMS.txt"
dmg_path="$artifact_dir/$expected_dmg_name"
for required_file in "$manifest_path" "$checksum_path" "$dmg_path"; do
    if [[ ! -f "$required_file" || -L "$required_file" || ! -s "$required_file" ]]; then
        fail "required artifact file is missing, empty, or a symlink: $required_file"
    fi
done
manifest_byte_count="$(wc -c < "$manifest_path" | tr -d ' ')"
if [[ ! "$manifest_byte_count" =~ ^[0-9]+$ \
    || "$manifest_byte_count" -gt "$maximum_metadata_bytes" ]]; then
    fail "RC manifest exceeds the 128 KiB verification limit"
fi
checksum_byte_count="$(wc -c < "$checksum_path" | tr -d ' ')"
if [[ ! "$checksum_byte_count" =~ ^[0-9]+$ \
    || "$checksum_byte_count" -gt "$maximum_checksum_bytes" ]]; then
    fail "SHA256SUMS.txt exceeds the 256-byte verification limit"
fi
dmg_byte_count="$(wc -c < "$dmg_path" | tr -d ' ')"
if [[ ! "$dmg_byte_count" =~ ^[0-9]+$ \
    || "$dmg_byte_count" -gt "$maximum_artifact_bytes" ]]; then
    fail "RC DMG exceeds the 25 MiB verification limit"
fi

shopt -s nullglob dotglob
artifact_entries=("$artifact_dir"/*)
shopt -u nullglob dotglob
if [[ ${#artifact_entries[@]} -ne 3 ]]; then
    fail "artifact directory must contain exactly the DMG, checksum, and RC manifest"
fi
for artifact_entry in "${artifact_entries[@]}"; do
    artifact_basename="$(basename "$artifact_entry")"
    case "$artifact_basename" in
        "$expected_dmg_name"|SHA256SUMS.txt|RC_MANIFEST.json) ;;
        *) fail "unexpected artifact entry: $artifact_entry" ;;
    esac
done

if ! jq -e \
    --arg run_id "$expected_run_id" \
    --arg run_url "$expected_run_url" \
    --arg artifact_name "$expected_artifact_name" \
    --arg commit_sha "$expected_commit_sha" \
    --arg version "$expected_version" \
    --arg workflow_path "$expected_workflow_path" \
    --arg workflow_ref "$expected_workflow_ref" \
    --arg dmg_name "$expected_dmg_name" \
    --arg dmg_sha256 "$expected_dmg_sha256" '
        type == "object"
        and keys == [
            "artifact_name",
            "authorization_attested",
            "commit_sha",
            "dmg_name",
            "dmg_sha256",
            "schema",
            "target_commit",
            "version",
            "workflow_event",
            "workflow_name",
            "workflow_path",
            "workflow_ref",
            "workflow_run_id",
            "workflow_run_url"
        ]
        and .schema == 2
        and .workflow_name == "Release"
        and .workflow_path == $workflow_path
        and .workflow_event == "workflow_dispatch"
        and .workflow_ref == $workflow_ref
        and .workflow_run_id == $run_id
        and .workflow_run_url == $run_url
        and .artifact_name == $artifact_name
        and .target_commit == $commit_sha
        and .commit_sha == $commit_sha
        and .version == $version
        and .dmg_name == $dmg_name
        and .dmg_sha256 == $dmg_sha256
        and .authorization_attested == true
    ' "$manifest_path" >/dev/null; then
    fail "RC manifest does not match the ledger, run, and artifact identity"
fi

checksum_line="$(<"$checksum_path")"
expected_checksum_line="$expected_dmg_sha256  $expected_dmg_name"
expected_checksum_byte_count=$((${#expected_checksum_line} + 1))
if [[ "$checksum_line" != "$expected_checksum_line" \
    || "$checksum_byte_count" != "$expected_checksum_byte_count" ]]; then
    fail "SHA256SUMS.txt does not exactly match the ledger and manifest"
fi
actual_dmg_sha256="$(shasum -a 256 "$dmg_path" | awk '{print $1}')"
if [[ "$actual_dmg_sha256" != "$expected_dmg_sha256" ]]; then
    fail "downloaded DMG SHA-256 does not match the ledger and manifest"
fi

echo "✅ verified RC artifact against ledger:" \
    "run=$expected_run_id artifact=$expected_artifact_name commit=$expected_commit_sha" \
    "dmg=$expected_dmg_name sha256=$actual_dmg_sha256"
