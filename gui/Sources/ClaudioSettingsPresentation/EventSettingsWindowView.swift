import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import Combine
import SoundPacksWindow
import SwiftUI

/// Production Events & Sounds surface corresponding to the prototype's scoped events page.
/// It reuses the panel's manager-owned scope and event projections; full per-event file editing
/// routes inside the same retained Settings window to the embedded Sounds editor.
@MainActor
package struct EventSettingsWindowView: View {
    @ObservedObject var model: PanelConfigController
    @ObservedObject var selection: EventSettingsWindowSelection
    @ObservedObject var hostIntegrations: HostIntegrationPresentationStore
    @ObservedObject var languageStore: ClaudioPreferences
    @ObservedObject var aiCueViewModel: AICueGenerationViewModel
    @ObservedObject var soundPacksEditorOwner: SoundPacksEditorOwner

    let soundPacksEditorNativeEffects: SoundPacksEditorNativeEffectsDispatcher
    let onConfigureSound: @MainActor (SoundPacksWindowRoute) -> Void
    let onAudibilityInputsChanged: @MainActor () -> Void
    let onAnnouncement: @MainActor (String) -> Void
    #if DEBUG
    var reloadsOnAppear = true
    #endif
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedTarget: EventSettingsFocusTarget?
    @State private var handledFocusRequestRevision: UInt64 = 0
    @State private var playingCandidateID: UUID?
    @State private var playingCandidateTitle: String?
    @State private var showsCredentialSheet = false
    @State private var previewAllTask: Task<Void, Never>?
    @State private var previewAllFailureEvent: Event?
    @State private var previewAllCoordinator = EventPreviewSequenceCoordinator()

    package init(
        model: PanelConfigController,
        selection: EventSettingsWindowSelection,
        hostIntegrations: HostIntegrationPresentationStore,
        languageStore: ClaudioPreferences,
        aiCueViewModel: AICueGenerationViewModel,
        soundPacksEditorOwner: SoundPacksEditorOwner,
        soundPacksEditorNativeEffects: SoundPacksEditorNativeEffectsDispatcher,
        onConfigureSound: @escaping @MainActor (SoundPacksWindowRoute) -> Void,
        onAudibilityInputsChanged: @escaping @MainActor () -> Void,
        onAnnouncement: @escaping @MainActor (String) -> Void
    ) {
        self.model = model
        self.selection = selection
        self.hostIntegrations = hostIntegrations
        self.languageStore = languageStore
        self.aiCueViewModel = aiCueViewModel
        self.soundPacksEditorOwner = soundPacksEditorOwner
        self.soundPacksEditorNativeEffects = soundPacksEditorNativeEffects
        self.onConfigureSound = onConfigureSound
        self.onAudibilityInputsChanged = onAudibilityInputsChanged
        self.onAnnouncement = onAnnouncement
    }

    private var l10n: ClaudioL10n { ClaudioL10n(language: languageStore.language) }
    private var interfaceTextSize: ClaudioInterfaceTextSize { languageStore.interfaceTextSize }
    private var scopes: [PanelSoundScopePresentation] {
        panelSoundScopePresentations(
            sourceRows: hostIntegrations.content.sourceRows,
            config: model.configState.resolvedConfig,
            language: languageStore.language)
    }
    private var resolvedScope: PanelSoundScopeID? {
        resolvedEventSettingsScope(route: selection.route, scopes: scopes)
    }
    private var selectedScope: PanelSoundScopePresentation {
        resolvedScope.flatMap { resolved in
            scopes.first(where: { $0.scope == resolved })
        } ?? scopes[0]
    }
    private var routeIsUnavailable: Bool {
        resolvedScope == nil
    }
    private var eventsEditorPresentation: EventsSoundPackPresentation? {
        guard case .events(let presentation) = soundPacksEditorOwner.presentation.mode,
            presentation.route == editorRoute,
            presentation.requestRevision == selection.routeRequestRevision
        else {
            return nil
        }
        return presentation
    }
    private var editorRoute: EventSettingsWindowRoute {
        guard let session = aiCueViewModel.session else { return selection.route }
        return EventSettingsWindowRoute(scope: session.scope, event: session.event)
    }
    private var editorLibraryHasUsableSnapshot: Bool {
        switch soundPacksEditorOwner.presentation.library {
        case .ready, .loading(previousAvailable: true), .failed(previousAvailable: true, _):
            return true
        case .unloaded, .loading(previousAvailable: false),
            .failed(previousAvailable: false, _):
            return false
        }
    }
    private var scopeProjectionIsAligned: Bool {
        resolvedScope == selectedScope.scope
            && model.selectedSurface == selectedScope.scope.surface
    }
    private var events: [PanelEventPresentation] {
        panelEventPresentations(
            rows: model.eventRows,
            scope: selectedScope.scope,
            masterVolume: model.config.masterVolume,
            language: languageStore.language,
            configWritesAllowed: model.surfaceSoundIssue == nil)
    }
    private var previewableEvents: [Event] {
        guard let editor = eventsEditorPresentation else { return [] }
        return events.compactMap { presentation in
            guard presentation.controls.previewEnabled,
                editor.eventAccess.first(where: { $0.event == presentation.event })?
                    .previewAction != nil
            else { return nil }
            return presentation.event
        }
    }
    private var editorCapabilityUnavailableHint: String {
        switch soundPacksEditorOwner.presentation.library {
        case .loading(previousAvailable: true):
            return l10n.text(.panelLoadingEvents)
        case .failed(previousAvailable: true, let reason):
            return l10n.format(
                .soundPacksLibraryRefreshFailed,
                localizedLibraryFailure(reason))
        case .unloaded, .loading(previousAvailable: false), .ready,
            .failed(previousAvailable: false, _):
            return l10n.text(.panelUnavailableEvents)
        }
    }

    package var body: some View {
        HStack(spacing: 0) {
            scopeSidebar
                .frame(width: 230)
                .frame(maxHeight: .infinity)
                .background(ClaudioTheme.elevated(colorScheme))
            Divider()
            eventContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ClaudioTheme.panel(colorScheme))
        .frame(minWidth: 680, minHeight: 520)
        .environment(\.dynamicTypeSize, interfaceTextSize.dynamicTypeSize)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l10n.text(.eventSettingsWindowTitle))
        .onReceive(selection.$presentationState) { presentation in
            let revision = presentation.focusRequestRevision
            guard revision > handledFocusRequestRevision else { return }
            handledFocusRequestRevision = revision
            if eventSettingsShouldCloseAICueComposer(
                includesAICueComposer: true,
                targetSurface: aiCueViewModel.session?.scope.surface,
                targetEvent: aiCueViewModel.session?.event,
                selectedSurface: selectedScope.scope.surface,
                selectedEvent: selection.route.event)
            {
                closeAICueComposer()
            }
            focusedTarget = presentation.focusTarget
        }
        .onAppear {
            #if DEBUG
            if reloadsOnAppear {
                model.reload()
            }
            #else
            model.reload()
            #endif
            reconcileScopeSelection()
        }
        .onChange(of: selection.route) { _ in
            stopAllPreviews()
            reconcileScopeSelection()
        }
        .onChange(of: scopes.map(\.scope)) { _ in
            stopAllPreviews()
            reconcileScopeSelection()
        }
        .onReceive(
            selection.$presentationState
                .map(\.previewStopRequestRevision)
                .removeDuplicates()
        ) { _ in
            stopAllPreviews()
        }
        .onReceive(
            selection.$presentationState
                .map(\.aiSessionEndRequestRevision)
                .removeDuplicates()
        ) { _ in
            stopCandidatePreview()
            showsCredentialSheet = false
        }
        .onChange(of: model.config.selectedPack) { _ in
            closeAICueComposer()
        }
        .onChange(of: aiCueViewModel.providerProfileID) { _ in
            stopCandidatePreview()
        }
        .onChange(of: aiCueViewModel.requiresCredentialConfiguration) { required in
            if required {
                showsCredentialSheet = true
            }
        }
        .task {
            await aiCueViewModel.refreshCredentialStatus()
        }
        .sheet(isPresented: $showsCredentialSheet) {
            EventSettingsAICueCredentialSheet(
                viewModel: aiCueViewModel,
                languageStore: languageStore)
        }
        .onDisappear {
            cancelPreviewSequenceState()
            stopCandidatePreview()
        }
    }

    private var scopeSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n.text(.panelSoundScope))
                .font(ClaudioTheme.font(.sectionTitle))
                .foregroundColor(ClaudioTheme.text(colorScheme))
                .padding(.horizontal, 16)
                .padding(.top, 18)

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 6) {
                    scopeOptions
                }
                .padding(.horizontal, 10)
            }
        }
    }

    @ViewBuilder
    private var scopeOptions: some View {
        if let global = scopes.first(where: { $0.scope == .global }) {
            scopeButton(global)
        }
        ForEach(hostSourceProductGroups(from: hostIntegrations.content.sourceRows)) { group in
            Text(group.title)
                .font(ClaudioTheme.font(.caption).weight(.semibold))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 9)
                .accessibilityAddTraits(.isHeader)
            ForEach(scopesForProduct(group.product)) { scope in
                scopeButton(scope)
            }
        }
    }

    private func scopesForProduct(_ product: HostProductID) -> [PanelSoundScopePresentation] {
        scopes.filter { $0.host?.descriptor.product == product }
    }

    private func scopeButton(_ scope: PanelSoundScopePresentation) -> some View {
        Button {
            selectScope(scope.scope)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(scope.name)
                        .font(ClaudioTheme.font(.body).weight(.semibold))
                    Text(scope.summaryText)
                        .font(ClaudioTheme.font(.caption))
                        .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                }
                Spacer(minLength: 4)
                if resolvedScope == scope.scope {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(ClaudioTheme.clay(colorScheme))
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control)
                    .fill(
                        resolvedScope == scope.scope
                            ? ClaudioTheme.clay(colorScheme).opacity(0.14)
                            : Color.clear))
        }
        .buttonStyle(ClaudioFullRowButtonStyle())
        .focused($focusedTarget, equals: .scope(scope.scope))
        .accessibilityLabel(scope.accessibilityLabel)
        .accessibilityValue(
            resolvedScope == scope.scope
                ? l10n.text(.integrationsSelected)
                : l10n.text(.integrationsNotSelected)
        )
        .accessibilityIdentifier("event-settings.scope.\(scope.scope.storedValue)")
    }

    private var eventContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            eventHeader
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            if let unavailableScope = selection.unavailableRequestedScopeStoredValue {
                Label {
                    Text(
                        l10n.format(
                            .eventSettingsUnavailableShortcutScope,
                            unavailableScope as NSString)
                    )
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(ClaudioTheme.error(colorScheme))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
                .accessibilityIdentifier("event-settings.shortcut-scope-failure")
            }
            if let failedEvent = previewAllFailureEvent {
                FailureRow(message: previewAllFailureMessage(for: failedEvent))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 18)
                    .accessibilityIdentifier("event-settings.preview-all-failure")
            }
            EventSettingsAICueServiceCard(
                viewModel: aiCueViewModel,
                languageStore: languageStore,
                onManageCredential: { showsCredentialSheet = true }
            )
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
            if let eligibility = aiCuePageEligibility,
                case .ineligible = eligibility
            {
                aiCueAvailabilityNotice(eligibility)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 18)
            }
            Divider()
            GeometryReader { geometry in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 20) {
                        eventRows(availableWidth: max(0, geometry.size.width - 48))
                        playbackSettings
                    }
                    .padding(24)
                }
            }
            .disabled(routeIsUnavailable)
        }
    }

    private var eventHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(l10n.text(.eventSettingsTitle))
                    .font(ClaudioTheme.font(.productTitle).weight(.bold))
                    .foregroundColor(ClaudioTheme.text(colorScheme))
                if let unavailableScope = selection.unavailableRequestedScopeStoredValue {
                    Text(
                        l10n.format(
                            .eventSettingsUnavailableShortcutScope,
                            unavailableScope as NSString)
                    )
                    .font(ClaudioTheme.font(.body))
                    .foregroundColor(ClaudioTheme.error(colorScheme))
                } else {
                    Text(selectedScope.name + " · " + selectedScope.summaryText)
                        .font(ClaudioTheme.font(.body))
                        .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    Text(
                        l10n.text(.panelSoundPackLabel) + " · "
                            + (model.selectedPackMetadata.displayName.isEmpty
                                ? l10n.text(.panelSelectedPackNone)
                                : model.selectedPackMetadata.displayName)
                    )
                    .font(ClaudioTheme.font(.caption))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("event-settings.header")
            Spacer(minLength: 8)
            Button {
                playAllPreviews()
            } label: {
                Label(
                    l10n.text(
                        previewAllTask == nil
                            ? .eventSettingsPreviewAll : .eventSettingsStopPreviewAll),
                    systemImage: previewAllTask == nil ? "play.fill" : "stop.fill")
            }
            .buttonStyle(.bordered)
            .disabled(
                routeIsUnavailable
                    || previewableEvents.isEmpty
            )
            .focused($focusedTarget, equals: .previewAll)
            .accessibilityLabel(
                l10n.text(
                    previewAllTask == nil
                        ? .eventSettingsPreviewAll : .eventSettingsStopPreviewAll)
            )
            .accessibilityHint(
                l10n.text(
                    previewAllTask == nil
                        ? .eventSettingsPreviewAllHint : .eventSettingsStopPreviewAllHint)
            )
            .accessibilityIdentifier("event-settings.preview-all")
        }
    }

    private var aiCuePageEligibility: SoundPackEditorAdoptionAvailability? {
        guard
            scopeProjectionIsAligned,
            case .events = model.configState.topContent,
            editorLibraryHasUsableSnapshot,
            let access = eventsEditorPresentation?.eventAccess.first(where: {
                $0.event == .stop
            })
        else { return nil }
        return access.adoptionAvailability
    }

    private func aiCueAvailabilityNotice(
        _ eligibility: SoundPackEditorAdoptionAvailability
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .accessibilityHidden(true)
            Text(aiCueEligibilityHint(eligibility))
                .font(ClaudioTheme.font(.caption))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if selectedScope.scope.surface != nil {
                Button(l10n.text(.panelManageSoundPacks)) {
                    onConfigureSound(.overview(surface: selectedScope.scope.surface))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(l10n.text(.panelManageSoundPacks))
                .accessibilityHint(aiCueEligibilityHint(eligibility))
                .accessibilityIdentifier("event-settings.ai-cue.resolve-eligibility")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(ClaudioTheme.elevated(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("event-settings.ai-cue.eligibility")
    }

    private var playbackSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n.text(.panelPlaybackSettings))
                .font(ClaudioTheme.font(.sectionTitle))
                .foregroundColor(ClaudioTheme.text(colorScheme))

            VStack(alignment: .leading, spacing: 14) {
                EventSettingsMasterVolumeControl(
                    diskVolume: model.config.masterVolume,
                    isEnabled: editorLibraryHasUsableSnapshot,
                    language: languageStore.language,
                    focusedTarget: $focusedTarget
                ) { volume in
                    let landed = model.setMasterVolume(volume)
                    onAudibilityInputsChanged()
                    return landed
                }

                Divider()

                VStack(alignment: .leading, spacing: 7) {
                    Picker(l10n.text(.panelSoundPackLabel), selection: selectedPackBinding) {
                        if !model.config.selectedPack.isEmpty,
                            !(eventsEditorPresentation?.packs ?? []).contains(where: {
                                $0.id == model.config.selectedPack
                            })
                        {
                            Text(model.selectedPackMetadata.displayName)
                                .tag(model.config.selectedPack)
                        }
                        ForEach(eventsEditorPresentation?.packs ?? [], id: \.id) { card in
                            Text(SelectedPackMetadata(id: card.id, name: card.name).displayName)
                                .tag(card.id)
                        }
                    }
                    .disabled(
                        !editorLibraryHasUsableSnapshot
                            || model.surfaceSoundIssue != nil
                            || (eventsEditorPresentation?.packs.isEmpty ?? true)
                    )
                    .focused($focusedTarget, equals: .packPicker)
                    .accessibilityIdentifier("event-settings.sound-pack-picker")

                    Text(soundPackInheritanceText)
                        .font(ClaudioTheme.font(.caption))
                        .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button(l10n.text(.eventSettingsManageSounds)) {
                            onConfigureSound(.overview(surface: selectedScope.scope.surface))
                        }
                        .buttonStyle(.bordered)
                        .focused($focusedTarget, equals: .manageSoundPacks)
                        .accessibilityHint(l10n.text(.eventSettingsManageSoundsHint))
                        .accessibilityIdentifier("event-settings.manage-sounds")

                        if selectedScope.scope.surface != nil {
                            Button(l10n.text(.panelResetSurface)) {
                                stopAllPreviews()
                                model.resetSelectedSurfaceOverrides()
                                onAudibilityInputsChanged()
                            }
                            .buttonStyle(.borderless)
                            .help(l10n.text(.panelResetSurfaceHint))
                            .accessibilityHint(l10n.text(.panelResetSurfaceHint))
                            .accessibilityIdentifier("event-settings.reset-surface")
                        }
                    }
                }
            }
            .padding(14)
            .background(ClaudioTheme.elevated(colorScheme))
            .overlay(
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control)
                    .strokeBorder(ClaudioTheme.hairline(colorScheme), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("event-settings.playback-settings")
    }

    private var selectedPackBinding: Binding<String> {
        Binding(
            get: { model.config.selectedPack },
            set: { packID in
                guard packID != model.config.selectedPack else { return }
                stopAllPreviews()
                let outcome = model.switchPack(to: packID)
                _ = soundPacksEditorOwner.send(.completePanelPackSwitch(outcome))
                if outcome == .succeeded {
                    onAudibilityInputsChanged()
                }
            })
    }

    private var soundPackInheritanceText: String {
        switch eventSettingsPackInheritanceState(
            config: model.configState.resolvedConfig,
            scope: selectedScope.scope)
        {
        case .globalDefault:
            return l10n.text(.panelGlobalInheritance)
        case .inheritedGlobal:
            return l10n.text(.panelInheritedGlobal)
        case .surfaceOverride:
            return l10n.text(.panelSurfaceOverride)
        case .invalidSurfaceOverride:
            return model.surfaceSoundIssue
                ?? l10n.format(.soundPacksDamagedScope, selectedScope.name as NSString)
        }
    }

    private func playAllPreviews() {
        if previewAllTask != nil {
            selection.requestPreviewStop()
            stopAllPreviews()
            return
        }
        stopAllPreviews()
        let eventsToPreview = previewableEvents
        let generation = selection.beginPreviewSequence()
        previewAllTask = Task { @MainActor in
            let result = await previewAllCoordinator.run(
                events: eventsToPreview,
                onPlay: { event in
                    guard
                        let action = eventsEditorPresentation?.eventAccess.first(where: {
                            $0.event == event
                        })?.previewAction
                    else { return nil }
                    return soundPacksEditorNativeEffects.playPreview(
                        action,
                        owner: soundPacksEditorOwner)
                })
            guard selection.completePreviewSequence(generation: generation) else { return }
            switch result {
            case .empty:
                break
            case .failed(let event):
                soundPacksEditorNativeEffects.stopPreview(owner: soundPacksEditorOwner)
                previewAllFailureEvent = event
                onAnnouncement(previewAllFailureMessage(for: event))
            case .completed, .cancelled:
                break
            }
            previewAllTask = nil
        }
    }

    private func stopAllPreviews() {
        cancelPreviewSequenceState()
        soundPacksEditorNativeEffects.stopPreview(owner: soundPacksEditorOwner)
        selection.notePreviewStopped()
    }

    private func cancelPreviewSequenceState() {
        previewAllTask?.cancel()
        previewAllTask = nil
        previewAllFailureEvent = nil
        previewAllCoordinator.cancel()
    }

    private func previewAllFailureMessage(for event: Event) -> String {
        let title = events.first(where: { $0.event == event })?.title ?? event.rawValue
        return l10n.format(.eventSettingsPreviewAllFailure, title as NSString)
    }

    @ViewBuilder
    private func eventRows(availableWidth: CGFloat) -> some View {
        let windowLayout = eventSettingsWindowLayout(
            availableWidth: Double(availableWidth),
            typeScale: interfaceTextSize.scale)
        if routeIsUnavailable {
            EmptyView()
        } else {
            switch model.configState.topContent {
            case .events:
                if scopeProjectionIsAligned {
                    if editorLibraryHasUsableSnapshot {
                        VStack(alignment: .leading, spacing: 12) {
                            if case .failed(previousAvailable: true, let reason) =
                                soundPacksEditorOwner.presentation.library
                            {
                                libraryFailure(reason, previousAvailable: true)
                            }
                            if !writeFailureMessages.isEmpty {
                                writeFailures
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(events.enumerated()), id: \.element.id) {
                                    index, event in
                                    let editorAccess =
                                        eventsEditorPresentation?.eventAccess.first(where: {
                                            $0.event == event.event
                                        })
                                    let eligibility =
                                        editorAccess?.adoptionAvailability
                                        ?? .ineligible(.writesStopped)
                                    EventSettingsEventRow(
                                        presentation: event,
                                        previewAvailability: editorAccess?.previewAvailability,
                                        previewActionAvailable: editorAccess?.previewAction != nil,
                                        previewCapabilityUnavailableHint:
                                            editorCapabilityUnavailableHint,
                                        windowLayout: windowLayout,
                                        language: languageStore.language,
                                        focusedTarget: $focusedTarget,
                                        onGenerateAICue: {
                                            openAICueComposer(
                                                eligibility,
                                                event: event.event)
                                        },
                                        onPreview: { playPreview(event.event) },
                                        onToggleMute: {
                                            model.toggleMute(event.event)
                                            onAudibilityInputsChanged()
                                        },
                                        onConfigureSound: {
                                            onConfigureSound(
                                                EventSettingsWindowRoute(scope: selectedScope.scope)
                                                    .soundPacksRoute(
                                                        packID: model.config.selectedPack,
                                                        event: event.event))
                                        },
                                        inheritanceText: eventInheritanceText(event.event),
                                        aiCueGenerationEnabled: aiCueGenerationIsEnabled(
                                            eligibility),
                                        aiCueGenerationHint: aiCueEligibilityHint(eligibility),
                                        soundEditingEnabled: !model.config.selectedPack.isEmpty
                                            && model.surfaceSoundIssue == nil,
                                        writeDisabledReason: model.surfaceSoundIssue)
                                    if eventSettingsAICueComposerMatches(
                                        targetSurface: aiCueViewModel.session?.scope.surface,
                                        targetEvent: aiCueViewModel.session?.event,
                                        selectedSurface: selectedScope.scope.surface,
                                        event: event.event)
                                    {
                                        EventSettingsAICueComposerView(
                                            viewModel: aiCueViewModel,
                                            languageStore: languageStore,
                                            eventTitle: event.title,
                                            playingCandidateID: playingCandidateID,
                                            adoptionEnabled:
                                                eventsEditorPresentation?.adoptionPermit != nil,
                                            adoptionUnavailableHint:
                                                editorCapabilityUnavailableHint,
                                            onConfigureCredential: { showsCredentialSheet = true },
                                            onPreviewCandidate: previewAICueCandidate,
                                            onAdoptCandidate: adoptAICueCandidate,
                                            onClose: closeAICueComposer
                                        )
                                        .padding(.vertical, 10)
                                    }
                                    if index < events.count - 1 {
                                        Divider().opacity(0.65)
                                    }
                                }
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("event-settings.events")
                    } else {
                        libraryUnavailableSection
                    }
                } else {
                    ProgressView()
                        .accessibilityLabel(l10n.text(.panelLoadingEvents))
                }
            case .needsPack:
                VStack(alignment: .leading, spacing: 12) {
                    Text(l10n.text(.panelNeedsPackSettingsMessage))
                        .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    Button(l10n.text(.panelManageSoundPacks)) {
                        onConfigureSound(.overview(surface: selectedScope.scope.surface))
                    }
                    .focused($focusedTarget, equals: .manageSoundPacks)
                    .help(l10n.text(.panelManageSoundPacksHint))
                    .accessibilityHint(l10n.text(.panelManageSoundPacksHint))
                    .accessibilityIdentifier("event-settings.manage-sound-packs")
                }
            case .configFailure(let reason):
                FailureRow(message: reason)
            }
        }
    }

    @ViewBuilder
    private var libraryUnavailableSection: some View {
        switch soundPacksEditorOwner.presentation.library {
        case .unloaded, .loading(previousAvailable: false):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text(l10n.text(.panelLoadingEvents))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            }
            .accessibilityIdentifier("event-settings.library.loading")
        case .failed(previousAvailable: false, let reason):
            libraryFailure(reason, previousAvailable: false)
        case .ready, .loading(previousAvailable: true), .failed(previousAvailable: true, _):
            EmptyView()
        }
    }

    private func libraryFailure(
        _ reason: SoundPackEditorLibraryFailureReason,
        previousAvailable: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            FailureRow(
                message: previousAvailable
                    ? l10n.format(
                        .soundPacksLibraryRefreshFailed,
                        localizedLibraryFailure(reason))
                    : localizedLibraryFailure(reason))
            Button(l10n.text(.panelRetry)) {
                guard let action = eventsEditorPresentation?.retryLibraryAction else { return }
                soundPacksEditorNativeEffects.consume(
                    soundPacksEditorOwner.send(.invoke(action)),
                    owner: soundPacksEditorOwner)
            }
            .focused($focusedTarget, equals: .retryLibrary)
            .accessibilityLabel(l10n.text(.panelRetry))
            .accessibilityHint(l10n.text(.panelRetryHint))
            .accessibilityIdentifier("event-settings.library.retry")
        }
    }

    private func localizedLibraryFailure(
        _ reason: SoundPackEditorLibraryFailureReason
    ) -> String {
        switch reason {
        case .locationUnavailable:
            return l10n.text(.soundPacksEmptyLoadFailedMessage)
        case .scanFailed:
            return l10n.text(.panelPacksReadFailed)
        }
    }

    private var writeFailures: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(writeFailureMessages, id: \.self) { message in
                FailureRow(message: message)
            }
        }
        .accessibilityIdentifier("event-settings.write-failures")
    }

    private func eventInheritanceText(_ event: Event) -> String? {
        switch eventSettingsInheritanceState(
            config: model.configState.resolvedConfig,
            scope: selectedScope.scope,
            event: event)
        {
        case .globalDefault:
            return nil
        case .inheritedGlobal:
            return l10n.text(.panelInheritedGlobal)
        case .surfaceOverride:
            return l10n.text(.panelSurfaceOverride)
        case .invalidSurfaceOverride:
            return model.surfaceSoundIssue
        }
    }

    private var writeFailureMessages: [String] {
        var messages = panelWriteFailures(
            muteError: selectedScope.scope == .global ? model.muteError : nil,
            packSwitchError: model.packSwitchError,
            masterVolumeError: model.masterVolumeError)
        if selectedScope.scope.surface != nil, let issue = model.surfaceSoundIssue,
            !messages.contains(issue)
        {
            messages.append(issue)
        }
        return messages
    }

    private func selectScope(_ scope: PanelSoundScopeID) {
        stopAllPreviews()
        closeAICueComposer()
        selection.select(EventSettingsWindowRoute(scope: scope))
        model.selectSoundSurface(scope.surface)
    }

    private func reconcileScopeSelection() {
        guard let scope = resolvedScope else {
            stopAllPreviews()
            closeAICueComposer()
            selection.markCurrentScopeUnavailable()
            return
        }
        if selection.unavailableRequestedScopeStoredValue != nil {
            selection.clearUnavailableScope()
        }
        if eventSettingsShouldCloseAICueComposer(
            includesAICueComposer: true,
            targetSurface: aiCueViewModel.session?.scope.surface,
            selectedSurface: scope.surface)
        {
            closeAICueComposer()
        }
        if model.selectedSurface != scope.surface {
            model.selectSoundSurface(scope.surface)
        }
    }

    private func playPreview(_ event: Event) {
        stopCandidatePreview()
        stopAllPreviews()
        guard
            let action = eventsEditorPresentation?.eventAccess.first(where: {
                $0.event == event
            })?.previewAction,
            soundPacksEditorNativeEffects.playPreview(
                action,
                owner: soundPacksEditorOwner) != nil
        else {
            return
        }
    }

    private func openAICueComposer(
        _ eligibility: SoundPackEditorAdoptionAvailability,
        event: Event
    ) {
        guard case .eligible = eligibility else { return }
        soundPacksEditorNativeEffects.stopPreview(owner: soundPacksEditorOwner)
        playingCandidateID = nil
        playingCandidateTitle = nil
        selection.beginAISession(scope: selectedScope.scope, event: event)
        aiCueViewModel.begin(scope: selectedScope.scope, event: event)
    }

    private func closeAICueComposer() {
        let hadSession = aiCueViewModel.session != nil
        let clearedCandidates = aiCueViewModel.generation != nil
        stopCandidatePreview()
        aiCueViewModel.endSession()
        selection.noteAISessionEnded()
        if hadSession {
            onAnnouncement(
                l10n.text(
                    clearedCandidates
                        ? .aiCueComposerClosedCandidatesCleared
                        : .aiCueComposerClosed))
        }
    }

    private func previewAICueCandidate(_ candidate: AICueCandidate) {
        let togglesCurrentCandidate = playingCandidateID == candidate.id
        stopCandidatePreview()
        stopAllPreviews()
        if togglesCurrentCandidate {
            return
        }
        guard nonEmptyRegularFileExists(at: candidate.asset.fileURL) else {
            aiCueViewModel.reportCandidateUnavailable()
            return
        }
        guard
            soundPacksEditorNativeEffects.playAICueCandidate(
                candidate,
                volume: previewVolume(for: model.config)) != nil
        else {
            aiCueViewModel.reportCandidateUnavailable()
            return
        }
        playingCandidateID = candidate.id
        let title = localizedAICueCandidateTitle(
            candidate.variant,
            language: languageStore.language)
        playingCandidateTitle = title
        onAnnouncement(
            l10n.format(
                .aiCueCandidatePlaybackStarted,
                title as NSString))
        let candidateID = candidate.id
        let resetDelay = Double(candidate.durationMilliseconds) / 1_000 + 0.15
        DispatchQueue.main.asyncAfter(deadline: .now() + resetDelay) {
            guard playingCandidateID == candidateID else { return }
            stopCandidatePreview()
        }
    }

    private func adoptAICueCandidate(_ candidateID: UUID) {
        stopCandidatePreview()
        guard let permit = eventsEditorPresentation?.adoptionPermit else { return }
        aiCueViewModel.adopt(candidateID: candidateID, permit: permit) {
            candidate, displayName, permit in
            let result = await soundPacksEditorOwner.perform(
                .adoptAICue(
                    candidate: candidate,
                    displayName: displayName,
                    permit: permit))
            if case .adopted = result {
                onAudibilityInputsChanged()
            }
            return result
        }
    }

    private func stopCandidatePreview() {
        let stoppedCandidateTitle = playingCandidateTitle
        soundPacksEditorNativeEffects.stopPreview(owner: soundPacksEditorOwner)
        playingCandidateID = nil
        playingCandidateTitle = nil
        if let stoppedCandidateTitle {
            onAnnouncement(
                l10n.format(
                    .aiCueCandidatePlaybackStopped,
                    stoppedCandidateTitle as NSString))
        }
    }

    private func aiCueGenerationIsEnabled(
        _ eligibility: SoundPackEditorAdoptionAvailability
    ) -> Bool {
        if case .eligible = eligibility { return true }
        return false
    }

    private func aiCueEligibilityHint(
        _ eligibility: SoundPackEditorAdoptionAvailability
    ) -> String {
        switch eligibility {
        case .eligible:
            return l10n.text(.aiCueGenerateHint)
        case .ineligible(.surfaceRequired):
            return l10n.text(.aiCueEligibilityGlobal)
        case .ineligible(.builtinReadOnly):
            return l10n.text(.aiCueEligibilityBuiltin)
        case .ineligible(.sharedPack):
            return l10n.text(.aiCueEligibilityShared)
        case .ineligible:
            return l10n.text(.aiCueEligibilityUnavailable)
        }
    }
}

