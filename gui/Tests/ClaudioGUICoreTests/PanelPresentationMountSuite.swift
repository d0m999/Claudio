import AppKit
import ClaudioCore
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

    suite("Panel presentation: refresh failure mounts the production panel with stale events") {
        withTempDirectory { root in
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true))
            let config = ClaudioConfig(
                selectedPack: "fixture-pack",
                masterVolume: 0.8,
                eventsEnabled: Dictionary(
                    uniqueKeysWithValues: Event.allCases.map { ($0.cliName, true) }))
            let panelModel = PanelConfigController(
                previewConfigState: .operational(config),
                eventRows: Event.allCases.map {
                    EventRow(
                        event: $0,
                        coverage: .present(fileName: "\($0.cliName).aiff"),
                        enabled: true)
                },
                libraryPresentationState: .refreshFailed(reason: "fixture scan failure"),
                environment: environment)
            let preferences = ClaudioPreferences(
                defaults: UserDefaults(suiteName: "com.orbitzero.claudio.panel-refresh-mount")!,
                preferredLanguageIdentifiers: { ["zh-Hans"] })
            let panel = PanelView(
                previewPanelModel: panelModel,
                previewScope: .global,
                audioEnvironment: environment,
                focusCoordinator: PanelFocusCoordinator(),
                hostIntegrations: HostIntegrationPresentationStore(
                    state: integrationDestinationTestState()),
                languageStore: preferences)
            let hostingView = NSHostingView(rootView: panel)
            hostingView.frame = NSRect(x: 0, y: 0, width: 312, height: 560)
            hostingView.layoutSubtreeIfNeeded()
            expect(
                hostingView.fittingSize.width > 0 && hostingView.fittingSize.height > 0,
                "带旧事件快照的刷新失败状态必须能挂载同一个生产 PanelView")
        }
    }
}
