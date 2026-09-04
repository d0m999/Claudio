import ClaudioGUICore
import SwiftUI

package enum SettingsRootInteractionDriver {
    package static func movedDestination(
        _ direction: SettingsSidebarMoveDirection,
        from current: SettingsDestination,
        availableDestinations: [SettingsDestination]
    ) -> SettingsDestination? {
        let next = settingsSidebarDestination(
            moving: direction,
            from: current,
            availableDestinations: availableDestinations)
        return next == current ? nil : next
    }

    package static func exitFocusTarget(
        destination: SettingsDestination
    ) -> SettingsWindowFocusTarget {
        .sidebar(destination)
    }
}

extension View {
    func settingsSidebarInteraction(
        item: SettingsDestination,
        availableDestinations: [SettingsDestination],
        onSelect: @escaping @MainActor (SettingsDestination) -> Void
    ) -> some View {
        modifier(
            SettingsSidebarInteractionModifier(
                item: item,
                availableDestinations: availableDestinations,
                onSelect: onSelect))
    }

    func settingsExitInteraction(
        destination: SettingsDestination,
        onFocus: @escaping @MainActor (SettingsWindowFocusTarget) -> Void
    ) -> some View {
        modifier(
            SettingsExitInteractionModifier(
                destination: destination,
                onFocus: onFocus))
    }
}

private struct SettingsSidebarInteractionModifier: ViewModifier {
    let item: SettingsDestination
    let availableDestinations: [SettingsDestination]
    let onSelect: @MainActor (SettingsDestination) -> Void

    func body(content: Content) -> some View {
        content
            .onMoveCommand { direction in
                let move: SettingsSidebarMoveDirection?
                switch direction {
                case .up: move = .previous
                case .down: move = .next
                default: move = nil
                }
                if let move { performMove(move) }
            }
            #if DEBUG
        .background(
            SettingsSidebarInteractionReportingView(
                item: item,
                performMove: performMove
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true))
            #endif
    }

    private func performMove(_ move: SettingsSidebarMoveDirection) {
        guard
            let next = SettingsRootInteractionDriver.movedDestination(
                move,
                from: item,
                availableDestinations: availableDestinations)
        else { return }
        onSelect(next)
    }
}

private struct SettingsExitInteractionModifier: ViewModifier {
    let destination: SettingsDestination
    let onFocus: @MainActor (SettingsWindowFocusTarget) -> Void

    func body(content: Content) -> some View {
        content
            .onExitCommand(perform: performExit)
            #if DEBUG
        .background(
            SettingsExitInteractionReportingView(performExit: performExit)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true))
            #endif
    }

    private func performExit() {
        let target = SettingsRootInteractionDriver.exitFocusTarget(destination: destination)
        #if DEBUG
        SettingsRootInteractionRecorder.noteExit(target)
        #endif
        onFocus(target)
    }
}

#if DEBUG
@MainActor
package enum SettingsRootInteractionRecorder {
    private static var moveHandlers: [SettingsDestination: (SettingsSidebarMoveDirection) -> Void] =
        [:]
    private static var exitHandler: (() -> Void)?
    private static var isRecording = false
    package private(set) static var lastExitTarget: SettingsWindowFocusTarget?

    package static func reset() {
        moveHandlers.removeAll()
        exitHandler = nil
        lastExitTarget = nil
        isRecording = true
    }

    package static func stopRecording() {
        moveHandlers.removeAll()
        exitHandler = nil
        lastExitTarget = nil
        isRecording = false
    }

    static func registerMove(
        item: SettingsDestination,
        handler: @escaping (SettingsSidebarMoveDirection) -> Void
    ) {
        guard isRecording else { return }
        moveHandlers[item] = handler
    }

    static func registerExit(handler: @escaping () -> Void) {
        guard isRecording else { return }
        exitHandler = handler
    }

    static func noteExit(_ target: SettingsWindowFocusTarget) {
        guard isRecording else { return }
        lastExitTarget = target
    }

    @discardableResult
    package static func invokeMove(
        _ direction: SettingsSidebarMoveDirection,
        from item: SettingsDestination
    ) -> Bool {
        guard let handler = moveHandlers[item] else { return false }
        handler(direction)
        return true
    }

    @discardableResult
    package static func invokeExit() -> Bool {
        guard let exitHandler else { return false }
        exitHandler()
        return true
    }
}

private struct SettingsSidebarInteractionReportingView: NSViewRepresentable {
    let item: SettingsDestination
    let performMove: @MainActor (SettingsSidebarMoveDirection) -> Void

    func makeNSView(context _: Context) -> NSView {
        register()
        return NSView(frame: .zero)
    }

    func updateNSView(_: NSView, context _: Context) {
        register()
    }

    private func register() {
        SettingsMountRecorder.record("settings.interaction.sidebar.\(item.rawValue)")
        SettingsRootInteractionRecorder.registerMove(item: item, handler: performMove)
    }
}

private struct SettingsExitInteractionReportingView: NSViewRepresentable {
    let performExit: @MainActor () -> Void

    func makeNSView(context _: Context) -> NSView {
        register()
        return NSView(frame: .zero)
    }

    func updateNSView(_: NSView, context _: Context) {
        register()
    }

    private func register() {
        SettingsMountRecorder.record("settings.interaction.exit")
        SettingsRootInteractionRecorder.registerExit(handler: performExit)
    }
}
#endif
