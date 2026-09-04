import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Foundation

// Dependency-free test harness — mirrors `helper/Tests/ClaudioCoreTests/main.swift`
// exactly (down to comment wording), for the same reason: this machine has
// CommandLineTools only (no Xcode), so `swift test` cannot resolve XCTest (absent) or
// Swift Testing (bundled but not exposed to SwiftPM / no macro plugin) here. Green
// signal: `swift run --package-path gui claudio-gui-tests`, exit 0.
//
// `main.swift` is the only file allowed top-level executable statements, so it stays a
// thin orchestrator: shared `expect`/`suite` primitives + calls into per-area suite
// functions defined in sibling files (`OnboardingStateSuite.swift`,
// `OnboardingCopySuite.swift`, `OnboardingDetectorSuite.swift`,
// `OnboardingViewModelSuite.swift`, `AudioFormatSniffSuite.swift`, `AudioImportSuite.swift`,
// `AudioImportBatchSuite.swift`, `AudioImportViewModelSuite.swift`,
// `CoverageStateSuite.swift`, `EventRowAccessibilitySuite.swift`, `ManifestBindingSuite.swift`,
// `PackGallerySuite.swift`, `PackAudioInventorySuite.swift`, `PackForkSuite.swift`,
// `PackRestoreSuite.swift`,
// `EventMuteControllerSuite.swift`, `MasterVolumeControllerSuite.swift`,
// `PanelFocusOrderSuite.swift`, `ContrastSuite.swift`,
// `ContrastHexParsingSuite.swift`,
// `PanelTypeSizeSuite.swift`, `PanelAccessibilitySuite.swift`, `PanelConfigSuite.swift`,
// `PanelFocusCoordinatorSuite.swift`,
// `PreviewFixturesSuite.swift`, `OnboardingActionsSuite.swift`, `ReleaseLayoutSuite.swift`,
// `MultiProviderPrototypeContractSuite.swift`,
// `ReleaseCandidateArtifactSuite.swift`,
// `ChatAXTracerSuite.swift`, `ChatAXTracerWiringSuite.swift`,
// `WorkBuddyKeyboardAccessibilitySuite.swift`, `VolumeDragSessionSuite.swift`,
// `PanelWriteFailuresSuite.swift`, `HitTargetSuite.swift`).

var totalChecks = 0
var failures = 0

@MainActor
func expect(
    _ condition: Bool,
    _ message: @autoclosure () -> String,
    file: StaticString = #file,
    line: UInt = #line
) {
    totalChecks += 1
    if !condition {
        failures += 1
        print("  ✗ \(message())  (\(file):\(line))")
    }
}

@MainActor
func suite(_ name: String, _ body: @MainActor () -> Void) {
    print("• \(name)")
    body()
}

/// Async overload of ``suite(_:_:)`` — for suites whose body must `await` (the
/// `AudioImportViewModel` drop handlers became `async` so their import pipeline runs off
/// the `@MainActor`, a T8 swift-review follow-up). Sync suites keep using the overload
/// above; the presence/absence of `await` at the call site selects the overload.
@MainActor
func suite(_ name: String, _ body: @MainActor () async -> Void) async {
    print("• \(name)")
    await body()
}

runOnboardingStateSuites()
runLocalizationSuites()
runAboutInformationSuites()
runLoginItemManagementSuites()
runOnboardingCopySuites()
runOnboardingDetectorSuites()
await runOnboardingViewModelSuites()
await runOnboardingViewModelDetailSuites()
await runOnboardingFailureLifecycleSuites()
await runSetupNoticeLifecycleSuites()
await runPanelAnnouncementLifecycleSuites()
runOnboardingActionsSuites()
runOnboardingActionsFixSuites()
runSetupNoticeSuites()
runPanelAnnouncementSuites()
runLocalPreRCSuites()
runReleaseLayoutSuites()
runReleaseCandidateArtifactSuites()
runReleaseSignatureSuites()
runSourceScannerSuites()
runViewWiringSuites()
runHitTargetSuites()
runChatAXTracerWiringSuites()
await runChatAXTracerSuites()
runAudioFormatSniffSuites()
runAICueDomainSuites()
runAICueProviderContractsSuites()
await runAICueHTTPTransportSuites()
await runAICueSSETransportSuites()
runAICuePayloadDecodingSuites()
await runAICueCredentialSuites()
await runAICueElevenLabsProviderSuites()
await runAICueMiniMaxProviderSuites()
await runQwenAICueProviderSuites()
await runAICueGenerationEngineSuites()
await runAICueGenerationDispatcherSuites()
await runAICueAdoptionSuites()
await runAICueGenerationViewModelSuites()
runAudioImportSuites()
runAudioImportBatchSuites()
await runAudioImportViewModelSuites()
runCoverageStateSuites()
runEventRowAccessibilitySuites()
await runManifestBindingSuites()
runPackGallerySuites()
runPackAudioInventorySuites()
runPackForkSuites()
runPackRestoreSuites()
runUserSoundPackDeletionSuites()
runSoundPacksEditorOwnerSuites()
await runSoundPacksEditorInterfaceSuites()
await runSoundPacksEditorMutationSuites()
await runSoundPacksEditorMutationImpactGapRedSuites()
await runSoundPacksEditorNativeTargetSuites()
await runSoundPacksEditorAsyncOperationSuites()
await runSoundPacksEditorGapRedSuites()
await runSoundPacksEditorAnnouncementGapRedSuites()
await runSoundPacksEditorNativeEffectsSuites()
await runSoundPacksEditorViewSuites()
runEventMuteControllerSuites()
runMasterVolumeControllerSuites()
runPanelFocusOrderSuites()
await runPanelPresentationSuites()
runEventSettingsDestinationCoordinatorSuites()
runPanelFocusInFlightSuites()
runContrastSuites()
runContrastHexParsingSuites()
runPanelTypeSizeSuites()
runProductUIModelsSuites()
runPanelAccessibilitySuites()
runHostIntegrationPresentationSuites()
runIntegrationDestinationPresentationSuites()
await runIntegrationDestinationModelSuites()
runWorkBuddyVisualStateBaselineSuites()
runWorkBuddyKeyboardAccessibilitySuites()
await runHostIntegrationManagerBridgeSuites()
runIntegrationDestinationWiringSuites()
runRetainedWindowHandbackTrackerSuites()
runPanelConfigSuites()
runPanelRefreshRouteSuites()
await runSoundPacksRefreshSuites()
await runSoundPackLibrarySuites()
await runSoundPackLibraryMutationTransactionSuites()
runSoundPacksWindowAccessibilitySuites()
await runSoundPacksEditorAccessibilityPostingSuites()
runSoundPacksWindowStarredPacksSuites()
runPanelConfigControllerSuites()
runPanelFocusCoordinatorSuites()
await runSettingsPreferencesSuites()
runDynamicQuietPolicySuites()
runDisplayPreferencesSuites()
await runUsageActivitySuites()
runGlobalShortcutsSuites()
runSettingsNavigationSuites()
runSettingsPresentationCharacterizationSuites()
runSettingsPresentationLifecycleSuites()
runSettingsPresentationTargetSuites()
runSettingsPresentationSliceSuites()
runPreviewFixturesSuites()
runMultiProviderPrototypeContractSuites()
runVolumeDragSessionSuites()
runPanelWriteFailuresSuites()

// MARK: - Summary

print("")
if failures == 0 {
    print("✓ all \(totalChecks) checks passed")
    exit(0)
} else {
    print("✗ \(failures) of \(totalChecks) checks FAILED")
    exit(1)
}
