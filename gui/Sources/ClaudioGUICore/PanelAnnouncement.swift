import Combine
import Foundation

/// 视图能观测到的**全部**播报时刻 —— `switch` 穷尽、无 `default:`，加第四个时刻会编译红。
public enum PanelAnnouncementMoment: Sendable, Equatable {
    /// 面板真的出现在屏幕上了（``PanelFocusCoordinator/showCount``）。
    ///
    /// `outcomeIsFirstAppearance`：`actionState` 里那条结果（`.failed` / `.reported`）是不是
    /// **这一次打开**才第一次露面。**只有** ``OnboardingViewModel/panelDidBecomeVisible()`` 算得出它 ——
    /// 它是 ``OnboardingViewModel/outcomeHasBeenSeen`` 的唯一读者，而且当场就把它消费掉了。视图结构上
    /// 算不出来，所以它只能作为那个函数的**返回值**流过来。
    case panelOpened(outcomeIsFirstAppearance: Bool)
    /// `.onChange(of: actionState)` —— 一个动作开始 / 失败 / 带着告知落地。
    case actionStateChanged
    /// `.onChange(of: state)` —— 探测态变了（接管成功 → `.installed`）。
    case stateChanged
}

/// 播报政策的全部输入。
public struct PanelAnnouncementFacts: Sendable, Equatable {
    public let moment: PanelAnnouncementMoment

    /// 探测态 —— 面板此刻「是哪一屏」。
    ///
    /// T17h：它必须在这里，而 `header` 顶替不了它。见 ``panelSentence(state:header:)`` 的文档：
    /// 视图侧的 `headerAccessibilityLabel` 在**每一个**非 `.installed` 态上都返回同一个常量，于是
    /// 五个 onboarding 态说出来是一模一样的一句话。真相源在 view-model 手里（``OnboardingViewModel/state``），
    /// 所以它跟 `actionState` 一样以模型事实的身份流进来 —— 视图**不**供给它，也就不会有第二个会漂移的答案。
    public let state: OnboardingState

    public let actionState: OnboardingActionState

    /// 面板此刻真的在屏幕上吗。真相源是 ``OnboardingViewModel`` 的 `isPanelVisible`（`private`），所以
    /// 这个结构体只由 ``OnboardingViewModel/announcement(_:header:)`` 组装 —— 视图拿不到第二个可见性
    /// oracle，也就不会有第二个会各自漂移的答案（而 `outcomeHasBeenSeen` 的诞生判据押的正是同一个事实）。
    public let panelIsVisible: Bool

    /// 视图侧那半句（`PanelView.headerAccessibilityLabel`）。其中当前包名来自独立于显示集的
    /// `PanelConfigController.selectedPackMetadata`；这里仍以**数据**身份接收整句 header，
    /// 政策一个字都没留在 SwiftUI 里。
    public let header: String

    public init(
        moment: PanelAnnouncementMoment,
        state: OnboardingState,
        actionState: OnboardingActionState,
        panelIsVisible: Bool,
        header: String
    ) {
        self.moment = moment
        self.state = state
        self.actionState = actionState
        self.panelIsVisible = panelIsVisible
        self.header = header
    }
}

