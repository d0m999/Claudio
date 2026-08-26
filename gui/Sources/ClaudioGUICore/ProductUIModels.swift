import ClaudioCore
import ClaudioLocalization
import Foundation

enum SoundPackReadSource: Sendable {
    case sharedLibrary
    #if DEBUG
    case directDiskFixture
    #endif

    var readsSharedSnapshot: Bool {
        switch self {
        case .sharedLibrary:
            return true
        #if DEBUG
        case .directDiskFixture:
            return false
        #endif
        }
    }
}

/// Claudio 自己的界面文字偏好。macOS SwiftUI 的 `dynamicTypeSize` 不会跟随系统文字大小，
/// 因此四个产品界面共享这一个显式、可持久化的四档设置。
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

    public func localizedDisplayName(_ language: ClaudioAppLanguage) -> String {
        let l10n = ClaudioL10n(language: language)
        return switch self {
        case .compact: l10n.text(.interfaceTextSizeCompact)
        case .standard: l10n.text(.interfaceTextSizeStandard)
        case .large: l10n.text(.interfaceTextSizeLarge)
        case .maximum: l10n.text(.interfaceTextSizeMaximum)
        }
    }

    /// The adjacent smaller level, if this is not already the compact level.
    public var smaller: ClaudioInterfaceTextSize? {
        switch self {
        case .compact: nil
        case .standard: .compact
        case .large: .standard
        case .maximum: .large
        }
    }

    /// The adjacent larger level, if this is not already the maximum level.
    public var larger: ClaudioInterfaceTextSize? {
        switch self {
        case .compact: .standard
        case .standard: .large
        case .large: .maximum
        case .maximum: nil
        }
    }

    public var levelNumber: Int {
        switch self {
        case .compact: 1
        case .standard: 2
        case .large: 3
        case .maximum: 4
        }
    }

    public var levelCount: Int { Self.allCases.count }

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
    case loading
    case pinned([PackCard])
    case noPinnedPacks(availablePackCount: Int)
    case noPacks
    case readFailed(reason: String)
}

/// Compact UI projection of ``SoundPackLibraryState``. The full snapshot stays in the model;
/// views only need to distinguish first load, background refresh, stale fallback, and hard failure.
public enum SoundPackLibraryPresentationState: Sendable, Equatable {
    case loading
    case ready
    case refreshing
    case refreshFailed(reason: String)
    case loadFailed(reason: String)

    /// Whether event mappings and pack counts come from a real snapshot.
    ///
    /// A refresh failure still owns a usable stale snapshot; a first-load failure does not.
    public var hasUsableSnapshot: Bool {
        switch self {
        case .ready, .refreshing, .refreshFailed:
            return true
        case .loading, .loadFailed:
            return false
        }
    }

    public var canRetry: Bool {
        switch self {
        case .refreshFailed, .loadFailed:
            return true
        case .loading, .ready, .refreshing:
            return false
        }
    }
}

/// Selected-pack inventory has its own asynchronous lifecycle. Library metadata can already be
/// ready while this one-pack directory read is still in flight, so an empty array alone is not a
/// truthful presentation state.
public enum SoundPackAudioInventoryPresentationState: Sendable, Equatable {
    case idle
    case loading(previous: [PackAudioFile]?)
    case ready([PackAudioFile])
    case failed(previous: [PackAudioFile]?, error: PackAudioInventoryError)

    public var files: [PackAudioFile] {
        switch self {
        case .idle:
            return []
        case .loading(let previous), .failed(let previous, _):
            return previous ?? []
        case .ready(let files):
            return files
        }
    }

