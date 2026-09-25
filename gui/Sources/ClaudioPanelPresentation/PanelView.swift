import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

private let panelScrollViewportCoordinateSpace = "panel.scroll-viewport"

/// 菜单栏 Agent 集成面板。生产树只呈现一个当前作用域的五行事件与两行播放设置；
/// 连接/诊断、事件设置和完整声音编辑继续由 retained window 负责。
@MainActor
public struct PanelView: View {
    @StateObject private var announcer: PanelAnnouncer
    @StateObject private var panelModel: PanelConfigController
    @State private var isSoundScopeMenuExpanded = false
    @State private var activityRange: LocalActivityRange = .today
    @State private var scrollViewportHeight: CGFloat = 0
    @State private var soundScopePickerBottom: CGFloat = 0
    @State private var previousTopContent: PanelTopContent?
    @State private var previewAttemptFailures: [Event: EventPreviewAttemptFailure] = [:]
    @FocusState private var focusedTarget: PanelFocusTarget?

    @ObservedObject private var focusCoordinator: PanelFocusCoordinator
    @ObservedObject private var hostIntegrations: HostIntegrationPresentationStore
    @ObservedObject private var languageStore: ClaudioPreferences
    @ObservedObject private var activityDiagnostics: ActivityDiagnosticsModel
    @ObservedObject private var eventNoticeModel: EventNoticeModel

    @Environment(\.colorScheme) private var colorScheme
    /// `unselected` 只表示从未选择；用户显式选过 Global 后持久化为 `global`。
    @AppStorage(panelSoundScopeDefaultsKey)
    private var selectedSurfaceRaw = "unselected"

    private let audioEnvironment: AudioImportEnvironment
    private let configFile: URL
    private let previewPlayer: AudioPreviewPlaying
    private let refreshesActivityOnLifecycle: Bool
    private let onAudibilityInputsChanged: @MainActor () -> Void
    private let onOpenSettings: @MainActor () -> Void
    private let onEditSoundScope: @MainActor (PanelSoundScopeID) -> Void
    private let onConfigureSound: @MainActor (SoundPacksWindowRoute) -> Void
    private let onOpenRecentNotices: @MainActor () -> Void
    private let onOpenIntegration: @MainActor (HostID) -> Void
    private let onQuit: @MainActor () -> Void
    private let onRevealConfig: @MainActor (URL) -> Void
    private let onAnnounce: @MainActor (String) -> Void

