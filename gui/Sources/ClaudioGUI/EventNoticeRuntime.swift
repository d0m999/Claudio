import ClaudioCore
import ClaudioGUICore
import Foundation

/// App-lifetime composition owner for the model, bounded ingress, and GUI-owned receiver.
/// Health is reported as fixed redacted codes only; a failed receiver never fabricates
/// delivery state and never disturbs the existing audio/receipt path.
@MainActor
final class EventNoticeRuntime {
    let model: EventNoticeModel
    let health: EventNoticeHealthStore
    private var receiver: EventNoticeReceiver?
    private let ingress: EventNoticeIngress
    private let receiptStore: HostHookReceiptStore

    init() {
        let model = EventNoticeModel(receiverEpoch: UUID())
        self.model = model
        health = EventNoticeHealthStore()
        receiptStore = HostHookReceiptStore(
            receiptsRoot: ClaudioPaths.receiptsDirectory,
            locksRoot: ClaudioPaths.receiptLocksDirectory,
            installationsRoot: ClaudioPaths.activeInstallationsDirectory,
            installationLocksRoot: ClaudioPaths.activeInstallationLocksDirectory)
        ingress = EventNoticeIngress { [weak model] notices in
            _ = model?.accept(contentsOf: notices)
        }
        startReceiver()
    }

    func startReceiver() {
        guard receiver == nil, model.isEnabled else { return }
        do {
            let receiptStore = self.receiptStore
            let receiver = try EventNoticeReceiver(
                epoch: model.receiverEpoch,
                currentInstallationID: { host in
                    receiptStore.currentInstallationID(host: host)
                }
            ) { [weak ingress] notice in
                ingress?.enqueue(notice)
            }
            receiver.start()
            self.receiver = receiver
            health.reportReady()
        } catch let error as EventNoticeReceiverError {
            // Best effort: no receiver means hooks retain their original playback/receipt/exit
            // contract and the GUI remains usable without fabricating delivery health.
            health.reportUnavailable(code: error.diagnosticCode)
        } catch {
            // Unknown failure kinds get the honest unknown code, never a guessed one.
            health.reportUnavailable(code: "unknown")
        }
    }

    func stopReceiver() {
        receiver?.stop()
        receiver = nil
        ingress.clear()
    }

    func setEnabled(_ enabled: Bool) {
        guard model.isEnabled != enabled else { return }
        stopReceiver()
        model.setEnabled(enabled)
        if enabled {
            startReceiver()
        } else {
            health.reportDisabled()
        }
    }

    /// Sleep and screen lock share one privacy boundary: hide immediately, clear source memory,
    /// and invalidate the epoch so a locked screen never replays private notices on return.
    func suspendForSystemPrivacy() {
        stopReceiver()
        model.clearForPrivacy()
        health.reportDisabled()
    }

    func resumeAfterSystemPrivacy() {
        startReceiver()
    }

    func stopForTermination() {
        stopReceiver()
        model.clearForPrivacy()
    }
}