    public var error: PackAudioInventoryError? {
        guard case .failed(_, let error) = self else { return nil }
        return error
    }

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// Honest panel summary for facts that do not exist until the library has produced a snapshot.
public func panelAudibleEventSummary(
    audibleEventCount: Int,
    libraryState: SoundPackLibraryPresentationState
) -> String {
    switch libraryState {
    case .loading:
        return "正在读取声音包状态"
    case .loadFailed:
        return "声音包状态不可用"
    case .ready, .refreshing, .refreshFailed:
        return "\(audibleEventCount) 个可听事件"
    }
}

public func localizedPanelAudibleEventSummary(
    audibleEventCount: Int,
    libraryState: SoundPackLibraryPresentationState,
    language: ClaudioAppLanguage
) -> String {
    let l10n = ClaudioL10n(language: language)
    switch libraryState {
    case .loading:
        return l10n.text(.panelAudibleEventsLoading)
    case .loadFailed:
        return l10n.text(.panelAudibleEventsUnavailable)
    case .ready, .refreshing, .refreshFailed:
        return l10n.plural(.panelAudibleEventsCount, count: audibleEventCount)
    }
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

public func localizedEventPreviewHint(
    _ availability: EventPreviewAvailability,
    language: ClaudioAppLanguage
) -> String {
    let l10n = ClaudioL10n(language: language)
    switch availability {
    case .available:
        return l10n.text(.eventPreviewHint)
    case .masterVolumeZero:
        return l10n.text(.eventPreviewMasterVolumeZero)
    case .unmapped:
        return l10n.text(.eventPreviewUnmapped)
    case .missingOrDamaged:
        return l10n.text(.eventPreviewMissing)
    case .unsafeOrUnreadable(let reason):
        return ClaudioL10n(language: language).format(.eventPreviewUnsafe, reason as NSString)
    }
}

/// 保留的声音包窗口只接受显式路由。每条路由都携带声音作用域；`nil` 明确表示 Global，
/// 不是“缺少 scope”。窗口必须先验证非 nil Surface 属于产品 registry，才允许任何配置写入。
public struct SoundPacksWindowRoute: Sendable, Equatable, Hashable {
    public enum Destination: Sendable, Equatable, Hashable {
        case overview
        case editEvent(packID: String, event: Event)
    }

    public let surface: HostSurfaceID?
    public let destination: Destination

    public init(surface: HostSurfaceID?, destination: Destination) {
        self.surface = surface
        self.destination = destination
    }

    /// 兼容现有 Global 调用点的显式值；它仍真实携带 `surface == nil`。
    public static let overview = SoundPacksWindowRoute(surface: nil, destination: .overview)

    public static func overview(surface: HostSurfaceID?) -> SoundPacksWindowRoute {
        SoundPacksWindowRoute(surface: surface, destination: .overview)
    }

    public static func editEvent(packID: String, event: Event) -> SoundPacksWindowRoute {
        editEvent(surface: nil, packID: packID, event: event)
    }

    public static func editEvent(
        surface: HostSurfaceID?,
        packID: String,
        event: Event
    ) -> SoundPacksWindowRoute {
        SoundPacksWindowRoute(
            surface: surface,
            destination: .editEvent(packID: packID, event: event))
    }

    public var editTarget: (packID: String, event: Event)? {
        guard case .editEvent(let packID, let event) = destination else { return nil }
        return (packID, event)
    }

    public var isOverview: Bool { destination == .overview }
}

public enum SoundPacksWindowRouteResolution: Sendable, Equatable {
    case resolved(SoundPacksWindowRoute)
    case pending(SoundPacksWindowRoute)
}

/// A first-open model starts with no cards even when the app-lifetime library already has a replay
/// ready to deliver. Only a completed `ready` snapshot can prove that an edit target is absent;
/// loading and failed refreshes must retain the route for a later retry.
public func resolveSoundPacksWindowRoute(
    _ route: SoundPacksWindowRoute,
    availablePackIDs: Set<String>,
    libraryState: SoundPackLibraryPresentationState
) -> SoundPacksWindowRouteResolution {
    guard let packID = route.editTarget?.packID else { return .resolved(route) }
    if availablePackIDs.contains(packID) { return .resolved(route) }
    if libraryState == .ready { return .resolved(.overview(surface: route.surface)) }
    return .pending(route)
}

/// SoundPacksWindow 可管理的 Surface 白名单。诊断专用 AX identity 即使能被解码，也不能
/// 借一个错误路由获得 config 写权限。
public func isValidSoundPacksWindowSurface(_ surface: HostSurfaceID?) -> Bool {
    guard let surface else { return true }
    return HostID.productVisibleCases.contains { $0.surfaceID == surface }
}

/// 能力矩阵当前格子的首要恢复意图。它只描述产品动作，不执行 host/config I/O。
public enum IntegrationsRecoveryAction: Sendable, Equatable, Hashable {
    case unmute(host: HostID, event: Event)
    case explainMasterVolumeZero(host: HostID, event: Event)
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
        case .explainMasterVolumeZero, .explainUnsupported, .none: nil
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
        return cell.muteReason == .masterVolumeZero
            ? .explainMasterVolumeZero(host: cell.host, event: cell.event)
            : .unmute(host: cell.host, event: cell.event)
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
