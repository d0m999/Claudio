import ClaudioCore
import Darwin
import Foundation

@MainActor
func runHookInputReaderSuites() {
    suite("HookInputReader：完整 JSON 不等待 EOF 且恢复 stdin flags") {
        let pipe = Pipe()
        let payload = Data(#"{"cwd":"/tmp/project","session_id":"abc"}"#.utf8)
        pipe.fileHandleForWriting.write(payload)
        let flagsBefore = fcntl(pipe.fileHandleForReading.fileDescriptor, F_GETFL)
        let result = HookInputReader.read(
            from: pipe.fileHandleForReading.fileDescriptor,
            budget: 0.02)
        expect(result.status == .data, "已收到完整 JSON 时必须立即返回 data")
        expect(result.data == payload, "读取结果必须保留完整 payload")
        expect(result.bytesRead == payload.count, "bytesRead 必须与读取数据一致")
        expect(
            fcntl(pipe.fileHandleForReading.fileDescriptor, F_GETFL) == flagsBefore,
            "读取后必须恢复原 flags")
        pipe.fileHandleForWriting.closeFile()
        pipe.fileHandleForReading.closeFile()
    }

    suite("HookInputReader：真实分片 pipe 只做 framing，字符串括号与转义不提前结束") {
        let pipe = Pipe()
        let payload = try! JSONSerialization.data(withJSONObject: [
            "cwd": "/tmp/project", "session_id": "session-1", "hook_event_name": "Notification",
            "notification_type": "elicitation_dialog",
            "message": String(repeating: "[}\\\"", count: 1800),
        ])
        let writer = pipe.fileHandleForWriting
        DispatchQueue.global().async {
            writer.write(payload.prefix(3000))
            Thread.sleep(forTimeInterval: 0.002)
            writer.write(payload.dropFirst(3000))
        }
        let result = HookInputReader.read(
            from: pipe.fileHandleForReading.fileDescriptor, budget: 0.02)
        expect(result.data == payload, "跨 read 边界必须保留完整输入，不受正文括号影响")
        let parsed = HostEventSourceParser.parseInput(
            host: .claudeCode, nativeEvent: "Notification", data: result.data)
        expect(
            parsed.reason == .needsInput && parsed.source.source?.sessionID == "session-1",
            "真实 pipe 输入沿用生产规范化")
        pipe.fileHandleForWriting.closeFile()
        pipe.fileHandleForReading.closeFile()
    }

    suite("HookInputReader：空输入、超限和无 EOF 分片都有界") {
        let emptyPipe = Pipe()
        let empty = HookInputReader.read(
            from: emptyPipe.fileHandleForReading.fileDescriptor,
            budget: 0.005)
        expect(empty.status == .timedOut, "保持打开且没有输入时必须按预算超时")
        emptyPipe.fileHandleForWriting.closeFile()
        emptyPipe.fileHandleForReading.closeFile()

        let largePipe = Pipe()
        largePipe.fileHandleForWriting.write(Data(repeating: 0x78, count: 40))
        let large = HookInputReader.read(
            from: largePipe.fileHandleForReading.fileDescriptor,
            maximumBytes: 32,
            budget: 0.02)
        expect(large.status == .tooLarge, "超过上限必须停止读取")
        largePipe.fileHandleForWriting.closeFile()
        largePipe.fileHandleForReading.closeFile()
    }

    suite("HookInputReader：真实 64KiB 上限及 20ms 无 EOF 故障预算") {
        let oversizedPipe = Pipe()
        let writer = oversizedPipe.fileHandleForWriting
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            writer.write(Data(repeating: 0x20, count: 64 * 1024 + 1))
            finished.signal()
        }
        let large = HookInputReader.read(from: oversizedPipe.fileHandleForReading.fileDescriptor)
        expect(large.status == .tooLarge && large.data == nil, "真实超过 64KiB 必须丢弃完整 payload")
        expect(finished.wait(timeout: .now() + 1) == .success, "有界 writer 必须完成")
        oversizedPipe.fileHandleForWriting.closeFile()
        oversizedPipe.fileHandleForReading.closeFile()

        let partialPipe = Pipe()
        partialPipe.fileHandleForWriting.write(Data(#"{"cwd":"#.utf8))
        let started = ProcessInfo.processInfo.systemUptime
        let partial = HookInputReader.read(from: partialPipe.fileHandleForReading.fileDescriptor)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        expect(partial.status == .data, "预算结束后返回有界的未完成数据，不等待 EOF")
        let parsed = HostEventSourceParser.parseInput(
            host: .claudeCode, nativeEvent: "Notification", data: partial.data)
        expect(parsed.source.source == nil && parsed.reason == .review, "未完成 JSON 独立降级，不制造来源")
        print(
            "  helper partial stdin fault: \(String(format: "%.2f", elapsed * 1000))ms (configured 20ms; includes OS scheduling)"
        )
        partialPipe.fileHandleForWriting.closeFile()
        partialPipe.fileHandleForReading.closeFile()
    }
}
