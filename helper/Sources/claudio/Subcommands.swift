import ArgumentParser
import ClaudioCore
import Foundation

extension Claudio {
    /// `claudio doctor` — self-check: afplay 在位、settings.json 可写（只读探测，绝不真
    /// 写）、当前声音包完整（无配置/无包 → warning，不判红）、claudio.log 尾部近期失败汇总
    /// （T6）。硬问题（afplay 缺 / settings.json 不可写）才让退出码非 0。
    struct Doctor: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "自检：afplay 在位、settings.json 可写、声音包完整（只读探测，不写入/不播放）。"
        )

        func run() throws {
            let report = runDoctorChecks()
            print("claudio doctor")
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
            abstract: "hook 调用：播放某事件的声音（跳过式去抖 + 后台 spawn afplay，立即 exit 0）。"
        )

        @Argument(help: "事件：stop / stop_failure / notification / subagent_stop")
        var event: String

        func run() throws {
            _ = playSoundEvent(event)
        }
    }

    /// `claudio install` — take over settings.json hooks (idempotent追加，见 ENGINEERING.md
    /// "settings.json 接管：追加而非覆盖").
    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "把 hook 写进 settings.json（幂等追加，不覆盖已有配置）。"
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

    /// `claudio uninstall` — precisely remove claudio's hook entries, preserving every
    /// other hook (ENGINEERING.md 工程落地细节 ③: 命令精确等值匹配，非子串)。
    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "精准摘除 claudio 的 hook 条目、保留其它 hook。"
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
            abstract: "v1 首次安装自举：复制二进制 + 内置声音包到 ~/.claudio/、默认选包、写 hooks（见 ENGINEERING.md T17）。"
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

private func printSetupSummary(_ outcome: SetupOutcome) {
    switch outcome {
    case .completed(let copiedBinary, let copiedPacks, let selectedPack, let hooksOutcome):
        print("✓ Claudio 首次安装自举完成")
        print(
            copiedBinary
                ? "  · 二进制已复制到 ~/.claudio/bin/claudio"
                : "  · 二进制已在 ~/.claudio/bin/claudio（跳过复制）")
        if copiedPacks.isEmpty {
            print("  · 没有发现需要复制的新内置声音包")
        } else {
            print("  · 已复制内置声音包：\(copiedPacks.joined(separator: ", "))")
        }
        if let selectedPack {
            print("  · 已默认选中声音包 \"\(selectedPack)\"")
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
        "已接管 settings.json（追加 hook，未覆盖已有配置；备份见 settings.json.claudio.bak）"
    case .alreadyInstalled:
        "settings.json 已接管过，无需重复操作"
    }
}
