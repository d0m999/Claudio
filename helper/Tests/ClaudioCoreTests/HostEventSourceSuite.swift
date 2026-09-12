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
        expect(
            source.sessionLabel == nil,
            "默认短会话标签由 GUI 侧本地化投影，helper 不得随 IPC 发送硬编码语言")
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
                && folded.source?.sessionID == nil,
            "项目标签可以折叠空白；会话 ID 必须保留原身份，控制字符导致独立降级")

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

    suite("HostEventInput：白名单原因与来源独立降级且不猜测正文") {
        let cases: [(String, HostEventNoticeReason)] = [
            ("permission_prompt", .permission),
            ("elicitation_dialog", .needsInput),
            ("elicitation_url_dialog", .needsInput),
            ("agent_needs_input", .needsInput),
            ("idle_prompt", .informational),
            ("auth_success", .informational),
            ("elicitation_complete", .informational),
            ("elicitation_response", .informational),
            ("agent_completed", .informational),
            ("quota_auto_resume_fired", .informational),
            ("future_reason", .review),
            ("Permission_prompt", .review),
        ]
        for (raw, expected) in cases {
            let data = try! JSONSerialization.data(withJSONObject: [
                "cwd": "/private-sentinel/project", "session_id": "session-1",
                "hook_event_name": "Notification", "notification_type": raw,
                "title": "SECRET_TITLE_permission_prompt",
                "message": "SECRET_MESSAGE_needs_input",
                "transcript_path": "/SECRET_TRANSCRIPT/path",
            ])
            let parsed = HostEventSourceParser.parseInput(
                host: .claudeCode, nativeEvent: "Notification", data: data)
            expect(parsed.reason == expected, "\(raw) 必须按通知类型分类")
            expect(parsed.source.source?.mainSessionIsKnown == true, "匹配的完整主会话可归并")
            let text = String(
                data: try! JSONEncoder().encode(parsed.source.source), encoding: .utf8)!
            expect(!text.contains("SECRET_") && !text.contains("private-sentinel"), "私密内容不得进入来源投影")
        }
        for raw in [
            #"{"cwd":"/tmp/project","session_id":"s","notification_type":42}"#,
            #"{"cwd":"/tmp/project","session_id":"s","notification_type":null}"#,
            #"{"cwd":"/tmp/project","session_id":"s","message":"permission_prompt"}"#,
            #"{"cwd":"/tmp/project","notification_type":"permission_prompt","notification_type":"idle_prompt"}"#,
        ] {
            let parsed = HostEventSourceParser.parseInput(
                host: .claudeCode, nativeEvent: "Notification", data: Data(raw.utf8))
            expect(parsed.reason == .review, "缺失、损坏、重复原因必须待查看")
            expect(parsed.source.source?.projectLabel == "project", "原因损坏不抹除安全来源")
        }
        for raw in [
            #"{"cwd":42,"notification_type":"permission_prompt"}"#,
            #"{"session_id":42,"notification_type":"permission_prompt"}"#,
            #"{"cwd":"/tmp/a","cwd":"/tmp/b","notification_type":"permission_prompt"}"#,
        ] {
            let parsed = HostEventSourceParser.parseInput(
                host: .claudeCode, nativeEvent: "Notification", data: Data(raw.utf8))
            expect(parsed.reason == .permission, "来源损坏不能抹掉明确原因")
        }
        for payload in [
            nil, Data("broken".utf8), Data(#"{"notification_type":"idle_prompt"}"#.utf8),
        ] {
            expect(
                HostEventSourceParser.parseInput(
                    host: .codex, nativeEvent: "PermissionRequest", data: payload
                ).reason == .permission,
                "已实现 Codex PermissionRequest 由 binding 强制归为授权")
        }
        expect(
            HostEventSourceParser.parseInput(
                host: .workBuddy, nativeEvent: "Notification", data: nil
            ).reason == nil,
            "不得升级 WorkBuddy 未实现 binding")
        expect(
            HostEventSourceParser.parseInput(host: .codex, nativeEvent: "StopFailure", data: nil)
                .reason == nil,
            "不存在的 Codex binding 不得产生关注能力")
        expect(
            HostEventSourceParser.parseInput(
                host: .claudeCode, nativeEvent: "Stop",
                data: Data(#"{"notification_type":"permission_prompt"}"#.utf8)
            ).reason == nil,
            "Stop 不因输入通知类型升级为授权")
    }

    suite("HostEventInput：身份不截断，parent 标记缺失或损坏不能变为主会话") {
        for session in [String(repeating: "a", count: 257), "a b", "a\nb", "a\tb", "a\u{202E}b"] {
            let data = try! JSONSerialization.data(withJSONObject: [
                "cwd": "/tmp/project", "session_id": session, "hook_event_name": "Notification",
            ])
            let source = HostEventSourceParser.parseInput(
                host: .claudeCode, nativeEvent: "Notification", data: data
            ).source.source
            expect(
                source?.projectLabel == "project" && source?.sessionID == nil, "不合法 ID 独立清除，保留项目")
        }
        for raw in [
            #"{"cwd":"/tmp/project","session_id":"s","agent_id":42}"#,
            #"{"cwd":"/tmp/project","session_id":"s","agent_id":""}"#,
            #"{"cwd":"/tmp/project","session_id":"s","is_subagent":1}"#,
            #"{"cwd":"/tmp/project","session_id":"s","subagent":"false"}"#,
            #"{"cwd":"/tmp/project","session_id":"s","hook_event_name":"Stop"}"#,
        ] {
            let source = HostEventSourceParser.parseInput(
                host: .claudeCode, nativeEvent: "Notification", data: Data(raw.utf8)
            ).source.source
            expect(
                source?.projectLabel == "project" && source?.sessionID == nil,
                "损坏或不匹配 parent 语义不得生成会话目标")
            expect(source?.mainSessionIsKnown != true, "损坏 parent 语义不得归并")
        }
        let missing = HostEventSourceParser.parseInput(
            host: .codex, nativeEvent: "PermissionRequest",
            data: Data(#"{"cwd":"/tmp/project","session_id":"s"}"#.utf8)
        ).source.source
        expect(
            missing?.sessionID == "s" && missing?.mainSessionIsKnown == nil,
            "缺失 native event 合同仍可复制已知 ID，但不得归并")
        let child = HostEventSourceParser.parseInput(
            host: .codex, nativeEvent: "SubagentStop",
            data: Data(
                #"{"cwd":"/tmp/project","session_id":"s","hook_event_name":"SubagentStop"}"#.utf8)
        ).source.source
        expect(
            child?.isParentSession == true && child?.mainSessionIsKnown != true,
            "SubagentStop 缺少 agent_id 仍是父会话投影")
    }

    suite("HostEventNotice：schema 1 新旧双向兼容且未来字段独立降级") {
        let binding = HostCapabilityCatalog.binding(host: .claudeCode, nativeEvent: "Notification")!
        let notice = HostEventNotice(
            receiverEpoch: UUID(), surface: .claudeCode, bindingID: binding.id,
            installationID: UUID(), nativeEvent: "Notification", event: .notification,
            occurredAt: Date(),
            source: HostEventSource(
                projectLabel: "project", projectKey: "key", sessionID: "s", mainSessionIsKnown: true
            ),
            reason: .needsInput, observedUptime: 123)
        let data = try! JSONEncoder().encode(notice)
        let old = try? JSONDecoder().decode(LegacyEventNotice.self, from: data)
        expect(old?.schema == 1 && old?.source?.sessionID == "s", "旧 schema 1 decoder 忽略新可选字段")
        var object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "reason")
        object.removeValue(forKey: "observed_uptime")
        var source = object["source"] as! [String: Any]
        source.removeValue(forKey: "main_session_is_known")
        object["source"] = source
        let legacyData = try! JSONSerialization.data(withJSONObject: object)
        let new = try! JSONDecoder().decode(HostEventNotice.self, from: legacyData)
        expect(
            new.reason == nil && new.observedUptime == nil && new.source?.mainSessionIsKnown == nil,
            "新 decoder 兼容旧消息且不会补造主会话身份")
        for futureReason in ["future_reason" as Any, 42, ["private"]] {
            object["reason"] = futureReason
            object["observed_uptime"] = "bad"
            source["main_session_is_known"] = "bad"
            object["source"] = source
            let modified = try! JSONSerialization.data(withJSONObject: object)
            let parsed = try? JSONDecoder().decode(HostEventNotice.self, from: modified)
            expect(
                parsed?.isSemanticallyValid == true && parsed?.source?.sessionID == "s",
                "未知或损坏可选字段不能丢弃安全来源消息")
            expect(
                parsed?.reason == nil && parsed?.observedUptime == nil
                    && parsed?.source?.mainSessionIsKnown == nil, "未来原因及非法观察时间独立降级")
        }
    }

}

// Frozen schema-1 consumer shape: no reason, observation, or main-session evidence fields.
private struct LegacyEventNotice: Decodable {
    let schema: Int
    let id: UUID
    let receiverEpoch: UUID
    let surface: HostSurfaceID
    let bindingID: HostEventBindingID
    let installationID: UUID
    let nativeEvent: String
    let event: Event
    let occurredAt: Date
    let source: LegacyEventSource?
    let sourceCompleteness: HostEventSourceCompleteness

    enum CodingKeys: String, CodingKey {
        case schema, surface, event, source
        case id = "event_id"
        case receiverEpoch = "receiver_epoch"
        case bindingID = "binding_id"
        case installationID = "installation_id"
        case nativeEvent = "native_event"
        case occurredAt = "occurred_at"
        case sourceCompleteness = "source_completeness"
    }
}

private struct LegacyEventSource: Decodable {
    let projectLabel: String?
    let projectKey: String?
    let sessionID: String?
    let sessionLabel: String?
    let isParentSession: Bool
    let completeness: HostEventSourceCompleteness

    enum CodingKeys: String, CodingKey {
        case projectLabel = "project_label"
        case projectKey = "project_key"
        case sessionID = "session_id"
        case sessionLabel = "session_label"
        case isParentSession = "is_parent_session"
        case completeness
    }
}
