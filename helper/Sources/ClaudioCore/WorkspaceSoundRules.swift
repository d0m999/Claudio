import Foundation

/// Local directory identity. Paths never belong to receipts, notices or activity summaries.
public struct WorkspaceDirectory: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case directory, git }
    public let kind: Kind
    public let path: String
    public let commonGitDirectory: String?

    public init(kind: Kind, path: String, commonGitDirectory: String? = nil) {
        self.kind = kind
        self.path = Self.canonicalPath(path)
        self.commonGitDirectory = commonGitDirectory.map(Self.canonicalPath)
    }

    public var isValid: Bool {
        Self.validPath(path) && (kind != .git || commonGitDirectory.map(Self.validPath) == true)
    }

    public static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 4096
            && !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private enum CodingKeys: String, CodingKey { case kind, path, commonGitDirectory }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let path = try c.decode(String.self, forKey: .path)
        let common = try c.decodeIfPresent(String.self, forKey: .commonGitDirectory)
        guard Self.validPath(path), common.map(Self.validPath) ?? true else {
            throw WorkspaceDirectoryError.invalidDirectory
        }
        self.init(
            kind: try c.decode(Kind.self, forKey: .kind), path: path, commonGitDirectory: common)
    }

    public var identity: String { kind == .git ? "git:\(commonGitDirectory ?? "")" : "dir:\(path)" }

    public func contains(_ candidate: WorkspaceDirectory) -> Bool {
        if kind == .git {
            return candidate.kind == .git && commonGitDirectory == candidate.commonGitDirectory
        }
        return candidate.path == path || candidate.path.hasPrefix(path == "/" ? "/" : path + "/")
    }
}

public enum WorkspaceDirectoryError: Error, Sendable { case invalidDirectory, gitUnavailable }

/// Git is invoked without a shell, inherited Git overrides, hooks or network access. The deadline
/// and output cap keep corrupt repositories from turning a hook into an unbounded subprocess.
public enum WorkspaceDirectoryResolver {
    public static func resolve(_ path: String) -> Result<
        WorkspaceDirectory, WorkspaceDirectoryError
    > {
        resolve(path, commandRunner: SystemCommandRunner())
    }

    package static func resolve(
        _ path: String, commandRunner: any CommandRunning
    ) -> Result<WorkspaceDirectory, WorkspaceDirectoryError> {
        guard WorkspaceDirectory.validPath(path) else { return .failure(.invalidDirectory) }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue, WorkspaceDirectory.validPath(url.path)
        else { return .failure(.invalidDirectory) }
        // No .git ancestor means a plain directory. A present but broken .git fails closed.
        var ancestor = url
        var hasGit = false
        while true {
            let marker = ancestor.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: marker.path)
                || leafNodeIsSymbolicLink(at: marker)
            {
                hasGit = true
                break
            }
            if ancestor.path == "/" { break }
            let parent = ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path { break }
            ancestor = parent
        }
        guard hasGit else { return .success(WorkspaceDirectory(kind: .directory, path: url.path)) }
        guard let output = gitPaths(at: url.path, commandRunner: commandRunner), output.count == 2,
            output.allSatisfy(WorkspaceDirectory.validPath)
        else { return .failure(.gitUnavailable) }
        return .success(
            WorkspaceDirectory(
                kind: .git,
                path: URL(fileURLWithPath: output[0]).resolvingSymlinksInPath().path,
                commonGitDirectory: URL(fileURLWithPath: output[1]).resolvingSymlinksInPath().path))
    }

    private static func gitPaths(at path: String, commandRunner: any CommandRunning) -> [String]? {
        let arguments = [
            "-i", "PATH=/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null",
            "GIT_TERMINAL_PROMPT=0", "/usr/bin/git", "--no-optional-locks", "-C", path,
            "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir",
        ]
        var result = commandRunner.run(
            executablePath: "/usr/bin/env", arguments: arguments, timeout: 0.5)
        // On a loaded CI host the 0.5s fast path can expire while a valid Git process is
        // finishing. Retry only a confirmed timeout; malformed repositories and failed cleanup
        // must remain failures. Both attempts use the same sanitized command and finite deadline.
        if case .timedOut = result {
            result = commandRunner.run(
                executablePath: "/usr/bin/env", arguments: arguments, timeout: 2.0)
        }
        guard case .completed(0, let output) = result, output.utf8.count <= 16_384 else {
            return nil
        }
        return output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

    }
}

