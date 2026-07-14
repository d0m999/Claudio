import AppKit
import ClaudioCore
import ClaudioGUICore
import SwiftUI

/// The real menu-bar panel content (ENGINEERING.md T15 D1) — the composition root that
/// replaces the temporary `WindowGroup { OnboardingView(...) }` scaffolding T7 shipped.
/// Every state DECISION (onboarding vs operational, per-row coverage, pack completeness,
/// focus order, contrast, Dynamic Type tier) already happened in `ClaudioGUICore`/`ClaudioCore`
/// before this view renders — this file only lays pixels out, wires actions to the already-
/// tested write paths (``selectPack``, ``EventMuteController/setEnabled(_:enabled:)``), and
/// resolves real playback via ``NSSoundAudioPreviewPlayer``.
///
/// COMPILE-ONLY here (CommandLineTools, no Xcode/simulator/`#Preview`): rendering, the
/// operational-panel wiring end-to-end, and Dynamic Type behavior are manual-verify on a
/// real Mac. `ClaudioGUICore`'s pieces this view composes (``packCoverage``, ``availablePacks``,
/// ``loadPanelConfig``, ``panelLayoutAdaptation``, ``panelFocusOrder``) are each independently
/// unit-tested — this file's own job is ONLY correct composition, not re-deciding anything.
public struct PanelView: View {
    @StateObject private var onboardingViewModel: OnboardingViewModel
    @StateObject private var dropZoneViewModel: AudioImportViewModel
    /// 「这一句刚说过」的去重器（T17g）—— 让「一趟 update pass ≤ 一条播报」在结构上成立。
    /// 它必须活得比一次 `body` 求值长（跨 handler、跨帧），所以是 `@StateObject` 而不是局部变量。
    @StateObject private var announcer: PanelAnnouncer
    @State private var rowImportViewModels: [Event: EventRowImportViewModel]
    /// 运行态面板的 config 读模型 + 流经它的写操作（`configState` / `config` / `eventRows` /
    /// `packCards` / `packSwitchError`，以及 `toggleMute` / `switchPack` / `reload` /
    /// `reloadEnabledFlags`）—— **全部搬进了 `ClaudioGUICore.PanelConfigController`**（红队 9cccc9c
    /// 兑现台账那条 P2）。理由见那个类的文档：这几段逻辑曾是本视图的 `@State` + 私有方法，而本视图住在
    /// `@main` executableTarget、测试 import 不进来，于是红队实测三条「改坏行为、两套测试全绿」的变异
    /// （refresh 不重载 configState / 某条路由 case 成死代码 / 静音去掉取反）。搬进可实例化的类之后，
    /// `PanelConfigControllerSuite` 用真磁盘把这三条各钉一条行为断言。
    ///
    /// 本视图这一侧只剩两件文本绊线**够得着**的事：① `operationalPanel` 从 `panelModel` 读状态渲染；
    /// ② 按钮把 action 接到 `panelModel` 的方法（`ViewWiringSuite` 的存在性检查）。
    @StateObject private var panelModel: PanelConfigController

    /// The REAL `@FocusState` `panelFocusOrder(_:)`'s pure model drives (a11y-architect FIX
    /// 4, CRITICAL/HIGH — `panelFocusOrder` was computed but never consumed anywhere in
    /// production before this fix). Every focusable control (`EventRowView`'s action/mute
    /// buttons, `PackGalleryView`'s cards, `OnboardingView`'s CTAs) reports into THIS one
    /// binding, keyed by the SAME ``PanelFocusTarget`` identities the pure model returns —
    /// see ``applyFirstFocus()``.
    @FocusState private var focusedTarget: PanelFocusTarget?

    /// Signals "the popover just showed" from `MenuBarController` (a11y-architect FIX 4) —
    /// see ``PanelFocusCoordinator``'s doc comment for why `.onAppear` alone isn't reliable
    /// enough as that signal. `@ObservedObject`, not `@StateObject`: this instance is OWNED
    /// and shared by `MenuBarController` (constructed once for the app's lifetime, passed in
    /// here), never created fresh per `PanelView` value.
    @ObservedObject private var focusCoordinator: PanelFocusCoordinator

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Dynamic-Type scale factor for the header's fixed `.system(size:)` text (a11y fix) — see
    /// ``EventRowView``'s `typeScale`. `dynamicTypeSize` above still drives the LAYOUT tier
    /// (``typeSizeTier``); this makes the header TEXT actually scale alongside it.
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    // MARK: - Reduced motion / reduced transparency (ENGINEERING.md T15 D5)
    //
    // 这条绊线响了，而且是被 T17 自己踩响的（T17c 修复）。
    //
    // 它此前写的是：「this view tree applies NO `.animation()`/`withAnimation` anywhere … if a
    // future task adds any animation to this tree, it MUST gate it behind
    // `accessibilityReduceMotion` at that point — this comment is the tripwire.」而 T17 往这棵树里
    // 加了**两个** `ProgressView()`（`OnboardingView.ctaButton` 与本文件的 `disconnectRow`）——
    // 一个无限旋转动画 —— 既没有 gate，也没有回来改这段话。一条自己被跨过去还留在原地的绊线，
    // 比没有绊线更坏：它是一句已经不成立的断言，而下一个人会信它。
    //
    // 现在的状态：这棵树里**唯一**的动画是那两颗 in-flight spinner，两者都 gate 在下面这个
    // `reduceMotion` 后面。降级路径是 DESIGN.md 写的「静态字形与瞬时状态切换」—— 进行态本来就已经
    // 由文案（「正在接管…」/「正在断开…」）与禁用态承担了，那圈转动只是锦上添花。
    // **规矩不变**：再往这棵树里加任何动画，必须在那一点 gate 住 `reduceMotion`。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    //
    // Reduced transparency: already satisfied structurally, not just here — `.background(
    // ClaudioColor.panel(colorScheme))` below is a near-solid opaque color, never a
    // `.material`/`.ultraThinMaterial`/vibrancy effect (DESIGN.md「面板材质（关键决策）」:
    // "不用满毛玻璃 vibrancy"). No code path in this tree introduces one.

    private let audioEnvironment: AudioImportEnvironment
    private let configFile: URL
    private let lockFile: URL
    private let previewPlayer: AudioPreviewPlaying

    /// Reports this panel's CURRENT ``PanelLayoutAdaptation/panelWidth`` to whoever owns the
    /// AppKit container around it — in production, ``MenuBarController``, which resizes its
    /// `NSPopover.contentSize` to match (T15 D5's 「极大 → 加宽 popover」 degradation rule).
    ///
    /// This callback is the whole reason that rule actually WORKS: the SwiftUI side already sized
    /// itself via `.frame(width: layoutAdaptation.panelWidth)`, but `NSPopover` had a HARDCODED
    /// 312pt `contentSize`, so at the `.maximum` Dynamic Type tier the panel widened to 360pt
    /// INSIDE a popover that stayed 312pt wide (TODOS.md:257). Defaulted to a no-op so previews /
    /// the state gallery — which have no popover to resize — need not care.
    private let onPanelWidthChange: (Double) -> Void

