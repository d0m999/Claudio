import Foundation

/// The two resolved product languages. `ClaudioLanguageMode.system` projects the current system
/// preference onto one of these values before catalog lookup; this enum never carries persistence
/// intent by itself.
public enum ClaudioAppLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case zhHans = "zh-Hans"
    case english = "en"

    public static let defaultsKey = "Claudio.InterfaceLanguage"
    /// Fail-closed source-language fallback for incomplete catalog entries.
    public static let defaultValue: ClaudioAppLanguage = .zhHans

    public var id: String { rawValue }

    /// The self-name shown inside the language selector. These labels stay stable so a user can
    /// always identify the other language, even before reading the rest of the UI.
    public var selfName: String {
        switch self {
        case .zhHans: "中文"
        case .english: "English"
        }
    }

}

/// The persisted language preference. The two explicit raw values intentionally match the
/// pre-system-mode values so existing choices migrate without rewriting or losing intent.
public enum ClaudioLanguageMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case english = "en"

    public static let defaultValue: ClaudioLanguageMode = .system

    public var id: String { rawValue }

    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? Self.defaultValue
    }

    public func resolvedLanguage(
        preferredLanguageIdentifiers: [String]
    ) -> ClaudioAppLanguage {
        switch self {
        case .zhHans:
            return .zhHans
        case .english:
            return .english
        case .system:
            for identifier in preferredLanguageIdentifiers {
                let languageCode =
                    identifier
                    .replacingOccurrences(of: "_", with: "-")
                    .split(separator: "-", maxSplits: 1)
                    .first?
                    .lowercased()
                switch languageCode {
                case "zh": return .zhHans
                case "en": return .english
                default: continue
                }
            }
            return .english
        }
    }

    public func localizedName(language: ClaudioAppLanguage) -> String {
        let l10n = ClaudioL10n(language: language)
        return switch self {
        case .system: l10n.text(.settingsGeneralLanguageSystem)
        case .zhHans: l10n.text(.settingsGeneralLanguageChinese)
        case .english: l10n.text(.settingsGeneralLanguageEnglish)
        }
    }
}

/// Resolves the package resource in both SwiftPM/test execution and the assembled application.
/// The real app intentionally does not depend on a fixed app name: renamed apps still resolve
/// exactly one `*_ClaudioLocalization.bundle` from `Contents/Resources`.
public enum ClaudioLocalizationBundleLocator {
    public static let resourceBundleSuffix = "_ClaudioLocalization.bundle"

    public static func bundle(
        mainBundle: Bundle = .main,
        moduleBundle: Bundle? = nil
    ) -> Bundle {
        let moduleBundle = moduleBundle ?? Bundle.module
        guard mainBundle.bundleURL.pathExtension == "app" else {
            return moduleBundle
        }

        guard let resourcesURL = mainBundle.resourceURL else {
            preconditionFailure("Claudio app is missing Contents/Resources")
        }

        let candidates =
            (try? FileManager.default.contentsOfDirectory(
                at: resourcesURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.lastPathComponent.hasSuffix(resourceBundleSuffix) }) ?? []

        guard candidates.count == 1 else {
            preconditionFailure(
                "Expected exactly one \(resourceBundleSuffix) in Contents/Resources, found \(candidates.count)"
            )
        }
        guard let bundle = Bundle(url: candidates[0]) else {
            preconditionFailure("Cannot load Claudio localization bundle at \(candidates[0].path)")
        }
        return bundle
    }
}

