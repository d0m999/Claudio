import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import Combine
import SwiftUI

@MainActor
struct AboutSettingsView: View {
    @ObservedObject var model: AboutSettingsModel
    @ObservedObject var preferences: ClaudioPreferences
    let focusedTarget: FocusState<SettingsWindowFocusTarget?>.Binding
    let onAnnouncement: (@MainActor (String) -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    private var l10n: ClaudioL10n { ClaudioL10n(language: preferences.language) }
    private var unknown: String { l10n.text(.settingsAboutUnknown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            identity.settingsSectionSurface()
            resources.settingsSectionSurface()
            diagnostics.settingsSectionSurface()

            if let feedback = model.feedback {
                Label {
                    Text(feedbackText(feedback))
                        .foregroundColor(.secondary)
                } icon: {
                    Image(systemName: feedbackIcon(feedback))
                        .foregroundColor(
                            feedback.isFailure
                                ? ClaudioTheme.error(colorScheme)
                                : ClaudioTheme.success(colorScheme))
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.about.feedback")
            }
        }
        .font(ClaudioTheme.font(.body))
        .frame(maxWidth: 620, alignment: .leading)
        .onReceive(model.$feedback.dropFirst().compactMap { $0 }) { feedback in
            onAnnouncement?(feedbackText(feedback))
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                ClaudioOrbitWordmark(height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.bundleFacts.brandName ?? unknown)
                        .font(ClaudioTheme.font(.productTitle))
                    Text(model.bundleFacts.productName ?? unknown)
                        .font(ClaudioTheme.font(.sectionTitle))
                        .foregroundColor(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.about.identity")

            VStack(alignment: .leading, spacing: 7) {
                factRow(.settingsAboutVersion, value: model.bundleFacts.version)
                factRow(.settingsAboutBuild, value: model.bundleFacts.build)
                factRow(.settingsAboutArchitecture, value: model.bundleFacts.architecture)
                factRow(.settingsAboutMinimumMacOS, value: model.bundleFacts.minimumSystemVersion)
                factRow(.settingsAboutCurrentMacOS, value: model.bundleFacts.operatingSystemVersion)
            }

            Button(l10n.text(.settingsAboutCopyVersion)) {
                model.copyVersionInformation(language: preferences.language)
            }
            .focused(focusedTarget, equals: .firstAction(.about))
            .accessibilityHint(l10n.text(.settingsAboutCopyVersionHint))
            .accessibilityIdentifier("settings.about.copy-version")
        }
    }

    private var resources: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n.text(.settingsAboutResourcesTitle))
                .font(ClaudioTheme.font(.sectionTitle))
                .accessibilityAddTraits(.isHeader)
            Text(l10n.text(.settingsAboutResourcesDescription))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(model.resources) { resource in
                let presentation = resourcePresentation(resource.kind)
                if resource.url != nil {
                    Button {
                        model.openResource(resource)
                    } label: {
                        Label(presentation.name, systemImage: presentation.icon)
                    }
                    .accessibilityHint(
                        l10n.format(
                            .settingsAboutOpenResourceHint,
                            presentation.name as NSString)
                    )
                    .accessibilityIdentifier("settings.about.resource.\(resource.kind.rawValue)")
                } else {
                    Label {
                        Text(
                            l10n.format(
                                .settingsAboutResourceMissing,
                                presentation.name as NSString)
                        )
                        .foregroundColor(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(ClaudioTheme.error(colorScheme))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(
                        "settings.about.resource.\(resource.kind.rawValue).missing")
                }
            }
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n.text(.settingsAboutDiagnosticsTitle))
                .font(ClaudioTheme.font(.sectionTitle))
                .accessibilityAddTraits(.isHeader)
            Text(l10n.text(.settingsAboutDiagnosticsDescription))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.diagnosticSummary)
                .font(ClaudioTheme.font(.technical))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.section))
                .accessibilityLabel(l10n.text(.settingsAboutDiagnosticsTitle))
                .accessibilityValue(model.diagnosticSummary)
                .accessibilityIdentifier("settings.about.diagnostics.summary")
            Button(l10n.text(.settingsAboutCopyDiagnostics)) {
                model.copyDiagnostics()
            }
            .accessibilityHint(l10n.text(.settingsAboutCopyDiagnosticsHint))
            .accessibilityIdentifier("settings.about.diagnostics.copy")
        }
    }

    private func factRow(_ labelKey: ClaudioL10nKey, value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(l10n.text(labelKey))
                .foregroundColor(.secondary)
                .frame(width: 128, alignment: .leading)
            Text(value ?? unknown)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private func resourcePresentation(
        _ kind: AboutBundledResourceKind
    ) -> (name: String, icon: String) {
        switch kind {
        case .openSourceLicense:
            (l10n.text(.settingsAboutResourceOpenSourceLicense), "doc.text")
        case .soundAttribution:
            (l10n.text(.settingsAboutResourceSoundAttribution), "music.note.list")
        case .privacyStatement:
            (l10n.text(.settingsAboutResourcePrivacy), "hand.raised")
        }
    }

    private func feedbackText(_ feedback: AboutSettingsFeedback) -> String {
        switch feedback {
        case .versionCopied:
            l10n.text(.settingsAboutVersionCopied)
        case .diagnosticsCopied:
            l10n.text(.settingsAboutDiagnosticsCopied)
        case .clipboardFailed:
            l10n.text(.settingsAboutClipboardFailed)
        case .resourceOpenFailed(let resource):
            l10n.format(
                .settingsAboutOpenFailed,
                resourcePresentation(resource).name as NSString)
        }
    }

    private func feedbackIcon(_ feedback: AboutSettingsFeedback) -> String {
        feedback.isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }
}
