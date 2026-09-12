import ClaudioCore
import Foundation

@MainActor
func runHookInputReaderSuites() {
    suite("HookInputReader：完整 JSON 不等待 EOF 且恢复 stdin flags") {
        let pipe = Pipe()
        let payload = Data(#"{"cwd":"/tmp/project","session_id":"abc"}"#.utf8)
        pipe.fileHandleForWriting.write(payload)
        let result = HookInputReader.read(
            from: pipe.fileHandleForReading.fileDescriptor,
            budget: 0.02)
        expect(result.status == .data, "已收到完整 JSON 时必须立即返回 data")
        expect(result.data == payload, "读取结果必须保留完整 payload")
        expect(result.bytesRead == payload.count, "bytesRead 必须与读取数据一致")
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
}
