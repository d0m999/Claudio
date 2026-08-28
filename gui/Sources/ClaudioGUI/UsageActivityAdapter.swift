import AppKit
import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
func makeUsageSettingsModel() -> UsageSettingsModel {
    let store = UsageActivityStore.production()
    let logFile = store.logFile

    func load() async -> UsageActivityPresentation {
        await Task.detached(priority: .userInitiated) {
            store.load()
        }.value
    }

    func mutate(
        _ operation:
            @escaping @Sendable (UsageActivityStore) -> Result<Void, UsageActivityStoreError>,
        mapFailure: @escaping @Sendable (UsageActivityStoreError) -> UsageSettingsFailure
    ) async -> Result<UsageActivityPresentation, UsageSettingsFailure> {
        await Task.detached(priority: .userInitiated) {
            switch operation(store) {
            case .success:
                return .success(store.load())
            case .failure(let error):
                return .failure(mapFailure(error))
            }
        }.value
    }

    return UsageSettingsModel(
        operations: UsageSettingsOperations(
            load: load,
            clearHistory: {
                await mutate(
                    { $0.clearHistory() },
                    mapFailure: historyUsageSettingsFailure)
            },
            clearLog: {
                await mutate(
                    { $0.clearLog() },
                    mapFailure: logUsageSettingsFailure)
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

private func historyUsageSettingsFailure(_ error: UsageActivityStoreError) -> UsageSettingsFailure {
    switch error {
    case .historyLockBusy: .historyLockBusy
    case .historyClearFailure, .lockFailure, .logLockBusy, .logClearFailure:
        .historyClearFailed
    }
}

private func logUsageSettingsFailure(_ error: UsageActivityStoreError) -> UsageSettingsFailure {
    switch error {
    case .logLockBusy: .logLockBusy
    case .logClearFailure, .lockFailure, .historyLockBusy, .historyClearFailure:
        .logClearFailed
    }
}
