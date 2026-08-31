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
            let settings = integrationDestinationSource("gui/Sources/ClaudioGUI/SettingsWindowView.swift"),
            let controller = integrationDestinationSource(
                "gui/Sources/ClaudioGUI/SettingsWindowController.swift"),
            let menu = integrationDestinationSource("gui/Sources/ClaudioGUI/MenuBarController.swift")
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
            controller.contains("private let integrationsModel: IntegrationDestinationModel")
                && controller.contains("integrationsModel.noteWindowVisibility")
                && controller.contains("integrationsModel.noteWindowKeyState"),
            "retained Settings controller 必须复用一个 Core destination model")
        expect(
            !controller.contains("IntegrationsWindowController")
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
        guard let view = integrationDestinationSource(
            "gui/Sources/ClaudioGUI/IntegrationsSettingsDestinationView.swift")
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

    suite("集成 destination action boundary：连接、清除、配置来源与 Events 各有唯一入口") {
        guard let view = integrationDestinationSource(
            "gui/Sources/ClaudioGUI/IntegrationsSettingsDestinationView.swift")
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
                && view.contains("model.confirmPendingAction()"),
            "断开与清除都必须统一走确认对话框和异步 action")
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
                "gui/Sources/ClaudioGUI/IntegrationsSettingsDestinationView.swift"),
            let gallery = integrationDestinationSource("gui/Sources/ClaudioGUI/StateGalleryView.swift")
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
                "gui/Sources/ClaudioGUI/IntegrationsSettingsDestinationView.swift"),
            let preferences = integrationDestinationSource(
                "gui/Sources/ClaudioGUICore/SettingsPreferences.swift"),
            let menu = integrationDestinationSource("gui/Sources/ClaudioGUI/MenuBarController.swift")
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
}