/// Stable catalog keys. The raw values are also used by the catalog alignment tests, so adding a
/// visible phrase requires adding both language entries in `Localizable.xcstrings`.
public struct ClaudioL10nKey: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public static let interfaceTitle: Self = "interface.title"
    public static let interfaceLanguage: Self = "interface.language"
    public static let interfaceChinese: Self = "interface.language.chinese"
    public static let interfaceEnglish: Self = "interface.language.english"
    public static let interfaceTextSize: Self = "interface.text-size"
    public static let interfaceTextSizeDecrease: Self = "interface.text-size.decrease"
    public static let interfaceTextSizeIncrease: Self = "interface.text-size.increase"
    public static let interfaceTextSizeCurrent: Self = "interface.text-size.current"
    public static let interfaceTextSizeLevel: Self = "interface.text-size.level"
    public static let interfaceTextSizeMinimum: Self = "interface.text-size.minimum"
    public static let interfaceTextSizeMaximum: Self = "interface.text-size.maximum"
    public static let interfaceTextSizeCompact: Self = "interface.text-size.compact"
    public static let interfaceTextSizeStandard: Self = "interface.text-size.standard"
    public static let interfaceTextSizeLarge: Self = "interface.text-size.large"
    public static let panelOptionsHint: Self = "panel.options.hint"
    public static let panelTitle: Self = "panel.title"
    public static let panelBaseLabel: Self = "panel.base-label"
    public static let panelHeader: Self = "panel.header"
    public static let panelHeaderWithPack: Self = "panel.header.with-pack"
    public static let panelSources: Self = "panel.sources"
    public static let panelSelectedPackNone: Self = "panel.selected-pack.none"
    public static let panelAudibleEventsLoading: Self = "panel.audible-events.loading"
    public static let panelAudibleEventsUnavailable: Self = "panel.audible-events.unavailable"
    public static let panelAudibleEventsCount: Self = "panel.audible-events.count"
    public static let panelEvents: Self = "panel.events"
    public static let panelSoundPacks: Self = "panel.sound-packs"
    public static let panelManageSoundPacks: Self = "panel.manage-sound-packs"
    public static let panelManageSoundPacksHint: Self = "panel.manage-sound-packs.hint"
    public static let panelQuitApplication: Self = "panel.quit-application"
    public static let panelQuitApplicationHint: Self = "panel.quit-application.hint"
    public static let panelRetry: Self = "panel.retry"
    public static let panelRetryHint: Self = "panel.retry.hint"
    public static let panelLoadingEvents: Self = "panel.loading-events"
    public static let panelUnavailableEvents: Self = "panel.unavailable-events"
    public static let panelPacksLoading: Self = "panel.packs.loading"
    public static let panelPacksNoPinnedTitle: Self = "panel.packs.no-pinned.title"
    public static let panelPacksNoPinnedMessage: Self = "panel.packs.no-pinned.message"
    public static let panelPacksNoneTitle: Self = "panel.packs.none.title"
    public static let panelPacksNoneMessage: Self = "panel.packs.none.message"
    public static let panelPacksReadFailed: Self = "panel.packs.read-failed"
    public static let panelSelectPack: Self = "panel.select-pack.title"
    public static let panelSelectPackMessage: Self = "panel.select-pack.message"
    public static let panelSelectPackWithChoicesMessage: Self =
        "panel.select-pack.message.with-choices"
    public static let panelSelectPackWithoutChoicesMessage: Self =
        "panel.select-pack.message.without-choices"
    public static let panelRevealConfig: Self = "panel.reveal-config"
    public static let panelRevealConfigHint: Self = "panel.reveal-config.hint"
    public static let panelMasterVolume: Self = "panel.master-volume"
    public static let panelMasterVolumeDescription: Self = "panel.master-volume.description"
    public static let panelSoundScope: Self = "panel.sound-scope"
    public static let panelSoundScopeInheritanceCaption: Self =
        "panel.sound-scope.inheritance-caption"
    public static let panelSoundScopeExpandHint: Self = "panel.sound-scope.expand-hint"
    public static let panelSoundScopeCollapseHint: Self = "panel.sound-scope.collapse-hint"
    public static let panelSoundScopeGlobalCoverage: Self = "panel.sound-scope.global-coverage"
    public static let panelSoundScopeStatusDefault: Self = "panel.sound-scope.status.default"
    public static let panelSoundScopeStatusActive: Self = "panel.sound-scope.status.active"
    public static let panelSoundScopeStatusAwaitingReceipt: Self =
        "panel.sound-scope.status.awaiting-receipt"
    public static let panelSoundScopeStatusLegacy: Self = "panel.sound-scope.status.legacy"
    public static let panelSoundScopeStatusNotConnected: Self =
        "panel.sound-scope.status.not-connected"
    public static let panelSoundScopeStatusNeedsAttention: Self =
        "panel.sound-scope.status.needs-attention"
    public static let panelEventsTitle: Self = "panel.events.title"
    public static let panelEventsMappable: Self = "panel.events.mappable"
    public static let panelGlobalDefaults: Self = "panel.global-defaults"
    public static let panelGlobalName: Self = "panel.global.name"
    public static let panelGlobalStatus: Self = "panel.global.status"
    public static let panelHeaderSummary: Self = "panel.header.summary"
    public static let panelConnectionsDiagnostics: Self = "panel.connections-diagnostics"
    public static let panelCustomSoundOverrides: Self = "panel.custom-sound-overrides"
    public static let panelNeedsPackSettingsMessage: Self = "panel.needs-pack.settings-message"
    public static let panelPlaybackSettings: Self = "panel.playback-settings"
    public static let panelSoundPackLabel: Self = "panel.sound-pack.label"
    public static let panelOpenSettings: Self = "panel.open-settings"
    public static let panelGlobalInheritance: Self = "panel.global-inheritance"
    public static let panelSurfaceOverride: Self = "panel.surface-override"
    public static let panelSurfaceOverrideDamaged: Self = "panel.surface-override-damaged"
    public static let panelInheritedGlobal: Self = "panel.inherited-global"
    public static let panelNoSoundAssigned: Self = "panel.no-sound-assigned"
    public static let panelMissingSound: Self = "panel.missing-sound"
    public static let panelNoNativeEvent: Self = "panel.no-native-event"
    public static let panelCapabilitySupported: Self = "panel.capability.supported"
    public static let panelCapabilityPartial: Self = "panel.capability.partial"
    public static let panelCapabilityUnsupported: Self = "panel.capability.unsupported"
    public static let panelCapabilitySupportedNotImplemented: Self =
        "panel.capability.supported-not-implemented"
    public static let panelCapabilityPartialNotImplemented: Self =
        "panel.capability.partial-not-implemented"
    public static let panelCapabilityUnsupportedNotImplemented: Self =
        "panel.capability.unsupported-not-implemented"
    public static let panelResetSurface: Self = "panel.reset-surface"
    public static let panelResetSurfaceHint: Self = "panel.reset-surface.hint"
    public static let hostDetailsHint: Self = "host.details.hint"
    public static let hostReady: Self = "host.ready"
    public static let hostConfigured: Self = "host.configured"
    public static let hostLegacy: Self = "host.legacy"
    public static let hostNotConnected: Self = "host.not-connected"
    public static let hostNeedsAttention: Self = "host.needs-attention"
    public static let hostCodexReadyDetail: Self = "host.codex.ready-detail"
    public static let hostCodexAwaitingDetail: Self = "host.codex.awaiting-detail"
    public static let hostClaudeAwaitingDetail: Self = "host.claude.awaiting-detail"
    public static let hostClaudeLegacyDetail: Self = "host.claude.legacy-detail"
    public static let hostCodexLegacyDetail: Self = "host.codex.legacy-detail"
    public static let hostWorkBuddyReadyDetail: Self = "host.workbuddy.ready-detail"
    public static let hostWorkBuddyAwaitingDetail: Self = "host.workbuddy.awaiting-detail"
    public static let hostWorkBuddyConflictDetail: Self = "host.workbuddy.conflict-detail"
    public static let qualificationAccessibilityBetaUnavailable: Self =
        "qualification.accessibility-beta-unavailable"
    public static let eventTaskStart: Self = "event.task-start"
    public static let eventStop: Self = "event.stop"
    public static let eventStopFailure: Self = "event.stop-failure"
    public static let eventNotification: Self = "event.notification"
    public static let eventSubagentStop: Self = "event.subagent-stop"
    public static let eventEditorHint: Self = "event.editor.hint"
    public static let eventCoveragePresent: Self = "event.coverage.present"
    public static let eventCoverageUnmapped: Self = "event.coverage.unmapped"
    public static let eventCoverageBroken: Self = "event.coverage.broken"
    public static let eventCoveragePresentFile: Self = "event.coverage.present-file"
    public static let eventCoverageBrokenFile: Self = "event.coverage.broken-file"
    public static let eventPreviewLabel: Self = "event.preview.label"
    public static let eventPreviewAvailableEnabled: Self = "event.preview.available-enabled"
    public static let eventPreviewAvailableMuted: Self = "event.preview.available-muted"
    public static let eventPreviewUnavailable: Self = "event.preview.unavailable"
    public static let eventMuteHint: Self = "event.mute.hint"
    public static let eventMute: Self = "event.mute"
    public static let eventUnmute: Self = "event.unmute"
    public static let eventEnabled: Self = "event.enabled"
    public static let eventMuted: Self = "event.muted"
    public static let eventPreviewHint: Self = "event.preview.hint"
    public static let eventPreviewMasterVolumeZero: Self = "event.preview.master-volume-zero"
    public static let eventPreviewUnmapped: Self = "event.preview.unmapped"
    public static let eventPreviewMissing: Self = "event.preview.missing"
    public static let eventPreviewUnsafe: Self = "event.preview.unsafe"
    public static let cellAudible: Self = "cell.audible"
    public static let cellMuted: Self = "cell.muted"
    public static let cellMasterVolumeZero: Self = "cell.master-volume-zero"
    public static let cellMissingSound: Self = "cell.missing-sound"
    public static let cellNotConnected: Self = "cell.not-connected"
    public static let cellAwaitingActivation: Self = "cell.awaiting-activation"
    public static let cellLegacy: Self = "cell.legacy"
    public static let cellUnsupported: Self = "cell.unsupported"
    public static let cellDegraded: Self = "cell.degraded"
    public static let hostPlaybackPlayed: Self = "host.playback.played"
    public static let hostPlaybackMuted: Self = "host.playback.muted"
    public static let hostPlaybackDebounced: Self = "host.playback.debounced"
    public static let hostPlaybackNotReady: Self = "host.playback.not-ready"
    public static let hostPlaybackUnsupported: Self = "host.playback.unsupported"
    public static let hostPlaybackFailed: Self = "host.playback.failed"
    public static let actionCopyHooks: Self = "action.copy-hooks"
    public static let actionCopyHooksHint: Self = "action.copy-hooks.hint"
    public static let actionRedetect: Self = "action.redetect"
    public static let actionRedetectHint: Self = "action.redetect.hint"
    public static let actionConnect: Self = "action.connect"
    public static let actionConnectHint: Self = "action.connect.hint"
    public static let actionUpgrade: Self = "action.upgrade"
    public static let actionUpgradeHint: Self = "action.upgrade.hint"
    public static let actionRepair: Self = "action.repair"
    public static let actionRepairHint: Self = "action.repair.hint"
    public static let actionDisconnect: Self = "action.disconnect"
    public static let actionDisconnectHint: Self = "action.disconnect.hint"
    public static let actionClearReceiptHistory: Self = "action.clear-receipt-history"
    public static let actionClearReceiptHistoryHint: Self = "action.clear-receipt-history.hint"
    public static let actionUnmute: Self = "action.unmute"
    public static let actionUnmuteHint: Self = "action.unmute.hint"
    public static let actionConfigureSound: Self = "action.configure-sound"
    public static let actionConfigureSoundHint: Self = "action.configure-sound.hint"
    public static let aiCueGenerateAction: Self = "ai-cue.action.generate"
    public static let aiCueGenerateHint: Self = "ai-cue.action.generate.hint"
    public static let aiCueProviderProfileElevenLabsGlobal: Self =
        "ai-cue.provider-profile.elevenlabs-global"
    public static let aiCueProviderProfileMiniMaxGlobal: Self =
        "ai-cue.provider-profile.minimax-global"
    public static let aiCueProviderProfileQwenSingapore: Self =
        "ai-cue.provider-profile.qwen-singapore"
    public static let aiCueProviderProfileQwenBeijing: Self =
        "ai-cue.provider-profile.qwen-beijing"
    public static let aiCueServiceTitle: Self = "ai-cue.service.title"
    public static let aiCueServiceSubtitle: Self = "ai-cue.service.subtitle"
    public static let aiCueServiceChecking: Self = "ai-cue.service.checking"
    public static let aiCueServiceMissing: Self = "ai-cue.service.missing"
    public static let aiCueServiceConfigured: Self = "ai-cue.service.configured"
    public static let aiCueServiceStoredVerified: Self = "ai-cue.service.stored-verified"
    public static let aiCueServiceStoredDeferred: Self = "ai-cue.service.stored-deferred"
    public static let aiCueServiceStoredRejected: Self = "ai-cue.service.stored-rejected"
    public static let aiCueServicePendingReplacement: Self =
        "ai-cue.service.pending-replacement"
    public static let aiCueServiceUnavailable: Self = "ai-cue.service.unavailable"
    public static let aiCueProviderLabel: Self = "ai-cue.provider.label"
    public static let aiCueProviderCapabilities: Self = "ai-cue.provider.capabilities"
    public static let aiCueModalitySpeech: Self = "ai-cue.modality.speech"
    public static let aiCueModalityAnimal: Self = "ai-cue.modality.animal"
    public static let aiCueModalitySoundEffect: Self = "ai-cue.modality.sound-effect"
    public static let aiCueModalityMixed: Self = "ai-cue.modality.mixed"
    public static let aiCueCredentialProbing: Self = "ai-cue.credential.probing"
    public static let aiCueCredentialSaving: Self = "ai-cue.credential.saving"
    public static let aiCueCredentialUpdatingReplacement: Self =
        "ai-cue.credential.updating-replacement"
    public static let aiCueCredentialDeleting: Self = "ai-cue.credential.deleting"
    public static let aiCueConfigureKey: Self = "ai-cue.credential.configure"
    public static let aiCueManageKey: Self = "ai-cue.credential.manage"
    public static let aiCueCredentialTitle: Self = "ai-cue.credential.title"
    public static let aiCueCredentialKeyLabel: Self = "ai-cue.credential.key-label"
    public static let aiCueCredentialPrivacy: Self = "ai-cue.credential.privacy"
    public static let aiCueCredentialPrivacyMiniMax: Self =
        "ai-cue.credential.privacy.minimax"
    public static let aiCueCredentialPrivacyQwenSingapore: Self =
        "ai-cue.credential.privacy.qwen-singapore"
    public static let aiCueCredentialPrivacyQwenBeijing: Self =
        "ai-cue.credential.privacy.qwen-beijing"
    public static let aiCueCredentialKeychain: Self = "ai-cue.credential.keychain"
    public static let aiCueCredentialValidateSave: Self = "ai-cue.credential.validate-save"
    public static let aiCueCredentialSave: Self = "ai-cue.credential.save"
    public static let aiCueCredentialCancelReplacement: Self =
        "ai-cue.credential.cancel-replacement"
    public static let aiCueCredentialDelete: Self = "ai-cue.credential.delete"
    public static let aiCueCredentialDeleteTitle: Self = "ai-cue.credential.delete-title"
    public static let aiCueCredentialDeleteMessage: Self = "ai-cue.credential.delete-message"
    public static let aiCueEligibilityGlobal: Self = "ai-cue.eligibility.global"
    public static let aiCueEligibilityBuiltin: Self = "ai-cue.eligibility.builtin"
    public static let aiCueEligibilityShared: Self = "ai-cue.eligibility.shared"
    public static let aiCueEligibilityUnavailable: Self = "ai-cue.eligibility.unavailable"
    public static let aiCueComposerTitle: Self = "ai-cue.composer.title"
    public static let aiCueStageDescription: Self = "ai-cue.stage.description"
    public static let aiCueStageCandidates: Self = "ai-cue.stage.candidates"
    public static let aiCueDescriptionLabel: Self = "ai-cue.description.label"
    public static let aiCueDescriptionHelp: Self = "ai-cue.description.help"
    public static let aiCueDescriptionPlaceholder: Self = "ai-cue.description.placeholder"
    public static let aiCueGenerateCandidates: Self = "ai-cue.generate-candidates"
    public static let aiCueGenerating: Self = "ai-cue.generating"
    public static let aiCueDescriptionSummary: Self = "ai-cue.description.summary"
    public static let aiCueModifyDescription: Self = "ai-cue.description.modify"
    public static let aiCueNameLabel: Self = "ai-cue.name.label"
    public static let aiCueNameHelp: Self = "ai-cue.name.help"
    public static let aiCueCandidateClear: Self = "ai-cue.candidate.clear"
    public static let aiCueCandidateBrisk: Self = "ai-cue.candidate.brisk"
    public static let aiCueCandidateRestrained: Self = "ai-cue.candidate.restrained"
    public static let aiCueCandidateDuration: Self = "ai-cue.candidate.duration"
    public static let aiCueCandidatePlayAction: Self = "ai-cue.candidate.play-action"
    public static let aiCueCandidateStopAction: Self = "ai-cue.candidate.stop-action"
    public static let aiCueCandidatePlaybackStarted: Self = "ai-cue.candidate.playback-started"
    public static let aiCueCandidatePlaybackStopped: Self = "ai-cue.candidate.playback-stopped"
    public static let aiCueComposerClosed: Self = "ai-cue.composer.closed"
    public static let aiCueComposerClosedCandidatesCleared: Self =
        "ai-cue.composer.closed-candidates-cleared"
    public static let aiCueUseForEvent: Self = "ai-cue.use-for-event"
    public static let aiCueRegenerate: Self = "ai-cue.regenerate"
    public static let aiCueAppliedTitle: Self = "ai-cue.applied.title"
    public static let aiCueAppliedMessage: Self = "ai-cue.applied.message"
    public static let aiCueErrorDescriptionRequired: Self = "ai-cue.error.description-required"
    public static let aiCueErrorDescriptionTooLong: Self = "ai-cue.error.description-too-long"
    public static let aiCueErrorSpeechNeedsText: Self = "ai-cue.error.speech-needs-text"
    public static let aiCueErrorUnsupportedModality: Self =
        "ai-cue.error.unsupported-modality"
    public static let aiCueErrorUnsupportedLocale: Self = "ai-cue.error.unsupported-locale"
    public static let aiCueErrorCredentialRequired: Self = "ai-cue.error.credential-required"
    public static let aiCueErrorCredentialInvalid: Self = "ai-cue.error.credential-invalid"
    public static let aiCueErrorCredentialUnavailable: Self = "ai-cue.error.credential-unavailable"
    public static let aiCueErrorCredits: Self = "ai-cue.error.credits"
    public static let aiCueErrorRateLimited: Self = "ai-cue.error.rate-limited"
    public static let aiCueErrorAudioInvalid: Self = "ai-cue.error.audio-invalid"
    public static let aiCueErrorGeneration: Self = "ai-cue.error.generation"
    public static let aiCueErrorNameRequired: Self = "ai-cue.error.name-required"
    public static let aiCueErrorNameInvalid: Self = "ai-cue.error.name-invalid"
    public static let aiCueErrorAdoptionTarget: Self = "ai-cue.error.adoption-target"
    public static let aiCueErrorAdoptionPartial: Self = "ai-cue.error.adoption-partial"
    public static let aiCueErrorAdoption: Self = "ai-cue.error.adoption"
    public static let actionRedetectInProgress: Self = "action.redetect.in-progress"
    public static let actionConnectInProgress: Self = "action.connect.in-progress"
    public static let actionUpgradeInProgress: Self = "action.upgrade.in-progress"
    public static let actionRepairInProgress: Self = "action.repair.in-progress"
    public static let actionDisconnectInProgress: Self = "action.disconnect.in-progress"
    public static let actionClearReceiptHistoryInProgress: Self =
        "action.clear-receipt-history.in-progress"
    public static let soundPacksWindowTitle: Self = "window.sound-packs.title"
    public static let soundPacksManagingScope: Self = "window.sound-packs.managing-scope"
    public static let soundPacksInvalidScope: Self = "window.sound-packs.invalid-scope"
    public static let soundPacksDamagedScope: Self = "window.sound-packs.damaged-scope"
    public static let eventSettingsTitle: Self = "event-settings.title"
    public static let eventSettingsPreviewAll: Self = "event-settings.preview-all"
    public static let eventSettingsPreviewAllHint: Self = "event-settings.preview-all.hint"
    public static let eventSettingsAutomaticPlayback: Self =
        "event-settings.automatic-playback"
    public static let eventSettingsAutomaticPlaybackFor: Self =
        "event-settings.automatic-playback-for"
    public static let eventSettingsManageSounds: Self = "event-settings.manage-sounds"
    public static let eventSettingsManageSoundsHint: Self = "event-settings.manage-sounds.hint"
    public static let eventSettingsWindowTitle: Self = "window.event-settings.title"
    public static let eventSettingsUnavailableShortcutScope: Self =
        "event-settings.shortcut-scope.unavailable"
    public static let integrationsWindowTitle: Self = "window.integrations.title"
    public static let settingsWindowTitle: Self = "window.settings.title"
    public static let settingsDestinationGeneral: Self = "settings.destination.general"
    public static let settingsDestinationIntegrations: Self =
        "settings.destination.integrations"
    public static let settingsDestinationEventsAndSounds: Self =
        "settings.destination.events-and-sounds"
    public static let settingsDestinationNotifications: Self =
        "settings.destination.notifications"
    public static let settingsDestinationDisplay: Self = "settings.destination.display"
    public static let settingsDestinationSounds: Self = "settings.destination.sounds"
    public static let settingsDestinationUsage: Self = "settings.destination.usage"
    public static let settingsDestinationShortcuts: Self = "settings.destination.shortcuts"
    public static let settingsDestinationAbout: Self = "settings.destination.about"
    public static let settingsSidebarAdvanced: Self = "settings.sidebar.advanced"
    public static let settingsSidebarProduct: Self = "settings.sidebar.product"
    public static let settingsSidebarLocalFirst: Self = "settings.sidebar.local-first"
    public static let settingsAnnouncementValue: Self = "settings.announcement.value"
    public static let settingsAboutUnknown: Self = "settings.about.unknown"
    public static let settingsAboutBrand: Self = "settings.about.brand"
    public static let settingsAboutProduct: Self = "settings.about.product"
    public static let settingsAboutVersion: Self = "settings.about.version"
    public static let settingsAboutBuild: Self = "settings.about.build"
    public static let settingsAboutArchitecture: Self = "settings.about.architecture"
    public static let settingsAboutMinimumMacOS: Self = "settings.about.minimum-macos"
    public static let settingsAboutCurrentMacOS: Self = "settings.about.current-macos"
    public static let settingsAboutCopyVersion: Self = "settings.about.copy-version"
    public static let settingsAboutCopyVersionHint: Self = "settings.about.copy-version.hint"
    public static let settingsAboutResourcesTitle: Self = "settings.about.resources.title"
    public static let settingsAboutResourcesDescription: Self =
        "settings.about.resources.description"
    public static let settingsAboutResourceOpenSourceLicense: Self =
        "settings.about.resource.open-source-license"
    public static let settingsAboutResourceSoundAttribution: Self =
        "settings.about.resource.sound-attribution"
    public static let settingsAboutResourcePrivacy: Self = "settings.about.resource.privacy"
    public static let settingsAboutResourceMissing: Self = "settings.about.resource.missing"
    public static let settingsAboutOpenResourceHint: Self = "settings.about.resource.open.hint"
    public static let settingsAboutDiagnosticsTitle: Self = "settings.about.diagnostics.title"
    public static let settingsAboutDiagnosticsDescription: Self =
        "settings.about.diagnostics.description"
    public static let settingsAboutCopyDiagnostics: Self = "settings.about.diagnostics.copy"
    public static let settingsAboutCopyDiagnosticsHint: Self =
        "settings.about.diagnostics.copy.hint"
    public static let settingsAboutVersionCopied: Self = "settings.about.feedback.version-copied"
    public static let settingsAboutDiagnosticsCopied: Self =
        "settings.about.feedback.diagnostics-copied"
    public static let settingsAboutClipboardFailed: Self = "settings.about.failure.clipboard"
    public static let settingsAboutOpenFailed: Self = "settings.about.failure.open"
    public static let settingsIntegrationsManageEvents: Self =
        "settings.integrations.manage-events"
    public static let settingsIntegrationsManageEventsHint: Self =
        "settings.integrations.manage-events.hint"
    /// One exported namespace avoids a separate public global for every Display leaf in the
    /// size-constrained menu-bar executable.
    public static let settingsDisplay = (
        textSizeDescription: Self("settings.display.text-size.description"),
        panelWidthTitle: Self("settings.display.panel-width.title"),
        panelWidthDescription: Self("settings.display.panel-width.description"),
        panelWidthAutomatic: Self("settings.display.panel-width.automatic"),
        panelWidthCompact: Self("settings.display.panel-width.compact"),
        panelWidthRoomy: Self("settings.display.panel-width.roomy"),
        panelWidthClamped: Self("settings.display.panel-width.clamped"),
        statusDotTitle: Self("settings.display.status-dot.title"),
        statusDotDescription: Self("settings.display.status-dot.description"),
        statusRunning: Self("menu-bar.status.running")
    )
    public static let settingsDisplayStatusDotEnabled: Self =
        "settings.display.status-dot.enabled"
    public static let settingsDisplayStatusDotDisabled: Self =
        "settings.display.status-dot.disabled"
    public static let settingsGeneralLanguageTitle: Self = "settings.general.language.title"
    public static let settingsGeneralLanguageDescription: Self =
        "settings.general.language.description"
    public static let settingsGeneralLanguageSystem: Self = "settings.general.language.system"
    public static let settingsGeneralLanguageChinese: Self = "settings.general.language.chinese"
    public static let settingsGeneralLanguageEnglish: Self = "settings.general.language.english"
    public static let settingsGeneralLanguageHint: Self = "settings.general.language.hint"
    public static let settingsGeneralSystemProjection: Self =
        "settings.general.language.system-projection"
    public static let settingsGeneralPreferenceRecovery: Self =
        "settings.general.preference-recovery"
    /// One exported namespace keeps this feature's catalog surface together without emitting a
    /// separate public global symbol for every label in the size-constrained menu-bar executable.
    public static let settingsGeneralLoginItem = (
        description: Self("settings.general.login-item.description"),
        toggle: Self("settings.general.login-item.toggle"),
        hint: Self("settings.general.login-item.hint"),
        disabled: Self("settings.general.login-item.status.disabled"),
        enabled: Self("settings.general.login-item.status.enabled"),
        requiresApproval: Self("settings.general.login-item.status.requires-approval"),
        unavailable: Self("settings.general.login-item.status.unavailable"),
        openSettings: Self("settings.general.login-item.open-settings"),
        openSettingsHint: Self("settings.general.login-item.open-settings.hint"),
        failureEnable: Self("settings.general.login-item.failure.enable"),
        failureDisable: Self("settings.general.login-item.failure.disable"),
        failureMissing: Self("settings.general.login-item.failure.missing")
    )
    public static let settingsNotificationsFocusTitle: Self =
        "settings.notifications.focus.title"
    public static let settingsNotificationsFocusDescription: Self =
        "settings.notifications.focus.description"
    public static let settingsNotificationsCalendarTitle: Self =
        "settings.notifications.calendar.title"
    public static let settingsNotificationsCalendarDescription: Self =
        "settings.notifications.calendar.description"
    public static let settingsNotificationsPermissionTitle: Self =
        "settings.notifications.permission.title"
    public static let settingsNotificationsCalendarPermissionTitle: Self =
        "settings.notifications.calendar.permission.title"
    public static let settingsNotificationsPermissionNotRequested: Self =
        "settings.notifications.permission.not-requested"
    public static let settingsNotificationsPermissionAuthorized: Self =
        "settings.notifications.permission.authorized"
    public static let settingsNotificationsPermissionDenied: Self =
        "settings.notifications.permission.denied"
    public static let settingsNotificationsPermissionRestricted: Self =
        "settings.notifications.permission.restricted"
    public static let settingsNotificationsCurrentReasonTitle: Self =
        "settings.notifications.reason.title"
    public static let settingsNotificationsReasonDisabled: Self =
        "settings.notifications.reason.disabled"
    public static let settingsNotificationsReasonPermissionRequired: Self =
        "settings.notifications.reason.permission-required"
    public static let settingsNotificationsReasonInactive: Self =
        "settings.notifications.reason.inactive"
    public static let settingsNotificationsReasonFocusActive: Self =
        "settings.notifications.reason.focus-active"
    public static let settingsNotificationsReasonCalendarBusy: Self =
        "settings.notifications.reason.calendar-busy"
    public static let settingsNotificationsReasonFocusAndCalendarBusy: Self =
        "settings.notifications.reason.focus-and-calendar-busy"
    public static let settingsNotificationsReasonObserverFailure: Self =
        "settings.notifications.reason.observer-failure"
    public static let settingsNotificationsSnapshotHealthTitle: Self =
        "settings.notifications.snapshot-health.title"
    public static let settingsNotificationsSnapshotCurrent: Self =
        "settings.notifications.snapshot-health.current"
    public static let settingsNotificationsSnapshotPublicationFailed: Self =
        "settings.notifications.snapshot-health.publication-failed"
    public static let settingsNotificationsSnapshotExpired: Self =
        "settings.notifications.snapshot-health.expired"
    public static let settingsNotificationsPublicationFailed: Self =
        "settings.notifications.publication-failed"
    public static let settingsNotificationsOpenCalendarPrivacy: Self =
        "settings.notifications.open-calendar-privacy"
    public static let settingsNotificationsOpenEvents: Self =
        "settings.notifications.open-events"
    public static let settingsNotificationsAnnouncementSummary: Self =
        "settings.notifications.announcement.summary"
    public static let settingsUsageDescription: Self = "settings.usage.description"
    public static let settingsUsageScopeNotice: Self = "settings.usage.scope-notice"
    public static let settingsUsageRefresh: Self = "settings.usage.refresh"
    public static let settingsUsageHistoryTitle: Self = "settings.usage.history.title"
    public static let settingsUsageSurfaceCount: Self = "settings.usage.history.surface-count"
    public static let settingsUsageHistoryNone: Self = "settings.usage.history.none"
    public static let settingsUsageHistoryMissing: Self = "settings.usage.history.missing"
    public static let settingsUsageHistoryDamaged: Self = "settings.usage.history.damaged"
    public static let settingsUsageHistoryUnreadable: Self = "settings.usage.history.unreadable"
    public static let settingsUsageResultCount: Self = "settings.usage.history.result-count"
    public static let settingsUsageLogTitle: Self = "settings.usage.log.title"
    public static let settingsUsageLogDescription: Self = "settings.usage.log.description"
    public static let settingsUsageLogAvailable: Self = "settings.usage.log.available"
    public static let settingsUsageLogMissing: Self = "settings.usage.log.missing"
    public static let settingsUsageLogDamaged: Self = "settings.usage.log.damaged"
    public static let settingsUsageLogUnreadable: Self = "settings.usage.log.unreadable"
    public static let settingsUsageLogNoFailures: Self = "settings.usage.log.no-failures"
    public static let settingsUsageLogFailurePlaybackLaunch: Self =
        "settings.usage.log.failure.playback-launch"
    public static let settingsUsageLogFailurePlaybackLock: Self =
        "settings.usage.log.failure.playback-lock"
    public static let settingsUsageLogFailureReceiptWrite: Self =
        "settings.usage.log.failure.receipt-write"
    public static let settingsUsageLogFailureOther: Self = "settings.usage.log.failure.other"
    public static let settingsUsageLogFailureUnknownEvent: Self =
        "settings.usage.log.failure.unknown-event"
    public static let settingsUsageLogFailureSummary: Self =
        "settings.usage.log.failure.summary"
    public static let settingsUsageRevealLog: Self = "settings.usage.log.reveal"
    public static let settingsUsageCopyLogPath: Self = "settings.usage.log.copy-path"
    public static let settingsUsageClearHistory: Self = "settings.usage.clear.history"
    public static let settingsUsageClearLog: Self = "settings.usage.clear.log"
    public static let settingsUsageClearHistoryTitle: Self =
        "settings.usage.clear.history.title"
    public static let settingsUsageClearHistoryMessage: Self =
        "settings.usage.clear.history.message"
    public static let settingsUsageClearLogTitle: Self = "settings.usage.clear.log.title"
    public static let settingsUsageClearLogMessage: Self = "settings.usage.clear.log.message"
    public static let settingsUsagePrivacyTitle: Self = "settings.usage.privacy.title"
    public static let settingsUsagePrivacyHost: Self = "settings.usage.privacy.host"
    public static let settingsUsagePrivacyProvider: Self = "settings.usage.privacy.provider"
    public static let settingsUsagePrivacyBilling: Self = "settings.usage.privacy.billing"
    public static let settingsUsageProviderDisclosure: Self =
        "settings.usage.privacy.provider-disclosure"
    public static let settingsUsageActionInProgress: Self = "settings.usage.action.in-progress"
    public static let settingsUsageActionHistoryCleared: Self =
        "settings.usage.action.history-cleared"
    public static let settingsUsageActionLogCleared: Self = "settings.usage.action.log-cleared"
    public static let settingsUsageActionLogRevealed: Self = "settings.usage.action.log-revealed"
    public static let settingsUsageActionLogPathCopied: Self =
        "settings.usage.action.log-path-copied"
    public static let settingsUsageFailureHistoryLockBusy: Self =
        "settings.usage.failure.history-lock-busy"
    public static let settingsUsageFailureLogLockBusy: Self =
        "settings.usage.failure.log-lock-busy"
    public static let settingsUsageFailureHistoryClear: Self =
        "settings.usage.failure.history-clear"
    public static let settingsUsageFailureLogClear: Self = "settings.usage.failure.log-clear"
    public static let settingsUsageFailureFinder: Self = "settings.usage.failure.finder"
    public static let settingsUsageFailureClipboard: Self = "settings.usage.failure.clipboard"
    public static let settingsShortcutsDescription: Self = "settings.shortcuts.description"
    public static let settingsShortcutsRequirement: Self = "settings.shortcuts.requirement"
    public static let settingsShortcutsActionTogglePanel: Self =
        "settings.shortcuts.action.toggle-panel"
    public static let settingsShortcutsActionTogglePanelDescription: Self =
        "settings.shortcuts.action.toggle-panel.description"
    public static let settingsShortcutsActionOpenSettings: Self =
        "settings.shortcuts.action.open-settings"
    public static let settingsShortcutsActionOpenSettingsDescription: Self =
        "settings.shortcuts.action.open-settings.description"
    public static let settingsShortcutsActionOpenCurrentScopeEvents: Self =
        "settings.shortcuts.action.open-current-scope-events"
    public static let settingsShortcutsActionOpenCurrentScopeEventsDescription: Self =
        "settings.shortcuts.action.open-current-scope-events.description"
    public static let settingsShortcutsUnassigned: Self = "settings.shortcuts.unassigned"
    public static let settingsShortcutsCurrentValue: Self = "settings.shortcuts.current-value"
    public static let settingsShortcutsRecord: Self = "settings.shortcuts.record"
    public static let settingsShortcutsRecording: Self = "settings.shortcuts.recording"
    public static let settingsShortcutsCancelRecording: Self =
        "settings.shortcuts.cancel-recording"
    public static let settingsShortcutsRecordLabel: Self = "settings.shortcuts.record.label"
    public static let settingsShortcutsCancelRecordingLabel: Self =
        "settings.shortcuts.cancel-recording.label"
    public static let settingsShortcutsRecordHint: Self = "settings.shortcuts.record.hint"
    public static let settingsShortcutsClear: Self = "settings.shortcuts.clear"
    public static let settingsShortcutsClearLabel: Self = "settings.shortcuts.clear.label"
    public static let settingsShortcutsFailureInvalidStoredValue: Self =
        "settings.shortcuts.failure.invalid-stored-value"
    public static let settingsShortcutsFailurePrimaryModifier: Self =
        "settings.shortcuts.failure.primary-modifier"
    public static let settingsShortcutsFailureUnsupportedKey: Self =
        "settings.shortcuts.failure.unsupported-key"
    public static let settingsShortcutsFailureSystemReserved: Self =
        "settings.shortcuts.failure.system-reserved"
    public static let settingsShortcutsFailureDuplicate: Self =
        "settings.shortcuts.failure.duplicate"
    public static let settingsShortcutsFailureConflict: Self =
        "settings.shortcuts.failure.conflict"
    public static let settingsShortcutsFailureRegistration: Self =
        "settings.shortcuts.failure.registration"
    public static let settingsShortcutsFailureUnregister: Self =
        "settings.shortcuts.failure.unregister"
    public static let settingsShortcutsFailurePersistence: Self =
        "settings.shortcuts.failure.persistence"
    public static let settingsShortcutsFailurePersistenceCleanup: Self =
        "settings.shortcuts.failure.persistence-cleanup"
    public static let settingsShortcutsFailureRollback: Self =
        "settings.shortcuts.failure.rollback"
    public static let settingsRouteIdentity: Self = "settings.route.identity"
    public static let settingsRouteReady: Self = "settings.route.ready"
    public static let settingsRouteInvalidSurface: Self = "settings.route.invalid-surface"
    public static let settingsRouteStaleSurface: Self = "settings.route.stale-surface"
    public static let settingsRouteStaleScope: Self = "settings.route.stale-scope"
    public static let settingsRouteStaleEvent: Self = "settings.route.stale-event"
    public static let settingsRouteInvalidPack: Self = "settings.route.invalid-pack"
    public static let settingsRouteStalePack: Self = "settings.route.stale-pack"
    public static let settingsRouteReturnToSidebar: Self = "settings.route.return-to-sidebar"
    public static let integrationsClearReceiptHistoryConfirm: Self =
        "integrations.clear-receipt-history.confirm"
    public static let integrationsClearReceiptHistoryTitle: Self =
        "integrations.clear-receipt-history.title"
    public static let integrationsClearReceiptHistoryMessage: Self =
        "integrations.clear-receipt-history.message"
    public static let integrationsRedetect: Self = "integrations.redetect"
    public static let integrationsRedetectLabel: Self = "integrations.redetect.label"
    public static let integrationsRedetectHint: Self = "integrations.redetect.hint"
    public static let integrationsSourcesSummary: Self = "integrations.sources-summary"
    public static let integrationsSelectionEmpty: Self = "integrations.selection.empty"
    public static let integrationsSelectionLabel: Self = "integrations.selection.label"
    public static let integrationsCapability: Self = "integrations.capability"
    public static let integrationsEvent: Self = "integrations.event"
    public static let integrationsInspector: Self = "integrations.inspector"
    public static let integrationsConnection: Self = "integrations.connection"
    public static let integrationsNativeEvent: Self = "integrations.native-event"
    public static let integrationsRecentReceipt: Self = "integrations.recent-receipt"
    public static let integrationsChooseEvent: Self = "integrations.choose-event"
    public static let integrationsConfigurationSource: Self = "integrations.configuration-source"
    public static let integrationsCopyPathHint: Self = "integrations.copy-path.hint"
    public static let integrationsCloseFeedback: Self = "integrations.feedback.close"
    public static let integrationsSelected: Self = "integrations.selected"
    public static let integrationsNotSelected: Self = "integrations.not-selected"
    public static let integrationsCellHint: Self = "integrations.cell.hint"
    public static let integrationsDisconnectConfirm: Self = "integrations.disconnect.confirm"
    public static let integrationsDisconnectTitle: Self = "integrations.disconnect.title"
    public static let integrationsDisconnectHint: Self = "integrations.disconnect.hint"
    public static let integrationsDisconnectMessage: Self = "integrations.disconnect.message"
    public static let integrationsCopyPathLabel: Self = "integrations.copy-path.label"
    public static let integrationsNoReceipt: Self = "integrations.no-receipt"
    public static let integrationsMasterVolumeZero: Self = "integrations.master-volume-zero"
    public static let integrationsUnsupported: Self = "integrations.unsupported"
    public static let integrationsStoreUnavailable: Self = "integrations.store-unavailable"
    public static let integrationsRecoveryUnavailable: Self = "integrations.recovery-unavailable"
    public static let integrationsMuteFallbackFailed: Self = "integrations.mute-fallback-failed"
    public static let integrationsManagerProvidedSource: Self =
        "integrations.manager-provided-source"
    public static let soundPacksTitle: Self = "sound-packs.title"
    public static let commonCancel: Self = "common.cancel"
    public static let commonConfirm: Self = "common.confirm"
    public static let commonRestore: Self = "common.restore"
    public static let commonDeletePermanently: Self = "common.delete-permanently"
    public static let commonCopy: Self = "common.copy"
    public static let commonRetry: Self = "common.retry"
    public static let commonClose: Self = "common.close"
    public static let soundPacksDeleteTitle: Self = "sound-packs.confirm.delete.title"
    public static let soundPacksDeleteButton: Self = "sound-packs.confirm.delete.button"
    public static let soundPacksDeleteHint: Self = "sound-packs.confirm.delete.hint"
    public static let soundPacksDeleteMessage: Self = "sound-packs.confirm.delete.message"
    public static let soundPacksRestoreTitle: Self = "sound-packs.confirm.restore.title"
    public static let soundPacksRestoreButton: Self = "sound-packs.confirm.restore.button"
    public static let soundPacksRestoreLabel: Self = "sound-packs.confirm.restore.label"
    public static let soundPacksRestoreHint: Self = "sound-packs.confirm.restore.hint"
    public static let soundPacksRestoreSelectedMessage: Self =
        "sound-packs.confirm.restore.selected"
    public static let soundPacksRestoreRetryMessage: Self = "sound-packs.confirm.restore.retry"
    public static let soundPacksRestoreAllMessage: Self = "sound-packs.confirm.restore.all"
    public static let soundPacksLibraryLoading: Self = "sound-packs.library.loading"
    public static let soundPacksLibraryRefreshing: Self = "sound-packs.library.refreshing"
    public static let soundPacksLibraryRefreshFailed: Self = "sound-packs.library.refresh-failed"
    public static let soundPacksLibraryRetryLabel: Self = "sound-packs.library.retry.label"
    public static let soundPacksLibraryRetryHint: Self = "sound-packs.library.retry.hint"
    public static let soundPacksSidebarTitle: Self = "sound-packs.sidebar.title"
    public static let soundPacksSidebarStars: Self = "sound-packs.sidebar.stars"
    public static let soundPacksSidebarLabel: Self = "sound-packs.sidebar.label"
    public static let soundPacksSidebarViewing: Self = "sound-packs.sidebar.viewing"
    public static let soundPacksSidebarNone: Self = "sound-packs.sidebar.none"
    public static let soundPacksSidebarHint: Self = "sound-packs.sidebar.hint"
    public static let soundPacksCardHint: Self = "sound-packs.card.hint"
    public static let soundPacksStarPin: Self = "sound-packs.star.pin"
    public static let soundPacksStarUnpin: Self = "sound-packs.star.unpin"
    public static let soundPacksStarPinHint: Self = "sound-packs.star.pin.hint"
    public static let soundPacksStarUnpinHint: Self = "sound-packs.star.unpin.hint"
    public static let soundPacksStarPinned: Self = "sound-packs.star.pinned"
    public static let soundPacksStarUnpinned: Self = "sound-packs.star.unpinned"
    public static let soundPacksUsing: Self = "sound-packs.using"
    public static let soundPacksAudioLoading: Self = "sound-packs.audio.loading"
    public static let soundPacksAudioLoadingLabel: Self = "sound-packs.audio.loading.label"
    public static let soundPacksBuiltinBadge: Self = "sound-packs.builtin.badge"
    public static let soundPacksBuiltinLabel: Self = "sound-packs.builtin.label"
    public static let soundPacksReveal: Self = "sound-packs.reveal"
    public static let soundPacksRevealLabel: Self = "sound-packs.reveal.label"
    public static let soundPacksRevealHint: Self = "sound-packs.reveal.hint"
    public static let soundPacksRestore: Self = "sound-packs.restore"
    public static let soundPacksRestorePackLabel: Self = "sound-packs.restore.label"
    public static let soundPacksBuiltinValue: Self = "sound-packs.builtin.value"
    public static let soundPacksRestorePackHint: Self = "sound-packs.restore.hint"
    public static let soundPacksCopy: Self = "sound-packs.copy"
    public static let soundPacksCopyLabel: Self = "sound-packs.copy.label"
    public static let soundPacksOriginalReadonly: Self = "sound-packs.original-readonly"
    public static let soundPacksAddAudio: Self = "sound-packs.add-audio"
    public static let soundPacksAddingAudio: Self = "sound-packs.adding-audio"
    public static let soundPacksWritingChanges: Self = "sound-packs.writing-changes"
    public static let soundPacksAddAudioLabel: Self = "sound-packs.add-audio.label"
    public static let soundPacksImporting: Self = "sound-packs.importing"
    public static let soundPacksAddAudioHint: Self = "sound-packs.add-audio.hint"
    public static let soundPacksPackDelete: Self = "sound-packs.pack-delete"
    public static let soundPacksPackDeleteTitle: Self = "sound-packs.pack-delete.title"
    public static let soundPacksPackDeleteMessage: Self = "sound-packs.pack-delete.message"
    public static let soundPacksPackDeleteLabel: Self = "sound-packs.pack-delete.label"
    public static let soundPacksPackDeleteHint: Self = "sound-packs.pack-delete.hint"
    public static let soundPacksPackDeleteActive: Self = "sound-packs.pack-delete.active"
    public static let soundPacksPackDeleteAvailable: Self = "sound-packs.pack-delete.available"
    public static let soundPacksPackDeleteNoSelection: Self =
        "sound-packs.pack-delete.error.no-selection"
    public static let soundPacksPackDeleteSelectionChanged: Self =
        "sound-packs.pack-delete.error.selection-changed"
    public static let soundPacksPackDeleteUnsafeID: Self =
        "sound-packs.pack-delete.error.unsafe-id"
    public static let soundPacksPackDeleteBuiltin: Self =
        "sound-packs.pack-delete.error.builtin"
    public static let soundPacksPackDeleteErrorActive: Self =
        "sound-packs.pack-delete.error.active"
    public static let soundPacksPackDeleteConfigUnavailable: Self =
        "sound-packs.pack-delete.error.config-unavailable"
    public static let soundPacksPackDeleteNotFound: Self =
        "sound-packs.pack-delete.error.not-found"
    public static let soundPacksPackDeleteUnsafeEntry: Self =
        "sound-packs.pack-delete.error.unsafe-entry"
    public static let soundPacksPackDeleteFailed: Self =
        "sound-packs.pack-delete.error.failed"
    public static let soundPacksPackDeleteIsolationRetained: Self =
        "sound-packs.pack-delete.error.isolation-retained"
    public static let soundPacksPackDeleteTrashRetained: Self =
        "sound-packs.pack-delete.error.trash-retained"
    public static let soundPacksPackDeleteLockBusy: Self =
        "sound-packs.pack-delete.error.lock-busy"
    public static let soundPacksPackDeleteLockFailed: Self =
        "sound-packs.pack-delete.error.lock-failed"
    public static let soundPacksUse: Self = "sound-packs.use"
    public static let soundPacksUseLabel: Self = "sound-packs.use.label"
    public static let soundPacksUseValue: Self = "sound-packs.use.value"
    public static let soundPacksUseHint: Self = "sound-packs.use.hint"
    public static let soundPacksEmptyLoadingMessage: Self = "sound-packs.empty.loading-message"
    public static let soundPacksEmptyLoadFailedMessage: Self =
        "sound-packs.empty.load-failed-message"
    public static let soundPacksEmptyFactoryMessage: Self = "sound-packs.empty.factory-message"
    public static let soundPacksEmptyRestore: Self = "sound-packs.empty.restore"
    public static let soundPacksEmptyRestoreLabel: Self = "sound-packs.empty.restore.label"
    public static let soundPacksEmptyRestoreValue: Self = "sound-packs.empty.restore.value"
    public static let soundPacksEmptyRestoreHint: Self = "sound-packs.empty.restore.hint"
    public static let soundPacksEmptyNoFactoryMessage: Self = "sound-packs.empty.no-factory-message"
    public static let soundPacksEmptyReveal: Self = "sound-packs.empty.reveal"
    public static let soundPacksEmptyRevealLabel: Self = "sound-packs.empty.reveal.label"
    public static let soundPacksEmptyRevealHint: Self = "sound-packs.empty.reveal.hint"
    public static let soundPacksRetryRestore: Self = "sound-packs.retry-restore"
    public static let soundPacksRetryRestoreLabel: Self = "sound-packs.retry-restore.label"
    public static let soundPacksRetryRestoreValue: Self = "sound-packs.retry-restore.value"
    public static let soundPacksRetryRestoreHint: Self = "sound-packs.retry-restore.hint"
    public static let soundPacksPreview: Self = "sound-packs.preview"
    public static let soundPacksPreviewLabel: Self = "sound-packs.preview.label"
    public static let soundPacksExistingFiles: Self = "sound-packs.existing-files"
    public static let soundPacksEmptyAudio: Self = "sound-packs.empty-audio"
    public static let soundPacksChooseBind: Self = "sound-packs.choose-bind"
    public static let soundPacksChooseBindLabel: Self = "sound-packs.choose-bind.label"
    public static let soundPacksChooseBindHint: Self = "sound-packs.choose-bind.hint"
    public static let soundPacksClearBinding: Self = "sound-packs.clear-binding"
    public static let soundPacksClearBindingLabel: Self = "sound-packs.clear-binding.label"
    public static let soundPacksClearBindingHint: Self = "sound-packs.clear-binding.hint"
    public static let soundPacksRevealMapping: Self = "sound-packs.reveal-mapping"
    public static let soundPacksRevealMappingLabel: Self = "sound-packs.reveal-mapping.label"
    public static let soundPacksRevealMappingHint: Self = "sound-packs.reveal-mapping.hint"
    public static let soundPacksMappingLabel: Self = "sound-packs.mapping.label"
    public static let soundPacksMappingHint: Self = "sound-packs.mapping.hint"
    public static let soundPacksOrphanTitle: Self = "sound-packs.orphan.title"
    public static let soundPacksOrphanReadonly: Self = "sound-packs.orphan.readonly"
    public static let soundPacksOrphanUnused: Self = "sound-packs.orphan.unused"
    public static let soundPacksOrphanAssign: Self = "sound-packs.orphan.assign"
    public static let soundPacksOrphanAssignLabel: Self = "sound-packs.orphan.assign.label"
    public static let soundPacksOrphanAssignValue: Self = "sound-packs.orphan.assign.value"
    public static let soundPacksOrphanAssignHint: Self = "sound-packs.orphan.assign.hint"
    public static let soundPacksOrphanDelete: Self = "sound-packs.orphan.delete"
    public static let soundPacksOrphanDeleteLabel: Self = "sound-packs.orphan.delete.label"
    public static let soundPacksOrphanDeleteValue: Self = "sound-packs.orphan.delete.value"
    public static let soundPacksOrphanDeleteHint: Self = "sound-packs.orphan.delete.hint"
    public static let soundPacksCoverageUnmapped: Self = "sound-packs.coverage.unmapped"
    public static let soundPacksCoverageBroken: Self = "sound-packs.coverage.broken"
    public static let soundPacksPackActive: Self = "sound-packs.pack.active"
    public static let soundPacksPackComplete: Self = "sound-packs.pack.complete"
    public static let soundPacksPackPartial: Self = "sound-packs.pack.partial"
    public static let soundPacksPackBroken: Self = "sound-packs.pack.broken"
    public static let soundPacksPackManifestIdentityMismatch: Self =
        "sound-packs.pack.manifest-identity-mismatch"
    public static let soundPacksPackModified: Self = "sound-packs.pack.modified"
    public static let soundPacksPanelVisible: Self = "sound-packs.pack.panel-visible"
    public static let soundPacksPackNotUsed: Self = "sound-packs.pack.not-used"
    public static let soundPacksEventPresent: Self = "sound-packs.event.present"
    public static let soundPacksEventUnmapped: Self = "sound-packs.event.unmapped"
    public static let soundPacksEventBroken: Self = "sound-packs.event.broken"
    public static let soundPacksOperationFailed: Self = "sound-packs.operation.failed"
    public static let soundPacksActionFailed: Self = "sound-packs.action.failed"
    public static let soundPacksAnnouncementWindowLoading: Self =
        "sound-packs.announcement.window.loading"
    public static let soundPacksAnnouncementWindowFailure: Self =
        "sound-packs.announcement.window.failure"
    public static let soundPacksAnnouncementWindowEmpty: Self =
        "sound-packs.announcement.window.empty"
    public static let soundPacksAnnouncementWindowSelected: Self =
        "sound-packs.announcement.window.selected"
    public static let soundPacksAnnouncementWindowUnselected: Self =
        "sound-packs.announcement.window.unselected"
    public static let soundPacksAnnouncementLibraryLoading: Self =
        "sound-packs.announcement.library.loading"
    public static let soundPacksAnnouncementLibraryRefreshing: Self =
        "sound-packs.announcement.library.refreshing"
    public static let soundPacksAnnouncementLibraryLoadFailed: Self =
        "sound-packs.announcement.library.load-failed"
    public static let soundPacksAnnouncementLibraryRefreshFailed: Self =
        "sound-packs.announcement.library.refresh-failed"
    public static let soundPacksAnnouncementLibraryReadyEmpty: Self =
        "sound-packs.announcement.library.ready.empty"
    public static let soundPacksAnnouncementLibraryReadyCount: Self =
        "sound-packs.announcement.library.ready.count"
    public static let soundPacksAnnouncementSelectionNone: Self =
        "sound-packs.announcement.selection.none"
    public static let soundPacksAnnouncementSelectionSelected: Self =
        "sound-packs.announcement.selection.selected"
    public static let soundPacksAudioErrorNoSelectedPack: Self =
        "sound-packs.audio-error.no-selected-pack"
    public static let soundPacksAudioErrorSelectionChanged: Self =
        "sound-packs.audio-error.selection-changed"
    public static let soundPacksAudioErrorBuiltinReadOnly: Self =
        "sound-packs.audio-error.builtin-read-only"
    public static let soundPacksAudioErrorNotInInventory: Self =
        "sound-packs.audio-error.not-in-inventory"
    public static let soundPacksBindErrorPackNotFound: Self =
        "sound-packs.bind-error.pack-not-found"
    public static let soundPacksBindErrorUnsafeFileName: Self =
        "sound-packs.bind-error.unsafe-file-name"
    public static let soundPacksBindErrorFileNotFound: Self =
        "sound-packs.bind-error.file-not-found"
    public static let soundPacksBindErrorManifestUnreadable: Self =
        "sound-packs.bind-error.manifest-unreadable"
    public static let soundPacksBindErrorWriteFailed: Self = "sound-packs.bind-error.write-failed"
    public static let soundPacksBindErrorLockBusy: Self = "sound-packs.bind-error.lock-busy"
    public static let soundPacksBindErrorLockFailed: Self = "sound-packs.bind-error.lock-failed"
    public static let soundPacksDeleteErrorBuiltinReadOnly: Self =
        "sound-packs.delete-error.builtin-read-only"
    public static let soundPacksDeleteErrorPackNotFound: Self =
        "sound-packs.delete-error.pack-not-found"
    public static let soundPacksDeleteErrorManifestUnreadable: Self =
        "sound-packs.delete-error.manifest-unreadable"
    public static let soundPacksDeleteErrorDirectoryUnreadable: Self =
        "sound-packs.delete-error.directory-unreadable"
    public static let soundPacksDeleteErrorUnsafeFileName: Self =
        "sound-packs.delete-error.unsafe-file-name"
    public static let soundPacksDeleteErrorFileNotFound: Self =
        "sound-packs.delete-error.file-not-found"
    public static let soundPacksDeleteErrorStillReferenced: Self =
        "sound-packs.delete-error.still-referenced"
    public static let soundPacksDeleteErrorFailed: Self = "sound-packs.delete-error.failed"
    public static let soundPacksDeleteErrorLockBusy: Self = "sound-packs.delete-error.lock-busy"
    public static let soundPacksDeleteErrorLockFailed: Self = "sound-packs.delete-error.lock-failed"
    public static let soundPacksInventoryPackNotFound: Self = "sound-packs.inventory.pack-not-found"
    public static let soundPacksInventoryManifestUnreadable: Self =
        "sound-packs.inventory.manifest-unreadable"
    public static let soundPacksInventoryDirectoryUnreadable: Self =
        "sound-packs.inventory.directory-unreadable"
    public static let soundPacksMissingCount: Self = "sound-packs.missing-count"
    public static let soundPacksFileMissing: Self = "sound-packs.file-missing"
    public static let soundPacksBuiltinCopyExplanation: Self =
        "sound-packs.builtin.copy-explanation"
    public static let soundPacksBuiltinCopyHelp: Self = "sound-packs.builtin.copy-help"
    public static let soundPacksCanChooseFile: Self = "sound-packs.can-choose-file"
    public static let soundPacksStatusBackground: Self = "sound-packs.status.background"
    public static let soundPacksStatusAddAudio: Self = "sound-packs.status.action.add-audio"
    public static let soundPacksStatusUpdateStars: Self = "sound-packs.status.action.update-stars"
    public static let soundPacksStatusRestoreBuiltins: Self =
        "sound-packs.status.action.restore-builtins"
    public static let soundPacksStatusRestoreFactory: Self =
        "sound-packs.status.action.restore-factory"
    public static let soundPacksStatusCopyPack: Self = "sound-packs.status.action.copy-pack"
    public static let soundPacksStatusUsePack: Self = "sound-packs.status.action.use-pack"
    public static let soundPacksStatusDeletePack: Self = "sound-packs.status.action.delete-pack"
    public static let soundPacksStatusAudioImported: Self = "sound-packs.status.audio-imported"
    public static let soundPacksStatusAudioPartial: Self = "sound-packs.status.audio-partial"
    public static let soundPacksStatusBatchRestored: Self = "sound-packs.status.batch-restored"
    public static let soundPacksStatusBatchRestoredWithSalvage: Self =
        "sound-packs.status.batch-restored.salvage"
    public static let soundPacksStatusBatchPartial: Self = "sound-packs.status.batch-partial"
    public static let soundPacksStatusBatchPartialWithSalvage: Self =
        "sound-packs.status.batch-partial.salvage"
    public static let soundPacksStatusFactoryRestored: Self = "sound-packs.status.factory-restored"
    public static let soundPacksStatusFactoryRestoredWithSalvage: Self =
        "sound-packs.status.factory-restored.salvage"
    public static let soundPacksStatusPackCopied: Self = "sound-packs.status.pack-copied"
    public static let soundPacksStatusPackUsed: Self = "sound-packs.status.pack-used"
    public static let soundPacksStatusPackTrashed: Self = "sound-packs.status.pack-trashed"

    public static let onboardingClaudeCodeNotInstalledTitle: Self =
        "onboarding.claude-code-not-installed.title"
    public static let onboardingClaudeCodeNotInstalledBody: Self =
        "onboarding.claude-code-not-installed.body"
    public static let onboardingHelperMissingTitle: Self = "onboarding.helper-missing.title"
    public static let onboardingHelperMissingBody: Self = "onboarding.helper-missing.body"
    public static let onboardingSettingsNotWritableTitle: Self =
        "onboarding.settings-not-writable.title"
    public static let onboardingSettingsNotWritableBody: Self =
        "onboarding.settings-not-writable.body"
    public static let onboardingSettingsParseFailureTitle: Self =
        "onboarding.settings-parse-failure.title"
    public static let onboardingSettingsParseFailureBody: Self =
        "onboarding.settings-parse-failure.body"
    public static let onboardingNotInstalledTitle: Self = "onboarding.not-installed.title"
    public static let onboardingNotInstalledBody: Self = "onboarding.not-installed.body"
    public static let onboardingInstalledTitle: Self = "onboarding.installed.title"
    public static let onboardingInstalledBody: Self = "onboarding.installed.body"
    public static let onboardingActionRedetect: Self = "onboarding.action.redetect"
    public static let onboardingActionRepair: Self = "onboarding.action.repair"
    public static let onboardingActionTakeOver: Self = "onboarding.action.take-over"
    public static let onboardingActionDisconnect: Self = "onboarding.action.disconnect"
    public static let onboardingActionRevealReason: Self = "onboarding.action.reveal-reason"
    public static let onboardingReasonExpand: Self = "onboarding.reason.expand"
    public static let onboardingReasonCollapse: Self = "onboarding.reason.collapse"
    public static let onboardingActionRunningTakeOver: Self = "onboarding.action.running.take-over"
    public static let onboardingActionRunningDisconnect: Self =
        "onboarding.action.running.disconnect"
    public static let onboardingFailureHelperUnavailable: Self =
        "onboarding.failure.helper-unavailable"
    public static let onboardingFailureSetup: Self = "onboarding.failure.setup"
    public static let onboardingFailureDisconnect: Self = "onboarding.failure.disconnect"
    public static let onboardingFailureDisconnectNothing: Self =
        "onboarding.failure.disconnect-nothing"
    public static let onboardingNoticeSalvaged: Self = "onboarding.notice.salvaged"
    public static let onboardingNoticeRepaired: Self = "onboarding.notice.repaired"

    public static let feedbackRedetectedSources: Self = "feedback.redetected-sources"
    public static let feedbackCopyHooksSucceeded: Self = "feedback.copy-hooks.succeeded"
    public static let feedbackCopyHooksFailed: Self = "feedback.copy-hooks.failed"
    public static let feedbackMuteCancelled: Self = "feedback.mute-cancelled"
    public static let feedbackOpenSoundMapping: Self = "feedback.open-sound-mapping"
    public static let feedbackCopyConfigurationPathSucceeded: Self =
        "feedback.copy-configuration-path.succeeded"
    public static let feedbackCopyConfigurationPathFailed: Self =
        "feedback.copy-configuration-path.failed"
    public static let feedbackOperationFailed: Self = "feedback.operation-failed"
    public static let feedbackReceipt: Self = "feedback.receipt"
    public static let feedbackDisconnected: Self = "feedback.disconnected"
    public static let feedbackConnectedReceipt: Self = "feedback.connected.receipt"
    public static let feedbackAwaitingConfirmation: Self = "feedback.awaiting-confirmation"
    public static let feedbackRepairedWaiting: Self = "feedback.repaired-waiting"
    public static let feedbackConfiguredWaiting: Self = "feedback.configured-waiting"
    public static let feedbackHostStateUpdated: Self = "feedback.host-state-updated"
    public static let feedbackReceiptHistoryCleared: Self = "feedback.receipt-history-cleared"

    public static let allKnown: [Self] = [
        .interfaceTitle, .interfaceLanguage, .interfaceChinese, .interfaceEnglish,
        .interfaceTextSize, .interfaceTextSizeDecrease, .interfaceTextSizeIncrease,
        .interfaceTextSizeCurrent, .interfaceTextSizeLevel, .interfaceTextSizeMinimum,
        .interfaceTextSizeMaximum, .interfaceTextSizeCompact, .interfaceTextSizeStandard,
        .interfaceTextSizeLarge, .panelOptionsHint,
        .panelTitle, .panelBaseLabel, .panelHeader, .panelHeaderWithPack, .panelSources,
        .panelSelectedPackNone, .panelAudibleEventsLoading,
        .panelAudibleEventsUnavailable, .panelAudibleEventsCount, .panelEvents, .panelSoundPacks,
        .panelManageSoundPacks, .panelManageSoundPacksHint, .panelQuitApplication,
        .panelQuitApplicationHint, .panelRetry, .panelRetryHint,
        .panelLoadingEvents, .panelUnavailableEvents, .panelSelectPack, .panelSelectPackMessage,
        .panelSelectPackWithChoicesMessage, .panelSelectPackWithoutChoicesMessage,
        .panelPacksLoading, .panelPacksNoPinnedTitle, .panelPacksNoPinnedMessage,
        .panelPacksNoneTitle, .panelPacksNoneMessage, .panelPacksReadFailed,
        .panelRevealConfig, .panelRevealConfigHint, .panelMasterVolume,
        .panelMasterVolumeDescription, .panelHeaderSummary, .panelConnectionsDiagnostics,
        .panelCustomSoundOverrides, .panelNeedsPackSettingsMessage, .panelPlaybackSettings,
        .panelSoundPackLabel, .panelOpenSettings, .panelGlobalInheritance,
        .panelSurfaceOverride, .panelSurfaceOverrideDamaged, .panelInheritedGlobal,
        .panelNoSoundAssigned,
        .panelMissingSound, .panelNoNativeEvent, .panelCapabilitySupported,
        .panelCapabilityPartial, .panelCapabilityUnsupported,
        .panelCapabilitySupportedNotImplemented, .panelCapabilityPartialNotImplemented,
        .panelCapabilityUnsupportedNotImplemented, .hostDetailsHint,
        .aiCueGenerateAction, .aiCueGenerateHint, .aiCueProviderProfileElevenLabsGlobal,
        .aiCueProviderProfileMiniMaxGlobal, .aiCueProviderProfileQwenSingapore,
        .aiCueProviderProfileQwenBeijing, .aiCueServiceTitle, .aiCueServiceSubtitle,
        .aiCueServiceChecking, .aiCueServiceMissing, .aiCueServiceConfigured,
        .aiCueServiceStoredVerified, .aiCueServiceStoredDeferred, .aiCueServiceStoredRejected,
        .aiCueServicePendingReplacement, .aiCueServiceUnavailable, .aiCueProviderLabel,
        .aiCueProviderCapabilities, .aiCueModalitySpeech, .aiCueModalityAnimal,
        .aiCueModalitySoundEffect, .aiCueModalityMixed, .aiCueCredentialProbing,
        .aiCueCredentialSaving, .aiCueCredentialUpdatingReplacement, .aiCueCredentialDeleting,
        .aiCueConfigureKey,
        .aiCueManageKey, .aiCueCredentialTitle,
        .aiCueCredentialKeyLabel, .aiCueCredentialPrivacy, .aiCueCredentialPrivacyMiniMax,
        .aiCueCredentialPrivacyQwenSingapore, .aiCueCredentialPrivacyQwenBeijing,
        .aiCueCredentialKeychain, .aiCueCredentialValidateSave, .aiCueCredentialSave,
        .aiCueCredentialCancelReplacement, .aiCueCredentialDelete,
        .aiCueCredentialDeleteTitle,
        .aiCueCredentialDeleteMessage, .aiCueEligibilityGlobal, .aiCueEligibilityBuiltin,
        .aiCueEligibilityShared, .aiCueEligibilityUnavailable, .aiCueComposerTitle,
        .aiCueStageDescription, .aiCueStageCandidates, .aiCueDescriptionLabel,
        .aiCueDescriptionHelp, .aiCueDescriptionPlaceholder, .aiCueGenerateCandidates,
        .aiCueGenerating, .aiCueDescriptionSummary, .aiCueModifyDescription, .aiCueNameLabel,
        .aiCueNameHelp, .aiCueCandidateClear, .aiCueCandidateBrisk, .aiCueCandidateRestrained,
        .aiCueCandidateDuration, .aiCueCandidatePlayAction, .aiCueCandidateStopAction,
        .aiCueCandidatePlaybackStarted, .aiCueCandidatePlaybackStopped, .aiCueComposerClosed,
        .aiCueComposerClosedCandidatesCleared,
        .aiCueUseForEvent, .aiCueRegenerate, .aiCueAppliedTitle,
        .aiCueAppliedMessage,
        .aiCueErrorDescriptionRequired, .aiCueErrorDescriptionTooLong,
        .aiCueErrorSpeechNeedsText, .aiCueErrorUnsupportedModality,
        .aiCueErrorUnsupportedLocale, .aiCueErrorCredentialRequired,
        .aiCueErrorCredentialInvalid, .aiCueErrorCredentialUnavailable, .aiCueErrorCredits,
        .aiCueErrorRateLimited, .aiCueErrorAudioInvalid, .aiCueErrorGeneration,
        .aiCueErrorNameRequired, .aiCueErrorNameInvalid, .aiCueErrorAdoptionTarget,
        .aiCueErrorAdoptionPartial, .aiCueErrorAdoption,
        .soundPacksWindowTitle, .soundPacksManagingScope, .soundPacksInvalidScope,
        .soundPacksDamagedScope,
        .eventSettingsTitle, .eventSettingsPreviewAll, .eventSettingsPreviewAllHint,
        .eventSettingsAutomaticPlayback, .eventSettingsAutomaticPlaybackFor,
        .eventSettingsManageSounds,
        .eventSettingsManageSoundsHint, .eventSettingsWindowTitle,
        .eventSettingsUnavailableShortcutScope,
        .integrationsWindowTitle,
        .settingsWindowTitle, .settingsDestinationGeneral, .settingsDestinationIntegrations,
        .settingsDestinationEventsAndSounds, .settingsDestinationNotifications,
        .settingsDestinationDisplay, .settingsDestinationSounds, .settingsDestinationUsage,
        .settingsDestinationShortcuts, .settingsDestinationAbout,
        .settingsSidebarAdvanced, .settingsSidebarProduct, .settingsSidebarLocalFirst,
        .settingsAnnouncementValue,
        .settingsIntegrationsManageEvents, .settingsIntegrationsManageEventsHint,
        .settingsAboutUnknown, .settingsAboutBrand, .settingsAboutProduct,
        .settingsAboutVersion, .settingsAboutBuild, .settingsAboutArchitecture,
        .settingsAboutMinimumMacOS, .settingsAboutCurrentMacOS,
        .settingsAboutCopyVersion, .settingsAboutCopyVersionHint,
        .settingsAboutResourcesTitle, .settingsAboutResourcesDescription,
        .settingsAboutResourceOpenSourceLicense, .settingsAboutResourceSoundAttribution,
        .settingsAboutResourcePrivacy, .settingsAboutResourceMissing,
        .settingsAboutOpenResourceHint, .settingsAboutDiagnosticsTitle,
        .settingsAboutDiagnosticsDescription, .settingsAboutCopyDiagnostics,
        .settingsAboutCopyDiagnosticsHint, .settingsAboutVersionCopied,
        .settingsAboutDiagnosticsCopied, .settingsAboutClipboardFailed,
        .settingsAboutOpenFailed,
        settingsDisplay.textSizeDescription, settingsDisplay.panelWidthTitle,
        settingsDisplay.panelWidthDescription, settingsDisplay.panelWidthAutomatic,
        settingsDisplay.panelWidthCompact, settingsDisplay.panelWidthRoomy,
        settingsDisplay.panelWidthClamped, settingsDisplay.statusDotTitle,
        settingsDisplay.statusDotDescription, settingsDisplay.statusRunning,
        .settingsDisplayStatusDotEnabled, .settingsDisplayStatusDotDisabled,
        .settingsGeneralLanguageTitle,
        .settingsGeneralLanguageDescription, .settingsGeneralLanguageSystem,
        .settingsGeneralLanguageChinese, .settingsGeneralLanguageEnglish,
        .settingsGeneralLanguageHint, .settingsGeneralSystemProjection,
        .settingsGeneralPreferenceRecovery, settingsGeneralLoginItem.description,
        settingsGeneralLoginItem.toggle,
        settingsGeneralLoginItem.hint, settingsGeneralLoginItem.disabled,
        settingsGeneralLoginItem.enabled, settingsGeneralLoginItem.requiresApproval,
        settingsGeneralLoginItem.unavailable, settingsGeneralLoginItem.openSettings,
        settingsGeneralLoginItem.openSettingsHint, settingsGeneralLoginItem.failureEnable,
        settingsGeneralLoginItem.failureDisable, settingsGeneralLoginItem.failureMissing,
        .settingsNotificationsFocusTitle,
        .settingsNotificationsFocusDescription, .settingsNotificationsCalendarTitle,
        .settingsNotificationsCalendarDescription, .settingsNotificationsPermissionTitle,
        .settingsNotificationsCalendarPermissionTitle,
        .settingsNotificationsPermissionNotRequested,
        .settingsNotificationsPermissionAuthorized, .settingsNotificationsPermissionDenied,
        .settingsNotificationsPermissionRestricted, .settingsNotificationsCurrentReasonTitle,
        .settingsNotificationsReasonDisabled,
        .settingsNotificationsReasonPermissionRequired, .settingsNotificationsReasonInactive,
        .settingsNotificationsReasonFocusActive, .settingsNotificationsReasonCalendarBusy,
        .settingsNotificationsReasonFocusAndCalendarBusy,
        .settingsNotificationsReasonObserverFailure, .settingsNotificationsSnapshotHealthTitle,
        .settingsNotificationsSnapshotCurrent,
        .settingsNotificationsSnapshotPublicationFailed,
        .settingsNotificationsSnapshotExpired,
        .settingsNotificationsPublicationFailed,
        .settingsNotificationsOpenCalendarPrivacy, .settingsNotificationsOpenEvents,
        .settingsNotificationsAnnouncementSummary,
        .settingsShortcutsDescription, .settingsShortcutsRequirement,
        .settingsShortcutsActionTogglePanel, .settingsShortcutsActionTogglePanelDescription,
        .settingsShortcutsActionOpenSettings, .settingsShortcutsActionOpenSettingsDescription,
        .settingsShortcutsActionOpenCurrentScopeEvents,
        .settingsShortcutsActionOpenCurrentScopeEventsDescription,
        .settingsShortcutsUnassigned, .settingsShortcutsCurrentValue,
        .settingsShortcutsRecord, .settingsShortcutsRecording,
        .settingsShortcutsCancelRecording, .settingsShortcutsRecordLabel,
        .settingsShortcutsCancelRecordingLabel, .settingsShortcutsRecordHint,
        .settingsShortcutsClear, .settingsShortcutsClearLabel,
        .settingsShortcutsFailureInvalidStoredValue,
        .settingsShortcutsFailurePrimaryModifier, .settingsShortcutsFailureUnsupportedKey,
        .settingsShortcutsFailureSystemReserved,
        .settingsShortcutsFailureDuplicate, .settingsShortcutsFailureConflict,
        .settingsShortcutsFailureRegistration, .settingsShortcutsFailureUnregister,
        .settingsShortcutsFailurePersistence,
        .settingsShortcutsFailurePersistenceCleanup, .settingsShortcutsFailureRollback,
        .settingsRouteIdentity,
        .settingsRouteReady, .settingsRouteInvalidSurface, .settingsRouteStaleSurface,
        .settingsRouteStaleScope, .settingsRouteStaleEvent, .settingsRouteInvalidPack,
        .settingsRouteStalePack,
        .settingsRouteReturnToSidebar,
        .integrationsRedetect,
        .integrationsRedetectLabel,
        .integrationsRedetectHint, .integrationsSourcesSummary, .integrationsSelectionEmpty,
        .integrationsSelectionLabel, .integrationsCapability, .integrationsEvent,
        .integrationsInspector, .integrationsConnection, .integrationsNativeEvent,
        .integrationsRecentReceipt, .integrationsChooseEvent, .integrationsConfigurationSource,
        .integrationsCopyPathHint, .integrationsCloseFeedback, .integrationsSelected,
        .integrationsNotSelected, .integrationsCellHint, .soundPacksTitle, .commonCancel,
        .commonConfirm, .commonRestore, .commonDeletePermanently, .commonCopy, .commonRetry,
        .commonClose, .soundPacksDeleteTitle, .soundPacksDeleteButton, .soundPacksDeleteHint,
        .soundPacksDeleteMessage, .soundPacksRestoreTitle, .soundPacksRestoreButton,
        .soundPacksRestoreLabel, .soundPacksRestoreHint, .soundPacksRestoreSelectedMessage,
        .soundPacksRestoreRetryMessage, .soundPacksRestoreAllMessage, .soundPacksLibraryLoading,
        .soundPacksLibraryRefreshing, .soundPacksLibraryRefreshFailed, .soundPacksLibraryRetryLabel,
        .soundPacksLibraryRetryHint, .soundPacksSidebarTitle, .soundPacksSidebarStars,
        .soundPacksSidebarLabel, .soundPacksSidebarViewing, .soundPacksSidebarNone,
        .soundPacksSidebarHint, .soundPacksCardHint, .soundPacksStarPin, .soundPacksStarUnpin,
        .soundPacksStarPinHint, .soundPacksStarUnpinHint, .soundPacksStarPinned,
        .soundPacksStarUnpinned, .soundPacksUsing, .soundPacksAudioLoading,
        .soundPacksAudioLoadingLabel, .soundPacksBuiltinBadge, .soundPacksBuiltinLabel,
        .soundPacksReveal, .soundPacksRevealLabel, .soundPacksRevealHint, .soundPacksRestore,
        .soundPacksRestorePackLabel, .soundPacksBuiltinValue, .soundPacksRestorePackHint,
        .soundPacksCopy, .soundPacksCopyLabel, .soundPacksOriginalReadonly,
        .soundPacksAddAudio, .soundPacksAddingAudio, .soundPacksWritingChanges,
        .soundPacksAddAudioLabel,
        .soundPacksImporting, .soundPacksAddAudioHint,
        .soundPacksPackDelete, .soundPacksPackDeleteTitle, .soundPacksPackDeleteMessage,
        .soundPacksPackDeleteLabel, .soundPacksPackDeleteHint,
        .soundPacksPackDeleteActive, .soundPacksPackDeleteAvailable,
        .soundPacksPackDeleteNoSelection, .soundPacksPackDeleteSelectionChanged,
        .soundPacksPackDeleteUnsafeID, .soundPacksPackDeleteBuiltin,
        .soundPacksPackDeleteErrorActive, .soundPacksPackDeleteConfigUnavailable,
        .soundPacksPackDeleteNotFound, .soundPacksPackDeleteUnsafeEntry,
        .soundPacksPackDeleteFailed, .soundPacksPackDeleteIsolationRetained,
        .soundPacksPackDeleteTrashRetained, .soundPacksPackDeleteLockBusy,
        .soundPacksPackDeleteLockFailed,
        .soundPacksUse, .soundPacksUseLabel,
        .soundPacksUseValue, .soundPacksUseHint, .soundPacksEmptyLoadingMessage,
        .soundPacksEmptyLoadFailedMessage, .soundPacksEmptyFactoryMessage,
        .soundPacksEmptyRestore, .soundPacksEmptyRestoreLabel, .soundPacksEmptyRestoreValue,
        .soundPacksEmptyRestoreHint, .soundPacksEmptyNoFactoryMessage, .soundPacksEmptyReveal,
        .soundPacksEmptyRevealLabel, .soundPacksEmptyRevealHint, .soundPacksRetryRestore,
        .soundPacksRetryRestoreLabel, .soundPacksRetryRestoreValue, .soundPacksRetryRestoreHint,
        .soundPacksPreview, .soundPacksPreviewLabel, .soundPacksExistingFiles,
        .soundPacksEmptyAudio, .soundPacksChooseBind, .soundPacksChooseBindLabel,
        .soundPacksChooseBindHint, .soundPacksClearBinding, .soundPacksClearBindingLabel,
        .soundPacksClearBindingHint, .soundPacksRevealMapping, .soundPacksRevealMappingLabel,
        .soundPacksRevealMappingHint, .soundPacksMappingLabel, .soundPacksMappingHint,
        .soundPacksOrphanTitle, .soundPacksOrphanReadonly, .soundPacksOrphanUnused,
        .soundPacksOrphanAssign, .soundPacksOrphanAssignLabel, .soundPacksOrphanAssignValue,
        .soundPacksOrphanAssignHint, .soundPacksOrphanDelete, .soundPacksOrphanDeleteLabel,
        .soundPacksOrphanDeleteValue, .soundPacksOrphanDeleteHint, .soundPacksCoverageUnmapped,
        .soundPacksCoverageBroken, .soundPacksPackActive, .soundPacksPackComplete,
        .soundPacksPackPartial, .soundPacksPackBroken, .soundPacksPackManifestIdentityMismatch,
        .soundPacksPackModified,
        .soundPacksPanelVisible, .soundPacksPackNotUsed, .soundPacksEventPresent,
        .soundPacksEventUnmapped, .soundPacksEventBroken, .soundPacksOperationFailed,
        .soundPacksActionFailed, .soundPacksAnnouncementWindowLoading,
        .soundPacksAnnouncementWindowFailure, .soundPacksAnnouncementWindowEmpty,
        .soundPacksAnnouncementWindowSelected, .soundPacksAnnouncementWindowUnselected,
        .soundPacksAnnouncementLibraryLoading, .soundPacksAnnouncementLibraryRefreshing,
        .soundPacksAnnouncementLibraryLoadFailed, .soundPacksAnnouncementLibraryRefreshFailed,
        .soundPacksAnnouncementLibraryReadyEmpty, .soundPacksAnnouncementLibraryReadyCount,
        .soundPacksAnnouncementSelectionNone, .soundPacksAnnouncementSelectionSelected,
        .soundPacksAudioErrorNoSelectedPack, .soundPacksAudioErrorSelectionChanged,
        .soundPacksAudioErrorBuiltinReadOnly, .soundPacksAudioErrorNotInInventory,
        .soundPacksBindErrorPackNotFound, .soundPacksBindErrorUnsafeFileName,
        .soundPacksBindErrorFileNotFound, .soundPacksBindErrorManifestUnreadable,
        .soundPacksBindErrorWriteFailed, .soundPacksBindErrorLockBusy,
        .soundPacksBindErrorLockFailed, .soundPacksDeleteErrorBuiltinReadOnly,
        .soundPacksDeleteErrorPackNotFound, .soundPacksDeleteErrorManifestUnreadable,
        .soundPacksDeleteErrorDirectoryUnreadable, .soundPacksDeleteErrorUnsafeFileName,
        .soundPacksDeleteErrorFileNotFound, .soundPacksDeleteErrorStillReferenced,
        .soundPacksDeleteErrorFailed, .soundPacksDeleteErrorLockBusy,
        .soundPacksDeleteErrorLockFailed, .soundPacksInventoryPackNotFound,
        .soundPacksInventoryManifestUnreadable, .soundPacksInventoryDirectoryUnreadable,
        .soundPacksMissingCount, .soundPacksFileMissing, .soundPacksBuiltinCopyExplanation,
        .soundPacksBuiltinCopyHelp, .soundPacksCanChooseFile, .soundPacksStatusBackground,
        .soundPacksStatusAddAudio, .soundPacksStatusUpdateStars,
        .soundPacksStatusRestoreBuiltins, .soundPacksStatusRestoreFactory,
        .soundPacksStatusCopyPack, .soundPacksStatusUsePack, .soundPacksStatusDeletePack,
        .soundPacksStatusAudioImported, .soundPacksStatusAudioPartial,
        .soundPacksStatusBatchRestored, .soundPacksStatusBatchRestoredWithSalvage,
        .soundPacksStatusBatchPartial, .soundPacksStatusBatchPartialWithSalvage,
        .soundPacksStatusFactoryRestored, .soundPacksStatusFactoryRestoredWithSalvage,
        .soundPacksStatusPackCopied, .soundPacksStatusPackUsed,
        .soundPacksStatusPackTrashed,
        .hostReady, .hostConfigured, .hostLegacy, .hostNotConnected, .hostNeedsAttention,
        .hostCodexReadyDetail, .hostCodexAwaitingDetail,
        .hostClaudeAwaitingDetail, .hostClaudeLegacyDetail, .hostCodexLegacyDetail,
        .hostWorkBuddyReadyDetail, .hostWorkBuddyAwaitingDetail,
        .hostWorkBuddyConflictDetail,
        .qualificationAccessibilityBetaUnavailable,
        .panelSoundScope, .panelSoundScopeInheritanceCaption, .panelSoundScopeExpandHint,
        .panelSoundScopeCollapseHint, .panelSoundScopeGlobalCoverage,
        .panelSoundScopeStatusDefault, .panelSoundScopeStatusActive,
        .panelSoundScopeStatusAwaitingReceipt, .panelSoundScopeStatusLegacy,
        .panelSoundScopeStatusNotConnected, .panelSoundScopeStatusNeedsAttention,
        .panelEventsTitle, .panelEventsMappable,
        .panelGlobalDefaults, .panelGlobalName, .panelGlobalStatus,
        .panelResetSurface, .panelResetSurfaceHint,
        .eventTaskStart, .eventStop, .eventStopFailure, .eventNotification, .eventSubagentStop,
        .eventEditorHint, .eventCoveragePresent, .eventCoverageUnmapped, .eventCoverageBroken,
        .eventCoveragePresentFile, .eventCoverageBrokenFile, .eventPreviewLabel,
        .eventPreviewAvailableEnabled, .eventPreviewAvailableMuted, .eventPreviewUnavailable,
        .eventMuteHint, .eventMute, .eventUnmute, .eventEnabled, .eventMuted, .eventPreviewHint,
        .eventPreviewMasterVolumeZero, .eventPreviewUnmapped, .eventPreviewMissing,
        .eventPreviewUnsafe,
        .cellAudible, .cellMuted, .cellMasterVolumeZero, .cellMissingSound, .cellNotConnected,
        .cellAwaitingActivation, .cellLegacy, .cellUnsupported, .cellDegraded,
        .hostPlaybackPlayed, .hostPlaybackMuted, .hostPlaybackDebounced, .hostPlaybackNotReady,
        .hostPlaybackUnsupported, .hostPlaybackFailed, .actionCopyHooks, .actionCopyHooksHint,
        .actionRedetect, .actionRedetectHint, .actionConnect, .actionConnectHint,
        .actionUpgrade, .actionUpgradeHint, .actionRepair, .actionRepairHint,
        .actionDisconnect, .actionDisconnectHint, .actionClearReceiptHistory,
        .actionClearReceiptHistoryHint, .actionUnmute, .actionUnmuteHint,
        .actionConfigureSound, .actionConfigureSoundHint, .integrationsDisconnectConfirm,
        .integrationsDisconnectTitle, .integrationsDisconnectHint, .integrationsDisconnectMessage,
        .integrationsCopyPathLabel,
        .integrationsNoReceipt, .integrationsMasterVolumeZero, .integrationsUnsupported,
        .integrationsStoreUnavailable, .integrationsRecoveryUnavailable,
        .integrationsMuteFallbackFailed, .integrationsManagerProvidedSource,
        .actionRedetectInProgress, .actionConnectInProgress, .actionUpgradeInProgress,
        .actionRepairInProgress, .actionDisconnectInProgress,
        .actionClearReceiptHistoryInProgress, .integrationsClearReceiptHistoryConfirm,
        .integrationsClearReceiptHistoryTitle, .integrationsClearReceiptHistoryMessage,
        .onboardingClaudeCodeNotInstalledTitle, .onboardingClaudeCodeNotInstalledBody,
        .onboardingHelperMissingTitle, .onboardingHelperMissingBody,
        .onboardingSettingsNotWritableTitle, .onboardingSettingsNotWritableBody,
        .onboardingSettingsParseFailureTitle, .onboardingSettingsParseFailureBody,
        .onboardingNotInstalledTitle, .onboardingNotInstalledBody,
        .onboardingInstalledTitle, .onboardingInstalledBody,
        .onboardingActionRedetect, .onboardingActionRepair, .onboardingActionTakeOver,
        .onboardingActionDisconnect, .onboardingActionRevealReason,
        .onboardingReasonExpand, .onboardingReasonCollapse,
        .onboardingActionRunningTakeOver, .onboardingActionRunningDisconnect,
        .onboardingFailureHelperUnavailable, .onboardingFailureSetup,
        .onboardingFailureDisconnect, .onboardingFailureDisconnectNothing,
        .onboardingNoticeSalvaged, .onboardingNoticeRepaired,
        .feedbackRedetectedSources, .feedbackCopyHooksSucceeded, .feedbackCopyHooksFailed,
        .feedbackMuteCancelled, .feedbackOpenSoundMapping,
        .feedbackCopyConfigurationPathSucceeded, .feedbackCopyConfigurationPathFailed,
        .feedbackOperationFailed, .feedbackReceipt, .feedbackDisconnected,
        .feedbackConnectedReceipt, .feedbackAwaitingConfirmation, .feedbackRepairedWaiting,
        .feedbackConfiguredWaiting, .feedbackHostStateUpdated, .feedbackReceiptHistoryCleared,
        .settingsUsageDescription, .settingsUsageScopeNotice, .settingsUsageRefresh,
        .settingsUsageHistoryTitle, .settingsUsageSurfaceCount, .settingsUsageHistoryNone,
        .settingsUsageHistoryMissing, .settingsUsageHistoryDamaged,
        .settingsUsageHistoryUnreadable, .settingsUsageResultCount, .settingsUsageLogTitle,
        .settingsUsageLogDescription, .settingsUsageLogAvailable, .settingsUsageLogMissing,
        .settingsUsageLogDamaged, .settingsUsageLogUnreadable,
        .settingsUsageLogNoFailures, .settingsUsageLogFailurePlaybackLaunch,
        .settingsUsageLogFailurePlaybackLock, .settingsUsageLogFailureReceiptWrite,
        .settingsUsageLogFailureOther, .settingsUsageLogFailureUnknownEvent,
        .settingsUsageLogFailureSummary, .settingsUsageRevealLog,
        .settingsUsageCopyLogPath, .settingsUsageClearHistory, .settingsUsageClearLog,
        .settingsUsageClearHistoryTitle, .settingsUsageClearHistoryMessage,
        .settingsUsageClearLogTitle, .settingsUsageClearLogMessage,
        .settingsUsagePrivacyTitle, .settingsUsagePrivacyHost,
        .settingsUsagePrivacyProvider, .settingsUsagePrivacyBilling,
        .settingsUsageProviderDisclosure, .settingsUsageActionInProgress,
        .settingsUsageActionHistoryCleared, .settingsUsageActionLogCleared,
        .settingsUsageActionLogRevealed, .settingsUsageActionLogPathCopied,
        .settingsUsageFailureHistoryLockBusy, .settingsUsageFailureLogLockBusy,
        .settingsUsageFailureHistoryClear, .settingsUsageFailureLogClear,
        .settingsUsageFailureFinder, .settingsUsageFailureClipboard,
    ]
}

