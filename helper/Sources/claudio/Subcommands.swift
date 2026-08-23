import ArgumentParser
import ClaudioCore
import Foundation

extension Claudio {
    /// 新版宿主 hook 入口。生成的配置始终传合法参数；即使配置被手改成未知宿主/事件/UUID，
    /// 这里也静默返回成功，绝不把宿主工作流卡在声音工具上。
    struct Hook: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "宿主 hook 回调：严格映射、宿主级去抖、写最小真实回执并立即退出。")

        @Argument(help: "宿主：claude-code / codex / workbuddy") var host: String
        @Argument(help: "宿主原生事件名") var nativeEvent: String
        @Option(name: .long, help: "当前连接 installation UUID") var installationID: String

        func run() throws {
            guard let parsedHost = HostID(rawValue: host),
                let parsedID = UUID(uuidString: installationID)
            else { return }
            let environment = systemHostHookEnvironment(for: parsedHost)
            _ = handleHostHook(
                host: parsedHost,
                nativeEvent: nativeEvent,
                installationID: parsedID,
                environment: environment)
        }
    }

    struct Integrations: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "查看、连接或断开已出货的声音来源。",
            subcommands: [Status.self, Connect.self, Disconnect.self])

        struct Status: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "只读检查共享 runtime 与全部已出货宿主。")

            @Flag(name: .long, help: "输出机器可读 JSON") var json = false

            mutating func run() async throws {
                let manager = makeSystemIntegrationManager()
                let snapshots = await manager.refresh()
                if json {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    encoder.dateEncodingStrategy = .iso8601
                    let data = try encoder.encode(snapshots)
                    print(String(decoding: data, as: UTF8.self))
                    return
                }
                print("claudi0 声音来源")
                if let runtime = snapshots.first?.runtime {
                    print("  共享 runtime: \(sharedRuntimeText(runtime))")
                }
                for snapshot in snapshots {
                    print("  \(snapshot.host.displayName): \(integrationSnapshotText(snapshot))")
                }
            }
        }

        struct Connect: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "连接指定宿主；先幂等自举共享 runtime。")

            @Argument(help: "claude-code / codex / workbuddy") var host: String

            mutating func run() async throws {
                guard let hostID = HostID(rawValue: host) else {
                    print("✗ 未知宿主：\(host)")
                    throw ExitCode.failure
                }
                let manager = makeSystemIntegrationManager()
                switch await manager.connect(hostID) {
                case .success(let snapshot):
                    print("✓ \(hostID.displayName)：\(integrationSnapshotText(snapshot))")
                    if hostID == .codex, case .awaitingReceipt = snapshot.activation {
                        print("  在 Codex 输入 /hooks，确认后再提交一次提示词。")
                    }
                case .failure(let error):
                    print("✗ \(error.description)")
                    throw ExitCode.failure
                }
            }
        }

        struct Disconnect: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "只摘除指定宿主的 claudi0 条目，保留共享 runtime 与第三方配置。")

            @Argument(help: "claude-code / codex / workbuddy") var host: String

            mutating func run() async throws {
                guard let hostID = HostID(rawValue: host) else {
                    print("✗ 未知宿主：\(host)")
                    throw ExitCode.failure
                }
                let manager = makeSystemIntegrationManager()
                switch await manager.disconnect(hostID) {
                case .success:
                    print("✓ 已断开 \(hostID.displayName)；另一宿主、声音包与第三方 hooks 均未修改")
                case .failure(let error):
                    print("✗ \(error.description)")
                    throw ExitCode.failure
                }
            }
        }
    }

    struct Acceptance: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "生成只读验收证据；不连接、不修复、不断开、不试听。",
            subcommands: [WorkBuddyPreflight.self])

        struct WorkBuddyPreflight: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "workbuddy-preflight",
                abstract: "采集 WorkBuddy 脱敏 preflight 基线。")

            @Flag(name: .long, help: "输出机器可读 JSON；默认输出脱敏 Markdown")
            var json = false

            @Option(name: .long, help: "当前 checkout 的 commit SHA；省略时只读读取 git HEAD")
            var commitSHA: String?

            mutating func run() async throws {
                let report = try await makeWorkBuddyAcceptancePreflight(
                    explicitCommitSHA: commitSHA)
                if json {
                    print(String(decoding: try report.jsonData(), as: UTF8.self))
                } else {
                    print(report.markdown())
                }
            }
        }
    }

    /// `claudio doctor` — self-check: afplay 在位、settings.json 可写（只读探测，绝不真
    /// 写）、当前声音包完整（无配置/无包 → warning，不判红）、claudio.log 尾部近期失败汇总
    /// （T6）。硬问题（afplay 缺 / settings.json 不可写）才让退出码非 0。
    struct Doctor: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "只读自检 shared runtime、声音包与已出货宿主；不写入、不播放。"
        )

        func run() throws {
            let report = runDoctorChecks(
                environment: DoctorEnvironment(integrations: DoctorIntegrationsEnvironment()))
            print("claudi0 doctor")
            for result in report.results {
                print("  \(result.message)")
            }
            print("  events : \(Event.allCases.map(\.cliName).joined(separator: ", "))")
            if report.hasFailure {
                throw ExitCode.failure
            }
        }
    }

    /// `claudio play <event>` — hook entry: debounced background-spawn playback
    /// (跳过式去抖 + 后台 spawn afplay + 立即 exit 0 + 逐事件 enabled). The entire pipeline
    /// lives in `ClaudioCore.playSoundEvent` (see `Play.swift`); every non-happy path
    /// (unknown event, muted event, incomplete pack, contended/broken lock) resolves
    /// silently there, and this subcommand ignores the returned outcome and always
    /// returns success — a hook must never fail or block Claude Code (ENGINEERING.md
    /// 决议 5 +「工程落地细节 ④ 播放必须异步，绝不卡住 Claude Code」—— *not* 决议 10 / 16,
    /// which don't exist: 权威决议表只到 6，10/16 是修订记录的历史快照条目).
    struct Play: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "legacy hook 入口：按声音语义播放（全局去抖，立即 exit 0）。"
        )

        @Argument(help: "事件：task_start / stop / stop_failure / notification / subagent_stop")
        var event: String

        func run() throws {
            _ = playSoundEvent(event)
        }
    }

    /// Claude Code legacy compatibility alias；不静默升级成真实回执连接。
    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "兼容别名：把 legacy hook 写进 Claude Code settings.json。"
        )
        func run() throws {
            do {
                try ensurePrivateDirectoryTree(at: ClaudioPaths.root)
            } catch {
                print("✗ 无法安全准备 Claudio 私有目录：\(error)")
                throw ExitCode.failure
            }
            let pipeline: LegacyInstallPipelineReport
            switch legacyInstallPipelineReport() {
            case .success(let report): pipeline = report
            case .failure(let error):
                print("✗ \(error.description)")
                throw ExitCode.failure
            }
            switch installClaudioHooks() {
            case .success(let outcome):
                print("✓ \(legacyHooksOutcomeMessage(outcome))")
                for warning in legacyInstallWarningMessages(pipeline.warnings) {
                    print("  \(warning)")
                }
            case .failure(let error):
                print("✗ \(error.description)")
                throw ExitCode.failure
            }
        }
    }

    /// Claude Code legacy compatibility alias：precisely remove claudio's hook entries, preserving every
    /// other hook (ENGINEERING.md 工程落地细节 ③: 命令精确等值匹配，非子串)。
    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Claude Code legacy 兼容别名：精准摘除 claudi0 条目并保留其它 hook。"
        )
        func run() throws {
            switch uninstallClaudioHooks() {
            case .success(.uninstalled(let count)):
                print("✓ 已从 settings.json 摘除 \(count) 条 claudio hook，其它 hook 保持不变")
            case .success(.notInstalled):
                print("✓ settings.json 中没有 claudio hook，无需操作")
            case .failure(let error):
                print("✗ \(error.description)")
                throw ExitCode.failure
            }
        }
    }

    /// `claudio use <pack-id>` — switch the active sound pack by *writing* config
    /// (ENGINEERING.md「工程落地细节 ⑥ config.json 归属」—— *not* T5, which is `play` and
    /// only ever *reads* config; 真实实现见 T17）。
    struct Use: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "切换当前声音包（写入 ~/.claudio/config.json）。"
        )
        @Argument(help: "声音包 id") var packID: String
        @Option(name: .long, help: "可选 surface：claude-code / codex / workbuddy")
        var surface: String?
        func run() throws {
            if let surface {
                guard let surfaceID = HostSurfaceID(rawValue: surface) else {
                    print("✗ 未知 surface：\(surface)")
                    throw ExitCode.failure
                }
                switch setSurfacePack(packID, surface: surfaceID) {
                case .success:
                    print("✓ 已将 \(surface) 的声音包覆盖切换为 \"\(packID)\"")
                case .failure(let error):
                    print("✗ \(error.description)")
                    throw ExitCode.failure
                }
                return
            }
            switch selectPack(packID) {
            case .success(.selected(let id)):
                print("✓ 已切换到声音包 \"\(id)\"")
            case .failure(let error):
                print("✗ \(error.description)")
                throw ExitCode.failure
            }
        }
    }

    /// `claudio setup` — v1 Terminal 首次安装自举（ENGINEERING.md T17）：真身菜单栏面板
    /// （T15）落地前的过渡方案，把随 app bundle 分发的二进制 + 内置声音包复制到
    /// `~/.claudio/`、建立首次默认选包、再调 `claudio install` 写 hooks。只在从 app bundle
    /// 内运行时才有实质工作可做；已经装到 `~/.claudio/bin/` 后重复运行只会幂等地补 hooks。
    struct Setup: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "legacy 自举：准备 shared runtime 并连接 Claude Code legacy hooks；不连接 Codex。"
        )
        func run() throws {
            let environment = SetupEnvironment(executablePath: currentExecutablePath())
            switch performFirstRunSetup(environment: environment) {
            case .success(let outcome):
                printSetupSummary(outcome)
                switch legacyInstallPipelineReport(
                    configFile: environment.configFile,
                    userPacksDirectory: environment.userPacksDirectory,
                    bundledPacksDirectory: nil)
                {
                case .success(let report):
                    for warning in legacyInstallWarningMessages(report.warnings) {
                        print("  \(warning)")
                    }
                case .failure(let error):
                    // setup 保留空包/部分包的 GUI 可修复语义；只在摘要中诚实标出当前不会发声。
                    print("  ⚠ \(error.description)")
                }
            case .failure(let error):
                print("✗ \(error.description)")
                throw ExitCode.failure
            }
        }
    }
}