public struct WorkspaceSoundProfile: Codable, Sendable, Equatable {
    public var selectedPack: String
    public var volume: Double
    public var events: [String: Bool]
    public init(selectedPack: String, volume: Double, events: [String: Bool]? = nil) {
        self.selectedPack = selectedPack
        self.volume = volume
        self.events =
            events ?? Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0.cliName, true) })
    }
    public var isValid: Bool {
        isSafePackID(selectedPack) && volume.isFinite && (0...1).contains(volume)
            && Event.allCases.allSatisfy { events[$0.cliName] != nil }
    }
}

public struct WorkspaceSoundRule: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let directory: WorkspaceDirectory
    public var surfaces: [HostSurfaceID]
    /// nil retains a recognizable selector whose explicit profile is malformed.
    public var profile: WorkspaceSoundProfile?
    public var name: String { URL(fileURLWithPath: directory.path).lastPathComponent }
    public init(
        id: UUID = UUID(), directory: WorkspaceDirectory, surfaces: [HostSurfaceID],
        profile: WorkspaceSoundProfile
    ) {
        self.id = id
        self.directory = directory
        self.surfaces = surfaces
        self.profile = profile
    }
    private enum CodingKeys: String, CodingKey { case id, directory, surfaces, profile }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        directory = try c.decode(WorkspaceDirectory.self, forKey: .directory)
        let rawSurfaces = try c.decode([String].self, forKey: .surfaces)
        surfaces = rawSurfaces.compactMap(HostSurfaceID.init(rawValue:))
        profile = try? c.decode(WorkspaceSoundProfile.self, forKey: .profile)
        if profile?.isValid != true { profile = nil }
        guard directory.isValid else { throw WorkspaceDirectoryError.invalidDirectory }
    }
}

/// The rule the user inspected when requesting deletion. A UUID alone cannot distinguish a
/// replacement written by another process before the confirmation is accepted.
public struct WorkspaceSoundDeleteTarget: Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let directory: WorkspaceDirectory

    public init(rule: WorkspaceSoundRule) {
        id = rule.id
        name = rule.name
        directory = rule.directory
    }
}

/// The selected workspace, captured before another process can rebind its ID.
public struct WorkspaceSoundWriteTarget: Sendable, Equatable {
    public let id: UUID
    public let directory: WorkspaceDirectory

    public init(id: UUID, directory: WorkspaceDirectory) {
        self.id = id
        self.directory = directory
    }

    public init(rule: WorkspaceSoundRule) {
        self.init(id: rule.id, directory: rule.directory)
    }
}

public enum WorkspaceSoundError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidRule, duplicateDirectory, staleRule, unsupportedSurface, invalidPack, configFailure,
        lockBusy, tooLarge
    case publishedConflict(recoveryPath: String? = nil)

    /// Only the anchored write result can supply this path. A changed published path has none.
    public var recoveryPath: String? {
        guard case .publishedConflict(let recoveryPath) = self else { return nil }
        return recoveryPath
    }

    public var isPublishedConflict: Bool {
        if case .publishedConflict = self { return true }
        return false
    }
    public var description: String {
        switch self {
        case .tooLarge: "配置超过 64 KiB 上限；请减少工作区规则或过大的扩展字段。"
        case .publishedConflict(let recoveryPath):
            recoveryPath == nil
                ? "配置已发布但检测到并发冲突；请重新读取当前配置。"
                : "配置已发布但检测到并发冲突；请检查当前配置与保留的恢复文件。"
        case .invalidRule: "工作区配置已损坏，请修复目录、声音包、音量或五个事件开关。"
        case .duplicateDirectory: "该目录或 Git 仓库已存在工作区规则。"
        case .staleRule: "工作区已不存在；未修改默认组。"
        case .unsupportedSurface: "该来源尚无完整的目录回调验证证据。"
        case .invalidPack: "声音包缺失或损坏，请先修复声音包。"
        case .configFailure: "配置或迁移备份写入失败；请检查文件权限并重试。"
        case .lockBusy: "配置正被其他进程使用，请稍后重试。"
        }
    }
}

/// The release evidence gate is deliberately separate from hook protocol support and activation.
/// Populate only after version-specific real callbacks for every implemented target event pass.
public enum WorkspaceSurfaceEligibility {
    public static let candidates: [HostSurfaceID] = [.codex, .claudeCode]
    public static let verified: Set<HostSurfaceID> = [.codex, .claudeCode]
}

