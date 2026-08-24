import ClaudioCore
import Darwin
import Foundation

@MainActor
func runHostIntegrationModelSuites() {
    suite("activation scope：宿主版本、Claudio 版本与当前 binding schema 共同决定身份") {
        let v1 = HostActivationScope.fingerprint(host: .claudeCode, hostVersion: " 2.1.206\n")
        let v2 = HostActivationScope.fingerprint(host: .claudeCode, hostVersion: "2.1.207")
        expect(v1 != nil && v1 != v2, "宿主版本变化必须改变 activation scope")
        expect(
            v1?.contains("surface=claude-code") == true
                && v1?.contains("claudio=\(ClaudioVersion.current)") == true
                && HostCapabilityCatalog.bindings(for: .claudeCode)
                    .filter(\.isAudibleCapability)
                    .allSatisfy { v1?.contains($0.id.rawValue) == true },
            "scope 必须绑定 surface、Claudio 版本与所有当前可听 binding")
        expect(
            HostActivationScope.fingerprint(host: .claudeCode, hostVersion: "  \n") == nil,
            "空版本身份必须失败关闭")
    }

    suite("activation scope：GUI PATH 缺少用户目录时仍从绝对路径探测 Claude 与 Codex") {
        withTempDirectory { root in
            let claude = root.appendingPathComponent(".local/bin/claude")
            let codex = root.appendingPathComponent(
                ".nvm/versions/node/v22.5.0/bin/codex")
            let node = codex.deletingLastPathComponent().appendingPathComponent("node")
            writeFixture("#!/bin/sh\nexit 0\n", to: claude)
            writeFixture("#!/usr/bin/env node\n", to: codex)
            writeFixture("#!/bin/sh\nprintf 'codex-cli 0.43.0\\n'\n", to: node)
            for executable in [claude, codex, node] {
                try! FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: executable.path)
            }

            let locator = HostExecutableLocator.standard(
                environmentPath: "/usr/bin:/bin",
                environment: [:],
                homeDirectory: root)
            let claudeRunner = ActivationScopeCommandRunner(
                result: .completed(exitCode: 0, stdout: "2.1.207 (Claude Code)\n"))
            let codexRunner = ActivationScopeCommandRunner(
                result: .completed(exitCode: 0, stdout: "codex-cli 0.42.0\n"))
            let claudeScope = HostActivationScope.claudeCode(
                executableLocator: locator,
                commandRunner: claudeRunner)
            let codexScope = HostActivationScope.codex(
                executableLocator: locator,
                commandRunner: codexRunner)

            expect(
                claudeRunner.executablePaths == [claude.path],
                "Claude scope 必须直接执行 ~/.local/bin 的绝对路径，不能交给 GUI PATH 查找")
            expect(
                codexRunner.executablePaths == [codex.path],
                "Codex scope 必须从 NVM 目录解析绝对路径，不能依赖 Finder PATH")
            expect(
                claudeScope?.contains("host=2.1.207 (Claude Code)") == true,
                "Claude 绝对路径版本输出必须进入 scope")
            expect(
                codexScope?.contains("host=cli=codex-cli 0.42.0") == true,
                "Codex 绝对路径版本输出必须进入 scope")

            let nvmOnlyLocator = HostExecutableLocator(
                searchDirectories: [codex.deletingLastPathComponent()])
            expect(
                HostActivationScope.codex(executableLocator: nvmOnlyLocator)?
                    .contains("host=cli=codex-cli 0.43.0") == true,
                "绝对 npm shim 的 /usr/bin/env node 必须从解析后的 NVM 目录启动")
        }
    }

    suite("activation scope：Volta/mise dispatcher 必须通过原始 shim 路径执行") {
        withTempDirectory { root in
            let shimDirectory = root.appendingPathComponent(".volta/bin", isDirectory: true)
            let dispatcher = shimDirectory.appendingPathComponent("volta-shim")
            let claude = shimDirectory.appendingPathComponent("claude")
            let codex = shimDirectory.appendingPathComponent("codex")
            writeFixture(
                """
                #!/bin/sh
                case "${0##*/}" in
                    claude) printf '2.1.207 (Claude Code)\\n' ;;
                    codex) printf 'codex-cli 0.42.0\\n' ;;
                    *) exit 64 ;;
                esac
                """,
                to: dispatcher)
            try! FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: dispatcher.path)
            try! FileManager.default.createSymbolicLink(
                atPath: claude.path,
                withDestinationPath: dispatcher.path)
            try! FileManager.default.createSymbolicLink(
                atPath: codex.path,
                withDestinationPath: dispatcher.path)

            let locator = HostExecutableLocator(searchDirectories: [shimDirectory])
            let claudeScope = HostActivationScope.claudeCode(executableLocator: locator)
            let codexScope = HostActivationScope.codex(executableLocator: locator)

            expect(locator.executablePath(command: "claude") == claude.path, "必须保留 claude shim 路径")
            expect(locator.executablePath(command: "codex") == codex.path, "必须保留 codex shim 路径")
            expect(
                claudeScope?.contains("host=2.1.207 (Claude Code)") == true,
                "Claude dispatcher 必须根据 argv[0] 生成版本身份")
            expect(
                codexScope?.contains("host=cli=codex-cli 0.42.0") == true,
                "Codex dispatcher 必须根据 argv[0] 生成版本身份")
        }
    }

    suite("activation scope：mise 自定义、XDG、默认与兼容 shim 目录均可发现") {
        withTempDirectory { root in
            let miseDataDirectory = root.appendingPathComponent("custom-mise", isDirectory: true)
            let xdgDataDirectory = root.appendingPathComponent("xdg-data", isDirectory: true)
            let locator = HostExecutableLocator.standard(
                environmentPath: "/usr/bin:/bin",
                environment: [
                    "MISE_DATA_DIR": miseDataDirectory.path,
                    "XDG_DATA_HOME": xdgDataDirectory.path,
                ],
                homeDirectory: root)
            let paths = locator.searchDirectories.map(\.path)
            let expectedMisePaths = [
                miseDataDirectory.appendingPathComponent("shims", isDirectory: true).path,
                xdgDataDirectory.appendingPathComponent("mise/shims", isDirectory: true).path,
                root.appendingPathComponent(".local/share/mise/shims", isDirectory: true).path,
                root.appendingPathComponent(".mise/shims", isDirectory: true).path,
            ]
            let positions = expectedMisePaths.compactMap { paths.firstIndex(of: $0) }

            expect(positions.count == expectedMisePaths.count, "mise 的四种数据目录必须全部进入候选")
            expect(
                zip(positions, positions.dropFirst()).allSatisfy { $0.0 < $0.1 },
                "mise 候选必须按显式配置、XDG、默认、兼容目录排序")
        }
    }

    suite("activation scope：候选不是可执行普通文件时继续失败关闭") {
        withTempDirectory { root in
            let directoryCandidate = root.appendingPathComponent("bin/claude", isDirectory: true)
            try! FileManager.default.createDirectory(
                at: directoryCandidate,
                withIntermediateDirectories: true)
            let locator = HostExecutableLocator(
                searchDirectories: [directoryCandidate.deletingLastPathComponent()])
            let runner = ActivationScopeCommandRunner(
                result: .completed(exitCode: 0, stdout: "2.1.207 (Claude Code)\n"))

            expect(
                HostActivationScope.claudeCode(
                    executableLocator: locator,
                    commandRunner: runner) == nil,
                "同名目录不得被当成宿主 CLI")
            expect(runner.executablePaths.isEmpty, "无安全绝对路径时不得启动版本子进程")
        }
    }

    suite("宿主能力目录：接口能力与当前实现分离") {
        let claude = HostCapabilityCatalog.bindings(for: .claudeCode)
        let codex = HostCapabilityCatalog.bindings(for: .codex)
        let workBuddy = HostCapabilityCatalog.bindings(for: .workBuddy)

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
                    support: .unsupported, qualification: .codexStopFailureUnavailable),
            "Codex StopFailure 必须 unsupported，不能降级映射到 Stop")
        expect(
            codex.first(where: { $0.event == .notification })?.nativeEvent == "PermissionRequest",
            "Codex 的待响应只能来自 PermissionRequest")
        expect(
            codex.first(where: { $0.event == .notification })?.support == .partial,
            "Codex PermissionRequest 必须标成 partial，而不是完整 Notification")
        expect(
            codex.first(where: { $0.event == .notification })?.qualification
                == .permissionRequestOnly,
            "Core 必须输出稳定 qualification token，不持有本地化文案")
        expect(workBuddy.map(\.event) == Event.allCases, "WorkBuddy 必须始终展示五个语义事件")
        expect(
            workBuddy.filter(\.isAudibleCapability).map(\.event) == [.taskStart, .stop],
            "WorkBuddy 首发只能执行 task_start 与 stop")
        expect(
            workBuddy.filter(\.isDeclaredCapability).count == 5,
            "官方接口能力必须保留在目录中，不能被当前实现数覆盖")
        for host in [HostID.chatGPTDesktopAX, .claudeDesktopAX] {
            let descriptor = host.descriptor
            let bindings = HostCapabilityCatalog.bindings(for: host)
            expect(
                descriptor.mechanism == .accessibilityBeta
                    && descriptor.maturity == .beta
                    && descriptor.controlSurface == .guiOnly,
                "\(host.displayName) 必须是 GUI-only Accessibility Beta surface")
            expect(
                bindings.map(\.event) == Event.allCases
                    && bindings.allSatisfy {
                        $0.support == .unsupported
                            && $0.implementation == .notImplemented
                            && $0.qualification == .accessibilityBetaUnavailable
                            && $0.nativeEvent == nil
                    },
                "AX 候选必须完整占位但不得伪造原生事件或实现能力")
        }
    }

    suite("宿主 registry：正常产品只列三项，AX identity 仅保留兼容解码与隔离诊断") {
        expect(
            HostID.productVisibleCases == [.claudeCode, .codex, .workBuddy],
            "正常产品 registry 必须固定为三个 native-hook surface")
        expect(
            HostID.productVisibleCases.allSatisfy {
                $0.descriptor.mechanism == .nativeHooks
                    && $0.descriptor.maturity == .stable
                    && $0.descriptor.controlSurface == .shared
            },
            "产品可见 registry 不得混入 AX Beta 或 GUI-only identity")
        expect(
            HostID(rawValue: "chatgpt-desktop-ax") == .chatGPTDesktopAX
                && HostID(rawValue: "claude-desktop-ax") == .claudeDesktopAX
                && HostSurfaceID(rawValue: "chatgpt-desktop-ax") == .chatGPTDesktopAX
                && HostSurfaceID(rawValue: "claude-desktop-ax") == .claudeDesktopAX,
            "隐藏 AX 不得破坏历史 token 与 DEBUG tracer identity 的解码")
        expect(
            Set(HostID.productVisibleCases).isDisjoint(with: [
                .chatGPTDesktopAX, .claudeDesktopAX,
            ]),
            "AX identity 不得重新进入正常产品 registry")
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
            "Codex PermissionRequest 必须映射到待响应")
        expect(
            HostCapabilityCatalog.semanticEvent(host: .codex, nativeEvent: "StopFailure") == nil,
            "Codex StopFailure 不能播放或被降级映射")
        expect(
            HostCapabilityCatalog.semanticEvent(host: .codex, nativeEvent: "SomethingNew") == nil,
            "未知 Codex 事件必须失败关闭")
    }

    suite("AudibilityMatrix 完全消费 adapter 能力数据，Codex 4/5 是中性就绪") {
        // 故意输入全部兼容 identity，证明矩阵只投影正常产品 registry。
        let readySnapshots = HostID.allCases.map {
            HostIntegrationSnapshot.connectedForTesting(host: $0)
        }
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
        expect(
            matrix.rows.allSatisfy { $0.cells.count == HostID.productVisibleCases.count },
            "每个事件必须永久保留所有已出货宿主子行")
        expect(
            matrix.rows.allSatisfy { $0.cells.map(\.host) == HostID.productVisibleCases },
            "兼容输入中的 AX identity 不得进入产品可听矩阵")
        expect(
            matrix.summary(for: .chatGPTDesktopAX) == nil
                && matrix.cell(host: .claudeDesktopAX, event: .stop) == nil,
            "产品矩阵不得为 AX identity 生成摘要或格子")
        expect(
            matrix.summary(for: .claudeCode) == .ready(supported: 5, total: 5), "Claude 5/5 ready")
        expect(matrix.summary(for: .codex) == .ready(supported: 4, total: 5), "Codex 4/5 是正常 ready")
        expect(
            matrix.summary(for: .workBuddy) == .ready(supported: 2, total: 5),
            "WorkBuddy 当前实现必须诚实显示 2/5")
        expect(
            matrix.cell(host: .codex, event: .stopFailure)?.state == .unsupported,
            "Codex 执行中断格必须以中性 unsupported 存在")
        expect(
            matrix.cell(host: .codex, event: .notification)?.accessibilityLabel
                == "Codex，待响应，permission_request_only，部分支持，已连接，可听",
            "Core 诊断必须使用稳定限定 token；GUI localization 再投影人类文案")

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
        let snapshots = HostID.productVisibleCases.map { host in
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
                uniqueKeysWithValues: HostID.productVisibleCases.map {
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

    suite("AudibilityMatrix：Claude 旧四事件连接把 taskStart 明确投影为需要升级") {
        let legacy = HostIntegrationSnapshot(
            host: .claudeCode,
            runtime: .ready,
            availability: .available,
            configuration: .legacyConnected,
            writability: .writable,
            activation: .none)
        let matrix = AudibilityMatrix.make(
            snapshots: [legacy],
            capabilities: [.claudeCode: HostCapabilityCatalog.bindings(for: .claudeCode)],
            soundCoverage: Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0, true) }),
            enabledEvents: Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0, true) }))

        let taskStart = matrix.cell(host: .claudeCode, event: .taskStart)
        expect(
            taskStart?.state == .degraded,
            "legacy installer 从未写 UserPromptSubmit，任务开始不得声称 legacy 可听")
        expect(
            taskStart?.detail == "旧版连接未安装此事件，请升级连接",
            "任务开始格必须给出唯一且可操作的升级说明")
        expect(
            taskStart?.accessibilityLabel
                == "Claude Code，任务开始，完整支持，需要处理，不可听，旧版连接未安装此事件，请升级连接",
            "VoiceOver 不得把旧连接的任务开始误报为可听或仅缺声音")
        expect(
            matrix.summary(for: .claudeCode) == .legacy(supported: 4, total: 5),
            "legacy 来源汇总只可计算旧安装器实际写入的四个事件")
        expect(
            matrix.cell(host: .claudeCode, event: .stop)?.state == .legacy,
            "旧安装器实际写入的四个 lifecycle 事件仍应保持 legacy 可听")
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
            let runtime = SystemSharedRuntimeBootstrapper(environment: fixture.environment)
                .inspect()
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
                "只有缺失的待响应格应显示 missingSound")
            expect(
                matrix.cell(host: .claudeCode, event: .stop)?.state == .audible,
                "仍有文件的本轮结束格必须保持 audible")
        }
    }
}

private final class ActivationScopeCommandRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let result: CommandRunResult
    private var recordedExecutablePaths: [String] = []

    init(result: CommandRunResult) {
        self.result = result
    }

    var executablePaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedExecutablePaths
    }

    func run(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> CommandRunResult {
        lock.lock()
        recordedExecutablePaths.append(executablePath)
        lock.unlock()
        return result
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
