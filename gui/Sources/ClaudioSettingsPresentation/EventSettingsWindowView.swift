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
struct EventSettingsWindowView: View {
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedTarget: EventSettingsFocusTarget?
    @State private var isAddingWorkspace = false
    @State private var player = NSSoundAudioPreviewPlayer()
    @State private var previewPulseTriggers: [Event: Int] = [:]
    @State private var previewSuccessTokens: [Event: UUID] = [:]
    @AppStorage("claudio.workspace-migration-notice-seen") private var migrationSeen = false

    init(
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
    private var scopes: [PanelSoundScopePresentation] {
        panelSoundScopePresentations(
            sourceRows: [], config: model.configState.resolvedConfig,
            language: languageStore.language)
    }
    private var current: PanelSoundScopePresentation? {
        scopes.first { $0.scope == selection.route.scope }
    }
    private var rule: WorkspaceSoundRule? {
        model.workspaceRules.first { $0.id == selection.route.scope.workspaceID }
    }
    private var writable: Bool {
        guard case .operational = model.configState else { return false }
        if model.workspaceError == .invalidRule || model.workspaceError == .staleRule {
            return false
        }
        return current != nil && selection.unavailableRequestedScopeStoredValue == nil
            && model.selectedSoundScope == selection.route.scope
    }
    private var events: [PanelEventPresentation] {
        panelEventPresentations(
            rows: model.eventRows, scope: selection.route.scope,
            masterVolume: model.config.masterVolume,
            language: languageStore.language, configWritesAllowed: writable,
            safetyFailures: model.previewSafetyFailures)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(l10n.text(.settingsDestinationEventsAndSounds))
                .font(.system(size: 30, weight: .bold))
                .accessibilityAddTraits(.isHeader)
                .focusable()
                .focused($focusedTarget, equals: .title)
                .settingsMountIdentity("settings.title.events-and-sounds")
                .padding(.horizontal, 52)
                .padding(.top, 60)
                .padding(.bottom, 24)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(scopes) { scope in
                                Button {
                                    player.stop()
                                    selection.select(EventSettingsWindowRoute(scope: scope.scope))
                                    let reselectsCurrentScope =
                                        model.selectedSoundScope == scope.scope
                                    model.selectSoundScope(scope.scope)
                                    if reselectsCurrentScope,
                                        model.workspaceError == .staleRule
                                            || model.workspaceError == .invalidRule
                                    {
                                        model.reload()
                                    }
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(scope.name).fontWeight(.semibold)
                                            Text(scope.summaryText).font(.caption).foregroundColor(
                                                .secondary)
                                        }
                                        Spacer()
                                        if selection.route.scope == scope.scope {
                                            Image(systemName: "checkmark")
                                        }
                                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(
                                            selection.route.scope == scope.scope
                                                ? ClaudioTheme.elevated(colorScheme) : Color.clear)
                                }
                                .buttonStyle(.plain)
                                .focused($focusedTarget, equals: .scope(scope.scope))
                                .accessibilityLabel(scope.accessibilityLabel)
                                .accessibilityIdentifier(
                                    "event-settings.scope.\(scope.scope.storedValue)")
                            }
                        }
                    }
                    Button(l10n.text(.workspaceAdd)) { isAddingWorkspace = true }
                        .accessibilityIdentifier("workspace.add")
                }.padding(16).frame(width: 225)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(current?.name ?? l10n.text(.workspaceUnavailable)).font(.title2)
                            .fontWeight(.bold)
                            .accessibilityAddTraits(.isHeader)
                        if !migrationSeen && !model.configState.resolvedConfig.selectedPack.isEmpty
                        {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(l10n.text(.workspaceMigration))
                                Button(l10n.text(.workspaceDismiss)) { migrationSeen = true }
                            }.padding(12).background(ClaudioTheme.elevated(colorScheme))
                                .accessibilityIdentifier("workspace.migration-notice")
                        }
                        if model.workspaceRulesMalformed {
                            FailureRow(message: l10n.text(.workspaceInvalidRule))
                        }
                        if let category = model.configState.errorCopyCategory {
                            FailureRow(message: l10n.text(category.key))
                            configRevealButton
                        }
                        if let failure = selection.previewFailure,
                            failure.scope == selection.route.scope,
                            (failure.packID != model.config.selectedPack || !writable
                                || !model.libraryPresentationState.hasUsableSnapshot)
                        {
                            FailureRow(
                                message: localizedEventPreviewAttemptFailure(
                                    failure.reason, language: languageStore.language)
                            )
                            .settingsMountIdentity("workspace.event.preview-failure-readback")
                            Button(l10n.text(.eventPreviewRepairSound)) {
                                onConfigureSound(
                                    .editEvent(
                                        scope: failure.scope, packID: failure.packID,
                                        event: failure.event))
                            }
                            .accessibilityIdentifier("workspace.event.preview-failure-repair")
                        }
                        if selection.conflictWasReadBack {
                            FailureRow(message: l10n.text(.eventSettingsConflictReadback))
                                .settingsMountIdentity("workspace.write.conflict-readback")
                            recoveryFileButtons(
                                selection.conflictRecoveryFiles,
                                identifierPrefix: "workspace.write.conflict-recovery-file")
                        }
                        unresolvedConflictNotice
                        if let feedback = selection.deletionPresentation.feedback {
                            deletionFeedback(feedback)
                        } else if let error = model.workspaceError,
                            !isRetainedWorkspaceConflict(error)
                        {
                            workspaceFailure(error)
                        }
                        libraryNotice
                        if writable {
                            if let rule { workspaceDetails(rule) }
                            if model.libraryPresentationState.hasUsableSnapshot {
                                soundControls
                                Text(l10n.text(.workspacePreviewNote)).font(.caption)
                                    .foregroundColor(
                                        .secondary)
                                ForEach(events) { event in eventRow(event) }
                            }
                            Button(l10n.text(.eventSettingsManageSounds)) {
                                onConfigureSound(.overview(surface: nil))
                            }
                        } else {
                            Text(l10n.text(.workspaceUnavailable)).foregroundColor(.secondary)
                                .focusable()
                                .focused($focusedTarget, equals: .unavailableScope)
                                .settingsMountIdentity("workspace.scope.unavailable")
                            if selection.route.scope != .global {
                                Button(l10n.text(.workspaceChooseDefaultGroup)) {
                                    player.stop()
                                    selection.select(EventSettingsWindowRoute(scope: .global))
                                    model.selectSoundScope(.global)
                                }
                                .settingsMountIdentity("workspace.choose-default-group")
                            }
                        }
                        writeFailures
                    }
                    .frame(maxWidth: 820, alignment: .leading)
                    .padding(24)
                }
                .id(selection.route.scope)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ClaudioTheme.panel(colorScheme))
        .accessibilityIdentifier("workspace.settings")
        .onAppear {
            #if DEBUG
            if reloadsOnAppear && !model.usesInjectedPreviewState { model.reload() }
            #else
            model.reload()
            #endif
            synchronize()
        }
        .onChange(of: selection.route) { _ in
            previewSuccessTokens.removeAll()
            synchronize()
        }
        .onChange(of: selection.presentationState.focusRequestRevision) { _ in synchronize() }
        .onDisappear {
            player.stop()
            previewSuccessTokens.removeAll()
            selection.cancelDeletion()
        }
        .sheet(
            isPresented: Binding(
                get: { selection.presentationState.credentialSheetIsPresented },
                set: {
                    if $0 {
                        selection.presentCredentialSheet()
                    } else {
                        selection.dismissCredentialSheet()
                    }
                })
        ) {
            EventSettingsAICueCredentialSheet(
                viewModel: aiCueViewModel, languageStore: languageStore)
        }
        .settingsMountIdentity(SettingsPresentationAccessibilityID.destination(.eventsAndSounds))
        .sheet(isPresented: $isAddingWorkspace) {
            AddWorkspaceSoundRuleView(model: model, language: languageStore.language) { id in
                selection.select(EventSettingsWindowRoute(scope: .workspace(id)))
                model.selectSoundScope(.workspace(id))
                isAddingWorkspace = false
            }
        }
        .alert(
            l10n.format(
                .workspaceDeleteConfirmTitle,
                selection.deletionPresentation.pending?.target.name ?? ""),
            isPresented: Binding(
                get: { selection.deletionPresentation.pending != nil },
                set: { presented in
                    guard !presented, let pending = selection.deletionPresentation.pending else {
                        return
                    }
                    // A native dismissal may arrive before its button action. Defer cancellation
                    // until the action has had a chance to consume the captured target.
                    Task { @MainActor in
                        if selection.deletionPresentation.pending == pending {
                            selection.cancelDeletion()
                        }
                    }
                }),
            presenting: selection.deletionPresentation.pending
        ) { request in
            Button(l10n.text(.workspaceCancel), role: .cancel) {
                selection.cancelDeletion()
            }
            .keyboardShortcut(.defaultAction)
            Button(l10n.text(.workspaceDeleteAction), role: .destructive) {
                confirmDeletion(request)
            }
        } message: { request in
            Text(l10n.format(.workspaceDeleteConfirmMessage, request.target.directory.path))
        }
    }

    private func synchronize() {
        player.stop()
        // Preserve invalid identities so delayed actions cannot write the Default Group.
        model.selectSoundScope(selection.route.scope)
        if let target = selection.presentationState.focusTarget {
            focusedTarget = target
        } else if selection.unavailableRequestedScopeStoredValue != nil {
            focusedTarget = .unavailableScope
        } else {
            focusedTarget =
                selection.route.event.map(EventSettingsFocusTarget.event)
                ?? .scope(selection.route.scope)
        }
    }

    private var libraryNotice: some View {
        Group {
            switch model.libraryPresentationState {
            case .loading:
                Text(l10n.text(.soundPacksLibraryLoading)).font(.caption)
            case .refreshing, .ready:
                EmptyView()
            case .refreshFailed:
                libraryFailure(l10n.text(.panelLibraryRefreshFailed))
            case .loadFailed:
                libraryFailure(l10n.text(.panelAudibleEventsUnavailable))
            }
        }
    }

    private func libraryFailure(_ message: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            FailureRow(message: message)
            Button(l10n.text(.soundPacksLibraryRetryLabel)) {
                model.retrySoundPackLibraryRefresh()
            }
            .accessibilityIdentifier("workspace.library.retry")
        }
        .settingsMountIdentity("workspace.library.failure")
    }

    private var soundControls: some View {
        let scope = selection.route.scope
        return VStack(alignment: .leading, spacing: 14) {
            Picker(
                l10n.text(.panelSoundPackLabel),
                selection: Binding(
                    get: { model.config.selectedPack },
                    set: {
                        guard model.selectedSoundScope == scope else { return }
                        let retry = EventSettingsWriteRetry(
                            scope: scope, workspaceDirectory: rule?.directory,
                            operation: .pack(before: model.config.selectedPack, requested: $0))
                        selection.clearConflictReadback()
                        _ = model.switchPack(to: $0)
                        selection.noteLockFailureRetry(retryIsLockBusy(retry) ? retry : nil)
                        markStaleWorkspaceTarget(scope)
                        selection.clearPreviewFailure()
                        onAudibilityInputsChanged()
                    })
            ) {
                if !model.allSoundPacks.contains(where: { $0.id == model.config.selectedPack }) {
                    Text(model.config.selectedPack).tag(model.config.selectedPack)
                }
                ForEach(model.allSoundPacks, id: \.id) { pack in
                    Text(SelectedPackMetadata(id: pack.id, name: pack.name).displayName).tag(
                        pack.id)
                }
            }.accessibilityIdentifier("event-settings.sound-pack-picker")
                .focused($focusedTarget, equals: .packPicker)
            EventSettingsMasterVolumeControl(
                diskVolume: model.config.masterVolume, isEnabled: writable,
                language: languageStore.language, focusedTarget: $focusedTarget
            ) { volume in
                let retry = EventSettingsWriteRetry(
                    scope: scope, workspaceDirectory: rule?.directory,
                    operation: .volume(before: model.config.masterVolume, requested: volume))
                selection.clearConflictReadback()
                let landed = model.setVolume(volume, for: scope)
                selection.noteLockFailureRetry(retryIsLockBusy(retry) ? retry : nil)
                markStaleWorkspaceTarget(scope)
                selection.clearPreviewFailure()
                onAudibilityInputsChanged()
                return landed
            }.id(selection.route.scope)
            if model.eventRows.contains(where: {
                if case .broken = $0.coverage { return true }; return false
            })
                || !model.allSoundPacks.contains(where: { $0.id == model.config.selectedPack })
            {
                FailureRow(message: l10n.text(.workspacePackRepair))
            }
        }.padding(14).background(ClaudioTheme.elevated(colorScheme))
    }

    private func workspaceDetails(_ rule: WorkspaceSoundRule) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n.text(.workspaceDirectory)).font(.headline)
            Text(rule.directory.path).textSelection(.enabled).font(
                .system(.body, design: .monospaced))
            Text(l10n.text(rule.directory.kind == .git ? .workspaceGitScope : .workspacePlainScope))
                .font(.caption)
            Text(l10n.text(.workspaceSurfaces)).font(.headline)
            ForEach(WorkspaceSurfaceEligibility.candidates, id: \.rawValue) { surface in
                let host = HostID.productVisibleCases.first { $0.surfaceID == surface }
                let sourceRow = hostIntegrations.content.sourceRows.first {
                    $0.host.surfaceID == surface
                }
                Toggle(
                    isOn: Binding(
                        get: { rule.surfaces.contains(surface) },
                        set: { enabled in
                            var surfaces = rule.surfaces.filter { $0 != surface }
                            if enabled { surfaces.append(surface) }
                            let retry = EventSettingsWriteRetry(
                                scope: .workspace(rule.id), workspaceDirectory: rule.directory,
                                operation: .surfaces(before: rule.surfaces, requested: surfaces))
                            selection.clearConflictReadback()
                            _ = model.changeWorkspace(.surfaces(rule.id, surfaces))
                            selection.noteLockFailureRetry(retryIsLockBusy(retry) ? retry : nil)
                            markStaleWorkspaceTarget(.workspace(rule.id))
                        })
                ) {
                    VStack(alignment: .leading) {
                        Text(host?.displayName ?? surface.rawValue)
                        Text(
                            !WorkspaceSurfaceEligibility.verified.contains(surface)
                                ? l10n.text(.workspaceEvidencePending)
                                : sourceRow.map {
                                    "\($0.readinessText) · \($0.supportedCount.map(String.init) ?? "—")/\($0.totalCount.map(String.init) ?? "—")"
                                } ?? l10n.text(.workspaceDisconnected)
                        )
                        .font(.caption).foregroundColor(.secondary)
                    }
                }.disabled(!WorkspaceSurfaceEligibility.verified.contains(surface))
            }
            if rule.surfaces.isEmpty { Text(l10n.text(.workspaceNoSurfaces)).font(.caption) }
            Text("WorkBuddy · " + l10n.text(.workspaceEvidencePending)).font(.caption)
                .foregroundColor(.secondary)
            Button(l10n.text(.workspaceRemove)) {
                _ = selection.requestDeletion(of: rule)
            }
            .focused($focusedTarget, equals: .workspaceRemove(rule.id))
            .settingsMountIdentity("workspace.remove")
        }
    }

    @ViewBuilder
    private func deletionFeedback(_ feedback: WorkspaceDeleteFeedback) -> some View {
        switch feedback {
        case .succeeded(let target):
            Label(
                l10n.format(.workspaceDeleteSucceeded, target.name),
                systemImage: "checkmark.circle.fill"
            )
            .focusable()
            .focused($focusedTarget, equals: .workspaceDeleteResult)
            .settingsMountIdentity("workspace.delete.result")
        case .failed(let target, let error, let readback):
            FailureRow(message: deletionFailureMessage(target, error: error, readback: readback))
                .focusable()
                .focused($focusedTarget, equals: .workspaceDeleteFeedback)
                .settingsMountIdentity("workspace.delete.failure")
            if error == .configFailure || error == .invalidRule || error.isPublishedConflict {
                configRevealButton
            }
            recoveryFileButtons(
                error.recoveryPath.map { [URL(fileURLWithPath: $0)] } ?? [],
                identifierPrefix: "workspace.delete.recovery-file")
            Button(l10n.text(.workspaceDeleteReload)) {
                model.reload()
                selection.refreshDeletionReadback(configState: model.configState)
            }
            .accessibilityIdentifier("workspace.delete.reload")
            if error == .lockBusy {
                Button(l10n.text(.commonRetry)) {
                    model.reload()
                    guard
                        let currentRule = model.workspaceRules.first(where: { $0.id == target.id })
                    else {
                        selection.refreshDeletionReadback(configState: model.configState)
                        return
                    }
                    _ = selection.requestDeletionRetry(of: currentRule)
                }
                .accessibilityIdentifier("workspace.delete.retry-confirmation")
            }
        }
    }

    private func workspaceFailure(_ error: WorkspaceSoundError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FailureRow(message: localizedWorkspaceError(error, language: languageStore.language))
            if error == .configFailure || error == .invalidRule || error.isPublishedConflict {
                configRevealButton
            }
            recoveryFileButtons(
                model.workspaceRecoveryFile.map { [$0] } ?? [],
                identifierPrefix: "workspace.write.recovery-file")
            if error == .invalidPack {
                Button(l10n.text(.eventSettingsManageSounds)) {
                    onConfigureSound(.overview(surface: nil))
                }
            }
            if error == .lockBusy, canRetryCurrentWrite {
                Button(l10n.text(.commonRetry)) { retryCurrentWrite() }
                    .accessibilityIdentifier("workspace.write.retry")
            }
            if error == .configFailure || error == .invalidRule || error.isPublishedConflict
                || error == .staleRule
            {
                Button(l10n.text(.workspaceDeleteReload)) {
                    if error.isPublishedConflict {
                        reloadConflict(
                            .workspace(error),
                            recoveryFiles: model.workspaceRecoveryFile.map { [$0] } ?? [])
                    } else {
                        model.reload()
                    }
                }
                .accessibilityIdentifier("workspace.write.reload")
            }
        }
        .settingsMountIdentity("workspace.write.failure")
    }

    private func recoveryFileButtons(
        _ files: [URL], identifierPrefix: String
    ) -> some View {
        let existing = files.compactMap(panelExistingRecoveryFileTarget)
        return ForEach(Array(existing.enumerated()), id: \.element) { index, file in
            Button(
                existing.count == 1
                    ? l10n.text(.panelRevealRecoveryFile)
                    : l10n.format(.panelRevealRecoveryFileNumber, Int64(index + 1))
            ) {
                guard let currentTarget = panelExistingRecoveryFileTarget(file) else { return }
                NSWorkspace.shared.activateFileViewerSelecting([currentTarget])
            }
            .accessibilityValue(file.path)
            .accessibilityIdentifier("\(identifierPrefix).\(index + 1)")
        }
    }

    @ViewBuilder
    private var configRevealButton: some View {
        if let target = model.configRecoveryTarget {
            Button(l10n.text(.panelRevealConfig)) {
                guard let currentTarget = model.configRecoveryTarget else { return }
                NSWorkspace.shared.activateFileViewerSelecting([currentTarget])
            }
            .accessibilityHint(l10n.text(.panelRevealConfigHint))
            .accessibilityIdentifier("workspace.reveal-config")
            .accessibilityValue(target.path)
        }
    }

    private var writeFailureItems: [PanelWriteFailure] {
        panelWriteFailureItems(
            muteError: model.muteError,
            packSwitchError: model.packSwitchError,
            masterVolumeError: model.masterVolumeError)
    }

    private var writeFailures: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(panelWriteFailureRows(items: writeFailureItems, l10n: l10n)) { row in
                FailureRow(message: row.message)
            }
            recoveryFileButtons(
                writeFailureRecoveryFiles,
                identifierPrefix: "workspace.write.reveal-recovery")
            if writeFailureItems.contains(where: { $0.reason.copyCategory.offersConfigRecovery }) {
                configRevealButton
            }
            if writeFailureItems.contains(where: {
                if case .lockBusy = $0.reason { return true }
                return false
            }), canRetryCurrentWrite {
                Button(l10n.text(.commonRetry)) { retryCurrentWrite() }
                    .accessibilityIdentifier("workspace.write.retry")
            }
            if writeFailureItems.contains(where: {
                if case .configPublishedButFailed = $0.reason { return true }
                return false
            }) {
                Button(l10n.text(.workspaceDeleteReload)) {
                    reloadConflict(
                        .writes(writeFailureItems), recoveryFiles: writeFailureRecoveryFiles)
                }
                .accessibilityIdentifier("workspace.write.reload")
            }
        }
    }

    private var writeFailureRecoveryFiles: [URL] {
        panelWriteFailureRecoveryFiles(items: writeFailureItems, surfaceRecoveryFile: nil)
    }

    @ViewBuilder
    private var unresolvedConflictNotice: some View {
        if let source = selection.unresolvedConflict {
            VStack(alignment: .leading, spacing: 8) {
                switch source {
                case .workspace(let error):
                    FailureRow(
                        message: localizedWorkspaceError(error, language: languageStore.language))
                case .writes(let failures):
                    ForEach(panelWriteFailureRows(items: failures, l10n: l10n)) { row in
                        FailureRow(message: row.message)
                    }
                }
                configRevealButton
                recoveryFileButtons(
                    selection.conflictRecoveryFiles,
                    identifierPrefix: "workspace.write.unresolved-recovery-file")
                Button(l10n.text(.workspaceDeleteReload)) {
                    reloadConflict(source, recoveryFiles: selection.conflictRecoveryFiles)
                }
                .accessibilityIdentifier("workspace.write.unresolved-reload")
            }
            .settingsMountIdentity("workspace.write.conflict-unresolved")
        }
    }

    private func isRetainedWorkspaceConflict(_ error: WorkspaceSoundError) -> Bool {
        guard case .workspace(let retained)? = selection.unresolvedConflict else { return false }
        return retained == error
    }

    private func reloadConflict(
        _ source: EventSettingsConflictSource, recoveryFiles: [URL]
    ) {
        let scope = selection.route.scope
        model.reload()
        _ = selection.finishConflictReadback(
            scope: scope, configState: model.configState, source: source,
            recoveryFiles: recoveryFiles)
    }

    private func retryIsLockBusy(_ retry: EventSettingsWriteRetry) -> Bool {
        if retry.scope.workspaceID != nil { return model.workspaceError == .lockBusy }
        switch retry.operation {
        case .pack:
            if case .lockBusy? = model.packSwitchError { return true }
        case .volume:
            if case .lockBusy? = model.masterVolumeError { return true }
        case .event:
            if case .lockBusy? = model.muteError { return true }
        case .surfaces:
            return false
        }
        return false
    }

    private func markStaleWorkspaceTarget(_ scope: PanelSoundScopeID) {
        if scope.workspaceID != nil, model.workspaceError == .staleRule {
            selection.markCurrentScopeUnavailable()
        }
    }

    private var canRetryCurrentWrite: Bool {
        guard let retry = selection.writeRetry else { return false }
        return retry.canRetry(
            route: selection.route,
            selectedScope: model.selectedSoundScope,
            configState: model.configState,
            config: model.config,
            workspaceRule: model.workspaceRules.first { $0.id == retry.scope.workspaceID })
    }

    private func retryCurrentWrite() {
        guard let retry = selection.writeRetry else { return }
        model.reload()
        guard canRetryCurrentWrite else {
            selection.clearWriteRetry()
            if retry.scope.workspaceID != nil,
                !model.workspaceRules.contains(where: { $0.id == retry.scope.workspaceID })
            {
                selection.markCurrentScopeUnavailable()
            }
            return
        }
        switch retry.operation {
        case .pack(_, let requested):
            selection.clearConflictReadback()
            _ = model.switchPack(to: requested)
        case .volume(_, let requested):
            selection.clearConflictReadback()
            _ = model.setVolume(requested, for: retry.scope)
        case .event(let event, _):
            selection.clearConflictReadback()
            model.toggleMute(event)
        case .surfaces(_, let requested):
            guard let workspaceID = retry.scope.workspaceID else { return }
            selection.clearConflictReadback()
            _ = model.changeWorkspace(.surfaces(workspaceID, requested))
        }
        selection.noteLockFailureRetry(retryIsLockBusy(retry) ? retry : nil)
        markStaleWorkspaceTarget(retry.scope)
        selection.clearPreviewFailure()
        onAudibilityInputsChanged()
    }

    private func deletionFailureMessage(
        _ target: WorkspaceSoundDeleteTarget,
        error: WorkspaceSoundError,
        readback: WorkspaceDeleteReadback?
    ) -> String {
        let reason = localizedWorkspaceError(error, language: languageStore.language)
        var message = l10n.format(.workspaceDeleteFailed, target.name, reason)
        if let readback {
            let key: ClaudioL10nKey
            switch readback {
            case .originalPresent: key = .workspaceDeleteReadbackPresent
            case .absent: key = .workspaceDeleteReadbackAbsent
            case .replaced: key = .workspaceDeleteReadbackReplaced
            case .unavailable: key = .workspaceDeleteReadbackUnavailable
            }
            message += " " + l10n.text(key)
        }
        return message
    }

    private func confirmDeletion(_ request: WorkspaceDeletionRequest) {
        guard selection.consumeDeletion(request) else { return }
        let target = request.target
        let succeeded = model.changeWorkspace(.remove(target))
        let error = model.workspaceError
        let selectedDefault = selection.finishDeletion(
            request, succeeded: succeeded, error: error, configState: model.configState)
        if selectedDefault { model.selectSoundScope(.global) }
        if let feedback = selection.deletionPresentation.feedback {
            switch feedback {
            case .succeeded:
                onAnnouncement(l10n.format(.workspaceDeleteSucceeded, target.name))
            case .failed(let failedTarget, let reason, let readback):
                onAnnouncement(
                    deletionFailureMessage(
                        failedTarget, error: reason, readback: readback))
            }
        }
    }

    private func eventRow(_ event: PanelEventPresentation) -> some View {
        let scope = selection.route.scope
        let recovery = eventPreviewRecoveryAction(for: event.controls.previewAvailability)
        let failure = selection.previewFailure.flatMap {
            $0.scope == scope && $0.packID == model.config.selectedPack
                && $0.event == event.event ? $0 : nil
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ClaudioEventGlyph(event: event.event, size: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title)
                        .font(ClaudioTheme.font(.body).weight(.semibold))
                    Text(event.soundFileText).font(.caption).foregroundColor(.secondary)
                    if !event.controls.previewEnabled {
                        Text(
                            localizedEventPreviewHint(
                                event.controls.previewAvailability,
                                language: languageStore.language)
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(
                            "workspace.event.preview-reason.\(event.event.cliName)")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityHint(
                    localizedEventPreviewHint(
                        event.controls.previewAvailability,
                        language: languageStore.language)
                )
                .focusable()
                .focused($focusedTarget, equals: .event(event.event))
                Spacer()
                Button {
                    let packID = model.config.selectedPack
                    switch model.attemptPreview(event.event, using: player) {
                    case .started:
                        selection.clearPreviewFailure()
                        previewPulseTriggers[event.event, default: 0] &+= 1
                        let token = UUID()
                        previewSuccessTokens[event.event] = token
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.2))
                            if previewSuccessTokens[event.event] == token {
                                previewSuccessTokens.removeValue(forKey: event.event)
                            }
                        }
                    case .failed(let failure):
                        previewSuccessTokens.removeValue(forKey: event.event)
                        reportPreviewFailure(
                            failure, event: event.event, scope: scope, packID: packID)
                    }
                } label: {
                    Image(systemName: "play.fill")
                        .claudioPreviewPulse(
                            trigger: previewPulseTriggers[event.event, default: 0])
                }
                .disabled(!event.controls.previewEnabled)
                .accessibilityLabel(l10n.format(.eventPreviewLabel, event.title))
                .accessibilityHint(
                    localizedEventPreviewHint(
                        event.controls.previewAvailability,
                        language: languageStore.language)
                )
                .focused($focusedTarget, equals: .preview(event.event))
                if recovery == .adjustGroupVolume {
                    Button(l10n.text(.eventPreviewAdjustGroupVolume)) {
                        guard selection.requestGroupVolumeFocus(for: scope) else { return }
                        focusedTarget = .masterVolume
                    }
                    .accessibilityIdentifier("workspace.event.adjust-volume.\(event.event.cliName)")
                }
                Button(
                    l10n.text(
                        recovery == .repairSound
                            ? .eventPreviewRepairSound : .eventSettingsManageSounds)
                ) {
                    configureSound(event.event, scope: scope)
                }
                .disabled(!writable)
                .focused($focusedTarget, equals: .configure(event.event))
                Toggle(
                    event.title,
                    isOn: Binding(
                        get: { event.enabled },
                        set: { _ in
                            guard model.selectedSoundScope == scope else { return }
                            let retry = EventSettingsWriteRetry(
                                scope: scope, workspaceDirectory: rule?.directory,
                                operation: .event(
                                    event.event, before: model.config.isEnabled(event.event)))
                            selection.clearConflictReadback()
                            model.toggleMute(event.event)
                            selection.noteLockFailureRetry(retryIsLockBusy(retry) ? retry : nil)
                            markStaleWorkspaceTarget(scope)
                            selection.clearPreviewFailure()
                            onAudibilityInputsChanged()
                        })
                ).labelsHidden().toggleStyle(.switch).disabled(!event.controls.muteEnabled)
                    .focused($focusedTarget, equals: .mute(event.event))
            }
            if reduceMotion && previewSuccessTokens[event.event] != nil {
                Label(l10n.text(.eventPreviewStarted), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(ClaudioTheme.clay(colorScheme))
                    .accessibilityIdentifier(
                        "workspace.event.preview-started.\(event.event.cliName)")
            }
            if let failure {
                FailureRow(
                    message: localizedEventPreviewAttemptFailure(
                        failure.reason, language: languageStore.language)
                )
                .settingsMountIdentity("workspace.event.preview-failure.\(event.event.cliName)")
            }
        }.padding(12).background(ClaudioTheme.elevated(colorScheme))
            .cornerRadius(ClaudioTheme.Radius.row)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("workspace.event.\(event.event.cliName)")
    }

    private func configureSound(_ event: Event, scope: PanelSoundScopeID) {
        guard model.selectedSoundScope == scope, selection.route.scope == scope else { return }
        onConfigureSound(.editEvent(scope: scope, packID: model.config.selectedPack, event: event))
    }

    private func reportPreviewFailure(
        _ reason: EventPreviewAttemptFailure,
        event: Event,
        scope: PanelSoundScopeID,
        packID: String
    ) {
        guard
            selection.notePreviewFailure(
                event: event, scope: scope, packID: packID, reason: reason)
        else { return }
        let message = localizedEventPreviewAttemptFailure(reason, language: languageStore.language)
        onAnnouncement(message)
    }
}

