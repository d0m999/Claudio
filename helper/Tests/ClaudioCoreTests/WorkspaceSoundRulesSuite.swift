import ClaudioCore
import Foundation

private final class WorkspacePlaybackRecorder: ProcessSpawning, @unchecked Sendable {
    var calls: [[String]] = []
    func spawn(executablePath: String, arguments: [String]) -> Bool {
        calls.append(arguments); return true
    }
}

private final class WorkspaceGitResultRunner: CommandRunning, @unchecked Sendable {
    private var results: [CommandRunResult]
    private(set) var calls: [(executable: String, arguments: [String], timeout: TimeInterval)] = []

    init(_ results: [CommandRunResult]) { self.results = results }

    func run(executablePath: String, arguments: [String], timeout: TimeInterval)
        -> CommandRunResult
    {
        calls.append((executablePath, arguments, timeout))
        return results.isEmpty ? .launchFailed : results.removeFirst()
    }
}

private final class WorkspaceHangingGitRunner: CommandRunning, @unchecked Sendable {
    private(set) var outcomes: [CommandRunResult] = []

    func run(executablePath: String, arguments: [String], timeout: TimeInterval)
        -> CommandRunResult
    {
        let outcome = SystemCommandRunner().run(
            executablePath: "/bin/sleep", arguments: ["20"], timeout: timeout)
        outcomes.append(outcome)
        return outcome
    }
}

