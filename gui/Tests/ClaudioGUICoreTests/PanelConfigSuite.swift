import ClaudioCore
import ClaudioGUICore
import Foundation

// MARK: - loadPanelConfig (ENGINEERING.md T15 D1 panel glue, rewritten for D23): the panel's
// complete verdict on config.json — combining the read axis (packSelection) and the write axis
// (probeConfigRewritable) into one ``PanelConfigState``. Never crashes over a missing/corrupt
// config.json, but — unlike the pre-D23 shape — no longer collapses "nobody has chosen a pack
// yet" (self-heal is open) and "the file itself is broken" (self-heal is NOT open, needs an
// honest failure state + a fix instruction) into the same empty-pack default.

@MainActor
func runPanelConfigSuites() {
    suite("loadPanelConfig: a missing config.json is .needsPack — not an error, the self-heal path (picking a pack) is open") {
        withTempDirectory { root in
            let state = loadPanelConfig(from: root.appendingPathComponent("config.json"))
            expect(state == .needsPack, "a missing file must report .needsPack, got \(state)")
            expect(
                state.resolvedConfig.selectedPack == "",
                "resolvedConfig must still hand back an empty-pack default for read models"
                    + " (packCoverage/availablePacks), got \(state.resolvedConfig.selectedPack)")
            expect(
                state.resolvedConfig.masterVolume == ClaudioConfig.defaultMasterVolume,
                "resolvedConfig's default must match the documented default master_volume")
        }
    }

    suite("loadPanelConfig: a corrupt config.json is .malformed with an actionable reason — never .needsPack (D23: these two used to be the same empty-pack fallback, hiding that self-heal is NOT open here)") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture("{ not valid json", to: configFile)
            let state = loadPanelConfig(from: configFile)
            guard case .malformed(let reason) = state else {
                expect(false, "a corrupt file must report .malformed, got \(state)")
                return
            }
            expect(!reason.isEmpty, "the malformed reason must not be empty")
            expect(
                state.resolvedConfig.selectedPack == "",
                "resolvedConfig must still be crash-safe for a malformed file, got"
                    + " \(state.resolvedConfig.selectedPack)")
        }
    }

    suite("loadPanelConfig: selected_pack is an empty string is .needsPack, same as a missing file") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(#"{ "selected_pack": "" }"#, to: configFile)
            let state = loadPanelConfig(from: configFile)
            expect(state == .needsPack, "an empty selected_pack must report .needsPack, got \(state)")
        }
    }

    suite("loadPanelConfig: a well-formed config.json decodes exactly into .operational") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(
                #"{ "selected_pack": "minimal-chime", "master_volume": 0.42, "events": { "stop": false } }"#,
                to: configFile)
            let state = loadPanelConfig(from: configFile)
            guard case .operational(let config) = state else {
                expect(false, "a well-formed config must report .operational, got \(state)")
                return
            }
            expect(config.selectedPack == "minimal-chime", "got \(config.selectedPack)")
            expect(config.masterVolume == 0.42, "got \(config.masterVolume)")
            expect(config.isEnabled(.stop) == false, "got \(config.isEnabled(.stop))")
        }
    }

    suite(
        "loadPanelConfig: selected_pack parses fine but master_volume is a string (读得动、写不动)"
            + " — must be .malformed, never .operational (D23 定稿②'s whole reason for existing:"
            + " the read axis alone would call this usable, and every click would then fail)"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(
                #"{ "selected_pack": "lofi", "master_volume": "0.35" }"#, to: configFile)
            let state = loadPanelConfig(from: configFile)
            guard case .malformed = state else {
                expect(
                    false,
                    "a config that reads as selected but fails the write axis must be .malformed,"
                        + " not .operational — got \(state)")
                return
            }
        }
    }

    suite("loadPanelConfig: content is fine but the parent directory is read-only → .unwritable, not .operational") {
        guard geteuid() != 0 else {
            print("  ⚠︎ 跳过：当前以 root 运行，chmod 只读目录挡不住 root 写入")
            return
        }
        withTempDirectory { root in
            let restrictedDirectory = root.appendingPathComponent("restricted", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: restrictedDirectory, withIntermediateDirectories: true)
            let configFile = restrictedDirectory.appendingPathComponent("config.json")
            writeFixture(#"{ "selected_pack": "lofi" }"#, to: configFile)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o500], ofItemAtPath: restrictedDirectory.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: restrictedDirectory.path)
            }

            let state = loadPanelConfig(from: configFile)
            guard case .unwritable(let reason) = state else {
                expect(false, "a config whose directory is read-only must be .unwritable, got \(state)")
                return
            }
            expect(reason.contains(restrictedDirectory.path), "got \(reason)")
        }
    }

    // PanelConfigState.topContent（/codex review f54d335 P1#1）：`PanelView` 的 operationalPanel 顶部渲染
    // 与 applyFirstFocus 的开局焦点派生此前各 `switch panelModel.configState` 一遍、只靠 ViewWiringSuite
    // 文本绊线防漂移。抽出这个单一分类后，两边都读它——而它是 ClaudioGUICore 的纯映射，可被 import，于是
    // 映射本身由这里的真行为测试钉死（不再是视图文本探针）。渲染 / 焦点漂移从此在类型层不可能。
    suite("PanelConfigState.topContent: 单一分类——.operational→.events, .needsPack→.needsPack, .malformed/.unwritable→.configFailure，且 .malformed 与 .unwritable 折叠成同一张失败卡并原样带上 reason") {
        expect(
            PanelConfigState.operational(ClaudioConfig(selectedPack: "lofi")).topContent == .events,
            "`.operational` 必须映射成 `.events`（四行事件 + 主音量滑块，isOperational 据此为真），got"
                + " \(PanelConfigState.operational(ClaudioConfig(selectedPack: "lofi")).topContent)")
        expect(
            PanelConfigState.needsPack.topContent == .needsPack,
            "`.needsPack` 必须映射成 `.needsPack`（先选包空态），got \(PanelConfigState.needsPack.topContent)")
        expect(
            PanelConfigState.malformed(reason: "bad json").topContent == .configFailure(reason: "bad json"),
            "`.malformed` 必须映射成 `.configFailure` 并**原样**带上 reason —— 渲染 configFailureNotice(reason:) 与"
                + " 焦点 hasConfigFailureNotice 都读这个映射，got"
                + " \(PanelConfigState.malformed(reason: "bad json").topContent)")
        expect(
            PanelConfigState.unwritable(reason: "dir 0500").topContent == .configFailure(reason: "dir 0500"),
            "`.unwritable` 必须和 `.malformed` 一样折叠成 `.configFailure`（同一张失败卡、同一颗 Reveal 控件、"
                + "同一个 `.configReveal` 开局焦点），并原样带上 reason，got"
                + " \(PanelConfigState.unwritable(reason: "dir 0500").topContent)")
    }

    // PanelTopContent 的两颗投影（/codex review f54d335 P1#1 follow-up）：applyFirstFocus 把它们**原样转发**进
    // panelOpeningFocus（hasMasterVolume / hasConfigFailureNotice），不在视图里重新 pattern-match。返回值由这里
    // 钉死——对抗复核实测过：只让 render/focus 读同一个 topContent **值**不够，视图里若用未测闭包把值重解释成
    // Bool，翻个返回值就能让失败卡照画、焦点跳过 Reveal 钮，而整套测试全绿。投影上提到这里后返回值被单测钉，
    // 视图只剩一句转发（由 ViewWiringSuite 钉住转发原样还在），漂移堵在决策层。
    suite("PanelTopContent.showsEventContent / .hasConfigFailureNotice：两颗焦点投影的返回值——.events 独有 showsEventContent，.configFailure 独有 hasConfigFailureNotice，其余全 false") {
        expect(PanelTopContent.events.showsEventContent, "`.events` 必须 showsEventContent（= hasMasterVolume 真：滑块 + 四行事件在屏幕上）")
        expect(!PanelTopContent.needsPack.showsEventContent, "`.needsPack` 不得 showsEventContent —— 先选包空态没有滑块")
        expect(
            !PanelTopContent.configFailure(reason: "x").showsEventContent,
            "`.configFailure` 不得 showsEventContent —— 诚实失败态换掉了四行事件 + 滑块")
        expect(
            PanelTopContent.configFailure(reason: "x").hasConfigFailureNotice,
            "`.configFailure` 必须 hasConfigFailureNotice（= .configReveal 领序、开局焦点落在 Reveal 钮上）")
        expect(!PanelTopContent.events.hasConfigFailureNotice, "`.events` 不得 hasConfigFailureNotice")
        expect(!PanelTopContent.needsPack.hasConfigFailureNotice, "`.needsPack` 不得 hasConfigFailureNotice")
    }
}
