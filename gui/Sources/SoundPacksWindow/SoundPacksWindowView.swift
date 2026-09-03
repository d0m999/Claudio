import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI
import UniformTypeIdentifiers

/// Unified Settings presentation of the app-lifetime editor owner. Route/focus state is local to
/// the embedded destination; every disk/config mutation stays behind `SoundPacksEditorOwner`.
@MainActor
public struct EmbeddedSoundPacksEditorView: View {
    @ObservedObject private var editorOwner: SoundPacksEditorOwner
    private let route: SoundPacksWindowRoute
    private let routeRequestRevision: UInt64
    private let nativeEffects: SoundPacksEditorNativeEffectsDispatcher
    @ObservedObject private var languageStore: ClaudioPreferences
    @StateObject private var focusCoordinator = SoundPacksWindowFocusCoordinator()
    @State private var focusApplicationTracker = SoundPacksEditorFocusApplicationTracker()

    package init(
        editorOwner: SoundPacksEditorOwner,
        route: SoundPacksWindowRoute,
        routeRequestRevision: UInt64,
        languageStore: ClaudioPreferences,
        nativeEffects: SoundPacksEditorNativeEffectsDispatcher
    ) {
        self.editorOwner = editorOwner
        self.route = route
        self.routeRequestRevision = routeRequestRevision
        self.languageStore = languageStore
        self.nativeEffects = nativeEffects
    }

    public var body: some View {
        SoundPacksWindowView(
            editorOwner: editorOwner,
            focusCoordinator: focusCoordinator,
            languageStore: languageStore,
            nativeEffects: nativeEffects
        )
        .onAppear {
            activate(route, requestsInitialFocus: true)
        }
        .onChange(of: routeRequestRevision) { _ in
            activate(route, requestsInitialFocus: false)
        }
        .onChange(of: focusProjection) { _ in
            applyFocusFromPresentation(requestsInitialFocus: false)
        }
        .onDisappear {
            nativeEffects.handleLifecycle(.soundsViewDisappeared, owner: editorOwner)
        }
        .accessibilityIdentifier("settings.sounds.editor")
    }

    private func activate(
        _ route: SoundPacksWindowRoute,
        requestsInitialFocus: Bool
    ) {
        _ = editorOwner.send(
            .activate(.sounds(route: route, requestRevision: routeRequestRevision)))
        applyFocusFromPresentation(requestsInitialFocus: requestsInitialFocus)
    }

    private func applyFocusFromPresentation(requestsInitialFocus: Bool) {
        guard case .sounds(let sounds) = editorOwner.presentation.mode else { return }
        let projection = SoundPacksEditorFocusProjection(
            requestRevision: sounds.requestRevision,
            routeState: sounds.routeState)
        guard
            focusApplicationTracker.recordAndShouldApply(
                projection,
                force: requestsInitialFocus)
        else { return }
        let focusRoute: SoundPacksWindowRoute
        switch sounds.routeState {
        case .resolved(let resolved):
            focusRoute = resolved
        case .pendingFreshSnapshot, .staleTarget:
            focusRoute = .overview(surface: sounds.route.surface)
        }
        if requestsInitialFocus {
            focusCoordinator.requestInitialFocus(route: focusRoute)
        } else {
            focusCoordinator.requestRoute(focusRoute)
        }
    }

    private var focusProjection: SoundPacksEditorFocusProjection? {
        guard case .sounds(let sounds) = editorOwner.presentation.mode else { return nil }
        return SoundPacksEditorFocusProjection(
            requestRevision: sounds.requestRevision,
            routeState: sounds.routeState)
    }
}

package struct SoundPacksEditorFocusProjection: Equatable {
    package let requestRevision: UInt64
    package let routeState: SoundPacksEditorRouteState

    package init(requestRevision: UInt64, routeState: SoundPacksEditorRouteState) {
        self.requestRevision = requestRevision
        self.routeState = routeState
    }
}

package struct SoundPacksEditorFocusApplicationTracker {
    private var lastApplied: SoundPacksEditorFocusProjection?

    package init() {}

    package mutating func recordAndShouldApply(
        _ projection: SoundPacksEditorFocusProjection,
        force: Bool
    ) -> Bool {
        let changed = lastApplied != projection
        lastApplied = projection
        return force || changed
    }
}

