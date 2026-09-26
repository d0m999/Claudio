import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioPanelPresentation
import Foundation
import SwiftUI

@MainActor
private final class MountedPanelPreviewPlayer: AudioPreviewPlaying {
    var startsPlayback = false
    private(set) var attempts = 0

    func play(fileAt url: URL, volume: Float) -> Bool {
        attempts += 1
        return startsPlayback
    }

    func stop() {}
}

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

    #if DEBUG
    suite("Panel mounted preview: click-time failure renders text and announces the same reason") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            let audioFile = packs.appendingPathComponent("pack-a/stop.mp3")
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(
                #"{"id":"pack-a","events":{"stop":"stop.mp3"}}"#,
                to: packs.appendingPathComponent("pack-a/manifest.json"))
            writeFixture("audio", to: audioFile)
            let config = ClaudioConfig(selectedPack: "pack-a", masterVolume: 0.42)
            try! JSONEncoder().encode(config).write(to: configFile)
            let environment = makeAudioImportEnvironment(userPacksDirectory: packs)
            let model = PanelConfigController(
                previewConfigState: .operational(config),
                eventRows: [
                    EventRow(event: .stop, coverage: .present(fileName: "stop.mp3"), enabled: true)
                ],
                environment: environment,
                previewConfigFile: configFile)
            let player = MountedPanelPreviewPlayer()
            var announcements: [String] = []
            let preferences = ClaudioPreferences(
                defaults: UserDefaults(suiteName: "com.orbitzero.claudio.panel-preview-mount")!,
                preferredLanguageIdentifiers: { ["en"] })
            let panel = PanelView(
                previewPanelModel: model,
                previewScope: .global,
                audioEnvironment: environment,
                focusCoordinator: PanelFocusCoordinator(),
                hostIntegrations: HostIntegrationPresentationStore(
                    state: integrationDestinationTestState()),
                languageStore: preferences,
                previewPlayer: player,
                onAnnounce: { announcements.append($0) })
            PanelPreviewMountRecorder.reset()
            defer { PanelPreviewMountRecorder.stopRecording() }
            let hostingView = NSHostingView(rootView: panel)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 312, height: 900),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hostingView
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil); window.close() }
            hostingView.layoutSubtreeIfNeeded()

            let expected = localizedEventPreviewAttemptFailure(
                .playbackFailed, language: .english)
            expect(
                PanelPreviewMountRecorder.invoke(.stop),
                "生产 Panel 的 stop 试听 Button 必须实际挂载并注册动作")
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            expect(player.attempts == 1, "挂载按钮必须经 controller 点击时读回后调用播放器一次")
            expect(announcements == [expected], "播放器启动失败必须经面板播报通道送出原原因")
            expect(
                PanelPreviewMountRecorder.visibleFailure(for: .stop) == expected,
                "播放器启动失败必须在挂载生产事件行里出现可见文字")

            try! FileManager.default.removeItem(at: audioFile)
            let changed = localizedEventPreviewAttemptFailure(
                .assetChanged, language: .english)
            expect(
                PanelPreviewMountRecorder.invoke(.stop),
                "点击前文件失效时仍应由已挂载的试听按钮消费动作")
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            expect(player.attempts == 1, "文件失效不得再次启动播放器")
            expect(announcements == [expected, changed], "文件失效必须播报自己的原因")
            expect(
                PanelPreviewMountRecorder.visibleFailure(for: .stop) == changed,
                "文件失效必须替换为挂载生产事件行里的可见原因")
        }
    }
    #endif
}