@MainActor
func runWorkspaceSoundRulesSuites() {
    suite("workspace directories: ordinary directory outside Git tree resolves") {
        withTempDirectory { root in
            let ordinary = root.appendingPathComponent("ordinary", isDirectory: true)
            try! FileManager.default.createDirectory(
                at: ordinary, withIntermediateDirectories: true)
            expect(
                (try? WorkspaceDirectoryResolver.resolve(ordinary.path).get())
                    == WorkspaceDirectory(kind: .directory, path: ordinary.path),
                "ancestor traversal reaches filesystem root and returns the ordinary directory")
        }
    }
    suite("workspace directories: two repositories, two worktrees, child and symlink identities") {
        withTempDirectory { root in
            @MainActor func git(_ args: [String]) {
                let process = Process();
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = args; process.standardOutput = FileHandle.nullDevice;
                process.standardError = FileHandle.nullDevice
                try! process.run(); process.waitUntilExit();
                expect(process.terminationStatus == 0, "fixture git command succeeds")
            }
            let a = root.appendingPathComponent("repo-a"), b = root.appendingPathComponent("repo-b")
            git(["init", "-q", a.path]); git(["init", "-q", b.path])
            git([
                "-C", a.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                "commit", "--allow-empty", "-qm", "fixture",
            ])
            let w1 = root.appendingPathComponent("worktree-one"),
                w2 = root.appendingPathComponent("worktree-two")
            git(["-C", a.path, "worktree", "add", "-qb", "one", w1.path]);
            git(["-C", a.path, "worktree", "add", "-qb", "two", w2.path])
            let child = a.appendingPathComponent("nested/child")
            try! FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            let alias = root.appendingPathComponent("alias")
            try! FileManager.default.createSymbolicLink(at: alias, withDestinationURL: child)
            var directories: [WorkspaceDirectory] = []
            for url in [a, b, w1, w2, child, alias] {
                switch WorkspaceDirectoryResolver.resolve(url.path) {
                case .success(let directory): directories.append(directory)
                case .failure:
                    expect(false, "real Git fixture must resolve")
                    return
                }
            }
            expect(
                directories[0].identity == directories[2].identity
                    && directories[2].identity == directories[3].identity,
                "both linked worktrees share common Git identity")
            expect(
                directories[0].identity != directories[1].identity,
                "different repository does not collide")
            expect(
                directories[4].path == a.resolvingSymlinksInPath().standardizedFileURL.path
                    && directories[5] == directories[4],
                "subdirectory and alias resolve explicitly to repository root")
            var config = ClaudioConfig(selectedPack: "default", masterVolume: 0.1)
            let plain = WorkspaceSoundRule(
                directory: WorkspaceDirectory(
                    kind: .directory, path: root.resolvingSymlinksInPath().path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "parent", volume: 0.2))
            let repository = WorkspaceSoundRule(
                directory: directories[0], surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "repo", volume: 0.7))
            config.workspaceRules = [plain, repository]
            for url in [a, child, w1, w2] {
                let profile = try! config.resolveSoundProfile(for: .codex, cwd: url.path).get()
                expect(
                    profile.selectedPack == "repo" && profile.volume == 0.7,
                    "Git match takes whole profile over covering ordinary directory")
            }
            expect(
                try! config.resolveSoundProfile(for: .codex, cwd: b.path).get().selectedPack
                    == "parent", "other repository only matches plain ancestor")
            expect(
                try! config.resolveSoundProfile(for: .claudeCode, cwd: a.path).get().selectedPack
                    == "default", "inapplicable Surface uses Default Group")
        }
    }
    suite("workspace Git lookup retries one transient deadline, but a persistent hang fails closed")
    {
        withTempDirectory { root in
            let repository = root.appendingPathComponent("repository")
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = ["init", "-q", repository.path]
            git.standardOutput = FileHandle.nullDevice
            git.standardError = FileHandle.nullDevice
            try! git.run()
            git.waitUntilExit()
            expect(git.terminationStatus == 0, "fixture repository is valid")

            let canonical = repository.resolvingSymlinksInPath().standardizedFileURL
            let output = "\(canonical.path)\n\(canonical.appendingPathComponent(".git").path)\n"
            let delayed = WorkspaceGitResultRunner([
                .timedOut, .completed(exitCode: 0, stdout: output),
            ])
            expect(
                WorkspaceDirectoryResolver.resolve(repository.path, commandRunner: delayed)
                    == .success(
                        WorkspaceDirectory(
                            kind: .git, path: canonical.path,
                            commonGitDirectory: canonical.appendingPathComponent(".git").path)),
                "a valid repository is not rejected after one transient Git deadline")
            expect(
                delayed.calls.count == 2 && delayed.calls[0].timeout == 0.5
                    && delayed.calls[1].timeout > delayed.calls[0].timeout
                    && delayed.calls[1].timeout <= 2.0,
                "one bounded longer attempt follows the fast Git deadline")
            expect(
                delayed.calls.allSatisfy {
                    $0.executable == "/usr/bin/env"
                        && $0.arguments.starts(with: ["-i", "PATH=/usr/bin:/bin"])
                        && $0.arguments.contains("/usr/bin/git")
                }, "both attempts keep the sanitized shell-free Git invocation")

            let hung = WorkspaceGitResultRunner([.timedOut, .timedOut])
            expect(
                WorkspaceDirectoryResolver.resolve(repository.path, commandRunner: hung)
                    == .failure(.gitUnavailable),
                "a persistently hung Git command never becomes an ordinary directory")
            expect(
                hung.calls.count == 2 && hung.calls.allSatisfy { $0.timeout > 0 },
                "a persistent hang receives only two finite attempts")

            let realHang = WorkspaceHangingGitRunner()
            let started = Date()
            expect(
                WorkspaceDirectoryResolver.resolve(repository.path, commandRunner: realHang)
                    == .failure(.gitUnavailable),
                "a real sleeping child fails closed through the production process runner")
            expect(
                realHang.outcomes == [.timedOut, .timedOut]
                    && Date().timeIntervalSince(started) < 10,
                "both real child processes are stopped and the retry remains bounded")
        }
    }
    suite("workspace Git lookup rejects stale .git targets") {
        withTempDirectory { root in
            let directory = root.appendingPathComponent("stale")
            try! FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            writeFixture(
                "gitdir: /no/such/claudio-git-target", to: directory.appendingPathComponent(".git"))
            expect(
                WorkspaceDirectoryResolver.resolve(directory.path) == .failure(.gitUnavailable),
                "a stale .git marker cannot silently become an ordinary directory")
        }
    }
    suite(
        "workspace matching: exact path boundary, most specific directory, missing cwd, malformed match"
    ) {
        withTempDirectory { root in
            let nested = root.appendingPathComponent("ordinary/nested")
            try! FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let base = root.resolvingSymlinksInPath().appendingPathComponent("ordinary")
            var config = ClaudioConfig(selectedPack: "default", masterVolume: 0.13)
            let parent = WorkspaceSoundRule(
                directory: WorkspaceDirectory(kind: .directory, path: base.path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "parent", volume: 0.4))
            var child = WorkspaceSoundRule(
                directory: WorkspaceDirectory(
                    kind: .directory, path: nested.resolvingSymlinksInPath().path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "child", volume: 0.9))
            config.workspaceRules = [parent, child]
            expect(
                try! config.resolveSoundProfile(for: .codex, cwd: nested.path).get().selectedPack
                    == "child", "longest ordinary directory wins")
            expect(
                !parent.directory.contains(
                    WorkspaceDirectory(kind: .directory, path: base.path + "-sibling")),
                "prefix sibling is not a descendant")
            for cwd in [nil, "", "relative/path", "/bad\u{0}path"] as [String?] {
                expect(
                    try! config.resolveSoundProfile(for: .codex, cwd: cwd).get().volume == 0.13,
                    "no trusted cwd uses complete defaults")
            }
            var unverified = parent
            unverified.surfaces = [.workBuddy]
            config.workspaceRules = [unverified]
            expect(
                try! config.resolveSoundProfile(for: .workBuddy, cwd: base.path).get().workspaceID
                    == nil,
                "unverified WorkBuddy uses Default Group even with externally supplied rule")
            child.profile = nil; config.workspaceRules = [parent, child]
            expect(
                config.resolveSoundProfile(for: .codex, cwd: nested.path) == .failure(.invalidRule),
                "matched damaged profile never falls through to parent or Default Group")
            config.workspaceRules = [parent, parent]
            expect(
                config.resolveSoundProfile(for: .codex, cwd: base.path)
                    == .failure(.duplicateDirectory), "external duplicate match fails closed")
            expect(
                WorkspaceHookDirectory.cwd(
                    from: Data(#"{"cwd":"/fixture","prompt":"private"}"#.utf8)) == "/fixture",
                "bounded payload extracts only cwd")
            expect(
                WorkspaceHookDirectory.cwd(from: Data(#"{"cwd":"/a","cwd":"/b"}"#.utf8)) == nil,
                "duplicate cwd fields are not trusted directory evidence")
            expect(
                WorkspaceHookDirectory.cwd(from: Data(repeating: 32, count: 65_537)) == nil,
                "oversize rejected")
        }
    }
    suite(
        "workspace mutations: explicit full profile, duplicate refusal, unknown fields, one exact migration backup"
    ) {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs"),
                pack = packs.appendingPathComponent("selected")
            try! FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
            writeFixture(
                #"{"id":"selected","name":"Selected","events":{}}"#,
                to: pack.appendingPathComponent("manifest.json"))
            let file = root.appendingPathComponent("config.json"),
                lock = root.appendingPathComponent("config.lock")
            let original =
                #"{"selected_pack":"default","master_volume":0.11,"events":{"stop":false},"surface_overrides":false,"future":{"keep":true}}"#
            writeFixture(original, to: file)
            let rule = WorkspaceSoundRule(
                directory: WorkspaceDirectory(
                    kind: .directory, path: root.resolvingSymlinksInPath().path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "selected", volume: 0.83))
            func mutate(_ mutation: WorkspaceSoundMutation) -> Result<Void, WorkspaceSoundError> {
                mutateWorkspaceSound(
                    mutation, configFile: file, lockFile: lock, userPacksDirectory: packs,
                    verifiedSurfaces: [.codex, .claudeCode])
            }
            expect(
                (try? mutate(.add(rule)).get()) != nil,
                "explicit selected pack and volume create full rule")
            expect(mutate(.add(rule)).isWorkspaceFailure(.duplicateDirectory), "duplicate rejected")
            expect(
                mutate(.volume(UUID(), 0.2)).isWorkspaceFailure(.staleRule),
                "stale UUID never writes defaults")
            expect(
                mutate(.surfaces(rule.id, [.workBuddy])).isWorkspaceFailure(.unsupportedSurface),
                "unverified WorkBuddy rejected")
            for event in Event.allCases {
                expect(
                    (try? mutate(.event(rule.id, event, false)).get()) != nil,
                    "all five event switches independently writable")
            }
            expect(
                (try? mutate(.volume(rule.id, 0.61)).get()) != nil,
                "workspace independent volume writes")
            let decoded = loadClaudioConfig(from: file)!
            let profile = try! decoded.resolveWorkspaceProfile(id: rule.id).get()
            expect(
                profile.volume == 0.61 && Event.allCases.allSatisfy { !profile.isEnabled($0) },
                "all writes read back")
            expect(
                decoded.masterVolume == 0.11 && !decoded.isEnabled(.stop), "Default Group unchanged"
            )
            let raw =
                try! JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            expect(
                raw["surface_overrides"] as? Bool == false
                    && (raw["future"] as? [String: Bool])?["keep"] == true,
                "opaque retired and future fields preserved")
            let backups = try! FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("config-before-workspaces-") }
            expect(
                backups.count == 1
                    && (try! String(contentsOf: backups[0], encoding: .utf8)) == original,
                "single recoverable byte-exact pre-upgrade backup")
        }
    }
    suite("workspace config growth: rejects oversized writes without changing original bytes") {
        withTempDirectory { root in
            let file = root.appendingPathComponent("config.json"),
                packs = root.appendingPathComponent("packs")
            writeFixture(
                #"{"id":"pack","events":{}}"#,
                to: packs.appendingPathComponent("pack/manifest.json"))
            let bytes = try! JSONSerialization.data(withJSONObject: [
                "selected_pack": "pack", "future": String(repeating: "x", count: 65_000),
            ])
            try! bytes.write(to: file)
            let rule = WorkspaceSoundRule(
                directory: WorkspaceDirectory(kind: .directory, path: root.path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "pack", volume: 0.5))
            expect(
                mutateWorkspaceSound(
                    .add(rule), configFile: file,
                    lockFile: root.appendingPathComponent("config.lock"),
                    userPacksDirectory: packs
                ).isWorkspaceFailure(.tooLarge),
                "large rule addition is rejected before publication")
            expect(
                (try! Data(contentsOf: file)) == bytes,
                "rejected growth preserves exact original bytes")
        }
    }
    suite("workspace pack write rejects a different directory reusing the same UUID") {
        withTempDirectory { root in
            let file = root.appendingPathComponent("config.json")
            let lock = root.appendingPathComponent("config.lock")
            let packs = root.appendingPathComponent("packs")
            writeFixture(
                #"{"id":"next","events":{}}"#,
                to: packs.appendingPathComponent("next/manifest.json"))
            let original = WorkspaceSoundRule(
                directory: WorkspaceDirectory(
                    kind: .directory, path: root.appendingPathComponent("a").path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "old", volume: 0.5))
            let replacement = WorkspaceSoundRule(
                id: original.id,
                directory: WorkspaceDirectory(
                    kind: .directory, path: root.appendingPathComponent("b").path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "old", volume: 0.5))
            var config = ClaudioConfig(selectedPack: "default", masterVolume: 0.2)
            config.workspaceRules = [replacement]
            let before = try! JSONEncoder().encode(config)
            try! before.write(to: file)
            let target = WorkspaceSoundPackTarget(rule: original)
            expect(
                mutateWorkspaceSound(
                    .pack(target, "next"), configFile: file, lockFile: lock,
                    userPacksDirectory: packs
                ).isWorkspaceFailure(.staleRule),
                "rebound UUID must fail closed inside the config lock")
            expect((try! Data(contentsOf: file)) == before, "failed write preserves config bytes")
            config.workspaceRules = [original]
            try! JSONEncoder().encode(config).write(to: file)
            expect(
                (try? mutateWorkspaceSound(
                    .pack(target, "next"), configFile: file, lockFile: lock,
                    userPacksDirectory: packs
                ).get()) != nil,
                "unchanged ID and directory still accept the pack write")
            expect(
                loadClaudioConfig(from: file)?.workspaceRules.first?.profile?.selectedPack == "next"
                    && loadClaudioConfig(from: file)?.selectedPack == "default",
                "accepted workspace pack write leaves Default Group unchanged")
        }
    }
    suite(
        "workspace playback: independent volume, five switches, damaged pack stops without fallback"
    ) {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs"),
                file = root.appendingPathComponent("config.json")
            for id in ["default", "workspace"] {
                let pack = packs.appendingPathComponent(id)
                try! FileManager.default.createDirectory(
                    at: pack, withIntermediateDirectories: true)
                let events = Dictionary(
                    uniqueKeysWithValues: Event.allCases.map { ($0.cliName, "tone.aiff") })
                let json: [String: Any] = ["id": id, "name": id, "events": events]
                try! JSONSerialization.data(withJSONObject: json).write(
                    to: pack.appendingPathComponent("manifest.json"))
                writeFixture("audio fixture", to: pack.appendingPathComponent("tone.aiff"))
            }
            var config = ClaudioConfig(selectedPack: "default", masterVolume: 0.12)
            let rule = WorkspaceSoundRule(
                directory: WorkspaceDirectory(
                    kind: .directory, path: root.resolvingSymlinksInPath().path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "workspace", volume: 0.87))
            config.workspaceRules = [rule]
            try! JSONEncoder().encode(config).write(to: file)
            let recorder = WorkspacePlaybackRecorder()
            let env = PlayEnvironment(
                surfaceID: .codex, workingDirectory: root.path,
                lockFile: root.appendingPathComponent("play.lock"), configFile: file,
                userPacksDirectory: packs, spawner: recorder,
                debounceStateFile: root.appendingPathComponent("debounce"), debounceInterval: 0,
                logFile: root.appendingPathComponent("log"),
                logLockFile: root.appendingPathComponent("log.lock"))
            for event in Event.allCases { _ = playSoundEvent(event.cliName, environment: env) }
            expect(
                recorder.calls.count == 5
                    && recorder.calls.allSatisfy {
                        $0[1] == AfplayVolume.afplayArgument(forMasterVolume: 0.87)
                            && $0[2].contains("/workspace/")
                    }, "five events use workspace pack and independent volume")
            let denied = PlayEnvironment(
                surfaceID: .codex, workingDirectory: root.path, playbackAuthorized: { false },
                lockFile: root.appendingPathComponent("play.lock"), configFile: file,
                userPacksDirectory: packs,
                spawner: recorder, debounceStateFile: root.appendingPathComponent("debounce"),
                debounceInterval: 0,
                logFile: root.appendingPathComponent("log"),
                logLockFile: root.appendingPathComponent("log.lock"))
            expect(
                playSoundEvent("stop", environment: denied) == .notReady
                    && recorder.calls.count == 5,
                "disconnect authorization is rechecked immediately before spawning audio")
            let manifestFile = packs.appendingPathComponent("workspace/manifest.json")
            let validManifest = try! Data(contentsOf: manifestFile)
            writeFixture(
                #"{"id":"workspace","events":{"stop":"tone.aiff","notification":"missing.aiff"}}"#,
                to: manifestFile)
            expect(
                playSoundEvent("stop", environment: env) == .notReady && recorder.calls.count == 5,
                "a broken declared sound stops the entire matched workspace pack")
            try! validManifest.write(to: manifestFile)
            config.workspaceRules[0].profile!.events = Dictionary(
                uniqueKeysWithValues: Event.allCases.map { ($0.cliName, false) })
            try! JSONEncoder().encode(config).write(to: file)
            for event in Event.allCases {
                expect(
                    playSoundEvent(event.cliName, environment: env) == .disabled(event: event),
                    "workspace switch stops its event")
            }
            config.workspaceRules[0].profile!.selectedPack = "missing";
            config.workspaceRules[0].profile!.events[Event.stop.cliName] = true
            try! JSONEncoder().encode(config).write(to: file)
            expect(
                playSoundEvent("stop", environment: env) == .notReady && recorder.calls.count == 5,
                "missing workspace pack never uses healthy Default Group")
            expect(
                !FileManager.default.fileExists(atPath: root.appendingPathComponent("log").path),
                "workspace paths do not enter ordinary logs")
        }
    }
}

extension Result where Success == Void, Failure == WorkspaceSoundError {
    fileprivate func isWorkspaceFailure(_ error: WorkspaceSoundError) -> Bool {
        if case .failure(let actual) = self { return actual == error }; return false
    }
}