private func makeSystemIntegrationManager() -> HostIntegrationManager {
    HostIntegrationManager(
        adapters: [
            ClaudeCodeIntegrationAdapter(), CodexIntegrationAdapter(),
            WorkBuddyIntegrationAdapter(),
        ],
        bootstrapper: SystemSharedRuntimeBootstrapper(
            environment: SetupEnvironment(executablePath: currentExecutablePath())))
}

private func makeWorkBuddyAcceptancePreflight(
    explicitCommitSHA: String?
) async throws -> WorkBuddyAcceptancePreflight {
    let statusSnapshots = await makeSystemIntegrationManager().refresh()
    guard let statusSnapshot = statusSnapshots.first(where: { $0.host == .workBuddy }) else {
        throw ValidationError("integrations status 未返回 WorkBuddy surface")
    }

    // 三个事实入口都必须保持只读：manager.refresh() 对应 integrations status；显式调用
    // adapter 的 inspect 对应 Inspect；runDoctorChecks 只做 probe/read。这里没有调用
    // HostIntegrationManager 的 connect、disconnect 或任何播放入口。
    let workBuddyEnvironment = WorkBuddyIntegrationEnvironment()
    let inspectedSnapshot = inspectWorkBuddySnapshot(
        environment: workBuddyEnvironment,
        runtime: statusSnapshot.runtime)
    let doctor = runDoctorChecks(
        environment: DoctorEnvironment(integrations: DoctorIntegrationsEnvironment()))
    let workBuddyDoctor = doctor.results.first { $0.name == "host-workbuddy" }?.severity ?? .failure

    return WorkBuddyAcceptancePreflight(
        commitSHA: try acceptanceCommitSHA(explicit: explicitCommitSHA),
        claudioVersion: ClaudioVersion.current,
        workBuddy: WorkBuddyApplicationIdentity.detect(),
        machine: WorkBuddyMachineIdentity.current(),
        inspectedSnapshot: inspectedSnapshot,
        statusSnapshot: statusSnapshot,
        workBuddyDoctor: workBuddyDoctor,
        overallDoctor: overallDoctorSeverity(doctor),
        scopeFingerprint: HostActivationScope.workBuddy())
}

