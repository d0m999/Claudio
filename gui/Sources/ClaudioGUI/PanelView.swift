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
        // API surface), constructed here rather than taken as a public, overridable
        // parameter — this panel is the only production owner of a preview player.
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
            settingsLockFile: ClaudioPaths.settingsLockFile,
            // 必须是 `audioEnvironment.packsLockFile`，**不是** `ClaudioPaths.packsLockFile`。
            //
            // manifest.json 有**两个**写者：这条接管链（→ `SetupEnvironment` → 发布内置包）与
            // `ManifestBinding` 的绑定/解绑（走 `audioEnvironment`）。上面 `userPacksDirectory:`
            // 那一行已经把两者指向同一个包目录；这一行是把两者的**互斥**焊在同一个源上的唯一
            // 结构链接。两边各自去取 `ClaudioPaths.packsLockFile` 也能在**今天**碰巧相等，但那
            // 是「两个独立默认值恰好收敛」，不是「同一个源」—— 谁改了 `audioEnvironment` 那一侧
            // （它是 `var`），两个写者当场分家，而 manifest.json 的读-改-写照旧并发。
            //
            // 漏掉这一行的代价（本行存在之前的真实状态，不是假想）：`packsLockFile` 有默认实参，
            // 于是**静默**落回 `ClaudioPaths.packsLockFile`，编译器一个字都不说。
            packsLockFile: audioEnvironment.packsLockFile)
        // 全部构造成**纯 local 实例**，再各自 wrap 进 `@StateObject` / `@State`，**并把同一实例**交给
        // `PanelConfigController`。绝不在这里读 `_someStateObject.wrappedValue` —— 那会在 SwiftUI 装好
        // state 之前重新求值 autoclosure、每次发一个全新实例（见上面 actionRunner 那段同样的坑）。捕获
        // local 不碰这个陷阱：`ovm` / `perRow` 就是被 wrap 的那几个引用，`panelModel` 的
        // `afterFullReload` 闭包捕获它们，跨-view-model 协调因此打到的是面板真正在渲染的那几个实例。
        let onboardingViewModel = OnboardingViewModel(
            environment: onboardingEnvironment,
            actionRunner: DiskOnboardingActionRunner(environment: actionEnvironment))

        let loadedConfig = loadPanelConfig(from: configFile).resolvedConfig
        // Built fully, as a `let`, BEFORE `panelModel` below — never mutated afterward. Earlier
        // this dict was a `var` populated by a loop AFTER `panelModel`'s `afterFullReload`
        // closure had already captured it (relying on "a `var` local captured by an escaping
        // closure is captured by reference, so mutating it later is safe" — true, but Swift's
        // Sendable-closure-capture diagnostic flags exactly that shape: "'perRow' mutated after
        // capture by sendable closure"). Building it complete up front removes the capture-then-
        // mutate shape entirely — same instances, same closures, zero behavior change, no warning.
        let perRow: [Event: EventRowImportViewModel] = Dictionary(
            uniqueKeysWithValues: Event.allCases.map { event in
                (
                    event,
                    EventRowImportViewModel(
                        event: event,
                        importViewModel: AudioImportViewModel(
                            packID: loadedConfig.selectedPack, environment: audioEnvironment))
                )
            })

        // config 读模型 + 静音/切包写路径的**全部行为**都住在这个可测的类里。`afterFullReload` 是全量
        // reload 里 config 读模型**之外**的那一半：onboarding 重探 + 每行 import view-model retarget 到
        // 新包 —— 与旧 `refresh()` 逐行等价（onboarding 那行挪到 config 重载之后，两者互不依赖，结果不变；
        // retarget 收到刚重载出的 config，用它的 `selectedPack`，与旧代码一致）。
        let panelModel = PanelConfigController(
            configFile: configFile,
            lockFile: lockFile,
            environment: audioEnvironment,
            afterFullReload: { reloadedConfig in
                onboardingViewModel.refresh()
                for rowViewModel in perRow.values {
                    rowViewModel.retarget(to: reloadedConfig.selectedPack)
                }
            })

        // `previewPlayer` (`self`'s own, assigned above) copied into a local so the escaping
        // `onImportSucceeded` closures below never need to capture `self` — a struct's `init`
        // may freely READ an already-assigned stored property, but an ESCAPING closure built
        // inside `init` capturing `self` itself is illegal until every stored property is set
        // (several of this type's `@StateObject`s below aren't yet).
        //
        // Wired in a SEPARATE loop, after `panelModel` exists — PLAN-SOUND-MANAGER.md T2
        // (核心回归 #3): re-wires the row-end auto-preview hook `AudioDropZoneView.onImportSucceeded`
        // used to drive before T1 deleted that view along with its only production caller —
        // `AudioPreviewPlayer.swift`'s own doc comment names this exact call site as where it was
        // slated to come back. Fires for BOTH a menu-driven pick (``EventRowView/openImportPanel()``)
        // and a drag-drop onto the file-name `Menu` (``EventRowView/handleDrop(_:)``): both funnel
        // through ``EventRowImportViewModel/handleDrop(sourceURL:suggestedFileName:)`` →
        // ``AudioImportViewModel/handleDrop(requests:)``, whose `.success` arm already calls this
        // hook (see that function's own doc comment). Reads the panel's CURRENT master volume at
        // the moment playback actually starts (`panelModel.config`, always the just-reloaded
        // truth, never a value captured once at init) — the exact same volume ``playPreview(for:)``
        // resolves for the row's manual 试听 ▶ button (``previewVolume(for:)``, the one clamp this
        // repo has). Mutating each row's `importViewModel.onImportSucceeded` — a stored property on
        // a reference type — here, after `perRow` is already built, never re-triggers the
        // capture-then-mutate warning `perRow` itself was rewritten to avoid.
        let previewPlayer = self.previewPlayer
        for rowViewModel in perRow.values {
            let importViewModel = rowViewModel.importViewModel
            importViewModel.onImportSucceeded = { [weak panelModel] file in
                guard let panelModel else { return }
                previewPlayer.play(
                    fileAt: file.destinationURL, volume: Float(previewVolume(for: panelModel.config)))
            }
        }

        _onboardingViewModel = StateObject(wrappedValue: onboardingViewModel)
        _announcer = StateObject(wrappedValue: PanelAnnouncer())
        _rowImportViewModels = State(initialValue: perRow)
        _panelModel = StateObject(wrappedValue: panelModel)
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

    /// 唯一实现住在 ``PanelHeader``（`PanelRows.swift`）—— 此前这里与 `OnboardingView.header` 是两份
    /// 逐字重复的副本，且两份对同一颗绿点的 a11y 处理正好相反（一份 hidden、一份配了一句**从来没有
    /// 人听到过**的 label）。见 ``PanelHeader`` 的文档。
    private var header: some View {
        PanelHeader(
            showsTakenOverDot: onboardingViewModel.state.showsHeaderTakenOverDot,
            accessibilityLabel: headerAccessibilityLabel)
    }

    private var headerAccessibilityLabel: String {
        guard onboardingViewModel.state == .installed else { return PanelHeader.baseLabel }
        let packName = panelModel.packCards.first(where: \.isSelected)?.name ?? panelModel.config.selectedPack
        return "\(PanelHeader.baseLabel)，当前声音包 \(packName)"
    }

    // MARK: - Operational panel (installed state)

    @ViewBuilder
    private var operationalPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            // D23 定稿④：路由到已经存在的自救路径，零新机制。`configState.topContent` 决定这一块顶部
            // 内容显示什么——`.events`（= `.operational`）是今天这四行事件覆盖度 + 主音量滑块；`.needsPack`
            //（还没有人选过包）换成画廊空态「先选包」，`PackGalleryView` 本身仍然照常渲染在下面（自救路径
            // 本来就通：点一张卡就是 ``selectPack``，会建出一份正确的 config）；`.configFailure`（=
            // `.malformed`/`.unwritable`）换成诚实失败态 + 可执行的修复指令——不禁用任何控件（写者本来就
            // 全部 fail closed），只是不再假装一切正常（D19 已作废：不是禁用一个滑块，是整个面板换一个诚实的态）。
            //
            // 这里 switch 的是 `.topContent`（`PanelConfigState.topContent`，映射由 `PanelConfigSuite` 真行为
            // 单测钉死），不是裸 `configState`——`applyFirstFocus` 的 `hasMasterVolume`/`hasConfigFailureNotice`
            // 读**同一个**分类，渲染判据与焦点判据从此在**决策级**一致（不再各写一份 `switch configState`），
            // 决策级漂移由类型堵死。但**呈现级**的 render 映射仍是手写：这个 switch 里 case→哪个子视图 没有
            // import 单测钉（塞错子视图、两颗投影仍全绿），要 ViewInspector/XCTest 才挡得住、本机没有——ViewWiringSuite
            // 只文本探针它「还在」（残余呈现级洞见 TODOS.md「render 映射仍是手写 switch」）
            //（/codex review f54d335 P1#1，取代 26bba37 那轮「两段 switch + 文本绊线防漂移」的设计）。
            switch panelModel.configState.topContent {
            case .events:
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
                            onImportCompleted: { panelModel.reload() },
                            // T2: the SAME reasoning as `onImportCompleted` above, for the
                            // menu's 「清除绑定」item — `EventRowImportViewModel.clearBinding()`
                            // writes `manifest.json` directly, and the row needs the exact same
                            // recompute-now nudge or it keeps showing its pre-clear state.
                            onBindingCleared: { panelModel.reload() }
                        )
                    }
                }
                // PLAN-MASTER-VOLUME.md 阶段 D：位置对齐线框——四行事件之后、拖入区之前。只在
                // `.events`（= `.operational`）渲染（D23 定稿 + D41：这是滑块唯一真的出现在屏幕上的态）。
                // `applyFirstFocus()` 的 `hasMasterVolume: isOperational` 从**同一个** `.topContent` 分类派生
                //（`isOperational = (content == .events)`），所以渲染判据与焦点判据自动一致——「不在屏幕上的
                // 控件不得占用焦点位」这条铁律由类型担保，不再靠两处手动同步。
                //
                // `setMasterVolume` 的完整行为（写、republish 错误、按结果路由刷新）整段住在
                // `panelModel` 里（`PanelConfigControllerSuite` 用真磁盘钉死）——这里只转发。
                MasterVolumeRow(
                    diskVolume: panelModel.config.masterVolume,
                    onCommit: { panelModel.setMasterVolume($0) },
                    focusCoordinator: focusCoordinator,
                    focusedTarget: $focusedTarget,
                    adaptation: layoutAdaptation)
            case .needsPack:
                needsPackNotice
            case .configFailure(let reason):
                configFailureNotice(reason: reason)
            }
            // 绝不静默吞错（项目规则）—— 静音写回失败、切包失败、主音量写回失败**都**在这里如实
            // 上报，合并成一个有序去重列表（PLAN-MASTER-VOLUME.md Step 5 · D3，`PanelWriteFailures.swift`）：
            // 多条可以同时存在（互不顶替），顺序稳定（静音 → 切包 → 主音量），三个写者撞上同一份
            // `.lockBusy`/`.lockFailed` 文案时只保留一条。`.configMissing` 已经在纯函数内部被滤掉
            // （D43）：那个失败不面向用户——写者据此把 `configState` 重路由到 `.needsPack`，「先选包」
            // 空态卡本身就是解释，再印一遍 description 是重复且从未 QA 过的字符串。
            //
            // `.lockBusy` 仍然要渲染，但**它的成因已经变了**（锁分离，D9）：`setEventEnabled` /
            // `selectPack` / `setMasterVolume` 现在拿 `config.lock`，`claudio play` 拿 `play.lock` ——
            // 两者不再相撞，「每个 Claude Code 事件 spawn 一次 play 就可能吞掉一次点击」那条高频路径
            // **已经没了**。今天 `.lockBusy` 只剩两个真实来源：另一个 config.json 写者（第二个 GUI
            // 实例，或用户手动跑 `claudio use`）—— 低频，但绝不是零。渲染保留（项目铁律：绝不静默
            // 吞错），文案本来就写好在各自的错误枚举里。
            ForEach(
                Array(
                    panelWriteFailures(
                        muteError: panelModel.muteError, packSwitchError: panelModel.packSwitchError,
                        masterVolumeError: panelModel.masterVolumeError
                    ).enumerated()), id: \.offset
            ) { _, message in
                FailureRow(message: message)
            }
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
                ActionNoticeRow(message: notice.message)
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
    ///
    /// 那颗「在访达中显示 config.json」是一颗**真控件**（焦点目标 ``PanelFocusTarget/configReveal``），
    /// 不是装饰：它渲染在面板顶端，是这两态开局键盘/VoiceOver 焦点的落点（/codex review P1，26bba37
    /// follow-up）。渲染它的判据与 `applyFirstFocus` 派生 `hasConfigFailureNotice` 的判据现在是**同一个**
    /// `panelModel.configState.topContent` 分类的 `.configFailure` 分支（单源化 f54d335 P1#1）——渲染 / 焦点
    /// 漂移在类型层就不可能；`ViewWiringSuite` 只需钉「两边都读了这个单源」+ 接线还在。
    private func configFailureNotice(reason: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 2026-07-15 冗余审计的**第六份**手抄拒绝行 —— 审计当时只数到五份，漏了这一处（它藏在
            // `configFailureNotice` 里面，不是一个独立命名的 `xxxRow` 函数，grep 拒绝行的时候没捞到它）。
            // 如实记在这里：一次「我数清了所有副本」的断言，自己也漏了一个。
            FailureRow(message: reason)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([configFile])
            } label: {
                Text("在访达中显示 config.json")
                    .font(.system(size: 11 * typeScale))
            }
            .buttonStyle(.plain)
            .foregroundColor(ClaudioColor.textSecondary(colorScheme))
            .accessibilityHint("在访达中定位 config.json，方便手工修正")
            // 它是这张卡上唯一的 bespoke 修复动作，渲染在面板最顶端 —— 所以它必须在焦点序里，且开局
            // 焦点就落在它上面（`.malformed`/`.unwritable` 时 `applyFirstFocus` 走 `.configReveal`）。
            // /codex review P1（26bba37 follow-up）。
            .focused($focusedTarget, equals: .configReveal)
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
                focusedTarget: $focusedTarget)
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

    // `errorNotice(_:)` 已删（2026-07-15 冗余审计 · A 类修复）—— 它是 DESIGN.md「拒绝行」的六份手抄
    // 副本之一，而它自己的 doc comment 当时写着「**identical to** `AudioDropZoneView` 的 `rejectRow`
    // 与 `EventRowView` 的 `importErrorRow`」，那句话在写下的时候就已经不是真的了（`rejectRow` 的图标
    // 根本没设字号，文字是 11.5 不是 11）。现在这个面板里的每一条失败行都渲染同一个 ``FailureRow``
    // （`PanelRows.swift`）—— 「它们长得一样」从一句需要被守的注释，变成了一个编译期事实。

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
        // D23 定稿④「路由态只做减法」：`operationalPanel` only renders `eventRows` for `.events`
        // (= `.operational`) — `.needsPack`/`.configFailure` show the empty-state/failure card
        // instead (see `operationalPanel`'s `switch panelModel.configState.topContent`). A control
        // that isn't on screen must never claim a slot in the opening-focus order, so this passes
        // an EMPTY row list for every non-`.events` state rather than `eventRows` (which, off
        // `resolvedConfig`'s empty-pack default, would otherwise resolve to four `.unmapped` rows
        // that are never actually rendered).
        //
        // 渲染与焦点读**同一个**分类 `panelModel.configState.topContent`（`PanelConfigState.topContent`，
        // 映射由 `PanelConfigSuite` 真行为单测钉死）：`operationalPanel` 顶部 switch 在它上面，这里也从它派生
        // 两颗 flag。此前这两颗 flag 各自 `switch panelModel.configState` 一遍、与渲染判据靠 ViewWiringSuite
        // 文本绊线防漂移；改读单源后，渲染判据与焦点判据在**决策级**一致，决策级漂移不再可能（呈现级 render 映射
        // 仍是手写 switch、只文本探针封——见 operationalPanel 顶部注释与 TODOS.md）（/codex review f54d335 P1#1）。
        let content = panelModel.configState.topContent
        // 两颗焦点 flag 现在是 `content` 上**单测钉过**的纯投影，applyFirstFocus 只**原样转发**、不在视图里
        // 重新解释——这是把「单源」从**值级**提到**决策级**的关键（/codex review f54d335 P1#1 follow-up：对抗
        // 复核实测，只让 render/focus 读同一个 `content` **值**还不够——视图里 `if case … = content { return
        // true }` 这两颗闭包的**返回值**没有任何测试钉，把 true 翻成 false 就能让失败卡照画、而焦点跳过 Reveal
        // 钮，全绿。把投影上提到 `PanelTopContent.showsEventContent` / `.hasConfigFailureNotice`、由 `PanelConfigSuite`
        // 单测其返回值后，视图这侧再没有可翻转的布尔，只剩一句转发；ViewWiringSuite 钉住这句转发原样还在）。
        // - showsEventContent：滑块 + 四行事件只在 `.events`（= `.operational`）真的在屏幕上，所以它同时决定
        //   `visibleRows`（哪些行真被渲染进焦点序）与 `hasMasterVolume`（滑块此刻在不在屏幕上）。
        // - hasConfigFailureNotice：诚实失败卡（`.configFailure` = `.malformed`/`.unwritable`）带着「在访达中
        //   显示 config.json」这颗真控件，渲染在面板顶端，所以 `.configReveal` 领序、开局焦点落在它上面。
        let visibleRows: [EventRow] = content.showsEventContent ? panelModel.eventRows : []
        focusedTarget = panelOpeningFocus(
            rows: visibleRows, packCardIDs: panelModel.packCards.map(\.id), ctaOperable: ctaOperable,
            hasDetailToggle: hasDetailToggle, hasMasterVolume: content.showsEventContent,
            hasConfigFailureNotice: content.hasConfigFailureNotice)
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
        // D2: 试听 must play at the panel's current master volume, not NSSound's own default
        // of 1.0 — read at the moment of the click (`panelModel.config` is always the
        // just-reloaded truth), not cached anywhere.
        previewPlayer.play(fileAt: resolvedFile, volume: Float(previewVolume(for: panelModel.config)))
    }

    // toggleMute / switchPack / reload / reloadEnabledFlags 已搬进 `ClaudioGUICore.PanelConfigController`
    // （红队 9cccc9c 兑现台账那条 P2）。理由见那个类的文档：这几段逻辑住在测不到的 View 里时，
    // 红队实测三条「改坏行为、两套测试全绿」的变异（refresh 不重载 configState / 某条路由 case 成
    // 死代码 / 静音去掉取反）；搬进可实例化的类后由 `PanelConfigControllerSuite` 用真磁盘各钉一条
    // 行为断言。本视图只经 `panelModel.toggleMute(_:)` / `.switchPack(to:)` / `.reload()` 调它们。
}
