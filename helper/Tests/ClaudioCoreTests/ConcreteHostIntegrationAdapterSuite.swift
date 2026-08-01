import ClaudioCore
import Foundation

@MainActor
func runConcreteHostIntegrationAdapterSuites() async {
    await asyncSuite("双 adapter：现代 hook 只有精确指向当前 helper 才计入连接") {
        await withAsyncTempDirectory { root in
            let paths = makeAdapterFixture(root: root)
            let staleBinary = paths.claudioRoot.appendingPathComponent("libexec/claudio")
            let installationID = UUID(
                uuidString: "31313131-1111-4111-8111-111111111111")!

            var claudeHooks: [String: Any] = [:]
            for binding in HostCapabilityCatalog.bindings(for: .claudeCode) {
                let command = hostIntegrationHookCommand(
                    host: .claudeCode,
                    nativeEvent: binding.nativeEvent!,
                    installationID: installationID,
                    claudioBinaryPath: staleBinary.path)!
                claudeHooks[binding.nativeEvent!] = [[
                    "hooks": [["type": "command", "command": command]]
                ]]
            }
            writeAdapterJSON(["hooks": claudeHooks], to: paths.claudeSettings)

            let codexMutation = CodexHooksTransform.connect(
                nil,
                installationID: installationID,
                claudioBinaryPath: staleBinary.path,
                claudioRoot: paths.claudioRoot.path)
            try! codexMutation.data!.write(to: paths.codexHooks)

            let claude = ClaudeCodeIntegrationAdapter(
                environment: ClaudeCodeIntegrationEnvironment(
                    settingsFile: paths.claudeSettings,
                    lockFile: root.appendingPathComponent("claude.lock"),
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: paths.receipts,
                    availability: { .available }))
            let codex = CodexIntegrationAdapter(
                environment: CodexIntegrationEnvironment(
                    hooksFile: paths.codexHooks,
                    lockFile: root.appendingPathComponent("codex.lock"),
                    configFile: root.appendingPathComponent("config.toml"),
                    legacyNotifyWrapper: root.appendingPathComponent("codex-notify"),
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: paths.receipts,
                    availability: { .available }))

            let claudeSnapshot = await claude.inspect(runtime: .ready)
            let codexSnapshot = await codex.inspect(runtime: .ready)
            expect(
                claudeSnapshot.configuration == .notConfigured,
                "root 内旧 helper 路径不得让 Claude 现代连接假绿")
            expect(
                codexSnapshot.configuration == .notConfigured,
                "root 内旧 helper 路径不得让 Codex 现代连接假绿")
        }
    }

    await asyncSuite("Codex adapter：同事件重复 Claudio hook 必须 conflict 且连接零写入") {
        await withAsyncTempDirectory { root in
            let paths = makeAdapterFixture(root: root)
            let installationID = UUID(
                uuidString: "32323232-2222-4222-8222-222222222222")!
            let mutation = CodexHooksTransform.connect(
                nil,
                installationID: installationID,
                claudioBinaryPath: paths.binary.path,
                claudioRoot: paths.claudioRoot.path)
            var object = try! JSONSerialization.jsonObject(with: mutation.data!) as! [String: Any]
            var hooks = object["hooks"] as! [String: Any]
            var stopGroups = hooks["Stop"] as! [Any]
            stopGroups.append(stopGroups[0])
            hooks["Stop"] = stopGroups
            object["hooks"] = hooks
            writeAdapterJSON(object, to: paths.codexHooks)
            let before = try! Data(contentsOf: paths.codexHooks)

            let adapter = CodexIntegrationAdapter(
                environment: CodexIntegrationEnvironment(
                    hooksFile: paths.codexHooks,
                    lockFile: root.appendingPathComponent("codex.lock"),
                    configFile: root.appendingPathComponent("config.toml"),
                    legacyNotifyWrapper: root.appendingPathComponent("codex-notify"),
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: paths.receipts,
                    availability: { .available }))

            let snapshot = await adapter.inspect(runtime: .ready)
            guard case .conflict(let reason) = snapshot.configuration else {
                expect(false, "重复 Stop 必须成为显式 conflict，got \(snapshot.configuration)")
                return
            }
            expect(reason.contains("重复") && reason.contains("Stop"), "conflict 必须指出重复事件")
            guard case .failure = await adapter.connect(runtime: .ready) else {
                expect(false, "重复配置不得被 connect 当作 complete")
                return
            }
            expect(try! Data(contentsOf: paths.codexHooks) == before, "conflict connect 必须零写入")
        }
    }

    await asyncSuite("Claude adapter：只有 type=command 的现代条目才能计入连接") {
        await withAsyncTempDirectory { root in
            let paths = makeAdapterFixture(root: root)
            let installationID = UUID(
                uuidString: "33333333-3333-4333-8333-333333333333")!
            var hooks: [String: Any] = [:]
            for (index, binding) in HostCapabilityCatalog.bindings(for: .claudeCode).enumerated() {
                let command = hostIntegrationHookCommand(
                    host: .claudeCode,
                    nativeEvent: binding.nativeEvent!,
                    installationID: installationID,
                    claudioBinaryPath: paths.binary.path)!
                let entry: [String: Any] = index.isMultiple(of: 2)
                    ? ["type": "prompt", "command": command]
                    : ["command": command]
                hooks[binding.nativeEvent!] = [["hooks": [entry]]]
            }
            writeAdapterJSON(["hooks": hooks], to: paths.claudeSettings)
            let adapter = ClaudeCodeIntegrationAdapter(
                environment: ClaudeCodeIntegrationEnvironment(
                    settingsFile: paths.claudeSettings,
                    lockFile: root.appendingPathComponent("claude.lock"),
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: paths.receipts,
                    availability: { .available }))

            let before = await adapter.inspect(runtime: .ready)
            expect(
                before.configuration == .notConfigured,
                "prompt/typeless command 字符串不能冒充 Claude 可执行 hook")
            guard case .success(let connected) = await adapter.connect(runtime: .ready) else {
                expect(false, "显式连接必须用真实 command hook 修复不可执行条目")
                return
            }
            expect(connected.configuration == .configured, "修复后四事件必须配置完整")
            let repairedHooks = readAdapterJSON(paths.claudeSettings)["hooks"] as? [String: Any]
            for binding in HostCapabilityCatalog.bindings(for: .claudeCode) {
                let groups = repairedHooks?[binding.nativeEvent!] as? [Any] ?? []
                let currentEntries = groups.flatMap { group -> [[String: Any]] in
                    ((group as? [String: Any])?["hooks"] as? [[String: Any]]) ?? []
                }.filter { entry in
                    guard let command = entry["command"] as? String else { return false }
                    return matchedCurrentHostHookCommand(
                        inHookCommand: command,
                        claudioBinaryPath: paths.binary.path) != nil
                }
                expect(currentEntries.count == 1, "每事件必须只留下一个当前 Claudio 条目")
                expect(
                    currentEntries.first?["type"] as? String == "command",
                    "修复后的 Claudio 条目必须是 type=command")
            }
        }
    }

    await asyncSuite("adapter 快照：同一毫秒内按完整精度选出真正最新回执") {
        await withAsyncTempDirectory { root in
            let paths = makeAdapterFixture(root: root)
            writeAdapterJSON([:], to: paths.claudeSettings)
            let adapter = ClaudeCodeIntegrationAdapter(
                environment: ClaudeCodeIntegrationEnvironment(
                    settingsFile: paths.claudeSettings,
                    lockFile: root.appendingPathComponent("claude.lock"),
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: paths.receipts,
                    availability: { .available }))
            guard case .success(let connected) = await adapter.connect(runtime: .ready),
                let installationID = connected.installationID
            else {
                expect(false, "测试前提：Claude 必须可连接并发布代次")
                return
            }

            let earlier = HostHookReceipt(
                installationID: installationID,
                host: .claudeCode,
                nativeEvent: "Stop",
                semanticEvent: .stop,
                timestamp: Date(timeIntervalSince1970: 100.1234),
                playbackResult: .played)
            let later = HostHookReceipt(
                installationID: installationID,
                host: .claudeCode,
                nativeEvent: "SubagentStop",
                semanticEvent: .subagentStop,
                timestamp: Date(timeIntervalSince1970: 100.1235),
                playbackResult: .muted)
            expect(paths.receipts.store(earlier) == .success(.written), "较早回执必须可写")
            expect(paths.receipts.store(later) == .success(.written), "较晚回执必须可写")

            let snapshot = await adapter.inspect(runtime: .ready)
            guard case .observed(let evidence) = snapshot.activation else {
                expect(false, "完整配置应投影当前代次真实回执")
                return
            }
            expect(evidence.nativeEvent == "SubagentStop", "不得因毫秒级截断选中较早 Stop")
            expect(evidence.timestamp == later.timestamp, "快照必须保留最新回执的完整 Date 精度")
        }
    }

    await asyncSuite("Claude adapter：modern 与 legacy 混装必须成为可操作 conflict，不能伪报缺少空列表") {
        await withAsyncTempDirectory { root in
            let paths = makeAdapterFixture(root: root)
            let installationID = UUID(
                uuidString: "34343434-4444-4444-8444-444444444444")!
            guard case .success(let modern) = connectClaudeCodeHooks(
                root: [:],
                claudioRoot: paths.claudioRoot.path,
                claudioBinaryPath: paths.binary.path,
                installationID: installationID)
            else {
                expect(false, "测试前提：必须生成完整现代 Claude 配置")
                return
            }
            var mixed = modern.root
            var hooks = mixed["hooks"] as! [String: Any]
            var stopGroups = hooks["Stop"] as! [Any]
            stopGroups.append([
                "hooks": [[
                    "type": "command",
                    "command": claudioHookCommand(
                        for: .stop, claudioBinaryPath: paths.binary.path),
                ]]
            ])
            hooks["Stop"] = stopGroups
            mixed["hooks"] = hooks
            writeAdapterJSON(mixed, to: paths.claudeSettings)
            let adapter = ClaudeCodeIntegrationAdapter(
                environment: ClaudeCodeIntegrationEnvironment(
                    settingsFile: paths.claudeSettings,
                    lockFile: root.appendingPathComponent("claude.lock"),
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: paths.receipts,
                    availability: { .available }))

            let snapshot = await adapter.inspect(runtime: .ready)
            guard case .conflict(let reason) = snapshot.configuration else {
                expect(
                    false,
                    "mixed modern/legacy 必须是 conflict，不能是 incomplete([])，got \(snapshot.configuration)")
                return
            }
            expect(
                reason.contains("modern") && reason.contains("legacy")
                    && reason.contains("重复播放"),
                "conflict 必须说明两套连接与重复播放风险，got \(reason)")
            expect(snapshot.installationID == nil, "mixed conflict 不得发布 installation ID")
            expect(snapshot.activation == .none, "mixed conflict 不得读取旧回执后假绿")
        }
    }

    await asyncSuite("Claude adapter：legacy 显式升级、真实回执点亮、断开保留第三方与任务开始声音") {
        await withAsyncTempDirectory { root in
            let paths = makeAdapterFixture(root: root)
            let third: [String: Any] = [
                "matcher": "third", "hooks": [["type": "command", "command": "echo third"]]
            ]
            let legacyTaskStart = claudioHookCommand(
                for: .notification, claudioBinaryPath: paths.binary.path)
            var hooks: [String: Any] = [
                "Stop": [third],
                "UserPromptSubmit": [[
                    "hooks": [["type": "command", "command": legacyTaskStart]]
                ]],
            ]
            for binding in HostCapabilityCatalog.bindings(for: .claudeCode) {
                var groups = (hooks[binding.nativeEvent!] as? [Any]) ?? []
                groups.append([
                    "hooks": [[
                        "type": "command",
                        "command": claudioHookCommand(
                            for: binding.event, claudioBinaryPath: paths.binary.path),
                    ]]
                ])
                hooks[binding.nativeEvent!] = groups
            }
            writeAdapterJSON(["hooks": hooks, "opaque": "keep"], to: paths.claudeSettings)
            let adapter = ClaudeCodeIntegrationAdapter(
                environment: ClaudeCodeIntegrationEnvironment(
                    settingsFile: paths.claudeSettings,
                    lockFile: root.appendingPathComponent("claude.lock"),
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: paths.receipts,
                    availability: { .available }))

            let legacy = await adapter.inspect(runtime: .ready)
            expect(legacy.configuration == .legacyConnected, "旧四事件必须呈现 legacyConnected")
            guard case .success(let connected) = await adapter.connect(runtime: .ready),
                let installationID = connected.installationID
            else {
                expect(false, "显式升级必须成功并产生 installation ID")
                return
            }
            expect(connected.configuration == .configured, "升级后配置必须完整")
            expect(
                connected.activation == .awaitingReceipt(installationID: installationID),
                "没有真实事件前不得显示绿色连接")
            expect(
                paths.receipts.currentInstallationID(host: .claudeCode) == installationID,
                "Claude connect 必须把实际写入配置的 ID 发布为当前回执代次")
            let receipt = HostHookReceipt(
                installationID: installationID,
                host: .claudeCode,
                nativeEvent: "Stop",
                semanticEvent: .stop,
                timestamp: Date(timeIntervalSince1970: 10),
                playbackResult: .played)
            expect(paths.receipts.store(receipt) == .success(.written), "fixture 回执必须可写")
            let observed = await adapter.inspect(runtime: .ready)
            guard case .observed(let evidence) = observed.activation else {
                expect(false, "同代次真实回执必须点亮连接")
                return
            }
            expect(evidence.installationID == installationID, "点亮证据必须属于当前代次")

            guard case .success(let disconnected) = await adapter.disconnect(runtime: .ready) else {
                expect(false, "断开 Claude 必须成功")
                return
            }
            expect(disconnected.configuration == .notConfigured, "断开后应未配置")
            let after = readAdapterJSON(paths.claudeSettings)
            let afterHooks = after["hooks"] as? [String: Any]
            expect((after["opaque"] as? String) == "keep", "未知顶层键必须保留")
            expect((afterHooks?["Stop"] as? [Any])?.count == 1, "第三方 Stop group 必须保留")
            expect(
                (afterHooks?["UserPromptSubmit"] as? [Any])?.count == 1,
                "旧 UserPromptSubmit 任务开始声音不得被新断开删除")
            expect(
                paths.receipts.currentInstallationID(host: .claudeCode) == nil,
                "Claude disconnect 成功移除配置后必须撤销当前回执代次")
            expect(
                paths.receipts.store(receipt) == .failure(.staleInstallation),
                "断开后迟到的 Claude hook 回执必须被拒绝")
        }
    }

    await asyncSuite("Codex adapter：只写 composable hooks，notify/trust 不变，3/4 待确认而非 degraded") {
        await withAsyncTempDirectory { root in
            let paths = makeAdapterFixture(root: root)
            let original: [String: Any] = [
                "notify": ["third-notifier", "--keep"],
                "trust": ["private": "opaque"],
                "hooks": [
                    "Stop": [[
                        "matcher": "third",
                        "hooks": [["type": "command", "command": "echo foreign"]],
                    ]],
                    "AfterTool": [[
                        "hooks": [["type": "command", "command": "echo after"]]
                    ]],
                ],
            ]
            writeAdapterJSON(original, to: paths.codexHooks)
            let adapter = CodexIntegrationAdapter(
                environment: CodexIntegrationEnvironment(
                    hooksFile: paths.codexHooks,
                    lockFile: root.appendingPathComponent("codex.lock"),
                    configFile: root.appendingPathComponent("config.toml"),
                    legacyNotifyWrapper: root.appendingPathComponent("codex-notify"),
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: paths.receipts,
                    availability: { .available }))
            guard case .success(let connected) = await adapter.connect(runtime: .ready),
                let installationID = connected.installationID
            else {
                expect(false, "Codex connect 必须成功")
                return
            }
            expect(connected.configuration == .configured, "三条 hook 必须配置完整")
            expect(
                connected.activation == .awaitingReceipt(installationID: installationID),
                "Codex /hooks 确认并产生真实事件前必须等待回执")
            expect(
                paths.receipts.currentInstallationID(host: .codex) == installationID,
                "Codex connect 必须把 hooks/wrapper 实际使用的 ID 发布为当前回执代次")
            let afterConnect = readAdapterJSON(paths.codexHooks)
            expect(adapterJSONEqual(afterConnect["notify"], original["notify"]), "notify 必须不变")
            expect(adapterJSONEqual(afterConnect["trust"], original["trust"]), "trust 必须不变")
            let hooks = afterConnect["hooks"] as? [String: Any]
            expect(hooks?["StopFailure"] == nil, "Codex 不得安装 StopFailure")
            expect((hooks?["Stop"] as? [Any])?.count == 2, "第三方 Stop 后只能追加一组 Claudio")
            expect((hooks?["PermissionRequest"] as? [Any])?.count == 1, "必须安装 PermissionRequest")
            expect((hooks?["SubagentStop"] as? [Any])?.count == 1, "必须安装 SubagentStop")
            expect((hooks?["AfterTool"] as? [Any])?.count == 1, "无关事件必须保留")

            guard case .success = await adapter.disconnect(runtime: .ready) else {
                expect(false, "Codex disconnect 必须成功")
                return
            }
            let afterDisconnect = readAdapterJSON(paths.codexHooks)
            let disconnectedHooks = afterDisconnect["hooks"] as? [String: Any]
            expect(adapterJSONEqual(afterDisconnect["notify"], original["notify"]), "断开也不得碰 notify")
            expect(adapterJSONEqual(afterDisconnect["trust"], original["trust"]), "断开也不得碰 trust")
            expect((disconnectedHooks?["Stop"] as? [Any])?.count == 1, "第三方 Stop 必须保留")
            expect((disconnectedHooks?["AfterTool"] as? [Any])?.count == 1, "第三方事件必须保留")
            expect(disconnectedHooks?["PermissionRequest"] == nil, "Claudio-only group 应清除")
            expect(
                paths.receipts.currentInstallationID(host: .codex) == nil,
                "Codex disconnect 成功移除配置后必须撤销当前回执代次")
        }
    }

    await asyncSuite("Codex adapter：已知旧 wrapper 显式迁移，保留 notifier 且 Stop 不重复") {
        await withAsyncTempDirectory { root in
            let paths = makeAdapterFixture(root: root)
            let configFile = root.appendingPathComponent(".codex/config.toml")
            let wrapper = paths.claudioRoot.appendingPathComponent("bin/codex-notify")
            let notifierLine =
                #""/Applications/Previous Notify.app/Contents/MacOS/previous-notify" --keep "$payload" >/dev/null 2>&1 &"#
            let originalWrapper = knownAdapterLegacyWrapper(
                binaryPath: paths.binary.path, notifierLine: notifierLine)
            writeFixture(originalWrapper, to: wrapper)
            try! FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
            let config = adapterPreviousNotifyConfig(wrapperPath: wrapper.path)
            writeFixture(config, to: configFile)
            let originalConfig = try! Data(contentsOf: configFile)
            writeAdapterJSON([
                "hooks": [
                    "Stop": [[
                        "matcher": "third",
                        "hooks": [["type": "command", "command": "echo foreign"]],
                    ]]
                ]
            ], to: paths.codexHooks)
            let adapter = CodexIntegrationAdapter(
                environment: CodexIntegrationEnvironment(
                    hooksFile: paths.codexHooks,
                    lockFile: root.appendingPathComponent("codex.lock"),
                    configFile: configFile,
                    legacyNotifyWrapper: wrapper,
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: paths.receipts,
                    availability: { .available }))

            let before = await adapter.inspect(runtime: .ready)
            guard case .unreadable(let reason) = before.configuration else {
                expect(false, "旧 wrapper 必须等待显式升级，不能静默显示已连接")
                return
            }
            expect(reason.contains("显式升级"), "旧 wrapper 状态必须解释升级动作")

            guard case .success(let connected) = await adapter.connect(runtime: .ready),
                let firstID = connected.installationID
            else {
                expect(false, "已知旧 wrapper 必须可显式迁移")
                return
            }
            expect(
                connected.activation == .awaitingReceipt(installationID: firstID),
                "迁移完成仍须等待当前代次真实回执")
            let migrated = String(data: try! Data(contentsOf: wrapper), encoding: .utf8)!
            expect(migrated.contains(notifierLine), "原 notifier 命令与 argv 必须逐字保留")
            expect(
                migrated.contains(" hook codex Stop --installation-id \(firstID.uuidString) "),
                "旧 play stop 分支必须升级为带 installation ID 的 Stop hook")
            expect(try! Data(contentsOf: configFile) == originalConfig, "config.toml 必须逐字不变")
            let permissions = try! FileManager.default.attributesOfItem(atPath: wrapper.path)[.posixPermissions]
                as? NSNumber
            expect(permissions?.intValue == 0o755, "原 wrapper 执行权限必须保留")
            let connectedHooks = readAdapterJSON(paths.codexHooks)["hooks"] as? [String: Any]
            expect((connectedHooks?["Stop"] as? [Any])?.count == 1, "Stop 只能由旧 wrapper 管理，不得重复安装")
            expect((connectedHooks?["PermissionRequest"] as? [Any])?.count == 1, "仍须安装授权请求 hook")
            expect((connectedHooks?["SubagentStop"] as? [Any])?.count == 1, "仍须安装子任务结束 hook")

            let wrapperStopReceipt = HostHookReceipt(
                installationID: firstID,
                host: .codex,
                nativeEvent: "Stop",
                semanticEvent: .stop,
                timestamp: Date(timeIntervalSince1970: 21),
                playbackResult: .played)
            expect(
                paths.receipts.store(wrapperStopReceipt) == .success(.written),
                "已生效 wrapper 的 Stop 回执应可落盘")
            let afterWrapperStop = await adapter.inspect(runtime: .ready)
            expect(
                afterWrapperStop.activation == .awaitingReceipt(installationID: firstID),
                "wrapper Stop 不能在 /hooks 确认前绕过信任门槛点绿")

            let trustedHooksReceipt = HostHookReceipt(
                installationID: firstID,
                host: .codex,
                nativeEvent: "PermissionRequest",
                semanticEvent: .notification,
                timestamp: Date(timeIntervalSince1970: 22),
                playbackResult: .played)
            expect(
                paths.receipts.store(trustedHooksReceipt) == .success(.written),
                "hooks.json 管理事件的回执应可落盘")
            let activated = await adapter.inspect(runtime: .ready)
            guard case .observed(let evidence) = activated.activation else {
                expect(false, "/hooks 管理事件的真实回执必须可以点亮迁移连接")
                return
            }
            expect(
                evidence.nativeEvent == "PermissionRequest",
                "迁移连接的激活证据必须来自 hooks.json 管理事件")

            guard case .success = await adapter.disconnect(runtime: .ready) else {
                expect(false, "迁移后的 Codex 必须可断开")
                return
            }
            let disconnected = String(data: try! Data(contentsOf: wrapper), encoding: .utf8)!
            expect(disconnected.contains(notifierLine), "断开不得删除原 notifier")
            expect(!disconnected.contains(" hook codex Stop "), "断开只应移除 Claudio 分支")

            guard case .success(let reconnected) = await adapter.connect(runtime: .ready),
                let nextID = reconnected.installationID
            else {
                expect(false, "notifier-only wrapper 必须可重新连接")
                return
            }
            expect(nextID != firstID, "断开重连必须产生新的安装代次")
            expect(
                paths.receipts.currentInstallationID(host: .codex) == nextID,
                "wrapper 重连必须发布其实际写入命令的 installation ID")
        }
    }

    await asyncSuite("Codex adapter：notifier-only wrapper 不冒充 Stop 管理者") {
        await withAsyncTempDirectory { root in
            let paths = makeAdapterFixture(root: root)
            let configFile = root.appendingPathComponent(".codex/config.toml")
            let wrapper = paths.claudioRoot.appendingPathComponent("bin/codex-notify")
            let notifierLine = "echo notifier \"$payload\" >/dev/null 2>&1 &"
            let legacyWrapper = Data(
                knownAdapterLegacyWrapper(
                    binaryPath: paths.binary.path, notifierLine: notifierLine).utf8)
            let config = Data(adapterPreviousNotifyConfig(wrapperPath: wrapper.path).utf8)
            guard case .success(let notifierOnly) =
                removeClaudioBranchFromLegacyCodexNotifyWrapper(
                    configTOML: config,
                    wrapper: legacyWrapper,
                    claudioRoot: paths.claudioRoot.path,
                    claudioBinaryPath: paths.binary.path)
            else {
                expect(false, "测试前提：已知旧 wrapper 必须可转为 notifier-only")
                return
            }
            try! notifierOnly.write(to: wrapper)
            try! config.write(to: configFile)

            let installationID = UUID(
                uuidString: "39393939-3939-4939-8939-393939393939")!
            let complete = CodexHooksTransform.connect(
                nil,
                installationID: installationID,
                claudioBinaryPath: paths.binary.path,
                claudioRoot: paths.claudioRoot.path)
            try! complete.data!.write(to: paths.codexHooks)
            let wrapperBefore = try! Data(contentsOf: wrapper)
            let hooksBefore = try! Data(contentsOf: paths.codexHooks)

            let adapter = CodexIntegrationAdapter(
                environment: CodexIntegrationEnvironment(
                    hooksFile: paths.codexHooks,
                    lockFile: root.appendingPathComponent("codex.lock"),
                    configFile: configFile,
                    legacyNotifyWrapper: wrapper,
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: paths.receipts,
                    availability: { .available }))

            let inspected = await adapter.inspect(runtime: .ready)
            expect(inspected.configuration == .configured, "modern hooks 完整时应已连接")
            expect(inspected.installationID == installationID, "必须保留 modern hooks 的代次")
            guard case .success(let connected) = await adapter.connect(runtime: .ready) else {
                expect(false, "notifier-only 与完整 modern hooks 必须可幂等 reconnect")
                return
            }
            expect(connected.installationID == installationID, "reconnect 不得换代")
            expect(
                (try? Data(contentsOf: wrapper)) == wrapperBefore,
                "notifier-only wrapper 没有 Claudio Stop 分支，不得被重写")
            expect(
                (try? Data(contentsOf: paths.codexHooks)) == hooksBefore,
                "完整 modern hooks 必须幂等保持 bytes")
        }
    }

    await asyncSuite("Codex legacy wrapper：最终 rename 前 expected-bytes CAS 保留第三方新内容") {
        await withAsyncTempDirectory { root in
            let paths = makeAdapterFixture(root: root)
            let configFile = root.appendingPathComponent(".codex/config.toml")
            let wrapper = paths.claudioRoot.appendingPathComponent("bin/codex-notify")
            let originalWrapper = knownAdapterLegacyWrapper(
                binaryPath: paths.binary.path,
                notifierLine: "echo notifier \"$payload\" >/dev/null 2>&1 &")
            let externalWrapper = Data("#!/bin/sh\nexec external-notifier \"$@\"\n".utf8)
            writeFixture(originalWrapper, to: wrapper)
            writeFixture(adapterPreviousNotifyConfig(wrapperPath: wrapper.path), to: configFile)
            writeAdapterJSON([:], to: paths.codexHooks)
            let hooksBefore = try! Data(contentsOf: paths.codexHooks)

            let adapter = CodexIntegrationAdapter(
                environment: CodexIntegrationEnvironment(
                    hooksFile: paths.codexHooks,
                    lockFile: root.appendingPathComponent("codex-config.lock"),
                    operationLockFile: root.appendingPathComponent("codex-operation.lock"),
                    configFile: configFile,
                    legacyNotifyWrapper: wrapper,
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: paths.receipts,
                    availability: { .available },
                    beforeLegacyWrapperFinalPublish: {
                        try! externalWrapper.write(to: wrapper)
                    }))

            guard case .failure(.migrationConflict(let reason)) =
                await adapter.connect(runtime: .ready)
            else {
                expect(false, "staging 后 wrapper 被外部修改必须拒绝最终 rename")
                return
            }
            expect(reason.contains("最终迁移之间发生变化"), "冲突理由必须指出最终发布 CAS，got \(reason)")
            expect(
                (try? Data(contentsOf: wrapper)) == externalWrapper,
                "第三方在 staging 后发布的新 notifier 必须逐字节存活")
            expect(
                (try? Data(contentsOf: paths.codexHooks)) == hooksBefore,
                "wrapper CAS 失败后 hooks.json 必须零写入")
            expect(
                paths.receipts.currentInstallationID(host: .codex) == nil,
                "wrapper CAS 失败不得发布 activation marker")
        }
    }

    await asyncSuite("Codex adapter：未知或修改过的旧 wrapper fail closed，不另装 Stop") {
        await withAsyncTempDirectory { root in
            let paths = makeAdapterFixture(root: root)
            let configFile = root.appendingPathComponent(".codex/config.toml")
            let wrapper = paths.claudioRoot.appendingPathComponent("bin/codex-notify")
            let modified = knownAdapterLegacyWrapper(
                binaryPath: paths.binary.path,
                notifierLine: "echo third \"$payload\" >/dev/null 2>&1 &")
                .replacingOccurrences(of: "payload=${1-}", with: "payload=$1")
            writeFixture(modified, to: wrapper)
            writeFixture(adapterPreviousNotifyConfig(wrapperPath: wrapper.path), to: configFile)
            let originalHooks: [String: Any] = [
                "hooks": [
                    "Stop": [["hooks": [["type": "command", "command": "echo foreign"]]]]
                ]
            ]
            writeAdapterJSON(originalHooks, to: paths.codexHooks)
            let before = try! Data(contentsOf: paths.codexHooks)
            let adapter = CodexIntegrationAdapter(
                environment: CodexIntegrationEnvironment(
                    hooksFile: paths.codexHooks,
                    lockFile: root.appendingPathComponent("codex.lock"),
                    configFile: configFile,
                    legacyNotifyWrapper: wrapper,
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: paths.receipts,
                    availability: { .available }))

            guard case .failure(.migrationConflict(let reason)) =
                await adapter.connect(runtime: .ready)
            else {
                expect(false, "未知 wrapper 必须拒绝连接")
                return
            }
            expect(reason.contains("未知或已被修改"), "冲突理由必须可排障")
            expect(try! Data(contentsOf: paths.codexHooks) == before, "冲突时 hooks.json 必须零写入")
            expect(try! String(contentsOf: wrapper, encoding: .utf8) == modified, "冲突时 wrapper 必须零写入")
        }
    }

    await asyncSuite("双 adapter：配置文件已不存在时仍按 marker fallback 撤销当前代次") {
        await withAsyncTempDirectory { root in
            let paths = makeAdapterFixture(root: root)
            let claudeID = UUID(uuidString: "41414141-1111-4111-8111-111111111111")!
            let codexID = UUID(uuidString: "42424242-2222-4222-8222-222222222222")!
            guard case .success = paths.receipts.activate(
                host: .claudeCode, installationID: claudeID),
                case .success = paths.receipts.activate(host: .codex, installationID: codexID)
            else {
                expect(false, "测试前提：两个宿主 marker 必须可发布")
                return
            }
            let claude = ClaudeCodeIntegrationAdapter(
                environment: ClaudeCodeIntegrationEnvironment(
                    settingsFile: paths.claudeSettings,
                    lockFile: root.appendingPathComponent("claude.lock"),
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: paths.receipts,
                    availability: { .available }))
            let codex = CodexIntegrationAdapter(
                environment: CodexIntegrationEnvironment(
                    hooksFile: paths.codexHooks,
                    lockFile: root.appendingPathComponent("codex.lock"),
                    configFile: root.appendingPathComponent("config.toml"),
                    legacyNotifyWrapper: root.appendingPathComponent("codex-notify"),
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: paths.receipts,
                    availability: { .available }))

            guard case .success = await claude.disconnect(runtime: .ready),
                case .success = await codex.disconnect(runtime: .ready)
            else {
                expect(false, "配置文件缺失时 disconnect 仍应成功清理 marker")
                return
            }
            expect(
                paths.receipts.currentInstallationID(host: .claudeCode) == nil,
                "Claude settings.json 缺失时不能遗留 active marker")
            expect(
                paths.receipts.currentInstallationID(host: .codex) == nil,
                "Codex hooks.json 缺失时不能遗留 active marker")
        }
    }

    await asyncSuite("双 adapter：dangling 配置 symlink 必须在只读快照中显式阻塞") {
        await withAsyncTempDirectory { root in
            let paths = makeAdapterFixture(root: root)
            let missingClaudeTarget = root.appendingPathComponent("dotfiles/claude-settings.json")
            let missingCodexTarget = root.appendingPathComponent("dotfiles/codex-hooks.json")
            try! FileManager.default.createSymbolicLink(
                at: paths.claudeSettings, withDestinationURL: missingClaudeTarget)
            try! FileManager.default.createSymbolicLink(
                at: paths.codexHooks, withDestinationURL: missingCodexTarget)

            let claude = ClaudeCodeIntegrationAdapter(
                environment: ClaudeCodeIntegrationEnvironment(
                    settingsFile: paths.claudeSettings,
                    lockFile: root.appendingPathComponent("claude.lock"),
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: paths.receipts,
                    availability: { .available }))
            let codex = CodexIntegrationAdapter(
                environment: CodexIntegrationEnvironment(
                    hooksFile: paths.codexHooks,
                    lockFile: root.appendingPathComponent("codex.lock"),
                    configFile: root.appendingPathComponent("config.toml"),
                    legacyNotifyWrapper: root.appendingPathComponent("codex-notify"),
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: paths.receipts,
                    availability: { .available }))

            for snapshot in [
                await claude.inspect(runtime: .ready),
                await codex.inspect(runtime: .ready),
            ] {
                guard case .unreadable(let configurationReason) = snapshot.configuration,
                    case .notWritable(let writabilityReason) = snapshot.writability
                else {
                    expect(false, "dangling symlink 必须同时阻塞配置与维护，got \(snapshot)")
                    continue
                }
                expect(
                    configurationReason.contains("符号链接")
                        && configurationReason.contains("目标不存在"),
                    "配置理由必须暴露 dangling symlink，got \(configurationReason)")
                expect(
                    writabilityReason.contains("符号链接")
                        && writabilityReason.contains("目标不存在"),
                    "维护理由必须与真实阻塞一致，got \(writabilityReason)")
            }
            guard case .failure = await claude.connect(runtime: .ready),
                case .failure = await codex.connect(runtime: .ready)
            else {
                expect(false, "dangling symlink 不得到真正连接时才意外成功")
                return
            }
            expect(!FileManager.default.fileExists(atPath: missingClaudeTarget.path), "不得创建 Claude 目标")
            expect(!FileManager.default.fileExists(atPath: missingCodexTarget.path), "不得创建 Codex 目标")
        }
    }

    await asyncSuite("双 adapter：已连接配置的父目录不可发布时必须报维护故障") {
        await withAsyncTempDirectory { root in
            let paths = makeAdapterFixture(root: root)
            let installationID = UUID(
                uuidString: "40404040-4040-4040-8040-404040404040")!
            guard case .success(let claudeMutation) = connectClaudeCodeHooks(
                root: [:],
                claudioRoot: paths.claudioRoot.path,
                claudioBinaryPath: paths.binary.path,
                installationID: installationID)
            else {
                expect(false, "测试前提：必须生成 Claude modern hooks")
                return
            }
            writeAdapterJSON(claudeMutation.root, to: paths.claudeSettings)
            let codexMutation = CodexHooksTransform.connect(
                nil,
                installationID: installationID,
                claudioBinaryPath: paths.binary.path,
                claudioRoot: paths.claudioRoot.path)
            try! codexMutation.data!.write(to: paths.codexHooks)

            let claudeParent = paths.claudeSettings.deletingLastPathComponent()
            let codexParent = paths.codexHooks.deletingLastPathComponent()
            for parent in [claudeParent, codexParent] {
                try! FileManager.default.setAttributes(
                    [.posixPermissions: 0o500], ofItemAtPath: parent.path)
            }
            defer {
                for parent in [claudeParent, codexParent] {
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o700], ofItemAtPath: parent.path)
                }
            }

            let claude = ClaudeCodeIntegrationAdapter(
                environment: ClaudeCodeIntegrationEnvironment(
                    settingsFile: paths.claudeSettings,
                    lockFile: root.appendingPathComponent("claude.lock"),
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: paths.receipts,
                    availability: { .available }))
            let codex = CodexIntegrationAdapter(
                environment: CodexIntegrationEnvironment(
                    hooksFile: paths.codexHooks,
                    lockFile: root.appendingPathComponent("codex.lock"),
                    configFile: root.appendingPathComponent("config.toml"),
                    legacyNotifyWrapper: root.appendingPathComponent("codex-notify"),
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: paths.receipts,
                    availability: { .available }))

            for snapshot in [
                await claude.inspect(runtime: .ready),
                await codex.inspect(runtime: .ready),
            ] {
                expect(snapshot.configuration == .configured, "配置内容本身仍应可识别")
                guard case .notWritable(let reason) = snapshot.writability else {
                    expect(false, "已连接但无法 staging/rename 必须成为维护故障")
                    continue
                }
                expect(reason.contains("原子替换"), "故障理由必须说明真实发布阻塞，got \(reason)")
            }
        }
    }

    await asyncSuite("双 adapter：配置 ID 与 marker 漂移时断开优先撤销真实 marker") {
        await withAsyncTempDirectory { root in
            let paths = makeAdapterFixture(root: root)
            let claudeConfigID = UUID(
                uuidString: "43434343-1111-4111-8111-111111111111")!
            let claudeMarkerID = UUID(
                uuidString: "43434343-2222-4222-8222-222222222222")!
            let codexConfigID = UUID(
                uuidString: "44444444-1111-4111-8111-111111111111")!
            let codexMarkerID = UUID(
                uuidString: "44444444-2222-4222-8222-222222222222")!

            guard case .success(let claudeMutation) = connectClaudeCodeHooks(
                root: [:],
                claudioRoot: paths.claudioRoot.path,
                claudioBinaryPath: paths.binary.path,
                installationID: claudeConfigID)
            else {
                expect(false, "Claude fixture 必须生成现代配置")
                return
            }
            writeAdapterJSON(claudeMutation.root, to: paths.claudeSettings)
            let codexMutation = CodexHooksTransform.connect(
                nil,
                installationID: codexConfigID,
                claudioBinaryPath: paths.binary.path,
                claudioRoot: paths.claudioRoot.path)
            try! codexMutation.data!.write(to: paths.codexHooks)
            guard case .success = paths.receipts.activate(
                host: .claudeCode, installationID: claudeMarkerID),
                case .success = paths.receipts.activate(
                    host: .codex, installationID: codexMarkerID)
            else {
                expect(false, "双宿主漂移 marker fixture 必须发布")
                return
            }

            let claude = ClaudeCodeIntegrationAdapter(
                environment: ClaudeCodeIntegrationEnvironment(
                    settingsFile: paths.claudeSettings,
                    lockFile: root.appendingPathComponent("claude.lock"),
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: paths.receipts,
                    availability: { .available }))
            let codex = CodexIntegrationAdapter(
                environment: CodexIntegrationEnvironment(
                    hooksFile: paths.codexHooks,
                    lockFile: root.appendingPathComponent("codex.lock"),
                    configFile: root.appendingPathComponent("config.toml"),
                    legacyNotifyWrapper: root.appendingPathComponent("codex-notify"),
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: paths.receipts,
                    availability: { .available }))

            guard case .success = await claude.disconnect(runtime: .ready),
                case .success = await codex.disconnect(runtime: .ready)
            else {
                expect(false, "两宿主漂移状态都必须可安全断开")
                return
            }
            expect(
                paths.receipts.currentInstallationID(host: .claudeCode) == nil,
                "Claude 断开不得留下不匹配 marker")
            expect(
                paths.receipts.currentInstallationID(host: .codex) == nil,
                "Codex 断开不得留下不匹配 marker")
            let lateClaude = HostHookReceipt(
                installationID: claudeMarkerID,
                host: .claudeCode,
                nativeEvent: "Stop",
                semanticEvent: .stop,
                timestamp: Date(),
                playbackResult: .played)
            let lateCodex = HostHookReceipt(
                installationID: codexMarkerID,
                host: .codex,
                nativeEvent: "Stop",
                semanticEvent: .stop,
                timestamp: Date(),
                playbackResult: .played)
            expect(
                paths.receipts.store(lateClaude) == .failure(.staleInstallation),
                "Claude 迟到漂移回执必须被拒绝")
            expect(
                paths.receipts.store(lateCodex) == .failure(.staleInstallation),
                "Codex 迟到漂移回执必须被拒绝")
        }
    }

    await asyncSuite("adapter：配置写入成功但代次 marker 发布失败时返回 configuration error") {
        await withAsyncTempDirectory { root in
            let paths = makeAdapterFixture(root: root)
            writeAdapterJSON([:], to: paths.claudeSettings)
            let blocked = root.appendingPathComponent("blocked-installations")
            writeFixture("not a directory", to: blocked)
            let failingStore = HostHookReceiptStore(
                receiptsRoot: root.appendingPathComponent("receipts"),
                locksRoot: root.appendingPathComponent("receipt-locks"),
                installationsRoot: blocked.appendingPathComponent("installations"),
                installationLocksRoot: root.appendingPathComponent("installation-locks"))
            let adapter = ClaudeCodeIntegrationAdapter(
                environment: ClaudeCodeIntegrationEnvironment(
                    settingsFile: paths.claudeSettings,
                    lockFile: root.appendingPathComponent("claude.lock"),
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: failingStore,
                    availability: { .available }))

            guard case .failure(.configuration(let reason)) =
                await adapter.connect(runtime: .ready)
            else {
                expect(false, "marker 无法私密发布时 connect 必须返回 configuration failure")
                return
            }
            expect(
                reason.contains("当前连接代次发布失败"),
                "错误必须明确配置已写但 activation registry 发布失败，got \(reason)")
        }
    }

    await asyncSuite("宿主级 operation lock：两侧 connect 争用时配置与 marker 都零写入") {
        await withAsyncTempDirectory { root in
            let paths = makeAdapterFixture(root: root)
            writeAdapterJSON([:], to: paths.claudeSettings)
            writeAdapterJSON([:], to: paths.codexHooks)
            let claudeOperationLock = root.appendingPathComponent("claude-operation.lock")
            let codexOperationLock = root.appendingPathComponent("codex-operation.lock")
            let claude = ClaudeCodeIntegrationAdapter(
                environment: ClaudeCodeIntegrationEnvironment(
                    settingsFile: paths.claudeSettings,
                    lockFile: root.appendingPathComponent("claude-config.lock"),
                    operationLockFile: claudeOperationLock,
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: paths.receipts,
                    availability: { .available }))
            let codex = CodexIntegrationAdapter(
                environment: CodexIntegrationEnvironment(
                    hooksFile: paths.codexHooks,
                    lockFile: root.appendingPathComponent("codex-config.lock"),
                    operationLockFile: codexOperationLock,
                    configFile: root.appendingPathComponent("config.toml"),
                    legacyNotifyWrapper: root.appendingPathComponent("codex-notify"),
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: paths.receipts,
                    availability: { .available }))
            let claudeBefore = try! Data(contentsOf: paths.claudeSettings)
            let codexBefore = try! Data(contentsOf: paths.codexHooks)

            let heldClaude = FileLock(path: claudeOperationLock.path)
            expect(heldClaude.attemptLock() == .acquired, "测试前提：占住 Claude operation lock")
            let claudeResult = await claude.connect(runtime: .ready)
            heldClaude.unlock()
            expect(
                claudeResult == .failure(.transaction(.lockBusy)),
                "Claude operation lock 争用必须立即返回 typed lockBusy")

            let heldCodex = FileLock(path: codexOperationLock.path)
            expect(heldCodex.attemptLock() == .acquired, "测试前提：占住 Codex operation lock")
            let codexResult = await codex.connect(runtime: .ready)
            heldCodex.unlock()
            expect(
                codexResult == .failure(.transaction(.lockBusy)),
                "Codex operation lock 争用必须立即返回 typed lockBusy")

            expect(try! Data(contentsOf: paths.claudeSettings) == claudeBefore, "Claude 争用不得改配置")
            expect(try! Data(contentsOf: paths.codexHooks) == codexBefore, "Codex 争用不得改配置")
            expect(paths.receipts.currentInstallationID(host: .claudeCode) == nil, "Claude 争用不得发布 marker")
            expect(paths.receipts.currentInstallationID(host: .codex) == nil, "Codex 争用不得发布 marker")
        }
    }

    await asyncSuite("disconnect：marker 撤销失败时必须在配置写入前停止") {
        await withAsyncTempDirectory { root in
            let paths = makeAdapterFixture(root: root)
            writeAdapterJSON([:], to: paths.claudeSettings)
            let adapter = ClaudeCodeIntegrationAdapter(
                environment: ClaudeCodeIntegrationEnvironment(
                    settingsFile: paths.claudeSettings,
                    lockFile: root.appendingPathComponent("claude-config.lock"),
                    operationLockFile: root.appendingPathComponent("claude-operation.lock"),
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: paths.receipts,
                    availability: { .available }))
            guard case .success(let connected) = await adapter.connect(runtime: .ready),
                let installationID = connected.installationID
            else {
                expect(false, "测试前提：Claude 必须先连接")
                return
            }
            let configuredBytes = try! Data(contentsOf: paths.claudeSettings)
            let markerLock = FileLock(
                path: paths.receipts.installationLockFile(host: .claudeCode).path)
            expect(markerLock.attemptLock() == .acquired, "测试前提：占住 marker lock")
            let result = await adapter.disconnect(runtime: .ready)
            markerLock.unlock()
            guard case .failure(.configuration(let reason)) = result else {
                expect(false, "marker lock 争用必须让 disconnect 失败")
                return
            }
            expect(reason.contains("代次撤销失败"), "错误必须指向 marker 撤销")
            expect(
                try! Data(contentsOf: paths.claudeSettings) == configuredBytes,
                "marker 撤销失败后 settings.json 必须一字节不变")
            expect(
                paths.receipts.currentInstallationID(host: .claudeCode) == installationID,
                "撤销未发生时旧 marker 必须仍在")
        }
    }

    await asyncSuite("Codex legacy wrapper：hooks connect 事务失败会 CAS 回滚 wrapper") {
        await withAsyncTempDirectory { root in
            let paths = makeAdapterFixture(root: root)
            let configFile = root.appendingPathComponent(".codex/config.toml")
            let wrapper = paths.claudioRoot.appendingPathComponent("bin/codex-notify")
            let originalWrapper = knownAdapterLegacyWrapper(
                binaryPath: paths.binary.path,
                notifierLine: "echo notifier \"$payload\" >/dev/null 2>&1 &")
            writeFixture(originalWrapper, to: wrapper)
            writeFixture(adapterPreviousNotifyConfig(wrapperPath: wrapper.path), to: configFile)
            writeAdapterJSON([:], to: paths.codexHooks)
            let hooksBefore = try! Data(contentsOf: paths.codexHooks)
            let adapter = CodexIntegrationAdapter(
                environment: CodexIntegrationEnvironment(
                    hooksFile: paths.codexHooks,
                    lockFile: root.appendingPathComponent("codex-config.lock"),
                    operationLockFile: root.appendingPathComponent("codex-operation.lock"),
                    backupFile: root.appendingPathComponent("missing-parent/hooks.backup"),
                    configFile: configFile,
                    legacyNotifyWrapper: wrapper,
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: paths.receipts,
                    availability: { .available }))

            let result = await adapter.connect(runtime: .ready)
            guard case .failure(.transaction(.backupFailure)) = result else {
                expect(false, "hooks backup 失败必须保留 typed transaction error，实得 \(result)")
                return
            }
            expect(
                try! String(contentsOf: wrapper, encoding: .utf8) == originalWrapper,
                "wrapper 必须回滚到原字节")
            expect(try! Data(contentsOf: paths.codexHooks) == hooksBefore, "hooks 事务失败必须零写入")
            expect(paths.receipts.currentInstallationID(host: .codex) == nil, "失败连接不得发布 marker")
        }
    }

    await asyncSuite("Codex legacy wrapper：hooks disconnect 解析失败会回滚 wrapper 并保持 marker 失效") {
        await withAsyncTempDirectory { root in
            let paths = makeAdapterFixture(root: root)
            let configFile = root.appendingPathComponent(".codex/config.toml")
            let wrapper = paths.claudioRoot.appendingPathComponent("bin/codex-notify")
            let originalWrapper = knownAdapterLegacyWrapper(
                binaryPath: paths.binary.path,
                notifierLine: "echo notifier \"$payload\" >/dev/null 2>&1 &")
            writeFixture(originalWrapper, to: wrapper)
            writeFixture(adapterPreviousNotifyConfig(wrapperPath: wrapper.path), to: configFile)
            writeAdapterJSON([:], to: paths.codexHooks)
            let adapter = CodexIntegrationAdapter(
                environment: CodexIntegrationEnvironment(
                    hooksFile: paths.codexHooks,
                    lockFile: root.appendingPathComponent("codex-config.lock"),
                    operationLockFile: root.appendingPathComponent("codex-operation.lock"),
                    configFile: configFile,
                    legacyNotifyWrapper: wrapper,
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: paths.receipts,
                    availability: { .available }))
            guard case .success(let connected) = await adapter.connect(runtime: .ready),
                let installationID = connected.installationID
            else {
                expect(false, "测试前提：已知 wrapper 必须先迁移成功")
                return
            }
            let migratedWrapper = try! Data(contentsOf: wrapper)
            writeFixture("{ malformed", to: paths.codexHooks)
            let malformedHooks = try! Data(contentsOf: paths.codexHooks)

            let result = await adapter.disconnect(runtime: .ready)
            guard case .failure(.transaction(.parseFailure)) = result else {
                expect(false, "畸形 hooks 必须保留 typed parse failure，实得 \(result)")
                return
            }
            expect(try! Data(contentsOf: wrapper) == migratedWrapper, "摘除过的 wrapper 必须回滚")
            expect(try! Data(contentsOf: paths.codexHooks) == malformedHooks, "畸形 hooks 必须零写入")
            expect(
                paths.receipts.currentInstallationID(host: .codex) == nil,
                "断开开始后即使配置失败，旧 marker 也必须失效")
            let lateReceipt = HostHookReceipt(
                installationID: installationID,
                host: .codex,
                nativeEvent: "Stop",
                semanticEvent: .stop,
                timestamp: Date(),
                playbackResult: .played)
            expect(
                paths.receipts.store(lateReceipt) == .failure(.staleInstallation),
                "配置失败不得让迟到旧回执重新点亮")
        }
    }

    await asyncSuite("HostIntegrationManager：两宿主永久存在，并行连接与单侧失败互不冻结") {
        await withAsyncTempDirectory { root in
            let paths = makeAdapterFixture(root: root)
            writeAdapterJSON([:], to: paths.claudeSettings)
            writeAdapterJSON([:], to: paths.codexHooks)
            let claude = ClaudeCodeIntegrationAdapter(
                environment: ClaudeCodeIntegrationEnvironment(
                    settingsFile: paths.claudeSettings,
                    lockFile: root.appendingPathComponent("claude.lock"),
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: paths.receipts,
                    availability: { .available }))
            let codex = CodexIntegrationAdapter(
                environment: CodexIntegrationEnvironment(
                    hooksFile: paths.codexHooks,
                    lockFile: root.appendingPathComponent("codex.lock"),
                    configFile: root.appendingPathComponent("config.toml"),
                    legacyNotifyWrapper: root.appendingPathComponent("codex-notify"),
                    claudioBinaryPath: paths.binary.path,
                    claudioRoot: paths.claudioRoot.path,
                    receiptStore: paths.receipts,
                    availability: { .available }))
            let manager = HostIntegrationManager(
                adapters: [claude, codex], bootstrapper: ReadyRuntimeBootstrapper())
            let initial = await manager.refresh()
            expect(initial.map(\.host) == HostID.allCases, "刷新必须固定返回两宿主")

            async let claudeResult = manager.connect(.claudeCode)
            async let codexResult = manager.connect(.codex)
            let results = await (claudeResult, codexResult)
            guard case .success = results.0, case .success = results.1 else {
                expect(false, "两侧独立配置文件必须可并行连接")
                return
            }
            let connected = await manager.snapshots()
            expect(
                connected.allSatisfy { $0.configuration == .configured },
                "两侧连接后快照都必须保留")
        }
    }
}

