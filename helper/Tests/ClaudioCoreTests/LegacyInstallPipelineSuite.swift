import ClaudioCore
import Foundation

@MainActor
func runLegacyInstallPipelineSuites() {
    suite("legacy install preflight refuses missing config and an all-silent pack") {
        withTempDirectory { root in
            let config = root.appendingPathComponent("config.json")
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            expect(
                legacyInstallPipelineReport(configFile: config, userPacksDirectory: packs)
                    == .failure(.configMissing(path: config.path)),
                "missing config must block legacy hooks")

            writeFixture(#"{ "selected_pack": "silent" }"#, to: config)
            writeFixture(
                #"{ "id": "silent", "events": { "stop": "empty.mp3" } }"#,
                to: packs.appendingPathComponent("silent/manifest.json"))
            writeFixture("", to: packs.appendingPathComponent("silent/empty.mp3"))
            expect(
                legacyInstallPipelineReport(configFile: config, userPacksDirectory: packs)
                    == .failure(.noPlayableEvents(packID: "silent")),
                "zero-byte-only pack must block legacy hooks")
        }
    }

    suite("legacy install preflight allows partial playback and reports every missing mapping") {
        withTempDirectory { root in
            let config = root.appendingPathComponent("config.json")
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            writeFixture(#"{ "selected_pack": "partial" }"#, to: config)
            writeFixture(
                #"{ "id": "partial", "events": { "stop": "stop.mp3", "notification": "missing.mp3" } }"#,
                to: packs.appendingPathComponent("partial/manifest.json"))
            writeFixture("sound", to: packs.appendingPathComponent("partial/stop.mp3"))

            guard case .success(let report) = legacyInstallPipelineReport(
                configFile: config, userPacksDirectory: packs)
            else {
                expect(false, "one playable mapping must allow install")
                return
            }
            expect(report.playableEvents == [.stop], "only the real non-empty file is playable")
            expect(report.warnings.count == Event.allCases.count - 1, "partial gaps must all be explicit")
            expect(
                legacyInstallWarningMessages(report.warnings).count == report.warnings.count,
                "every semantic warning must have a CLI line")
        }
    }

    suite("legacy install preflight follows play's lenient optional-config decoding") {
        withTempDirectory { root in
            let config = root.appendingPathComponent("config.json")
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            writeFixture(
                #"{ "selected_pack": "usable", "master_volume": "wrong", "events": [] }"#,
                to: config)
            writeFixture(
                #"{ "id": "usable", "events": { "stop": "stop.mp3" } }"#,
                to: packs.appendingPathComponent("usable/manifest.json"))
            writeFixture("sound", to: packs.appendingPathComponent("usable/stop.mp3"))

            guard case .success(let report) = legacyInstallPipelineReport(
                configFile: config, userPacksDirectory: packs)
            else {
                expect(false, "可播放包不得被仅写配置才关心的可选字段类型拒绝")
                return
            }
            expect(report.packID == "usable" && report.playableEvents == [.stop], "预检必须保留播放路径的选择与事件")
        }
    }
}
