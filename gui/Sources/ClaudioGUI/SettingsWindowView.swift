#if DEBUG
import AppKit
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// DEBUG-only unified Settings navigation shell. Destination migrations inject real content later;
/// this gallery surface validates typed routing, failures, geometry, scrolling, and focus order.
@MainActor
struct SettingsWindowView: View {
    @ObservedObject var model: SettingsWindowPresentationModel<NSRunningApplication>
    @ObservedObject var languageStore: ClaudioLanguageStore

    @FocusState private var focusedTarget: SettingsWindowFocusTarget?

    private var l10n: ClaudioL10n { ClaudioL10n(language: languageStore.language) }
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

            ForEach(SettingsDestination.allCases) { item in
                Button {
                    model.request(.destination(item))
                } label: {
                    Label(
                        item.localizedName(language: languageStore.language),
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
                .accessibilityLabel(item.localizedName(language: languageStore.language))
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
                Text(destination.localizedName(language: languageStore.language))
                    .font(.system(size: 30, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilitySortPriority(2)
                    .focusable()
                    .focused(
                        $focusedTarget,
                        equals: SettingsWindowFocusTarget.title(destination))
                    .accessibilityIdentifier("settings.title.\(destination.rawValue)")

                VStack(alignment: .leading, spacing: 8) {
                    Text(l10n.text(.settingsRouteIdentity))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(model.resolution.route.stableIdentityComponents.joined(separator: " / "))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }

                if let failure = model.resolution.failure {
                    routeFailure(failure)
                } else {
                    Label(l10n.text(.settingsRouteReady), systemImage: "checkmark.circle.fill")
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier("settings.route.ready")
                }

                Button(l10n.text(.settingsRouteReturnToSidebar)) {
                    focusedTarget = SettingsWindowFocusTarget.sidebar(destination)
                }
                .focused(
                    $focusedTarget,
                    equals: SettingsWindowFocusTarget.firstAction(destination))
                .accessibilitySortPriority(1)
                .accessibilityIdentifier("settings.first-action.\(destination.rawValue)")
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 52)
            .padding(.vertical, 60)
        }
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
#endif
