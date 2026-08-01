import Foundation

/// Claude Code `settings.json` 中 Claudio 自有条目的只读分类。
public enum ClaudeCodeHooksInspection: Sendable, Equatable {
    case notConfigured
    case legacyConnected
    case configured(installationID: UUID)
    case partial(missingNativeEvents: [String], hasLegacyEntries: Bool)
    case conflict(reason: String)
}

public enum HostHooksTransformError: Error, Sendable, Equatable, CustomStringConvertible {
    case malformed(reason: String)

    public var description: String {
        switch self {
        case .malformed(let reason): reason
        }
    }
}

/// 纯 JSON 变换结果。`root` 保留所有非 Claudio 数据；上层只有在 `changed == true` 时才交给
/// ``ConfigFileTransaction`` 写盘。
public struct HostHooksJSONMutation {
    public let root: [String: Any]
    public let changed: Bool
    public let removedCount: Int

    public init(root: [String: Any], changed: Bool, removedCount: Int = 0) {
        self.root = root
        self.changed = changed
        self.removedCount = removedCount
    }
}

/// 只读检查 Claude Code 的 hooks。modern Claudio command 会扫描所有事件键，避免一条
/// 错放在 `SessionStart` / `UserPromptSubmit` 等合法事件下的 callback 被完整四事件掩盖；
/// legacy `claudio play` 仍只在四个正式事件中计入连接，因此旧任务开始声音原样保留。
public func inspectClaudeCodeHooks(
    root: [String: Any],
    claudioRoot: String,
    claudioBinaryPath: String
) -> Result<ClaudeCodeHooksInspection, HostHooksTransformError> {
    switch validatedClaudeHooks(in: root) {
    case .failure(let error):
        return .failure(error)
    case .success(let hooks):
        let bindings = HostCapabilityCatalog.bindings(for: .claudeCode)
        let bindingByNativeEvent = Dictionary(
            uniqueKeysWithValues: bindings.compactMap { binding in
                binding.nativeEvent.map { ($0, binding) }
            })
        var legacyEvents = Set<Event>()
        var modernByNativeEvent: [String: [MatchedHostHookCommand]] = [:]
        var ownedCount = 0
        var misplacedModern = false

        for (nativeEvent, rawGroups) in hooks {
            guard let groups = rawGroups as? [Any] else { continue }
            for group in groups {
                let entries = ((group as? [String: Any])?["hooks"] as? [Any]) ?? []
                for entry in entries {
                    guard let entry = entry as? [String: Any],
                        (entry["type"] as? String) == "command",
                        let command = entry["command"] as? String
                    else {
                        continue
                    }
                    if let modern = matchedCurrentHostHookCommand(
                        inHookCommand: command, claudioBinaryPath: claudioBinaryPath),
                        modern.host == .claudeCode
                    {
                        ownedCount += 1
                        modernByNativeEvent[nativeEvent, default: []].append(modern)
                        misplacedModern = misplacedModern || modern.nativeEvent != nativeEvent
                    } else if let binding = bindingByNativeEvent[nativeEvent],
                        let event = matchedClaudioEvent(
                            inHookCommand: command, claudioRoot: claudioRoot)
                    {
                        ownedCount += 1
                        if event == binding.event { legacyEvents.insert(event) }
                    }
                }
            }
        }

        guard ownedCount > 0 else { return .success(.notConfigured) }
        if misplacedModern {
            return .success(.conflict(reason: "Claude Code hook 的事件位置与命令不一致"))
        }

        let modern = modernByNativeEvent.values.flatMap { $0 }
        let modernIDs = Set(modern.map(\.installationID))
        let duplicatedModernEvent = modernByNativeEvent.values.contains { $0.count > 1 }
        if modernIDs.count > 1 || duplicatedModernEvent {
            return .success(.conflict(reason: "Claude Code hook 含重复或不同安装代次"))
        }

        let modernMissing = bindings.compactMap { binding -> String? in
            guard let nativeEvent = binding.nativeEvent else { return nil }
            return modernByNativeEvent[nativeEvent]?.count == 1 ? nil : nativeEvent
        }
        if modernMissing.isEmpty, legacyEvents.isEmpty, let id = modernIDs.first {
            return .success(.configured(installationID: id))
        }
        if modern.isEmpty, legacyEvents == Set(bindings.map(\.event)) {
            return .success(.legacyConnected)
        }
        return .success(
            .partial(
                missingNativeEvents: modernMissing,
                hasLegacyEntries: !legacyEvents.isEmpty))
    }
}

