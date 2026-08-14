import Foundation

private func integrationsRepositoryRoot(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent()  // ClaudioGUICoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // gui
        .deletingLastPathComponent()  // repository root
}

private func integrationsSource(
    _ relativePath: String,
    file: StaticString = #filePath
) -> String? {
    try? String(
        contentsOf: integrationsRepositoryRoot(file: file).appendingPathComponent(relativePath),
        encoding: .utf8)
}

@MainActor
func runIntegrationsWindowWiringSuites() {
    suite("IntegrationsWindow controller：窗口 retained、重复 show 复用，关闭后只还一次触发控件焦点") {
        guard
            let controller = integrationsSource(
                "gui/Sources/ClaudioGUI/IntegrationsWindowController.swift")
        else {
            expect(false, "缺少 IntegrationsWindowController.swift")
            return
        }

        expect(controller.contains("private var window: NSWindow?"), "controller 必须持有唯一窗口")
        expect(controller.contains("window ?? makeWindow()"), "重复 show 必须复用 retained NSWindow")
        expect(
            controller.contains("window.isReleasedWhenClosed = false"),
            "close 后窗口不得释放，否则不能 retained reopen")
        expect(controller.contains("window.delegate = self"), "controller 必须接管关闭生命周期")
        expect(
            controller.contains("func showWindow(")
                && controller.contains("returnFocusTo restoration:"),
            "show API 必须接收恢复触发控件焦点的 seam")
        expect(
            controller.contains("focusRestoration = nil")
                && controller.contains("windowWillClose"),
            "close 必须先清空再调用焦点恢复，防止 retained reopen 重复偿还旧焦点")
        expect(
            controller.contains("focusCoordinator.requestInitialFocus()"),
            "首次展示和隐藏后重开必须向窗口自己的 FocusState 发新请求")
        expect(
            controller.contains("func restoreKeyWindow() -> Bool")
                && controller.contains("guard let window, window.isVisible else { return false }")
                && controller.contains("return true"),
            "跨窗口恢复必须只在集成窗口仍可见时报告成功")
        expect(
            controller.contains("width: 840, height: 620")
                && controller.contains("width: 640, height: 520"),
            "集成窗口默认必须是 840×620，且最小保持 640×520")
    }

    suite("MenuBar shell：唯一 retained IntegrationsWindow，经 popover close 交接并精确恢复触发控件") {
        guard
            let menu = integrationsSource("gui/Sources/ClaudioGUI/MenuBarController.swift"),
            let panel = integrationsSource("gui/Sources/ClaudioGUI/PanelView.swift")
        else {
            expect(false, "缺少 MenuBarController/PanelView")
            return
        }

        expect(
            menu.contains("private let integrationsWindowController: IntegrationsWindowController"),
            "MenuBarController 必须 app-lifetime 持有唯一详情窗 controller")
        expect(
            menu.components(separatedBy: "let integrationsWindowController = IntegrationsWindowController(").count - 1 == 1
                && menu.contains("model: integrationsModel")
                && menu.contains("languageStore: languageStore"),
            "IntegrationsWindowController 只能初始化一次")
        expect(
            panel.contains("HostSourceRowView(")
                && panel.contains("onManageIntegrations(.hostSource(row.host))")
                && !panel.contains("manageIntegrationsRow"),
            "两条宿主状态条必须把精确触发 target 交给 AppKit shell，且不保留重复底部入口")
        expect(
            menu.contains("pendingIntegrationsWindowFocusTarget")
                && menu.contains("popoverDidClose")
                && menu.contains(
                    "integrationsWindowController.showWindow { [weak self] latestHandbackApplication in"),
            "详情窗必须在 popoverDidClose 后展示，不能与 transient close 竞态")
        expect(
            menu.contains("restorePanelFocus(")
                && menu.contains("latestHandbackApplication: latestHandbackApplication")
                && menu.contains("focusCoordinator.requestFocus(target: restoredTarget)"),
            "关闭详情窗必须重开面板并恢复原始宿主行/管理入口")

        guard let integrationBranch = menu.range(of: "if let integrationsFocusTarget") else {
            expect(false, "找不到 integrations handoff 分支")
            return
        }
        let suffix = String(menu[integrationBranch.lowerBound...])
        let branchBeforeSoundPacks = String(
            suffix.prefix(
                upTo: suffix.range(of: "let soundPacksPresentation")?.lowerBound
                    ?? suffix.endIndex))
        expect(
            !branchBeforeSoundPacks.contains("previousApp = nil"),
            "integrations handoff 不得提前清 activation debt；要等恢复后的 popover 正常关闭")
    }

    suite("IntegrationsWindow handback：可见期间跟踪最近外部 app，关闭后交回 MenuBar 的原债务槽") {
        guard
            let controllerSource = integrationsSource(
                "gui/Sources/ClaudioGUI/IntegrationsWindowController.swift"),
            let menuSource = integrationsSource("gui/Sources/ClaudioGUI/MenuBarController.swift")
        else {
            expect(false, "缺少 IntegrationsWindowController/MenuBarController")
            return
        }
        let controller = collapsingWhitespace(
            strippingComments(controllerSource).codeWithoutStringLiterals)
        let menu = collapsingWhitespace(strippingComments(menuSource).codeWithoutStringLiterals)

        expect(
            controller.contains("RetainedWindowHandbackTracker<NSRunningApplication>()")
                && controller.contains("NSWorkspace.didActivateApplicationNotification")
                && controller.contains(".sink { [weak self]"),
            "retained integrations window 必须弱订阅外部 activation，并把状态交给可行为测试的 tracker")
        expect(
            controller.contains("handbackTracker.noteExternalActivation(")
                && controller.contains("isWindowVisible: self.window?.isVisible == true")
                && controller.contains("ProcessInfo.processInfo.processIdentifier"),
            "activation 输入必须携带真实可见性并排除 Claudio 自己，不能在隐藏/自激活时污染 handback")
        expect(
            controller.contains("if !wasVisible { handbackTracker.beginPresentation() }")
                && controller.contains("handbackTracker.consumeOnClose()")
                && controller.contains("restoration?(handbackApplication)"),
            "hidden→visible 才能开新代次，close 必须一次性消费最近 app 并随焦点恢复闭包交回")
        expect(
            menu.contains("if let latestHandbackApplication {")
                && menu.contains("previousApp = latestHandbackApplication"),
            "MenuBar 必须只在窗口确实观察到新外部 app 时覆盖原 previousApp；nil 时保留最初来源")
        expect(
            !controller.contains("latestHandbackApplication.activate(")
                && !controller.contains("handbackApplication.activate("),
            "详情窗关闭时不得直接激活外部 app；先恢复 popover，等它正常关闭后再偿还 handback")
    }

    suite("MenuBar shell：点宿主行先选中对应详情，管理入口保留现有选择") {
        guard let menu = integrationsSource("gui/Sources/ClaudioGUI/MenuBarController.swift") else {
            expect(false, "缺少 MenuBarController.swift")
            return
        }
        guard
            let start = menu.range(of: "fileprivate func requestIntegrationsWindowPresentation")?
                .lowerBound,
            let end = menu.range(of: "private func restorePanelFocus")?.lowerBound,
            start < end
        else {
            expect(false, "无法定位 integrations handoff 函数")
            return
        }
        let handoff = String(menu[start..<end])
        let normalized = handoff.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        expect(
            normalized.contains(
                "if case .hostSource(let host) = target { integrationsModel.select(.host(host)) }"),
            "宿主行触发必须在关 popover 前把 retained window 选到对应宿主")
        expect(
            handoff.components(separatedBy: "integrationsModel.select(").count - 1 == 1,
            "handoff 里只允许 hostSource 分支改选择；底部管理入口必须保留现有 inspector")
    }

    suite("Retained IntegrationsWindow：后台/bootstrap/popover 刷新同时替换 store 与已保留 model") {
        guard
            let menu = integrationsSource("gui/Sources/ClaudioGUI/MenuBarController.swift"),
            let model = integrationsSource("gui/Sources/ClaudioGUI/IntegrationsWindowModel.swift"),
            let store = integrationsSource(
                "gui/Sources/ClaudioGUI/HostIntegrationPresentationStore.swift")
        else {
            expect(false, "缺少 MenuBarController/IntegrationsWindowModel/presentation store")
            return
        }
        expect(
            menu.contains("private let integrationsModel: IntegrationsWindowModel")
                && menu.contains("self.integrationsModel = integrationsModel")
                && menu.contains("let integrationsWindowController = IntegrationsWindowController(")
                && menu.contains("model: integrationsModel")
                && menu.contains("languageStore: languageStore"),
            "MenuBarController 必须与 retained controller 共享同一个 model 实例")
        expect(
            menu.contains("let content = self.hostIntegrations.replace(state: state)")
                && menu.contains("self.integrationsModel.replaceExternalContent(content)"),
            "manager 后台刷新必须先投影共享 store，再同步 retained model")
        expect(
            model.contains("func replaceExternalContent(")
                && model.contains("replaceContent(replacement)"),
            "retained model 必须有显式外部替换 seam，不能只在窗口按钮动作后更新")
        expect(
            model.contains("integrationsReceiptTransitions(from: content, to: replacement)")
                && model.contains("presentFeedbackSequence(")
                && model.contains("key: .feedbackReceipt")
                && model.contains("stateChangeAccessibilityText("),
            "外部刷新同帧发现多个当前代次回执时必须逐条生成短暂可关闭反馈")
        expect(
            store.contains(
                "latestReceiptEvidence: snapshots[row.host].flatMap(hostLatestReceiptEvidence)")
                && model.contains("receiptTransitions.map")
                && model.contains("receiptTransition.event")
                && model.contains("currentFacts.latestReceiptEvidence")
                && model.contains("newEvidence != oldEvidence")
                && model.contains("stateChangeAccessibilityText(")
                && model.contains("capabilityCells:")
                && model.contains("selectedCapabilityEvent(for: host)"),
            "真实回执/refresh 主动播报必须从共享 host row 与 matrix cell 组合完整上下文")
    }

    suite("Panel 双宿主来源行：与其余面板控件共用 Dynamic Type scale") {
        guard let panel = integrationsSource("gui/Sources/ClaudioGUI/PanelView.swift") else {
            expect(false, "缺少 PanelView.swift")
            return
        }
        expect(
            panel.contains("HostSourceRowView(")
                && panel.contains("typeScale: typeScale")
                && panel.contains("let typeScale: CGFloat"),
            "两条来源行必须接收 Panel 的 @ScaledMetric，而不是固定字号孤岛")
        expect(
            panel.contains("size: 11.5 * typeScale")
                && panel.contains("size: 9.5 * typeScale")
                && panel.contains("minHeight: 48 * typeScale"),
            "来源行标题、状态与几何必须一起随最大 Dynamic Type 放大")
    }

    suite("IntegrationsWindow action outcome：除 copy 外成功/失败都注入刷新后的完整播报上下文") {
        guard let model = integrationsSource(
            "gui/Sources/ClaudioGUI/IntegrationsWindowModel.swift")
        else {
            expect(false, "缺少 IntegrationsWindowModel.swift")
            return
        }
        guard
            let start = model.range(of: "func perform(_ action:")?.lowerBound,
            let end = model.range(of: "func dismissFeedback(revision:")?.lowerBound,
            start < end
        else {
            expect(false, "无法定位 IntegrationsWindowModel.perform")
            return
        }
        let performBody = String(model[start..<end])
        expect(
            !performBody.contains("accessibilityAnnouncement: action == .redetect"),
            "connect/repair/disconnect outcome 不得继续回落成 host + 短 message")
        expect(
            performBody.contains("in: outcome.content")
                && performBody.contains("event: selectedCapabilityEvent(for: host)"),
            "所有成功 outcome 必须从刷新后的 content 与当前选择组合完整播报")

        guard
            let catchStart = performBody.range(of: "} catch {")?.lowerBound,
            catchStart < performBody.endIndex
        else {
            expect(false, "无法定位 perform catch")
            return
        }
        let catchBody = String(performBody[catchStart...])
        expect(
            catchBody.contains("stateChangeAccessibilityText(")
                && catchBody.contains("in: content")
                && catchBody.contains("event: selectedCapabilityEvent(for: host)"),
            "失败 catch 也必须从当前共享 content 补齐事件、连接状态和 qualification")

        let copyBody = String(
            performBody.prefix(
                upTo: performBody.range(of: "let hostStatus")?.lowerBound
                    ?? performBody.endIndex))
        expect(
            !copyBody.contains("stateChangeAccessibilityAnnouncement("),
            "copy /hooks 不是连接状态变化，保持短同步反馈即可")
    }

    suite("MenuBar shell：SoundPacks 已验证的 close-before-show 与前台 app handback 保持不变") {
        guard let menu = integrationsSource("gui/Sources/ClaudioGUI/MenuBarController.swift") else {
            expect(false, "缺少 MenuBarController")
            return
        }
        expect(
            menu.contains("pendingSoundPacksWindowPresentation = (route, target)")
                && menu.contains("route: soundPacksPresentation.route")
                && menu.contains("returnFocusTo: previous"),
            "新增 integrations handoff 不得破坏 SoundPacks 的 pending 与 activation handback")
        expect(menu.contains("popover.close()"), "两个管理窗口都必须先可靠关闭 transient popover")
    }

    suite("App 默认事实：明确构造两条 disconnected snapshot，禁止伪造 connected") {
        guard let app = integrationsSource("gui/Sources/ClaudioGUI/ClaudioGUIApp.swift") else {
            expect(false, "缺少 ClaudioGUIApp.swift")
            return
        }
        expect(
            app.contains("let disconnectedSnapshots = HostID.allCases.map")
                && app.contains("HostIntegrationSnapshot.disconnected(host: $0)")
                && app.contains("AudibilityMatrix.make("),
            "默认 shell 必须从两个明确 disconnected snapshot 生成矩阵")
        expect(
            !app.contains("connectedForTesting"),
            "production AppDelegate 绝不能为展示效果伪造 connected")
    }

    suite("原生 host-card probe：发布构建不受测试环境变量影响") {
        guard
            let app = integrationsSource("gui/Sources/ClaudioGUI/ClaudioGUIApp.swift"),
            let bundle = integrationsSource("scripts/dev-bundle.sh"),
            let probe = integrationsSource("scripts/test-host-card-height.sh")
        else {
            expect(false, "缺少 ClaudioGUIApp.swift 或原生 probe 脚本")
            return
        }

        expect(
            app.contains(
                "#if CLAUDIO_NATIVE_HOST_CARD_PROBE\n"
                    + "        let nativeProbeState = nativeHostCardProbeState()\n"
                    + "#else\n"
                    + "        let nativeProbeState: HostIntegrationPresentationState? = nil\n"
                    + "#endif"),
            "production 编译分支必须明确关闭 native host-card 状态注入")
        expect(
            app.contains("#if CLAUDIO_NATIVE_HOST_CARD_PROBE\n/// Fixed, side-effect-free state")
                && app.contains("ProcessInfo.processInfo.environment[\"CLAUDIO_TEST_HOST_CARD_STATE\"]"),
            "测试环境变量的读取必须只存在于专用 probe 编译分支")
        expect(
            bundle.contains("GUI_NATIVE_HOST_CARD_PROBE=true")
                && bundle.contains(
                    "-Xswiftc -DCLAUDIO_NATIVE_HOST_CARD_PROBE")
                && bundle.contains("usage: $0 [--native-host-card-probe]"),
            "probe 宏必须只能通过显式的专用 dev-bundle 参数开启")
        expect(
            probe.contains("bash scripts/dev-bundle.sh --native-host-card-probe"),
            "原生布局脚本必须构建 probe 变体，而不是让普通发布 bundle 响应环境变量")
    }

    suite("host-card probe 脚本：快照未完成时 EXIT trap 不得删除用户 defaults") {
        guard let script = integrationsSource("scripts/test-host-card-height.sh") else {
            expect(false, "缺少 test-host-card-height.sh")
            return
        }

        guard
            let restoreStart = script.range(of: "restore_test_state()"),
            let snapshotGuard = script.range(of: #"if [[ "$STATE_SNAPSHOT_COMPLETE" != true ]]; then"#),
            let firstRestore = script.range(of: #"if [[ "$HAD_TEXT_SIZE" == true ]]; then"#),
            let appearanceRead = script.range(
                of: #"PREVIOUS_APPEARANCE="$(defaults read "#),
            let snapshotComplete = script.range(of: "STATE_SNAPSHOT_COMPLETE=true")
        else {
            expect(false, "host-card probe 必须声明完整快照闸门与两个 defaults 快照")
            return
        }

        expect(
            restoreStart.lowerBound < snapshotGuard.lowerBound
                && snapshotGuard.lowerBound < firstRestore.lowerBound,
            "EXIT trap 必须在恢复 defaults 前先确认快照已经完成")
        expect(
            appearanceRead.lowerBound < snapshotComplete.lowerBound,
            "只有读取完 AppleInterfaceStyle 后才能标记 defaults 快照完成")
    }

    suite("App 真实组装：双 adapter + manager + shared bootstrap；启动只 bootstrap/refresh 不 connect") {
        guard
            let app = integrationsSource("gui/Sources/ClaudioGUI/ClaudioGUIApp.swift"),
            let menu = integrationsSource("gui/Sources/ClaudioGUI/MenuBarController.swift")
        else {
            expect(false, "缺少 App/MenuBar 组装源")
            return
        }
        for token in [
            "HostIntegrationManager(",
            "ClaudeCodeIntegrationAdapter()",
            "CodexIntegrationAdapter()",
            "SystemSharedRuntimeBootstrapper(environment: setupEnvironment)",
            "HostIntegrationManagerBridge(",
            "integrationBridge.perform(action)",
        ] {
            expect(app.contains(token), "production 必须真实组装 manager 链，缺少 \(token)")
        }
        expect(
            app.contains("bundledHelper ?? ClaudioPaths.claudioBinary"),
            "共享 bootstrap 必须优先 bundle helper，并在开发态回落已安装 helper")
        expect(
            menu.contains("requestHostIntegrationRefresh(bootstrapSharedRuntime: true)")
                && menu.contains("provider.bootstrapSharedRuntime()"),
            "启动必须只走共享 bootstrap + inspect")
        let menuCode = strippingComments(menu).codeWithoutStringLiterals
        let refreshBody: String
        if let start = menuCode.range(of: "fileprivate func requestHostIntegrationRefresh")?.lowerBound,
            let end = menuCode.range(of: "fileprivate func publishHostIntegrationState")?.lowerBound,
            start < end
        {
            refreshBody = String(menuCode[start..<end])
        } else {
            refreshBody = ""
            expect(false, "无法定位 requestHostIntegrationRefresh 以检查 bootstrap completion 顺序")
        }
        guard
            let providerReturn = refreshBody.range(of: "provider.bootstrapSharedRuntime()"),
            let panelReload = refreshBody.range(
                of: "self?.soundPacksRefreshCoordinator.completeSharedRuntimeBootstrap()"),
            let cancellationGuard = refreshBody.range(of: "!Task.isCancelled")
        else {
            expect(false, "bootstrap 返回、panel full reload 与 cancellation guard 三个边界必须同时存在")
            return
        }
        expect(
            providerReturn.lowerBound < panelReload.lowerBound
                && panelReload.lowerBound < cancellationGuard.lowerBound,
            "bootstrap 的 panel full reload 必须在 provider 完成后、取消/代次 guard 前发布；用户中途打开面板会取消旧 task，"
                + "但不能吞掉 bootstrap 已完成的 config/packs 变化")
        let startupCall = "requestHostIntegrationRefresh(bootstrapSharedRuntime: true)"
        let startupSuffix = menu.range(of: startupCall).map { String(menu[$0.lowerBound...]) } ?? ""
        expect(
            !startupSuffix.prefix(500).contains(".connect("),
            "启动 bootstrap 邻域不得自动连接任何宿主")
        expect(
            !app.contains("managerUnavailable"),
            "production 不得再注入永久不可用/no-op action handler")
    }

    suite("双表面共享 presentation store；Panel 不读取宿主配置") {
        guard
            let store = integrationsSource(
                "gui/Sources/ClaudioGUI/HostIntegrationPresentationStore.swift"),
            let panel = integrationsSource("gui/Sources/ClaudioGUI/PanelView.swift")
        else {
            expect(false, "缺少 presentation store/PanelView")
            return
        }
        expect(
            store.contains("HostIntegrationPresentationStore: ObservableObject")
                && store.contains("hostSourceRowPresentations(from: state.matrix)")
                && store.contains("mutedReason: state.masterVolumeIsZero")
                && store.contains("? .masterVolumeZero : .eventDisabled"),
            "popover 与 window 必须从同一注入矩阵投影")
        expect(
            panel.contains("@ObservedObject private var hostIntegrations")
                && panel.contains("ForEach(localizedHostRows)")
                && panel.contains("hostIntegrations.content.sourceRows"),
            "Panel 必须观察共享 presentation，而非自建宿主状态")
        let sourceSection: String
        if let start = panel.range(of: "private var hostSourcesSection")?.lowerBound,
            let end = panel.range(of: "// MARK: - Operational panel")?.lowerBound,
            start < end
        {
            sourceSection = String(panel[start..<end])
        } else {
            sourceSection = ""
            expect(false, "无法定位 Panel 声音来源区域")
        }
        for forbidden in ["settings.json", "hooks.json", "Data(contentsOf:", "JSONDecoder"] {
            expect(!sourceSection.contains(forbidden), "声音来源区域不得读取宿主配置，命中：\(forbidden)")
        }
    }

    suite("事件行宿主 Logo：Panel 只投影共享矩阵；Logo 只读且状态合并进编辑入口") {
        guard
            let panel = integrationsSource("gui/Sources/ClaudioGUI/PanelView.swift"),
            let row = integrationsSource("gui/Sources/ClaudioGUI/EventRowView.swift")
        else {
            expect(false, "缺少 Panel/EventRow 源")
            return
        }
        let rowLayout = collapsingWhitespace(strippingComments(row).codeWithoutStringLiterals)
        expect(
            panel.contains("eventHostIndicatorPresentations(")
                && panel.contains("matrix: hostIntegrations.content.matrix"),
            "五条事件行必须从共享 manager 矩阵投影宿主 Logo")
        expect(
            row.contains("ForEach(hostIndicators)")
                && row.contains("hostIndicatorImage(for: indicator.host)")
                && row.contains("Text(indicator.compactDisplayName)")
                && row.contains("eventHostIndicatorAssetName(for: host)")
                && row.contains("hostIconResourceBundle.image(forResource:")
                && row.contains("image.isTemplate = true")
                && row.contains("hostIndicators.map")
                && row.contains("localizedHostName(indicator.host"),
            "共享宿主投影必须同时驱动打包资源中的 Logo 与事件编辑入口 VoiceOver label")
        expect(
            row.contains("localizedEventName(row.event, language: language)")
                && !row.contains("func eventDisplayName"),
            "EventRowView 必须直接复用 Event.displayName，禁止保留第二份中文 switch")
        expect(
            rowLayout.contains("private let identitySpacing: CGFloat = 6")
                && rowLayout.contains("HStack(alignment: .center, spacing: identitySpacing)")
                && rowLayout.contains(".lineLimit(2)")
                && rowLayout.contains(".fixedSize(horizontal: false, vertical: true)")
                && rowLayout.contains("ZStack(alignment: .trailing)")
                && (rowLayout.contains(
                        ".padding(.trailing, adaptation.eventActionsMoveBelow ? 0 : actionOverlayClearance)")
                    || rowLayout.contains(
                        ".padding( .trailing, adaptation.eventActionsMoveBelow ? 0 : actionOverlayClearance)"))
                && !rowLayout.contains("ZStack(alignment: .topTrailing)")
                && !rowLayout.contains("HStack(alignment: .top, spacing: identitySpacing)")
                && !rowLayout.contains("minHeight: ClaudioTheme.Metrics.iconTarget"),
            "事件身份区必须让字形相对完整文案居中、保留 6pt 间距与双行标题，并由文案栈预留动作区")
        expect(
            row.contains("private var statusChips")
                && row.contains("if adaptation.rowWrapsToTwoLines && !adaptation.eventActionsMoveBelow")
                && row.contains("VStack(alignment: .leading, spacing: chipSpacing)"),
            "较大字号事件行必须把映射芯片下移，不能在 312pt 面板中固定横排溢出")
        expect(
            row.contains(".accessibilityValue(coverageAccessibilityValue)")
                && row.contains("private var coverageAccessibilityValue")
                && row.contains("case .unmapped, .broken:")
                && row.contains("coverageHelp"),
            "隐藏的映射芯片详情必须聚合进事件编辑入口的 VoiceOver value")
        expect(
            panel.contains("panelTypeSizeTier(for: interfaceTextSize)"),
            "Panel 必须复用可测试的四档字号映射，不能在 SwiftUI 里保留第二份 switch")
        for forbidden in [
            "EventHostCoveragePresentation", "hostCoverage", "宿主覆盖未检测",
            "两个来源", "仅 Claude Code", "PermissionRequest", "HostID.allCases",
        ] {
            expect(!row.contains(forbidden), "EventRowView 不得硬编码宿主矩阵：\(forbidden)")
        }

        guard
            let indicatorStart = row.range(of: "private var hostIndicatorGroup")?.lowerBound,
            let indicatorEnd = row.range(of: "private var previewButton")?.lowerBound,
            indicatorStart < indicatorEnd
        else {
            expect(false, "无法定位 EventRowView 的只读 Logo 组")
            return
        }
        let indicatorGroup = String(row[indicatorStart..<indicatorEnd])
        expect(!indicatorGroup.contains("Button("), "Logo 组不得包含独立 Button")
        expect(!indicatorGroup.contains("bundle: .module"), "Logo 组不得直接走 SwiftPM 的 Bundle.module 根目录查找")
        expect(!indicatorGroup.contains(".focused("), "Logo 组不得新增焦点 owner")
        expect(!indicatorGroup.contains("PanelFocusTarget"), "Logo 组不得新增 PanelFocusTarget")
        expect(
            indicatorGroup.contains(".accessibilityHidden(true)"),
            "Logo 自身必须从 VoiceOver 树隐藏，由事件编辑入口统一播报")
        expect(
            indicatorGroup.contains("HStack(spacing: chipSpacing)")
                && row.contains("private let chipSpacing: CGFloat = 4")
                && row.contains("private let hostIndicatorSize: CGFloat = 12")
                && indicatorGroup.contains("ClaudioTheme.font(.caption).weight(.semibold)")
                && indicatorGroup.contains(".padding(.horizontal, 6)")
                && indicatorGroup.contains(".padding(.vertical, 3)")
                && indicatorGroup.contains("RoundedRectangle(cornerRadius: 6)"),
            "宿主标签必须使用 4pt 间距、12pt PDF Logo、caption semibold 与 6/3/6 几何")
        expect(
            indicatorGroup.contains("indicator.state.usesActiveColor")
                && indicatorGroup.contains("activeColor.opacity(0.12)")
                && indicatorGroup.contains("ClaudioTheme.secondaryText(colorScheme)"),
            "连接宿主必须使用宿主色浅底，非连接宿主必须使用中性描边")
        for forbidden in [".animation(", ".onHover("] {
            expect(!indicatorGroup.contains(forbidden), "宿主标签不得添加 hover 动画：\(forbidden)")
        }
    }

    suite("事件静音按钮：使用批准的 24×24 双声波矢量，不回退到 SF Symbol") {
        guard let row = integrationsSource("gui/Sources/ClaudioGUI/EventRowView.swift") else {
            expect(false, "缺少 EventRowView 源")
            return
        }
        expect(
            row.contains("EventMuteSpeakerIcon(")
                && row.contains("SpeakerBodyShape")
                && row.contains("SpeakerWaveShape(radius: 4")
                && row.contains("SpeakerWaveShape(radius: 8"),
            "静音按钮必须由扬声器本体与两道声波组成")
        expect(
            row.contains("x: 3.5, y: 9")
                && row.contains("x: 12.5, y: 19")
                && row.contains("startX: 16, startY: 9.2, endY: 14.8")
                && row.contains("startX: 18.8, startY: 6.5, endY: 17.5"),
            "扬声器与两道声波必须钉住批准 mockup 的 24×24 几何")
        expect(
            row.contains("isMuted ? 0.24 : 1")
                && row.contains("x: 4, y: 4.5")
                && row.contains("x: 20, y: 20")
                && row.contains("lineWidth: 2.1"),
            "静音态必须把声波降至 24% 并叠加批准斜线")
        expect(
            !row.contains("speaker.wave.2") && !row.contains("speaker.slash.fill"),
            "事件静音按钮不得回退到旧 SF Symbol")
    }

    suite("可听矩阵刷新：面板全量 reload 与静音写入都回到共享 manager provider") {
        guard
            let menu = integrationsSource("gui/Sources/ClaudioGUI/MenuBarController.swift"),
            let panel = integrationsSource("gui/Sources/ClaudioGUI/PanelView.swift")
        else {
            expect(false, "缺少 MenuBar/Panel 源")
            return
        }
        expect(
            menu.contains("func audibilityInputsChanged()")
                && menu.contains("owner?.requestHostIntegrationRefresh()")
                && menu.contains("onAudibilityInputsChanged:"),
            "面板磁盘变化必须经 router 请求共享刷新")
        expect(
            panel.contains("afterFullReload:")
                && panel.contains("onAudibilityInputsChanged()"),
            "切包、导入、绑定、重开及管理窗口通知的全量 reload 必须更新矩阵")
        expect(
            panel.contains("panelModel.toggleMute(row.event)")
                && panel.components(separatedBy: "onAudibilityInputsChanged()").count >= 3,
            "静音的 configOnly 路径也必须显式更新矩阵")
        expect(
            menu.contains("case .unmute(_, let event):")
                && menu.contains("integrationsMuteController.setEnabled(event, enabled: true)")
                && menu.contains(
                    "soundPacksRefreshCoordinator?.completePanelConfigChange(.changed)"),
            "集成取消静音成功后必须推进共享 config-only revision，让保留窗口同步 enabled")
    }

    suite("集成→声音包关闭恢复：目标窗口消失时回落普通关闭交接") {
        guard
            let menu = integrationsSource("gui/Sources/ClaudioGUI/MenuBarController.swift"),
            let soundPacks = integrationsSource(
                "gui/Sources/SoundPacksWindow/SoundPacksWindowController.swift")
        else {
            expect(false, "缺少 MenuBarController/SoundPacksWindowController")
            return
        }
        expect(
            menu.contains("self?.integrationsWindowController.restoreKeyWindow() ?? false"),
            "关闭声音包窗口时必须把集成窗口恢复的真实 Bool 交给 owner")
        expect(
            soundPacks.contains("guard !restoration(previous) else { return }")
                && soundPacks.contains("self.completeCloseHandoff(to: previous)"),
            "恢复返回 false 时不得无条件 return，必须继续 handback 或 deactivate")
    }

    suite("检查器证据：真实 snapshot receipt 与两个实际配置路径由共享 store 投影") {
        guard let store = integrationsSource(
            "gui/Sources/ClaudioGUI/HostIntegrationPresentationStore.swift")
        else {
            expect(false, "缺少 HostIntegrationPresentationStore")
            return
        }
        expect(
            store.contains("state.snapshots")
                && store.contains("flatMap(hostLatestReceiptText)"),
            "最近真实回执必须来自 manager snapshot，不得由 View 读 receipts")
        expect(
            store.contains("configurationSources[row.host]")
                && store.contains("latestReceiptText:"),
            "检查器必须从共享 store 注入实际配置来源与回执")
    }

    suite("IntegrationsWindow boundary：视图与 controller 只消费注入 presentation，不自行读宿主配置") {
        let paths = [
            "gui/Sources/ClaudioGUI/IntegrationsWindowModel.swift",
            "gui/Sources/ClaudioGUI/IntegrationsWindowView.swift",
            "gui/Sources/ClaudioGUI/IntegrationsWindowController.swift",
        ]
        let sources = paths.compactMap { integrationsSource($0) }
        expect(sources.count == paths.count, "IntegrationsWindow 三个实现文件必须齐全")
        let joined = sources.joined(separator: "\n")

        expect(
            joined.contains("HostSourceRowPresentation")
                && joined.contains("HostCapabilityMatrixPresentation"),
            "窗口必须直接消费 HostIntegrationPresentation 的两种投影")
        for forbidden in [
            "FileManager", "Data(contentsOf:", "JSONDecoder", "settings.json", "hooks.json",
            "ClaudioPaths.claude", "ClaudioPaths.codex",
        ] {
            expect(
                !joined.contains(forbidden),
                "窗口层不得读取/解析配置或拼宿主路径，命中禁用 token：\(forbidden)")
        }
        expect(
            joined.contains("IntegrationsWindowRefreshHandler")
                && joined.contains("IntegrationsWindowActionHandler"),
            "重新检测与连接动作必须经注入 handler 回到共享 manager seam")
    }

    suite("IntegrationsWindow layout：紧凑双宿主摘要；标准 5×2 表格，最大文字纵向双宿主行；只有纵向滚动") {
        guard
            let view = integrationsSource(
                "gui/Sources/ClaudioGUI/IntegrationsWindowView.swift")
        else {
            expect(false, "缺少 IntegrationsWindowView.swift")
            return
        }

        expect(
            view.contains("ForEach(localizedSourceRows)")
                && view.contains("sourceSummaryButton"),
            "顶部宿主摘要必须由固定两行 presentation 同一视图生成")
        expect(
            view.contains("sourceSummaryButton(row)")
                && view.contains(".frame(maxWidth: .infinity"),
            "两条宿主摘要必须共享实现并各自占满等宽槽")
        expect(
            view.contains("usesNarrowCapabilityTable")
                && view.contains("case .eventCards = layoutAdaptation.mode")
                && view.contains("standardCapabilityMatrix")
                && view.contains("narrowCapabilityTable"),
            "真实视图必须消费纯模型的两种 Dynamic Type 布局，而不是只在测试里声明")
        expect(
            view.contains("ForEach(localizedMatrix.rows)")
                && view.contains("ForEach(row.cells)"),
            "标准与最大布局都必须遍历同一份 adapter 驱动的事件行/宿主格")
        expect(view.contains("ScrollView(.vertical"), "窗口内容必须允许纵向增长")
        expect(!view.contains("ScrollView(.horizontal"), "最大字号严禁横向滚动")
        expect(!view.contains(".clipped()"), "文字与事件卡不得用裁切解决拥挤")
        expect(
            view.contains("interfaceTextSize == .maximum ? 3 : 1"),
            "只有固定选择摘要可在非最大文字时单行；最大文字必须放开为三行")
        expect(
            view.contains("interfaceTextSize == .maximum")
                && view.contains("integrationsWindowLayoutAdaptation"),
            "Claudio 最大文字档必须真实映射到 presentation 的 eventCards 决策")
        expect(
            view.contains("width >= 760 && interfaceTextSize != .maximum")
                && view.contains("if usesSideBySideLayout(width: geometry.size.width)")
                && view.contains("sideBySideContent(width: geometry.size.width)")
                && view.contains("stackedContent"),
            "矩阵与 inspector 必须按真实窗口宽度在左右常驻和纵向重排间切换，最大文字恒为纵向")
    }

    suite("IntegrationsWindow inspector：三类证据与动作齐全，Codex 待确认固定为 /hooks + 重新检测") {
        guard
            let view = integrationsSource("gui/Sources/ClaudioGUI/IntegrationsWindowView.swift"),
            let model = integrationsSource("gui/Sources/ClaudioGUI/IntegrationsWindowModel.swift")
        else {
            expect(false, "缺少 IntegrationsWindow view/model")
            return
        }

        for key in ["integrationsConfigurationSource", "integrationsNativeEvent", "integrationsRecentReceipt"] {
            expect(view.contains("l10n.text(.\(key))"), "inspector 必须显示本地化字段 key：\(key)")
        }
        expect(
            model.contains("nativeEvents.joined(separator: \"、\")"),
            "选择宿主卡时原生事件字段必须列出该宿主真实支持的事件，而不是空占位")
        expect(
            model.contains("row.status == .awaitingActivation")
                && model.contains(".copyHooksCommand")
                && model.contains(".redetect"),
            "Codex 待确认必须由状态事实补齐复制 /hooks 与重新检测")
        expect(
            view.contains("localizedInspectorActionTitle(action")
                && model.contains(".copyHooksCommand"),
            "Codex 待授权必须通过统一动作标题渲染复制 /hooks")
        expect(
            view.contains("Label(l10n.text(.integrationsRedetect), systemImage: \"arrow.clockwise\")"),
            "重新检测必须位于窗口工具栏")
        expect(
            view.contains("localizedInspectorActionTitle(")
                && view.contains("hostStatus: selectedHostStatus"),
            "repair 按钮必须从纯状态标题投影 legacy 的“升级连接”，不能一律写修复")
        expect(
            view.contains("role: .destructive")
                && view.contains("visibleInspectorActions"),
            "断开必须是破坏性按钮，并从纯焦点序派生到检查器末尾")
    }

    suite("IntegrationsWindow focus：真实 FocusState 与纯 presentation 同身份、同顺序") {
        guard
            let view = integrationsSource("gui/Sources/ClaudioGUI/IntegrationsWindowView.swift"),
            let model = integrationsSource("gui/Sources/ClaudioGUI/IntegrationsWindowModel.swift")
        else {
            expect(false, "缺少 IntegrationsWindow view/model")
            return
        }

        expect(
            view.contains("@FocusState private var focusedTarget: IntegrationsWindowFocusTarget?"),
            "窗口必须拥有独立真实 FocusState")
        for target in [
            ".hostCard(row.host)", ".capabilityCell(host: cell.host, event: cell.event)",
            ".dismissFeedback(revision: feedback.revision)", ".inspectorAction(action)",
        ] {
            expect(view.contains(target), "真实控件缺少纯焦点身份：\(target)")
        }
        expect(
            view.contains("integrationsWindowFocusOrder(focusScope).first"),
            "打开焦点必须取纯模型焦点序第一项")
        expect(
            view.contains("integrationsWindowFocusOrder(focusScope)")
                && model.contains("IntegrationsWindowFocusCoordinator"),
            "焦点恢复与控件消失后的 reconcile 必须复用同一纯顺序")
    }

    suite("IntegrationsWindow VoiceOver：宿主、格子与短暂反馈都提供完整独立 label") {
        guard
            let view = integrationsSource(
                "gui/Sources/ClaudioGUI/IntegrationsWindowView.swift")
        else {
            expect(false, "缺少 IntegrationsWindowView.swift")
            return
        }

        expect(
            view.contains(".accessibilityLabel(sourceRowAccessibilityLabel(row))"),
            "宿主卡必须读出宿主、能力、连接状态与当前操作限定语")
        expect(
            view.contains(".accessibilityLabel(cell.accessibilityLabel)"),
            "矩阵格必须原样使用含宿主、事件、连接及“仅授权请求”的 Core label")
        expect(
            view.contains("Text(qualification)"),
            "“仅授权请求”等限定语还必须可见，不能只藏在 VoiceOver")
        expect(
            view.contains("feedback.localizedAccessibilityLabel(language: languageStore.language)"),
            "短暂状态必须把宿主与结果作为完整独立 label 暴露给 VoiceOver")
        expect(
                view.components(separatedBy: "NSAccessibility.post(").count - 1 == 1
                && view.contains("notification: .announcementRequested")
                && view.contains("feedbackAnnouncer.consume(")
                && view.contains("language: languageStore.language"),
            "反馈 revision 变化必须经唯一主动播报出口开口；关闭/到期由纯去重器吞掉")
    }

    suite("IntegrationsWindow VoiceOver：retained 窗口隐藏或失去 key 时不越界播报") {
        guard
            let view = integrationsSource("gui/Sources/ClaudioGUI/IntegrationsWindowView.swift"),
            let model = integrationsSource("gui/Sources/ClaudioGUI/IntegrationsWindowModel.swift"),
            let controller = integrationsSource(
                "gui/Sources/ClaudioGUI/IntegrationsWindowController.swift")
        else {
            expect(false, "缺少 IntegrationsWindow view/model/controller")
            return
        }
        expect(
            model.contains("@Published private(set) var isWindowVisible")
                && model.contains("@Published private(set) var isWindowKey"),
            "retained model 必须显式承载 AppKit 可见/key 事实")
        expect(
            controller.contains("windowDidBecomeKey")
                && controller.contains("windowDidResignKey")
                && controller.contains("model.noteWindowVisibility(false)"),
            "controller 必须把 show/key/close 生命周期交给 model")
        expect(
            view.contains("guard model.isWindowVisible, model.isWindowKey, NSApp.isActive")
                && view.contains(".onChange(of: model.isWindowKey)"),
            "隐藏/非 key 时不得 post；尚未过期的反馈应在重新成为 key 后再尝试")
    }

    suite("IntegrationsWindow feedback：5 秒可关闭、代次防误关，并在 Reduce Motion 下取消动画") {
        guard
            let view = integrationsSource("gui/Sources/ClaudioGUI/IntegrationsWindowView.swift"),
            let model = integrationsSource("gui/Sources/ClaudioGUI/IntegrationsWindowModel.swift")
        else {
            expect(false, "缺少 IntegrationsWindow view/model")
            return
        }

        expect(model.contains("IntegrationsFeedbackModel"), "真实状态必须复用纯反馈模型")
        expect(
            model.contains("scheduleFeedbackExpiryIfNeeded()")
                && model.contains("current.expiresAt.timeIntervalSince(now)")
                && model.contains("dismissFeedback(revision:"),
            "反馈必须按自己的截止时间自动过期并允许按代次关闭")
        expect(
            view.contains("@Environment(\\.accessibilityReduceMotion)")
                && view.contains("integrationsFeedbackTransition"),
            "真实视图必须消费 Reduce Motion 策略")
        expect(
            view.contains(".transition(reduceMotion ? .identity : .opacity)"),
            "Reduce Motion 开启时必须完全移除反馈动画")

        guard
            let dismissStart = model.range(of: "func dismissFeedback(revision:")?.lowerBound,
            let dismissEnd = model.range(of: "private func replaceContent(")?.lowerBound,
            dismissStart < dismissEnd
        else {
            expect(false, "无法定位反馈关闭逻辑")
            return
        }
        let dismissBody = String(model[dismissStart..<dismissEnd])
        let revisionGuard = dismissBody.range(
            of: "guard feedbackState.current?.revision == revision else { return }")
        let cancel = dismissBody.range(of: "feedbackExpiryTask?.cancel()")
        expect(
            revisionGuard != nil && cancel != nil
                && revisionGuard!.lowerBound < cancel!.lowerBound,
            "旧 revision 的延迟关闭不得取消或重置当前反馈的 expiry task")
        expect(
            model.contains("self.feedbackState.expire(at: Date())")
                && model.contains("self.feedback = self.feedbackState.current")
                && model.contains("current.expiresAt.timeIntervalSince(now)")
                && model.components(separatedBy: "scheduleFeedbackExpiryIfNeeded()").count - 1
                    >= 3,
            "关闭或自然到期推进队列后，必须发布下一 revision，并按实际截止时间重新安排 expiry task")
    }

    suite("IntegrationsWindow 明暗模式：所有表面与状态色都接设计 token，禁止硬编码颜色") {
        guard let view = integrationsSource("gui/Sources/ClaudioGUI/IntegrationsWindowView.swift")
        else {
            expect(false, "缺少 IntegrationsWindowView.swift")
            return
        }
        expect(
            view.contains("@Environment(\\.colorScheme)")
                && view.contains("ClaudioTheme.panel(colorScheme)")
                && view.contains("ClaudioTheme.elevated(colorScheme)")
                && view.contains("ClaudioTheme.secondaryText(colorScheme)")
                && view.contains("ClaudioTheme.hairline(colorScheme)"),
            "窗口中性表面必须随 colorScheme 使用现有 token")
        expect(
            view.contains("ClaudioTheme.success(colorScheme)")
                && view.contains("ClaudioTheme.error(colorScheme)")
                && view.contains("ClaudioTheme.clay(colorScheme)")
                && view.contains("ClaudioEventGlyph(event:"),
            "窗口状态与五事件颜色必须使用语义 token")
        for forbidden in [
            "Color(red:", "Color.white", "Color.black", ".foregroundColor(.red)",
            ".background(.white)",
        ] {
            expect(!view.contains(forbidden), "详情窗不得硬编码明暗颜色：\(forbidden)")
        }
    }

    suite("IntegrationsWindow 当前操作：model 持有目标宿主动作，宿主卡显示原生 ProgressView + 可见/VO 文案") {
        guard
            let view = integrationsSource("gui/Sources/ClaudioGUI/IntegrationsWindowView.swift"),
            let model = integrationsSource("gui/Sources/ClaudioGUI/IntegrationsWindowModel.swift")
        else {
            expect(false, "缺少 IntegrationsWindow view/model")
            return
        }
        expect(
            model.contains("@Published private(set) var inFlightOperation")
                && model.contains("integrationsInFlightPresentation("),
            "model 必须保存纯投影的 in-flight action/host，而非只有全局 bool")
        expect(
            view.contains("model.inFlightOperation")
                && view.contains("operation.host == row.host")
                && view.contains("ProgressView()")
                && view.contains("Text(localizedInFlightStatus(operation))"),
            "只有目标宿主卡必须显示原生进度与连接中/升级中/修复中/断开中文案")
        expect(
            view.contains("return \"\\(row.accessibilityLabel)\\(separator)\\(localizedInFlightStatus(operation))\""),
            "当前操作限定语必须进入宿主卡 VoiceOver label")
        expect(
            !view.contains("rotationEffect") && !view.contains("repeatForever"),
            "进行中状态不得自绘旋转动画；使用尊重系统设置的原生 ProgressView")
    }

    suite("State Gallery：双宿主场景用 catalog + AudibilityMatrix 生成，并渲染真实详情窗") {
        guard
            let fixtures = integrationsSource(
                "gui/Sources/ClaudioGUICore/PreviewFixtures.swift"),
            let gallery = integrationsSource("gui/Sources/ClaudioGUI/StateGalleryView.swift")
        else {
            expect(false, "缺少 PreviewFixtures/StateGalleryView")
            return
        }
        expect(
            fixtures.contains("hostIntegrationScenarios")
                && fixtures.contains("HostCapabilityCatalog.bindings(for:")
                && fixtures.contains("AudibilityMatrix.make("),
            "双宿主 fixture 必须由 adapter catalog 与 Core 矩阵组合")
        expect(
            !fixtures.contains("AudibilityCell("),
            "PreviewFixtures 不得手写任何矩阵格，否则第四格会与 adapter 漂移")
        expect(
            gallery.contains("PreviewFixtures.hostIntegrationScenarios")
                && gallery.contains("HostIntegrationStateFrame")
                && gallery.contains("IntegrationsWindowView("),
            "gallery 必须遍历权威场景并渲染生产 IntegrationsWindowView")
        expect(
            fixtures.contains("eventHostIndicatorScenarios")
                && fixtures.contains("id: \"full-color\"")
                && fixtures.contains("id: \"mixed\"")
                && fixtures.contains("id: \"all-gray\"")
                && fixtures.contains("id: \"legacy\"")
                && fixtures.contains("id: \"awaiting-narrow\""),
            "EventRow Logo fixture 必须覆盖全彩、混合、全灰、legacy 与待激活窄版")
        expect(
            gallery.contains("PreviewFixtures.eventHostIndicatorScenarios")
                && gallery.contains("EventHostIndicatorStateFrame")
                && gallery.contains("hostIndicators: eventHostIndicatorPresentations("),
            "EventRow Logo gallery 必须遍历 catalog 并渲染生产 EventRowView")
        expect(
            fixtures.contains("eventRowLayoutScenarios")
                && fixtures.contains("ClaudioAppLanguage.allCases.flatMap")
                && fixtures.contains("interfaceTextSizes.map")
                && gallery.contains("ForEach(PreviewFixtures.eventRowLayoutScenarios)")
                && gallery.contains("ForEach(scenario.samples)")
                && gallery.contains("hostIndicators: localizedEventHostIndicators(")
                && gallery.contains("adaptation: scenario.adaptation"),
            "双语四档界面文字帧必须同帧渲染三种映射状态、真实宿主标签与生产布局")
        expect(
            fixtures.contains("title: \"claudi0 已写好，等待 Codex 确认\"")
                && !fixtures.contains("title: \"Codex 已写好，等待 /hooks 确认\""),
            "Codex 待确认场景 caption 必须使用固定产品文案")
    }

    suite("IntegrationsWindow Package：仍归唯一 ClaudioGUI app target，不增加第二个 @main") {
        guard let package = integrationsSource("gui/Package.swift") else {
            expect(false, "读不到 gui/Package.swift")
            return
        }
        let appSources = integrationsSource("gui/Sources/ClaudioGUI/ClaudioGUIApp.swift") ?? ""
        let controller =
            integrationsSource(
                "gui/Sources/ClaudioGUI/IntegrationsWindowController.swift") ?? ""

        expect(
            package.contains("retained `IntegrationsWindow`")
                && package.contains(".executableTarget(\n            name: \"ClaudioGUI\""),
            "Package target 注释必须明确新窗口仍由唯一 app shell 所有")
        expect(appSources.contains("@main"), "ClaudioGUIApp 必须继续是唯一入口")
        expect(!controller.contains("@main"), "IntegrationsWindow controller 不得制造第二入口")
    }
}
