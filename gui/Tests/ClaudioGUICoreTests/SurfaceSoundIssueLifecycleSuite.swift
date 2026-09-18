import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
func runSurfaceSoundIssueLifecycleSuites() {
    suite("Surface 声音问题：结构性损坏只在当前覆盖有效读回恢复后清除") {
        let issue = SurfaceSoundIssue.malformedOverride(message: "覆盖已损坏")
        // Strict disk validation routes malformed override JSON to the top-level config failure.
        // Use a decoded config here to verify the independent Surface issue lifecycle.
        let broken = ClaudioConfig(
            selectedPack: "global-pack",
            invalidSurfaceOverrideKeys: [HostSurfaceID.workBuddy.rawValue])
        let healthy = ClaudioConfig(selectedPack: "global-pack")

        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(
                #"{ "selected_pack": "global-pack", "surface_overrides": { "workbuddy": { "selected_pack": 7 } } }"#,
                to: configFile)
            let controller = PanelConfigController(
                previewConfigState: .operational(broken),
                environment: makeAudioImportEnvironment(
                    userPacksDirectory: root.appendingPathComponent("packs")),
                previewConfigFile: configFile)
            controller.selectSoundSurface(.workBuddy)
            expect(controller.surfaceSoundIssue != nil, "解析失败必须置入结构性问题")
            expect(
                controller.config.selectedPack.isEmpty && !controller.config.isEnabled(.stop),
                "损坏的显式覆盖必须停止该 Surface，不能继承全局包")

            controller.reloadConfigOnly()
            expect(controller.surfaceSoundIssue != nil, "磁盘上的覆盖仍损坏时重载不能清除问题")
            writeFixture(
                #"{ "selected_pack": "global-pack", "surface_overrides": {} }"#,
                to: configFile)
            controller.reloadConfigOnly()
            expect(controller.surfaceSoundIssue == nil, "外部修复覆盖并有效读回后必须清除结构性问题")
            expect(controller.config.selectedPack == "global-pack", "恢复后必须投影健康的声音配置")
        }

        expect(
            surfaceSoundIssueAfterReadBack(
                issue, configState: .operational(broken), selectedSurface: .workBuddy) == issue,
            "当前 Surface 覆盖仍损坏时必须保留问题")
        expect(
            surfaceSoundIssueAfterReadBack(
                issue, configState: .malformed(reason: "读回失败"),
                selectedSurface: .workBuddy) == issue,
            "配置未有效读回不能充当恢复证据")
        expect(
            surfaceSoundIssueAfterReadBack(
                issue, configState: .operational(healthy), selectedSurface: nil) == issue,
            "没有当前 Surface 时不能用全局配置证明该覆盖已恢复")
        expect(
            surfaceSoundIssueAfterReadBack(
                issue, configState: .operational(healthy), selectedSurface: .workBuddy) == nil,
            "当前 Surface 覆盖经有效读回恢复健康后必须清除结构性问题")
    }

    suite("Surface 声音问题：写失败不因健康读回而消失") {
        let issue = SurfaceSoundIssue.writeFailure(message: "锁忙")
        let healthy = ClaudioConfig(selectedPack: "global-pack")
        expect(
            surfaceSoundIssueAfterReadBack(
                issue, configState: .operational(healthy), selectedSurface: .workBuddy) == issue,
            "写失败不能被一次成功读回误判为写入能力恢复")

        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let packsDirectory = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "selected_pack": "global-pack", "surface_overrides": { "workbuddy": {} } }"#,
                to: configFile)
            let controller = PanelConfigController(
                configFile: configFile,
                lockFile: lockFile,
                environment: makeAudioImportEnvironment(userPacksDirectory: packsDirectory))
            controller.selectSoundSurface(.workBuddy)
            let holder = FileLock(path: lockFile.path)
            guard holder.tryLock() else {
                expect(false, "前提：须先取得 config.lock")
                return
            }
            controller.toggleMute(.stop)
            holder.unlock()
            let failedMessage = controller.surfaceSoundIssue
            expect(failedMessage != nil, "Surface 静音写失败必须显示问题")

            controller.reloadConfigOnly()
            expect(
                controller.surfaceSoundIssue == failedMessage,
                "配置健康读回后仍须保留未解决的 Surface 写失败")
            controller.selectSoundSurface(nil)
            expect(controller.surfaceSoundIssue == nil, "切换作用域只丢弃当前瞬时问题提示")
        }
    }
}
