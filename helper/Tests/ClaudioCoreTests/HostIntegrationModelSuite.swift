import Darwin
import ClaudioCore
import Foundation

@MainActor
func runHostIntegrationModelSuites() {
    suite("双宿主能力目录：Claude Code 5/5、Codex 严格 4/5") {
        let claude = HostCapabilityCatalog.bindings(for: .claudeCode)
        let codex = HostCapabilityCatalog.bindings(for: .codex)

        expect(claude.map(\.event) == Event.allCases, "Claude Code 必须按五个语义事件的稳定顺序给出能力")
        expect(
            claude.compactMap(\.nativeEvent)
                == ["UserPromptSubmit", "Stop", "StopFailure", "Notification", "SubagentStop"],
            "Claude Code 原生事件名必须来自 adapter 能力目录")
        expect(claude.allSatisfy { $0.support == .supported }, "Claude Code 必须是 5/5 supported")

        expect(codex.map(\.event) == Event.allCases, "Codex 也必须保留五格，unsupported 不能被隐藏")
        expect(codex.filter(\.isAudibleCapability).count == 4, "Codex 的正常能力事实必须严格是 4/5")
        expect(
            codex.first(where: { $0.event == .stopFailure })
                == HostCapabilityBinding(
                    host: .codex, event: .stopFailure, nativeEvent: nil,
                    support: .unsupported, qualification: "Codex 暂无执行中断事件"),
            "Codex StopFailure 必须 unsupported，不能降级映射到 Stop")
        expect(
            codex.first(where: { $0.event == .notification })?.nativeEvent == "PermissionRequest",
            "Codex 的需要你只能来自 PermissionRequest")
        expect(
            codex.first(where: { $0.event == .notification })?.support == .partial,
            "Codex PermissionRequest 必须标成 partial，而不是完整 Notification")
        expect(
            codex.first(where: { $0.event == .notification })?.qualification == "仅授权请求",
            "可见文案与 VoiceOver 共用的限定语必须是“仅授权请求”")
    }

    suite("原生事件归一化：UserPromptSubmit 映射任务开始，未知事件与 Codex StopFailure 拒绝") {
        expect(
            HostCapabilityCatalog.semanticEvent(host: .claudeCode, nativeEvent: "UserPromptSubmit")
                == .taskStart,
            "Claude Code UserPromptSubmit 必须映射任务开始")
        expect(
            HostCapabilityCatalog.semanticEvent(host: .codex, nativeEvent: "UserPromptSubmit")
                == .taskStart,
            "Codex UserPromptSubmit 必须映射任务开始")
        expect(
            HostCapabilityCatalog.semanticEvent(host: .claudeCode, nativeEvent: "StopFailure")
                == .stopFailure,
            "Claude Code StopFailure 必须映射到执行中断")
        expect(
            HostCapabilityCatalog.semanticEvent(host: .codex, nativeEvent: "PermissionRequest")
                == .notification,
            "Codex PermissionRequest 必须映射到需要你")
        expect(
            HostCapabilityCatalog.semanticEvent(host: .codex, nativeEvent: "StopFailure") == nil,
            "Codex StopFailure 不能播放或被降级映射")
        expect(
            HostCapabilityCatalog.semanticEvent(host: .codex, nativeEvent: "SomethingNew") == nil,
            "未知 Codex 事件必须失败关闭")
    }

    suite("AudibilityMatrix 完全消费 adapter 能力数据，Codex 4/5 是中性就绪") {
        let readySnapshots = [
            HostIntegrationSnapshot.connectedForTesting(host: .claudeCode),
            HostIntegrationSnapshot.connectedForTesting(host: .codex),
        ]
        let coverage = Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0, true) })
        let enabled = Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0, true) })
        let matrix = AudibilityMatrix.make(
            snapshots: readySnapshots,
            capabilities: Dictionary(
                uniqueKeysWithValues: HostID.allCases.map {
                    ($0, HostCapabilityCatalog.bindings(for: $0))
                }),
            soundCoverage: coverage,
            enabledEvents: enabled)

        expect(matrix.rows.count == 5, "矩阵必须有五张语义事件行")
        expect(matrix.rows.allSatisfy { $0.cells.count == 2 }, "每个事件必须永久保留两条宿主子行")
        expect(matrix.summary(for: .claudeCode) == .ready(supported: 5, total: 5), "Claude 5/5 ready")
        expect(matrix.summary(for: .codex) == .ready(supported: 4, total: 5), "Codex 4/5 是正常 ready")
        expect(
            matrix.cell(host: .codex, event: .stopFailure)?.state == .unsupported,
            "Codex 执行中断格必须以中性 unsupported 存在")
        expect(
            matrix.cell(host: .codex, event: .notification)?.accessibilityLabel
                == "Codex，需要你，仅授权请求，部分支持，已连接，可听",
            "VoiceOver 必须说出宿主、声音语义、限定语、支持级别、连接状态和可听状态，"
                + "但不拿原生 key 当主文案")

        var mutated = HostCapabilityCatalog.bindings(for: .codex)
        mutated.removeAll { $0.event == .subagentStop }
        let mutationMatrix = AudibilityMatrix.make(
            snapshots: readySnapshots,
            capabilities: [
                .claudeCode: HostCapabilityCatalog.bindings(for: .claudeCode),
                .codex: mutated,
            ],
            soundCoverage: coverage,
            enabledEvents: enabled)
        expect(
            mutationMatrix.summary(for: .codex) == .ready(supported: 3, total: 5),
            "删除 Codex 映射必须改变矩阵，证明第四格不是 UI 硬编码")
        expect(
            mutationMatrix.cell(host: .codex, event: .subagentStop)?.state == .unsupported,
            "能力数据缺格时矩阵必须失败关闭为 unsupported")
    }

    suite("AudibilityMatrix：未安装且未连接是中性空态，不是 degraded") {
        let snapshots = HostID.allCases.map { host in
            HostIntegrationSnapshot(
                host: host,
                runtime: .ready,
                availability: .unavailable(reason: "未检测到配置目录"),
                configuration: .notConfigured,
                writability: .unknown,
                activation: .none)
        }
        let matrix = AudibilityMatrix.make(
            snapshots: snapshots,
            capabilities: Dictionary(
                uniqueKeysWithValues: HostID.allCases.map {
                    ($0, HostCapabilityCatalog.bindings(for: $0))
                }),
            soundCoverage: Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0, true) }),
            enabledEvents: Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0, true) }))

        expect(
            matrix.summary(for: .claudeCode) == .notConnected(supported: 5, total: 5),
            "未安装 Claude Code 应保持中性 5/5 未连接")
        expect(
            matrix.summary(for: .codex) == .notConnected(supported: 4, total: 5),
            "未安装 Codex 应保持中性 4/5 未连接")
        expect(
            matrix.cell(host: .codex, event: .stop)?.state == .notConnected,
            "支持的 Codex 格应显示未连接，不能显示红色 degraded")
        expect(
            matrix.cell(host: .codex, event: .stopFailure)?.state == .unsupported,
            "能力本身不支持仍优先显示 unsupported")
    }

    suite("Shared runtime inspect：helper 必须是非空、可执行、无隔离的普通文件") {
        withTempDirectory { root in
            let fixture = makeSharedRuntimeFixture(root: root, missingEvent: nil)
            writeSharedRuntimeExecutable(at: fixture.helper)
            let bootstrapper = SystemSharedRuntimeBootstrapper(environment: fixture.environment)
            expect(bootstrapper.inspect() == .ready, "健康 helper + 完整声音包必须 ready")

            try! Data().write(to: fixture.helper, options: .atomic)
            try! FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: fixture.helper.path)
            expectSharedRuntimeDamaged(
                bootstrapper.inspect(), contains: "空",
                "0 字节 helper 不得被认为 ready")

            writeSharedRuntimeExecutable(at: fixture.helper)
            try! FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: fixture.helper.path)
            expectSharedRuntimeDamaged(
                bootstrapper.inspect(), contains: "执行",
                "无执行位 helper 不得被认为 ready")

            writeSharedRuntimeExecutable(at: fixture.helper)
            setSharedRuntimeQuarantine(at: fixture.helper)
            expectSharedRuntimeDamaged(
                bootstrapper.inspect(), contains: "隔离",
                "带 quarantine 的 helper 不得被认为 ready")
            stripQuarantineAttribute(at: fixture.helper)

            let realHelper = root.appendingPathComponent("real-claudio")
            try! FileManager.default.moveItem(at: fixture.helper, to: realHelper)
            try! FileManager.default.createSymbolicLink(
                at: fixture.helper, withDestinationURL: realHelper)
            expectSharedRuntimeDamaged(
                bootstrapper.inspect(), contains: "普通文件",
                "固定 helper 路径不得用 symlink 冒充普通文件")

            try! FileManager.default.removeItem(at: realHelper)
            expectSharedRuntimeDamaged(
                bootstrapper.inspect(), contains: "普通文件",
                "悬空 symlink 仍是损坏的 helper 节点，不能伪装成从未发布")
        }
    }

    suite("Shared runtime inspect：声音包只缺单事件时保持 ready，由矩阵精确显示 missingSound") {
        withTempDirectory { root in
            let fixture = makeSharedRuntimeFixture(root: root, missingEvent: .notification)
            writeSharedRuntimeExecutable(at: fixture.helper)
            let runtime = SystemSharedRuntimeBootstrapper(environment: fixture.environment).inspect()
            expect(
                runtime == .ready,
                "partial 声音包仍能播放其他事件，不得把共享 runtime 整体判 damaged")

            let installationID = UUID(uuidString: "ABABABAB-1234-4ABC-8DEF-ABABABABABAB")!
            let snapshot = HostIntegrationSnapshot(
                host: .claudeCode,
                runtime: runtime,
                availability: .available,
                configuration: .configured,
                writability: .writable,
                activation: .observed(
                    HostReceiptEvidence(
                        installationID: installationID,
                        nativeEvent: "UserPromptSubmit",
                        event: .taskStart,
                        timestamp: Date(timeIntervalSince1970: 1),
                        playbackResult: .played)),
                installationID: installationID)
            let matrix = AudibilityMatrix.make(
                snapshots: [snapshot],
                capabilities: [.claudeCode: HostCapabilityCatalog.bindings(for: .claudeCode)],
                soundCoverage: Dictionary(
                    uniqueKeysWithValues: Event.allCases.map { ($0, $0 != .notification) }),
                enabledEvents: Dictionary(
                    uniqueKeysWithValues: Event.allCases.map { ($0, true) }))

            expect(
                matrix.summary(for: .claudeCode) == .ready(supported: 5, total: 5),
                "单事件缺音不得把宿主来源行整体降级")
            expect(
                matrix.cell(host: .claudeCode, event: .notification)?.state == .missingSound,
                "只有缺失的需要你格应显示 missingSound")
            expect(
                matrix.cell(host: .claudeCode, event: .stop)?.state == .audible,
                "仍有文件的本轮结束格必须保持 audible")
        }
    }
}