/// 显式连接/升级 Claude Code：若已是完整现代连接且所有事件都没有额外 modern callback，
/// 则幂等不写；否则清理所有事件中的 modern Claudio 条目，只在四个正式事件中清理 legacy，
/// 再为四个正式事件追加同一 installation ID 的 canonical command hook。
public func connectClaudeCodeHooks(
    root: [String: Any],
    claudioRoot: String,
    claudioBinaryPath: String,
    installationID: UUID
) -> Result<HostHooksJSONMutation, HostHooksTransformError> {
    let inspection: ClaudeCodeHooksInspection
    switch inspectClaudeCodeHooks(
        root: root,
        claudioRoot: claudioRoot,
        claudioBinaryPath: claudioBinaryPath)
    {
    case .failure(let error): return .failure(error)
    case .success(let value): inspection = value
    }
    let hasRelocatedModern = containsRelocatedClaudeCodeHooks(
        root: root,
        claudioRoot: claudioRoot,
        claudioBinaryPath: claudioBinaryPath)
    if case .configured = inspection, !hasRelocatedModern {
        return .success(HostHooksJSONMutation(root: root, changed: false))
    }
    let chosenInstallationID: UUID
    if case .configured(let currentID) = inspection {
        chosenInstallationID = currentID
    } else {
        chosenInstallationID = installationID
    }

    var next = root
    var hooks = (next["hooks"] as? [String: Any]) ?? [:]
    var removed = 0
    let officialNativeEvents = Set(
        HostCapabilityCatalog.bindings(for: .claudeCode).compactMap(\.nativeEvent))
    for nativeEvent in Array(hooks.keys) {
        guard let groups = hooks[nativeEvent] as? [Any] else { continue }
        let filtered = filterClaudeOwnedEntries(
            groups: groups,
            claudioRoot: claudioRoot,
            // A repair connect must sweep Claudio-owned commands written by an older helper
            // location before appending today's canonical one. Inspect stays exact-current so a
            // removed old binary can never make the host look connected.
            modernBinaryPath: nil,
            removeLegacy: officialNativeEvents.contains(nativeEvent),
            removed: &removed)
        if filtered.isEmpty {
            hooks.removeValue(forKey: nativeEvent)
        } else {
            hooks[nativeEvent] = filtered
        }
    }
    for binding in HostCapabilityCatalog.bindings(for: .claudeCode) {
        guard let nativeEvent = binding.nativeEvent else { continue }
        let groups = (hooks[nativeEvent] as? [Any]) ?? []
        var newGroups = groups
        guard let command = hostIntegrationHookCommand(
            host: .claudeCode,
            nativeEvent: nativeEvent,
            installationID: chosenInstallationID,
            claudioBinaryPath: claudioBinaryPath)
        else {
            return .failure(.malformed(reason: "Claude Code 能力目录缺少 \(nativeEvent)"))
        }
        newGroups.append([
            "hooks": [["type": "command", "command": command]]
        ])
        hooks[nativeEvent] = newGroups
    }
    next["hooks"] = hooks
    return .success(HostHooksJSONMutation(root: next, changed: true, removedCount: removed))
}

/// Whether at least one modern Claude Code command belongs to this Claudio root but does not
/// point at the helper path this build writes. Read-only status deliberately ignores these so an
/// absent old binary cannot make a connection green; explicit connect and the legacy compatibility
/// installer use this broader fact to prevent two callback chains from coexisting.
func containsRelocatedClaudeCodeHooks(
    root: [String: Any],
    claudioRoot: String,
    claudioBinaryPath: String
) -> Bool {
    guard case .success(let hooks) = validatedClaudeHooks(in: root) else { return false }
    for rawGroups in hooks.values {
        guard let groups = rawGroups as? [Any] else { continue }
        for group in groups {
            let entries = ((group as? [String: Any])?["hooks"] as? [Any]) ?? []
            for entry in entries {
                guard let command = (entry as? [String: Any])?["command"] as? String,
                    let historical = matchedHostHookCommand(
                        inHookCommand: command, claudioRoot: claudioRoot),
                    historical.host == .claudeCode,
                    matchedCurrentHostHookCommand(
                        inHookCommand: command, claudioBinaryPath: claudioBinaryPath) == nil
                else { continue }
                return true
            }
        }
    }
    return false
}

