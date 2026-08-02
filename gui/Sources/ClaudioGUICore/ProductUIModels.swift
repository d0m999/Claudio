import ClaudioCore
import Foundation

/// Claudio 自己的界面文字偏好。macOS SwiftUI 的 `dynamicTypeSize` 不会跟随系统文字大小，
/// 因此三个产品界面共享这一个显式、可持久化的四档设置。
public enum ClaudioInterfaceTextSize: String, CaseIterable, Codable, Sendable, Identifiable {
    case compact
    case standard
    case large
    case maximum

    public static let defaultsKey = "Claudio.InterfaceTextSize"
    public static let defaultValue: ClaudioInterfaceTextSize = .standard

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .compact: "紧凑"
        case .standard: "标准"
        case .large: "较大"
        case .maximum: "最大"
        }
    }

    /// 仅供固定点字号仍需显式缩放的根视图使用。语义字体由 SwiftUI 环境缩放。
    public var scale: Double {
        switch self {
        case .compact: 0.92
        case .standard: 1
        case .large: 1.18
        case .maximum: 1.42
        }
    }

    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? Self.defaultValue
    }
}

/// 主面板声音包区域的四个互斥状态。`noPinnedPacks` 与 `noPacks` 不能合并：前者有包可恢复，
/// 后者必须把用户带到完整管理窗口创建或恢复包。
public enum PanelPackSectionState: Sendable, Equatable {
    case pinned([PackCard])
    case noPinnedPacks(availablePackCount: Int)
    case noPacks
    case readFailed(reason: String)
}

public func panelPackSectionState(
    pinnedCards: [PackCard],
    availablePackCount: Int,
    readFailureReason: String? = nil
) -> PanelPackSectionState {
    if let readFailureReason, !readFailureReason.isEmpty {
        return .readFailed(reason: readFailureReason)
    }
    if !pinnedCards.isEmpty { return .pinned(Array(pinnedCards.prefix(maxStarredPacks))) }
    if availablePackCount > 0 { return .noPinnedPacks(availablePackCount: availablePackCount) }
    return .noPacks
}

/// 手工试听与事件自动播放静音完全正交。只要映射仍是安全、可读的正规文件且主音量非零，
/// `enabled == false` 的真实事件也可以从面板或声音包窗口手工试听。
public enum EventPreviewAvailability: Sendable, Equatable {
    case available(fileName: String)
    case masterVolumeZero(fileName: String)
    case unmapped
    case missingOrDamaged(fileName: String)
    case unsafeOrUnreadable(reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var unavailableReason: String? {
        switch self {
        case .available:
            return nil
        case .masterVolumeZero:
            return "主音量为零"
        case .unmapped:
            return "尚未配置声音"
        case .missingOrDamaged:
            return "声音文件缺失或损坏"
        case .unsafeOrUnreadable(let reason):
            return reason
        }
    }

    public var accessibilityHint: String {
        switch self {
        case .available:
            return "播放当前映射的音频；事件静音不影响手工试听"
        case .masterVolumeZero:
            return "主音量为零；调高主音量后可以试听"
        case .unmapped:
            return "尚未配置声音；请在声音包窗口中绑定音频"
        case .missingOrDamaged:
            return "映射的声音文件缺失或损坏；请在声音包窗口中修复"
        case .unsafeOrUnreadable(let reason):
            return "无法安全试听：\(reason)"
        }
    }
}

public func eventPreviewAvailability(
    coverage: CoverageState,
    masterVolume: Double,
    safetyFailureReason: String? = nil
) -> EventPreviewAvailability {
    if let safetyFailureReason, !safetyFailureReason.isEmpty {
        return .unsafeOrUnreadable(reason: safetyFailureReason)
    }
    switch coverage {
    case .unmapped:
        return .unmapped
    case .broken(let fileName):
        return .missingOrDamaged(fileName: fileName)
    case .present(let fileName):
        return AfplayVolume.clamped(masterVolume) == 0
            ? .masterVolumeZero(fileName: fileName)
            : .available(fileName: fileName)
    }
}

/// 保留的声音包窗口只接受显式路由；`.overview` 不改变当前检查上下文，`.editEvent` 才定位包与事件。
public enum SoundPacksWindowRoute: Sendable, Equatable, Hashable {
    case overview
    case editEvent(packID: String, event: Event)
}

/// 能力矩阵当前格子的首要恢复意图。它只描述产品动作，不执行 host/config I/O。
public enum IntegrationsRecoveryAction: Sendable, Equatable, Hashable {
    case unmute(host: HostID, event: Event)
    case configureSound(host: HostID, event: Event)
    case connect(HostID)
    case upgrade(HostID)
    case repair(HostID)
    case redetect(HostID)
    case explainUnsupported(host: HostID, event: Event)
    case none

    public var title: String? {
        switch self {
        case .unmute: "取消静音"
        case .configureSound: "配置声音…"
        case .connect(let host): "连接 \(host.displayName)"
        case .upgrade: "升级连接"
        case .repair(let host): "修复 \(host.displayName) 连接"
        case .redetect: "重新检测"
        case .explainUnsupported, .none: nil
        }
    }
}

public func integrationsRecoveryAction(
    for cell: HostCapabilityCellPresentation,
    hostStatus: HostSourceRowStatus
) -> IntegrationsRecoveryAction {
    switch cell.state {
    case .audible:
        return .none
    case .muted:
        return .unmute(host: cell.host, event: cell.event)
    case .missingSound:
        return .configureSound(host: cell.host, event: cell.event)
    case .notConnected:
        return .connect(cell.host)
    case .awaitingActivation:
        return .redetect(cell.host)
    case .legacy:
        return .upgrade(cell.host)
    case .unsupported:
        return .explainUnsupported(host: cell.host, event: cell.event)
    case .degraded:
        return hostStatus == .legacy ? .upgrade(cell.host) : .repair(cell.host)
    }
}

/// 配置路径的可见短形。完整值仍应作为 tooltip 与 accessibility value 暴露。
public func abbreviatedConfigurationPath(
    _ path: String,
    homeDirectory: String = NSHomeDirectory()
) -> String {
    guard !path.hasPrefix("~") else { return path }
    let normalizedHome = URL(fileURLWithPath: homeDirectory).standardizedFileURL.path
    let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
    guard normalizedPath == normalizedHome || normalizedPath.hasPrefix(normalizedHome + "/") else {
        return path
    }
    return "~" + normalizedPath.dropFirst(normalizedHome.count)
}
