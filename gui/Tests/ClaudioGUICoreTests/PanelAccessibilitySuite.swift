import ClaudioGUICore
import Foundation

// MARK: - Panel-level accessibility copy (PLAN-SOUND-MANAGER.md T7)
//
// `PanelView` lives in the `ClaudioGUI` executable target and cannot be imported by this
// dependency-free harness. Keep the two-axis needsPack copy decision in ClaudioGUICore so the
// actual VoiceOver sentence — not merely the presence of an `.accessibilityLabel` modifier in
// source text — is asserted as a value.

@MainActor
func runPanelAccessibilitySuites() {
    suite("PanelAccessibility: needsPack × 零行的 label 明确指向「管理声音包…」，且不产生半截事件标题") {
        let copy = needsPackNoticeCopy(hasVisiblePackChoices: false)

        expect(
            copy.message == "还没有选中任何声音包。选择「管理声音包…」，在访达中添加声音包后再回来选择。",
            "零行可见文案必须指向屏幕上真实存在的管理入口，实得 \(copy.message)")
        expect(
            copy.accessibilityLabel
                == "先选包。还没有选中任何声音包。选择「管理声音包…」，在访达中添加声音包后再回来选择。",
            "零行 VoiceOver label 必须把标题、上下文与主行动说成完整一句，实得 \(copy.accessibilityLabel)")
        expect(
            copy.accessibilityLabel.contains("管理声音包")
                && !copy.accessibilityLabel.contains("点一个声音包"),
            "零行时不能让 VoiceOver 指向不存在的包行，实得 \(copy.accessibilityLabel)")
        expect(
            !copy.accessibilityLabel.contains(" · 事件"),
            "needsPack 不渲染事件区，label 里也不得出现「 · 事件」半截标题，实得 \(copy.accessibilityLabel)")
    }

    suite("PanelAccessibility: needsPack × 有包行的 label 指向「点一个声音包」，不误导用户先去管理") {
        let copy = needsPackNoticeCopy(hasVisiblePackChoices: true)

        expect(
            copy.message == "还没有选中任何声音包。点一个声音包，claudi0 会建好配置。",
            "有包行时主行动必须是选择现有声音包，实得 \(copy.message)")
        expect(
            copy.accessibilityLabel == "先选包。还没有选中任何声音包。点一个声音包，claudi0 会建好配置。",
            "有包行的 VoiceOver label 必须与可见文案同源，实得 \(copy.accessibilityLabel)")
        expect(
            !copy.accessibilityLabel.contains("管理声音包"),
            "已有可选包行时，不应把次级管理入口说成主行动，实得 \(copy.accessibilityLabel)")
    }
}