private struct CatalogEntry {
    let strings: [String: String]
    let plurals: [String: [String: String]]
}

private final class CatalogCache: @unchecked Sendable {
    static let shared = CatalogCache()

    private let lock = NSLock()
    private var values: [String: [String: CatalogEntry]] = [:]

    func value(for bundle: Bundle, load: () -> [String: CatalogEntry]) -> [String: CatalogEntry] {
        let key = bundle.bundleURL.path
        lock.lock()
        if let cached = values[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let loaded = load()
        lock.lock()
        values[key] = loaded
        lock.unlock()
        return loaded
    }
}

private struct CatalogDocument: Decodable {
    let strings: [String: CatalogEntry]

    enum CodingKeys: String, CodingKey {
        case strings
    }
}

private struct CatalogEntryDecoder: Decodable {
    let localizations: [String: LocalizationValue]

    enum CodingKeys: String, CodingKey {
        case localizations
    }
}

private struct LocalizationValue: Decodable {
    let stringUnit: StringUnit?
    let variations: Variations?

    enum CodingKeys: String, CodingKey {
        case stringUnit
        case variations
    }
}

private struct StringUnit: Decodable {
    let value: String
}

private struct Variations: Decodable {
    let plural: [String: LocalizationValue]?

    enum CodingKeys: String, CodingKey {
        case plural
    }
}

extension CatalogEntry: Decodable {
    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CatalogEntryDecoder.CodingKeys.self)
        let localizations = try value.decode(
            [String: LocalizationValue].self,
            forKey: .localizations)
        var strings: [String: String] = [:]
        var plurals: [String: [String: String]] = [:]
        for (language, localization) in localizations {
            if let stringUnit = localization.stringUnit {
                strings[language] = stringUnit.value
            }
            if let plural = localization.variations?.plural {
                plurals[language] = plural.compactMapValues { $0.stringUnit?.value }
            }
        }
        self.strings = strings
        self.plurals = plurals
    }
}