/// 面板此刻「是哪一屏」那一句 —— 面板句本身，外加（非 `.installed` 时）**这个 onboarding 态自己**那一句。
///
/// ## 它修的那个洞（T17h —— `/codex review a3c2d08` 独立评审逮到，本地读码证实）
///
/// `header` 由视图侧的 `PanelView.headerAccessibilityLabel` 供给，而它长这样：
///
/// ```swift
/// guard onboardingViewModel.state == .installed else { return "Claudio 面板" }
/// return "Claudio 面板，当前声音包 \(packName)"
/// ```
///
/// 也就是说：**五个 onboarding 态**（`.claudeCodeNotInstalled` / `.helperMissing` /
/// `.settingsNotWritable` / `.settingsParseFailure` / `.notInstalled`）被折叠成**同一个常量**。
/// 包名那半句只在 `.installed` 时才拼得出来，别的态一个字节的状态信息都不带。
///
/// 于是：用户在 onboarding 卡上点「重新检测」（他刚在别处把 Claude Code 装好了），`state` 从一个
/// onboarding 态跃迁到另一个 —— 屏幕上大标题、正文、CTA 三样**全变了** —— 而 `.stateChanged` 那一句
/// 与刚说完的那一句**逐字相同**，被 ``PanelAnnouncer`` 当成后缀吞掉：**VoiceOver 一个字都没有。**
///
/// 这就是 T17g 自己那句「结果画得出来，却说不出口」，只不过这一次它长在 ``OnboardingState`` 上，
/// 而不是 ``OnboardingActionState`` 上。T17g 的穷尽 `switch` 逐格钉死了后者，**前者一格都没人盯** ——
/// 修复者在自己刚立的规矩上，漏掉了正交的那一维。这个仓库为「真相源自己漏了一维」这个形状
/// （`PreviewFixtures` 的文档、`/ship` 收口记录 ③）已经交过两次学费了。
///
/// ⚠️ **去重器不是罪魁，别去改它。** 被它吞掉的那句话本来就一个字节的状态信息都不带 —— 放它过去，
/// 用户只会第二次听到一句「Claudio 面板。」。根因是那个常量 header，而不是「dedup 的 scope 太宽」。
/// （第一版评审意见正是建议去缩 dedup 的 scope；那会把一句毫无信息量的重复播报放回来，然后宣布修好了。）
///
/// 真相源现成就在 ``onboardingCopy(for:)`` —— 屏幕上那行大标题，念出来即可。政策留在这个纯函数里，
/// 而不是回到视图的 `headerAccessibilityLabel` 里：`ClaudioGUI` 是个 `@main` executableTarget，
/// harness **一行都 import 不到**，把 state → 那句话的映射写在那儿 = 六个态零测试守护。
///
/// ## 不变式（``PanelAnnouncementSuite`` 逐对钉死）
///
/// **给定同一个 `header`，任意两个不同的 ``OnboardingState``，这个函数说出来的话必须不同。**
/// 相等 = 那条跃迁在听觉通道上根本不存在。用同一个 header 喂全部六个态是刻意的**更强**条件：
/// 它不许这条不变式去指望 header 帮忙区分（而在真实视图里，五个 onboarding 态拿到的正是同一个 header）。
public func panelSentence(state: OnboardingState, header: String) -> String? {
    guard state != .installed else { return joinSpokenClauses([header]) }
    return joinSpokenClauses([header, onboardingCopy(for: state).title])
}

