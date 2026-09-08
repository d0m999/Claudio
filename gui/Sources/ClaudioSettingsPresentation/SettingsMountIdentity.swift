import ClaudioGUICore
import SwiftUI

extension SettingsPresentationAccessibilityID {
    package static func destination(_ destination: SettingsDestination) -> String {
        if destination == .general { return general }
        return "settings.destination.\(destination.rawValue)"
    }
}

extension View {
    @ViewBuilder
    func settingsMountIdentity(_ identifier: String) -> some View {
        #if DEBUG
        modifier(SettingsMountIdentityModifier(identifier: identifier))
        #else
        accessibilityIdentifier(identifier)
        #endif
    }
}

#if DEBUG
private struct SettingsMountIdentityModifier: ViewModifier {
    let identifier: String

    func body(content: Content) -> some View {
        content
            .accessibilityIdentifier(identifier)
            .background(
                SettingsMountReportingView(identifier: identifier)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true))
    }
}

@MainActor
package enum SettingsMountRecorder {
    package private(set) static var identifiers: [String] = []

    package static func reset() {
        identifiers.removeAll()
    }

    static func record(_ identifier: String) {
        if !identifiers.contains(identifier) { identifiers.append(identifier) }
    }
}

struct SettingsMountReportingView: NSViewRepresentable {
    let identifier: String

    func makeNSView(context _: Context) -> NSView {
        SettingsMountRecorder.record(identifier)
        return NSView(frame: .zero)
    }

    func updateNSView(_: NSView, context _: Context) {
        SettingsMountRecorder.record(identifier)
    }
}
#endif
