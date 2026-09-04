import AppKit
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

@MainActor
struct ShortcutSettingsView: View {
    @ObservedObject var model: GlobalShortcutSettingsModel
    @ObservedObject var preferences: ClaudioPreferences
    let focusedTarget: FocusState<SettingsWindowFocusTarget?>.Binding
    let onAnnouncement: @MainActor (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var recordingAction: GlobalShortcutAction?

    private var l10n: ClaudioL10n { ClaudioL10n(language: preferences.language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(l10n.text(.settingsShortcutsDescription))
                .font(ClaudioTheme.font(.body))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(l10n.text(.settingsShortcutsRequirement), systemImage: "command")
                .font(ClaudioTheme.font(.body))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(GlobalShortcutAction.allCases) { action in
                shortcutRow(action)
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .background {
            LocalShortcutCaptureView(
                isRecording: recordingAction != nil,
                onCapture: { keyCode, modifiers in
                    guard let action = recordingAction else { return }
                    recordingAction = nil
                    model.replace(action, keyCode: keyCode, modifiers: modifiers)
                    model.resumeAfterRecording(preservingFailureFor: action)
                    announceState(action)
                    restoreRecordingButtonFocus(action)
                },
                onCancel: { stopRecording() }
            )
            .frame(width: 1, height: 1)
            .opacity(0.001)
            .accessibilityHidden(true)
        }
        .onDisappear { stopRecording(restoringFocus: false) }
    }

    private func shortcutRow(_ action: GlobalShortcutAction) -> some View {
        let state = model.state(for: action)
        return VStack(alignment: .leading, spacing: 10) {
            Text(actionTitle(action))
                .font(ClaudioTheme.font(.sectionTitle))
            Text(actionDescription(action))
                .font(ClaudioTheme.font(.body))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Text(currentValue(state))
                    .font(ClaudioTheme.font(.body).weight(.medium))
                    .frame(minWidth: 150, alignment: .leading)
                    .accessibilityLabel(
                        l10n.format(
                            .settingsShortcutsCurrentValue,
                            currentValue(state) as NSString)
                    )
                    .accessibilityIdentifier("settings.shortcuts.\(action.rawValue).value")

                recordingButton(action)

                Button(l10n.text(.settingsShortcutsClear)) {
                    stopRecording()
                    model.clear(action)
                    announceState(action)
                }
                .disabled(state.shortcut == nil && state.failure != .invalidStoredValue)
                .accessibilityLabel(
                    l10n.format(
                        .settingsShortcutsClearLabel,
                        actionTitle(action) as NSString)
                )
                .accessibilityIdentifier("settings.shortcuts.\(action.rawValue).clear")
            }

            if recordingAction == action {
                Label(l10n.text(.settingsShortcutsRecording), systemImage: "keyboard")
                    .foregroundColor(ClaudioTheme.clay(colorScheme))
                    .accessibilityIdentifier("settings.shortcuts.\(action.rawValue).recording")
            }

            if let failure = state.failure {
                Label {
                    Text(shortcutFailureText(failure))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(ClaudioTheme.error(colorScheme))
                }
                .accessibilityIdentifier("settings.shortcuts.\(action.rawValue).failure")
            }
        }
        .font(ClaudioTheme.font(.body))
        .settingsSectionSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.shortcuts.\(action.rawValue)")
    }

    private func actionTitle(_ action: GlobalShortcutAction) -> String {
        switch action {
        case .togglePanel: l10n.text(.settingsShortcutsActionTogglePanel)
        case .openSettings: l10n.text(.settingsShortcutsActionOpenSettings)
        case .openCurrentScopeEvents:
            l10n.text(.settingsShortcutsActionOpenCurrentScopeEvents)
        }
    }

    @ViewBuilder
    private func recordingButton(_ action: GlobalShortcutAction) -> some View {
        let button = Button(
            recordingAction == action
                ? l10n.text(.settingsShortcutsCancelRecording)
                : l10n.text(.settingsShortcutsRecord)
        ) {
            if recordingAction == action {
                stopRecording()
            } else if recordingAction != nil {
                recordingAction = action
            } else if model.suspendForRecording() {
                recordingAction = action
            } else {
                model.resumeAfterRecording()
                announceState(action)
            }
        }
        .accessibilityLabel(
            l10n.format(
                recordingAction == action
                    ? .settingsShortcutsCancelRecordingLabel
                    : .settingsShortcutsRecordLabel,
                actionTitle(action) as NSString)
        )
        .accessibilityHint(l10n.text(.settingsShortcutsRecordHint))
        .accessibilityIdentifier("settings.shortcuts.\(action.rawValue).record")

        button.focused(
            focusedTarget,
            equals: recordingButtonFocusTarget(action))
    }

    private func stopRecording(restoringFocus: Bool = true) {
        guard let action = recordingAction else { return }
        recordingAction = nil
        model.resumeAfterRecording()
        if restoringFocus { restoreRecordingButtonFocus(action) }
    }

    private func restoreRecordingButtonFocus(_ action: GlobalShortcutAction) {
        let target = recordingButtonFocusTarget(action)
        DispatchQueue.main.async {
            focusedTarget.wrappedValue = target
        }
    }

    private func recordingButtonFocusTarget(
        _ action: GlobalShortcutAction
    ) -> SettingsWindowFocusTarget {
        action == .togglePanel ? .firstAction(.shortcuts) : .shortcutAction(action)
    }

    private func actionDescription(_ action: GlobalShortcutAction) -> String {
        switch action {
        case .togglePanel: l10n.text(.settingsShortcutsActionTogglePanelDescription)
        case .openSettings: l10n.text(.settingsShortcutsActionOpenSettingsDescription)
        case .openCurrentScopeEvents:
            l10n.text(.settingsShortcutsActionOpenCurrentScopeEventsDescription)
        }
    }

    private func currentValue(_ state: GlobalShortcutItemState) -> String {
        state.shortcut?.displayName ?? l10n.text(.settingsShortcutsUnassigned)
    }

    private func announceState(_ action: GlobalShortcutAction) {
        let state = model.state(for: action)
        let value = state.failure.map(shortcutFailureText) ?? currentValue(state)
        onAnnouncement(
            l10n.format(
                .settingsAnnouncementValue,
                actionTitle(action) as NSString,
                value as NSString)
        )
    }

    private func shortcutFailureText(_ failure: GlobalShortcutOperationFailure) -> String {
        switch failure {
        case .invalidStoredValue:
            l10n.text(.settingsShortcutsFailureInvalidStoredValue)
        case .validation(.primaryModifierRequired):
            l10n.text(.settingsShortcutsFailurePrimaryModifier)
        case .validation(.unsupportedKeyCode):
            l10n.text(.settingsShortcutsFailureUnsupportedKey)
        case .validation(.systemReserved):
            l10n.text(.settingsShortcutsFailureSystemReserved)
        case .validation(.duplicate(let action)):
            l10n.format(
                .settingsShortcutsFailureDuplicate,
                actionTitle(action) as NSString)
        case .conflict:
            l10n.text(.settingsShortcutsFailureConflict)
        case .registrationFailed:
            l10n.text(.settingsShortcutsFailureRegistration)
        case .unregisterFailed:
            l10n.text(.settingsShortcutsFailureUnregister)
        case .persistenceFailed:
            l10n.text(.settingsShortcutsFailurePersistence)
        case .persistenceCleanupFailed:
            l10n.text(.settingsShortcutsFailurePersistenceCleanup)
        case .rollbackFailed:
            l10n.text(.settingsShortcutsFailureRollback)
        }
    }
}

/// A local first-responder-only recorder. It consumes exactly one keyDown while armed and never
/// installs an NSEvent monitor or retains a stream of characters.
private struct LocalShortcutCaptureView: NSViewRepresentable {
    let isRecording: Bool
    let onCapture: @MainActor (UInt32, GlobalShortcutModifiers) -> Void
    let onCancel: @MainActor () -> Void

    func makeNSView(context: Context) -> LocalShortcutCaptureNSView {
        LocalShortcutCaptureNSView(
            onCapture: onCapture,
            onCancel: onCancel)
    }

    func updateNSView(_ view: LocalShortcutCaptureNSView, context: Context) {
        view.isRecording = isRecording
        view.onCapture = onCapture
        view.onCancel = onCancel
        if isRecording {
            DispatchQueue.main.async { [weak view] in
                guard let view, view.isRecording else { return }
                view.window?.makeFirstResponder(view)
            }
        } else if view.window?.firstResponder === view {
            view.window?.makeFirstResponder(nil)
        }
    }
}

@MainActor
private final class LocalShortcutCaptureNSView: NSView {
    var isRecording = false
    var onCapture: @MainActor (UInt32, GlobalShortcutModifiers) -> Void
    var onCancel: @MainActor () -> Void

    init(
        onCapture: @escaping @MainActor (UInt32, GlobalShortcutModifiers) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.onCapture = onCapture
        self.onCancel = onCancel
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isRecording, !event.isARepeat else {
            super.keyDown(with: event)
            return
        }
        isRecording = false
        if event.keyCode == 53 {
            onCancel()
            return
        }
        onCapture(UInt32(event.keyCode), shortcutModifiers(event.modifierFlags))
    }
}

private func shortcutModifiers(_ flags: NSEvent.ModifierFlags) -> GlobalShortcutModifiers {
    var modifiers: GlobalShortcutModifiers = []
    let normalized = flags.intersection(.deviceIndependentFlagsMask)
    if normalized.contains(.command) { modifiers.insert(.command) }
    if normalized.contains(.control) { modifiers.insert(.control) }
    if normalized.contains(.option) { modifiers.insert(.option) }
    if normalized.contains(.shift) { modifiers.insert(.shift) }
    return modifiers
}