@MainActor
private struct AddWorkspaceSoundRuleView: View {
    @ObservedObject var model: PanelConfigController
    let language: ClaudioAppLanguage
    let onCreated: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var directory: WorkspaceDirectory?
    @State private var selectedPack = ""
    @State private var volume = ClaudioConfig.defaultMasterVolume
    @State private var volumeConfirmed = false
    @State private var surfaces = WorkspaceSurfaceEligibility.verified
    @State private var resolving = false
    @State private var failure: WorkspaceSoundError?
    private var l10n: ClaudioL10n { ClaudioL10n(language: language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(l10n.text(.workspaceAdd)).font(.title2)
            Button(l10n.text(.workspaceChooseDirectory)) { chooseDirectory() }.disabled(resolving)
            if let directory {
                Text(directory.path).textSelection(.enabled)
                Text(l10n.text(directory.kind == .git ? .workspaceGitScope : .workspacePlainScope))
                    .font(.caption)
            }
            Picker(l10n.text(.panelSoundPackLabel), selection: $selectedPack) {
                Text(l10n.text(.workspaceSelectPack)).tag("")
                ForEach(model.allSoundPacks, id: \.id) { pack in
                    Text(SelectedPackMetadata(id: pack.id, name: pack.name).displayName).tag(
                        pack.id)
                }
            }
            HStack {
                Text(l10n.text(.panelMasterVolume))
                Slider(value: $volume, in: 0...1).accessibilityLabel(l10n.text(.panelMasterVolume))
                    .onChange(of: volume) { _ in
                        volumeConfirmed = false
                    }
                Text("\(Int(volume * 100))%").monospacedDigit()
            }
            Toggle(l10n.text(.workspaceVolumeConfirm), isOn: $volumeConfirmed)
            Text(l10n.text(.workspaceSurfaces)).font(.headline)
            ForEach(WorkspaceSurfaceEligibility.candidates, id: \.rawValue) { surface in
                Toggle(
                    HostID.productVisibleCases.first { $0.surfaceID == surface }?.displayName
                        ?? surface.rawValue,
                    isOn: Binding(
                        get: { surfaces.contains(surface) },
                        set: {
                            if $0 { surfaces.insert(surface) } else { surfaces.remove(surface) }
                        })
                ).disabled(!WorkspaceSurfaceEligibility.verified.contains(surface))
            }
            if WorkspaceSurfaceEligibility.verified.isEmpty {
                Text(l10n.text(.workspaceEvidencePending)).font(.caption)
            }
            if let error = failure ?? model.workspaceError {
                FailureRow(message: localizedWorkspaceError(error, language: language))
            }
            HStack {
                Button(l10n.text(.workspaceCancel)) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(l10n.text(.workspaceCreate)) {
                    guard let directory else { return }
                    let rule = WorkspaceSoundRule(
                        directory: directory,
                        surfaces: surfaces.sorted { $0.rawValue < $1.rawValue },
                        profile: WorkspaceSoundProfile(selectedPack: selectedPack, volume: volume))
                    if model.changeWorkspace(.add(rule)) { onCreated(rule.id) }
                }.disabled(
                    directory == nil || selectedPack.isEmpty || !volumeConfirmed || resolving
                )
                .keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520)
    }
    private func chooseDirectory() {
        guard let url = runWorkspaceDirectoryOpenPanel() else { return }
        resolving = true; failure = nil
        Task {
            let result = await Task.detached { WorkspaceDirectoryResolver.resolve(url.path) }.value
            resolving = false
            switch result {
            case .success(let resolved): directory = resolved
            case .failure: directory = nil; failure = .invalidRule
            }
        }
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
