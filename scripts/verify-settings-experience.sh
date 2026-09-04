#!/usr/bin/env bash
# Unified-settings integration gate. The caller supplies the implementation baseline so existing
# swift-format diagnostics remain evidence rather than being mistaken for regressions.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"
format_base="${1:-}"
source "$script_dir/settings-format-diagnostics.sh"

if [[ -z "$format_base" || $# -ne 1 ]]; then
    echo "usage: $0 <format-baseline-commit>" >&2
    exit 2
fi

cd "$repo_root"
format_base="$(git rev-parse --verify "$format_base^{commit}")"
if ! git merge-base --is-ancestor "$format_base" HEAD; then
    echo "❌ format baseline is not an ancestor of HEAD: $format_base" >&2
    exit 1
fi
if [[ -n "$(git status --porcelain=v1 --untracked-files=all)" ]]; then
    echo "❌ unified settings evidence must be collected from a clean HEAD" >&2
    git status --short >&2
    exit 1
fi

bash scripts/test-settings-format-diagnostics.sh

require_registration() {
    local harness="$1"
    local suite="$2"
    if ! rg -q "^[[:space:]]*(await[[:space:]]+)?${suite}\\(\\)[[:space:]]*$" "$harness"; then
        echo "❌ required suite is not registered in $harness: $suite" >&2
        exit 1
    fi
}

helper_main="helper/Tests/ClaudioCoreTests/main.swift"
gui_main="gui/Tests/ClaudioGUICoreTests/main.swift"

# These registrations bind the broad harness totals to #102's named regression contracts. The
# suites themselves own behavioral assertions; this source check only guards the harness's manual
# registration seam, where an existing suite could otherwise stop running without a compile error.
for suite in \
    runSurfaceSoundPreferencesSuites \
    runDynamicQuietStateSuites \
    runHostHookReceiptSuites \
    runHostHookRunnerSuites \
    runHostIntegrationModelSuites
do
    require_registration "$helper_main" "$suite"
done

for suite in \
    runLocalizationSuites \
    runAboutInformationSuites \
    runLoginItemManagementSuites \
    runAICueDomainSuites \
    runAICueProviderContractsSuites \
    runAICueHTTPTransportSuites \
    runAICueSSETransportSuites \
    runAICuePayloadDecodingSuites \
    runAICueCredentialSuites \
    runAICueElevenLabsProviderSuites \
    runAICueMiniMaxProviderSuites \
    runQwenAICueProviderSuites \
    runAICueGenerationEngineSuites \
    runAICueGenerationDispatcherSuites \
    runAICueAdoptionSuites \
    runAICueGenerationViewModelSuites \
    runHostIntegrationPresentationSuites \
    runHostIntegrationManagerBridgeSuites \
    runIntegrationDestinationPresentationSuites \
    runIntegrationDestinationModelSuites \
    runIntegrationDestinationWiringSuites \
    runSoundPacksEditorOwnerSuites \
    runSettingsPreferencesSuites \
    runDynamicQuietPolicySuites \
    runDisplayPreferencesSuites \
    runUsageActivitySuites \
    runGlobalShortcutsSuites \
    runSettingsNavigationSuites \
    runEventSettingsWindowSelectionSuites \
    runSettingsPresentationLifecycleSuites \
    runSettingsPresentationTargetSuites \
    runSettingsPresentationSliceSuites \
    runPreviewFixturesSuites \
    runMultiProviderPrototypeContractSuites
do
    require_registration "$gui_main" "$suite"
done
echo "✅ required integration suites are registered"

swift run --package-path helper claudio-tests
swift run --package-path gui claudio-gui-tests
swift build -c debug --package-path gui --target ClaudioSettingsPresentation
swift build -c release --package-path gui --target ClaudioSettingsPresentation
swift build -c debug --package-path gui --product ClaudioGUI
swift build -c release --package-path gui --product ClaudioGUI
jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings
bash scripts/dev-bundle.sh
bash scripts/check-release-size.sh dist/claudi0.app
git diff --check
git diff --check "$format_base...HEAD"

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/claudio-settings-gate.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT
baseline_root="$temporary_root/baseline"
mkdir -p "$baseline_root"
git archive "$format_base" .swift-format helper gui | tar -x -C "$baseline_root"

collect_format_diagnostics() {
    local source_root="$1"
    local raw_output="$2"
    local normalized_output="$3"
    local status=0

    (
        cd "$source_root"
        swift format lint --strict --recursive helper gui
    ) >"$raw_output" 2>&1 || status=$?

    if [[ $status -ne 0 && $status -ne 1 ]]; then
        cat "$raw_output" >&2
        echo "❌ swift format lint failed with status $status" >&2
        exit "$status"
    fi

    settings_format_normalize_diagnostics "$raw_output" "$normalized_output"
    settings_format_validate_diagnostics "$status" "$raw_output" "$normalized_output"
}

baseline_raw="$temporary_root/baseline-format.txt"
baseline_diagnostics="$temporary_root/baseline-format-diagnostics.txt"
head_raw="$temporary_root/head-format.txt"
head_diagnostics="$temporary_root/head-format-diagnostics.txt"
new_diagnostics="$temporary_root/new-format-diagnostics.txt"

collect_format_diagnostics "$baseline_root" "$baseline_raw" "$baseline_diagnostics"
collect_format_diagnostics "$repo_root" "$head_raw" "$head_diagnostics"
settings_format_compare_diagnostics \
    "$baseline_diagnostics" \
    "$head_diagnostics" \
    "$new_diagnostics"

if [[ -s "$new_diagnostics" ]]; then
    new_diagnostic_count="$(wc -l <"$new_diagnostics" | tr -d ' ')"
    echo "❌ $new_diagnostic_count strict format diagnostic occurrences added since $format_base:" >&2
    LC_ALL=C uniq -c "$new_diagnostics" >&2
    exit 1
fi

baseline_count="$(wc -l <"$baseline_diagnostics" | tr -d ' ')"
head_count="$(wc -l <"$head_diagnostics" | tr -d ' ')"
echo "✅ strict format baseline: no new diagnostics (baseline=$baseline_count, HEAD=$head_count)"
echo "✅ unified settings integration gate passed at $(git rev-parse HEAD)"
