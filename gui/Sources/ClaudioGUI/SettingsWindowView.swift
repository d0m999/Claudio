import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SoundPacksWindow
import SwiftUI

/// Unified Settings navigation shell. Production preferences expose only migrated destinations;
/// DEBUG previews inject all destinations to validate typed routing and failure presentation.
@MainActor
struct SettingsWindowView: View {
    @ObservedObject var model: SettingsWindowPresentationModel<NSRunningApplication>
    @ObservedObject var preferences: ClaudioPreferences
    @ObservedObject var dynamicQuietPolicy: DynamicQuietPolicyController
    @ObservedObject var loginItemSettings: LoginItemSettingsModel
    let soundPacksEditorOwner: SoundPacksEditorOwner?
    let eventSettingsModel: PanelConfigController?
    let eventSettingsSelection: EventSettingsWindowSelection?
    let hostIntegrations: HostIntegrationPresentationStore?
    let integrationsModel: IntegrationsWindowModel?
    let integrationsFocusCoordinator: IntegrationsWindowFocusCoordinator?
    let aiCueViewModel: AICueGenerationViewModel?
    let audioEnvironment: AudioImportEnvironment?
    let onEventAudibilityInputsChanged: (@MainActor () -> Void)?
    let onEventPackSwitch: (@MainActor (PanelPackSwitchOutcome) -> Void)?
    let onAdoptAICue:
        (
            @MainActor (AICueAdoptionRequest) async -> Result<
                AICueAdoptionOutcome, AICueAdoptionError
            >
        )?

    @FocusState private var focusedTarget: SettingsWindowFocusTarget?

    private var l10n: ClaudioL10n { ClaudioL10n(language: preferences.language) }
    private var destination: SettingsDestination { model.resolution.destination }

