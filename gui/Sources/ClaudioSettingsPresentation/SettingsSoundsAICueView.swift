import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SoundPacksWindow
import SwiftUI

package enum AICuePackDraftNameEdit: Equatable {
    case noDraft
    case unchanged
    case pending(AICuePackName)
    case invalid

    package var needsSave: Bool {
        switch self {
        case .pending, .invalid: true
        case .noDraft, .unchanged: false
        }
    }

    package var savableName: AICuePackName? {
        guard case .pending(let name) = self else { return nil }
        return name
    }
}

package func aiCuePackDraftNameEdit(draftName: String?, input: String) -> AICuePackDraftNameEdit {
    guard let draftName else { return .noDraft }
    guard let name = try? AICuePackName(input) else { return .invalid }
    if name.value == draftName { return .unchanged }
    return .pending(name)
}

/// Package-scoped AI cue generation belongs to the Sounds destination. Events & Sounds keeps its
/// source facts and missing-sound deep links, while this view owns the visible package/event
/// composer and the one-shot adoption permit that the retained editor owner signs.
@MainActor
struct SettingsSoundsAICueView: View {
    @ObservedObject var viewModel: AICueGenerationViewModel
    @ObservedObject var editorOwner: SoundPacksEditorOwner
    @ObservedObject var languageStore: ClaudioPreferences
    let nativeEffects: SoundPacksEditorNativeEffectsDispatcher
    let route: SoundPacksWindowRoute
    let onAnnouncement: @MainActor (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedEvent: Event?
    @State private var credentialSheetIsPresented = false
    @State private var playingCandidateID: UUID?
    @State private var pendingRouteSession: AICueComposerSession?
    @State private var draftNameInput = ""

    private var l10n: ClaudioL10n { ClaudioL10n(language: languageStore.language) }

    private var sounds: SoundsEditorPresentation? {
        guard case .sounds(let presentation) = editorOwner.presentation.mode else { return nil }
        return presentation
    }

    private var selectedPack: SoundPackEditorPackPresentation? { sounds?.selectedPack }

    private var draftNameEdit: AICuePackDraftNameEdit {
        aiCuePackDraftNameEdit(draftName: sounds?.draft?.name, input: draftNameInput)
    }

    private var activePackID: String? {
        sounds?.draft?.packID ?? selectedPack?.id
    }

    private var activeEvent: Event? {
        guard let session = viewModel.session, session.packID == activePackID else { return nil }
        return session.event
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n.text(.settingsSoundsAICueTitle))
                .font(ClaudioTheme.font(.sectionTitle).weight(.bold))
                .foregroundColor(ClaudioTheme.text(colorScheme))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("settings.sounds.ai-cue.title")
            serviceCard
            packContext
            eventList
            if let event = activeEvent, let packID = activePackID {
                composer(packID: packID, event: event)
            }
        }
        .onAppear {
            pendingRouteSession = routeSession
            draftNameInput = sounds?.draft?.name ?? ""
            beginRouteSessionIfNeeded()
            syncOwnerComposer()
            Task { await viewModel.refreshCredentialStatus() }
        }
        .onChange(of: route) { _ in
            stopCandidatePreview()
            viewModel.endSession()
            editorOwner.updateAICueComposer(session: nil, generation: nil)
            pendingRouteSession = routeSession
            beginRouteSessionIfNeeded()
        }
        .onChange(of: sounds?.routeState) { _ in beginRouteSessionIfNeeded() }
        .onChange(of: selectedPack?.id) { selectedID in
            if let session = viewModel.session, session.packID != activePackID {
                stopCandidatePreview()
                viewModel.endSession()
                syncOwnerComposer()
            }
            if selectedID != nil { beginRouteSessionIfNeeded() }
        }
        .onChange(of: sounds?.draft?.name) { name in
            draftNameInput = name ?? ""
        }
        .onChange(of: viewModel.session) { _ in syncOwnerComposer() }
        .onChange(of: viewModel.generation) { _ in syncOwnerComposer() }
        .onChange(of: viewModel.requiresCredentialConfiguration) { required in
            if required { credentialSheetIsPresented = true }
        }
        .sheet(isPresented: $credentialSheetIsPresented) {
            EventSettingsAICueCredentialSheet(
                viewModel: viewModel,
                languageStore: languageStore)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.sounds.ai-cue")
    }

