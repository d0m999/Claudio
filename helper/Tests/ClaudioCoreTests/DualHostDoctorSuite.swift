import ClaudioCore
import Foundation

private let dualHostDoctorCurrentID =
    UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
private let dualHostDoctorStaleID =
    UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!

private struct DualHostDoctorFixture {
    let claudioRoot: URL
    let claudioBinary: URL
    let claudeSettings: URL
    let codexHooks: URL
    let receiptStore: HostHookReceiptStore

    var environment: DoctorIntegrationsEnvironment {
        DoctorIntegrationsEnvironment(
            claudeSettingsFile: claudeSettings,
            codexHooksFile: codexHooks,
            claudioRoot: claudioRoot.path,
            receiptStore: receiptStore,
            claudeAvailability: { .available },
            codexAvailability: { .available })
    }
}

private struct DualHostDoctorCommandRunner: CommandRunning {
    func run(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> CommandRunResult {
        .completed(exitCode: 0, stdout: "2.1.206 (Claude Code)")
    }
}

@MainActor
private func makeDualHostDoctorFixture(under root: URL) -> DualHostDoctorFixture {
    let claudioRoot = root.appendingPathComponent(".claudio", isDirectory: true)
    let claudeSettings = root.appendingPathComponent(".claude/settings.json")
    let codexHooks = root.appendingPathComponent(".codex/hooks.json")
    try! FileManager.default.createDirectory(
        at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(
        at: codexHooks.deletingLastPathComponent(), withIntermediateDirectories: true)
    return DualHostDoctorFixture(
        claudioRoot: claudioRoot,
        claudioBinary: claudioRoot.appendingPathComponent("bin/claudio"),
        claudeSettings: claudeSettings,
        codexHooks: codexHooks,
        receiptStore: HostHookReceiptStore(
            receiptsRoot: claudioRoot.appendingPathComponent(
                "integrations/receipts", isDirectory: true),
            locksRoot: claudioRoot.appendingPathComponent(
                "integrations/receipt-locks", isDirectory: true)))
}

@MainActor
private func writeDualHostDoctorJSON(_ object: [String: Any], to file: URL) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
    try! data.write(to: file)
}

@MainActor
private func makeDualHostDoctorExecutable(at file: URL) {
    writeFixture("#!/bin/sh\nexit 0\n", to: file)
    try! FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: file.path)
}

@MainActor
@discardableResult
private func writeCompleteCodexDoctorHooks(
    _ fixture: DualHostDoctorFixture,
    installationID: UUID = dualHostDoctorCurrentID
) -> Data {
    let mutation = CodexHooksTransform.connect(
        nil,
        installationID: installationID,
        claudioBinaryPath: fixture.claudioBinary.path,
        claudioRoot: fixture.claudioRoot.path)
    guard mutation.status == .complete(installationID: installationID),
        let data = mutation.data
    else {
        expect(false, "测试 fixture 必须能由 transform 建出完整 Codex 配置")
        return Data()
    }
    try! data.write(to: fixture.codexHooks)
    if case .failure(let error) = fixture.receiptStore.activate(
        host: .codex, installationID: installationID)
    {
        expect(false, "测试 fixture 无法发布当前 Codex installation：\(error.description)")
    }
    return data
}

private func dualHostDoctorResult(
    _ results: [DoctorCheckResult], host: HostID
) -> DoctorCheckResult? {
    results.first { $0.name == "host-\(host.rawValue)" }
}

