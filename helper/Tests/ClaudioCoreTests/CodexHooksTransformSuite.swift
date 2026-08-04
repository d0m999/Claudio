import ClaudioCore
import Foundation

private let codexTransformRoot = "/Users/tester/.claudio"
private let codexTransformBinary = "\(codexTransformRoot)/bin/claudio"
private let codexTransformID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
private let codexOtherID = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!
private let codexNativeEvents = ["UserPromptSubmit", "Stop", "PermissionRequest", "SubagentStop"]

@MainActor
private func codexFixtureData(_ source: String) -> Data {
    withTempDirectory { root in
        let file = root.appendingPathComponent("hooks.json")
        writeFixture(source, to: file)
        return (try? Data(contentsOf: file)) ?? Data()
    }
}

private func codexJSONObject(_ data: Data?) -> [String: Any]? {
    guard let data,
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object
}

private func codexEventGroups(_ object: [String: Any]?, _ event: String) -> [[String: Any]] {
    guard let hooks = object?["hooks"] as? [String: Any],
        let groups = hooks[event] as? [[String: Any]]
    else { return [] }
    return groups
}

private func codexInnerHooks(_ group: [String: Any]) -> [[String: Any]] {
    group["hooks"] as? [[String: Any]] ?? []
}

private func codexCommands(_ groups: [[String: Any]]) -> [String] {
    groups.flatMap(codexInnerHooks).compactMap { $0["command"] as? String }
}

private func codexJSONValue(_ object: [String: Any]?, key: String) -> Any? {
    object?[key]
}

private func codexJSONEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    return (lhs as AnyObject).isEqual(rhs)
}

