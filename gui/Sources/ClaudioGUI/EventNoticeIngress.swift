import ClaudioCore
import Foundation

/// Bounded cross-queue handoff from the receiver's serial I/O queue to MainActor. It keeps at
/// most 128 notices and schedules one drain at a time; a dropped packet never becomes a fake
/// count or a persisted history record.
final class EventNoticeIngress: @unchecked Sendable {
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
