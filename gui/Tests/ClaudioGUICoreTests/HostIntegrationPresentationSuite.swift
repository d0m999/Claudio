import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

private let hostPresentationInstallationID = UUID(
    uuidString: "00000000-0000-4000-8000-0000000000A1")!

private func hostPresentationSnapshot(
    _ host: HostID,
    activation: HostActivationEvidence? = nil
) -> HostIntegrationSnapshot {
    guard let binding = HostCapabilityCatalog.bindings(for: host).first(where: \.isAudibleCapability)
    else {
        return HostIntegrationSnapshot(
            host: host,
            runtime: .ready,
            availability: .unavailable(reason: "Beta candidate unavailable"),
            configuration: .notConfigured,
            writability: .unknown,
            activation: .none)
    }
    let evidence = HostReceiptEvidence(
        installationID: hostPresentationInstallationID,
        nativeEvent: binding.nativeEvent!,
        event: binding.event,
        timestamp: Date(timeIntervalSince1970: 100.123),
        playbackResult: .played)
    let resolvedActivation = activation ?? .observed(evidence)
    let latestReceipt: HostReceiptEvidence?
    if case .observed(let observed) = resolvedActivation {
        latestReceipt = observed
    } else {
        latestReceipt = nil
    }
    return HostIntegrationSnapshot(
        host: host,
        runtime: .ready,
        availability: .available,
        configuration: .configured,
        writability: .writable,
        activation: resolvedActivation,
        latestReceipt: latestReceipt,
        installationID: hostPresentationInstallationID)
}

private func hostPresentationMatrix(
    snapshots: [HostIntegrationSnapshot]? = nil,
    capabilities: [HostID: [HostCapabilityBinding]]? = nil
) -> AudibilityMatrix {
    AudibilityMatrix.make(
        snapshots: snapshots ?? HostID.productVisibleCases.map { hostPresentationSnapshot($0) },
        capabilities: capabilities
            ?? Dictionary(
                uniqueKeysWithValues: HostID.productVisibleCases.map {
                    ($0, HostCapabilityCatalog.bindings(for: $0))
                }),
        soundCoverage: Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0, true) }),
        enabledEvents: Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0, true) }))
}

