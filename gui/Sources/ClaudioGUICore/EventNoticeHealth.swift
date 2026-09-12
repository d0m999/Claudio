import Combine
import Foundation

public enum EventNoticeReceiverStatus: String, Sendable, Equatable {
    case ready
    case disabled
    case unavailable
}

/// App-lifetime health projection for the GUI-owned event-notice receiver. It carries only a
/// fixed redacted reason code — never a payload, path, or source value — so the Settings
/// notifications page can say "live prompts are unavailable" without fabricating delivery
/// health (SPEC Failure modes G3). Written from the MainActor runtime; kept nonisolated so the
/// settings dependency value can be assembled in any context.
public final class EventNoticeHealthStore: ObservableObject {
    @Published public private(set) var status: EventNoticeReceiverStatus = .disabled
    @Published public private(set) var failureCode: String?

    public init() {}

    public func reportReady() {
        status = .ready
        failureCode = nil
    }

    public func reportUnavailable(code: String) {
        status = .unavailable
        failureCode = code
    }

    public func reportDisabled() {
        status = .disabled
        failureCode = nil
    }
}
