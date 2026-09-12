import ClaudioCore
import Foundation

/// Bounded cross-queue handoff from the receiver's serial I/O queue to MainActor. It keeps at
/// most 128 notices and schedules one drain at a time; a dropped packet never becomes a fake
/// count or a persisted history record.
public final class EventNoticeIngress: @unchecked Sendable {
    public static let maximumMailboxCount = 128

    private let lock = NSLock()
    private let deliver: @MainActor ([HostEventNotice]) -> Int
    private var mailbox: [HostEventNotice] = []
    private var drainScheduled = false
    private var generation: UInt64 = 0

    public var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return mailbox.count
    }

    public init(deliver: @escaping @MainActor ([HostEventNotice]) -> Int) {
        self.deliver = deliver
    }

    public func enqueue(_ notice: HostEventNotice) {
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

    public func clear() {
        lock.lock()
        generation &+= 1
        mailbox.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    @MainActor
    private func drain() {
        lock.lock()
        let batch = Array(mailbox.prefix(32))
        let capturedGeneration = generation
        lock.unlock()

        let consumed = batch.isEmpty ? 0 : deliver(batch)
        lock.lock()
        if capturedGeneration == generation {
            mailbox.removeFirst(min(max(0, consumed), min(batch.count, mailbox.count)))
        }
        let hasMore = !mailbox.isEmpty
        if !hasMore { drainScheduled = false }
        lock.unlock()

        guard hasMore else { return }
        Task { @MainActor [weak self] in
            self?.drain()
        }
    }
}
