import ClaudioGUICore
import ClaudioLocalization
import Foundation

@MainActor
func runDisplayPreferencesSuites() {
    suite("Display：只保留菜单栏活动状态点与固定紧凑布局") {
        guard
            let settings = displaySource(
                "gui/Sources/ClaudioSettingsPresentation/SettingsRootView.swift"),
            let preferences = displaySource("gui/Sources/ClaudioGUICore/SettingsPreferences.swift"),
            let panel = displaySource("gui/Sources/ClaudioGUI/PanelView.swift")
        else {
            expect(false, "读不到 Display、Preferences 或 Panel 源码")
            return
        }
        expect(
            settings.contains("settingsDisplayFixedLayoutTitle")
                && settings.contains("settings.display.status-dot")
                && !settings.contains("InterfaceTextSizeStepper")
                && !settings.contains("panelWidthPreference"),
            "Display 页面必须只呈现状态点和固定布局说明")
        expect(
            !preferences.contains("interfaceTextSize")
                && !preferences.contains("panelWidthPreference")
                && !preferences.contains("setInterfaceTextSize")
                && !preferences.contains("setPanelWidthPreference"),
            "Preference owner 不得再读取、写入或发布字号/面板宽度偏好")
        expect(
            panel.contains("standardPanelWidth")
                && !panel.contains("interfaceTextSize")
                && !panel.contains("panelWidthPreference")
                && !panel.contains("dynamicTypeSize"),
            "Panel 必须固定使用紧凑宽度，不再分支读取显示偏好")
    }

    suite("Display：旧 UserDefaults 值停止读取且不新增迁移") {
        let sourcePaths = [
            "gui/Sources/ClaudioGUI/PanelView.swift",
            "gui/Sources/ClaudioSettingsPresentation/EventSettingsWindowView.swift",
            "gui/Sources/ClaudioSettingsPresentation/IntegrationsSettingsDestinationView.swift",
            "gui/Sources/SoundPacksWindow/SoundPacksWindowView.swift",
        ]
        for path in sourcePaths {
            guard let source = displaySource(path) else {
                expect(false, "读不到显示消费者：\(path)")
                continue
            }
            expect(
                !source.contains("Claudio.InterfaceTextSize")
                    && !source.contains("Claudio.PanelWidthPreference")
                    && !source.contains("interfaceTextSize")
                    && !source.contains("panelWidthPreference")
                    && !source.contains("dynamicTypeSize"),
                "\(path) 不得保留旧显示偏好的第二写入/读取路径")
        }
    }

    suite("Display：文案双语存在") {
        for language in ClaudioAppLanguage.allCases {
            let l10n = ClaudioL10n(language: language)
            expect(
                !l10n.text(.settingsDisplayFixedLayoutTitle).isEmpty
                    && !l10n.text(.settingsDisplayFixedLayoutDescription).isEmpty,
                "固定布局说明必须提供 \(language) 文案")
        }
    }
}

private func displaySource(_ relativePath: String) -> String? {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try? String(
        contentsOf: root.appendingPathComponent(relativePath),
        encoding: .utf8)
}
