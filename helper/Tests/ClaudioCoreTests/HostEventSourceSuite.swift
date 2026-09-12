import ClaudioCore
import Foundation

@MainActor
func runHostEventSourceSuites() {
    suite("HostEventSource：按宿主白名单提取项目、会话与父会话身份") {
        let payload = Data(
            #"{"cwd":"/Users/example/同名项目","session_id":"12345678-abcdef","agent_id":"child-1","transcript":"private"}"#
                .utf8)
        let outcome = HostEventSourceParser.parse(host: .codex, data: payload)
        guard case .available(let source) = outcome else {
            expect(false, "合法 Codex payload 必须得到来源")
            return
        }
        expect(source.projectLabel == "同名项目", "项目展示名必须取 cwd 的末级安全标签")
        expect(source.sessionID == "12345678-abcdef", "session_id 必须保留有效会话身份")
        expect(source.sessionLabel == "session · 12345678", "短会话标签必须显示真实前缀")
        expect(source.isParentSession, "子任务 payload 必须标注父会话，不得改用 agent_id 导航")
        expect(source.completeness == .complete, "项目与会话都存在时完整度必须为 complete")
    }

    suite("HostEventSource：同名项目不合并且缺失字段明确降级") {
        let first = HostEventSourceParser.parse(
            host: .claudeCode,
            data: Data(#"{"cwd":"/tmp/one/same","session_id":"a"}"#.utf8))
        let second = HostEventSourceParser.parse(
            host: .claudeCode,
            data: Data(#"{"cwd":"/tmp/two/same","session_id":"b"}"#.utf8))
        expect(first.source?.projectLabel == second.source?.projectLabel, "同名项目仍可显示相同标签")
        expect(first.source?.projectKey != second.source?.projectKey, "不同原始路径必须保留不同内存 key")

        let folded = HostEventSourceParser.parse(
            host: .claudeCode,
            data: Data(#"{"cwd":"/tmp/line\nproject","session_id":"session\r\npart"}"#.utf8))
        expect(
            folded.source?.projectLabel == "line project"
                && folded.source?.sessionID == "session part",
            "换行与制表符必须安全折叠为空格，而不是把已知来源整条抹掉")

        let projectOnly = HostEventSourceParser.parse(
            host: .claudeCode,
            data: Data(#"{"cwd":"/tmp/project"}"#.utf8))
        expect(projectOnly.completeness == .partial, "只有项目时必须是 partial")
        expect(projectOnly.source?.sessionID == nil, "缺失会话不得从其他记录猜测")
    }

    suite("HostEventSource：未知宿主、重复字段、危险文本和超限输入 fail closed") {
        let workBuddy = HostEventSourceParser.parse(
            host: .workBuddy,
            data: Data(#"{"cwd":"/tmp/project","session_id":"abc"}"#.utf8))
        expect(
            workBuddy == .unavailable(reason: .unsupportedHost, partial: nil),
            "未校准的 WorkBuddy 字段不得被猜测兼容")

        let duplicate = HostEventSourceParser.parse(
            host: .codex,
            data: Data(#"{"cwd":"/tmp/one","cwd":"/tmp/two"}"#.utf8))
        expect(
            duplicate == .unavailable(reason: .duplicateField, partial: nil),
            "重复 allowlist 字段必须拒绝")

        let unsafe = HostEventSourceParser.parse(
            host: .codex,
            data: Data("{\"cwd\":\"/tmp/project\",\"session_id\":\"bad\u{202E}id\"}".utf8))
        expect(unsafe.source?.projectLabel == "project", "不安全会话字段不得抹掉已知项目")
        expect(unsafe.source?.sessionID == nil, "危险会话字段必须被清除")

        let oversized = HostEventSourceParser.parse(
            host: .codex,
            data: Data(repeating: 0x20, count: 64 * 1024 + 1))
        expect(
            oversized == .unavailable(reason: .oversized, partial: nil),
            "超过 64KiB 的来源包必须拒绝")

        let binding = HostCapabilityCatalog.binding(host: .codex, nativeEvent: "Stop")!
        let mismatchedNotice = HostEventNotice(
            receiverEpoch: UUID(),
            surface: .codex,
            bindingID: binding.id,
            installationID: UUID(),
            nativeEvent: binding.nativeEvent!,
            event: binding.event,
            occurredAt: Date(),
            source: HostEventSource(
                projectLabel: "project",
                sessionID: "session",
                completeness: .unknown))
        expect(
            !mismatchedNotice.isSemanticallyValid,
            "跨进程 notice 的来源完整度与字段不一致时必须拒绝")
    }
}
