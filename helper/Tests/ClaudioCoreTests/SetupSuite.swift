import ClaudioCore
import Foundation

// MARK: - claudio setup: v1 首次安装自举 (ENGINEERING.md T17)
//
// Fixture layout mirrors the real `release.yml` bundle shape:
//   <bundleRoot>/Contents/Resources/bin/claudio     (the "currently running" binary)
//   <bundleRoot>/Contents/Resources/packs/<id>/     (bundled packs, sibling of bin/)
// against a `<claudioRoot>` standing in for `~/.claudio/`.

@MainActor
private func makeBundleFixture(
    at bundleRoot: URL, packIDs: [String] = ["minimal-chime"]
) -> (executablePath: URL, packsDirectory: URL) {
    let binDirectory = bundleRoot.appendingPathComponent(
        "Contents/Resources/bin", isDirectory: true)
    let packsDirectory = bundleRoot.appendingPathComponent(
        "Contents/Resources/packs", isDirectory: true)
    let executablePath = binDirectory.appendingPathComponent("claudio")
    try? FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    try? Data("#!fake-binary-fixture".utf8).write(to: executablePath)
    for id in packIDs {
        let packDirectory = packsDirectory.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: packDirectory, withIntermediateDirectories: true)
        writeFixture(
            #"{ "schema": 1, "id": "\#(id)", "events": { "stop": "stop.mp3" } }"#,
            to: packDirectory.appendingPathComponent("manifest.json"))
    }
    return (executablePath, packsDirectory)
}

private func makeEnvironment(
    root: URL, executablePath: URL, claudioRootName: String = "claudio-root"
) -> SetupEnvironment {
    let claudioRoot = root.appendingPathComponent(claudioRootName, isDirectory: true)
    return SetupEnvironment(
        executablePath: executablePath,
        claudioBinaryDestination: claudioRoot.appendingPathComponent("bin/claudio"),
        userPacksDirectory: claudioRoot.appendingPathComponent("packs", isDirectory: true),
        configFile: claudioRoot.appendingPathComponent("config.json"),
        settingsFile: root.appendingPathComponent("settings.json"),
        lockFile: claudioRoot.appendingPathComponent("play.lock"))
}

