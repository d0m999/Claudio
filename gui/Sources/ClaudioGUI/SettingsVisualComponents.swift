import ClaudioGUIComponents
import SwiftUI

#if DEBUG
private struct SettingsReduceTransparencyOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    /// Controlled visual-environment seam. Production leaves this nil and follows AppKit;
    /// deterministic render and snapshot hosts may inject the same platform fact explicitly.
    var settingsReduceTransparencyOverride: Bool? {
        get { self[SettingsReduceTransparencyOverrideKey.self] }
        set { self[SettingsReduceTransparencyOverrideKey.self] = newValue }
    }
}
#endif

/// One shared native Settings surface. It keeps the approved 13 pt group radius and strengthens
/// its boundary under Increase Contrast without replacing the system control background.
struct SettingsSectionCard<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    #if DEBUG
    @Environment(\.settingsReduceTransparencyOverride) private var reduceTransparencyOverride
    #endif
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.colorScheme) private var colorScheme

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                effectiveReduceTransparency
                    ? ClaudioTheme.surface(colorScheme)
                    : ClaudioTheme.elevated(colorScheme)
            )
            .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.section))
            .overlay {
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.section)
                    .stroke(
                        colorSchemeContrast == .increased
                            ? ClaudioTheme.secondaryText(colorScheme).opacity(0.38)
                            : ClaudioTheme.hairline(colorScheme),
                        lineWidth: colorSchemeContrast == .increased ? 1.5 : 1)
            }
    }

    private var effectiveReduceTransparency: Bool {
        #if DEBUG
        reduceTransparencyOverride ?? reduceTransparency
        #else
        reduceTransparency
        #endif
    }
}

extension View {
    func settingsSectionSurface() -> some View {
        SettingsSectionCard { self }
    }
}
