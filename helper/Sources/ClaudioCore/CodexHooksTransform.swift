import Foundation

/// Read-only classification of Claudio's command hooks inside Codex `hooks.json`.
///
/// This deliberately describes only commands recognized by ``matchedHostHookCommand`` under
/// the caller's current Claudio root. Foreign roots, other hosts, third-party hooks, and edited
/// command strings are not claimed as ours.
public enum CodexHooksConfigurationStatus: Sendable, Equatable {
    case absent
    case complete(installationID: UUID)
    case partial(installationID: UUID, missingNativeEvents: [String])
    case conflictingInstallationIDs([UUID])
    case conflict(reason: String)
    case malformed(reason: String)
}

/// A pure JSON mutation result. `data` is the exact input bytes whenever `changed == false`;
/// callers can therefore skip a config-file transaction for idempotent or fail-closed results.
public struct CodexHooksTransformResult: Sendable, Equatable {
    public let data: Data?
    public let status: CodexHooksConfigurationStatus
    public let changed: Bool
    public let removedCount: Int

    public init(
        data: Data?,
        status: CodexHooksConfigurationStatus,
        changed: Bool,
        removedCount: Int = 0
    ) {
        self.data = data
        self.status = status
        self.changed = changed
        self.removedCount = removedCount
    }
}

/// Pure schema inspection and transformation for Codex's composable `hooks.json`.
/// Disk locking, backup, CAS, symlink defense, and atomic publication belong to
/// `ConfigFileTransaction`; this type never touches the filesystem.
public enum CodexHooksTransform {
    private static let hooksKey = "hooks"
    private static let typeKey = "type"
    private static let commandKey = "command"
    private static let commandType = "command"

    private static var managedNativeEvents: [String] {
        HostCapabilityCatalog.bindings(for: .codex).compactMap { binding in
            binding.isAudibleCapability ? binding.nativeEvent : nil
        }
    }

    /// Classifies the current document without changing it.
    public static func inspect(
        _ data: Data?,
        claudioRoot: String,
        claudioBinaryPath: String,
        externallyManagedNativeEvents: Set<String> = [],
        externalInstallationID: UUID? = nil
    ) -> CodexHooksConfigurationStatus {
        switch loadAndInspect(
            data,
            claudioRoot: claudioRoot,
            claudioBinaryPath: claudioBinaryPath,
            externallyManagedNativeEvents: externallyManagedNativeEvents,
            externalInstallationID: externalInstallationID)
        {
        case .success(let loaded): return loaded.status
        case .failure(let error): return .malformed(reason: error.reason)
        }
    }

