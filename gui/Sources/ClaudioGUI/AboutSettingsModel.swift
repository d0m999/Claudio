import AppKit
import ClaudioGUICore
import Foundation

extension AboutBundledResourceKind {
    fileprivate var relativeComponents: [String] {
        switch self {
        case .openSourceLicense: ["LICENSE"]
        case .soundAttribution: ["packs", "LICENSES.md"]
        case .privacyStatement: ["PRIVACY.md"]
        }
    }
}

@MainActor
func makeSystemAboutSettingsModel(
    bundle: Bundle = .main,
    surfaceFacts: [AboutSurfaceFact]
) -> AboutSettingsModel {
    let facts = projectAboutBundleFacts(
        AboutBundleFactsInput(
            brandName: bundle.object(forInfoDictionaryKey: "ClaudioBrandName") as? String,
            productName: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            architecture: currentAboutArchitecture,
            minimumSystemVersion: bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion")
                as? String,
            operatingSystemVersion: currentAboutOperatingSystemVersion))

    let isApplicationBundle =
        bundle.bundleURL.pathExtension == "app"
        && isSafeAboutPathShape(bundle.bundleURL, itemKind: .directory)
    let resourcesRoot = isApplicationBundle ? bundle.resourceURL : nil
    let resources = AboutBundledResourceKind.allCases.map { kind in
        let candidate = resourcesRoot.map { root in
            kind.relativeComponents.reduce(root) { partial, component in
                partial.appendingPathComponent(component)
            }
        }
        return AboutBundledResource(
            kind: kind,
            url: candidate.flatMap { safeBundledRegularFile($0, resourcesRoot: resourcesRoot) })
    }

    let helperURL = resourcesRoot?
        .appendingPathComponent("bin", isDirectory: true)
        .appendingPathComponent("claudi0")
    let soundsURL = resourcesRoot?.appendingPathComponent("packs", isDirectory: true)
    let resourceLookup = Dictionary(
        uniqueKeysWithValues: resources.map { ($0.kind, $0.url != nil) })
    let pathFacts = [
        AboutPathExistenceFact(kind: .applicationBundle, exists: isApplicationBundle),
        AboutPathExistenceFact(
            kind: .bundledHelper,
            exists: resourcesRoot.flatMap { root in
                helperURL.map {
                    isSafeAboutBundledPath(
                        $0,
                        resourcesRoot: root,
                        itemKind: .regularFile)
                }
            } == true),
        AboutPathExistenceFact(
            kind: .bundledSounds,
            exists: resourcesRoot.flatMap { root in
                soundsURL.map {
                    isSafeAboutBundledPath(
                        $0,
                        resourcesRoot: root,
                        itemKind: .directory)
                }
            } == true),
        AboutPathExistenceFact(
            kind: .openSourceLicense,
            exists: resourceLookup[.openSourceLicense] == true),
        AboutPathExistenceFact(
            kind: .soundAttribution,
            exists: resourceLookup[.soundAttribution] == true),
        AboutPathExistenceFact(
            kind: .privacyStatement,
            exists: resourceLookup[.privacyStatement] == true),
    ]

    return AboutSettingsModel(
        bundleFacts: facts,
        resources: resources,
        pathFacts: pathFacts,
        surfaceFacts: surfaceFacts,
        actions: AboutSettingsActions(
            copy: { value in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                return pasteboard.setString(value, forType: .string)
            },
            open: { NSWorkspace.shared.open($0) }))
}

private var currentAboutArchitecture: String? {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return nil
    #endif
}

private var currentAboutOperatingSystemVersion: String {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
}

private func safeBundledRegularFile(_ candidate: URL, resourcesRoot: URL?) -> URL? {
    guard let resourcesRoot else { return nil }
    return isSafeAboutBundledPath(
        candidate,
        resourcesRoot: resourcesRoot,
        itemKind: .regularFile) ? candidate : nil
}
