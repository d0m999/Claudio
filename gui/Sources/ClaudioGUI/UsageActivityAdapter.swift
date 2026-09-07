import AppKit
import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
func makeActivityDiagnosticsModel() -> ActivityDiagnosticsModel {
    let activityStore = LocalActivitySummaryStore.production
    let logStore = ActivityDiagnosticLogStore.production
    let logFile = logStore.logFile

    let load: @Sendable () async -> ActivityDiagnosticsLoadResult = {
        await Task.detached(priority: .userInitiated) {
            ActivityDiagnosticsLoadResult(
                readResult: activityStore.read(),
                log: logStore.diagnosticLogSnapshot())
        }.value
    }

    return ActivityDiagnosticsModel(
        operations: ActivityDiagnosticsOperations(
            load: load,
            clearActivity: {
                await Task.detached(priority: .userInitiated) {
                    switch activityStore.clear() {
                    case .success(let clearedDocument):
                        return .success(
                            ActivityDiagnosticsLoadResult(
                                readResult: LocalActivitySummaryReadResult(
                                    state: .ready(clearedDocument)),
                                log: logStore.diagnosticLogSnapshot()))
                    case .failure(let error):
                        return .failure(activityDiagnosticsFailure(error))
                    }
                }.value
            },
            clearLog: {
                await Task.detached(priority: .userInitiated) {
                    switch logStore.clearLog() {
                    case .success:
                        return .success(logStore.diagnosticLogSnapshot())
                    case .failure(let error):
                        return .failure(logClearFailure(error))
                    }
                }.value
            },
            revealLog: {
                NSWorkspace.shared.selectFile(
                    logFile.path,
                    inFileViewerRootedAtPath: "")
            },
            copyLogPath: {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                return pasteboard.setString(logFile.path, forType: .string)
            }))
}

private func activityDiagnosticsFailure(
    _ error: LocalActivitySummaryStoreError
) -> ActivityDiagnosticsFailure {
    switch error {
    case .lockBusy: .activityLockBusy
    case .lockFailure, .summaryMissing, .summaryUnreadable, .summaryDamaged,
        .summaryOversize, .pendingUnreadable, .pendingOversize, .directoryFailure,
        .writeFailure:
        .activityClearFailed
    }
}

private func logClearFailure(_ error: ActivityDiagnosticLogStoreError) -> ActivityDiagnosticsFailure
{
    switch error {
    case .logLockBusy: .logLockBusy
    case .logClearFailure, .lockFailure:
        .logClearFailed
    }
}
