import ClaudioCore
import ClaudioLocalization
import Foundation

/// Raw application and runtime metadata supplied by the executable composition root. Keeping the
/// projector value-only lets missing or malformed bundle fields fail to `nil` without teaching the
/// Settings view how to inspect a bundle.
public struct AboutBundleFactsInput: Sendable, Equatable {
    public let brandName: String?
    public let productName: String?
    public let version: String?
    public let build: String?
    public let architecture: String?
    public let minimumSystemVersion: String?
    public let operatingSystemVersion: String?

    public init(
        brandName: String?,
        productName: String?,
        version: String?,
        build: String?,
        architecture: String?,
        minimumSystemVersion: String?,
        operatingSystemVersion: String?
    ) {
        self.brandName = brandName
        self.productName = productName
        self.version = version
        self.build = build
        self.architecture = architecture
        self.minimumSystemVersion = minimumSystemVersion
        self.operatingSystemVersion = operatingSystemVersion
    }
}

/// Display-safe application identity. Optional values are intentional: the UI says "Unknown"
/// rather than inventing a release identity when a development process or damaged app is missing
/// metadata.
public struct AboutBundleFacts: Sendable, Equatable {
    public let brandName: String?
    public let productName: String?
    public let version: String?
    public let build: String?
    public let architecture: String?
    public let minimumSystemVersion: String?
    public let operatingSystemVersion: String?

    init(
        brandName: String?,
        productName: String?,
        version: String?,
        build: String?,
        architecture: String?,
        minimumSystemVersion: String?,
        operatingSystemVersion: String?
    ) {
        self.brandName = brandName
        self.productName = productName
        self.version = version
        self.build = build
        self.architecture = architecture
        self.minimumSystemVersion = minimumSystemVersion
        self.operatingSystemVersion = operatingSystemVersion
    }
}

public func projectAboutBundleFacts(_ input: AboutBundleFactsInput) -> AboutBundleFacts {
    AboutBundleFacts(
        brandName: safeAboutDisplayValue(input.brandName),
        productName: safeAboutDisplayValue(input.productName),
        version: safeAboutDiagnosticToken(input.version),
        build: safeAboutDiagnosticToken(input.build),
        architecture: safeAboutDiagnosticToken(input.architecture),
        minimumSystemVersion: safeAboutDiagnosticToken(input.minimumSystemVersion),
        operatingSystemVersion: safeAboutDiagnosticToken(input.operatingSystemVersion))
}

private func safeAboutDisplayValue(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 80 else { return nil }
    guard trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
        return nil
    }
    return trimmed
}

private func safeAboutDiagnosticToken(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
    let permitted = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-")
    guard trimmed.unicodeScalars.allSatisfy(permitted.contains) else { return nil }
    return trimmed
}

public enum AboutSurfaceSemanticState: String, Sendable, Equatable {
    case ready
    case awaitingActivation = "awaiting-activation"
    case legacy
    case notConnected = "not-connected"
    case needsAttention = "needs-attention"
}

/// The only Surface fact allowed into a copied About diagnostic. It cannot carry display text,
/// error detail, evidence, configuration, or any other free-form value.
public struct AboutSurfaceFact: Sendable, Equatable {
    public let surface: HostSurfaceID
    public let state: AboutSurfaceSemanticState

    public init?(host: HostID, state: AboutSurfaceSemanticState) {
        guard HostID.productVisibleCases.contains(host) else { return nil }
        self.surface = host.surfaceID
        self.state = state
    }
}

/// Redacts rich host rows into the fixed product Surface registry and one semantic enum per row.
/// Duplicate or diagnostic-only identities are ignored rather than copied through.
public func aboutSurfaceFacts(
    from rows: [HostSourceRowPresentation]
) -> [AboutSurfaceFact] {
    hostSurfacePresentationOrder().compactMap { host in
        guard let row = rows.first(where: { $0.host == host }) else { return nil }
        let state: AboutSurfaceSemanticState =
            switch row.status {
            case .ready: .ready
            case .awaitingActivation: .awaitingActivation
            case .legacy: .legacy
            case .notConnected: .notConnected
            case .needsAttention: .needsAttention
            }
        return AboutSurfaceFact(host: host, state: state)
    }
}

public enum AboutPathKind: String, CaseIterable, Sendable, Equatable {
    case applicationBundle = "application-bundle"
    case bundledHelper = "bundled-helper"
    case bundledSounds = "bundled-sounds"
    case openSourceLicense = "open-source-license"
    case soundAttribution = "sound-attribution"
    case privacyStatement = "privacy-statement"
}

/// The closed set of filesystem shapes the About adapter is allowed to disclose as present.
/// Resource lookup deliberately distinguishes directories from regular files so sockets, devices,
/// aliases, and other unexpected entries fail closed.
public enum AboutBundledPathItemKind: Sendable, Equatable {
    case regularFile
    case directory
}