    /// Adds the missing Claudio Codex groups without replacing or reordering existing groups.
    /// A partial installation keeps its already-written installation ID so the completed three
    /// hooks can never be split across generations.
    public static func connect(
        _ data: Data?,
        installationID: UUID,
        claudioBinaryPath: String,
        claudioRoot: String,
        externallyManagedNativeEvents: Set<String> = [],
        externalInstallationID: UUID? = nil
    ) -> CodexHooksTransformResult {
        switch loadAndInspect(
            data,
            claudioRoot: claudioRoot,
            claudioBinaryPath: claudioBinaryPath,
            externallyManagedNativeEvents: externallyManagedNativeEvents,
            externalInstallationID: externalInstallationID)
        {
        case .failure(let error):
            return CodexHooksTransformResult(
                data: data, status: .malformed(reason: error.reason), changed: false)
        case .success(let loaded):
            switch loaded.status {
            case .malformed:
                return CodexHooksTransformResult(
                    data: data, status: loaded.status, changed: false)
            case .conflictingInstallationIDs, .conflict:
                return CodexHooksTransformResult(
                    data: data, status: loaded.status, changed: false)
            case .complete:
                if !loaded.hasRelocatedOwnedCommands {
                    return CodexHooksTransformResult(
                        data: data, status: loaded.status, changed: false)
                }
            case .absent, .partial:
                break
            }

            if loaded.hasRelocatedOwnedCommands {
                let repairID: UUID
                switch loaded.status {
                case .complete(let existingID), .partial(let existingID, _):
                    repairID = existingID
                case .absent:
                    repairID = installationID
                case .malformed, .conflictingInstallationIDs, .conflict:
                    return CodexHooksTransformResult(
                        data: data, status: loaded.status, changed: false)
                }
                let swept = disconnect(data, claudioRoot: claudioRoot)
                guard swept.changed, let sweptData = swept.data else {
                    return CodexHooksTransformResult(
                        data: data,
                        status: .malformed(
                            reason: "无法安全清理 Codex 旧 helper 路径 callback"),
                        changed: false)
                }
                let rebuilt = connect(
                    sweptData,
                    installationID: repairID,
                    claudioBinaryPath: claudioBinaryPath,
                    claudioRoot: claudioRoot,
                    externallyManagedNativeEvents: externallyManagedNativeEvents,
                    externalInstallationID: externalInstallationID)
                return CodexHooksTransformResult(
                    data: rebuilt.data,
                    status: rebuilt.status,
                    changed: rebuilt.changed,
                    removedCount: swept.removedCount + rebuilt.removedCount)
            }

            let chosenID: UUID
            let missingEvents: [String]
            switch loaded.status {
            case .partial(let existingID, let missing):
                chosenID = existingID
                missingEvents = missing
            case .absent:
                chosenID = installationID
                missingEvents = managedNativeEvents
            default:
                return CodexHooksTransformResult(
                    data: data, status: loaded.status, changed: false)
            }

            var root = loaded.root
            var hooks = (root[hooksKey] as? [String: Any]) ?? [:]
            for nativeEvent in missingEvents {
                guard
                    let semanticEvent = HostCapabilityCatalog.semanticEvent(
                        host: .codex, nativeEvent: nativeEvent),
                    let command = hostIntegrationHookCommand(
                        host: .codex,
                        nativeEvent: nativeEvent,
                        installationID: chosenID,
                        claudioBinaryPath: claudioBinaryPath),
                    matchedCurrentHostHookCommand(
                        inHookCommand: command, claudioBinaryPath: claudioBinaryPath)
                        == MatchedHostHookCommand(
                            host: .codex,
                            nativeEvent: nativeEvent,
                            event: semanticEvent,
                            installationID: chosenID)
                else {
                    return CodexHooksTransformResult(
                        data: data,
                        status: .malformed(
                            reason: "无法为 Codex \(nativeEvent) 生成当前 claudi0 root 可识别的命令"),
                        changed: false)
                }

                var groups = (hooks[nativeEvent] as? [Any]) ?? []
                groups.append([
                    hooksKey: [[typeKey: commandType, commandKey: command]]
                ])
                hooks[nativeEvent] = groups
            }
            root[hooksKey] = hooks

            guard let encoded = encode(root) else {
                return CodexHooksTransformResult(
                    data: data,
                    status: .malformed(reason: "Codex hooks.json 无法安全序列化"),
                    changed: false)
            }
            return CodexHooksTransformResult(
                data: encoded, status: .complete(installationID: chosenID), changed: true)
        }
    }

    /// Removes only commands structurally recognized as Codex hooks under `claudioRoot`.
    /// Matching intentionally keys off the command rather than `type`: a typeless leftover that
    /// Claudio previously wrote is not runnable, but disconnect must still be able to clean it.
    public static func disconnect(
        _ data: Data?, claudioRoot: String
    ) -> CodexHooksTransformResult {
        switch loadAndInspect(
            data,
            claudioRoot: claudioRoot,
            claudioBinaryPath: nil,
            externallyManagedNativeEvents: [],
            externalInstallationID: nil)
        {
        case .failure(let error):
            return CodexHooksTransformResult(
                data: data, status: .malformed(reason: error.reason), changed: false)
        case .success(let loaded):
            var root = loaded.root
            guard var hooks = root[hooksKey] as? [String: Any] else {
                return CodexHooksTransformResult(
                    data: data, status: .absent, changed: false)
            }

            var removed = 0
            for nativeEvent in managedNativeEvents {
                guard let groups = hooks[nativeEvent] as? [Any] else { continue }
                var retainedGroups: [Any] = []
                for rawGroup in groups {
                    // `loadAndInspect` validated these casts before any mutation.
                    guard var group = rawGroup as? [String: Any],
                        let innerHooks = group[hooksKey] as? [Any]
                    else {
                        return CodexHooksTransformResult(
                            data: data,
                            status: .malformed(
                                reason: "Codex hooks.json 在断开前出现未通过校验的 group"),
                            changed: false)
                    }

                    var groupRemoved = 0
                    let retainedInner = innerHooks.filter { rawInner in
                        guard let inner = rawInner as? [String: Any],
                            let command = inner[commandKey] as? String,
                            let match = matchedHostHookCommand(
                                inHookCommand: command, claudioRoot: claudioRoot),
                            match.host == .codex,
                            match.nativeEvent == nativeEvent
                        else { return true }
                        groupRemoved += 1
                        removed += 1
                        return false
                    }

                    if retainedInner.isEmpty, groupRemoved > 0 {
                        // Claudio emptied this group, so the group is now ours to remove. A group
                        // already empty before this sweep has `groupRemoved == 0` and survives.
                        continue
                    }
                    if groupRemoved > 0 { group[hooksKey] = retainedInner }
                    retainedGroups.append(group)
                }

                if retainedGroups.isEmpty {
                    hooks.removeValue(forKey: nativeEvent)
                } else {
                    hooks[nativeEvent] = retainedGroups
                }
            }

            guard removed > 0 else {
                return CodexHooksTransformResult(
                    data: data, status: loaded.status, changed: false)
            }
            root[hooksKey] = hooks
            guard let encoded = encode(root) else {
                return CodexHooksTransformResult(
                    data: data,
                    status: .malformed(reason: "Codex hooks.json 断开结果无法安全序列化"),
                    changed: false)
            }
            return CodexHooksTransformResult(
                data: encoded, status: .absent, changed: true, removedCount: removed)
        }
    }

