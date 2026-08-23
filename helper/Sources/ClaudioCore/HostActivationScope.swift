import Foundation

/// Resolves host CLIs without assuming a Finder/LaunchServices process inherited the user's shell
/// `PATH`. Every returned path is absolute and points at an executable regular file; callers can
/// therefore invoke it directly instead of handing a bare command back to `/usr/bin/env`.
public struct HostExecutableLocator: Sendable {
    public let searchDirectories: [URL]

    public init(searchDirectories: [URL]) {
        var seen: Set<String> = []
        self.searchDirectories = searchDirectories.compactMap { directory in
            guard directory.path.hasPrefix("/") else { return nil }
            let path = directory.standardizedFileURL.path
            guard seen.insert(path).inserted else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    public var executableSearchPath: String {
        searchDirectories.map(\.path).joined(separator: ":")
    }

    /// GUI `PATH` remains the first choice when it is useful. Explicit per-user installation roots
    /// then cover native installers and common Node version managers before system package-manager
    /// roots. NVM versions are numeric-descending so a GUI process with no shell-selected version
    /// still makes a deterministic choice.
    public static func standard(
        environmentPath: String? = ProcessInfo.processInfo.environment["PATH"],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> HostExecutableLocator {
        let pathDirectories = (environmentPath ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        let userDirectories = [
            ".local/bin",
            "bin",
            ".claude/local",
            ".codex/bin",
            ".volta/bin",
            ".asdf/shims",
            ".mise/shims",
            ".fnm/current/bin",
            ".npm-global/bin",
            "Library/pnpm",
            ".bun/bin",
        ].map { homeDirectory.appendingPathComponent($0, isDirectory: true) }
        let nvmDirectories = nvmNodeBinDirectories(
            homeDirectory: homeDirectory,
            fileManager: fileManager)
        let systemDirectories = [
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/bin", isDirectory: true),
            URL(fileURLWithPath: "/bin", isDirectory: true),
        ]
        return HostExecutableLocator(
            searchDirectories:
                pathDirectories + userDirectories + nvmDirectories + systemDirectories)
    }

    public func executablePath(command: String, fileManager: FileManager = .default) -> String? {
        guard !command.isEmpty, !command.contains("/") else { return nil }
        for directory in searchDirectories {
            let candidate = directory.appendingPathComponent(command, isDirectory: false)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                !isDirectory.boolValue,
                fileManager.isExecutableFile(atPath: candidate.path),
                (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            return candidate.path
        }
        return nil
    }

    private static func nvmNodeBinDirectories(
        homeDirectory: URL,
        fileManager: FileManager
    ) -> [URL] {
        let versionsRoot = homeDirectory.appendingPathComponent(
            ".nvm/versions/node",
            isDirectory: true)
        guard
            let children = try? fileManager.contentsOfDirectory(
                at: versionsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        return children.compactMap { directory -> (SemanticVersion, URL)? in
            let token =
                directory.lastPathComponent.hasPrefix("v")
                ? String(directory.lastPathComponent.dropFirst())
                : directory.lastPathComponent
            guard let version = SemanticVersion(parsing: token) else { return nil }
            return (version, directory.appendingPathComponent("bin", isDirectory: true))
        }
        .sorted { $0.0 > $1.0 }
        .map(\.1)
    }
}

/// Current Activation 的版本身份。调用方只能比较完整 fingerprint，不得拆开后自行放宽。
public enum HostActivationScope {
    public static func fingerprint(host: HostID, hostVersion: String) -> String? {
        let normalizedVersion = hostVersion.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalizedVersion.isEmpty, normalizedVersion.utf8.count <= 256 else { return nil }
        let bindingSchema = HostCapabilityCatalog.bindings(for: host)
            .filter(\.isAudibleCapability)
            .map(\.id.rawValue)
            .sorted()
            .joined(separator: ",")
        guard !bindingSchema.isEmpty else { return nil }
        return
            "surface=\(host.surfaceID.rawValue);host=\(normalizedVersion);"
            + "claudio=\(ClaudioVersion.current);bindings=\(bindingSchema)"
    }

    public static func claudeCode(
        executableLocator: HostExecutableLocator = .standard(),
        commandRunner: (any CommandRunning)? = nil
    ) -> String? {
        guard
            let version = commandVersion(
                command: "claude",
                executableLocator: executableLocator,
                commandRunner: commandRunner)
        else { return nil }
        return fingerprint(host: .claudeCode, hostVersion: version)
    }

    public static func codex(
        executableLocator: HostExecutableLocator = .standard(),
        commandRunner: (any CommandRunning)? = nil
    ) -> String? {
        guard
            let version = commandVersion(
                command: "codex",
                executableLocator: executableLocator,
                commandRunner: commandRunner)
        else { return nil }
        return fingerprint(host: .codex, hostVersion: "cli=\(version)")
    }

    public static func workBuddy() -> String? {
        guard let version = bundleVersion(at: "/Applications/WorkBuddy.app") else { return nil }
        return fingerprint(host: .workBuddy, hostVersion: "app=\(version)")
    }

    private static func bundleVersion(at path: String) -> String? {
        guard let bundle = Bundle(path: path) else { return nil }
        let shortVersion =
            (bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let buildVersion = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let components = [
            shortVersion.flatMap { $0.isEmpty ? nil : "short=\($0)" },
            buildVersion.flatMap { $0.isEmpty ? nil : "build=\($0)" },
        ].compactMap { $0 }
        return components.isEmpty ? nil : components.joined(separator: ";")
    }

    private static func commandVersion(
        command: String,
        executableLocator: HostExecutableLocator,
        commandRunner: (any CommandRunning)?
    ) -> String? {
        guard let executablePath = executableLocator.executablePath(command: command) else {
            return nil
        }
        let resolvedRunner = commandRunner ?? SystemCommandRunner(
            environmentOverrides: ["PATH": executableLocator.executableSearchPath])
        switch resolvedRunner.run(
            executablePath: executablePath,
            arguments: ["--version"],
            timeout: 1.0)
        {
        case .completed(let exitCode, let stdout) where exitCode == 0:
            let normalized = stdout.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return normalized.isEmpty || normalized.utf8.count > 256 ? nil : normalized
        case .completed, .timedOut, .launchFailed:
            return nil
        }
    }
}
