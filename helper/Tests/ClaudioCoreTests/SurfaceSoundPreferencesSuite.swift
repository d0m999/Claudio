import ClaudioCore
import Foundation

@MainActor
func runSurfaceSoundPreferencesSuites() {
    suite("retired Surface sounds: overrides never affect automatic defaults") {
        for overrides in [
            #"{"codex":{"selected_pack":"old","events":{"stop":false}}}"#, #"{"codex":null}"#,
            "false",
        ] {
            let data = Data(
                "{\"selected_pack\":\"default\",\"master_volume\":0.42,\"surface_overrides\":\(overrides)}"
                    .utf8)
            let config = try! JSONDecoder().decode(ClaudioConfig.self, from: data)
            for surface in HostSurfaceID.allCases {
                guard case .success(let profile) = config.resolveSoundProfile(for: surface) else {
                    expect(false, "old overrides must be ignored"); continue
                }
                expect(
                    profile.selectedPack == "default" && profile.isEnabled(.stop)
                        && profile.volume == 0.42, "whole Default Group applies immediately")
            }
        }
    }
    suite("retired Surface writes fail explicitly without changing bytes") {
        withTempDirectory { root in
            let file = root.appendingPathComponent("config.json")
            let lock = root.appendingPathComponent("config.lock")
            let original =
                #"{"selected_pack":"default","surface_overrides":{"codex":{"selected_pack":"old"}},"future":true}"#
            writeFixture(original, to: file)
            if case .success = setSurfacePack(
                "old", surface: .codex, configFile: file, lockFile: lock)
            {
                expect(false, "pack writes retired")
            }
            if case .success = setSurfaceEventEnabled(
                .stop, enabled: false, surface: .codex, configFile: file, lockFile: lock)
            {
                expect(false, "event writes retired")
            }
            if case .success = resetSurfaceSoundOverride(
                surface: .codex, configFile: file, lockFile: lock)
            {
                expect(false, "reset retired")
            }
            expect(
                (try! String(contentsOf: file, encoding: .utf8)) == original,
                "old settings and unknown fields preserved verbatim")
        }
    }
}