@MainActor
func runHostIntegrationPresentationSuites() {
    suite("宿主事件文案：五个 UI 名称统一为声音语义，不泄漏原生事件名") {
        expect(
            Event.allCases.map(\.displayName)
                == ["任务开始", "本轮结束", "执行中断", "待响应", "子任务结束"],
            "Event displayName 必须保持产品声音语义顺序")
        let codex = localizedCapabilityCell(
            HostCapabilityCellPresentation(
                host: .codex,
                event: .notification,
                state: .awaitingActivation,
                qualificationText: "仅授权请求"),
            language: .english)
        expect(
            codex.qualificationText == "Authorization request only"
                && !codex.accessibilityLabel.contains("PermissionRequest"),
            "原生事件 key 不得泄漏到能力 label")
    }

    suite("宿主来源共享 presentation：产品 registry 永久出现，AX identity 只留在诊断层") {
        let rows = hostSourceRowPresentations(from: hostPresentationMatrix())
        expect(rows.map(\.host) == [.codex, .claudeCode, .workBuddy], "共享来源仍保持 Product 分组顺序")
        expect(
            rows.map(\.supportedCount) == [4, 5, 2]
                && rows.allSatisfy { $0.totalCount == Event.allCases.count },
            "能力数量必须来自 adapter/catalog 事实")
        expect(
            hostSourceRowPresentations(
                from: hostPresentationMatrix(
                    snapshots: [hostPresentationSnapshot(.claudeCode)]))
                .map(\.host) == [.codex, .claudeCode, .workBuddy],
            "缺少快照也不能隐藏其他产品宿主")
        expect(
            Set(rows.map(\.host)).isDisjoint(with: [.chatGPTDesktopAX, .claudeDesktopAX]),
            "AX-only identity 不得进入普通来源行")
    }

    suite("共享能力矩阵：严格由五个语义行和产品宿主单元组成，缺失映射保持 fail closed") {
        let matrix = hostCapabilityMatrixPresentation(from: hostPresentationMatrix())
        expect(matrix.rows.map(\.event) == Event.allCases, "矩阵必须保持五个事件语义行")
        expect(matrix.hostColumns == hostSurfacePresentationOrder(), "矩阵列继续消费共享 Product 顺序")
        let codexStopFailure = matrix.cell(host: .codex, event: .stopFailure)
        expect(
            codexStopFailure?.state == .unsupported
                && codexStopFailure?.nativeEventText == nil,
            "Codex 未声明的 stop_failure 不得由 UI 硬编码补回")
        let noCodexMapping = hostPresentationMatrix(
            capabilities: [
                .claudeCode: HostCapabilityCatalog.bindings(for: .claudeCode),
                .codex: HostCapabilityCatalog.bindings(for: .codex).filter {
                    $0.event != .stop
                },
                .workBuddy: HostCapabilityCatalog.bindings(for: .workBuddy),
            ])
        expect(
            hostCapabilityMatrixPresentation(from: noCodexMapping)
                .cell(host: .codex, event: .stop)?.state == .unsupported,
            "删除 adapter 映射必须暴露 unsupported，而非补写声音能力")
    }

    suite("Accessibility Beta qualification：能力格和事件指示器共享双语限定语") {
        let source = "Accessibility Beta 候选尚未实现"
        let cell = HostCapabilityCellPresentation(
            host: .chatGPTDesktopAX,
            event: .taskStart,
            state: .unsupported,
            qualificationText: source)
        let indicator = EventHostIndicatorPresentation(
            host: .chatGPTDesktopAX,
            state: .unsupported,
            qualificationText: source)
        expect(
            localizedCapabilityCell(cell, language: .english).qualificationText
                == "Accessibility Beta candidate is not implemented"
                && localizedEventHostIndicator(indicator, language: .english).qualificationText
                    == "Accessibility Beta candidate is not implemented",
            "AX unavailable 文案必须在共享 localization seam 中保持一致")
    }

    suite("真实回执 presentation：只显示宿主、事件、时间与脱敏结果") {
        let observed = hostPresentationSnapshot(.claudeCode)
        let text = hostLatestReceiptText(snapshot: observed)
        expect(
            hostLatestReceiptEvidence(snapshot: observed)?.event == .taskStart
                && text?.contains("Claude Code · 任务开始") == true,
            "observed receipt 必须保留结构化宿主与声音语义")
        expect(
            text?.contains("UserPromptSubmit") == false
                && text?.contains(hostPresentationInstallationID.uuidString) == false
                && text?.contains("/") == false,
            "回执摘要不得泄漏原生 key、installation ID 或绝对路径")
        let awaiting = hostPresentationSnapshot(
            .codex,
            activation: .awaitingReceipt(installationID: hostPresentationInstallationID))
        expect(
            hostLatestReceiptText(snapshot: awaiting) == nil
                && hostLatestReceiptEvidence(snapshot: awaiting) == nil,
            "awaiting 状态不能伪造当前安装实例回执")
    }

    suite("回执变化与播放结果：结构化 evidence 区分同毫秒摘要，六种结果均可脱敏显示") {
        let binding = HostCapabilityCatalog.bindings(for: .claudeCode)
            .first(where: \.isAudibleCapability)!
        func snapshot(at interval: TimeInterval, result: HostHookPlaybackResult = .played)
            -> HostIntegrationSnapshot
        {
            let evidence = HostReceiptEvidence(
                installationID: hostPresentationInstallationID,
                nativeEvent: binding.nativeEvent!,
                event: binding.event,
                timestamp: Date(timeIntervalSince1970: interval),
                playbackResult: result)
            return HostIntegrationSnapshot(
                host: .claudeCode,
                runtime: .ready,
                availability: .available,
                configuration: .configured,
                writability: .writable,
                activation: .observed(evidence),
                latestReceipt: evidence,
                installationID: hostPresentationInstallationID)
        }
        expect(
            hostLatestReceiptText(snapshot: snapshot(at: 100.1234))
                == hostLatestReceiptText(snapshot: snapshot(at: 100.1235)),
            "测试前提：同毫秒精度下摘要可能相同")
        expect(
            hostLatestReceiptEvidence(snapshot: snapshot(at: 100.1234))
                != hostLatestReceiptEvidence(snapshot: snapshot(at: 100.1235)),
            "变化判断必须消费完整 evidence")
        let expected: [(HostHookPlaybackResult, String)] = [
            (.played, "已播放"), (.muted, "已静音"), (.debounced, "防抖跳过"),
            (.notReady, "声音未就绪"), (.unsupportedEvent, "事件不支持"), (.playbackFailed, "播放失败"),
        ]
        for (result, title) in expected {
            expect(hostHookPlaybackResultDisplayName(result) == title, "\(result) 必须显示 \(title)")
            expect(
                hostLatestReceiptText(snapshot: snapshot(at: 100, result: result))?.hasSuffix("· \(title)")
                    == true,
                "\(result) 回执摘要必须包含脱敏结果")
        }
    }

    suite("共享反馈模型：右下 toast 的五秒边界、代次保护与 Reduce Motion 不变") {
        let now = Date(timeIntervalSince1970: 2_000)
        var model = IntegrationsFeedbackModel()
        let old = model.present(
            host: .claudeCode,
            kind: .success,
            message: "Claude Code 已连接",
            now: now)
        let new = model.present(
            host: .codex,
            kind: .failure,
            message: "Codex 重新检测失败",
            now: now)
        model.dismiss(revision: old, now: now)
        expect(model.current?.revision == new, "旧 toast 的关闭事件不得误关新 toast")
        expect(
            model.current?.expiresAt == now.addingTimeInterval(integrationsFeedbackLifetime),
            "toast 生命周期必须为五秒")
        expect(
            integrationsFeedbackTransition(reduceMotionEnabled: false) == .opacity
                && integrationsFeedbackTransition(reduceMotionEnabled: true) == .immediate,
            "Reduce Motion 开启时必须立即更新")
        var announcer = IntegrationsFeedbackAnnouncementModel()
        expect(announcer.consume(model.current) != nil, "新代次必须可播报")
        expect(announcer.consume(model.current) == nil && announcer.consume(nil) == nil, "去重不可被 nil 重置")
    }
}
