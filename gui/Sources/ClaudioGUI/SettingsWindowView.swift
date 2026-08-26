import AppKit
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// Unified Settings navigation shell. Production preferences expose only migrated destinations;
/// DEBUG previews inject all destinations to validate typed routing and failure presentation.
@MainActor
struct SettingsWindowView: View {
    @ObservedObject var model: SettingsWindowPresentationModel<NSRunningApplication>
    @ObservedObject var preferences: ClaudioPreferences

    @FocusState private var focusedTarget: SettingsWindowFocusTarget?

    private var l10n: ClaudioL10n { ClaudioL10n(language: preferences.language) }
    private var destination: SettingsDestination { model.resolution.destination }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 252)
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            routeSlot
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: SettingsWindowGeometry.minimumWidth,
            minHeight: SettingsWindowGeometry.minimumHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l10n.text(.settingsWindowTitle))
        .onReceive(model.$routeRequestRevision) { _ in
            focusedTarget = SettingsWindowFocusTarget.title(destination)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("claudi0")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

            ForEach(preferences.availableSettingsDestinations) { item in
                Button {
                    model.request(.destination(item))
                } label: {
                    Label(
                        item.localizedName(language: preferences.language),
                        systemImage: icon(item))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(
                                    item == destination
                                        ? Color.accentColor.opacity(0.16) : .clear))
                }
                .buttonStyle(.plain)
                .focused($focusedTarget, equals: SettingsWindowFocusTarget.sidebar(item))
                .accessibilityLabel(item.localizedName(language: preferences.language))
                .accessibilitySortPriority(3)
                .accessibilityIdentifier("settings.sidebar.\(item.rawValue)")
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 20)
    }

    private var routeSlot: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 24) {
                Text(destination.localizedName(language: preferences.language))
                    .font(.system(size: 30, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilitySortPriority(2)
                    .focusable()
                    .focused(
                        $focusedTarget,
                        equals: SettingsWindowFocusTarget.title(destination))
                    .accessibilityIdentifier("settings.title.\(destination.rawValue)")

                if let failure = model.resolution.failure {
                    routeFailure(failure)
                } else if destination == .general {
                    generalSettings
                } else {
                    debugRouteContent
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 52)
            .padding(.vertical, 60)
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(l10n.text(.settingsGeneralLanguageDescription))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker(
                l10n.text(.settingsGeneralLanguageTitle),
                selection: languageModeBinding
            ) {
                ForEach(ClaudioLanguageMode.allCases) { mode in
                    Text(mode.localizedName(language: preferences.language))
                        .tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .focused(
                $focusedTarget,
                equals: SettingsWindowFocusTarget.firstAction(.general))
            .accessibilityLabel(l10n.text(.settingsGeneralLanguageTitle))
            .accessibilityValue(
                preferences.languageMode.localizedName(language: preferences.language))
            .accessibilityHint(l10n.text(.settingsGeneralLanguageHint))
            .accessibilitySortPriority(1)
            .accessibilityIdentifier("settings.general.language")

            if preferences.languageMode == .system {
                Label(
                    l10n.format(
                        .settingsGeneralSystemProjection,
                        preferences.language.selfName as NSString),
                    systemImage: "globe")
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("settings.general.language.system-projection")
            }

            if !preferences.recoveryIssues.isEmpty {
                Label {
                    Text(l10n.text(.settingsGeneralPreferenceRecovery))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                }
                .padding(12)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("settings.general.preference-recovery")
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private var debugRouteContent: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                Text(l10n.text(.settingsRouteIdentity))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(model.resolution.route.stableIdentityComponents.joined(separator: " / "))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }

            Label(l10n.text(.settingsRouteReady), systemImage: "checkmark.circle.fill")
                .foregroundColor(.secondary)
                .accessibilityIdentifier("settings.route.ready")

            Button(l10n.text(.settingsRouteReturnToSidebar)) {
                focusedTarget = SettingsWindowFocusTarget.sidebar(destination)
            }
            .focused(
                $focusedTarget,
                equals: SettingsWindowFocusTarget.firstAction(destination))
            .accessibilitySortPriority(1)
            .accessibilityIdentifier("settings.first-action.\(destination.rawValue)")
        }
    }

    private var languageModeBinding: Binding<ClaudioLanguageMode> {
        Binding(
            get: { preferences.languageMode },
            set: { preferences.setLanguageMode($0) })
    }

    private func routeFailure(_ failure: SettingsRouteFailure) -> some View {
        Label {
            Text(settingsFailureMessage(failure))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
        }
        .padding(14)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("settings.route.failure.\(destination.rawValue)")
    }

    private func settingsFailureMessage(_ failure: SettingsRouteFailure) -> String {
        switch failure {
        case .invalidSurface(let surface):
            l10n.format(.settingsRouteInvalidSurface, surface.rawValue as NSString)
        case .staleSurface(let surface):
            l10n.format(.settingsRouteStaleSurface, surface.rawValue as NSString)
        case .staleSoundScope(let scope):
            l10n.format(.settingsRouteStaleScope, scope.storedValue as NSString)
        case .staleEvent(let event):
            l10n.format(.settingsRouteStaleEvent, event.cliName as NSString)
        case .invalidSoundPackID:
            l10n.text(.settingsRouteInvalidPack)
        case .staleSoundPack(let packID):
            l10n.format(.settingsRouteStalePack, packID as NSString)
        }
    }

    private func icon(_ destination: SettingsDestination) -> String {
        switch destination {
        case .general: "gearshape"
        case .integrations: "puzzlepiece.extension"
        case .eventsAndSounds: "waveform"
        case .notifications: "bell"
        case .display: "display"
        case .sounds: "speaker.wave.2"
        case .usage: "chart.bar"
        case .shortcuts: "command"
        case .about: "info.circle"
        }
    }
}