public enum WorkspaceHookDirectory {
    public static func cwd(from data: Data?) -> String? {
        guard let data, data.count <= HookInputReader.defaultMaximumBytes,
            !HostEventSourceParser.duplicateTopLevelKeys(data).contains("cwd"),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let path = object["cwd"] as? String, WorkspaceDirectory.validPath(path)
        else { return nil }
        return path
    }
}

extension ClaudioConfig {
    public func resolveWorkspaceProfile(id: UUID) -> Result<
        ResolvedSoundProfile, WorkspaceSoundError
    > {
        guard !workspaceRulesMalformed else { return .failure(.invalidRule) }
        guard let rule = workspaceRules.first(where: { $0.id == id }) else {
            return .failure(.staleRule)
        }
        guard let profile = rule.profile, profile.isValid else { return .failure(.invalidRule) }
        return .success(
            ResolvedSoundProfile(
                selectedPack: profile.selectedPack, eventsEnabled: profile.events,
                inheritedPack: false, inheritedEvents: [], volume: profile.volume, workspaceID: id))
    }

    /// One automatic-play resolver. No cwd or inapplicable Surface means the Default Group.
    public func resolveSoundProfile(
        for surface: HostSurfaceID?, cwd: String? = nil,
        directoryResolver: (String) -> Result<WorkspaceDirectory, WorkspaceDirectoryError> =
            WorkspaceDirectoryResolver.resolve
    ) -> Result<ResolvedSoundProfile, WorkspaceSoundError> {
        let defaults = ResolvedSoundProfile(
            selectedPack: selectedPack, eventsEnabled: eventsEnabled,
            inheritedPack: false, inheritedEvents: [], volume: masterVolume, workspaceID: nil)
        guard let surface, let cwd, WorkspaceDirectory.validPath(cwd) else {
            return .success(defaults)
        }
        guard WorkspaceSurfaceEligibility.verified.contains(surface) else {
            return .success(defaults)
        }
        guard !workspaceRulesMalformed else { return .failure(.invalidRule) }
        let applicable = workspaceRules.filter { $0.surfaces.contains(surface) }
        guard !applicable.isEmpty else { return .success(defaults) }
        let directory: WorkspaceDirectory
        switch directoryResolver(cwd) {
        case .success(let value): directory = value
        case .failure(.invalidDirectory): return .success(defaults)
        case .failure(.gitUnavailable): return .failure(.invalidRule)
        }
        // Ordinary rules compare the actual cwd, not the enclosing Git root.
        let actual = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path
        let plain = WorkspaceDirectory(kind: .directory, path: actual)
        let matches = applicable.filter {
            $0.directory.contains($0.directory.kind == .git ? directory : plain)
        }
        .sorted {
            if $0.directory.kind != $1.directory.kind { return $0.directory.kind == .git }
            return $0.directory.path.count > $1.directory.path.count
        }
        guard let rule = matches.first else { return .success(defaults) }
        if matches.dropFirst().contains(where: { $0.directory.identity == rule.directory.identity })
        {
            return .failure(.duplicateDirectory)
        }
        return resolveWorkspaceProfile(id: rule.id)
    }
}

public enum WorkspaceSoundMutation: Sendable {
    case add(WorkspaceSoundRule)
    case remove(WorkspaceSoundDeleteTarget)
    case pack(WorkspaceSoundWriteTarget, String)
    case volume(WorkspaceSoundWriteTarget, Double)
    case event(WorkspaceSoundWriteTarget, Event, Bool)
    case surfaces(WorkspaceSoundWriteTarget, [HostSurfaceID])
}

