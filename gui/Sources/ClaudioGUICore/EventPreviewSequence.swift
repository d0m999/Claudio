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

public struct EventPreviewSequenceItem: Sendable, Equatable {
    public let event: Event
    public let fileURL: URL
    public let delayNanoseconds: UInt64

    public init(event: Event, fileURL: URL, delayNanoseconds: UInt64) {
        self.event = event
        self.fileURL = fileURL
        self.delayNanoseconds = delayNanoseconds
    }
}

public enum EventPreviewSequencePlan: Sendable, Equatable {
    case ready([EventPreviewSequenceItem])
    case failed(Event)
}

/// Builds the ordered, fail-closed sequence consumed by “Preview All”. The retained view calls
/// this only through ``EventPreviewSequenceCoordinator/run(makePlan:onPlay:)``, which executes the
/// filesystem and duration work in a detached task rather than during SwiftUI body evaluation.
public func makeEventPreviewSequencePlan(
    presentations: [PanelEventPresentation],
    rows: [EventRow],
    packID: String,
    environment: AudioImportEnvironment
) -> EventPreviewSequencePlan {
    let rowsByEvent = Dictionary(uniqueKeysWithValues: rows.map { ($0.event, $0) })
    var items: [EventPreviewSequenceItem] = []
    for presentation in presentations where presentation.controls.previewEnabled {
        guard
            let row = rowsByEvent[presentation.event],
            let fileURL = eventPreviewFileURL(
                row: row,
                packID: packID,
                environment: environment)
        else {
            return .failed(presentation.event)
        }
        let probedDuration = environment.durationProbe.probeDuration(of: fileURL) ?? 3
        let duration = probedDuration.isFinite ? probedDuration : 3
        let boundedDuration = min(3, max(0.1, duration))
        items.append(
            EventPreviewSequenceItem(
                event: presentation.event,
                fileURL: fileURL,
                delayNanoseconds: UInt64((boundedDuration + 0.15) * 1_000_000_000)))
    }
    return .ready(items)
}

public enum EventPreviewSequenceRunResult: Sendable, Equatable {
    case completed
    case empty
    case cancelled
    case failed(Event)
}

/// Cancellation-aware sequencing owner for the retained Settings destination. Each new run
/// invalidates the previous generation; scope changes and individual previews call ``cancel()``.
/// Planning happens off MainActor, while the injected playback callback returns to MainActor.
@MainActor
public final class EventPreviewSequenceCoordinator {
    private var generation: UInt64 = 0

    public init() {}

    public func cancel() {
        generation &+= 1
    }

    public func run(
        makePlan: @escaping @Sendable () -> EventPreviewSequencePlan,
        onPlay: @escaping @MainActor @Sendable (EventPreviewSequenceItem) -> Bool
    ) async -> EventPreviewSequenceRunResult {
        generation &+= 1
        let runGeneration = generation
        let plan = await Task.detached(priority: .userInitiated) {
            makePlan()
        }.value
        guard generation == runGeneration, !Task.isCancelled else { return .cancelled }
        let items: [EventPreviewSequenceItem]
        switch plan {
        case .ready(let plannedItems):
            items = plannedItems
        case .failed(let event):
            return .failed(event)
        }
        guard !items.isEmpty else { return .empty }

        for item in items {
            guard generation == runGeneration, !Task.isCancelled else { return .cancelled }
            guard onPlay(item) else { return .failed(item.event) }
            do {
                try await Task.sleep(nanoseconds: item.delayNanoseconds)
            } catch {
                return .cancelled
            }
        }
        guard generation == runGeneration else { return .cancelled }
        return .completed
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
