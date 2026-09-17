import ClaudioCore
import ClaudioGUICore
import Foundation

private func scopedPackCard(
    id: String,
    state: PackCardState = .complete,
    availability: PackCardAvailability = .installed
) -> PackCard {
    PackCard(
        id: id,
        name: id,
        isCC0: false,
        presentEvents: state == .complete ? Set(Event.allCases) : [],
        state: state,
        isSelected: false,
        availability: availability)
}

private func readJSON(at url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

@MainActor
func runAICuePackScopedSuites() {
    suite("AI 提示音包名称：去空白、64 字符上限与双语顺序") {
        expect(
            (try? AICuePackName("  My Cue Pack  "))?.value == "My Cue Pack",
            "包名称必须先去除首尾空白")
        expect(
            (try? AICuePackName(String(repeating: "中", count: 64))) != nil,
            "64 个完整字符必须合法")
        expect(
            (try? AICuePackName(String(repeating: "中", count: 65))) == nil,
            "超过 64 个字符必须拒绝")
        expect(
            (try? AICuePackName("\u{0000}")) == nil,
            "控制字符必须拒绝")
        expect(
            nextAICuePackDraftName(
                existingNames: ["My Cue Pack 1", "MY CUE PACK 2"],
                language: .english
            ).value == "My Cue Pack 3",
            "英文默认名称必须跳过大小写等价的已占用名称")
        expect(
            nextAICuePackDraftName(
                existingNames: ["我的提示音组 １"],
                language: .zhHans
            ).value == "我的提示音组 2",
            "中文默认名称必须识别全角数字占用")
    }

    suite("AI 提示音包使用范围：Global 继承、Surface 覆盖与损坏配置分离") {
        let globalConfig = ClaudioConfig(selectedPack: "global-pack")
        let globalUsage = aiCuePackUsage(packID: "global-pack", config: globalConfig)
        let expectedGlobalConsumers =
            [.global] + HostID.productVisibleCases.map { AICuePackConsumer.surface($0.surfaceID) }
        expect(
            globalUsage.effectiveConsumers == expectedGlobalConsumers,
            "Global 包必须报告 Global 与所有产品 Surface 的继承使用者")
        expect(
            globalUsage.consumers.dropFirst().allSatisfy(\.inherited)
                && !globalUsage.usageIsIncomplete,
            "继承使用者必须单独标记且完整配置不得提示范围不完整")

        let surfaceConfig = ClaudioConfig(
            selectedPack: "global-pack",
            surfaceOverrides: [
                HostSurfaceID.workBuddy.rawValue: SurfaceSoundOverride(
                    selectedPack: "surface-pack")
            ])
        let surfaceUsage = aiCuePackUsage(packID: "surface-pack", config: surfaceConfig)
        expect(
            surfaceUsage.effectiveConsumers == [.surface(.workBuddy)]
                && !surfaceUsage.consumers[0].inherited,
            "显式 Surface 包必须只报告该 Surface，不能把它误算成 Global 继承")

        var damagedConfig = surfaceConfig
        damagedConfig.invalidSurfaceOverrideKeys.insert(HostSurfaceID.codex.rawValue)
        let damagedUsage = aiCuePackUsage(packID: "global-pack", config: damagedConfig)
        expect(
            damagedUsage.usageIsIncomplete,
            "无法分类的 Surface override 必须显示使用范围不完整")
        expect(
            !damagedUsage.effectiveConsumers.contains(.surface(.codex)),
            "损坏的 Surface 不得被静默降级成 Global 或有效使用者")
    }

    suite("AI 提示音包资格：健康用户包与损坏配置解耦，内置/损坏/缺失包仍拒绝") {
        let healthy = scopedPackCard(
            id: "healthy-pack",
            state: .partial(present: 2, total: Event.allCases.count))
        let healthyEligibility = aiCuePackAdoptionEligibility(
            packID: "healthy-pack",
            event: .stop,
            packCards: [healthy],
            builtinPackIDs: [])
        expect(
            healthyEligibility
                == .eligible(try! AICueAdoptionTarget(packID: "healthy-pack", event: .stop)),
            "健康用户包即使配置投影损坏也必须可进行包级采用")

        expect(
            aiCuePackAdoptionEligibility(
                packID: "healthy-pack",
                event: .stop,
                packCards: [healthy],
                builtinPackIDs: ["healthy-pack"])
                == .ineligible(.builtinReadOnly(packID: "healthy-pack")),
            "内置包不得被包级 AI 采用改写")
        expect(
            aiCuePackAdoptionEligibility(
                packID: "broken-pack",
                event: .stop,
                packCards: [
                    scopedPackCard(id: "broken-pack", state: .broken(reason: "bad manifest"))
                ],
                builtinPackIDs: [])
                == .ineligible(.packBroken(packID: "broken-pack")),
            "manifest 损坏的包不得获得采用许可")
        expect(
            aiCuePackAdoptionEligibility(
                packID: "missing-pack",
                event: .stop,
                packCards: [
                    scopedPackCard(
                        id: "missing-pack", availability: .missingSelectedPlaceholder)
                ],
                builtinPackIDs: [])
                == .ineligible(.packUnavailable(packID: "missing-pack")),
            "仅有缺失占位的包不得获得采用许可")
    }

    suite("AI 提示音路由：普通编辑与复制并应用保留不同意图及精确作用域") {
        let ordinary = SoundPacksWindowRoute.editEvent(
            surface: .workBuddy, packID: "factory-pack", event: .notification)
        let copyAndApply = SoundPacksWindowRoute.copyAndApply(
            surface: .workBuddy, packID: "factory-pack", event: .notification)
        let globalCopy = SoundPacksWindowRoute.copyAndApply(
            packID: "factory-pack", event: .notification)
        expect(ordinary != copyAndApply, "复制并应用不得与普通事件编辑共享同一个路由身份")
        expect(copyAndApply.isCopyAndApply, "复制并应用路由必须带有类型化意图")
        expect(
            copyAndApply.editTarget?.packID == "factory-pack"
                && copyAndApply.editTarget?.event == .notification
                && copyAndApply.surface == .workBuddy,
            "Surface 复制路由必须保留 pack、Event 与 Surface")
        expect(
            globalCopy.surface == nil && globalCopy.isCopyAndApply,
            "Global 复制路由必须显式表达 nil Global，而非伪造 Surface")

        let eventRoute = EventSettingsWindowRoute(
            scope: .surface(.workBuddy), event: .notification)
        expect(
            eventRoute.soundPacksCopyAndApplyRoute(
                packID: "factory-pack", event: .notification) == copyAndApply,
            "事件缺声深链必须使用同一个显式 Surface 复制路由")
    }

    suite("AI 提示音空组：取消只清理草稿，不创建可选声音包") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            let owner = SoundPacksEditorOwner.stateGalleryFixture(
                previewConfig: ClaudioConfig(selectedPack: "existing-pack"),
                packCards: [],
                selectedPackID: nil,
                selectedEventRows: [],
                environment: makeAudioImportEnvironment(userPacksDirectory: packs))
            expect(
                owner.beginAICuePackDraft(language: .english),
                "声音页必须能先创建未发布的草稿身份")
            guard case .sounds(let soundsWithDraft) = owner.presentation.mode,
                let draft = soundsWithDraft.draft
            else {
                expect(false, "创建草稿后必须投影 draft，而不是直接投影可选包")
                return
            }
            expect(
                draft.name == "My Cue Pack 1"
                    && draft.packID.hasPrefix("ai-cue-")
                    && !FileManager.default.fileExists(
                        atPath: packs.appendingPathComponent(draft.packID).path),
                "空组草稿只能保留安全 ID 和名称，不能提前出现最终包目录")

            owner.cancelAICuePackDraft()
            guard case .sounds(let soundsAfterCancel) = owner.presentation.mode else {
                expect(false, "取消草稿后仍应停留在声音页")
                return
            }
            expect(
                soundsAfterCancel.draft == nil
                    && !FileManager.default.fileExists(
                        atPath: packs.appendingPathComponent(draft.packID).path),
                "取消草稿不得留下可选包目录")
        }
    }

    suite("AI 提示音草稿事务：音频与绑定先在隐藏树完成，再一次性发布并去除归属声明") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            let source = root.appendingPathComponent("source.mp3")
            writeFixture(validMP3ID3Data(), to: source)
            let environment = AudioImportEnvironment(
                userPacksDirectory: packs,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: injectedPacksLock(besideUserPacks: packs))
            let draft = try! AICuePackDraft(
                packID: "ai-cue-draft-test",
                name: try! AICuePackName("测试草稿"))

            guard
                case .success(let stage) = makeAICuePackDraftStage(
                    draft, environment: environment)
            else {
                expect(false, "必须能创建隐藏草稿暂存树")
                return
            }
            expect(
                stage.rootURL.lastPathComponent.hasPrefix(".ai-cue-draft-test.tmp-")
                    && !FileManager.default.fileExists(atPath: stage.finalDirectoryURL.path),
                "暂存目录必须隐藏且最终包在发布前不可见")

            writeFixture(
                #"{ "id": "ai-cue-draft-test", "name": "测试草稿", "license": "CC0-1.0", "author": "AI", "schema": 7, "events": {}, "audio_names": {} }"#,
                to: stage.packDirectoryURL.appendingPathComponent("manifest.json"))
            let stagingEnvironment = stagingEnvironment(
                for: stage, basedOn: environment)
            guard
                case .success(let imported) = importAudioFile(
                    sourceURL: source,
                    suggestedFileName: "generated.mp3",
                    packID: draft.packID,
                    environment: stagingEnvironment)
            else {
                expect(false, "草稿音频必须先成功写入隐藏暂存包")
                discardAICuePackDraftStage(stage)
                return
            }
            let binding = bindAICueToManifest(
                event: .stop,
                fileName: imported.fileName,
                displayName: try! AICueDisplayName("完成"),
                packID: draft.packID,
                environment: stagingEnvironment,
                expectedEventBinding: .unmapped,
                removePackAttribution: true)
            guard case .success = binding else {
                expect(false, "草稿 manifest 必须能在暂存树中绑定 Event")
                discardAICuePackDraftStage(stage)
                return
            }
            guard
                case .success(let published) = publishAICuePackDraft(
                    stage, importedFile: imported, environment: environment)
            else {
                expect(false, "完整草稿必须能以独占重命名发布")
                discardAICuePackDraftStage(stage)
                return
            }
            expect(
                published.destinationURL
                    == stage.finalDirectoryURL.appendingPathComponent(imported.fileName)
                    && FileManager.default.fileExists(atPath: published.destinationURL.path),
                "发布后的导入结果必须指向最终用户包")
            guard
                let manifest = readJSON(
                    at: stage.finalDirectoryURL.appendingPathComponent("manifest.json"))
            else {
                expect(false, "发布后的 manifest 必须可读")
                discardAICuePackDraftStage(stage)
                return
            }
            let events = manifest["events"] as? [String: Any]
            let audioNames = manifest["audio_names"] as? [String: Any]
            expect(
                manifest["license"] == nil && manifest["author"] == nil
                    && manifest["schema"] as? Int == 7,
                "采用发布必须在同一次 manifest 写入中移除 license/author 并保留未知字段")
            expect(
                events?[Event.stop.manifestKey] as? String == imported.fileName
                    && audioNames?[imported.fileName] as? String == "完成",
                "发布后的 manifest 必须同时保留 Event 绑定与显示名称")
            discardAICuePackDraftStage(stage)
            expect(
                !FileManager.default.fileExists(atPath: stage.rootURL.path),
                "发布完成后隐藏暂存根必须清理")
        }
    }

    suite("AI 提示音草稿事务：发布前失败不暴露最终包") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            let source = root.appendingPathComponent("source.mp3")
            writeFixture(validMP3ID3Data(), to: source)
            let environment = AudioImportEnvironment(
                userPacksDirectory: packs,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: injectedPacksLock(besideUserPacks: packs),
                beforeAICueDraftPublish: { _ in
                    throw NSError(domain: "AICuePackScopedSuite", code: 1)
                })
            let draft = try! AICuePackDraft(
                packID: "ai-cue-publish-failure",
                name: try! AICuePackName("失败草稿"))
            guard
                case .success(let stage) = makeAICuePackDraftStage(
                    draft, environment: environment)
            else {
                expect(false, "失败路径测试必须先获得隐藏暂存树")
                return
            }
            let stagingEnvironment = stagingEnvironment(
                for: stage, basedOn: environment)
            guard
                case .success(let imported) = importAudioFile(
                    sourceURL: source,
                    suggestedFileName: "generated.mp3",
                    packID: draft.packID,
                    environment: stagingEnvironment)
            else {
                expect(false, "失败路径测试必须先获得暂存导入文件")
                discardAICuePackDraftStage(stage)
                return
            }
            let result = publishAICuePackDraft(
                stage, importedFile: imported, environment: environment)
            if case .failure(.publishFailed) = result {
                expect(true, "发布钩子失败必须映射为 typed publishFailed")
            } else {
                expect(false, "发布钩子失败必须保持失败且不误报成功：\(result)")
            }
            expect(
                !FileManager.default.fileExists(atPath: stage.finalDirectoryURL.path),
                "发布失败不得产生可选最终包")
            discardAICuePackDraftStage(stage)
        }
    }

    suite("已安装声音包复制：用户来源优先、保留未知字段并去除归属") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            let bundled = root.appendingPathComponent("bundled", isDirectory: true)
            writeFixture(
                #"{ "id": "source-pack", "name": "用户当前", "license": "CC0-1.0", "author": "User", "schema": 9, "events": { "stop": "user.mp3" } }"#,
                to: packs.appendingPathComponent("source-pack/manifest.json"))
            writeFixture(
                Data("user-bytes".utf8),
                to: packs.appendingPathComponent("source-pack/user.mp3"))
            writeFixture(
                #"{ "id": "source-pack", "name": "工厂版本", "events": { "stop": "factory.mp3" } }"#,
                to: bundled.appendingPathComponent("source-pack/manifest.json"))
            writeFixture(
                Data("factory-bytes".utf8),
                to: bundled.appendingPathComponent("source-pack/factory.mp3"))
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: packs,
                bundledPacksDirectory: bundled,
                factoryPacksDirectory: bundled)

            let result = forkInstalledPack(
                fromID: "source-pack", newID: "source-pack-copy", environment: environment)
            guard case .success = result,
                let manifest = readJSON(
                    at: packs.appendingPathComponent("source-pack-copy/manifest.json"))
            else {
                expect(false, "健康已安装包必须能复制")
                return
            }
            expect(
                manifest["id"] as? String == "source-pack-copy"
                    && manifest["name"] as? String == "用户当前 的副本"
                    && manifest["license"] == nil
                    && manifest["author"] == nil
                    && manifest["schema"] as? Int == 9,
                "复制必须使用用户当前来源、改写身份并保留未知字段")
            expect(
                (try? Data(contentsOf: packs.appendingPathComponent("source-pack-copy/user.mp3")))
                    == Data("user-bytes".utf8),
                "复制必须保留已安装用户包的实际音频内容")
        }
    }

    suite("复制后应用失败：副本保留，且不自动重新生成") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            writeFixture(
                #"{ "id": "source-pack", "name": "源包", "events": { "stop": "stop.mp3" } }"#,
                to: packs.appendingPathComponent("source-pack/manifest.json"))
            writeFixture(
                Data("audio".utf8),
                to: packs.appendingPathComponent("source-pack/stop.mp3"))
            let config = root.appendingPathComponent("config.json")
            writeFixture(
                #"{ "selected_pack": "source-pack", "master_volume": 0.8, "events": {} }"#,
                to: config)
            let environment = makeAudioImportEnvironment(userPacksDirectory: packs)
            let model = SoundPacksWindowModel(
                configFile: config,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                refreshCoordinator: SoundPacksRefreshCoordinator())
            guard case .success(let copy) = model.copySelectedPack() else {
                expect(false, "复制应用失败测试必须先完成复制")
                return
            }
            let apply = model.applyPackSelection(
                copy.newPackID,
                to: .chatGPTDesktopAX,
                allowFreshlyPublishedPack: true)
            expect(
                apply == .failure(.invalidScope(.chatGPTDesktopAX)),
                "非法作用域应用必须 fail closed")
            expect(
                FileManager.default.fileExists(
                    atPath: packs.appendingPathComponent(copy.newPackID).path),
                "复制成功而应用失败时必须保留副本供用户再次检查")
        }
    }
}
