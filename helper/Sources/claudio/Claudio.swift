import ArgumentParser
import ClaudioCore

/// `claudi0` — 多个 AI 宿主共用的语义提示音 helper。
///
/// v1 base skeleton: the command surface is wired up so the project builds and tests
/// green from day one. Individual subcommand bodies land in T2–T6 (see ../ENGINEERING.md).
@main
struct Claudio: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "claudi0",
        abstract: "claudi0 — Claude Code、Codex 与 WorkBuddy 的语义化提示音中心。",
        version: ClaudioVersion.current,
        subcommands: [
            Doctor.self, Play.self, Hook.self, Integrations.self, Acceptance.self,
            Install.self, Uninstall.self, Use.self, Setup.self,
        ]
    )
}
