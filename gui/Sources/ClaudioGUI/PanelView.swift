import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// 菜单栏 Agent 集成面板。生产树只呈现一个当前作用域的五行事件与两行播放设置；
/// 连接/诊断和完整声音编辑继续由两个 retained window 负责。
public struct PanelView: View {
    @StateObject private var announcer: PanelAnnouncer
    @StateObject private var panelModel: PanelConfigController
    @FocusState private var focusedTarget: PanelFocusTarget?

    @ObservedObject private var focusCoordinator: PanelFocusCoordinator
    @ObservedObject private var hostIntegrations: HostIntegrationPresentationStore
    @ObservedObject private var bootstrapReports: BootstrapReportPresentationStore
    @ObservedObject private var languageStore: ClaudioLanguageStore

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ClaudioInterfaceTextSize.defaultsKey)
    private var interfaceTextSizeRaw = ClaudioInterfaceTextSize.defaultValue.rawValue
    /// `unselected` 只表示从未选择；用户显式选过 Global 后持久化为 `global`。
    @AppStorage("claudio.panel.selected-surface")
    private var selectedSurfaceRaw = "unselected"

    private let audioEnvironment: AudioImportEnvironment
    private let configFile: URL
    private let previewPlayer: AudioPreviewPlaying
    private let onManageSounds: @MainActor (SoundPacksWindowRoute, PanelFocusTarget) -> Void
    private let onManageIntegrations: @MainActor (HostID?, PanelFocusTarget) -> Void
    private let onRetryBootstrap: @MainActor () -> Void
    private let onAudibilityInputsChanged: @MainActor () -> Void
    private let onQuit: @MainActor () -> Void
    private let onPanelWidthChange: (Double) -> Void

    public init(
        audioEnvironment: AudioImportEnvironment,
        configFile: URL = ClaudioPaths.configFile,
        lockFile: URL = ClaudioPaths.configLockFile,
        focusCoordinator: PanelFocusCoordinator = PanelFocusCoordinator(),
        hostIntegrations: HostIntegrationPresentationStore,
        bootstrapReports: BootstrapReportPresentationStore,
        languageStore: ClaudioLanguageStore,
        soundPackLibrary: SoundPackLibrary,
        soundPacksRefreshCoordinator: SoundPacksRefreshCoordinator,
        onManageSounds: @escaping @MainActor (SoundPacksWindowRoute, PanelFocusTarget) -> Void,
        onManageIntegrations: @escaping @MainActor (HostID?, PanelFocusTarget) -> Void,
        onRetryBootstrap: @escaping @MainActor () -> Void,
        onAudibilityInputsChanged: @escaping @MainActor () -> Void,
        onQuit: @escaping @MainActor () -> Void,
        onPanelWidthChange: @escaping (Double) -> Void = { _ in }
    ) {
        self.audioEnvironment = audioEnvironment
        self.configFile = configFile
        self.focusCoordinator = focusCoordinator
        self.hostIntegrations = hostIntegrations
        self.bootstrapReports = bootstrapReports
        self.languageStore = languageStore
        self.onManageSounds = onManageSounds
        self.onManageIntegrations = onManageIntegrations
        self.onRetryBootstrap = onRetryBootstrap
        self.onAudibilityInputsChanged = onAudibilityInputsChanged
        self.onQuit = onQuit
        self.onPanelWidthChange = onPanelWidthChange
        previewPlayer = NSSoundAudioPreviewPlayer()

        let inputsChanged = onAudibilityInputsChanged
        _announcer = StateObject(wrappedValue: PanelAnnouncer())
        _panelModel = StateObject(
            wrappedValue: PanelConfigController(
                configFile: configFile,
                lockFile: lockFile,
                environment: audioEnvironment,
                soundPackLibrary: soundPackLibrary,
                afterFullReload: { _ in inputsChanged() },
                soundPacksRefreshCoordinator: soundPacksRefreshCoordinator))
    }

    #if DEBUG
    /// Deterministic production-composition initializer used only by the state gallery. The
    /// injected model owns every visible state; callbacks are inert and AppStorage keys are unique
    /// so frames cannot change the user's real panel preferences or each other.
    init(
        previewPanelModel: PanelConfigController,
        previewScope: PanelSoundScopeID,
        previewTextSize: ClaudioInterfaceTextSize,
        audioEnvironment: AudioImportEnvironment,
        focusCoordinator: PanelFocusCoordinator,
        hostIntegrations: HostIntegrationPresentationStore,
        bootstrapReports: BootstrapReportPresentationStore,
        languageStore: ClaudioLanguageStore
    ) {
        let previewKey = UUID().uuidString
        let defaults = UserDefaults(suiteName: "com.orbitzero.claudio.state-gallery")!
        _interfaceTextSizeRaw = AppStorage(
            wrappedValue: previewTextSize.rawValue,
            "claudio.preview.text-size.\(previewKey)",
            store: defaults)
        _selectedSurfaceRaw = AppStorage(
            wrappedValue: previewScope.storedValue,
            "claudio.preview.selected-surface.\(previewKey)",
            store: defaults)
        _announcer = StateObject(wrappedValue: PanelAnnouncer())
        _panelModel = StateObject(wrappedValue: previewPanelModel)
        self.audioEnvironment = audioEnvironment
        self.configFile = URL(fileURLWithPath: "/dev/null/claudio-panel-preview-config.json")
        self.focusCoordinator = focusCoordinator
        self.hostIntegrations = hostIntegrations
        self.bootstrapReports = bootstrapReports
        self.languageStore = languageStore
        self.previewPlayer = NSSoundAudioPreviewPlayer()
        self.onManageSounds = { _, _ in }
        self.onManageIntegrations = { _, _ in }
        self.onRetryBootstrap = {}
        self.onAudibilityInputsChanged = {}
        self.onQuit = {}
        self.onPanelWidthChange = { _ in }
    }
    #endif

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    soundScopeMenu
                    bootstrapReportSection
                    mainContent
                    writeFailures
                }
                .padding(13)
            }
            PanelQuitFooter(
                language: languageStore.language,
                typeScale: typeScale,
                focusedTarget: $focusedTarget,
                onQuit: onQuit)
        }
        .frame(width: layoutAdaptation.panelWidth)
        .background(ClaudioTheme.panelGradient(colorScheme))
        .overlay(
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.panel)
                .strokeBorder(ClaudioTheme.hairline(colorScheme), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.panel))
        .environment(\.dynamicTypeSize, interfaceTextSize.dynamicTypeSize)
        .onAppear {
            synchronizeSelectedSoundSurface()
            applyFirstFocus()
            onPanelWidthChange(layoutAdaptation.panelWidth)
        }
        .onChange(of: focusCoordinator.showCount) { _ in
            panelModel.reload()
            synchronizeSelectedSoundSurface()
            applyFirstFocus()
            announcePanelSummary()
        }
        .onChange(of: hostIntegrations.content.sourceRows) { _ in
            synchronizeSelectedSoundSurface()
            applyFirstFocus()
        }
        .onChange(of: bootstrapReports.records) { _ in
            guard focusCoordinator.showCount > focusCoordinator.hideCount else { return }
            applyFirstFocus()
            announcePanelSummary()
        }
        .onChange(of: panelModel.libraryPresentationState) { _ in
            if isEventFocusTarget(focusedTarget) { applyFirstFocus() }
        }
        .onChange(of: layoutAdaptation.panelWidth) { width in
            onPanelWidthChange(width)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(headerAccessibilityLabel)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center) {
                ClaudioOrbitWordmark(height: 22 * typeScale)
                Spacer(minLength: 8)
                InterfaceTextSizeControl(
                    selection: interfaceTextSizeBinding,
                    languageStore: languageStore)
            }
            Text(headerSummary)
                .font(.system(size: 11 * typeScale, design: .rounded))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityLabel(headerAccessibilityLabel)
    }

    private var headerSummary: String {
        let pack = selectedPackDisplayName.isEmpty
            ? l10n.text(.panelSelectedPackNone) : selectedPackDisplayName
        return l10n.format(.panelHeaderSummary, pack, Int64(publishedSurfaceCount))
    }

    private var headerAccessibilityLabel: String {
        l10n.text(.panelTitle)
            + (languageStore.language == .english ? ", " : "，")
            + headerSummary
    }

    private func announcePanelSummary() {
        let announcer = self.announcer
        let coordinator = focusCoordinator
        let hideCount = coordinator.hideCount
        let summary = headerAccessibilityLabel
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard coordinator.hideCount == hideCount,
                    let sentence = announcer.consume(summary, openCount: coordinator.showCount)
                else { return }
                NSAccessibility.post(
                    element: NSApp as Any,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: sentence,
                        .priority: NSAccessibilityPriorityLevel.high.rawValue,
                    ])
            }
        }
    }

    // MARK: - Sound scope

    private var soundScopePresentations: [PanelSoundScopePresentation] {
        panelSoundScopePresentations(
            sourceRows: hostIntegrations.content.sourceRows,
            config: panelModel.config,
            language: languageStore.language)
    }

    private var selectedScope: PanelSoundScopePresentation {
        let resolved = resolvedPanelSoundScopeSelection(
            storedValue: selectedSurfaceRaw,
            scopes: soundScopePresentations)
        return soundScopePresentations.first(where: { $0.scope == resolved })
            ?? soundScopePresentations[0]
    }

    private var publishedSurfaceCount: Int {
        max(0, soundScopePresentations.count - 1)
    }

    private var soundScopeMenu: some View {
        Menu {
            ForEach(soundScopePresentations) { scope in
                Button {
                    selectSoundScope(scope.scope)
                } label: {
                    HStack {
                        Label(scope.name, systemImage: statusSymbol(scope.status))
                        Text(scope.compactStatusText)
                        if scope.scope == selectedScope.scope {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .accessibilityLabel(scope.accessibilityLabel)
                .accessibilityIdentifier("panel.sound-scope.item.\(scope.scope.storedValue)")
            }
            Divider()
            Button {
                onManageIntegrations(diagnosticsHost, .soundScope)
            } label: {
                Label(l10n.text(.panelConnectionsDiagnostics), systemImage: "stethoscope")
            }
            .accessibilityLabel(l10n.text(.panelConnectionsDiagnostics))
            .accessibilityIdentifier("panel.sound-scope.integrations")
        } label: {
            HStack(spacing: 9) {
                Image(systemName: statusSymbol(selectedScope.status))
                    .foregroundColor(statusColor(selectedScope.status))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedScope.name)
                        .font(.system(size: 12.5 * typeScale, weight: .semibold, design: .rounded))
                        .foregroundColor(ClaudioTheme.text(colorScheme))
                    Text(selectedScope.compactStatusText)
                        .font(.system(size: 10.5 * typeScale, design: .rounded))
                        .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10 * typeScale, weight: .semibold))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ClaudioTheme.elevated(colorScheme))
            .overlay(
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control)
                    .strokeBorder(ClaudioTheme.hairline(colorScheme), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .focused($focusedTarget, equals: .soundScope)
        .accessibilityLabel(l10n.text(.panelSoundScope))
        .accessibilityValue(selectedScope.accessibilityLabel)
        .accessibilityIdentifier("panel.sound-scope")
    }

    private var diagnosticsHost: HostID? {
        selectedScope.host ?? soundScopePresentations.first(where: { $0.host != nil })?.host
    }

    private func selectSoundScope(_ scope: PanelSoundScopeID) {
        selectedSurfaceRaw = scope.storedValue
        panelModel.selectSoundSurface(scope.surface)
        applyFirstFocus()
    }

    private func synchronizeSelectedSoundSurface() {
        let resolved = resolvedPanelSoundScopeSelection(
            storedValue: selectedSurfaceRaw,
            scopes: soundScopePresentations)
        if let storedValue = panelSoundScopeStoredValueToPersist(
            storedValue: selectedSurfaceRaw,
            resolvedSelection: resolved),
            selectedSurfaceRaw != storedValue
        {
            selectedSurfaceRaw = storedValue
        }
        panelModel.selectSoundSurface(resolved.surface)
    }

    private func statusSymbol(_ status: HostSourceRowStatus) -> String {
        switch status {
        case .ready: "checkmark.circle.fill"
        case .awaitingActivation: "clock.fill"
        case .legacy: "arrow.triangle.2.circlepath.circle.fill"
        case .notConnected: "minus.circle"
        case .needsAttention: "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(_ status: HostSourceRowStatus) -> Color {
        switch status {
        case .ready: ClaudioTheme.success(colorScheme)
        case .awaitingActivation, .legacy: ClaudioColor.warning(colorScheme)
        case .notConnected: ClaudioTheme.secondaryText(colorScheme)
        case .needsAttention: ClaudioTheme.error(colorScheme)
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private var mainContent: some View {
        switch panelModel.configState.topContent {
        case .events:
            if panelModel.libraryPresentationState.hasUsableSnapshot {
                eventSection
            } else {
                libraryUnavailableSection
            }
            playbackSettings(masterVolumeEnabled: panelModel.libraryPresentationState.hasUsableSnapshot)
        case .needsPack:
            needsPackNotice
            playbackSettings(masterVolumeEnabled: false)
        case .configFailure(let reason):
            configFailureNotice(reason: reason)
        }
    }

    private var eventPresentations: [PanelEventPresentation] {
        panelEventPresentations(
            rows: panelModel.eventRows,
            scope: selectedScope.scope,
            masterVolume: panelModel.config.masterVolume,
            language: languageStore.language,
            configWritesAllowed: panelModel.surfaceSoundIssue == nil)
    }

    private var eventSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(l10n.text(.panelEvents))
                .font(.system(size: 11 * typeScale, weight: .semibold, design: .rounded))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .padding(.bottom, 4)
            ForEach(Array(eventPresentations.enumerated()), id: \.element.id) { index, event in
                PanelAgentEventRow(
                    presentation: event,
                    adaptation: layoutAdaptation,
                    language: languageStore.language,
                    focusedTarget: $focusedTarget,
                    onPreview: {
                        guard let row = panelModel.eventRows.first(where: { $0.event == event.event })
                        else { return }
                        playPreview(for: row)
                    },
                    onToggleMute: {
                        panelModel.toggleMute(event.event)
                        onAudibilityInputsChanged()
                    })
                if index < eventPresentations.count - 1 {
                    Divider().opacity(0.65)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel.events.single-scope")
    }

    @ViewBuilder
    private var libraryUnavailableSection: some View {
        switch panelModel.libraryPresentationState {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text(l10n.text(.panelLoadingEvents))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            }
            .accessibilityIdentifier("panel.events.loading")
        case .loadFailed(let reason):
            VStack(alignment: .leading, spacing: 7) {
                FailureRow(message: reason)
                Button(l10n.text(.panelRetry)) {
                    panelModel.retrySoundPackLibraryRefresh()
                }
                .focused($focusedTarget, equals: .bootstrapReportRetry(id: "library"))
                .accessibilityLabel(l10n.text(.panelRetry))
                .accessibilityIdentifier("panel.library.retry")
            }
        case .ready, .refreshing, .refreshFailed:
            EmptyView()
        }
    }

    private var needsPackNotice: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(l10n.text(.panelSelectPack), systemImage: "speaker.slash")
                .font(.system(size: 12 * typeScale, weight: .semibold, design: .rounded))
                .foregroundColor(ClaudioTheme.text(colorScheme))
            Text(l10n.text(.panelNeedsPackSettingsMessage))
                .font(.system(size: 11 * typeScale, design: .rounded))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .background(ClaudioTheme.elevated(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control))
        .accessibilityIdentifier("panel.needs-pack")
    }

    private func configFailureNotice(reason: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            FailureRow(message: reason)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([configFile])
            } label: {
                Label(l10n.text(.panelRevealConfig), systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .focused($focusedTarget, equals: .configReveal)
            .accessibilityLabel(l10n.text(.panelRevealConfig))
            .accessibilityHint(l10n.text(.panelRevealConfigHint))
            .accessibilityIdentifier("panel.reveal-config")
        }
        .accessibilityIdentifier("panel.config-failure")
    }

    // MARK: - Playback settings

    private func playbackSettings(masterVolumeEnabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(l10n.text(.panelPlaybackSettings))
                .font(.system(size: 11 * typeScale, weight: .semibold, design: .rounded))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            VStack(spacing: 0) {
                MasterVolumeRow(
                    diskVolume: panelModel.config.masterVolume,
                    isEnabled: masterVolumeEnabled,
                    onCommit: { volume in
                        let landed = panelModel.setMasterVolume(volume)
                        onAudibilityInputsChanged()
                        return landed
                    },
                    focusCoordinator: focusCoordinator,
                    focusedTarget: $focusedTarget,
                    adaptation: layoutAdaptation,
                    language: languageStore.language)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                Divider().padding(.leading, 9)
                soundPackSettingsRow
                    .padding(.horizontal, 9)
                    .padding(.vertical, 8)
            }
            .background(ClaudioTheme.elevated(colorScheme))
            .overlay(
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control)
                    .strokeBorder(ClaudioTheme.hairline(colorScheme), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel.playback-settings")
    }

    private var soundPackSettingsRow: some View {
        Group {
            if layoutAdaptation.rowWrapsToTwoLines {
                VStack(alignment: .leading, spacing: 7) {
                    soundPackIdentity
                    soundPackActions
                }
            } else {
                HStack(alignment: .center, spacing: 8) {
                    soundPackIdentity
                    Spacer(minLength: 6)
                    soundPackActions
                }
            }
        }
    }

    private var soundPackIdentity: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(l10n.text(.panelSoundPackLabel))
                .font(.system(size: 12 * typeScale, weight: .medium, design: .rounded))
                .foregroundColor(ClaudioTheme.text(colorScheme))
            Text(selectedPackDisplayName.isEmpty ? l10n.text(.panelSelectedPackNone) : selectedPackDisplayName)
                .font(.system(size: 10.5 * typeScale, design: .rounded))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .lineLimit(layoutAdaptation.rowWrapsToTwoLines ? 2 : 1)
            Text(soundPackInheritanceText)
                .font(.system(size: 9.5 * typeScale, design: .rounded))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var soundPackActions: some View {
        HStack(spacing: 6) {
            Button(l10n.text(.panelOpenSettings)) {
                onManageSounds(
                    .overview(surface: selectedScope.scope.surface),
                    .openSoundSettings)
            }
            .buttonStyle(.bordered)
            .focused($focusedTarget, equals: .openSoundSettings)
            .accessibilityLabel(l10n.text(.panelOpenSettings))
            .accessibilityIdentifier("panel.sound-settings.open")

            if selectedScope.scope.surface != nil {
                Button(l10n.text(.panelResetSurface)) {
                    panelModel.resetSelectedSurfaceOverrides()
                    onAudibilityInputsChanged()
                }
                .buttonStyle(.borderless)
                .focused($focusedTarget, equals: .resetSurface)
                .help(l10n.text(.panelResetSurfaceHint))
                .accessibilityLabel(l10n.text(.panelResetSurface))
                .accessibilityIdentifier("panel.sound-settings.reset-surface")
            }
        }
        .fixedSize(horizontal: !layoutAdaptation.rowWrapsToTwoLines, vertical: false)
    }

    private var soundPackInheritanceText: String {
        guard let surface = selectedScope.scope.surface else {
            return l10n.text(.panelGlobalInheritance)
        }
        let hasPackOverride = panelModel.config.surfaceOverrides[surface.rawValue]?.selectedPack != nil
        if hasPackOverride {
            return l10n.text(.panelSurfaceOverride)
        }
        return l10n.text(.panelInheritedGlobal)
    }

    // MARK: - Bootstrap reports and failures

    @ViewBuilder
    private var bootstrapReportSection: some View {
        if let error = bootstrapReports.acknowledgementError {
            FailureRow(message: error)
        }
        ForEach(bootstrapReports.records, id: \.id) { record in
            let reportID = record.id.uuidString
            let failure = record.events.contains { event in
                if case .failure = event { return true }
                return false
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(bootstrapReportMessage(record))
                    .font(.system(size: 11 * typeScale, weight: .medium))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 7) {
                    if failure {
                        Button(languageStore.language == .english ? "Retry" : "重试") {
                            onRetryBootstrap()
                        }
                        .focused($focusedTarget, equals: .bootstrapReportRetry(id: reportID))
                        .accessibilityLabel(l10n.text(.panelRetry))
                        .accessibilityIdentifier("bootstrap-report.retry")
                        Button(languageStore.language == .english ? "Diagnostics" : "连接与诊断") {
                            onManageIntegrations(.claudeCode, .soundScope)
                        }
                        .focused($focusedTarget, equals: .bootstrapReportDiagnostics(id: reportID))
                        .accessibilityLabel(l10n.text(.panelConnectionsDiagnostics))
                        .accessibilityIdentifier("bootstrap-report.diagnostics")
                    }
                    if let path = bootstrapReportRevealPath(record) {
                        Button(languageStore.language == .english ? "Show in Finder" : "在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                        .focused($focusedTarget, equals: .bootstrapReportReveal(id: reportID))
                        .accessibilityLabel(l10n.text(.panelRevealConfig))
                        .accessibilityIdentifier("bootstrap-report.reveal")
                    }
                    if record.events.contains(where: { if case .selectionChanged = $0 { return true }; return false }) {
                        Button(l10n.text(.panelOpenSettings)) {
                            onManageSounds(
                                .overview(surface: selectedScope.scope.surface),
                                .bootstrapReportManageSounds(id: reportID))
                        }
                        .focused($focusedTarget, equals: .bootstrapReportManageSounds(id: reportID))
                        .accessibilityLabel(l10n.text(.panelOpenSettings))
                        .accessibilityIdentifier("bootstrap-report.manage-sounds")
                    }
                    Spacer(minLength: 0)
                    Button(languageStore.language == .english ? "Got it" : "知道了") {
                        bootstrapReports.acknowledge(record.id)
                    }
                    .focused($focusedTarget, equals: .bootstrapReportAcknowledge(id: reportID))
                    .accessibilityLabel(
                        languageStore.language == .english ? "Got it" : "知道了")
                    .accessibilityIdentifier("bootstrap-report.acknowledge")
                }
                .buttonStyle(.bordered)
            }
            .padding(9)
            .background(
                (failure ? ClaudioTheme.error(colorScheme) : ClaudioColor.warning(colorScheme))
                    .opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(bootstrapReportMessage(record))
        }
    }

    private var writeFailures: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(
                Array(
                    panelWriteFailures(
                        muteError: panelModel.muteError,
                        packSwitchError: panelModel.packSwitchError,
                        masterVolumeError: panelModel.masterVolumeError).enumerated()),
                id: \.offset
            ) { _, message in
                FailureRow(message: message)
            }
            if let issue = localizedSurfaceSoundIssue {
                FailureRow(message: issue)
            }
        }
    }

    private var localizedSurfaceSoundIssue: String? {
        guard let issue = panelModel.surfaceSoundIssue else { return nil }
        guard panelModel.selectedSurfaceProfileIsMalformed,
            let surface = selectedScope.scope.surface
        else { return issue }
        let name = HostID.productVisibleCases.first(where: { $0.surfaceID == surface })?.displayName
            ?? surface.rawValue
        return l10n.format(.panelSurfaceOverrideDamaged, name)
    }

    private func bootstrapReportMessage(_ record: BootstrapReportRecord) -> String {
        let english = languageStore.language == .english
        let messages = record.events.map { event -> String in
            switch event {
            case .failure(let code):
                return english ? "Startup repair failed (\(code))." : "启动修复失败（\(code)）。"
            case .helperCopied:
                return english ? "The helper was installed." : "helper 已完成安装。"
            case .packPublished(let packID):
                return english ? "Installed sound pack \(packID)." : "已发布声音包 \(packID)。"
            case .packSalvaged(let packID, let movedTo):
                return english
                    ? "Moved unreadable pack \(packID) to \(movedTo); no files were deleted."
                    : "无法读取的声音包 \(packID) 已搬到 \(movedTo)，没有删除任何文件。"
            case .selectionChanged(let removed, let selected):
                if let removed {
                    return english
                        ? "The missing selection \(removed) was replaced with \(selected)."
                        : "缺失的选中包 \(removed) 已自动改为 \(selected)。"
                }
                return english ? "Selected \(selected)." : "已自动选择 \(selected)。"
            }
        }
        let repeated = record.occurrenceCount > 1
            ? (english ? " Repeated \(record.occurrenceCount) times." : " 已重复 \(record.occurrenceCount) 次。")
            : ""
        return messages.joined(separator: " ") + repeated
    }

    private func bootstrapReportRevealPath(_ record: BootstrapReportRecord) -> String? {
        record.events.compactMap { event in
            if case .packSalvaged(_, let movedTo) = event { return movedTo }
            return nil
        }.first
    }

    private var bootstrapReportFocusActions: [PanelFocusTarget] {
        bootstrapReports.records.flatMap { record in
            let id = record.id.uuidString
            var actions: [PanelFocusTarget] = []
            if record.events.contains(where: { if case .failure = $0 { return true }; return false }) {
                actions += [.bootstrapReportRetry(id: id), .bootstrapReportDiagnostics(id: id)]
            }
            if bootstrapReportRevealPath(record) != nil {
                actions.append(.bootstrapReportReveal(id: id))
            }
            if record.events.contains(where: { if case .selectionChanged = $0 { return true }; return false }) {
                actions.append(.bootstrapReportManageSounds(id: id))
            }
            actions.append(.bootstrapReportAcknowledge(id: id))
            return actions
        }
    }

    // MARK: - Focus and playback

    private func applyFirstFocus() {
        let content = panelModel.configState.topContent
        let visibleEvents = content.showsEventContent
            && panelModel.libraryPresentationState.hasUsableSnapshot
            ? eventPresentations : []
        let hasOpenSettings = !content.hasConfigFailureNotice
        let hasReset = hasOpenSettings && selectedScope.scope.surface != nil
        let order = panelFocusOrder(
            .operational(
                events: visibleEvents,
                hasMasterVolume: content.showsEventContent
                    && panelModel.libraryPresentationState.hasUsableSnapshot,
                hasOpenSoundSettings: hasOpenSettings,
                hasResetSurface: hasReset,
                hasConfigFailureNotice: content.hasConfigFailureNotice,
                bootstrapReportActions: bootstrapReportFocusActions))
        if let requested = focusCoordinator.requestedTarget, order.contains(requested) {
            focusedTarget = requested
        } else {
            focusedTarget = order.first
        }
    }

    private func isEventFocusTarget(_ target: PanelFocusTarget?) -> Bool {
        switch target {
        case .eventPreview, .eventMute: true
        default: false
        }
    }

    private func playPreview(for row: EventRow) {
        guard case .present(let fileName) = row.coverage,
            let packDirectory = resolvePackDirectory(
                id: panelModel.config.selectedPack,
                userPacksDirectory: audioEnvironment.userPacksDirectory,
                bundledPacksDirectory: audioEnvironment.bundledPacksDirectory),
            let file = safePackFileURL(fileName, in: packDirectory),
            nonEmptyRegularFileExists(at: file)
        else {
            panelModel.reload()
            return
        }
        previewPlayer.play(fileAt: file, volume: Float(previewVolume(for: panelModel.config)))
    }

    // MARK: - Shared projections

    private var selectedPackDisplayName: String { panelModel.selectedPackMetadata.displayName }
    private var l10n: ClaudioL10n { ClaudioL10n(language: languageStore.language) }
    private var interfaceTextSize: ClaudioInterfaceTextSize {
        ClaudioInterfaceTextSize(storedValue: interfaceTextSizeRaw)
    }
    private var interfaceTextSizeBinding: Binding<ClaudioInterfaceTextSize> {
        Binding(
            get: { ClaudioInterfaceTextSize(storedValue: interfaceTextSizeRaw) },
            set: { interfaceTextSizeRaw = $0.rawValue })
    }
    private var typeScale: CGFloat { CGFloat(interfaceTextSize.scale) }
    private var layoutAdaptation: PanelLayoutAdaptation {
        panelLayoutAdaptation(for: panelTypeSizeTier(for: interfaceTextSize))
    }
}

/// 单一来源事件行：标题/原生事件/能力/文件是只读事实，右侧只有试听与静音。
@MainActor
private struct PanelAgentEventRow: View {
    let presentation: PanelEventPresentation
    let adaptation: PanelLayoutAdaptation
    let language: ClaudioAppLanguage
    let onPreview: () -> Void
    let onToggleMute: () -> Void
    private let focusedTarget: FocusState<PanelFocusTarget?>.Binding

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    init(
        presentation: PanelEventPresentation,
        adaptation: PanelLayoutAdaptation,
        language: ClaudioAppLanguage,
        focusedTarget: FocusState<PanelFocusTarget?>.Binding,
        onPreview: @escaping () -> Void,
        onToggleMute: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.adaptation = adaptation
        self.language = language
        self.focusedTarget = focusedTarget
        self.onPreview = onPreview
        self.onToggleMute = onToggleMute
    }

    var body: some View {
        Group {
            if adaptation.eventActionsMoveBelow {
                VStack(alignment: .leading, spacing: 6) {
                    identity
                    actions.padding(.leading, 30)
                }
            } else {
                HStack(alignment: .center, spacing: 8) {
                    identity
                    Spacer(minLength: 4)
                    actions
                }
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel.event.\(presentation.event.rawValue).row")
    }

    private var identity: some View {
        HStack(alignment: .top, spacing: 7) {
            ClaudioEventGlyph(event: presentation.event, size: 23)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title)
                    .font(.system(size: 12.5 * typeScale, weight: .semibold, design: .rounded))
                    .foregroundColor(
                        controlsUnavailable
                            ? ClaudioTheme.secondaryText(colorScheme)
                            : ClaudioTheme.text(colorScheme))
                Text(presentation.nativeEventText)
                    .font(.system(size: 9.5 * typeScale, design: .monospaced))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    .textSelection(.enabled)
                if adaptation.rowWrapsToTwoLines {
                    VStack(alignment: .leading, spacing: 3) {
                        capabilityBadge
                        soundFileText
                    }
                } else {
                    HStack(spacing: 5) {
                        capabilityBadge
                        soundFileText
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private var controlsUnavailable: Bool {
        presentation.implementation == .notImplemented || presentation.support == .unsupported
    }

    private var capabilityBadge: some View {
        Text(presentation.capabilityText)
            .font(.system(size: 9 * typeScale, weight: .medium, design: .rounded))
            .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(ClaudioTheme.elevated(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var soundFileText: some View {
        Text(presentation.soundFileText)
            .font(.system(size: 9.5 * typeScale, design: .rounded))
            .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            .lineLimit(adaptation.rowWrapsToTwoLines ? 2 : 1)
    }

    private var actions: some View {
        HStack(spacing: 5) {
            Button(action: onPreview) {
                Image(systemName: "play.fill")
            }
            .buttonStyle(ClaudioIconButtonStyle())
            .foregroundColor(
                presentation.controls.previewEnabled
                    ? ClaudioTheme.event(presentation.event, colorScheme)
                    : ClaudioTheme.secondaryText(colorScheme))
            .disabled(!presentation.controls.previewEnabled)
            .focused(focusedTarget, equals: .eventPreview(presentation.event))
            .help(localizedEventPreviewHint(presentation.controls.previewAvailability, language: language))
            .accessibilityLabel(
                ClaudioL10n(language: language).format(
                    .eventPreviewLabel,
                    presentation.title))
            .accessibilityIdentifier("panel.event.\(presentation.event.rawValue).preview")

            Button(action: onToggleMute) {
                EventMuteSpeakerIcon(
                    isMuted: !presentation.enabled,
                    color: presentation.enabled
                        ? ClaudioTheme.secondaryText(colorScheme)
                        : ClaudioTheme.clay(colorScheme)
                )
                .accessibilityHidden(true)
            }
            .buttonStyle(ClaudioIconButtonStyle())
            .disabled(!presentation.controls.muteEnabled)
            .focused(focusedTarget, equals: .eventMute(presentation.event))
            .accessibilityLabel(
                presentation.enabled
                    ? ClaudioL10n(language: language).format(.eventMute, presentation.title)
                    : ClaudioL10n(language: language).format(.eventUnmute, presentation.title))
            .accessibilityValue(
                presentation.enabled
                    ? ClaudioL10n(language: language).text(.eventEnabled)
                    : ClaudioL10n(language: language).text(.eventMuted))
            .accessibilityIdentifier("panel.event.\(presentation.event.rawValue).mute")
        }
        .fixedSize()
    }
}

/// Panel 专属语言/文字大小 popover。关闭后焦点精确回到 `Aa⌄` 触发器。
@MainActor
struct InterfaceTextSizeControl: View {
    @Binding var selection: ClaudioInterfaceTextSize
    @ObservedObject var languageStore: ClaudioLanguageStore

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isTriggerFocused: Bool
    @State private var isPopoverPresented = false

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            Text("Aa⌄")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
        }
        .buttonStyle(.bordered)
        .tint(ClaudioTheme.clay(colorScheme))
        .frame(width: 54, height: 32)
        .focused($isTriggerFocused)
        .accessibilityLabel(ClaudioL10n(language: languageStore.language).text(.interfaceTitle))
        .accessibilityValue(
            "\(languageStore.language.selfName)"
                + (languageStore.language == .english ? ", " : "，")
                + selection.localizedDisplayName(languageStore.language))
        .accessibilityHint(ClaudioL10n(language: languageStore.language).text(.panelOptionsHint))
        .accessibilityIdentifier("panel.options.text-size")
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            InterfaceSettingsPopoverContent(
                selection: $selection,
                languageStore: languageStore)
        }
        .onChange(of: isPopoverPresented) { presented in
            if !presented { isTriggerFocused = true }
        }
        .onDisappear {
            isPopoverPresented = false
            isTriggerFocused = false
        }
    }
}