/// Events & Sounds adds one explicit editor affordance to the panel's read-only event facts.
/// It remains a separate row so the production panel cannot accidentally regain mapping writes.
@MainActor
private struct EventSettingsEventRow: View {
    let presentation: PanelEventPresentation
    let previewAvailability: EventPreviewAvailability?
    let previewActionAvailable: Bool
    let previewCapabilityUnavailableHint: String
    let windowLayout: EventSettingsWindowLayout
    let language: ClaudioAppLanguage
    let onGenerateAICue: () -> Void
    let onPreview: () -> Void
    let onToggleMute: () -> Void
    let onConfigureSound: () -> Void
    let inheritanceText: String?
    let aiCueGenerationEnabled: Bool
    let aiCueGenerationHint: String
    let soundEditingEnabled: Bool
    let writeDisabledReason: String?
    private let focusedTarget: FocusState<EventSettingsFocusTarget?>.Binding

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    init(
        presentation: PanelEventPresentation,
        previewAvailability: EventPreviewAvailability?,
        previewActionAvailable: Bool,
        previewCapabilityUnavailableHint: String,
        windowLayout: EventSettingsWindowLayout,
        language: ClaudioAppLanguage,
        focusedTarget: FocusState<EventSettingsFocusTarget?>.Binding,
        onGenerateAICue: @escaping () -> Void,
        onPreview: @escaping () -> Void,
        onToggleMute: @escaping () -> Void,
        onConfigureSound: @escaping () -> Void,
        inheritanceText: String?,
        aiCueGenerationEnabled: Bool,
        aiCueGenerationHint: String,
        soundEditingEnabled: Bool,
        writeDisabledReason: String?
    ) {
        self.presentation = presentation
        self.previewAvailability = previewAvailability
        self.previewActionAvailable = previewActionAvailable
        self.previewCapabilityUnavailableHint = previewCapabilityUnavailableHint
        self.windowLayout = windowLayout
        self.language = language
        self.focusedTarget = focusedTarget
        self.onGenerateAICue = onGenerateAICue
        self.onPreview = onPreview
        self.onToggleMute = onToggleMute
        self.onConfigureSound = onConfigureSound
        self.inheritanceText = inheritanceText
        self.aiCueGenerationEnabled = aiCueGenerationEnabled
        self.aiCueGenerationHint = aiCueGenerationHint
        self.soundEditingEnabled = soundEditingEnabled
        self.writeDisabledReason = writeDisabledReason
    }