    public init(
        audioEnvironment: AudioImportEnvironment,
        configFile: URL = ClaudioPaths.configFile,
        lockFile: URL = ClaudioPaths.configLockFile,
        focusCoordinator: PanelFocusCoordinator = PanelFocusCoordinator(),
        hostIntegrations: HostIntegrationPresentationStore,
        languageStore: ClaudioPreferences,
        activityDiagnostics: ActivityDiagnosticsModel,
        soundPackLibrary: SoundPackLibrary,
        soundPacksRefreshCoordinator: SoundPacksRefreshCoordinator,
        eventNoticeModel: EventNoticeModel,
        onAudibilityInputsChanged: @escaping @MainActor () -> Void,
        onOpenSettings: @escaping @MainActor () -> Void,
        onEditSoundScope: @escaping @MainActor (PanelSoundScopeID) -> Void = { _ in },
        onConfigureSound: @escaping @MainActor (SoundPacksWindowRoute) -> Void = { _ in },
        onOpenRecentNotices: @escaping @MainActor () -> Void,
        onOpenIntegration: @escaping @MainActor (HostID) -> Void,
        onQuit: @escaping @MainActor () -> Void,
        onRevealConfig: @escaping @MainActor (URL) -> Void,
        onAnnounce: @escaping @MainActor (String) -> Void,
    ) {
        self.audioEnvironment = audioEnvironment
        self.configFile = configFile
        self.focusCoordinator = focusCoordinator
        self.hostIntegrations = hostIntegrations
        self.languageStore = languageStore
        self.activityDiagnostics = activityDiagnostics
        self.eventNoticeModel = eventNoticeModel
        self.onAudibilityInputsChanged = onAudibilityInputsChanged
        self.onOpenSettings = onOpenSettings
        self.onEditSoundScope = onEditSoundScope
        self.onConfigureSound = onConfigureSound
        self.onOpenRecentNotices = onOpenRecentNotices
        self.onOpenIntegration = onOpenIntegration
        self.onQuit = onQuit
        self.onRevealConfig = onRevealConfig
        self.onAnnounce = onAnnounce
        previewPlayer = NSSoundAudioPreviewPlayer()
        refreshesActivityOnLifecycle = true

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
    /// injected model owns every visible state; callbacks are inert and the injected typed
    /// preferences are isolated so frames cannot change the user's real panel preferences.
    public init(
        previewPanelModel: PanelConfigController,
        previewScope: PanelSoundScopeID,
        previewSoundScopeExpanded: Bool = false,
        previewActivityPresentation: ActivityDiagnosticsPresentation = .empty(),
        previewActivityRange: LocalActivityRange = .today,
        audioEnvironment: AudioImportEnvironment,
        focusCoordinator: PanelFocusCoordinator,
        hostIntegrations: HostIntegrationPresentationStore,
        languageStore: ClaudioPreferences,
        eventNoticeModel: EventNoticeModel = EventNoticeModel(receiverEpoch: UUID())
    ) {
        let previewKey = UUID().uuidString
        let defaults = UserDefaults(suiteName: "com.orbitzero.claudio.state-gallery")!
        _selectedSurfaceRaw = AppStorage(
            wrappedValue: previewScope.storedValue,
            "claudio.preview.selected-surface.\(previewKey)",
            store: defaults)
        _announcer = StateObject(wrappedValue: PanelAnnouncer())
        _panelModel = StateObject(wrappedValue: previewPanelModel)
        _isSoundScopeMenuExpanded = State(initialValue: previewSoundScopeExpanded)
        _activityRange = State(initialValue: previewActivityRange)
        self.audioEnvironment = audioEnvironment
        self.configFile = URL(fileURLWithPath: "/dev/null/claudio-panel-preview-config.json")
        self.focusCoordinator = focusCoordinator
        self.hostIntegrations = hostIntegrations
        self.languageStore = languageStore
        self.eventNoticeModel = eventNoticeModel
        self.activityDiagnostics = ActivityDiagnosticsModel(
            previewPresentation: previewActivityPresentation)
        self.previewPlayer = NSSoundAudioPreviewPlayer()
        self.refreshesActivityOnLifecycle = false
        self.onAudibilityInputsChanged = {}
        self.onOpenSettings = {}
        self.onEditSoundScope = { _ in }
        self.onConfigureSound = { _ in }
        self.onOpenRecentNotices = {}
        self.onOpenIntegration = { _ in }
        self.onQuit = {}
        self.onRevealConfig = { _ in }
        self.onAnnounce = { _ in }
    }
    #endif

    public var body: some View {
        VStack(spacing: 0) {
            header
                .padding(13)
            Rectangle()
                .fill(ClaudioTheme.hairline(colorScheme))
                .frame(height: ClaudioTheme.Metrics.hairline)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    soundScopePicker(
                        availableMenuHeight: max(
                            0,
                            scrollViewportHeight - soundScopePickerBottom - 5)
                    )
                    .background(
                        GeometryReader { pickerGeometry in
                            Color.clear.preference(
                                key: PanelSoundScopePickerBottomPreferenceKey.self,
                                value: pickerGeometry.frame(
                                    in: .named(panelScrollViewportCoordinateSpace)
                                ).maxY)
                        }
                    )
                    activityOverview
                    if showsRefreshFailedNotice {
                        refreshFailedNotice
                    }
                    mainContent
                    writeFailures
                }
                .padding(13)
            }
            .coordinateSpace(name: panelScrollViewportCoordinateSpace)
            .background(
                GeometryReader { scrollViewport in
                    Color.clear.preference(
                        key: PanelScrollViewportHeightPreferenceKey.self,
                        value: scrollViewport.size.height)
                }
            )
            .onPreferenceChange(PanelScrollViewportHeightPreferenceKey.self) {
                scrollViewportHeight = $0
            }
            .onPreferenceChange(PanelSoundScopePickerBottomPreferenceKey.self) {
                soundScopePickerBottom = $0
            }
            PanelQuitFooter(
                language: languageStore.language,
                focusedTarget: $focusedTarget,
                onQuit: onQuit)
        }
        .frame(width: standardPanelWidth)
        .background(ClaudioTheme.panelGradient(colorScheme))
        .overlay(
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.panel)
                .strokeBorder(ClaudioTheme.hairline(colorScheme), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.panel))
        .onAppear {
            announcer.observeLibraryTransitions(
                from: panelModel.$libraryPresentationState,
                facts: {
                    [
                        model = panelModel, coordinator = focusCoordinator,
                        preferences = languageStore
                    ] in
                    Self.libraryAnnouncementFacts(
                        model: model, coordinator: coordinator, preferences: preferences)
                },
                onAnnounce: onAnnounce)
            synchronizeSelectedSoundSurface()
            applyFirstFocus()
            if refreshesActivityOnLifecycle {
                activityDiagnostics.refresh()
            }
        }
        .onChange(of: focusCoordinator.showCount) { _ in
            isSoundScopeMenuExpanded = false
            previewAttemptFailures = [:]
            panelModel.reload()
            if refreshesActivityOnLifecycle {
                activityDiagnostics.refresh()
            }
            synchronizeSelectedSoundSurface()
            applyFirstFocus()
            announcePanelSummary()
        }
        .onChange(of: hostIntegrations.content.sourceRows) { _ in
            synchronizeSelectedSoundSurface()
            applyFirstFocus()
        }
        .onChange(of: panelModel.libraryPresentationState) { _ in
            if isEventFocusTarget(focusedTarget) || focusedTarget == .libraryRefreshRetry {
                applyFocusAfterContentChange()
            }
            announcePanelSummary(opening: false)
        }
        .onChange(of: panelModel.config.selectedPack) { _ in
            previewAttemptFailures = [:]
        }
        .onChange(of: panelModel.configState.topContent) { content in
            focusedTarget = panelFocusAfterTopContentChange(
                previous: previousTopContent,
                current: content,
                focusedTarget: focusedTarget,
                nextOrder: focusOrder(for: content))
            previousTopContent = content
            announcePanelSummary(opening: false)
        }
        .onChange(of: writeFailureRecoveryFocusTargets) { _ in
            if isWriteFailureRecoveryTarget(focusedTarget) {
                applyFocusAfterContentChange()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(headerAccessibilityLabel)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            ClaudioOrbitWordmark(height: 22)
            Spacer(minLength: 8)
            Button(action: onOpenSettings) {
                Label(l10n.text(.panelOpenSettings), systemImage: "gearshape")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 8)
                    .frame(minHeight: ClaudioTheme.Metrics.compactControlHeight)
                    .contentShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control))
            }
            .buttonStyle(ClaudioIconButtonStyle())
            .focused($focusedTarget, equals: .headerSettings)
            .accessibilityLabel(l10n.text(.panelOpenSettings))
            .accessibilityIdentifier("panel.settings")
            Button(action: onOpenRecentNotices) {
                HStack(spacing: 3) {
                    Image(systemName: "bell.badge")
                    if eventNoticeModel.badgeCount > 0 {
                        Text(String(eventNoticeModel.badgeCount))
                            .monospacedDigit()
                    }
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 7)
                .frame(minHeight: ClaudioTheme.Metrics.compactControlHeight)
                .contentShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control))
            }
            .buttonStyle(ClaudioIconButtonStyle())
            .focused($focusedTarget, equals: .recentNotices)
            .accessibilityLabel(l10n.text(.eventNoticeRecent))
            .accessibilityValue(
                eventNoticeModel.badgeCount > 0
                    ? String(eventNoticeModel.badgeCount)
                    : "0"
            )
            .accessibilityHint(l10n.text(.eventNoticeExpandHint))
            .accessibilityIdentifier("panel.recent-notices")
        }
        .accessibilityLabel(headerAccessibilityLabel)
    }

    private var headerAccessibilityLabel: String {
        Self.headerAccessibilityLabel(language: languageStore.language)
    }

    private static func headerAccessibilityLabel(language: ClaudioAppLanguage) -> String {
        let l10n = ClaudioL10n(language: language)
        let separator = language == .english ? ", " : "，"
        return l10n.text(.panelTitle) + separator + l10n.text(.panelOpenSettings)
            + separator + l10n.text(.eventNoticeRecent)
    }

    private static func libraryAnnouncementFacts(
        model: PanelConfigController,
        coordinator: PanelFocusCoordinator,
        preferences: ClaudioPreferences
    ) -> PanelLibraryAnnouncementFacts {
        PanelLibraryAnnouncementFacts(
            header: headerAccessibilityLabel(language: preferences.language),
            refreshFailedNotice: ClaudioL10n(language: preferences.language)
                .text(.panelLibraryRefreshFailed),
            topContent: model.configState.topContent,
            libraryState: model.libraryPresentationState,
            panelIsVisible: coordinator.isPanelVisible,
            openCount: coordinator.showCount)
    }

    private func announcePanelSummary(opening: Bool = true) {
        let announcer = self.announcer
        let coordinator = focusCoordinator
        let model = panelModel
        announcer.scheduleLibraryUpdate(
            opening: opening,
            facts: {
                Self.libraryAnnouncementFacts(
                    model: model, coordinator: coordinator, preferences: languageStore)
            },
            onAnnounce: onAnnounce)
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

    private func soundScopePicker(availableMenuHeight: CGFloat) -> some View {
        PanelSoundScopePicker(
            scopes: soundScopePresentations,
            selectedScope: selectedScope,
            language: languageStore.language,
            availableMenuHeight: availableMenuHeight,
            isExpanded: $isSoundScopeMenuExpanded,
            focusedTarget: $focusedTarget,
            onSelect: selectSoundScope,
            onOpenIntegration: onOpenIntegration)
    }

    private func selectSoundScope(_ requestedScope: PanelSoundScopeID) {
        guard
            let scope = validatedPanelSoundScopeSelection(
                requestedScope,
                availableScopes: soundScopePresentations.map(\.scope))
        else {
            synchronizeSelectedSoundSurface()
            return
        }
        selectedSurfaceRaw = scope.storedValue
        panelModel.selectSoundScope(scope)
        previewAttemptFailures = [:]
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
        if panelModel.selectedSoundScope != resolved { previewAttemptFailures = [:] }
        panelModel.selectSoundScope(resolved)
    }

    // MARK: - Activity overview

    private var activityPresentation: ActivityOverviewPresentation {
        activityDiagnostics.presentation.projection.presentation(for: .global)
    }

    private var activityOverview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(l10n.text(.settingsActivityTitle) + " · " + l10n.text(.workspaceAllSources))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                Spacer(minLength: 4)
                Picker(
                    l10n.text(.settingsActivityTitle),
                    selection: $activityRange
                ) {
                    Text(l10n.text(.settingsActivityRangeToday)).tag(LocalActivityRange.today)
                    Text(l10n.text(.settingsActivityRangeSevenDays)).tag(
                        LocalActivityRange.sevenDays)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 132)
                .focused($focusedTarget, equals: .activityRange)
                .accessibilityLabel(l10n.text(.settingsActivityTitle))
                .accessibilityIdentifier("panel.activity.range")
            }

            HStack(spacing: 8) {
                activityMetric(
                    title: localizedEventName(.taskStart, language: languageStore.language),
                    value: activityRange == .today
                        ? activityPresentation.event(.taskStart)?.todayCount
                        : activityPresentation.event(.taskStart)?.sevenDayCount,
                    identifier: "panel.activity.task-start")
                activityMetric(
                    title: localizedEventName(.stop, language: languageStore.language),
                    value: activityRange == .today
                        ? activityPresentation.event(.stop)?.todayCount
                        : activityPresentation.event(.stop)?.sevenDayCount,
                    identifier: "panel.activity.stop")
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(l10n.text(.settingsActivityMessages))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                Text(
                    activityCountText(
                        activityRange == .today
                            ? activityPresentation.todayMessages
                            : activityPresentation.sevenDayMessages)
                )
                .fontWeight(.semibold)
                .monospacedDigit()
                Spacer(minLength: 4)
                Text(
                    activityStatusText(
                        activityRange == .today
                            ? activityPresentation.todayStatus
                            : activityPresentation.sevenDayStatus)
                )
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("panel.activity.messages")

            GeometryReader { proxy in
                let layouts = ActivityOverviewBarLayout.resolve(
                    segments: activityPresentation.barSegments,
                    range: activityRange,
                    availableWidth: proxy.size.width)
                HStack(spacing: 3) {
                    ForEach(layouts) { segment in
                        activitySegment(segment)
                            .frame(width: segment.width)
                            .frame(minHeight: 29)
                    }
                }
            }
            .frame(height: 29)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("panel.activity.bar")

            if let failure = activityPresentation.event(.stopFailure),
                let count = activityRange == .today ? failure.todayCount : failure.sevenDayCount,
                count > 0
            {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(ClaudioTheme.warning(colorScheme))
                    Text(localizedEventName(.stopFailure, language: languageStore.language))
                    Spacer(minLength: 4)
                    Text(String(count)).monospacedDigit()
                }
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("panel.activity.stop-failure")
            }
        }
        .padding(10)
        .background(ClaudioTheme.surface(colorScheme))
        .overlay(
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.section)
                .strokeBorder(
                    ClaudioTheme.hairline(colorScheme),
                    lineWidth: ClaudioTheme.Metrics.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.section))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel.activity-overview")
    }

    private func activityMetric(title: String, value: UInt64?, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8.5, weight: .medium, design: .rounded))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            Text(value.map { String($0) } ?? "—")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(ClaudioTheme.text(colorScheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func activitySegment(
        _ segment: ActivityOverviewSegmentLayout
    ) -> some View {
        let color = ClaudioTheme.event(segment.event, colorScheme)
        let isSupported = segment.availability == .supported
        return Button {
            focusedTarget = .activityMetric(segment.event)
        } label: {
            ZStack {
                Color.clear
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSupported && (segment.count ?? 0) > 0 ? color : .clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(
                                isSupported ? color : ClaudioTheme.secondaryText(colorScheme),
                                style: StrokeStyle(
                                    lineWidth: 1.5,
                                    dash: isSupported ? [] : [3, 2]))
                    }
                    .overlay {
                        if !isSupported {
                            Image(systemName: "slash.circle")
                                .font(.caption2)
                                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                        }
                    }
                    .frame(height: ActivityOverviewBarLayout.visibleBarHeight)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(
            PanelActivitySegmentButtonStyle(
                cornerRadius: ClaudioTheme.Radius.control)
        )
        .focused($focusedTarget, equals: .activityMetric(segment.event))
        .accessibilityLabel(localizedEventName(segment.event, language: languageStore.language))
        .accessibilityValue(activityTooltipText(segment))
        .accessibilityHint(
            l10n.format(
                .settingsActivityCoverage,
                Int64(activityPresentation.event(segment.event)?.coverage.supportedCount ?? 0),
                Int64(activityPresentation.event(segment.event)?.coverage.totalCount ?? 0))
        )
        .help(activityTooltipText(segment))
        .accessibilityIdentifier("panel.activity.segment.\(segment.event.cliName)")
    }

    private func activityTooltipText(_ segment: ActivityOverviewSegmentLayout) -> String {
        let event = activityPresentation.event(segment.event)
        let today = activityCountText(event?.todayCount)
        let sevenDays = activityCountText(event?.sevenDayCount)
        let coverage = l10n.format(
            .settingsActivityCoverage,
            Int64(event?.coverage.supportedCount ?? 0),
            Int64(event?.coverage.totalCount ?? 0))
        let label = localizedEventName(segment.event, language: languageStore.language)
        return "\(label) · \(l10n.text(.settingsActivityRangeToday)) \(today) · "
            + "\(l10n.text(.settingsActivityRangeSevenDays)) \(sevenDays) · \(coverage)"
    }

    private func activityStatusText(_ status: ActivityOverviewStatus) -> String {
        switch status {
        case .ready: return l10n.text(.settingsActivityStatusReady)
        case .empty: return l10n.text(.settingsActivityStatusEmpty)
        case .unobserved: return l10n.text(.settingsActivityStatusUnobserved)
        case .unavailable: return l10n.text(.settingsActivityStatusUnavailable)
        case .stale(let date):
            return l10n.format(
                .settingsActivityStatusStale,
                date.formatted(date: .abbreviated, time: .shortened) as NSString)
        case .partial(let date):
            return l10n.format(
                .settingsActivityStatusPartial,
                date.formatted(date: .abbreviated, time: .shortened) as NSString)
        }
    }

    private func activityCountText(_ count: UInt64?) -> String {
        count.map { String($0) } ?? "—"
    }

    // MARK: - Main content

    private var showsRefreshFailedNotice: Bool {
        panelShowsRefreshFailedNotice(
            topContent: panelModel.configState.topContent,
            libraryState: panelModel.libraryPresentationState)
    }

    private var refreshFailedNotice: some View {
        HStack(alignment: .center, spacing: 7) {
            FailureRow(message: l10n.text(.panelLibraryRefreshFailed))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("panel.library.refreshFailed")
            Button(l10n.text(.panelRetry)) {
                panelModel.retrySoundPackLibraryRefresh()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(minHeight: ClaudioTheme.Metrics.compactControlHeight)
            .focused($focusedTarget, equals: .libraryRefreshRetry)
            .accessibilityLabel(l10n.text(.panelRetry))
            .accessibilityHint(l10n.text(.panelRetryHint))
            .accessibilityIdentifier("panel.library.refresh-retry")
            .help(l10n.text(.panelRetryHint))
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var mainContent: some View {
        switch panelModel.configState.topContent {
        case .events:
            if panelModel.libraryPresentationState.hasUsableSnapshot {
                eventSection
            } else {
                libraryUnavailableSection
            }
            playbackSettings(
                masterVolumeEnabled: panelModel.libraryPresentationState.hasUsableSnapshot)
        case .needsPack:
            needsPackNotice
            playbackSettings(masterVolumeEnabled: false)
        case .configFailure:
            configFailureNotice()
        }
    }

    private var eventPresentations: [PanelEventPresentation] {
        panelEventPresentations(
            rows: panelModel.eventRows,
            scope: selectedScope.scope,
            masterVolume: panelModel.config.masterVolume,
            language: languageStore.language,
            configWritesAllowed: panelModel.surfaceSoundIssue == nil,
            safetyFailures: panelModel.previewSafetyFailures)
    }

    private var eventSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(l10n.format(.panelEventsTitle, selectedScope.name))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                Spacer(minLength: 4)
                Text(eventCoverageSummary)
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            }
            .padding(.bottom, 4)
            VStack(spacing: 0) {
                ForEach(Array(eventPresentations.enumerated()), id: \.element.id) { index, event in
                    PanelAgentEventRow(
                        presentation: event,
                        adaptation: layoutAdaptation,
                        language: languageStore.language,
                        attemptFailure: previewAttemptFailures[event.event],
                        focusedTarget: $focusedTarget,
                        onPreview: {
                            let outcome = panelModel.attemptPreview(
                                event.event, using: previewPlayer)
                            switch outcome {
                            case .started:
                                previewAttemptFailures[event.event] = nil
                                return true
                            case .failed(let failure):
                                previewAttemptFailures[event.event] = failure
                                onAnnounce(
                                    localizedEventPreviewAttemptFailure(
                                        failure, language: languageStore.language))
                                return false
                            }
                        },
                        onRecovery: { action in
                            switch action {
                            case .adjustGroupVolume:
                                focusedTarget = .masterVolume
                            case .editSound, .repairSound:
                                guard panelModel.selectedSoundScope == selectedScope.scope,
                                    !panelModel.config.selectedPack.isEmpty
                                else { return }
                                onConfigureSound(
                                    .editEvent(
                                        surface: nil, packID: panelModel.config.selectedPack,
                                        event: event.event))
                            }
                        },
                        onToggleMute: {
                            panelModel.toggleMute(event.event)
                            onAudibilityInputsChanged()
                        })
                    if index < eventPresentations.count - 1 {
                        Rectangle()
                            .fill(ClaudioTheme.hairline(colorScheme))
                            .frame(height: ClaudioTheme.Metrics.hairline)
                    }
                }
            }
            .padding(.horizontal, 8)
            .background(ClaudioTheme.surface(colorScheme))
            .overlay(
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row)
                    .strokeBorder(
                        ClaudioTheme.hairline(colorScheme),
                        lineWidth: ClaudioTheme.Metrics.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel.events.single-scope")
    }

    private var eventCoverageSummary: String {
        if selectedScope.scope.surface == nil { return selectedScope.coverageText }
        return l10n.format(
            .panelEventsMappable,
            Int64(selectedScope.supportedCount),
            Int64(selectedScope.totalCount))
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
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(ClaudioTheme.text(colorScheme))
            Text(l10n.text(.panelNeedsPackSettingsMessage))
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .background(ClaudioTheme.elevated(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row))
        .accessibilityIdentifier("panel.needs-pack")
    }

    private func configFailureNotice() -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let category = panelModel.configState.errorCopyCategory {
                FailureRow(message: l10n.text(category.key))
            }
            if panelConfigRecoveryTarget(configFile: configFile) != nil {
                Button {
                    guard let current = panelConfigRecoveryTarget(configFile: configFile) else {
                        return
                    }
                    onRevealConfig(current)
                } label: {
                    Label(l10n.text(.panelRevealConfig), systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .focused($focusedTarget, equals: .configReveal)
                .accessibilityLabel(l10n.text(.panelRevealConfig))
                .accessibilityHint(l10n.text(.panelRevealConfigHint))
                .accessibilityIdentifier("panel.reveal-config")
            }
        }
        .accessibilityIdentifier("panel.config-failure")
    }

    // MARK: - Playback settings

    private func playbackSettings(masterVolumeEnabled: Bool) -> some View {
        let scope = selectedScope.scope
        return VStack(alignment: .leading, spacing: 5) {
            Text(l10n.text(.panelPlaybackSettings))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            VStack(spacing: 8) {
                Picker(
                    l10n.text(.panelSoundPackLabel),
                    selection: Binding(
                        get: { panelModel.config.selectedPack },
                        set: {
                            guard panelModel.selectedSoundScope == scope else { return }
                            _ = panelModel.switchPack(to: $0); onAudibilityInputsChanged()
                        })
                ) {
                    if !panelModel.allSoundPacks.contains(where: {
                        $0.id == panelModel.config.selectedPack
                    }) {
                        Text(panelModel.config.selectedPack).tag(panelModel.config.selectedPack)
                    }
                    ForEach(panelModel.allSoundPacks, id: \.id) { pack in
                        Text(SelectedPackMetadata(id: pack.id, name: pack.name).displayName).tag(
                            pack.id)
                    }
                }.padding(.horizontal, 9).padding(.top, 7)
                    .accessibilityIdentifier("panel.workspace.pack-picker")
                    .focused($focusedTarget, equals: .soundPackPicker)
                MasterVolumeRow(
                    diskVolume: panelModel.config.masterVolume,
                    isEnabled: masterVolumeEnabled,
                    onCommit: { volume in
                        let landed = panelModel.setVolume(volume, for: scope)
                        onAudibilityInputsChanged()
                        return landed
                    },
                    focusCoordinator: focusCoordinator,
                    focusedTarget: $focusedTarget,
                    adaptation: layoutAdaptation,
                    language: languageStore.language
                )
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .id(selectedScope.scope)
                if let id = selectedScope.scope.workspaceID,
                    let rule = panelModel.workspaceRules.first(where: { $0.id == id })
                {
                    Text(
                        l10n.text(.workspaceSurfaces) + ": "
                            + rule.surfaces.map { surface in
                                HostID.productVisibleCases.first { $0.surfaceID == surface }?
                                    .displayName ?? surface.rawValue
                            }.joined(separator: ", ")
                    )
                    .font(.caption).foregroundColor(.secondary)
                    Button(l10n.text(.workspaceEdit)) { onEditSoundScope(.workspace(id)) }
                        .accessibilityIdentifier("panel.workspace.edit")
                        .focused($focusedTarget, equals: .workspaceDetails)
                }
                Text(l10n.text(.workspacePreviewNote)).font(.caption).foregroundColor(.secondary)
                    .padding(9)
                if panelModel.workspaceRulesMalformed {
                    FailureRow(message: l10n.text(.workspaceInvalidRule))
                }
                if let error = panelModel.workspaceError {
                    FailureRow(
                        message: localizedWorkspaceError(error, language: languageStore.language))
                    if error == .configFailure || error.isPublishedConflict,
                        panelConfigRecoveryTarget(configFile: configFile) != nil
                    {
                        Button(l10n.text(.panelRevealConfig)) {
                            guard let current = panelConfigRecoveryTarget(configFile: configFile)
                            else { return }
                            onRevealConfig(current)
                        }
                        .accessibilityIdentifier("panel.workspace.reveal-config")
                    }
                    if let recoveryFile = panelModel.workspaceRecoveryFile {
                        Button(l10n.text(.panelRevealRecoveryFile)) {
                            guard let target = panelExistingRecoveryFileTarget(recoveryFile)
                            else { return }
                            onRevealConfig(target)
                        }
                        .accessibilityIdentifier("panel.workspace.reveal-recovery")
                    }
                    if error.isPublishedConflict {
                        Button(l10n.text(.workspaceDeleteReload)) {
                            panelModel.reload()
                        }
                        .accessibilityIdentifier("panel.workspace.reload-after-conflict")
                    }
                }
            }
            .background(ClaudioTheme.surface(colorScheme))
            .overlay(
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row)
                    .strokeBorder(
                        ClaudioTheme.hairline(colorScheme),
                        lineWidth: ClaudioTheme.Metrics.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel.playback-settings")
    }

    private var writeFailures: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(panelWriteFailureRows(items: writeFailureItems, l10n: l10n)) { row in
                FailureRow(message: row.message)
            }
            if let category = panelModel.surfaceSoundIssueCopyCategory {
                FailureRow(message: l10n.text(category.key))
            }
            ForEach(Array(writeFailureRecoveryFiles.enumerated()), id: \.element) { index, file in
                if panelExistingRecoveryFileTarget(file) != nil {
                    Button {
                        guard let current = panelExistingRecoveryFileTarget(file) else { return }
                        onRevealConfig(current)
                    } label: {
                        Label(
                            writeFailureRecoveryFiles.count == 1
                                ? l10n.text(.panelRevealRecoveryFile)
                                : l10n.format(.panelRevealRecoveryFileNumber, Int64(index + 1)),
                            systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .focused($focusedTarget, equals: .writeFailureRecoveryFile(path: file.path))
                    .accessibilityHint(l10n.text(.panelRevealRecoveryFileHint))
                    .accessibilityIdentifier("panel.write-failure.reveal-recovery.\(index + 1)")
                }
            }
            if showsWriteFailureConfigRecovery,
                panelConfigRecoveryTarget(configFile: configFile) != nil
            {
                Button {
                    guard let current = panelConfigRecoveryTarget(configFile: configFile) else {
                        return
                    }
                    onRevealConfig(current)
                } label: {
                    Label(l10n.text(.panelRevealConfig), systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .focused($focusedTarget, equals: .writeFailureConfigReveal)
                .accessibilityLabel(l10n.text(.panelRevealConfig))
                .accessibilityHint(l10n.text(.panelRevealConfigHint))
                .accessibilityIdentifier("panel.write-failure.reveal-config")
            }
        }
    }

    private var writeFailureItems: [PanelWriteFailure] {
        panelWriteFailureItems(
            muteError: panelModel.muteError,
            packSwitchError: panelModel.packSwitchError,
            masterVolumeError: panelModel.masterVolumeError,
            configFailureReason: currentConfigFailureReason)
    }

    private var showsWriteFailureConfigRecovery: Bool {
        guard !panelModel.configState.topContent.hasConfigFailureNotice else { return false }
        guard panelConfigRecoveryTarget(configFile: configFile) != nil else { return false }
        return writeFailureItems.contains(where: { $0.reason.copyCategory.offersConfigRecovery })
            || panelModel.surfaceSoundIssueCopyCategory?.offersConfigRecovery == true
    }

    private var writeFailureRecoveryFiles: [URL] {
        panelWriteFailureRecoveryFiles(
            items: writeFailureItems,
            surfaceRecoveryFile: panelModel.surfaceSoundIssueRecoveryFile)
    }

    private var writeFailureRecoveryFocusTargets: [PanelFocusTarget] {
        writeFailureRecoveryFiles.map { .writeFailureRecoveryFile(path: $0.path) }
            + (showsWriteFailureConfigRecovery ? [.writeFailureConfigReveal] : [])
    }

    private var currentConfigFailureReason: String? {
        switch panelModel.configState {
        case .malformed(let reason), .unwritable(let reason): return reason
        case .operational, .needsPack: return nil
        }
    }

    // MARK: - Focus and playback

    private func applyFirstFocus() {
        let content = panelModel.configState.topContent
        focusedTarget =
            focusCoordinator.requestedTarget.flatMap { requested in
                let order = focusOrder(for: content)
                return order.contains(requested) ? requested : nil
            } ?? focusOrder(for: content).first(where: { $0 == .soundScope })
            ?? focusOrder(for: content).first
        previousTopContent = content
    }

    private func applyFocusAfterContentChange() {
        let content = panelModel.configState.topContent
        focusedTarget = panelFocusAfterTopContentChange(
            previous: previousTopContent,
            current: content,
            focusedTarget: focusedTarget,
            nextOrder: focusOrder(for: content))
        previousTopContent = content
    }

    private func focusOrder(for content: PanelTopContent) -> [PanelFocusTarget] {
        let visibleEvents =
            content.showsEventContent
                && panelModel.libraryPresentationState.hasUsableSnapshot
            ? eventPresentations : []
        let order = panelFocusOrder(
            .activityOperational(
                events: visibleEvents,
                hasActivityOverview: true,
                hasMasterVolume: content.showsEventContent
                    && panelModel.libraryPresentationState.hasUsableSnapshot,
                hasConfigFailureNotice: content.hasConfigFailureNotice
                    && panelConfigRecoveryTarget(configFile: configFile) != nil,
                hasRefreshFailedNotice: showsRefreshFailedNotice,
                writeFailureRecoveryPaths: writeFailureRecoveryFiles.map(\.path),
                hasWriteFailureConfigRecovery: showsWriteFailureConfigRecovery,
                hasSoundPackPicker: !content.hasConfigFailureNotice,
                hasWorkspaceDetails: !content.hasConfigFailureNotice
                    && panelModel.workspaceRules.contains {
                        $0.id == selectedScope.scope.workspaceID
                    }))
        return order
    }

    private func isEventFocusTarget(_ target: PanelFocusTarget?) -> Bool {
        switch target {
        case .eventPreview, .eventMute: true
        default: false
        }
    }

    private func isWriteFailureRecoveryTarget(_ target: PanelFocusTarget?) -> Bool {
        switch target {
        case .writeFailureConfigReveal, .writeFailureRecoveryFile: true
        default: false
        }
    }

    // MARK: - Shared projections

    private var l10n: ClaudioL10n { ClaudioL10n(language: languageStore.language) }
    private var layoutAdaptation: PanelLayoutAdaptation {
        PanelLayoutAdaptation(
            hidesWaveform: false,
            rowWrapsToTwoLines: false,
            eventActionsMoveBelow: false,
            panelWidth: standardPanelWidth)
    }
}

private struct PanelSoundScopePickerBottomPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct PanelScrollViewportHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 单一来源事件行：标题/原生事件/能力/文件是只读事实，右侧只有试听与静音。
@MainActor
private struct PanelAgentEventRow: View {
    let presentation: PanelEventPresentation
    let adaptation: PanelLayoutAdaptation
    let language: ClaudioAppLanguage
    let attemptFailure: EventPreviewAttemptFailure?
    let onPreview: () -> Bool
    let onRecovery: (EventPreviewRecoveryAction) -> Void
    let onToggleMute: () -> Void
    private let focusedTarget: FocusState<PanelFocusTarget?>.Binding

    @Environment(\.colorScheme) private var colorScheme
    @State private var previewPulseTrigger = 0

    init(
        presentation: PanelEventPresentation,
        adaptation: PanelLayoutAdaptation,
        language: ClaudioAppLanguage,
        attemptFailure: EventPreviewAttemptFailure?,
        focusedTarget: FocusState<PanelFocusTarget?>.Binding,
        onPreview: @escaping () -> Bool,
        onRecovery: @escaping (EventPreviewRecoveryAction) -> Void,
        onToggleMute: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.adaptation = adaptation
        self.language = language
        self.attemptFailure = attemptFailure
        self.focusedTarget = focusedTarget
        self.onPreview = onPreview
        self.onRecovery = onRecovery
        self.onToggleMute = onToggleMute
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
            if let reason = previewUnavailableReason {
                Text(reason)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(
                        "panel.event.\(presentation.event.rawValue).preview-reason")
                if let recoveryAction {
                    Button(recoveryTitle(for: recoveryAction)) {
                        onRecovery(recoveryAction)
                    }
                    .buttonStyle(.link)
                    .accessibilityIdentifier(
                        "panel.event.\(presentation.event.rawValue).preview-recovery")
                }
            }
            if let attemptFailure {
                Text(localizedEventPreviewAttemptFailure(attemptFailure, language: language))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(
                        "panel.event.\(presentation.event.rawValue).preview-failure")
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
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundColor(
                        controlsUnavailable
                            ? ClaudioTheme.secondaryText(colorScheme)
                            : ClaudioTheme.text(colorScheme))
                Text(presentation.nativeEventText)
                    .font(.system(size: 9.5, design: .monospaced))
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
        .accessibilityLabel(identityAccessibilityLabel)
    }

    private var previewUnavailableReason: String? {
        guard !presentation.controls.previewAvailability.isAvailable else { return nil }
        return localizedEventPreviewHint(
            presentation.controls.previewAvailability, language: language)
    }

    private var recoveryAction: EventPreviewRecoveryAction? {
        eventPreviewRecoveryAction(for: presentation.controls.previewAvailability)
    }

    private func recoveryTitle(for action: EventPreviewRecoveryAction) -> String {
        let l10n = ClaudioL10n(language: language)
        switch action {
        case .adjustGroupVolume: return l10n.text(.eventPreviewAdjustGroupVolume)
        case .editSound: return l10n.text(.actionConfigureSound)
        case .repairSound: return l10n.text(.eventPreviewRepairSound)
        }
    }

    private var identityAccessibilityLabel: String {
        let separator = language == .english ? ", " : "，"
        return [
            presentation.accessibilityLabel,
            previewUnavailableReason,
            attemptFailure.map { localizedEventPreviewAttemptFailure($0, language: language) },
        ].compactMap { $0 }.joined(separator: separator)
    }

    private var controlsUnavailable: Bool {
        presentation.implementation == .notImplemented || presentation.support == .unsupported
    }

    private var capabilityBadge: some View {
        Text(presentation.capabilityText)
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(ClaudioTheme.elevated(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var soundFileText: some View {
        Text(presentation.soundFileText)
            .font(.system(size: 9.5, design: .rounded))
            .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            .lineLimit(adaptation.rowWrapsToTwoLines ? 2 : 1)
    }

    private var actions: some View {
        HStack(spacing: 5) {
            Button {
                if onPreview() {
                    previewPulseTrigger &+= 1
                }
            } label: {
                Image(systemName: "play.fill")
                    .claudioPreviewPulse(trigger: previewPulseTrigger)
            }
            .buttonStyle(ClaudioIconButtonStyle())
            .disabled(!presentation.controls.previewEnabled)
            .focused(focusedTarget, equals: .eventPreview(presentation.event))
            .help(
                localizedEventPreviewHint(
                    presentation.controls.previewAvailability, language: language)
            )
            .accessibilityHint(
                localizedEventPreviewHint(
                    presentation.controls.previewAvailability, language: language)
            )
            .accessibilityLabel(
                ClaudioL10n(language: language).format(
                    .eventPreviewLabel,
                    presentation.title)
            )
            .accessibilityIdentifier("panel.event.\(presentation.event.rawValue).preview")

            Button(action: onToggleMute) {
                PanelMuteSpeakerIcon(isMuted: !presentation.enabled)
                    .accessibilityHidden(true)
            }
            .buttonStyle(ClaudioIconButtonStyle())
            .disabled(!presentation.controls.muteEnabled)
            .focused(focusedTarget, equals: .eventMute(presentation.event))
            .accessibilityLabel(
                presentation.enabled
                    ? ClaudioL10n(language: language).format(.eventMute, presentation.title)
                    : ClaudioL10n(language: language).format(.eventUnmute, presentation.title)
            )
            .accessibilityValue(
                presentation.enabled
                    ? ClaudioL10n(language: language).text(.eventEnabled)
                    : ClaudioL10n(language: language).text(.eventMuted)
            )
            .accessibilityIdentifier("panel.event.\(presentation.event.rawValue).mute")
        }
        .fixedSize()
    }
}

/// Activity segments keep their 29pt target and 13pt visible bar while exposing the same warm
/// interaction language as the shared icon actions. Geometry never changes between states.
private struct PanelActivitySegmentButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        PanelActivitySegmentButtonStyleBody(
            configuration: configuration,
            cornerRadius: cornerRadius)
    }
}

private struct PanelActivitySegmentButtonStyleBody: View {
    let configuration: ButtonStyleConfiguration
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    private var interactionState: ClaudioIconButtonInteractionState {
        ClaudioIconButtonInteractionState(
            isEnabled: isEnabled,
            isHovered: isHovered,
            isFocused: isFocused,
            isPressed: configuration.isPressed)
    }

    private var isHighlighted: Bool {
        interactionState == .hovered || interactionState == .focused
    }

    private var backgroundColor: Color {
        if isHighlighted { return ClaudioTheme.claySoft(colorScheme) }
        if interactionState == .pressed { return ClaudioTheme.elevated(colorScheme) }
        return .clear
    }

    private var borderColor: Color {
        isHighlighted ? ClaudioTheme.clay(colorScheme) : .clear
    }

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        borderColor,
                        lineWidth: ClaudioTheme.Metrics.hairline)
            )
            .contentShape(Rectangle())
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: interactionState
            )
            .onHover { isHovered = $0 }
    }
}

/// The custom Touch Bar speaker remains the visual mask; the shared button style owns its actual
/// foreground so hover, focus, disabled and Reduce Motion states cannot be overridden locally.
private struct PanelMuteSpeakerIcon: View {
    let isMuted: Bool

    var body: some View {
        Rectangle()
            .fill(.foreground)
            .frame(width: 24, height: 24)
            .mask {
                EventMuteSpeakerIcon(isMuted: isMuted, color: .white)
            }
    }
}