/// Validates one fixed app resource without returning any path text to the diagnostic model.
/// Every component beneath `resourcesRoot` must be a real directory rather than a symbolic link;
/// the final entry must match the requested shape and remain inside the resolved bundle root.
public func isSafeAboutBundledPath(
    _ candidate: URL,
    resourcesRoot: URL,
    itemKind: AboutBundledPathItemKind
) -> Bool {
    guard candidate.isFileURL, resourcesRoot.isFileURL else { return false }

    let root = resourcesRoot.standardizedFileURL
    let item = candidate.standardizedFileURL
    let rootComponents = root.pathComponents
    let itemComponents = item.pathComponents
    guard
        itemComponents.count > rootComponents.count,
        itemComponents.starts(with: rootComponents),
        isSafeAboutPathShape(root, itemKind: .directory)
    else { return false }

    var cursor = root
    let relativeComponents = itemComponents.dropFirst(rootComponents.count)
    for (offset, component) in relativeComponents.enumerated() {
        cursor.appendPathComponent(component)
        let expectedKind: AboutBundledPathItemKind =
            offset == relativeComponents.count - 1 ? itemKind : .directory
        guard isSafeAboutPathShape(cursor, itemKind: expectedKind) else { return false }
    }

    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
    let resolvedItem = item.resolvingSymlinksInPath().standardizedFileURL
    let resolvedRootComponents = resolvedRoot.pathComponents
    let resolvedItemComponents = resolvedItem.pathComponents
    return resolvedItemComponents.count > resolvedRootComponents.count
        && resolvedItemComponents.starts(with: resolvedRootComponents)
}

/// Checks a single path entry's filesystem shape without following a symbolic-link node.
/// Composition roots use this for the app bundle itself; bundled descendants additionally pass
/// through `isSafeAboutBundledPath` so their entire relative chain and containment are validated.
public func isSafeAboutPathShape(
    _ url: URL,
    itemKind: AboutBundledPathItemKind
) -> Bool {
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink == false else {
        return false
    }
    switch itemKind {
    case .regularFile:
        return values.isRegularFile == true && values.isDirectory == false
    case .directory:
        return values.isDirectory == true && values.isRegularFile == false
    }
}

/// A path is reduced to a fixed semantic name and one bit before it reaches diagnostics.
public struct AboutPathExistenceFact: Sendable, Equatable {
    public let kind: AboutPathKind
    public let exists: Bool

    public init(kind: AboutPathKind, exists: Bool) {
        self.kind = kind
        self.exists = exists
    }
}

public struct AboutDiagnosticFacts: Sendable, Equatable {
    public let bundle: AboutBundleFacts
    public let surfaces: [AboutSurfaceFact]
    public let paths: [AboutPathExistenceFact]

    public init(
        bundle: AboutBundleFacts,
        surfaces: [AboutSurfaceFact],
        paths: [AboutPathExistenceFact]
    ) {
        self.bundle = bundle
        self.surfaces = surfaces
        self.paths = paths
    }
}

/// Stable, deliberately non-localized support text. Every dynamic value comes from a closed enum,
/// a boolean, or the strict bundle-token projector above.
public func makeAboutDiagnosticSummary(_ facts: AboutDiagnosticFacts) -> String {
    let unknown = "unknown"
    var lines = [
        "claudi0-version: \(facts.bundle.version ?? unknown)",
        "claudi0-build: \(facts.bundle.build ?? unknown)",
        "architecture: \(facts.bundle.architecture ?? unknown)",
        "macos: \(facts.bundle.operatingSystemVersion ?? unknown)",
        "minimum-macos: \(facts.bundle.minimumSystemVersion ?? unknown)",
    ]
    lines.append(
        contentsOf: facts.surfaces.map {
            "surface.\($0.surface.rawValue): \($0.state.rawValue)"
        })
    let pathLookup = Dictionary(uniqueKeysWithValues: facts.paths.map { ($0.kind, $0.exists) })
    lines.append(
        contentsOf: AboutPathKind.allCases.map { kind in
            "path.\(kind.rawValue): \(pathLookup[kind] == true ? "present" : "missing")"
        })
    return lines.joined(separator: "\n")
}

public func aboutVersionInformation(
    _ facts: AboutBundleFacts,
    language: ClaudioAppLanguage
) -> String {
    let l10n = ClaudioL10n(language: language)
    let unknown = l10n.text(.settingsAboutUnknown)
    return [
        "\(l10n.text(.settingsAboutBrand)): \(facts.brandName ?? unknown)",
        "\(l10n.text(.settingsAboutProduct)): \(facts.productName ?? unknown)",
        "\(l10n.text(.settingsAboutVersion)): \(facts.version ?? unknown)",
        "\(l10n.text(.settingsAboutBuild)): \(facts.build ?? unknown)",
        "\(l10n.text(.settingsAboutArchitecture)): \(facts.architecture ?? unknown)",
        "\(l10n.text(.settingsAboutMinimumMacOS)): \(facts.minimumSystemVersion ?? unknown)",
        "\(l10n.text(.settingsAboutCurrentMacOS)): \(facts.operatingSystemVersion ?? unknown)",
    ].joined(separator: "\n")
}
