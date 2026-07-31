import ClaudioCore
import Combine

/// 一次声音包管理面与面板之间的可观察刷新效果。
///
/// 两个 UI 面不互持彼此的 view-model：窗口写成功只发布 ``panelReloadRevision``；面板切包
/// 成功发布 ``windowReloadRevision``（窗口跟随 active pack）；面板音频/import/manifest 真变化
/// 发布 ``windowContentReloadRevision``（只重读窗口当前检查项）。各自仍在自己的 `@MainActor`
/// 上重读磁盘，因而没有后台写、跨 actor 可变状态或第二份缓存。
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

/// `SoundPacksWindow` 与 popover 的双向刷新路由。
///
/// 这是 app 生命周期内的单实例，由 ``MenuBarController`` 创建并同时注入两个 UI 面：
///
/// - 窗口写成功 → `panelReloadRevision` 前进；`PanelView` **必须**调用
///   `PanelConfigController.reload()`，不能走不会重算 `packCards` 的 `reloadConfigOnly()`。
/// - 面板切包成功 → `windowReloadRevision` 前进；窗口重读 config 与包状态。
/// - 面板包音频或 manifest 真变化 → `windowContentReloadRevision` 前进；窗口保持侧栏选择重读。
/// - 没有落盘变化的失败 → revision 不动；失败前磁盘已经变化 → 两侧如实重读，但错误仍由调用面显示。
///
/// `@MainActor` 不只是发布 UI 状态的要求，也是 manifest/config 写者的时序边界：调用方必须在
/// 同一 actor 上先完成同步落盘，再调用这里的 completion；禁止把写操作丢进 `Task`、
/// `DispatchQueue` 或 `async` 后提前发 revision。
@MainActor
public final class SoundPacksRefreshCoordinator: ObservableObject {
    @Published public private(set) var panelReloadRevision = 0
    @Published public private(set) var windowReloadRevision = 0
    @Published public private(set) var windowContentReloadRevision = 0

    public init() {}

    @discardableResult
    public func completeWindowWrite(
        _ outcome: SoundPacksWindowWriteOutcome
    ) -> SoundPacksRefreshEffect {
        guard outcome != .failed else { return .none }
        panelReloadRevision += 1
        return .panelFullReload
    }

    @discardableResult
    public func completePanelPackSwitch(
        _ outcome: PanelPackSwitchOutcome
    ) -> SoundPacksRefreshEffect {
        guard outcome == .succeeded else { return .none }
        windowReloadRevision += 1
        return .windowReload
    }

    /// Publishes a selected-pack content reload without changing which sidebar item the retained
    /// management window is inspecting.
    @discardableResult
    public func completePanelPackAudioChange(
        _ outcome: PanelPackAudioChangeOutcome
    ) -> SoundPacksRefreshEffect {
        guard outcome == .changed else { return .none }
        windowContentReloadRevision += 1
        return .windowReload
    }
}
