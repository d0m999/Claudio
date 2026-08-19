import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
private func starredWindowEnvironment(_ packsDirectory: URL) -> AudioImportEnvironment {
    AudioImportEnvironment(
        userPacksDirectory: packsDirectory,
        bundledPacksDirectory: nil,
        durationProbe: StubDurationProbe(fixedDuration: 1),
        packsLockFile: packsDirectory.deletingLastPathComponent()
            .appendingPathComponent("packs.lock"))
}

@MainActor
private func writeStarredWindowPack(_ id: String, under packsDirectory: URL) {
    writeFixture(
        "{ \"id\": \"\(id)\", \"name\": \"\(id)\", \"events\": {} }",
        to: packsDirectory.appendingPathComponent("\(id)/manifest.json"))
}

@MainActor
private func readStarredWindowConfig(_ configFile: URL) -> [String]? {
    guard
        let data = try? Data(contentsOf: configFile),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return nil
    }
    return object["starred_packs"] as? [String]
}

@MainActor
func runSoundPacksWindowStarredPacksSuites() {
    suite("T17 星标窗口状态源保留原始有效五颗星，而面板显示集独立防御性截为前四") {
        let installed = ["a", "b", "c", "d", "e"]
        let rawFiveStarConfig = ["e", "d", "c", "b", "a"]

        expect(
            soundPacksWindowStarredPackIDs(
                installedPackIDs: installed,
                starredPacks: rawFiveStarConfig,
                defaultStarredPackIDs: []
            ) == rawFiveStarConfig,
            "窗口状态源必须是原始 starred_packs 与磁盘的交集，不能复用 panel prefix(4) 显示集")
        expect(
            starredPackDisplayIDs(
                orderedPackIDs: installed,
                starredPacks: rawFiveStarConfig,
                defaultStarredPackIDs: []
            ) == ["a", "b", "c", "d"],
            "同一份手工五颗星 config 在面板仍只能显示 id 顺序的前四颗")

        let fifthStar = soundPacksWindowStarControl(
            packID: "e",
            rawStarredPackIDs: rawFiveStarConfig,
            isPackBroken: false)
        expect(
            fifthStar.isStarred && fifthStar.isEnabled,
            "超过上限的既有第五颗星必须仍显示为已星标且可取消，不能被 UI 静默截掉")
    }

    suite("T17 窗口取消手工第五颗星会经 setStarredPacks 写盘，并发布 PanelConfigController 的全量 packCards 重算") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let packsDirectory = root.appendingPathComponent("packs")
            let ids = ["a", "b", "c", "d", "e"]
            writeFixture(
                #"{ "selected_pack": "a", "starred_packs": ["a", "b", "c", "d", "e"] }"#,
                to: configFile)
            for id in ids { writeStarredWindowPack(id, under: packsDirectory) }

            let coordinator = SoundPacksRefreshCoordinator()
            let panel = PanelConfigController(
                configFile: configFile,
                lockFile: lockFile,
                environment: starredWindowEnvironment(packsDirectory),
                soundPacksRefreshCoordinator: coordinator)
            let window = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: lockFile,
                environment: starredWindowEnvironment(packsDirectory),
                refreshCoordinator: coordinator)

            expect(
                window.starredPackIDs == ids,
                "窗口必须如实暴露第五颗已有星，给用户解除入口")
            expect(
                panel.packCards.map(\.id) == Array(ids.prefix(maxStarredPacks)),
                "面板必须只读取已过滤的四张卡，不能在 PanelView 再丢弃第五张")

            let result = window.toggleStarredPack("e")
            guard case .success = result else {
                expect(false, "取消第五颗已有星应成功，实得 \(result)")
                return
            }

            expect(
                readStarredWindowConfig(configFile) == Array(ids.prefix(maxStarredPacks)),
                "取消第五颗星必须写出完整但未截断的四颗显式数组")
            expect(
                window.starredPackIDs == Array(ids.prefix(maxStarredPacks)),
                "窗口必须在成功写后从磁盘重读自己的原始星标状态")
            expect(
                panel.packCards.map(\.id) == Array(ids.prefix(maxStarredPacks)),
                "窗口写星后必须触发 PanelConfigController.reload() 重算 packCards，不能走 configOnly")
            expect(
                coordinator.panelReloadRevision == 1,
                "一次成功的星标写必须恰好发布一次 panel full reload")
        }
    }

    suite("T17 星标 toggle：窗口陈旧时保留外部并发加入的 sibling") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let packsDirectory = root.appendingPathComponent("packs")
            for id in ["a", "b", "c"] { writeStarredWindowPack(id, under: packsDirectory) }
            writeFixture(
                #"{"selected_pack":"a","starred_packs":["a"]}"#,
                to: configFile)
            let model = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: lockFile,
                environment: starredWindowEnvironment(packsDirectory),
                refreshCoordinator: SoundPacksRefreshCoordinator())
            expect(model.starredPackIDs == ["a"], "前提：保留窗口仍持有旧星标投影")

            writeFixture(
                #"{"selected_pack":"a","starred_packs":["a","b"]}"#,
                to: configFile)
            let result = model.toggleStarredPack("c")
            expect(
                result == .success(.updated(ids: ["a", "b", "c"])),
                "toggle 必须在锁内基于最新 JSON 加入 c：\(result)")
            expect(
                readStarredWindowConfig(configFile) == ["a", "b", "c"],
                "外部新增的 b 不得被窗口旧数组覆盖掉")
        }
    }

    suite("T17 加入第四颗星后窗口发布 full reload，面板 packCards 不得停在三行 stale 显示") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let packsDirectory = root.appendingPathComponent("packs")
            let ids = ["a", "b", "c", "d"]
            writeFixture(
                #"{ "selected_pack": "a", "starred_packs": ["a", "b", "c"] }"#,
                to: configFile)
            for id in ids { writeStarredWindowPack(id, under: packsDirectory) }

            let coordinator = SoundPacksRefreshCoordinator()
            let panel = PanelConfigController(
                configFile: configFile,
                lockFile: lockFile,
                environment: starredWindowEnvironment(packsDirectory),
                soundPacksRefreshCoordinator: coordinator)
            let window = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: lockFile,
                environment: starredWindowEnvironment(packsDirectory),
                refreshCoordinator: coordinator)
            expect(panel.packCards.map(\.id) == ["a", "b", "c"], "前提：面板初始仅显示三颗星")

            guard case .success = window.toggleStarredPack("d") else {
                expect(false, "第四颗星应能成功写盘")
                return
            }
            expect(
                panel.packCards.map(\.id) == ids,
                "星标只改 config.json 也会改变包列表，因此写后必须走 PanelConfigController.reload()；"
                    + "若误走 reloadConfigOnly，这里会仍是三行")
        }
    }

    suite("T17 满四颗时未星标按钮显式禁用并给原因，取消一颗后恢复") {
        let initiallyFull = ["a", "b", "c", "d"]
        let disabled = soundPacksWindowStarControl(
            packID: "e",
            rawStarredPackIDs: initiallyFull,
            isPackBroken: false)
        expect(
            !disabled.isStarred && !disabled.isEnabled
                && disabled.disabledReason == "面板最多显示 4 个，先取消一颗",
            "满四颗时其余 ☆ 必须是显式禁用控件并给出可执行原因")

        let enabledAfterRemoval = soundPacksWindowStarControl(
            packID: "e",
            rawStarredPackIDs: ["a", "b", "c"],
            isPackBroken: false)
        expect(
            !enabledAfterRemoval.isStarred && enabledAfterRemoval.isEnabled
                && enabledAfterRemoval.disabledReason == nil,
            "取消一颗后其余 ☆ 必须恢复可操作，不能遗留 stale disabled 状态")

        let broken = soundPacksWindowStarControl(
            packID: "broken",
            rawStarredPackIDs: ["a", "b", "c"],
            isPackBroken: true)
        expect(
            !broken.isStarred && !broken.isEnabled
                && broken.disabledReason == "声音包不可用，无法显示在面板",
            "不可用声音包的 ☆ 也必须禁用，并提供与可见就地提示相同的原因")
    }

    suite("T17 第一次取消默认内置星会物化显式空数组，不让默认星在下一次 reload 复活") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let packsDirectory = root.appendingPathComponent("packs")
            let factoryDirectory = root.appendingPathComponent("factory")
            writeFixture(#"{ "selected_pack": "builtin" }"#, to: configFile)
            writeStarredWindowPack("builtin", under: packsDirectory)
            try? FileManager.default.createDirectory(
                at: factoryDirectory.appendingPathComponent("builtin"),
                withIntermediateDirectories: true)
            let environment = AudioImportEnvironment(
                userPacksDirectory: packsDirectory,
                bundledPacksDirectory: nil,
                factoryPacksDirectory: factoryDirectory,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: root.appendingPathComponent("packs.lock"))
            let model = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: lockFile,
                environment: environment,
                refreshCoordinator: SoundPacksRefreshCoordinator())

            expect(model.starredPackIDs == ["builtin"], "缺键时窗口必须显示内置默认星")
            guard case .success = model.toggleStarredPack("builtin") else {
                expect(false, "取消唯一默认星必须能通过 T16 写者物化明确空数组")
                return
            }
            expect(
                readStarredWindowConfig(configFile) == [],
                "取消最后一颗默认星必须写 starred_packs: []，否则下一次 reload 会错误复活默认星")
            expect(model.starredPackIDs.isEmpty, "成功写后的窗口状态必须确认默认星没有复活")
        }
    }

    suite("T17 星标写失败保留窗口可见 reason，并将同一句 reason 交给窗口 VoiceOver 策略") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let packsDirectory = root.appendingPathComponent("packs")
            writeStarredWindowPack("a", under: packsDirectory)
            writeFixture(
                #"{ "selected_pack": "a", "starred_packs": "不是数组" }"#,
                to: configFile)

            guard case .malformed(let probeReason) = probeConfigRewritable(configFile: configFile) else {
                expect(false, "测试前提：畸形 starred_packs 必须被 probe 拦下")
                return
            }
            let model = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: lockFile,
                environment: starredWindowEnvironment(packsDirectory),
                refreshCoordinator: SoundPacksRefreshCoordinator())
            let result = model.updateStarredPacks(to: ["a"])
            guard case .failure(.configReadFailure) = result else {
                expect(false, "畸形 config 的星标写必须 fail closed，实得 \(result)")
                return
            }
            expect(
                model.starredPacksFailureReason == probeReason,
                "窗口 FailureRow 的 config reason 必须与 probeConfigRewritable 逐字同句")
            expect(
                soundPacksWindowAnnouncement(
                    .writeFailed(action: "更新星标", reason: model.starredPacksFailureReason ?? ""),
                    facts: SoundPacksWindowAnnouncementFacts(packCount: 1, selectedPackName: "a")
                ) == "更新星标失败：\(probeReason)",
                "窗口 VoiceOver 必须复用可见 FailureRow 的同一句可执行 reason")
        }

        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let packsDirectory = root.appendingPathComponent("packs")
            writeStarredWindowPack("a", under: packsDirectory)
            writeFixture(#"{ "selected_pack": "a", "starred_packs": [] }"#, to: configFile)
            let holder = FileLock(path: lockFile.path)
            expect(holder.tryLock(), "测试前提：必须实际占住 config.lock")
            defer { holder.unlock() }
            let model = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: lockFile,
                environment: starredWindowEnvironment(packsDirectory),
                refreshCoordinator: SoundPacksRefreshCoordinator())

            guard case .failure(.lockBusy) = model.updateStarredPacks(to: ["a"]) else {
                expect(false, "锁忙的星标写必须保留 .lockBusy，而不是安静丢弃")
                return
            }
            expect(
                model.starredPacksFailureReason == SetStarredPacksError.lockBusy.description,
                "lock busy 必须在窗口 FailureRow 中显示写者的可执行原句")
        }

        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let packsDirectory = root.appendingPathComponent("packs")
            let ids = ["a", "b", "c", "d", "e"]
            for id in ids { writeStarredWindowPack(id, under: packsDirectory) }
            writeFixture(#"{ "selected_pack": "a", "starred_packs": [] }"#, to: configFile)
            let model = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: lockFile,
                environment: starredWindowEnvironment(packsDirectory),
                refreshCoordinator: SoundPacksRefreshCoordinator())

            guard case .failure(.tooManyStarredPacks(max: maxStarredPacks)) =
                model.updateStarredPacks(to: ids)
            else {
                expect(false, "绕过 UI 传入第五颗星时，T16 写者仍必须拒绝")
                return
            }
            expect(
                model.starredPacksFailureReason
                    == SetStarredPacksError.tooManyStarredPacks(max: maxStarredPacks).description,
                ">4 拒绝必须进入同一个窗口 FailureRow/VoiceOver reason 通道")
        }
    }

    suite("T17 接线：面板在 availablePacks 的 id 层过滤，窗口星标写走 full reload、共享 FailureRow 与窗口 VO") {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let panel = (try? String(contentsOf: root.appendingPathComponent(
            "gui/Sources/ClaudioGUICore/PanelConfigController.swift"), encoding: .utf8)) ?? ""
        let gallery = (try? String(contentsOf: root.appendingPathComponent(
            "gui/Sources/ClaudioGUICore/PackGallery.swift"), encoding: .utf8)) ?? ""
        let model = (try? String(contentsOf: root.appendingPathComponent(
            "gui/Sources/ClaudioGUICore/SoundPacksWindowModel.swift"), encoding: .utf8)) ?? ""
        let view = (try? String(contentsOf: root.appendingPathComponent(
            "gui/Sources/SoundPacksWindow/SoundPacksWindowView.swift"), encoding: .utf8)) ?? ""
        let controller = (try? String(contentsOf: root.appendingPathComponent(
            "gui/Sources/SoundPacksWindow/SoundPacksWindowController.swift"), encoding: .utf8)) ?? ""

        expect(
            panel.contains("scope: .panelStarredDisplay")
                && gallery.contains("case .panelStarredDisplay")
                && gallery.contains("var cards = displayedIDs.map"),
            "≤4 过滤必须在 PanelConfigController.reloadConfigReadModel 的 availablePacks 调用生效，并先于 buildPackCard")
        expect(
            !view.contains("starredPackDisplayIDs("),
            "窗口不得复用 prefix(4) 的面板显示集作为星标状态源")
        expect(
            model.contains("ClaudioCore.toggleStarredPack(")
                && model.contains("completeSynchronousWrite(.succeeded)")
                && model.contains("completeSynchronousWrite(.failed)"),
            "窗口星标写必须走锁内原子 membership writer；成功 full refresh，失败保留状态但不假刷新")
        expect(
            view.contains("private func starButton")
                && view.contains(".disabled(!control.isEnabled)")
                && view.contains(".help(control.disabledReason ?? \"\")")
                && view.contains("if let reason = starControl.disabledReason")
                && view.contains("Text(reason)")
                && view.contains(".accessibilityHidden(true)")
                && view.contains(".accessibilityHint(")
                && view.contains("model.toggleStarredPack(card.id)")
                && !view.contains(".opacity(control.isEnabled")
                && view.contains("FailureRow(message: reason)"),
            "禁用 ☆ 的原因必须同时以 macOS hover、就地可见文字和既有 VoiceOver hint 提供；"
                + "不得靠降低整行透明度表达禁用，星标失败仍接到共享 FailureRow")
        expect(
            model.contains("kind: .starredPacks")
                && model.contains(
                    "messageText: .literal(soundPacksWindowStarredPacksFailureReason(error))")
                && controller.contains("model.$windowStatuses")
                && controller.contains("status.action(language: languageStore.language)")
                && controller.contains("status.message(language: languageStore.language)"),
            "星标失败必须用 FailureRow 同一句 reason 进入统一状态与唯一 VoiceOver bridge")
    }
}
