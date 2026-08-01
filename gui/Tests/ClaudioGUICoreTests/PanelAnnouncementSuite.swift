import ClaudioCore
import ClaudioGUICore
import Foundation

// MARK: - T17g：播报政策的真值表
//
// DEFECT 1（codex 独立评审逮到）：`PanelView` 的「面板打开」handler 从来不播报动作态 —— 于是
// 「用户点完接管就切走、`.transient` popover 当场关闭、不随视图销毁的 Task 继续跑完（失败 / 带着
// 一条「我替你换了包」的告知）、用户回来重开面板」这条路径上，VoiceOver 用户听到的只有一句平静的
// 「Claudio 面板，当前声音包 X」。T17d/T17f 费尽力气让那条结果**活到被看见**（`outcomeHasBeenSeen`
// 就是为它造的），却从没让它**被听见**。
//
// 更要命的是那个「顺手的修法」——在 handler 里再补一句 `announceActionState()` ——**修不好它**：
// `.announcementRequested` 是「一次一句」的通道，两条 post 挤在一趟里，后一条把前一条截断。所以政策
// 整体下沉成纯函数，让「同一趟里两条内容不同的播报」在结构上不可能，而不是靠视图里的自觉。

// MARK: - T17h：`state` 这一维（`/codex review a3c2d08` 逮到）
//
// DEFECT 2：T17g 的穷尽 switch 逐格钉死了 `OnboardingActionState`，而**正交的那一维**
// （`OnboardingState`，六个 case）一格都没人盯。视图侧的 `headerAccessibilityLabel` 把五个
// onboarding 态折叠成同一个常量「Claudio 面板」，于是它们之间的任何一次跃迁说出来都是**同一句话**，
// 被 `PanelAnnouncer` 当成后缀吞掉：屏幕上标题、正文、CTA 全变了，VoiceOver 一个字都没有。
// 这就是 T17g 自己那句「画得出来，说不出口」——长在了修复者刚立的规矩上。
//
// 下面每一个矩阵都从「× actionStates」变成「× states × actionStates」。

private let H = "Claudio 面板，当前声音包 lofi"

/// **刻意对全部六个态用同一个 `header`。** 真实视图里五个 onboarding 态拿到的正是同一个常量，所以
/// 这是那条区分性不变式的**更强**版本：它不许 `panelSentence` 去指望 header 帮忙区分两个态。
@MainActor
private func facts(
    _ moment: PanelAnnouncementMoment,
    _ actionState: OnboardingActionState,
    state: OnboardingState = .installed,
    visible: Bool = true
) -> PanelAnnouncementFacts {
    PanelAnnouncementFacts(
        moment: moment, state: state, actionState: actionState, panelIsVisible: visible, header: H)
}

/// 无 `default:` —— 加一个时刻会编译红；下面那份名册让「加了 case 却一格都没测」当场变红。
private func momentLabel(_ moment: PanelAnnouncementMoment) -> String {
    switch moment {
    case .panelOpened(let first): first ? "panelOpened.first" : "panelOpened.repeat"
    case .actionStateChanged: "actionStateChanged"
    case .stateChanged: "stateChanged"
    }
}

private let allMoments: [PanelAnnouncementMoment] = [
    .panelOpened(outcomeIsFirstAppearance: true),
    .panelOpened(outcomeIsFirstAppearance: false),
    .actionStateChanged,
    .stateChanged,
]

/// 视图**真正能遇到**的开面板时刻 —— 由 ``OnboardingViewModel/panelDidBecomeVisible()`` 的契约决定：
/// 它只在把结果清成 `.idle` **之后**才返回 `false`（那条契约由 `OnboardingViewModelSuite` 的真值表钉死）。
/// 无 `default:`：加一个动作态，这里编译红。
private func reachableOpenMoments(for actionState: OnboardingActionState)
    -> [PanelAnnouncementMoment]
{
    switch actionState {
    case .idle, .running: [.panelOpened(outcomeIsFirstAppearance: false)]
    case .failed, .reported: [.panelOpened(outcomeIsFirstAppearance: true)]
    }
}

