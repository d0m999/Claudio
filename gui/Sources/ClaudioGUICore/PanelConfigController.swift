import ClaudioCore
import Combine
import Foundation

/// 运行态面板的 **config 读模型 + 流经它的写操作** —— 从 `PanelView` 里抽出来的那一半
/// （ENGINEERING.md「视图拆进可 import 的 library target」，红队 9cccc9c 兑现）。
///
/// ## 它为什么必须住在这里，而不是 `PanelView` 里（红队 9cccc9c，worktree 实测 3 条存活变异）
///
/// `configState` / `config` / `eventRows` / `packCards` 曾是 `PanelView` 的 `@State`，操作它们的
/// `toggleMute` / `refresh` / `refreshEnabledFlags` 曾是 `PanelView` 的私有方法。而 `PanelView` 住在
/// `@main` executableTarget，**测试 import 不进来** —— 于是这几段逻辑唯一的守卫是 `ViewWiringSuite` 的
/// 文本绊线。红队对它们发动六视角攻击，实测三条**改坏真实行为、两套测试全绿**的变异，全落在文本绊线
/// 的强度天花板上：
///
///   - **执行**：`refresh()` 正确被调，但函数体里删掉 `configState` 重载 → 面板对磁盘上的删除永久失明。
///   - **可达性**：在路由 switch 前插一句早退，让某条 case 成死代码 → 绊线要的字符串一个不少（存在≠可达）。
///   - **翻转**：`setEnabled(enabled: !currentlyEnabled)` 去掉那个 `!` → toggle 变死键，翻转逻辑裸奔。
///
/// 三条同一个根因：**状态和操作它的方法住在测不到的 View 里，文本绊线只能守「代码在不在」，守不住
/// 「代码做什么 / 可不可达 / 翻转对不对」。** 搬进这个可实例化的 `@MainActor` 类之后，`PanelConfigControllerSuite`
/// 能真的 `new` 它、喂**真磁盘** config、调 `toggleMute`、断言 `configState` 真从 `.operational` 翻到
/// `.needsPack`、`eventRows` 的 enabled 位真的翻转 —— 三条变异各自当场变红。
///
/// 唯一仍关不掉的是 `PanelView.body` 把按钮绑到 `toggleMute` 那**最外层一根接线**（SwiftUI body 接线，
/// 纯逻辑测试到不了，本机 CommandLineTools 无 XCTest）—— 那一根由 `ViewWiringSuite` 的存在性检查兜底。
///
/// ## 跨-view-model 协调用注入闭包，不在这里持有别的 view-model
///
/// 全量 `reload()`（= 旧 `PanelView.refresh()`）除了重载自己这份读模型，还要 `onboardingViewModel.refresh()`
/// 和把 `dropZone` / 每行 import 两组 view-model `retarget` 到新包。那些不是 config 读模型的事，所以它们
/// 走 ``afterFullReload`` 闭包 —— 生产端 `PanelView` 在 `init` 里构造好那几个 view-model 的**纯 local
/// 实例**后捕获它们（避开「读 `@StateObject.wrappedValue` 造幽灵实例」那个陷阱），测试端传一个 no-op 或
/// spy。这样 `toggleMute` 的**完整行为**（翻转 + 路由 + 重载）都在这个类里，一次测得到，不再跨 View 边界
/// 裂成两半。
@MainActor
public final class PanelConfigController: ObservableObject {
    /// D23 定稿：面板对 `config.json` 的完整判定，驱动 `operationalPanel` 顶部路由（事件行 / 「先选包」
    /// 空态 / 诚实失败态）与 `applyFirstFocus()` 的行可见性。`config` 始终与它同步（`resolvedConfig`）。
    @Published public private(set) var configState: PanelConfigState
    /// 读模型（`packCoverage` / `availablePacks`）算什么用的那份 config —— 不是决定哪个顶层视图渲染的。
    @Published public private(set) var config: ClaudioConfig
    @Published public private(set) var eventRows: [EventRow]
    @Published public private(set) var packCards: [PackCard]
    /// Existing audio for the active pack, computed once per full reload and shared by all four
    /// event-row menus. This avoids four synchronous `readdir` calls during one SwiftUI body pass.
    /// An unreadable manifest yields an empty, fail-closed menu rather than invented orphan facts.
    @Published public private(set) var selectedPackAudioFiles: [PackAudioFile]
    @Published public private(set) var selectedPackIsBuiltinReadOnly: Bool
    /// The current pack's title/header metadata, loaded from that pack itself — never inferred
    /// from ``packCards``. The display set may legally omit the selected pack once starred-only
    /// filtering is active, while the event-section title remains its only guaranteed visible name.
    @Published public private(set) var selectedPackMetadata: SelectedPackMetadata
    /// 上一次**失败**的切包（`nil` 表示还没失败过 / 上一次成功已清）——镜像 ``EventMuteController/lastError``
    /// 的形状（静音那一半的失败就住在那里）。绝不静默吞错：切包失败必须如实上报，不能像旧代码那样
    /// `if case .success = result { … }` 把 error 整个丢掉。
    @Published public private(set) var packSwitchError: UseError?
    /// 上一次静音写盘的失败（`nil` 表示成功 / 还没点过）——面板据此渲染红色 errorNotice。
    ///
    /// ## 为什么这条 error 住在这里，而不是让面板直接读 `EventMuteController.lastError`（红队 b86ec0a）
    ///
    /// 上一版 `muteController` 是**注入**的：`PanelView` 持一个 `@StateObject muteController`（面板渲染
    /// errorNotice 读它的 `lastError`），又把**同一个实例**传进这个 controller（`toggleMute` 调它写盘）。
    /// 红队实测：把注入实参换成一个**新**实例（`muteController: EventMuteController(...)` 而不是共享的那个）——
    /// 面板读实例 A、controller 写实例 B，一次静音**失败**（`.lockBusy`）的错误记进 B，面板读 A 恒 nil →
    /// errorNotice **永不渲染** = 静默吞错，两套测试全绿。init 注释亲口警告了「幽灵实例」，却只用注释挡，
    /// 没用**结构**挡。
    ///
    /// 现在结构上挡死：`muteController` 由这个 controller **自己构造、自己独占**（下面 init 里），外部
    /// **递不进来第二个实例**。静音失败经这里的 `muteError`（`@Published`）republish，面板读的是
    /// `panelModel.muteError`（经 `panelModel` 这个 `@StateObject` 观测）—— 面板与写盘看的是同一个 error
    /// 源，分叉在类型层面不可能。
    @Published public private(set) var muteError: SetEventEnabledError?
    /// 上一次主音量写盘的失败（`nil` 表示成功 / 还没拖过）——面板据此渲染红色 errorNotice。生命周期
    /// 逐字镜像 ``muteError``：同样的「独占构造，不注入」理由（避免面板读一个实例、controller 写另一个
    /// 的幽灵分叉），同样经 ``setMasterVolume(_:)`` republish（PLAN-MASTER-VOLUME.md 阶段 D，D39）。
    @Published public private(set) var masterVolumeError: SetMasterVolumeError?

