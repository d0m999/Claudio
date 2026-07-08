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
    /// 决议 5 + 10 + 16).
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
            case .success(.installed):
                print("✓ 已接管 settings.json（追加 hook，未覆盖已有配置；备份见 settings.json.claudio.bak）")
            case .success(.alreadyInstalled):
                print("✓ settings.json 已接管过，无需重复操作")
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

    /// `claudio use <pack-id>` — switch the active sound pack. Lands with config (T5).
    struct Use: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "切换当前声音包（改配置文件，见 T5/config）。"
        )
        @Argument(help: "声音包 id") var packID: String
        func run() throws {
            _ = packID
            throw NotYetImplemented(command: "use", task: "config")
        }
    }
}

/// Placeholder error for base-skeleton subcommands whose bodies land in later tasks.
/// Compiling green today; running one of these prints a clear pointer and exits non-zero.
struct NotYetImplemented: Error, CustomStringConvertible {
    let command: String
    let task: String
    var description: String { "`claudio \(command)` 尚未实现（见 \(task)）。" }
}