    public init(
        audioEnvironment: AudioImportEnvironment,
        /// `Claudio.app/Contents/Resources/bin/claudio` — the helper the 接管 CTA copies into
        /// `~/.claudio/bin/claudio`. **No default on purpose**: a default would let a future call
        /// site silently ship a panel whose CTA can never install anything, which is precisely the
        /// bug T17 exists to close. `nil` is a legal, explicit answer ("this build has no bundle"),
        /// and it surfaces as a real error in the panel — never as a dead button.
        bundledHelperBinary: URL?,
        configFile: URL = ClaudioPaths.configFile,
        lockFile: URL = ClaudioPaths.configLockFile,
        onboardingEnvironment: OnboardingEnvironment = OnboardingEnvironment(),
        focusCoordinator: PanelFocusCoordinator = PanelFocusCoordinator(),
        onPanelWidthChange: @escaping (Double) -> Void = { _ in }
    ) {
        self.audioEnvironment = audioEnvironment
        self.configFile = configFile
        self.lockFile = lockFile
        self.focusCoordinator = focusCoordinator
        self.onPanelWidthChange = onPanelWidthChange
        // `NSSoundAudioPreviewPlayer` is internal (module-private, not exposed as a public
        // API surface) — mirrors `AudioDropZoneView`'s own init, which constructs it the
        // same way rather than taking it as a public, overridable parameter.
        self.previewPlayer = NSSoundAudioPreviewPlayer()

        // The runner is built INSIDE the `StateObject(wrappedValue:)` autoclosure, together with
        // the view-model it belongs to — never assigned afterwards.
        //
        // Assigning it in this init's BODY (`onboardingViewModel.actionRunner = …`) would be the
        // tempting answer and a silent disaster: reading a `@StateObject`'s `wrappedValue` before
        // SwiftUI has installed the state re-evaluates this autoclosure and hands back a BRAND NEW
        // instance every time ("Accessing StateObject's object without being installed on a View.
        // This will create a new instance each time."). The runner would land on a phantom
        // view-model that `body` never renders, the real one would keep a nil runner, and the CTA
        // would be a no-op again — T17's own bug, reproduced by the fix for T17.
        //
        // Constructor injection removes the question entirely: there is no "when do we wire it",
        // and deleting the wiring is a COMPILE ERROR rather than a green test suite.
        let actionEnvironment = OnboardingActionEnvironment(
            onboarding: onboardingEnvironment,
            bundledHelperBinary: bundledHelperBinary,
            userPacksDirectory: audioEnvironment.userPacksDirectory,
            configFile: configFile,
            // `lockFile` (this init's own parameter) only ever guards `config.json` — see its
            // other two call sites below (`EventMuteController`, `selectPack`). The takeOver path
            // this environment drives ALSO writes `settings.json` (`installClaudioHooks`), which
            // must serialize on its own, separate lock — never `config.json`'s.
            configLockFile: lockFile,
            settingsLockFile: ClaudioPaths.settingsLockFile)
        // 全部构造成**纯 local 实例**，再各自 wrap 进 `@StateObject` / `@State`，**并把同一实例**交给
        // `PanelConfigController`。绝不在这里读 `_someStateObject.wrappedValue` —— 那会在 SwiftUI 装好
        // state 之前重新求值 autoclosure、每次发一个全新实例（见上面 actionRunner 那段同样的坑）。捕获
        // local 不碰这个陷阱：`ovm` / `dz` / `perRow` 就是被 wrap 的那几个引用，`panelModel` 的
        // `afterFullReload` 闭包捕获它们，跨-view-model 协调因此打到的是面板真正在渲染的那几个实例。
        let onboardingViewModel = OnboardingViewModel(
            environment: onboardingEnvironment,
            actionRunner: DiskOnboardingActionRunner(environment: actionEnvironment))

        let loadedConfig = loadPanelConfig(from: configFile).resolvedConfig
        let dropZoneViewModel = AudioImportViewModel(
            packID: loadedConfig.selectedPack, environment: audioEnvironment)
        var perRow: [Event: EventRowImportViewModel] = [:]
        for event in Event.allCases {
            let importViewModel = AudioImportViewModel(
                packID: loadedConfig.selectedPack, environment: audioEnvironment)
            perRow[event] = EventRowImportViewModel(event: event, importViewModel: importViewModel)
        }

        _onboardingViewModel = StateObject(wrappedValue: onboardingViewModel)
        _dropZoneViewModel = StateObject(wrappedValue: dropZoneViewModel)
        _announcer = StateObject(wrappedValue: PanelAnnouncer())
        _rowImportViewModels = State(initialValue: perRow)

        // config 读模型 + 静音/切包写路径的**全部行为**都住在这个可测的类里。`afterFullReload` 是全量
        // reload 里 config 读模型**之外**的那一半：onboarding 重探 + 两组 import view-model retarget 到
        // 新包 —— 与旧 `refresh()` 逐行等价（onboarding 那行挪到 config 重载之后，两者互不依赖，结果不变；
        // retarget 收到刚重载出的 config，用它的 `selectedPack`，与旧代码一致）。
        _panelModel = StateObject(
            wrappedValue: PanelConfigController(
                configFile: configFile,
                lockFile: lockFile,
                environment: audioEnvironment,
                afterFullReload: { reloadedConfig in
                    onboardingViewModel.refresh()
                    dropZoneViewModel.retarget(to: reloadedConfig.selectedPack)
                    for rowViewModel in perRow.values {
                        rowViewModel.retarget(to: reloadedConfig.selectedPack)
                    }
                }))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // `header` is rendered ONLY in the operational (`.installed`) branch — NOT
            // unconditionally above the `if` — because `OnboardingView` renders its OWN
            // "Claudio" header (`OnboardingView.header`). Rendering both would stack two
            // identical titles (and double the VoiceOver announcement) on every onboarding
            // screen — the first thing a new user sees. Installed → PanelView owns the header
            // (with the "当前声音包 …" a11y label); onboarding → OnboardingView owns it.
            if onboardingViewModel.state == .installed {
                header
                operationalPanel
            } else {
                OnboardingView(viewModel: onboardingViewModel, focusedTarget: $focusedTarget)
            }
        }
        .padding(13)
        .frame(width: layoutAdaptation.panelWidth)
        .background(ClaudioColor.panel(colorScheme))
        .overlay(
            RoundedRectangle(cornerRadius: 15)
                .strokeBorder(ClaudioColor.hairlineStrong(colorScheme), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 15))
        // `.onAppear` deliberately does NOT call `refresh()` (`/ship` 评审 · 性能): `refresh()`
        // is a synchronous, main-thread DISK SCAN (re-reads config.json, the selected pack's
        // manifest + a `stat` per event, then enumerates BOTH pack roots and reads EVERY pack's
        // manifest). It used to run from `.onAppear` **and** from `.onChange(showCount)` below —
        // both of which fire when the popover opens, so the very first open scanned everything
        // TWICE. `.onChange(showCount)` is the reliable signal of the two (see
        // ``PanelFocusCoordinator``'s own doc comment on why `.onAppear` is not), and `init(...)`
        // has already loaded the initial rows/cards from disk, so this hook only needs to place
        // focus and report the panel's width.
        //
        // T17g：它也**不播报**，一字不差的同一条推理 —— `.onAppear` 与 `.onChange(showCount)` 在同一次
        // 打开里**都会**跑，两条 post 会抢同一条「一次一句」的通道，而谁先谁后取决于 `onAppear` 与
        // `popoverDidShow` 的 AppKit 时序：一个没实测过的语义。`showCount` 是这两个信号里可靠的那个
        // （见 ``PanelFocusCoordinator`` 的文档），所以播报只挂它。
        .onAppear {
            applyFirstFocus()
            onPanelWidthChange(layoutAdaptation.panelWidth)
        }
        // a11y-architect FIX 4: `MenuBarController.popoverDidShow` bumps
        // `focusCoordinator.showCount` every time the popover becomes visible — the ONE place
        // "the popover just (re)opened, re-read the disk" is handled.
        .onChange(of: focusCoordinator.showCount) { _ in
            // 面板真的出现在屏幕上了。**一条已经被看过的失败**在这里被忘掉；一条在面板关着时诞生的
            // 失败**不会** —— 这一次打开才是它的第一次露面（T17d，见
            // ``OnboardingViewModel/panelDidBecomeVisible()``）。上一版在这里无条件清，于是「用户
            // 点完接管就切走、安装在后台失败」这条路径上的失败，从头到尾一个像素都没有过。
            //
            // 必须在 `refresh()` **之前**：清掉 `.failed` 会改变 `hasDetailToggle`，而
            // `applyFirstFocus()` 要按清理**之后**的焦点序落焦，否则光标会落在一颗刚被清掉的
            // 「查看原因」上。
            // T17g —— **返回值不许丢**。它是「这条结果是不是第一次露面」的**唯一**真相源
            // （`outcomeHasBeenSeen` 就在那个函数里被消费掉了），而那正是这一次打开唯一一次能把它
            // **说出口**的机会。上一版把它丢了：结果画出来了，VoiceOver 用户却只听到一句平静的
            // 「Claudio 面板，当前声音包 X」—— 静默替换换到听觉通道上原样复活。
            let moment = onboardingViewModel.panelDidBecomeVisible()
            panelModel.reload()
            applyFirstFocus()
            // `say(_:)` 必须在 `refresh()` **之后**：面板句里的包名来自刚被 refresh 写新的 `packCards`。
            say(moment)
        }
        // 另一半（T17d）：`MenuBarController.popoverDidClose` bumps `focusCoordinator.hideCount`。
        // 没有它，view-model 就只能去**假定**「下一次打开 = 上一条失败已经被看过」—— 而在
        // `.transient` popover 被一次 app 切换关掉、写盘 Task 却还在跑的那条路径上，那个假定是假的。
        .onChange(of: focusCoordinator.hideCount) { _ in
            onboardingViewModel.panelDidHide()
        }
        // T17 —— **这一行是「接管成功」这件事真正被兑现的地方**，不是锦上添花。
        //
        // CTA 落地后 `onboardingViewModel.refresh()` 把 state 翻到 `.installed`，`body` 于是从
        // onboarding 卡切到 `operationalPanel`。但 `config` / `eventRows` / `packCards` 是三个
        // 独立的 `@State`，只在 `init` 里读过一次盘 —— 而 `init` 跑在 app 启动的那一刻，也就是
        // setup **之前**：那时 `config.json` 还不存在（`loadPanelConfig` 回落到 `.needsPack`，
        // `config` 走 `resolvedConfig` 的空包默认值）、包一个都还没复制。于是用户在**接管成功的
        // 那一秒**看到的会是：「先选包」空态卡（D23 定稿④的路由态）+ 一个空的切包画廊
        // —— 而真实的包和 config 明明已经躺在磁盘上了。他必须关掉
        // 面板再打开一次才看得到真相。这个产品在它唯一一次庆祝时刻上撒谎。
        //
        // 不会递归：`refresh()` 内部第一行就是 `onboardingViewModel.refresh()`，而探测是磁盘的
        // 纯函数 —— 第二遍得到同一个 state，`onChange` 不再触发。
        .onChange(of: onboardingViewModel.state) { _ in
            panelModel.reload()
            applyFirstFocus()
            // T17g：有结果要说的时候，这一句**主动让出**那条「一次一句」的通道（政策在
            // ``panelAnnouncement(_:)``）。上一版两边都无条件开口，于是「你的包被换掉了」能不能被听见，
            // 押在 SwiftUI **未文档化**的 onChange 顺序上 —— `runDiskAction` 在同一个 MainActor turn 里
            // 写完 `actionState` 又写 `state`，两个 handler 在**同一趟** update pass 里都会触发。
            say(.stateChanged)
        }
        // 动作态变化（开始跑 / 失败）：① 播报——一颗变灰的按钮 + 一个 spinner 对 VoiceOver 是完全
        // 无声的，而这个仓库自己已经论证过「光有 label 不会被播报，VO 只读它光标落上的元素」；
        // ② 重新落焦——in-flight 期间 CTA 被禁用，持有焦点的那颗按钮当场作废，没人把焦点接走的话
        // 键盘用户按完空格就无处可去了。
        //
        // 刻意 `{ _ in }` 而不是 `{ newValue in }`（与上面那条 `state` handler 一样）：两个 handler 必须读
        // view-model 的**当前值**。整个防竞争契约（「同一趟里只有一个开口，或两个说同一句」）建立在
        // 「两边看到的是同一份快照」上。
        .onChange(of: onboardingViewModel.actionState) { _ in
            // T17h′ —— **这一行让「同一趟只 post 一句」从一句推理变成一条结构。**
            //
            // 上一版这里是三个 `say(_:)` 调用点里**唯一**不先 `refresh()` 的那个。而 `refresh()` 写的正是
            // `config` / `packCards` 两个 `@State`，也就是面板句里包名的来源。于是一次**无告知的成功接管**
            // （`actionState: .running → .idle`、`state: .notInstalled → .installed`，同一个 MainActor turn、
            // 同一趟 update pass）里，若 SwiftUI 先跑这个 handler（**未文档化**的顺序）：
            //   · `onboardingViewModel.state` 已经是 `.installed`（引用类型，早更新了）
            //   · 而 `packCards` / `config` 还是 **app 启动时**读的那份 —— 那时 `config.json` 还不存在，
            //     `loadPanelConfig` 回落成 `.needsPack`，`config` 走空包默认值
            //   → header = 「Claudio 面板，当前声音包 」**包名是空的**
            // 紧接着 state 那个 handler（先 `refresh()`）说「…当前声音包 lofi。」——**两句不同，后缀规则吞不掉，
            // 同一趟 post 了两条。** 而这恰恰是 T17f/T17g 整台机器存在的唯一理由。
            //
            // 「它没害处」是一句**推理**（陈旧那句必然先 post，后一条把它截断，幸存者总是对的）——它押的是
            // 「被截断的那条一个字都不会出声」，一个**没人实测过**的 VoiceOver 语义。用户完全可能听到一句
            // 卡半截的「Claudio 面板，当前声音包…」，就在这个产品唯一一次庆祝时刻上。
            //
            // 只在 `.idle` 那一格 refresh：**面板句只在那一格才被说出来**（别的动作态说的是 `actionClause`，
            // 一个字的 header 都不用）。而 `.running` 时 refresh 会去扫一块**动作正在写**的磁盘 —— 那是
            // 拿一个真 bug 换一个假 bug。代价：一次落地动作多扫一遍盘（点击路径，不是每次开面板的热路径 ——
            // `/ship` 性能评审管的是后者）。
            if case .idle = onboardingViewModel.actionState { panelModel.reload() }
            say(.actionStateChanged)
            applyFirstFocus()
        }
        // T15 D5 「极大 → 加宽 popover」: SwiftUI already widened ITSELF (`.frame(width:)` above);
        // this tells the AppKit popover around it to follow (see ``onPanelWidthChange``).
        .onChange(of: layoutAdaptation.panelWidth) { newWidth in
            onPanelWidthChange(newWidth)
        }
        // `.contain` keeps every control individually reachable by the VoiceOver cursor; the
        // label names the container itself, which otherwise reads as an anonymous group. It is
        // NOT what delivers 「VoiceOver 进入先播报面板标题 + 当前包」 — a label is read when the
        // cursor lands on the element, and the cursor lands on a control, not on the group.
        // ``say(_:)`` is what actually says the sentence on open.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(headerAccessibilityLabel)
    }

    /// **整个 GUI 里唯一一处 `NSAccessibility.post`，也是唯一一处播报调用点**（T17g）。
    ///
    /// 「VoiceOver 进入先播报面板标题 + 当前包」(ENGINEERING.md「无障碍规格」)，以及一次 CTA 动作的
    /// 开始 / 失败 / 「我替你做主」的告知 —— 全部走这一个出口。一个禁用的按钮 + 一个
    /// `.accessibilityHidden(true)` 的 spinner 对 VoiceOver 完全无声；一条静态 `Text` 写的失败原因，
    /// VO 光标不会自己跑过去。**让 VoiceOver 开口的唯一办法，是去求它开口。**
    ///
    /// 政策不在这里：说不说、说哪一句、多条告知怎么拼，全在 ``panelAnnouncement(_:)``
    /// （`ClaudioGUICore`，纯函数，harness 逐格钉死）；「同一趟里别说两遍」在 ``PanelAnnouncer``。
    /// 这里只剩「把事实凑齐 + 把那一句交给 AppKit」。上一版的政策住在这个文件的三个 `private` 函数里，
    /// 而 `ClaudioGUI` 是个 `@main` executableTarget —— harness **一行都 import 不到**，于是
    /// 「谁抢到那条一次一句的通道」押在 SwiftUI 未文档化的 onChange 顺序上，零测试守护。
    ///
    /// 用 AppKit 的 `.announcementRequested` 而不是 SwiftUI 的 `AccessibilityNotification`
    /// （macOS 14+，高于本包 macOS 12 的地板）。异步 post，好让它落在 popover 的窗口成为 key、进入
    /// AX 树**之后** —— VoiceOver 会丢掉发给一个还不在那儿的 app 的播报。VoiceOver 没开时是 no-op。
    ///
    /// ⚠️ **不要从别处再调一次**（`switchPack` / `toggleMute` 都很诱人：换完包，面板句就变了）：
    /// `.announcementRequested` 是「一次一句」的通道，那次 post 会**截断**用户可能还没听完的那条告知。
    /// 要加一个新的播报时刻，先给 ``PanelAnnouncementMoment`` 加一个 case —— 那会让
    /// ``panelAnnouncement(_:)`` 的 `switch` 编译红，逼你在纯函数里想清楚它跟别人抢不抢通道。
    /// ## 为什么闸门与去重都在 `async` **里面**（T17h —— `/codex review a3c2d08` 逮到）
    ///
    /// 上一版在这里**同步**问完「该说吗 / 说哪句 / 刚才说过没」，却把 post 排进了下一趟 main queue：
    ///
    /// ```swift
    /// let candidate = viewModel.announcement(moment, header: …)   // ← 闸门在这一趟问的
    /// guard let sentence = announcer.consume(candidate, …) else { return }
    /// DispatchQueue.main.async { NSAccessibility.post(…) }        // ← 但 post 发生在下一趟
    /// ```
    ///
    /// 于是那道「面板关着就一个字都不说」的闸门，问的是**过去**的世界。两趟之间面板完全可能已经关了
    /// （`.transient` popover 被一次 app 切换当场关掉 —— 那正是 T17d/T17f/T17g 整条 bug 家族的主路径），
    /// 而 post 照发不误：`element: NSApp` 是**整个 app**，不是那个已经消失的 popover。用户人已经在
    /// Finder 里，Claudio 朝着他正在用的窗口念了一句话。
    ///
    /// 那扇窗有多宽？只有**一次 main queue drain**：block 已经排在队里，AppKit 通常会在处理下一个输入
    /// 事件之前把它抽干。所以这条路径**没有人实测到过**。但「我推理出这个格子不可达」正是这个仓库
    /// 反复交学费的那句话（T17c 的两个无人认领的格子、T17d 那条「重开 = 看过了」的假定），而这里的
    /// 修法只是把三行代码挪进一个已经存在的 block。
    ///
    /// 挪进来之后，闸门、去重、post 看到的是**同一份**世界，而不是隔着一趟的两份。顺带还白拿两件事：
    /// - 若动作在这一跳里刚好落地，`.running` 那句「正在接管…」会被自动读成新的结果 —— 一句本来就要
    ///   被下一条 post 当场截断的废话，现在压根不出生。
    /// - 面板若已关闭，`announcement(…)` 返回 `nil`，`consume` **一次都不跑** —— 去重器不会被一条
    ///   从未出口的话污染。
    ///
    /// **顺序不变**：两条 `say(_:)` 在同一趟 update pass 里各排一个 block，main queue 是 FIFO 的，
    /// 所以它们仍按 handler 顺序 consume。「开面板那一句永远以结果结尾，第二条必然是它的后缀」这条
    /// 结构不变式一个字都没动（`PanelAnnouncementSuite` 全矩阵仍然逐格钉着它）。
    private func say(_ moment: PanelAnnouncementMoment) {
        // ⚠️ **这里有一个已知的、活的正确性缺口 —— 不要把下面这段读成「已经论证安全」。**
        // 台账：TODOS.md「面板句里的 `header` 在 async **外**捕获，其余三个事实在 async **内**重读」（P2）。
        //
        // `header` 仍在**这一趟**取，而不是推迟到 post：包名那半句来自 `packCards` / `config` 两个
        // `@State`。**这是一个选择，不是能力所限** —— 这里曾经写着「`@Sendable` 闭包捕不到 `self`」，
        // 那句话**是假的**：`View` 协议是 `@MainActor` 的，所以 `PanelView` 是 MainActor 隔离的，因而
        // **隐式 `Sendable`**，闭包捕得到 `self`（今天它已经捕了 `announcer` / `coordinator` / `viewModel`
        // —— 这本该是线索）。把这一行挪进闭包，Swift 6 语言模式下零错误零警告编得过，实测过。
        //
        // 真正的理由是**语义**，不是编译器：把视图 struct 捕进一个逃逸闭包、在 SwiftUI 已经更新过视图之后
        // 再去读它的 `@State`，不是有文档保证的行为（SwiftUI 只保证 view update 期间的 State 读），捕获的
        // 那个值完全可能读到一块已经卸掉的 / 陈旧的存储。**这一条我们没有实测过** —— 所以按未验证对待，
        // 不去赌它。但要说清楚：它是一堵**我们选择不翻**的墙，不是一堵翻不过去的墙。
        //
        // 而剩下的事实（`state` / `actionState` / 面板还开着吗）全部推迟到 post 的那一趟去问 —— 它们的
        // 真相源是 view-model，一个引用类型，读得到最新值。**于是四个事实分居两趟：三个在执行侧，
        // header 一个在捕获侧。** T17h 把闸门 / 去重 / post 挪进 async 的理由是「三者从此看到同一份
        // 世界」—— 那个世界并没有统一，只是从「四个全在捕获侧」变成了三比一。
        //
        // 【这段曾经写着什么，以及它为什么不再成立】T17h 之前，这里论证的是「header 凭什么是新鲜的」：
        // 每一个会用到它的调用点都排在 `refresh()` 之后 ——
        //   · `.onChange(showCount)`  → `refresh()` → `say(moment)`
        //   · `.onChange(state)`      → `refresh()` → `say(.stateChanged)`
        //   · `.onChange(actionState)`→ `.idle` 时 `refresh()` → `say(.actionStateChanged)`
        // 这条论证今天**仍然成立**（`ViewWiringSuite` 有顺序断言钉着第三条），但它论证的是**捕获时刻**的
        // 新鲜度。T17h 之前，捕获与 post 是同一趟，「捕获时新鲜」等于「post 时新鲜」；T17h 之后，两者
        // 之间隔了一次 main queue 派发，这两句话不再是同一句。**旧论证没有变错，是它要回答的问题变了。**
        //
        // 【缺口怎么走通的 —— 不需要 FIFO 被违反，恰恰是 FIFO 被遵守造成的】
        // Darwin 上 MainActor 的默认 executor 就是把 job enqueue 进 main dispatch queue，串行队列按**入队
        // 顺序**严格 FIFO。所以在下面这个 block **之后**入队的 MainActor job 抢不到它前面 —— 竞争不在执行
        // 顺序，在**入队时刻**，而那个时刻**不由主线程决定**：`DiskOnboardingActionRunner.run` 是
        // `await Task.detached { performOnboardingDiskAction(…) }.value`（`OnboardingActions.swift:632-639`），
        // `OnboardingViewModel.swift` 里那个 `await` 的续体，是**后台线程完工的那一刻**丢回主执行器的。
        // 它完全可能落在下面的「捕获 header」与「enqueue block」之间 —— 真这么落了，它就**先跑**：
        // `actionState → .idle`、view-model 的 `refresh()` 把 `state` 翻面。block 随后醒来，把**捕获时**的
        // header 拼到**执行时**的 state 上 —— 这就是全部的缺口。代码里没有任何东西把那个续体排在这个
        // block 之后。
        //   （两点精确性，别再传错：① view-model 的 `refresh()` 只有一行 `state = detectOnboardingState(…)`，
        //     **从不碰** `packCards` —— 重写 `packCards` 的是 `panelModel.reload()`（`PanelConfigController`，
        //     T15 之后从这个文件抽出去了），那要等下一趟 update pass，与这条竞争无关：header 早在捕获时
        //     就定死了。② 此处只说「可能先跑」，**不说「保证」**：
        //     下面那段刚论证过，Swift 并发 job 相对 dispatch block 的入队顺序是**实现细节** —— 缺口论证
        //     不需要、也不该反过来把同一条实现细节当成保证来用。）
        //
        // 最现实的一格是**断开连接**：`.running` 那趟捕获 header 时磁盘写还没落地 —— `state` 仍是
        // `.installed`，于是 `headerAccessibilityLabel` 第一行放行，header 带着旧包名。**注意「只在 `.idle`
        // 才 `refresh()`」那道门在这一格帮不上任何忙**：`uninstallClaudioHooks` 只重写 settings.json，根本
        // 不碰 config.json / packs 目录，所以就算这一趟真的 refresh 了，算出来的 header 一字不差。陈旧的
        // 根因是「在写落地**之前**捕获」，不是「没 refresh」—— 谁要是想靠拆掉那道门来修这一格，会一无所获。
        // 而这次重写只动一个小 JSON（不拷二进制、不拷包），比接管那条路径轻得多；**窗口有多宽没人测过**，
        // 这里只断言它**存在**：这一句 post 出去的内容会带上用户**刚刚断开**的那个包名。
        //
        // 接管那条路径症状相反：捕获时 `state` 还是 `.notInstalled`（hooks 是 `performFirstRunSetup` 的最后
        // 一次写），header 回落成常量「Claudio 面板」，醒来时已是 `.installed` —— **这一句** post 出去的
        // 内容里，包名那半句是缺的。
        //   （用户最终**听到**什么，这里不作断言：续体的 `@Published` 写会触发下一趟 update pass，那一趟
        //     `refresh()` → `say(…)` 会 post 出完整的那一句，且**不会**被后缀去重吞掉（`hasSuffix`，长句
        //     不是短句的后缀）。真实症状更可能是「半句被更完整的一句截断 / 替换」。两处都只断言
        //     「post 出去的这一句是错的」，不断言听感 —— 那需要真机 VoiceOver 实测。）
        //
        // 【为什么不在这里就地修】就地重算是**能编过的**（捕 `self`，在闭包里算 header）—— 不选它，是因为
        // 那要在 SwiftUI 的 update pass 之外读视图 `@State`，语义无文档保证（见上）。真正的修法是把
        // `config` / `packCards` 从视图 `@State` 搬进一个 `@MainActor` view-model（`@MainActor` class 是
        // `Sendable` 的，捕得到，且读的是引用类型的**当前**值）。
        //
        // ⚠️ 2026-07-13 更新：那个 view-model **已经存在了**（`PanelConfigController`，红队 9cccc9c）——
        // 「一次买下三个洞：第二个 oracle、可测性、以及这条竞争」里，前两个（可测性 + oracle）已经关掉。
        // 但**这条竞争本身还没修**：下面仍然在 update pass 里就地把 `header` 算成一个常量捕获进 block，
        // 而不是捕 `panelModel`、在 block 里读它的**当前** `packCards` / `config`。修它现在只是**够得着**了
        // （`panelModel` 是 `@MainActor` `Sendable` class，捕得到），不再是「无文档保证」——但它是一次
        // 独立的、要碰 T17f/g 播报时序的改动，本轮（view-model 抽取）**没做**。别把「view-model 落地了」
        // 读成「这条竞争修好了」。
        let header = headerAccessibilityLabel
        let viewModel = onboardingViewModel
        let announcer = self.announcer
        let coordinator = focusCoordinator
        DispatchQueue.main.async {
            // `DispatchQueue.main.async` 的闭包不是 `@MainActor` 的，但它**跑在主线程上**——
            // `assumeIsolated` 把这个运行期事实交给编译器，好让下面两行 `@MainActor` 调用合法。
            //
            // 【为什么是 `DispatchQueue.main.async` 而不是 `Task { @MainActor in … }`】
            // **不是**因为后者「会换一条队列」—— 这段注释以前是这么写的，而那句话在 Darwin 上**是假的**：
            // MainActor 的默认 executor 正是把 job enqueue 进 main dispatch queue
            // （`swift_task_enqueueMainExecutor` → `dispatch_async_swift_job`），并没有换队列。
            //
            // 真正的理由是**保证的强度**：后缀去重这条不变式，依赖「同一趟 update pass 里排下的两个 block
            // 按 handler 顺序 drain」。串行队列按入队顺序 FIFO 是 **libdispatch 的文档保证**；而 Swift
            // 并发的 job 相对于 dispatch block 的入队顺序，是**实现细节**（今天走同一条 main queue，明天不
            // 一定）。把一条产品级不变式压在实现细节上，是本仓库反复交学费的那类赌注 —— 所以选文档保证的
            // 那个。**换成 `Task {}` 之前，先想清楚你是在拿哪一条保证换哪一条。**
            MainActor.assumeIsolated {
                guard
                    let sentence = announcer.consume(
                        viewModel.announcement(moment, header: header),
                        openCount: coordinator.showCount)
                else { return }
                NSAccessibility.post(
                    element: NSApp as Any,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: sentence,
                        .priority: NSAccessibilityPriorityLevel.high.rawValue,
                    ])
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Claudio")
                .font(.system(size: 15 * typeScale, weight: .semibold))
                .foregroundColor(ClaudioColor.text(colorScheme))
            if onboardingViewModel.state.showsHeaderTakenOverDot {
                Circle()
                    .fill(ClaudioColor.success(colorScheme))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headerAccessibilityLabel)
    }

    private var headerAccessibilityLabel: String {
        guard onboardingViewModel.state == .installed else { return "Claudio 面板" }
        let packName = panelModel.packCards.first(where: \.isSelected)?.name ?? panelModel.config.selectedPack
        return "Claudio 面板，当前声音包 \(packName)"
    }

    // MARK: - Operational panel (installed state)

    @ViewBuilder
    private var operationalPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            // D23 定稿④：路由到已经存在的自救路径，零新机制。`configState` 决定这一块顶部内容
            // 显示什么——`.operational` 时是今天这四行事件覆盖度；`.needsPack`（还没有人选过包）
            // 换成画廊空态「先选包」，`PackGalleryView` 本身仍然照常渲染在下面（自救路径本来就
            // 通：点一张卡就是 ``selectPack``，会建出一份正确的 config）；`.malformed`/`.unwritable`
            // 换成诚实失败态 + 可执行的修复指令——不禁用任何控件（写者本来就全部 fail closed），
            // 只是不再假装一切正常（D19 已作废：不是禁用一个滑块，是整个面板换一个诚实的态）。
            switch panelModel.configState {
            case .operational:
                ForEach(panelModel.eventRows, id: \.event) { row in
                    if let importViewModel = rowImportViewModels[row.event] {
                        EventRowView(
                            row: row,
                            importViewModel: importViewModel,
                            focusedTarget: $focusedTarget,
                            adaptation: layoutAdaptation,
                            onPreview: { playPreview(for: row) },
                            onToggleMute: { panelModel.toggleMute(row.event) },
                            // T16 fix: a successful row-end bind writes `manifest.json` but the
                            // row renders off `eventRows`, which only `refresh()` recomputes —
                            // without this the just-bound row keeps showing "未配置/文件丢失" and a
                            // disabled 试听 until an unrelated mute/switch/reopen. Recompute now.
                            onImportCompleted: { panelModel.reload() }
                        )
                    }
                }
            case .needsPack:
                needsPackNotice
            case .malformed(let reason), .unwritable(let reason):
                configFailureNotice(reason: reason)
            }
            // 绝不静默吞错（项目规则）—— 静音写回失败与切包失败**都**在这里如实上报。两条都
            // 可能同时非 nil（一次失败的静音 + 一次失败的切包），所以两条都渲染，不互相顶替。
            //
            // `.lockBusy` 仍然要渲染，但**它的成因已经变了**（锁分离，D9）：`setEventEnabled` /
            // `selectPack` 现在拿 `config.lock`，`claudio play` 拿 `play.lock` —— 两者不再相撞，
            // 「每个 Claude Code 事件 spawn 一次 play 就可能吞掉一次点击」那条高频路径**已经没了**。
            // 今天 `.lockBusy` 只剩两个真实来源：另一个 config.json 写者（第二个 GUI 实例，或用户
            // 手动跑 `claudio use`）—— 低频，但绝不是零。渲染保留（项目铁律：绝不静默吞错），
            // 文案本来就写好在 `SetEventEnabledError`/`UseError` 里。
            // `.configMissing` is deliberately excluded here (PLAN-MASTER-VOLUME.md D43): it is
            // not a user-facing error — ``toggleMute`` reroutes ``configState`` to `.needsPack`
            // on this exact failure, and that empty state (`needsPackNotice`) IS the explanation.
            // Rendering its `description` too would show a redundant, never-QA'd string
            // underneath a card that already says "先选包".
            if let error = panelModel.muteError, error != .configMissing {
                errorNotice(error.description)
            }
            if let error = panelModel.packSwitchError {
                errorNotice(error.description)
            }
            AudioDropZoneView(viewModel: dropZoneViewModel)

            // T17f：**这里是告知真正的家 —— 而且位置本身是它文案的一部分。**
            //
            // 一次成功的「接管」必然把 state 推成 `.installed`（`runDiskAction` 无条件 `refresh()`），
            // 而 `.installed` 渲染的正是这个运行态面板 —— onboarding 卡此刻根本不在屏幕上。所以
            // 「你选的包没了、已替你换成 X」「你那个读不出的包被搬到了 Y」这两句话，**每一次都诞生
            // 在这一侧**。上一版这里一行都没有，于是它们每一次都无声。
            //
            // **紧挨在 `PackGalleryView` 之前**，这一条是硬约束，不是排版口味：那句文案白纸黑字写着
            // 「你随时可以在**下面的**声音包里换成别的」。T17f 自评审第一版把它放进了 `disconnectRow`
            // （画廊**之后**），于是那句话下面唯一的东西是「断开连接」那颗破坏性按钮 —— 一个刚被替换
            // 了选包、正想换回去的用户，被一句话指向了卸载键。
            //
            // 换句话说：**移动这个 `ForEach` 到画廊下方，就等于把那句文案变成谎话。** 要改位置，
            // 先改文案。（`runSetupNoticeSuites` 钉住了「文案里有『下面的声音包』」这一半；另一半
            // ——「它真的在下面」—— 只有这条注释和你的眼睛守着。）
            ForEach(Array(onboardingVisibleNotices(actionState: onboardingViewModel.actionState).enumerated()), id: \.offset) { _, notice in
                ActionNoticeRow(message: notice.message, typeScale: typeScale)
            }

            PackGalleryView(
                cards: panelModel.packCards, focusedTarget: $focusedTarget, onSelect: { panelModel.switchPack(to: $0.id) })
            disconnectRow
        }
    }

    /// D23 定稿④「先选包」空态卡——`configState == .needsPack` 时替换掉本该渲染的四行事件覆盖度。
    /// `PackGalleryView` 仍然照常渲染在下面（这就是主行动：点一张卡）；这里只负责说清楚温度 +
    /// 上下文（DESIGN.md 空态三要素）。文案是 ENGINEERING.md「切包画廊」空态行的标题
    /// （"先选包"）+ 一句 2026-07-12 拍板的工作稿副文案。
    private var needsPackNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("先选包")
                .font(.system(size: 13 * typeScale, weight: .semibold))
                .foregroundColor(ClaudioColor.text(colorScheme))
            Text("还没有选中任何声音包。点一张卡片，Claudio 会建好配置。")
                .font(.system(size: 11 * typeScale))
                .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("先选包。还没有选中任何声音包。点一张卡片，Claudio 会建好配置。")
    }

    /// D23 定稿④诚实失败态——`configState`是 `.malformed`/`.unwritable` 时替换掉本该渲染的四行事件
    /// 覆盖度。**不禁用任何控件**（写者本来就全部 fail closed，见 `ConfigMutation.swift`）：这里只
    /// 负责把已经存在的、可执行的修复原因说出来，并给一个「在访达中显示」的快捷方式——doctor 的
    /// 诊断今天就带着这句一模一样的话（``configRewritabilityResult(configFile:)``），这里不重新
    /// 发明一套说法。
    private func configFailureNotice(reason: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11 * typeScale))
                    .foregroundColor(ClaudioColor.error(colorScheme))
                Text(reason)
                    .font(.system(size: 11 * typeScale))
                    .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([configFile])
            } label: {
                Text("在访达中显示 config.json")
                    .font(.system(size: 11 * typeScale))
            }
            .buttonStyle(.plain)
            .foregroundColor(ClaudioColor.textSecondary(colorScheme))
            .accessibilityHint("在访达中定位 config.json，方便手工修正")
        }
    }

    /// 「断开连接」——`.installed` 态的次 CTA（T17，**授权的设计变更**）。
    ///
    /// 它此前**在整个 shipping app 里没有一个像素**：`OnboardingCopy(.installed).secondaryActionTitle`
    /// 确实写着「断开连接」，但 `.installed` 时 `body` 渲染的是这个 `operationalPanel`，
    /// `OnboardingView` 压根不出现 —— 那颗按钮只活在 state gallery 里。而 `.notInstalled` 的正文
    /// 白纸黑字向用户承诺「还会自动留一份备份，**随时可以一键撤销**」。那个「一键」到今天为止
    /// 不存在。
    ///
    /// 失败也在这里渲染：断开失败的那一刻，onboarding 卡不在屏幕上（state 还是 `.installed`），
    /// 所以 `OnboardingView` 里那条 `ActionFailureRow` 够不着它。
    @ViewBuilder
    private var disconnectRow: some View {
        // 渲染**任何**失败，不只是断开的（T17c）。上一版这里只认 `branch: .disconnect`，理由是
        // 「一条陈旧的接管失败不该永久挂在一张已经装好的面板底部」—— 顾虑是真的，答案是错的：它让
        // 一次**真的**接管失败（失败后 state 恰好落在 `.installed`）变得**一个像素都没有**。
        // 陈旧问题现在由时效性回答（``OnboardingViewModel/clearConsumedFailure()``，面板重开即清），
        // 而不是靠在这里把它丢掉。
        if let failure = onboardingVisibleFailure(actionState: onboardingViewModel.actionState) {
            ActionFailureRow(
                message: failure.message, detail: failure.detail,
                isShowingDetail: onboardingViewModel.isShowingDetail,
                showsDetailToggle: onboardingShowsFailureDetailToggle(
                    state: onboardingViewModel.state, actionState: onboardingViewModel.actionState),
                onToggleDetail: { onboardingViewModel.toggleDetail() },
                focusedTarget: $focusedTarget, typeScale: typeScale)
        }

        // 告知**不在这里** —— 它排在 `PackGalleryView` **之前**（见 `operationalPanel`）。
        // 那是刻意的，而且是被自评审逼出来的：文案说「在下面的声音包里换成别的」，而
        // `disconnectRow` 排在画廊之后 —— 把提示行放在这里，就等于把用户指向「断开连接」。

        let intent = onboardingSecondaryIntent(for: onboardingViewModel.state)
        let isRunning = onboardingViewModel.isRunning(intent)
        // copy 是按钮文案的**单一真相源**，没有兜底字面量（T17c）。上一版写的是
        // `?? "断开连接"` —— 一条死分支（`.installed` 的 `secondaryActionTitle` 恒非 nil），
        // 它唯一的效果是：哪天有人把那条 copy 改成 `nil`（= 「这个态没有这颗按钮」），面板照样会
        // 用硬编码字面量把按钮画出来，copy 与视图当场分叉且零信号。copy 说没有，就真的不画。
        if let baseTitle = onboardingViewModel.copy.secondaryActionTitle {
            let title = isRunning ? onboardingActionRunningTitle(.disconnect) : baseTitle

            Button {
                Task { await onboardingViewModel.performSecondaryAction() }
            } label: {
                HStack(spacing: 6) {
                    // `reduceMotion` 时不画 spinner（T17c）：这棵视图树的「无动画」绊线注释（见 body
                    // 上方）立下的规矩是「若将来往这棵树里加动画，**必须**在那一点 gate 住
                    // `accessibilityReduceMotion`」。`ProgressView` 是一个无限旋转动画，它是这棵树里
                    // 的第一个。降级路径正是 DESIGN.md 写的「静态字形与瞬时状态切换」—— 而进行态本来
                    // 就已经由文案（「正在断开…」）承担了，不靠那圈转动。
                    if isRunning, !reduceMotion {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .font(.system(size: 11 * typeScale))
                }
                .frame(maxWidth: .infinity)
                // ≥24×24 命中区（a11y-architect FIX 6）。
                .frame(minHeight: 24)
                .padding(.vertical, 4)
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            // DESIGN.md「次 CTA = ghost」：**必须有 1px 描边**。裸 `.plain` 会让这条全宽的、破坏性的
            // 点击区在视觉上彻底消失 —— 用户看到的只是一行灰字，既不知道它是个按钮，也不知道它有多大。
            // 只用既有 token（`hairline-strong` 描边 + `text-2` 文字），不新造颜色。
            .buttonStyle(.plain)
            .foregroundColor(ClaudioColor.textSecondary(colorScheme))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(ClaudioColor.hairlineStrong(colorScheme), lineWidth: 1)
            )
            .disabled(onboardingViewModel.isPerformingAction)
            .accessibilityLabel(title)
            .accessibilityHint("摘掉 Claudio 的声音，Claude Code 的其它设置都保留")
            .focused($focusedTarget, equals: .disconnect)
        }
    }

    /// One panel-level failure line — the 「拒绝行」 shape DESIGN.md already defines ("真红
    /// `circle-x` 字形 + `text-2` 说明"), identical to ``AudioDropZoneView``'s `rejectRow(_:)` and
    /// ``EventRowView``'s `importErrorRow(_:)` so every failure in this panel looks like the same
    /// kind of thing.
    ///
    /// 真红只上**图标**（非文本，≥3:1），文案走 `text-2`（≥4.5:1）—— 真红当正文亮色下只有
    /// 4.07:1，不达文本门槛（`/ship` 评审实证）。
    private func errorNotice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11 * typeScale))
                .foregroundColor(ClaudioColor.error(colorScheme))
            Text(message)
                .font(.system(size: 11 * typeScale))
                .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Dynamic Type (ENGINEERING.md T15 D5「Dynamic Type + 降级规则」)

    /// Real `DynamicTypeSize` (11 cases) → this panel's own 4-tier
    /// ``PanelTypeSizeTier`` — the only place this mapping happens; the actual DEGRADATION
    /// TABLE for each tier (``panelLayoutAdaptation(for:)``) lives in `ClaudioGUICore` and
    /// is unit-tested there. This mapping itself is a one-line SwiftUI-only lookup, not a
    /// "decision" worth its own test (the environment type isn't available outside SwiftUI).
    private var typeSizeTier: PanelTypeSizeTier {
        switch dynamicTypeSize {
        case .xSmall, .small, .medium, .large: .standard
        case .xLarge, .xxLarge: .larger
        case .xxxLarge, .accessibility1: .largest
        default: .maximum  // .accessibility2...5
        }
    }

    private var layoutAdaptation: PanelLayoutAdaptation { panelLayoutAdaptation(for: typeSizeTier) }

    // MARK: - Focus owner (a11y-architect FIX 4; ENGINEERING.md「无障碍规格」"打开焦点落首个
    // 可操作项")

    /// Sets ``focusedTarget`` to the panel's first OPERABLE control for whichever state it is
    /// currently rendering — called on appear and every time ``focusCoordinator`` signals the
    /// popover just (re)showed.
    ///
    /// The OPERATIONAL half delegates wholesale to ``panelOpeningFocus(rows:packCardIDs:)``
    /// (`ClaudioGUICore`, unit-tested): building the scope, deriving which rows' `.eventAction`
    /// slots are non-operable (``EventRow/eventActionOperable``), and resolving through
    /// ``panelFirstFocusTarget(_:nonOperableActionEvents:)`` — never plain
    /// `panelFocusOrder(_:).first`, which would park the opening caret on a muted first row's
    /// disabled 试听 ▶ (ENGINEERING.md「无障碍规格」"打开焦点落首个可操作项" — 可操作 is
    /// load-bearing). That three-step composition used to be hand-inlined HERE, as two private
    /// members inside SwiftUI, i.e. unreachable from this machine's dependency-free harness (T16
    /// review 修复⑥ sank it into the pure function precisely so it is TESTABLE — this view must
    /// not keep a second, untested copy of the same derivation).
    ///
    /// Onboarding has no rows, hence no `.eventAction` targets to filter, so it resolves through
    /// ``panelFirstFocusTarget(_:nonOperableActionEvents:)`` directly, off the same
    /// ``OnboardingCopy`` the branch actually renders — the consumed ORDER and the rendered
    /// CONTROLS can never disagree about which state the panel is in.
    ///
    /// Note: setting a SwiftUI `@FocusState` value only actually MOVES real AppKit keyboard focus
    /// once the hosting view is already part of the window's responder chain — that half is
    /// `MenuBarController.popoverDidShow`'s `makeFirstResponder` call, which always runs BEFORE
    /// this (via `focusCoordinator.requestFocus()`), never after.
    private func applyFirstFocus() {
        // `ctaOperable` (T17): while a `.takeOver`/`.disconnect` is in flight, both CTAs are
        // `.disabled(...)`, so the pure model must not hand focus to one — otherwise the caret
        // sits on a dead control and the keyboard user who just pressed 空格 on 「接管」 has
        // nowhere to go. Same 可操作 rule the muted-row's disabled 试听 ▶ already obeys, applied
        // to a transition that happens INSIDE the panel rather than at open.
        let ctaOperable = !onboardingViewModel.isPerformingAction
        // 失败行上那颗「查看原因」是一个真控件，所以它必须在焦点序里 —— 而渲染它的判据与算焦点序的
        // 判据是**同一个纯函数**，两者不可能各自漂移。
        let hasDetailToggle = onboardingShowsFailureDetailToggle(
            state: onboardingViewModel.state, actionState: onboardingViewModel.actionState)

        guard onboardingViewModel.state == .installed else {
            let copy = onboardingViewModel.copy
            focusedTarget = panelFirstFocusTarget(
                .onboarding(
                    hasPrimaryAction: copy.primaryActionTitle != nil,
                    hasSecondaryAction: copy.secondaryActionTitle != nil,
                    hasDetailToggle: hasDetailToggle),
                ctaOperable: ctaOperable)
            return
        }
        // D23 定稿④「路由态只做减法」：`operationalPanel` only renders `eventRows` for
        // `.operational` — `.needsPack`/`.malformed`/`.unwritable` show the empty-state/failure
        // card instead (see `operationalPanel`'s `switch configState`). A control that isn't on
        // screen must never claim a slot in the opening-focus order, so this passes an EMPTY row
        // list for every non-operational state rather than `eventRows` (which, off
        // `resolvedConfig`'s empty-pack default, would otherwise resolve to four `.unmapped` rows
        // that are never actually rendered).
        //
        let isOperational: Bool = {
            if case .operational = panelModel.configState { return true }
            return false
        }()
        let visibleRows: [EventRow] = isOperational ? panelModel.eventRows : []
        // hasMasterVolume: false (fix for a `/codex review` P2 on 341d9b7, which itself fixed a
        // P1): `isOperational` is NOT a valid proxy for "the slider is on screen" yet — this repo
        // is mid-way through PLAN-MASTER-VOLUME.md's staged rollout, and the actual slider view
        // (`MasterVolumeRow`, 阶段 D) has not landed. `operationalPanel` renders zero master-volume
        // control today (grep the target: no `Slider` bound to `.masterVolume` exists anywhere in
        // `gui/Sources/ClaudioGUI`), so passing `isOperational` here reintroduces the exact bug
        // 341d9b7 closed — just widened from three edge-case configStates to the common
        // `.operational` one. Flip this back to `isOperational` ONLY when 阶段 D lands
        // `MasterVolumeRow` in `operationalPanel` (ViewWiringSuite pins the literal `false` here
        // and fails the moment this line reads anything else, so this is not a "remember to come
        // back" — the test does the remembering).
        focusedTarget = panelOpeningFocus(
            rows: visibleRows, packCardIDs: panelModel.packCards.map(\.id), ctaOperable: ctaOperable,
            hasDetailToggle: hasDetailToggle, hasMasterVolume: false)
    }

    // MARK: - Actions

    /// Resolves the row's present file against the SELECTED pack directory (never trusting
    /// a stale path) and plays it — the real playback wiring `EventRowView`'s `onPreview`
    /// seam has always awaited (its own doc comment: "the caller...owns turning this into
    /// an actual playback call").
    /// 试听这一行的声音。
    ///
    /// `else` 分支**不是**空的（本轮 /ship 评审：Claude 对抗子代理）。走到这里说明 `row.coverage` 还是
    /// `.present`——那是上一次 ``panelModel.reload()`` 时算出来的——但文件此刻已经解析不出来了：用户在
    /// 这中间把它删了 / 改名了 / 换成了一个目录。原来的 `else { return }` 让「点了试听、什么都没发生、
    /// 也没有任何解释」成为可能，而这正是这一轮刚在 `switchPack` / 静音 / 绑定三处修掉的那种静默吞错。
    ///
    /// 修法不是弹一个错误框，而是**让面板说实话**：重跑 ``panelModel.reload()``，这一行会自己从
    /// `.present` 变成 `.broken`（「文件丢失」+ 进 doctor）。用户点下去看到的是行的状态当场改变——那比
    /// 任何一句提示都更接近「不回头也知道状态」。
    private func playPreview(for row: EventRow) {
        guard case .present(let fileName) = row.coverage,
            let packDirectory = resolvePackDirectory(
                id: panelModel.config.selectedPack, userPacksDirectory: audioEnvironment.userPacksDirectory,
                bundledPacksDirectory: audioEnvironment.bundledPacksDirectory),
            let resolvedFile = safePackFileURL(fileName, in: packDirectory),
            regularFileExists(at: resolvedFile)
        else {
            panelModel.reload()
            return
        }
        previewPlayer.play(fileAt: resolvedFile)
    }

    // toggleMute / switchPack / reload / reloadEnabledFlags 已搬进 `ClaudioGUICore.PanelConfigController`
    // （红队 9cccc9c 兑现台账那条 P2）。理由见那个类的文档：这几段逻辑住在测不到的 View 里时，
    // 红队实测三条「改坏行为、两套测试全绿」的变异（refresh 不重载 configState / 某条路由 case 成
    // 死代码 / 静音去掉取反）；搬进可实例化的类后由 `PanelConfigControllerSuite` 用真磁盘各钉一条
    // 行为断言。本视图只经 `panelModel.toggleMute(_:)` / `.switchPack(to:)` / `.reload()` 调它们。
}
