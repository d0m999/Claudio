import AppKit
import ClaudioGUIComponents
import SwiftUI

/// One shared native Settings surface. It keeps the approved 13 pt group radius and strengthens
/// its boundary under Increase Contrast without replacing the system control background.
struct SettingsSectionCard<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                reduceTransparency
                    ? Color(nsColor: .windowBackgroundColor)
                    : Color(nsColor: .controlBackgroundColor)
            )
            .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.section))
            .overlay {
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.section)
                    .stroke(
                        Color.primary.opacity(colorSchemeContrast == .increased ? 0.22 : 0.08),
                        lineWidth: colorSchemeContrast == .increased ? 1.5 : 1)
            }
    }
}

extension View {
    func settingsSectionSurface() -> some View {
        SettingsSectionCard { self }
    }
}
