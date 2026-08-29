import ClaudioCore
import Combine
import Foundation

/// 一次声音包管理面与面板之间的可观察刷新效果。
///
/// UI 面不互持彼此的 view-model：窗口写成功只发布 ``panelReloadRevision``；面板切包
/// 成功发布 ``windowReloadRevision``（窗口跟随 active pack）；面板音频/import/manifest 或
/// `master_volume` 等非切包 config 真变化发布 ``windowContentReloadRevision``（只重读窗口当前检查项）。
/// 多个 `PanelConfigController` projection 通过 ``configFactRevision`` 共享 config 落盘事实，
/// source token 只跳过已完成本地重读的写者，不合并各自的 Surface selection。
/// 两侧在自己的 `@MainActor` 上重读 config 并投影同一个不可变 library snapshot；真正的包读取由
/// app-lifetime ``SoundPackLibrary`` 在后台完成。写入仍同步留在 MainActor，没有后台写或第二份缓存。
public enum SoundPacksRefreshEffect: Equatable, Sendable {
    case none
    case panelFullReload
    case windowReload
}

/// 管理窗口里一次同步写操作的落盘结局。
public enum SoundPacksWindowWriteOutcome: Equatable, Sendable {
    case succeeded
    /// The requested operation failed, but an earlier safety step already changed the visible
    /// pack tree (for example, factory restore moved the old tree to salvage before publish
    /// failed). Both UIs must reload the disk truth while continuing to render the failure.
    case changedDespiteFailure
    case failed
}

/// 面板切包的真实结局。失败携带原始 ``UseError``，让调用方不能把「方法返回了」误当成功。
public enum PanelPackSwitchOutcome: Equatable, Sendable {
    case succeeded
    case failed(UseError)
}

/// 面板内一次音频目录或 manifest 变更的真实结局。
///
/// 与切包不同，这类变化只要求管理窗口重读它正在检查的包，绝不能把侧栏选择拉回 active pack。
public enum PanelPackAudioChangeOutcome: Equatable, Sendable {
    case changed
    case unchanged
}

/// 面板内一次不改变 active pack 的 config 写入结局。
public enum PanelConfigChangeOutcome: Equatable, Sendable {
    case changed
    case unchanged
}

/// Identity for one config projection subscribed to the app-lifetime refresh coordinator. The
/// source skips its own revision while every peer reprojects the same config fact.
public struct PanelConfigProjectionToken: Hashable, Sendable {
    fileprivate let rawValue: UUID

    public init() {
        rawValue = UUID()
    }
}

/// `SoundPacksWindow` 与 popover 的双向刷新路由。
///
/// 这是 app 生命周期内的单实例，由 ``MenuBarController`` 创建并同时注入两个 UI 面：
///
/// - 窗口写成功 → `panelReloadRevision` 前进；`PanelView` **必须**调用
///   `PanelConfigController.reload()`，不能走不会重算 `packCards` 的 `reloadConfigOnly()`。
/// - shared bootstrap 完成 → `panelReloadRevision` 前进；即使启动时的宿主 presentation task
///   已因用户打开面板而取消，面板仍须重读 bootstrap 刚创建或修复的 config / packs。
/// - 面板切包成功 → `windowReloadRevision` 前进；窗口重读 config 与包状态。
/// - 面板包音频、manifest 或非切包 config 真变化 → `windowContentReloadRevision` 前进；窗口保持侧栏选择重读。
/// - 任一 config projection 写成功 → `configFactRevision` 前进；source 跳过，所有 peer 重投影。
/// - 没有落盘变化的失败 → revision 不动；失败前磁盘已经变化 → 两侧如实重读，但错误仍由调用面显示。
///
/// `@MainActor` 不只是发布 UI 状态的要求，也是 manifest/config 写者的时序边界：调用方必须在
/// 同一 actor 上先完成同步落盘，再调用这里的 completion；禁止把写操作丢进 `Task`、
/// `DispatchQueue` 或 `async` 后提前发 revision。
@MainActor
public final class SoundPacksRefreshCoordinator: ObservableObject {
    @Published public private(set) var panelReloadRevision = 0
    /// Read synchronously by the panel subscriber for the revision currently being published.
    /// The window that completed a pack mutation owns the one shared-library refresh; the panel
    /// always reprojects that shared stream instead of issuing a duplicate presentation request.
    public private(set) var panelReloadRequiresLibraryRefresh = false
    @Published public private(set) var windowReloadRevision = 0
    /// Pack selection is config-only, so the active-pack follower normally reprojects the current
    /// snapshot. Kept explicit to make the revision's I/O semantics impossible to guess at use.
    public private(set) var windowReloadRequiresLibraryRefresh = false
    @Published public private(set) var windowContentReloadRevision = 0
    /// Read synchronously by the retained-window subscriber for the content revision being sent.
    public private(set) var windowContentReloadRequiresLibraryRefresh = false
    @Published public private(set) var configFactRevision = 0
    /// Read synchronously by config-projection subscribers for the revision being published.
    public private(set) var configFactSource: PanelConfigProjectionToken?

