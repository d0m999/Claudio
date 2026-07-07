import ArgumentParser

/// `claudio` — the helper CLI invoked by Claude Code hooks.
///
/// v1 base skeleton: the command surface is wired up so the project builds and tests
/// green from day one. Individual subcommand bodies land in T2–T6 (see ../ENGINEERING.md).
@main
struct Claudio: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "claudio",
        abstract: "Claudio — Claude Code 的语义化提示音 helper。",
        version: "0.0.1",
        subcommands: [Doctor.self, Play.self, Install.self, Uninstall.self, Use.self]
    )
}