    var body: some View {
        Group {
            if windowLayout.actionsMoveBelow {
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
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("event-settings.event.\(presentation.event.rawValue).row")
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
                if windowLayout.metadataStacks {
                    VStack(alignment: .leading, spacing: 3) {
                        capabilityBadge
                        soundFileText
                        inheritanceLabel
                    }
                } else {
                    HStack(spacing: 5) {
                        capabilityBadge
                        soundFileText
                        inheritanceLabel
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(identityAccessibilityLabel)
        .focusable()
        .focused(focusedTarget, equals: .event(presentation.event))
        .accessibilityIdentifier(
            "event-settings.event.\(presentation.event.rawValue).identity")
    }

    private var identityAccessibilityLabel: String {
        eventSettingsIdentityAccessibilityLabel(
            presentationLabel: presentation.accessibilityLabel,
            inheritanceText: inheritanceText,
            language: language)
    }

    private var controlsUnavailable: Bool {
        presentation.implementation == .notImplemented || presentation.support == .unsupported
    }

    private var configureSoundHint: String {
        if controlsUnavailable { return presentation.capabilityText }
        if let writeDisabledReason { return writeDisabledReason }
        if !soundEditingEnabled {
            return ClaudioL10n(language: language).text(.panelNeedsPackSettingsMessage)
        }
        return ClaudioL10n(language: language).text(.actionConfigureSoundHint)
    }

    private var muteHint: String {
        if controlsUnavailable { return presentation.capabilityText }
        if let writeDisabledReason { return writeDisabledReason }
        return ClaudioL10n(language: language).text(.eventMuteHint)
    }

    private var previewHint: String {
        if controlsUnavailable { return presentation.capabilityText }
        if previewAvailability?.isAvailable == true, !previewActionAvailable {
            return previewCapabilityUnavailableHint
        }
        return localizedEventPreviewHint(
            previewAvailability ?? presentation.controls.previewAvailability,
            language: language)
    }

    private var previewEnabled: Bool {
        !controlsUnavailable && previewActionAvailable
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
            .lineLimit(windowLayout.metadataStacks ? 2 : 1)
    }

    @ViewBuilder
    private var inheritanceLabel: some View {
        if let inheritanceText {
            Text(inheritanceText)
                .font(.system(size: 9 * typeScale, weight: .medium, design: .rounded))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(ClaudioTheme.elevated(colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    private var actions: some View {
        HStack(spacing: 5) {
            Button(action: onGenerateAICue) {
                Label(
                    ClaudioL10n(language: language).text(.aiCueGenerateAction),
                    systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!aiCueGenerationEnabled || controlsUnavailable)
            .focused(focusedTarget, equals: .generateAICue(presentation.event))
            .help(aiCueGenerationHint)
            .accessibilityLabel(
                ClaudioL10n(language: language).text(.aiCueGenerateAction)
            )
            .accessibilityHint(aiCueGenerationHint)
            .accessibilityIdentifier(
                "event-settings.event.\(presentation.event.rawValue).ai-cue")

            Button(action: onConfigureSound) {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(ClaudioIconButtonStyle())
            .disabled(!soundEditingEnabled || controlsUnavailable)
            .focused(focusedTarget, equals: .configure(presentation.event))
            .help(configureSoundHint)
            .accessibilityLabel(ClaudioL10n(language: language).text(.actionConfigureSound))
            .accessibilityHint(configureSoundHint)
            .accessibilityIdentifier(
                "event-settings.event.\(presentation.event.rawValue).configure")

            Button(action: onPreview) {
                Image(systemName: "play.fill")
            }
            .buttonStyle(ClaudioIconButtonStyle())
            .foregroundColor(
                previewEnabled
                    ? ClaudioTheme.event(presentation.event, colorScheme)
                    : ClaudioTheme.secondaryText(colorScheme)
            )
            .disabled(!previewEnabled)
            .focused(focusedTarget, equals: .preview(presentation.event))
            .help(previewHint)
            .accessibilityLabel(
                ClaudioL10n(language: language).format(.eventPreviewLabel, presentation.title)
            )
            .accessibilityHint(previewHint)
            .accessibilityIdentifier(
                "event-settings.event.\(presentation.event.rawValue).preview")

            Toggle(
                ClaudioL10n(language: language).text(.eventSettingsAutomaticPlayback),
                isOn: Binding(
                    get: { presentation.enabled },
                    set: { _ in onToggleMute() })
            )
            .toggleStyle(.switch)
            .font(ClaudioTheme.font(.caption))
            .controlSize(.small)
            .disabled(!presentation.controls.muteEnabled)
            .focused(focusedTarget, equals: .mute(presentation.event))
            .help(muteHint)
            .accessibilityLabel(
                ClaudioL10n(language: language).format(
                    .eventSettingsAutomaticPlaybackFor,
                    presentation.title as NSString)
            )
            .accessibilityValue(
                presentation.enabled
                    ? ClaudioL10n(language: language).text(.eventEnabled)
                    : ClaudioL10n(language: language).text(.eventMuted)
            )
            .accessibilityHint(muteHint)
            .accessibilityIdentifier(
                "event-settings.event.\(presentation.event.rawValue).automatic-playback")
        }
        .fixedSize()
    }
}

/// Settings wrapper around the shared slider lifecycle; only its wider label layout and focus
/// identity differ from the compact panel row.
@MainActor
private struct EventSettingsMasterVolumeControl: View {
    let diskVolume: Double
    let isEnabled: Bool
    let language: ClaudioAppLanguage
    let onCommit: (Double) -> Double?
    private let focusedTarget: FocusState<EventSettingsFocusTarget?>.Binding

    init(
        diskVolume: Double,
        isEnabled: Bool,
        language: ClaudioAppLanguage,
        focusedTarget: FocusState<EventSettingsFocusTarget?>.Binding,
        onCommit: @escaping (Double) -> Double?
    ) {
        self.diskVolume = diskVolume
        self.isEnabled = isEnabled
        self.language = language
        self.focusedTarget = focusedTarget
        self.onCommit = onCommit
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ClaudioL10n(language: language).text(.panelMasterVolume))
                    .font(ClaudioTheme.font(.body).weight(.semibold))
                Text(ClaudioL10n(language: language).text(.panelMasterVolumeDescription))
                    .font(ClaudioTheme.font(.caption))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 10)
            SharedMasterVolumeSlider(
                diskVolume: diskVolume,
                isEnabled: isEnabled,
                language: language,
                accessibilityIdentifier: "event-settings.master-volume",
                flushesOnDisappear: true,
                onCommit: onCommit
            )
            .focused(focusedTarget, equals: .masterVolume)
            .frame(maxWidth: 302)
        }
    }
}
