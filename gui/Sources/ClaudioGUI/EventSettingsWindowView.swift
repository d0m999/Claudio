import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// Production Events & Sounds surface corresponding to the prototype's scoped events page.
/// It reuses the panel's manager-owned scope and event projections; full per-event file editing
/// remains delegated to SoundPacksWindow.
@MainActor
struct EventSettingsWindowView: View {
    @ObservedObject var model: PanelConfigController
    @ObservedObject var selection: EventSettingsWindowSelection
    @ObservedObject var hostIntegrations: HostIntegrationPresentationStore
    @ObservedObject var languageStore: ClaudioLanguageStore
    @ObservedObject var aiCueViewModel: AICueGenerationViewModel

    let audioEnvironment: AudioImportEnvironment
    let onConfigureSound: @MainActor (SoundPacksWindowRoute) -> Void
    let onAudibilityInputsChanged: @MainActor () -> Void
    let onAdoptAICue: @MainActor (
        AICueCandidate,
        AICueDisplayName,
        AICueAdoptionTarget
    ) async -> Result<AICueAdoptionOutcome, AICueAdoptionError>

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ClaudioInterfaceTextSize.defaultsKey)
    private var interfaceTextSizeRaw = ClaudioInterfaceTextSize.defaultValue.rawValue
    @FocusState private var focusedTarget: EventSettingsFocusTarget?
    @State private var previewPlayer = NSSoundAudioPreviewPlayer()
    @State private var handledFocusRequestRevision = 0
    @State private var playingCandidateID: UUID?
    @State private var showsCredentialSheet = false

    private var l10n: ClaudioL10n { ClaudioL10n(language: languageStore.language) }
    private var interfaceTextSize: ClaudioInterfaceTextSize {
        ClaudioInterfaceTextSize(storedValue: interfaceTextSizeRaw)
    }
    private var scopes: [PanelSoundScopePresentation] {
        panelSoundScopePresentations(
            sourceRows: hostIntegrations.content.sourceRows,
            config: model.configState.resolvedConfig,
            language: languageStore.language)
    }
    private var resolvedScope: PanelSoundScopeID {
        resolvedEventSettingsScope(route: selection.route, scopes: scopes)
    }
    private var selectedScope: PanelSoundScopePresentation {
        scopes.first(where: { $0.scope == resolvedScope }) ?? scopes[0]
    }
    private var scopeProjectionIsAligned: Bool {
        selection.route.scope == selectedScope.scope
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

    var body: some View {
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
        .onReceive(selection.$focusRequestRevision) { revision in
            guard revision > handledFocusRequestRevision else { return }
            handledFocusRequestRevision = revision
            focusedTarget = eventSettingsFirstFocusTarget(scopes: scopes.map(\.scope))
        }
        .onAppear { reconcileScopeSelection() }
        .onChange(of: scopes.map(\.scope)) { _ in reconcileScopeSelection() }
        .onChange(of: model.config.selectedPack) { _ in closeAICueComposer() }
        .onChange(of: aiCueViewModel.requiresCredentialConfiguration) { required in
            if required { showsCredentialSheet = true }
        }
        .task { await aiCueViewModel.refreshCredentialStatus() }
        .sheet(isPresented: $showsCredentialSheet) {
            EventSettingsAICueCredentialSheet(
                viewModel: aiCueViewModel,
                languageStore: languageStore)
        }
        .onDisappear {
            previewPlayer.stop()
            playingCandidateID = nil
            aiCueViewModel.endSession()
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
                    ForEach(scopes) { scope in
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
                                if scope.scope == selectedScope.scope {
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
                                        scope.scope == selectedScope.scope
                                            ? ClaudioTheme.clay(colorScheme).opacity(0.14)
                                            : Color.clear))
                        }
                        .buttonStyle(.plain)
                        .focused($focusedTarget, equals: .scope(scope.scope))
                        .accessibilityLabel(scope.accessibilityLabel)
                        .accessibilityValue(
                            scope.scope == selectedScope.scope
                                ? l10n.text(.integrationsSelected)
                                : l10n.text(.integrationsNotSelected)
                        )
                        .accessibilityIdentifier(
                            "event-settings.scope.\(scope.scope.storedValue)")
                    }
                }
                .padding(.horizontal, 10)
            }
        }
    }

    private var eventContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            eventHeader
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            EventSettingsAICueServiceCard(
                viewModel: aiCueViewModel,
                languageStore: languageStore,
                onManageCredential: { showsCredentialSheet = true })
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
                    eventRows(availableWidth: max(0, geometry.size.width - 48))
                        .padding(24)
                }
            }
        }
    }

    private var eventHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l10n.text(.eventSettingsTitle))
                .font(ClaudioTheme.font(.productTitle).weight(.bold))
                .foregroundColor(ClaudioTheme.text(colorScheme))
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
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("event-settings.header")
    }

    private var aiCuePageEligibility: AICueAdoptionEligibility? {
        guard
            scopeProjectionIsAligned,
            case .events = model.configState.topContent,
            model.libraryPresentationState.hasUsableSnapshot
        else { return nil }
        return model.aiCueAdoptionEligibility(for: .stop)
    }

    private func aiCueAvailabilityNotice(
        _ eligibility: AICueAdoptionEligibility
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

    @ViewBuilder
    private func eventRows(availableWidth: CGFloat) -> some View {
        let windowLayout = eventSettingsWindowLayout(
            availableWidth: Double(availableWidth),
            typeScale: interfaceTextSize.scale)
        switch model.configState.topContent {
        case .events:
            if scopeProjectionIsAligned {
                if model.libraryPresentationState.hasUsableSnapshot {
                    VStack(alignment: .leading, spacing: 12) {
                        if !writeFailureMessages.isEmpty {
                            writeFailures
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                                let eligibility = model.aiCueAdoptionEligibility(for: event.event)
                                EventSettingsEventRow(
                                    presentation: event,
                                    windowLayout: windowLayout,
                                    language: languageStore.language,
                                    focusedTarget: $focusedTarget,
                                    onGenerateAICue: { openAICueComposer(eligibility) },
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
                                    aiCueGenerationEnabled: aiCueGenerationIsEnabled(eligibility),
                                    aiCueGenerationHint: aiCueEligibilityHint(eligibility),
                                    soundEditingEnabled: !model.config.selectedPack.isEmpty
                                        && model.surfaceSoundIssue == nil,
                                    writeDisabledReason: model.surfaceSoundIssue)
                                if aiCueViewModel.target?.event == event.event {
                                    EventSettingsAICueComposerView(
                                        viewModel: aiCueViewModel,
                                        languageStore: languageStore,
                                        eventTitle: event.title,
                                        playingCandidateID: playingCandidateID,
                                        onConfigureCredential: { showsCredentialSheet = true },
                                        onPreviewCandidate: previewAICueCandidate,
                                        onAdoptCandidate: adoptAICueCandidate,
                                        onClose: closeAICueComposer)
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
                    Text(l10n.text(.panelUnavailableEvents))
                        .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
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

    private var writeFailures: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(writeFailureMessages, id: \.self) { message in
                FailureRow(message: message)
            }
        }
        .accessibilityIdentifier("event-settings.write-failures")
    }

    private var writeFailureMessages: [String] {
        var messages = panelWriteFailures(
            muteError: selectedScope.scope == .global ? model.muteError : nil,
            packSwitchError: nil,
            masterVolumeError: nil)
        if selectedScope.scope.surface != nil, let issue = model.surfaceSoundIssue,
            !messages.contains(issue)
        {
            messages.append(issue)
        }
        return messages
    }

    private func selectScope(_ scope: PanelSoundScopeID) {
        closeAICueComposer()
        selection.select(EventSettingsWindowRoute(scope: scope))
        model.selectSoundSurface(scope.surface)
    }

    private func reconcileScopeSelection() {
        let scope = selectedScope.scope
        if aiCueViewModel.target?.surface != scope.surface {
            closeAICueComposer()
        }
        if selection.route.scope != scope {
            selection.select(EventSettingsWindowRoute(scope: scope))
            focusedTarget = .scope(scope)
        }
        if model.selectedSurface != scope.surface {
            model.selectSoundSurface(scope.surface)
        }
    }

    private func playPreview(_ event: Event) {
        stopCandidatePreview()
        guard
            let row = model.eventRows.first(where: { $0.event == event }),
            let file = eventPreviewFileURL(
                row: row,
                packID: model.config.selectedPack,
                environment: audioEnvironment)
        else {
            model.reload()
            return
        }
        previewPlayer.play(fileAt: file, volume: Float(previewVolume(for: model.config)))
    }

    private func openAICueComposer(_ eligibility: AICueAdoptionEligibility) {
        guard case .eligible(let target) = eligibility else { return }
        previewPlayer.stop()
        playingCandidateID = nil
        aiCueViewModel.begin(target: target)
    }

    private func closeAICueComposer() {
        stopCandidatePreview()
        aiCueViewModel.endSession()
    }

    private func previewAICueCandidate(_ candidate: AICueCandidate) {
        if playingCandidateID == candidate.id {
            stopCandidatePreview()
            return
        }
        guard nonEmptyRegularFileExists(at: candidate.asset.fileURL) else {
            stopCandidatePreview()
            aiCueViewModel.reportCandidateUnavailable()
            return
        }
        previewPlayer.play(
            fileAt: candidate.asset.fileURL,
            volume: Float(previewVolume(for: model.config)))
        playingCandidateID = candidate.id
        let candidateID = candidate.id
        let resetDelay = Double(candidate.durationMilliseconds) / 1_000 + 0.15
        DispatchQueue.main.asyncAfter(deadline: .now() + resetDelay) {
            guard playingCandidateID == candidateID else { return }
            playingCandidateID = nil
        }
    }

    private func adoptAICueCandidate(_ candidateID: UUID) {
        stopCandidatePreview()
        aiCueViewModel.adopt(candidateID: candidateID, using: onAdoptAICue)
    }

    private func stopCandidatePreview() {
        previewPlayer.stop()
        playingCandidateID = nil
    }

    private func aiCueGenerationIsEnabled(_ eligibility: AICueAdoptionEligibility) -> Bool {
        if case .eligible = eligibility { return true }
        return false
    }

    private func aiCueEligibilityHint(_ eligibility: AICueAdoptionEligibility) -> String {
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
    let windowLayout: EventSettingsWindowLayout
    let language: ClaudioAppLanguage
    let onGenerateAICue: () -> Void
    let onPreview: () -> Void
    let onToggleMute: () -> Void
    let onConfigureSound: () -> Void
    let aiCueGenerationEnabled: Bool
    let aiCueGenerationHint: String
    let soundEditingEnabled: Bool
    let writeDisabledReason: String?
    private let focusedTarget: FocusState<EventSettingsFocusTarget?>.Binding

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    init(
        presentation: PanelEventPresentation,
        windowLayout: EventSettingsWindowLayout,
        language: ClaudioAppLanguage,
        focusedTarget: FocusState<EventSettingsFocusTarget?>.Binding,
        onGenerateAICue: @escaping () -> Void,
        onPreview: @escaping () -> Void,
        onToggleMute: @escaping () -> Void,
        onConfigureSound: @escaping () -> Void,
        aiCueGenerationEnabled: Bool,
        aiCueGenerationHint: String,
        soundEditingEnabled: Bool,
        writeDisabledReason: String?
    ) {
        self.presentation = presentation
        self.windowLayout = windowLayout
        self.language = language
        self.focusedTarget = focusedTarget
        self.onGenerateAICue = onGenerateAICue
        self.onPreview = onPreview
        self.onToggleMute = onToggleMute
        self.onConfigureSound = onConfigureSound
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
        return localizedEventPreviewHint(
            presentation.controls.previewAvailability,
            language: language)
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
                ClaudioL10n(language: language).text(.aiCueGenerateAction))
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
                presentation.controls.previewEnabled
                    ? ClaudioTheme.event(presentation.event, colorScheme)
                    : ClaudioTheme.secondaryText(colorScheme)
            )
            .disabled(!presentation.controls.previewEnabled)
            .focused(focusedTarget, equals: .preview(presentation.event))
            .help(previewHint)
            .accessibilityLabel(
                ClaudioL10n(language: language).format(.eventPreviewLabel, presentation.title)
            )
            .accessibilityHint(previewHint)
            .accessibilityIdentifier(
                "event-settings.event.\(presentation.event.rawValue).preview")

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
            .focused(focusedTarget, equals: .mute(presentation.event))
            .help(muteHint)
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
            .accessibilityHint(muteHint)
            .accessibilityIdentifier(
                "event-settings.event.\(presentation.event.rawValue).mute")
        }
        .fixedSize()
    }
}
