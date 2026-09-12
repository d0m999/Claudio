import ClaudioCore
import Darwin
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

    var values: [HostEventNotice] {
        lock.lock()
        defer { lock.unlock() }
        return notices
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

    suite("EventNoticeTransport：真实 pipe → 规范化 → socket，以及旧 schema 1 wire 可配对") {
        withTempDirectory { root in
            let installationID = UUID()
            let received = EventNoticeCollector()
            guard
                let receiver = try? EventNoticeReceiver(
                    descriptorFile: root.appendingPathComponent("descriptor.json"),
                    ownerLockFile: root.appendingPathComponent("owner.lock"),
                    currentInstallationID: { $0 == .claudeCode ? installationID : nil },
                    callback: { received.append($0) })
            else {
                expect(false, "测试 receiver 必须创建成功")
                return
            }
            receiver.start()
            defer { receiver.stop() }
            let pipe = Pipe()
            pipe.fileHandleForWriting.write(
                Data(
                    #"{"cwd":"/private-sentinel/project","session_id":"s","hook_event_name":"Notification","notification_type":"permission_prompt","message":"SECRET_MESSAGE"}"#
                        .utf8))
            let input = HookInputReader.read(from: pipe.fileHandleForReading.fileDescriptor)
            pipe.fileHandleForWriting.closeFile()
            pipe.fileHandleForReading.closeFile()
            let normalized = HostEventSourceParser.parseInput(
                host: .claudeCode, nativeEvent: "Notification", data: input.data)
            let binding = HostCapabilityCatalog.binding(
                host: .claudeCode, nativeEvent: "Notification")!
            let notice = HostEventNotice(
                receiverEpoch: receiver.descriptor.epoch, surface: .claudeCode,
                bindingID: binding.id, installationID: installationID,
                nativeEvent: "Notification", event: .notification, occurredAt: Date(),
                source: normalized.source.source, reason: normalized.reason, observedUptime: 123)
            expect(
                EventNoticeTransport.send(notice, to: receiver.descriptor) == .sent,
                "新消息沿用生产 socket")
            var legacy =
                try! JSONSerialization.jsonObject(with: JSONEncoder().encode(notice))
                as! [String: Any]
            legacy["event_id"] = UUID().uuidString
            legacy.removeValue(forKey: "reason")
            legacy.removeValue(forKey: "observed_uptime")
            var source = legacy["source"] as! [String: Any]
            source.removeValue(forKey: "main_session_is_known")
            legacy["source"] = source
            let legacyData = try! JSONSerialization.data(withJSONObject: legacy)
            expect(
                sendLegacyNoticeDatagram(legacyData, socketPath: receiver.descriptor.socketPath),
                "旧消息直接经过真实 socket")
            for _ in 0..<100 {
                if received.count == 2 { break }
                Thread.sleep(forTimeInterval: 0.005)
            }
            let values = received.values
            expect(values.count == 2, "新旧 schema 1 消息都必须被当前 receiver 接受")
            expect(
                values.contains {
                    $0.reason == .permission && $0.observedUptime == 123
                        && $0.source?.mainSessionIsKnown == true
                }, "新规范字段到达完整")
            expect(
                values.contains {
                    $0.reason == nil && $0.observedUptime == nil
                        && $0.source?.mainSessionIsKnown == nil
                }, "旧消息保持未知能力")
            let wire = String(data: try! JSONEncoder().encode(notice), encoding: .utf8)!
            expect(
                !wire.contains("SECRET_MESSAGE") && !wire.contains("private-sentinel"),
                "wire 不携带正文或完整路径")
        }
    }

    suite("EventNoticeTransport：连续发送中停止会回收 endpoint 且无迟到交付") {
        withTempDirectory { root in
            let collector = EventNoticeCollector()
            let firstDelivery = DispatchSemaphore(value: 0)
            guard
                let receiver = try? EventNoticeReceiver(
                    descriptorFile: root.appendingPathComponent("descriptor.json"),
                    ownerLockFile: root.appendingPathComponent("owner.lock"),
                    callback: { notice in
                        collector.append(notice); firstDelivery.signal()
                    })
            else { expect(false, "压力接收器创建失败"); return }
            receiver.start()
            let descriptor = receiver.descriptor
            let binding = HostCapabilityCatalog.binding(host: .codex, nativeEvent: "Stop")!
            let notice = HostEventNotice(
                receiverEpoch: descriptor.epoch, surface: .codex,
                bindingID: binding.id, installationID: UUID(), nativeEvent: "Stop", event: .stop,
                occurredAt: Date())
            let producer = DispatchGroup()
            producer.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                for _ in 0..<1000 { _ = EventNoticeTransport.send(notice, to: descriptor) }
                producer.leave()
            }
            expect(firstDelivery.wait(timeout: .now() + 1) == .success, "连续发送应有真实交付")
            receiver.stop()
            let stoppedCount = collector.count
            expect(producer.wait(timeout: .now() + 5) == .success, "producer 非阻塞退出")
            expect(collector.count == stoppedCount, "stop 返回后没有迟到交付")
            expect(!FileManager.default.fileExists(atPath: descriptor.socketPath), "停止后清理 endpoint")
        }
    }

    suite("EventNoticeTransport：100 次 receiver 生命周期和发送不会持续增长 FD") {
        withTempDirectory { root in
            let installationID = UUID()
            let binding = HostCapabilityCatalog.binding(host: .codex, nativeEvent: "Stop")!
            func runCycle() -> Bool {
                guard
                    let receiver = try? EventNoticeReceiver(
                        descriptorFile: root.appendingPathComponent("descriptor.json"),
                        ownerLockFile: root.appendingPathComponent("owner.lock"),
                        currentInstallationID: { $0 == .codex ? installationID : nil },
                        callback: { _ in })
                else { return false }
                receiver.start()
                let notice = HostEventNotice(
                    receiverEpoch: receiver.descriptor.epoch, surface: .codex,
                    bindingID: binding.id, installationID: installationID,
                    nativeEvent: "Stop", event: .stop, occurredAt: Date())
                let sent = EventNoticeTransport.send(notice, to: receiver.descriptor) == .sent
                receiver.stop()
                return sent
                    && !FileManager.default.fileExists(atPath: receiver.descriptor.socketPath)
                    && !FileManager.default.fileExists(
                        atPath: root.appendingPathComponent("descriptor.json").path)
            }
            expect(runCycle(), "先预热一次 libdispatch socket 生命周期")
            let before = noticeOpenDescriptorCount()
            for _ in 0..<50 { expect(runCycle(), "每次停止必须清理自有 socket 和 descriptor") }
            let midway = noticeOpenDescriptorCount()
            for _ in 0..<50 { expect(runCycle(), "后 50 次同样必须清理资源") }
            let after = noticeOpenDescriptorCount()
            print(
                "  event notice FD (0..<1024): \(before) → \(midway) → \(after), 100 receiver/send/stop cycles"
            )
            expect(midway <= before && after <= midway, "receiver、owner lock 与 sender FD 不能逐轮增长")
        }
    }
}

private func noticeOpenDescriptorCount() -> Int {
    (Int32(0)..<Int32(1024)).reduce(0) { $0 + (fcntl($1, F_GETFD) == -1 ? 0 : 1) }
}

private func sendLegacyNoticeDatagram(_ data: Data, socketPath: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
    guard fd >= 0 else { return false }
    defer { _ = Darwin.close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8) + [0]
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return data.withUnsafeBytes { bytes in
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.sendto(
                    fd, bytes.baseAddress, bytes.count, 0, $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)) == bytes.count
            }
        }
    }
}