    public init() {}

    @discardableResult
    public func completeWindowWrite(
        _ outcome: SoundPacksWindowWriteOutcome
    ) -> SoundPacksRefreshEffect {
        guard outcome != .failed else { return .none }
        // `SoundPacksWindowModel.completeSynchronousWrite` owns any required invalidation and
        // refresh before publishing this revision. Asking the panel to request it again can overlap
        // the first scan and is indistinguishable from a genuinely later external observation,
        // which correctly schedules a follow-up. Keep one scan owner and let both consumers observe
        // it. Config-only writes use the same projection-only recipient path.
        panelReloadRequiresLibraryRefresh = false
        panelReloadRevision += 1
        return .panelFullReload
    }

    /// Shared runtime bootstrap may create the default config, copy packs, or salvage a damaged
    /// pack tree after `PanelConfigController` has already hydrated its initial read model. Its
    /// completion is therefore an unconditional full-reload boundary, including partial/failure
    /// outcomes: the bootstrap manager reports those through host state, while the panel must still
    /// render whatever disk truth the attempt left behind.
    @discardableResult
    public func completeSharedRuntimeBootstrap() -> SoundPacksRefreshEffect {
        panelReloadRequiresLibraryRefresh = true
        panelReloadRevision += 1
        windowContentReloadRequiresLibraryRefresh = false
        windowContentReloadRevision += 1
        return .panelFullReload
    }

    /// External config writers are not required to publish our in-process revision. App activation
    /// is therefore an explicit config projection boundary for a retained management window.
    @discardableResult
    public func refreshWindowConfigProjection() -> SoundPacksRefreshEffect {
        windowContentReloadRequiresLibraryRefresh = false
        windowContentReloadRevision += 1
        return .windowReload
    }

    @discardableResult
    public func completePanelPackSwitch(
        _ outcome: PanelPackSwitchOutcome
    ) -> SoundPacksRefreshEffect {
        guard outcome == .succeeded else { return .none }
        windowReloadRequiresLibraryRefresh = false
        windowReloadRevision += 1
        return .windowReload
    }

    /// Publishes a config fact to sibling `PanelConfigController` projections. A pack switch uses
    /// this directly because its management-window route is the separate active-pack revision;
    /// ordinary Event/volume writes publish through ``completePanelConfigChange(_:source:)``.
    @discardableResult
    public func completeConfigFactChange(
        _ outcome: PanelConfigChangeOutcome,
        source: PanelConfigProjectionToken? = nil
    ) -> Bool {
        guard outcome == .changed else { return false }
        configFactSource = source
        configFactRevision += 1
        return true
    }

    /// Publishes a selected-pack content reload without changing which sidebar item the retained
    /// management window is inspecting.
    @discardableResult
    public func completePanelPackAudioChange(
        _ outcome: PanelPackAudioChangeOutcome
    ) -> SoundPacksRefreshEffect {
        guard outcome == .changed else { return .none }
        windowContentReloadRequiresLibraryRefresh = true
        windowContentReloadRevision += 1
        return .windowReload
    }

    /// Publishes a config-only refresh without changing which sidebar item the retained
    /// management window is inspecting. The panel already reloaded its own read model, so this
    /// deliberately never advances `panelReloadRevision`.
    @discardableResult
    public func completePanelConfigChange(
        _ outcome: PanelConfigChangeOutcome,
        source: PanelConfigProjectionToken? = nil
    ) -> SoundPacksRefreshEffect {
        guard outcome == .changed else { return .none }
        completeConfigFactChange(outcome, source: source)
        windowContentReloadRequiresLibraryRefresh = false
        windowContentReloadRevision += 1
        return .windowReload
    }
}
