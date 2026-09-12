import ClaudioCore
import Combine
import Foundation

public struct SessionNavigationTarget: Sendable, Equatable, Hashable {
    public let surface: HostSurfaceID
    public let projectKey: String?
    public let sessionID: String

    public init(surface: HostSurfaceID, projectKey: String?, sessionID: String) {
        self.surface = surface
        self.projectKey = projectKey
        self.sessionID = sessionID
    }
}

/// The absence of a verified route is a first-class state. `.viewSource` means that the UI may
/// reveal/copy the safe identity; it is not a claim that a host session can be opened precisely.
public enum SessionNavigationCapability: Sendable, Equatable, Hashable {
    case unavailable
    case viewSource
    case viewSession(SessionNavigationTarget)

    public var canViewSource: Bool {
        switch self {
        case .unavailable: false
        case .viewSource, .viewSession: true
        }
    }

    public var canOpenSession: Bool {
        if case .viewSession = self { return true }
        return false
    }

    public var canCopySessionID: Bool {
        switch self {
        case .unavailable: false
        case .viewSource, .viewSession: true
        }
    }
}

public func sessionNavigationCapability(
    for notice: HostEventNotice,
    verifiedTarget: SessionNavigationTarget? = nil
) -> SessionNavigationCapability {
    guard notice.isSemanticallyValid, let source = notice.source else {
        return .unavailable
    }
    if let verifiedTarget,
        verifiedTarget.surface == notice.surface,
        verifiedTarget.projectKey == source.projectKey,
        verifiedTarget.sessionID == source.sessionID
    {
        return .viewSession(verifiedTarget)
    }
    return source.sessionID == nil && source.projectLabel == nil ? .unavailable : .viewSource
}

public enum SessionNavigationActionResult: Sendable, Equatable {
    case idle
    case unavailable
    case started
    case succeeded
    case failed
    case timedOut
    case copied
}

/// A narrow async action seam. Production currently injects no exact host route; DEBUG previews
/// may provide a simulated success/failure handler without making that simulation a production
/// navigation promise.
@MainActor
public final class SessionNavigationCoordinator: ObservableObject {
    @Published public private(set) var result: SessionNavigationActionResult = .idle

    private let navigate:
        @MainActor (SessionNavigationTarget) async -> SessionNavigationActionResult
    private var actionRevision: UInt64 = 0

    public init(
        navigate:
            @escaping @MainActor (
                SessionNavigationTarget
            ) async -> SessionNavigationActionResult = { _ in .unavailable }
    ) {
        self.navigate = navigate
    }

    public func openSession(_ capability: SessionNavigationCapability) {
        guard case .viewSession(let target) = capability else {
            result = .unavailable
            return
        }
        actionRevision &+= 1
        let revision = actionRevision
        result = .started
        Task { @MainActor [weak self] in
            guard let self else { return }
            let actionResult = await self.navigate(target)
            guard self.actionRevision == revision else { return }
            self.result = actionResult
        }
    }

    public func markCopied() {
        actionRevision &+= 1
        result = .copied
    }

    public func reset() {
        actionRevision &+= 1
        result = .idle
    }
}