    init(
        model: SettingsWindowPresentationModel<NSRunningApplication>,
        preferences: ClaudioPreferences,
        dynamicQuietPolicy: DynamicQuietPolicyController,
        loginItemSettings: LoginItemSettingsModel,
        soundPacksEditorOwner: SoundPacksEditorOwner? = nil,
        eventSettingsModel: PanelConfigController? = nil,
        eventSettingsSelection: EventSettingsWindowSelection? = nil,
        hostIntegrations: HostIntegrationPresentationStore? = nil,
        integrationsModel: IntegrationsWindowModel? = nil,
        integrationsFocusCoordinator: IntegrationsWindowFocusCoordinator? = nil,
        aiCueViewModel: AICueGenerationViewModel? = nil,
        audioEnvironment: AudioImportEnvironment? = nil,
        onEventAudibilityInputsChanged: (@MainActor () -> Void)? = nil,
        onEventPackSwitch: (@MainActor (PanelPackSwitchOutcome) -> Void)? = nil,
        onAdoptAICue:
            (
                @MainActor (AICueAdoptionRequest) async -> Result<
                    AICueAdoptionOutcome, AICueAdoptionError
                >
            )? = nil
    ) {
        self.model = model
        self.preferences = preferences
        self.dynamicQuietPolicy = dynamicQuietPolicy
        self.loginItemSettings = loginItemSettings
        self.soundPacksEditorOwner = soundPacksEditorOwner
        self.eventSettingsModel = eventSettingsModel
        self.eventSettingsSelection = eventSettingsSelection
        self.hostIntegrations = hostIntegrations
        self.integrationsModel = integrationsModel
        self.integrationsFocusCoordinator = integrationsFocusCoordinator
        self.aiCueViewModel = aiCueViewModel
        self.audioEnvironment = audioEnvironment
        self.onEventAudibilityInputsChanged = onEventAudibilityInputsChanged
        self.onEventPackSwitch = onEventPackSwitch
        self.onAdoptAICue = onAdoptAICue
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 252)
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            routeSlot
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: SettingsWindowGeometry.minimumWidth,
            minHeight: SettingsWindowGeometry.minimumHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l10n.text(.settingsWindowTitle))
        .onReceive(model.$routeRequestRevision) { _ in
            if destination == .integrations,
                let integrationsModel,
                let integrationsFocusCoordinator
            {
                guard model.resolution.failure == nil else {
                    focusedTarget = SettingsWindowFocusTarget.title(destination)
                    return
                }
                if case .integrations(let surface) = model.resolution.route,
                    let host = HostID.productVisibleCases.first(where: {
                        $0.surfaceID == surface
                    })
                {
                    integrationsModel.select(.host(host))
                    integrationsFocusCoordinator.requestFocus(.hostCard(host))
                } else {
                    integrationsFocusCoordinator.cancelPendingRequest()
                    focusedTarget = SettingsWindowFocusTarget.title(destination)
                }
            } else if destination == .eventsAndSounds,
                let eventSettingsSelection,
                let eventSettingsModel
            {
                guard model.resolution.failure == nil else {
                    focusedTarget = SettingsWindowFocusTarget.title(destination)
                    return
                }
                if let route = eventSettingsRoute {
                    eventSettingsSelection.select(route)
                    eventSettingsModel.selectSoundSurface(route.surface)
                }
                eventSettingsSelection.requestInitialFocus()
            } else if destination != .sounds {
                focusedTarget = SettingsWindowFocusTarget.title(destination)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("claudi0")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

            ForEach(preferences.availableSettingsDestinations) { item in
                Button {
                    model.request(.destination(item))
                } label: {
                    Label(
                        item.localizedName(language: preferences.language),
                        systemImage: icon(item))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(
                                    item == destination
                                        ? Color.accentColor.opacity(0.16) : .clear))
                }
                .buttonStyle(.plain)
                .focused($focusedTarget, equals: SettingsWindowFocusTarget.sidebar(item))
                .accessibilityLabel(item.localizedName(language: preferences.language))
                .accessibilitySortPriority(3)
                .accessibilityIdentifier("settings.sidebar.\(item.rawValue)")
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 20)
    }

    @ViewBuilder
    private var routeSlot: some View {
        if destination == .integrations,
            model.resolution.failure == nil,
            let integrationsModel,
            let integrationsFocusCoordinator
        {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    destinationTitle
                    Spacer(minLength: 16)
                    Button(l10n.text(.settingsIntegrationsManageEvents)) {
                        manageSelectedIntegrationEvents(in: integrationsModel)
                    }
                    .focused(
                        $focusedTarget,
                        equals: SettingsWindowFocusTarget.firstAction(.integrations)
                    )
                    .accessibilityHint(l10n.text(.settingsIntegrationsManageEventsHint))
                    .accessibilityIdentifier("settings.integrations.manage-events")
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)

                IntegrationsWindowView(
                    model: integrationsModel,
                    focusCoordinator: integrationsFocusCoordinator,
                    languageStore: preferences)
            }
        } else if destination == .eventsAndSounds,
            model.resolution.failure == nil,
            let soundPacksEditorOwner,
            let eventSettingsModel,
            let eventSettingsSelection,
            let hostIntegrations,
            let aiCueViewModel,
            let audioEnvironment,
            let onEventAudibilityInputsChanged,
            let onEventPackSwitch,
            let onAdoptAICue
        {
            EventSettingsWindowView(
                model: eventSettingsModel,
                selection: eventSettingsSelection,
                hostIntegrations: hostIntegrations,
                languageStore: preferences,
                aiCueViewModel: aiCueViewModel,
                soundPacksModel: soundPacksEditorOwner.model,
                audioEnvironment: audioEnvironment,
                onConfigureSound: { model.request(.sounds($0)) },
                onAudibilityInputsChanged: onEventAudibilityInputsChanged,
                onPackSwitch: onEventPackSwitch,
                onAdoptAICue: onAdoptAICue,
                presentationContext: .unifiedSettings)
        } else if destination == .sounds,
            model.resolution.failure == nil,
            let soundPacksEditorOwner
        {
            VStack(alignment: .leading, spacing: 16) {
                destinationTitle

                EmbeddedSoundPacksEditorView(
                    editorOwner: soundPacksEditorOwner,
                    route: soundsRoute,
                    routeRequestRevision: model.routeRequestRevision,
                    languageStore: preferences)
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 20)
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 24) {
                    destinationTitle

                    if let failure = model.resolution.failure {
                        routeFailure(failure)
                    } else if destination == .general {
                        generalSettings
                    } else if destination == .notifications {
                        notificationsSettings
                    } else {
                        debugRouteContent
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, 52)
                .padding(.vertical, 60)
            }
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
        guard case .sounds(let route) = model.resolution.route else { return .overview }
        return route
    }

    private var eventSettingsRoute: EventSettingsWindowRoute? {
        guard case .events(let scope, let event) = model.resolution.route else { return nil }
        return EventSettingsWindowRoute(scope: scope, event: event)
    }

    private func manageSelectedIntegrationEvents(in integrationsModel: IntegrationsWindowModel) {
        let host = integrationsModel.selection.host
        let event: Event?
        switch integrationsModel.selection {
        case .host:
            event = nil
        case .capability(_, let selectedEvent):
            event = selectedEvent
        }
        model.request(.events(scope: .surface(host.surfaceID), event: event))
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(l10n.text(.settingsGeneralLanguageDescription))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
                .accessibilityIdentifier("settings.general.language.system-projection")
            }

            Divider()

            LoginItemSettingsSection(model: loginItemSettings, l10n: l10n)

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
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("settings.general.preference-recovery")
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private var debugRouteContent: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                Text(l10n.text(.settingsRouteIdentity))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(model.resolution.route.stableIdentityComponents.joined(separator: " / "))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }

            Label(l10n.text(.settingsRouteReady), systemImage: "checkmark.circle.fill")
                .foregroundColor(.secondary)
                .accessibilityIdentifier("settings.route.ready")

            Button(l10n.text(.settingsRouteReturnToSidebar)) {
                focusedTarget = SettingsWindowFocusTarget.sidebar(destination)
            }
            .focused(
                $focusedTarget,
                equals: SettingsWindowFocusTarget.firstAction(destination)
            )
            .accessibilitySortPriority(1)
            .accessibilityIdentifier("settings.first-action.\(destination.rawValue)")
        }
    }

    private var notificationsSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
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

            Divider()

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
                    openCalendarPrivacySettings()
                }
                .accessibilityIdentifier("settings.notifications.calendar-privacy")
            }
            settingsStatusRow(
                title: l10n.text(.settingsNotificationsCurrentReasonTitle),
                value: dynamicQuietCurrentReasonText)
            settingsStatusRow(
                title: l10n.text(.settingsNotificationsSnapshotHealthTitle),
                value: snapshotHealthText)

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
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("settings.notifications.publication-failed")
            }

            Button(l10n.text(.settingsNotificationsOpenEvents)) {
                model.request(.destination(.eventsAndSounds))
            }
            .accessibilityIdentifier("settings.notifications.open-events")
        }
        .frame(maxWidth: 620, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.notifications.dynamic-quiet-policy")
    }

    private var focusQuietBinding: Binding<Bool> {
        Binding(
            get: { dynamicQuietPolicy.presentation.focusIsEnabled },
            set: { dynamicQuietPolicy.setFocusEnabled($0) })
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

    private func openCalendarPrivacySettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        else { return }
        NSWorkspace.shared.open(url)
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
            set: { preferences.setLanguageMode($0) })
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
}

