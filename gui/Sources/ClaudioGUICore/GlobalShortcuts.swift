import Combine
import Foundation

public enum GlobalShortcutAction: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case togglePanel = "toggle-panel"
    case openSettings = "open-settings"
    case openCurrentScopeEvents = "open-current-scope-events"

    public var id: String { rawValue }

    /// Stable Carbon IDs are part of the persisted shortcut identity, never array offsets.
    public var registrationID: UInt32 {
        switch self {
        case .togglePanel: 1
        case .openSettings: 2
        case .openCurrentScopeEvents: 3
        }
    }
}

public struct GlobalShortcutModifiers: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let command = Self(rawValue: 1 << 0)
    public static let control = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let shift = Self(rawValue: 1 << 3)
    public static let supported: Self = [.command, .control, .option, .shift]

    public var normalized: Self { intersection(.supported) }
    public var containsPrimaryModifier: Bool { contains(.command) || contains(.control) }
}

public struct GlobalShortcut: Codable, Sendable, Hashable {
    public static let schemaVersion = 1

    public let schema: Int
    public let shortcutID: GlobalShortcutAction
    public let keyCode: UInt32
    public let modifiers: GlobalShortcutModifiers

    public init(
        shortcutID: GlobalShortcutAction,
        keyCode: UInt32,
        modifiers: GlobalShortcutModifiers,
        schema: Int = GlobalShortcut.schemaVersion
    ) {
        self.schema = schema
        self.shortcutID = shortcutID
        self.keyCode = keyCode
        self.modifiers = modifiers.normalized
    }

    public var displayName: String {
        var components: [String] = []
        if modifiers.contains(.control) { components.append("⌃") }
        if modifiers.contains(.option) { components.append("⌥") }
        if modifiers.contains(.shift) { components.append("⇧") }
        if modifiers.contains(.command) { components.append("⌘") }
        components.append(globalShortcutKeyName(keyCode: keyCode))
        return components.joined()
    }
}

public enum GlobalShortcutValidationFailure: Sendable, Equatable {
    case primaryModifierRequired
    case unsupportedKeyCode
    case systemReserved
    case duplicate(GlobalShortcutAction)
}

public enum GlobalShortcutOperationFailure: Sendable, Equatable {
    case invalidStoredValue
    case validation(GlobalShortcutValidationFailure)
    case conflict
    case registrationFailed
    case unregisterFailed
    case persistenceFailed
    case persistenceCleanupFailed
    case rollbackFailed
}

public struct GlobalShortcutItemState: Sendable, Equatable {
    public let shortcut: GlobalShortcut?
    public let isRegistered: Bool
    public let failure: GlobalShortcutOperationFailure?

    public init(
        shortcut: GlobalShortcut? = nil,
        isRegistered: Bool = false,
        failure: GlobalShortcutOperationFailure? = nil
    ) {
        self.shortcut = shortcut
        self.isRegistered = isRegistered
        self.failure = failure
    }
}

public enum GlobalShortcutAdapterError: Error, Sendable, Equatable {
    case conflict
    case systemFailure(Int32)
}

/// Injectable Carbon boundary. Production wraps RegisterEventHotKey/UnregisterEventHotKey;
/// tests own deterministic registrations and trigger delivery without installing global hooks.
@MainActor
public struct GlobalHotKeyAdapter {
    public let register: (GlobalShortcut) throws -> Void
    public let unregister: (GlobalShortcutAction) throws -> Void
    public let setActionHandler: (@escaping @MainActor (GlobalShortcutAction) -> Void) -> Void

    public init(
        register: @escaping (GlobalShortcut) throws -> Void,
        unregister: @escaping (GlobalShortcutAction) throws -> Void,
        setActionHandler:
            @escaping (@escaping @MainActor (GlobalShortcutAction) -> Void) -> Void
    ) {
        self.register = register
        self.unregister = unregister
        self.setActionHandler = setActionHandler
    }
}

/// Each action has an independent value so one damaged or future-schema record disables only its
/// own item. The adapter also makes persistence failures deterministic in the transaction tests.
@MainActor
public struct GlobalShortcutPersistenceAdapter {
    public let read: (GlobalShortcutAction) -> Data?
    public let persist: (GlobalShortcutAction, Data?) throws -> Void

    public init(
        read: @escaping (GlobalShortcutAction) -> Data?,
        persist: @escaping (GlobalShortcutAction, Data?) throws -> Void
    ) {
        self.read = read
        self.persist = persist
    }