/// 此刻 VoiceOver 该听到的**那一句**；`nil` = 一个字都不说。
///
/// ## 它取消掉的那场竞争（T17g）
///
/// `NSAccessibility.announcementRequested` 是「一次一句」的通道：同一趟 post 两条，VoiceOver 只说最后
/// 一条（`PanelView` 自己在 T17f 就把这条写进了注释）。而 ``OnboardingViewModel/runDiskAction(_:)`` 在
/// **同一个 MainActor turn** 里先写 `actionState`、再经 `refresh()` 写 `state`，两次写之间没有 `await`
/// —— SwiftUI 把它们合并成**一次** update pass，`.onChange(of: state)` 与 `.onChange(of: actionState)`
/// **都会**触发。上一版于是把「那条告知能不能被听见」押在 SwiftUI **未文档化**的 onChange 执行顺序上，
/// 零测试守护：顺序一翻，「你的包被换掉了」就被一句平静的「当前声音包 X」吃掉 —— 正是 T17f 宣称杀死的
/// 那个静默替换，换到听觉通道上复活。
///
/// 这里不去**赢**那场竞争，而是让它**不存在**：
/// - `actionState` 非 `.idle` 时，`.stateChanged` **一个字都不说**（主动让出通道）；
/// - `.idle` 时两个时刻说的是**同一句**（面板句），于是 ``PanelAnnouncer`` 把第二条当成重复吞掉。
///
/// 于是无论 SwiftUI 按什么顺序跑、是否把两次写合并成一趟，**这一趟里 post 出去的永远只有一句**。
/// `PanelAnnouncementSuite` 对 `PreviewFixtures.onboardingActionStates` 全矩阵逐格断言这一条。
public func panelAnnouncement(_ facts: PanelAnnouncementFacts) -> String? {
    // 闸门：面板不在屏幕上 → 一个字都不说。用户此刻人在别的 app 里，这句话会被念进他正在用的窗口。
    //
    // 这**不是**在丢弃信息 —— 它与 T17d 的寿命规则是同一件事的两半：一条诞生在关着的面板上的结果，
    // `outcomeHasBeenSeen == false`，它必然活到下一次打开，并在那时由
    // `.panelOpened(outcomeIsFirstAppearance: true)` 说出来。闸门只是把它**推迟**到有人在听的时候。
    guard facts.panelIsVisible else { return nil }

    // 「面板句」不再等于 `header` —— 非 `.installed` 时它还得带上这个 onboarding 态自己那一句，
    // 否则五个态说出来一模一样（T17h，见 ``panelSentence(state:header:)``）。下面三个时刻里
    // 「说面板句」的每一处都必须走它，一处漏掉 = 那一格的跃迁重新变哑。
    let panel = panelSentence(state: facts.state, header: facts.header)

    switch facts.moment {
    case .panelOpened(let isFirstAppearance):
        return joinSpokenClauses(
            [panel, openingOutcomeClause(facts.actionState, isFirstAppearance)]
                .compactMap { $0 })

    case .actionStateChanged:
        // `.idle` = 一次「无话可说」的动作落地（成功但没什么要告诉他 / 一条已经看过的结果刚被清掉 /
        // 「重新检测」清掉了上一条失败）。此刻**仍然要开口** —— 说面板句。
        //
        // 上一版把这句话全权交给了 `.stateChanged`，于是一个**不改变 `state`** 的成功动作会彻底无声，
        // 而且没有任何测试会红（今天两个磁盘动作成功后 `state` 必变，所以它是一个「暂时」不可达的洞 ——
        // 而「我推理出这个格子不可达」正是这个仓库交过学费的那句话）。
        //
        // 它与 `.stateChanged` 说的是**同一句**，所以同一趟里两个 handler 都跑也只会 post 一次。
        return joinSpokenClauses([actionClause(facts.actionState) ?? panel].compactMap { $0 })

    case .stateChanged:
        // 有结果要说的时候，面板句**主动让出**这条一次一句的通道 —— 见本函数头部。
        guard case .idle = facts.actionState else { return nil }
        return panel
    }
}

/// The operational dual-host panel no longer changes shape with Claude Code onboarding state.
/// Its opening/status announcement is therefore the already-composed panel header, normalized to
/// one spoken sentence here rather than reintroducing announcement policy in SwiftUI.
public func dualHostPanelAnnouncement(header: String) -> String? {
    joinSpokenClauses([header])
}

/// 一条动作态**说出口**是什么样子；`nil` = 这个态没有任何话要说。
/// `switch` 穷尽、无 `default:`：将来加一个动作态，这里编译红。
public func actionClause(_ actionState: OnboardingActionState) -> String? {
    switch actionState {
    case .idle:
        return nil
    case .running(let action):
        // 一颗变灰的按钮 + 一个 `.accessibilityHidden(true)` 的 spinner 对 VoiceOver 是彻底无声的，而
        // `applyFirstFocus()` 还刻意把焦点**挪离**了那颗按钮 —— VO 光标永远落不上去。不说这句，重开面板
        // 的用户完全不知道有一个写盘动作正在跑。
        return onboardingActionRunningTitle(action)
    case .failed(_, let message, _):
        return message
    case .reported(let notices):
        // 多条告知拼进**同一句**：一次一句的通道，连发多条只会被截断成最后一条 —— 而被丢掉的那条，恰恰
        // 可能是「你的目录被搬到了哪儿」。
        return joinSpokenClauses(notices.map(\.message))
    }
}

/// 打开面板这一刻，除了面板句还欠用户一句什么。
private func openingOutcomeClause(
    _ actionState: OnboardingActionState, _ isFirstAppearance: Bool
) -> String? {
    switch actionState {
    case .idle:
        return nil
    case .running:
        return actionClause(actionState)
    case .failed, .reported:
        // 第一次露面 → 说出来（T17d/T17f 把这条结果**画**出来了，却从没**说**出来）。
        // 已经说过了 → 闭嘴：每次重开都重播同一条失败，正是 ``OnboardingViewModel`` 文档里
        // 「同一条播两遍」那条禁令。
        //
        // ⚠️ `false` 这一格在生产里**不可达**：``OnboardingViewModel/panelDidBecomeVisible()`` 只在把结果
        // 清成 `.idle` **之后**才返回 `false`（`OnboardingViewModelSuite` 的真值表钉死这条契约，而
        // `PanelAnnouncementSuite` 的后缀不变式建立在它上面）。这里仍然明确写出来，不靠「推理出它不可达」。
        return isFirstAppearance ? actionClause(actionState) : nil
    }
}

