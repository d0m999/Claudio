import ClaudioLocalization
import Combine
import Foundation

public enum AboutBundledResourceKind: String, CaseIterable, Identifiable, Sendable {
    case openSourceLicense
    case soundAttribution
    case privacyStatement

    public var id: String { rawValue }
}

public struct AboutBundledResource: Identifiable, Sendable {
    public var id: AboutBundledResourceKind { kind }
    public let kind: AboutBundledResourceKind
    public let url: URL?

    public init(kind: AboutBundledResourceKind, url: URL?) {
        self.kind = kind
        self.url = url
    }
}

public enum AboutSettingsFeedback: Equatable, Sendable {
    case versionCopied
    case diagnosticsCopied
    case clipboardFailed
    case resourceOpenFailed(AboutBundledResourceKind)

    public var isFailure: Bool {
        switch self {
        case .versionCopied, .diagnosticsCopied: false
        case .clipboardFailed, .resourceOpenFailed: true
        }
    }
}

public struct AboutSettingsActions {
    let copy: @MainActor (String) -> Bool
    let open: @MainActor (URL) -> Bool

    public init(
        copy: @escaping @MainActor (String) -> Bool,
        open: @escaping @MainActor (URL) -> Bool
    ) {
        self.copy = copy
        self.open = open
    }
}

/// Retained, Foundation-only About behavior. It owns only already-redacted Surface enums, fixed
/// bundle resources, and closed feedback; richer integration values are discarded before this
/// object is called.
@MainActor
public final class AboutSettingsModel: ObservableObject {
    public let bundleFacts: AboutBundleFacts
    public let resources: [AboutBundledResource]
    public let pathFacts: [AboutPathExistenceFact]
    @Published public private(set) var surfaceFacts: [AboutSurfaceFact]
    @Published public private(set) var feedback: AboutSettingsFeedback?

    private let actions: AboutSettingsActions

    public init(
        bundleFacts: AboutBundleFacts,
        resources: [AboutBundledResource],
        pathFacts: [AboutPathExistenceFact],
        surfaceFacts: [AboutSurfaceFact],
        actions: AboutSettingsActions
    ) {
        self.bundleFacts = bundleFacts
        self.resources = resources
        self.pathFacts = pathFacts
        self.surfaceFacts = surfaceFacts
        self.actions = actions
    }

    public var diagnosticSummary: String {
        makeAboutDiagnosticSummary(
            AboutDiagnosticFacts(
                bundle: bundleFacts,
                surfaces: surfaceFacts,
                paths: pathFacts))
    }

    public func replaceSurfaceFacts(_ replacement: [AboutSurfaceFact]) {
        guard replacement != surfaceFacts else { return }
        surfaceFacts = replacement
    }

    public func copyVersionInformation(language: ClaudioAppLanguage) {
        feedback =
            actions.copy(aboutVersionInformation(bundleFacts, language: language))
            ? .versionCopied : .clipboardFailed
    }

    public func copyDiagnostics() {
        feedback = actions.copy(diagnosticSummary) ? .diagnosticsCopied : .clipboardFailed
    }

    public func openResource(_ resource: AboutBundledResource) {
        guard let url = resource.url, actions.open(url) else {
            feedback = .resourceOpenFailed(resource.kind)
            return
        }
        feedback = nil
    }
}
