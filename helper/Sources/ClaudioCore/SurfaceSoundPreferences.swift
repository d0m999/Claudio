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
    public var volume: Double = ClaudioConfig.defaultMasterVolume
    public var workspaceID: UUID? = nil

    public func isEnabled(_ event: Event) -> Bool {
        eventsEnabled[event.cliName] ?? true
    }
}

public enum SurfaceSoundProfileError: Error, Sendable, Equatable {
    case malformedOverrides
    case malformedOverride(surface: HostSurfaceID)
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
    case configPublishedButFailed(reason: String, recoveryPath: String? = nil)
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
        case .configPublishedButFailed(let reason, _): reason
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
    .failure(.configWriteFailure(reason: "来源声音设置已退役，请编辑默认组或工作区。"))
}

public func setSurfaceEventEnabled(
    _ event: Event,
    enabled: Bool,
    surface: HostSurfaceID,
    configFile: URL = ClaudioPaths.configFile,
    lockFile: URL = ClaudioPaths.configLockFile
) -> Result<SurfaceSoundMutationOutcome, SurfaceSoundMutationError> {
    .failure(.configWriteFailure(reason: "来源声音设置已退役，请编辑默认组或工作区。"))
}

public func resetSurfaceSoundOverride(
    surface: HostSurfaceID,
    field: SurfaceSoundOverrideField = .all,
    configFile: URL = ClaudioPaths.configFile,
    lockFile: URL = ClaudioPaths.configLockFile
) -> Result<SurfaceSoundMutationOutcome, SurfaceSoundMutationError> {
    .failure(.configWriteFailure(reason: "来源声音设置已退役，旧字段已保留；请编辑默认组或工作区。"))
}
