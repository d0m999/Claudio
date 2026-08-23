import ClaudioCore
import Foundation

@MainActor
func runSurfaceSoundPreferencesSuites() {
    suite("surface profile：按字段稀疏继承，全局 master volume 不进入覆盖") {
        let data = Data(
            #"{"selected_pack":"global","master_volume":0.42,"events":{"stop":false},"surface_overrides":{"workbuddy":{"selected_pack":"work","events":{"stop":true}}}}"#
                .utf8)
        let config = try! JSONDecoder().decode(ClaudioConfig.self, from: data)
        guard case .success(let workBuddy) = config.resolveSoundProfile(for: .workBuddy),
            case .success(let codex) = config.resolveSoundProfile(for: .codex)
        else {
            expect(false, "合法稀疏覆盖必须可解析")
            return
        }
        expect(workBuddy.selectedPack == "work" && !workBuddy.inheritedPack, "WorkBuddy 必须覆盖 pack")
        expect(workBuddy.isEnabled(.stop), "surface 事件开关必须覆盖全局默认")
        expect(workBuddy.isEnabled(.notification), "缺失事件键必须继承全局 enabled 默认")
        expect(codex.selectedPack == "global" && codex.inheritedPack, "无覆盖 surface 必须继承全局 pack")
        expect(!codex.isEnabled(.stop), "无覆盖 surface 必须继承全局事件静音")
        expect(config.masterVolume == 0.42, "masterVolume 只能是全局安全闸")
    }

    suite("surface profile：单个显式坏覆盖只让目标 surface 失败关闭") {
        let data = Data(
            #"{"selected_pack":"global","surface_overrides":{"workbuddy":{"events":{"stop":1}},"codex":{"events":{"stop":true}}}}"#
                .utf8)
        let config = try! JSONDecoder().decode(ClaudioConfig.self, from: data)
        expect(
            config.resolveSoundProfile(for: .workBuddy)
                == .failure(.malformedOverride(surface: .workBuddy)),
            "显式坏 WorkBuddy override 不得回退到 global")
        guard case .success(let codex) = config.resolveSoundProfile(for: .codex) else {
            expect(false, "兄弟 surface 的合法覆盖不应被连带破坏")
            return
        }
        expect(codex.isEnabled(.stop), "合法 Codex 覆盖仍应生效")
    }

    suite("surface mutation：外科式写入与逐字段/整 surface reset 保留未知键") {
        withTempDirectory { root in
            let config = root.appendingPathComponent("config.json")
            let lock = root.appendingPathComponent("config.lock")
            writeFixture(
                #"{"selected_pack":"global","future":{"keep":true},"surface_overrides":{"workbuddy":{"future_surface":"keep"}}}"#,
                to: config)

            expect(
                setSurfaceEventEnabled(
                    .stop,
                    enabled: false,
                    surface: .workBuddy,
                    configFile: config,
                    lockFile: lock) == .success(.updated(surface: .workBuddy)),
                "surface event 写入必须成功")
            var object =
                try! JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
            var override =
                ((object["surface_overrides"] as! [String: Any])["workbuddy"] as! [String: Any])
            expect((override["events"] as? [String: Any])?["stop"] as? Bool == false, "必须写入稀疏事件位")
            expect(override["future_surface"] as? String == "keep", "surface 内未知键必须保留")
            expect((object["future"] as? [String: Any])?["keep"] as? Bool == true, "顶层未知键必须保留")

            expect(
                resetSurfaceSoundOverride(
                    surface: .workBuddy,
                    field: .event(.stop),
                    configFile: config,
                    lockFile: lock) == .success(.updated(surface: .workBuddy)),
                "单字段 reset 必须成功")
            object =
                try! JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
            override =
                ((object["surface_overrides"] as! [String: Any])["workbuddy"] as! [String: Any])
            expect(
                override["events"] == nil && override["future_surface"] as? String == "keep",
                "reset 只能删目标字段")

            expect(
                resetSurfaceSoundOverride(
                    surface: .workBuddy,
                    configFile: config,
                    lockFile: lock) == .success(.updated(surface: .workBuddy)),
                "整 surface reset 必须成功")
            object =
                try! JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
            expect(object["surface_overrides"] == nil, "最后一个 override 清空后应移除空容器")
            expect((object["future"] as? [String: Any])?["keep"] as? Bool == true, "reset 不得损伤兄弟键")
        }
    }

    suite("surface mutation：缺少全局 config 时拒绝伪造选择") {
        withTempDirectory { root in
            let result = setSurfaceEventEnabled(
                .stop,
                enabled: false,
                surface: .workBuddy,
                configFile: root.appendingPathComponent("missing.json"),
                lockFile: root.appendingPathComponent("config.lock"))
            expect(result == .failure(.configMissing), "没有全局选择时不得新建 surface-only config")
        }
    }
}
