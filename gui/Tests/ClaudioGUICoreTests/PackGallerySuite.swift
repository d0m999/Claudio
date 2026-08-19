import ClaudioCore
import ClaudioGUICore
import Foundation

// MARK: - availablePacks / PackCard / PackCardState (ENGINEERING.md T15 D3: pack switching
// gallery model). Mirrors `CoverageStateSuite.swift`'s fixture style.

@MainActor
private func makeEnvironment(
    userPacksDirectory: URL,
    bundledPacksDirectory: URL? = nil,
    factoryPacksDirectory: URL? = nil
) -> AudioImportEnvironment {
    AudioImportEnvironment(
        userPacksDirectory: userPacksDirectory,
        bundledPacksDirectory: bundledPacksDirectory,
        factoryPacksDirectory: factoryPacksDirectory,
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
private func writeCompletePack(named id: String, at userPacks: URL, name: String = "测试包", license: String = "CC0-1.0") {
    writeFixture(
        #"""
        { "id": "\#(id)", "name": "\#(name)", "license": "\#(license)", "events": {
            "task_start": "task.mp3", "stop": "stop.mp3", "stop_failure": "fail.mp3", "notification": "ping.mp3",
            "subagent_stop": "sub.mp3" } }
        """#,
        to: userPacks.appendingPathComponent("\(id)/manifest.json"))
    for file in ["task.mp3", "stop.mp3", "fail.mp3", "ping.mp3", "sub.mp3"] {
        writeFixture("fake-audio", to: userPacks.appendingPathComponent("\(id)/\(file)"))
    }
}

@MainActor
func runPackGallerySuites() {
    suite("full library synthesizes a selected broken placeholder for a missing selected_pack") {
        withTempDirectory { root in
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true))
            let config = ClaudioConfig(selectedPack: "missing-selected")
            let full = availablePacks(
                config: config, environment: environment, scope: .fullLibrary,
                synthesizeMissingSelectedPlaceholder: true)
            let placeholder = full.first { $0.id == "missing-selected" }
            expect(placeholder?.isSelected == true, "placeholder must preserve config selection")
            expect(
                placeholder?.availability == .missingSelectedPlaceholder,
                "full library must expose missing-selected placeholder")
            guard case .broken = placeholder?.state else {
                expect(false, "placeholder must be visibly broken")
                return
            }
            let panel = availablePacks(
                config: config, environment: environment, scope: .panelStarredDisplay)
            expect(
                !panel.contains(where: { $0.id == "missing-selected" }),
                "starred-only panel projection must not inject the placeholder")
        }
    }
    suite("starredPackDisplayIDs: absent defaults, explicit empty, disk intersection, de-duplication, and defensive cap") {
        let installedInOrder = ["a", "b", "c", "d", "e"]
        let missingKeyFixture = try! JSONDecoder().decode(
            ClaudioConfig.self, from: #"{ "selected_pack": "a" }"#.data(using: .utf8)!)
        let explicitEmptyFixture = try! JSONDecoder().decode(
            ClaudioConfig.self,
            from: #"{ "selected_pack": "a", "starred_packs": [] }"#.data(using: .utf8)!)

        expect(
            starredPackDisplayIDs(
                orderedPackIDs: installedInOrder, starredPacks: missingKeyFixture.starredPacks,
                defaultStarredPackIDs: ["d", "b"]
            ) == ["b", "d"],
            "the missing-key fixture must use built-in defaults in existing id order")
        expect(
            starredPackDisplayIDs(
                orderedPackIDs: installedInOrder, starredPacks: explicitEmptyFixture.starredPacks,
                defaultStarredPackIDs: ["a"]
            ).isEmpty,
            "the explicit-empty fixture must mean zero rows, never revive defaults")
        expect(
            starredPackDisplayIDs(
                orderedPackIDs: installedInOrder, starredPacks: ["b", "b", "ghost", "a"],
                defaultStarredPackIDs: []
            ) == ["a", "b"],
            "read-side intersection must omit stale ids and collapse duplicate ids without writing")
        expect(
            starredPackDisplayIDs(
                orderedPackIDs: installedInOrder, starredPacks: installedInOrder,
                defaultStarredPackIDs: []
            ) == ["a", "b", "c", "d"],
            "a hand-edited five-star config must be defensively capped to the first four only in the display model")
        expect(maxStarredPacks == 4, "the read model and writer must share ClaudioCore's named four-star limit")
    }

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

    // MARK: - PLAN-SOUND-MANAGER.md T13: factoryIntegrity（逐字节 CC0 背书）

    suite("factoryIntegrity: clean built-in pack compares manifest and every declared file byte-for-byte") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("user-packs")
            let factoryPacks = root.appendingPathComponent("factory-packs")
            writeCompletePack(named: "minimal-chime", at: userPacks)
            writeCompletePack(named: "minimal-chime", at: factoryPacks)
            let environment = makeEnvironment(
                userPacksDirectory: userPacks, factoryPacksDirectory: factoryPacks)

            expect(
                factoryIntegrity(packID: "minimal-chime", environment: environment) == true,
                "a clean built-in pack must match its factory copy")
            let card = availablePacks(
                config: ClaudioConfig(selectedPack: "minimal-chime"), environment: environment).first
            expect(card?.factoryIntegrity == true, "availablePacks must cache the one factory result on the card")
            expect(
                packRowMetaSlots(
                    isCC0: card?.isCC0 == true, state: card?.state ?? .broken(reason: "missing"),
                    factoryIntegrity: card?.factoryIntegrity).license == .cc0,
                "a clean built-in CC0 card must show CC0")
        }
    }

    suite("factoryIntegrity: manifest bytes or a changed declared file marks the row modified") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("user-packs")
            let factoryPacks = root.appendingPathComponent("factory-packs")
            writeCompletePack(named: "minimal-chime", at: userPacks)
            writeCompletePack(named: "minimal-chime", at: factoryPacks)
            let environment = makeEnvironment(
                userPacksDirectory: userPacks, factoryPacksDirectory: factoryPacks)
            let manifestURL = userPacks.appendingPathComponent("minimal-chime/manifest.json")
            writeFixture(
                #"{ "id": "minimal-chime", "name": "被改过", "license": "CC0-1.0", "events": { "stop": "stop.mp3", "stop_failure": "fail.mp3", "notification": "ping.mp3", "subagent_stop": "sub.mp3" } }"#,
                to: manifestURL)

            expect(
                factoryIntegrity(packID: "minimal-chime", environment: environment) == false,
                "a manifest byte change must fail factoryIntegrity")

            writeCompletePack(named: "minimal-chime", at: userPacks)
            let stopURL = userPacks.appendingPathComponent("minimal-chime/stop.mp3")
            var changedBytes = (try? Data(contentsOf: stopURL)) ?? Data()
            changedBytes.append(0x01)
            writeFixture(changedBytes, to: stopURL)

            let cards = availablePacks(
                config: ClaudioConfig(selectedPack: "minimal-chime"), environment: environment)
            guard let card = cards.first else {
                expect(false, "the modified built-in pack must still have a gallery card")
                return
            }
            expect(card.factoryIntegrity == false, "a changed declared file must fail the cached result")
            let slots = packRowMetaSlots(
                isCC0: card.isCC0, state: card.state, factoryIntegrity: card.factoryIntegrity)
            expect(slots.license == .modified, "a changed built-in row must show ⚠ 已修改")
            expect(slots.license != .cc0, "⚠ 已修改 and CC0 must be mutually exclusive")
        }
    }

    suite("factoryIntegrity: equal-size byte replacement is detected, not just a size change") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("user-packs")
            let factoryPacks = root.appendingPathComponent("factory-packs")
            writeCompletePack(named: "minimal-chime", at: userPacks)
            writeCompletePack(named: "minimal-chime", at: factoryPacks)
            let stopURL = userPacks.appendingPathComponent("minimal-chime/stop.mp3")
            var equalSizeReplacement = (try? Data(contentsOf: stopURL)) ?? Data()
            equalSizeReplacement[0] ^= 0x01
            writeFixture(equalSizeReplacement, to: stopURL)
            let environment = makeEnvironment(
                userPacksDirectory: userPacks, factoryPacksDirectory: factoryPacks)

            expect(
                equalSizeReplacement.count
                    == ((try? Data(contentsOf: factoryPacks.appendingPathComponent("minimal-chime/stop.mp3")))?.count ?? -1),
                "the fixture mutation must preserve file size")
            expect(
                factoryIntegrity(packID: "minimal-chime", environment: environment) == false,
                "an equal-size byte replacement must fail factoryIntegrity")
        }
    }

    suite("factoryIntegrity: non-built-in packs and nil factory roots do not produce a warning") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("user-packs")
            let factoryPacks = root.appendingPathComponent("factory-packs")
            writeCompletePack(named: "custom-pack", at: userPacks)
            writeCompletePack(named: "minimal-chime", at: factoryPacks)
            let withFactory = makeEnvironment(
                userPacksDirectory: userPacks, factoryPacksDirectory: factoryPacks)
            let customCard = availablePacks(
                config: ClaudioConfig(selectedPack: "custom-pack"), environment: withFactory).first
            expect(customCard?.factoryIntegrity == nil, "a non-built-in pack must not participate")
            expect(
                packRowMetaSlots(
                    isCC0: customCard?.isCC0 == true, state: customCard?.state ?? .broken(reason: "missing"),
                    factoryIntegrity: customCard?.factoryIntegrity).license == .cc0,
                "a non-built-in CC0 pack must not be falsely marked modified")

            let withoutFactory = makeEnvironment(userPacksDirectory: userPacks)
            let devCard = availablePacks(
                config: ClaudioConfig(selectedPack: "custom-pack"), environment: withoutFactory).first
            expect(devCard?.factoryIntegrity == nil, "nil factoryPacksDirectory must degrade to not checked")
            expect(
                packRowMetaSlots(
                    isCC0: devCard?.isCC0 == true, state: devCard?.state ?? .broken(reason: "missing"),
                    factoryIntegrity: devCard?.factoryIntegrity).license != .modified,
                "nil factoryPacksDirectory must never show ⚠ 已修改")
        }
    }

    suite("factoryIntegrity: missing or non-regular declared files fail closed") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("user-packs")
            let factoryPacks = root.appendingPathComponent("factory-packs")
            writeCompletePack(named: "minimal-chime", at: userPacks)
            writeCompletePack(named: "minimal-chime", at: factoryPacks)
            let environment = makeEnvironment(
                userPacksDirectory: userPacks, factoryPacksDirectory: factoryPacks)
            let stopURL = userPacks.appendingPathComponent("minimal-chime/stop.mp3")

            try? FileManager.default.removeItem(at: stopURL)
            expect(
                factoryIntegrity(packID: "minimal-chime", environment: environment) == false,
                "a missing declared file must fail factoryIntegrity")

            try? FileManager.default.createDirectory(at: stopURL, withIntermediateDirectories: true)
            expect(
                factoryIntegrity(packID: "minimal-chime", environment: environment) == false,
                "a directory in place of a declared file must fail factoryIntegrity")
        }
    }

    suite("factoryIntegrity: nil factory root is honest even for a built-in-shaped fixture id") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("user-packs")
            writeCompletePack(named: "minimal-chime", at: userPacks)
            let environment = makeEnvironment(userPacksDirectory: userPacks)
            let card = availablePacks(
                config: ClaudioConfig(selectedPack: "minimal-chime"), environment: environment).first

            expect(card?.factoryIntegrity == nil, "without a factory root there is no bundle evidence")
            expect(
                packRowMetaSlots(
                    isCC0: card?.isCC0 == true,
                    state: card?.state ?? .broken(reason: "missing"),
                    factoryIntegrity: card?.factoryIntegrity).license == .cc0,
                "without a factory root a clean fixture must keep the existing CC0-positive behavior")
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
                cards.first?.state == .partial(present: 2, total: 5),
                "2 of 5 events present must report .partial(present: 2, total: 5), got"
                    + " \(String(describing: cards.first?.state))")
            expect(
                cards.first?.presentEvents == [.stop, .notification],
                "presentEvents must list exactly the two events whose files really exist, got"
                    + " \(String(describing: cards.first?.presentEvents))")
            expect(cards.first?.isSelected == false, "a non-selected pack must report isSelected == false")
        }
    }

    // Regression net for the T16 fix: a pack that BOTH leaves some events unmapped AND has a
    // declared-but-missing file. Before the fix, `.partial(present:)` was `total - (declared files
    // missing)`, counted over declared keys, so it disagreed with `presentEvents` (counted over
    // all five current events) — the badge overstated coverage while the track lit 1 slot and
    // VoiceOver named 4 missing. `present` must now equal `presentEvents.count`, so badge, track, and label are
    // one source of truth. (Under the old formula this asserted 3; it now asserts 1.)
    suite("availablePacks: an unmapped event + a declared-but-missing file — present == presentEvents.count") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            // Only stop + stop_failure declared (task_start/notification/subagent_stop UNMAPPED); of the
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
                "only stop truly resolves .present (stop_failure broken, the other three unmapped), got"
                    + " \(String(describing: cards.first?.presentEvents))")
            expect(
                cards.first?.state == .partial(present: 1, total: 5),
                "present must equal presentEvents.count (1), not total minus declared-missing,"
                    + " so badge/grid/label agree — got \(String(describing: cards.first?.state))")
        }
    }

    // Regression net: `manifest.events` is an unconstrained `[String: String]`, so a
    // forward-compat manifest can carry event keys beyond the five current events. Extra keys
    // pointing at missing files must NOT inflate the missing count (which once drove
    // `present = total − missingCount` negative). Counting present current events instead
    // keeps `present` in `0...5` regardless of how many extra broken keys a manifest declares.
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
                cards.first?.state == .partial(present: 1, total: 5),
                "only the one present current event counts; five extra missing keys must not drive"
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
                    "task_start": "task.mp3", "stop": "stop.mp3", "stop_failure": "fail.mp3",
                    "notification": "ping.mp3", "subagent_stop": "sub.mp3" } }
                """#,
                to: userPacks.appendingPathComponent("nameless-pack/manifest.json"))
            for file in ["task.mp3", "stop.mp3", "fail.mp3", "ping.mp3", "sub.mp3"] {
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

    suite("availablePacks: a manifest declaring ZERO events reports .partial(present: 0, total: 5), never .complete") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "silent-pack", "name": "全静默", "events": {} }"#,
                to: userPacks.appendingPathComponent("silent-pack/manifest.json"))

            let cards = availablePacks(
                config: ClaudioConfig(selectedPack: "silent-pack"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            expect(
                cards.first?.state == .partial(present: 0, total: 5),
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
                "卡片点亮的字形集合必须**恒等于** packCoverage 判定的 .present 集合（badge / 覆盖轨 /"
                    + " VoiceOver「缺少：…」三处同一个真相源）——got \(String(describing: card?.presentEvents))"
                    + " vs \(coverageTruth)")
            expect(coverageTruth == [.stop, .notification], "fixture 前提：恰好两个事件真的存在")
            expect(
                card?.state == .partial(present: 2, total: 5),
                "badge 计数必须仍等于 presentEvents.count，got \(String(describing: card?.state))")
        }
    }

    // MARK: - PLAN-SOUND-MANAGER.md T4: packRowTrailingSlot（竖排整宽行的 a11y/布局二分模型）
    //
    // T4 的验收原句：「complete/partial 行必渲染轨、broken 行渲染状态行且高度不跳」。这套无
    // ViewInspector 的 harness 测不了「像素真的没跳」，但「哪个状态落哪个分支」是一个纯函数，
    // 能被钉死——`PackGalleryView` 只切换这个已经决定好的值，自己不做任何状态判断。

    suite("packRowTrailingSlot: exhaustive over the three PackCardState shapes") {
        expect(
            packRowTrailingSlot(for: .complete) == .track,
            "a manifest-readable complete row must resolve to .track")
        expect(
            packRowTrailingSlot(for: .partial(present: 2, total: 5)) == .track,
            "a manifest-readable partial row must resolve to .track, regardless of the count")
        expect(
            packRowTrailingSlot(for: .partial(present: 0, total: 5)) == .track,
            "even a fully-silent (0/5) but still-READABLE manifest must resolve to .track — it's"
                + " not .broken, so there's real (all-missing) coverage data to render")
        expect(
            packRowTrailingSlot(for: .broken(reason: "任意原因")) == .brokenStatus,
            "an unreadable pack must resolve to .brokenStatus regardless of its reason string")
    }

    suite("packRowTrailingSlot: agrees with real availablePacks() output, not just hand-built PackCardState literals") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeCompletePack(named: "complete-pack", at: userPacks)
            writeFixture(
                #"{ "id": "partial-pack", "name": "半成品", "events": { "stop": "stop.mp3" } }"#,
                to: userPacks.appendingPathComponent("partial-pack/manifest.json"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("partial-pack/stop.mp3"))
            writeFixture("{ not valid json", to: userPacks.appendingPathComponent("broken-pack/manifest.json"))

            let cards = availablePacks(
                config: ClaudioConfig(selectedPack: "complete-pack"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            expect(cards.count == 3, "expected complete/partial/broken, got \(cards.count)")
            for card in cards {
                let slot = packRowTrailingSlot(for: card.state)
                switch card.state {
                case .complete, .partial:
                    expect(
                        slot == .track,
                        "\(card.id) is manifest-readable (\(card.state)) — must resolve to .track, got \(slot)")
                case .broken:
                    expect(
                        slot == .brokenStatus,
                        "\(card.id) is broken — must resolve to .brokenStatus, got \(slot)")
                }
            }
        }
    }

    // MARK: - PLAN-SOUND-MANAGER.md T5: packRowMetaSlots（meta 槽拆两个正交子槽）
    //
    // T5 的验收原句：一张 CC0 的 `.partial` 卡必须同时读出 `.cc0` 徽标与「缺 N 个」——license 与
    // 完整度是两根正交轴，T4 前那个单一 `switch card.state` 一旦落进 `.partial` 分支就再也不看
    // `card.isCC0`，CC0 徽标随之静默消失。这个纯函数把「该显哪个徽标」也钉成可测的值，
    // `PackGalleryView` 只渲染它，不再自己切 `card.state`。

    suite("packRowMetaSlots: exhaustive over isCC0 × PackCardState") {
        expect(
            packRowMetaSlots(isCC0: false, state: .complete) == PackRowMetaSlots(license: .none, missingCount: nil),
            "complete + 非 CC0 → 两个子槽都空")
        expect(
            packRowMetaSlots(isCC0: true, state: .complete) == PackRowMetaSlots(license: .cc0, missingCount: nil),
            "complete + CC0 → 仅 license 子槽亮，缺失数为 nil")
        expect(
            packRowMetaSlots(isCC0: false, state: .partial(present: 4, total: 5))
                == PackRowMetaSlots(license: .none, missingCount: 1),
            "partial + 非 CC0 → 仅完整度子槽亮")
        expect(
            packRowMetaSlots(isCC0: true, state: .partial(present: 4, total: 5))
                == PackRowMetaSlots(license: .cc0, missingCount: 1),
            "T5 的核心断言：partial + CC0 → 两个子槽必须同时亮 —— CC0 徽标不因「缺 N 个」而消失")
        expect(
            packRowMetaSlots(isCC0: true, state: .broken(reason: "任意原因"))
                == PackRowMetaSlots(license: .none, missingCount: nil),
            "broken → 整个 meta 槽仍必须是空的，即使 isCC0 传 true（broken 行的判定不看 license）")
        expect(
            packRowMetaSlots(isCC0: false, state: .broken(reason: "任意原因"))
                == PackRowMetaSlots(license: .none, missingCount: nil),
            "broken + 非 CC0 → 同样两个子槽都空")
    }

    suite("packRowMetaSlots: agrees with real availablePacks() output — a CC0 partial pack keeps both badges") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"""
                { "id": "cc0-partial-pack", "name": "半成品 CC0 包", "license": "CC0-1.0", "events": {
                    "task_start": "task.mp3", "stop": "stop.mp3", "stop_failure": "fail.mp3",
                    "notification": "ping.mp3", "subagent_stop": "sub.mp3" } }
                """#,
                to: userPacks.appendingPathComponent("cc0-partial-pack/manifest.json"))
            // 只有四个 declared 文件真的存在——缺 1 个。
            for file in ["task.mp3", "stop.mp3", "fail.mp3", "ping.mp3"] {
                writeFixture("fake-audio", to: userPacks.appendingPathComponent("cc0-partial-pack/\(file)"))
            }

            let cards = availablePacks(
                config: ClaudioConfig(selectedPack: "cc0-partial-pack"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            expect(cards.count == 1, "expected exactly one card, got \(cards.count)")
            guard let card = cards.first else { return }
            expect(card.isCC0 == true, "fixture 前提：license 是 CC0-1.0")
            expect(card.state == .partial(present: 4, total: 5), "fixture 前提：缺 1 个事件")

            let slots = packRowMetaSlots(isCC0: card.isCC0, state: card.state)
            expect(
                slots == PackRowMetaSlots(license: .cc0, missingCount: 1),
                "一张 CC0 的 partial 卡必须同时读出 .cc0 与 missingCount: 1，got \(slots)")
        }
    }

    suite("旧四事件声音包无需 schema 迁移即可加载，并明确显示 4/5 缺任务开始") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let pack = userPacks.appendingPathComponent("legacy-four", isDirectory: true)
            writeFixture(
                #"{"schema":1,"id":"legacy-four","events":{"stop":"stop.mp3","stop_failure":"fail.mp3","notification":"ping.mp3","subagent_stop":"sub.mp3"}}"#,
                to: pack.appendingPathComponent("manifest.json"))
            for file in ["stop.mp3", "fail.mp3", "ping.mp3", "sub.mp3"] {
                writeFixture("fake-audio", to: pack.appendingPathComponent(file))
            }

            let cards = availablePacks(
                config: ClaudioConfig(selectedPack: "legacy-four"),
                environment: makeEnvironment(userPacksDirectory: userPacks))
            guard let card = cards.first else {
                expect(false, "旧四事件包必须继续形成可用卡片")
                return
            }
            expect(card.state == .partial(present: 4, total: 5), "旧包必须诚实显示 4/5")
            expect(
                card.presentEvents == Set(Event.legacyLifecycleCases),
                "旧包只保留原四事件覆盖，不能伪造 task_start fallback")
            expect(!card.presentEvents.contains(.taskStart), "缺任务开始必须保持独立缺失")
        }
    }
}
