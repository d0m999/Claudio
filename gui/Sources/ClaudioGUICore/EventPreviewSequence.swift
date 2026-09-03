import ClaudioCore
import Foundation

/// Foundation-only short-audio playback seam shared by production surfaces and deterministic
/// runtime-failure tests. `false` means playback did not start and must not be reported as success.
@MainActor
public protocol AudioPreviewPlaying: AnyObject {
    @discardableResult
    func play(fileAt url: URL, volume: Float) -> Bool
    func stop()
}

public enum EventPreviewSequenceRunResult: Sendable, Equatable {
    case completed
    case empty
    case cancelled
    case failed(Event)
}

/// Cancellation-aware sequencing owner for the retained Settings destination. Each new run
/// invalidates the previous generation; scope changes and individual previews call ``cancel()``.
/// The callback consumes owner-signed Event capabilities through the native adapter and returns
/// only the playback duration needed for sequencing.
@MainActor
public final class EventPreviewSequenceCoordinator {
    private var generation: UInt64 = 0

    public init() {}

    public func cancel() {
        generation &+= 1
    }

    /// Runs already-authorized Event capabilities. Native playback returns duration while the
    /// sequence owner keeps ordering/cancellation; neither layer exposes or derives pack paths.
    public func run(
        events: [Event],
        onPlay: @escaping @MainActor @Sendable (Event) -> TimeInterval?
    ) async -> EventPreviewSequenceRunResult {
        generation &+= 1
        let runGeneration = generation
        guard !events.isEmpty else { return .empty }

        for event in events {
            guard generation == runGeneration, !Task.isCancelled else { return .cancelled }
            guard let probedDuration = onPlay(event) else { return .failed(event) }
            let duration = probedDuration.isFinite ? probedDuration : 3
            let boundedDuration = min(3, max(0.1, duration))
            do {
                try await Task.sleep(
                    nanoseconds: UInt64((boundedDuration + 0.15) * 1_000_000_000))
            } catch {
                return .cancelled
            }
        }
        guard generation == runGeneration else { return .cancelled }
        return .completed
    }
}