/// Standard-window surface: full pack sidebar plus the selected pack's four mappings.
///
/// T9 adds a window-owned focus/VoiceOver/Dynamic Type layer. T11 adds selected-pack audio
/// inventory, existing-audio assignment, and explicit confirmed orphan deletion.
@MainActor
package struct SoundPacksWindowView: View {
    @ObservedObject private var editorOwner: SoundPacksEditorOwner
    private let focusCoordinator: SoundPacksWindowFocusCoordinator
    @ObservedObject private var languageStore: ClaudioPreferences
    private let nativeEffects: SoundPacksEditorNativeEffectsDispatcher

    package init(
        editorOwner: SoundPacksEditorOwner,
        focusCoordinator: SoundPacksWindowFocusCoordinator,
        languageStore: ClaudioPreferences,
        nativeEffects: SoundPacksEditorNativeEffectsDispatcher
    ) {
        self.editorOwner = editorOwner
        self.focusCoordinator = focusCoordinator
        self.languageStore = languageStore
        self.nativeEffects = nativeEffects
    }

    package var body: some View {
        let presentation = editorOwner.presentation
        Group {
            if case .sounds(let sounds) = presentation.mode {
                SoundPacksWindowContentView(
                    editorOwner: editorOwner,
                    presentation: presentation,
                    sounds: sounds,
                    focusCoordinator: focusCoordinator,
                    languageStore: languageStore,
                    nativeEffects: nativeEffects)
            } else {
                ProgressView()
                    .frame(minWidth: 640, minHeight: 480)
                    .accessibilityLabel(
                        ClaudioL10n(language: languageStore.language).text(
                            .soundPacksLibraryLoading))
            }
        }
    }
}

@MainActor
private struct SoundPacksWindowContentView: View {
    private let editorOwner: SoundPacksEditorOwner
    let presentation: SoundPacksEditorPresentation
    let sounds: SoundsEditorPresentation
    @ObservedObject var focusCoordinator: SoundPacksWindowFocusCoordinator
    @ObservedObject var languageStore: ClaudioPreferences
    private let nativeEffects: SoundPacksEditorNativeEffectsDispatcher

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedTarget: SoundPacksWindowFocusTarget?
    @State private var handledFocusRequestRevision = 0
    @State private var dropTargetEvent: Event?
    @State private var requestedRoute: SoundPacksWindowRoute = .overview

    init(
        editorOwner: SoundPacksEditorOwner,
        presentation: SoundPacksEditorPresentation,
        sounds: SoundsEditorPresentation,
        focusCoordinator: SoundPacksWindowFocusCoordinator,
        languageStore: ClaudioPreferences,
        nativeEffects: SoundPacksEditorNativeEffectsDispatcher
    ) {
        self.editorOwner = editorOwner
        self.presentation = presentation
        self.sounds = sounds
        self.focusCoordinator = focusCoordinator
        self.languageStore = languageStore
        self.nativeEffects = nativeEffects
    }

    private var l10n: ClaudioL10n { ClaudioL10n(language: languageStore.language) }