/// 一句话的合法终止符 —— 「正在接管…」以省略号结尾，不该再被补一个句号。
private let spokenTerminators: Set<Character> = ["。", "！", "？", "…"]

/// 若干子句拼成一句人能听的话。`nil` = 没有任何子句。
///
/// **绝不返回空串**：空串是一次会打断 VoiceOver 正在说的话、然后什么都不说的 post。
///
/// `SetupNotice.message` / `OnboardingActionError.message` 自带句号，`headerAccessibilityLabel` 不带，
/// `onboardingActionRunningTitle` 以省略号结尾 —— 直接 `joined(separator: " ")` 会拼出一句没有句读的长串，
/// VoiceOver 会连成一坨读完。
public func joinSpokenClauses(_ clauses: [String]) -> String? {
    let cleaned =
        clauses
        .map { clause -> String in
            var trimmed = clause
            while trimmed.hasSuffix("。") { trimmed.removeLast() }
            return trimmed
        }
        .filter { !$0.isEmpty }
    guard !cleaned.isEmpty else { return nil }
    let joined = cleaned.joined(separator: "。")
    guard let last = joined.last, spokenTerminators.contains(last) else { return joined + "。" }
    return joined
}

/// `next` 是不是「刚说完那句话的尾巴」—— 同一次打开里再 post 一遍，只会**打断**用户正在听的那一句。
public func panelAnnouncementIsRedundant(_ next: String, after previous: String) -> Bool {
    !previous.isEmpty && previous.hasSuffix(next)
}

/// 「这一句刚说过」—— 让「一次转变 ≤ 一条播报」在结构上成立的去重器（T17g）。
///
/// ## 为什么光有政策不够
///
/// 面板重开时，SwiftUI 完全可能把「面板关着那段时间攒下的 `@Published` 变化」推迟到这一趟 update 才
/// flush（**没有人实测过**，AppKit / SwiftUI 都没文档化）。于是同一趟里会跑到：`.panelOpened` 说完整的
/// 「Claudio 面板，当前声音包 lofi。你之前选的「pikachu」已经不在了…」，紧接着那条被推迟的
/// `.onChange(of: actionState)` 又把「你之前选的「pikachu」已经不在了…」说一遍 —— 后一条把前一条**截断**。
///
/// 去重器把这条路堵死，而且是**可证明完备**的，不是启发式：`.panelOpened` 拼句时结果永远在**尾巴**上
/// （`[header, outcome]`），所以 `.actionStateChanged` 那句必然是它的**后缀**。`PanelAnnouncementSuite` 对
/// 全矩阵逐格断言这条后缀关系。
///
/// 顺带：这也让重开那一趟**与顺序无关** —— 跑在 `panelDidBecomeVisible()` **之前**的 handler 被闸门
/// （`isPanelVisible` 此刻仍是 `false`）挡下，跑在**之后**的被后缀规则吞掉。
///
/// **按 `openCount` 分段**：跨两次打开重复同一句面板句是**必须**的（用户重开面板就该重新听到它），所以
/// 去重只在**同一次打开**之内生效。全局按内容去重 = 第二次打开面板一片死寂。
@MainActor
public final class PanelAnnouncer: ObservableObject {
    private var lastOpenCount = -1
    private var lastSentence = ""

    public init() {}

    /// 这一刻真正该 post 出去的那句话（`nil` = 不 post）。
    public func consume(_ candidate: String?, openCount: Int) -> String? {
        guard let candidate, !candidate.isEmpty else { return nil }
        if openCount == lastOpenCount,
            panelAnnouncementIsRedundant(candidate, after: lastSentence)
        {
            return nil
        }
        lastOpenCount = openCount
        lastSentence = candidate
        return candidate
    }
}