/// Explicit catalog lookup and formatting. The language is an input to every lookup, which keeps
/// tests and retained windows independent of `Locale.current` and `AppleLanguages`.
public struct ClaudioL10n {
    public let language: ClaudioAppLanguage

    private let entries: [String: CatalogEntry]
    private let bundle: Bundle

    public init(
        language: ClaudioAppLanguage,
        bundle: Bundle = ClaudioLocalizationBundleLocator.bundle()
    ) {
        self.language = language
        self.bundle = bundle
        entries = Self.loadEntries(from: bundle)
    }

    public func text(_ key: ClaudioL10nKey) -> String {
        resolve(key.rawValue, pluralCategory: nil)
    }

    public func format(_ key: ClaudioL10nKey, _ arguments: CVarArg...) -> String {
        let value = resolve(key.rawValue, pluralCategory: nil)
        return String(
            format: value, locale: Locale(identifier: language.rawValue), arguments: arguments)
    }

    public func format(_ key: ClaudioL10nKey, arguments: [String]) -> String {
        let value = resolve(key.rawValue, pluralCategory: nil)
        return String(
            format: value,
            locale: Locale(identifier: language.rawValue),
            arguments: arguments.map { $0 as NSString })
    }

    public func plural(_ key: ClaudioL10nKey, count: Int) -> String {
        let value = resolve(
            key.rawValue,
            pluralCategory: count == 1 ? "one" : "other")
        return String(
            format: value,
            locale: Locale(identifier: language.rawValue),
            arguments: [Int64(count)])
    }

