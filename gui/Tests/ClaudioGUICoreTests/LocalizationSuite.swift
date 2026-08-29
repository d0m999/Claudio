import ClaudioGUICore
import ClaudioLocalization
import Foundation

@MainActor
func runLocalizationSuites() {
    suite("Claudio localization") {
        expect(
            ClaudioAppLanguage.allCases == [.zhHans, .english],
            "language enum must expose exactly Simplified Chinese and English")
        expect(
            ClaudioAppLanguage.defaultValue == .zhHans,
            "catalog fallback must remain the Simplified Chinese source language")
        expect(ClaudioAppLanguage.zhHans.selfName == "中文", "Chinese segment must use its self-name")
        expect(ClaudioAppLanguage.english.selfName == "English", "English segment must use its self-name")

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
        expect(
            chinese.text(.soundPacksCardHint) == "选择后在右侧查看"
                && english.text(.soundPacksCardHint) == "Select to inspect on the right",
            "sound-pack rows must not advertise the removed panel-star action")
        expect(
            chinese.text(.soundPacksUseHint) == "明确切换当前使用的声音包"
                && english.text(.soundPacksUseHint) == "Explicitly switch the active sound pack",
            "use-pack help must describe only the active-pack action")
        expect(
            chinese.text(.soundPacksEmptyRestoreHint) == "恢复后可以选择和试听内置声音包"
                && english.text(.soundPacksEmptyRestoreHint)
                    == "After restoring, built-in packs can be selected and previewed",
            "factory-restore help must not promise a removed pinning control")
        expect(
            chinese.format(.soundPacksStatusPackCopied, "示例")
                == "已创建并选中「示例」。原内置包未更改；需要时可点「用这个包」。"
                && english.format(.soundPacksStatusPackCopied, "Example")
                    == "Created and selected “Example”. The built-in pack is unchanged; choose Use This Pack when needed.",
            "copy completion must not direct users to a removed star control")
        expect(
            chinese.format(.soundPacksStatusPackUsed, "示例") == "现在使用「示例」。"
                && english.format(.soundPacksStatusPackUsed, "Example")
                    == "Now using “Example”.",
            "use completion must not mention the compatibility-only starred list")
        expect(
            chinese.text(.soundPacksPackNotUsed) == "未使用"
                && english.text(.soundPacksPackNotUsed) == "Not in use",
            "pack accessibility values must not expose removed pinning state")
        expect(
            localizedSoundPackLibraryReason(
                "sound-pack-library.manifest-identity-mismatch",
                language: .zhHans) == "manifest 声音包 ID 与所在文件夹不一致"
                && localizedSoundPackLibraryReason(
                    "sound-pack-library.manifest-identity-mismatch",
                    language: .english)
                    == "The manifest sound pack ID does not match its folder",
            "manifest identity mismatch must use catalog copy in both product languages")

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

        expect(
            chinese.text(.aiCueCredentialPrivacy)
                == "声音描述和生成指令会由本机直接发送给 ElevenLabs；生成可能由 ElevenLabs 向你的账户收费；数据留存及是否用于模型改进，以你的 ElevenLabs 账户设置和其条款为准。"
                && english.text(.aiCueCredentialPrivacy)
                    == "Your sound description and generation instructions are sent directly to ElevenLabs. ElevenLabs may charge your account for generation. Retention and model-improvement use follow your ElevenLabs account and their terms.",
            "首次保存凭据前，两种语言必须同时披露直连、潜在费用与供应商数据边界")
        expect(
            !chinese.text(.aiCueCredentialPrivacyMiniMax).contains("ElevenLabs")
                && !english.text(.aiCueCredentialPrivacyMiniMax).contains("ElevenLabs")
                && chinese.text(.aiCueCredentialPrivacyQwenSingapore).contains("新加坡")
                && english.text(.aiCueCredentialPrivacyQwenSingapore).contains("Singapore")
                && chinese.text(.aiCueCredentialPrivacyQwenBeijing).contains("北京")
                && english.text(.aiCueCredentialPrivacyQwenBeijing).contains("Beijing"),
            "MiniMax/Qwen 必须逐 profile 披露供应商与 region，不能推广 ElevenLabs 条款")
        expect(
            chinese.format(
                .aiCueProviderCapabilities,
                "\(chinese.text(.aiCueModalitySpeech))，\(chinese.text(.aiCueModalityAnimal))")
                == "支持能力：语音，动物叫声"
                && english.format(
                    .aiCueProviderCapabilities,
                    "\(english.text(.aiCueModalitySpeech)), \(english.text(.aiCueModalityAnimal))")
                    == "Capabilities: speech, animal calls",
            "Provider 能力必须由可组合的双语 modality 文案和语言对应分隔符投影")
        expect(
            !chinese.text(.aiCueErrorCredentialRequired).contains("ElevenLabs")
                && !english.text(.aiCueErrorCredentialRequired).contains("ElevenLabs")
                && !chinese.text(.aiCueErrorCredits).contains("ElevenLabs")
                && !english.text(.aiCueErrorCredits).contains("ElevenLabs")
                && !chinese.text(.aiCueErrorRateLimited).contains("ElevenLabs")
                && !english.text(.aiCueErrorRateLimited).contains("ElevenLabs"),
            "共享 credential/额度/限流错误不得把一家供应商名称推广到其他 profile")
        expect(
            chinese.text(.aiCueEligibilityGlobal) == "请选择一个明确的事件来源，以隔离生成声音。"
                && english.text(.aiCueEligibilityGlobal)
                    == "Choose a specific event source to keep generated sounds isolated.",
            "AI 提示音资格文案必须使用事件来源领域词汇，不得退回应用来源")
        expect(
            chinese.format(.aiCueCandidateDuration, "1.2") == "1.2 秒"
                && english.format(.aiCueCandidateDuration, "1.2") == "1.2 s",
            "候选时长单位必须由 localization catalog 按当前语言呈现")

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
