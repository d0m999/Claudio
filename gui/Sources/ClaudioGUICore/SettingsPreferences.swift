import ClaudioLocalization
import Combine
import Foundation

public extension SettingsDestination {
    static let defaultsKey = "Claudio.Settings.LastDestination"

    /// Top-level destinations with production content today. Later destination migrations extend
    /// this list when their real views ship; DEBUG galleries inject `allCases` explicitly.
    static let availableCases: [SettingsDestination] = [.general]
}

public enum ClaudioPreferenceRecoveryIssue: String, Sendable, Hashable {
    case invalidLanguageMode
    case invalidSettingsDestination
}

/// One atomic projection of the Settings preferences currently owned by Claudio. New preference
/// fields belong here only when their destination ships; this ticket intentionally owns language
/// mode and the last top-level destination, and nothing else.
public struct ClaudioPreferenceSnapshot: Sendable, Equatable {
    public let languageMode: ClaudioLanguageMode
    public let language: ClaudioAppLanguage
    public let lastSettingsDestination: SettingsDestination
    public let recoveryIssues: Set<ClaudioPreferenceRecoveryIssue>

    public init(
        languageMode: ClaudioLanguageMode,
        language: ClaudioAppLanguage,
        lastSettingsDestination: SettingsDestination,
        recoveryIssues: Set<ClaudioPreferenceRecoveryIssue> = []
    ) {
        self.languageMode = languageMode
        self.language = language
        self.lastSettingsDestination = lastSettingsDestination
        self.recoveryIssues = recoveryIssues
    }
}

/// App-lifetime typed preference owner shared by every visible consumer. Publishing one snapshot
/// keeps language mode, its resolved projection, navigation restoration, and recovery state
/// mutually consistent for SwiftUI and AppKit observers.
@MainActor
public final class ClaudioPreferences: ObservableObject {
    @Published public private(set) var snapshot: ClaudioPreferenceSnapshot
    public let availableSettingsDestinations: [SettingsDestination]

    public var languageMode: ClaudioLanguageMode { snapshot.languageMode }
    public var language: ClaudioAppLanguage { snapshot.language }
    public var lastSettingsDestination: SettingsDestination {
        snapshot.lastSettingsDestination
    }
    public var recoveryIssues: Set<ClaudioPreferenceRecoveryIssue> {
        snapshot.recoveryIssues
    }

    private let defaults: UserDefaults
    private let preferredLanguageIdentifiers: @MainActor () -> [String]
    private var localeCancellable: AnyCancellable?

    public init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        availableSettingsDestinations: [SettingsDestination] = SettingsDestination.availableCases,
        preferredLanguageIdentifiers: @escaping @MainActor () -> [String] = {
            Locale.preferredLanguages
        }
    ) {
        self.defaults = defaults
        self.preferredLanguageIdentifiers = preferredLanguageIdentifiers
        let legalDestinations = availableSettingsDestinations.isEmpty
            ? [.general] : availableSettingsDestinations
        self.availableSettingsDestinations = legalDestinations

        let languageObject = defaults.object(forKey: ClaudioAppLanguage.defaultsKey)
        let languageRawValue = languageObject as? String
        let languageMode = ClaudioLanguageMode(storedValue: languageRawValue)
        let destinationObject = defaults.object(forKey: SettingsDestination.defaultsKey)
        let destinationRawValue = destinationObject as? String
        let parsedDestination = destinationRawValue.flatMap(SettingsDestination.init(rawValue:))
        let destination = parsedDestination.flatMap {
            legalDestinations.contains($0) ? $0 : nil
        } ?? .general
        var recoveryIssues: Set<ClaudioPreferenceRecoveryIssue> = []
        if languageObject != nil {
            if let languageRawValue {
                if ClaudioLanguageMode(rawValue: languageRawValue) == nil {
                    recoveryIssues.insert(.invalidLanguageMode)
                }
            } else {
                recoveryIssues.insert(.invalidLanguageMode)
            }
        }
        if destinationObject != nil {
            if let destinationRawValue {
                if SettingsDestination(rawValue: destinationRawValue).map(
                    legalDestinations.contains) != true
                {
                    recoveryIssues.insert(.invalidSettingsDestination)
                }
            } else {
                recoveryIssues.insert(.invalidSettingsDestination)
            }
        }

        snapshot = ClaudioPreferenceSnapshot(
            languageMode: languageMode,
            language: languageMode.resolvedLanguage(
                preferredLanguageIdentifiers: preferredLanguageIdentifiers()),
            lastSettingsDestination: destination,
            recoveryIssues: recoveryIssues)

        localeCancellable = notificationCenter
            .publisher(for: NSLocale.currentLocaleDidChangeNotification)
            .sink { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshSystemLanguage()
                }
            }
    }

    #if DEBUG
    /// State-gallery initializer that does not read or observe the app's real preferences.
    public convenience init(previewLanguage: ClaudioAppLanguage) {
        self.init(
            defaults: UserDefaults(),
            notificationCenter: NotificationCenter(),
            availableSettingsDestinations: SettingsDestination.allCases,
            preferredLanguageIdentifiers: { [previewLanguage.rawValue] })
        setLanguage(previewLanguage)
    }
    #endif

    public func setLanguageMode(_ languageMode: ClaudioLanguageMode) {
        let language = languageMode.resolvedLanguage(
            preferredLanguageIdentifiers: preferredLanguageIdentifiers())
        var recoveryIssues = snapshot.recoveryIssues
        recoveryIssues.remove(.invalidLanguageMode)
        let next = ClaudioPreferenceSnapshot(
            languageMode: languageMode,
            language: language,
            lastSettingsDestination: snapshot.lastSettingsDestination,
            recoveryIssues: recoveryIssues)
        guard next != snapshot else { return }
        defaults.set(languageMode.rawValue, forKey: ClaudioAppLanguage.defaultsKey)
        snapshot = next
    }

    /// Compatibility entry point for the existing compact language control. Choosing either
    /// product language there remains an explicit preference, never an implicit system value.
    public func setLanguage(_ language: ClaudioAppLanguage) {
        switch language {
        case .zhHans: setLanguageMode(.zhHans)
        case .english: setLanguageMode(.english)
        }
    }

    public func setLastSettingsDestination(_ destination: SettingsDestination) {
        guard availableSettingsDestinations.contains(destination) else { return }
        var recoveryIssues = snapshot.recoveryIssues
        recoveryIssues.remove(.invalidSettingsDestination)
        let next = ClaudioPreferenceSnapshot(
            languageMode: snapshot.languageMode,
            language: snapshot.language,
            lastSettingsDestination: destination,
            recoveryIssues: recoveryIssues)
        guard next != snapshot else { return }
        defaults.set(destination.rawValue, forKey: SettingsDestination.defaultsKey)
        snapshot = next
    }

    private func refreshSystemLanguage() {
        guard snapshot.languageMode == .system else { return }
        let language = snapshot.languageMode.resolvedLanguage(
            preferredLanguageIdentifiers: preferredLanguageIdentifiers())
        guard language != snapshot.language else { return }
        snapshot = ClaudioPreferenceSnapshot(
            languageMode: snapshot.languageMode,
            language: language,
            lastSettingsDestination: snapshot.lastSettingsDestination,
            recoveryIssues: snapshot.recoveryIssues)
    }
}
