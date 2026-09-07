import ClaudioCore
import Darwin
import Foundation

/// A bounded, redacted projection of the diagnostic log. It contains no raw reason text.
public struct ActivityLogFailureSummary: Sendable, Equatable {
    public let timestamp: Date
    public let event: Event?
    public let category: LogFailureCategory

    public init(timestamp: Date, event: Event?, category: LogFailureCategory) {
        self.timestamp = timestamp
        self.event = event
        self.category = category
    }
}

public enum ActivityDiagnosticLogState: Sendable, Equatable {
    case available(sizeBytes: Int)
    case missing
    case damaged(sizeBytes: Int, skippedLineCount: Int)
    case unreadable
}

public struct ActivityDiagnosticLogSnapshot: Sendable, Equatable {
    public let path: String
    public let state: ActivityDiagnosticLogState
    public let failures: [ActivityLogFailureSummary]

    public init(
        path: String,
        state: ActivityDiagnosticLogState,
        failures: [ActivityLogFailureSummary]
    ) {
        self.path = path
        self.state = state
        self.failures = failures
    }
}

public enum ActivityDiagnosticLogStoreError: Error, Sendable, Equatable {
    case logLockBusy
    case lockFailure
    case logClearFailure
}

/// The only production adapter for the diagnostic log. Receipt history remains an integration
/// fact and is intentionally not part of Activity & Diagnostics.
public struct ActivityDiagnosticLogStore: Sendable {
    public static let maximumLogBytes = 1 << 20
    public static let maximumFailureSummaries = 5

    public let logFile: URL
    public let logLockFile: URL

    public init(logFile: URL, logLockFile: URL) {
        self.logFile = logFile
        self.logLockFile = logLockFile
    }

    public static var production: Self {
        Self(logFile: ClaudioPaths.logFile, logLockFile: ClaudioPaths.logLockFile)
    }

    public func diagnosticLogSnapshot() -> ActivityDiagnosticLogSnapshot {
        let path = logFile.path
        switch readRegularFileBounded(
            at: logFile,
            maxBytes: Self.maximumLogBytes,
            followSymlink: false)
        {
        case .success(let data):
            let entries = parseRecentLogEntries(data, maxLines: Int.max)
            let totalLineCount = data.split(separator: UInt8(ascii: "\n")).count
            let skippedLineCount = max(0, totalLineCount - entries.count)
            let failures = entries.suffix(Self.maximumFailureSummaries).map { entry in
                ActivityLogFailureSummary(
                    timestamp: entry.timestamp,
                    event: Event(cliName: entry.event),
                    category: entry.redactedFailureCategory)
            }
            let state: ActivityDiagnosticLogState =
                skippedLineCount == 0
                ? .available(sizeBytes: data.count)
                : .damaged(sizeBytes: data.count, skippedLineCount: skippedLineCount)
            return ActivityDiagnosticLogSnapshot(path: path, state: state, failures: failures)
        case .notRegularFile, .oversize:
            return ActivityDiagnosticLogSnapshot(path: path, state: .unreadable, failures: [])
        case .unreadable:
            var status = stat()
            if lstat(path, &status) != 0, errno == ENOENT {
                return ActivityDiagnosticLogSnapshot(path: path, state: .missing, failures: [])
            }
            return ActivityDiagnosticLogSnapshot(path: path, state: .unreadable, failures: [])
        }
    }

    public func clearLog() -> Result<Void, ActivityDiagnosticLogStoreError> {
        let locked = withNonBlockingLock(path: logLockFile.path) {
            guard Darwin.unlink(logFile.path) == 0 || errno == ENOENT else {
                return Result<Void, ActivityDiagnosticLogStoreError>.failure(.logClearFailure)
            }
            return Result<Void, ActivityDiagnosticLogStoreError>.success(())
        }
        switch locked {
        case .ran(let result): return result
        case .skipped: return .failure(.logLockBusy)
        case .failed: return .failure(.lockFailure)
        }
    }
}
