import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// Production-shape root for the real General/Login slice. #135 will extend this same root with
/// the complete destination tree; this initial mount contains no placeholder destinations.
@MainActor
package struct SettingsRootView: View {
    @ObservedObject private var session: SettingsPresentationSession

    package init(session: SettingsPresentationSession) {
        self.session = session
    }

    package var body: some View {
        let l10n = ClaudioL10n(language: session.state.language)
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 24) {
                Text(SettingsDestination.general.localizedName(language: session.state.language))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("settings.title.general")

                Text(l10n.text(.settingsGeneralLanguageDescription))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                sectionSurface {
                    Picker(
                        l10n.text(.settingsGeneralLanguageTitle),
                        selection: languageModeBinding
                    ) {
                        ForEach(ClaudioLanguageMode.allCases) { mode in
                            Text(mode.localizedName(language: session.state.language))
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .accessibilityLabel(l10n.text(.settingsGeneralLanguageTitle))
                    .accessibilityValue(
                        session.state.languageMode.localizedName(
                            language: session.state.language)
                    )
                    .accessibilityHint(l10n.text(.settingsGeneralLanguageHint))
                    .accessibilityIdentifier("settings.general.language")
                }

                sectionSurface {
                    LoginItemSettingsSection(session: session)
                }

                if !session.state.recoveryIssues.isEmpty {
                    FailureRow(message: l10n.text(.settingsGeneralPreferenceRecovery))
                        .padding(12)
                        .accessibilityIdentifier("settings.general.preference-recovery")
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 52)
            .padding(.vertical, 60)
        }
        .frame(minWidth: 560, minHeight: 440)
        .environment(\.dynamicTypeSize, session.state.interfaceTextSize.dynamicTypeSize)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SettingsPresentationAccessibilityID.root)
    }

    private var languageModeBinding: Binding<ClaudioLanguageMode> {
        Binding(
            get: { session.state.languageMode },
            set: { session.setLanguageMode($0) })
    }

    private func sectionSurface<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.section))
            .overlay {
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.section)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .accessibilityIdentifier(SettingsPresentationAccessibilityID.general)
    }
}
