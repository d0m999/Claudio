import ClaudioCore
import ClaudioGUICore
import Foundation

private let hostPresentationInstallationID = UUID(
    uuidString: "00000000-0000-4000-8000-0000000000A1")!

private func hostPresentationSnapshot(
    _ host: HostID,
    activation: HostActivationEvidence? = nil
) -> HostIntegrationSnapshot {
    guard
        let binding = HostCapabilityCatalog.bindings(for: host).first(where: \.isAudibleCapability)
    else {
        return HostIntegrationSnapshot(
            host: host,
            runtime: .ready,
            availability: .unavailable(reason: "Beta candidate unavailable"),
            configuration: .notConfigured,
            writability: .unknown,
            activation: .none)
    }
    let evidence =
        activation
        ?? .observed(
            HostReceiptEvidence(
                installationID: hostPresentationInstallationID,
                nativeEvent: binding.nativeEvent!,
                event: binding.event,
                timestamp: Date(timeIntervalSince1970: 100),
                playbackResult: .played))
    let latestReceipt: HostReceiptEvidence?
    if case .observed(let observed) = evidence {
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
        activation: evidence,
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
    suite("事件文案：五个 UI 名称统一为声音语义，不泄漏宿主原生事件名") {
        let expected: [(Event, String)] = [
            (.taskStart, "任务开始"),
            (.stop, "本轮结束"),
            (.stopFailure, "执行中断"),
            (.notification, "待响应"),
            (.subagentStop, "子任务结束"),
        ]

        expect(
            Event.allCases.map(\.displayName) == expected.map(\.1),
            "五个事件必须按稳定顺序使用统一中文语义，实得 \(Event.allCases.map(\.displayName))")
        expect(
            Set(Event.allCases.map(\.displayName)).count == Event.allCases.count,
            "五个声音语义名称必须互不重复")
        for (event, title) in expected {
            expect(
                event.displayName == title, "\(event.rawValue) 应显示 \(title)，实得 \(event.displayName)"
            )
        }
    }

    suite("AX unavailable qualification：能力格与事件宿主指示器使用同一双语文案") {
        let sourceText = "Accessibility Beta 候选尚未实现"
        let cell = HostCapabilityCellPresentation(
            host: .chatGPTDesktopAX,
            event: .taskStart,
            state: .unsupported,
            qualificationText: sourceText)
        let indicator = EventHostIndicatorPresentation(
            host: .chatGPTDesktopAX,
            state: .unsupported,
            qualificationText: sourceText)

        let chineseCell = localizedCapabilityCell(cell, language: .zhHans)
        let englishCell = localizedCapabilityCell(cell, language: .english)
        let chineseIndicator = localizedEventHostIndicator(indicator, language: .zhHans)
        let englishIndicator = localizedEventHostIndicator(indicator, language: .english)

        expect(
            chineseCell.qualificationText == "Accessibility Beta 候选尚未实现"
                && chineseIndicator.qualificationText == "Accessibility Beta 候选尚未实现",
            "AX unavailable qualification 的能力格与事件宿主指示器必须共享 zh-Hans 文案")
        expect(
            englishCell.qualificationText == "Accessibility Beta candidate is not implemented"
                && englishIndicator.qualificationText
                    == "Accessibility Beta candidate is not implemented",
            "AX unavailable qualification 的能力格与事件宿主指示器必须共享 English 文案")
    }

    suite("声音来源行：产品 registry 永久等权出现，能力数是实现事实") {
        let rows = hostSourceRowPresentations(from: hostPresentationMatrix())
        let expectedVisualOrder: [HostID] = [.codex, .claudeCode, .workBuddy]

        expect(
            rows.count == HostID.productVisibleCases.count,
            "声音来源必须覆盖产品 registry，实得 \(rows.count)")
        expect(rows.map(\.host) == expectedVisualOrder, "宿主行必须服从唯一 Product → Surface 视觉序")
        let claude = rows.first(where: { $0.host == .claudeCode })!
        let codex = rows.first(where: { $0.host == .codex })!
        let workBuddy = rows.first(where: { $0.host == .workBuddy })!
        expect(claude.title == "Claude Code", "Claude 来源标题必须是 Claude Code")
        expect(claude.readinessText == "5/5 已就绪", "Claude Code 应显示 5/5 已就绪")
        expect(claude.status == .ready, "Claude Code 完整连接应使用 ready 状态")
        expect(codex.title == "Codex", "Codex 来源标题必须是 Codex")
        expect(codex.readinessText == "4/5 已就绪", "Codex 正常能力事实应显示 4/5 已就绪")
        expect(codex.status == .ready, "Codex 的 4/5 不得降级成 warning 或 needsAttention")
        expect(codex.detailText == "执行中断暂无事件", "Codex ready 行必须诚实说明缺少执行中断事件")
        expect(
            codex.accessibilityLabel == "Codex，4/5 已就绪，执行中断暂无事件",
            "宿主行 VoiceOver 必须完整读出宿主、能力与限定，实得 \(codex.accessibilityLabel)")
        expect(workBuddy.title == "WorkBuddy", "WorkBuddy 来源标题必须是 WorkBuddy")
        expect(workBuddy.readinessText == "2/5 已就绪", "WorkBuddy 当前实现必须显示 2/5")
        expect(
            workBuddy.detailText == "当前版本已实现 2/5；其余能力尚未启用",
            "接口能力与已实现能力不得混成假 5/5")
        expect(
            rows.allSatisfy { $0.host.descriptor.mechanism == .nativeHooks },
            "普通声音来源不得显示 Desktop AX Beta 占位")
        let groups = hostSourceProductGroups(from: rows)
        let visualOrder = hostSurfacePresentationOrder(from: rows)
        expect(groups.map(\.product) == HostProductID.allCases, "来源必须按产品稳定分组")
        expect(
            visualOrder
                == [.codex, .claudeCode, .workBuddy],
            "Product → Surface 必须形成来源卡、矩阵与焦点共用的唯一视觉顺序")
        expect(
            groups.first(where: { $0.product == .chatGPT })?.surfaces.map(\.host)
                == [.codex],
            "ChatGPT 产品在普通 UI 中只能包含 Codex surface")
        expect(
            groups.first(where: { $0.product == .claude })?.surfaces.map(\.host)
                == [.claudeCode],
            "Claude 产品在普通 UI 中只能包含 Claude Code surface")
        expect(
            Set(rows.map(\.host)).isDisjoint(with: [.chatGPTDesktopAX, .claudeDesktopAX]),
            "AX identity 不得通过产品分组重新进入普通 UI")
    }

    suite("声音来源行：缺少一个快照也不能隐藏该宿主；Codex 待确认文案固定") {
        let onlyClaude = hostSourceRowPresentations(
            from: hostPresentationMatrix(snapshots: [hostPresentationSnapshot(.claudeCode)]))
        expect(
            onlyClaude.map(\.host) == [.codex, .claudeCode, .workBuddy],
            "单宿主连接时仍须保留全部产品声音来源行")
        let disconnectedCodex = onlyClaude.first(where: { $0.host == .codex })!
        expect(disconnectedCodex.status == .notConnected, "没有 Codex 快照应呈现未连接")
        expect(
            disconnectedCodex.readinessText == "4/5 未连接",
            "未连接仍须保留 Codex 的 4/5 能力事实")

        let awaiting = hostSourceRowPresentations(
            from: hostPresentationMatrix(
                snapshots: [
                    hostPresentationSnapshot(.claudeCode),
                    hostPresentationSnapshot(
                        .codex,
                        activation: .awaitingReceipt(
                            installationID: hostPresentationInstallationID)),
                ]))
        let awaitingCodex = awaiting.first(where: { $0.host == .codex })!
        expect(awaitingCodex.status == .awaitingActivation, "等待首个真实回执必须是待确认状态")
        expect(awaitingCodex.readinessText == "4/5 已配置", "待确认不得冒充已连接")
        expect(
            awaitingCodex.detailText == "在 Codex 输入 /hooks，确认后再提交一次提示词",
            "Codex 待确认文案必须逐字固定，实得 \(String(describing: awaitingCodex.detailText))")
    }

    suite("legacy 检查器：必须提供升级、重探、清除历史与末尾断开，并复用 repair seam") {
        let legacySnapshot = HostIntegrationSnapshot(
            host: .claudeCode,
            runtime: .ready,
            availability: .available,
            configuration: .legacyConnected,
            writability: .writable,
            activation: .none)
        let rows = hostSourceRowPresentations(
            from: hostPresentationMatrix(snapshots: [legacySnapshot]))
        let legacy = rows.first(where: { $0.host == .claudeCode })!
        let actions = integrationsInspectorActions(for: legacy)

        expect(legacy.status == .legacy, "fixture 必须真实投影 legacy 行")
        expect(legacy.readinessText == "4/5 旧版连接", "legacy 汇总不得把任务开始算作已安装")
        expect(
            legacy.detailText == "四个旧版事件可听；任务开始需升级",
            "legacy 行的可见与无障碍摘要必须直接指出任务开始需要升级")
        expect(
            actions == [
                .repair(.claudeCode), .redetect, .clearReceiptHistory(.claudeCode),
                .disconnect(.claudeCode),
            ],
            "legacy 必须可升级、可重探、可清除历史且破坏性断开在末尾，实得 \(actions)")
        expect(
            integrationsInspectorActionTitle(
                .repair(.claudeCode), hostStatus: legacy.status) == "升级连接",
            "legacy 的 repair 可见标题必须是升级连接")
        expect(
            integrationsInspectorActionTitle(
                .repair(.claudeCode), hostStatus: .needsAttention)
                == "修复 Claude Code 连接",
            "真实损坏态仍应显示修复，不能一律叫升级")
    }

    suite("可听能力矩阵：严格由五个语义行 × registry 宿主单元组成") {
        let visualOrder = hostSurfacePresentationOrder()
        let presentation = hostCapabilityMatrixPresentation(from: hostPresentationMatrix())

        expect(presentation.hostColumns == visualOrder, "矩阵宿主列必须服从 Product → Surface 视觉序")
        expect(presentation.rows.map(\.event) == Event.allCases, "矩阵事件行必须来自 Event.allCases")
        expect(presentation.rows.count == 5, "矩阵必须有五个事件行")
        expect(
            presentation.rows.allSatisfy { $0.cells.map(\.host) == visualOrder },
            "每个事件行必须按同一视觉顺序提供全部单元")
        expect(
            presentation.rows.flatMap(\.cells).count == Event.allCases.count
                * HostID.productVisibleCases.count,
            "标准矩阵必须完整提供全部事件与宿主组合")

        let permission = presentation.cell(host: .codex, event: .notification)
        expect(
            permission?.nativeEventText == "PermissionRequest", "Codex 待响应必须显示原生 PermissionRequest")
        expect(permission?.qualificationText == "仅授权请求", "可见文案必须显示“仅授权请求”")
        let permissionLabel = permission?.accessibilityLabel ?? ""
        for required in [
            "Codex", "待响应", "部分支持", "仅授权请求", "已连接",
        ] {
            expect(
                permissionLabel.contains(required),
                "VoiceOver label 必须包含 \(required)，实得 \(permissionLabel)")
        }

        let interruption = presentation.cell(host: .codex, event: .stopFailure)
        expect(interruption?.state == .unsupported, "Codex 执行中断必须严格是不支持")
        expect(interruption?.nativeEventText == nil, "不支持的 Codex 执行中断不得伪造原生事件名")
        expect(interruption?.statusText == "不支持", "不支持状态必须同时用文字编码")
    }

    suite("可听能力矩阵：删除 adapter 映射会暴露缺失，不得由 GUI 硬编码补回第四格") {
        var capabilities = Dictionary(
            uniqueKeysWithValues: HostID.productVisibleCases.map {
                ($0, HostCapabilityCatalog.bindings(for: $0))
            })
        capabilities[.codex] = capabilities[.codex]?.filter { $0.event != .notification }

        let presentation = hostCapabilityMatrixPresentation(
            from: hostPresentationMatrix(capabilities: capabilities))
        let missing = presentation.cell(host: .codex, event: .notification)

        expect(missing?.state == .unsupported, "缺少 adapter 映射的格子必须 fail closed 为 unsupported")
        expect(missing?.nativeEventText == nil, "GUI 不得硬编码补回 PermissionRequest")
        expect(
            missing?.qualificationText == "此宿主未声明该能力",
            "缺映射必须保留 Core 生成的诊断限定语，实得 \(String(describing: missing?.qualificationText))")
        expect(
            missing?.accessibilityLabel.contains("仅授权请求") == false,
            "删除 adapter 映射后 VoiceOver 也不得残留硬编码限定语")
    }

    suite("菜单栏事件宿主 Logo：8 种矩阵状态按固定规则映射彩色或灰色") {
        let cases:
            [(
                AudibilityCellState, EventHostIndicatorState, Bool, String
            )] = [
                (.audible, .connected, true, "已连接"),
                (.muted, .connected, true, "已连接"),
                (.missingSound, .connected, true, "已连接"),
                (.legacy, .legacy, true, "旧版连接"),
                (.notConnected, .notConnected, false, "未连接"),
                (.awaitingActivation, .awaitingActivation, false, "待激活"),
                (.unsupported, .unsupported, false, "此事件不支持"),
                (.degraded, .needsAttention, false, "需处理"),
            ]

        for (cellState, expectedState, expectedColor, expectedHelp) in cases {
            let matrix = HostCapabilityMatrixPresentation(
                hostColumns: [.claudeCode],
                rows: [
                    HostCapabilityEventRowPresentation(
                        event: .stop,
                        title: Event.stop.displayName,
                        cells: [
                            HostCapabilityCellPresentation(
                                host: .claudeCode,
                                event: .stop,
                                state: cellState)
                        ])
                ])
            let indicators = eventHostIndicatorPresentations(event: .stop, matrix: matrix)
            expect(indicators.count == 1, "每个 hostColumns 项必须生成一枚 Logo")
            expect(
                indicators.first?.state == expectedState,
                "\(cellState) 应映射为 \(expectedState)，实得 \(String(describing: indicators.first?.state))"
            )
            expect(
                indicators.first?.state.usesActiveColor == expectedColor,
                "\(cellState) 的彩色规则错误")
            expect(indicators.first?.helpText == expectedHelp, "\(cellState) 的鼠标帮助错误")
        }
    }

    suite("菜单栏事件宿主 Logo：顺序只取 matrix.hostColumns，缺失格 fail closed") {
        let matrix = HostCapabilityMatrixPresentation(
            hostColumns: [.codex, .claudeCode],
            rows: [
                HostCapabilityEventRowPresentation(
                    event: .stop,
                    title: Event.stop.displayName,
                    cells: [
                        HostCapabilityCellPresentation(
                            host: .claudeCode,
                            event: .stop,
                            state: .audible)
                    ])
            ])
        let indicators = eventHostIndicatorPresentations(event: .stop, matrix: matrix)

        expect(
            indicators.map(\.host) == [.codex, .claudeCode],
            "Logo 顺序必须逐字服从 matrix.hostColumns，实得 \(indicators.map(\.host))")
        expect(
            indicators.map(\.compactDisplayName) == ["Codex", "Claude"],
            "紧凑视觉名必须随共享投影及宿主列顺序输出")
        expect(
            indicators[0].state == .unsupported && !indicators[0].state.usesActiveColor,
            "缺失的 Codex 格必须保留 Logo 并 fail closed 为灰色不支持")
        expect(indicators[1].state == .connected, "存在的 Claude Code 可听格必须保持彩色")
    }

    suite("菜单栏事件宿主 Logo：Codex 限定语进入编辑入口，StopFailure 永久灰色") {
        let matrix = hostCapabilityMatrixPresentation(from: hostPresentationMatrix())
        let notification = eventHostIndicatorPresentations(event: .notification, matrix: matrix)
        let interruption = eventHostIndicatorPresentations(event: .stopFailure, matrix: matrix)
        let codexNotification = notification.first(where: { $0.host == .codex })
        let codexInterruption = interruption.first(where: { $0.host == .codex })

        expect(
            notification.map(\.host)
                == matrix.hostColumns.filter { $0.descriptor.mechanism == .nativeHooks },
            "菜单栏只展示可配置 native surface，并保持其 registry 顺序")
        expect(
            codexNotification?.qualificationText == "仅授权请求"
                && codexNotification?.accessibilityLabel == "Codex，已连接，仅授权请求",
            "Codex 待响应必须把完整工具名、连接状态和能力限定合并进 VoiceOver label")
        expect(
            codexInterruption?.state == .unsupported
                && codexInterruption?.state.usesActiveColor == false,
            "Codex StopFailure 即使宿主已连接也必须永久灰色")
        expect(
            codexInterruption?.helpText == "此事件不支持",
            "Codex StopFailure 鼠标帮助必须明确说明事件不支持")
    }

    suite("宿主 Logo 资源与状态色：HostID 穷举映射固定到两枚 template PDF") {
        expect(
            eventHostIndicatorCompactDisplayName(for: .claudeCode) == "Claude",
            "Claude Code 只在事件行视觉标签中缩写为 Claude")
        expect(
            eventHostIndicatorCompactDisplayName(for: .codex) == "Codex",
            "Codex 的事件行视觉标签错误")
        expect(eventHostIndicatorAssetName(for: .claudeCode) == "claude", "Claude 资源名错误")
        expect(eventHostIndicatorAssetName(for: .codex) == "codex", "Codex 资源名错误")
        expect(
            eventHostIndicatorPalette(for: .claudeCode)
                == EventHostIndicatorPalette(lightHex: "BD6549", darkHex: "E48667"),
            "Claude 连接状态色必须匹配批准 mockup")
        expect(
            eventHostIndicatorPalette(for: .codex)
                == EventHostIndicatorPalette(lightHex: "318A50", darkHex: "79C995"),
            "Codex 连接状态色必须匹配批准 mockup")
    }

    suite("IntegrationsWindow 主动状态播报：共享宿主行与矩阵格补齐事件、连接状态及能力限定") {
        let matrix = hostCapabilityMatrixPresentation(from: hostPresentationMatrix())
        let codexRow = hostSourceRowPresentations(from: hostPresentationMatrix())
            .first(where: { $0.host == .codex })!
        let permission = matrix.cell(host: .codex, event: .notification)!
        let receiptAnnouncement = integrationsStateChangeAccessibilityLabel(
            message: "收到当前代次真实回执：已播放",
            hostRow: codexRow,
            capabilityCells: [permission])

        for required in [
            "Codex", "4/5 已就绪", "待响应", "仅授权请求",
            "已连接", "收到当前代次真实回执",
        ] {
            expect(
                receiptAnnouncement.contains(required),
                "真实回执主动播报必须包含 \(required)，实得 \(receiptAnnouncement)")
        }

        let refreshAnnouncement = integrationsStateChangeAccessibilityLabel(
            message: "已重新检测声音来源",
            hostRow: codexRow,
            capabilityCells: matrix.rows.compactMap {
                $0.cells.first(where: { $0.host == .codex })
            })
        expect(
            refreshAnnouncement.contains("任务开始")
                && refreshAnnouncement.contains("本轮结束")
                && refreshAnnouncement.contains("执行中断")
                && refreshAnnouncement.contains("待响应")
                && refreshAnnouncement.contains("子任务结束"),
            "宿主级 refresh 必须从共享矩阵播出五个事件，而不是只有一句无上下文的完成提示")
        expect(
            refreshAnnouncement.contains("仅授权请求")
                && refreshAnnouncement.contains("已连接"),
            "宿主级 refresh 仍须保留 Codex 的能力限定与连接状态")
    }

    suite("真实回执摘要：只投影 observed 的宿主、事件、时间与脱敏结果") {
        let observed = hostPresentationSnapshot(.claudeCode)
        let text = hostLatestReceiptText(snapshot: observed)
        expect(
            hostLatestReceiptEvidence(snapshot: observed)?.event == .taskStart,
            "结构化回执必须来自同一份 observed evidence，不能反向解析摘要字符串")
        expect(text?.contains("Claude Code · 任务开始") == true, "回执摘要必须包含宿主与声音语义")
        expect(text?.contains("UserPromptSubmit") == false, "回执主文案不得泄漏宿主原生 key")
        expect(text?.contains("1970-01-01T00:01:40.000Z") == true, "回执摘要必须保留 ISO 8601 小数秒")
        expect(text?.hasSuffix("· 已播放") == true, "回执摘要必须显示脱敏播放结果")
        expect(
            text?.contains(hostPresentationInstallationID.uuidString) == false,
            "检查器不得显示 installation ID")
        expect(text?.contains("/") == false, "检查器不得显示绝对路径")

        let awaiting = hostPresentationSnapshot(
            .codex,
            activation: .awaitingReceipt(installationID: hostPresentationInstallationID))
        expect(
            hostLatestReceiptText(snapshot: awaiting) == nil,
            "待确认不能伪造最近真实回执")
        expect(hostLatestReceiptEvidence(snapshot: awaiting) == nil, "待确认也不能伪造回执 evidence")
    }

    suite("真实回执变化：同毫秒摘要相同时仍由完整 evidence 区分") {
        let binding = HostCapabilityCatalog.bindings(for: .claudeCode)
            .first(where: { $0.isAudibleCapability })!
        func snapshot(at interval: TimeInterval) -> HostIntegrationSnapshot {
            hostPresentationSnapshot(
                .claudeCode,
                activation: .observed(
                    HostReceiptEvidence(
                        installationID: hostPresentationInstallationID,
                        nativeEvent: binding.nativeEvent!,
                        event: binding.event,
                        timestamp: Date(timeIntervalSince1970: interval),
                        playbackResult: .played)))
        }
        let earlier = snapshot(at: 100.1234)
        let later = snapshot(at: 100.1235)

        expect(
            hostLatestReceiptText(snapshot: earlier) == hostLatestReceiptText(snapshot: later),
            "测试前提：可见 ISO 摘要在同毫秒内可能相同")
        guard let earlierEvidence = hostLatestReceiptEvidence(snapshot: earlier),
            let laterEvidence = hostLatestReceiptEvidence(snapshot: later)
        else {
            expect(false, "observed snapshot 必须暴露结构化 evidence")
            return
        }
        expect(earlierEvidence != laterEvidence, "变化判定不得被相同摘要吞掉")
        expect(
            earlierEvidence.timestamp < laterEvidence.timestamp,
            "结构化 evidence 必须保留同毫秒内的真实顺序")
    }

    suite("真实回执播放结果：六种 Core 结果全部有中文且不泄漏 ID/路径") {
        let binding = HostCapabilityCatalog.bindings(for: .claudeCode)
            .first(where: { $0.isAudibleCapability })!
        let cases: [(HostHookPlaybackResult, String)] = [
            (.played, "已播放"),
            (.muted, "已静音"),
            (.debounced, "防抖跳过"),
            (.notReady, "声音未就绪"),
            (.unsupportedEvent, "事件不支持"),
            (.playbackFailed, "播放失败"),
        ]

        for (result, expected) in cases {
            expect(
                hostHookPlaybackResultDisplayName(result) == expected,
                "\(result) 应投影为 \(expected)")
            let snapshot = HostIntegrationSnapshot(
                host: .claudeCode,
                runtime: .ready,
                availability: .available,
                configuration: .configured,
                writability: .writable,
                activation: .observed(
                    HostReceiptEvidence(
                        installationID: hostPresentationInstallationID,
                        nativeEvent: binding.nativeEvent!,
                        event: binding.event,
                        timestamp: Date(timeIntervalSince1970: 100),
                        playbackResult: result)),
                latestReceipt: HostReceiptEvidence(
                    installationID: hostPresentationInstallationID,
                    nativeEvent: binding.nativeEvent!,
                    event: binding.event,
                    timestamp: Date(timeIntervalSince1970: 100),
                    playbackResult: result),
                installationID: hostPresentationInstallationID)
            let resultText = hostLatestReceiptText(snapshot: snapshot)
            expect(resultText?.hasSuffix("· \(expected)") == true, "回执摘要必须包含 \(expected)")
            expect(
                resultText?.contains(hostPresentationInstallationID.uuidString) == false,
                "\(result) 回执不得泄漏 installation ID")
            expect(resultText?.contains("/") == false, "\(result) 回执不得泄漏绝对路径")
        }
    }

    suite("IntegrationsWindow 布局：默认三列改用事件卡，足够宽才显示矩阵") {
        let defaultWindowCapabilityWidth = 840.0 - max(300.0, 840.0 * 0.39) - 41.0
        let defaultWindow = integrationsWindowLayoutAdaptation(
            for: .standard,
            availableWidth: defaultWindowCapabilityWidth)
        let wide = integrationsWindowLayoutAdaptation(
            for: .standard,
            availableWidth: 1_000)
        let maximum = integrationsWindowLayoutAdaptation(
            for: .maximum,
            availableWidth: 1_000)

        expect(
            defaultWindow.mode
                == .eventCards(
                    cardCount: Event.allCases.count,
                    hostRowsPerCard: HostID.productVisibleCases.count),
            "默认 840px 左右分栏的三列空间不足，必须使用纵向事件卡，实得 \(defaultWindow.mode)")
        expect(!defaultWindow.allowsHorizontalScrolling, "默认窗口不得用横向滚动隐藏拥挤")
        expect(
            wide.mode
                == .capabilityMatrix(
                    eventRowCount: Event.allCases.count,
                    hostColumnCount: HostID.productVisibleCases.count),
            "每个宿主列达到可读宽度后应恢复完整动态矩阵，实得 \(wide.mode)")
        expect(!wide.allowsHorizontalScrolling, "宽窗口矩阵也不应依赖横向滚动")
        expect(
            maximum.mode
                == .eventCards(
                    cardCount: Event.allCases.count,
                    hostRowsPerCard: HostID.productVisibleCases.count),
            "最大字号必须重排为事件卡并保留全部宿主子行，实得 \(maximum.mode)")
        expect(!maximum.allowsHorizontalScrolling, "最大字号严禁横向滚动或裁切")
    }

    suite("IntegrationsWindow 焦点序：宿主摘要领先、矩阵逐行、检查器视觉序随后，断开永远最后") {
        let visualOrder = hostSurfacePresentationOrder()
        let matrix = hostCapabilityMatrixPresentation(
            from: hostPresentationMatrix(),
            hostOrder: visualOrder)
        let scope = IntegrationsWindowFocusScope(
            matrix: matrix,
            hostOrder: visualOrder,
            inspectorActions: [
                .disconnect(.codex), .copyHooksCommand, .redetect, .connect(.claudeCode),
            ],
            recoveryAction: .repair(.codex),
            configurationPathHost: .codex,
            feedbackRevision: 7)
        let order = integrationsWindowFocusOrder(scope)
        let expectedCells = Event.allCases.flatMap { event in
            visualOrder.map {
                IntegrationsWindowFocusTarget.capabilityCell(host: $0, event: event)
            }
        }

        let hostCount = visualOrder.count
        let cellCount = Event.allCases.count * hostCount
        expect(
            Array(order.prefix(hostCount)) == visualOrder.map { .hostCard($0) },
            "焦点必须先按 Product → Surface 视觉序经过所有等权宿主卡")
        expect(
            Array(order.dropFirst(hostCount).prefix(cellCount)) == expectedCells,
            "焦点随后必须按事件行、宿主列遍历全部真实矩阵单元")
        expect(
            order.dropFirst(hostCount + cellCount).prefix(6) == [
                .copyConfigurationPath(.codex),
                .dismissFeedback(revision: 7),
                .recoveryAction(.repair(.codex)),
                .inspectorAction(.copyHooksCommand),
                .inspectorAction(.redetect),
                .inspectorAction(.connect(.claudeCode)),
            ],
            "配置路径、反馈、主恢复与非破坏检查器动作应按视觉序排在断开之前")
        expect(
            order.last == .inspectorAction(.disconnect(.codex)),
            "破坏性的断开必须无条件位于详情窗焦点序末尾")
    }

    suite("IntegrationsWindow 反馈：短暂、可关闭、可过期，VoiceOver 带宿主且 Reduce Motion 禁用位移动画") {
        let now = Date(timeIntervalSince1970: 1_000)
        var feedback = IntegrationsFeedbackModel()
        let fullAnnouncement =
            "Codex，4/5 已就绪。Codex，待响应，仅授权请求，已连接"
        let revision = feedback.present(
            host: .codex,
            kind: .information,
            message: "Claudio 已写好，等待 Codex 确认",
            accessibilityAnnouncement: fullAnnouncement,
            now: now)
        let banner = feedback.activeFeedback(at: now)

        expect(banner?.revision == revision, "present 应返回当前反馈代次")
        expect(banner?.isDismissible == true, "状态反馈必须提供显式关闭")
        expect(
            banner?.expiresAt == now.addingTimeInterval(integrationsFeedbackLifetime),
            "状态反馈必须使用固定短生命周期")
        expect(
            banner?.message == "Claudio 已写好，等待 Codex 确认",
            "可见反馈必须继续保持短文案")
        expect(
            banner?.accessibilityLabel == fullAnnouncement,
            "主动播报必须允许使用共享 presentation 生成的完整上下文，实得 "
                + "\(String(describing: banner?.accessibilityLabel))")
        expect(
            integrationsFeedbackTransition(reduceMotionEnabled: false) == .opacity,
            "普通模式只使用短促透明度反馈")
        expect(
            integrationsFeedbackTransition(reduceMotionEnabled: true) == .immediate,
            "Reduce Motion 开启时必须取消动画")
        expect(
            feedback.activeFeedback(
                at: now.addingTimeInterval(integrationsFeedbackLifetime)) == nil,
            "反馈到期边界必须立即不可见")

        feedback.expire(at: now.addingTimeInterval(integrationsFeedbackLifetime))
        expect(feedback.current == nil, "expire 必须清理已到期反馈")
    }

    suite("IntegrationsWindow 反馈：旧关闭动作不能误关后来出现的新反馈") {
        let now = Date(timeIntervalSince1970: 2_000)
        var feedback = IntegrationsFeedbackModel()
        let oldRevision = feedback.present(
            host: .claudeCode, kind: .success, message: "Claude Code 已连接", now: now)
        let newRevision = feedback.present(
            host: .codex, kind: .failure, message: "Codex 重新检测失败", now: now)

        feedback.dismiss(revision: oldRevision)
        expect(
            feedback.current?.revision == newRevision,
            "旧 banner 的延迟关闭事件不得清掉更新后的反馈")
        feedback.dismiss(revision: newRevision)
        expect(feedback.current == nil, "当前 banner 的关闭动作必须立即生效")
    }

    suite("IntegrationsWindow 完整播报覆盖：成功与失败 outcome 都不回落成短文案") {
        let now = Date(timeIntervalSince1970: 2_500)
        let announcement =
            "Codex，4/5 已就绪。Codex，待响应，仅授权请求，已连接"
        for (kind, message) in [
            (IntegrationsFeedbackKind.success, "Codex 已连接"),
            (IntegrationsFeedbackKind.failure, "Codex 连接失败"),
        ] {
            var feedback = IntegrationsFeedbackModel()
            _ = feedback.present(
                host: .codex,
                kind: kind,
                message: message,
                accessibilityAnnouncement: announcement,
                now: now)
            expect(feedback.current?.message == message, "可见 outcome 反馈仍须保持短文案")
            expect(
                feedback.current?.accessibilityLabel == announcement,
                "\(kind) outcome 的主动播报必须保留共享 presentation 完整上下文")
        }
    }

    suite("IntegrationsWindow 反馈播报：新 revision 恰好一次；关闭/过期 nil 不播也不重置去重") {
        let now = Date(timeIntervalSince1970: 3_000)
        let first = IntegrationsFeedback(
            revision: 1,
            host: .codex,
            kind: .information,
            message: "Claudio 已写好，等待 Codex 确认",
            expiresAt: now.addingTimeInterval(5))
        let second = IntegrationsFeedback(
            revision: 2,
            host: .claudeCode,
            kind: .failure,
            message: "连接失败",
            expiresAt: now.addingTimeInterval(5))
        var announcer = IntegrationsFeedbackAnnouncementModel()

        expect(
            announcer.consume(first) == first.accessibilityLabel,
            "新反馈必须主动播完整宿主限定句")
        expect(announcer.consume(first) == nil, "同一 revision 不得重复播报")
        expect(announcer.consume(nil) == nil, "关闭或到期不得播一条空通知")
        expect(announcer.consume(first) == nil, "nil 不得重置去重、让旧反馈复活")
        expect(
            announcer.consume(second) == second.accessibilityLabel,
            "新 revision 必须独立播报")
    }

    suite("IntegrationsWindow 双宿主同帧回执：逐条反馈、独立 revision，关闭或到期后推进") {
        let now = Date(timeIntervalSince1970: 3_500)
        let requests = [
            IntegrationsFeedbackRequest(
                host: .claudeCode,
                kind: .information,
                message: "收到 Claude Code 回执",
                accessibilityAnnouncement: "Claude Code，本轮结束，已连接，收到真实回执"),
            IntegrationsFeedbackRequest(
                host: .codex,
                kind: .information,
                message: "收到 Codex 回执",
                accessibilityAnnouncement: "Codex，待响应，仅授权请求，已连接，收到真实回执"),
        ]

        var dismissedSequence = IntegrationsFeedbackModel()
        guard let firstRevision = dismissedSequence.presentSequence(requests, now: now) else {
            expect(false, "非空反馈序列必须立即呈现第一条")
            return
        }
        let firstFeedback = dismissedSequence.current
        expect(dismissedSequence.current?.host == .claudeCode, "第一条必须按宿主稳定顺序呈现")
        dismissedSequence.dismiss(revision: firstRevision, now: now.addingTimeInterval(1))
        let secondAfterDismiss = dismissedSequence.current
        expect(secondAfterDismiss?.host == .codex, "关闭第一条后必须推进第二宿主反馈")
        expect(secondAfterDismiss?.revision != firstRevision, "两条回执必须使用独立 revision 去重")
        expect(
            secondAfterDismiss?.expiresAt
                == now.addingTimeInterval(1 + integrationsFeedbackLifetime),
            "第二条必须从实际呈现时重新计算短生命周期")

        var expiredSequence = IntegrationsFeedbackModel()
        let firstBeforeExpiry = expiredSequence.presentSequence(requests, now: now)
        expiredSequence.expire(at: now.addingTimeInterval(integrationsFeedbackLifetime))
        let secondAfterExpiry = expiredSequence.current
        expect(secondAfterExpiry?.host == .codex, "第一条自然到期后也必须推进第二宿主反馈")
        expect(secondAfterExpiry?.revision != firstBeforeExpiry, "自然推进也必须分配独立 revision")
        expect(
            secondAfterExpiry?.expiresAt
                == now.addingTimeInterval(2 * integrationsFeedbackLifetime),
            "自然推进后的第二条也必须重新获得完整 5 秒生命周期")

        var announcer = IntegrationsFeedbackAnnouncementModel()
        let firstSentence = announcer.consume(firstFeedback)
        let secondSentence = announcer.consume(secondAfterDismiss)
        expect(firstSentence == requests[0].accessibilityAnnouncement, "第一宿主必须产生完整 VoiceOver 句")
        expect(secondSentence == requests[1].accessibilityAnnouncement, "第二宿主必须产生完整 VoiceOver 句")
    }

    suite("IntegrationsWindow 当前操作：目标宿主、可见文字与 VoiceOver 同源，legacy repair 为升级中") {
        let cases: [(IntegrationsWindowInspectorAction, HostSourceRowStatus?, String)] = [
            (.redetect, .ready, "重新检测中"),
            (.connect(.codex), .notConnected, "连接中"),
            (.repair(.claudeCode), .needsAttention, "修复中"),
            (.repair(.claudeCode), .legacy, "升级中"),
            (.disconnect(.codex), .ready, "断开中"),
            (.clearReceiptHistory(.workBuddy), .ready, "清除回执历史中"),
        ]
        for (action, status, expected) in cases {
            let operation = integrationsInFlightPresentation(
                action: action,
                selectedHost: .claudeCode,
                hostStatus: status)
            expect(operation?.statusText == expected, "\(action) 应显示 \(expected)")
            expect(
                operation?.accessibilityLabel.contains(expected) == true,
                "\(action) 的限定语必须进入 VoiceOver")
        }
        expect(
            integrationsInFlightPresentation(
                action: .redetect,
                selectedHost: .codex,
                hostStatus: .ready)?.host == .codex,
            "重新检测必须显示在当前选择的宿主卡")
        expect(
            integrationsInFlightPresentation(
                action: .copyHooksCommand,
                selectedHost: .codex,
                hostStatus: .awaitingActivation) == nil,
            "同步复制动作不应制造虚假的进行中态")
    }
}
