import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SoundPacksWindow
import SwiftUI

/// Unified Settings navigation shell shared by production and the compiled harness.
@MainActor
package struct SettingsRootView: View {
    @ObservedObject var preferences: ClaudioPreferences
    @ObservedObject var dynamicQuietPolicy: DynamicQuietPolicyController
    @ObservedObject var settingsPresentationSession: SettingsPresentationSession
    @ObservedObject var usageSettings: UsageSettingsModel
    @ObservedObject var globalShortcutSettings: GlobalShortcutSettingsModel
    @ObservedObject var aboutSettings: AboutSettingsModel
    let soundPacksEditorOwner: SoundPacksEditorOwner
    let soundPacksEditorNativeEffects: SoundPacksEditorNativeEffectsDispatcher
    let eventSettingsModel: PanelConfigController
    let eventSettingsSelection: EventSettingsWindowSelection
    let hostIntegrations: HostIntegrationPresentationStore
    let integrationsModel: IntegrationDestinationModel
    let integrationsFocusCoordinator: IntegrationDestinationFocusCoordinator
    let aiCueViewModel: AICueGenerationViewModel
    let onEventAudibilityInputsChanged: @MainActor () -> Void
    let onAnnouncement: @MainActor (String) -> Void

    @FocusState private var focusedTarget: SettingsWindowFocusTarget?
    @State private var handledFocusDebtRevision: UInt64 = 0

    private var l10n: ClaudioL10n { ClaudioL10n(language: preferences.language) }
    private var destination: SettingsDestination {
        settingsPresentationSession.state.routeResolution.destination
    }

    package init(session: SettingsPresentationSession) {
        let dependencies = session.dependencies
        _preferences = ObservedObject(wrappedValue: dependencies.preferences)
        _dynamicQuietPolicy = ObservedObject(wrappedValue: dependencies.dynamicQuietPolicy)
        _settingsPresentationSession = ObservedObject(wrappedValue: session)
        _usageSettings = ObservedObject(wrappedValue: dependencies.usageSettings)
        _globalShortcutSettings = ObservedObject(
            wrappedValue: dependencies.globalShortcutSettings)
        _aboutSettings = ObservedObject(wrappedValue: dependencies.aboutSettings)
        soundPacksEditorOwner = dependencies.soundPacksEditorOwner
        soundPacksEditorNativeEffects = dependencies.soundPacksEditorNativeEffects
        eventSettingsModel = dependencies.eventSettingsModel
        eventSettingsSelection = session.eventSettingsSelection
        hostIntegrations = dependencies.hostIntegrations
        integrationsModel = dependencies.integrationsModel
        integrationsFocusCoordinator = session.integrationsFocusCoordinator
        aiCueViewModel = dependencies.aiCueViewModel
        onEventAudibilityInputsChanged = {
            _ = session.send(.eventAudibilityInputsChanged)
        }
        onAnnouncement = {
            _ = session.send(.announceDestinationUpdate($0))
        }
    }

    package var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                sidebar
                    .frame(
                        width: CGFloat(
                            settingsSidebarWidth(
                                windowWidth: geometry.size.width,
                                interfaceTextSize: preferences.interfaceTextSize))
                    )
                    .frame(maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                routeSlot
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(
            minWidth: SettingsWindowGeometry.minimumWidth,
            minHeight: SettingsWindowGeometry.minimumHeight
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l10n.text(.settingsWindowTitle))
        .accessibilityIdentifier(SettingsPresentationAccessibilityID.root)
        .environment(\.dynamicTypeSize, preferences.interfaceTextSize.dynamicTypeSize)
        .onExitCommand {
            focusedTarget = SettingsWindowFocusTarget.sidebar(destination)
        }
        .onAppear {
            synchronizeDestinationFocus(settingsPresentationSession.state)
        }
        .onReceive(settingsPresentationSession.$state) { state in
            synchronizeDestinationFocus(state)
        }
    }

    private func synchronizeDestinationFocus(_ state: SettingsPresentationState) {
        guard state.windowPhase == .key,
            let debt = state.focusDebt,
            debt.revision > handledFocusDebtRevision
        else { return }
        handledFocusDebtRevision = debt.revision
        if state.routeResolution.failure != nil
            || (debt.destination != .integrations
                && debt.destination != .eventsAndSounds
                && debt.destination != .sounds)
        {
            focusedTarget = SettingsWindowFocusTarget.title(state.routeResolution.destination)
        }
        _ = settingsPresentationSession.send(.acknowledgeFocus(revision: debt.revision))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("claudi0")
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.bottom, 16)

            ForEach(
                settingsSidebarSections(
                    availableDestinations: preferences.availableSettingsDestinations)
            ) { section in
                if section.id != .primary {
                    Divider()
                        .padding(.horizontal, 9)
                        .padding(.vertical, 12)
                    Text(sidebarSectionName(section.id))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 5)
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(section.destinations) { item in
                        sidebarButton(item)
                    }
                }
            }

            Spacer(minLength: 0)

            Label(l10n.text(.settingsSidebarLocalFirst), systemImage: "lock.shield")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .accessibilityIdentifier("settings.sidebar.local-first")
        }
        .padding(.horizontal, 12)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private func sidebarButton(_ item: SettingsDestination) -> some View {
        Button {
            settingsPresentationSession.send(.route(.destination(item)))
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon(item))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 25, height: 25)
                    .background(sidebarIconColor(item))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)

                Text(item.localizedName(language: preferences.language))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 4)

                if item == destination {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(item == destination ? Color.primary.opacity(0.1) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(.body, design: .rounded).weight(item == destination ? .semibold : .regular))
        .focused($focusedTarget, equals: SettingsWindowFocusTarget.sidebar(item))
        .onMoveCommand { direction in
            switch direction {
            case .up:
                moveSidebarSelection(.previous, from: item)
            case .down:
                moveSidebarSelection(.next, from: item)
            default:
                break
            }
        }
        .accessibilityLabel(item.localizedName(language: preferences.language))
        .accessibilityAddTraits(item == destination ? .isSelected : [])
        .accessibilitySortPriority(3)
        .accessibilityIdentifier("settings.sidebar.\(item.rawValue)")
    }

    @ViewBuilder
    private var routeSlot: some View {
        if let failure = settingsPresentationSession.state.routeResolution.failure {
            standardDestination { routeFailure(failure) }
        } else {
            switch destination {
            case .general:
                standardDestination { generalSettings }
            case .integrations:
                IntegrationsSettingsDestinationView(
                    model: integrationsModel,
                    focusCoordinator: integrationsFocusCoordinator,
                    languageStore: preferences,
                    onManageEvents: { host in
                        settingsPresentationSession.send(
                            .route(.events(scope: .surface(host.surfaceID), event: nil)))
                    },
                    onAnnouncement: onAnnouncement)
            case .eventsAndSounds:
                EventSettingsWindowView(
                    model: eventSettingsModel,
                    selection: eventSettingsSelection,
                    hostIntegrations: hostIntegrations,
                    languageStore: preferences,
                    aiCueViewModel: aiCueViewModel,
                    soundPacksEditorOwner: soundPacksEditorOwner,
                    soundPacksEditorNativeEffects: soundPacksEditorNativeEffects,
                    onConfigureSound: {
                        settingsPresentationSession.send(.route(.sounds($0)))
                    },
                    onAudibilityInputsChanged: onEventAudibilityInputsChanged,
                    onAnnouncement: onAnnouncement)
            case .notifications:
                standardDestination { notificationsSettings }
            case .display:
                standardDestination { displaySettings }
            case .sounds:
                VStack(alignment: .leading, spacing: 16) {
                    destinationTitle

                    EmbeddedSoundPacksEditorView(
                        editorOwner: soundPacksEditorOwner,
                        route: soundsRoute,
                        routeRequestRevision:
                            settingsPresentationSession.state.explicitRouteRequestRevision,
                        languageStore: preferences,
                        nativeEffects: soundPacksEditorNativeEffects)
                }
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 20)
            case .usage:
                standardDestination {
                    UsageSettingsView(
                        model: usageSettings,
                        preferences: preferences,
                        focusedTarget: $focusedTarget,
                        onAnnouncement: onAnnouncement)
                }
            case .shortcuts:
                standardDestination {
                    ShortcutSettingsView(
                        model: globalShortcutSettings,
                        preferences: preferences,
                        focusedTarget: $focusedTarget,
                        onAnnouncement: onAnnouncement)
                }
            case .about:
                standardDestination {
                    AboutSettingsView(
                        model: aboutSettings,
                        preferences: preferences,
                        focusedTarget: $focusedTarget,
                        onAnnouncement: onAnnouncement)
                }
            }
        }
    }

    private func standardDestination<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 24) {
                destinationTitle
                content()
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 52)
            .padding(.vertical, 60)
        }
    }

    private var destinationTitle: some View {
        Text(destination.localizedName(language: preferences.language))
            .font(.system(size: 30, weight: .bold))
            .accessibilityAddTraits(.isHeader)
            .accessibilitySortPriority(2)
            .focusable()
            .focused(
                $focusedTarget,
                equals: SettingsWindowFocusTarget.title(destination)
            )
            .accessibilityIdentifier("settings.title.\(destination.rawValue)")
    }

    private var soundsRoute: SoundPacksWindowRoute {
        guard
            case .sounds(let route) = settingsPresentationSession.state.routeResolution.route
        else { return .overview }
        return route
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(l10n.text(.settingsGeneralLanguageDescription))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SettingsSectionCard {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(
                        l10n.text(.settingsGeneralLanguageTitle),
                        selection: languageModeBinding
                    ) {
                        ForEach(ClaudioLanguageMode.allCases) { mode in
                            Text(mode.localizedName(language: preferences.language))
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .focused(
                        $focusedTarget,
                        equals: SettingsWindowFocusTarget.firstAction(.general)
                    )
                    .accessibilityLabel(l10n.text(.settingsGeneralLanguageTitle))
                    .accessibilityValue(
                        preferences.languageMode.localizedName(language: preferences.language)
                    )
                    .accessibilityHint(l10n.text(.settingsGeneralLanguageHint))
                    .accessibilitySortPriority(1)
                    .accessibilityIdentifier("settings.general.language")

                    if preferences.languageMode == .system {
                        Label(
                            l10n.format(
                                .settingsGeneralSystemProjection,
                                preferences.language.selfName as NSString),
                            systemImage: "globe"
                        )
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier(
                            "settings.general.language.system-projection")
                    }
                }
            }

            SettingsSectionCard {
                LoginItemSettingsSection(session: settingsPresentationSession)
            }

            if !preferences.recoveryIssues.isEmpty {
                Label {
                    Text(l10n.text(.settingsGeneralPreferenceRecovery))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                }
                .padding(12)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .accessibilityIdentifier("settings.general.preference-recovery")
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .accessibilityIdentifier(SettingsPresentationAccessibilityID.general)
    }

    private var displaySettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSectionCard {
                InterfaceTextSizeStepperContent(
                    selection: interfaceTextSizeBinding,
                    managesFocus: false,
                    language: preferences.language
                )
                .focused(
                    $focusedTarget,
                    equals: SettingsWindowFocusTarget.firstAction(.display)
                )
                .accessibilityHint(l10n.text(.settingsDisplay.textSizeDescription))
                .accessibilityIdentifier("settings.display.text-size")
            }

            SettingsSectionCard {
                VStack(alignment: .leading, spacing: 10) {
                    Picker(
                        l10n.text(.settingsDisplay.panelWidthTitle),
                        selection: panelWidthPreferenceBinding
                    ) {
                        Text(
                            ClaudioPanelWidthPreference.automatic.localizedDisplayName(
                                preferences.language)
                        )
                        .tag(ClaudioPanelWidthPreference.automatic)
                        Text(
                            ClaudioPanelWidthPreference.compact.localizedDisplayName(
                                preferences.language)
                        )
                        .tag(ClaudioPanelWidthPreference.compact)
                        Text(
                            ClaudioPanelWidthPreference.roomy.localizedDisplayName(
                                preferences.language)
                        )
                        .tag(ClaudioPanelWidthPreference.roomy)
                    }
                    .accessibilityHint(l10n.text(.settingsDisplay.panelWidthDescription))
                    .accessibilityIdentifier("settings.display.panel-width")

                    if panelWidthResolution.isClamped {
                        Text(
                            l10n.format(
                                .settingsDisplay.panelWidthClamped,
                                Int64(panelWidthResolution.effectiveWidth))
                        )
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier("settings.display.panel-width.clamped")
                    }
                }
            }

            SettingsSectionCard {
                Toggle(
                    l10n.text(.settingsDisplay.statusDotTitle),
                    isOn: menuBarStatusDotBinding
                )
                .accessibilityValue(
                    l10n.text(
                        preferences.showsMenuBarStatusDot
                            ? .settingsDisplayStatusDotEnabled
                            : .settingsDisplayStatusDotDisabled)
                )
                .accessibilityHint(l10n.text(.settingsDisplay.statusDotDescription))
                .accessibilityIdentifier("settings.display.status-dot")
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private var notificationsSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSectionCard {
                VStack(alignment: .leading, spacing: 18) {
                    Toggle(isOn: focusQuietBinding) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(l10n.text(.settingsNotificationsFocusTitle))
                                .font(.headline)
                            Text(l10n.text(.settingsNotificationsFocusDescription))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .focused(
                        $focusedTarget,
                        equals: SettingsWindowFocusTarget.firstAction(.notifications)
                    )
                    .accessibilityIdentifier("settings.notifications.focus-toggle")

                    Divider()

                    Toggle(isOn: calendarQuietBinding) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(l10n.text(.settingsNotificationsCalendarTitle))
                                .font(.headline)
                            Text(l10n.text(.settingsNotificationsCalendarDescription))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("settings.notifications.calendar-toggle")
                }
            }

            SettingsSectionCard {
                VStack(alignment: .leading, spacing: 12) {
                    settingsStatusRow(
                        title: l10n.text(.settingsNotificationsPermissionTitle),
                        value: focusAuthorizationText)
                    settingsStatusRow(
                        title: l10n.text(.settingsNotificationsCalendarPermissionTitle),
                        value: calendarAuthorizationText)
                    if dynamicQuietPolicy.presentation.calendarAuthorization == .denied
                        || dynamicQuietPolicy.presentation.calendarAuthorization == .restricted
                    {
                        Button(l10n.text(.settingsNotificationsOpenCalendarPrivacy)) {
                            settingsPresentationSession.send(
                                .performPlatformAction(.openCalendarPrivacySettings))
                        }
                        .accessibilityIdentifier("settings.notifications.calendar-privacy")
                    }
                    settingsStatusRow(
                        title: l10n.text(.settingsNotificationsCurrentReasonTitle),
                        value: dynamicQuietCurrentReasonText)
                    settingsStatusRow(
                        title: l10n.text(.settingsNotificationsSnapshotHealthTitle),
                        value: snapshotHealthText)
                }
            }

            if dynamicQuietPolicy.presentation.hasObserverFailure,
                dynamicQuietPolicy.presentation.currentReason != .observerFailure
            {
                Label {
                    Text(l10n.text(.settingsNotificationsReasonObserverFailure))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                }
                .accessibilityIdentifier("settings.notifications.observer-failure")
            }

            if dynamicQuietPolicy.presentation.snapshotHealth != .current {
                Label {
                    Text(l10n.text(.settingsNotificationsPublicationFailed))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                }
                .padding(12)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .accessibilityIdentifier("settings.notifications.publication-failed")
            }

            Button(l10n.text(.settingsNotificationsOpenEvents)) {
                settingsPresentationSession.send(.route(.destination(.eventsAndSounds)))
            }
            .accessibilityIdentifier("settings.notifications.open-events")
        }
        .frame(maxWidth: 620, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.notifications.dynamic-quiet-policy")
        .onChange(of: dynamicQuietPolicy.presentation) { _ in
            onAnnouncement(dynamicQuietAnnouncement)
        }
    }

    private var focusQuietBinding: Binding<Bool> {
        Binding(
            get: { dynamicQuietPolicy.presentation.focusIsEnabled },
            set: { dynamicQuietPolicy.setFocusEnabled($0) })
    }

    private var interfaceTextSizeBinding: Binding<ClaudioInterfaceTextSize> {
        Binding(
            get: { preferences.interfaceTextSize },
            set: {
                preferences.setInterfaceTextSize($0)
                onAnnouncement(
                    l10n.format(
                        .settingsAnnouncementValue,
                        l10n.text(.interfaceTextSize) as NSString,
                        $0.localizedDisplayName(preferences.language) as NSString)
                )
            })
    }

    private var panelWidthPreferenceBinding: Binding<ClaudioPanelWidthPreference> {
        Binding(
            get: { preferences.panelWidthPreference },
            set: {
                preferences.setPanelWidthPreference($0)
                onAnnouncement(
                    l10n.format(
                        .settingsAnnouncementValue,
                        l10n.text(.settingsDisplay.panelWidthTitle) as NSString,
                        $0.localizedDisplayName(preferences.language) as NSString)
                )
            })
    }

    private var menuBarStatusDotBinding: Binding<Bool> {
        Binding(
            get: { preferences.showsMenuBarStatusDot },
            set: {
                preferences.setShowsMenuBarStatusDot($0)
                onAnnouncement(
                    l10n.text(
                        $0
                            ? .settingsDisplayStatusDotEnabled
                            : .settingsDisplayStatusDotDisabled)
                )
            })
    }

    private var panelWidthResolution: (effectiveWidth: Double, isClamped: Bool) {
        ClaudioGUICore.panelWidthResolution(
            preference: preferences.panelWidthPreference,
            language: preferences.language,
            interfaceTextSize: preferences.interfaceTextSize)
    }

    private var calendarQuietBinding: Binding<Bool> {
        Binding(
            get: { dynamicQuietPolicy.presentation.calendarIsEnabled },
            set: { dynamicQuietPolicy.setCalendarEnabled($0) })
    }

    private var focusAuthorizationText: String {
        switch dynamicQuietPolicy.presentation.focusAuthorization {
        case .notRequested: l10n.text(.settingsNotificationsPermissionNotRequested)
        case .authorized: l10n.text(.settingsNotificationsPermissionAuthorized)
        case .denied: l10n.text(.settingsNotificationsPermissionDenied)
        case .restricted: l10n.text(.settingsNotificationsPermissionRestricted)
        }
    }

    private var calendarAuthorizationText: String {
        switch dynamicQuietPolicy.presentation.calendarAuthorization {
        case .notRequested: l10n.text(.settingsNotificationsPermissionNotRequested)
        case .authorized: l10n.text(.settingsNotificationsPermissionAuthorized)
        case .denied: l10n.text(.settingsNotificationsPermissionDenied)
        case .restricted: l10n.text(.settingsNotificationsPermissionRestricted)
        }
    }

    private var dynamicQuietCurrentReasonText: String {
        switch dynamicQuietPolicy.presentation.currentReason {
        case .policiesDisabled: l10n.text(.settingsNotificationsReasonDisabled)
        case .permissionRequired: l10n.text(.settingsNotificationsReasonPermissionRequired)
        case .noDynamicQuiet: l10n.text(.settingsNotificationsReasonInactive)
        case .focusActive: l10n.text(.settingsNotificationsReasonFocusActive)
        case .calendarBusy: l10n.text(.settingsNotificationsReasonCalendarBusy)
        case .focusAndCalendarBusy:
            l10n.text(.settingsNotificationsReasonFocusAndCalendarBusy)
        case .observerFailure: l10n.text(.settingsNotificationsReasonObserverFailure)
        }
    }

    private var snapshotHealthText: String {
        switch dynamicQuietPolicy.presentation.snapshotHealth {
        case .current: l10n.text(.settingsNotificationsSnapshotCurrent)
        case .publicationFailed: l10n.text(.settingsNotificationsSnapshotPublicationFailed)
        case .expired: l10n.text(.settingsNotificationsSnapshotExpired)
        }
    }

    private var dynamicQuietAnnouncement: String {
        l10n.format(
            .settingsNotificationsAnnouncementSummary,
            focusAuthorizationText as NSString,
            calendarAuthorizationText as NSString,
            dynamicQuietCurrentReasonText as NSString,
            snapshotHealthText as NSString)
    }

    private func settingsStatusRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .foregroundColor(.secondary)
            Spacer(minLength: 20)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var languageModeBinding: Binding<ClaudioLanguageMode> {
        Binding(
            get: { preferences.languageMode },
            set: {
                preferences.setLanguageMode($0)
                onAnnouncement(
                    l10n.format(
                        .settingsAnnouncementValue,
                        l10n.text(.settingsGeneralLanguageTitle) as NSString,
                        $0.localizedName(language: preferences.language) as NSString)
                )
            })
    }

    private func routeFailure(_ failure: SettingsRouteFailure) -> some View {
        Label {
            Text(settingsFailureMessage(failure))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
        }
        .padding(14)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("settings.route.failure.\(destination.rawValue)")
    }

    private func settingsFailureMessage(_ failure: SettingsRouteFailure) -> String {
        switch failure {
        case .invalidSurface(let surface):
            l10n.format(.settingsRouteInvalidSurface, surface.rawValue as NSString)
        case .staleSurface(let surface):
            l10n.format(.settingsRouteStaleSurface, surface.rawValue as NSString)
        case .staleSoundScope(let scope):
            l10n.format(.settingsRouteStaleScope, scope.storedValue as NSString)
        case .staleEvent(let event):
            l10n.format(.settingsRouteStaleEvent, event.cliName as NSString)
        case .invalidSoundPackID:
            l10n.text(.settingsRouteInvalidPack)
        case .staleSoundPack(let packID):
            l10n.format(.settingsRouteStalePack, packID as NSString)
        }
    }

    private func icon(_ destination: SettingsDestination) -> String {
        switch destination {
        case .general: "gearshape"
        case .integrations: "puzzlepiece.extension"
        case .eventsAndSounds: "waveform"
        case .notifications: "bell"
        case .display: "display"
        case .sounds: "speaker.wave.2"
        case .usage: "chart.bar"
        case .shortcuts: "command"
        case .about: "info.circle"
        }
    }

    private func sidebarSectionName(_ section: SettingsSidebarSectionID) -> String {
        switch section {
        case .primary: ""
        case .advanced: l10n.text(.settingsSidebarAdvanced)
        case .product: l10n.text(.settingsSidebarProduct)
        }
    }

    private func sidebarIconColor(_ destination: SettingsDestination) -> Color {
        switch destination {
        case .general: .gray
        case .integrations: .cyan
        case .eventsAndSounds: .red
        case .notifications: .purple
        case .display: .indigo
        case .sounds: .green
        case .usage: .pink
        case .shortcuts: .purple
        case .about: .blue
        }
    }

    private func moveSidebarSelection(
        _ direction: SettingsSidebarMoveDirection,
        from current: SettingsDestination
    ) {
        let next = settingsSidebarDestination(
            moving: direction,
            from: current,
            availableDestinations: preferences.availableSettingsDestinations)
        guard next != current else { return }
        settingsPresentationSession.send(.route(.destination(next)))
        focusedTarget = .sidebar(next)
    }
}
