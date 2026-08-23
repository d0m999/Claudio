import Foundation

/// WorkBuddy Desktop 用户级 `settings.json` 中 Claudio 自有条目的只读分类。
public enum WorkBuddyHooksInspection: Sendable, Equatable {
    case notConfigured
    case configured(installationID: UUID)
    case partial(installationID: UUID?, missingNativeEvents: [String])
    case conflict(reason: String)
}

/// WorkBuddy 首发只安装 catalog 中标为 implemented 的两条 command hook。官方接口中其余
/// binding 继续用于能力展示，但不会被这个变换悄悄写进用户配置。
public func inspectWorkBuddyHooks(
    root: [String: Any],
    claudioBinaryPath: String
) -> Result<WorkBuddyHooksInspection, HostHooksTransformError> {
    let hooks: [String: Any]
    switch validatedWorkBuddyHooks(in: root) {
    case .success(let value): hooks = value
    case .failure(let error): return .failure(error)
    }

    let implemented = HostCapabilityCatalog.bindings(for: .workBuddy)
        .filter(\.isAudibleCapability)
    var matchedByEvent: [String: [MatchedHostHookCommand]] = [:]
    var ownedCount = 0
    var misplaced = false

    for (nativeEvent, rawGroups) in hooks {
        guard let groups = rawGroups as? [Any] else { continue }
        for group in groups {
            let entries = ((group as? [String: Any])?["hooks"] as? [Any]) ?? []
            for entry in entries {
                guard let command = (entry as? [String: Any])?["command"] as? String,
                    let match = matchedCurrentHostHookCommand(
                        inHookCommand: command, claudioBinaryPath: claudioBinaryPath),
                    match.host == .workBuddy
                else { continue }
                ownedCount += 1
                matchedByEvent[nativeEvent, default: []].append(match)
                misplaced = misplaced || match.nativeEvent != nativeEvent
            }
        }
    }

    guard ownedCount > 0 else { return .success(.notConfigured) }
    guard !misplaced else {
        return .success(.conflict(reason: "WorkBuddy hook 的事件位置与命令不一致"))
    }
    let matches = matchedByEvent.values.flatMap { $0 }
    let ids = Set(matches.map(\.installationID))
    guard ids.count <= 1, !matchedByEvent.values.contains(where: { $0.count > 1 }) else {
        return .success(.conflict(reason: "WorkBuddy hook 含重复或不同安装代次"))
    }
    let missing = implemented.compactMap { binding -> String? in
        guard let nativeEvent = binding.nativeEvent else { return nil }
        return matchedByEvent[nativeEvent]?.count == 1 ? nil : nativeEvent
    }
    if missing.isEmpty, let id = ids.first {
        return .success(.configured(installationID: id))
    }
    return .success(.partial(installationID: ids.first, missingNativeEvents: missing))
}

public func connectWorkBuddyHooks(
    root: [String: Any],
    claudioRoot: String,
    claudioBinaryPath: String,
    installationID: UUID
) -> Result<HostHooksJSONMutation, HostHooksTransformError> {
    let inspection: WorkBuddyHooksInspection
    switch inspectWorkBuddyHooks(root: root, claudioBinaryPath: claudioBinaryPath) {
    case .success(let value): inspection = value
    case .failure(let error): return .failure(error)
    }
    if case .configured = inspection,
        !containsRelocatedWorkBuddyHooks(
            root: root,
            claudioRoot: claudioRoot,
            claudioBinaryPath: claudioBinaryPath)
    {
        return .success(HostHooksJSONMutation(root: root, changed: false))
    }

    let chosenID: UUID
    switch inspection {
    case .configured(let id), .partial(let id?, _): chosenID = id
    case .notConfigured, .partial(nil, _), .conflict: chosenID = installationID
    }

    var next = root
    var hooks = (next["hooks"] as? [String: Any]) ?? [:]
    var removed = 0
    for nativeEvent in Array(hooks.keys) {
        guard let groups = hooks[nativeEvent] as? [Any] else { continue }
        let filtered = filterWorkBuddyOwnedEntries(
            groups: groups, claudioRoot: claudioRoot, removed: &removed)
        if filtered.isEmpty {
            hooks.removeValue(forKey: nativeEvent)
        } else {
            hooks[nativeEvent] = filtered
        }
    }

    for binding in HostCapabilityCatalog.bindings(for: .workBuddy)
    where binding.isAudibleCapability {
        guard let nativeEvent = binding.nativeEvent,
            let command = hostIntegrationHookCommand(
                host: .workBuddy,
                nativeEvent: nativeEvent,
                installationID: chosenID,
                claudioBinaryPath: claudioBinaryPath)
        else {
            return .failure(.malformed(reason: "WorkBuddy 能力目录缺少可执行 binding"))
        }
        var groups = (hooks[nativeEvent] as? [Any]) ?? []
        groups.append(["hooks": [["type": "command", "command": command]]])
        hooks[nativeEvent] = groups
    }
    next["hooks"] = hooks
    return .success(HostHooksJSONMutation(root: next, changed: true, removedCount: removed))
}