@MainActor
func runSetupSuites() {
    suite("performFirstRunSetup: running from inside a bundle copies binary + pack, selects default, installs hooks") {
        withTempDirectory { root in
            let (executablePath, _) = makeBundleFixture(at: root.appendingPathComponent("bundle"))
            let environment = makeEnvironment(root: root, executablePath: executablePath)

            let result = performFirstRunSetup(environment: environment)
            guard case .success(.completed(let copiedBinary, let copiedPacks, let selectedPack, let hooksOutcome)) = result
            else {
                expect(false, "expected .success(.completed(...)), got \(result)")
                return
            }
            expect(copiedBinary, "binary should be copied when running from inside a bundle")
            expect(copiedPacks == ["minimal-chime"], "the bundled pack should be copied, got \(copiedPacks)")
            expect(selectedPack == "minimal-chime", "a fresh config.json should default-select the copied pack")
            expect(hooksOutcome == .installed, "a fresh settings.json should get hooks installed")

            expect(
                FileManager.default.fileExists(atPath: environment.claudioBinaryDestination.path),
                "binary must actually exist at the fixed destination afterward")
            var isExecutable = false
            if let attributes = try? FileManager.default.attributesOfItem(
                atPath: environment.claudioBinaryDestination.path),
                let permissions = attributes[.posixPermissions] as? NSNumber
            {
                isExecutable = (permissions.uint16Value & 0o111) != 0
            }
            expect(isExecutable, "the copied binary must be marked executable")

            let packDirectory = environment.userPacksDirectory.appendingPathComponent(
                "minimal-chime", isDirectory: true)
            expect(
                FileManager.default.fileExists(
                    atPath: packDirectory.appendingPathComponent("manifest.json").path),
                "the copied pack's manifest.json must exist under the user pack root")
        }
    }

    suite("performFirstRunSetup: already running from the fixed destination only ensures hooks (no copy)") {
        withTempDirectory { root in
            let claudioRoot = root.appendingPathComponent("claudio-root", isDirectory: true)
            let destination = claudioRoot.appendingPathComponent("bin/claudio")
            let environment = SetupEnvironment(
                executablePath: destination,
                claudioBinaryDestination: destination,
                userPacksDirectory: claudioRoot.appendingPathComponent("packs", isDirectory: true),
                configFile: claudioRoot.appendingPathComponent("config.json"),
                settingsFile: root.appendingPathComponent("settings.json"),
                lockFile: claudioRoot.appendingPathComponent("play.lock"))

            let result = performFirstRunSetup(environment: environment)
            expect(
                result
                    == .success(
                        .completed(
                            copiedBinary: false, copiedPacks: [], selectedPack: nil,
                            hooksOutcome: .installed)),
                "re-running setup from the already-installed location must skip copy steps, got \(result)"
            )
        }
    }

    suite("performFirstRunSetup: not running from a bundle (no sibling packs/) skips copy, still installs hooks") {
        withTempDirectory { root in
            let executablePath = root.appendingPathComponent("some-random-place/claudio")
            try? FileManager.default.createDirectory(
                at: executablePath.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("#!fake".utf8).write(to: executablePath)
            let environment = makeEnvironment(root: root, executablePath: executablePath)

            let result = performFirstRunSetup(environment: environment)
            expect(
                result
                    == .success(
                        .completed(
                            copiedBinary: false, copiedPacks: [], selectedPack: nil,
                            hooksOutcome: .installed)),
                "running with no sibling packs/ directory must not attempt any copy, got \(result)")
        }
    }

    suite("performFirstRunSetup: never clobbers a same-id pack the user already has") {
        withTempDirectory { root in
            let (executablePath, _) = makeBundleFixture(at: root.appendingPathComponent("bundle"))
            let environment = makeEnvironment(root: root, executablePath: executablePath)
            let userPackDirectory = environment.userPacksDirectory.appendingPathComponent(
                "minimal-chime", isDirectory: true)
            writeFixture(
                "the user's own customized pack file",
                to: userPackDirectory.appendingPathComponent("custom.txt"))

            let result = performFirstRunSetup(environment: environment)
            guard case .success(.completed(_, let copiedPacks, _, _)) = result else {
                expect(false, "expected success, got \(result)")
                return
            }
            expect(
                copiedPacks.isEmpty,
                "a pack id that already exists under the user root must not be reported as copied")
            expect(
                (try? String(
                    contentsOf: userPackDirectory.appendingPathComponent("custom.txt"),
                    encoding: .utf8)) == "the user's own customized pack file",
                "the user's existing pack contents must survive setup completely untouched")
        }
    }

    suite("performFirstRunSetup: an existing config.json's selected_pack is left untouched") {
        withTempDirectory { root in
            let (executablePath, _) = makeBundleFixture(at: root.appendingPathComponent("bundle"))
            let environment = makeEnvironment(root: root, executablePath: executablePath)
            writeFixture(
                #"{ "selected_pack": "some-other-pack", "master_volume": 0.6 }"#,
                to: environment.configFile)

            let result = performFirstRunSetup(environment: environment)
            guard case .success(.completed(_, _, let selectedPack, _)) = result else {
                expect(false, "expected success, got \(result)")
                return
            }
            expect(
                selectedPack == nil,
                "setup must never touch config.json when one already exists, got selectedPack=\(String(describing: selectedPack))"
            )
            let data = try? Data(contentsOf: environment.configFile)
            let config = data.flatMap { try? JSONDecoder().decode(ClaudioConfig.self, from: $0) }
            expect(
                config?.selectedPack == "some-other-pack",
                "the user's existing pack selection must survive setup untouched")
        }
    }

    suite("performFirstRunSetup: multiple bundled packs default-select the alphabetically-first one") {
        withTempDirectory { root in
            let (executablePath, _) = makeBundleFixture(
                at: root.appendingPathComponent("bundle"), packIDs: ["zebra-chime", "alpha-chime"])
            let environment = makeEnvironment(root: root, executablePath: executablePath)

            let result = performFirstRunSetup(environment: environment)
            guard case .success(.completed(_, let copiedPacks, let selectedPack, _)) = result else {
                expect(false, "expected success, got \(result)")
                return
            }
            expect(
                copiedPacks == ["alpha-chime", "zebra-chime"],
                "packs should be copied in deterministic (sorted) order, got \(copiedPacks)")
            expect(
                selectedPack == "alpha-chime",
                "default selection should be the deterministic (sorted) first pack, got \(String(describing: selectedPack))"
            )
        }
    }

    suite("performFirstRunSetup: re-running from inside the bundle a second time is idempotent") {
        withTempDirectory { root in
            let (executablePath, _) = makeBundleFixture(at: root.appendingPathComponent("bundle"))
            let environment = makeEnvironment(root: root, executablePath: executablePath)

            _ = performFirstRunSetup(environment: environment)
            let second = performFirstRunSetup(environment: environment)
            guard case .success(.completed(let copiedBinary, let copiedPacks, let selectedPack, let hooksOutcome)) = second
            else {
                expect(false, "expected success on second run, got \(second)")
                return
            }
            expect(copiedBinary, "the binary copy step itself is not guarded — copying over itself is safe")
            expect(
                copiedPacks.isEmpty,
                "the pack should not be reported as newly copied the second time (destination already exists)"
            )
            expect(
                selectedPack == nil,
                "config.json already exists after the first run, so the second run must not touch selected_pack"
            )
            expect(
                hooksOutcome == .alreadyInstalled,
                "hooks should already be installed on the second run")
        }
    }
}
