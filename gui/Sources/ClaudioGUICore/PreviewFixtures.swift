import ClaudioCore
import ClaudioLocalization
import Foundation

// This entire catalog is DEBUG-only: its only consumers are the DEBUG-gated state gallery
// (`ClaudioGUI/StateGalleryView.swift`) and the test harness, so it never belongs in a
// Release build — matching the `#if DEBUG` gating on the `previewState` view-model inits it
// renders through. Keeps this preview/test-only sample data off the shipped `ClaudioGUICore`
// public surface entirely rather than relying on the linker to dead-strip it (T14
// swift-review nit).
//
// The harness is NOT "always debug", despite what this comment used to claim: `claudio-gui-tests`
// is an `executableTarget` (this repo has no Xcode, hence no XCTest — see Package.swift), so a
// bare `swift build -c release` builds it too, and it does not compile without these symbols.
// That is why `Package.swift` declares an explicit `ClaudioGUI` product and release.yml builds
// `--product ClaudioGUI`. Verify with BOTH, never just the first:
//     swift run claudio-gui-tests                        # debug: the green signal
//     swift build -c release --product ClaudioGUI        # release: what CI actually ships
#if DEBUG

/// The **single canonical catalog** of concrete sample values for every case of every per-feature
/// state family (ENGINEERING.md T14 D1, plus PLAN-MASTER-VOLUME.md D33/D38's ``MasterVolumeState``):
/// ``OnboardingState``, ``OnboardingActionState``, ``DropZoneState``, ``EventRow``/``CoverageState``,
/// ``PackCard``/``PackCardState``, ``MasterVolumeState``，以及双宿主集成场景。
///
/// 权威清单是 ``assertExhaustive()`` 实际遍历的那几个数组 —— **不是**这段散文里的族数。原文写死了
/// 「all five」，而它在 T17 加进 `OnboardingActionState` 那天就已经数错，阶段 D 又添一族
/// （`/codex review 8771946`）。一个写死的计数总会过期；下面那个函数不会。
///
/// This is the ONE place in the repo that constructs sample state VALUES — both the state
/// gallery (`ClaudioGUI`'s `StateGalleryView`, T14 D2) and, where a test already hard-coded
/// its own sample values, the dependency-free test harness now point HERE instead (T14
/// acceptance criterion 3: "changing an enum reflects in BOTH tests and gallery"). It must
/// live in `ClaudioGUICore` (not a separate module, and not `ClaudioGUI`) for one structural
/// reason: ``ImportedAudioFile``'s memberwise initializer is synthesized `internal` (Swift
/// never synthesizes a `public` memberwise init for a `public` struct, even when every
/// stored property is itself `public` — a well-known gotcha, not an oversight) — only code
/// inside THIS module can construct ``DropZoneState/success(_:)`` at all.
///
/// Pure value construction only — **no disk I/O, no environment/view-model wiring**. Every
/// fixture below is a plain, deterministic literal; nothing here reads `~/.claude` or
/// `~/.claudio`, mirroring every other fixture helper in this codebase
/// (`OnboardingEnvironment`'s own warning about `$HOME` not working on Darwin — this type
/// sidesteps that class of bug entirely by never touching a real path).
///
/// ## Exhaustiveness (T14 acceptance criterion 3, the load-bearing part)
/// None of the five state enums below are `CaseIterable` (each has at least one
/// associated-value case), so there is no compiler-checked "did I fixture every case?" for
/// free. The five `_coverage(_:)` functions at the bottom of this file are hand-written
/// exhaustive `switch`es over EVERY case of ``OnboardingState``, ``DropRejectionReason``
/// (nested one level inside ``DropZoneState``), ``CoverageState``, ``PackCardState``, and
/// ``MasterVolumeState`` — with no `default:` branch anywhere. The instant a new case is added
/// to any of those five enums, EVERY `switch` in THIS repo that already omits `default:` (which
/// includes these five, plus each type's own `OnboardingState.swift`/`DropZoneState.swift`/
/// `CoverageState.swift`/`PackGallery.swift` internals) stops compiling until a matching
/// branch — and, by the convention this file establishes, a fixture — is added. `Package
/// GallerySuite.swift` (T14 D3) additionally pins the RUNTIME shape (how many fixtures,
/// which combinations) so a compiling-but-incomplete fixture array still fails a test.
public enum PreviewFixtures {

    // MARK: - OnboardingState (6 cases, ENGINEERING.md T7)

    /// All six ``OnboardingState`` cases, in the same declaration order as the enum itself.
    /// The two associated-value cases carry representative reason strings shaped like the
    /// real ones ``detectOnboardingState(environment:)`` produces (see
    /// `OnboardingDetectorSuite.swift`), not placeholder text.
    public static let onboardingStates: [OnboardingState] = [
        .claudeCodeNotInstalled,
        .helperMissing,
        .settingsNotWritable(reason: "settings.json 存在但不可写：/Users/demo/.claude/settings.json"),
        .settingsParseFailure(reason: "settings.json 解析失败，已中止（未修改文件）：期望对象，得到数组"),
        .notInstalled,
        .installed,
    ]

