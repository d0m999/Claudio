import ClaudioCore
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

    func validateTarget(
        _ job: SoundPackAudioImportJob,
        cancellation: SoundPackAudioImportCancellation
    ) async -> SoundPackAudioImportTargetValidation {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Self.queue.async {
                    guard !cancellation.isCancelled else {
                        continuation.resume(returning: .cancelled)
                        return
                    }
                    guard
                        editorImportTargetIsCurrent(
                            packID: job.packID,
                            environment: job.environment)
                    else {
                        continuation.resume(returning: .unavailable)
                        return
                    }
                    continuation.resume(returning: .available)
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

enum SoundPackAudioImportTargetValidation: Sendable {
    case cancelled
    case unavailable
    case available
}

enum SoundPackAudioImportExecution: Sendable {
    case cancelledBeforeWrite
    case completed(AudioImportBatchResult, cancellationRequested: Bool)
}

/// Cheap off-main rejection at the async ownership boundary. This does not publish a second disk
/// fact: a miss is handed back to the owner, which asks the one shared `SoundPackLibrary` to
/// observe and publish the authoritative result before returning a typed refusal.
private func editorImportTargetIsCurrent(
    packID: String,
    environment: AudioImportEnvironment
) -> Bool {
    guard
        let resolved = resolvePackDirectory(
            id: packID,
            userPacksDirectory: environment.userPacksDirectory,
            bundledPacksDirectory: environment.bundledPacksDirectory)
    else { return false }
    let expected = environment.userPacksDirectory.appendingPathComponent(
        packID, isDirectory: true)
    return resolved.standardizedFileURL.path == expected.standardizedFileURL.path
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
