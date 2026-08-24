import ClaudioLocalization
import Foundation

@MainActor
func runLocalizationSuites() {
    suite("Claudio localization") {
        expect(
            ClaudioAppLanguage.allCases == [.zhHans, .english],
            "language enum must expose exactly Simplified Chinese and English")
        expect(ClaudioAppLanguage.defaultValue == .zhHans, "first launch must default to zh-Hans")
        expect(
            ClaudioAppLanguage(storedValue: nil) == .zhHans,
            "missing persisted language must fall back to zh-Hans")
        expect(
            ClaudioAppLanguage(storedValue: "invalid") == .zhHans,
            "invalid persisted language must fall back to zh-Hans")
        expect(ClaudioAppLanguage(storedValue: "en") == .english, "English raw value must round-trip")
        expect(ClaudioAppLanguage.zhHans.selfName == "中文", "Chinese segment must use its self-name")
        expect(ClaudioAppLanguage.english.selfName == "English", "English segment must use its self-name")

        let suiteName = "ClaudioLocalizationSuite.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = ClaudioLanguageStore(defaults: defaults)
        expect(store.language == .zhHans, "new language store must publish zh-Hans")
        store.setLanguage(.english)
        expect(store.language == .english, "setLanguage must publish immediately")
        expect(
            defaults.string(forKey: ClaudioAppLanguage.defaultsKey) == "en",
            "setLanguage must persist the explicit raw value")
        let restored = ClaudioLanguageStore(defaults: defaults)
        expect(restored.language == .english, "a new store must restore the persisted language")
        defaults.set("not-a-language", forKey: ClaudioAppLanguage.defaultsKey)
        expect(
            ClaudioLanguageStore(defaults: defaults).language == .zhHans,
            "a persisted unknown value must not leak into the UI")
        defaults.removePersistentDomain(forName: suiteName)

        let chinese = ClaudioL10n(language: .zhHans)
        let english = ClaudioL10n(language: .english)
        expect(
            chinese.text(.interfaceTitle) == "界面",
            "explicit zh-Hans lookup must not depend on Locale.current")
        expect(
            english.text(.interfaceTitle) == "Interface",
            "explicit English lookup must not depend on Locale.current")
        expect(
            chinese.format(.panelHeader, Int64(2)).contains("2"),
            "Chinese format placeholders must be substituted")
        expect(
            english.format(.panelHeader, Int64(2)).contains("2"),
            "English format placeholders must be substituted")
        expect(
            chinese.plural(.panelAudibleEventsCount, count: 1) == "1 个可听事件",
            "Chinese singular plural entry must resolve")
        expect(
            english.plural(.panelAudibleEventsCount, count: 2) == "2 audible events",
            "English other plural entry must resolve")
        expect(
            chinese.text(.panelQuitApplication) == "退出 claudi0",
            "quit accessibility label must use the exact approved Chinese copy")
        expect(
            english.text(.panelQuitApplication) == "Quit claudi0",
            "quit accessibility label must have the approved English copy")
        expect(
            !chinese.text(.panelQuitApplicationHint).isEmpty
                && !english.text(.panelQuitApplicationHint).isEmpty,
            "quit accessibility hint must exist in both product languages")

        let axUnavailableQualification = ClaudioL10nKey(
            rawValue: "qualification.accessibility-beta-unavailable")
        expect(
            ClaudioL10nKey.allKnown.contains(axUnavailableQualification),
            "Accessibility Beta unavailable qualification must be a registered catalog key")
        expect(
            chinese.text(axUnavailableQualification) == "Accessibility Beta 候选尚未实现",
            "Accessibility Beta unavailable qualification must have approved zh-Hans copy")
        expect(
            english.text(axUnavailableQualification)
                == "Accessibility Beta candidate is not implemented",
            "Accessibility Beta unavailable qualification must have approved English copy")

        let values = ClaudioL10n.catalogValues()
        let pluralValues = ClaudioL10n.catalogPluralValues()
        let knownKeys = ClaudioL10nKey.allKnown.map(\.rawValue)
        expect(Set(knownKeys).count == knownKeys.count, "allKnown localization keys must be unique")
        expect(
            Set(knownKeys) == Set(values.keys),
            "every registered key must have a catalog entry and no unregistered entry may exist")
        expect(
            ClaudioL10n.missingEnglishKeys().isEmpty,
            "every catalog entry must have an English string or plural")
        for key in ClaudioL10nKey.allKnown {
            let source = values[key.rawValue] ?? [:]
            let englishValues = values[key.rawValue]?[ClaudioAppLanguage.english.rawValue] ?? ""
            let chineseValues = source[ClaudioAppLanguage.zhHans.rawValue] ?? ""
            let sourcePlural = pluralValues[key.rawValue]?[ClaudioAppLanguage.zhHans.rawValue] ?? [:]
            let englishPlural = pluralValues[key.rawValue]?[ClaudioAppLanguage.english.rawValue] ?? [:]
            expect(
                (!chineseValues.isEmpty || !sourcePlural.isEmpty)
                    && (!englishValues.isEmpty || !englishPlural.isEmpty),
                "catalog languages must both be present for \(key.rawValue)")
            let chinesePlaceholders = Set(
                placeholders(in: chineseValues)
                    + sourcePlural.values.flatMap { placeholders(in: $0) })
            let englishPlaceholders = Set(
                placeholders(in: englishValues)
                    + englishPlural.values.flatMap { placeholders(in: $0) })
            expect(
                chinesePlaceholders == englishPlaceholders,
                "placeholder signature must match for \(key.rawValue): \(chinesePlaceholders) vs \(englishPlaceholders)")
        }
    }
}

private func placeholders(in value: String) -> [String] {
    let pattern = #"%(?:\d+\$)?(?:lld|ld|d|f|@|s)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return regex.matches(in: value, range: range).compactMap {
        Range($0.range, in: value).map { String(value[$0]) }
    }
}