    public static func userDefaults(_ defaults: UserDefaults = .standard) -> Self {
        Self(
            read: { defaults.data(forKey: globalShortcutDefaultsKey($0)) },
            persist: { action, data in
                if let data {
                    defaults.set(data, forKey: globalShortcutDefaultsKey(action))
                } else {
                    defaults.removeObject(forKey: globalShortcutDefaultsKey(action))
                }
            })
    }
}

public func globalShortcutDefaultsKey(_ action: GlobalShortcutAction) -> String {
    "Claudio.GlobalShortcut.\(action.rawValue)"
}

/// Selects the application that should regain activation after a Settings window opened by a
/// global shortcut closes. The generic payload keeps AppKit out of `ClaudioGUICore` while making
/// the pre-activation selection rule executable in the package harness.
package func resolveGlobalShortcutHandbackApplication<Application>(
    frontmostApplication: Application?,
    previousApplication: Application?,
    isCurrentApplication: (Application) -> Bool
) -> Application? {
    guard let frontmostApplication else { return nil }
    if isCurrentApplication(frontmostApplication) {
        return previousApplication
    }
    return frontmostApplication
}

public func validateGlobalShortcut(
    _ shortcut: GlobalShortcut,
    existing: [GlobalShortcut]
) -> GlobalShortcutValidationFailure? {
    guard shortcut.modifiers.containsPrimaryModifier else {
        return .primaryModifierRequired
    }
    guard globalShortcutIsSupportedKeyCode(shortcut.keyCode) else {
        return .unsupportedKeyCode
    }
    if globalShortcutIsSystemReserved(shortcut) {
        return .systemReserved
    }
    if let duplicate = existing.first(where: {
        $0.shortcutID != shortcut.shortcutID
            && $0.keyCode == shortcut.keyCode
            && $0.modifiers.normalized == shortcut.modifiers.normalized
    })?.shortcutID {
        return .duplicate(duplicate)
    }
    return nil
}

public func globalShortcutIsSystemReserved(_ shortcut: GlobalShortcut) -> Bool {
    let modifiers = shortcut.modifiers.normalized
    let commandOnly = modifiers == .command
    let commandShift = modifiers == [.command, .shift]
    let commandOption = modifiers == [.command, .option]
    let controlOnly = modifiers == .control

    // Hardware key codes keep this check and display stable across keyboard-layout changes.
    // Tab=48, Space=49, Escape=53 on macOS virtual-key-code layouts.
    return (shortcut.keyCode == 48 && (commandOnly || commandShift))
        || (shortcut.keyCode == 49 && (commandOnly || controlOnly))
        || (shortcut.keyCode == 53 && commandOption)
}

/// Layout-independent key-cap glyphs for common macOS virtual key codes. Keeping this projection
/// language-neutral prevents a keyboard-layout change from rewriting the persisted shortcut or
/// exposing English-only key names in the Chinese UI.
private let globalShortcutKeyNames: [UInt32: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
    8: "C", 9: "V", 10: "§", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
    16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
    23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
    30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
    37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
    44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "␠",
    50: "`", 51: "⌫", 53: "⎋", 64: "F17", 65: "⌨.",
    67: "⌨*", 69: "⌨+", 71: "⌧", 75: "⌨/",
    76: "⌨↩", 78: "⌨-", 79: "F18", 80: "F19",
    81: "⌨=", 82: "⌨0", 83: "⌨1", 84: "⌨2",
    85: "⌨3", 86: "⌨4", 87: "⌨5", 88: "⌨6",
    89: "⌨7", 90: "F20", 91: "⌨8", 92: "⌨9",
    93: "¥", 94: "_", 95: "⌨,", 96: "F5", 97: "F6", 98: "F7",
    99: "F3", 100: "F8", 101: "F9", 102: "英数", 103: "F11",
    104: "かな", 105: "F13", 106: "F16", 107: "F14", 109: "F10",
    111: "F12", 113: "F15", 114: "?", 115: "↖", 116: "⇞",
    117: "⌦", 118: "F4", 119: "↘", 120: "F2", 121: "⇟",
    122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
]

public func globalShortcutIsSupportedKeyCode(_ keyCode: UInt32) -> Bool {
    globalShortcutKeyNames[keyCode] != nil
}

public func globalShortcutKeyName(keyCode: UInt32) -> String {
    globalShortcutKeyNames[keyCode] ?? "#\(keyCode)"
}

@MainActor
public final class GlobalShortcutSettingsModel: ObservableObject {
    @Published public private(set) var states: [GlobalShortcutAction: GlobalShortcutItemState]

    private let adapter: GlobalHotKeyAdapter
    private let persistence: GlobalShortcutPersistenceAdapter
    private let actionHandler: @MainActor (GlobalShortcutAction) -> Void
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var deferredPersistedShortcuts: [GlobalShortcutAction: DeferredPersistedShortcut] = [:]
    private var systemSuspensionActive = false
    private var recordingSuspensionActive = false

