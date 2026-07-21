import ClaudioCore
import ClaudioGUICore
import Foundation

// MARK: - availablePacks / PackCard / PackCardState (ENGINEERING.md T15 D3: pack switching
// gallery model). Mirrors `CoverageStateSuite.swift`'s fixture style.

@MainActor
private func makeEnvironment(
    userPacksDirectory: URL,
    bundledPacksDirectory: URL? = nil
) -> AudioImportEnvironment {
    AudioImportEnvironment(
        userPacksDirectory: userPacksDirectory,
        bundledPacksDirectory: bundledPacksDirectory,
        durationProbe: StubDurationProbe(fixedDuration: 1.0),
        // 见 ``injectedPacksLock(under:)``：漏掉 ⇒ 静默落回用户真实 `~/.claudio/packs.lock`。
        packsLockFile: injectedPacksLock(besideUserPacks: userPacksDirectory)
    )
}

@MainActor
private func writeCompletePack(named id: String, at userPacks: URL, name: String = "测试包", license: String = "CC0-1.0") {
    writeFixture(
        #"""
        { "id": "\#(id)", "name": "\#(name)", "license": "\#(license)", "events": {
            "stop": "stop.mp3", "stop_failure": "fail.mp3", "notification": "ping.mp3",
            "subagent_stop": "sub.mp3" } }
        """#,
        to: userPacks.appendingPathComponent("\(id)/manifest.json"))
    for file in ["stop.mp3", "fail.mp3", "ping.mp3", "sub.mp3"] {
        writeFixture("fake-audio", to: userPacks.appendingPathComponent("\(id)/\(file)"))
    }
}

@MainActor
func runPackGallerySuites() {
    suite("availablePacks: a complete pack (every declared file present) reports .complete") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeCompletePack(named: "minimal-chime", at: userPacks)

            let cards = availablePacks(
                config: ClaudioConfig(selectedPack: "minimal-chime"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            expect(cards.count == 1, "expected exactly one card, got \(cards.count)")
            expect(cards.first?.state == .complete, "got \(String(describing: cards.first?.state))")
            expect(cards.first?.name == "测试包", "the card's name must come from manifest.json's raw name field")
            expect(cards.first?.isCC0 == true, "license CC0-1.0 must set isCC0 == true")
            expect(
                cards.first?.presentEvents == Set(Event.allCases),
                "every declared+present event must appear in presentEvents")
            expect(cards.first?.isSelected == true, "the card matching config.selectedPack must be isSelected")
        }
    }

    suite("availablePacks: a pack missing 1-2 declared files reports .partial with the right count") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"""
                { "id": "half-pack", "name": "半成品", "events": {
                    "stop": "stop.mp3", "stop_failure": "fail.mp3",
                    "notification": "ping.mp3", "subagent_stop": "sub.mp3" } }
                """#,
                to: userPacks.appendingPathComponent("half-pack/manifest.json"))
            // Only two of the four declared files actually exist on disk.
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("half-pack/stop.mp3"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("half-pack/ping.mp3"))

            let cards = availablePacks(
                config: ClaudioConfig(selectedPack: "minimal-chime"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            expect(cards.count == 1, "expected exactly one card, got \(cards.count)")
            expect(
                cards.first?.state == .partial(present: 2, total: 4),
                "2 of 4 declared files present must report .partial(present: 2, total: 4), got"
                    + " \(String(describing: cards.first?.state))")
            expect(
                cards.first?.presentEvents == [.stop, .notification],
                "presentEvents must list exactly the two events whose files really exist, got"
                    + " \(String(describing: cards.first?.presentEvents))")
            expect(cards.first?.isSelected == false, "a non-selected pack must report isSelected == false")
        }
    }

    // Regression net for the T16 fix: a pack that BOTH leaves some events unmapped AND has a
    // declared-but-missing file. Before the fix, `.partial(present:)` was `4 - (declared files
    // missing)`, counted over declared keys, so it disagreed with `presentEvents` (counted over
    // all four v1 events) — the badge said "3/4" while the grid lit 1 glyph and VoiceOver named
    // 3 missing. `present` must now equal `presentEvents.count`, so badge, grid, and label are
    // one source of truth. (Under the old formula this asserted 3; it now asserts 1.)
    suite("availablePacks: an unmapped event + a declared-but-missing file — present == presentEvents.count") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            // Only stop + stop_failure declared (notification/subagent_stop UNMAPPED); of the
            // two declared, only stop.mp3 exists — fail.mp3 is declared but never written.
            writeFixture(
                #"""
                { "id": "mixed-pack", "name": "混合包", "events": {
                    "stop": "stop.mp3", "stop_failure": "fail.mp3" } }
                """#,
                to: userPacks.appendingPathComponent("mixed-pack/manifest.json"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("mixed-pack/stop.mp3"))

            let cards = availablePacks(
                config: ClaudioConfig(selectedPack: "minimal-chime"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            expect(cards.count == 1, "expected exactly one card, got \(cards.count)")
            expect(
                cards.first?.presentEvents == [.stop],
                "only stop truly resolves .present (stop_failure broken, the other two unmapped), got"
                    + " \(String(describing: cards.first?.presentEvents))")
            expect(
                cards.first?.state == .partial(present: 1, total: 4),
                "present must equal presentEvents.count (1), NOT 4 − declared-missing (which was 3),"
                    + " so badge/grid/label agree — got \(String(describing: cards.first?.state))")
        }
    }

    // Regression net: `manifest.events` is an unconstrained `[String: String]`, so a
    // forward-compat manifest can carry event keys beyond the four v1 events. Extra keys
    // pointing at missing files must NOT inflate the missing count (which once drove
    // `present = 4 − missingCount` negative, e.g. "-1/4"). Counting present v1 events instead
    // keeps `present` in `0...4` regardless of how many extra broken keys a manifest declares.
    suite("availablePacks: extra forward-compat event keys with missing files never push present below 0") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            // stop present; five extra non-v1 keys all point at files that don't exist.
            writeFixture(
                #"""
                { "id": "future-pack", "name": "未来包", "events": {
                    "stop": "stop.mp3", "v2_a": "a.mp3", "v2_b": "b.mp3", "v2_c": "c.mp3",
                    "v2_d": "d.mp3", "v2_e": "e.mp3" } }
                """#,
                to: userPacks.appendingPathComponent("future-pack/manifest.json"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("future-pack/stop.mp3"))

            let cards = availablePacks(
                config: ClaudioConfig(selectedPack: "minimal-chime"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            expect(
                cards.first?.state == .partial(present: 1, total: 4),
                "only the one present v1 event counts; five extra missing keys must not drive"
                    + " present negative — got \(String(describing: cards.first?.state))")
        }
    }

    suite("availablePacks: a pack with a corrupt manifest.json reports .broken") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture("{ not valid json", to: userPacks.appendingPathComponent("evil-pack/manifest.json"))

            let cards = availablePacks(
                config: ClaudioConfig(selectedPack: "minimal-chime"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            expect(cards.count == 1, "expected exactly one card, got \(cards.count)")
            guard case .broken = cards.first?.state else {
                expect(false, "a corrupt manifest must report .broken, got \(String(describing: cards.first?.state))")
                return
            }
            expect(cards.first?.name == nil, "a broken card must not surface a name")
            expect(cards.first?.presentEvents.isEmpty == true, "a broken card must have no present events")
        }
    }

    // Distinct from the corrupt-manifest suite above: that one exercises `loadPackManifest`'s
    // `.decodeFailed`; a pack directory with NO manifest.json at all exercises `.unreadable`.
    // Both must land on `.broken`, but via different reasons — and a directory with no manifest
    // is the shape a killed/partial import or a hand-made pack folder really leaves behind.
    suite("availablePacks: a pack directory with NO manifest.json at all reports .broken") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            // A pack directory holding only an audio file — no manifest.json.
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("orphan-pack/stop.mp3"))

            let cards = availablePacks(
                config: ClaudioConfig(selectedPack: "minimal-chime"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            expect(cards.count == 1, "the directory must still be LISTED as a pack, got \(cards.count)")
            guard case .broken(let reason) = cards.first?.state else {
                expect(
                    false,
                    "a manifest-less pack directory must report .broken, got"
                        + " \(String(describing: cards.first?.state))")
                return
            }
            expect(
                reason.contains("不存在或不可读"),
                "the reason must be the unreadable-manifest one (not a decode failure), got \(reason)")
            expect(cards.first?.presentEvents.isEmpty == true, "a broken card must light no glyphs")
        }
    }

    suite("availablePacks: a manifest with no `name` field falls back to nil (the view renders the id)") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            // A perfectly valid, COMPLETE pack that simply omits the optional `name` key —
            // `PackCardView` renders `card.name ?? card.id`, so `name == nil` is a supported
            // shape, not a defect: it must NOT make the card `.broken`.
            writeFixture(
                #"""
                { "id": "nameless-pack", "license": "CC0-1.0", "events": {
                    "stop": "stop.mp3", "stop_failure": "fail.mp3",
                    "notification": "ping.mp3", "subagent_stop": "sub.mp3" } }
                """#,
                to: userPacks.appendingPathComponent("nameless-pack/manifest.json"))
            for file in ["stop.mp3", "fail.mp3", "ping.mp3", "sub.mp3"] {
                writeFixture("fake-audio", to: userPacks.appendingPathComponent("nameless-pack/\(file)"))
            }

            let cards = availablePacks(
                config: ClaudioConfig(selectedPack: "nameless-pack"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            expect(cards.first?.name == nil, "an absent `name` key must read as nil, got \(String(describing: cards.first?.name))")
            expect(
                cards.first?.state == .complete,
                "a missing OPTIONAL name must never downgrade a complete pack, got"
                    + " \(String(describing: cards.first?.state))")
            expect(cards.first?.isCC0 == true, "the license must still be read")
        }
    }

    suite("availablePacks: a manifest declaring ZERO events reports .partial(present: 0, total: 4), never .complete") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "silent-pack", "name": "全静默", "events": {} }"#,
                to: userPacks.appendingPathComponent("silent-pack/manifest.json"))

            let cards = availablePacks(
                config: ClaudioConfig(selectedPack: "silent-pack"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            expect(
                cards.first?.state == .partial(present: 0, total: 4),
                "a readable manifest that maps nothing is a legal, fully-silent pack — .partial"
                    + " with a zero count, never .complete and never .broken, got"
                    + " \(String(describing: cards.first?.state))")
            expect(cards.first?.presentEvents.isEmpty == true, "no event may light up")
        }
    }

    suite("availablePacks: a stray regular FILE in the packs root is never listed as a pack") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeCompletePack(named: "real-pack", at: userPacks)
            // A non-dot-prefixed regular file sitting in the packs root (a stray README, a
            // downloaded archive) — `packDirectoryIDs`'s isDirectory check must exclude it, or
            // the gallery would render a phantom `.broken` card for it.
            writeFixture("i am not a pack", to: userPacks.appendingPathComponent("README.md"))

            let cards = availablePacks(
                config: ClaudioConfig(selectedPack: "real-pack"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            expect(
                cards.map(\.id) == ["real-pack"],
                "only real subdirectories may be listed as packs, got \(cards.map(\.id))")
        }
    }

    suite("availablePacks: a user pack shadows a same-id bundled pack (user wins), only one card") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let bundledPacks = root.appendingPathComponent("bundled-packs")
            writeCompletePack(named: "minimal-chime", at: userPacks, name: "用户版")
            // The bundled copy is deliberately BROKEN (missing files) — if the user copy
            // didn't win, the card would report .partial/.broken instead of .complete.
            writeFixture(
                #"{ "id": "minimal-chime", "name": "内置版", "events": { "stop": "stop.mp3" } }"#,
                to: bundledPacks.appendingPathComponent("minimal-chime/manifest.json"))

            let cards = availablePacks(
                config: ClaudioConfig(selectedPack: "minimal-chime"),
                environment: makeEnvironment(
                    userPacksDirectory: userPacks, bundledPacksDirectory: bundledPacks))

            expect(cards.count == 1, "a same-id pack in both roots must dedup to exactly one card, got \(cards.count)")
            expect(cards.first?.name == "用户版", "the user pack's data must win over the bundled one")
            expect(cards.first?.state == .complete, "the user copy (complete) must be what's reported")
        }
    }

    suite("availablePacks: a bundled-only pack (no user copy) still appears") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let bundledPacks = root.appendingPathComponent("bundled-packs")
            writeCompletePack(named: "builtin-only", at: bundledPacks, name: "纯内置")

            let cards = availablePacks(
                config: ClaudioConfig(selectedPack: "minimal-chime"),
                environment: makeEnvironment(
                    userPacksDirectory: userPacks, bundledPacksDirectory: bundledPacks))

            expect(cards.count == 1, "a bundled-only pack must still appear, got \(cards.count)")
            expect(cards.first?.id == "builtin-only", "got \(String(describing: cards.first?.id))")
            expect(cards.first?.name == "纯内置", "got \(String(describing: cards.first?.name))")
        }
    }

    suite("availablePacks: a non-CC0 license does not set isCC0") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeCompletePack(named: "proprietary-pack", at: userPacks, license: "MIT")

            let cards = availablePacks(
                config: ClaudioConfig(selectedPack: "minimal-chime"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            expect(cards.first?.isCC0 == false, "a non-CC0-1.0 license must not set isCC0")
        }
    }

    suite("availablePacks: cards are sorted by id, and a dot-prefixed scratch dir is excluded") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeCompletePack(named: "zeta-pack", at: userPacks)
            writeCompletePack(named: "alpha-pack", at: userPacks)
            // A killed import/setup can leave a `.<id>.tmp-<pid>` scratch dir behind.
            writeFixture(
                #"{ "id": "alpha-pack", "events": {} }"#,
                to: userPacks.appendingPathComponent(".alpha-pack.tmp-123/manifest.json"))

            let cards = availablePacks(
                config: ClaudioConfig(selectedPack: "minimal-chime"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            expect(
                cards.map(\.id) == ["alpha-pack", "zeta-pack"],
                "cards must be sorted by id and exclude dot-prefixed scratch dirs, got \(cards.map(\.id))")
        }
    }

    suite("availablePacks: an empty pack root reports no cards, never crashes") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let cards = availablePacks(
                config: ClaudioConfig(selectedPack: "minimal-chime"),
                environment: makeEnvironment(userPacksDirectory: userPacks))
            expect(cards.isEmpty, "an empty pack root must report zero cards, got \(cards.count)")
        }
    }

    // MARK: - /ship 评审修复④（性能）：每个包只解析一次目录、只读一次 manifest bytes
    //
    // `buildPackCard` 过去对每个包读三遍 manifest（`packCoverage(packID:)` 一遍、broken 判定
    // 一遍、`packMetadata` 一遍）+ 解析两遍目录（每遍一轮 realpath），而 `PanelView.refresh()`
    // 在**主线程**、每次开面板和每次静音点击都会跑一次。现在只读一次、解析一次，同一份
    // `packDirectory` / `Data` / `PackManifest` 喂给三个消费者。
    //
    // 读的**次数**在这个无依赖 harness 里不可直接观测（没有可注入的文件系统），所以下面钉的是
    // 这次优化真正有可能破坏的那两条**不变量**——上面那一整套 `availablePacks` 行为断言（complete /
    // partial / broken / name / license / 去重 / 排序）则原样保留，作为「行为一个字都没变」的回归网。

    suite("packCoverage: 按 packID 的入口 == 按已解码 manifest 的下层入口（薄包装，不是第二套逻辑）") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            // 三态齐全的包：stop 存在、stop_failure 声明了但文件不在（broken）、另两个未声明（unmapped）。
            writeFixture(
                #"""
                { "id": "tri-state", "name": "三态", "events": {
                    "stop": "stop.mp3", "stop_failure": "missing.mp3" } }
                """#,
                to: userPacks.appendingPathComponent("tri-state/manifest.json"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("tri-state/stop.mp3"))

            // stop 被静音——正交的 `enabled` 位必须原样穿过下层入口（不是被它「顺手」重算成默认值）。
            let config = ClaudioConfig(
                selectedPack: "tri-state", eventsEnabled: [Event.stop.cliName: false])
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let viaPackID = packCoverage(packID: "tri-state", config: config, environment: environment)

            guard
                let packDirectory = resolvePackDirectory(
                    id: "tri-state", userPacksDirectory: userPacks, bundledPacksDirectory: nil),
                case .success(let manifest) = loadPackManifest(in: packDirectory)
            else {
                expect(false, "fixture 自己就该解析得开——测试前提不成立")
                return
            }
            let viaManifest = packCoverage(
                manifest: manifest, packDirectory: packDirectory, config: config)

            expect(
                viaPackID == viaManifest,
                "两个入口必须给出逐条相同的 EventRow（含 coverage 三态与正交的 enabled 位）——"
                    + "下层入口一旦长出第二套 coverage 逻辑，这条就红。got \(viaPackID) vs \(viaManifest)")
            // 顺带钉住这份 fixture 真的三态齐全，否则上面那条相等断言可能只是在比两个平凡结果。
            expect(
                viaPackID.first(where: { $0.event == .stop })?.coverage == .present(fileName: "stop.mp3"),
                "stop 必须是 .present")
            expect(
                viaPackID.first(where: { $0.event == .stopFailure })?.coverage
                    == .broken(fileName: "missing.mp3"),
                "stop_failure 必须是 .broken（声明了但文件不在）")
            expect(
                viaPackID.first(where: { $0.event == .notification })?.coverage == .unmapped,
                "notification 必须是 .unmapped（manifest 里没这个 key）")
            expect(
                viaManifest.first(where: { $0.event == .stop })?.enabled == false,
                "静音位必须原样穿过下层入口（stop 在 config 里被静音）")
        }
    }

    suite("availablePacks: 卡片的 presentEvents 仍逐个来自 packCoverage —— 不是 PackGallery 自己重算的一套") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"""
                { "id": "tri-state", "name": "三态", "events": {
                    "stop": "stop.mp3", "stop_failure": "missing.mp3", "notification": "ping.mp3" } }
                """#,
                to: userPacks.appendingPathComponent("tri-state/manifest.json"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("tri-state/stop.mp3"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("tri-state/ping.mp3"))

            let config = ClaudioConfig(selectedPack: "tri-state")
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let card = availablePacks(config: config, environment: environment).first
            let coverageTruth = Set(
                packCoverage(packID: "tri-state", config: config, environment: environment)
                    .compactMap { row -> Event? in
                        if case .present = row.coverage { return row.event }
                        return nil
                    })

            expect(
                card?.presentEvents == coverageTruth,
                "卡片点亮的字形集合必须**恒等于** packCoverage 判定的 .present 集合（badge / 2×2 网格 /"
                    + " VoiceOver「缺少：…」三处同一个真相源）——got \(String(describing: card?.presentEvents))"
                    + " vs \(coverageTruth)")
            expect(coverageTruth == [.stop, .notification], "fixture 前提：恰好两个事件真的存在")
            expect(
                card?.state == .partial(present: 2, total: 4),
                "badge 计数必须仍等于 presentEvents.count，got \(String(describing: card?.state))")
        }
    }
}