    // MARK: - OnboardingActionState (3 cases, ENGINEERING.md T17)

    /// 每一个 ``OnboardingActionState`` case —— CTA 动作本身的状态，与 ``OnboardingState`` **正交**
    /// 的第五族。
    ///
    /// 它必须在这里，否则 T17 引入的两个新视觉态（进行中的 CTA = 禁用按钮 + spinner；失败的 CTA =
    /// 一条拒绝行）**从来不会被任何一帧渲染**，而 ``assertExhaustive()`` 仍然全绿 —— 因为
    /// `onboardingStates` 依然「穷尽」它自己那六个 case。这与 `/ship` 收口记录 ③ 逮到的那次翻车
    /// 是同一类错：真相源自己漏了一维，没人看得见。
    ///
    /// `.failed` 的两份 fixture 刻意一份带 `detail`、一份不带 —— 「查看原因」这个披露入口只在
    /// `detail != nil` 时出现，两条渲染路径都得有人看过。
    public static let onboardingActionStates: [OnboardingActionState] = [
        .idle,
        .running(.takeOver),
        .running(.disconnect),
        .failed(
            action: .takeOver,
            message: "这一步没能完成，claudi0 已经停下、没有留下半成品。看看下面的原因，或者稍后再试一次。",
            detail: "写 settings.json hooks 失败：settings.json 存在但不可写：/Users/demo/.claude/settings.json"),
        .failed(
            action: .takeOver,
            message: "没找到 claudi0 随身带的那个小助手，所以什么都没有改动。请从「应用程序」里打开 claudi0 再试一次。",
            detail: nil),
        // T17f —— 第三个视觉分支：动作**成功了**，但 setup 替用户做了主。三份 fixture 各渲染出不同的
        // 东西（一行搬走 / 一行换包 / 两行叠着），所以是三个 label、三帧。少任何一帧，那个变体就
        // 「从来没有任何人看过」——而这正是本文件存在的全部理由。
        //
        // ⚠️ 文案不是这里写的：它是 `SetupNotice.message` 算出来的，与生产环境**逐字同源**。
        // 在这儿手抄一遍好看的假句子，等于让画廊评审的是一句真机上永远不会出现的话。
        .reported(notices: [
            .salvagedPack(
                packID: "wobbuffet", movedTo: "/Users/demo/.claudio/packs/wobbuffet-已搬走")
        ]),
        .reported(notices: [
            .repairedDeadSelection(removed: "pikachu", selected: "minimal-chime")
        ]),
        .reported(notices: [
            .salvagedPack(
                packID: "wobbuffet", movedTo: "/Users/demo/.claudio/packs/wobbuffet-已搬走"),
            .repairedDeadSelection(removed: "wobbuffet", selected: "minimal-chime"),
        ]),
    ]

    // MARK: - DropZoneState (ENGINEERING.md T8): idle / hover / reject×6 / success

    /// A representative ``ImportedAudioFile`` — the payload ``DropZoneState/success(_:)``
    /// carries. `destinationURL` is a plausible (never-touched) path shape; nothing reads
    /// it.
    public static let sampleImportedAudioFile = ImportedAudioFile(
        packID: "minimal-chime",
        destinationURL: URL(fileURLWithPath: "/Users/demo/.claudio/packs/minimal-chime/stop.mp3"),
        fileName: "stop.mp3",
        format: .mp3,
        fileSizeBytes: 214_016,
        duration: 1.2
    )

    /// `.idle`, `.hover`, `.success`, and one `.reject` for EACH of ``DropRejectionReason``'s
    /// eight cases (eleven fixtures total) — every ``DropZoneState`` case, and every reason a
    /// `.reject` can carry, appears at least once.
    public static let dropZoneStates: [DropZoneState] = [
        .idle,
        .hover,
        .reject(.oversize(actualBytes: 8_400_000, maxBytes: 5 * 1024 * 1024)),
        .reject(.nonWhitelistFormat),
        .reject(.pathTraversal),
        .reject(.overDuration(actualSeconds: 6.4, maxSeconds: 3.0)),
        .reject(.builtinReadOnly(packID: "minimal-chime")),
        .reject(.copyFailed(reason: "磁盘已满")),
        .reject(.lockBusy),
        .reject(.lockFailed(errno: 5)),
        .success(sampleImportedAudioFile),
    ]

    // MARK: - EventRow / CoverageState (ENGINEERING.md T16 D2, DESIGN.md "事件行三态")

