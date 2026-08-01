import ClaudioCore
import Foundation

@MainActor
func runClaudeCodeHooksTransformSuites() {
    suite("Claude transform：显式 connect 清理旧 helper 路径 modern hooks，并保留第三方顺序") {
        let rootPath = "/Users/test/.claudio"
        let currentBinary = rootPath + "/bin/claudio"
        let staleBinary = rootPath + "/libexec/claudio"
        let staleID = UUID(uuidString: "61616161-1111-4111-8111-111111111111")!
        let requestedID = UUID(uuidString: "61616161-2222-4222-8222-222222222222")!
        var hooks: [String: Any] = [:]
        for binding in HostCapabilityCatalog.bindings(for: .claudeCode) {
            let stale = hostIntegrationHookCommand(
                host: .claudeCode,
                nativeEvent: binding.nativeEvent!,
                installationID: staleID,
                claudioBinaryPath: staleBinary)!
            hooks[binding.nativeEvent!] = [
                ["matcher": "before", "hooks": [["type": "command", "command": "echo before"]]],
                ["hooks": [["type": "command", "command": stale]]],
                ["matcher": "after", "hooks": [["type": "command", "command": "echo after"]]],
            ]
        }
        let original: [String: Any] = ["hooks": hooks, "opaque": ["keep": true]]

        guard case .success(let connected) = connectClaudeCodeHooks(
            root: original,
            claudioRoot: rootPath,
            claudioBinaryPath: currentBinary,
            installationID: requestedID)
        else {
            expect(false, "仅旧路径 modern fixture 必须可由显式 connect 修复")
            return
        }

        expect(connected.changed, "旧路径 modern 必须触发真实清理写入")
        expect(connected.removedCount == 4, "四条 stale modern 必须全部移除")
        expect(
            (connected.root["opaque"] as? [String: Any])?["keep"] as? Bool == true,
            "未知顶层数据必须保留")
        let connectedHooks = connected.root["hooks"] as? [String: Any]
        for binding in HostCapabilityCatalog.bindings(for: .claudeCode) {
            let groups = connectedHooks?[binding.nativeEvent!] as? [[String: Any]] ?? []
            expect(
                groups.compactMap { $0["matcher"] as? String } == ["before", "after"],
                "\(binding.nativeEvent!) 第三方 group 相对顺序必须保留")
            let owned = groups.flatMap(claudeTransformCommands).compactMap {
                matchedHostHookCommand(inHookCommand: $0, claudioRoot: rootPath)
            }.filter { $0.host == .claudeCode }
            expect(owned.count == 1, "\(binding.nativeEvent!) 修复后只能剩一个 Claudio modern hook")
            expect(
                owned.first
                    == MatchedHostHookCommand(
                        host: .claudeCode,
                        nativeEvent: binding.nativeEvent!,
                        event: binding.event,
                        installationID: requestedID),
                "\(binding.nativeEvent!) 必须指向当前 helper 与新 installation")
            expect(
                groups.flatMap(claudeTransformCommands).contains { command in
                    matchedCurrentHostHookCommand(
                        inHookCommand: command, claudioBinaryPath: currentBinary) != nil
                },
                "\(binding.nativeEvent!) 必须有当前 canonical command")
        }
    }

    suite("Claude transform：当前完整连接夹带 stale modern 时 connect 归一为每事件一个 canonical") {
        let rootPath = "/Users/test/.claudio"
        let currentBinary = rootPath + "/bin/claudio"
        let staleBinary = rootPath + "/libexec/claudio"
        let currentID = UUID(uuidString: "62626262-1111-4111-8111-111111111111")!
        let staleID = UUID(uuidString: "62626262-2222-4222-8222-222222222222")!
        guard case .success(let canonical) = connectClaudeCodeHooks(
            root: [:], claudioRoot: rootPath, claudioBinaryPath: currentBinary,
            installationID: currentID)
        else {
            expect(false, "测试前提：必须生成当前 canonical Claude 配置")
            return
        }
        var mixed = canonical.root
        var hooks = mixed["hooks"] as! [String: Any]
        var stopGroups = hooks["Stop"] as! [Any]
        let staleStop = hostIntegrationHookCommand(
            host: .claudeCode, nativeEvent: "Stop", installationID: staleID,
            claudioBinaryPath: staleBinary)!
        stopGroups.insert([
            "matcher": "stale-owned",
            "hooks": [["type": "command", "command": staleStop]],
        ], at: 0)
        hooks["Stop"] = stopGroups
        mixed["hooks"] = hooks

        guard case .success(let repaired) = connectClaudeCodeHooks(
            root: mixed, claudioRoot: rootPath, claudioBinaryPath: currentBinary,
            installationID: UUID())
        else {
            expect(false, "完整 current + stale fixture 必须可显式清理")
            return
        }
        expect(repaired.changed, "额外 stale callback 不能被 complete 状态掩盖成幂等零写")
        let repairedHooks = repaired.root["hooks"] as? [String: Any]
        for binding in HostCapabilityCatalog.bindings(for: .claudeCode) {
            let groups = repairedHooks?[binding.nativeEvent!] as? [[String: Any]] ?? []
            let commands = groups.flatMap(claudeTransformCommands)
            let owned = commands.compactMap {
                matchedHostHookCommand(inHookCommand: $0, claudioRoot: rootPath)
            }.filter { $0.host == .claudeCode }
            expect(owned.count == 1, "\(binding.nativeEvent!) 最终只能有一个 Claudio callback")
            expect(
                owned.first?.installationID == currentID,
                "清理额外 stale 时应保留健康 current installation ID")
            expect(
                commands.contains {
                    matchedCurrentHostHookCommand(
                        inHookCommand: $0, claudioBinaryPath: currentBinary) != nil
                },
                "\(binding.nativeEvent!) 最终命令必须精确指向 current helper")
        }
    }

    suite("Claude transform：legacy 只识别不静默升级，显式连接后四事件共用真实代次") {
        let rootPath = "/Users/test/.claudio"
        let binary = rootPath + "/bin/claudio"
        var hooks: [String: Any] = [:]
        for binding in HostCapabilityCatalog.bindings(for: .claudeCode) {
            hooks[binding.nativeEvent!] = [[
                "hooks": [[
                    "type": "command",
                    "command": claudioHookCommand(
                        for: binding.event, claudioBinaryPath: binary),
                ]]
            ]]
        }
        let legacyRoot: [String: Any] = ["hooks": hooks, "keep": "third-party"]
        expect(
            inspectClaudeCodeHooks(
                root: legacyRoot, claudioRoot: rootPath, claudioBinaryPath: binary)
                == .success(.legacyConnected),
            "完整旧 play hooks 必须只标 legacyConnected")

        let installationID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        guard case .success(let mutation) = connectClaudeCodeHooks(
            root: legacyRoot, claudioRoot: rootPath, claudioBinaryPath: binary,
            installationID: installationID)
        else {
            expect(false, "显式升级必须成功")
            return
        }
        expect(mutation.changed && mutation.removedCount == 4, "必须原位替换四条 legacy hook")
        expect((mutation.root["keep"] as? String) == "third-party", "未知顶层键必须保留")
        expect(
            inspectClaudeCodeHooks(
                root: mutation.root, claudioRoot: rootPath, claudioBinaryPath: binary)
                == .success(.configured(installationID: installationID)),
            "升级后必须是同一代次的完整现代连接")
        guard case .success(let repeated) = connectClaudeCodeHooks(
            root: mutation.root, claudioRoot: rootPath, claudioBinaryPath: binary,
            installationID: UUID())
        else {
            expect(false, "重复连接检查必须成功")
            return
        }
        expect(!repeated.changed, "已有完整现代连接不得因新随机 UUID 重复写入")
    }

    suite("Claude transform：第三方顺序和 UserPromptSubmit 保留，断开只删本宿主条目") {
        let rootPath = "/Users/test/.claudio"
        let binary = rootPath + "/bin/claudio"
        let id = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!
        let foreignGroup: [String: Any] = [
            "matcher": "third",
            "hooks": [["type": "command", "command": "echo foreign"]],
        ]
        let oldTaskStart: [Any] = [[
            "hooks": [[
                "type": "command",
                "command": claudioHookCommand(for: .notification, claudioBinaryPath: binary),
            ]]
        ]]
        let initial: [String: Any] = [
            "hooks": ["Stop": [foreignGroup], "UserPromptSubmit": oldTaskStart],
            "opaque": ["trust": true],
        ]
        guard case .success(let connected) = connectClaudeCodeHooks(
            root: initial, claudioRoot: rootPath, claudioBinaryPath: binary, installationID: id),
            case .success(let disconnected) = disconnectClaudeCodeHooks(
                root: connected.root, claudioRoot: rootPath)
        else {
            expect(false, "连接/断开必须成功")
            return
        }
        let hooks = disconnected.root["hooks"] as? [String: Any]
        let stop = hooks?["Stop"] as? [Any]
        expect(
            ((stop?.first as? [String: Any])?["matcher"] as? String) == "third",
            "Stop 第三方 group 与数组位置必须保留")
        expect((hooks?["UserPromptSubmit"] as? [Any])?.count == 1, "旧任务开始声音必须保留")
        expect((disconnected.root["opaque"] as? [String: Any])?["trust"] as? Bool == true,
            "不透明数据必须保留")
        expect(disconnected.removedCount == 4, "断开必须只删除四条现代 Claude hook")
        expect(
            inspectClaudeCodeHooks(
                root: disconnected.root, claudioRoot: rootPath, claudioBinaryPath: binary)
                == .success(.notConfigured),
            "正式四事件清除后应未连接；UserPromptSubmit 不计能力")
    }

    suite("Claude transform：部分安装、代次冲突、畸形 schema 全部诚实失败关闭") {
        let rootPath = "/Users/test/.claudio"
        let binary = rootPath + "/bin/claudio"
        let first = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let second = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
        let stop = hostIntegrationHookCommand(
            host: .claudeCode, nativeEvent: "Stop", installationID: first,
            claudioBinaryPath: binary)!
        let notification = hostIntegrationHookCommand(
            host: .claudeCode, nativeEvent: "Notification", installationID: second,
            claudioBinaryPath: binary)!
        let conflicted: [String: Any] = ["hooks": [
            "Stop": [["hooks": [["type": "command", "command": stop]]]],
            "Notification": [["hooks": [["type": "command", "command": notification]]]],
        ]]
        guard case .success(.conflict) = inspectClaudeCodeHooks(
            root: conflicted, claudioRoot: rootPath, claudioBinaryPath: binary)
        else {
            expect(false, "不同 installation ID 必须冲突")
            return
        }

        let malformed: [String: Any] = ["hooks": ["Stop": "not-an-array"]]
        expect(
            inspectClaudeCodeHooks(
                root: malformed, claudioRoot: rootPath, claudioBinaryPath: binary).isFailure,
            "畸形 target event 必须失败关闭")
        expect(
            connectClaudeCodeHooks(
                root: malformed, claudioRoot: rootPath, claudioBinaryPath: binary,
                installationID: first).isFailure,
            "畸形配置不得被 connect 覆盖")
    }
}

private func claudeTransformCommands(in group: [String: Any]) -> [String] {
    let hooks = group["hooks"] as? [[String: Any]] ?? []
    return hooks.compactMap { $0["command"] as? String }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
