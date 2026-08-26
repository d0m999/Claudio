import Carbon
import ClaudioGUICore

private let claudioHotKeySignature: OSType = 0x434C4430  // "CLD0"

/// Process-scoped Carbon registrar. It deliberately installs no NSEvent global monitor, so the
/// three shortcuts require neither Accessibility nor Input Monitoring permission.
@MainActor
final class CarbonGlobalShortcutRegistrar {
    private var registrations: [GlobalShortcutAction: EventHotKeyRef] = [:]
    private var actionHandler: (@MainActor (GlobalShortcutAction) -> Void)?
    private var eventHandler: EventHandlerRef?

    init() {}

    private func installEventHandlerIfNeeded() throws {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                return MainActor.assumeIsolated {
                    let owner = Unmanaged<CarbonGlobalShortcutRegistrar>
                        .fromOpaque(context)
                        .takeUnretainedValue()
                    return owner.handle(event)
                }
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler)
        guard status == noErr else {
            eventHandler = nil
            throw GlobalShortcutAdapterError.systemFailure(status)
        }
    }

    func makeAdapter() -> GlobalHotKeyAdapter {
        GlobalHotKeyAdapter(
            register: { [weak self] shortcut in
                guard let self else { throw GlobalShortcutAdapterError.systemFailure(-1) }
                try self.register(shortcut)
            },
            unregister: { [weak self] action in
                guard let self else { throw GlobalShortcutAdapterError.systemFailure(-1) }
                try self.unregister(action)
            },
            setActionHandler: { [weak self] handler in
                self?.actionHandler = handler
            })
    }

    /// The registrar is app-lifetime. Explicit termination cleanup keeps non-Sendable Carbon
    /// pointers on MainActor instead of reaching through Swift 6's intentionally nonisolated
    /// deinitializer.
    func invalidate() {
        for reference in registrations.values {
            UnregisterEventHotKey(reference)
        }
        registrations.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        actionHandler = nil
    }

    private func register(_ shortcut: GlobalShortcut) throws {
        try installEventHandlerIfNeeded()
        guard registrations[shortcut.shortcutID] == nil else {
            throw GlobalShortcutAdapterError.conflict
        }
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(
            signature: claudioHotKeySignature,
            id: shortcut.shortcutID.registrationID)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            carbonModifiers(shortcut.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference)
        guard status == noErr, let reference else {
            if status == eventHotKeyExistsErr {
                throw GlobalShortcutAdapterError.conflict
            }
            throw GlobalShortcutAdapterError.systemFailure(status)
        }
        registrations[shortcut.shortcutID] = reference
    }

    private func unregister(_ action: GlobalShortcutAction) throws {
        guard let reference = registrations[action] else { return }
        let status = UnregisterEventHotKey(reference)
        guard status == noErr else {
            throw GlobalShortcutAdapterError.systemFailure(status)
        }
        registrations[action] = nil
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID)
        guard status == noErr, hotKeyID.signature == claudioHotKeySignature,
            let action = GlobalShortcutAction.allCases.first(where: {
                $0.registrationID == hotKeyID.id
            })
        else {
            return OSStatus(eventNotHandledErr)
        }
        actionHandler?(action)
        return noErr
    }
}

private func carbonModifiers(_ modifiers: GlobalShortcutModifiers) -> UInt32 {
    var result: UInt32 = 0
    if modifiers.contains(.command) { result |= UInt32(cmdKey) }
    if modifiers.contains(.control) { result |= UInt32(controlKey) }
    if modifiers.contains(.option) { result |= UInt32(optionKey) }
    if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
    return result
}
