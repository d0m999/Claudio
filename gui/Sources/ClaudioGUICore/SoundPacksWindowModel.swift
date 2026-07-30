import ClaudioCore
import Combine
import Foundation

/// 管理窗口的磁盘读模型。它列出完整包库，不应用面板的星标显示集，也不持有 `NSWindow`。
///
/// 所有 reload 与未来写 completion 都在 `@MainActor` 同步完成。窗口自己的 config/manifest 写者
/// 必须先完成落盘，再调用 ``completeSynchronousWrite(_:)``；这个 API 不接受 async closure，
/// 因而不会把「刷新已发布」与「字节尚未落盘」拆成两个时刻。
@MainActor
public final class SoundPacksWindowModel: ObservableObject {
    @Published public private(set) var configState: PanelConfigState
    @Published public private(set) var config: ClaudioConfig
    @Published public private(set) var packCards: [PackCard]
    @Published public private(set) var selectedPackID: String?
    @Published public private(set) var selectedEventRows: [EventRow]

    private let configFile: URL
    private let environment: AudioImportEnvironment
    private let refreshCoordinator: SoundPacksRefreshCoordinator
    private var windowRefreshCancellable: AnyCancellable?

    public init(
        configFile: URL,
        environment: AudioImportEnvironment,
        refreshCoordinator: SoundPacksRefreshCoordinator
    ) {
        self.configFile = configFile
        self.environment = environment
        self.refreshCoordinator = refreshCoordinator

        let loadedState = loadPanelConfig(from: configFile)
        let loadedConfig = loadedState.resolvedConfig
        let loadedCards = availablePacks(config: loadedConfig, environment: environment)
        let initialSelection =
            loadedCards.contains(where: { $0.id == loadedConfig.selectedPack })
            ? loadedConfig.selectedPack
            : loadedCards.first?.id

        configState = loadedState
        config = loadedConfig
        packCards = loadedCards
        selectedPackID = initialSelection
        selectedEventRows =
            initialSelection.map {
                packCoverage(packID: $0, config: loadedConfig, environment: environment)
            } ?? []

        windowRefreshCancellable = refreshCoordinator.$windowReloadRevision
            .dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reload(followActivePack: true)
                }
            }
    }

    /// 侧栏只改变窗口正在查看的包，不写 config，也不改变面板当前包。
    public func selectPackForInspection(_ packID: String) {
        guard packCards.contains(where: { $0.id == packID }) else { return }
        selectedPackID = packID
        selectedEventRows = packCoverage(
            packID: packID, config: config, environment: environment)
    }

    /// 窗口即将展示或已收到外部切包通知时重读磁盘。
    ///
    /// `followActivePack == true` 只用于「popover 刚成功切包」与首次展示；普通窗口内写保留用户
    /// 正在查看的侧栏项，不把一次 manifest 编辑误当成选包动作。
    public func reload(followActivePack: Bool) {
        let previousSelection = selectedPackID
        let loadedState = loadPanelConfig(from: configFile)
        let loadedConfig = loadedState.resolvedConfig
        let loadedCards = availablePacks(config: loadedConfig, environment: environment)

        let nextSelection: String?
        if followActivePack,
            loadedCards.contains(where: { $0.id == loadedConfig.selectedPack })
        {
            nextSelection = loadedConfig.selectedPack
        } else if let previousSelection,
            loadedCards.contains(where: { $0.id == previousSelection })
        {
            nextSelection = previousSelection
        } else if loadedCards.contains(where: { $0.id == loadedConfig.selectedPack }) {
            nextSelection = loadedConfig.selectedPack
        } else {
            nextSelection = loadedCards.first?.id
        }

        configState = loadedState
        config = loadedConfig
        packCards = loadedCards
        selectedPackID = nextSelection
        selectedEventRows =
            nextSelection.map {
                packCoverage(packID: $0, config: loadedConfig, environment: environment)
            } ?? []
    }

    /// 窗口内一个同步写者的统一 completion。
    ///
    /// 成功时先刷新窗口自己的读模型，再发布面板 full reload；失败时两边都不假刷新。未来 T11/T12/T17
    /// 的每个写者都应收口到这里，而不是各自选择 `reloadConfigOnly()`。
    @discardableResult
    public func completeSynchronousWrite(
        _ outcome: SoundPacksWindowWriteOutcome
    ) -> SoundPacksRefreshEffect {
        if outcome == .succeeded {
            reload(followActivePack: false)
        }
        return refreshCoordinator.completeWindowWrite(outcome)
    }
}