private struct AdapterFixturePaths {
    let claudioRoot: URL
    let binary: URL
    let claudeSettings: URL
    let codexHooks: URL
    let receipts: HostHookReceiptStore
}

@MainActor
private func makeAdapterFixture(root: URL) -> AdapterFixturePaths {
    let claudioRoot = root.appendingPathComponent(".claudio", isDirectory: true)
    let binary = claudioRoot.appendingPathComponent("bin/claudio")
    let claudeSettings = root.appendingPathComponent(".claude/settings.json")
    let codexHooks = root.appendingPathComponent(".codex/hooks.json")
    try! FileManager.default.createDirectory(
        at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(
        at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(
        at: codexHooks.deletingLastPathComponent(), withIntermediateDirectories: true)
    writeFixture("binary", to: binary)
    return AdapterFixturePaths(
        claudioRoot: claudioRoot,
        binary: binary,
        claudeSettings: claudeSettings,
        codexHooks: codexHooks,
        receipts: HostHookReceiptStore(
            receiptsRoot: claudioRoot.appendingPathComponent("integrations/receipts"),
            locksRoot: claudioRoot.appendingPathComponent("integrations/receipt-locks")))
}

@MainActor
private func withAsyncTempDirectory(
    _ body: (URL) async -> Void
) async {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("claudio-adapter-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    await body(directory)
}

@MainActor
private func writeAdapterJSON(_ root: [String: Any], to file: URL) {
    let data = try! JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
    try! data.write(to: file)
}

private func readAdapterJSON(_ file: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: file),
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return root
}

private func adapterJSONEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    return (lhs as AnyObject).isEqual(rhs)
}

private func knownAdapterLegacyWrapper(binaryPath: String, notifierLine: String) -> String {
    """
    #!/bin/sh
    # Codex 的 notify 只能配置一个外部命令；这里保留既有通知，并追加 Claudio 的完成音效。

    payload=${1-}

    \(notifierLine)
    \(shellQuotedPath(binaryPath)) play stop >/dev/null 2>&1 &

    exit 0

    """
}

private func adapterPreviousNotifyConfig(wrapperPath: String) -> String {
    let json = String(
        data: try! JSONSerialization.data(withJSONObject: [wrapperPath]),
        encoding: .utf8)!
    let tomlArgument = json
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return """
    notify = [
      "/Applications/Previous Notify.app/Contents/MacOS/previous-notify",
      "turn-ended",
      "--previous-notify",
      "\(tomlArgument)",
    ]

    [projects."/tmp/example"]
    trust_hash = "opaque"
    """
}

private struct ReadyRuntimeBootstrapper: SharedRuntimeBootstrapping {
    func inspect() -> SharedRuntimeHealth { .ready }

    func bootstrap() -> Result<SharedRuntimeBootstrapOutcome, SetupError> {
        .success(
            SharedRuntimeBootstrapOutcome(
                copiedBinary: false,
                copiedPacks: [],
                salvaged: [],
                packSelection: .untouched))
    }
}
