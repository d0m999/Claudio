import ClaudioGUICore
import ClaudioLocalization
import Combine
import Foundation

@MainActor
func runDisplayPreferencesSuites() {
    suite("Display preferences：三档宽度身份、默认值与双语名称") {
        expect(
            ClaudioPanelWidthPreference.allCases == [.automatic, .compact, .roomy],
            "面板宽度必须恰好按 automatic、compact、roomy 排列")
        expect(
            ClaudioPanelWidthPreference(storedValue: nil) == .automatic
                && ClaudioPanelWidthPreference(storedValue: "future") == .automatic,
            "缺失或未知宽度值必须安全回退到 automatic")
        expect(
            ClaudioPanelWidthPreference.defaultsKey == "Claudio.PanelWidthPreference",
            "面板宽度必须有唯一稳定 defaults key")
        expect(
            ClaudioPanelWidthPreference.allCases.map {
                $0.localizedDisplayName(.zhHans)
            } == ["自动", "紧凑", "宽松"]
                && ClaudioPanelWidthPreference.allCases.map {
                    $0.localizedDisplayName(.english)
                } == ["Automatic", "Compact", "Roomy"],
            "三档面板宽度必须有完整双语名称")
    }

    suite("Display preferences：三宽度 × 四文字档 × 双语全部经过内容安全下限") {
        // Independent contract fixtures: each row pins the content-width audit for one locale and
        // text tier, plus the three expected effective choices in allCases order. This deliberately
        // does not reproduce the production switch, so a mutated floor or mode mapping fails.
        let fixtures: [PanelWidthFixture] = [
            .init(.zhHans, .compact, safeMinimum: 312, effectiveWidths: [356, 312, 400]),
            .init(.zhHans, .standard, safeMinimum: 312, effectiveWidths: [356, 312, 400]),
            .init(.zhHans, .large, safeMinimum: 336, effectiveWidths: [368, 336, 400]),
            .init(.zhHans, .maximum, safeMinimum: 368, effectiveWidths: [384, 368, 400]),
            .init(.english, .compact, safeMinimum: 320, effectiveWidths: [360, 320, 400]),
            .init(.english, .standard, safeMinimum: 328, effectiveWidths: [364, 328, 400]),
            .init(.english, .large, safeMinimum: 360, effectiveWidths: [380, 360, 400]),
            .init(.english, .maximum, safeMinimum: 392, effectiveWidths: [396, 392, 400]),
        ]
        expect(fixtures.count == 8, "双语 × 四文字档必须恰好有八份独立内容宽度 fixture")

        for fixture in fixtures {
            expect(
                panelContentSafeMinimumWidth(
                    language: fixture.language,
                    interfaceTextSize: fixture.textSize) == fixture.safeMinimum,
                "内容安全下限偏离审计 fixture：\(fixture.language) / \(fixture.textSize)")
            let resolutions = ClaudioPanelWidthPreference.allCases.map {
                panelWidthResolution(
                    preference: $0,
                    language: fixture.language,
                    interfaceTextSize: fixture.textSize)
            }
            expect(
                resolutions.map(\.effectiveWidth) == fixture.effectiveWidths,
                "三档实际宽度偏离独立 fixture：\(fixture.language) / \(fixture.textSize)")
            expect(
                Set(resolutions.map(\.effectiveWidth)).count == 3,
                "automatic、compact、roomy 必须保持三种可区分行为："
                    + "\(fixture.language) / \(fixture.textSize)")
            expect(
                resolutions.allSatisfy { $0.effectiveWidth >= fixture.safeMinimum },
                "三档宽度都不得低于内容安全下限：\(fixture.language) / \(fixture.textSize)")
        }
    }

    suite("Display preferences：typed owner 持久化、原子观察与损坏回落") {
        let suiteName = "DisplayPreferencesSuite.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("large", forKey: ClaudioInterfaceTextSize.defaultsKey)
        defaults.set("compact", forKey: ClaudioPanelWidthPreference.defaultsKey)
        defaults.set(false, forKey: ClaudioPreferences.menuBarStatusDotDefaultsKey)
        let preferences = ClaudioPreferences(
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            preferredLanguageIdentifiers: { ["en-US"] })
        expect(
            preferences.interfaceTextSize == .large
                && preferences.panelWidthPreference == .compact
                && !preferences.showsMenuBarStatusDot,
            "typed owner 必须从同一 snapshot 恢复三项显示偏好")
        expect(
            preferences.availableSettingsDestinations
                == [
                    .general, .integrations, .eventsAndSounds, .notifications, .display, .sounds,
                    .usage,
                ],
            "production owner 必须在现有目的页中暴露已交付的 Display 与 Usage destination")

        var firstConsumer: [ClaudioPreferenceSnapshot] = []
        var secondConsumer: [ClaudioPreferenceSnapshot] = []
        let firstCancellable = preferences.$snapshot.dropFirst().sink {
            firstConsumer.append($0)
        }
        let secondCancellable = preferences.$snapshot.dropFirst().sink {
            secondConsumer.append($0)
        }
        preferences.setInterfaceTextSize(.maximum)
        preferences.setPanelWidthPreference(.roomy)
        preferences.setShowsMenuBarStatusDot(true)
        expect(
            firstConsumer == secondConsumer && firstConsumer.count == 3
                && firstConsumer.last == preferences.snapshot,
            "Panel Aa 与 Display 页等多个消费者必须观察同一份原子 snapshot")
        expect(
            defaults.string(forKey: ClaudioInterfaceTextSize.defaultsKey) == "maximum"
                && defaults.string(forKey: ClaudioPanelWidthPreference.defaultsKey) == "roomy"
                && defaults.bool(forKey: ClaudioPreferences.menuBarStatusDotDefaultsKey),
            "三项显示偏好必须只由 typed owner 写回各自稳定 key")
        withExtendedLifetime((firstCancellable, secondCancellable)) {}

        defaults.set(["broken"], forKey: ClaudioInterfaceTextSize.defaultsKey)
        defaults.set("sideways", forKey: ClaudioPanelWidthPreference.defaultsKey)
        defaults.set("yes", forKey: ClaudioPreferences.menuBarStatusDotDefaultsKey)
        let damaged = ClaudioPreferences(
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            preferredLanguageIdentifiers: { ["zh-Hans"] })
        expect(
            damaged.interfaceTextSize == .standard
                && damaged.panelWidthPreference == .automatic
                && damaged.showsMenuBarStatusDot,
            "未知或损坏显示值必须回落到 standard、automatic、显示状态点")
        expect(
            damaged.recoveryIssues.isSuperset(of: [
                .invalidInterfaceTextSize, .invalidPanelWidthPreference,
                .invalidMenuBarStatusDot,
            ]),
            "typed owner 必须发布三种显示偏好损坏原因")
    }

    suite("Display preferences：状态点只切换 Orbit Zero 变体且保留完整 VoiceOver 状态") {
        for language in ClaudioAppLanguage.allCases {
            expect(
                !ClaudioL10n(language: language).text(.settingsDisplay.statusRunning).isEmpty,
                "关闭视觉状态点后 VoiceOver 必须继续播报同一份完整运行状态")
        }
    }

    suite("Display preferences：所有生产消费者只观察共享 typed owner") {
        let paths = [
            "gui/Sources/ClaudioGUI/PanelView.swift",
            "gui/Sources/ClaudioGUI/EventSettingsWindowView.swift",
            "gui/Sources/ClaudioGUI/IntegrationsWindowView.swift",
            "gui/Sources/SoundPacksWindow/SoundPacksWindowView.swift",
        ]
        for path in paths {
            guard let source = displayPreferenceSource(path) else {
                expect(false, "读不到显示偏好消费者：\(path)")
                continue
            }
            expect(
                source.contains("ClaudioPreferences")
                    && source.contains("languageStore.interfaceTextSize")
                    && !source.contains("@AppStorage(ClaudioInterfaceTextSize.defaultsKey)"),
                "\(path) 必须消费共享 typed owner，不能保留第二个 raw defaults 真相源")
        }

        guard
            let settings = displayPreferenceSource(
                "gui/Sources/ClaudioGUI/SettingsWindowView.swift"),
            let controller = displayPreferenceSource(
                "gui/Sources/ClaudioGUI/MenuBarController.swift"),
            let icon = displayPreferenceSource("gui/Sources/ClaudioGUI/MenuBarIcon.swift")
        else {
            expect(false, "读不到 Display、MenuBarController 或 MenuBarIcon wiring")
            return
        }
        expect(
            settings.contains("destination == .display")
                && settings.contains("preferences.setInterfaceTextSize($0)")
                && settings.contains("preferences.setPanelWidthPreference($0)")
                && settings.contains("preferences.setShowsMenuBarStatusDot($0)")
                && settings.contains("managesFocus: false"),
            "Display destination 必须接到共享 typed owner，并服从 Settings 窗口焦点")
        expect(
            controller.contains("languageStore.$snapshot")
                && controller.contains("applyMenuBarIcon")
                && !controller.contains("removeStatusItem")
                && !controller.contains("statusItem.isVisible"),
            "状态点变化只能更新已存在 status item 的图标与 VoiceOver 文案")
        expect(
            icon.contains("if showsStatusDot")
                && icon.contains("image.isTemplate = true"),
            "MenuBarIcon 必须只在 activity 变体绘制状态点，并保持 template image")
    }
}

private struct PanelWidthFixture {
    let language: ClaudioAppLanguage
    let textSize: ClaudioInterfaceTextSize
    let safeMinimum: Double
    let effectiveWidths: [Double]

    init(
        _ language: ClaudioAppLanguage,
        _ textSize: ClaudioInterfaceTextSize,
        safeMinimum: Double,
        effectiveWidths: [Double]
    ) {
        self.language = language
        self.textSize = textSize
        self.safeMinimum = safeMinimum
        self.effectiveWidths = effectiveWidths
    }
}

private func displayPreferenceSource(_ relativePath: String) -> String? {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
}
