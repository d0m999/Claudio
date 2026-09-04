import ClaudioCore
import ClaudioGUICore
import Foundation

private func integrationDestinationSource(_ relativePath: String) -> String? {
    try? String(
        contentsOf: guiTestRepositoryRoot().appendingPathComponent(relativePath),
        encoding: .utf8)
}

@MainActor
func runIntegrationDestinationWiringSuites() {
    suite("集成 destination package wiring：所有展示类型在 Foundation-only ClaudioGUICore") {
        let coreRoot = guiTestRepositoryRoot().appendingPathComponent("gui/Sources/ClaudioGUICore")
        let guiRoot = guiTestRepositoryRoot().appendingPathComponent("gui/Sources/ClaudioGUI")
        let requiredCoreFiles = [
            "IntegrationDestinationPresentation.swift",
            "IntegrationDestinationModel.swift",
            "IntegrationDestinationFocus.swift",
            "HostIntegrationPresentationStore.swift",
        ]
        for file in requiredCoreFiles {
            expect(
                FileManager.default.fileExists(atPath: coreRoot.appendingPathComponent(file).path),
                "ClaudioGUICore 必须包含 \(file)")
        }
        expect(
            !FileManager.default.fileExists(
                atPath: guiRoot.appendingPathComponent("IntegrationsWindowView.swift").path)
                && !FileManager.default.fileExists(
                    atPath: guiRoot.appendingPathComponent("IntegrationsWindowModel.swift").path),
            "旧 IntegrationsWindow view/model 必须原子移除")
        expect(
            !FileManager.default.fileExists(
                atPath: coreRoot.appendingPathComponent("IntegrationsWindowFocus.swift").path),
            "旧 matrix/Inspector focus scope 必须移除")
        if let model = integrationDestinationSource(
            "gui/Sources/ClaudioGUICore/IntegrationDestinationModel.swift")
        {
            expect(!model.contains("import AppKit"), "Core model 不得依赖 AppKit")
            expect(
                model.contains("IntegrationDestinationRefreshHandler")
                    && model.contains("IntegrationDestinationActionHandler")
                    && model.contains("IntegrationDestinationClipboardWriter"),
                "Core model 必须通过 handler/clipboard seam 注入外部动作")
        } else {
            expect(false, "读不到 Core IntegrationDestinationModel.swift")
        }
    }

    suite("统一 Settings wiring：直接挂载 production destination，不创建第二窗口或 controller") {
        guard
            let settings = integrationDestinationSource(
                "gui/Sources/ClaudioSettingsPresentation/SettingsRootView.swift"),
            let session = integrationDestinationSource(
                "gui/Sources/ClaudioSettingsPresentation/SettingsPresentationSession.swift"),
            let menu = integrationDestinationSource(
                "gui/Sources/ClaudioGUI/MenuBarController.swift")
        else {
            expect(false, "缺少 Settings/MenuBar production source")
            return
        }
        expect(
            settings.contains("IntegrationsSettingsDestinationView(")
                && settings.contains("onManageEvents: { host in")
                && settings.contains(".events(scope: .surface(host.surfaceID), event: nil)"),
            "统一 Settings 必须直接挂载新 destination，并把事件管理路由到当前 Surface")
        expect(
            session.contains("dependencies.integrationsModel.noteWindowVisibility")
                && session.contains("dependencies.integrationsModel.noteWindowKeyState"),
            "retained Settings session 必须复用一个 Core destination model")
        expect(
            !session.contains("IntegrationsWindowController")
                && !menu.contains("IntegrationsWindowController")
                && !menu.contains("private let integrationsWindowController"),
            "生产 wiring 不得保留第二窗口/controller")
        expect(
            menu.contains("IntegrationDestinationRefreshHandler")
                && menu.contains("IntegrationDestinationActionHandler")
                && menu.contains("HostIntegrationPresentationStore"),
            "manager handlers、store 与 destination model 必须在 composition root 注入")
    }

    suite("集成 destination layout contract：单层纵向 ScrollView、820 内容宽度、无旧矩阵/Inspector") {
        guard
            let view = integrationDestinationSource(
                "gui/Sources/ClaudioSettingsPresentation/IntegrationsSettingsDestinationView.swift")
        else {
            expect(false, "缺少 IntegrationsSettingsDestinationView.swift")
            return
        }
        let stripped = strippingComments(view)
        expect(stripped.unmodeledConstructs.isEmpty, "destination source scanner 必须完成解析")
        expect(
            stripped.codeWithoutStringLiterals.contains("ScrollView(.vertical")
                && !stripped.codeWithoutStringLiterals.contains("ScrollView(.horizontal"),
            "页面只能有一层纵向滚动，不得用横向滚动承载旧矩阵")
        expect(
            view.contains(".frame(maxWidth: 820")
                && view.contains("SettingsSectionCard")
                && view.contains("IntegrationsSettingsDestinationView"),
            "内容必须最大宽度 820 并使用 prototype 的分组卡片")
        expect(
            !view.contains("Inspector")
                && !view.contains("capabilityMatrix")
                && !view.contains("sideBySideContent")
                && !view.contains("toolbar"),
            "新 destination 不得保留旧 Inspector、能力矩阵、side-by-side 或 toolbar")
        expect(
            view.contains("integrations.destination.feedback.toast")
                && view.contains(".bottomTrailing"),
            "反馈必须使用原型式右下 Toast")
    }

    suite("集成 destination typed focus：通用入口的 title 请求落到真实可聚焦标题") {
        guard
            let view = integrationDestinationSource(
                "gui/Sources/ClaudioSettingsPresentation/IntegrationsSettingsDestinationView.swift"),
            let settings = integrationDestinationSource(
                "gui/Sources/ClaudioSettingsPresentation/SettingsRootView.swift")
        else {
            expect(false, "缺少 Integrations destination 或 Settings route source")
            return
        }
        expect(
            settings.components(
                separatedBy: "integrationsFocusCoordinator.requestFocus(.title)"
            ).count - 1 == 0,
            "Root 不得拥有 generic/invalid Integration route 的第二 focus 决策")

        let code = strippingComments(view).codeWithoutStringLiterals
        guard
            let headerStart = code.range(of: "private var pageHeader: some View"),
            let nextFunction = code.range(
                of: "private func sectionLabel(",
                range: headerStart.upperBound..<code.endIndex)
        else {
            expect(false, "destination 必须保留可审查的 pageHeader 边界")
            return
        }
        let headerRegion = String(code[headerStart.lowerBound..<nextFunction.lowerBound])
        expect(
            headerRegion.contains(".accessibilityAddTraits(.isHeader)")
                && headerRegion.contains(".focusable()")
                && headerRegion.contains(".focused($focusedTarget, equals: .title)"),
            "typed .title 必须绑定同时具有 header 语义与 focusable key-view 能力的标题")
    }

    suite("集成 destination action boundary：连接、清除、配置来源与 Events 各有唯一入口") {
        guard
            let view = integrationDestinationSource(
                "gui/Sources/ClaudioSettingsPresentation/IntegrationsSettingsDestinationView.swift")
        else {
            expect(false, "缺少 destination view")
            return
        }
        expect(
            view.contains("model.requestToggle(for: agent.host)")
                && view.contains("model.requestClearReceiptHistory(for: host)"),
            "Agent Toggle 与第四行清除必须进入 Core model")
        expect(
            view.contains("model.copyConfigurationSource(for: host)")
                && view.contains("onManageEvents?(host)"),
            "第二行复制和第三行 Events 必须消费各自 typed row action")
        expect(
            view.contains("confirmationDialog(")
                && view.contains("role: .destructive")
                && view.components(separatedBy: "submitConfirmation(confirmation)").count - 1 == 2,
            "断开与清除都必须统一走确认对话框和异步 action")
        let code = strippingComments(view).codeWithoutStringLiterals
        guard
            let submitStart = code.range(
                of:
                    "private func submitConfirmation(\n        _ confirmation: IntegrationDestinationConfirmation\n    )"
            ),
            let nextFunction = code.range(
                of: "private func confirmationMessage(",
                range: submitStart.upperBound..<code.endIndex)
        else {
            expect(false, "destination 必须有可审查的同步 confirmation 提交边界")
            return
        }
        let submitRegion = String(code[submitStart.lowerBound..<nextFunction.lowerBound])
        guard
            let consume = submitRegion.range(of: "model.consumePendingAction(confirmation)"),
            let task = submitRegion.range(of: "Task {")
        else {
            expect(false, "confirmation 提交边界必须同时包含同步消费与异步 manager action")
            return
        }
        expect(
            consume.lowerBound < task.lowerBound
                && submitRegion.contains("await model.perform(action)"),
            "必须先同步消费 presenting confirmation，再创建执行已捕获 manager action 的 Task")
        expect(
            !view.contains("NSSound") && !view.contains("AVAudio") && !view.contains("playSound"),
            "destination action chain 不得获得自动试听能力")
    }

    suite("集成 destination state/feedback wiring：真实事实、5 秒反馈与窗口 key 守卫") {
        guard
            let presentation = integrationDestinationSource(
                "gui/Sources/ClaudioGUICore/IntegrationDestinationPresentation.swift"),
            let sharedPresentation = integrationDestinationSource(
                "gui/Sources/ClaudioGUICore/HostIntegrationPresentation.swift"),
            let model = integrationDestinationSource(
                "gui/Sources/ClaudioGUICore/IntegrationDestinationModel.swift"),
            let view = integrationDestinationSource(
                "gui/Sources/ClaudioSettingsPresentation/IntegrationsSettingsDestinationView.swift"),
            let gallery = integrationDestinationSource(
                "gui/Sources/ClaudioGUI/StateGalleryView.swift")
        else {
            expect(false, "缺少 destination state/feedback source")
            return
        }
        expect(
            presentation.contains("HostID.productVisibleCases")
                && presentation.contains("IntegrationConnectionRowKind")
                && presentation.contains("HostIntegrationMechanism"),
            "presentation 必须消费产品 Surface registry、四行 contract 与 descriptor mechanism")
        expect(
            model.contains("inFlightOperation")
                && model.contains("guard !isPerformingAction")
                && model.contains("replaceContent(outcome.content)"),
            "model 必须保留旧快照、阻止重复提交并在 outcome 后刷新")
        expect(
            view.contains("model.isWindowVisible, model.isWindowKey")
                && view.contains("IntegrationsFeedbackAnnouncementModel")
                && sharedPresentation.contains("integrationsFeedbackLifetime"),
            "反馈播报必须经过可见/key 与既有代次/五秒语义")
        expect(
            gallery.contains("IntegrationsSettingsDestinationView(")
                && gallery.contains("previewInFlightAction: .disconnect(.workBuddy)"),
            "State Gallery 必须使用同一 production view 并固定断开 in-flight 帧")
    }

    suite("配置与偏好 wiring：展示层不读宿主文件，Surface 偏好使用独立稳定 key") {
        guard
            let view = integrationDestinationSource(
                "gui/Sources/ClaudioSettingsPresentation/IntegrationsSettingsDestinationView.swift"),
            let preferences = integrationDestinationSource(
                "gui/Sources/ClaudioGUICore/SettingsPreferences.swift"),
            let menu = integrationDestinationSource(
                "gui/Sources/ClaudioGUI/MenuBarController.swift")
        else {
            expect(false, "缺少 preference/configuration source")
            return
        }
        expect(
            !view.contains("FileManager") && !view.contains("Data(contentsOf:")
                && !view.contains("UserDefaults"),
            "destination view 不得直接读取宿主文件、配置或 defaults")
        expect(
            preferences.contains("lastIntegrationSurface")
                && preferences.contains("integrationSurfaceDefaultsKey")
                && preferences.contains("invalidIntegrationSurface")
                && preferences.contains("setLastIntegrationSurface"),
            "偏好 owner 必须发布独立 Surface 字段、稳定 key 和 recovery issue")
        expect(
            menu.contains("ClaudioPaths.claudeSettingsFile.path")
                && menu.contains("ClaudioPaths.codexHooksFile.path")
                && menu.contains("ClaudioPaths.workBuddySettingsFile.path"),
            "配置来源只能由 composition root 注入 manager 已知的生产路径")
    }

    suite("固定基线门禁：脚本、harness 与文档使用当前 Integration Destination suites") {
        guard
            let gate = integrationDestinationSource("scripts/verify-settings-experience.sh"),
            let harness = integrationDestinationSource(
                "gui/Tests/ClaudioGUICoreTests/main.swift"),
            let acceptance = integrationDestinationSource(
                "docs/settings-experience-acceptance.md")
        else {
            expect(false, "缺少固定基线门、GUI harness 或验收文档")
            return
        }
        let currentSuites = [
            (
                entrypoint: "runIntegrationDestinationPresentationSuites",
                documented: "IntegrationDestinationPresentationSuite"
            ),
            (
                entrypoint: "runIntegrationDestinationModelSuites",
                documented: "IntegrationDestinationModelSuite"
            ),
            (
                entrypoint: "runIntegrationDestinationWiringSuites",
                documented: "IntegrationDestinationWiringSuite"
            ),
        ]
        for suiteName in currentSuites {
            expect(
                gate.contains(suiteName.entrypoint),
                "固定基线门必须要求 \(suiteName.entrypoint)")
            expect(
                harness.contains("\(suiteName.entrypoint)()"),
                "GUI harness 必须注册 \(suiteName.entrypoint)")
            expect(
                acceptance.contains(suiteName.documented),
                "验收文档必须列出 \(suiteName.documented)")
        }
        expect(
            !gate.contains("runIntegrationsWindowWiringSuites")
                && !acceptance.contains("IntegrationsWindowWiringSuite"),
            "已删除的 Integration Window suite 不得残留在门禁或当前验收文档")
    }
}