    private var activeSounds: SoundsEditorPresentation { sounds }

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
        .onChange(of: activeSounds.packs.map(\.id)) { _ in
            reconcileFocusWithVisibleControls()
        }
        .onChange(of: activeSounds.selectedPack?.id) { _ in
            reconcileFocusWithVisibleControls()
        }
        .onChange(of: activeSounds.inventory) { _ in
            reconcileFocusWithVisibleControls()
        }
        .onChange(of: activeSounds.eventRows) { _ in
            reconcileFocusWithVisibleControls()
        }
        .onChange(of: activeSounds.recoveryActions.map(\.packID)) { _ in
            if activeSounds.packs.isEmpty,
                let packID = activeSounds.recoveryActions.first?.packID
            {
                focusedTarget = .retryFactoryRestore(packID: packID)
            } else {
                reconcileFocusWithVisibleControls()
            }
        }
        .onChange(of: presentation.library) { _ in
            reconcileFocusWithVisibleControls(assignFirstIfNil: true)
        }
        .confirmationDialog(
            deleteOrphanConfirmation.map {
                l10n.format(.soundPacksDeleteTitle, $0.fileName ?? "")
            } ?? l10n.text(.soundPacksDeleteButton),
            isPresented: Binding(
                get: { deleteOrphanConfirmation != nil },
                set: { if !$0 { cancelConfirmation(deleteOrphanConfirmation) } }),
            titleVisibility: .visible,
            presenting: deleteOrphanConfirmation
        ) { confirmation in
            let fileName = confirmation.fileName ?? ""
            Button(l10n.text(.soundPacksDeleteButton), role: .destructive) {
                invoke(confirmation.confirmAction)
            }
            .accessibilityLabel(l10n.format(.soundPacksOrphanDeleteLabel, fileName))
            .accessibilityHint(l10n.text(.soundPacksDeleteHint))
            .accessibilityIdentifier("sound-packs.confirm-delete")
            Button(l10n.text(.commonCancel), role: .cancel) {
                invoke(confirmation.cancelAction)
            }
            .accessibilityLabel(l10n.text(.commonCancel))
            .accessibilityIdentifier("sound-packs.cancel-delete")
        } message: { confirmation in
            Text(l10n.format(.soundPacksDeleteMessage, confirmation.fileName ?? ""))
        }
        .confirmationDialog(
            deletePackConfirmation.map {
                l10n.format(
                    .soundPacksPackDeleteTitle,
                    confirmationPackDisplayName($0))
            } ?? l10n.text(.soundPacksPackDelete),
            isPresented: Binding(
                get: { deletePackConfirmation != nil },
                set: { if !$0 { cancelConfirmation(deletePackConfirmation) } }),
            titleVisibility: .visible,
            presenting: deletePackConfirmation
        ) { confirmation in
            let displayName = confirmationPackDisplayName(confirmation)
            Button(l10n.text(.soundPacksPackDelete), role: .destructive) {
                invoke(confirmation.confirmAction)
            }
            .accessibilityLabel(
                l10n.format(.soundPacksPackDeleteLabel, displayName)
            )
            .accessibilityHint(l10n.text(.soundPacksPackDeleteHint))
            .accessibilityIdentifier("sound-packs.confirm-pack-delete")
            Button(l10n.text(.commonCancel), role: .cancel) {
                invoke(confirmation.cancelAction)
            }
            .accessibilityLabel(l10n.text(.commonCancel))
            .accessibilityIdentifier("sound-packs.cancel-pack-delete")
        } message: { confirmation in
            Text(
                l10n.format(.soundPacksPackDeleteMessage, confirmationPackDisplayName(confirmation))
            )
        }
        .confirmationDialog(
            restoreConfirmation.map {
                l10n.format(.soundPacksRestoreTitle, confirmationPackDisplayName($0))
            } ?? l10n.text(.soundPacksRestore),
            isPresented: Binding(
                get: { restoreConfirmation != nil },
                set: { if !$0 { cancelConfirmation(restoreConfirmation) } }),
            titleVisibility: .visible,
            presenting: restoreConfirmation
        ) { confirmation in
            Button(l10n.text(.soundPacksRestoreButton), role: .destructive) {
                invoke(confirmation.confirmAction)
            }
            .accessibilityLabel(
                l10n.format(.soundPacksRestoreLabel, confirmationPackDisplayName(confirmation))
            )
            .accessibilityHint(l10n.text(.soundPacksRestoreHint))
            .accessibilityIdentifier("sound-packs.confirm-factory-restore")
            Button(l10n.text(.commonCancel), role: .cancel) {
                invoke(confirmation.cancelAction)
            }
            .accessibilityLabel(l10n.text(.commonCancel))
            .accessibilityIdentifier("sound-packs.cancel-factory-restore")
        } message: { confirmation in
            Text(factoryRestoreConfirmationMessage(confirmation))
        }
        .disabled(isPerformingWrite)
    }

    private var managedScopeBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: managedSurface == nil ? "globe" : "square.stack.3d.up.fill")
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
            l10n.format(.soundPacksManagingScope, managedScopeName)
        )
        .accessibilityIdentifier("sound-packs.managed-scope")
    }

    private var managedScopeName: String {
        guard let surface = managedSurface else {
            return l10n.text(.panelGlobalName)
        }
        return HostID.productVisibleCases.first(where: { $0.surfaceID == surface })?.displayName
            ?? surface.rawValue
    }

    private var localizedManagedScopeFailure: String? {
        guard case .unavailable = activeSounds.scope else { return nil }
        return l10n.format(.soundPacksDamagedScope, managedScopeName)
    }

    @ViewBuilder
    private var libraryStatusBar: some View {
        if isPerformingWrite {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(l10n.text(.soundPacksWritingChanges))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(l10n.text(.soundPacksWritingChanges))
            .accessibilityIdentifier("sound-packs.write-in-progress")
        } else {
            switch presentation.library {
            case .unloaded, .loading(previousAvailable: false):
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
                .accessibilityLabel(
                    l10n.text(.soundPacksLibraryLoading).replacingOccurrences(of: "…", with: "")
                )
                .accessibilityIdentifier("sound-packs.library.loading")
            case .loading(previousAvailable: true):
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
            case .failed(let previousAvailable, let reason):
                HStack(alignment: .center, spacing: 10) {
                    FailureRow(
                        message: previousAvailable
                            ? l10n.format(
                                .soundPacksLibraryRefreshFailed,
                                localizedLibraryFailure(reason))
                            : localizedLibraryFailure(reason))
                    Spacer(minLength: 8)
                    Button(l10n.text(.commonRetry)) {
                        invoke(activeSounds.retryLibraryAction)
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
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n.text(.soundPacksSidebarTitle))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 10)
                .padding(.top, 10)

            List(selection: selection) {
                ForEach(activeSounds.packs) { card in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(SelectedPackMetadata(id: card.id, name: card.name).displayName)
                                .lineLimit(layoutAdaptation.packNameLineLimit)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        if card.isActiveForScope {
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
                        card.isInspected ? .isSelected : [])
                }
            }
            .focusable(!activeSounds.packs.isEmpty)
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
                            if !activeSounds.windowStatuses.isEmpty {
                                windowStatusRegion
                                    .padding(.horizontal, 20)
                                    .padding(.top, 20)
                            }

                            if let card = selectedCard {
                                VStack(alignment: .leading, spacing: 16) {
                                    detailHeader(card, stacks: stacksDetail)

                                    if card.isBuiltinReadOnly {
                                        builtinCopyExplanation(card)
                                    }

                                    Divider()

                                    VStack(alignment: .leading, spacing: 10) {
                                        ForEach(activeSounds.eventRows) { row in
                                            eventMappingRow(
                                                row,
                                                stacks: layoutAdaptation.stacksEventRows
                                                    || stacksDetail
                                            )
                                            .id("event-\(row.event.rawValue)")
                                        }
                                    }

                                    if inventoryIsLoading {
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

                                    if let error = inventoryFailure {
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
                    .onChange(of: activeSounds.selectedPack?.id) { _ in
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
            ForEach(activeSounds.windowStatuses) { status in
                windowStatusRow(status)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func detailHeader(
        _ card: SoundPackEditorPackPresentation,
        stacks: Bool
    ) -> some View {
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

    private func detailIdentity(_ card: SoundPackEditorPackPresentation) -> some View {
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
            if card.isBuiltinReadOnly {
                ClaudioStatusCapsule(l10n.text(.soundPacksBuiltinBadge))
                    .accessibilityLabel(l10n.text(.soundPacksBuiltinLabel))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func revealButton(_ card: SoundPackEditorPackPresentation) -> some View {
        Button {
            invoke(card.revealAction)
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
        .accessibilityValue(card.revealDisplayValue ?? "")
        .accessibilityHint(l10n.text(.soundPacksRevealHint))
        .accessibilityIdentifier("sound-packs.reveal-selected")
        .disabled(card.revealAction == nil)
    }

    private func factoryRestoreButton(_ card: SoundPackEditorPackPresentation) -> some View {
        let displayName = SelectedPackMetadata(id: card.id, name: card.name).displayName
        return Button(l10n.text(.soundPacksRestore)) {
            invoke(card.restoreAction)
        }
        .disabled(card.restoreAction == nil)
        .frame(minHeight: ClaudioTheme.Metrics.compactControlHeight)
        .focused($focusedTarget, equals: .restoreFactoryPack)
        .accessibilityLabel(l10n.format(.soundPacksRestorePackLabel, displayName))
        .accessibilityValue(l10n.text(.soundPacksBuiltinValue))
        .accessibilityHint(l10n.text(.soundPacksRestorePackHint))
        .accessibilityIdentifier("sound-packs.restore-selected-factory-pack")
    }

    private func builtinCopyExplanation(_ card: SoundPackEditorPackPresentation) -> some View {
        let message = l10n.text(.soundPacksBuiltinCopyExplanation)
        return Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .help(message)
            .accessibilityLabel(message)
    }

    @ViewBuilder
    private func packActionBar(
        _ card: SoundPackEditorPackPresentation,
        stacks: Bool
    ) -> some View {
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
    private func packActions(
        _ card: SoundPackEditorPackPresentation,
        includeFlexibleSpace: Bool
    ) -> some View {
        let displayName = SelectedPackMetadata(id: card.id, name: card.name).displayName
        if card.availability == .missingSelectedPlaceholder {
            if card.restoreAction != nil {
                factoryRestoreButton(card)
            }
        } else if card.isBuiltinReadOnly {
            Button(l10n.text(.soundPacksCopy)) {
                invoke(card.forkAction)
            }
            .disabled(card.forkAction == nil)
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
            Button(
                isImportingAudio
                    ? l10n.text(.soundPacksAddingAudio)
                    : l10n.text(.soundPacksAddAudio)
            ) {
                invoke(activeSounds.requestImportAction)
            }
            .disabled(isImportingAudio || !canEditSelectedPack)
            .frame(minHeight: ClaudioTheme.Metrics.regularControlHeight)
            .fixedSize(horizontal: false, vertical: true)
            .focused($focusedTarget, equals: .addAudio)
            .accessibilityLabel(l10n.format(.soundPacksAddAudioLabel, displayName))
            .accessibilityValue(
                isImportingAudio
                    ? l10n.text(.soundPacksImporting)
                    : l10n.text(.soundPacksCanChooseFile)
            )
            .accessibilityHint(l10n.text(.soundPacksAddAudioHint))
            .accessibilityIdentifier("sound-packs.add-audio")

            Button(l10n.text(.soundPacksPackDelete), role: .destructive) {
                invoke(card.deleteAction)
            }
            .disabled(!canDeleteSelectedPack)
            .frame(minHeight: ClaudioTheme.Metrics.regularControlHeight)
            .fixedSize(horizontal: false, vertical: true)
            .focused($focusedTarget, equals: .deleteUserPack)
            .accessibilityLabel(l10n.format(.soundPacksPackDeleteLabel, displayName))
            .accessibilityValue(
                card.isReferencedByAnyScope
                    ? l10n.text(.soundPacksPackDeleteActive)
                    : l10n.text(.soundPacksPackDeleteAvailable)
            )
            .accessibilityHint(l10n.text(.soundPacksPackDeleteHint))
            .accessibilityIdentifier("sound-packs.delete-selected-pack")
        }

        if includeFlexibleSpace {
            Spacer(minLength: 8)
        }

        if card.isActiveForScope {
            ClaudioStatusCapsule(l10n.text(.soundPacksUsing), isEmphasized: true)
                .accessibilityLabel(l10n.text(.soundPacksUsing))
        } else if card.isBuiltinReadOnly {
            Button(l10n.text(.soundPacksUse)) {
                invoke(card.useAction)
            }
            .disabled(card.useAction == nil)
            .frame(minHeight: ClaudioTheme.Metrics.regularControlHeight)
            .focused($focusedTarget, equals: .useSelectedPack)
            .accessibilityLabel(l10n.format(.soundPacksUseLabel, displayName))
            .accessibilityValue(l10n.text(.soundPacksUseValue))
            .accessibilityHint(l10n.text(.soundPacksUseHint))
            .accessibilityIdentifier("sound-packs.use-selected-pack")
        } else {
            Button(l10n.text(.soundPacksUse)) {
                invoke(card.useAction)
            }
            .disabled(card.useAction == nil)
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

    private func builtinCopyHelp(_ card: SoundPackEditorPackPresentation) -> String {
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

    private func invoke(_ action: SoundPackEditorAction?) {
        guard let action else { return }
        nativeEffects.consume(editorOwner.send(.invoke(action)), owner: editorOwner)
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
            !isImportingAudio,
            let importAction = activeSounds.eventRows.first(where: { $0.event == event })?
                .importAction,
            providers.contains(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            })
        else { return false }
        nativeEffects.consumeDrop(
            providers,
            action: importAction,
            owner: editorOwner)
        return true
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Text(emptyLibraryTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if presentation.library == .unloaded
                || presentation.library == .loading(previousAvailable: false)
            {
                Text(l10n.text(.soundPacksEmptyLoadingMessage))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if case .failed(previousAvailable: false, _) =
                presentation.library
            {
                Text(l10n.text(.soundPacksEmptyLoadFailedMessage))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if case .restoreFactory(let action) = activeSounds.emptyLibraryRecovery {
                Text(l10n.text(.soundPacksEmptyFactoryMessage))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(l10n.text(.soundPacksEmptyRestore)) {
                    invoke(action)
                }
                .buttonStyle(.borderedProminent)
                .tint(ClaudioSharedColor.clay(colorScheme))
                .frame(minHeight: ClaudioTheme.Metrics.regularControlHeight)
                .focused($focusedTarget, equals: .restoreAllFactoryPacks)
                .accessibilityLabel(l10n.text(.soundPacksEmptyRestoreLabel))
                .accessibilityValue(l10n.text(.soundPacksEmptyRestoreValue))
                .accessibilityHint(l10n.text(.soundPacksEmptyRestoreHint))
                .accessibilityIdentifier("sound-packs.restore-all-factory-packs")
            } else if case .revealRoot(let displayValue, let action) =
                activeSounds.emptyLibraryRecovery
            {
                Text(l10n.text(.soundPacksEmptyNoFactoryMessage))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(l10n.text(.soundPacksEmptyReveal)) {
                    invoke(action)
                }
                .frame(minHeight: ClaudioTheme.Metrics.regularControlHeight)
                .focused($focusedTarget, equals: .revealPacksDirectory)
                .accessibilityLabel(l10n.text(.soundPacksEmptyRevealLabel))
                .accessibilityValue(displayValue)
                .accessibilityHint(l10n.text(.soundPacksEmptyRevealHint))
                .accessibilityIdentifier("sound-packs.reveal-packs-directory")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var emptyLibraryTitle: String {
        switch presentation.library {
        case .unloaded, .loading(previousAvailable: false):
            return l10n.text(.soundPacksLibraryLoading).replacingOccurrences(of: "…", with: "")
        case .failed(previousAvailable: false, _):
            return l10n.text(.panelPacksReadFailed)
        case .loading(previousAvailable: true), .ready, .failed(previousAvailable: true, _):
            return l10n.text(.panelPacksNoneTitle)
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
                ForEach(
                    activeSounds.recoveryActions.filter { packIDs.contains($0.packID) }
                ) { recovery in
                    let packID = recovery.packID
                    let displayName = SelectedPackMetadata(id: packID, name: nil).displayName
                    Button(l10n.format(.soundPacksRetryRestore, displayName)) {
                        invoke(recovery.retryAction)
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
    private func eventMappingRow(
        _ row: SoundPackEditorEventPresentation,
        stacks: Bool
    ) -> some View {
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

    private func eventIdentity(_ row: SoundPackEditorEventPresentation) -> some View {
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

    private func eventControls(_ row: SoundPackEditorEventPresentation) -> some View {
        let availability = row.previewAvailability
        return HStack(spacing: 8) {
            eventAudioControl(row)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                invoke(row.previewAction)
            } label: {
                Label(l10n.text(.soundPacksPreview), systemImage: "play.fill")
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: ClaudioTheme.Metrics.compactControlHeight)
            .disabled(row.previewAction == nil)
            .focused($focusedTarget, equals: .eventPreview(row.event))
            .accessibilityLabel(
                l10n.format(
                    .soundPacksPreviewLabel,
                    localizedEventName(row.event, language: languageStore.language))
            )
            .accessibilityValue(mappingText(row.coverage))
            .accessibilityHint(
                localizedEventPreviewHint(availability, language: languageStore.language)
            )
            .accessibilityIdentifier("sound-packs.event.\(row.event.rawValue).preview")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func eventAudioControl(_ row: SoundPackEditorEventPresentation) -> some View {
        if canEditSelectedPack {
            Menu {
                Section(l10n.text(.soundPacksExistingFiles)) {
                    if inventoryIsLoading && inventoryFiles.isEmpty {
                        Text(l10n.text(.soundPacksAudioLoading))
                    } else if inventoryFiles.isEmpty {
                        Text(l10n.text(.soundPacksEmptyAudio))
                    } else {
                        ForEach(inventoryFiles) { file in
                            Button(
                                file.isOrphan
                                    ? l10n.format(.soundPacksOrphanUnused, file.fileName)
                                    : file.fileName
                            ) {
                                invoke(
                                    file.assignments.first(where: { $0.event == row.event })?
                                        .action)
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
                    invoke(row.importAction)
                }
                .accessibilityLabel(
                    l10n.format(
                        .soundPacksChooseBindLabel,
                        localizedEventName(row.event, language: languageStore.language))
                )
                .accessibilityHint(l10n.text(.soundPacksChooseBindHint))
                .accessibilityIdentifier(
                    "sound-packs.event.\(row.event.rawValue).choose-and-bind")
                Button(l10n.text(.soundPacksClearBinding), role: .destructive) {
                    invoke(row.clearAction)
                }
                .disabled(row.clearAction == nil)
                .accessibilityLabel(
                    l10n.format(
                        .soundPacksClearBindingLabel,
                        localizedEventName(row.event, language: languageStore.language))
                )
                .accessibilityHint(l10n.text(.soundPacksClearBindingHint))
                .accessibilityIdentifier(
                    "sound-packs.event.\(row.event.rawValue).clear-binding")
                Button(l10n.text(.soundPacksRevealMapping)) {
                    invoke(mappedAudio(for: row)?.revealAction)
                }
                .disabled(mappedAudio(for: row)?.revealAction == nil)
                .accessibilityLabel(
                    l10n.format(
                        .soundPacksRevealMappingLabel,
                        localizedEventName(row.event, language: languageStore.language))
                )
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
            .accessibilityLabel(
                l10n.format(
                    .soundPacksMappingLabel,
                    localizedEventName(row.event, language: languageStore.language))
            )
            .accessibilityValue(mappingText(row.coverage))
            .accessibilityHint(l10n.text(.soundPacksMappingHint))
            .accessibilityIdentifier("sound-packs.event.\(row.event.rawValue).mapping")
        } else {
            mappingValue(row.coverage)
                .accessibilityLabel(
                    l10n.format(
                        .soundPacksMappingLabel,
                        localizedEventName(row.event, language: languageStore.language))
                )
                .accessibilityValue(mappingText(row.coverage))
        }
    }

    @ViewBuilder
    private var orphanAudioSection: some View {
        let orphanFiles = inventoryFiles.filter(\.isOrphan)
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

    private func orphanAudioRow(_ file: SoundPackEditorAudioPresentation) -> some View {
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
                    ForEach(file.assignments) { assignment in
                        let event = assignment.event
                        Button(localizedEventName(event, language: languageStore.language)) {
                            invoke(assignment.action)
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
                    invoke(file.deleteAction)
                }
                .disabled(file.deleteAction == nil)
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

    private var deleteOrphanConfirmation: SoundPackEditorConfirmation? {
        guard let confirmation = presentation.pendingConfirmation,
            confirmation.kind == .deleteOrphan
        else { return nil }
        return confirmation
    }

    private var deletePackConfirmation: SoundPackEditorConfirmation? {
        guard let confirmation = presentation.pendingConfirmation,
            confirmation.kind == .deletePack
        else { return nil }
        return confirmation
    }

    private var restoreConfirmation: SoundPackEditorConfirmation? {
        guard let confirmation = presentation.pendingConfirmation else { return nil }
        switch confirmation.kind {
        case .restoreFactory, .retryRestore, .restoreAllFactory:
            return confirmation
        case .deletePack, .deleteOrphan:
            return nil
        }
    }

    private func cancelConfirmation(_ confirmation: SoundPackEditorConfirmation?) {
        guard let confirmation,
            presentation.pendingConfirmation?.id == confirmation.id
        else { return }
        invoke(confirmation.cancelAction)
    }

    private func confirmationPackDisplayName(
        _ confirmation: SoundPackEditorConfirmation
    ) -> String {
        guard let packID = confirmation.packID else {
            return l10n.text(.soundPacksEmptyRestoreLabel)
        }
        let name = activeSounds.packs.first(where: { $0.id == packID })?.name
        return SelectedPackMetadata(id: packID, name: name).displayName
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

    private func factoryRestoreConfirmationMessage(
        _ confirmation: SoundPackEditorConfirmation
    ) -> String {
        switch confirmation.kind {
        case .restoreFactory:
            return l10n.text(.soundPacksRestoreSelectedMessage)
        case .retryRestore:
            return l10n.text(.soundPacksRestoreRetryMessage)
        case .restoreAllFactory:
            return l10n.text(.soundPacksRestoreAllMessage)
        case .deletePack, .deleteOrphan:
            return ""
        }
    }

    private func inventoryErrorMessage(
        _ error: SoundPackEditorInventoryFailureReason
    ) -> String {
        switch error {
        case .packUnavailable:
            return l10n.format(
                .soundPacksInventoryPackNotFound,
                selectedCard?.id ?? "")
        case .manifestUnreadable:
            return l10n.format(
                .soundPacksInventoryManifestUnreadable,
                l10n.text(.panelPacksReadFailed))
        case .directoryUnavailable:
            return l10n.format(
                .soundPacksInventoryDirectoryUnreadable,
                l10n.text(.panelPacksReadFailed))
        }
    }

    private var managedSurface: HostSurfaceID? {
        switch activeSounds.scope {
        case .available(let scope), .unavailable(scope: let scope, reason: _):
            return scope.surface
        }
    }

    private var isImportingAudio: Bool {
        presentation.activities.contains {
            guard case .busy = $0.phase else { return false }
            return $0.kind == .importAudio
        }
    }

    private var isPerformingWrite: Bool {
        return presentation.activities.contains {
            guard case .busy = $0.phase else { return false }
            return $0.kind != .importAudio
        }
    }

    private var inventoryFiles: [SoundPackEditorAudioPresentation] {
        switch activeSounds.inventory {
        case .idle:
            return []
        case .loading(let previous), .failed(let previous, _):
            return previous ?? []
        case .ready(let files):
            return files
        }
    }

    private var inventoryIsLoading: Bool {
        if case .loading = activeSounds.inventory { return true }
        return false
    }

    private var inventoryFailure: SoundPackEditorInventoryFailureReason? {
        guard case .failed(_, let reason) = activeSounds.inventory else { return nil }
        return reason
    }

    private func mappedAudio(
        for row: SoundPackEditorEventPresentation
    ) -> SoundPackEditorAudioPresentation? {
        let fileName: String
        switch row.coverage {
        case .present(let value), .broken(let value):
            fileName = value
        case .unmapped:
            return nil
        }
        return inventoryFiles.first(where: { $0.fileName == fileName })
    }

    private var selection: Binding<String?> {
        Binding(
            get: { activeSounds.selectedPack?.id },
            set: { newValue in
                invoke(activeSounds.packs.first(where: { $0.id == newValue })?.inspectAction)
            })
    }

    private var selectedCard: SoundPackEditorPackPresentation? { activeSounds.selectedPack }

    private var focusScope: SoundPacksWindowFocusScope {
        let emptyRecovery = activeSounds.emptyLibraryRecovery
        let canRestoreAllFactoryPacks: Bool
        let canRevealPacksDirectory: Bool
        switch emptyRecovery {
        case .restoreFactory:
            canRestoreAllFactoryPacks = true
            canRevealPacksDirectory = false
        case .revealRoot:
            canRestoreAllFactoryPacks = false
            canRevealPacksDirectory = true
        case .none:
            canRestoreAllFactoryPacks = false
            canRevealPacksDirectory = false
        }
        return SoundPacksWindowFocusScope(
            packIDs: activeSounds.packs.map(\.id),
            selectedPackID: activeSounds.selectedPack?.id,
            editableEvents: canEditSelectedPack ? activeSounds.eventRows.map(\.event) : [],
            previewableEvents: activeSounds.eventRows.filter {
                $0.previewAction != nil
            }.map(\.event),
            orphanFileNames: canEditSelectedPack
                ? inventoryFiles.filter(\.isOrphan).map(\.fileName) : [],
            canEditSelectedPack: canEditSelectedPack,
            canForkFactoryPack: selectedCard?.forkAction != nil,
            canAddAudio: activeSounds.requestImportAction != nil,
            canDeleteUserPack: selectedCard?.deleteAction != nil,
            canRestoreFactoryPack: selectedCard?.restoreAction != nil,
            canUseSelectedPack: selectedCard?.useAction != nil,
            canRestoreAllFactoryPacks: canRestoreAllFactoryPacks,
            canRevealPacksDirectory: canRevealPacksDirectory,
            canRetryLibraryLoad: activeSounds.retryLibraryAction != nil,
            retryFactoryRestorePackIDs: activeSounds.recoveryActions.map(\.packID))
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

    private var interfaceTextSize: ClaudioInterfaceTextSize { languageStore.interfaceTextSize }

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
        activeSounds.requestImportAction != nil
    }

    private var canDeleteSelectedPack: Bool {
        selectedCard?.deleteAction != nil
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

    private func packAccessibilityLabel(
        _ card: SoundPackEditorPackPresentation
    ) -> String {
        localizedSoundPacksPackAccessibilityLabel(
            displayName: SelectedPackMetadata(id: card.id, name: card.name).displayName,
            isActivePack: card.isActiveForScope,
            state: card.state,
            license: packRowMetaSlots(
                isCC0: card.isCC0,
                state: card.state,
                factoryIntegrity: card.factoryIntegrity
            ).license,
            language: languageStore.language)
    }

    private func packAccessibilityValue(
        _ card: SoundPackEditorPackPresentation
    ) -> String {
        var values: [String] = []
        if card.isInspected {
            values.append(
                l10n.format(
                    .soundPacksSidebarViewing,
                    SelectedPackMetadata(id: card.id, name: card.name).displayName))
        }
        if card.isActiveForScope { values.append(l10n.text(.soundPacksUsing)) }
        return values.isEmpty
            ? l10n.text(.soundPacksPackNotUsed)
            : values.joined(separator: languageStore.language == .english ? ", " : "，")
    }
}
