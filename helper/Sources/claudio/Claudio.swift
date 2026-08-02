import ArgumentParser

/// `claudi0` — Claude Code 与 Codex 共用的声音中心 helper。
///
/// v1 base skeleton: the command surface is wired up so the project builds and tests
/// green from day one. Individual subcommand bodies land in T2–T6 (see ../ENGINEERING.md).
@main
struct Claudio: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "claudi0",
        abstract: "claudi0 — Claude Code 与 Codex 的语义化提示音中心。",
        version: "0.0.1",
        subcommands: [
            Doctor.self, Play.self, Hook.self, Integrations.self,
            Install.self, Uninstall.self, Use.self, Setup.self,
        ]
    )
}
