#!/usr/bin/env bash
# Commit-bound local pre-RC verification. This produces only current-machine development evidence.
set -euo pipefail

usage() {
    echo "usage: $0" >&2
}

if [[ $# -ne 0 ]]; then
    usage
    exit 2
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"
source "$script_dir/pinned-output-directory.sh"
cd "$repo_root"

readonly contract_path="scripts/local-pre-rc-contract.json"
readonly report_path="dist/local-pre-rc-report.json"
readonly app_path="dist/claudi0.app"
readonly output_directory="dist"
readonly report_name="local-pre-rc-report.json"
readonly app_name="claudi0.app"

fail() {
    echo "❌ $*" >&2
    exit 1
}

remove_stale_report() {
    if [[ -d "$report_name" && ! -L "$report_name" ]]; then
        fail "local pre-RC report path must not be a directory: $report_path"
    fi
    /bin/rm -f -- "$report_name"
}

# The expectation is private child-script state. A new public pre-RC run must establish its own
# identity before exporting it to nested scripts.
unset CLAUDIO_PINNED_OUTPUT_DIRECTORY_IDENTITY
output_directory_identity="$(
    claudio_with_pinned_output_directory \
        "$repo_root" "$output_directory" claudio_output_directory_identity "."
)" || fail "cannot pin the local pre-RC output directory"
if [[ ! "$output_directory_identity" =~ ^[0-9]+:[0-9]+$ ]]; then
    fail "local pre-RC output directory identity is invalid"
fi
readonly output_directory_identity
export CLAUDIO_PINNED_OUTPUT_DIRECTORY_IDENTITY="$output_directory_identity"

# Even an early tool, contract, or HEAD failure must not leave an older success looking current.
claudio_with_pinned_output_directory \
    "$repo_root" "$output_directory" remove_stale_report

for required_tool in git sw_vers uname swift jq bash lipo codesign plutil; do
    command -v "$required_tool" >/dev/null 2>&1 \
        || fail "required tool is unavailable: $required_tool"
done

# These supported overrides are useful for negative gate tests and versioned packaging, but they
# must never weaken or change the canonical local pre-RC baseline inherited from the scripts.
unset CLAUDIO_GUI_BYTES_PER_ARCH \
    CLAUDIO_HELPER_BYTES_PER_ARCH \
    CLAUDIO_LOGIN_ITEM_BYTES_PER_ARCH \
    CLAUDIO_NON_EXECUTABLE_BUNDLE_BYTES \
    CLAUDIO_LIPO_BIN \
    CLAUDIO_VERSION

if [[ ! -f "$contract_path" || -L "$contract_path" ]]; then
    fail "local pre-RC contract must be a regular non-symlink file: $contract_path"
fi
jq -e '
  .schema == 1
  and .evidence_class == "local_pre_rc"
  and .qualification == "pre_rc_only"
  and .formal_release_candidate == false
  and .formal_evidence == {
    "universal": "not_satisfied",
    "developer_id": "not_satisfied",
    "notarization": "not_evaluated",
    "stapling": "not_evaluated",
    "gatekeeper": "not_evaluated",
    "dmg_checksum": "not_evaluated",
    "intel_hardware": "not_evaluated"
  }
' "$contract_path" >/dev/null || fail "local pre-RC evidence boundary is invalid"

expected_commit="$(git rev-parse --verify HEAD^{commit} 2>/dev/null)" \
    || fail "cannot resolve the current git HEAD"
if [[ ! "$expected_commit" =~ ^[0-9a-f]{40}$ ]]; then
    fail "current git HEAD is not a canonical 40-character commit SHA"
fi

assert_checkout_identity() {
    local expected="$1"
    local current status
    current="$(git rev-parse --verify HEAD^{commit} 2>/dev/null)" \
        || fail "cannot re-resolve git HEAD"
    if [[ "$current" != "$expected" ]]; then
        fail "git HEAD changed during local pre-RC verification: expected=$expected actual=$current"
    fi
    status="$(git status --porcelain --untracked-files=all)"
    if [[ -n "$status" ]]; then
        fail "local pre-RC verification requires a clean checkout bound to $expected"
    fi
}

run_bound_step() {
    local label="$1"
    shift
    assert_checkout_identity "$expected_commit"
    echo "▶ $label"
    "$@"
    assert_checkout_identity "$expected_commit"
}

macos_version="$(sw_vers -productVersion)"
cpu_architecture="$(uname -m)"
if [[ -z "$macos_version" || -z "$cpu_architecture" ]]; then
    fail "cannot resolve the current macOS and CPU identity"
fi

assert_checkout_identity "$expected_commit"
run_bound_step "patch whitespace" git diff --check
run_bound_step "helper harness" swift run --package-path helper claudio-tests
run_bound_step "GUI harness" swift run --package-path gui claudio-gui-tests
run_bound_step "ClaudioGUI Debug build" \
    swift build -c debug --package-path gui --product ClaudioGUI
run_bound_step "localization catalog" \
    jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings
run_bound_step "current-architecture ad-hoc dev bundle" bash scripts/dev-bundle.sh
run_bound_step "release-size gate" claudio_with_pinned_output_directory \
    "$repo_root" "$output_directory" bash "$repo_root/scripts/check-release-size.sh" "$app_name"

readonly gui_binary="$app_name/Contents/MacOS/claudi0-app"
readonly helper_binary="$app_name/Contents/Resources/bin/claudi0"
gui_architectures="$(claudio_with_pinned_output_directory \
    "$repo_root" "$output_directory" lipo -archs "$gui_binary")"
helper_architectures="$(claudio_with_pinned_output_directory \
    "$repo_root" "$output_directory" lipo -archs "$helper_binary")"
if [[ "$gui_architectures" != "$cpu_architecture" \
    || "$helper_architectures" != "$cpu_architecture" ]]; then
    fail "dev bundle must contain only the current architecture: machine=$cpu_architecture "\
"gui=[$gui_architectures] helper=[$helper_architectures]"
fi

signature_details="$(claudio_with_pinned_output_directory \
    "$repo_root" "$output_directory" codesign -dv --verbose=4 "$app_name" 2>&1)"
if ! grep -q '^Signature=adhoc$' <<<"$signature_details"; then
    fail "dev bundle must carry an ad-hoc signature"
fi
if ! grep -q '^TeamIdentifier=not set$' <<<"$signature_details"; then
    fail "dev bundle must not carry a Developer ID team identity"
fi
assert_checkout_identity "$expected_commit"

publish_report() {
    local temporary_report
    local report_is_current=false

    temporary_report="$(mktemp ".local-pre-rc-report.XXXXXX")"
    cleanup_temporary_report() {
        local exit_status=$?
        /bin/rm -f -- "$temporary_report"
        if [[ "$report_is_current" != true ]]; then
            /bin/rm -f -- "$report_name"
        fi
        return "$exit_status"
    }
    trap cleanup_temporary_report EXIT

    jq \
        --arg commit_sha "$expected_commit" \
        --arg macos_version "$macos_version" \
        --arg cpu_architecture "$cpu_architecture" \
        --arg app_path "$app_path" \
        --arg gui_architecture "$gui_architectures" \
        --arg helper_architecture "$helper_architectures" \
        '. + {
          commit_sha: $commit_sha,
          checkout: {
            clean: true,
            head_verified_before_and_after_each_step: true
          },
          machine: {
            macos_version: $macos_version,
            cpu_architecture: $cpu_architecture
          },
          bundle: {
            path: $app_path,
            gui_architectures: [$gui_architecture],
            helper_architectures: [$helper_architecture],
            signature: "ad_hoc"
          },
          checks: [
            {id: "patch_whitespace", status: "passed"},
            {id: "helper_harness", status: "passed"},
            {id: "gui_harness", status: "passed"},
            {id: "gui_debug_build", status: "passed"},
            {id: "localization_catalog", status: "passed"},
            {id: "dev_bundle", status: "passed"},
            {id: "release_size", status: "passed"}
          ]
        }' "$repo_root/$contract_path" > "$temporary_report"
    jq empty "$temporary_report"
    assert_checkout_identity "$expected_commit"
    mv -f -- "$temporary_report" "$report_name"
    assert_checkout_identity "$expected_commit"
    claudio_assert_pinned_output_binding \
        "$repo_root/$output_directory" "$(claudio_output_directory_identity ".")"
    report_is_current=true
    trap - EXIT
}

claudio_with_pinned_output_directory \
    "$repo_root" "$output_directory" publish_report

echo "✅ local pre-RC verification passed for $expected_commit"
echo "   report: $report_path"
echo "   qualification: pre_rc_only (not a signed universal RC or formal acceptance)"
