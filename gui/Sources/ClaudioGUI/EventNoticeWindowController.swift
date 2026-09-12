import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import Combine
import Foundation
import SwiftUI

/// Bounded cross-queue handoff from the receiver's serial I/O queue to MainActor. It keeps at
/// most 128 notices and schedules one drain at a time; a dropped packet never becomes a fake
/// count or a persisted history record.
private final class EventNoticeIngress: @unchecked Sendable {
    private static let maximumMailboxCount = 128

    private let lock = NSLock()
    private let deliver: @MainActor ([HostEventNotice]) -> Void
    private var mailbox: [HostEventNotice] = []
    private var drainScheduled = false

    init(deliver: @escaping @MainActor ([HostEventNotice]) -> Void) {
        self.deliver = deliver
    }

    func enqueue(_ notice: HostEventNotice) {
        lock.lock()
        guard mailbox.count < Self.maximumMailboxCount else {
            lock.unlock()
            return
        }
        mailbox.append(notice)
        let shouldSchedule = !drainScheduled
        drainScheduled = true
        lock.unlock()
        guard shouldSchedule else { return }
        Task { @MainActor [weak self] in
            self?.drain()
        }
    }

    func clear() {
        lock.lock()
        mailbox.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    @MainActor
    private func drain() {
        lock.lock()
        let batch = Array(mailbox.prefix(32))
        mailbox.removeFirst(min(32, mailbox.count))
        let hasMore = !mailbox.isEmpty
        if !hasMore { drainScheduled = false }
        lock.unlock()

        if !batch.isEmpty { deliver(batch) }
        guard hasMore else { return }
        Task { @MainActor [weak self] in
            self?.drain()
        }
    }
}

@MainActor
private final class EventNoticeWindowActionRouter {
    weak var owner: EventNoticeWindowController?

    func viewSource(_ notice: HostEventNotice) {
        owner?.viewSource(notice)
    }

    @discardableResult
    func copySessionID(_ sessionID: String) -> Bool {
        owner?.copySessionID(sessionID) ?? false
    }

    func close() {
        owner?.close()
    }
}

/// Retained, non-activating native surface for the C-direction prompt. Automatic delivery only
/// orders the panel; explicit interaction is the only path that makes it key.
@MainActor
final class EventNoticeWindowController: NSObject, NSWindowDelegate {
    let model: EventNoticeModel

    private let languageStore: ClaudioPreferences
    private let window: NSPanel
    private let actionRouter: EventNoticeWindowActionRouter
    private var snapshotCancellable: AnyCancellable?
    private var screenCancellable: AnyCancellable?
    private var animationRevision: UInt64 = 0
    private var presentationScreen: NSScreen?
    private var isInteractive = false

    init(model: EventNoticeModel, languageStore: ClaudioPreferences) {
        self.model = model
        self.languageStore = languageStore
        actionRouter = EventNoticeWindowActionRouter()
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 92),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true)

        super.init()

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isFloatingPanel = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = false
        window.delegate = self
        window.title = "claudi0 event notice"
        window.contentView = NSHostingView(
            rootView: EventNoticeView(
                model: model,
                languageStore: languageStore,
                onViewSource: { [weak actionRouter] notice in
                    actionRouter?.viewSource(notice)
                },
                onCopySessionID: { [weak actionRouter] sessionID in
                    actionRouter?.copySessionID(sessionID) ?? false
                },
                onClose: { [weak actionRouter] in
                    actionRouter?.close()
                }))

