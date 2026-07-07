import ArgumentParser
import ClaudioCore
import Foundation

extension Claudio {
    /// `claudio doctor` — self-check. Base skeleton reports afplay + the known event set.
    /// Full checks (settings.json writable, pack integrity) land with T2/T6.
    struct Doctor: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "自检：afplay 是否在位、已知事件集（完整自检见 T2/T6）。"
        )

        func run() throws {
            let afplay = FileManager.default.isExecutableFile(atPath: "/usr/bin/afplay")
            print("claudio doctor")
            print("  afplay : \(afplay ? "✓ /usr/bin/afplay" : "✗ 未找到")")
            print("  events : \(Event.allCases.map(\.cliName).joined(separator: ", "))")
        }
    }

    /// `claudio play <event>` — hook entry. Base skeleton validates the event and exits 0;
    /// the debounced background-spawn playback pipeline lands in T5.
    struct Play: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "hook 调用：播放某事件的声音（v1 播放链路见 T5）。"
        )

        @Argument(help: "事件：stop / stop_failure / notification / subagent_stop")
        var event: String

        func run() throws {
            // 未知事件 → 静默、退出 0，绝不阻断 Claude Code（ENGINEERING.md 退出码语义）。
            guard Event(cliName: event) != nil else { throw ExitCode.success }
            // TODO(T5): 跳过式去抖 + 后台 spawn afplay + 立即 exit 0。
        }
    }

    /// `claudio install` — take over settings.json hooks (idempotent). Lands in T2.
    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "把 hook 写进 settings.json（幂等追加，见 T2）。"
        )
        func run() throws { throw NotYetImplemented(command: "install", task: "T2") }
    }

    /// `claudio uninstall` — precisely remove claudio's hook entries. Lands in T2.
    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "精准摘除 claudio 的 hook 条目、保留其它 hook（见 T2）。"
        )
        func run() throws { throw NotYetImplemented(command: "uninstall", task: "T2") }
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