    /// Every ``CoverageState`` case × `enabled` (true/false) — six rows — AND every ``Event``,
    /// on both axes at once: the five events are ROTATED across the six coverage×enabled
    /// combinations (in ``Event/allCases`` declaration order), so the combination grid stays
    /// exhaustive while no event is left un-rendered.
    ///
    /// The event axis is load-bearing, not decoration (T14 review 修复①): this catalog is the
    /// repo's ONLY exhaustive visual truth source, and an event that never appears in it has
    /// its display name, its glyph, and its ``ClaudioColor/event(_:_:)`` tile color rendered
    /// exactly zero times — nobody has ever LOOKED at it. That is precisely how `night_dim`
    /// drifted before. `SubagentStop`'s indigo was missing here until this fix.
    ///
    /// Each row's event is visible in FULL color regardless of `enabled`/coverage
    /// (`EventRowView`'s `glyphTile` never dims — DESIGN.md 硬约束 "不整行降 opacity"), so one
    /// appearance per event is genuinely enough to see its true color; the rotation doesn't
    /// need to also pair every event with every coverage state.
    ///
    /// ``PreviewFixturesSuite`` pins BOTH axes at runtime: the six coverage×enabled
    /// combinations, and `Set(eventRows.map(\.event)) == Set(Event.allCases)` — the latter
    /// driven straight off ``Event``'s compiler-synthesized `allCases`, so adding a fifth
    /// event turns that check red without anyone having to remember to update a hand-written
    /// list.
    public static let eventRows: [EventRow] = [
        EventRow(
            event: .taskStart, coverage: .present(fileName: "task-start.mp3"), enabled: true),
        EventRow(
            event: .stop, coverage: .present(fileName: "stop.mp3"), enabled: false),
        EventRow(event: .stopFailure, coverage: .unmapped, enabled: true),
        EventRow(event: .notification, coverage: .unmapped, enabled: false),
        EventRow(
            event: .subagentStop, coverage: .broken(fileName: "subagent-stop.mp3"), enabled: true),
        EventRow(event: .notification, coverage: .broken(fileName: "ping.mp3"), enabled: false),
    ]

    // MARK: - PackCard / PackCardState (ENGINEERING.md T15 D3)

    /// Every ``PackCardState`` case × `isSelected` (true/false) — six cards.
    ///
    /// The `presentEvents` sets carry a SECOND exhaustiveness obligation, for the same reason
    /// ``eventRows`` does (T14 review 修复①): the row's 5-slot coverage track
    /// (``PackGalleryView``, T4) renders ``Event/allCases`` for every card whose
    /// ``packRowTrailingSlot(for:)`` resolves to `.track`, styling each slot present-or-absent.
    /// So the fixtures whose state is `.complete`/`.partial` (the ones that actually reach a
    /// track) must show each of the five events in BOTH styles among THEMSELVES — the two
    /// `.broken` cards' `presentEvents == []` does NOT count toward this anymore (T4: a broken
    /// row renders a status row instead of a track, so its `presentEvents` is never turned into
    /// an actual absent-styled slot anywhere in the gallery — counting it here would be exactly
    /// the "asserted against data nobody renders" bug this file exists to prevent). The
    /// `.complete` cards (`presentEvents == Set(Event.allCases)`) supply all five PRESENT
    /// slots; the two `.partial` cards' present sets are chosen so their absent sets' UNION is
    /// all five events. ``PreviewFixturesSuite`` pins both halves, scoped to the `.track`-
    /// resolving cards, off ``Event/allCases`` directly.
    public static let packCards: [PackCard] = [
        PackCard(
            id: "minimal-chime", name: "极简铃", isCC0: true, presentEvents: Set(Event.allCases),
            state: .complete, isSelected: true),
        PackCard(
            id: "sunny-chime", name: "晴朗铃", isCC0: true, presentEvents: Set(Event.allCases),
            state: .complete, isSelected: false),
        PackCard(
            id: "half-pack", name: "半成品", isCC0: false,
            presentEvents: [.taskStart, .stop, .notification],
            state: .partial(present: 3, total: 5), isSelected: true),
        // `one-event-pack` 刻意只让 `.subagentStop` 在场：其缺失集
        // {taskStart, stop, stopFailure, notification} 与 `half-pack` 的缺失集
        // {stopFailure, subagentStop} 取并集，五个事件的「缺」才恰好全部覆盖到。
        // 两个都缺的正是 `stopFailure`/`subagentStop`，若这里仍选 `.stop` 在场，`.stop` 就永远
        // 不会在任何一张会画轨的卡片上以「缺失格」样式出现过。
        PackCard(
            id: "one-event-pack", name: "缺四个", isCC0: false, presentEvents: [.subagentStop],
            state: .partial(present: 1, total: 5), isSelected: false),
        PackCard(
            id: "ghost-pack", name: nil, isCC0: false, presentEvents: [],
            state: .broken(reason: "声音包目录未找到"), isSelected: true),
        PackCard(
            id: "corrupt-pack", name: nil, isCC0: false, presentEvents: [],
            state: .broken(reason: "manifest.json 解析失败"), isSelected: false),
    ]