@MainActor
private struct LoginItemSettingsSection: View {
    @ObservedObject var model: LoginItemSettingsModel
    let l10n: ClaudioL10n

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n.text(.settingsGeneralLoginItem.description))
                .foregroundColor(.secondary)

            Toggle(
                l10n.text(.settingsGeneralLoginItem.toggle),
                isOn: enabledBinding
            )
            .disabled(!model.projection.registration.canToggle)
            .accessibilityHint(l10n.text(.settingsGeneralLoginItem.hint))
            .accessibilityValue(statusText)
            .accessibilityIdentifier("settings.general.login-item.toggle")

            Text(statusText)
                .foregroundColor(.secondary)

            if model.projection.registration == .requiresApproval {
                Button(l10n.text(.settingsGeneralLoginItem.openSettings)) {
                    model.openSystemSettings()
                }
                .accessibilityHint(l10n.text(.settingsGeneralLoginItem.openSettingsHint))
            }

            if let failure = model.projection.failure {
                VStack(alignment: .leading, spacing: 8) {
                    FailureRow(
                        message: failureText(
                            failure.reason,
                            requestedEnabled: failure.requestedEnabled))

                    Button(l10n.text(.commonRetry)) {
                        model.retryFailedOperation()
                    }
                }
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { model.projection.registration.isOn },
            set: { model.setEnabled($0) })
    }

    private var statusText: String {
        switch model.projection.registration {
        case .disabled: l10n.text(.settingsGeneralLoginItem.disabled)
        case .enabled: l10n.text(.settingsGeneralLoginItem.enabled)
        case .requiresApproval: l10n.text(.settingsGeneralLoginItem.requiresApproval)
        case .unavailable: l10n.text(.settingsGeneralLoginItem.unavailable)
        }
    }

    private func failureText(
        _ reason: LoginItemOperationFailureReason,
        requestedEnabled: Bool
    ) -> String {
        switch reason {
        case .embeddedLoginItemMissing:
            l10n.text(.settingsGeneralLoginItem.failureMissing)
        case .systemRejected:
            l10n.text(
                requestedEnabled
                    ? .settingsGeneralLoginItem.failureEnable
                    : .settingsGeneralLoginItem.failureDisable)
        }
    }
}
