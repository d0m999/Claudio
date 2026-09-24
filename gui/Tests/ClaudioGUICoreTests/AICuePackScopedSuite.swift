import ClaudioCore
import ClaudioGUICore
import ClaudioSettingsPresentation
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

    suite("声音页草稿名称状态：归一化后统一控制保存与采纳") {
        let unchanged = aiCuePackDraftNameEdit(
            draftName: "My Cue Pack 1", input: "  My Cue Pack 1  ")
        expect(
            unchanged == .unchanged && !unchanged.needsSave
                && unchanged.savableName == nil,
            "只多首尾空白不是待保存变更，不能阻止候选采纳")

        let changed = aiCuePackDraftNameEdit(
            draftName: "My Cue Pack 1", input: "  My Favorite Cue  ")
        expect(
            changed.savableName?.value == "My Favorite Cue" && changed.needsSave,
            "有效改名必须允许保存，并在保存前阻止候选采纳")

        let invalid = aiCuePackDraftNameEdit(draftName: "My Cue Pack 1", input: "  ")
        expect(
            invalid == .invalid && invalid.needsSave && invalid.savableName == nil,
            "无效名称不能保存，也不能绕过采纳前名称检查")

        for staleInput in ["", "previous draft"] {
            let absent = aiCuePackDraftNameEdit(draftName: nil, input: staleInput)
            expect(
                absent == .noDraft && !absent.needsSave,
                "已有包没有草稿时，不得显示保存草稿名提示或阻止采纳")
        }
    }

    suite("AI 提示音包使用范围：Global 继承、Surface 覆盖与损坏配置分离") {
        let globalConfig = ClaudioConfig(selectedPack: "global-pack")
        let globalUsage = aiCuePackUsage(packID: "global-pack", config: globalConfig)
        expect(globalUsage.effectiveConsumers == [.global], "默认组只报告一个消费者")
        var config = globalConfig
        let rule = WorkspaceSoundRule(
            directory: WorkspaceDirectory(kind: .directory, path: "/fixture/project"),
            surfaces: [.codex],
            profile: WorkspaceSoundProfile(selectedPack: "workspace-pack", volume: 0.4))
        config.workspaceRules = [rule]
        config.surfaceOverrides = [
            HostSurfaceID.workBuddy.rawValue: SurfaceSoundOverride(selectedPack: "retired")
        ]
        expect(
            aiCuePackUsage(packID: "workspace-pack", config: config).effectiveConsumers == [
                .workspace(rule.id)
            ], "工作区必须报告独立包使用关系")
        expect(
            aiCuePackUsage(packID: "retired", config: config).effectiveConsumers.isEmpty,
            "旧来源覆盖不再使用声音包")
        config.invalidSurfaceOverrideKeys.insert(HostSurfaceID.codex.rawValue)
        expect(
            !aiCuePackUsage(packID: "global-pack", config: config).usageIsIncomplete,
            "旧覆盖损坏不应污染新声音模型")

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

    suite("声音页联网生成门：目标会话与健康可编辑包必须一致") {
        withTempDirectory { root in
            let owner = SoundPacksEditorOwner.stateGalleryFixture(
                previewConfig: ClaudioConfig(selectedPack: "pack-a"),
                packCards: [
                    scopedPackCard(id: "pack-a"),
                    scopedPackCard(id: "builtin-pack"),
                    scopedPackCard(
                        id: "broken-pack", state: .broken(reason: "bad manifest")),
                ],
                selectedPackID: "pack-a",
                selectedEventRows: [],
                builtinPackIDs: ["builtin-pack"],
                environment: makeAudioImportEnvironment(
                    userPacksDirectory: root.appendingPathComponent("packs")))
            @MainActor func allowed(_ session: AICueComposerSession) -> Bool {
                guard case .sounds(let sounds) = owner.presentation.mode else { return false }
                return soundsAICueGenerationIsAllowed(
                    sounds: sounds,
                    library: owner.presentation.library,
                    session: session,
                    event: .stop)
            }
            expect(
                allowed(AICueComposerSession(packID: "pack-a", event: .stop)),
                "健康用户包的当前会话可以生成")
            expect(
                !allowed(AICueComposerSession(packID: "builtin-pack", event: .stop)),
                "会话指向另一包时即使有旧 composer 也不能生成")
            guard case .sounds(let first) = owner.presentation.mode,
                let inspectBuiltin = first.packs.first(where: { $0.id == "builtin-pack" })?
                    .inspectAction
            else {
                expect(false, "内置包必须可供检查")
                return
            }
            _ = owner.send(.invoke(inspectBuiltin))
            expect(
                !allowed(AICueComposerSession(packID: "builtin-pack", event: .stop)),
                "内置只读包不能发起可能计费的生成")
            guard case .sounds(let second) = owner.presentation.mode,
                let inspectBroken = second.packs.first(where: { $0.id == "broken-pack" })?
                    .inspectAction
            else {
                expect(false, "损坏包必须可供检查")
                return
            }
            _ = owner.send(.invoke(inspectBroken))
            expect(
                !allowed(AICueComposerSession(packID: "broken-pack", event: .stop)),
                "损坏包不能发起可能计费的生成")
            expect(
                owner.beginAICuePackDraft(language: .english),
                "健康包不可用时仍可新建未发布草稿")
            guard case .sounds(let withDraft) = owner.presentation.mode,
                let draft = withDraft.draft
            else {
                expect(false, "新建草稿必须投影身份")
                return
            }
            expect(
                allowed(AICueComposerSession(packID: draft.packID, event: .stop)),
                "未发布草稿允许为首音生成")
            guard
                let inspectA = withDraft.packs.first(where: { $0.id == "pack-a" })?
                    .inspectAction
            else {
                expect(false, "草稿期间仍需提供已安装包检查动作")
                return
            }
            _ = owner.send(.invoke(inspectA))
            guard case .sounds(let afterInspect) = owner.presentation.mode else {
                expect(false, "检查包后必须仍在声音页")
                return
            }
            expect(
                afterInspect.draft == nil && afterInspect.selectedPack?.id == "pack-a"
                    && !allowed(AICueComposerSession(packID: draft.packID, event: .stop)),
                "切换到已安装包必须丢弃空草稿并撤销旧目标的生成资格")
        }
    }

    suite("声音页缺声深链：加载时待定，ready 后定位包再打开事件") {
        withTempDirectory { root in
            let route = SoundPacksWindowRoute.editEvent(
                packID: "pack-b", event: .stop)
            let pending = AICueComposerSession(packID: "pack-b", event: .stop)
            let loading = SoundPacksEditorOwner.stateGalleryFixture(
                previewConfig: ClaudioConfig(selectedPack: "pack-a"),
                packCards: [],
                selectedPackID: nil,
                selectedEventRows: [],
                libraryPresentationState: .loading,
                environment: makeAudioImportEnvironment(
                    userPacksDirectory: root.appendingPathComponent("loading")),
                activation: .sounds(route: route, requestRevision: 1))
            if case .sounds(let sounds) = loading.presentation.mode,
                case .pending = soundsAICueRouteStep(pending, route: route, sounds: sounds)
            {
                expect(true, "首次库加载不能丢弃深链")
            } else {
                expect(false, "首次库加载必须保留待定位深链")
            }

            let ready = SoundPacksEditorOwner.stateGalleryFixture(
                previewConfig: ClaudioConfig(selectedPack: "pack-a"),
                packCards: [scopedPackCard(id: "pack-a"), scopedPackCard(id: "pack-b")],
                selectedPackID: "pack-a",
                selectedEventRows: [],
                environment: makeAudioImportEnvironment(
                    userPacksDirectory: root.appendingPathComponent("ready")),
                activation: .sounds(route: route, requestRevision: 1))
            guard case .sounds(let atTarget) = ready.presentation.mode else {
                expect(false, "就绪后必须投影声音页")
                return
            }
            if case .begin(let session) = soundsAICueRouteStep(
                pending, route: route, sounds: atTarget)
            {
                expect(session == pending, "ready 后必须打开原始包和事件")
            } else {
                expect(false, "ready 后必须解析精确事件深链")
            }
            guard
                let inspectA = atTarget.packs.first(where: { $0.id == "pack-a" })?
                    .inspectAction
            else {
                expect(false, "目标就绪时其他包仍应可供检查")
                return
            }
            _ = ready.send(.invoke(inspectA))
            if case .sounds(let atA) = ready.presentation.mode,
                case .inspect(let inspectB) = soundsAICueRouteStep(
                    pending, route: route, sounds: atA)
            {
                _ = ready.send(.invoke(inspectB))
                if case .sounds(let atB) = ready.presentation.mode,
                    case .begin = soundsAICueRouteStep(pending, route: route, sounds: atB)
                {
                    expect(true, "先检查目标包，再打开其事件")
                } else {
                    expect(false, "inspect 后必须能继续原深链")
                }
            } else {
                expect(false, "包未选中时必须先检查目标包")
            }
        }
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
            expect(
                owner.renameAICuePackDraft(try! AICuePackName("  我的铃声  ")),
                "未发布草稿必须允许用户修改名称")
            guard case .sounds(let renamedSounds) = owner.presentation.mode,
                let renamed = renamedSounds.draft
            else {
                expect(false, "改名后必须继续投影同一个草稿")
                return
            }
            expect(
                renamed.packID == draft.packID && renamed.name == "我的铃声"
                    && !FileManager.default.fileExists(
                        atPath: packs.appendingPathComponent(draft.packID).path),
                "改名只更新草稿元数据，不能提前发布包")

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
            expect(
                !FileManager.default.fileExists(atPath: stage.rootURL.path),
                "成功发布必须自行清理已搬空的隐藏暂存根")
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

@MainActor
func runAICuePackScopedAsyncSuites() async {
    await suite("声音页包级生成：配置损坏不阻断健康包或未发布草稿") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["healthy-pack"],
                configJSON: "{not-json")
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 1)))
            await waitForSoundEditorReady(owner, library: fixture.library)

            @MainActor func canGenerate(_ packID: String) -> Bool {
                guard case .sounds(let sounds) = owner.presentation.mode else { return false }
                return soundsAICueGenerationIsAllowed(
                    sounds: sounds,
                    library: owner.presentation.library,
                    session: AICueComposerSession(packID: packID, event: .stop),
                    event: .stop)
            }

            guard case .sounds(let sounds) = owner.presentation.mode else {
                expect(false, "损坏配置仍需显示声音页")
                return
            }
            expect(
                sounds.scope == .unavailable(scope: .global, reason: .scopeUnavailable),
                "测试必须先证明配置写入已被停止")
            expect(sounds.selectedPack?.id == "healthy-pack", "测试必须选中健康用户包")
            expect(
                canGenerate("healthy-pack"),
                "配置损坏只应阻止作用域写入，不应阻止健康包的联网生成")

            expect(owner.beginAICuePackDraft(language: .english), "损坏配置仍可建立未发布草稿")
            guard case .sounds(let draftSounds) = owner.presentation.mode,
                let draft = draftSounds.draft
            else {
                expect(false, "必须投影未发布草稿")
                return
            }
            expect(
                canGenerate(draft.packID),
                "配置损坏不应阻止未发布草稿的首音生成")
        }
    }

    await suite("声音页包级生成：Surface 写入目标损坏仍可编辑独立健康包") {
        await withTempDirectory { root in
            let invalidSurfaceConfig =
                #"{"selected_pack":"healthy-pack","surface_overrides":{"workbuddy":7}}"#
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["healthy-pack"],
                configJSON: invalidSurfaceConfig)
            let owner = fixture.owner
            _ = owner.send(
                .activate(
                    .sounds(
                        route: .overview(surface: .workBuddy),
                        requestRevision: 1)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let sounds) = owner.presentation.mode else {
                expect(false, "损坏 Surface 仍需显示声音页")
                return
            }
            let blockedScope: SoundPackEditorScopeAvailability = .unavailable(
                scope: .surface(.workBuddy), reason: .scopeUnavailable)
            expect(
                sounds.scope == blockedScope,
                "测试必须先证明此 Surface 的配置写入已被停止")
            expect(
                sounds.selectedPack?.id == "healthy-pack",
                "测试必须仍选中健康用户包")
            expect(
                soundsAICueGenerationIsAllowed(
                    sounds: sounds,
                    library: owner.presentation.library,
                    session: AICueComposerSession(packID: "healthy-pack", event: .stop),
                    event: .stop),
                "损坏 Surface 的配置写入门不得阻断包级联网生成")
        }
    }

    await suite("AI 提示音草稿：关闭发生在导入末尾后仍不得发布") {
        await withTempDirectory { root in
            let gate = SoundEditorPostSampleGate()
            defer { gate.release() }
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["existing-pack"],
                afterFinalImportCancellationSampleForTesting: { gate.pauseWorker() })
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 1)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard owner.beginAICuePackDraft(language: .english),
                case .sounds(let sounds) = owner.presentation.mode,
                let draft = sounds.draft
            else {
                expect(false, "测试需要未发布草稿")
                return
            }
            let source = root.appendingPathComponent("candidate.mp3")
            writeFixture(validMP3ID3Data(), to: source)
            let generationID = UUID()
            let candidate = AICueCandidate(
                id: UUID(),
                variant: .clear,
                asset: AICueTemporaryAudioAsset(
                    fileURL: source,
                    byteCount: validMP3ID3Data().count,
                    sniffedFormat: .mp3),
                durationMilliseconds: 1_000,
                mediaType: "audio/mpeg",
                provenance: AICueCandidateProvenance(
                    providerID: .elevenLabs,
                    profileID: .elevenLabsGlobal,
                    modelID: "eleven_text_to_sound_v2",
                    generationID: generationID,
                    requestOrdinal: 1,
                    providerRequestID: nil))
            let generation = AICueGeneration(
                id: generationID,
                profileID: .elevenLabsGlobal,
                plan: AICueSoundPlan(
                    suggestedDisplayName: "完成",
                    modality: .soundEffect,
                    soundDescription: "短促完成音",
                    spokenContent: nil,
                    languageTag: nil,
                    styleDescription: "清晰",
                    targetDurationMilliseconds: 1_000,
                    instructionVersion: AICueSoundPlanner.instructionVersion),
                candidates: [candidate],
                generatedAt: Date(timeIntervalSince1970: 1))
            owner.updateAICueComposer(
                session: AICueComposerSession(packID: draft.packID, event: .stop),
                generation: generation)
            guard case .sounds(let ready) = owner.presentation.mode,
                let permit = ready.eventRows.first(where: { $0.event == .stop })?
                    .aiCueAdoptionPermit
            else {
                expect(false, "草稿候选必须签发采纳许可")
                return
            }
            let task = Task { @MainActor in
                await owner.perform(
                    .adoptAICue(
                        candidate: candidate,
                        displayName: try! AICueDisplayName("完成"),
                        permit: permit))
            }
            guard await gate.waitUntilEntered() else {
                gate.release()
                _ = await task.value
                expect(false, "导入必须到达末尾暂停点")
                return
            }
            owner.cancelAICuePackDraft()
            owner.updateAICueComposer(session: nil, generation: nil)
            _ = owner.send(.activate(.inactive))
            gate.release()
            let result = await task.value
            expect(
                result == .rejected(.targetChanged) || result == .rejected(.cancelled),
                "关闭后的草稿采纳必须拒绝")
            expect(
                !FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("packs/\(draft.packID)").path),
                "关闭后不可发布可选用户包")
            let entries =
                (try? FileManager.default.contentsOfDirectory(
                    atPath: root.appendingPathComponent("packs").path)) ?? []
            expect(
                !entries.contains(where: { $0.hasPrefix(".\(draft.packID).tmp-") }),
                "拒绝发布后必须清理隐藏暂存目录")
        }
    }
}