    private struct DeferredPersistedShortcut {
        let shortcut: GlobalShortcut?
    }

    public init(
        adapter: GlobalHotKeyAdapter,
        persistence: GlobalShortcutPersistenceAdapter,
        actionHandler: @escaping @MainActor (GlobalShortcutAction) -> Void
    ) {
        self.adapter = adapter
        self.persistence = persistence
        self.actionHandler = actionHandler
        states = Dictionary(
            uniqueKeysWithValues: GlobalShortcutAction.allCases.map {
                ($0, GlobalShortcutItemState())
            })

        adapter.setActionHandler { [weak self] action in
            self?.deliver(action)
        }
        restorePersistedRegistrations()
    }

    public func state(for action: GlobalShortcutAction) -> GlobalShortcutItemState {
        states[action] ?? GlobalShortcutItemState()
    }

    public func replace(
        _ action: GlobalShortcutAction,
        keyCode: UInt32,
        modifiers: GlobalShortcutModifiers
    ) {
        let candidate = GlobalShortcut(
            shortcutID: action,
            keyCode: keyCode,
            modifiers: modifiers)
        let existing = currentShortcuts(excluding: action)
        if let failure = validateGlobalShortcut(candidate, existing: existing) {
            update(
                action,
                shortcut: state(for: action).shortcut,
                isRegistered: state(for: action).isRegistered,
                failure: .validation(failure))
            return
        }

        let oldState = state(for: action)
        if oldState.isRegistered {
            do {
                try adapter.unregister(action)
            } catch {
                update(
                    action,
                    shortcut: oldState.shortcut,
                    isRegistered: true,
                    failure: .unregisterFailed)
                return
            }
        }

        do {
            try adapter.register(candidate)
        } catch {
            restoreOldAfterFailure(
                action: action,
                oldState: oldState,
                failure: registrationFailure(for: error))
            return
        }

        do {
            try persistence.persist(action, try encoder.encode(candidate))
            deferredPersistedShortcuts[action] = nil
            update(action, shortcut: candidate, isRegistered: true, failure: nil)
        } catch {
            do {
                try adapter.unregister(action)
            } catch {
                if deferredPersistedShortcuts[action] == nil {
                    deferredPersistedShortcuts[action] = DeferredPersistedShortcut(
                        shortcut: oldState.shortcut)
                }
                update(
                    action,
                    shortcut: candidate,
                    isRegistered: true,
                    failure: .persistenceCleanupFailed)
                return
            }
            restoreOldAfterFailure(
                action: action,
                oldState: oldState,
                failure: .persistenceFailed)
        }
    }

    public func clear(_ action: GlobalShortcutAction) {
        let oldState = state(for: action)
        guard oldState.shortcut != nil else {
            if oldState.failure == .invalidStoredValue {
                do {
                    try persistence.persist(action, nil)
                    update(action, shortcut: nil, isRegistered: false, failure: nil)
                } catch {
                    update(action, shortcut: nil, isRegistered: false, failure: .persistenceFailed)
                }
            }
            return
        }
        if oldState.isRegistered {
            do {
                try adapter.unregister(action)
            } catch {
                update(
                    action,
                    shortcut: oldState.shortcut,
                    isRegistered: true,
                    failure: .unregisterFailed)
                return
            }
        }
        do {
            try persistence.persist(action, nil)
            deferredPersistedShortcuts[action] = nil
            update(action, shortcut: nil, isRegistered: false, failure: nil)
        } catch {
            restoreOldAfterFailure(
                action: action,
                oldState: oldState,
                failure: .persistenceFailed)
        }
    }

    /// Carbon hot keys are process registrations. Suspending removes only those registrations;
    /// the versioned preferences remain untouched and are replayed after wake.
    public func suspend() {
        systemSuspensionActive = true
        _ = suspendRegistrations()
    }

    /// The local recorder must not arm unless every process registration is gone; otherwise the
    /// old global shortcut could consume the keyDown before the focused capture view receives it.
    public func suspendForRecording() -> Bool {
        recordingSuspensionActive = true
        guard suspendRegistrations() else {
            recordingSuspensionActive = false
            return false
        }
        return true
    }

    private func suspendRegistrations() -> Bool {
        for action in GlobalShortcutAction.allCases {
            let current = state(for: action)
            guard current.isRegistered else {
                restoreDeferredPersistedShortcutIfNeeded(for: action)
                continue
            }
            do {
                try adapter.unregister(action)
                if deferredPersistedShortcuts[action] != nil {
                    restoreDeferredPersistedShortcutIfNeeded(for: action)
                } else {
                    update(
                        action,
                        shortcut: current.shortcut,
                        isRegistered: false,
                        failure: nil)
                }
            } catch {
                update(
                    action,
                    shortcut: current.shortcut,
                    isRegistered: true,
                    failure: .unregisterFailed)
            }
        }
        return GlobalShortcutAction.allCases.allSatisfy { !state(for: $0).isRegistered }
    }