    private let configFile: URL
    private let lockFile: URL
    private let environment: AudioImportEnvironment
    private let builtinPackIDs: Set<String>
    /// 这个 controller **独占**它 —— 不注入（见 ``muteError`` 的文档：注入会开「幽灵实例」的口）。
    /// 拿 `lockFile`（= `config.lock`）构造，与切包写路径守同一把锁（锁分离 D9）。
    private let muteController: EventMuteController
    /// 同上，主音量的写者（D27/D39）——独占构造，与 ``muteController`` 同一个理由。
    private let masterVolumeController: MasterVolumeController
    /// 一次**全量** reload 之后，config 读模型之外还要做的跨-view-model 协调（onboarding 重探 + 两组
    /// import view-model `retarget` 到新包）。参数是刚重载出来的 config —— retarget 要用它的 `selectedPack`。
    private let afterFullReload: @MainActor (ClaudioConfig) -> Void
    /// 管理窗口成功写发布的 revision。订阅只做 ``reload()``，绝不降级到
    /// ``reloadConfigOnly()``，因为 manifest 与未来的星标写都可能改变 `packCards`。
    private var soundPacksRefreshCancellable: AnyCancellable?

    public init(
        configFile: URL,
        lockFile: URL,
        environment: AudioImportEnvironment,
        afterFullReload: @escaping @MainActor (ClaudioConfig) -> Void = { _ in },
        soundPacksRefreshCoordinator: SoundPacksRefreshCoordinator? = nil
    ) {
        self.configFile = configFile
        self.lockFile = lockFile
        self.environment = environment
        self.builtinPackIDs = environment.builtinPackIDs
        // 独占构造，不注入 —— 结构性堵死「面板读一个实例、controller 写另一个」的幽灵分叉（见 muteError 文档）。
        self.muteController = EventMuteController(configFile: configFile, lockFile: lockFile)
        self.masterVolumeController = MasterVolumeController(configFile: configFile, lockFile: lockFile)
        self.afterFullReload = afterFullReload

        let loadedState = loadPanelConfig(from: configFile)
        let loadedConfig = loadedState.resolvedConfig
        self.configState = loadedState
        self.config = loadedConfig
        self.eventRows = packCoverage(
            packID: loadedConfig.selectedPack, config: loadedConfig, environment: environment)
        self.packCards = availablePacks(
            config: loadedConfig,
            environment: environment,
            scope: .panelStarredDisplay)
        self.selectedPackAudioFiles = Self.loadSelectedPackAudioFiles(
            packID: loadedConfig.selectedPack, environment: environment)
        self.selectedPackIsBuiltinReadOnly = builtinPackIDs.contains(loadedConfig.selectedPack)
        self.selectedPackMetadata = ClaudioGUICore.selectedPackMetadata(
            packID: loadedConfig.selectedPack, environment: environment)
        self.packSwitchError = nil
        self.muteError = nil
        self.masterVolumeError = nil

        soundPacksRefreshCancellable = soundPacksRefreshCoordinator?.$panelReloadRevision
            .dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reload()
                }
            }
    }

    /// 把 `event` 的静音位翻到当前值的**反面**，经 ``EventMuteController`` 写盘，再按结果路由刷新。
    ///
    /// **整条逻辑都在这里**（翻转 `!currentlyEnabled` + `panelRefreshRoute` 路由 + 三条刷新分支），
    /// 这正是它从 `PanelView` 搬过来的全部理由：红队实测「去掉 `!`」「某条 case 早退成死代码」在旧
    /// 位置上两套测试全绿。搬过来后，`PanelConfigControllerSuite` 对这三样各有一条行为断言。
    public func toggleMute(_ event: Event) {
        let currentlyEnabled = eventRows.first(where: { $0.event == event })?.enabled ?? true
        let succeeded = muteController.setEnabled(event, enabled: !currentlyEnabled)
        // republish：面板读 `panelModel.muteError`，不直接读 muteController（那会开幽灵实例的口，见 muteError 文档）。
        // setEnabled 成功把 lastError 清 nil、失败记下错误，所以此刻读它就是这次写盘的结果。
        muteError = muteController.lastError
        switch panelRefreshRoute(muteSucceeded: succeeded, error: muteController.lastError) {
        case .configOnly: reloadConfigOnly()
        case .full: reload()
        case .noRefresh: break
        }
    }

    /// 写 `master_volume`（PLAN-MASTER-VOLUME.md 阶段 D，D27/D39/D43），经 ``MasterVolumeController``。
    /// **整条逻辑都在这里**，与 ``toggleMute(_:)`` 同一个理由：写、republish 错误、按结果路由刷新
    /// 三件事绑在一起，才不会在测不到的 View 里再裂出第二份「翻转 + 路由」的手抄副本。
    ///
    /// - Returns: 落地（已钳制）的值，success 时；`nil` 表示失败（``masterVolumeError`` 已记下原因）——
    ///   调用方（``MasterVolumeRow``）据此让 `VolumeDragSession` 提交成功或回滚，从不自己猜。
    /// - 成功 → `.configOnly`（D27，``reloadConfigOnly()``）：一次成功的写盘只翻了一个 `Double`，
    ///   不可能牵动任何包的 manifest / 磁盘上有哪些包，全量刷新在这条路上纯属白扫。
    /// - `.configMissing`（D43）→ `.full`（``reload()``）：`config.json` 被外部删掉，`configState` 必须
    ///   重路由到 `.needsPack`，而那张「先选包」空态卡的自救入口是画廊，画廊必须新鲜。
    /// - 其余「什么也证明不了」的失败（`.lockBusy` 除外）→ 仍走 `.configOnly`：理由与静音那一半
    ///   ``panelRefreshRoute(muteSucceeded:error:)`` 完全相同，见那里的文档。
    @discardableResult
    public func setMasterVolume(_ volume: Double) -> Double? {
        let landed = masterVolumeController.setVolume(volume)
        // republish：面板读 `panelModel.masterVolumeError`，不直接读 masterVolumeController（那会开
        // 幽灵实例的口，见 masterVolumeError 文档）。
        masterVolumeError = masterVolumeController.lastError
        switch masterVolumeRefreshRoute(succeeded: landed != nil, error: masterVolumeController.lastError) {
        case .configOnly: reloadConfigOnly()
        case .full: reload()
        case .noRefresh: break
        }
        return landed
    }

    /// 切包，经 ``selectPack`` —— `claudio use` / `performFirstRunSetup` 用的**同一条**写路径。成功清
    /// `packSwitchError` 并全量 `reload()`；失败把 error 记进 `packSwitchError`（由面板渲染），绝不丢弃。
    ///
    /// **失败也可能要刷新**（`/codex review` 第二条 [P1]）：上一版的失败分支只记 error 就完事，于是
    /// 「打开有效面板 → 外部把 `master_volume` 改成字符串 → 点一张包卡」会让 `selectPack` 如实返回
    /// `.configReadFailure`，而 `configState` 纹丝不动地停在 `.operational` —— 面板一边红字说 config 读不动，
    /// 一边继续渲染四行活控件。刷哪一种交给 ``packSwitchRefreshRoute(after:)``（纯函数、穷尽 switch、由
    /// `PanelRefreshRouteSuite` 逐 case 钉死），与静音那一半 ``panelRefreshRoute(muteSucceeded:error:)``
    /// 是同一种极性：只有**可证明什么也没揭示**的失败（`.lockBusy` / `.invalidPackID`）才完全跳过。
    ///
    /// 顺序：先记 error 再刷新 —— 两条刷新路径都不碰 `packSwitchError`（只有一次**成功**的切包清它），
    /// 所以红字不会被它自己触发的这次重读抹掉。
    /// - Returns: 切包的真实落盘结局。窗口同步只消费这个 outcome；调用返回本身绝不等于成功。
    @discardableResult
    public func switchPack(to packID: String) -> PanelPackSwitchOutcome {
        switch selectPack(
            packID, configFile: configFile, userPacksDirectory: environment.userPacksDirectory,
            bundledPacksDirectory: environment.bundledPacksDirectory, lockFile: lockFile)
        {
        case .success:
            packSwitchError = nil
            reload()
            return .succeeded
        case .failure(let error):
            packSwitchError = error
            switch packSwitchRefreshRoute(after: error) {
            case .configOnly: reloadConfigOnly()
            case .full: reload()
            case .noRefresh: break
            }
            return .failed(error)
        }
    }

    /// **全量** reload（= 旧 `PanelView.refresh()`）：重读 `config.json` + 重算每一个派生读模型，再做
    /// 跨-view-model 协调。面板「磁盘上可能有东西变了」那条规则用它 —— popover 重开、切包之后、一次
    /// 行内 import/bind 之后。其余情况走下面那条轻量 `reloadConfigOnly()`。
    ///
    /// 顺序：先重载自己的读模型，再 `afterFullReload(config)`。旧 `refresh()` 里 `onboardingViewModel.refresh()`
    /// 排在最前，但它探的是 helper 二进制 / settings.json，与 config 读模型**互不依赖**，挪到后面结果一字
    /// 不差；而 `retarget` 必须排在 config 重载**之后**（它要用新的 `selectedPack`），闭包收到的正是新 config。
    public func reload() {
        reload(using: loadPanelConfig(from: configFile))
    }

    /// 使用一份已经读到的 config state 执行与 ``reload()`` 完全相同的全量重载。轻量刷新若发现
    /// `selected_pack` 被外部写者换过，会从这里升级，既避免把同一份 config 再读一次，也保证
    /// `eventRows` / `packCards` / `selectedPackMetadata` 与 import view-model retarget 在同一次刷新中
    /// 对齐到同一包。
    private func reload(using loadedState: PanelConfigState) {
        reloadConfigReadModel(using: loadedState)
        afterFullReload(config)
    }

    /// **只重读 config 读模型**（``PanelRefreshRoute/configOnly``）：重读 `config.json` → 重算 `configState`
    /// / `config` → 按新 config 重算每行的 `enabled` 位。**不**重扫包根、正常写（selected_pack
    /// 未变）**不**读 manifest、**不**调 `afterFullReload`。若外部写者同时换了 selected_pack，则升级为
    /// 与 ``reload()`` 相同的全量重载：标题、事件覆盖、画廊高亮和 import view-model 的写入目标必须一起
    /// 切到新包，不能只换标题。正常路径代价 = 一次文件读 + 一次目录 stat。
    ///
    /// 两条路共用它，因为要做的事一模一样：
    ///
    ///   - **静音成功**（`/ship` 性能评审）：只翻了 `config.json` 里的一个 bool，**不可能**改变任何包的
    ///     manifest / 声音文件存在性 / 磁盘上有哪些包 —— 全量 `reload()` 在这条路上是纯浪费：点一次静音钮
    ///     就在主线程上扫一遍整个包库。`coverage` 按定义不变，从已有行原样带过来。
    ///   - **「什么也证明不了」的失败**（`.lockFailed` / `.configReadFailure` / `.configWriteFailure`）：
    ///     必须重读才知道 `config.json` 和它的目录还在不在原来的样子 —— `configState` 据此落到 `.malformed`
    ///     / `.unwritable`，诚实失败卡才出得来。但**包库**没理由变，不扫；也不该拿一份 `selectedPack` 为空的
    ///     config 去 `afterFullReload` retarget（那会污染 drop zone、让画廊丢掉选中卡高亮）。
    ///
    /// ⚠️ 改名自 `reloadEnabledFlags()`：那个名字在**低报**它做的事 —— 它从第一天起就在重算 `configState`
    /// （下面第一行），只是没人注意到，于是没人想到「失败路径也可以用它」。
    public func reloadConfigOnly() {
        let previousSelectedPack = config.selectedPack
        let reloaded = loadPanelConfig(from: configFile)
        let selectedPackChanged: Bool
        switch reloaded {
        case .operational(let reloadedConfig):
            selectedPackChanged = reloadedConfig.selectedPack != previousSelectedPack
        case .needsPack:
            selectedPackChanged = !previousSelectedPack.isEmpty
        case .malformed, .unwritable:
            // These states expose an empty `resolvedConfig` only as a safe read-model fallback.
            // It is not evidence that an external writer actually selected the empty pack.
            selectedPackChanged = false
        }

        if selectedPackChanged {
            reload(using: reloaded)
            return
        }

        configState = reloaded
        config = reloaded.resolvedConfig
        eventRows = eventRows.map { row in
            EventRow(event: row.event, coverage: row.coverage, enabled: config.isEnabled(row.event))
        }
    }

    /// 重读 `config.json` + 重算 config 派生的每一个读模型 —— `reload()` 里“属于这个类自己”的那一半，
    /// 不含跨-view-model 协调（那是 `afterFullReload` 的事）。
    private func reloadConfigReadModel(using loadedState: PanelConfigState) {
        configState = loadedState
        config = configState.resolvedConfig
        eventRows = packCoverage(
            packID: config.selectedPack, config: config, environment: environment)
        packCards = availablePacks(
            config: config,
            environment: environment,
            scope: .panelStarredDisplay)
        selectedPackAudioFiles = Self.loadSelectedPackAudioFiles(
            packID: config.selectedPack, environment: environment)
        selectedPackIsBuiltinReadOnly = builtinPackIDs.contains(config.selectedPack)
        selectedPackMetadata = ClaudioGUICore.selectedPackMetadata(
            packID: config.selectedPack, environment: environment)
    }

    private static func loadSelectedPackAudioFiles(
        packID: String,
        environment: AudioImportEnvironment
    ) -> [PackAudioFile] {
        guard case .success(let files) = packAudioFiles(
            packID: packID, environment: environment)
        else {
            return []
        }
        return files
    }
}
