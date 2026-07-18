import ClaudioGUICore
import Foundation

// MARK: - EventRowView 的两条 VoiceOver 标签（PLAN-SOUND-MANAGER.md §2.5 第 7 条）
//
// `eventRowIdentityAccessibilityLabel(eventDisplayName:coverage:enabled:)` /
// `eventRowFileNameMenuAccessibilityLabel(eventDisplayName:coverage:)`
// （`ClaudioGUICore/EventRowAccessibility.swift`）是从 `EventRowView`（不可 `import` 的
// `ClaudioGUI` executableTarget）里拆出来的两条 DECISION —— 拆之前，这两条契约在
// `ViewWiringSuite` 里只有「控件确实接了 accessibilityLabel」这种存在性级别的间接佐证
// （TODOS.md「T2 文件名 Menu 的 VoiceOver 措辞」那条 P3 记的正是这个天花板）。现在它们是
// 普通的纯函数，可以像 `PanelAnnouncementSuite` 断 `panelSentence`/`panelAnnouncement` 那样，
// 直接断返回的字符串本身 —— 这是本文件存在的全部理由。
//
// 结构性的第②条（禁用的试听 ▶ 不会被 `.combine` 合并抢播）走的是另一条路（源码文本绊线，
// `ViewWiringSuite` 那条同名 suite），理由同样是 `EventRowView` 不可 `import`——但那一条断的是
// 「控件树的形状」，不是「字符串的内容」，两者不能用同一套测试基础设施。

private let displayName = "干完了"  // 任意一个事件名即可，下面每条断言都不依赖具体是哪个事件

@MainActor
func runEventRowAccessibilitySuites() {
    // MARK: - §2.5 第 7 条 ①：行身份与菜单 label 不重复播报「声音 xxx」两遍

    suite(
        "EventRowAccessibility: .present — identity 与 fileNameMenu 的 label 不同，且不逐字重复「声音 <file>」"
    ) {
        let coverage = CoverageState.present(fileName: "stop.mp3")
        let identity = eventRowIdentityAccessibilityLabel(
            eventDisplayName: displayName, coverage: coverage, enabled: true)
        let menu = eventRowFileNameMenuAccessibilityLabel(
            eventDisplayName: displayName, coverage: coverage)

        expect(identity != menu, "两条 label 不许逐字相同，实得 identity=\(identity) menu=\(menu)")
        expect(
            identity.contains("声音 stop.mp3"),
            "identity 必须报「声音 <file>」这个组合短语（DESIGN.md「无障碍规格」），实得 \(identity)")
        expect(
            !menu.contains("声音 stop.mp3"),
            "fileNameMenu 不许逐字重复 identity 那句「声音 <file>」组合短语——它自己的措辞是"
                + "「更改…的声音，当前 <file>」，文件名本身必然出现在两边（同一份文件），但「声音」"
                + "与文件名**紧邻**这个组合短语只许 identity 一家说，实得 \(menu)")
    }

    suite(
        "EventRowAccessibility: .unmapped — identity 与 fileNameMenu 的 label 不同，且不逐字重复「未配置声音」"
    ) {
        let coverage = CoverageState.unmapped
        let identity = eventRowIdentityAccessibilityLabel(
            eventDisplayName: displayName, coverage: coverage, enabled: true)
        let menu = eventRowFileNameMenuAccessibilityLabel(
            eventDisplayName: displayName, coverage: coverage)

        expect(identity != menu, "两条 label 不许逐字相同，实得 identity=\(identity) menu=\(menu)")
        expect(identity.contains("未配置声音"), "identity 必须报「未配置声音」，实得 \(identity)")
        expect(
            !menu.contains("未配置声音"),
            "fileNameMenu 不许逐字重复 identity 那句「未配置声音」，实得 \(menu)")
    }

    suite(
        "EventRowAccessibility: .broken — identity 与 fileNameMenu 的 label 不同，且不逐字重复「声音文件丢失」"
    ) {
        let coverage = CoverageState.broken(fileName: "stop.mp3")
        let identity = eventRowIdentityAccessibilityLabel(
            eventDisplayName: displayName, coverage: coverage, enabled: true)
        let menu = eventRowFileNameMenuAccessibilityLabel(
            eventDisplayName: displayName, coverage: coverage)

        expect(identity != menu, "两条 label 不许逐字相同，实得 identity=\(identity) menu=\(menu)")
        expect(identity.contains("声音文件丢失"), "identity 必须报「声音文件丢失」，实得 \(identity)")
        expect(
            !menu.contains("声音文件丢失"),
            "fileNameMenu 不许逐字重复 identity 那句「声音文件丢失」——这条此前是真的会撞车：旧措辞"
                + "「<event>的声音文件丢失，选择新文件或清除绑定」把 identity 那四个字原样复述了一遍，"
                + "两个 VoiceOver 停靠点背靠背念出同一句话，写这条断言时当场抓到并改掉了（见"
                + " EventRowAccessibility.swift 的 doc comment）。现在只说「激活这个控件能做什么」"
                + "（重新选择 / 清除失效绑定），实得 \(menu)")
    }

    // MARK: - §2.5 第 7 条 ③：unmapped 行的 Menu label 必须让 VO 用户听得出「这里能修」

    suite(
        "EventRowAccessibility: .unmapped 的 fileNameMenu label 是一句可操作的祈使句（动词「选择」），不是纯状态描述"
    ) {
        let menu = eventRowFileNameMenuAccessibilityLabel(
            eventDisplayName: displayName, coverage: .unmapped)
        expect(
            menu.contains("选择"),
            "unmapped 行的菜单 label 必须包含可操作的动词「选择」，让 VO 用户听得出「这里能修」——"
                + "而不是像可见文案「未配置」那样只描述状态。实得 \(menu)")
        expect(
            !menu.contains("未配置"),
            "不许把纯状态描述「未配置」搬进这句可操作的 label——那是行内可见文案"
                + "（`EventRowView.pillLabel(text:)`）自己的措辞，VO 契约要的是「能做什么」，不是"
                + "「现在是什么状态」。实得 \(menu)")
    }

    // MARK: - 换一批事件名 / 文件名，结论不变（不是只测了一个巧合的 fixture）

    suite("EventRowAccessibility: 换一批事件名 / 文件名，identity 与 fileNameMenu 仍然不相等（三态各一次）") {
        let fixtures: [CoverageState] = [
            .present(fileName: "a-different-name.wav"), .unmapped,
            .broken(fileName: "another-name.aiff"),
        ]
        for coverage in fixtures {
            let identity = eventRowIdentityAccessibilityLabel(
                eventDisplayName: "子任务完成", coverage: coverage, enabled: false)
            let menu = eventRowFileNameMenuAccessibilityLabel(
                eventDisplayName: "子任务完成", coverage: coverage)
            expect(
                identity != menu,
                "coverage=\(coverage) 下两条 label 撞车了：identity=\(identity) menu=\(menu)")
        }
    }
}