@MainActor
func runPanelAnnouncementSuites() {
    suite("双宿主面板播报：只消费已组合 header，并规范为一句完整播报") {
        expect(dualHostPanelAnnouncement(header: "") == nil, "空 header 不得打断 VoiceOver")
        expect(
            dualHostPanelAnnouncement(header: "Claudio 面板，2 个声音来源")
                == "Claudio 面板，2 个声音来源。",
            "双宿主运行面板不得再附加已被移除的 Claude onboarding 屏幕文案")
    }

    suite("T17g 时刻名册：每一个 PanelAnnouncementMoment 变体都被这套 suite 真的喂过一次") {
        expect(
            Set(allMoments.map(momentLabel))
                == ["panelOpened.first", "panelOpened.repeat", "actionStateChanged", "stateChanged"],
            "加了一个新的播报时刻却没给它 fixture —— 它的政策一格都没人验过")
    }

    suite("T17g【拼句】没有子句 → nil，绝不是一个孤零零的句号（空串 = 一次打断 VoiceOver 却什么都不说的 post）") {
        expect(joinSpokenClauses([]) == nil, "空数组 → nil")
        expect(joinSpokenClauses(["", "。"]) == nil, "全是空子句 → nil，而不是「。」")
        expect(joinSpokenClauses(["Claudio 面板"]) == "Claudio 面板。", "补句号")
        expect(
            joinSpokenClauses(["Claudio 面板", "正在接管…"]) == "Claudio 面板。正在接管…",
            "省略号结尾不再补句号")
        expect(joinSpokenClauses(["A。", "B。"]) == "A。B。", "不许拼出「。。」")
    }

    suite("T17g【去重器】同一次打开里，一句话的后缀不许再 post 一遍（那只会截断用户正在听的话）") {
        let announcer = PanelAnnouncer()
        expect(
            announcer.consume("Claudio 面板。你的包被换了。", openCount: 1)
                == "Claudio 面板。你的包被换了。", "第一句必须说")
        expect(
            announcer.consume("你的包被换了。", openCount: 1) == nil,
            "它是刚说完那句的后缀 —— 面板重开时被推迟的 .onChange(of: actionState) 干的正是这件事")
        expect(
            announcer.consume("你的包被换了。", openCount: 2) == "你的包被换了。",
            "换了一次打开 → 去重不跨段")
    }

    suite("T17g【去重器】跨两次打开重复同一句面板句，必须照说 —— 否则重开面板就是一片死寂") {
        let announcer = PanelAnnouncer()
        expect(announcer.consume("Claudio 面板。", openCount: 1) == "Claudio 面板。", "第一次打开")
        expect(
            announcer.consume("Claudio 面板。", openCount: 2) == "Claudio 面板。",
            "第二次打开必须再说一遍 —— 全局按内容去重 = 重开面板一片死寂")
    }

    suite("T17g【去重器】nil / 空串不 post，也不污染「刚说过什么」") {
        let announcer = PanelAnnouncer()
        expect(announcer.consume("A。", openCount: 1) == "A。", "先说一句")
        expect(announcer.consume(nil, openCount: 1) == nil, "nil 不 post")
        expect(announcer.consume("", openCount: 1) == nil, "空串不 post")
        expect(announcer.consume("A。", openCount: 1) == nil, "nil / 空串不该把「刚说过 A」冲掉")
    }

    suite("T17g【重开必须开口】第一次露面的失败 / 告知，必须连同面板句一起被说出来（DEFECT 1）") {
        let failure = OnboardingActionState.failed(
            action: .takeOver, message: "这一步没能完成。", detail: "d")
        guard
            let said = panelAnnouncement(
                facts(.panelOpened(outcomeIsFirstAppearance: true), failure))
        else {
            expect(false, "❌ 静默失败在听觉通道上复活了：这一次打开是它唯一一次能被听见的机会")
            return
        }
        expect(
            said.contains("这一步没能完成"),
            "听到的必须是失败原因本身，而不是一句平静的面板句。实得 \(said)")
        expect(said.hasPrefix(H), "面板句在前、结果在后 —— 去重器的后缀规则依赖这个次序。实得 \(said)")

        let notices: [SetupNotice] = [
            .salvagedPack(packID: "wobbuffet", movedTo: "/tmp/w-aside"),
            .repairedDeadSelection(removed: "wobbuffet", selected: "minimal-chime"),
        ]
        guard
            let reported = panelAnnouncement(
                facts(.panelOpened(outcomeIsFirstAppearance: true), .reported(notices: notices)))
        else {
            expect(false, "❌ 静默替换在听觉通道上复活了")
            return
        }
        for notice in notices {
            expect(
                reported.contains(notice.message),
                "一条告知在拼句里掉了 —— 被丢掉的那条恰恰可能是「你的目录被搬到了哪儿」。实得 \(reported)")
        }
    }

    suite("T17g【进行中】动作还在跑时重开面板，必须听得到「正在接管…」") {
        let said = panelAnnouncement(
            facts(.panelOpened(outcomeIsFirstAppearance: false), .running(.takeOver)))
        expect(
            said?.contains("正在接管…") == true,
            "spinner 被 .accessibilityHidden(true)、按钮被 .disabled 且焦点被刻意挪离 —— 不说这句，"
                + "VO 用户重开面板时完全不知道有一个写盘动作正在跑。实得 \(String(describing: said))")
        expect(said?.hasPrefix(H) == true, "面板句也在")
    }

    suite("T17g【不重播】一条已经说过、刚被清掉的结果，重开时一个字的原因都不许再念") {
        let opened = panelAnnouncement(facts(.panelOpened(outcomeIsFirstAppearance: false), .idle))
        expect(opened == "\(H)。", "重开一张干净的面板 → 只说面板句。实得 \(String(describing: opened))")
        expect(
            panelAnnouncement(facts(.actionStateChanged, .idle)) == opened,
            "清理路径（.reported → .idle）触发的那次 onChange，必须与开面板那一句**一字不差** —— 否则它会"
                + "把刚说完的话截断。上一版靠 `announceActionState(.idle)` 恰好 `break` 兜着，那是一条没人守的隐含依赖")
    }

    #if DEBUG
        // ── T17h：`OnboardingState` 这一维（DEFECT 2）─────────────────────────────────────────

        suite("T17h【区分性】任意两个不同的 OnboardingState，面板句必须**不同** —— 相等 = 那条跃迁在听觉上不存在") {
            var spoken: [String: OnboardingState] = [:]
            for state in PreviewFixtures.onboardingStates {
                guard let said = panelSentence(state: state, header: H) else {
                    expect(false, "\(state)：面板句是 nil —— 这一屏在 VoiceOver 里根本不存在")
                    continue
                }
                if let clash = spoken[said] {
                    expect(
                        false,
                        "两个不同的态说出了**同一句话**：\(clash) 与 \(state) 都念作「\(said)」。用户点"
                            + "「重新检测」，磁盘上的事实变了、屏幕上大标题 / 正文 / CTA 三样全变了，而"
                            + " .stateChanged 那一句与刚说完的**逐字相同** → PanelAnnouncer 按后缀吞掉 →"
                            + " VoiceOver 一个字都没有。⚠️ 别去改去重器：被它吞掉的那句话本来就一个字节的"
                            + "状态信息都不带，放它过去只会让用户第二次听到「Claudio 面板。」")
                }
                spoken[said] = state
            }
            expect(
                spoken.count == PreviewFixtures.onboardingStates.count,
                "六个态必须念出六句**互不相同**的话，实得 \(spoken.count) 句")
        }

        suite("T17h【内容】每个 onboarding 态的面板句，必须真的念出它屏幕上那行大标题") {
            for state in PreviewFixtures.onboardingStates where state != .installed {
                let title = onboardingCopy(for: state).title
                let said = panelSentence(state: state, header: H)
                expect(
                    said?.contains(title) == true,
                    "\(state)：屏幕上白纸黑字写着「\(title)」，VoiceOver 却听不到它 —— 视图侧的 "
                        + "headerAccessibilityLabel 把五个 onboarding 态全折叠成同一个常量「Claudio 面板」。"
                        + "实得 \(String(describing: said))")
            }
            expect(
                panelSentence(state: .installed, header: H) == "\(H)。",
                "已接管这一屏念的是包名那一句，不再往后拼标题 —— header 在 .installed 时本来就带着"
                    + "全部信息（当前声音包 X），而它的标题「已经接好了」与那个绿点是同一个意思")
        }

        suite("T17h【端到端】同一次打开里的一次真实 onboarding 跃迁，去重器不许吞掉它") {
            // 用户开着面板（「没找到 Claude Code」），在别处把 Claude Code 装好，回来点「重新检测」。
            let announcer = PanelAnnouncer()
            let opened = panelAnnouncement(
                facts(
                    .panelOpened(outcomeIsFirstAppearance: false), .idle,
                    state: .claudeCodeNotInstalled))
            expect(announcer.consume(opened, openCount: 1) != nil, "开面板那一句必须说出来")

            let advanced = panelAnnouncement(facts(.stateChanged, .idle, state: .notInstalled))
            let posted = announcer.consume(advanced, openCount: 1)
            expect(
                posted != nil,
                "同一次打开里 state 从 .claudeCodeNotInstalled 跃迁到 .notInstalled —— 大标题从"
                    + "「没找到 Claude Code」变成「让 Claude Code 学会开口」，CTA 从「重新检测」变成"
                    + "「接管 Claude Code」，整屏都换了。**修复前这里返回 nil**：两句话逐字相同（都是"
                    + "那个常量 header），被后缀规则当成重复吞掉，VoiceOver 一片死寂。"
                    + "实得 \(String(describing: posted))")
            expect(
                posted?.contains("让 Claude Code 学会开口") == true,
                "而且听到的必须是**新那一屏**的标题，不是一句泛泛的面板句。实得 \(String(describing: posted))")
        }

        // ── T17g 的四条不变式 —— 现在每一条都在 states × actionStates **两维**上逐格跑 ──────────
        //
        // 上一版只扫 actionStates（隐含 state == .installed 那一格）。DEFECT 2 恰恰长在没人扫的那一维上：
        // 政策函数里新增的 `panelSentence` 一旦在某个 state 上返回错的东西（空串 / 与别人相同 / 破坏后缀），
        // 单维矩阵一格都不会红。

        suite("T17g/h【闸门】面板关着时：任何 state × 任何动作态 × 任何时刻，都不许开口") {
            for state in PreviewFixtures.onboardingStates {
                for actionState in PreviewFixtures.onboardingActionStates {
                    for moment in allMoments {
                        expect(
                            panelAnnouncement(
                                facts(moment, actionState, state: state, visible: false)) == nil,
                            "\(state) × \(momentLabel(moment)) × \(actionState)：面板关着、用户人在 Finder "
                                + "里，而 Claudio 朝着他正在用的那个窗口念了一句话。（这不是丢信息：那条结果的 "
                                + "outcomeHasBeenSeen == false，它会活到下一次打开，由 .panelOpened(first: true) 说出来。）"
                        )
                    }
                }
            }
        }

        suite("T17g/h【一次一句】.stateChanged 与 .actionStateChanged 同时非 nil 时，必须是**同一句**") {
            for state in PreviewFixtures.onboardingStates {
                for actionState in PreviewFixtures.onboardingActionStates {
                    let s = panelAnnouncement(facts(.stateChanged, actionState, state: state))
                    let a = panelAnnouncement(facts(.actionStateChanged, actionState, state: state))
                    if let s, let a {
                        expect(
                            s == a,
                            "\(state) × \(actionState)：两条**内容不同**的 post 抢同一条「一次一句」的通道 ——"
                                + "谁活下来取决于 SwiftUI 未文档化的 onChange 顺序（runDiskAction 在同一个 "
                                + "MainActor turn 里写完两个 @Published，两个 onChange 都会在同一趟 update pass "
                                + "里触发）。T17f 押的正是那个注。实得 s=「\(s)」 a=「\(a)」")
                    }
                }
            }
        }

        suite("T17g/h【一次一句】开面板那一句永远以「动作态那一句」结尾 —— 去重器据此结构性地吞掉重复的第二条") {
            for state in PreviewFixtures.onboardingStates {
                for actionState in PreviewFixtures.onboardingActionStates {
                    for moment in reachableOpenMoments(for: actionState) {
                        guard
                            let opened = panelAnnouncement(
                                facts(moment, actionState, state: state))
                        else {
                            expect(false, "\(state) × \(actionState)：开面板至少必须说出面板句")
                            continue
                        }
                        guard
                            let changed = panelAnnouncement(
                                facts(.actionStateChanged, actionState, state: state))
                        else { continue }
                        expect(
                            panelAnnouncementIsRedundant(changed, after: opened),
                            "\(state) × \(momentLabel(moment)) × \(actionState)：面板重开时，SwiftUI 完全"
                                + "可能把关着那段时间攒下的 @Published 变化推迟到这一趟才 flush —— .panelOpened "
                                + "说完整句，紧接着 .actionStateChanged 又把结果说一遍，把前一句**截断**。只有"
                                + "「后者必然是前者的后缀」这条，才能让 PanelAnnouncer 结构性地吞掉它。"
                                + "（T17h 把面板句加长了 —— 结果仍必须在**尾巴**上，否则这条不变式当场断。）"
                                + "实得 opened=「\(opened)」 changed=「\(changed)」")
                    }
                }
            }
        }

        suite("T17g/h【拼句】全矩阵：永不空串、永不「。。」、每条告知一个字都不许掉") {
            for state in PreviewFixtures.onboardingStates {
                for actionState in PreviewFixtures.onboardingActionStates {
                    for moment in allMoments {
                        guard let said = panelAnnouncement(facts(moment, actionState, state: state))
                        else { continue }
                        expect(
                            !said.isEmpty,
                            "\(state) × \(momentLabel(moment)) × \(actionState)：空串会打断 VoiceOver "
                                + "然后什么都不说")
                        expect(
                            !said.contains("。。"),
                            "\(state) × \(momentLabel(moment)) × \(actionState)：拼出了连着的两个句号。"
                                + "实得 \(said)")
                    }
                    if case .reported(let notices) = actionState {
                        let said = panelAnnouncement(
                            facts(
                                .panelOpened(outcomeIsFirstAppearance: true), actionState,
                                state: state))
                        for notice in notices {
                            expect(
                                said?.contains(notice.message) == true,
                                "\(state)：拼句丢了一条告知：\(notice.message)。"
                                    + "实得 \(String(describing: said))")
                        }
                    }
                }
            }
        }
    #endif
}
