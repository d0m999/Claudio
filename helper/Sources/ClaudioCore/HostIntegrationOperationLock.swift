import Foundation

/// Serializes one host's complete connect/disconnect side effect across Claudio processes.
/// ConfigFileTransaction still owns the narrower JSON-file lock; this outer lock must use a
/// different path so it can cover marker and legacy-wrapper phases without self-contention.
func withHostIntegrationOperationLock<T>(
    path: URL,
    _ operation: () -> Result<T, HostIntegrationActionError>
) -> Result<T, HostIntegrationActionError> {
    switch withNonBlockingLock(path: path.path, operation) {
    case .ran(let result):
        return result
    case .skipped:
        return .failure(.transaction(.lockBusy))
    case .failed(let code):
        return .failure(.transaction(.lockFailed(errno: code)))
    }
}
