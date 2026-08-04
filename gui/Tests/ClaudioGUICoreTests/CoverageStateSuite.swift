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
        durationProbe: StubDurationProbe(fixedDuration: 1.0),
        // 见 ``injectedPacksLock(under:)``。⚠️ 这一行的**理由在 e278736 之后变了**，别照抄旧说法：
        // 那之前 `packsLockFile` 有一个指向真实 `~/.claudio/packs.lock` 的默认值，漏掉它是**静默**
        // 的（测试全绿，锁开在用户 home 上）；现在那个默认值已经拆掉，漏掉是**编译错误**。
        // 所以这一行今天防的不再是「忘记」，而是「递错」——递 `ClaudioPaths.packsLockFile` 依旧会去
        // 用户机器上开真锁，只是那一种是**响**的（写下这一行的人知道自己在写什么，且它出现在 diff 里）。
        packsLockFile: injectedPacksLock(besideUserPacks: userPacksDirectory)
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

    // MARK: - EventRow.eventActionOperable (PLAN-SOUND-MANAGER.md §2.5/T2). `.eventAction` is
    // now UNCONDITIONALLY the 试听 ▶ preview button in all three coverage states (the file-name
    // `Menu` that used to double as `.unmapped`/`.broken`'s action slot moved to its own focus
    // identity, ``PanelFocusTarget/eventSound(_:)``) — so this is simply
    // `coverage.previewEnabled && enabled`: operable ONLY for a `.present`, not-muted row.
    // `.unmapped`/`.broken` are non-operable UNCONDITIONALLY (their 试听 ▶ is permanently
    // disabled, mute or not — `CoverageState.previewEnabled` is `false` for both) — this is the
    // exact opposite of their PRE-T2 answer, which is why these four cases are rewritten rather
    // than deleted (PLAN-SOUND-MANAGER.md §2.5 acceptance: "CoverageStateSuite 8 条按新语义重写").

    suite("EventRow.eventActionOperable: .present + enabled is operable (the preview plays)") {
        let row = EventRow(event: .stop, coverage: .present(fileName: "stop.mp3"), enabled: true)
        expect(row.eventActionOperable, ".present not-muted must be operable")
    }

    suite("EventRow.eventActionOperable: .present + muted 仍可手工试听（静音只控制真实事件）") {
        let row = EventRow(event: .stop, coverage: .present(fileName: "stop.mp3"), enabled: false)
        expect(row.eventActionOperable, ".present muted must remain manually previewable")
    }

    suite("EventRow.eventActionOperable: .unmapped is NEVER operable, mute or not (试听 ▶ is permanently disabled — CoverageState.previewEnabled is false; ``PanelFocusTarget/eventSound(_:)`` is this row's actually-fixable, always-operable slot instead)") {
        expect(
            !EventRow(event: .notification, coverage: .unmapped, enabled: true).eventActionOperable,
            ".unmapped + enabled must still be non-operable — T2 removed the import affordance"
                + " that used to make this slot operable regardless of mute")
        expect(
            !EventRow(event: .notification, coverage: .unmapped, enabled: false).eventActionOperable,
            ".unmapped + muted must also be non-operable")
    }

    suite("EventRow.eventActionOperable: .broken is NEVER operable, mute or not (same reason as .unmapped)") {
        expect(
            !EventRow(event: .stopFailure, coverage: .broken(fileName: "x.mp3"), enabled: true)
                .eventActionOperable,
            ".broken + enabled must be non-operable")
        expect(
            !EventRow(event: .stopFailure, coverage: .broken(fileName: "x.mp3"), enabled: false)
                .eventActionOperable,
            ".broken + muted must also be non-operable")
    }

    // MARK: - `EventRow.previewClaimsActionFocus` 已删（PLAN-SOUND-MANAGER.md §2.5/T2）—— 它当年
    // 存在的唯一理由是仲裁「试听 ▶ 与导入入口，两者之中谁在这一行拥有 `.eventAction`」；T2 把导入入口
    // 整个搬进了 `PanelFocusTarget.eventSound(_:)`（文件名 `Menu` 自己的焦点身份），于是 `.eventAction`
    // 从此在三态下都只剩一个候选（试听 ▶ 自己），仲裁不再有意义。
    //
    // 这里**不留**一条「previewClaimsActionFocus 成员不存在」的 suite（/codex review dcab3de,7e97bc4
    // P2）：那种 suite 只能重复断言 `eventActionOperable`（上面四条已覆盖），对「`.eventAction` 到底接在
    // 谁身上」零分辨力 —— 而「成员真被删」这件事由**编译器**把关（任何引用都会编译失败），一条恒真
    // suite 只会制造「删除契约已被测试覆盖」的错觉。真正的替代不变量是「`.eventAction` 恰好一个 owner、
    // 且永远是试听 ▶」，那是控件树结构问题，钉在 `ViewWiringSuite` 的「三槽焦点身份各自恰好一个 owner」
    // 那条里（连同 `.eventSound` 归 fileNameMenu、`.eventMute` 归 muteIndicator、三槽顺序一并钉住）。

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

    suite("packCoverage: covers all five current events, exactly once each") {
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
