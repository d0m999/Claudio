import Dispatch
import Foundation

/// Runs only the blocking, value-in/value-out audio importer away from Swift's cooperative
/// executor. Config, manifest coordination, refresh and presentation remain on `MainActor`.
struct SoundPackAudioImportExecutor: Sendable {
    private static let queue = DispatchQueue(
        label: "com.claudio.sound-pack-editor.import",
        qos: .userInitiated)

    #if DEBUG
    private let afterFinalCancellationSampleForTesting: (@Sendable () -> Void)?

    init(afterFinalCancellationSampleForTesting: (@Sendable () -> Void)? = nil) {
        self.afterFinalCancellationSampleForTesting = afterFinalCancellationSampleForTesting
    }
    #else
    init() {}
    #endif

    func execute(_ job: SoundPackAudioImportJob) async -> SoundPackAudioImportExecution {
        let cancellation = SoundPackAudioImportCancellation()
        return await execute(job, cancellation: cancellation)
    }

    func execute(
        _ job: SoundPackAudioImportJob,
        cancellation: SoundPackAudioImportCancellation
    ) async -> SoundPackAudioImportExecution {
        #if DEBUG
        let afterFinalCancellationSampleForTesting = afterFinalCancellationSampleForTesting
        #endif
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Self.queue.async {
                    guard !cancellation.isCancelled else {
                        continuation.resume(returning: .cancelledBeforeWrite)
                        return
                    }
                    let result = importAudioFiles(
                        job.requests,
                        packID: job.packID,
                        environment: job.environment)
                    let execution = SoundPackAudioImportExecution.completed(
                        result,
                        cancellationRequested: cancellation.isCancelled)
                    #if DEBUG
                    afterFinalCancellationSampleForTesting?()
                    #endif
                    continuation.resume(returning: execution)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

struct SoundPackAudioImportJob: Sendable {
    let requests: [AudioImportRequest]
    let packID: String
    let environment: AudioImportEnvironment
}

enum SoundPackAudioImportExecution: Sendable {
    case cancelledBeforeWrite
    case completed(AudioImportBatchResult, cancellationRequested: Bool)
}

final class SoundPackAudioImportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