    /// Returns the exact catalog values known for a key. This is used by the harness to verify
    /// that every source-language entry has an English counterpart without making fallback look
    /// like a successful translation.
    public static func catalogValues(
        bundle: Bundle = ClaudioLocalizationBundleLocator.bundle()
    ) -> [String: [String: String]] {
        loadEntries(from: bundle).mapValues { entry in
            entry.strings
        }
    }

    public static func catalogPluralValues(
        bundle: Bundle = ClaudioLocalizationBundleLocator.bundle()
    ) -> [String: [String: [String: String]]] {
        loadEntries(from: bundle).mapValues { entry in
            entry.plurals
        }
    }

    public static func missingEnglishKeys(
        bundle: Bundle = ClaudioLocalizationBundleLocator.bundle()
    ) -> [String] {
        loadEntries(from: bundle).compactMap { key, entry in
            entry.strings[ClaudioAppLanguage.english.rawValue] == nil
                && entry.plurals[ClaudioAppLanguage.english.rawValue] == nil
                ? key : nil
        }.sorted()
    }

    private func resolve(_ key: String, pluralCategory: String?) -> String {
        guard let entry = entries[key] else {
            return missingValue(for: key)
        }

        let languageKey = language.rawValue
        if let pluralCategory,
            let localizedPlurals = entry.plurals[languageKey]
        {
            if let value = localizedPlurals[pluralCategory] {
                return value
            }
            if let value = localizedPlurals["other"] {
                return value
            }
        }
        if let value = entry.strings[languageKey] {
            return value
        }

        // English intentionally fails closed to Simplified Chinese when a translation is not
        // present. Tests still expose the omission through `missingEnglishKeys`.
        if let pluralCategory,
            let defaultPlurals = entry.plurals[ClaudioAppLanguage.defaultValue.rawValue]
        {
            if let value = defaultPlurals[pluralCategory] {
                return value
            }
            if let value = defaultPlurals["other"] {
                return value
            }
        }
        return entry.strings[ClaudioAppLanguage.defaultValue.rawValue] ?? missingValue(for: key)
    }

