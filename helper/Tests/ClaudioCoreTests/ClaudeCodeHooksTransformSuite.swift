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
        expect(connected.removedCount == 5, "五条 stale modern 必须全部移除")
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

    suite("Claude transform：legacy 四事件只识别不静默升级，显式连接后五事件共用真实代次") {
        let rootPath = "/Users/test/.claudio"
        let binary = rootPath + "/bin/claudio"
        var hooks: [String: Any] = [:]
        for event in Event.legacyLifecycleCases {
            let nativeEvent = HostCapabilityCatalog.binding(
                host: .claudeCode, event: event)!.nativeEvent!
            hooks[nativeEvent] = [[
                "hooks": [[
                    "type": "command",
                    "command": claudioHookCommand(
                        for: event, claudioBinaryPath: binary),
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

    suite("Claude transform：纯能力升级补 UserPromptSubmit 时沿用唯一 installation ID") {
        let rootPath = "/Users/test/.claudio"
        let binary = rootPath + "/bin/claudio"
        let originalID = UUID(uuidString: "12121212-1212-4212-8212-121212121212")!
        guard case .success(let full) = connectClaudeCodeHooks(
            root: [:], claudioRoot: rootPath, claudioBinaryPath: binary,
            installationID: originalID)
        else {
            expect(false, "测试前提：必须生成五事件配置")
            return
        }
        var oldModern = full.root
        var hooks = oldModern["hooks"] as! [String: Any]
        hooks.removeValue(forKey: "UserPromptSubmit")
        oldModern["hooks"] = hooks
        expect(
            inspectClaudeCodeHooks(
                root: oldModern, claudioRoot: rootPath, claudioBinaryPath: binary)
                == .success(
                    .partial(
                        installationID: originalID,
                        missingNativeEvents: ["UserPromptSubmit"], hasLegacyEntries: false)),
            "旧四条 modern 应被识别为纯能力缺口")
        guard case .success(let upgraded) = connectClaudeCodeHooks(
            root: oldModern, claudioRoot: rootPath, claudioBinaryPath: binary,
            installationID: UUID())
        else {
            expect(false, "纯能力升级必须成功")
            return
        }
        expect(
            inspectClaudeCodeHooks(
                root: upgraded.root, claudioRoot: rootPath, claudioBinaryPath: binary)
                == .success(.configured(installationID: originalID)),
            "补第五条时不得生成新 installation ID")
    }

    suite("Claude transform：升级删除旧 prompt 通知，断开保留第三方与非管理 legacy") {
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
        let promptThird: [String: Any] = [
            "matcher": "prompt-third",
            "hooks": [["type": "command", "command": "echo keep-prompt"]],
        ]
        let initial: [String: Any] = [
            "hooks": [
                "Stop": [foreignGroup],
                "UserPromptSubmit": oldTaskStart + [promptThird],
            ],
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
        let promptGroups = hooks?["UserPromptSubmit"] as? [[String: Any]] ?? []
        expect(
            promptGroups.flatMap(claudeTransformCommands) == ["echo keep-prompt"],
            "显式升级必须删除当前 root 的旧 play notification；第三方条目与顺序保留")
        expect((disconnected.root["opaque"] as? [String: Any])?["trust"] as? Bool == true,
            "不透明数据必须保留")
        expect(disconnected.removedCount == 5, "断开必须只删除五条现代 Claude hook")
        expect(
            inspectClaudeCodeHooks(
                root: disconnected.root, claudioRoot: rootPath, claudioBinaryPath: binary)
                == .success(.notConfigured),
            "五条现代事件清除后应未连接；第三方 prompt 不计能力")
    }

    suite("Claude transform：所有事件都扫描 modern callback，但非正式事件中的 legacy 仍保留") {
        let rootPath = "/Users/test/.claudio"
        let binary = rootPath + "/bin/claudio"
        let currentID = UUID(uuidString: "BBBBBBBB-1111-4111-8111-111111111111")!
        let repairID = UUID(uuidString: "BBBBBBBB-2222-4222-8222-222222222222")!
        guard case .success(let canonical) = connectClaudeCodeHooks(
            root: [:], claudioRoot: rootPath, claudioBinaryPath: binary,
            installationID: currentID)
        else {
            expect(false, "测试前提：必须先生成完整 Claude modern 配置")
            return
        }

        let misplacedStop = hostIntegrationHookCommand(
            host: .claudeCode,
            nativeEvent: "Stop",
            installationID: currentID,
            claudioBinaryPath: binary)!
        let legacyPrompt = claudioHookCommand(
            for: .notification, claudioBinaryPath: binary)
        var mixed = canonical.root
        var hooks = mixed["hooks"] as! [String: Any]
        hooks["SessionStart"] = [[
            "matcher": "session-third",
            "hooks": [
                ["type": "command", "command": misplacedStop],
                ["type": "command", "command": "echo keep-session"],
            ],
        ]]
        hooks["UserPromptSubmit"] = [[
            "matcher": "prompt-third",
            "hooks": [
                ["type": "command", "command": legacyPrompt],
                ["type": "command", "command": misplacedStop],
                ["type": "command", "command": "echo keep-prompt"],
            ],
        ]]
        mixed["hooks"] = hooks

        guard case .success(.conflict(let reason)) = inspectClaudeCodeHooks(
            root: mixed, claudioRoot: rootPath, claudioBinaryPath: binary)
        else {
            expect(false, "非正式事件中的 modern Stop 不能被完整五事件掩盖成 configured")
            return
        }
        expect(reason.contains("事件位置"), "错位 modern callback 必须给出可诊断原因，got \(reason)")

        guard case .success(let repaired) = connectClaudeCodeHooks(
            root: mixed, claudioRoot: rootPath, claudioBinaryPath: binary,
            installationID: repairID)
        else {
            expect(false, "显式 connect 必须能清扫非正式事件中的 modern callback")
            return
        }
        expect(repaired.changed, "额外 modern callback 必须阻止幂等 no-op")
        expect(repaired.removedCount == 7, "四条仍在的 canonical、两条错位 modern 与旧 prompt 必须清理")
        expect(
            inspectClaudeCodeHooks(
                root: repaired.root, claudioRoot: rootPath, claudioBinaryPath: binary)
                == .success(.configured(installationID: repairID)),
            "清扫后必须形成唯一 repair installation")
        let repairedHooks = repaired.root["hooks"] as? [String: Any]
        let repairedSession = repairedHooks?["SessionStart"] as? [[String: Any]] ?? []
        expect(
            repairedSession.flatMap(claudeTransformCommands) == ["echo keep-session"],
            "SessionStart 第三方 command 与 group 必须保留")
        let repairedPrompt = repairedHooks?["UserPromptSubmit"] as? [[String: Any]] ?? []
        let repairedPromptCommands = repairedPrompt.flatMap(claudeTransformCommands)
        expect(repairedPromptCommands.first == "echo keep-prompt", "第三方 prompt command 必须保留首位")
        expect(
            !repairedPromptCommands.contains(legacyPrompt)
                && repairedPromptCommands.compactMap {
                    matchedCurrentHostHookCommand(
                        inHookCommand: $0, claudioBinaryPath: binary)
                }.count == 1,
            "显式 repair 必须删除旧 play notification 并补一个 canonical taskStart")

        guard case .success(let disconnected) = disconnectClaudeCodeHooks(
            root: mixed, claudioRoot: rootPath)
        else {
            expect(false, "disconnect 必须能从所有事件清扫 modern callback")
            return
        }
        expect(disconnected.changed, "非正式事件的 modern callback 必须触发断开写入")
        expect(disconnected.removedCount == 6, "disconnect 必须移除正式及非正式的全部 modern")
        let disconnectedHooks = disconnected.root["hooks"] as? [String: Any]
        let disconnectedSession = disconnectedHooks?["SessionStart"] as? [[String: Any]] ?? []
        expect(
            disconnectedSession.flatMap(claudeTransformCommands) == ["echo keep-session"],
            "disconnect 必须保留 SessionStart 第三方 command")
        let disconnectedPrompt = disconnectedHooks?["UserPromptSubmit"] as? [[String: Any]] ?? []
        expect(
            disconnectedPrompt.flatMap(claudeTransformCommands) == [legacyPrompt, "echo keep-prompt"],
            "disconnect 必须保留非正式事件中的 legacy play 与第三方 command")
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
