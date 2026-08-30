import ClaudioGUICore
import ClaudioLocalization
import Combine
import Foundation

@MainActor
func runSettingsPreferencesSuites() async {
    suite("Settings preferences：语言模式身份与旧值迁移") {
        expect(
            ClaudioLanguageMode.allCases == [.system, .zhHans, .english],
            "语言模式必须恰好按 system、zh-Hans、English 排列")
        expect(
            ClaudioLanguageMode(storedValue: nil) == .system
                && ClaudioLanguageMode(storedValue: "unknown") == .system,
            "缺失或未知语言值必须安全回退到 system")
        expect(
            ClaudioLanguageMode(storedValue: "zh-Hans") == .zhHans
                && ClaudioLanguageMode(storedValue: "en") == .english,
            "现有两个显式语言 raw value 必须无损迁移")
        expect(
            ClaudioLanguageMode.zhHans.resolvedLanguage(preferredLanguageIdentifiers: ["en-US"])
                == .zhHans
                && ClaudioLanguageMode.english.resolvedLanguage(
                    preferredLanguageIdentifiers: ["zh-Hans"])
                    == .english,
            "显式语言不得受 system locale 影响")
        expect(
            ClaudioLanguageMode.system.resolvedLanguage(
                preferredLanguageIdentifiers: ["fr-FR", "zh-Hans-CN", "en-US"])
                == .zhHans
                && ClaudioLanguageMode.system.resolvedLanguage(
                    preferredLanguageIdentifiers: ["fr-FR", "en-SG"])
                    == .english,
            "system 必须按首个受支持的系统语言解析，并以 English 安全兜底")
        expect(
            ClaudioLanguageMode.system.localizedName(language: .zhHans) == "跟随系统"
                && ClaudioLanguageMode.system.localizedName(language: .english)
                    == "Follow System",
            "system 模式必须有完整双语名称")
        expect(
            ClaudioLanguageMode.zhHans.localizedName(language: .zhHans) == "简体中文"
                && ClaudioLanguageMode.zhHans.localizedName(language: .english)
                    == "Simplified Chinese"
                && ClaudioLanguageMode.english.localizedName(language: .zhHans) == "English",
            "两个显式语言模式必须在两种界面语言下可识别")
    }

    suite("Settings preferences：隔离 defaults suite、持久化与损坏回退") {
        let firstSuite = "SettingsPreferencesSuite.first.\(UUID().uuidString)"
        let secondSuite = "SettingsPreferencesSuite.second.\(UUID().uuidString)"
        let firstDefaults = UserDefaults(suiteName: firstSuite)!
        let secondDefaults = UserDefaults(suiteName: secondSuite)!
        firstDefaults.removePersistentDomain(forName: firstSuite)
        secondDefaults.removePersistentDomain(forName: secondSuite)
        defer {
            firstDefaults.removePersistentDomain(forName: firstSuite)
            secondDefaults.removePersistentDomain(forName: secondSuite)
        }

        firstDefaults.set("zh-Hans", forKey: ClaudioAppLanguage.defaultsKey)
        firstDefaults.set("sounds", forKey: SettingsDestination.defaultsKey)
        let first = ClaudioPreferences(
            defaults: firstDefaults,
            notificationCenter: NotificationCenter(),
            availableSettingsDestinations: SettingsDestination.allCases,
            preferredLanguageIdentifiers: { ["en-US"] })
        expect(
            first.languageMode == .zhHans && first.language == .zhHans,
            "旧 zh-Hans 值必须恢复为显式简体中文，而不是 system")
        expect(first.lastSettingsDestination == .sounds, "合法顶层 destination 必须恢复")
        expect(
            firstDefaults.string(forKey: ClaudioAppLanguage.defaultsKey) == "zh-Hans",
            "读取旧显式值不得改写或丢失原始 raw value")

        first.setLanguageMode(.english)
        first.setLastSettingsDestination(.about)
        let restored = ClaudioPreferences(
            defaults: firstDefaults,
            notificationCenter: NotificationCenter(),
            availableSettingsDestinations: SettingsDestination.allCases,
            preferredLanguageIdentifiers: { ["zh-Hans"] })
        expect(
            restored.languageMode == .english && restored.language == .english,
            "显式 English 必须跨 owner 恢复且不跟随系统")
        expect(restored.lastSettingsDestination == .about, "顶层 destination 必须跨 owner 恢复")

        let isolated = ClaudioPreferences(
            defaults: secondDefaults,
            notificationCenter: NotificationCenter(),
            preferredLanguageIdentifiers: { ["en-US"] })
        expect(
            isolated.languageMode == .system && isolated.lastSettingsDestination == .general,
            "不同 defaults suite 不得互相泄漏偏好")
        expect(
            isolated.availableSettingsDestinations
                == [
                    .general, .integrations, .eventsAndSounds, .notifications, .display, .sounds,
                    .usage, .shortcuts, .about,
                ],
            "production owner 只能暴露已交付真实内容的通用、集成、事件、通知、显示、声音、用量、快捷键与关于 destination")
        isolated.setLastSettingsDestination(.usage)
        expect(
            isolated.lastSettingsDestination == .usage
                && secondDefaults.string(forKey: SettingsDestination.defaultsKey) == "usage",
            "已交付的 Usage destination 必须可由 production owner 持久化")

        firstDefaults.set(["broken"], forKey: ClaudioAppLanguage.defaultsKey)
        firstDefaults.set(87, forKey: SettingsDestination.defaultsKey)
        let damaged = ClaudioPreferences(
            defaults: firstDefaults,
            notificationCenter: NotificationCenter(),
            preferredLanguageIdentifiers: { ["en-US"] })
        expect(
            damaged.languageMode == .system && damaged.language == .english,
            "损坏语言值必须回退到 system 的安全投影")
        expect(
            damaged.lastSettingsDestination == .general,
            "损坏 destination 必须回退到通用")
        expect(
            damaged.recoveryIssues
                == [.invalidLanguageMode, .invalidSettingsDestination],
            "typed owner 必须发布可见失败态所需的完整恢复原因")
    }

    await suite("Settings preferences：system locale 即时重投影且多消费者一致") {
        let suiteName = "SettingsPreferencesSuite.locale.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notifications = NotificationCenter()
        let preferredLanguages = PreferredLanguageIdentifiers(["zh-Hans"])
        let preferences = ClaudioPreferences(
            defaults: defaults,
            notificationCenter: notifications,
            preferredLanguageIdentifiers: { preferredLanguages.values })

        var firstConsumer: [ClaudioPreferenceSnapshot] = []
        var secondConsumer: [ClaudioPreferenceSnapshot] = []
        let firstCancellable = preferences.$snapshot.dropFirst().sink {
            firstConsumer.append($0)
        }
        let secondCancellable = preferences.$snapshot.dropFirst().sink {
            secondConsumer.append($0)
        }

        expect(
            preferences.languageMode == .system && preferences.language == .zhHans,
            "缺省 system 必须投影当前简体中文 locale")
        preferredLanguages.values = ["en-SG"]
        DispatchQueue.global().async {
            notifications.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        }
        let updatedFromBackground = await waitForPreferenceUpdate {
            preferences.language == .english
        }
        expect(
            updatedFromBackground && preferences.languageMode == .system,
            "后台线程的 locale 通知必须安全切回 MainActor 并即时重投影 system 语言")
        expect(
            firstConsumer == secondConsumer && firstConsumer.last == preferences.snapshot,
            "多个消费者必须观察到同一份原子 typed preference snapshot")

        preferences.setLanguageMode(.zhHans)
        preferredLanguages.values = ["en-US"]
        await postLocaleChangeInBackground(notifications)
        try? await Task.sleep(nanoseconds: 20_000_000)
        expect(
            preferences.language == .zhHans,
            "显式语言模式必须忽略后续 locale 通知")
        withExtendedLifetime((firstCancellable, secondCancellable)) {}
    }

    suite("Settings preferences：owner 保持 Foundation-only 且 locale 更新无业务重建") {
        guard
            let source = settingsPreferencesSource(
                "gui/Sources/ClaudioGUICore/SettingsPreferences.swift")
        else {
            expect(false, "缺少 SettingsPreferences.swift")
            return
        }
        expect(
            source.contains("publisher(for: NSLocale.currentLocaleDidChangeNotification)")
                && source.contains("Task { @MainActor")
                && source.contains("self?.refreshSystemLanguage()")
                && !source.contains("MainActor.assumeIsolated"),
            "typed owner 必须把任意投递线程的 locale 通知安全切回 MainActor 后刷新投影")
        for forbiddenOwner in [
            "HostIntegrationManager", "SoundPackLibrary", "AICueGenerationViewModel",
        ] {
            expect(
                !source.contains(forbiddenOwner),
                "locale 重投影不得构造或拥有 \(forbiddenOwner)")
        }
    }
}

@MainActor
private func waitForPreferenceUpdate(
    timeout: TimeInterval = 1,
    condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return condition()
}

private func postLocaleChangeInBackground(_ notifications: NotificationCenter) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            notifications.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
            continuation.resume()
        }
    }
}

@MainActor
private final class PreferredLanguageIdentifiers {
    var values: [String]

    init(_ values: [String]) {
        self.values = values
    }
}

private func settingsPreferencesSource(_ relativePath: String) -> String? {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
}