@MainActor
func runDualHostDoctorSuites() {
    suite("双宿主 doctor：共享 runtime 不可用必须 hard fail，已连接宿主不得继续假绿") {
        withTempDirectory { root in
            let fixture = makeDualHostDoctorFixture(under: root)
            let afplay = root.appendingPathComponent("bin/afplay")
            makeDualHostDoctorExecutable(at: afplay)
            makeDualHostDoctorExecutable(at: fixture.claudioBinary)
            writeCompleteCodexDoctorHooks(fixture)
            let receipt = HostHookReceipt(
                installationID: dualHostDoctorCurrentID,
                host: .codex,
                nativeEvent: "Stop",
                semanticEvent: .stop,
                timestamp: Date(timeIntervalSince1970: 1_800_000_100),
                playbackResult: .played)
            expect(
                fixture.receiptStore.store(receipt) == .success(.written),
                "测试前提：当前 Codex 回执必须可写")

            let report = runDoctorChecks(
                environment: DoctorEnvironment(
                    afplayPath: afplay.path,
                    settingsFile: fixture.claudeSettings,
                    configFile: fixture.claudioRoot.appendingPathComponent("config.json"),
                    userPacksDirectory: fixture.claudioRoot.appendingPathComponent("packs"),
                    bundledPacksDirectory: nil,
                    logFile: fixture.claudioRoot.appendingPathComponent("claudio.log"),
                    claudioBinaryPath: fixture.claudioBinary.path,
                    commandRunner: DualHostDoctorCommandRunner(),
                    currentMacOSVersion: {
                        SemanticVersion(major: 15, minor: 0, patch: 0)
                    },
                    integrations: fixture.environment))

            expect(report.hasFailure, "未选择声音包时共享 runtime 不可用，doctor 必须非零")
            expect(
                report.results.contains {
                    $0.name == "shared-runtime" && $0.severity == .failure
                },
                "doctor 必须有共享 runtime 的单一事实行")
            let codex = dualHostDoctorResult(report.results, host: .codex)
            expect(codex?.severity == .failure, "runtime 不可用时已连接 Codex 不得继续显示 3/4 ready")
            expect(
                codex?.message.contains("共享 runtime") == true,
                "宿主 failure 必须解释声音链路不可用的共同根因")
        }
    }

    suite("双宿主 doctor：helper 目录不能冒充可执行二进制") {
        withTempDirectory { root in
            let fixture = makeDualHostDoctorFixture(under: root)
            let afplay = root.appendingPathComponent("bin/afplay")
            makeDualHostDoctorExecutable(at: afplay)
            try! FileManager.default.createDirectory(
                at: fixture.claudioBinary, withIntermediateDirectories: true)
            let report = runDoctorChecks(
                environment: DoctorEnvironment(
                    afplayPath: afplay.path,
                    settingsFile: fixture.claudeSettings,
                    configFile: fixture.claudioRoot.appendingPathComponent("config.json"),
                    userPacksDirectory: fixture.claudioRoot.appendingPathComponent("packs"),
                    bundledPacksDirectory: nil,
                    logFile: fixture.claudioRoot.appendingPathComponent("claudio.log"),
                    claudioBinaryPath: fixture.claudioBinary.path,
                    commandRunner: DualHostDoctorCommandRunner(),
                    currentMacOSVersion: {
                        SemanticVersion(major: 15, minor: 0, patch: 0)
                    },
                    integrations: fixture.environment))
            let binary = report.results.first { $0.name == "claudio-binary" }
            expect(binary?.severity == .failure, "可搜索目录也必须被 helper 正规文件闸门拒绝")
            expect(binary?.message.contains("不是普通文件") == true, "诊断必须指出 helper 路径形状")
        }
    }

    suite("双宿主 doctor：新版完整报告不再用旧 Claude-only settings 检查误判双未安装") {
        withTempDirectory { root in
            let afplay = root.appendingPathComponent("shared/bin/afplay")
            let binary = root.appendingPathComponent("shared/bin/claudio")
            makeDualHostDoctorExecutable(at: afplay)
            makeDualHostDoctorExecutable(at: binary)
            writeFixture(
                #"{"selected_pack":"doctor-ready"}"#,
                to: root.appendingPathComponent(".claudio/config.json"))
            writeFixture(
                #"{"id":"doctor-ready","events":{"stop":"stop.mp3"}}"#,
                to: root.appendingPathComponent(
                    ".claudio/packs/doctor-ready/manifest.json"))
            writeFixture(
                "audio",
                to: root.appendingPathComponent(
                    ".claudio/packs/doctor-ready/stop.mp3"))

            let claudeSettings = root.appendingPathComponent("missing-claude/settings.json")
            let codexHooks = root.appendingPathComponent("missing-codex/hooks.json")
            let integrations = DoctorIntegrationsEnvironment(
                claudeSettingsFile: claudeSettings,
                codexHooksFile: codexHooks,
                claudioRoot: root.appendingPathComponent(".claudio").path,
                receiptStore: HostHookReceiptStore(
                    receiptsRoot: root.appendingPathComponent("receipts"),
                    locksRoot: root.appendingPathComponent("receipt-locks")),
                claudeAvailability: { .unavailable(reason: "未检测到 Claude Code 配置目录") },
                codexAvailability: { .unavailable(reason: "未检测到 Codex 配置目录") })
            let report = runDoctorChecks(
                environment: DoctorEnvironment(
                    afplayPath: afplay.path,
                    settingsFile: claudeSettings,
                    configFile: root.appendingPathComponent(".claudio/config.json"),
                    userPacksDirectory: root.appendingPathComponent(".claudio/packs"),
                    bundledPacksDirectory: nil,
                    logFile: root.appendingPathComponent(".claudio/claudio.log"),
                    claudioBinaryPath: binary.path,
                    commandRunner: DualHostDoctorCommandRunner(),
                    currentMacOSVersion: {
                        SemanticVersion(major: 15, minor: 0, patch: 0)
                    },
                    integrations: integrations))

            expect(
                !FileManager.default.fileExists(
                    atPath: claudeSettings.deletingLastPathComponent().path)
                    && !FileManager.default.fileExists(
                        atPath: codexHooks.deletingLastPathComponent().path),
                "fixture 与 doctor 都不得创建未安装宿主的配置目录")
            let hostRows = report.results.filter { $0.name.hasPrefix("host-") }
            expect(hostRows.count == 2, "完整 doctor 仍必须固定输出两条宿主行")
            expect(
                hostRows.allSatisfy { $0.severity == .warning },
                "双宿主均未安装只能是 warning，got \(hostRows)")
            expect(
                !report.results.contains { $0.name == "settings.json" },
                "注入双宿主事实源后必须停用旧 Claude-only settings hard check")
            expect(
                !report.hasFailure,
                "共享 afplay/helper 就绪时，两个未安装宿主不得让完整 doctor 非零退出")
        }
    }

    suite("双宿主 doctor：双未连仍固定返回两行 warning，且没有 hard failure") {
        withTempDirectory { root in
            let fixture = makeDualHostDoctorFixture(under: root)
            let results = hostIntegrationDoctorResults(environment: fixture.environment)

            expect(results.count == 2, "无论连接状态如何都必须固定返回两个宿主结果")
            expect(
                results.map(\.name) == ["host-claude-code", "host-codex"],
                "doctor 行顺序必须固定为 Claude Code、Codex")
            expect(
                results.allSatisfy { $0.severity == .warning },
                "双未连是 warning，不是成功假绿或 hard failure，got \(results)")
            expect(
                !results.contains { $0.severity == .failure },
                "未安装/未连接不得让 doctor 非零退出")
        }
    }

    suite("双宿主 doctor：已有连接的一侧宿主不可用是 failure，不影响另一侧行") {
        withTempDirectory { root in
            let fixture = makeDualHostDoctorFixture(under: root)
            writeCompleteCodexDoctorHooks(fixture)
            let unavailableEnvironment = DoctorIntegrationsEnvironment(
                claudeSettingsFile: fixture.claudeSettings,
                codexHooksFile: fixture.codexHooks,
                claudioRoot: fixture.claudioRoot.path,
                receiptStore: fixture.receiptStore,
                claudeAvailability: { .available },
                codexAvailability: { .unavailable(reason: "Codex 配置目录已断开") })

            let results = hostIntegrationDoctorResults(environment: unavailableEnvironment)
            expect(results.count == 2, "单侧不可用不能吞掉另一宿主 doctor 行")
            expect(
                dualHostDoctorResult(results, host: .claudeCode)?.severity == .warning,
                "未连接 Claude Code 仍只是 warning")
            let codex = dualHostDoctorResult(results, host: .codex)
            expect(codex?.severity == .failure, "已有配置但宿主不可用必须 hard fail")
            expect(
                codex?.message.contains("已有 claudi0 连接但宿主不可用") == true,
                "failure 必须明确区分未安装空态与已连接侧损坏")
        }
    }

    suite("双宿主 doctor：Codex 三条 hook 无回执时固定等待 /hooks 确认") {
        withTempDirectory { root in
            let fixture = makeDualHostDoctorFixture(under: root)
            writeCompleteCodexDoctorHooks(fixture)

            let results = hostIntegrationDoctorResults(environment: fixture.environment)
            guard let codex = dualHostDoctorResult(results, host: .codex) else {
                expect(false, "必须保留 Codex doctor 行")
                return
            }
            expect(codex.severity == .warning, "配置完成但未激活必须是待确认 warning")
            expect(
                codex.message.contains("claudi0 已写好，等待 Codex 确认")
                    && codex.message.contains("/hooks"),
                "待确认文案必须给出固定状态与可执行 /hooks 指令，got \(codex.message)")
        }
    }

    suite("双宿主 doctor：当前 installation 的真实回执点亮 Codex 中性 3/4") {
        withTempDirectory { root in
            let fixture = makeDualHostDoctorFixture(under: root)
            writeCompleteCodexDoctorHooks(fixture)
            let receipt = HostHookReceipt(
                installationID: dualHostDoctorCurrentID,
                host: .codex,
                nativeEvent: "PermissionRequest",
                semanticEvent: .notification,
                timestamp: Date(timeIntervalSince1970: 1_800_000_000),
                playbackResult: .played)
            expect(
                fixture.receiptStore.store(receipt) == .success(.written),
                "测试前提：当前代次真实回执必须成功写入临时 store")

            let results = hostIntegrationDoctorResults(environment: fixture.environment)
            guard let codex = dualHostDoctorResult(results, host: .codex) else {
                expect(false, "必须保留 Codex doctor 行")
                return
            }
            expect(codex.severity == .ok, "真实回执后 Codex 3/4 是正常能力事实")
            expect(codex.message.contains("3/4 已就绪"), "必须诚实显示 Codex 3/4")
            expect(
                codex.message.contains("仅授权请求"),
                "需要你的 Codex 限定语必须进入 doctor 可见文案")
        }
    }

    suite("双宿主 doctor：Codex hook 缺失与损坏均是 failure") {
        withTempDirectory { root in
            let fixture = makeDualHostDoctorFixture(under: root)
            let complete = writeCompleteCodexDoctorHooks(fixture)
            var object = try! JSONSerialization.jsonObject(with: complete) as! [String: Any]
            var hooks = object["hooks"] as! [String: Any]
            hooks.removeValue(forKey: "SubagentStop")
            object["hooks"] = hooks
            writeDualHostDoctorJSON(object, to: fixture.codexHooks)

            let partial = hostIntegrationDoctorResults(environment: fixture.environment)
            let partialCodex = dualHostDoctorResult(partial, host: .codex)
            expect(partialCodex?.severity == .failure, "已有 Claudio 配置但缺 hook 必须 hard fail")
            expect(
                partialCodex?.message.contains("SubagentStop") == true,
                "缺失事件必须进入诊断文案")
        }

        withTempDirectory { root in
            let fixture = makeDualHostDoctorFixture(under: root)
            writeFixture(#"{"hooks":{"Stop":"not-an-array"}}"#, to: fixture.codexHooks)
            let malformed = hostIntegrationDoctorResults(environment: fixture.environment)
            let malformedCodex = dualHostDoctorResult(malformed, host: .codex)
            expect(malformedCodex?.severity == .failure, "畸形 Codex hook schema 必须 hard fail")
            expect(
                malformedCodex?.message.contains("配置损坏或冲突") == true,
                "畸形配置必须给出损坏/冲突诊断")
        }
    }

    suite("双宿主 doctor：完整连接但 Codex 配置不可写是 failure") {
        withTempDirectory { root in
            let fixture = makeDualHostDoctorFixture(under: root)
            writeCompleteCodexDoctorHooks(fixture)
            try! FileManager.default.setAttributes(
                [.posixPermissions: 0o400], ofItemAtPath: fixture.codexHooks.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: fixture.codexHooks.path)
            }

            let results = hostIntegrationDoctorResults(environment: fixture.environment)
            let codex = dualHostDoctorResult(results, host: .codex)
            expect(codex?.severity == .failure, "已连接配置不可写必须 hard fail")
            expect(
                codex?.message.contains("已连接但配置不可写") == true,
                "不可写 failure 必须明确连接仍在但无法维护")
        }
    }

    suite("双宿主 doctor：Claude legacy 可听但无真实回执，因此仅 warning") {
        withTempDirectory { root in
            let fixture = makeDualHostDoctorFixture(under: root)
            var hooks: [String: Any] = [:]
            for binding in HostCapabilityCatalog.bindings(for: .claudeCode) {
                hooks[binding.nativeEvent!] = [[
                    "hooks": [[
                        "type": "command",
                        "command": claudioHookCommand(
                            for: binding.event,
                            claudioBinaryPath: fixture.claudioBinary.path),
                    ]]
                ]]
            }
            writeDualHostDoctorJSON(["hooks": hooks], to: fixture.claudeSettings)

            let results = hostIntegrationDoctorResults(environment: fixture.environment)
            let claude = dualHostDoctorResult(results, host: .claudeCode)
            expect(claude?.severity == .warning, "Claude legacy 不应假装有回执，也不应 hard fail")
            expect(
                claude?.message.contains("旧版连接") == true
                    && claude?.message.contains("暂无真实回执") == true,
                "legacy 文案必须同时表达可听与证据限制")
        }
    }

    suite("双宿主 doctor：Claude modern/legacy 混装给出 conflict，绝不显示空缺失列表") {
        withTempDirectory { root in
            let fixture = makeDualHostDoctorFixture(under: root)
            guard case .success(let modern) = connectClaudeCodeHooks(
                root: [:],
                claudioRoot: fixture.claudioRoot.path,
                claudioBinaryPath: fixture.claudioBinary.path,
                installationID: dualHostDoctorCurrentID)
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
                        for: .stop, claudioBinaryPath: fixture.claudioBinary.path),
                ]]
            ])
            hooks["Stop"] = stopGroups
            mixed["hooks"] = hooks
            writeDualHostDoctorJSON(mixed, to: fixture.claudeSettings)

            let results = hostIntegrationDoctorResults(environment: fixture.environment)
            let claude = dualHostDoctorResult(results, host: .claudeCode)
            expect(claude?.severity == .failure, "mixed 两套播放链必须是 doctor failure")
            expect(
                claude?.message.contains("modern 与 legacy") == true
                    && claude?.message.contains("重复播放") == true,
                "doctor 必须给出可操作 mixed conflict，got \(String(describing: claude))")
            expect(
                claude?.message.contains("缺少 hook：") != true,
                "modern 完整 + legacy residue 不能再渲染空的“缺少 hook：”")
        }
    }

    suite("双宿主 doctor：Claude legacy 配置不可写是 connected failure") {
        withTempDirectory { root in
            let fixture = makeDualHostDoctorFixture(under: root)
            var hooks: [String: Any] = [:]
            for binding in HostCapabilityCatalog.bindings(for: .claudeCode) {
                hooks[binding.nativeEvent!] = [[
                    "hooks": [[
                        "type": "command",
                        "command": claudioHookCommand(
                            for: binding.event,
                            claudioBinaryPath: fixture.claudioBinary.path),
                    ]]
                ]]
            }
            writeDualHostDoctorJSON(["hooks": hooks], to: fixture.claudeSettings)
            try! FileManager.default.setAttributes(
                [.posixPermissions: 0o400], ofItemAtPath: fixture.claudeSettings.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: fixture.claudeSettings.path)
            }

            let results = hostIntegrationDoctorResults(environment: fixture.environment)
            let claude = dualHostDoctorResult(results, host: .claudeCode)
            expect(claude?.severity == .failure, "legacy 仍是已连接配置，不可维护时必须 hard fail")
            expect(
                claude?.message.contains("配置不可写") == true,
                "legacy failure 必须明确连接仍在但配置不可维护")
        }
    }

    suite("双宿主 doctor：旧代次与损坏 receipt 都不能点亮 Codex") {
        withTempDirectory { root in
            let fixture = makeDualHostDoctorFixture(under: root)
            writeCompleteCodexDoctorHooks(fixture)
            let staleReceipt = HostHookReceipt(
                installationID: dualHostDoctorStaleID,
                host: .codex,
                nativeEvent: "PermissionRequest",
                semanticEvent: .notification,
                timestamp: Date(timeIntervalSince1970: 1_800_000_010),
                playbackResult: .played)
            expect(
                fixture.receiptStore.store(staleReceipt) == .failure(.staleInstallation),
                "当前代次已发布后，旧代次回执必须在写入前被拒绝")

            let staleResults = hostIntegrationDoctorResults(environment: fixture.environment)
            let staleCodex = dualHostDoctorResult(staleResults, host: .codex)
            expect(staleCodex?.severity == .warning, "旧代次回执不得点亮当前配置")
            expect(
                staleCodex?.message.contains("等待 Codex 确认") == true,
                "旧代次存在时仍必须显示当前代次待确认")

            guard let receiptFile = fixture.receiptStore.receiptFile(
                host: .codex, nativeEvent: "PermissionRequest")
            else {
                expect(false, "PermissionRequest 必须有稳定回执路径")
                return
            }
            writeFixture("{broken receipt", to: receiptFile)
            let damagedResults = hostIntegrationDoctorResults(environment: fixture.environment)
            let damagedCodex = dualHostDoctorResult(damagedResults, host: .codex)
            expect(damagedCodex?.severity == .warning, "损坏回执必须失败关闭，不能点亮 Codex")
            expect(
                damagedCodex?.message.contains("等待 Codex 确认") == true,
                "损坏回执存在时仍必须给出 /hooks 激活路径")
        }
    }

    suite("双宿主 doctor：已迁移 codex-notify 的 Stop 与 adapter 使用同一事实源") {
        withTempDirectory { root in
            let fixture = makeDualHostDoctorFixture(under: root)
            let config = fixture.codexHooks.deletingLastPathComponent()
                .appendingPathComponent("config.toml")
            let wrapper = fixture.claudioRoot.appendingPathComponent("bin/codex-notify")
            let configText = "notify = [\"\(wrapper.path)\"]\n"
            let notifierLine = #"/usr/bin/true "$payload" >/dev/null 2>&1 &"#
            let legacy = """
                #!/bin/sh
                # Codex 的 notify 只能配置一个外部命令；这里保留既有通知，并追加 Claudio 的完成音效。

                payload=${1-}

                \(notifierLine)
                "\(fixture.claudioBinary.path)" play stop >/dev/null 2>&1 &

                exit 0

                """
            let migrated = migrateLegacyCodexNotifyWrapper(
                configTOML: configText,
                wrapper: legacy,
                claudioRoot: fixture.claudioRoot.path,
                claudioBinaryPath: fixture.claudioBinary.path,
                installationID: dualHostDoctorCurrentID)
            guard case .success(let migratedWrapper) = migrated else {
                expect(false, "测试前提：已知 legacy wrapper 必须能迁移")
                return
            }
            writeFixture(configText, to: config)
            writeFixture(migratedWrapper, to: wrapper)

            let hooks = CodexHooksTransform.connect(
                nil,
                installationID: dualHostDoctorCurrentID,
                claudioBinaryPath: fixture.claudioBinary.path,
                claudioRoot: fixture.claudioRoot.path,
                externallyManagedNativeEvents: ["Stop"],
                externalInstallationID: dualHostDoctorCurrentID)
            guard let hooksData = hooks.data else {
                expect(false, "测试前提：外部 Stop + 两条 composable hook 必须可生成")
                return
            }
            try! hooksData.write(to: fixture.codexHooks)
            guard case .success = fixture.receiptStore.activate(
                host: .codex, installationID: dualHostDoctorCurrentID)
            else {
                expect(false, "测试前提：migrated wrapper 的当前 installation 必须先发布")
                return
            }

            let adapterSnapshot = inspectCodexSnapshot(
                environment: CodexIntegrationEnvironment(
                    hooksFile: fixture.codexHooks,
                    configFile: config,
                    legacyNotifyWrapper: wrapper,
                    claudioBinaryPath: fixture.claudioBinary.path,
                    claudioRoot: fixture.claudioRoot.path,
                    receiptStore: fixture.receiptStore,
                    availability: { .available }),
                runtime: .ready)
            expect(
                adapterSnapshot.configuration == .configured
                    && adapterSnapshot.installationID == dualHostDoctorCurrentID,
                "adapter 必须把 migrated wrapper 的 Stop 与 hooks.json 两条事件合成完整 3/4")

            let results = hostIntegrationDoctorResults(environment: fixture.environment)
            let codex = dualHostDoctorResult(results, host: .codex)
            expect(codex?.severity == .warning, "无真实回执时应等待确认，而不是误报缺 Stop")
            expect(
                codex?.message.contains("等待 Codex 确认") == true,
                "doctor 必须复用 adapter 对 migrated wrapper 的判定，got \(String(describing: codex))")
        }
    }
}