@MainActor
func runCodexHooksTransformSuites() {
    suite("Codex hooks connect：清理仅旧 helper 路径 modern hooks，并保留第三方数组顺序") {
        let staleBinary = "\(codexTransformRoot)/libexec/claudio"
        var hooks: [String: Any] = [:]
        for event in codexNativeEvents {
            let stale = hostIntegrationHookCommand(
                host: .codex,
                nativeEvent: event,
                installationID: codexOtherID,
                claudioBinaryPath: staleBinary)!
            hooks[event] = [
                ["matcher": "before", "hooks": [["type": "command", "command": "echo before"]]],
                ["hooks": [["type": "command", "command": stale]]],
                ["matcher": "after", "hooks": [["type": "command", "command": "echo after"]]],
            ]
        }
        let originalObject: [String: Any] = [
            "notify": ["keep-notifier"],
            "trust": ["opaque": true],
            "hooks": hooks,
        ]
        let original = try! JSONSerialization.data(
            withJSONObject: originalObject, options: [.prettyPrinted, .sortedKeys])

        let repaired = CodexHooksTransform.connect(
            original,
            installationID: codexTransformID,
            claudioBinaryPath: codexTransformBinary,
            claudioRoot: codexTransformRoot)

        expect(repaired.changed, "仅 stale modern 必须触发清理与 canonical 写入")
        expect(repaired.removedCount == 4, "四条旧路径 Codex callback 必须全部被清理")
        expect(
            repaired.status == .complete(installationID: codexTransformID),
            "修复后必须形成调用方请求的 current installation")
        let object = codexJSONObject(repaired.data)
        expect(codexJSONEqual(object?["notify"], originalObject["notify"]), "notify 必须保留")
        expect(codexJSONEqual(object?["trust"], originalObject["trust"]), "trust 必须保留")
        for event in codexNativeEvents {
            let groups = codexEventGroups(object, event)
            expect(
                groups.compactMap { $0["matcher"] as? String } == ["before", "after"],
                "\(event) 第三方 group 相对顺序必须保留")
            let commands = codexCommands(groups)
            let owned = commands.compactMap {
                matchedHostHookCommand(inHookCommand: $0, claudioRoot: codexTransformRoot)
            }.filter { $0.host == .codex }
            expect(owned.count == 1, "\(event) 修复后只能剩一个 Codex callback")
            expect(
                commands.contains {
                    matchedCurrentHostHookCommand(
                        inHookCommand: $0, claudioBinaryPath: codexTransformBinary) != nil
                },
                "\(event) 最终必须精确指向 current helper")
        }
    }

    suite("Codex hooks connect：当前完整连接夹带 stale modern 时归一为每事件一个 canonical") {
        let staleBinary = "\(codexTransformRoot)/libexec/claudio"
        let canonical = CodexHooksTransform.connect(
            nil,
            installationID: codexTransformID,
            claudioBinaryPath: codexTransformBinary,
            claudioRoot: codexTransformRoot)
        guard var mixed = codexJSONObject(canonical.data) else {
            expect(false, "测试前提：必须生成完整 current Codex 配置")
            return
        }
        var hooks = mixed["hooks"] as! [String: Any]
        var stopGroups = hooks["Stop"] as! [Any]
        let staleStop = hostIntegrationHookCommand(
            host: .codex,
            nativeEvent: "Stop",
            installationID: codexOtherID,
            claudioBinaryPath: staleBinary)!
        stopGroups.insert([
            "matcher": "stale-owned",
            "hooks": [["type": "command", "command": staleStop]],
        ], at: 0)
        hooks["Stop"] = stopGroups
        mixed["hooks"] = hooks
        let mixedData = try! JSONSerialization.data(
            withJSONObject: mixed, options: [.prettyPrinted, .sortedKeys])

        let repaired = CodexHooksTransform.connect(
            mixedData,
            installationID: codexOtherID,
            claudioBinaryPath: codexTransformBinary,
            claudioRoot: codexTransformRoot)

        expect(repaired.changed, "complete 状态旁的 stale callback 不能被幂等分支掩盖")
        expect(repaired.removedCount >= 1, "修复结果必须报告至少清理一条 stale callback")
        expect(
            repaired.status == .complete(installationID: codexTransformID),
            "清理额外 stale 时必须保留健康 current installation ID")
        let object = codexJSONObject(repaired.data)
        for event in codexNativeEvents {
            let commands = codexCommands(codexEventGroups(object, event))
            let owned = commands.compactMap {
                matchedHostHookCommand(inHookCommand: $0, claudioRoot: codexTransformRoot)
            }.filter { $0.host == .codex }
            expect(owned.count == 1, "\(event) 最终只能有一个 Codex callback")
            expect(owned.first?.installationID == codexTransformID, "\(event) 必须保留 current ID")
            expect(
                commands.contains {
                    matchedCurrentHostHookCommand(
                        inHookCommand: $0, claudioBinaryPath: codexTransformBinary) != nil
                },
                "\(event) 最终命令必须精确指向 current helper")
        }
    }

    suite("Codex hooks connect：旧 helper relocated command 位于错误事件时失败关闭且零写入") {
        let staleBinary = "\(codexTransformRoot)/libexec/claudio"
        let misplacedStop = hostIntegrationHookCommand(
            host: .codex,
            nativeEvent: "Stop",
            installationID: codexOtherID,
            claudioBinaryPath: staleBinary)!
        let original = codexFixtureData(
            #"{"notify":"keep","hooks":{"PermissionRequest":[{"matcher":"third","hooks":[{"type":"command","command":"echo keep"},{"type":"command","command":"\#(misplacedStop)"}]}]}}"#)

        let result = CodexHooksTransform.connect(
            original,
            installationID: codexTransformID,
            claudioBinaryPath: codexTransformBinary,
            claudioRoot: codexTransformRoot)

        expect(!result.changed, "错位 relocated 自有 callback 必须失败关闭，不能边保留边补 canonical")
        expect(result.data == original, "错位 relocated callback 检测后必须逐字节零写入")
        guard case .malformed(let reason) = result.status else {
            expect(false, "错位 relocated callback 必须返回可诊断 malformed，got \(result.status)")
            return
        }
        expect(
            reason.contains("旧 helper") && reason.contains("错误事件")
                && reason.contains("PermissionRequest"),
            "错误必须指出 relocated 与实际落点，got \(reason)")
    }

    suite("Codex hooks connect：全新配置只新增四个真实事件并保留顶层未知配置") {
        let original = codexFixtureData(
            #"{"notify":["third-party"],"trust":{"opaque":"keep"},"theme":"night"}"#)
        let result = CodexHooksTransform.connect(
            original,
            installationID: codexTransformID,
            claudioBinaryPath: codexTransformBinary,
            claudioRoot: codexTransformRoot)

        expect(result.changed, "全新 Codex 配置必须新增 Claudio hooks")
        expect(result.removedCount == 0, "connect 不得报告移除")
        expect(
            result.status == .complete(installationID: codexTransformID),
            "四条 hook 必须使用同一 installation ID，got \(result.status)")

        let object = codexJSONObject(result.data)
        let originalObject = codexJSONObject(original)
        for key in ["notify", "trust", "theme"] {
            expect(
                codexJSONEqual(
                    codexJSONValue(object, key: key), codexJSONValue(originalObject, key: key)),
                "connect 必须保留顶层 \(key)")
        }

        let expectedEvents = codexNativeEvents
        let hooks = object?["hooks"] as? [String: Any]
        let actualEventNames = hooks?.keys.map { $0 } ?? []
        expect(
            Set(actualEventNames) == Set(expectedEvents),
            "Codex 只能安装四种真实事件，got \(actualEventNames.sorted())")
        expect(hooks?["StopFailure"] == nil, "Codex 不得伪造 StopFailure")

        for event in expectedEvents {
            let commands = codexCommands(codexEventGroups(object, event))
            let expected = hostIntegrationHookCommand(
                host: .codex, nativeEvent: event, installationID: codexTransformID,
                claudioBinaryPath: codexTransformBinary)
            expect(commands == [expected].compactMap { $0 }, "\(event) 必须写 canonical command")
            expect(
                commands.first.flatMap {
                    matchedHostHookCommand(inHookCommand: $0, claudioRoot: codexTransformRoot)
                }?.host == .codex,
                "\(event) command 必须能由共享 matcher 识别")
        }
    }

    suite("Codex hooks inspect：区分 absent、partial、complete、UUID 冲突与错位命令") {
        expect(
            CodexHooksTransform.inspect(
                nil,
                claudioRoot: codexTransformRoot,
                claudioBinaryPath: codexTransformBinary) == .absent,
            "缺失 hooks.json 必须是 absent")
        expect(
            CodexHooksTransform.inspect(
                codexFixtureData(
                    #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"third-party"}]}]}}"#),
                claudioRoot: codexTransformRoot,
                claudioBinaryPath: codexTransformBinary) == .absent,
            "只有第三方 hook 必须是 absent")

        let stop = hostIntegrationHookCommand(
            host: .codex, nativeEvent: "Stop", installationID: codexTransformID,
            claudioBinaryPath: codexTransformBinary)!
        let permission = hostIntegrationHookCommand(
            host: .codex, nativeEvent: "PermissionRequest", installationID: codexTransformID,
            claudioBinaryPath: codexTransformBinary)!
        let subagent = hostIntegrationHookCommand(
            host: .codex, nativeEvent: "SubagentStop", installationID: codexTransformID,
            claudioBinaryPath: codexTransformBinary)!
        let prompt = hostIntegrationHookCommand(
            host: .codex, nativeEvent: "UserPromptSubmit", installationID: codexTransformID,
            claudioBinaryPath: codexTransformBinary)!
        let partial = codexFixtureData(
            #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\#(stop)"}]}]}}"#)
        expect(
            CodexHooksTransform.inspect(
                partial,
                claudioRoot: codexTransformRoot,
                claudioBinaryPath: codexTransformBinary)
                == .partial(
                    installationID: codexTransformID,
                    missingNativeEvents: ["UserPromptSubmit", "PermissionRequest", "SubagentStop"]),
            "单条 Stop 必须报告有序缺口")

        let complete = codexFixtureData(
            #"{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"\#(prompt)"}]}],"Stop":[{"hooks":[{"type":"command","command":"\#(stop)"}]}],"PermissionRequest":[{"hooks":[{"type":"command","command":"\#(permission)"}]}],"SubagentStop":[{"hooks":[{"type":"command","command":"\#(subagent)"}]}]}}"#
        )
        expect(
            CodexHooksTransform.inspect(
                complete,
                claudioRoot: codexTransformRoot,
                claudioBinaryPath: codexTransformBinary)
                == .complete(installationID: codexTransformID),
            "四条同代次 hook 必须 complete")

        let conflictingPermission = hostIntegrationHookCommand(
            host: .codex, nativeEvent: "PermissionRequest", installationID: codexOtherID,
            claudioBinaryPath: codexTransformBinary)!
        let conflict = codexFixtureData(
            #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\#(stop)"}]}],"PermissionRequest":[{"hooks":[{"type":"command","command":"\#(conflictingPermission)"}]}]}}"#
        )
        expect(
            CodexHooksTransform.inspect(
                conflict,
                claudioRoot: codexTransformRoot,
                claudioBinaryPath: codexTransformBinary)
                == .conflictingInstallationIDs(
                    [codexTransformID, codexOtherID].sorted { $0.uuidString < $1.uuidString }),
            "同一配置出现不同 UUID 必须显式 conflict")
        let conflictConnect = CodexHooksTransform.connect(
            conflict,
            installationID: codexTransformID,
            claudioBinaryPath: codexTransformBinary,
            claudioRoot: codexTransformRoot)
        expect(!conflictConnect.changed, "UUID conflict 时 connect 必须失败关闭")
        expect(conflictConnect.data == conflict, "UUID conflict 不得重写原字节")
        expect(
            conflictConnect.status
                == .conflictingInstallationIDs(
                    [codexTransformID, codexOtherID].sorted { $0.uuidString < $1.uuidString }),
            "connect 必须把 UUID conflict 返回 adapter")

        let misplaced = codexFixtureData(
            #"{"hooks":{"PermissionRequest":[{"hooks":[{"type":"command","command":"\#(stop)"}]}]}}"#
        )
        if case .malformed(let reason) = CodexHooksTransform.inspect(
            misplaced,
            claudioRoot: codexTransformRoot,
            claudioBinaryPath: codexTransformBinary)
        {
            expect(reason.contains("错误事件"), "错位命令原因必须可执行，got \(reason)")
        } else {
            expect(false, "Claudio Stop 命令放在 PermissionRequest 下必须 fail closed")
        }
    }

    suite("Codex hooks connect：部分安装沿用原 UUID，补齐时不改第三方数组顺序，重复连接零字节变化") {
        let stop = hostIntegrationHookCommand(
            host: .codex, nativeEvent: "Stop", installationID: codexTransformID,
            claudioBinaryPath: codexTransformBinary)!
        let partial = codexFixtureData(
            #"{"notify":"keep-notifier","trust":{"hash":"opaque"},"hooks":{"Stop":[{"matcher":"turn","vendor":"keep","hooks":[{"type":"command","command":"third-a"},{"type":"command","command":"\#(stop)"},{"type":"prompt","payload":{"unknown":true}}]}],"PermissionRequest":[{"matcher":"permission","hooks":[{"type":"command","command":"third-permission"}]}],"AfterTool":[{"matcher":"*","hooks":[{"type":"command","command":"third-after"}]}]}}"#
        )

        let connected = CodexHooksTransform.connect(
            partial,
            installationID: codexOtherID,
            claudioBinaryPath: codexTransformBinary,
            claudioRoot: codexTransformRoot)
        expect(connected.changed, "partial 必须补齐")
        expect(
            connected.status == .complete(installationID: codexTransformID),
            "补齐必须沿用已有 installation ID，不能混入调用方新 UUID")

        let object = codexJSONObject(connected.data)
        let stopGroups = codexEventGroups(object, "Stop")
        expect(stopGroups.count == 1, "已有 Stop group 不得被拆分或重复追加")
        expect(stopGroups.first?["matcher"] as? String == "turn", "matcher 必须保留")
        expect(stopGroups.first?["vendor"] as? String == "keep", "group 未知键必须保留")
        expect(
            codexCommands(stopGroups) == ["third-a", stop],
            "Stop command hook 顺序必须保留")
        let stopInnerHooks = stopGroups.first.map(codexInnerHooks) ?? []
        expect(stopInnerHooks.count == 3, "Stop 非 command hook 不能被删")
        expect(
            codexJSONEqual(stopInnerHooks.last?["payload"], ["unknown": true]),
            "Stop 非 command hook 的未知 payload 必须保留")

        let permissionGroups = codexEventGroups(object, "PermissionRequest")
        expect(permissionGroups.count == 2, "已有第三方 PermissionRequest group 后应追加 Claudio group")
        expect(
            codexCommands(permissionGroups).first == "third-permission",
            "第三方 PermissionRequest group 必须保持首位")
        expect(codexEventGroups(object, "SubagentStop").count == 1, "缺失事件必须补一组")
        expect(codexEventGroups(object, "UserPromptSubmit").count == 1, "任务开始必须补一组")
        expect(codexEventGroups(object, "AfterTool").count == 1, "无关事件必须原样保留")

        let repeated = CodexHooksTransform.connect(
            connected.data,
            installationID: codexOtherID,
            claudioBinaryPath: codexTransformBinary,
            claudioRoot: codexTransformRoot)
        expect(!repeated.changed, "complete 配置重复 connect 必须 no-op")
        expect(repeated.data == connected.data, "no-op 必须返回输入原字节，不能重排 JSON")
        expect(repeated.status == connected.status, "no-op 状态必须稳定")
    }

    suite("Codex hooks upgrade：只删除当前 root 的旧提示词通知，保留第三方、look-alike、空 group 与顺序") {
        let canonical = CodexHooksTransform.connect(
            nil,
            installationID: codexTransformID,
            claudioBinaryPath: codexTransformBinary,
            claudioRoot: codexTransformRoot)
        guard var object = codexJSONObject(canonical.data),
            var hooks = object["hooks"] as? [String: Any],
            let canonicalPromptGroup = (hooks["UserPromptSubmit"] as? [Any])?.first,
            let canonicalPrompt = codexCommands(
                codexEventGroups(object, "UserPromptSubmit")).first
        else {
            expect(false, "测试前提：必须先生成一条 canonical UserPromptSubmit")
            return
        }

        let legacyNotification = claudioHookCommand(
            for: .notification, claudioBinaryPath: codexTransformBinary)
        let legacyStop = claudioHookCommand(
            for: .stop, claudioBinaryPath: codexTransformBinary)
        let foreignNotification = "/Users/other/.claudio/bin/claudio play notification"
        let lookAlike = "\(legacyNotification) --extra"
        hooks["UserPromptSubmit"] = [
            ["matcher": "empty-third-party", "hooks": []],
            [
                "matcher": "shared",
                "hooks": [
                    ["type": "command", "command": "third-before"],
                    ["type": "command", "command": legacyNotification],
                    ["type": "command", "command": foreignNotification],
                    ["type": "command", "command": lookAlike],
                    ["type": "command", "command": legacyStop],
                    ["type": "command", "command": "third-after"],
                ],
            ],
            canonicalPromptGroup,
            [
                "matcher": "legacy-only",
                "hooks": [["type": "command", "command": legacyNotification]],
            ],
        ]
        object["hooks"] = hooks
        let mixed = try! JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])

        let upgraded = CodexHooksTransform.connect(
            mixed,
            installationID: codexOtherID,
            claudioBinaryPath: codexTransformBinary,
            claudioRoot: codexTransformRoot)
        expect(upgraded.changed, "完整 modern 夹带旧 prompt notification 仍必须显式升级")
        expect(upgraded.removedCount == 2, "两条精确旧 prompt notification 必须被清理")
        expect(
            upgraded.status == .complete(installationID: codexTransformID),
            "纯清理升级必须保留唯一现有 installation ID")

        let upgradedObject = codexJSONObject(upgraded.data)
        let promptGroups = codexEventGroups(upgradedObject, "UserPromptSubmit")
        expect(
            promptGroups.compactMap { $0["matcher"] as? String }
                == ["empty-third-party", "shared"],
            "空 group、共享 group 与相对顺序必须保留；仅旧命令独占 group 应删除")
        expect(
            codexCommands(promptGroups)
                == [
                    "third-before", foreignNotification, lookAlike, legacyStop, "third-after",
                    canonicalPrompt,
                ],
            "第三方、其它用户路径、look-alike、其它 legacy 事件与 canonical 顺序必须逐项保留")

        let repeated = CodexHooksTransform.connect(
            upgraded.data,
            installationID: codexOtherID,
            claudioBinaryPath: codexTransformBinary,
            claudioRoot: codexTransformRoot)
        expect(!repeated.changed, "清理后的完整 Codex 配置重复 connect 必须 no-op")
        expect(repeated.data == upgraded.data, "重复 connect 必须逐字节不改")
    }

    suite("Codex hooks schema：hooks/event/group/inner 任一层畸形都失败关闭且原字节不变") {
        let malformedFixtures = [
            "{ not json",
            "[]",
            #"{"hooks":"oops","notify":"keep"}"#,
            #"{"hooks":{"Stop":{"hooks":[]}},"notify":"keep"}"#,
            #"{"hooks":{"Stop":["oops"]},"notify":"keep"}"#,
            #"{"hooks":{"Stop":[{"matcher":"x"}]},"notify":"keep"}"#,
            #"{"hooks":{"Stop":[{"hooks":"oops"}]},"notify":"keep"}"#,
            #"{"hooks":{"Stop":[{"hooks":["oops"]}]},"notify":"keep"}"#,
            #"{"hooks":{"Stop":[{"matcher":7,"hooks":[]}]},"notify":"keep"}"#,
            #"{"hooks":{"Stop":[{"hooks":[{"type":7,"command":"keep"}]}]},"notify":"keep"}"#,
            #"{"hooks":{"Stop":[{"hooks":[{"type":"command"}]}]},"notify":"keep"}"#,
            #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":7}]}]},"notify":"keep"}"#,
        ]

        for fixture in malformedFixtures {
            let original = codexFixtureData(fixture)
            if case .malformed(let reason) = CodexHooksTransform.inspect(
                original,
                claudioRoot: codexTransformRoot,
                claudioBinaryPath: codexTransformBinary)
            {
                expect(!reason.isEmpty, "malformed 必须给上层可显示原因")
            } else {
                expect(false, "畸形 fixture 必须由 inspect 报 malformed：\(fixture)")
            }

            let result = CodexHooksTransform.connect(
                original,
                installationID: codexTransformID,
                claudioBinaryPath: codexTransformBinary,
                claudioRoot: codexTransformRoot)
            expect(!result.changed, "畸形配置不得写入：\(fixture)")
            expect(result.data == original, "畸形配置必须逐字节保留：\(fixture)")
            if case .malformed = result.status {
                // expected
            } else {
                expect(false, "connect 必须把畸形状态返回上层：\(result.status)")
            }

            let disconnected = CodexHooksTransform.disconnect(
                original, claudioRoot: codexTransformRoot)
            expect(!disconnected.changed, "畸形配置 disconnect 也不得写入：\(fixture)")
            expect(disconnected.data == original, "disconnect 必须逐字节保留畸形配置：\(fixture)")
            if case .malformed = disconnected.status {
                // expected
            } else {
                expect(false, "disconnect 必须把畸形状态返回上层：\(disconnected.status)")
            }
        }
    }

    suite("Codex hooks disconnect：只扫当前 root 的 Codex entries，并精确处理空 group") {
        let stop = hostIntegrationHookCommand(
            host: .codex, nativeEvent: "Stop", installationID: codexTransformID,
            claudioBinaryPath: codexTransformBinary)!
        let permission = hostIntegrationHookCommand(
            host: .codex, nativeEvent: "PermissionRequest", installationID: codexTransformID,
            claudioBinaryPath: codexTransformBinary)!
        let subagent = hostIntegrationHookCommand(
            host: .codex, nativeEvent: "SubagentStop", installationID: codexTransformID,
            claudioBinaryPath: codexTransformBinary)!
        let prompt = hostIntegrationHookCommand(
            host: .codex, nativeEvent: "UserPromptSubmit", installationID: codexTransformID,
            claudioBinaryPath: codexTransformBinary)!
        let claudeStop = hostIntegrationHookCommand(
            host: .claudeCode, nativeEvent: "Stop", installationID: codexTransformID,
            claudioBinaryPath: codexTransformBinary)!
        let foreignStop = hostIntegrationHookCommand(
            host: .codex, nativeEvent: "Stop", installationID: codexTransformID,
            claudioBinaryPath: "/tmp/.claudio/bin/claudio")!
        let fixture = codexFixtureData(
            #"{"notify":["keep"],"trust":{"opaque":true},"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"\#(prompt)"}]}],"Stop":[{"matcher":"empty-third-party","hooks":[]},{"ownedMeta":"drop-with-owned-group","hooks":[{"type":"command","command":"\#(stop)"}]},{"matcher":"shared","hooks":[{"type":"command","command":"third-before"},{"type":"command","command":"\#(stop)"},{"type":"command","command":"\#(claudeStop)"},{"type":"command","command":"\#(foreignStop)"},{"type":"command","command":"\#(stop) --extra"},{"type":"command","command":"third-after"}]}],"PermissionRequest":[{"hooks":[{"type":"command","command":"\#(permission)"}]}],"SubagentStop":[{"hooks":[{"command":"\#(subagent)"}]}],"AfterTool":[{"hooks":[{"type":"command","command":"third-after-tool"}]}]}}"#
        )

        let result = CodexHooksTransform.disconnect(fixture, claudioRoot: codexTransformRoot)
        expect(result.changed, "存在当前 root Codex entries 时必须改变")
        expect(
            result.removedCount == 5,
            "UserPromptSubmit + 两个 Stop + PermissionRequest + typeless SubagentStop 应移除 5 条")
        expect(result.status == .absent, "扫完当前 root 的四事件后状态必须 absent")

        let object = codexJSONObject(result.data)
        expect(
            codexJSONEqual(object?["notify"], codexJSONObject(fixture)?["notify"]),
            "disconnect 必须保留 notify")
        expect(
            codexJSONEqual(object?["trust"], codexJSONObject(fixture)?["trust"]),
            "disconnect 必须保留 trust")
        let stopGroups = codexEventGroups(object, "Stop")
        expect(stopGroups.count == 2, "Claudio-only group 删除；预先空 group 与 shared group 保留")
        expect(
            stopGroups.first?["matcher"] as? String == "empty-third-party",
            "预先为空的第三方 group 不得顺带删除")
        expect(
            codexCommands(Array(stopGroups.dropFirst()))
                == ["third-before", claudeStop, foreignStop, stop + " --extra", "third-after"],
            "shared group 只删当前 root Codex exact commands，且保留其余 inner 顺序")
        let hooks = object?["hooks"] as? [String: Any]
        expect(hooks?["PermissionRequest"] == nil, "被 Claudio 清空的 PermissionRequest event 应删除")
        expect(hooks?["SubagentStop"] == nil, "typeless Claudio leftover 也必须可清扫")
        expect(hooks?["UserPromptSubmit"] == nil, "任务开始 callback 必须可清扫")
        expect(codexEventGroups(object, "AfterTool").count == 1, "无关 event 必须保留")

        let repeated = CodexHooksTransform.disconnect(
            result.data, claudioRoot: codexTransformRoot)
        expect(!repeated.changed, "重复 disconnect 必须 no-op")
        expect(repeated.removedCount == 0, "重复 disconnect removedCount 必须为 0")
        expect(repeated.data == result.data, "no-op disconnect 必须返回输入原字节")
    }

    suite("Codex hooks connect：已知 wrapper 外管 Stop 时只写其余三事件且外部 UUID 参与一致性") {
        let original = codexFixtureData(
            #"{"notify":["legacy-wrapper"],"trust":{"opaque":"keep"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"third-party-stop"}]}]}}"#
        )
        let result = CodexHooksTransform.connect(
            original,
            installationID: codexOtherID,
            claudioBinaryPath: codexTransformBinary,
            claudioRoot: codexTransformRoot,
            externallyManagedNativeEvents: ["Stop"],
            externalInstallationID: codexTransformID)

        expect(result.changed, "external Stop 下仍须补 UserPromptSubmit/PermissionRequest/SubagentStop")
        expect(
            result.status == .complete(installationID: codexTransformID),
            "complete 必须沿用并报告 wrapper installation ID")
        let object = codexJSONObject(result.data)
        expect(
            codexCommands(codexEventGroups(object, "Stop")) == ["third-party-stop"],
            "external Stop 时不得再追加 Claudio Stop 造成双响")
        for event in ["UserPromptSubmit", "PermissionRequest", "SubagentStop"] {
            let matches = codexCommands(codexEventGroups(object, event)).compactMap {
                matchedHostHookCommand(inHookCommand: $0, claudioRoot: codexTransformRoot)
            }
            expect(matches.count == 1, "\(event) 必须新增恰一条")
            expect(
                matches.first?.installationID == codexTransformID,
                "\(event) 必须与 external Stop 使用同一 UUID")
        }
        expect(
            CodexHooksTransform.inspect(
                result.data,
                claudioRoot: codexTransformRoot,
                claudioBinaryPath: codexTransformBinary,
                externallyManagedNativeEvents: ["Stop"],
                externalInstallationID: codexTransformID)
                == .complete(installationID: codexTransformID),
            "带 external evidence 的 inspect 必须 complete")
        expect(
            CodexHooksTransform.inspect(
                result.data,
                claudioRoot: codexTransformRoot,
                claudioBinaryPath: codexTransformBinary)
                == .partial(
                    installationID: codexTransformID, missingNativeEvents: ["Stop"]),
            "不注入 wrapper evidence 时必须诚实报告 hooks.json 缺 Stop")

        let conflicting = CodexHooksTransform.inspect(
            result.data,
            claudioRoot: codexTransformRoot,
            claudioBinaryPath: codexTransformBinary,
            externallyManagedNativeEvents: ["Stop"],
            externalInstallationID: codexOtherID)
        expect(
            conflicting
                == .conflictingInstallationIDs(
                    [codexTransformID, codexOtherID].sorted { $0.uuidString < $1.uuidString }),
            "wrapper 与 hooks.json UUID 不同必须 conflict")

        let missingExternalID = CodexHooksTransform.connect(
            original,
            installationID: codexTransformID,
            claudioBinaryPath: codexTransformBinary,
            claudioRoot: codexTransformRoot,
            externallyManagedNativeEvents: ["Stop"])
        expect(!missingExternalID.changed, "声明 external Stop 却没有 UUID 必须失败关闭")
        expect(missingExternalID.data == original, "external evidence 不完整不得重写")
        if case .malformed = missingExternalID.status {
            // expected
        } else {
            expect(false, "external evidence 不完整必须返回 malformed")
        }
    }
}
