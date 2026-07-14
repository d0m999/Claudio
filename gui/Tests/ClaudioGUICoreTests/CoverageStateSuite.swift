import ClaudioCore
import ClaudioGUICore
import Foundation

// MARK: - CoverageState / EventRow / packCoverage (ENGINEERING.md T16 D2, DESIGN.md
// "事件行三态"): present/unmapped/broken per event, computed purely from the pack's
// manifest.json + on-disk file presence — this is the state gallery's (T14) and the real
// panel's (T15) shared render-ready fixture.

@MainActor
private func makeEnvironment(
    userPacksDirectory: URL,
    bundledPacksDirectory: URL? = nil
) -> AudioImportEnvironment {
    AudioImportEnvironment(
        userPacksDirectory: userPacksDirectory,
        bundledPacksDirectory: bundledPacksDirectory,
        durationProbe: StubDurationProbe(fixedDuration: 1.0)
    )
}

@MainActor
func runCoverageStateSuites() {
    // MARK: - previewEnabled / entersDoctor

    suite("CoverageState: previewEnabled is true ONLY for .present") {
        expect(
            CoverageState.present(fileName: "stop.mp3").previewEnabled,
            ".present must have previewEnabled == true")
        expect(!CoverageState.unmapped.previewEnabled, ".unmapped must have previewEnabled == false")
        expect(
            !CoverageState.broken(fileName: "stop.mp3").previewEnabled,
            ".broken must have previewEnabled == false")
    }

    suite("CoverageState: entersDoctor is true ONLY for .broken") {
        expect(
            !CoverageState.present(fileName: "stop.mp3").entersDoctor,
            ".present must have entersDoctor == false")
        expect(!CoverageState.unmapped.entersDoctor, ".unmapped must have entersDoctor == false")
        expect(
            CoverageState.broken(fileName: "stop.mp3").entersDoctor,
            ".broken must have entersDoctor == true")
    }

    // MARK: - EventRow.eventActionOperable (a11y-architect FIX 4 first-focus: the pure decision
    // PanelView.nonOperableActionEvents inverts, feeding panelFirstFocusTarget). Non-operable
    // ONLY for a .present-AND-muted row (its 试听 ▶ is the disabled .eventAction owner);
    // unmapped/broken keep an operable action slot (the always-enabled import affordance).

    suite("EventRow.eventActionOperable: .present + enabled is operable (the preview plays)") {
        let row = EventRow(event: .stop, coverage: .present(fileName: "stop.mp3"), enabled: true)
        expect(row.eventActionOperable, ".present not-muted must be operable")
    }

    suite("EventRow.eventActionOperable: .present + muted is the ONLY non-operable case (disabled 试听 ▶ owns .eventAction)") {
        let row = EventRow(event: .stop, coverage: .present(fileName: "stop.mp3"), enabled: false)
        expect(!row.eventActionOperable, ".present muted must be non-operable — this is the whole bug the resolver fixes")
    }

    suite("EventRow.eventActionOperable: .unmapped is operable regardless of mute (import affordance owns .eventAction, always enabled)") {
        expect(
            EventRow(event: .notification, coverage: .unmapped, enabled: true).eventActionOperable,
            ".unmapped + enabled must be operable")
        expect(
            EventRow(event: .notification, coverage: .unmapped, enabled: false).eventActionOperable,
            ".unmapped + muted must STILL be operable — muting doesn't disable the import affordance")
    }

    suite("EventRow.eventActionOperable: .broken is operable regardless of mute (import affordance owns .eventAction, always enabled)") {
        expect(
            EventRow(event: .stopFailure, coverage: .broken(fileName: "x.mp3"), enabled: true).eventActionOperable,
            ".broken + enabled must be operable")
        expect(
            EventRow(event: .stopFailure, coverage: .broken(fileName: "x.mp3"), enabled: false).eventActionOperable,
            ".broken + muted must STILL be operable — the import affordance is the action slot, not the disabled preview")
    }

    // MARK: - EventRow.previewClaimsActionFocus (T16 review 修复⑥: the OTHER half of the
    // a11y-architect FIX 4 dedup — WHO owns the row's `.eventAction` focus identity, as opposed
    // to `eventActionOperable`'s "can that slot be used right now"). It lived as three
    // hand-written `claimsActionFocus: true/false/false` literals inside `EventRowView`'s
    // coverage `switch`, where nothing constrained them: flipping one so that BOTH the disabled
    // preview and the import affordance bind `.eventAction` (undefined SwiftUI focus resolution,
    // and opening focus lands on the dead preview) broke no test whatsoever. Now a pure function,
    // pinned here.

    suite("EventRow.previewClaimsActionFocus: .present is the ONLY state where the preview button owns .eventAction") {
        expect(
            EventRow(event: .stop, coverage: .present(fileName: "stop.mp3"), enabled: true)
                .previewClaimsActionFocus,
            ".present + enabled: the preview button is the row's sole action control")
        expect(
            EventRow(event: .stop, coverage: .present(fileName: "stop.mp3"), enabled: false)
                .previewClaimsActionFocus,
            ".present + MUTED must still claim it: the disabled 试听 ▶ is still the row's action"
                + " slot (that it's disabled is eventActionOperable's separate question — the two"
                + " axes must not be collapsed)")
    }

    suite("EventRow.previewClaimsActionFocus: .unmapped/.broken preview must NOT claim .eventAction (the import affordance owns it — one row, one owner)") {
        for enabled in [true, false] {
            expect(
                !EventRow(event: .notification, coverage: .unmapped, enabled: enabled)
                    .previewClaimsActionFocus,
                ".unmapped (enabled: \(enabled)): the co-rendered disabled preview must not ALSO"
                    + " bind .eventAction — two simultaneous .focused(_:equals:) on one value make"
                    + " SwiftUI's focus resolution undefined, and opening focus would land on the"
                    + " dead preview instead of the operable import affordance")
            expect(
                !EventRow(
                    event: .subagentStop, coverage: .broken(fileName: "x.mp3"), enabled: enabled
                ).previewClaimsActionFocus,
                ".broken (enabled: \(enabled)): same — the import affordance is the action slot")
        }
    }

    suite("EventRow.previewClaimsActionFocus vs eventActionOperable: a muted .present row CLAIMS the slot yet is NOT operable (the two axes are independent)") {
        let mutedPresent = EventRow(
            event: .stop, coverage: .present(fileName: "stop.mp3"), enabled: false)
        expect(
            mutedPresent.previewClaimsActionFocus && !mutedPresent.eventActionOperable,
            "this exact combination is what makes opening focus skip to the mute toggle; if either"
                + " axis were derived from the other, the skip would be impossible to express")
        let mutedUnmapped = EventRow(event: .stop, coverage: .unmapped, enabled: false)
        expect(
            !mutedUnmapped.previewClaimsActionFocus && mutedUnmapped.eventActionOperable,
            "and .unmapped inverts BOTH answers — no accidental coupling")
    }

    // MARK: - packCoverage: per-event present/unmapped/broken

    suite("packCoverage: an event absent from the manifest reports .unmapped") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": { "stop": "stop.mp3" } }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))

            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            let notification = rows.first { $0.event == .notification }
            expect(
                notification?.coverage == .unmapped,
                "notification has no manifest entry → .unmapped, got \(String(describing: notification?.coverage))"
            )
        }
    }

    suite("packCoverage: an event mapped to an existing, contained file reports .present") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": { "stop": "stop.mp3" } }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))

            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            let stop = rows.first { $0.event == .stop }
            expect(
                stop?.coverage == .present(fileName: "stop.mp3"),
                "stop is mapped and the file exists → .present, got \(String(describing: stop?.coverage))"
            )
        }
    }

    suite("packCoverage: an event mapped to a file that doesn't exist on disk reports .broken") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": { "stop_failure": "fail.mp3" } }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            // `fail.mp3` is declared but never actually written to disk.

            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            let stopFailure = rows.first { $0.event == .stopFailure }
            expect(
                stopFailure?.coverage == .broken(fileName: "fail.mp3"),
                "stop_failure is mapped but the file is missing → .broken, got \(String(describing: stopFailure?.coverage))"
            )
        }
    }

    suite(
        "packCoverage: an event mapped to a file resolving outside the pack dir (symlink escape) reports .broken, never .present"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": { "notification": "ping.mp3" } }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            let outside = root.appendingPathComponent("outside-secret", isDirectory: true)
            try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let outsideFile = outside.appendingPathComponent("real.mp3")
            writeFixture("fake-audio", to: outsideFile)
            createSymlink(
                at: userPacks.appendingPathComponent("my-pack/ping.mp3"), pointingTo: outsideFile)

            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            let notification = rows.first { $0.event == .notification }
            expect(
                notification?.coverage == .broken(fileName: "ping.mp3"),
                "a containment-failing (symlink-escaping) mapped file must report .broken, never"
                    + " .present, got \(String(describing: notification?.coverage))")
        }
    }

    suite(
        "packCoverage: an event mapped to a filename that is an IN-PACK symlink whose target resolves INSIDE the pack dir reports .present"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": { "stop": "stop-link.mp3" } }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            // The symlink's target is a REAL file, but crucially still INSIDE the pack
            // directory — unlike the escaping-symlink case above, this must satisfy
            // `isReallyContained` and report .present, not .broken.
            //
            // 这条同时是**正规文件闸门的误伤护栏**（见下面那两条 .broken 用例）：`coverageState` 现在用
            // ``regularFileExists(at:)``，而它刻意 `stat` 而非 `lstat` —— 符号链接**跟随**。一个「顺手」
            // 把它改成 `lstat`（或改回一个只认真实文件的实现）的人，会在这里变红：包内指向包内真实文件
            // 的符号链接是**合法**用法（helper 的 `PackContentSafetySuite` 也为 doctor 钉了同一条）。
            let realFile = userPacks.appendingPathComponent("my-pack/real-stop.mp3")
            writeFixture("fake-audio", to: realFile)
            createSymlink(
                at: userPacks.appendingPathComponent("my-pack/stop-link.mp3"), pointingTo: realFile)

            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            let stop = rows.first { $0.event == .stop }
            expect(
                stop?.coverage == .present(fileName: "stop-link.mp3"),
                "an in-pack symlink resolving to a real file still inside the pack dir must"
                    + " report .present, got \(String(describing: stop?.coverage))")
        }
    }

    // MARK: - 正规文件闸门：`.present` 要求路径上躺着一个**正规文件**，不是「路径上有东西」
    //
    // 这两条和 helper 的 `PackContentSafetySuite`（`checkPackIntegrity` / `playSoundEvent` 的同名用例）
    // 是**同一个谓词的两端**。GUI 侧曾经用 `FileManager.fileExists(atPath:)`，它对目录 / FIFO / socket /
    // 设备一律回答 `true`，而 helper 早已改用 ``regularFileExists(at:)``（`stat(2)` + `S_IFREG`）。
    // 两边于是互相打架：一个名叫 `stop.mp3` 的**目录**，面板显示 `.present`（文件名照常、试听键可点），
    // `doctor` 却说它缺失、`play` 拒播。用户得到的是一个「配好了却不响、而且 doctor 骂你」的包。
    // 现在同一个谓词、同一个答案：`.broken`（试听灰掉、进 doctor），面板和 CLI 说的是同一句话。

    suite("packCoverage: 一个名叫 stop.mp3 的**目录** → .broken，绝不是 .present（与 helper 的正规文件闸门对齐）") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": { "stop": "stop.mp3" } }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            // 注意这个目录**存在**、路径**在包内**、containment 检查也**通过**——挡住它的只能是
            // 「它不是正规文件」这一条。`fileExists(atPath:)` 会说它在。
            try? FileManager.default.createDirectory(
                at: userPacks.appendingPathComponent("my-pack/stop.mp3"),
                withIntermediateDirectories: true)

            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            let stop = rows.first { $0.event == .stop }
            expect(
                stop?.coverage == .broken(fileName: "stop.mp3"),
                "一个目录不是音频文件 —— 必须 .broken（试听灰掉、进 doctor），否则面板会说「配好了」而"
                    + " doctor/play 说「没有」，got \(String(describing: stop?.coverage))")
            expect(
                stop?.coverage.previewEnabled == false,
                "而且它的试听键必须是灰的 —— 一个能点的试听键会 spawn 一次注定无声的播放")
        }
    }

    suite("packCoverage: 一个名叫 stop.mp3 的 FIFO → .broken（`fileExists` 会说它在；`stat`+S_IFREG 不会）") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": { "stop": "stop.mp3" } }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            // FIFO 是那条「`fileExists(atPath:isDirectory:)` 也救不了你」的用例：它连目录都不是，
            // 只有 `S_IFMT == S_IFREG` 这个判断能挡住它（helper 的 doctor/play 钉的是同一个 fixture）。
            makePackFIFO(at: userPacks.appendingPathComponent("my-pack/stop.mp3"))

            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            expect(
                rows.first { $0.event == .stop }?.coverage == .broken(fileName: "stop.mp3"),
                "FIFO 不是音频文件 —— 必须 .broken，got"
                    + " \(String(describing: rows.first { $0.event == .stop }?.coverage))")
        }
    }

    suite("packCoverage: covers all four v1 events, exactly once each") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": {} }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))

            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            expect(rows.count == Event.allCases.count, "packCoverage must return exactly one row per event")
            expect(
                Set(rows.map(\.event)) == Set(Event.allCases),
                "packCoverage must cover every Event.allCases entry exactly once")
        }
    }

    // MARK: - Pack/manifest resolution failure → every event .unmapped

    suite("packCoverage: an unresolvable packID reports every event as .unmapped") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let rows = packCoverage(
                packID: "ghost-pack", config: ClaudioConfig(selectedPack: "ghost-pack"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            expect(
                rows.allSatisfy { $0.coverage == .unmapped },
                "an unresolvable pack must report every event .unmapped, got \(rows)")
        }
    }

    // A real, live shape, not a hypothetical (D23): `PanelConfigState.resolvedConfig` hands back
    // `ClaudioConfig(selectedPack: "")` for every state EXCEPT `.operational` — `.needsPack`
    // (nobody has chosen a pack yet) chief among them — and `PanelView` feeds that empty id
    // straight into `packCoverage` so its read models never crash while the panel is still
    // showing its "先选包" empty state. `isSafePackID("")` is false → `resolvePackDirectory`
    // returns nil → every event must read `.unmapped` rather than trapping on an empty path
    // component.
    suite("packCoverage: an EMPTY packID (PanelConfigState.resolvedConfig's non-operational default) reports every event .unmapped, never crashes") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": { "stop": "stop.mp3" } }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))

            let rows = packCoverage(
                packID: "", config: ClaudioConfig(selectedPack: ""),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            expect(rows.count == Event.allCases.count, "even an empty packID must return one row per event")
            expect(
                rows.allSatisfy { $0.coverage == .unmapped },
                "an empty packID must report every event .unmapped (never resolve to the packs root"
                    + " itself, never crash), got \(rows)")
        }
    }

    suite("packCoverage: a bundled-only pack (no user copy) resolves its coverage from the bundled root") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let bundledPacks = root.appendingPathComponent("bundled")
            writeFixture(
                #"{ "id": "builtin-only", "events": { "stop": "stop.mp3" } }"#,
                to: bundledPacks.appendingPathComponent("builtin-only/manifest.json"))
            writeFixture("fake-audio", to: bundledPacks.appendingPathComponent("builtin-only/stop.mp3"))

            let rows = packCoverage(
                packID: "builtin-only", config: ClaudioConfig(selectedPack: "builtin-only"),
                environment: makeEnvironment(
                    userPacksDirectory: userPacks, bundledPacksDirectory: bundledPacks))

            expect(
                rows.first { $0.event == .stop }?.coverage == .present(fileName: "stop.mp3"),
                "a pack living only in the bundled root must still resolve .present via"
                    + " resolvePackDirectory's second lookup, got"
                    + " \(String(describing: rows.first { $0.event == .stop }?.coverage))")
            expect(
                rows.first { $0.event == .notification }?.coverage == .unmapped,
                "its unmapped events still read .unmapped")
        }
    }

    suite("packCoverage: a corrupt manifest.json reports every event as .unmapped, never crashes") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                "{ not valid json", to: userPacks.appendingPathComponent("my-pack/manifest.json"))

            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            expect(
                rows.allSatisfy { $0.coverage == .unmapped },
                "a corrupt manifest must report every event .unmapped, got \(rows)")
        }
    }

    // MARK: - enabled orthogonality (决议③): does NOT change coverage

    suite("packCoverage: enabled=false does not change the computed CoverageState (orthogonal axes)")
    {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": { "stop": "stop.mp3" } }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))

            let mutedConfig = ClaudioConfig(
                selectedPack: "my-pack", eventsEnabled: ["stop": false])
            let rows = packCoverage(
                packID: "my-pack", config: mutedConfig,
                environment: makeEnvironment(userPacksDirectory: userPacks))

            let stop = rows.first { $0.event == .stop }
            expect(
                stop?.coverage == .present(fileName: "stop.mp3"),
                "muting an event must not change its CoverageState — still .present, got"
                    + " \(String(describing: stop?.coverage))")
            expect(stop?.enabled == false, "the row must still reflect enabled == false")
        }
    }

    suite("packCoverage: an event absent from config.events defaults to enabled (opt-out design)") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": { "stop": "stop.mp3" } }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))

            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            expect(
                rows.allSatisfy(\.enabled),
                "every row must default to enabled == true when config.events doesn't mention it")
        }
    }

    // MARK: - checkPackIntegrity (helper doctor path): a broken (mapped-but-missing) file
    // is surfaced as a pack defect, matching CoverageState.broken's entersDoctor == true.

    suite(
        "checkPackIntegrity: a mapped-but-missing file (the same shape CoverageState calls .broken) is reported by doctor as .incomplete"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDir = root.appendingPathComponent("packs")
            writeFixture(#"{ "selected_pack": "my-pack" }"#, to: configFile)
            writeFixture(
                #"{ "id": "my-pack", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("my-pack/manifest.json"))
            // `stop.mp3` is declared but never written — the exact fixture shape the
            // `packCoverage` suite above pins as `CoverageState.broken`.

            let status = checkPackIntegrity(
                configFile: configFile, userPacksDirectory: packsDir, bundledPacksDirectory: nil)
            expect(
                status == .incomplete(packID: "my-pack", missingFiles: ["stop.mp3"]),
                "a broken (mapped-but-missing) event file must surface via doctor's pack check,"
                    + " got \(status)")
        }
    }
}
