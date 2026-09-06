import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
func runActivityDiagnosticsSuites() async {
    suite("Activity diagnostic log is bounded, redacted, and independently clearable") {
        withTempDirectory { root in
            let log = root.appendingPathComponent("claudio.log")
            let lockURL = root.appendingPathComponent("claudio.log.lock")
            expect(
                appendLogLine(
                    event: "stop",
                    reason: "Authorization Bearer secret /Users/private/prompt.wav",
                    timestamp: Date(timeIntervalSince1970: 1_900_000_000),
                    to: log,
                    lockFile: lockURL),
                "a valid diagnostic line should be written")

            let store = ActivityDiagnosticLogStore(logFile: log, logLockFile: lockURL)
            let snapshot = store.diagnosticLogSnapshot()
            if case .available(let size) = snapshot.state {
                expect(size > 0 && snapshot.failures.count == 1,
                    "the log projection should expose only bounded redacted failure facts")
            } else {
                expect(false, "a valid diagnostic log should be available")
            }
            let reflected = String(reflecting: snapshot)
            for forbidden in ["secret", "Authorization", "/Users/private", "prompt.wav"] {
                expect(!reflected.contains(forbidden), "raw diagnostic content must not escape: \(forbidden)")
            }

            let held = FileLock(path: lockURL.path)
            expect(held.attemptLock() == .acquired, "test must hold the diagnostic lock")
            let busyResult = store.clearLog()
            if case .failure(.logLockBusy) = busyResult {
                expect(true, "a busy log lock must not delete the log")
            } else {
                expect(false, "a busy log lock must not delete the log")
            }
            held.unlock()
            let clearResult = store.clearLog()
            if case .success = clearResult {
                expect(true, "clearing the diagnostic log should succeed")
            } else {
                expect(false, "clearing the diagnostic log should succeed")
            }
            expect(store.diagnosticLogSnapshot().state == .missing,
                "cleared diagnostics should report a missing log, not stale failures")
        }
    }

    await suite("Activity diagnostics keeps activity projection independent from log clearing") {
        let initial = ActivityDiagnosticsPresentation.empty()
        let updatedLog = ActivityDiagnosticLogSnapshot(
            path: "/tmp/claudio.log",
            state: .missing,
            failures: [])
        let model = ActivityDiagnosticsModel(
            initialPresentation: initial,
            operations: ActivityDiagnosticsOperations(
                load: {
                    ActivityDiagnosticsLoadResult(
                        readResult: LocalActivitySummaryReadResult(state: .missing),
                        log: initial.log)
                },
                clearActivity: { .failure(.activityClearFailed) },
                clearLog: { .success(updatedLog) },
                revealLog: { true },
                copyLogPath: { true }))

        model.clearLog()
        for _ in 0..<6 { await Task.yield() }
        expect(model.presentation.projection == initial.projection,
            "clearing diagnostics must not change activity counts or status")
        expect(model.presentation.log == updatedLog,
            "the log operation must publish only its own child fact")
    }

    suite("Activity production wiring has no receipt-history usage projection") {
        let root = guiTestRepositoryRoot()
        let adapter = try? String(
            contentsOf: root.appendingPathComponent("gui/Sources/ClaudioGUI/UsageActivityAdapter.swift"),
            encoding: .utf8)
        let activityView = try? String(
            contentsOf: root.appendingPathComponent("gui/Sources/ClaudioGUI/ActivityDiagnosticsView.swift"),
            encoding: .utf8)
        let settings = try? String(
            contentsOf: root.appendingPathComponent("gui/Sources/ClaudioGUI/SettingsWindowView.swift"),
            encoding: .utf8)
        expect(
            adapter?.contains("LocalActivitySummaryStore.production") == true
                && adapter?.contains("ActivityDiagnosticLogStore.production") == true
                && adapter?.contains("UsageActivityStore") == false,
            "production composition must use the local activity and log-only owners")
        expect(
            activityView?.contains("ActivityDiagnosticsModel") == true
                && activityView?.contains("UsageActivityStore") == false,
            "the Activity destination must consume the shared model, not the retired usage store")
        expect(
            settings?.contains("ActivityDiagnosticsView(") == true
                && settings?.contains("model: activityDiagnostics") == true,
            "the retained Settings window must mount the shared Activity destination")
        expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("gui/Sources/ClaudioGUI/UsageSettingsView.swift").path),
            "the receipt-history settings view must be retired")
    }
}
