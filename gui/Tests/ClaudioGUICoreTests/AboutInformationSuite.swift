import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

@MainActor
private final class AboutActionProbe {
    var copiedValues: [String] = []
    var openedURLs: [URL] = []
    var copySucceeds = true
    var openSucceeds = false

    func copy(_ value: String) -> Bool {
        copiedValues.append(value)
        return copySucceeds
    }

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return openSucceeds
    }
}

@MainActor
func runAboutInformationSuites() {
    suite("About bundle facts are honest pure values") {
        let facts = projectAboutBundleFacts(
            AboutBundleFactsInput(
                brandName: " Orbit Zero ",
                productName: "claudi0",
                version: "0.1.0",
                build: "42",
                architecture: "arm64",
                minimumSystemVersion: "12.0",
                operatingSystemVersion: "15.6.1"))
        expect(facts.brandName == "Orbit Zero", "brand must trim bundle whitespace")
        expect(facts.productName == "claudi0", "product must come from the supplied bundle fact")
        expect(facts.version == "0.1.0" && facts.build == "42", "version/build must stay exact")
        expect(
            facts.architecture == "arm64"
                && facts.minimumSystemVersion == "12.0"
                && facts.operatingSystemVersion == "15.6.1",
            "architecture and macOS facts must stay exact")

        let missing = projectAboutBundleFacts(
            AboutBundleFactsInput(
                brandName: "  ",
                productName: "bad\nname",
                version: "/Users/private/version",
                build: "secret value",
                architecture: nil,
                minimumSystemVersion: "12.0 beta",
                operatingSystemVersion: ""))
        expect(
            missing.brandName == nil && missing.productName == nil && missing.version == nil
                && missing.build == nil && missing.architecture == nil
                && missing.minimumSystemVersion == nil
                && missing.operatingSystemVersion == nil,
            "missing/control/path-like bundle fields must become unknown rather than leak or fabricate"
        )
    }

    suite("About diagnostic redacts rich host rows to closed semantic facts") {
        let secret = "SENSITIVE_SENTINEL"
        let rows = [
            HostSourceRowPresentation(
                host: .claudeCode,
                title: secret,
                readinessText: secret,
                detailText: secret,
                status: .ready,
                accessibilityLabel: secret),
            HostSourceRowPresentation(
                host: .workBuddy,
                title: secret,
                readinessText: secret,
                detailText: secret,
                status: .needsAttention,
                accessibilityLabel: secret),
            HostSourceRowPresentation(
                host: .chatGPTDesktopAX,
                title: secret,
                readinessText: secret,
                detailText: secret,
                status: .needsAttention,
                accessibilityLabel: secret),
        ]
        let surfaces = aboutSurfaceFacts(from: rows)
        expect(
            surfaces
                == [
                    AboutSurfaceFact(host: .claudeCode, state: .ready)!,
                    AboutSurfaceFact(host: .workBuddy, state: .needsAttention)!,
                ],
            "only published product Surfaces and their semantic enum may survive redaction")
        expect(
            HostID.productVisibleCases.allSatisfy {
                AboutSurfaceFact(host: $0, state: .ready) != nil
            } && AboutSurfaceFact(host: .chatGPTDesktopAX, state: .ready) == nil
                && AboutSurfaceFact(host: .claudeDesktopAX, state: .ready) == nil,
            "About Surface facts must follow the product registry and reject diagnostic-only AX identities"
        )

        let summary = makeAboutDiagnosticSummary(
            AboutDiagnosticFacts(
                bundle: projectAboutBundleFacts(
                    AboutBundleFactsInput(
                        brandName: secret,
                        productName: secret,
                        version: "0.1.0",
                        build: "42",
                        architecture: "arm64",
                        minimumSystemVersion: "12.0",
                        operatingSystemVersion: "15.6.1")),
                surfaces: surfaces,
                paths: [
                    AboutPathExistenceFact(kind: .applicationBundle, exists: true),
                    AboutPathExistenceFact(kind: .bundledHelper, exists: false),
                ]))
        expect(summary.contains("claudi0-version: 0.1.0"), "summary must include safe version")
        expect(summary.contains("surface.claude-code: ready"), "summary must include Surface state")
        expect(
            summary.contains("path.application-bundle: present"), "summary must include path bit")
        expect(
            summary.contains("path.bundled-helper: missing"),
            "summary must include missing path bit")
        expect(!summary.contains(secret), "diagnostic must discard every rich-row free-form field")
        expect(!summary.contains("Orbit Zero"), "diagnostic must not copy display-only identity")
    }

    suite("About diagnostic production sources do not access sensitive domains") {
        let root = guiTestRepositoryRoot()
        let sourcePaths = [
            "gui/Sources/ClaudioGUICore/AboutInformation.swift",
            "gui/Sources/ClaudioGUICore/AboutSettingsModel.swift",
            "gui/Sources/ClaudioGUI/AboutSettingsModel.swift",
            "gui/Sources/ClaudioSettingsPresentation/AboutSettingsView.swift",
        ]
        let sources = sourcePaths.compactMap {
            try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
        }
        expect(sources.count == sourcePaths.count, "static scanner must read every About source")
        let joined = sources.joined(separator: "\n")
        let forbiddenAccesses = [
            "configurationSource", "latestReceipt", "HostHookReceipt", "SensitiveCredentialInput",
            "AICueCandidate", "providerResponse", "UsageDiagnosticFailure", "ClaudioConfig",
            "FocusQuiet", "EKEventStore", "ClaudioPaths", "soundDescription",
            "AICueHTTPRequest", "AICueHTTPResponse", "selectedPack", "packCards",
            "UsageDiagnosticLogSnapshot",
        ]
        for forbidden in forbiddenAccesses {
            expect(
                !joined.contains(forbidden),
                "About production source must not access sensitive field/domain: \(forbidden)")
        }
    }

    suite("About bundled path validation rejects links, escapes, and wrong shapes") {
        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "claudio-about-paths-\(UUID().uuidString)",
            isDirectory: true)
        let resourcesRoot = fixtureRoot.appendingPathComponent("Resources", isDirectory: true)
        let packs = resourcesRoot.appendingPathComponent("packs", isDirectory: true)
        let regularFile = packs.appendingPathComponent("LICENSES.md")
        let outsideFile = fixtureRoot.appendingPathComponent("private.txt")
        let linkedFile = packs.appendingPathComponent("LINKED.md")
        let linkedDirectory = resourcesRoot.appendingPathComponent("linked-packs")
        let fileBelowLinkedDirectory = linkedDirectory.appendingPathComponent("LICENSES.md")
        defer { try? fileManager.removeItem(at: fixtureRoot) }

        do {
            try fileManager.createDirectory(at: packs, withIntermediateDirectories: true)
            try Data("attribution".utf8).write(to: regularFile)
            try Data("private".utf8).write(to: outsideFile)
            try fileManager.createSymbolicLink(at: linkedFile, withDestinationURL: regularFile)
            try fileManager.createSymbolicLink(at: linkedDirectory, withDestinationURL: packs)
        } catch {
            expect(false, "About path fixture setup must succeed: \(error)")
            return
        }

        expect(
            isSafeAboutBundledPath(
                regularFile,
                resourcesRoot: resourcesRoot,
                itemKind: .regularFile),
            "a real regular file under the resource root must be accepted")
        expect(
            isSafeAboutBundledPath(
                packs,
                resourcesRoot: resourcesRoot,
                itemKind: .directory),
            "a real directory under the resource root must be accepted")
        expect(
            !isSafeAboutBundledPath(
                regularFile,
                resourcesRoot: resourcesRoot,
                itemKind: .directory)
                && !isSafeAboutBundledPath(
                    packs,
                    resourcesRoot: resourcesRoot,
                    itemKind: .regularFile),
            "wrong filesystem shapes must fail closed")
        expect(
            !isSafeAboutBundledPath(
                linkedFile,
                resourcesRoot: resourcesRoot,
                itemKind: .regularFile)
                && !isSafeAboutBundledPath(
                    linkedDirectory,
                    resourcesRoot: resourcesRoot,
                    itemKind: .directory)
                && !isSafeAboutBundledPath(
                    fileBelowLinkedDirectory,
                    resourcesRoot: resourcesRoot,
                    itemKind: .regularFile),
            "symbolic-link files, directories, and intermediate components must fail closed")
        expect(
            !isSafeAboutBundledPath(
                outsideFile,
                resourcesRoot: resourcesRoot,
                itemKind: .regularFile),
            "a real file outside the resource root must fail closed")
    }

    suite("About behavior model maps injected copy, open, and Surface outcomes") {
        let licenseURL = URL(fileURLWithPath: "/fixed-bundle/LICENSE")
        let license = AboutBundledResource(kind: .openSourceLicense, url: licenseURL)
        let missingPrivacy = AboutBundledResource(kind: .privacyStatement, url: nil)
        let actionProbe = AboutActionProbe()
        let model = AboutSettingsModel(
            bundleFacts: projectAboutBundleFacts(
                AboutBundleFactsInput(
                    brandName: "Orbit Zero",
                    productName: "claudi0",
                    version: "0.1.0",
                    build: "42",
                    architecture: "arm64",
                    minimumSystemVersion: "12.0",
                    operatingSystemVersion: "15.6.1")),
            resources: [license, missingPrivacy],
            pathFacts: [
                AboutPathExistenceFact(kind: .openSourceLicense, exists: true),
                AboutPathExistenceFact(kind: .privacyStatement, exists: false),
            ],
            surfaceFacts: [AboutSurfaceFact(host: .claudeCode, state: .ready)!],
            actions: AboutSettingsActions(
                copy: { actionProbe.copy($0) },
                open: { actionProbe.open($0) }))

        model.copyVersionInformation(language: .english)
        expect(model.feedback == .versionCopied, "successful version copy must publish success")
        expect(
            actionProbe.copiedValues.last?.contains("Version: 0.1.0") == true,
            "version copy must send projected, localized facts to the adapter")

        actionProbe.copySucceeds = false
        model.copyDiagnostics()
        expect(model.feedback == .clipboardFailed, "failed diagnostic copy must be visible")
        expect(
            actionProbe.copiedValues.last == model.diagnosticSummary,
            "diagnostic copy must send only the safe summary to the adapter")

        model.openResource(missingPrivacy)
        expect(
            model.feedback == .resourceOpenFailed(.privacyStatement)
                && actionProbe.openedURLs.isEmpty,
            "missing resource must fail visibly without calling the open adapter")
        model.openResource(license)
        expect(
            model.feedback == .resourceOpenFailed(.openSourceLicense)
                && actionProbe.openedURLs == [licenseURL],
            "open adapter failure must preserve the fixed resource identity")
        actionProbe.openSucceeds = true
        model.openResource(license)
        expect(model.feedback == nil, "successful open must clear prior resource feedback")

        let replacement = [AboutSurfaceFact(host: .workBuddy, state: .legacy)!]
        model.replaceSurfaceFacts(replacement)
        expect(
            model.surfaceFacts == replacement
                && model.diagnosticSummary.contains("surface.workbuddy: legacy"),
            "Surface replacement must update the redacted diagnostic and no richer value")
    }

    suite("About GUI exposes only ticket-scoped actions and visible failures") {
        let root = guiTestRepositoryRoot()
        let view =
            (try? String(
                contentsOf: root.appendingPathComponent(
                    "gui/Sources/ClaudioSettingsPresentation/AboutSettingsView.swift"),
                encoding: .utf8)) ?? ""
        let model =
            (try? String(
                contentsOf: root.appendingPathComponent(
                    "gui/Sources/ClaudioGUICore/AboutSettingsModel.swift"),
                encoding: .utf8)) ?? ""
        expect(
            view.contains(".firstAction(.about)")
                && view.contains("settings.about.copy-version")
                && view.contains("settings.about.diagnostics.copy"),
            "About must wire sidebar/title/first-action keyboard order and both copy actions")
        expect(
            view.contains("ClaudioOrbitWordmark("),
            "About identity must reuse the current Orbit Zero wordmark component")
        expect(
            view.contains("settingsAboutResourceMissing")
                && view.contains("settings.about.feedback")
                && model.contains(".clipboardFailed")
                && model.contains(".resourceOpenFailed"),
            "missing resources, clipboard failures, and open failures must have visible state")
        expect(
            view.contains(".accessibilityHint")
                && view.contains(".accessibilityIdentifier")
                && view.contains(".textSelection(.enabled)"),
            "About actions and diagnostic text must have keyboard/VoiceOver wiring")
        let forbiddenActions = [
            "checkForUpdates", "updater", "homepage", "feedbackURL", "telemetry", "analytics",
        ]
        for forbidden in forbiddenActions {
            expect(
                !view.localizedCaseInsensitiveContains(forbidden)
                    && !model.localizedCaseInsensitiveContains(forbidden),
                "About must not add out-of-scope action: \(forbidden)")
        }
    }

    suite("About resources have one repository source and a bundle assembly contract") {
        let root = guiTestRepositoryRoot()
        let dev =
            (try? String(
                contentsOf: root.appendingPathComponent("scripts/dev-bundle.sh"),
                encoding: .utf8)) ?? ""
        let release =
            (try? String(
                contentsOf: root.appendingPathComponent(".github/workflows/release.yml"),
                encoding: .utf8)) ?? ""
        let privacy =
            (try? String(
                contentsOf: root.appendingPathComponent("PRIVACY.md"),
                encoding: .utf8)) ?? ""
        for assembly in [dev, release] {
            expect(
                assembly.contains("Contents/Resources/LICENSE")
                    && assembly.contains("Contents/Resources/PRIVACY.md")
                    && assembly.contains("Contents/Resources/packs"),
                "each app assembler must ship license, privacy, and sound-attribution sources")
            expect(
                assembly.contains("<key>ClaudioBrandName</key><string>Orbit Zero</string>"),
                "each real app Info.plist must carry the About brand identity")
        }
        let englishProfileLines = privacy.split(separator: "\n").map(String.init).filter {
            $0.hasPrefix("- Profile ")
        }
        let chineseProfileLines = privacy.split(separator: "\n").map(String.init).filter {
            $0.hasPrefix("- 配置 ")
        }
        let providerNames: [AICueProviderID: String] = [
            .elevenLabs: "ElevenLabs",
            .miniMax: "MiniMax",
            .qwen: "Qwen / DashScope",
        ]
        let profiles = AICueProviderRegistry().profiles()
        let expectedEnglishProfiles = profiles.compactMap { profile -> String? in
            guard let providerName = providerNames[profile.providerID] else { return nil }
            return
                "- Profile `\(profile.id.rawValue)`: provider `\(providerName)`; region `\(profile.regionID ?? "global")`."
        }
        let expectedChineseProfiles = profiles.compactMap { profile -> String? in
            guard let providerName = providerNames[profile.providerID] else { return nil }
            return
                "- 配置 `\(profile.id.rawValue)`：Provider `\(providerName)`；region `\(profile.regionID ?? "global")`。"
        }
        expect(
            privacy.contains("local helper and host-hook runtime")
                && privacy.contains("per-profile disclosure")
                && expectedEnglishProfiles.count == profiles.count
                && englishProfileLines == expectedEnglishProfiles
                && chineseProfileLines == expectedChineseProfiles,
            "privacy resource must match the allowlisted profile registry exactly in both languages"
        )
        expect(
            privacy.contains("It excludes path\nvalues")
                || privacy.contains("It excludes path values"),
            "privacy resource must explicitly exclude path values from copied diagnostics")
    }

    suite("About copied version information localizes unknown values") {
        let facts = projectAboutBundleFacts(
            AboutBundleFactsInput(
                brandName: "Orbit Zero",
                productName: "claudi0",
                version: nil,
                build: "42",
                architecture: "x86_64",
                minimumSystemVersion: "12.0",
                operatingSystemVersion: "14.7"))
        let english = aboutVersionInformation(facts, language: .english)
        let chinese = aboutVersionInformation(facts, language: .zhHans)
        expect(english.contains("Version: Unknown"), "English copy must expose missing version")
        expect(chinese.contains("版本: 未知"), "Chinese copy must expose missing version")
        expect(english.contains("Architecture: x86_64"), "copy must include architecture")
        expect(chinese.contains("最低 macOS: 12.0"), "copy must include minimum macOS")
    }
}
