import ClaudioLocalization
import Combine
import Foundation

public extension SettingsDestination {
    static let defaultsKey = "Claudio.Settings.LastDestination"

    /// Top-level destinations with production content today. Later destination migrations extend
    /// this list when their real views ship; DEBUG galleries inject `allCases` explicitly.
    static let availableCases: [SettingsDestination] = [
        .general, .integrations, .eventsAndSounds, .notifications, .display, .sounds, .usage,
        .shortcuts,
    ]
}

public enum ClaudioPreferenceRecoveryIssue: String, Sendable, Hashable {
    case invalidLanguageMode
    case invalidSettingsDestination
    case invalidInterfaceTextSize
    case invalidPanelWidthPreference
    case invalidMenuBarStatusDot
}

/// One atomic projection of the Settings preferences currently owned by Claudio. New preference
/// fields belong here only when their destination ships; language, navigation, and Display
/// consumers all observe this single coherent value.
public struct ClaudioPreferenceSnapshot: Sendable, Equatable {
    public fileprivate(set) var languageMode: ClaudioLanguageMode
    public fileprivate(set) var language: ClaudioAppLanguage
    public fileprivate(set) var lastSettingsDestination: SettingsDestination
    public fileprivate(set) var interfaceTextSize: ClaudioInterfaceTextSize
    public fileprivate(set) var panelWidthPreference: ClaudioPanelWidthPreference
    public fileprivate(set) var showsMenuBarStatusDot: Bool
    public fileprivate(set) var recoveryIssues: Set<ClaudioPreferenceRecoveryIssue>

    public init(
        languageMode: ClaudioLanguageMode,
        language: ClaudioAppLanguage,
        lastSettingsDestination: SettingsDestination,
        interfaceTextSize: ClaudioInterfaceTextSize,
        panelWidthPreference: ClaudioPanelWidthPreference,
        showsMenuBarStatusDot: Bool,
        recoveryIssues: Set<ClaudioPreferenceRecoveryIssue> = []
    ) {
        self.languageMode = languageMode
        self.language = language
        self.lastSettingsDestination = lastSettingsDestination
        self.interfaceTextSize = interfaceTextSize
        self.panelWidthPreference = panelWidthPreference
        self.showsMenuBarStatusDot = showsMenuBarStatusDot
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
    public var interfaceTextSize: ClaudioInterfaceTextSize { snapshot.interfaceTextSize }
    public var panelWidthPreference: ClaudioPanelWidthPreference {
        snapshot.panelWidthPreference
    }
    public var showsMenuBarStatusDot: Bool { snapshot.showsMenuBarStatusDot }
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
        let textSizeObject = defaults.object(forKey: ClaudioInterfaceTextSize.defaultsKey)
        let textSizeRawValue = textSizeObject as? String
        let interfaceTextSize = ClaudioInterfaceTextSize(storedValue: textSizeRawValue)
        let panelWidthObject = defaults.object(forKey: ClaudioPanelWidthPreference.defaultsKey)
        let panelWidthRawValue = panelWidthObject as? String
        let panelWidthPreference = ClaudioPanelWidthPreference(storedValue: panelWidthRawValue)
        let statusDotObject = defaults.object(forKey: Self.menuBarStatusDotDefaultsKey)
        let showsMenuBarStatusDot = statusDotObject as? Bool ?? true
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
        if textSizeObject != nil,
            textSizeRawValue.flatMap(ClaudioInterfaceTextSize.init(rawValue:)) == nil
        {
            recoveryIssues.insert(.invalidInterfaceTextSize)
        }
        if panelWidthObject != nil,
            panelWidthRawValue.flatMap(ClaudioPanelWidthPreference.init(rawValue:)) == nil
        {
            recoveryIssues.insert(.invalidPanelWidthPreference)
        }
        if statusDotObject != nil, statusDotObject is Bool == false {
            recoveryIssues.insert(.invalidMenuBarStatusDot)
        }

        snapshot = ClaudioPreferenceSnapshot(
            languageMode: languageMode,
            language: languageMode.resolvedLanguage(
                preferredLanguageIdentifiers: preferredLanguageIdentifiers()),
            lastSettingsDestination: destination,
            interfaceTextSize: interfaceTextSize,
            panelWidthPreference: panelWidthPreference,
            showsMenuBarStatusDot: showsMenuBarStatusDot,
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
        var next = snapshot
        next.languageMode = languageMode
        next.language = language
        next.recoveryIssues.remove(.invalidLanguageMode)
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
        var next = snapshot
        next.lastSettingsDestination = destination
        next.recoveryIssues.remove(.invalidSettingsDestination)
        guard next != snapshot else { return }
        defaults.set(destination.rawValue, forKey: SettingsDestination.defaultsKey)
        snapshot = next
    }

    public func setInterfaceTextSize(_ interfaceTextSize: ClaudioInterfaceTextSize) {
        var next = snapshot
        next.interfaceTextSize = interfaceTextSize
        next.recoveryIssues.remove(.invalidInterfaceTextSize)
        guard next != snapshot else { return }
        defaults.set(interfaceTextSize.rawValue, forKey: ClaudioInterfaceTextSize.defaultsKey)
        snapshot = next
    }

    public func setPanelWidthPreference(_ preference: ClaudioPanelWidthPreference) {
        var next = snapshot
        next.panelWidthPreference = preference
        next.recoveryIssues.remove(.invalidPanelWidthPreference)
        guard next != snapshot else { return }
        defaults.set(preference.rawValue, forKey: ClaudioPanelWidthPreference.defaultsKey)
        snapshot = next
    }

    public func setShowsMenuBarStatusDot(_ showsStatusDot: Bool) {
        var next = snapshot
        next.showsMenuBarStatusDot = showsStatusDot
        next.recoveryIssues.remove(.invalidMenuBarStatusDot)
        guard next != snapshot else { return }
        defaults.set(showsStatusDot, forKey: Self.menuBarStatusDotDefaultsKey)
        snapshot = next
    }

    private func refreshSystemLanguage() {
        guard snapshot.languageMode == .system else { return }
        let language = snapshot.languageMode.resolvedLanguage(
            preferredLanguageIdentifiers: preferredLanguageIdentifiers())
        guard language != snapshot.language else { return }
        var next = snapshot
        next.language = language
        snapshot = next
    }

    public static let menuBarStatusDotDefaultsKey = "Claudio.MenuBarStatusDot"
}
