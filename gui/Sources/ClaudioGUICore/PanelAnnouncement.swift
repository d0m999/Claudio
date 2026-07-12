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
    public let actionState: OnboardingActionState

    /// 面板此刻真的在屏幕上吗。真相源是 ``OnboardingViewModel`` 的 `isPanelVisible`（`private`），所以
    /// 这个结构体只由 ``OnboardingViewModel/announcement(_:header:)`` 组装 —— 视图拿不到第二个可见性
    /// oracle，也就不会有第二个会各自漂移的答案（而 `outcomeHasBeenSeen` 的诞生判据押的正是同一个事实）。
    public let panelIsVisible: Bool

    /// 视图侧那半句（`PanelView.headerAccessibilityLabel`）。它依赖 `packCards` / `config` 两个只活在视图里
    /// 的 `@State`，所以它以**数据**身份传进来 —— 政策一个字都没留在 SwiftUI 里。
    public let header: String

    public init(
        moment: PanelAnnouncementMoment,
        actionState: OnboardingActionState,
        panelIsVisible: Bool,
        header: String
    ) {
        self.moment = moment
        self.actionState = actionState
        self.panelIsVisible = panelIsVisible
        self.header = header
    }
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

    switch facts.moment {
    case .panelOpened(let isFirstAppearance):
        return joinSpokenClauses(
            [facts.header, openingOutcomeClause(facts.actionState, isFirstAppearance)]
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
        return joinSpokenClauses([actionClause(facts.actionState) ?? facts.header])

    case .stateChanged:
        // 有结果要说的时候，面板句**主动让出**这条一次一句的通道 —— 见本函数头部。
        guard case .idle = facts.actionState else { return nil }
        return joinSpokenClauses([facts.header])
    }
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