        snapshotCancellable = model.$snapshot.sink { [weak self] snapshot in
            self?.render(snapshot)
        }
        screenCancellable = NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.repositionIfVisible()
            }
        actionRouter.owner = self
    }

    func openInteractive() {
        model.openRecent()
        guard model.snapshot.current != nil else { return }
        isInteractive = true
        positionWindow()
        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)
        model.setKeyboardFocused(true)
    }

    func viewSource(_ notice: HostEventNotice) {
        // Production has no verified host route yet. This action enters the retained detail/list
        // surface; it does not claim that an application or exact session was opened.
        guard notice.isSemanticallyValid, notice.receiverEpoch == model.receiverEpoch else {
            return
        }
        model.selectRecent(id: notice.id)
        guard model.snapshot.current?.id == notice.id else { return }
        openInteractive()
    }

    @discardableResult
    func copySessionID(_ sessionID: String) -> Bool {
        guard
            !sessionID.isEmpty,
            model.snapshot.current?.source?.sessionID == sessionID
        else { return false }
        guard
            NSPasteboard.general.clearContents() != 0,
            NSPasteboard.general.setString(sessionID, forType: .string)
        else { return false }
        openInteractive()
        return true
    }

    func close() {
        isInteractive = false
        model.setKeyboardFocused(false)
        model.dismiss()
    }

    func clearForPrivacy() {
        isInteractive = false
        presentationScreen = nil
        window.orderOut(nil)
        model.clearForPrivacy()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard isInteractive else { return }
        model.setKeyboardFocused(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        model.setKeyboardFocused(false)
    }

    private func render(_ snapshot: EventNoticeModelSnapshot) {
        guard snapshot.current != nil, snapshot.phase != .hidden else {
            if snapshot.phase == .hidden { presentationScreen = nil }
            if window.isVisible { window.orderOut(nil) }
            return
        }
        positionWindow()
        animationRevision &+= 1
        let revision = animationRevision
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        switch snapshot.phase {
        case .entering, .visible:
            if !window.isVisible {
                window.alphaValue = reduceMotion ? 1 : 0; window.orderFront(nil)
            }
            if reduceMotion {
                window.alphaValue = 1
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = EventNoticeModel.fadeDuration
                    window.animator().alphaValue = 1
                }
            }
        case .exiting:
            if reduceMotion {
                window.alphaValue = 0
                window.orderOut(nil)
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = EventNoticeModel.fadeDuration
                    context.completionHandler = { [weak self] in
                        guard let self, self.animationRevision == revision else { return }
                        self.window.orderOut(nil)
                    }
                    window.animator().alphaValue = 0
                }
            }
        case .hidden:
            window.orderOut(nil)
        }
    }

    private func repositionIfVisible() {
        guard window.isVisible else { return }
        positionWindow()
    }

    private func positionWindow() {
        if let presentationScreen,
            !NSScreen.screens.contains(where: { $0 === presentationScreen })
        {
            self.presentationScreen = nil
        }
        let screen = presentationScreen ?? screenForFirstNotice() ?? NSScreen.main
        guard let screen else { return }
        if presentationScreen == nil { presentationScreen = screen }
        let visible = screen.visibleFrame
        let width = min(440, max(280, visible.width - 32))
        let height = max(88, min(180, window.contentView?.fittingSize.height ?? 92))
        let minimumX = visible.minX + 16
        let maximumX = max(minimumX, visible.maxX - width - 16)
        let x = min(max(visible.midX - width / 2, minimumX), maximumX)
        let y = visible.maxY - 12 - height
        window.setFrame(
            NSRect(x: x, y: max(visible.minY + 16, y), width: width, height: height),
            display: true)
    }

    private func screenForFirstNotice() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(point) })
    }
}

/// App-lifetime composition owner for the model, bounded ingress, and GUI-owned receiver.
@MainActor
final class EventNoticeRuntime {
    let model: EventNoticeModel
    private var receiver: EventNoticeReceiver?
    private let ingress: EventNoticeIngress
    private let receiptStore: HostHookReceiptStore

    init() {
        let model = EventNoticeModel(receiverEpoch: UUID())
        self.model = model
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
        } catch {
            // Best effort: no receiver means hooks retain their original playback/receipt/exit
            // contract and the GUI remains usable without fabricating delivery health.
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
        if enabled { startReceiver() }
    }

    func suspendForPower() {
        stopReceiver()
        model.clearForPrivacy()
    }

    func resumeAfterPower() {
        startReceiver()
    }

    func stopForTermination() {
        stopReceiver()
        model.clearForPrivacy()
    }
}
