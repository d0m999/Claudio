import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
func runSoundPacksWindowAccessibilitySuites() {
    suite("SoundPacksWindow a11y：焦点序跟随视觉序，空态/陈旧选择不制造死焦点") {
        let populated = SoundPacksWindowFocusScope(
            packIDs: ["pack-a", "pack-b"],
            selectedPackID: "pack-b")
        expect(
            soundPacksWindowFocusOrder(populated) == [.packList, .revealSelectedPack],
            "有选择时必须先到左侧原生列表，再到右侧 Finder 按钮")
        expect(
            soundPacksWindowFirstFocusTarget(populated) == .packList,
            "窗口打开必须落在第一个可操作的列表，而不是跳过侧栏")

        expect(
            soundPacksWindowFocusOrder(
                SoundPacksWindowFocusScope(packIDs: [], selectedPackID: nil)
            ).isEmpty,
            "空列表不是可操作项，不得成为死焦点")
        let retryOnly = SoundPacksWindowFocusScope(
            packIDs: [],
            selectedPackID: nil,
            retryFactoryRestorePackIDs: ["missing-a", "missing-b"])
        expect(
            soundPacksWindowFocusOrder(retryOnly)
                == [
                    .retryFactoryRestore(packID: "missing-a"),
                    .retryFactoryRestore(packID: "missing-b"),
                ]
                && soundPacksWindowFirstFocusTarget(retryOnly)
                    == .retryFactoryRestore(packID: "missing-a"),
            "发布失败移除最后一个或多个包时，每个窗口级重试都必须是可区分的可达焦点")
        expect(
            soundPacksWindowFocusOrder(
                SoundPacksWindowFocusScope(
                    packIDs: ["pack-a"],
                    selectedPackID: "stale-pack")
            ) == [.packList],
            "陈旧选择没有详情按钮，只能留下真实存在的列表停靠点")
    }

    suite("SoundPacksWindow a11y：Dynamic Type 降级梯在辅助功能字号改为上下分区且不截名") {
        let standard = soundPacksWindowLayoutAdaptation(for: .standard)
        let enlarged = soundPacksWindowLayoutAdaptation(for: .enlarged)
        let accessibility = soundPacksWindowLayoutAdaptation(for: .accessibility)

        expect(!standard.stacksPrimaryRegions, "标准字号必须保留设计规定的左右窗口结构")
        expect(!standard.stacksDetailHeader, "标准字号的标题与 Finder 动作应同排")
        expect(standard.packNameLineLimit == 1, "标准字号可使用单行包名")

        expect(!enlarged.stacksPrimaryRegions, "较大字号仍可保留左右主结构")
        expect(
            enlarged.stacksDetailHeader && enlarged.stacksEventRows,
            "较大字号必须先把详情头与映射行拆成上下结构")
        expect(
            enlarged.sidebarIdealWidth > standard.sidebarIdealWidth,
            "较大字号的侧栏必须获得更多宽度")
        expect(
            enlarged.sidebarMinimumWidth + enlarged.detailMinimumWidth <= 560,
            "较大字号在窗口最小 560pt 宽度下不得声明一组互相挤不下的最小宽度")
        expect(
            enlarged.packNameLineLimit == nil,
            "较大字号不得再用固定行数截断第三方包名")

        expect(
            accessibility.stacksPrimaryRegions
                && accessibility.stacksDetailHeader
                && accessibility.stacksEventRows,
            "辅助功能字号必须把两大区、详情头、映射行全部改为上下结构")
        expect(
            accessibility.packNameLineLimit == nil,
            "辅助功能字号不得用 lineLimit 截断第三方包名")
        expect(
            accessibility.sidebarMinimumHeight >= 160,
            "上下结构中的列表必须仍有可用高度并允许内部滚动")
    }

    suite("SoundPacksWindow a11y：每次真实 hidden→visible 都能发出独立首焦点请求") {
        let coordinator = SoundPacksWindowFocusCoordinator()
        expect(coordinator.requestRevision == 0, "焦点请求 revision 必须从 0 开始")
        coordinator.requestInitialFocus()
        expect(coordinator.requestRevision == 1, "第一次展示必须产生一次独立焦点请求")
        coordinator.requestInitialFocus()
        expect(coordinator.requestRevision == 2, "隐藏后复用窗口重开也必须产生新请求")
    }

    suite("SoundPacksWindow a11y：包级动作栏、空态 CTA 与视觉顺序完全一致") {
        let builtin = SoundPacksWindowFocusScope(
            packIDs: ["builtin"],
            selectedPackID: "builtin",
            canForkFactoryPack: true,
            canRestoreFactoryPack: true,
            canUseSelectedPack: true)
        expect(
            soundPacksWindowFocusOrder(builtin)
                == [
                    .packList, .revealSelectedPack, .forkFactoryPack,
                    .restoreFactoryPack, .useSelectedPack,
                ],
            "built-in 焦点必须按列表→Finder→复制→恢复→启用")

        let custom = SoundPacksWindowFocusScope(
            packIDs: ["custom"],
            selectedPackID: "custom",
            editableEvents: [.stop],
            orphanFileNames: ["spare.wav"],
            canEditSelectedPack: true,
            canAddAudio: true,
            canUseSelectedPack: true)
        expect(
            soundPacksWindowFocusOrder(custom)
                == [
                    .packList, .revealSelectedPack, .eventAudio(.stop),
                    .orphanAssignment(fileName: "spare.wav"),
                    .orphanDeletion(fileName: "spare.wav"),
                    .addAudio, .useSelectedPack,
                ],
            "custom 焦点必须按列表→Finder→事件/孤儿控件→底部添加/启用动作栏")

        expect(
            soundPacksWindowFocusOrder(
                SoundPacksWindowFocusScope(
                    packIDs: [], selectedPackID: nil,
                    canRestoreAllFactoryPacks: true)) == [.restoreAllFactoryPacks],
            "factory 可用的零包空态必须有唯一恢复 CTA")
        expect(
            soundPacksWindowFocusOrder(
                SoundPacksWindowFocusScope(
                    packIDs: [], selectedPackID: nil,
                    canRevealPacksDirectory: true)) == [.revealPacksDirectory],
            "factory 不可用的零包空态必须有唯一 Finder CTA")
    }

    suite("SoundPacksWindow a11y：T11 编辑控件按视觉序进入窗口自己的焦点序，内置包不产生活控件") {
        let editable = SoundPacksWindowFocusScope(
            packIDs: ["my-pack"],
            selectedPackID: "my-pack",
            editableEvents: [.stop, .notification],
            orphanFileNames: ["a.mp3"],
            canEditSelectedPack: true)
        expect(
            soundPacksWindowFocusOrder(editable)
                == [
                    .packList,
                    .revealSelectedPack,
                    .eventAudio(.stop),
                    .eventAudio(.notification),
                    .orphanAssignment(fileName: "a.mp3"),
                    .orphanDeletion(fileName: "a.mp3"),
                ],
            "焦点必须按列表→详情头→事件菜单→孤儿分配/删除的视觉顺序")

        let builtin = SoundPacksWindowFocusScope(
            packIDs: ["builtin"],
            selectedPackID: "builtin",
            editableEvents: Event.allCases,
            orphanFileNames: ["spare.mp3"],
            canEditSelectedPack: false)
        expect(
            soundPacksWindowFocusOrder(builtin) == [.packList, .revealSelectedPack],
            "内置包只读时不得为隐藏/禁用的编辑动作制造死焦点")
    }

    suite("SoundPacksWindow a11y：T12 恢复出厂是内置包独有的真焦点，位于 Finder 动作之后") {
        let builtin = SoundPacksWindowFocusScope(
            packIDs: ["minimal-chime"],
            selectedPackID: "minimal-chime",
            canRestoreFactoryPack: true)
        expect(
            soundPacksWindowFocusOrder(builtin)
                == [.packList, .revealSelectedPack, .restoreFactoryPack],
            "内置包焦点序必须是列表→Finder→恢复出厂，不能隐藏恢复按钮或制造死焦点")

        let custom = SoundPacksWindowFocusScope(
            packIDs: ["my-pack"],
            selectedPackID: "my-pack",
            canRestoreFactoryPack: false)
        expect(
            !soundPacksWindowFocusOrder(custom).contains(.restoreFactoryPack),
            "个人包没有恢复出厂动作，不得出现幽灵焦点")

        let fallbackWithRetry = SoundPacksWindowFocusScope(
            packIDs: ["my-pack"],
            selectedPackID: "my-pack",
            retryFactoryRestorePackIDs: ["minimal-chime"])
        expect(
            soundPacksWindowFocusOrder(fallbackWithRetry)
                == [
                    .packList,
                    .retryFactoryRestore(packID: "minimal-chime"),
                    .revealSelectedPack,
                ],
            "原内置包消失并落到 fallback 时，焦点必须按列表→窗口级重试→所选包详情排列")
    }

    suite("SoundPacksWindow a11y：包行 Name/Value 区分当前、残缺、损坏与 license") {
        let partial = soundPacksWindowPackAccessibilityLabel(
            displayName: "我的包",
            isActivePack: true,
            state: .partial(present: 2, total: 4),
            license: .cc0)
        expect(partial.contains("我的包"), "包名必须进入 VoiceOver Name，实得 \(partial)")
        expect(partial.contains("当前正在使用"), "active pack 状态不能只靠勾号，实得 \(partial)")
        expect(partial.contains("2/4") && partial.contains("缺 2 个"), "残缺数必须可辨，实得 \(partial)")
        expect(partial.contains("CC0"), "license 必须可辨，实得 \(partial)")

        let broken = soundPacksWindowPackAccessibilityLabel(
            displayName: "坏包",
            isActivePack: false,
            state: .broken(reason: "manifest.json 无法读取"),
            license: .none)
        expect(
            broken.contains("声音包不可用") && broken.contains("manifest.json 无法读取"),
            "损坏包必须报错误性质与原因，不能只靠颜色，实得 \(broken)")

        let modified = soundPacksWindowPackAccessibilityLabel(
            displayName: "内置包",
            isActivePack: false,
            state: .complete,
            license: .modified)
        expect(
            modified.contains("内置包已被修改") && !modified.contains("CC0"),
            "modified 优先级必须与可见 license 槽一致，实得 \(modified)")
    }

    suite("SoundPacksWindow a11y：四条映射的 present/unmapped/broken 与静音轴逐字可辨") {
        let present = soundPacksWindowEventAccessibilityLabel(
            eventName: "stop",
            coverage: .present(fileName: "stop.wav"),
            enabled: true)
        expect(
            present == "stop，声音 stop.wav，已启用",
            "present 行必须报事件、文件与启用态，实得 \(present)")

        let unmapped = soundPacksWindowEventAccessibilityLabel(
            eventName: "notification",
            coverage: .unmapped,
            enabled: false)
        expect(
            unmapped == "notification，未配置声音，已静音",
            "unmapped 不能冒充错误，且静音轴必须保留，实得 \(unmapped)")

        let broken = soundPacksWindowEventAccessibilityLabel(
            eventName: "subagent_stop",
            coverage: .broken(fileName: "gone.wav"),
            enabled: true)
        expect(
            broken.contains("错误") && broken.contains("声音文件 gone.wav 丢失"),
            "broken 必须明确报错与失败文件，不能只靠次级色，实得 \(broken)")
    }

    suite("SoundPacksWindow a11y：窗口/选择/失败播报由窗口自己的策略完整成句") {
        let opened = soundPacksWindowAnnouncement(
            .windowOpened,
            facts: SoundPacksWindowAnnouncementFacts(
                packCount: 2,
                selectedPackName: "我的包"))
        expect(
            opened == "声音包管理窗口。共 2 个声音包。正在检查「我的包」。",
            "打开播报必须交代窗口、数量与检查对象，实得 \(opened)")

        let empty = soundPacksWindowAnnouncement(
            .windowOpened,
            facts: SoundPacksWindowAnnouncementFacts(
                packCount: 0,
                selectedPackName: nil))
        expect(
            empty == "声音包管理窗口。没有可管理的声音包。",
            "空态打开播报必须诚实，实得 \(empty)")

        let selection = soundPacksWindowAnnouncement(
            .selectionChanged,
            facts: SoundPacksWindowAnnouncementFacts(
                packCount: 2,
                selectedPackName: "另一个包"))
        expect(
            selection == "正在检查「另一个包」。",
            "列表选择变化必须报新检查对象，实得 \(selection)")

        let failure = soundPacksWindowAnnouncement(
            .writeFailed(action: "用这个包", reason: "config.json 没有写权限"),
            facts: SoundPacksWindowAnnouncementFacts(
                packCount: 2,
                selectedPackName: "另一个包"))
        expect(
            failure == "用这个包失败：config.json 没有写权限",
            "未来窗口写失败行必须把动作与可执行原因一起播报，实得 \(failure)")

        let restoreNotice =
            "「minimal-chime」已恢复为出厂版本。恢复前的内容已原样搬到 "
            + "/tmp/.minimal-chime.pre-restore-42；一个文件都没删。"
        let success = soundPacksWindowAnnouncement(
            .writeSucceeded(message: restoreNotice),
            facts: SoundPacksWindowAnnouncementFacts(
                packCount: 2,
                selectedPackName: "极简铃音"))
        expect(
            success == restoreNotice,
            "恢复成功的 VoiceOver 播报必须逐字复用可见 salvage 路径告知，不能另写一份会漂移的文案")
    }

    suite("SoundPacksWindow a11y：新窗口 target 不得耦合任何面板专用 a11y 类型") {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sourcesRoot = root.appendingPathComponent("gui/Sources/SoundPacksWindow")
        guard let walker = FileManager.default.enumerator(atPath: sourcesRoot.path) else {
            expect(false, "读不到 SoundPacksWindow target")
            return
        }

        var scannedSources: [(name: String, code: String)] = []
        let coreAccessibilityURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUICore/SoundPacksWindowAccessibility.swift")
        if let data = try? Data(contentsOf: coreAccessibilityURL),
            let source = String(data: data, encoding: .utf8)
        {
            scannedSources.append(
                (name: "ClaudioGUICore/SoundPacksWindowAccessibility.swift",
                 code: strippingComments(source).code))
        } else {
            expect(false, "读不到窗口专用的 Core a11y 设施")
        }

        var forbiddenSites: [String] = []
        var announcementPosts = 0
        for case let name as String in walker where name.hasSuffix(".swift") {
            let url = sourcesRoot.appendingPathComponent(name)
            guard
                let data = try? Data(contentsOf: url),
                let source = String(data: data, encoding: .utf8)
            else {
                forbiddenSites.append("\(name): unreadable")
                continue
            }
            let code = strippingComments(source).code
            scannedSources.append((name: "SoundPacksWindow/\(name)", code: code))
            announcementPosts +=
                code.components(separatedBy: "NSAccessibility.post").count - 1
        }

        for source in scannedSources {
            for forbidden in [
                "PanelFocusTarget",
                "PanelLayoutAdaptation",
                "PanelAnnouncement",
            ] where source.code.contains(forbidden) {
                forbiddenSites.append("\(source.name): \(forbidden)")
            }
        }

        expect(
            scannedSources.count >= 4,
            "应覆盖 Core a11y 设施及窗口 target 的 controller、view、bridge")
        expect(
            forbiddenSites.isEmpty,
            "窗口不得编译耦合面板专用 a11y 类型，实得 \(forbiddenSites)")
        expect(
            announcementPosts == 1,
            "窗口播报必须收口到自己的唯一 bridge，实得 \(announcementPosts) 处")

        let sourceByName = Dictionary(
            uniqueKeysWithValues: scannedSources.map { ($0.name, $0.code) })
        guard
            let view = sourceByName["SoundPacksWindow/SoundPacksWindowView.swift"],
            let controller = sourceByName[
                "SoundPacksWindow/SoundPacksWindowController.swift"],
            let bridge = sourceByName[
                "SoundPacksWindow/SoundPacksWindowAccessibilityBridge.swift"]
        else {
            expect(false, "窗口 a11y 接线检查缺少 view、controller 或 bridge")
            return
        }

        expect(
            view.contains(".focusable(!model.packCards.isEmpty)")
                && view.contains(".focused($focusedTarget, equals: .packList)")
                && view.contains(".focused($focusedTarget, equals: .revealSelectedPack)"),
            "纯焦点序必须绑到列表与 Finder 真控件，空列表必须明确不可聚焦")
        expect(
            view.contains("soundPacksWindowFocusOrder(focusScope)")
                && view.contains("soundPacksWindowFirstFocusTarget(focusScope)"),
            "首焦点与状态变化后的焦点修复必须消费同一套窗口纯模型")
        expect(
            view.contains("@Environment(\\.dynamicTypeSize)")
                && view.contains("layoutAdaptation.detailMinimumWidth")
                && view.contains("layoutAdaptation.packNameLineLimit"),
            "Dynamic Type 环境值必须实际驱动详情最小宽度与包名截断策略")
        expect(
            view.contains(".frame(minHeight: 44)")
                && view.contains(".accessibilityLabel(packAccessibilityLabel(card))")
                && view.contains("soundPacksWindowEventAccessibilityLabel("),
            "44pt 目标、包行状态与事件失败状态必须真正接进窗口视图")

        guard
            let responderIndex = controller.range(of: "makeFirstResponder")?.lowerBound,
            let focusIndex = controller.range(of: "requestInitialFocus()")?.lowerBound
        else {
            expect(false, "窗口展示必须先进入 responder chain，再请求 SwiftUI 首焦点")
            return
        }
        expect(
            responderIndex < focusIndex,
            "窗口展示必须先进入 responder chain，再请求 SwiftUI 首焦点")
        expect(
            bridge.contains("DispatchQueue.main.async")
                && bridge.contains("window.isKeyWindow")
                && bridge.contains("NSAccessibility.post"),
            "播报必须延后一趟等窗口进入 AX 树，并在真正 post 前重新确认仍是 key window")
        expect(
            controller.contains("model.$windowStatuses")
                && controller.contains("status.severity == .failure")
                && controller.contains(".writeSucceeded(message: status.message)"),
            "恢复、音频、星标、复制和启用必须共用一个 revision 驱动的 VoiceOver 出口")
        expect(
            controller.contains("public func windowDidBecomeKey")
                && controller.contains("announceLatestWindowStatusIfNeeded(in: keyWindow)")
                && controller.contains("status.revision > lastAnnouncedStatusRevision"),
            "窗口非 key 期间完成的全局结果必须在重新成为 key 时补播且 revision 去重")
    }
}
