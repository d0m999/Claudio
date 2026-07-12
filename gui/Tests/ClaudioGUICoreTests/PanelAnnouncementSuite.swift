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

private let H = "Claudio 面板，当前声音包 lofi"

@MainActor
private func facts(
    _ moment: PanelAnnouncementMoment, _ actionState: OnboardingActionState, visible: Bool = true
) -> PanelAnnouncementFacts {
    PanelAnnouncementFacts(
        moment: moment, actionState: actionState, panelIsVisible: visible, header: H)
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
        suite("T17g【闸门】面板关着时，任何时刻 × 任何动作态，都不许开口") {
            for actionState in PreviewFixtures.onboardingActionStates {
                for moment in allMoments {
                    expect(
                        panelAnnouncement(facts(moment, actionState, visible: false)) == nil,
                        "\(momentLabel(moment)) × \(actionState)：面板关着、用户人在 Finder 里，而 Claudio "
                            + "朝着他正在用的那个窗口念了一句话。（这不是丢信息：那条结果的 "
                            + "outcomeHasBeenSeen == false，它会活到下一次打开，由 .panelOpened(first: true) 说出来。）"
                    )
                }
            }
        }

        suite("T17g【一次一句】.stateChanged 与 .actionStateChanged 同时非 nil 时，必须是**同一句**") {
            for actionState in PreviewFixtures.onboardingActionStates {
                let s = panelAnnouncement(facts(.stateChanged, actionState))
                let a = panelAnnouncement(facts(.actionStateChanged, actionState))
                if let s, let a {
                    expect(
                        s == a,
                        "\(actionState)：两条**内容不同**的 post 抢同一条「一次一句」的通道 —— 谁活下来取决于"
                            + " SwiftUI 未文档化的 onChange 顺序（runDiskAction 在同一个 MainActor turn 里写完"
                            + "两个 @Published，两个 onChange 都会在同一趟 update pass 里触发）。T17f 押的正是那个注。"
                            + "实得 s=「\(s)」 a=「\(a)」")
                }
            }
        }

        suite("T17g【一次一句】开面板那一句永远以「动作态那一句」结尾 —— 去重器据此结构性地吞掉重复的第二条") {
            for actionState in PreviewFixtures.onboardingActionStates {
                for moment in reachableOpenMoments(for: actionState) {
                    guard let opened = panelAnnouncement(facts(moment, actionState)) else {
                        expect(false, "\(actionState)：开面板至少必须说出面板句")
                        continue
                    }
                    guard let changed = panelAnnouncement(facts(.actionStateChanged, actionState))
                    else { continue }
                    expect(
                        panelAnnouncementIsRedundant(changed, after: opened),
                        "\(momentLabel(moment)) × \(actionState)：面板重开时，SwiftUI 完全可能把关着那段时间"
                            + "攒下的 @Published 变化推迟到这一趟才 flush —— .panelOpened 说完整句，紧接着"
                            + " .actionStateChanged 又把结果说一遍，把前一句**截断**。只有「后者必然是前者的"
                            + "后缀」这条，才能让 PanelAnnouncer 结构性地吞掉它。"
                            + "实得 opened=「\(opened)」 changed=「\(changed)」")
                }
            }
        }

        suite("T17g【拼句】全矩阵：永不空串、永不「。。」、每条告知一个字都不许掉") {
            for actionState in PreviewFixtures.onboardingActionStates {
                for moment in allMoments {
                    guard let said = panelAnnouncement(facts(moment, actionState)) else { continue }
                    expect(
                        !said.isEmpty,
                        "\(momentLabel(moment)) × \(actionState)：空串会打断 VoiceOver 然后什么都不说")
                    expect(
                        !said.contains("。。"),
                        "\(momentLabel(moment)) × \(actionState)：拼出了连着的两个句号。实得 \(said)")
                }
                if case .reported(let notices) = actionState {
                    let said = panelAnnouncement(
                        facts(.panelOpened(outcomeIsFirstAppearance: true), actionState))
                    for notice in notices {
                        expect(
                            said?.contains(notice.message) == true,
                            "拼句丢了一条告知：\(notice.message)。实得 \(String(describing: said))")
                    }
                }
            }
        }
    #endif
}
