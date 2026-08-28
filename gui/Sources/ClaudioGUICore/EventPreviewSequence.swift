import ClaudioCore
import Foundation

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

/// Builds the ordered, fail-closed sequence consumed by “Preview All”. The retained view calls
/// this only through ``EventPreviewSequenceCoordinator/run(makePlan:onPlay:)``, which executes the
/// filesystem and duration work in a detached task rather than during SwiftUI body evaluation.
public func makeEventPreviewSequencePlan(
    presentations: [PanelEventPresentation],
    rows: [EventRow],
    packID: String,
    environment: AudioImportEnvironment
) -> [EventPreviewSequenceItem] {
    let rowsByEvent = Dictionary(uniqueKeysWithValues: rows.map { ($0.event, $0) })
    return presentations.compactMap { presentation in
        guard presentation.controls.previewEnabled,
            let row = rowsByEvent[presentation.event],
            let fileURL = eventPreviewFileURL(
                row: row,
                packID: packID,
                environment: environment)
        else { return nil }
        let probedDuration = environment.durationProbe.probeDuration(of: fileURL) ?? 3
        let duration = probedDuration.isFinite ? probedDuration : 3
        let boundedDuration = min(3, max(0.1, duration))
        return EventPreviewSequenceItem(
            event: presentation.event,
            fileURL: fileURL,
            delayNanoseconds: UInt64((boundedDuration + 0.15) * 1_000_000_000))
    }
}

public enum EventPreviewSequenceRunResult: Sendable, Equatable {
    case completed
    case empty
    case cancelled
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
        makePlan: @escaping @Sendable () -> [EventPreviewSequenceItem],
        onPlay: @escaping @MainActor @Sendable (EventPreviewSequenceItem) -> Void
    ) async -> EventPreviewSequenceRunResult {
        generation &+= 1
        let runGeneration = generation
        let items = await Task.detached(priority: .userInitiated) {
            makePlan()
        }.value
        guard generation == runGeneration, !Task.isCancelled else { return .cancelled }
        guard !items.isEmpty else { return .empty }

        for item in items {
            guard generation == runGeneration, !Task.isCancelled else { return .cancelled }
            onPlay(item)
            do {
                try await Task.sleep(nanoseconds: item.delayNanoseconds)
            } catch {
                return .cancelled
            }
        }
        guard generation == runGeneration else { return .cancelled }
        return .completed
    }
}