    private func restoreDeferredPersistedShortcutIfNeeded(
        for action: GlobalShortcutAction
    ) {
        guard let persisted = deferredPersistedShortcuts.removeValue(forKey: action) else {
            return
        }
        update(
            action,
            shortcut: persisted.shortcut,
            isRegistered: false,
            failure: persisted.shortcut == nil ? nil : .persistenceFailed)
    }

    public func resume() {
        systemSuspensionActive = false
        resumeRegistrationsIfAllowed()
    }

    public func resumeAfterRecording(
        preservingFailureFor preservedAction: GlobalShortcutAction? = nil
    ) {
        recordingSuspensionActive = false
        resumeRegistrationsIfAllowed(preservingFailureFor: preservedAction)
    }

    private func resumeRegistrationsIfAllowed(
        preservingFailureFor preservedAction: GlobalShortcutAction? = nil
    ) {
        guard !systemSuspensionActive, !recordingSuspensionActive else { return }
        for action in GlobalShortcutAction.allCases {
            let current = state(for: action)
            guard let shortcut = current.shortcut, !current.isRegistered else { continue }
            do {
                try adapter.register(shortcut)
                update(
                    action,
                    shortcut: shortcut,
                    isRegistered: true,
                    failure: action == preservedAction ? current.failure : nil)
            } catch {
                update(
                    action,
                    shortcut: shortcut,
                    isRegistered: false,
                    failure: registrationFailure(for: error))
            }
        }
    }

    private func restorePersistedRegistrations() {
        var restored: [GlobalShortcut] = []
        for action in GlobalShortcutAction.allCases {
            guard let data = persistence.read(action) else { continue }
            guard
                let shortcut = try? decoder.decode(GlobalShortcut.self, from: data),
                shortcut.schema == GlobalShortcut.schemaVersion,
                shortcut.shortcutID == action,
                shortcut.modifiers == shortcut.modifiers.normalized,
                validateGlobalShortcut(shortcut, existing: restored) == nil
            else {
                update(action, shortcut: nil, isRegistered: false, failure: .invalidStoredValue)
                continue
            }
            do {
                try adapter.register(shortcut)
                restored.append(shortcut)
                update(action, shortcut: shortcut, isRegistered: true, failure: nil)
            } catch {
                restored.append(shortcut)
                update(
                    action,
                    shortcut: shortcut,
                    isRegistered: false,
                    failure: registrationFailure(for: error))
            }
        }
    }

    private func restoreOldAfterFailure(
        action: GlobalShortcutAction,
        oldState: GlobalShortcutItemState,
        failure: GlobalShortcutOperationFailure
    ) {
        guard let old = oldState.shortcut else {
            update(action, shortcut: nil, isRegistered: false, failure: failure)
            return
        }
        do {
            try adapter.register(old)
            update(action, shortcut: old, isRegistered: true, failure: failure)
        } catch {
            update(action, shortcut: old, isRegistered: false, failure: .rollbackFailed)
        }
    }

    private func registrationFailure(for error: Error) -> GlobalShortcutOperationFailure {
        if let adapterError = error as? GlobalShortcutAdapterError,
            adapterError == .conflict
        {
            return .conflict
        }
        return .registrationFailed
    }

    private func currentShortcuts(
        excluding excluded: GlobalShortcutAction
    ) -> [GlobalShortcut] {
        GlobalShortcutAction.allCases.flatMap { action -> [GlobalShortcut] in
            guard action != excluded else { return [] }
            var shortcuts: [GlobalShortcut] = []
            if let current = state(for: action).shortcut {
                shortcuts.append(current)
            }
            if let persisted = deferredPersistedShortcuts[action]?.shortcut,
                !shortcuts.contains(persisted)
            {
                shortcuts.append(persisted)
            }
            return shortcuts
        }
    }

    private func update(
        _ action: GlobalShortcutAction,
        shortcut: GlobalShortcut?,
        isRegistered: Bool,
        failure: GlobalShortcutOperationFailure?
    ) {
        states[action] = GlobalShortcutItemState(
            shortcut: shortcut,
            isRegistered: isRegistered,
            failure: failure)
    }

    private func deliver(_ action: GlobalShortcutAction) {
        guard state(for: action).isRegistered else { return }
        actionHandler(action)
    }
}