    private struct LoadedDocument {
        let root: [String: Any]
        let status: CodexHooksConfigurationStatus
        let hasRelocatedOwnedCommands: Bool
    }

    private struct SchemaError: Error {
        let reason: String
    }

    private static func loadAndInspect(
        _ data: Data?,
        claudioRoot: String,
        claudioBinaryPath: String?,
        externallyManagedNativeEvents: Set<String>,
        externalInstallationID: UUID?
    ) -> Result<LoadedDocument, SchemaError> {
        let root: [String: Any]
        if let data {
            do {
                let object = try JSONSerialization.jsonObject(with: data)
                guard let dictionary = object as? [String: Any] else {
                    return .failure(SchemaError(reason: "Codex hooks.json 顶层必须是对象"))
                }
                root = dictionary
            } catch {
                return .failure(
                    SchemaError(reason: "Codex hooks.json 解析失败：\(error.localizedDescription)"))
            }
        } else {
            root = [:]
        }

        let unknownExternalEvents = externallyManagedNativeEvents.subtracting(managedNativeEvents)
        guard unknownExternalEvents.isEmpty else {
            return .failure(
                SchemaError(
                    reason:
                        "Codex 外部管理事件不受支持：\(unknownExternalEvents.sorted().joined(separator: ", "))"
                ))
        }
        guard externallyManagedNativeEvents.isEmpty == (externalInstallationID == nil) else {
            return .failure(
                SchemaError(reason: "Codex 外部管理事件与 external installation ID 必须同时提供"))
        }

        var installationIDs = Set<UUID>()
        var presentEventCounts = Dictionary(
            uniqueKeysWithValues: externallyManagedNativeEvents.map { ($0, 1) })
        if let externalInstallationID { installationIDs.insert(externalInstallationID) }

        guard let rawHooks = root[hooksKey] else {
            return .success(
                LoadedDocument(
                    root: root,
                    status: configurationStatus(
                        installationIDs: installationIDs,
                        presentEventCounts: presentEventCounts),
                    hasRelocatedOwnedCommands: false))
        }
        guard let hooks = rawHooks as? [String: Any] else {
            return .failure(SchemaError(reason: "Codex hooks.json 的 hooks 必须是对象"))
        }

        var hasRelocatedOwnedCommands = false

        for (eventName, rawGroups) in hooks {
            guard let groups = rawGroups as? [Any] else {
                return .failure(
                    SchemaError(reason: "Codex hooks.json 的 hooks.\(eventName) 必须是数组"))
            }
            for (groupIndex, rawGroup) in groups.enumerated() {
                guard let group = rawGroup as? [String: Any],
                    let innerHooks = group[hooksKey] as? [Any]
                else {
                    return .failure(
                        SchemaError(
                            reason:
                                "Codex hooks.json 的 hooks.\(eventName)[\(groupIndex)] 必须是含 hooks 数组的对象"
                        ))
                }
                if let matcher = group["matcher"], !(matcher is String) {
                    return .failure(
                        SchemaError(
                            reason:
                                "Codex hooks.json 的 hooks.\(eventName)[\(groupIndex)].matcher 必须是字符串"
                        ))
                }
                for (innerIndex, rawInner) in innerHooks.enumerated() {
                    guard let inner = rawInner as? [String: Any] else {
                        return .failure(
                            SchemaError(
                                reason:
                                    "Codex hooks.json 的 hooks.\(eventName)[\(groupIndex)].hooks[\(innerIndex)] 必须是对象"
                            ))
                    }
                    if let type = inner[typeKey], !(type is String) {
                        return .failure(
                            SchemaError(
                                reason:
                                    "Codex hooks.json 的 hooks.\(eventName)[\(groupIndex)].hooks[\(innerIndex)].type 必须是字符串"
                            ))
                    }
                    if let command = inner[commandKey], !(command is String) {
                        return .failure(
                            SchemaError(
                                reason:
                                    "Codex hooks.json 的 hooks.\(eventName)[\(groupIndex)].hooks[\(innerIndex)].command 必须是字符串"
                            ))
                    }
                    if (inner[typeKey] as? String) == commandType, inner[commandKey] == nil {
                        return .failure(
                            SchemaError(
                                reason:
                                    "Codex command hook 缺少 hooks.\(eventName)[\(groupIndex)].hooks[\(innerIndex)].command"
                            ))
                    }
                    guard (inner[typeKey] as? String) == commandType,
                        let command = inner[commandKey] as? String
                    else { continue }
                    let candidate: MatchedHostHookCommand?
                    if let claudioBinaryPath {
                        candidate = matchedCurrentHostHookCommand(
                            inHookCommand: command,
                            claudioBinaryPath: claudioBinaryPath)
                        if candidate == nil,
                            let relocated = matchedHostHookCommand(
                                inHookCommand: command, claudioRoot: claudioRoot),
                            relocated.host == .codex
                        {
                            guard relocated.nativeEvent == eventName else {
                                return .failure(
                                    SchemaError(
                                        reason:
                                            "claudi0 Codex 旧 helper \(relocated.nativeEvent) 命令"
                                            + "位于错误事件 hooks.\(eventName)"))
                            }
                            hasRelocatedOwnedCommands = true
                        }
                    } else {
                        candidate = matchedHostHookCommand(
                            inHookCommand: command,
                            claudioRoot: claudioRoot)
                    }
                    guard let match = candidate, match.host == .codex else { continue }
                    guard match.nativeEvent == eventName else {
                        return .failure(
                            SchemaError(
                                reason:
                                    "claudi0 Codex \(match.nativeEvent) 命令位于错误事件 hooks.\(eventName)"
                            ))
                    }
                    guard !externallyManagedNativeEvents.contains(eventName) else {
                        return .failure(
                            SchemaError(
                                reason:
                                    "Codex \(eventName) 同时由旧 wrapper 与 hooks.json 管理，可能重复播放"))
                    }
                    installationIDs.insert(match.installationID)
                    presentEventCounts[eventName, default: 0] += 1
                }
            }
        }

        return .success(
            LoadedDocument(
                root: root,
                status: configurationStatus(
                    installationIDs: installationIDs,
                    presentEventCounts: presentEventCounts),
                hasRelocatedOwnedCommands: hasRelocatedOwnedCommands))
    }

    private static func configurationStatus(
        installationIDs: Set<UUID>, presentEventCounts: [String: Int]
    ) -> CodexHooksConfigurationStatus {
        let sortedIDs = installationIDs.sorted { $0.uuidString < $1.uuidString }
        guard !sortedIDs.isEmpty else {
            return .absent
        }
        guard sortedIDs.count == 1, let currentID = sortedIDs.first else {
            return .conflictingInstallationIDs(sortedIDs)
        }
        let duplicatedEvents = managedNativeEvents.filter {
            presentEventCounts[$0, default: 0] > 1
        }
        if !duplicatedEvents.isEmpty {
            return .conflict(
                reason: "Codex hooks 含重复 claudi0 事件：\(duplicatedEvents.joined(separator: ", "))")
        }
        let missing = managedNativeEvents.filter { presentEventCounts[$0, default: 0] == 0 }
        if missing.isEmpty {
            return .complete(installationID: currentID)
        }
        return .partial(installationID: currentID, missingNativeEvents: missing)
    }

    private static func encode(_ root: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(root) else { return nil }
        return try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}