    // MARK: - Product UI refactor states

    /// 主面板包区域的五个互斥状态，另加固定包 1 行/4 行两种真实密度。
    public static let panelPackSectionStates: [PanelPackSectionState] = [
        .loading,
        .pinned([packCards[0]]),
        .pinned(Array(packCards.prefix(maxStarredPacks))),
        .noPinnedPacks(availablePackCount: 6),
        .noPacks,
        .readFailed(reason: "声音包目录暂时无法读取，请检查权限。"),
    ]

    /// Claudio 专属界面文字的全部四档；gallery 用同一个动态字号映射渲染代表内容。
    public static let interfaceTextSizes = ClaudioInterfaceTextSize.allCases

    // MARK: - MasterVolumeState (PLAN-MASTER-VOLUME.md 阶段 D, D33/D38/D39)
    //
    // 主音量控件行在 state gallery 里的展示态。**这不是生产代码里一个真实存在的状态机**——生产端
    // `MasterVolumeRow` 显示什么是两个独立事实的组合（`VolumeDragSession.draft` 当前的值 + 若有，
    // `PanelConfigController.masterVolumeError` 那条写失败），从未被合并成一个真实类型。这个 enum
    // 只是给 gallery 一个可以逐帧枚举的手柄，与其它四族「照抄生产类型」的做法不同，理由见下。
    //
    // D38：范围只到这一族的六帧（含至少一条「行 + 错误行」组合帧，D39）——D23 定稿的三个路由态
    // （`.needsPack`/`.malformed`/`.unwritable`）不进 gallery（那三态根本不渲染 `MasterVolumeRow`，
    // 走真机走查 ⑫⑬ 兜底，见 `TODOS.md` 登记的 `PanelRouteState` 族 P3）。

    /// 六帧要覆盖的两个「形状」：滑块单独显示一个值，或者滑块回滚之后贴着一条错误行（D12 的瞬跳 +
    /// D39 的组合帧）。
    public enum MasterVolumeState: Sendable, Equatable {
        /// 滑块显示 `volume`，没有错误行。
        case value(Double)
        /// 一次写盘失败之后（D12：draft 已经瞬跳回磁盘上的 `volume`），下方贴着一条错误行 `message`
        /// （D39：`.writeFailed` 归 `PanelView` 渲染，`MasterVolumeRow` 自身零错误 UI）。
        case failed(volume: Double, message: String)
    }

    /// D16：音量 0 是合法值（总输出无声），不是"禁用"或"错误"——它必须有自己的一帧，不能被折进
    /// 「随便一个值」里悄悄消失。0.35 是 21 档网格上的一个中间值（D45「干净渲染」那一类的代表）。
    /// 两条 `.failed` 帧的文案直接取自 `SetMasterVolumeError.description`（真实文案，不是在这里
    /// 手抄一遍好看的假句子——见 `onboardingActionStates` 头部同一条纪律）：一条是高频常态的锁竞争，
    /// 一条是 D12 走查项 ⑧ 的真实场景（目录只读）。
    public static let masterVolumeStates: [MasterVolumeState] = [
        .value(0.0),
        .value(0.35),
        .value(ClaudioConfig.defaultMasterVolume),
        .value(1.0),
        .failed(volume: 0.8, message: SetMasterVolumeError.lockBusy.description),
        .failed(
            volume: 0.35,
            message: SetMasterVolumeError.configWriteFailure(
                reason: "~/.claudio 目录不可写，请检查权限后重试"
            ).description),
    ]

    // MARK: - Host integrations (Claude Code + Codex)

    /// 双宿主状态展柜的一帧。`state` 同时携带宿主快照与 Core 合成的可听矩阵，
    /// 因此宿主卡、矩阵格和检查器不会在预览中分裂成三套事实。
    public struct HostIntegrationScenario: Identifiable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let state: HostIntegrationPresentationState

