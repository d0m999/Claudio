import Foundation

private func multiProviderPrototypeRepositoryRoot(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

private func multiProviderPrototypeSource(_ relativePath: String) -> String? {
    try? String(
        contentsOf: multiProviderPrototypeRepositoryRoot().appendingPathComponent(relativePath),
        encoding: .utf8)
}

private func multiProviderPrototypeSection(
    _ source: String,
    from startMarker: String,
    to endMarker: String
) -> String? {
    guard
        let start = source.range(of: startMarker),
        let end = source.range(
            of: endMarker,
            range: start.upperBound..<source.endIndex)
    else {
        return nil
    }
    return String(source[start.lowerBound..<end.lowerBound])
}

private func multiProviderPrototypeOccurrences(of needle: String, in source: String) -> Int {
    source.components(separatedBy: needle).count - 1
}

private func multiProviderPrototypeCollapsed(_ source: String) -> String {
    source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

@MainActor
func runMultiProviderPrototypeContractSuites() {
    suite("multi-provider prototype pins the four-profile allowlist and unknown fallback") {
        guard
            let html = multiProviderPrototypeSource(
                "mockups/ai-app-manager-native-macos.html"),
            let profiles = multiProviderPrototypeSection(
                html,
                from: "const ttsProviderProfiles = [",
                to: "const initialTTSStageKey"),
            let profileResolution = multiProviderPrototypeSection(
                html,
                from: "const initialTTSProfileID",
                to: "const ttsCredentialStates")
        else {
            expect(false, "必须能读取多 Provider 原型的 profile 合同")
            return
        }

        let expectedProfileIDs = [
            "elevenlabs-global", "minimax-global", "qwen-singapore", "qwen-beijing",
        ]
        expect(
            multiProviderPrototypeOccurrences(of: "id: '", in: profiles) == 4,
            "原型 registry 必须且只能声明四个 profile fixture")
        for profileID in expectedProfileIDs {
            expect(
                multiProviderPrototypeOccurrences(of: "id: '\(profileID)'", in: profiles) == 1,
                "原型 registry 必须恰好声明一次 \(profileID)")
        }

        let collapsedResolution = multiProviderPrototypeCollapsed(profileResolution)
        expect(
            collapsedResolution.contains(
                "ttsProviderProfiles.some(profile => profile.id === initialTTSProfileID)"
                    + " ? initialTTSProfileID : 'elevenlabs-global';"),
            "未知或缺省 profile 必须回落到 elevenlabs-global")
    }

    suite("legacy credential ready is an ElevenLabs-only compatibility alias") {
        guard
            let html = multiProviderPrototypeSource(
                "mockups/ai-app-manager-native-macos.html"),
            let credentialFixtures = multiProviderPrototypeSection(
                html,
                from: "const ttsCredentialStates = {",
                to: "const ttsPendingReplacementPreviousStates"),
            let compatibility = multiProviderPrototypeSection(
                html,
                from: "const initialTTSCredentialValue",
                to: "if (ttsCredentialStates[selectedTTSProfileID] === 'pending')")
        else {
            expect(false, "必须能读取原型的 credential fixture 合同")
            return
        }

        for fixture in [
            "'elevenlabs-global': 'verified'",
            "'minimax-global': 'missing'",
            "'qwen-singapore': 'deferred'",
            "'qwen-beijing': 'unavailable'",
        ] {
            expect(
                credentialFixtures.contains(fixture),
                "原型必须保留固定 credential fixture：\(fixture)")
        }

        let collapsedCompatibility = multiProviderPrototypeCollapsed(compatibility)
        expect(
            collapsedCompatibility.contains(
                "initialTTSCredentialValue === 'ready'"
                    + " && selectedTTSProfileID === 'elevenlabs-global'"),
            "credential=ready 只能把 elevenlabs-global 解释为 verified")
        expect(
            !collapsedCompatibility.contains(
                "if (initialTTSCredentialValue === 'ready')"),
            "credential=ready 不得无条件覆盖 MiniMax/Qwen fixture 状态")
    }

    suite("prototype compatibility boundary is synchronized across both plans") {
        let ttsPlan = multiProviderPrototypeSource("plan/PLAN-CONSUMER-TTS-EXECUTION.md")
        let settingsPlan = multiProviderPrototypeSource("plan/PLAN-SETTINGS-EXPERIENCE.md")
        for (name, plan) in [("TTS", ttsPlan), ("settings", settingsPlan)] {
            expect(plan != nil, "必须能读取 \(name) plan")
            expect(
                plan?.contains("credential=ready") == true
                    && plan?.contains("elevenlabs-global") == true
                    && plan?.contains("MiniMax/Qwen") == true,
                "\(name) plan 必须记录 ready 的 ElevenLabs-only 兼容边界")
        }
    }
}