    private var serviceCard: some View {
        EventSettingsAICueServiceCard(
            viewModel: viewModel,
            languageStore: languageStore,
            onManageCredential: { credentialSheetIsPresented = true }
        )
        .accessibilityIdentifier("settings.sounds.ai-cue.service")
    }

    @ViewBuilder
    private var packContext: some View {
        if let draft = sounds?.draft {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil")
                        .foregroundColor(ClaudioTheme.clay(colorScheme))
                        .accessibilityHidden(true)
                    TextField(l10n.text(.settingsSoundsAICuePackName), text: $draftNameInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                        .disabled(viewModel.phase == .adopting)
                        .accessibilityIdentifier("settings.sounds.ai-cue.draft-name")
                    Button(l10n.text(.settingsSoundsAICueSaveName)) {
                        guard let name = draftNameEdit.savableName else { return }
                        _ = editorOwner.renameAICuePackDraft(name)
                    }
                    .disabled(
                        viewModel.phase == .adopting
                            || draft.cancelAction == nil
                            || draftNameEdit.savableName == nil
                    )
                    .accessibilityIdentifier("settings.sounds.ai-cue.save-draft-name")
                    Text(l10n.text(.settingsSoundsAICueDraft))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                }
                Text(l10n.text(.settingsSoundsAICueDescription))
                    .font(.caption)
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                if draftNameEdit == .invalid {
                    Text(l10n.text(.settingsSoundsAICueInvalidName))
                        .font(.caption)
                        .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                }
                if let cancelAction = draft.cancelAction {
                    Button(l10n.text(.commonCancel)) {
                        invoke(cancelAction)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("settings.sounds.ai-cue.cancel-draft")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.sounds.ai-cue.draft")
        } else if let selectedPack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(
                        SelectedPackMetadata(id: selectedPack.id, name: selectedPack.name)
                            .displayName
                    )
                    .font(.headline)
                    if selectedPack.usage.isShared {
                        Text(l10n.text(.settingsSoundsAICueShared))
                            .font(.caption.weight(.semibold))
                            .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    }
                }
                if selectedPack.usage.usageIsIncomplete {
                    Label(
                        l10n.text(.settingsSoundsAICueScopeIncomplete),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.sounds.ai-cue.scope-incomplete")
                }
                if !selectedPack.usage.consumers.isEmpty {
                    Text(l10n.text(.settingsSoundsAICueUsage))
                        .font(.caption.weight(.semibold))
                    ForEach(Array(selectedPack.usage.consumers.enumerated()), id: \.offset) {
                        _, consumer in
                        Text(usageLabel(consumer))
                            .font(.caption)
                            .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    }
                }
                if selectedPack.copyAction != nil || selectedPack.copyAndApplyAction != nil {
                    Text(l10n.text(.settingsSoundsAICueCopyAttribution))
                        .font(.caption)
                        .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if route.isCopyAndApply, let copyAction = selectedPack.copyAndApplyAction {
                    Button(copyAndApplyTitle) {
                        invoke(copyAction)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ClaudioTheme.clay(colorScheme))
                    .accessibilityLabel(copyAndApplyTitle)
                    .accessibilityIdentifier("settings.sounds.ai-cue.copy-and-apply")
                }
                if let copyAction = selectedPack.copyAction {
                    Button(l10n.text(.commonCopy)) {
                        invoke(copyAction)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(
                        l10n.format(
                            .soundPacksCopyLabel,
                            SelectedPackMetadata(id: selectedPack.id, name: selectedPack.name)
                                .displayName)
                    )
                    .accessibilityIdentifier("settings.sounds.ai-cue.copy")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.sounds.ai-cue.pack-context")
        } else {
            Text(l10n.text(.settingsSoundsAICueDescription))
                .font(.caption)
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(l10n.text(.panelEventsTitle))
                    .font(.headline)
                Spacer(minLength: 8)
                Button(l10n.text(.settingsSoundsAICueNewPack)) {
                    beginDraft()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isBusy || sounds?.draft != nil)
                .accessibilityLabel(l10n.text(.settingsSoundsAICueNewPack))
                .accessibilityIdentifier("settings.sounds.ai-cue.new-pack")
            }
            ForEach(Event.allCases, id: \.self) { event in
                eventButton(event)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.sounds.ai-cue.events")
    }

    private func eventButton(_ event: Event) -> some View {
        let isExpanded = activeEvent == event
        let row = sounds?.eventRows.first(where: { $0.event == event })
        return Button {
            beginSession(for: event)
        } label: {
            HStack(spacing: 8) {
                ClaudioEventGlyph(event: event, size: 22)
                    .accessibilityHidden(true)
                Text(localizedEventName(event, language: languageStore.language))
                    .font(.body.weight(.medium))
                Spacer(minLength: 8)
                if let displayName = row?.audioDisplayName, !displayName.isEmpty {
                    Text(displayName)
                        .font(.caption)
                        .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                        .lineLimit(1)
                }
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row)
                    .fill(
                        isExpanded
                            ? ClaudioTheme.claySoft(colorScheme)
                            : ClaudioTheme.elevated(colorScheme)))
        }
        .buttonStyle(.plain)
        .focused($focusedEvent, equals: event)
        .accessibilityLabel(localizedEventName(event, language: languageStore.language))
        .accessibilityValue(row?.audioDisplayName ?? l10n.text(.soundPacksCoverageUnmapped))
        .accessibilityHint(
            adoptionHint(
                row?.aiCueAdoptionAvailability
                    ?? .ineligible(.configurationUnavailable))
        )
        .accessibilityIdentifier("settings.sounds.ai-cue.event.\(event.rawValue)")
    }

    private func composer(packID: String, event: Event) -> some View {
        let row = sounds?.eventRows.first(where: { $0.event == event })
        let availability =
            row?.aiCueAdoptionAvailability
            ?? .ineligible(.configurationUnavailable)
        return EventSettingsAICueComposerView(
            viewModel: viewModel,
            languageStore: languageStore,
            eventTitle: localizedEventName(event, language: languageStore.language),
            playingCandidateID: playingCandidateID,
            adoptionEnabled: row?.aiCueAdoptionPermit != nil
                && !draftNameEdit.needsSave,
            generationEnabled: canGenerate(packID: packID, event: event),
            onGenerate: {
                guard canGenerate(packID: packID, event: event) else { return }
                viewModel.startGeneration(locale: languageStore.language.rawValue)
            },
            attributionDisclosure: selectedPack?.isBuiltinReadOnly == false
                ? l10n.text(.settingsSoundsAICueAdoptAttribution) : nil,
            adoptionUnavailableHint: draftNameEdit.needsSave
                ? l10n.text(.settingsSoundsAICueSaveNameBeforeAdopting)
                : adoptionHint(availability),
            onConfigureCredential: { credentialSheetIsPresented = true },
            onPreviewCandidate: previewCandidate,
            onAdoptCandidate: {
                candidateID in
                adoptCandidate(candidateID: candidateID, packID: packID, event: event)
            },
            onClose: closeComposer
        )
        .accessibilityIdentifier("settings.sounds.ai-cue.composer.\(event.rawValue)")
    }

    private var copyAndApplyTitle: String {
        let target =
            route.surface.map { surface in
                HostID.productVisibleCases.first(where: { $0.surfaceID == surface })?.displayName
                    ?? surface.rawValue
            } ?? l10n.text(.panelGlobalName)
        return l10n.format(.settingsSoundsAICueCopyAndApply, target as NSString)
    }

    private var routeSession: AICueComposerSession? {
        guard !route.isCopyAndApply, let target = route.editTarget else { return nil }
        return AICueComposerSession(packID: target.packID, event: target.event)
    }

    private func beginRouteSessionIfNeeded() {
        guard let pendingRouteSession, let sounds else { return }
        switch soundsAICueRouteStep(pendingRouteSession, route: route, sounds: sounds) {
        case .pending:
            return
        case .inspect(let action):
            invoke(action)
        case .begin(let target):
            self.pendingRouteSession = nil
            guard let packID = target.packID else { return }
            beginSession(for: target.event, packID: packID)
        case .unavailable:
            self.pendingRouteSession = nil
        }
    }

    private func beginSession(for event: Event) {
        guard let packID = activePackID else { return }
        pendingRouteSession = nil
        beginSession(for: event, packID: packID)
    }

    private func beginSession(for event: Event, packID: String) {
        nativeEffects.stopPreview(owner: editorOwner)
        playingCandidateID = nil
        viewModel.begin(packID: packID, event: event)
        syncOwnerComposer()
        DispatchQueue.main.async {
            focusedEvent = event
        }
    }

    private func beginDraft() {
        nativeEffects.stopPreview(owner: editorOwner)
        playingCandidateID = nil
        viewModel.endSession()
        editorOwner.updateAICueComposer(session: nil, generation: nil)
        let language: AICuePackDraftLanguage =
            languageStore.language == .english
            ? .english : .zhHans
        guard editorOwner.beginAICuePackDraft(language: language) else { return }
        onAnnouncement(l10n.text(.settingsSoundsAICueNewPack))
    }

    private func closeComposer() {
        let hadSession = viewModel.session != nil
        let hadCandidates = viewModel.generation != nil
        stopCandidatePreview()
        viewModel.endSession()
        editorOwner.cancelAICuePackDraft()
        editorOwner.updateAICueComposer(session: nil, generation: nil)
        focusedEvent = nil
        guard hadSession else { return }
        onAnnouncement(
            l10n.text(
                hadCandidates
                    ? .aiCueComposerClosedCandidatesCleared : .aiCueComposerClosed))
    }

    private func syncOwnerComposer() {
        editorOwner.updateAICueComposer(
            session: viewModel.session,
            generation: viewModel.generation)
    }

    private func previewCandidate(_ candidate: AICueCandidate) {
        let togglesCurrentCandidate = playingCandidateID == candidate.id
        stopCandidatePreview()
        if togglesCurrentCandidate { return }
        guard nonEmptyRegularFileExists(at: candidate.asset.fileURL),
            nativeEffects.playAICueCandidate(
                candidate,
                volume: AfplayVolume.clamped(
                    sounds?.masterVolume ?? ClaudioConfig.defaultMasterVolume))
                != nil
        else {
            viewModel.reportCandidateUnavailable()
            return
        }
        playingCandidateID = candidate.id
        let candidateID = candidate.id
        let resetDelay = Double(candidate.durationMilliseconds) / 1_000 + 0.15
        DispatchQueue.main.asyncAfter(deadline: .now() + resetDelay) {
            guard playingCandidateID == candidateID else { return }
            stopCandidatePreview()
        }
    }

    private func adoptCandidate(candidateID: UUID, packID: String, event: Event) {
        stopCandidatePreview()
        guard
            !draftNameEdit.needsSave,
            let permit = sounds?.eventRows.first(where: { $0.event == event })?
                .aiCueAdoptionPermit,
            viewModel.session == AICueComposerSession(packID: packID, event: event)
        else { return }
        viewModel.adopt(candidateID: candidateID, permit: permit) {
            candidate, displayName, permit in
            await editorOwner.perform(
                .adoptAICue(
                    candidate: candidate,
                    displayName: displayName,
                    permit: permit))
        }
    }

    private func stopCandidatePreview() {
        guard playingCandidateID != nil else { return }
        nativeEffects.stopPreview(owner: editorOwner)
        playingCandidateID = nil
    }

    private func invoke(_ action: SoundPackEditorAction) {
        nativeEffects.consume(editorOwner.send(.invoke(action)), owner: editorOwner)
    }

    private func adoptionHint(_ availability: SoundPackEditorAdoptionAvailability) -> String {
        switch availability {
        case .eligible:
            return l10n.text(.aiCueGenerateHint)
        case .ineligible(.builtinReadOnly):
            return l10n.text(.aiCueEligibilityBuiltin)
        case .ineligible(.sharedPack):
            return l10n.text(.aiCueEligibilityShared)
        case .ineligible:
            return l10n.text(.aiCueEligibilityUnavailable)
        }
    }

    private func usageLabel(_ usage: AICuePackUsageConsumer) -> String {
        let name: String
        switch usage.consumer {
        case .global:
            name = l10n.text(.panelGlobalName)
        case .surface(let surface):
            name =
                HostID.productVisibleCases.first(where: { $0.surfaceID == surface })?
                .displayName ?? surface.rawValue
        }
        return usage.inherited
            ? l10n.format(.settingsSoundsAICueInheritedUsage, name as NSString)
            : name
    }

    private func canGenerate(packID: String, event: Event) -> Bool {
        guard viewModel.session == AICueComposerSession(packID: packID, event: event) else {
            return false
        }
        return soundsAICueGenerationIsAllowed(
            sounds: sounds,
            library: editorOwner.presentation.library,
            session: viewModel.session,
            event: event)
    }
}
