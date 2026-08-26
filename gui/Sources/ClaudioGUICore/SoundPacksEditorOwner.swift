import ClaudioCore
import Foundation

/// App-lifetime owner of the one writable sound-pack editor model.
///
/// The legacy standalone window and unified Settings destination are presentations of this owner,
/// not separate disk-backed models. Route application lives in the Foundation-only module so the
/// embedded Scope/pack/Event contract can be exercised without constructing AppKit or SwiftUI.
@MainActor
public final class SoundPacksEditorOwner {
    public let model: SoundPacksWindowModel
    public let userPacksDirectory: URL
    private var statusAnnouncementTracker = SoundPacksWindowStatusAnnouncementTracker()
    private var lastSelectionAnnouncementDecision: (packID: String?, shouldAnnounce: Bool)?

    public init(
        configFile: URL,
        lockFile: URL = ClaudioPaths.configLockFile,
        environment: AudioImportEnvironment,
        soundPackLibrary: SoundPackLibrary,
        refreshCoordinator: SoundPacksRefreshCoordinator
    ) {
        model = SoundPacksWindowModel(
            configFile: configFile,
            lockFile: lockFile,
            environment: environment,
            soundPackLibrary: soundPackLibrary,
            refreshCoordinator: refreshCoordinator)
        userPacksDirectory = environment.userPacksDirectory
    }

    #if DEBUG
    /// Deterministic route-test seam that uses the harness's synchronous disk-backed model.
    public init(
        configFile: URL,
        lockFile: URL,
        environment: AudioImportEnvironment,
        refreshCoordinator: SoundPacksRefreshCoordinator
    ) {
        model = SoundPacksWindowModel(
            configFile: configFile,
            lockFile: lockFile,
            environment: environment,
            refreshCoordinator: refreshCoordinator)
        userPacksDirectory = environment.userPacksDirectory
    }

    /// Deterministic pending/ready route seam for model fixtures that do not touch user disk.
    public init(model: SoundPacksWindowModel, userPacksDirectory: URL) {
        self.model = model
        self.userPacksDirectory = userPacksDirectory
    }
    #endif

    /// Applies one typed route to the shared inspection/write model. Missing targets remain
    /// pending until the shared library can prove a fresh ready snapshot; only then may the
    /// presentation degrade to overview.
    @discardableResult
    public func apply(
        route: SoundPacksWindowRoute
    ) -> SoundPacksWindowRouteResolution {
        model.setManagedSurface(route.surface)
        switch resolveSoundPacksWindowRoute(
            route,
            availablePackIDs: Set(model.packCards.map(\.id)),
            libraryState: model.libraryPresentationState)
        {
        case .pending:
            return .pending(route)
        case .resolved(let resolvedRoute):
            guard let packID = resolvedRoute.editTarget?.packID else {
                return .resolved(resolvedRoute)
            }
            guard model.selectPackForInspection(packID) else {
                return .resolved(.overview(surface: resolvedRoute.surface))
            }
            return .resolved(resolvedRoute)
        }
    }

    /// Coordinates asynchronous status announcements across the Settings and legacy window
    /// presentations. A revision posted by whichever window is actually key is consumed once for
    /// both, so the other retained window cannot replay that status when it later becomes key.
    public func beginStatusAnnouncementAttempt(revision: Int, isWindowKey: Bool) -> Bool {
        statusAnnouncementTracker.beginAttempt(
            revision: revision,
            isWindowKey: isWindowKey)
    }

    public func finishStatusAnnouncementAttempt(revision: Int, didPost: Bool) {
        statusAnnouncementTracker.finishAttempt(revision: revision, didPost: didPost)
    }

    /// Returns one shared suppression decision to every retained presentation observing the same
    /// `@Published` selection emission. This prevents an inactive window from consuming the fork
    /// suppression token before the key presentation sees it, while a later A→B→A emission still
    /// computes a fresh decision after the intervening pack ID.
    public func shouldAnnounceSelectionChange(to packID: String?) -> Bool {
        if let lastSelectionAnnouncementDecision,
            lastSelectionAnnouncementDecision.packID == packID
        {
            return lastSelectionAnnouncementDecision.shouldAnnounce
        }
        let shouldAnnounce = !model.consumeSelectionAnnouncementSuppression(for: packID)
        lastSelectionAnnouncementDecision = (packID, shouldAnnounce)
        return shouldAnnounce
    }

    /// Projects announcement facts from the shared read model for whichever retained window is
    /// currently key. `@Published` emits before storing, so callers may pass the emitted selection
    /// or library state to describe the transition rather than the previous property value.
    public func announcementFacts(
        selectedPackID: String? = nil,
        usesEmittedSelection: Bool = false,
        libraryPresentationState: SoundPackLibraryPresentationState? = nil
    ) -> SoundPacksWindowAnnouncementFacts {
        let effectiveSelectedPackID = usesEmittedSelection ? selectedPackID : model.selectedPackID
        let selectedName = effectiveSelectedPackID.flatMap { packID in
            model.packCards.first(where: { $0.id == packID }).map {
                SelectedPackMetadata(id: $0.id, name: $0.name).displayName
            }
        }
        return SoundPacksWindowAnnouncementFacts(
            packCount: model.packCards.count,
            selectedPackName: selectedName,
            libraryPresentationState:
                libraryPresentationState ?? model.libraryPresentationState)
    }
}