public func mutateWorkspaceSound(
    _ mutation: WorkspaceSoundMutation,
    configFile: URL = ClaudioPaths.configFile,
    lockFile: URL = ClaudioPaths.configLockFile,
    userPacksDirectory: URL = ClaudioPaths.packsDirectory,
    bundledPacksDirectory: URL? = nil,
    verifiedSurfaces: Set<HostSurfaceID> = WorkspaceSurfaceEligibility.verified,
    testingBeforeRename: (() -> Void)? = nil
) -> Result<Void, WorkspaceSoundError> {
    var rejection: WorkspaceSoundError?
    let locked = withNonBlockingLock(path: lockFile.path) {
        updateConfigJSON(
            at: configFile, onMissing: .failClosed,
            testingBeforeRename: testingBeforeRename
        ) { json in
            func reject(_ error: WorkspaceSoundError) -> Result<Void, ConfigMutationFailure> {
                rejection = error
                return .failure(.mutationRejected)
            }
            guard let data = try? JSONSerialization.data(withJSONObject: json),
                let config = try? JSONDecoder().decode(ClaudioConfig.self, from: data),
                !config.workspaceRulesMalformed
            else { return reject(.invalidRule) }
            var rules = json["workspace_rules"] as? [String: Any] ?? [:]
            let id: UUID
            switch mutation {
            case .add(let rule):
                guard rule.directory.isValid, rule.profile?.isValid == true,
                    case .success(let currentDirectory) = WorkspaceDirectoryResolver.resolve(
                        rule.directory.path),
                    currentDirectory == rule.directory
                else { return reject(.invalidRule) }
                guard
                    config.workspaceRules.allSatisfy({
                        $0.directory.identity != rule.directory.identity && $0.id != rule.id
                    })
                else { return reject(.duplicateDirectory) }
                guard Set(rule.surfaces).isSubset(of: verifiedSurfaces) else {
                    return reject(.unsupportedSurface)
                }
                guard let encoded = try? JSONEncoder().encode(rule),
                    let object = try? JSONSerialization.jsonObject(with: encoded)
                else { return reject(.invalidRule) }
                rules[rule.id.uuidString] = object
                id = rule.id
            case .remove(let target):
                guard let current = config.workspaceRules.first(where: { $0.id == target.id }),
                    current.directory == target.directory,
                    rules.removeValue(forKey: target.id.uuidString) != nil
                else {
                    return reject(.staleRule)
                }
                json["workspace_rules"] = rules
                return .success(())
            case .pack(let target, _), .volume(let target, _), .event(let target, _, _),
                .surfaces(let target, _):
                guard
                    config.workspaceRules.first(where: { $0.id == target.id })?.directory
                        == target.directory
                else { return reject(.staleRule) }
                id = target.id
            }
            guard var rule = rules[id.uuidString] as? [String: Any],
                var profile = rule["profile"] as? [String: Any]
            else { return reject(.staleRule) }
            switch mutation {
            case .add: break
            case .remove: break
            case .pack(_, let pack): profile["selectedPack"] = pack
            case .volume(_, let volume):
                guard volume.isFinite && (0...1).contains(volume) else {
                    return reject(.invalidRule)
                }
                profile["volume"] = volume
            case .event(_, let event, let enabled):
                var events = profile["events"] as? [String: Any] ?? [:]
                events[event.cliName] = enabled
                profile["events"] = events
            case .surfaces(_, let surfaces):
                guard Set(surfaces).isSubset(of: verifiedSurfaces) else {
                    return reject(.unsupportedSurface)
                }
                // Unknown future entries remain intact; only currently known entries are edited.
                let unknown = (rule["surfaces"] as? [String] ?? []).filter {
                    HostSurfaceID(rawValue: $0) == nil
                }
                rule["surfaces"] = surfaces.map(\.rawValue) + unknown
            }
            rule["profile"] = profile
            guard let encoded = try? JSONSerialization.data(withJSONObject: rule),
                let decoded = try? JSONDecoder().decode(WorkspaceSoundRule.self, from: encoded),
                let sound = decoded.profile
            else { return reject(.invalidRule) }
            // Changing volume/events must remain possible while repairing a missing pack.
            switch mutation {
            case .add, .pack:
                guard
                    let directory = resolvePackDirectory(
                        id: sound.selectedPack, userPacksDirectory: userPacksDirectory,
                        bundledPacksDirectory: bundledPacksDirectory),
                    case .success = loadPackManifest(in: directory)
                else { return reject(.invalidPack) }
            default: break
            }
            rules[id.uuidString] = rule
            json["workspace_rules"] = rules
            var sizeProbe = json
            if sizeProbe["sound_model_version"] == nil { sizeProbe["sound_model_version"] = 2 }
            if case .success(let data) = encodeJSONForWriting(sizeProbe, path: configFile.path),
                data.count > maxConfigFileBytes
            {
                return reject(.tooLarge)
            }
            return .success(())
        }
    }
    switch locked {
    case .ran(.success): return .success(())
    case .ran(.failure(.postPublishConflict(let recoveryPath))):
        return .failure(.publishedConflict(recoveryPath: recoveryPath))
    case .ran(.failure(.postPublishPathChanged)):
        return .failure(.publishedConflict())
    case .skipped: return .failure(.lockBusy)
    default: return .failure(rejection ?? .configFailure)
    }
}
