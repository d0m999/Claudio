import ClaudioCore
import ClaudioGUICore
import Foundation

// MARK: - loadPanelConfig (ENGINEERING.md T15 D1 panel glue): never crashes the panel over
// a missing/corrupt config.json.

@MainActor
func runPanelConfigSuites() {
    suite("loadPanelConfig: a missing config.json falls back to an empty-pack default") {
        withTempDirectory { root in
            let config = loadPanelConfig(from: root.appendingPathComponent("config.json"))
            expect(config.selectedPack == "", "a missing file must fall back to an empty selectedPack")
            expect(
                config.masterVolume == ClaudioConfig.defaultMasterVolume,
                "a missing file must fall back to the documented default master_volume")
        }
    }

    suite("loadPanelConfig: a corrupt config.json falls back to the same default, never crashes") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture("{ not valid json", to: configFile)
            let config = loadPanelConfig(from: configFile)
            expect(config.selectedPack == "", "a corrupt file must fall back to an empty selectedPack")
        }
    }

    suite("loadPanelConfig: a well-formed config.json decodes exactly") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(
                #"{ "selected_pack": "minimal-chime", "master_volume": 0.42, "events": { "stop": false } }"#,
                to: configFile)
            let config = loadPanelConfig(from: configFile)
            expect(config.selectedPack == "minimal-chime", "got \(config.selectedPack)")
            expect(config.masterVolume == 0.42, "got \(config.masterVolume)")
            expect(config.isEnabled(.stop) == false, "got \(config.isEnabled(.stop))")
        }
    }
}