private struct SharedRuntimeFixture {
    let helper: URL
    let environment: SetupEnvironment
}

@MainActor
private func makeSharedRuntimeFixture(
    root: URL,
    missingEvent: Event?
) -> SharedRuntimeFixture {
    let claudioRoot = root.appendingPathComponent(".claudio", isDirectory: true)
    let helper = claudioRoot.appendingPathComponent("bin/claudio")
    let packs = claudioRoot.appendingPathComponent("packs", isDirectory: true)
    let pack = packs.appendingPathComponent("runtime-fixture", isDirectory: true)
    let config = claudioRoot.appendingPathComponent("config.json")
    try! FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
    writeFixture(#"{"selected_pack":"runtime-fixture"}"#, to: config)

    let eventFiles: [(Event, String)] = [
        (.taskStart, "task-start.mp3"),
        (.stop, "stop.mp3"),
        (.stopFailure, "stop-failure.mp3"),
        (.notification, "notification.mp3"),
        (.subagentStop, "subagent-stop.mp3"),
    ]
    let manifestEvents = Dictionary(
        uniqueKeysWithValues: eventFiles.map { ($0.0.manifestKey, $0.1) })
    let manifest: [String: Any] = [
        "id": "runtime-fixture",
        "name": "Runtime Fixture",
        "author": "Tests",
        "version": "1",
        "events": manifestEvents,
    ]
    let manifestData = try! JSONSerialization.data(
        withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try! manifestData.write(to: pack.appendingPathComponent("manifest.json"))
    for (event, filename) in eventFiles where event != missingEvent {
        writeFixture("audio", to: pack.appendingPathComponent(filename))
    }

    return SharedRuntimeFixture(
        helper: helper,
        environment: SetupEnvironment(
            executablePath: helper,
            claudioBinaryDestination: helper,
            userPacksDirectory: packs,
            configFile: config,
            settingsFile: root.appendingPathComponent(".claude/settings.json"),
            configLockFile: claudioRoot.appendingPathComponent("config.lock"),
            settingsLockFile: claudioRoot.appendingPathComponent("settings.lock"),
            packsLockFile: claudioRoot.appendingPathComponent("packs.lock")))
}

@MainActor
private func writeSharedRuntimeExecutable(at url: URL) {
    try! FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: url)
    FileManager.default.createFile(
        atPath: url.path,
        contents: Data("#!/bin/sh\nexit 0\n".utf8),
        attributes: [.posixPermissions: 0o755])
}

@MainActor
private func setSharedRuntimeQuarantine(at url: URL) {
    let value = "0083;68713a00;Safari;\(UUID().uuidString)"
    _ = value.withCString { pointer in
        setxattr(url.path, quarantineAttributeName, pointer, strlen(pointer), 0, 0)
    }
}

@MainActor
private func expectSharedRuntimeDamaged(
    _ health: SharedRuntimeHealth,
    contains expectedText: String,
    _ message: String
) {
    guard case .damaged(let reason) = health else {
        expect(false, "\(message)；got \(health)")
        return
    }
    expect(reason.contains(expectedText), "\(message)；reason=\(reason)")
}
