import ClaudioCore
import Foundation

private final class EventNoticeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var notices: [HostEventNotice] = []

    func append(_ notice: HostEventNotice) {
        lock.lock()
        notices.append(notice)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return notices.count
    }
}

@MainActor
func runEventNoticeTransportSuites() {
    suite("EventNoticeTransport：私有 receiver 接收合法 datagram 并隔离陈旧 epoch") {
        withTempDirectory { root in
            let descriptorFile = root.appendingPathComponent("descriptor.json")
            let lockFile = root.appendingPathComponent("owner.lock")
            let received = EventNoticeCollector()
            let installationID = UUID()
            let epoch = UUID()
            let receiver: EventNoticeReceiver
            do {
                receiver = try EventNoticeReceiver(
                    descriptorFile: descriptorFile,
                    ownerLockFile: lockFile,
                    epoch: epoch,
                    currentInstallationID: { host in
                        host == .codex ? installationID : nil
                    }
                ) { notice in
                    received.append(notice)
                }
            } catch {
                expect(false, "测试 receiver 必须能创建：\(error)")
                return
            }
            receiver.start()
            let descriptor = EventNoticeTransport.loadDescriptor(from: descriptorFile)
            expect(
                descriptor?.epoch == receiver.descriptor.epoch, "descriptor epoch 必须与 receiver 一致")
            guard let descriptor else {
                receiver.stop()
                return
            }
            let binding = HostCapabilityCatalog.binding(
                host: .codex,
                nativeEvent: "Stop")!
            let notice = HostEventNotice(
                receiverEpoch: descriptor.epoch,
                surface: .codex,
                bindingID: binding.id,
                installationID: installationID,
                nativeEvent: binding.nativeEvent!,
                event: binding.event,
                occurredAt: Date())
            expect(
                EventNoticeTransport.send(notice, to: descriptor) == .sent,
                "合法 notice 必须可以 best-effort 发送")
            for _ in 0..<100 {
                if received.count == 1 { break }
                Thread.sleep(forTimeInterval: 0.005)
            }
            expect(received.count == 1, "receiver 必须交付合法 datagram")

            let wrongInstallation = HostEventNotice(
                receiverEpoch: descriptor.epoch,
                surface: .codex,
                bindingID: binding.id,
                installationID: UUID(),
                nativeEvent: binding.nativeEvent!,
                event: binding.event,
                occurredAt: Date())
            expect(
                EventNoticeTransport.send(wrongInstallation, to: descriptor) == .sent,
                "传输层可以 best-effort 发送，但 installation 过滤应由接收端完成")
            Thread.sleep(forTimeInterval: 0.02)
            expect(received.count == 1, "非当前 installation 的 notice 不得进入 GUI callback")

            let stale = HostEventNotice(
                receiverEpoch: UUID(),
                surface: .codex,
                bindingID: binding.id,
                installationID: UUID(),
                nativeEvent: binding.nativeEvent!,
                event: binding.event,
                occurredAt: Date())
            expect(
                EventNoticeTransport.send(stale, to: descriptor) == .dropped(.invalidNotice),
                "陈旧 epoch 必须在发送边界被拒绝")
            receiver.stop()
            expect(
                !FileManager.default.fileExists(atPath: descriptorFile.path),
                "stop 必须清理自有 descriptor")
        }
    }
}
