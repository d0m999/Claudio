import Foundation

struct SurfaceSoundDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// 一个 surface 对全局声音默认值的稀疏覆盖。`nil`/缺键表示继承，不表示空值。
public struct SurfaceSoundOverride: Codable, Sendable, Equatable {
    public let selectedPack: String?
    public let eventsEnabled: [String: Bool]

    public init(selectedPack: String? = nil, eventsEnabled: [String: Bool] = [:]) {
        self.selectedPack = selectedPack
        self.eventsEnabled = eventsEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case selectedPack = "selected_pack"
        case eventsEnabled = "events"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.selectedPack) {
            selectedPack = try container.decode(String.self, forKey: .selectedPack)
        } else {
            selectedPack = nil
        }
        if container.contains(.eventsEnabled) {
            eventsEnabled = try container.decode([String: Bool].self, forKey: .eventsEnabled)
        } else {
            eventsEnabled = [:]
        }
    }
}

public struct ResolvedSoundProfile: Sendable, Equatable {
    public let selectedPack: String
    public let eventsEnabled: [String: Bool]
    public let inheritedPack: Bool
    public let inheritedEvents: Set<Event>

    public func isEnabled(_ event: Event) -> Bool {
        eventsEnabled[event.cliName] ?? true
    }
}

public enum SurfaceSoundProfileError: Error, Sendable, Equatable {
    case malformedOverrides
    case malformedOverride(surface: HostSurfaceID)
}

extension ClaudioConfig {
    /// 解析 effective profile 的唯一入口。显式损坏覆盖返回失败，绝不静默继承。
    public func resolveSoundProfile(
        for surface: HostSurfaceID?
    ) -> Result<ResolvedSoundProfile, SurfaceSoundProfileError> {
        guard let surface else {
            return .success(
                ResolvedSoundProfile(
                    selectedPack: selectedPack,
                    eventsEnabled: eventsEnabled,
                    inheritedPack: false,
                    inheritedEvents: []))
        }
        guard !surfaceOverridesMalformed else { return .failure(.malformedOverrides) }
        guard !invalidSurfaceOverrideKeys.contains(surface.rawValue) else {
            return .failure(.malformedOverride(surface: surface))
        }
        guard let override = surfaceOverrides[surface.rawValue] else {
            return .success(
                ResolvedSoundProfile(
                    selectedPack: selectedPack,
                    eventsEnabled: eventsEnabled,
                    inheritedPack: true,
                    inheritedEvents: Set(Event.allCases)))
        }
        var effectiveEvents = eventsEnabled
        for (event, enabled) in override.eventsEnabled {
            effectiveEvents[event] = enabled
        }
        return .success(
            ResolvedSoundProfile(
                selectedPack: override.selectedPack ?? selectedPack,
                eventsEnabled: effectiveEvents,
                inheritedPack: override.selectedPack == nil,
                inheritedEvents: Set(
                    Event.allCases.filter {
                        override.eventsEnabled[$0.cliName] == nil
                    })))
    }
}

public enum SurfaceSoundMutationOutcome: Sendable, Equatable {
    case updated(surface: HostSurfaceID)
}

public enum SurfaceSoundMutationError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidPackID(String)
    case packNotFound(String)
    case manifestUnreadable(packID: String, reason: String)
    case configReadFailure(reason: String)
    case configWriteFailure(reason: String)
    case configMissing
    case lockBusy
    case lockFailed(errno: Int32)

    public var description: String {
        switch self {
        case .invalidPackID(let id): "\"\(id)\" 不是合法的声音包 id"
        case .packNotFound(let id): "找不到声音包 \"\(id)\""
        case .manifestUnreadable(let id, let reason):
            "声音包 \"\(id)\" 的 manifest.json 无法安全读取或解析：\(reason)"
        case .configReadFailure(let reason): "config.json 读取失败，已中止（未修改文件）：\(reason)"
        case .configWriteFailure(let reason): "config.json 写入失败：\(reason)"
        case .configMissing: "config.json 不存在，请先选择全局默认声音包"
        case .lockBusy: "config.json 当前被占用（另一个 claudio 进程正在读写），请稍后重试"
        case .lockFailed(let errno): "无法获取文件锁（errno \(errno)），请稍后重试"
        }
    }
}

