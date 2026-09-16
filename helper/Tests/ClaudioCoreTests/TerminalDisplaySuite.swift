import ClaudioCore
import Foundation

@MainActor
func runTerminalDisplaySuites() {
    suite("terminalSafePackID：控制字符与双向控制符不会修改终端呈现") {
        let unsafe = "pack\u{001B}[31m\n\u{202E}x\u{2066}"
        let safe = terminalSafePackID(unsafe)
        expect(safe == "pack\\u{1B}[31m\\u{A}\\u{202E}x\\u{2066}", "控制符必须可见转义：\(safe)")
        expect(!safe.contains("\u{001B}") && !safe.contains("\u{202E}"), "输出不得保留控制符")
        expect(terminalSafePackID("普通-pack") == "普通-pack", "普通身份不能被改写")
    }

    suite("terminalSafePackID：同时限制 grapheme、scalar 与最终字节数") {
        let long = String(repeating: "👩‍💻", count: 100)
        let output = terminalSafePackID(long)
        expect(output.hasSuffix("…"), "超长身份必须截断")
        expect(output.utf8.count <= 256, "终端输出不得超过字节上限")
        let combined = "a" + String(repeating: "\u{0301}", count: 400)
        let combinedOutput = terminalSafePackID(combined)
        expect(combinedOutput.hasSuffix("…"), "单个组合 grapheme 也必须受限")
        expect(combinedOutput.utf8.count <= 256, "组合 grapheme 不得绕过字节上限")
    }
}
