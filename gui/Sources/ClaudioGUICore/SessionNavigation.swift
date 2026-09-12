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

public enum SessionNavigationCapability: Sendable, Equatable, Hashable {
    case unavailable
    case detailsOnly
    case viewSource
    case viewSession(SessionNavigationTarget)

    public var canViewSource: Bool { self != .unavailable }
    public var canOpenSession: Bool {
        if case .viewSession = self { return true }
        return false
    }
    public var canCopySessionID: Bool {
        switch self {
        case .unavailable, .detailsOnly: false
        case .viewSource, .viewSession: true
        }
    }
}

public func sessionNavigationCapability(
    for notice: HostEventNotice,
    verifiedTarget: SessionNavigationTarget? = nil
) -> SessionNavigationCapability {
    guard notice.isSemanticallyValid else { return .unavailable }
    guard let source = notice.source, source.sessionID != nil else { return .detailsOnly }
    if let verifiedTarget, !source.isParentSession, source.mainSessionIsKnown == true,
        source.projectKey != nil,
        verifiedTarget.surface == notice.surface,
        verifiedTarget.projectKey.map({ Data($0.utf8) })
            == source.projectKey.map({ Data($0.utf8) }),
        source.sessionID.map({ verifiedTarget.sessionID.utf8.elementsEqual($0.utf8) }) == true
    {
        return .viewSession(verifiedTarget)
    }
    return .viewSource
}

public enum SessionNavigationActionResult: Sendable, Equatable {
    case idle, unavailable, started, succeeded, exactReturnConfirmed, failed, timedOut, cancelled,
        copied, copyFailed
}

/// One request at a time, with a cancellable adapter and an independent deadline. Late callbacks
/// contain only version identities, and never keep a task or source alive in this coordinator.
/// Production injects no exact route. A generic success never removes a reminder.
@MainActor
public final class SessionNavigationCoordinator: ObservableObject {
    public static let timeout: TimeInterval = 3
    @Published public private(set) var result: SessionNavigationActionResult = .idle
    @Published public private(set) var action: EventNoticeAction?
    public private(set) var capabilityGeneration: UUID

    private let navigate:
        @MainActor (
            SessionNavigationTarget, @escaping @MainActor (SessionNavigationActionResult) -> Void
        ) -> EventNoticeCancellation
    private let scheduler: EventNoticeScheduler
    private var requestID: UUID?
    private var operation: EventNoticeCancellation?
    private var timeoutTask: EventNoticeCancellation?
    private weak var model: EventNoticeModel?
    private var observation: AnyCancellable?

    public init(
        model: EventNoticeModel? = nil,
        scheduler: EventNoticeScheduler = .live,
        capabilityGeneration: UUID = UUID(),
        navigate:
            @escaping @MainActor (
                SessionNavigationTarget,
                @escaping @MainActor (SessionNavigationActionResult) -> Void
            ) -> EventNoticeCancellation = { _, complete in
                complete(.unavailable)
                return EventNoticeCancellation {}
            }
    ) {
        self.model = model
        self.scheduler = scheduler
        self.capabilityGeneration = capabilityGeneration
        self.navigate = navigate
        observation = model?.$snapshot.sink { [weak self] snapshot in
            guard let self, let action = self.action else { return }
            if snapshot.receiverEpoch != action.epoch || self.model?.isCurrent(action) != true {
                self.reset()
            }
        }
    }

    public func openSession(
        _ capability: SessionNavigationCapability,
        action: EventNoticeAction,
        generation: UUID
    ) {
        guard requestID == nil else { return }
        guard generation == capabilityGeneration, let model, model.isCurrent(action),
            let notice = model.sourceNotice(for: action),
            case .viewSession(let target) = capability,
            sessionNavigationCapability(for: notice, verifiedTarget: target) == capability
        else { result = .unavailable; return }
        let id = UUID()
        requestID = id
        self.action = action
        model.protect(action)
        result = .started
        timeoutTask = scheduler.schedule(after: Self.timeout) { [weak self] in
            guard let self, self.requestID == id else { return }
            self.finish(.timedOut, id: id, action: action, generation: generation)
        }
        guard requestID == id, capabilityGeneration == generation, model.isCurrent(action) else {
            reset(); return
        }
        let cancellation = navigate(target) { [weak self] outcome in
            self?.finish(outcome, id: id, action: action, generation: generation)
        }
        // Adapters may complete synchronously during dispatch.
        if requestID == id { operation = cancellation } else { cancellation.cancel() }
    }

    /// Explicit copy is synchronous, so both validation and the actual pasteboard result belong
    /// to the captured action. Source browsing and copying never consume an attention version.
    @discardableResult
    public func copy(_ action: EventNoticeAction, write: (String) -> Bool) -> Bool {
        cancelRequest()
        self.action = action
        let success = model?.copySessionID(action, write: write) == true
        result = success ? .copied : .copyFailed
        return success
    }

    public func replaceCapabilityGeneration(_ generation: UUID) {
        guard generation != capabilityGeneration else { return }
        capabilityGeneration = generation
        reset()
    }

    public func cancel() {
        cancelRequest()
        result = .cancelled
    }

    public func reset() {
        cancelRequest()
        action = nil
        result = .idle
    }

    private func finish(
        _ outcome: SessionNavigationActionResult, id: UUID, action: EventNoticeAction,
        generation: UUID
    ) {
        guard requestID == id else { return }
        guard generation == capabilityGeneration, let model, model.isCurrent(action) else {
            reset(); return
        }
        cancelRequest()
        if outcome == .exactReturnConfirmed {
            // Removing this exact version may synchronously invalidate the observed action.
            self.action = nil
            guard model.remove(action, reason: .exactReturnConfirmed) == .applied else {
                result = .unavailable; return
            }
        }
        result = outcome
    }

    private func cancelRequest() {
        requestID = nil
        operation?.cancel()
        operation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        model?.protect(nil)
    }
}