    private func missingValue(for key: String) -> String {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLAUDIO_LOCALIZATION_STRICT"] == "1" {
            assertionFailure("Missing Claudio localization key: \(key)")
        }
        #endif
        return key
    }

    private static func loadEntries(from bundle: Bundle) -> [String: CatalogEntry] {
        CatalogCache.shared.value(for: bundle) {
            loadEntriesUncached(from: bundle)
        }
    }

    private static func loadEntriesUncached(from bundle: Bundle) -> [String: CatalogEntry] {
        guard let url = bundle.url(forResource: "Localizable", withExtension: "xcstrings"),
            let data = try? Data(contentsOf: url)
        else {
            return [:]
        }

        // The catalog's nested value objects are small and stable; decoding them through a
        // keyed wrapper keeps this parser independent from Foundation's implicit locale lookup.
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any],
            let rawStrings = root["strings"] as? [String: [String: Any]]
        else {
            return [:]
        }

        var result: [String: CatalogEntry] = [:]
        for (key, rawEntry) in rawStrings {
            guard let localizations = rawEntry["localizations"] as? [String: [String: Any]] else {
                continue
            }
            var strings: [String: String] = [:]
            var plurals: [String: [String: String]] = [:]
            for (language, rawLocalization) in localizations {
                if let unit = rawLocalization["stringUnit"] as? [String: Any],
                    let value = unit["value"] as? String
                {
                    strings[language] = value
                }
                if let variations = rawLocalization["variations"] as? [String: Any],
                    let plural = variations["plural"] as? [String: [String: Any]]
                {
                    plurals[language] = plural.compactMapValues { variation in
                        (variation["stringUnit"] as? [String: Any])?["value"] as? String
                    }
                }
            }
            result[key] = CatalogEntry(strings: strings, plurals: plurals)
        }
        return result
    }
}
