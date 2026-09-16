import AppKit
import ClaudioGUICore
import ClaudioPanelPresentation
import Foundation
import SwiftUI

/// The harness must mount the same production `PanelView` type that the menu-bar composition
/// uses. Source scans can prove a callback exists; an `NSHostingView` proves the split target is
/// actually importable and that the view can be composed into AppKit without a gallery-only copy.
@MainActor
func runPanelPresentationMountSuites() {
    suite("Panel presentation: production view mounts through NSHostingView") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            let environment = makeAudioImportEnvironment(userPacksDirectory: packs)
            let panelModel = PanelConfigController(
                previewConfigState: .needsPack,
                environment: environment)
            let hostIntegrations = HostIntegrationPresentationStore(
                state: integrationDestinationTestState())
            let preferences = ClaudioPreferences(
                defaults: UserDefaults(suiteName: "com.orbitzero.claudio.panel-mount")!,
                preferredLanguageIdentifiers: { ["en"] })
            let panel = PanelView(
                previewPanelModel: panelModel,
                previewScope: .global,
                audioEnvironment: environment,
                focusCoordinator: PanelFocusCoordinator(),
                hostIntegrations: hostIntegrations,
                languageStore: preferences)

            let hostingView = NSHostingView(rootView: panel)
            hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 620)
            hostingView.layoutSubtreeIfNeeded()

            expect(
                hostingView.fittingSize.width > 0 && hostingView.fittingSize.height > 0,
                "NSHostingView 挂载生产 PanelView 后必须有非零 fittingSize")
        }
    }
}