public enum SurfaceSoundOverrideField: Sendable, Equatable {
    case selectedPack
    case event(Event)
    case all
}

public func setSurfacePack(
    _ packID: String,
    surface: HostSurfaceID,
    configFile: URL = ClaudioPaths.configFile,
    userPacksDirectory: URL = ClaudioPaths.packsDirectory,
    bundledPacksDirectory: URL? = nil,
    lockFile: URL = ClaudioPaths.configLockFile
) -> Result<SurfaceSoundMutationOutcome, SurfaceSoundMutationError> {
    guard isSafePackID(packID) else { return .failure(.invalidPackID(packID)) }
    guard
        let directory = resolvePackDirectory(
            id: packID,
            userPacksDirectory: userPacksDirectory,
            bundledPacksDirectory: bundledPacksDirectory)
    else { return .failure(.packNotFound(packID)) }
    if case .failure(let error) = loadPackManifest(in: directory) {
        return .failure(.manifestUnreadable(packID: packID, reason: error.reason))
    }
    return mutateSurfaceSoundOverride(surface: surface, configFile: configFile, lockFile: lockFile)
    {
        $0["selected_pack"] = packID
    }
}

public func setSurfaceEventEnabled(
    _ event: Event,
    enabled: Bool,
    surface: HostSurfaceID,
    configFile: URL = ClaudioPaths.configFile,
    lockFile: URL = ClaudioPaths.configLockFile
) -> Result<SurfaceSoundMutationOutcome, SurfaceSoundMutationError> {
    mutateSurfaceSoundOverride(surface: surface, configFile: configFile, lockFile: lockFile) {
        var events = $0["events"] as? [String: Any] ?? [:]
        events[event.cliName] = enabled
        $0["events"] = events
    }
}

public func resetSurfaceSoundOverride(
    surface: HostSurfaceID,
    field: SurfaceSoundOverrideField = .all,
    configFile: URL = ClaudioPaths.configFile,
    lockFile: URL = ClaudioPaths.configLockFile
) -> Result<SurfaceSoundMutationOutcome, SurfaceSoundMutationError> {
    mutateSurfaceSoundOverride(surface: surface, configFile: configFile, lockFile: lockFile) {
        switch field {
        case .selectedPack:
            $0.removeValue(forKey: "selected_pack")
        case .event(let event):
            var events = $0["events"] as? [String: Any] ?? [:]
            events.removeValue(forKey: event.cliName)
            if events.isEmpty { $0.removeValue(forKey: "events") } else { $0["events"] = events }
        case .all:
            $0.removeAll()
        }
    }
}

private func mutateSurfaceSoundOverride(
    surface: HostSurfaceID,
    configFile: URL,
    lockFile: URL,
    mutation: (inout [String: Any]) -> Void
) -> Result<SurfaceSoundMutationOutcome, SurfaceSoundMutationError> {
    let locked = withNonBlockingLock(path: lockFile.path) {
        updateConfigJSON(at: configFile, onMissing: .failClosed) { json in
            var surfaces = json["surface_overrides"] as? [String: Any] ?? [:]
            var override = surfaces[surface.rawValue] as? [String: Any] ?? [:]
            mutation(&override)
            if override.isEmpty {
                surfaces.removeValue(forKey: surface.rawValue)
            } else {
                surfaces[surface.rawValue] = override
            }
            if surfaces.isEmpty {
                json.removeValue(forKey: "surface_overrides")
            } else {
                json["surface_overrides"] = surfaces
            }
            return .success(())
        }
    }
    switch locked {
    case .skipped: return .failure(.lockBusy)
    case .failed(let errno): return .failure(.lockFailed(errno: errno))
    case .ran(.success): return .success(.updated(surface: surface))
    case .ran(.failure(.missing)): return .failure(.configMissing)
    case .ran(.failure(.unreadable(let reason))):
        return .failure(.configReadFailure(reason: reason))
    case .ran(.failure(.writeFailed(let reason))):
        return .failure(.configWriteFailure(reason: reason))
    case .ran(.failure(.mutationRejected)):
        return .failure(.configWriteFailure(reason: "配置变更被调用方拒绝"))
    }
}
