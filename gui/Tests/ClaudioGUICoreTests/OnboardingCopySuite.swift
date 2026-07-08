import ClaudioGUICore
import Foundation

// MARK: - onboardingCopy(for:): reassurance-toned text per state (T7 acceptance 2 + 3)
//
// Every state must have non-empty title/body and, except `.installed`, a non-nil
// primary CTA label (acceptance 2: "其余各态文案+CTA 正确"). None of the
// user-visible copy (title/body/CTA labels — not the opt-in `detail`) may contain raw
// engineering vocabulary (acceptance 3: 不写"写入 hook 到 settings.json"这类工程语).

/// Jargon terms the primary-voice copy (title/body/CTA labels) must never surface
/// directly — these are the exact nouns ENGINEERING.md's contract is written in
/// (`hooks`, `settings.json`, the CLI's own name), which a non-technical user shouldn't
/// need to know. `detail` is exempt by design (see `OnboardingCopy.swift`'s doc comment):
/// it's the opt-in, secondary "查看原因" disclosure, not primary voice.
private let forbiddenJargon = ["settings.json", "hook", "claudio install", "claudio play"]

private func containsJargon(_ text: String) -> Bool {
    let lowered = text.lowercased()
    return forbiddenJargon.contains { lowered.contains($0.lowercased()) }
}

@MainActor
func runOnboardingCopySuites() {
    let allStatesWithLabels: [(String, OnboardingState)] = [
        ("claudeCodeNotInstalled", .claudeCodeNotInstalled),
        ("helperMissing", .helperMissing),
        ("settingsNotWritable", .settingsNotWritable(reason: "settings.json 存在但不可写：/x")),
        ("settingsParseFailure", .settingsParseFailure(reason: "解析失败：corrupt")),
        ("notInstalled", .notInstalled),
        ("installed", .installed),
    ]

    suite("every state has a non-empty title and body") {
        for (label, state) in allStatesWithLabels {
            let copy = onboardingCopy(for: state)
            expect(!copy.title.isEmpty, "\(label): title must not be empty")
            expect(!copy.body.isEmpty, "\(label): body must not be empty")
        }
    }

    suite("every state except .installed has a primary CTA; .installed has none") {
        for (label, state) in allStatesWithLabels {
            let copy = onboardingCopy(for: state)
            if state == .installed {
                expect(
                    copy.primaryActionTitle == nil,
                    "\(label): .installed is the terminal state, expected no primary CTA")
            } else {
                expect(
                    copy.primaryActionTitle?.isEmpty == false,
                    "\(label): expected a non-empty primary CTA label, got \(String(describing: copy.primaryActionTitle))"
                )
            }
        }
    }

    suite("only the two settings-error states expose a `detail` reason") {
        for (label, state) in allStatesWithLabels {
            let copy = onboardingCopy(for: state)
            let expectsDetail = (label == "settingsNotWritable" || label == "settingsParseFailure")
            expect(
                (copy.detail != nil) == expectsDetail,
                "\(label): detail presence mismatch (expected present=\(expectsDetail))")
        }
    }

    suite("only the two settings-error states expose a secondary '查看原因' CTA; .installed exposes '断开连接'") {
        for (label, state) in allStatesWithLabels {
            let copy = onboardingCopy(for: state)
            switch label {
            case "settingsNotWritable", "settingsParseFailure":
                expect(
                    copy.secondaryActionTitle != nil,
                    "\(label): expected a secondary CTA (查看原因)")
            case "installed":
                expect(
                    copy.secondaryActionTitle != nil,
                    "installed: expected a secondary CTA (断开连接) honoring '随时一键撤销'")
            default:
                expect(
                    copy.secondaryActionTitle == nil,
                    "\(label): expected no secondary CTA, got \(String(describing: copy.secondaryActionTitle))"
                )
            }
        }
    }

    suite("title/body/CTA labels never surface raw engineering jargon (acceptance criterion 3)") {
        for (label, state) in allStatesWithLabels {
            let copy = onboardingCopy(for: state)
            expect(!containsJargon(copy.title), "\(label): title must not contain engineering jargon: \(copy.title)")
            expect(!containsJargon(copy.body), "\(label): body must not contain engineering jargon: \(copy.body)")
            if let primary = copy.primaryActionTitle {
                expect(!containsJargon(primary), "\(label): primary CTA must not contain engineering jargon: \(primary)")
            }
            if let secondary = copy.secondaryActionTitle {
                expect(!containsJargon(secondary), "\(label): secondary CTA must not contain engineering jargon: \(secondary)")
            }
        }
    }

    suite("settingsNotWritable/settingsParseFailure: `detail` carries the exact reason string through untouched") {
        let writabilityReason = "settings.json 存在但不可写：/Users/tester/.claude/settings.json"
        let notWritableCopy = onboardingCopy(for: .settingsNotWritable(reason: writabilityReason))
        expect(
            notWritableCopy.detail == writabilityReason,
            "settingsNotWritable detail must equal the reason verbatim (progressive disclosure, not a rewrite)"
        )

        let parseReason = "settings.json 解析失败，已中止（未修改文件）：some decoder message"
        let parseFailureCopy = onboardingCopy(for: .settingsParseFailure(reason: parseReason))
        expect(
            parseFailureCopy.detail == parseReason,
            "settingsParseFailure detail must equal the reason verbatim")
    }

    suite("copy is a pure function of state: calling twice for the same state returns equal copy") {
        for (label, state) in allStatesWithLabels {
            let first = onboardingCopy(for: state)
            let second = onboardingCopy(for: state)
            expect(first == second, "\(label): onboardingCopy(for:) must be deterministic")
        }
    }
}