/// 精准断开 Claude Code：扫描所有事件并移除 modern Claudio command；legacy 只在四个
/// 正式事件中移除，因此用户已有的 `UserPromptSubmit → claudio play notification` 原样保留。
public func disconnectClaudeCodeHooks(
    root: [String: Any],
    claudioRoot: String
) -> Result<HostHooksJSONMutation, HostHooksTransformError> {
    let hooks: [String: Any]
    switch validatedClaudeHooks(in: root) {
    case .failure(let error): return .failure(error)
    case .success(let value): hooks = value
    }

    var next = root
    var nextHooks = hooks
    var removed = 0
    let officialNativeEvents = Set(
        HostCapabilityCatalog.bindings(for: .claudeCode).compactMap(\.nativeEvent))
    for nativeEvent in Array(nextHooks.keys) {
        guard let groups = nextHooks[nativeEvent] as? [Any] else { continue }
        let filtered = filterClaudeOwnedEntries(
            groups: groups,
            claudioRoot: claudioRoot,
            modernBinaryPath: nil,
            removeLegacy: officialNativeEvents.contains(nativeEvent),
            removed: &removed)
        if filtered.isEmpty {
            nextHooks.removeValue(forKey: nativeEvent)
        } else {
            nextHooks[nativeEvent] = filtered
        }
    }
    guard removed > 0 else {
        return .success(HostHooksJSONMutation(root: root, changed: false))
    }
    next["hooks"] = nextHooks
    return .success(HostHooksJSONMutation(root: next, changed: true, removedCount: removed))
}

private func validatedClaudeHooks(
    in root: [String: Any]
) -> Result<[String: Any], HostHooksTransformError> {
    guard let hooksValue = root["hooks"] else { return .success([:]) }
    guard let hooks = hooksValue as? [String: Any] else {
        return .failure(.malformed(reason: "Claude settings.json 的 hooks 必须是 object"))
    }
    for binding in HostCapabilityCatalog.bindings(for: .claudeCode) {
        guard let nativeEvent = binding.nativeEvent, let value = hooks[nativeEvent] else { continue }
        guard let groups = value as? [Any] else {
            return .failure(.malformed(reason: "hooks.\(nativeEvent) 必须是 array"))
        }
        for group in groups {
            guard let group = group as? [String: Any], let entries = group["hooks"] as? [Any] else {
                return .failure(.malformed(reason: "hooks.\(nativeEvent) 的 group 必须含 hooks array"))
            }
            guard entries.allSatisfy({ $0 is [String: Any] }) else {
                return .failure(.malformed(reason: "hooks.\(nativeEvent) 的 hook entry 必须是 object"))
            }
        }
    }
    return .success(hooks)
}

private func filterClaudeOwnedEntries(
    groups: [Any],
    claudioRoot: String,
    modernBinaryPath: String?,
    removeLegacy: Bool,
    removed: inout Int
) -> [Any] {
    var filteredGroups: [Any] = []
    for value in groups {
        guard var group = value as? [String: Any], let entries = group["hooks"] as? [Any] else {
            filteredGroups.append(value)
            continue
        }
        let kept = entries.filter { value in
            guard let command = (value as? [String: Any])?["command"] as? String else {
                return true
            }
            let modern = modernBinaryPath.map {
                matchedCurrentHostHookCommand(
                    inHookCommand: command, claudioBinaryPath: $0)
            } ?? matchedHostHookCommand(inHookCommand: command, claudioRoot: claudioRoot)
            let isModernClaude = modern?.host == .claudeCode
            let isLegacy = removeLegacy
                && matchedClaudioEvent(
                    inHookCommand: command, claudioRoot: claudioRoot) != nil
            if isModernClaude || isLegacy {
                removed += 1
                return false
            }
            return true
        }
        if kept.isEmpty, !entries.isEmpty { continue }
        if kept.count != entries.count { group["hooks"] = kept }
        filteredGroups.append(group)
    }
    return filteredGroups
}