        public init(
            id: String,
            title: String,
            state: HostIntegrationPresentationState
        ) {
            self.id = id
            self.title = title
            self.state = state
        }
    }

    /// 双宿主产品态的最小验收名册。每帧都通过 ``hostIntegrationScenario`` 调用
    /// ``HostCapabilityCatalog`` + ``AudibilityMatrix.make`` 构建；这里不允许手写
    /// ``AudibilityCell``，因此删除 Codex 映射会直接改变展柜里的真实格子。
    public static let hostIntegrationScenarios: [HostIntegrationScenario] = [
        hostIntegrationScenario(
            id: "dual-disconnected",
            title: "双宿主未连接",
            snapshots: HostID.allCases.map { HostIntegrationSnapshot.disconnected(host: $0) }),
        hostIntegrationScenario(
            id: "claude-only",
            title: "仅 Claude Code 已连接",
            snapshots: [
                hostIntegrationSnapshot(host: .claudeCode),
                .disconnected(host: .codex),
            ]),
        hostIntegrationScenario(
            id: "codex-only",
            title: "仅 Codex 已连接",
            snapshots: [
                .disconnected(host: .claudeCode),
                hostIntegrationSnapshot(host: .codex),
            ]),
        hostIntegrationScenario(
            id: "dual-connected",
            title: "双宿主已连接",
            snapshots: HostID.allCases.map { hostIntegrationSnapshot(host: $0) }),
        hostIntegrationScenario(
            id: "codex-awaiting",
            title: "claudi0 已写好，等待 Codex 确认",
            snapshots: [
                hostIntegrationSnapshot(host: .claudeCode),
                hostIntegrationSnapshot(
                    host: .codex,
                    activation: .awaitingReceipt(installationID: hostIntegrationInstallationID)),
            ]),
        hostIntegrationScenario(
            id: "claude-legacy",
            title: "Claude Code 旧版连接，可升级",
            snapshots: [
                hostIntegrationSnapshot(
                    host: .claudeCode,
                    configuration: .legacyConnected,
                    activation: HostActivationEvidence.none),
                hostIntegrationSnapshot(host: .codex),
            ]),
        hostIntegrationScenario(
            id: "codex-normal-4-of-5",
            title: "Codex 正常 4/5",
            snapshots: [
                .disconnected(host: .claudeCode),
                hostIntegrationSnapshot(host: .codex),
            ]),
        hostIntegrationScenario(
            id: "partial-single-degraded",
            title: "Claude Code 缺少一个 hook，Codex 仍可用",
            snapshots: [
                hostIntegrationSnapshot(
                    host: .claudeCode,
                    configuration: .incomplete(missingNativeEvents: ["StopFailure"]),
                    activation: HostActivationEvidence.none),
                hostIntegrationSnapshot(host: .codex),
            ]),
        hostIntegrationScenario(
            id: "shared-runtime-failure",
            title: "共享 helper 损坏",
            snapshots: HostID.allCases.map {
                hostIntegrationSnapshot(
                    host: $0,
                    runtime: .damaged(reason: "claudi0 helper 损坏"))
            }),
        hostIntegrationScenario(
            id: "single-side-connection-failure",
            title: "Claude Code 连接失败，Codex 仍可用",
            snapshots: [
                hostIntegrationSnapshot(
                    host: .claudeCode,
                    configuration: .conflict(reason: "连接失败：配置已被外部修改"),
                    activation: HostActivationEvidence.none,
                    operation: .failed(reason: "配置已被外部修改")),
                hostIntegrationSnapshot(host: .codex),
            ]),
    ]

    /// 菜单栏事件行宿主 Logo 的五个视觉事实态。每帧复用上面的真实双宿主矩阵，并明确携带
    /// 标准或窄版布局；Gallery 不在 View 里手写任一状态或宿主能力。
    public struct EventHostIndicatorScenario: Identifiable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let row: EventRow
        public let state: HostIntegrationPresentationState
        public let adaptation: PanelLayoutAdaptation

        public init(
            id: String,
            title: String,
            row: EventRow,
            state: HostIntegrationPresentationState,
            adaptation: PanelLayoutAdaptation
        ) {
            self.id = id
            self.title = title
            self.row = row
            self.state = state
            self.adaptation = adaptation
        }
    }

    public static let eventHostIndicatorScenarios: [EventHostIndicatorScenario] = [
        eventHostIndicatorScenario(
            id: "full-color",
            title: "双宿主已连接 · 标签 Logo 12pt",
            event: .stop,
            sourceScenarioID: "dual-connected",
            tier: .standard),
        eventHostIndicatorScenario(
            id: "mixed",
            title: "Claude 可用 · Codex 此事件不支持",
            event: .stopFailure,
            sourceScenarioID: "dual-connected",
            tier: .standard),
        eventHostIndicatorScenario(
            id: "all-gray",
            title: "双宿主未连接",
            event: .stop,
            sourceScenarioID: "dual-disconnected",
            tier: .standard),
        eventHostIndicatorScenario(
            id: "legacy",
            title: "Claude Code 旧版连接",
            event: .stop,
            sourceScenarioID: "claude-legacy",
            tier: .standard),
        eventHostIndicatorScenario(
            id: "awaiting-narrow",
            title: "Codex 待激活 · 较大字号 · 标签 Logo 12pt",
            event: .notification,
            sourceScenarioID: "codex-awaiting",
            tier: .largest),
    ]

    /// One production event-row sample inside the C-layout locale/type-size gallery. Each sample
    /// carries the same composed host state production consumes, so disconnected/degraded chips
    /// cannot be mocked independently from the capability matrix.
    public struct EventRowLayoutSample: Identifiable, Sendable, Equatable {
        public var id: Event { row.event }
        public let row: EventRow
        public let state: HostIntegrationPresentationState

        public init(row: EventRow, state: HostIntegrationPresentationState) {
            self.row = row
            self.state = state
        }
    }

    /// One language × interface-text-size frame. Every frame deliberately mixes all three
    /// `CoverageState` shapes in one panel; across the eight frames this gives the visual truth
    /// source the complete 2 languages × 4 sizes × 3 mapping states grid.
    public struct EventRowLayoutScenario: Identifiable, Sendable, Equatable {
        public let id: String
        public let language: ClaudioAppLanguage
        public let interfaceTextSize: ClaudioInterfaceTextSize
        public let samples: [EventRowLayoutSample]
        public let adaptation: PanelLayoutAdaptation

        public init(
            id: String,
            language: ClaudioAppLanguage,
            interfaceTextSize: ClaudioInterfaceTextSize,
            samples: [EventRowLayoutSample],
            adaptation: PanelLayoutAdaptation
        ) {
            self.id = id
            self.language = language
            self.interfaceTextSize = interfaceTextSize
            self.samples = samples
            self.adaptation = adaptation
        }
    }

    public static let eventRowLayoutScenarios: [EventRowLayoutScenario] =
        ClaudioAppLanguage.allCases.flatMap { language in
            interfaceTextSizes.map { interfaceTextSize in
                eventRowLayoutScenario(
                    language: language,
                    interfaceTextSize: interfaceTextSize)
            }
        }

    private static let hostIntegrationInstallationID = UUID(
        uuidString: "00000000-0000-4000-8000-0000000000C1")!

    private static func hostIntegrationSnapshot(
        host: HostID,
        runtime: SharedRuntimeHealth = .ready,
        configuration: HostConfigurationState = .configured,
        activation: HostActivationEvidence? = nil,
        operation: HostOperationState = .idle
    ) -> HostIntegrationSnapshot {
        let binding = HostCapabilityCatalog.bindings(for: host)
            .first(where: \.isAudibleCapability)!
        let resolvedActivation = activation ?? .observed(
            HostReceiptEvidence(
                installationID: hostIntegrationInstallationID,
                nativeEvent: binding.nativeEvent!,
                event: binding.event,
                timestamp: Date(timeIntervalSince1970: 1_721_980_800),
                playbackResult: .played))
        return HostIntegrationSnapshot(
            host: host,
            runtime: runtime,
            availability: .available,
            configuration: configuration,
            writability: .writable,
            activation: resolvedActivation,
            operation: operation,
            installationID: configuration == .notConfigured
                ? nil : hostIntegrationInstallationID)
    }

    private static func hostIntegrationScenario(
        id: String,
        title: String,
        snapshots: [HostIntegrationSnapshot]
    ) -> HostIntegrationScenario {
        let capabilities = Dictionary(
            uniqueKeysWithValues: HostID.allCases.map {
                ($0, HostCapabilityCatalog.bindings(for: $0))
            })
        let matrix = AudibilityMatrix.make(
            snapshots: snapshots,
            capabilities: capabilities,
            soundCoverage: Dictionary(
                uniqueKeysWithValues: Event.allCases.map { ($0, true) }),
            enabledEvents: Dictionary(
                uniqueKeysWithValues: Event.allCases.map { ($0, true) }))
        return HostIntegrationScenario(
            id: id,
            title: title,
            state: HostIntegrationPresentationState(
                snapshots: snapshots,
                matrix: matrix))
    }

    private static func eventHostIndicatorScenario(
        id: String,
        title: String,
        event: Event,
        sourceScenarioID: String,
        tier: PanelTypeSizeTier
    ) -> EventHostIndicatorScenario {
        guard let source = hostIntegrationScenarios.first(where: { $0.id == sourceScenarioID })
        else {
            preconditionFailure("missing host integration fixture: \(sourceScenarioID)")
        }
        return EventHostIndicatorScenario(
            id: id,
            title: title,
            row: EventRow(
                event: event,
                coverage: .present(fileName: "\(event.cliName).mp3"),
                enabled: true),
            state: source.state,
            adaptation: panelLayoutAdaptation(for: tier))
    }

    private static func eventRowLayoutScenario(
        language: ClaudioAppLanguage,
        interfaceTextSize: ClaudioInterfaceTextSize
    ) -> EventRowLayoutScenario {
        func state(_ scenarioID: String) -> HostIntegrationPresentationState {
            guard let source = hostIntegrationScenarios.first(where: { $0.id == scenarioID })
            else {
                preconditionFailure("missing host integration fixture: \(scenarioID)")
            }
            return source.state
        }

        return EventRowLayoutScenario(
            id: "\(language.rawValue)-\(interfaceTextSize.rawValue)",
            language: language,
            interfaceTextSize: interfaceTextSize,
            samples: [
                // Longest current English event title; production has enough room for its full
                // two-line rendering at every tier rather than truncating it with an ellipsis.
                EventRowLayoutSample(
                    row: EventRow(
                        event: .stopFailure,
                        coverage: .present(fileName: "execution-interrupted.mp3"),
                        enabled: true),
                    state: state("dual-connected")),
                EventRowLayoutSample(
                    row: EventRow(event: .notification, coverage: .unmapped, enabled: true),
                    state: state("dual-disconnected")),
                EventRowLayoutSample(
                    row: EventRow(
                        event: .subagentStop,
                        coverage: .broken(fileName: "subagent-stop.mp3"),
                        enabled: false),
                    state: state("single-side-connection-failure")),
            ],
            adaptation: panelLayoutAdaptation(
                for: panelTypeSizeTier(for: interfaceTextSize)))
    }

    // MARK: - Compile-time exhaustiveness guards

    /// Runs every `_coverage(_:)` guard below against its matching fixture array and RETURNS
    /// the set of `family.case` labels those guards actually visited — e.g.
    /// `"onboarding.installed"`, `"dropZone.reject.oversize"`, `"coverage.broken"`,
    /// `"packCard.partial"`. Labels are family-qualified because the bare ones collide
    /// (`broken` belongs to both ``CoverageState`` and ``PackCardState``).
    ///
    /// It RETURNS a value rather than merely running (T14 review 修复②): the previous
    /// `-> Void` version could only ever be "tested" by calling it and asserting `true`, a
    /// tautology that could never fail while still occupying a line in the check count. The
    /// returned set is a real, falsifiable observation of WHICH cases the shipped fixtures
    /// exercise, so ``PreviewFixturesSuite`` can compare it against the full expected roster and
    /// go RED the moment a fixture array stops covering one of its enum's cases — the compiler's
    /// own exhaustive-`switch` guarantee (a branch EXISTS for every case) never covered that: a
    /// branch nothing ever reaches compiles perfectly.
    ///
    /// Still also serves its original purpose: it keeps every `…Coverage(_:)` `switch` below
    /// demonstrably live code, so a future cleanup can't delete the enforcement mechanism as
    /// unreferenced. (This line used to promise "the four `switch`es below" — there are nine today,
    /// and that count was already wrong before 阶段 D added the ninth. A hard-coded tally in prose
    /// is a claim nobody re-checks; `/codex review 8771946`.)
    public static func assertExhaustive() -> Set<String> {
        var visited: Set<String> = []
        for state in onboardingStates { visited.insert("onboarding.\(onboardingStateCoverage(state))") }
        for state in onboardingActionStates {
            visited.insert("onboardingAction.\(onboardingActionStateCoverage(state))")
        }
        for state in dropZoneStates { visited.insert("dropZone.\(dropZoneStateCoverage(state))") }
        for row in eventRows { visited.insert("coverage.\(coverageStateCoverage(row.coverage))") }
        for card in packCards { visited.insert("packCard.\(packCardStateCoverage(card.state))") }
        for state in panelPackSectionStates {
            visited.insert("panelPack.\(panelPackSectionStateCoverage(state))")
        }
        for size in interfaceTextSizes {
            visited.insert("interfaceText.\(interfaceTextSizeCoverage(size))")
        }
        for state in masterVolumeStates { visited.insert("masterVolume.\(masterVolumeStateCoverage(state))") }
        for scenario in hostIntegrationScenarios {
            visited.insert("hostIntegration.\(scenario.id)")
        }
        for scenario in eventHostIndicatorScenarios {
            visited.insert("eventHostIndicator.\(scenario.id)")
        }
        for scenario in eventRowLayoutScenarios {
            visited.insert("eventRowLayout.\(scenario.id)")
        }
        return visited
    }

    /// Exhaustive over every ``OnboardingActionState`` case — no `default:` — recursing into
    /// ``OnboardingDiskAction`` for `.running` so both enums are guarded by one function
    /// (mirrors ``dropZoneStateCoverage(_:)``'s treatment of ``DropRejectionReason``).
    /// `.failed` splits on whether it carries a `detail`, because those are two DIFFERENT
    /// renders: only the `detail != nil` one grows a 「查看原因」 disclosure.
    static func onboardingActionStateCoverage(_ state: OnboardingActionState) -> String {
        switch state {
        case .idle: "idle"
        case .running(let action): "running.\(onboardingDiskActionCoverage(action))"
        case .failed(_, _, let detail): detail == nil ? "failed.noDetail" : "failed.withDetail"
        // `.reported` 按**内容**分标签，不是笼统一个 "reported"（T17f）。这正是本文件头部那条警告
        // 在说的事：label 是 `assertExhaustive()` 能看见的**唯一**投影，任何没编进这个字符串的
        // payload 维度，对穷尽性检查都是隐形的。三个变体渲染出三种不同的东西（一行搬走 / 一行换包 /
        // 两行叠着），塌成一个 label 就等于「有两种没人看过」——而它们全都塌在同一个 `Set` 里。
        // 递归进 ``setupNoticeCoverage(_:)``，于是将来加第三种告知同样是**编译错误**。
        case .reported(let notices):
            "reported."
                + (notices.count > 1
                    ? "multiple"
                    // 恒非空（``onboardingActionState(afterSuccess:)`` 是唯一构造入口，
                    // `OnboardingActionsSuite` 钉死）。`?? "empty"` 不是兜底，是**绊线**：
                    // 它一旦出现在 label 集合里，就说明那条不变式被绕过去了，roster 当场变红。
                    : (notices.first.map(setupNoticeCoverage) ?? "empty"))
        }
    }

    /// Exhaustive over every ``OnboardingDiskAction`` case — no `default:`. Adding a third
    /// disk-touching CTA breaks this until it has a fixture and a gallery frame.
    static func onboardingDiskActionCoverage(_ action: OnboardingDiskAction) -> String {
        switch action {
        case .takeOver: "takeOver"
        case .disconnect: "disconnect"
        }
    }

    /// Exhaustive over every ``SetupNotice`` case — no `default:`（T17f）。加第三种「我替你做主」
    /// 的告知，这里会**编译红**，直到它也有 fixture、也有一帧被人真的看过。
    static func setupNoticeCoverage(_ notice: SetupNotice) -> String {
        switch notice {
        case .salvagedPack: "salvaged"
        case .repairedDeadSelection: "repaired"
        }
    }

    /// Exhaustive over every ``OnboardingState`` case — no `default:`. Adding a 7th case
    /// breaks this `switch` (and, independently, every other non-`default` `switch` over
    /// `OnboardingState` in `OnboardingState.swift`/`OnboardingCopy.swift`) until it's
    /// handled here too.
    static func onboardingStateCoverage(_ state: OnboardingState) -> String {
        switch state {
        case .claudeCodeNotInstalled: "claudeCodeNotInstalled"
        case .helperMissing: "helperMissing"
        case .settingsNotWritable: "settingsNotWritable"
        case .settingsParseFailure: "settingsParseFailure"
        case .notInstalled: "notInstalled"
        case .installed: "installed"
        }
    }

    /// Exhaustive over every ``DropZoneState`` case, recursing into ``DropRejectionReason``
    /// for `.reject` so both the outer 4-case enum and the inner 6-case one are guarded by
    /// one function.
    static func dropZoneStateCoverage(_ state: DropZoneState) -> String {
        switch state {
        case .idle: "idle"
        case .hover: "hover"
        case .reject(let reason): "reject.\(dropRejectionReasonCoverage(reason))"
        case .success: "success"
        }
    }

    /// Exhaustive over every ``DropRejectionReason`` case — no `default:`.
    static func dropRejectionReasonCoverage(_ reason: DropRejectionReason) -> String {
        switch reason {
        case .oversize: "oversize"
        case .nonWhitelistFormat: "nonWhitelistFormat"
        case .pathTraversal: "pathTraversal"
        case .overDuration: "overDuration"
        case .builtinReadOnly: "builtinReadOnly"
        case .copyFailed: "copyFailed"
        case .lockBusy: "lockBusy"
        case .lockFailed: "lockFailed"
        }
    }

    /// Exhaustive over every ``CoverageState`` case — no `default:`.
    static func coverageStateCoverage(_ state: CoverageState) -> String {
        switch state {
        case .present: "present"
        case .unmapped: "unmapped"
        case .broken: "broken"
        }
    }

    /// Exhaustive over every ``PackCardState`` case — no `default:`.
    static func packCardStateCoverage(_ state: PackCardState) -> String {
        switch state {
        case .complete: "complete"
        case .partial: "partial"
        case .broken: "broken"
        }
    }

    static func panelPackSectionStateCoverage(_ state: PanelPackSectionState) -> String {
        switch state {
        case .loading: "loading"
        case .pinned(let cards): cards.count == 1 ? "pinned.one" : "pinned.four"
        case .noPinnedPacks: "noPinned"
        case .noPacks: "noPacks"
        case .readFailed: "readFailed"
        }
    }

    static func interfaceTextSizeCoverage(_ size: ClaudioInterfaceTextSize) -> String {
        switch size {
        case .compact: "compact"
        case .standard: "standard"
        case .large: "large"
        case .maximum: "maximum"
        }
    }

    /// Exhaustive over every ``MasterVolumeState`` case — no `default:`.
    static func masterVolumeStateCoverage(_ state: MasterVolumeState) -> String {
        switch state {
        case .value: "value"
        case .failed: "failed"
        }
    }
}

#endif
