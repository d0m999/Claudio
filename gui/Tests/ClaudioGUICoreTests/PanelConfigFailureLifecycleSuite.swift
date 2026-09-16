import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
func runPanelConfigFailureLifecycleSuites() {
    suite("PanelConfigController：写后刷新保留错误，外部刷新清除过期错误") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDirectory = root.appendingPathComponent("packs", isDirectory: true)
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(
                #"{ "selected_pack": "minimal-chime", "master_volume": "broken", "events": {} }"#,
                to: configFile)

            let controller = PanelConfigController(
                configFile: configFile,
                lockFile: lockFile,
                environment: makeAudioImportEnvironment(userPacksDirectory: packsDirectory))

            guard case .malformed = controller.configState else {
                expect(false, "损坏配置的初始状态必须是 .malformed")
                return
            }

            controller.toggleMute(.stop)
            expect(controller.muteError != nil, "静音写失败必须保留 typed 操作错误")
            guard case .malformed = controller.configState else {
                expect(false, "写后 config-only 刷新必须继续呈现磁盘损坏状态")
                return
            }

            controller.setMasterVolume(0.5)
            expect(controller.masterVolumeError != nil, "主音量写失败必须保留 typed 操作错误")

            controller.reloadConfigOnly()
            expect(
                controller.muteError == nil && controller.masterVolumeError == nil,
                "外部/重新打开面板刷新必须清掉过期的写错误")
            guard case .malformed = controller.configState else {
                expect(false, "外部刷新不能把真实损坏状态降级成 needsPack")
                return
            }
        }
    }

    suite("PanelConfigController：同一次失败的不同写者可并存，成功同类操作才清除自身错误") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDirectory = root.appendingPathComponent("packs", isDirectory: true)
            writeFixture(
                #"{ "selected_pack": "minimal-chime", "master_volume": "broken", "events": {} }"#,
                to: configFile)
            let controller = PanelConfigController(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: makeAudioImportEnvironment(userPacksDirectory: packsDirectory))

            controller.toggleMute(.notification)
            controller.setMasterVolume(0.25)
            expect(
                controller.muteError != nil && controller.masterVolumeError != nil,
                "不同写者的失败不能互相覆盖")

            writeFixture(
                #"{ "selected_pack": "minimal-chime", "master_volume": 0.42, "events": {} }"#,
                to: configFile)
            controller.toggleMute(.notification)
            expect(
                controller.muteError == nil,
                "同类静音操作成功后必须清除静音错误")
        }
    }

    suite("PanelConfigController：试听文件失效后全量刷新保留未解决的写入错误") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let packsDirectory = root.appendingPathComponent("packs")
            let audioFile = packsDirectory.appendingPathComponent("pack-a/stop.mp3")
            writeFixture(
                #"{ "selected_pack": "pack-a", "master_volume": 0.42, "events": {} }"#,
                to: configFile)
            writeFixture(
                #"{ "id": "pack-a", "events": { "stop": "stop.mp3" } }"#,
                to: packsDirectory.appendingPathComponent("pack-a/manifest.json"))
            writeFixture("audio", to: audioFile)
            let environment = makeAudioImportEnvironment(userPacksDirectory: packsDirectory)
            var fullReloads = 0
            let controller = PanelConfigController(
                configFile: configFile,
                lockFile: lockFile,
                environment: environment,
                afterFullReload: { _ in fullReloads += 1 })
            guard let oldRow = controller.eventRows.first(where: { $0.event == .stop }) else {
                expect(false, "前提：stop 行必须存在")
                return
            }
            expect(
                eventPreviewFileURL(row: oldRow, packID: "pack-a", environment: environment)
                    == audioFile,
                "前提：试听文件原本必须可解析")

            let packOutcome = controller.switchPack(to: "missing-pack")
            expect(
                packOutcome == .failed(.packNotFound("missing-pack"))
                    && controller.packSwitchError == .packNotFound("missing-pack"),
                "前提：切包失败必须留下可见的写入错误")
            let holder = FileLock(path: lockFile.path)
            guard holder.tryLock() else {
                expect(false, "前提：必须先取得 config.lock")
                return
            }
            controller.toggleMute(.stop)
            _ = controller.setMasterVolume(0.5)
            holder.unlock()
            expect(
                controller.muteError == .lockBusy && controller.masterVolumeError == .lockBusy,
                "前提：静音和主音量失败必须留下可见的写入错误")

            guard (try? FileManager.default.removeItem(at: audioFile)) != nil else {
                expect(false, "前提：试听文件必须能够被删除")
                return
            }
            expect(
                eventPreviewFileURL(row: oldRow, packID: "pack-a", environment: environment)
                    == nil,
                "旧行的试听文件失效必须触发预览刷新路径")
            let reloadsBeforePreview = fullReloads
            controller.reloadAfterMissingPreview()
            expect(fullReloads == reloadsBeforePreview + 1, "试听失效必须全量刷新读模型")
            expect(
                controller.eventRows.first(where: { $0.event == .stop })?.coverage
                    == .broken(fileName: "stop.mp3"),
                "试听失效后事件行必须反映磁盘上的缺失文件")
            expect(
                controller.packSwitchError == .packNotFound("missing-pack")
                    && controller.muteError == .lockBusy
                    && controller.masterVolumeError == .lockBusy,
                "试听刷新不能清除尚未重试的配置写入错误")

            controller.reload()
            expect(
                controller.packSwitchError == nil && controller.muteError == nil
                    && controller.masterVolumeError == nil,
                "真正的外部刷新仍应清掉过期的写入错误")
        }
    }
}