private func acceptanceCommitSHA(explicit: String?) throws -> String {
    let candidate: String
    if let explicit {
        candidate = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        let result = SystemCommandRunner().run(
            executablePath: "/usr/bin/git",
            arguments: ["rev-parse", "--verify", "HEAD"],
            timeout: 1.0)
        guard case .completed(let exitCode, let stdout) = result, exitCode == 0 else {
            throw ValidationError("无法只读读取当前 checkout 的 git HEAD；请显式传入 --commit-sha")
        }
        candidate = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard candidate.range(of: "^[0-9a-fA-F]{7,64}$", options: .regularExpression) != nil else {
        throw ValidationError("commit SHA 必须是 7 到 64 位十六进制字符串")
    }
    return candidate
}

private func overallDoctorSeverity(_ report: DoctorReport) -> DoctorSeverity {
    if report.hasFailure { return .failure }
    if report.results.contains(where: { $0.severity == .warning }) { return .warning }
    return .ok
}

private func integrationSnapshotText(_ snapshot: HostIntegrationSnapshot) -> String {
    if case .unavailable(let reason) = snapshot.availability {
        if snapshot.configuration == .notConfigured {
            return "未安装或未连接：\(reason)"
        }
        return "需要处理：已有 claudi0 配置，但宿主不可用（\(reason)）"
    }
    if case .notWritable(let reason) = snapshot.writability,
        snapshot.configuration != .notConfigured
    {
        return "需要处理：已有 claudi0 配置，但无法维护（\(reason)）"
    }
    if snapshot.configuration != .notConfigured {
        switch snapshot.runtime {
        case .ready:
            break
        case .unavailable(let reason), .damaged(let reason):
            return "需要处理：共享 runtime 不可用（\(reason)）"
        }
    }
    switch snapshot.configuration {
    case .notConfigured:
        return "未连接"
    case .legacyConnected:
        return "旧版连接，可听但暂无真实回执"
    case .incomplete(let missing):
        return "配置不完整，缺少 \(missing.joined(separator: ", "))"
    case .unreadable(let reason), .conflict(let reason):
        return "需要处理：\(reason)"
    case .configured:
        switch snapshot.activation {
        case .observed:
            let supported = HostCapabilityCatalog.bindings(for: snapshot.host)
                .filter(\.isAudibleCapability).count
            return "\(supported)/\(Event.allCases.count) 已就绪"
        case .none, .awaitingReceipt:
            return snapshot.host == .codex
                ? "在 Codex 输入 /hooks，确认后再提交一次提示词"
                : "已配置，请提交一次提示词以确认连接"
        }
    }
}

private func sharedRuntimeText(_ runtime: SharedRuntimeHealth) -> String {
    switch runtime {
    case .ready:
        "已就绪"
    case .unavailable(let reason):
        "尚不可用：\(reason)"
    case .damaged(let reason):
        "需要处理：\(reason)"
    }
}

private func printSetupSummary(_ outcome: SetupOutcome) {
    for line in setupSummaryLines(outcome) {
        print(line)
    }
}
