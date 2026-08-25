import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI
import UniformTypeIdentifiers

private struct PermanentAudioDeletionRequest: Identifiable {
    let packID: String
    let file: PackAudioFile

    var id: String { "\(packID)/\(file.fileName)" }
}

private struct FactoryPackRestoreRequest: Identifiable {
    enum Kind {
        case selectedPack
        case failedPublishRetry
        case allFactoryPacks
    }

    let packID: String
    let displayName: String
    let kind: Kind

    var id: String { packID }
}

/// Standard-window surface: full pack sidebar plus the selected pack's four mappings.
///
/// T9 adds a window-owned focus/VoiceOver/Dynamic Type layer. T11 adds selected-pack audio
/// inventory, existing-audio assignment, and explicit confirmed orphan deletion.
@MainActor
struct SoundPacksWindowView: View {
    @ObservedObject var model: SoundPacksWindowModel
    let userPacksDirectory: URL
    @ObservedObject var focusCoordinator: SoundPacksWindowFocusCoordinator
    @ObservedObject var languageStore: ClaudioLanguageStore

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ClaudioInterfaceTextSize.defaultsKey)
    private var interfaceTextSizeRaw = ClaudioInterfaceTextSize.defaultValue.rawValue
    @FocusState private var focusedTarget: SoundPacksWindowFocusTarget?
    @State private var handledFocusRequestRevision = 0
    @State private var pendingPermanentDeletion: PermanentAudioDeletionRequest?
    @State private var pendingFactoryPackRestore: FactoryPackRestoreRequest?
    @State private var previewPlayer = NSSoundAudioPreviewPlayer()
    @State private var isImportingAudio = false
    @State private var dropTargetEvent: Event?
    @State private var requestedRoute: SoundPacksWindowRoute = .overview

    private var l10n: ClaudioL10n { ClaudioL10n(language: languageStore.language) }

    var body: some View {
        VStack(spacing: 0) {
            managedScopeBar
            libraryStatusBar
            Group {
                if layoutAdaptation.stacksPrimaryRegions {
                    VSplitView {
                        sidebar
                            .frame(
                                minHeight: layoutAdaptation.sidebarMinimumHeight,
                                idealHeight: 180)
                        detail
                            .frame(
                                minWidth: 0,
                                maxWidth: .infinity,
                                minHeight: 200,
                                maxHeight: .infinity)
                    }
                } else {
                    HSplitView {
                        sidebar
                            .frame(
                                minWidth: layoutAdaptation.sidebarMinimumWidth,
                                idealWidth: layoutAdaptation.sidebarIdealWidth,
                                maxWidth: layoutAdaptation.sidebarMaximumWidth)
                        detail
                            .frame(
                                minWidth: layoutAdaptation.detailMinimumWidth,
                                maxWidth: .infinity,
                                maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .background(ClaudioTheme.panel(colorScheme))
        .environment(\.dynamicTypeSize, interfaceTextSize.dynamicTypeSize)
        .onReceive(focusCoordinator.$requestRevision) { revision in
            guard revision > handledFocusRequestRevision else { return }
            requestedRoute = focusCoordinator.requestedRoute
            handledFocusRequestRevision = revision
            applyInitialFocus()
        }
        .onChange(of: model.packCards.map(\.id)) { _ in
            reconcileFocusWithVisibleControls()
        }
        .onChange(of: model.selectedPackID) { _ in
            reconcileFocusWithVisibleControls()
        }
        .onChange(of: model.selectedAudioInventoryState) { _ in
            reconcileFocusWithVisibleControls()
        }
        .onChange(of: model.selectedEventRows) { _ in
            reconcileFocusWithVisibleControls()
        }
        .onChange(of: model.factoryRestoreRetryPackIDs) { _ in
            if model.packCards.isEmpty, let packID = model.factoryRestoreRetryPackIDs.first {
                focusedTarget = .retryFactoryRestore(packID: packID)
            } else {
                reconcileFocusWithVisibleControls()
            }
        }
        .onChange(of: model.libraryPresentationState) { _ in
            reconcileFocusWithVisibleControls(assignFirstIfNil: true)
        }
        .confirmationDialog(
            pendingPermanentDeletion.map {
                l10n.format(.soundPacksDeleteTitle, $0.file.fileName)
            } ?? l10n.text(.soundPacksDeleteButton),
            isPresented: Binding(
                get: { pendingPermanentDeletion != nil },
                set: { if !$0 { pendingPermanentDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingPermanentDeletion
        ) { request in
            Button(l10n.text(.soundPacksDeleteButton), role: .destructive) {
                model.deleteSelectedOrphanAudioFileAfterConfirmation(
                    request.file.fileName,
                    expectedPackID: request.packID)
                pendingPermanentDeletion = nil
            }
            .accessibilityLabel(l10n.format(.soundPacksOrphanDeleteLabel, request.file.fileName))
            .accessibilityHint(l10n.text(.soundPacksDeleteHint))
            .accessibilityIdentifier("sound-packs.confirm-delete")
            Button(l10n.text(.commonCancel), role: .cancel) {
                pendingPermanentDeletion = nil
            }
            .accessibilityLabel(l10n.text(.commonCancel))
            .accessibilityIdentifier("sound-packs.cancel-delete")
        } message: { request in
            Text(l10n.format(.soundPacksDeleteMessage, request.file.fileName))
        }
        .confirmationDialog(
            pendingFactoryPackRestore.map {
                l10n.format(.soundPacksRestoreTitle, $0.displayName)
            } ?? l10n.text(.soundPacksRestore),
            isPresented: Binding(
                get: { pendingFactoryPackRestore != nil },
                set: { if !$0 { pendingFactoryPackRestore = nil } }),
            titleVisibility: .visible,
            presenting: pendingFactoryPackRestore
        ) { request in
            Button(l10n.text(.soundPacksRestoreButton), role: .destructive) {
                switch request.kind {
                case .selectedPack:
                    model.restoreSelectedFactoryPackAfterConfirmation(
                        expectedPackID: request.packID)
                case .failedPublishRetry:
                    model.retryFailedFactoryPackRestoreAfterConfirmation(
                        expectedPackID: request.packID)
                case .allFactoryPacks:
                    model.restoreAllFactoryPacksAfterConfirmation()
                }
                pendingFactoryPackRestore = nil
            }
            .accessibilityLabel(l10n.format(.soundPacksRestoreLabel, request.displayName))
            .accessibilityHint(l10n.text(.soundPacksRestoreHint))
            .accessibilityIdentifier("sound-packs.confirm-factory-restore")
            Button(l10n.text(.commonCancel), role: .cancel) {
                pendingFactoryPackRestore = nil
            }
            .accessibilityLabel(l10n.text(.commonCancel))
            .accessibilityIdentifier("sound-packs.cancel-factory-restore")
        } message: { request in
            Text(factoryRestoreConfirmationMessage(request))
        }
    }

    private var managedScopeBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: model.managedSurface == nil ? "globe" : "square.stack.3d.up.fill")
                    .foregroundColor(ClaudioTheme.clay(colorScheme))
                    .accessibilityHidden(true)
                Text(l10n.format(.soundPacksManagingScope, managedScopeName))
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundColor(ClaudioTheme.text(colorScheme))
                Spacer(minLength: 0)
            }
            if let reason = localizedManagedScopeFailure {
                FailureRow(message: reason)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ClaudioTheme.elevated(colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            l10n.format(.soundPacksManagingScope, managedScopeName))
        .accessibilityIdentifier("sound-packs.managed-scope")
    }

    private var managedScopeName: String {
        guard let surface = model.managedSurface else {
            return l10n.text(.panelGlobalName)
        }
        return HostID.productVisibleCases.first(where: { $0.surfaceID == surface })?.displayName
            ?? surface.rawValue
    }

    private var localizedManagedScopeFailure: String? {
        guard let reason = model.managedScopeFailureReason else { return nil }
        if model.managedScopeIsInvalid, let surface = model.managedSurface {
            return l10n.format(.soundPacksInvalidScope, surface.rawValue)
        }
        if model.managedSurfaceProfileIsMalformed {
            return l10n.format(.soundPacksDamagedScope, managedScopeName)
        }
        return reason
    }

    @ViewBuilder
    private var libraryStatusBar: some View {
        switch model.libraryPresentationState {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(l10n.text(.soundPacksLibraryLoading))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(l10n.text(.soundPacksLibraryLoading).replacingOccurrences(of: "…", with: ""))
            .accessibilityIdentifier("sound-packs.library.loading")
        case .refreshing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(l10n.text(.soundPacksLibraryRefreshing))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(l10n.text(.soundPacksLibraryRefreshing))
            .accessibilityIdentifier("sound-packs.library.refreshing")
        case .refreshFailed(let reason), .loadFailed(let reason):
            HStack(alignment: .center, spacing: 10) {
                FailureRow(
                    message: model.libraryPresentationState == .refreshFailed(reason: reason)
                        ? l10n.format(.soundPacksLibraryRefreshFailed, reason)
                        : reason)
                Spacer(minLength: 8)
                Button(l10n.text(.commonRetry)) {
                    model.retrySoundPackLibraryRefresh()
                }
                .accessibilityLabel(l10n.text(.soundPacksLibraryRetryLabel))
                .accessibilityHint(l10n.text(.soundPacksLibraryRetryHint))
                .accessibilityIdentifier("sound-packs.library.retry")
                .focused($focusedTarget, equals: .retryLibraryLoad)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        case .ready:
            EmptyView()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(l10n.text(.soundPacksSidebarTitle))
                    .font(.headline)
                Spacer(minLength: 8)
                Text(l10n.format(
                    .soundPacksSidebarStars,
                    Int64(model.starredPackIDs.count),
                    Int64(maxStarredPacks)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(l10n.format(
                .soundPacksSidebarLabel) + (languageStore.language == .english ? ", " : "，") + l10n.format(
                    .soundPacksSidebarStars,
                    Int64(model.starredPackIDs.count),
                    Int64(maxStarredPacks)))
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 10)
            .padding(.top, 10)

            List(selection: selection) {
                ForEach(model.packCards, id: \.id) { card in
                    let starControl = model.starControl(for: card)
                    HStack(spacing: 6) {
                        starButton(card, control: starControl)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(SelectedPackMetadata(id: card.id, name: card.name).displayName)
                                .lineLimit(layoutAdaptation.packNameLineLimit)
                                .fixedSize(horizontal: false, vertical: true)
                            if let reason = starControl.disabledReason {
                                Text(reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityHidden(true)
                            }
                        }
                        Spacer(minLength: 4)
                        if card.isSelected {
                            ClaudioStatusCapsule(l10n.text(.soundPacksUsing), isEmphasized: true)
                        }
                    }
                    .frame(minHeight: ClaudioTheme.Metrics.regularControlHeight)
                    .contentShape(Rectangle())
                    .tag(Optional(card.id))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(packAccessibilityLabel(card))
                    .accessibilityValue(packAccessibilityValue(card))
                    .accessibilityHint(l10n.text(.soundPacksCardHint))
                    .accessibilityIdentifier("sound-packs.pack.\(card.id)")
                    .accessibilityAddTraits(
                        model.selectedPackID == card.id ? .isSelected : [])
                }
            }
            .focusable(!model.packCards.isEmpty)
            .focused($focusedTarget, equals: .packList)
            .accessibilityLabel(l10n.text(.soundPacksSidebarLabel))
            .accessibilityValue(
                selectedCard.map {
                    l10n.format(
                        .soundPacksSidebarViewing,
                        SelectedPackMetadata(id: $0.id, name: $0.name).displayName)
                } ?? l10n.text(.soundPacksSidebarNone)
            )
            .accessibilityHint(l10n.text(.soundPacksSidebarHint))
            .accessibilityIdentifier("sound-packs.pack-list")
        }
    }

    private func starButton(
        _ card: PackCard,
        control: SoundPacksWindowStarControl
    ) -> some View {
        let displayName = SelectedPackMetadata(id: card.id, name: card.name).displayName
        return Button {
            model.toggleStarredPack(card.id)
        } label: {
            Image(systemName: control.isStarred ? "star.fill" : "star")
                .font(.system(size: 13, weight: .semibold))
                .frame(
                    minWidth: ClaudioTheme.Metrics.iconTarget,
                    minHeight: ClaudioTheme.Metrics.iconTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!control.isEnabled)
        .help(control.disabledReason ?? "")
        .accessibilityLabel(
            control.isStarred
            ? l10n.format(.soundPacksStarUnpin, displayName)
                : l10n.format(.soundPacksStarPin, displayName)
        )
        .accessibilityHint(
            control.disabledReason
                ?? (control.isStarred
                    ? l10n.text(.soundPacksStarUnpinHint)
                    : l10n.text(.soundPacksStarPinHint))
        )
        .accessibilityValue(
            control.isStarred
                ? l10n.text(.soundPacksStarPinned)
                : l10n.text(.soundPacksStarUnpinned))
        .accessibilityAddTraits(control.isStarred ? .isSelected : [])
        .accessibilityIdentifier("sound-packs.pack.\(card.id).star")
    }

    @ViewBuilder
    private var detail: some View {
        GeometryReader { geometry in
            let stacksDetail = soundPacksWindowDetailUsesStackedLayout(
                detailWidth: geometry.size.width,
                tier: typeSizeTier)
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Color.clear.frame(height: 0).id("detail-top")
                        if !model.windowStatuses.isEmpty {
                            windowStatusRegion
                                .padding(.horizontal, 20)
                                .padding(.top, 20)
                        }

                        if let card = selectedCard {
                            VStack(alignment: .leading, spacing: 16) {
                                detailHeader(card, stacks: stacksDetail)

                                if model.selectedPackIsBuiltinReadOnly {
                                    builtinCopyExplanation(card)
                                }

                                Divider()

                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(model.selectedEventRows, id: \.event) { row in
                                        eventMappingRow(
                                            row,
                                            stacks: layoutAdaptation.stacksEventRows
                                                    || stacksDetail
                                            )
                                            .id("event-\(row.event.rawValue)")
                                    }
                                }

                                if model.selectedAudioInventoryState.isLoading {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text(l10n.text(.soundPacksAudioLoading))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityLabel(l10n.text(.soundPacksAudioLoadingLabel))
                                }

                                if let error = model.audioInventoryError {
                                    windowFailureRow(
                                        action: l10n.text(.soundPacksAudioLoadingLabel),
                                        reason: inventoryErrorMessage(error))
                                }

                                orphanAudioSection
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                        } else {
                            emptyState
                        }
                    }
                        .frame(
                            maxWidth: .infinity,
                            minHeight: selectedCard == nil ? geometry.size.height : nil,
                            alignment: .topLeading)
                    }
                    .onChange(of: model.selectedPackID) { _ in
                        withAnimation(.easeOut(duration: 0.14)) {
                            proxy.scrollTo("detail-top", anchor: .top)
                        }
                    }
                    .onChange(of: handledFocusRequestRevision) { _ in
                        guard let event = requestedRoute.editTarget?.event else { return }
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.14)) {
                                proxy.scrollTo("event-\(event.rawValue)", anchor: .center)
                            }
                        }
                    }
                }
                if let card = selectedCard {
                    Divider()
                    packActionBar(card, stacks: stacksDetail)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var windowStatusRegion: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.windowStatuses) { status in
                windowStatusRow(status)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func detailHeader(_ card: PackCard, stacks: Bool) -> some View {
        if stacks {
            VStack(alignment: .leading, spacing: 10) {
                detailIdentity(card)
                revealButton(card)
            }
        } else {
            HStack {
                detailIdentity(card)
                Spacer(minLength: 12)
                revealButton(card)
            }
        }
    }

    private func detailIdentity(_ card: PackCard) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(SelectedPackMetadata(id: card.id, name: card.name).displayName)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let label = licenseBadgeLabel(metaSlots.license) {
                    Text(label)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.selectedPackIsBuiltinReadOnly {
                ClaudioStatusCapsule(l10n.text(.soundPacksBuiltinBadge))
                    .accessibilityLabel(l10n.text(.soundPacksBuiltinLabel))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func revealButton(_ card: PackCard) -> some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([
                userPacksDirectory.appendingPathComponent(card.id)
            ])
        } label: {
            Text(l10n.text(.soundPacksReveal))
                .frame(minHeight: ClaudioTheme.Metrics.compactControlHeight)
                .fixedSize(horizontal: false, vertical: true)
        }
        .focused($focusedTarget, equals: .revealSelectedPack)
        .accessibilityLabel(
            l10n.format(
                .soundPacksRevealLabel,
                SelectedPackMetadata(id: card.id, name: card.name).displayName)
        )
        .accessibilityValue(userPacksDirectory.appendingPathComponent(card.id).path)
        .accessibilityHint(l10n.text(.soundPacksRevealHint))
        .accessibilityIdentifier("sound-packs.reveal-selected")
        .disabled(card.availability == .missingSelectedPlaceholder)
    }

    private func factoryRestoreButton(_ card: PackCard) -> some View {
        let displayName = SelectedPackMetadata(id: card.id, name: card.name).displayName
        return Button(l10n.text(.soundPacksRestore)) {
            pendingFactoryPackRestore = FactoryPackRestoreRequest(
                packID: card.id,
                displayName: displayName,
                kind: .selectedPack)
        }
        .frame(minHeight: ClaudioTheme.Metrics.compactControlHeight)
        .focused($focusedTarget, equals: .restoreFactoryPack)
        .accessibilityLabel(l10n.format(.soundPacksRestorePackLabel, displayName))
        .accessibilityValue(l10n.text(.soundPacksBuiltinValue))
        .accessibilityHint(l10n.text(.soundPacksRestorePackHint))
        .accessibilityIdentifier("sound-packs.restore-selected-factory-pack")
    }

    private func builtinCopyExplanation(_ card: PackCard) -> some View {
        let message = l10n.text(.soundPacksBuiltinCopyExplanation)
        return Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .help(message)
            .accessibilityLabel(message)
    }

    @ViewBuilder
    private func packActionBar(_ card: PackCard, stacks: Bool) -> some View {
        if stacks {
            VStack(alignment: .leading, spacing: 8) {
                packActions(card, includeFlexibleSpace: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 8) {
                packActions(card, includeFlexibleSpace: true)
            }
        }
    }

    @ViewBuilder
    private func packActions(_ card: PackCard, includeFlexibleSpace: Bool) -> some View {
        let displayName = SelectedPackMetadata(id: card.id, name: card.name).displayName
        if model.selectedPackIsMissingPlaceholder {
            if model.selectedPackCanRestoreFactory {
                factoryRestoreButton(card)
            }
        } else if model.selectedPackIsBuiltinReadOnly {
            Button(l10n.text(.soundPacksCopy)) {
                model.forkSelectedFactoryPack()
            }
            .buttonStyle(.borderedProminent)
            .tint(ClaudioSharedColor.clay(colorScheme))
            .frame(minHeight: ClaudioTheme.Metrics.regularControlHeight)
            .fixedSize(horizontal: false, vertical: true)
            .focused($focusedTarget, equals: .forkFactoryPack)
            .help(builtinCopyHelp(card))
            .accessibilityLabel(l10n.format(.soundPacksCopyLabel, displayName))
            .accessibilityValue(l10n.text(.soundPacksOriginalReadonly))
            .accessibilityHint(builtinCopyHelp(card))
            .accessibilityIdentifier("sound-packs.fork-selected-pack")

            factoryRestoreButton(card)
        } else {
            Button(isImportingAudio
                ? l10n.text(.soundPacksAddingAudio)
                : l10n.text(.soundPacksAddAudio)) {
                chooseAndImportAudio()
            }
            .disabled(isImportingAudio || !canEditSelectedPack)
            .frame(minHeight: ClaudioTheme.Metrics.regularControlHeight)
            .fixedSize(horizontal: false, vertical: true)
            .focused($focusedTarget, equals: .addAudio)
            .accessibilityLabel(l10n.format(.soundPacksAddAudioLabel, displayName))
            .accessibilityValue(isImportingAudio
                ? l10n.text(.soundPacksImporting)
                : l10n.text(.soundPacksCanChooseFile))
            .accessibilityHint(l10n.text(.soundPacksAddAudioHint))
            .accessibilityIdentifier("sound-packs.add-audio")
        }

        if includeFlexibleSpace {
            Spacer(minLength: 8)
        }

        if card.isSelected {
            ClaudioStatusCapsule(l10n.text(.soundPacksUsing), isEmphasized: true)
                .accessibilityLabel(l10n.text(.soundPacksUsing))
        } else if model.selectedPackIsBuiltinReadOnly {
            Button(l10n.text(.soundPacksUse)) {
                model.useSelectedPack()
            }
            .frame(minHeight: ClaudioTheme.Metrics.regularControlHeight)
            .focused($focusedTarget, equals: .useSelectedPack)
            .accessibilityLabel(l10n.format(.soundPacksUseLabel, displayName))
            .accessibilityValue(l10n.text(.soundPacksUseValue))
            .accessibilityHint(l10n.text(.soundPacksUseHint))
            .accessibilityIdentifier("sound-packs.use-selected-pack")
        } else {
            Button(l10n.text(.soundPacksUse)) {
                model.useSelectedPack()
            }
            .buttonStyle(.borderedProminent)
            .tint(ClaudioSharedColor.clay(colorScheme))
            .frame(minHeight: ClaudioTheme.Metrics.regularControlHeight)
            .focused($focusedTarget, equals: .useSelectedPack)
            .accessibilityLabel(l10n.format(.soundPacksUseLabel, displayName))
            .accessibilityValue(l10n.text(.soundPacksUseValue))
            .accessibilityHint(l10n.text(.soundPacksUseHint))
            .accessibilityIdentifier("sound-packs.use-selected-pack")
        }
    }

    private func builtinCopyHelp(_ card: PackCard) -> String {
        if card.factoryIntegrity == false {
            return l10n.text(.soundPacksBuiltinCopyHelp)
        }
        switch card.state {
        case .complete:
            return l10n.text(.soundPacksBuiltinCopyHelp)
        case .partial, .broken:
            return l10n.text(.soundPacksBuiltinCopyHelp)
        }
    }

    private func chooseAndImportAudio() {
        guard let expectedPackID = model.selectedPackID else { return }
        let requests = runAudioOpenPanel(allowsMultipleSelection: true).map {
            AudioImportRequest(sourceURL: $0, suggestedFileName: $0.lastPathComponent)
        }
        guard !requests.isEmpty else { return }
        isImportingAudio = true
        Task {
            defer { isImportingAudio = false }
            let result = await model.importSelectedAudioFiles(
                requests,
                expectedPackID: expectedPackID)
            guard
                case .success(let completion) = result,
                let previewFile = completion.previewFile
            else { return }
            if previewVolume(for: model.config) > 0 {
                previewPlayer.play(
                    fileAt: previewFile.destinationURL,
                    volume: Float(previewVolume(for: model.config)))
            }
        }
    }

    private func chooseAndBindAudio(to event: Event) {
        guard
            let sourceURL = runAudioOpenPanel(allowsMultipleSelection: false).first,
            let expectedPackID = model.selectedPackID
        else { return }
        let request = AudioImportRequest(
            sourceURL: sourceURL,
            suggestedFileName: sourceURL.lastPathComponent)
        importAndBind(request, to: event, expectedPackID: expectedPackID)
    }

    private func importAndBind(
        _ request: AudioImportRequest,
        to event: Event,
        expectedPackID: String
    ) {
        guard canEditSelectedPack, !isImportingAudio else { return }
        isImportingAudio = true
        Task {
            defer { isImportingAudio = false }
            let result = await model.importSelectedAudioFiles(
                [request],
                expectedPackID: expectedPackID)
            guard
                case .success(let completion) = result,
                let imported = completion.result.accepted.last,
                !completion.completedInBackground,
                completion.targetPackID == model.selectedPackID,
                case .success = model.assignImportedAudioFile(imported, to: event)
            else { return }
            if previewVolume(for: model.config) > 0 {
                previewPlayer.play(
                    fileAt: imported.destinationURL,
                    volume: Float(previewVolume(for: model.config)))
            }
        }
    }

    private func revealMappedAudio(for event: Event) {
        guard let fileURL = model.previewFileForSelectedEvent(event) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private func dropTargetBinding(for event: Event) -> Binding<Bool> {
        Binding(
            get: { dropTargetEvent == event },
            set: { isTargeted in
                if isTargeted {
                    dropTargetEvent = event
                } else if dropTargetEvent == event {
                    dropTargetEvent = nil
                }
            })
    }

    private func handleAudioDrop(_ providers: [NSItemProvider], onto event: Event) -> Bool {
        guard
            canEditSelectedPack,
            !isImportingAudio,
            let expectedPackID = model.selectedPackID,
            let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            })
        else { return false }

        Task { @MainActor in
            guard let request = await loadSoundPacksDropRequest(from: provider) else { return }
            importAndBind(request, to: event, expectedPackID: expectedPackID)
        }
        return true
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Text(emptyLibraryTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if model.libraryPresentationState == .loading {
                Text(l10n.text(.soundPacksEmptyLoadingMessage))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if case .loadFailed = model.libraryPresentationState {
                Text(l10n.text(.soundPacksEmptyLoadFailedMessage))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.hasFactoryPacks {
                Text(l10n.text(.soundPacksEmptyFactoryMessage))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(l10n.text(.soundPacksEmptyRestore)) {
                    pendingFactoryPackRestore = FactoryPackRestoreRequest(
                        packID: "all-factory-packs",
                        displayName: l10n.text(.soundPacksEmptyRestoreLabel),
                        kind: .allFactoryPacks)
                }
                .buttonStyle(.borderedProminent)
                .tint(ClaudioSharedColor.clay(colorScheme))
                .frame(minHeight: ClaudioTheme.Metrics.regularControlHeight)
                .focused($focusedTarget, equals: .restoreAllFactoryPacks)
                .accessibilityLabel(l10n.text(.soundPacksEmptyRestoreLabel))
                .accessibilityValue(l10n.text(.soundPacksEmptyRestoreValue))
                .accessibilityHint(l10n.text(.soundPacksEmptyRestoreHint))
                .accessibilityIdentifier("sound-packs.restore-all-factory-packs")
            } else {
                Text(l10n.text(.soundPacksEmptyNoFactoryMessage))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(l10n.text(.soundPacksEmptyReveal)) {
                    revealPacksDirectory()
                }
                .frame(minHeight: ClaudioTheme.Metrics.regularControlHeight)
                .focused($focusedTarget, equals: .revealPacksDirectory)
                .accessibilityLabel(l10n.text(.soundPacksEmptyRevealLabel))
                .accessibilityValue(userPacksDirectory.path)
                .accessibilityHint(l10n.text(.soundPacksEmptyRevealHint))
                .accessibilityIdentifier("sound-packs.reveal-packs-directory")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var emptyLibraryTitle: String {
        switch model.libraryPresentationState {
        case .loading: return l10n.text(.soundPacksLibraryLoading).replacingOccurrences(of: "…", with: "")
        case .loadFailed: return l10n.text(.panelPacksReadFailed)
        case .ready, .refreshing, .refreshFailed: return l10n.text(.panelPacksNoneTitle)
        }
    }

    private func revealPacksDirectory() {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: userPacksDirectory.path,
            isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            NSWorkspace.shared.open(userPacksDirectory)
        } else {
            NSWorkspace.shared.open(userPacksDirectory.deletingLastPathComponent())
        }
    }

    @ViewBuilder
    private func windowStatusRow(_ status: SoundPacksWindowStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if status.severity == .failure {
                windowFailureRow(
                    action: status.action(language: languageStore.language),
                    reason: status.message(language: languageStore.language))
            } else {
                let message = status.message(language: languageStore.language)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(message)
            }
            if case .retryFactoryRestores(let packIDs)? = status.recovery {
                ForEach(packIDs, id: \.self) { packID in
                    let displayName = SelectedPackMetadata(id: packID, name: nil).displayName
                    Button(l10n.format(.soundPacksRetryRestore, displayName)) {
                        pendingFactoryPackRestore = FactoryPackRestoreRequest(
                            packID: packID,
                            displayName: displayName,
                            kind: .failedPublishRetry)
                    }
                    .frame(minHeight: ClaudioTheme.Metrics.regularControlHeight)
                    .focused(
                        $focusedTarget,
                        equals: .retryFactoryRestore(packID: packID)
                    )
                    .accessibilityLabel(l10n.format(.soundPacksRetryRestoreLabel, displayName))
                    .accessibilityValue(l10n.text(.soundPacksRetryRestoreValue))
                    .accessibilityHint(l10n.text(.soundPacksRetryRestoreHint))
                    .accessibilityIdentifier("sound-packs.retry-factory-restore.\(packID)")
                }
            }
        }
    }

    @ViewBuilder
    private func eventMappingRow(_ row: EventRow, stacks: Bool) -> some View {
        Group {
            if stacks {
                VStack(alignment: .leading, spacing: 8) {
                    eventIdentity(row)
                    eventControls(row)
                }
            } else {
                HStack(alignment: .center) {
                    eventIdentity(row)
                    Spacer(minLength: 12)
                    eventControls(row)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control)
                .fill(
                    dropTargetEvent == row.event
                        ? ClaudioTheme.clay(colorScheme).opacity(0.12)
                        : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control)
                .stroke(
                    dropTargetEvent == row.event
                        ? ClaudioTheme.clay(colorScheme)
                        : ClaudioTheme.hairline(colorScheme),
                    lineWidth: ClaudioTheme.Metrics.hairline)
        }
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: dropTargetBinding(for: row.event),
            perform: { providers in handleAudioDrop(providers, onto: row.event) }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            localizedSoundPacksEventAccessibilityLabel(
                eventName: localizedEventName(row.event, language: languageStore.language),
                coverage: row.coverage,
                enabled: row.enabled,
                language: languageStore.language)
        )
        .accessibilityHint(
            canEditSelectedPack
                ? l10n.text(.soundPacksMappingHint)
                : l10n.text(.soundPacksBuiltinLabel)
        )
        .accessibilityIdentifier("sound-packs.event.\(row.event.rawValue)")
    }

    private func eventIdentity(_ row: EventRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                ClaudioEventGlyph(event: row.event, size: 24)
                Text(localizedEventName(row.event, language: languageStore.language))
                    .font(ClaudioTheme.font(.body).weight(.medium))
            }
            Text(row.event.manifestKey)
                .font(ClaudioTheme.font(.technical))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func mappingValue(_ coverage: CoverageState) -> some View {
        Text(mappingText(coverage))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func eventControls(_ row: EventRow) -> some View {
        let availability = previewAvailability(for: row)
        return HStack(spacing: 8) {
            eventAudioControl(row)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                playPreview(for: row)
            } label: {
                Label(l10n.text(.soundPacksPreview), systemImage: "play.fill")
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: ClaudioTheme.Metrics.compactControlHeight)
            .disabled(!availability.isAvailable)
            .focused($focusedTarget, equals: .eventPreview(row.event))
            .accessibilityLabel(l10n.format(
                .soundPacksPreviewLabel,
                localizedEventName(row.event, language: languageStore.language)))
            .accessibilityValue(mappingText(row.coverage))
            .accessibilityHint(
                localizedEventPreviewHint(availability, language: languageStore.language))
            .accessibilityIdentifier("sound-packs.event.\(row.event.rawValue).preview")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func eventAudioControl(_ row: EventRow) -> some View {
        if canEditSelectedPack {
            Menu {
                Section(l10n.text(.soundPacksExistingFiles)) {
                    if model.selectedAudioInventoryState.isLoading
                        && model.selectedAudioFiles.isEmpty
                    {
                        Text(l10n.text(.soundPacksAudioLoading))
                    } else if model.selectedAudioFiles.isEmpty {
                        Text(l10n.text(.soundPacksEmptyAudio))
                    } else {
                        ForEach(model.selectedAudioFiles) { file in
                            Button(file.isOrphan
                                ? l10n.format(.soundPacksOrphanUnused, file.fileName)
                                : file.fileName) {
                                model.assignSelectedAudioFile(file.fileName, to: row.event)
                        }
                        .accessibilityLabel(
                            l10n.format(
                                .soundPacksChooseBindLabel,
                                "\(localizedEventName(row.event, language: languageStore.language))"
                                    + (languageStore.language == .english ? ": " : "：")
                                    + file.fileName)
                            )
                            .accessibilityIdentifier(
                                "sound-packs.event.\(row.event.rawValue).existing.\(file.fileName)")
                        }
                    }
                }
                Divider()
                Button(l10n.text(.soundPacksChooseBind)) {
                    chooseAndBindAudio(to: row.event)
                }
                                .accessibilityLabel(l10n.format(
                                    .soundPacksChooseBindLabel,
                                    localizedEventName(row.event, language: languageStore.language)))
                .accessibilityHint(l10n.text(.soundPacksChooseBindHint))
                .accessibilityIdentifier(
                    "sound-packs.event.\(row.event.rawValue).choose-and-bind")
                Button(l10n.text(.soundPacksClearBinding), role: .destructive) {
                    model.clearSelectedEventBinding(row.event)
                }
                .disabled(!hasBinding(row.coverage))
                .accessibilityLabel(l10n.format(
                    .soundPacksClearBindingLabel,
                    localizedEventName(row.event, language: languageStore.language)))
                .accessibilityHint(l10n.text(.soundPacksClearBindingHint))
                .accessibilityIdentifier(
                    "sound-packs.event.\(row.event.rawValue).clear-binding")
                Button(l10n.text(.soundPacksRevealMapping)) {
                    revealMappedAudio(for: row.event)
                }
                .disabled(!row.coverage.previewEnabled)
                .accessibilityLabel(l10n.format(
                    .soundPacksRevealMappingLabel,
                    localizedEventName(row.event, language: languageStore.language)))
                .accessibilityHint(l10n.text(.soundPacksRevealMappingHint))
                .accessibilityIdentifier(
                    "sound-packs.event.\(row.event.rawValue).reveal-mapping")
            } label: {
                Text(mappingText(row.coverage))
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: ClaudioTheme.Metrics.compactControlHeight)
            .focused($focusedTarget, equals: .eventAudio(row.event))
            .accessibilityLabel(l10n.format(
                .soundPacksMappingLabel,
                localizedEventName(row.event, language: languageStore.language)))
            .accessibilityValue(mappingText(row.coverage))
            .accessibilityHint(l10n.text(.soundPacksMappingHint))
            .accessibilityIdentifier("sound-packs.event.\(row.event.rawValue).mapping")
        } else {
            mappingValue(row.coverage)
                .accessibilityLabel(l10n.format(
                    .soundPacksMappingLabel,
                    localizedEventName(row.event, language: languageStore.language)))
                .accessibilityValue(mappingText(row.coverage))
        }
    }

    @ViewBuilder
    private var orphanAudioSection: some View {
        let orphanFiles = model.selectedAudioFiles.filter(\.isOrphan)
        if !orphanFiles.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text(l10n.text(.soundPacksOrphanTitle))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                ForEach(orphanFiles) { file in
                    orphanAudioRow(file)
                }
                if !canEditSelectedPack {
                    Text(l10n.text(.soundPacksOrphanReadonly))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func orphanAudioRow(_ file: PackAudioFile) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(l10n.format(.soundPacksOrphanUnused, file.fileName))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if canEditSelectedPack {
                Menu(l10n.text(.soundPacksOrphanAssign)) {
                    ForEach(Event.allCases, id: \.self) { event in
                        Button(localizedEventName(event, language: languageStore.language)) {
                            model.assignSelectedAudioFile(file.fileName, to: event)
                        }
                        .accessibilityLabel(
                            l10n.format(
                                .soundPacksOrphanAssignLabel,
                                file.fileName
                                    + (languageStore.language == .english ? ": " : "：")
                                    + localizedEventName(event, language: languageStore.language))
                        )
                        .accessibilityIdentifier(
                            "sound-packs.orphan.\(file.fileName).event.\(event.rawValue)")
                    }
                }
                .frame(minHeight: ClaudioTheme.Metrics.compactControlHeight)
                .focused(
                    $focusedTarget,
                    equals: .orphanAssignment(fileName: file.fileName)
                )
                .accessibilityLabel(l10n.format(.soundPacksOrphanAssignLabel, file.fileName))
                .accessibilityValue(l10n.text(.soundPacksOrphanAssignValue))
                .accessibilityHint(l10n.text(.soundPacksOrphanAssignHint))
                .accessibilityIdentifier("sound-packs.orphan.\(file.fileName).assign")

                Button(l10n.text(.soundPacksOrphanDelete)) {
                    if let selectedPackID = model.selectedPackID {
                        pendingPermanentDeletion = PermanentAudioDeletionRequest(
                            packID: selectedPackID,
                            file: file)
                    }
                }
                .frame(minHeight: ClaudioTheme.Metrics.compactControlHeight)
                .focused(
                    $focusedTarget,
                    equals: .orphanDeletion(fileName: file.fileName)
                )
                .accessibilityLabel(l10n.format(.soundPacksOrphanDeleteLabel, file.fileName))
                .accessibilityValue(l10n.text(.soundPacksOrphanDeleteValue))
                .accessibilityHint(l10n.text(.soundPacksOrphanDeleteHint))
                .accessibilityIdentifier("sound-packs.orphan.\(file.fileName).delete")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func windowFailureRow(action: String, reason: String) -> some View {
        FailureRow(message: reason)
        .accessibilityLabel(
            localizedSoundPacksFailureAccessibilityLabel(
                action: action,
                reason: reason,
                language: languageStore.language))
    }

    private func factoryRestoreConfirmationMessage(
        _ request: FactoryPackRestoreRequest
    ) -> String {
        switch request.kind {
        case .selectedPack:
            return l10n.text(.soundPacksRestoreSelectedMessage)
        case .failedPublishRetry:
            return l10n.text(.soundPacksRestoreRetryMessage)
        case .allFactoryPacks:
            return l10n.text(.soundPacksRestoreAllMessage)
        }
    }

    private func inventoryErrorMessage(_ error: PackAudioInventoryError) -> String {
        switch error {
        case .packNotFound(let packID):
            return l10n.format(.soundPacksInventoryPackNotFound, packID)
        case .manifestUnreadable(let reason):
            return l10n.format(.soundPacksInventoryManifestUnreadable, reason)
        case .directoryUnreadable(let reason):
            return l10n.format(.soundPacksInventoryDirectoryUnreadable, reason)
        }
    }

    private func previewAvailability(for row: EventRow) -> EventPreviewAvailability {
        eventPreviewAvailability(
            coverage: row.coverage,
            masterVolume: model.config.masterVolume)
    }

    private func playPreview(for row: EventRow) {
        guard let resolvedFile = model.previewFileForSelectedEvent(row.event) else { return }
        previewPlayer.play(
            fileAt: resolvedFile,
            volume: Float(previewVolume(for: model.config)))
    }

    private var selection: Binding<String?> {
        Binding(
            get: { model.selectedPackID },
            set: { newValue in
                if let newValue {
                    model.selectPackForInspection(newValue)
                }
            })
    }

    private var selectedCard: PackCard? {
        guard let selectedPackID = model.selectedPackID else { return nil }
        return model.packCards.first(where: { $0.id == selectedPackID })
    }

    private var focusScope: SoundPacksWindowFocusScope {
        let allowsEmptyLibraryActions = model.libraryPresentationState.hasUsableSnapshot
        return SoundPacksWindowFocusScope(
            packIDs: model.packCards.map(\.id),
            selectedPackID: model.selectedPackID,
            editableEvents: canEditSelectedPack ? model.selectedEventRows.map(\.event) : [],
            previewableEvents: model.selectedEventRows.filter {
                previewAvailability(for: $0).isAvailable
            }.map(\.event),
            orphanFileNames: canEditSelectedPack
                ? model.selectedAudioFiles.filter(\.isOrphan).map(\.fileName) : [],
            canEditSelectedPack: canEditSelectedPack,
            canForkFactoryPack:
                model.selectedPackIsBuiltinReadOnly && !model.selectedPackIsMissingPlaceholder,
            canAddAudio: canEditSelectedPack,
            canRestoreFactoryPack: model.selectedPackCanRestoreFactory,
            canUseSelectedPack: selectedCard?.isSelected == false,
            canRestoreAllFactoryPacks:
                allowsEmptyLibraryActions && model.packCards.isEmpty && model.hasFactoryPacks,
            canRevealPacksDirectory:
                allowsEmptyLibraryActions && model.packCards.isEmpty && !model.hasFactoryPacks,
            canRetryLibraryLoad: model.libraryPresentationState.canRetry,
            retryFactoryRestorePackIDs: model.factoryRestoreRetryPackIDs)
    }

    private func applyInitialFocus() {
        switch requestedRoute.destination {
        case .overview:
            focusedTarget = soundPacksWindowFirstFocusTarget(focusScope)
        case .editEvent(_, let event):
            if canEditSelectedPack {
                focusedTarget = .eventAudio(event)
            } else if focusScope.previewableEvents.contains(event) {
                focusedTarget = .eventPreview(event)
            } else {
                focusedTarget = soundPacksWindowFirstFocusTarget(focusScope)
            }
        }
    }

    private func reconcileFocusWithVisibleControls(assignFirstIfNil: Bool = false) {
        let order = soundPacksWindowFocusOrder(focusScope)
        if let focusedTarget {
            if !order.contains(focusedTarget) {
                self.focusedTarget = order.first
            }
        } else if assignFirstIfNil {
            self.focusedTarget = order.first
        }
    }

    private var typeSizeTier: SoundPacksWindowTypeSizeTier {
        switch interfaceTextSize {
        case .compact, .standard: .standard
        case .large: .enlarged
        case .maximum: .accessibility
        }
    }

    private var interfaceTextSize: ClaudioInterfaceTextSize {
        ClaudioInterfaceTextSize(storedValue: interfaceTextSizeRaw)
    }

    private var layoutAdaptation: SoundPacksWindowLayoutAdaptation {
        soundPacksWindowLayoutAdaptation(for: typeSizeTier)
    }

    private var metaSlots: PackRowMetaSlots {
        guard let card = selectedCard else {
            return PackRowMetaSlots(license: .none, missingCount: nil)
        }
        return packRowMetaSlots(
            isCC0: card.isCC0, state: card.state, factoryIntegrity: card.factoryIntegrity)
    }

    private var canEditSelectedPack: Bool {
        selectedCard?.availability == .installed && !model.selectedPackIsBuiltinReadOnly
    }

    private func licenseBadgeLabel(_ badge: PackRowLicenseBadge) -> String? {
        switch badge {
        case .none:
            return nil
        case .cc0:
            return "CC0"
        case .modified:
            return "⚠ " + l10n.text(.soundPacksPackModified)
        }
    }

    private func mappingText(_ coverage: CoverageState) -> String {
        switch coverage {
        case .present(let fileName): return fileName
        case .unmapped: return l10n.text(.soundPacksCoverageUnmapped)
        case .broken(let fileName): return l10n.format(.soundPacksCoverageBroken, fileName)
        }
    }

    private func hasBinding(_ coverage: CoverageState) -> Bool {
        if case .unmapped = coverage { return false }
        return true
    }

    private func packAccessibilityLabel(_ card: PackCard) -> String {
        localizedSoundPacksPackAccessibilityLabel(
            displayName: SelectedPackMetadata(id: card.id, name: card.name).displayName,
            isActivePack: card.isSelected,
            state: card.state,
            license: packRowMetaSlots(
                isCC0: card.isCC0,
                state: card.state,
                factoryIntegrity: card.factoryIntegrity
            ).license,
            language: languageStore.language)
    }

    private func packAccessibilityValue(_ card: PackCard) -> String {
        var values: [String] = []
        if model.selectedPackID == card.id {
            values.append(l10n.format(
                .soundPacksSidebarViewing,
                SelectedPackMetadata(id: card.id, name: card.name).displayName))
        }
        if model.starredPackIDs.contains(card.id) { values.append(l10n.text(.soundPacksPanelVisible)) }
        if card.isSelected { values.append(l10n.text(.soundPacksUsing)) }
        return values.isEmpty ? l10n.text(.soundPacksPackNotUsed) : values.joined(separator: languageStore.language == .english ? ", " : "，")
    }
}