public func disconnectWorkBuddyHooks(
    root: [String: Any],
    claudioRoot: String
) -> Result<HostHooksJSONMutation, HostHooksTransformError> {
    let hooks: [String: Any]
    switch validatedWorkBuddyHooks(in: root) {
    case .success(let value): hooks = value
    case .failure(let error): return .failure(error)
    }

    var next = root
    var nextHooks = hooks
    var removed = 0
    for nativeEvent in Array(nextHooks.keys) {
        guard let groups = nextHooks[nativeEvent] as? [Any] else { continue }
        let filtered = filterWorkBuddyOwnedEntries(
            groups: groups, claudioRoot: claudioRoot, removed: &removed)
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

private func validatedWorkBuddyHooks(
    in root: [String: Any]
) -> Result<[String: Any], HostHooksTransformError> {
    guard let hooksValue = root["hooks"] else { return .success([:]) }
    guard let hooks = hooksValue as? [String: Any] else {
        return .failure(.malformed(reason: "WorkBuddy settings.json 的 hooks 必须是 object"))
    }
    for (nativeEvent, value) in hooks {
        guard let groups = value as? [Any] else {
            return .failure(.malformed(reason: "hooks.\(nativeEvent) 必须是 array"))
        }
        for group in groups {
            guard let group = group as? [String: Any], let entries = group["hooks"] as? [Any]
            else {
                return .failure(
                    .malformed(reason: "hooks.\(nativeEvent) 的 group 必须含 hooks array"))
            }
            guard entries.allSatisfy({ $0 is [String: Any] }) else {
                return .failure(
                    .malformed(reason: "hooks.\(nativeEvent) 的 hook entry 必须是 object"))
            }
        }
    }
    return .success(hooks)
}

private func containsRelocatedWorkBuddyHooks(
    root: [String: Any],
    claudioRoot: String,
    claudioBinaryPath: String
) -> Bool {
    guard case .success(let hooks) = validatedWorkBuddyHooks(in: root) else { return false }
    for rawGroups in hooks.values {
        guard let groups = rawGroups as? [Any] else { continue }
        for group in groups {
            let entries = ((group as? [String: Any])?["hooks"] as? [Any]) ?? []
            for entry in entries {
                guard let command = (entry as? [String: Any])?["command"] as? String,
                    matchedHostHookCommand(inHookCommand: command, claudioRoot: claudioRoot)?.host
                        == .workBuddy,
                    matchedCurrentHostHookCommand(
                        inHookCommand: command,
                        claudioBinaryPath: claudioBinaryPath) == nil
                else { continue }
                return true
            }
        }
    }
    return false
}

private func filterWorkBuddyOwnedEntries(
    groups: [Any],
    claudioRoot: String,
    removed: inout Int
) -> [Any] {
    var filteredGroups: [Any] = []
    for value in groups {
        guard var group = value as? [String: Any], let entries = group["hooks"] as? [Any]
        else {
            filteredGroups.append(value)
            continue
        }
        let kept = entries.filter { value in
            guard let command = (value as? [String: Any])?["command"] as? String,
                matchedHostHookCommand(inHookCommand: command, claudioRoot: claudioRoot)?.host
                    == .workBuddy
            else { return true }
            removed += 1
            return false
        }
        if kept.isEmpty, !entries.isEmpty { continue }
        if kept.count != entries.count { group["hooks"] = kept }
        filteredGroups.append(group)
    }
    return filteredGroups
}
