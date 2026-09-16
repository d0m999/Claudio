import ClaudioCore
import Foundation

/// This branch runs in an isolated child so ClaudioPaths evaluates its production defaults
/// against CLAUDIO_TEST_ROOT, without touching the user's real home or rewriting global state.
func runDefaultLockChildProbe() -> Int32 {
    guard CommandLine.arguments.count == 3 else { return 2 }
    switch CommandLine.arguments[2] {
    case "write":
        switch setEventEnabled(.stop, enabled: true) {
        case .success: print("WRITE_OK"); return 0
        case .failure(.lockBusy): print("WRITE_BUSY"); return 0
        case .failure(let error): print("WRITE_ERROR: \(error)"); return 1
        }
    case "play":
        switch playSoundEvent("stop") {
        case .played: print("PLAY_OK"); return 0
        case .skippedDebounce: print("PLAY_BUSY"); return 0
        case let outcome: print("PLAY_ERROR: \(outcome)"); return 1
        }
    default: return 2
    }
}

@MainActor
func runDefaultLockBehaviorSuites() {
    suite("生产默认路径：play/config/settings 锁跨进程互不误阻，同行锁仍争用") {
        let scenarios: [(held: String, action: String, expected: String)] = [
            ("play.lock", "write", "WRITE_OK"),
            ("config.lock", "play", "PLAY_OK"),
            ("settings.lock", "play", "PLAY_OK"),
            ("config.lock", "write", "WRITE_BUSY"),
            ("play.lock", "play", "PLAY_BUSY"),
        ]
        for scenario in scenarios {
            withTempDirectory { directory in
                let home = directory.appendingPathComponent("home", isDirectory: true)
                let root = home.appendingPathComponent(".claudio", isDirectory: true)
                let pack = root.appendingPathComponent("packs/pack-a", isDirectory: true)
                try! FileManager.default.createDirectory(
                    at: pack, withIntermediateDirectories: true)
                try! Data(#"{"selected_pack":"pack-a","master_volume":0,"events":{}}"#.utf8)
                    .write(to: root.appendingPathComponent("config.json"))
                try! Data(#"{"id":"pack-a","events":{"stop":"stop.mp3"}}"#.utf8)
                    .write(to: pack.appendingPathComponent("manifest.json"))
                try! Data([0x49, 0x44, 0x33, 0, 0, 0, 0, 0, 0, 0])
                    .write(to: pack.appendingPathComponent("stop.mp3"))
                let lock = FileLock(path: root.appendingPathComponent(scenario.held).path)
                expect(lock.tryLock(), "测试前提：须能持有 \(scenario.held)")
                defer { lock.unlock() }
                let runner = SystemCommandRunner(environmentOverrides: [
                    "CLAUDIO_TEST_HOME": home.path,
                    "CLAUDIO_TEST_ROOT": root.path,
                ])
                let result = runner.run(
                    executablePath: URL(fileURLWithPath: CommandLine.arguments[0])
                        .standardizedFileURL.path,
                    arguments: ["--default-lock-probe", scenario.action], timeout: 3.0)
                guard case .completed(let code, let output) = result else {
                    expect(false, "子进程须完成，got \(result)")
                    return
                }
                expect(
                    code == 0
                        && output.trimmingCharacters(in: .whitespacesAndNewlines)
                            == scenario.expected,
                    "\(scenario.held) / \(scenario.action) 应为 \(scenario.expected)，got \(code): \(output)"
                )
            }
        }
    }
}
