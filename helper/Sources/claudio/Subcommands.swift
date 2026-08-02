import ArgumentParser
import ClaudioCore
import Foundation

extension Claudio {
    /// 新版宿主 hook 入口。生成的配置始终传合法参数；即使配置被手改成未知宿主/事件/UUID，
    /// 这里也静默返回成功，绝不把宿主工作流卡在声音工具上。
    struct Hook: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "宿主 hook 回调：严格映射、宿主级去抖、写最小真实回执并立即退出。")

        @Argument(help: "宿主：claude-code / codex") var host: String
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
            abstract: "查看、连接或断开 Claude Code 与 Codex 声音来源。",
            subcommands: [Status.self, Connect.self, Disconnect.self])

        struct Status: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "只读检查共享 runtime 与两个宿主。")

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

            @Argument(help: "claude-code / codex") var host: String

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
                        print("  claudi0 已写好，等待 Codex 确认；在 Codex 输入 /hooks。")
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

            @Argument(help: "claude-code / codex") var host: String

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

    /// `claudio doctor` — self-check: afplay 在位、settings.json 可写（只读探测，绝不真
    /// 写）、当前声音包完整（无配置/无包 → warning，不判红）、claudio.log 尾部近期失败汇总
    /// （T6）。硬问题（afplay 缺 / settings.json 不可写）才让退出码非 0。
    struct Doctor: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "只读自检 shared runtime、声音包、Claude Code 与 Codex；不写入、不播放。"
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

        @Argument(help: "事件：stop / stop_failure / notification / subagent_stop")
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
            switch installClaudioHooks() {
            case .success(let outcome):
                print("✓ \(hooksOutcomeMessage(outcome))")
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
        func run() throws {
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
            case .failure(let error):
                print("✗ \(error.description)")
                throw ExitCode.failure
            }
        }
    }
}

private func makeSystemIntegrationManager() -> HostIntegrationManager {
    HostIntegrationManager(
        adapters: [ClaudeCodeIntegrationAdapter(), CodexIntegrationAdapter()],
        bootstrapper: SystemSharedRuntimeBootstrapper(
            environment: SetupEnvironment(executablePath: currentExecutablePath())))
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
                ? "claudi0 已写好，等待 Codex 确认"
                : "已配置，等待首个真实事件"
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
    switch outcome {
    case .completed(let copiedBinary, let copiedPacks, let salvaged, let packSelection, let hooksOutcome):
        print("✓ claudi0 首次安装自举完成")
        print(
            copiedBinary
                ? "  · runtime 已复制到 ~/.claudio/bin/claudio，并提供 ~/.claudio/bin/claudi0 命令"
                : "  · runtime 已在 ~/.claudio/bin/claudio，并已同步 ~/.claudio/bin/claudi0 命令")
        if copiedPacks.isEmpty {
            print("  · 没有发现需要复制的新内置声音包")
        } else {
            print("  · 已复制内置声音包：\(copiedPacks.joined(separator: ", "))")
        }
        // ⚠ 而不是 · ：搬走一个用户目录，是这次 setup 里代价最大的一个「我替你做主」。绝不能让它
        // 混在几条 · 里悄悄过去 —— 那个目录里完全可能装着他自己导入的、磁盘上唯一一份音频。
        for pack in salvaged {
            print(
                "  ⚠ \(pack.packID) 读不出 manifest（多半是上次安装被中断留下的残骸，也可能是这个包的"
                    + " manifest 坏了）——已把它**原样搬到** \(pack.movedTo)（一个文件都没删），"
                    + "并重新装了一份干净的")
        }
        switch packSelection {
        case .untouched:
            break  // 用户已有的选择好好的 —— 没什么可报告的。
        case .selectedDefault(let packID):
            print("  · 已默认选中声音包 \"\(packID)\"")
        case .repairedDeadSelection(let removed, let selected):
            // ⚠ 而不是 · ：这是这次 setup 里唯一一件「我替你做了一个你没让我做的决定」的事，
            // 它必须被说出来，而不是混在四条 · 里当成日常。见 `PackSelectionPlan.repairDeadSelection`。
            print(
                "  ⚠ 你之前选的声音包 \"\(removed)\" 已经不在了（或读不出来）——"
                    + "已替你选中 \"\(selected)\"，在面板的切包画廊里随时可以换")
        }
        print("  · \(hooksOutcomeMessage(hooksOutcome))")
    }
}

/// Shared between `claudio install` and `claudio setup`'s summary — both report the same
/// hooks-install outcome, just under a different line prefix (`✓ ` vs `  · `). Kept as one
/// switch so the two user-facing messages can't silently drift out of sync.
private func hooksOutcomeMessage(_ outcome: InstallOutcome) -> String {
    switch outcome {
    case .installed:
        "已连接 Claude Code legacy hooks（追加条目，未覆盖已有配置；备份见 settings.json.claudio.bak）"
    case .alreadyInstalled:
        "Claude Code legacy hooks 已存在，无需重复操作"
    case .modernConnectionPresent:
        "Claude Code 已是现代连接；未追加 legacy hooks，请使用 `claudi0 integrations` 管理"
    }
}
