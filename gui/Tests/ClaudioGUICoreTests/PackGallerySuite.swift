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
        durationProbe: StubDurationProbe(fixedDuration: 1.0)
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
}
