import ClaudioCore
import ClaudioGUICore
import Foundation

private func panelPresentationRow(
    _ host: HostID,
    status: HostSourceRowStatus,
    supported: Int
) -> HostSourceRowPresentation {
    HostSourceRowPresentation(
        host: host,
        title: host.displayName,
        readinessText: "fixture",
        detailText: nil,
        status: status,
        supportedCount: supported,
        totalCount: Event.allCases.count)
}

private func panelPresentationEventRows(
    coverage: CoverageState = .present(fileName: "tone.aiff")
) -> [EventRow] {
    Event.allCases.map { EventRow(event: $0, coverage: coverage, enabled: true) }
}

@MainActor
func runPanelPresentationSuites() async {
    suite("事件与提示音路由：保留 Global/Surface，并为声音编辑携带同一作用域") {
        let global = EventSettingsWindowRoute(scope: .global)
        let workBuddy = EventSettingsWindowRoute(scope: .surface(.workBuddy), event: .stop)

        expect(global.surface == nil, "Global 路由不得伪造 Host Surface")
        expect(workBuddy.surface == .workBuddy, "WorkBuddy 路由必须保留稳定 surface token")
        expect(workBuddy.event == .stop, "设置深链接必须保留稳定公共 Event token")
        expect(
            workBuddy.soundPacksRoute(packID: "user-pack", event: .stop)
                == .editEvent(surface: .workBuddy, packID: "user-pack", event: .stop),
            "逐事件声音编辑必须把当前 Surface 原样交给声音包窗口")
        expect(
            eventSettingsFirstFocusTarget(scopes: [.global, .surface(.workBuddy)])
                == .scope(.global),
            "事件设置窗口必须把首个可见作用域作为确定性首焦点")
        expect(
            eventSettingsFirstFocusTarget(scopes: []) == nil,
            "没有作用域时不得伪造焦点身份")
        expect(
            eventSettingsRouteFocusTarget(
                route: workBuddy,
                scopes: [.global, .surface(.workBuddy)]) == .event(.stop),
            "scope/Event 深链接必须把焦点交给精确事件身份")
        expect(
            eventSettingsRouteFocusTarget(
                route: workBuddy,
                scopes: [.global]) == .scope(.global),
            "陈旧 Surface 不得留下可写事件焦点，必须回到可见安全 scope")

        let sparseConfig = ClaudioConfig(
            selectedPack: "global",
            surfaceOverrides: [
                HostSurfaceID.workBuddy.rawValue: SurfaceSoundOverride(
                    eventsEnabled: [Event.stop.cliName: false])
            ])
        expect(
            eventSettingsInheritanceState(
                config: sparseConfig,
                scope: .surface(.workBuddy),
                event: .stop) == .surfaceOverride,
            "逐 Event 显式覆盖必须可见为 Surface override")
        expect(
            eventSettingsInheritanceState(
                config: sparseConfig,
                scope: .surface(.workBuddy),
                event: .taskStart) == .inheritedGlobal,
            "同 Surface 未覆盖的 Event 必须明确显示继承 Global")
        expect(
            eventSettingsPackInheritanceState(
                config: sparseConfig,
                scope: .surface(.workBuddy)) == .inheritedGlobal,
            "只有 Event 覆盖时，声音包仍必须明确显示继承 Global")

        let packOverrideConfig = ClaudioConfig(
            selectedPack: "global",
            surfaceOverrides: [
                HostSurfaceID.workBuddy.rawValue: SurfaceSoundOverride(selectedPack: "surface")
            ])
        expect(
            eventSettingsPackInheritanceState(
                config: packOverrideConfig,
                scope: .surface(.workBuddy)) == .surfaceOverride,
            "只有 selected_pack 覆盖时，声音包才显示 Surface override")

        let invalidOverrideConfig = ClaudioConfig(
            selectedPack: "global",
            surfaceOverrides: sparseConfig.surfaceOverrides,
            invalidSurfaceOverrideKeys: [HostSurfaceID.workBuddy.rawValue])
        expect(
            eventSettingsPackInheritanceState(
                config: invalidOverrideConfig,
                scope: .surface(.workBuddy)) == .invalidSurfaceOverride,
            "损坏 Surface 的声音包继承必须 fail closed")
        expect(
            !eventSettingsShouldCloseAICueComposer(
                includesAICueComposer: false,
                targetSurface: .workBuddy,
                selectedSurface: .codex),
            "不呈现 composer 的只读投影不得结束其他表面的 AI session")
        expect(
            eventSettingsShouldCloseAICueComposer(
                includesAICueComposer: true,
                targetSurface: .workBuddy,
                selectedSurface: .codex),
            "composer 切换到另一 scope 时必须结束旧 session")
        expect(
            !eventSettingsShouldCloseAICueComposer(
                includesAICueComposer: true,
                targetSurface: .workBuddy,
                selectedSurface: .workBuddy),
            "composer 留在同一 scope 时不得误关 session")
        expect(
            eventSettingsShouldCloseAICueComposer(
                includesAICueComposer: true,
                targetSurface: .workBuddy,
                targetEvent: .stop,
                selectedSurface: .workBuddy,
                selectedEvent: .notification),
            "同一 Surface 显式切换 Event 路由也必须结束旧候选 session")
        expect(
            !eventSettingsShouldCloseAICueComposer(
                includesAICueComposer: true,
                targetSurface: .workBuddy,
                targetEvent: .stop,
                selectedSurface: .workBuddy,
                selectedEvent: nil),
            "没有显式 Event 路由变化时不得因可选焦点为空误关 session")
        expect(
            eventSettingsAICueComposerMatches(
                targetSurface: .workBuddy,
                targetEvent: .stop,
                selectedSurface: .workBuddy,
                event: .stop),
            "legacy composer 只在精确 Surface/Event 下显示")
        expect(
            !eventSettingsAICueComposerMatches(
                targetSurface: .workBuddy,
                targetEvent: .stop,
                selectedSurface: .codex,
                event: .stop),
            "同 Event 的另一 Surface 不得显示或采用 legacy composer session")
        expect(
            !eventSettingsAICueComposerMatches(
                targetSurface: nil,
                targetEvent: nil,
                selectedSurface: .workBuddy,
                event: .stop),
            "没有 AI target 时不得显示 composer")

        let baseIdentity = "Stop, Claude Code Stop"
        expect(
            eventSettingsIdentityAccessibilityLabel(
                presentationLabel: baseIdentity,
                inheritanceText: nil,
                language: .english) == baseIdentity,
            "Global Event identity 没有继承状态时不得增加空 AX 片段")
        expect(
            eventSettingsIdentityAccessibilityLabel(
                presentationLabel: baseIdentity,
                inheritanceText: "Inherited from Global",
                language: .english)
                == "Stop, Claude Code Stop, Inherited from Global",
            "英文 Event AX identity 必须包含可见继承状态")
        expect(
            eventSettingsIdentityAccessibilityLabel(
                presentationLabel: "停止，Claude Code Stop",
                inheritanceText: "继承 Global",
                language: .zhHans)
                == "停止，Claude Code Stop，继承 Global",
            "中文 Event AX identity 必须包含可见继承状态并使用中文分隔")

        withTempDirectory { directory in
            let unavailablePreview = eventPreviewFileURL(
                row: EventRow(
                    event: .stop,
                    coverage: .present(fileName: "missing.mp3"),
                    enabled: true),
                packID: "missing-pack",
                environment: AudioImportEnvironment(
                    userPacksDirectory: directory.appendingPathComponent("packs"),
                    durationProbe: StubDurationProbe(fixedDuration: 1),
                    packsLockFile: directory.appendingPathComponent("packs.lock")))
            expect(
                unavailablePreview == nil,
                "共享试听解析必须在包或文件已经失效时 fail closed")
        }
    }

    suite("事件设置作用域：与面板同源过滤未连接 Surface，陈旧深链接保留可见失败") {
        let rows = [
            panelPresentationRow(.claudeCode, status: .notConnected, supported: 5),
            panelPresentationRow(.workBuddy, status: .ready, supported: 2),
        ]
        let scopeIDs = panelSoundScopeIDs(sourceRows: rows)
        let panelScopes = panelSoundScopePresentations(
            sourceRows: rows,
            config: ClaudioConfig(selectedPack: "pack"),
            language: .zhHans)

        expect(
            scopeIDs == [.global, .surface(.workBuddy)]
                && panelScopes.map(\.scope) == scopeIDs,
            "面板与 Events route availability 必须消费同一份已配置/可用作用域真相")

        let availability = SettingsRouteAvailability(
            integrationSurfaces: [.claudeCode, .workBuddy],
            eventScopes: Set(scopeIDs),
            soundScopes: Set(scopeIDs),
            soundPackIDs: [],
            events: Set(Event.allCases))
        let disconnected = resolveSettingsRoute(
            .events(scope: .surface(.claudeCode), event: .stop),
            availability: availability)
        let available = resolveSettingsRoute(
            .events(scope: .surface(.workBuddy), event: .stop),
            availability: availability)

        expect(
            disconnected.failure == .staleSurface(.claudeCode),
            "未连接 Surface 不得出现在 Events 选择器，typed deep link 必须留下可见失败")
        expect(available.failure == nil, "可用 Surface 的 typed deep link 必须继续正常解析")
    }

    await suite("试听全部：离主线程规划真实文件、保持公共事件顺序并可取消") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            let pack = packs.appendingPathComponent("pack", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: pack,
                withIntermediateDirectories: true)
            try? Data([0x52, 0x49, 0x46, 0x46]).write(
                to: pack.appendingPathComponent("task.aiff"))
            try? Data([0x52, 0x49, 0x46, 0x46]).write(
                to: pack.appendingPathComponent("stop.aiff"))
            let rows = [
                EventRow(
                    event: .taskStart,
                    coverage: .present(fileName: "task.aiff"),
                    enabled: true),
                EventRow(
                    event: .stop,
                    coverage: .present(fileName: "stop.aiff"),
                    enabled: true),
                EventRow(
                    event: .subagentStop,
                    coverage: .present(fileName: "vanished.aiff"),
                    enabled: true),
            ]
            let presentations = panelEventPresentations(
                rows: rows,
                scope: .global,
                masterVolume: 0.8,
                language: .english)
            let environment = AudioImportEnvironment(
                userPacksDirectory: packs,
                durationProbe: StubDurationProbe(fixedDuration: 0.2),
                packsLockFile: root.appendingPathComponent("packs.lock"))
            let plan = makeEventPreviewSequencePlan(
                presentations: presentations,
                rows: rows,
                packID: "pack",
                environment: environment)
            expect(
                plan.map(\.event) == [.taskStart, .stop],
                "规划必须保持公共事件顺序，并在播放前剔除已失效文件")
            expect(
                plan.allSatisfy { $0.delayNanoseconds == 350_000_000 },
                "每项等待必须消费注入时长并追加固定切换间隔")
        }

        let coordinator = EventPreviewSequenceCoordinator()
        let items = [
            EventPreviewSequenceItem(
                event: .taskStart,
                fileURL: URL(fileURLWithPath: "/fixture/task.aiff"),
                delayNanoseconds: 5_000_000_000),
            EventPreviewSequenceItem(
                event: .stop,
                fileURL: URL(fileURLWithPath: "/fixture/stop.aiff"),
                delayNanoseconds: 1),
        ]
        var played: [Event] = []
        let run = Task { @MainActor in
            await coordinator.run(
                makePlan: { items },
                onPlay: { played.append($0.event) })
        }
        while played.isEmpty {
            await Task.yield()
        }
        coordinator.cancel()
        expect(await run.value == .cancelled, "scope/单项试听切换必须取消在途序列")
        expect(played == [.taskStart], "取消后不得继续播放下一公共事件")
    }

    suite("事件与提示音窗口布局：按窗口可用宽度与文字缩放独立降级") {
        let regular = eventSettingsWindowLayout(availableWidth: 580, typeScale: 1)
        let narrow = eventSettingsWindowLayout(availableWidth: 430, typeScale: 1)
        let maximumText = eventSettingsWindowLayout(availableWidth: 580, typeScale: 1.42)

        expect(
            !regular.metadataStacks && !regular.actionsMoveBelow,
            "标准窗口宽度下元数据与动作必须保持行内：\(regular)")
        expect(
            narrow.metadataStacks && narrow.actionsMoveBelow,
            "窄窗口必须把元数据和动作逐级堆叠：\(narrow)")
        expect(
            maximumText.metadataStacks && maximumText.actionsMoveBelow,
            "最大界面文字必须在同一窗口宽度触发窗口自己的降级：\(maximumText)")
    }

    suite("声音作用域菜单：未取得视口测量时仍提供可见选项与诊断入口") {
        let unmeasured = panelSoundScopeMenuLayout(
            scopeCount: 3,
            typeScale: 1,
            availableHeight: 0)
        let invalidMeasurement = panelSoundScopeMenuLayout(
            scopeCount: 3,
            typeScale: 1,
            availableHeight: .nan)

        expect(unmeasured.optionsHeight == 144, "三个标准字号来源必须完整显示：\(unmeasured)")
        expect(unmeasured.totalHeight == 199, "未测量状态不得把菜单裁成零高：\(unmeasured)")
        expect(
            invalidMeasurement == unmeasured,
            "非有限几何值必须与尚未测量使用同一安全布局：\(invalidMeasurement)")
    }

    suite("声音作用域菜单：最大字号按滚动视口剩余高度裁定选项区，诊断入口固定可见") {
        let layout = panelSoundScopeMenuLayout(
            scopeCount: 4,
            typeScale: ClaudioInterfaceTextSize.maximum.scale,
            availableHeight: 160)

        expect(layout.totalHeight == 160, "菜单总高必须精确受剩余视口 160pt 限制：\(layout)")
        expect(
            layout.optionsHeight < layout.optionsContentHeight,
            "四来源最大字号必须把溢出的选项留在内部滚动区")
        expect(
            abs(layout.diagnosticsHeight - 48.28) < 0.000_1,
            "视口裁切不得压缩底部连接与诊断入口：\(layout.diagnosticsHeight)")
    }

    suite("面板作用域：Global 恒在、Surface 按 registry 排序，notConnected 一律过滤") {
        let config = ClaudioConfig(
            selectedPack: "pack",
            surfaceOverrides: [
                HostSurfaceID.claudeCode.rawValue: SurfaceSoundOverride(selectedPack: "other")
            ])
        let scopes = panelSoundScopePresentations(
            sourceRows: [
                panelPresentationRow(.workBuddy, status: .awaitingActivation, supported: 2),
                panelPresentationRow(.claudeCode, status: .notConnected, supported: 5),
                panelPresentationRow(.codex, status: .ready, supported: 4),
            ],
            config: config,
            language: .zhHans)

        expect(
            scopes.map(\.scope) == [.global, .surface(.codex), .surface(.workBuddy)],
            "作用域菜单必须遵守 Global → Codex → Claude Code → WorkBuddy，并过滤未连接项：\(scopes.map(\.scope))")
        expect(scopes[0].name == "全局默认", "Global 作用域必须使用完整名称")
        expect(
            scopes[0].coverageText == "5 个事件" && scopes[0].stateText == "默认"
                && scopes[0].summaryText == "5 个事件 · 默认",
            "Global 必须把事件数与默认状态分开投影")
        expect(
            scopes[1].coverageText == "4/5" && scopes[1].stateText == "已激活"
                && scopes[1].summaryText == "4/5 · 已激活",
            "Codex 必须显示 4/5 与当前激活事实")
        expect(
            scopes[2].status == .awaitingActivation && scopes[2].stateText == "待回执"
                && scopes[2].summaryText == "2/5 · 待回执",
            "WorkBuddy 必须保留 awaitingActivation 语义并使用面板专属待回执文案")
        expect(
            !scopes.contains(where: { $0.scope == .surface(.claudeCode) }),
            "即使磁盘残留 Surface 覆盖，notConnected 也不得进入 popup")
    }

    suite("面板作用域文案：英文同样分离覆盖数与状态，不回退共享 readiness 文案") {
        let scopes = panelSoundScopePresentations(
            sourceRows: [
                panelPresentationRow(.workBuddy, status: .awaitingActivation, supported: 2)
            ],
            config: ClaudioConfig(selectedPack: "pack"),
            language: .english)

        expect(scopes[0].name == "Global defaults", "英文 Global 必须使用完整名称")
        expect(scopes[0].summaryText == "5 events · Default", "英文 Global 摘要错误")
        expect(
            scopes[1].summaryText == "2/5 · Awaiting receipt",
            "英文等待态不得继续显示 configured")
        expect(
            scopes[1].accessibilityLabel.contains("Awaiting receipt"),
            "AX 文案必须消费与屏幕相同的面板状态投影")
    }

    suite("面板作用域恢复：显式 Global/合法历史值保留，首次与失效值选首个可用来源") {
        let scopes = panelSoundScopePresentations(
            sourceRows: [
                panelPresentationRow(.claudeCode, status: .ready, supported: 5),
                panelPresentationRow(.codex, status: .ready, supported: 4),
                panelPresentationRow(.workBuddy, status: .ready, supported: 2),
            ],
            config: ClaudioConfig(selectedPack: "pack"),
            language: .english)

        expect(
            resolvedPanelSoundScopeSelection(storedValue: "global", scopes: scopes) == .global,
            "显式 Global 不得被自动选择覆盖")
        expect(
            resolvedPanelSoundScopeSelection(
                storedValue: HostSurfaceID.workBuddy.rawValue,
                scopes: scopes) == .surface(.workBuddy),
            "合法历史 WorkBuddy 选择必须恢复")
        expect(
            resolvedPanelSoundScopeSelection(storedValue: nil, scopes: scopes) == .surface(.codex),
            "首次打开应选 registry 中首个可用来源")
        expect(
            resolvedPanelSoundScopeSelection(storedValue: "stale", scopes: scopes)
                == .surface(.codex),
            "失效值应选首个可用来源")
        expect(
            resolvedPanelSoundScopeSelection(storedValue: nil, scopes: [scopes[0]]) == .global,
            "没有可用来源时必须回退 Global")
        expect(
            resolvedEventSettingsScope(
                route: EventSettingsWindowRoute(scope: .surface(.workBuddy)),
                scopes: Array(scopes.prefix(2))) == .surface(.codex),
            "窗口保留期间 WorkBuddy 消失时必须规范化到首个可用 Surface，不能继续写旧作用域")
        expect(
            resolvedEventSettingsScope(
                route: EventSettingsWindowRoute(scope: .surface(.workBuddy)),
                scopes: [scopes[0]]) == .global,
            "窗口保留期间所有 Surface 消失时必须让路由与写目标一起回退 Global")

        let pendingFallback = resolvedPanelSoundScopeSelection(
            storedValue: "unselected",
            scopes: [scopes[0]])
        expect(
            panelSoundScopeStoredValueToPersist(
                storedValue: "unselected",
                resolvedSelection: pendingFallback) == nil,
            "首次宿主刷新尚未完成时只能临时显示 Global，必须保留 unselected 未决状态")

        let firstAvailable = resolvedPanelSoundScopeSelection(
            storedValue: "unselected",
            scopes: scopes)
        expect(
            panelSoundScopeStoredValueToPersist(
                storedValue: "unselected",
                resolvedSelection: firstAvailable) == HostSurfaceID.codex.rawValue,
            "首个可用来源到达后才应把首次自动选择持久化")
    }

    suite("WorkBuddy 五行：仅 UserPromptSubmit/Stop 可操作，其余显式未实现") {
        let events = panelEventPresentations(
            rows: panelPresentationEventRows(),
            scope: .surface(.workBuddy),
            masterVolume: 0.8,
            language: .english)
        let chineseEvents = panelEventPresentations(
            rows: panelPresentationEventRows(),
            scope: .surface(.workBuddy),
            masterVolume: 0.8,
            language: .zhHans)

        expect(events.count == 5, "WorkBuddy 必须稳定显示五行")
        expect(
            events.map(\.nativeEventText)
                == ["UserPromptSubmit", "Stop", "StopFailure", "Notification", "SubagentStop"],
            "WorkBuddy 原生事件名必须来自 catalog")
        for event in events.prefix(2) {
            expect(event.implementation == .implemented, "\(event.event) 必须已实现")
            expect(event.capabilityText.contains("Implemented"), "能力标签必须说出已实现")
            expect(
                event.controls.previewEnabled && event.controls.muteEnabled,
                "\(event.event) 必须同时允许试听与静音")
        }
        expect(
            chineseEvents.prefix(2).allSatisfy { $0.capabilityText.contains("已实现") },
            "简体中文能力标签也必须说出已实现")
        for event in events.suffix(3) {
            expect(event.implementation == .notImplemented, "\(event.event) 必须显式未实现")
            expect(event.capabilityText.contains("Not implemented"), "能力标签必须说出未实现")
            expect(
                !event.controls.previewEnabled && !event.controls.muteEnabled,
                "未实现事件不得提供试听或静音假动作")
        }
    }

    suite("Codex 4/5：无原生事件的 StopFailure 不得伪装成 claudi0 事件 ID") {
        let chineseEvents = panelEventPresentations(
            rows: panelPresentationEventRows(),
            scope: .surface(.codex),
            masterVolume: 0.8,
            language: .zhHans)
        let englishEvents = panelEventPresentations(
            rows: panelPresentationEventRows(),
            scope: .surface(.codex),
            masterVolume: 0.8,
            language: .english)
        let unsupported = chineseEvents.first(where: { $0.event == .stopFailure })!
        let chinesePermission = chineseEvents.first(where: { $0.event == .notification })!
        let englishPermission = englishEvents.first(where: { $0.event == .notification })!

        expect(unsupported.support == .unsupported, "Codex StopFailure 必须携带 unsupported 枚举")
        expect(unsupported.nativeEventText == "无原生事件", "不得用 stop_failure 伪造宿主原生事件")
        expect(
            !unsupported.controls.previewEnabled && !unsupported.controls.muteEnabled,
            "Codex 不支持事件的两个动作必须禁用")
        expect(
            chineseEvents.filter { $0.controls.muteEnabled }.count == 4,
            "Codex 必须只有 4/5 个可配置事件")
        expect(
            chinesePermission.capabilityText == "接口部分支持 · 已实现",
            "Codex PermissionRequest 的中文能力标签必须同时说出 partial 与 implemented")
        expect(
            englishPermission.capabilityText == "Interface partially supported · Implemented",
            "Codex PermissionRequest 的英文能力标签必须同时说出 partial 与 implemented")
    }

    suite("Global 行使用 claudi0 事件 ID 与全局默认，不伪造宿主事实") {
        let events = panelEventPresentations(
            rows: panelPresentationEventRows(),
            scope: .global,
            masterVolume: 0.8,
            language: .zhHans)
        expect(
            events.map(\.nativeEventText) == Event.allCases.map(\.cliName),
            "Global 原生事件列必须显示稳定 claudi0 ID")
        expect(events.allSatisfy { $0.capabilityText == "全局默认" }, "Global 能力标签必须是全局默认")
        expect(
            events.allSatisfy { $0.support == nil && $0.implementation == nil },
            "Global 不得伪造 Host capability")
    }

    suite("事件可用性：缺失声音只禁试听；主音量为零不禁静音；禁止写入时静音 fail closed") {
        let broken = panelEventPresentations(
            rows: panelPresentationEventRows(coverage: .broken(fileName: "missing.aiff")),
            scope: .global,
            masterVolume: 0.8,
            language: .zhHans)
        expect(
            broken.allSatisfy { !$0.controls.previewEnabled && $0.controls.muteEnabled },
            "文件缺失只应禁用试听")
        expect(broken[0].soundFileText == "文件缺失：missing.aiff", "缺失文件必须明确标注")

        let silent = panelEventPresentations(
            rows: panelPresentationEventRows(),
            scope: .global,
            masterVolume: 0,
            language: .zhHans)
        expect(
            silent.allSatisfy { !$0.controls.previewEnabled && $0.controls.muteEnabled },
            "主音量零只影响试听可达性")

        let readOnly = panelEventPresentations(
            rows: panelPresentationEventRows(),
            scope: .global,
            masterVolume: 0.8,
            language: .zhHans,
            configWritesAllowed: false)
        expect(readOnly.allSatisfy { !$0.controls.muteEnabled }, "配置不可写时不得展示可操作静音")
    }

    suite("当前声音：事件行同时显示真实文件名与 AI 提示音名称") {
        let namedRows = Event.allCases.map {
            EventRow(
                event: $0,
                coverage: .present(fileName: "ai-cue.mp3"),
                enabled: true,
                audioDisplayName: "小猫两声")
        }
        let named = panelEventPresentations(
            rows: namedRows,
            scope: .surface(.workBuddy),
            masterVolume: 0.8,
            language: .zhHans)
        let unnamed = panelEventPresentations(
            rows: panelPresentationEventRows(coverage: .present(fileName: "legacy.aiff")),
            scope: .surface(.workBuddy),
            masterVolume: 0.8,
            language: .zhHans)
        let namedBrokenRows = Event.allCases.map {
            EventRow(
                event: $0,
                coverage: .broken(fileName: "ai-cue.mp3"),
                enabled: true,
                audioDisplayName: "小猫两声")
        }
        let namedBroken = panelEventPresentations(
            rows: namedBrokenRows,
            scope: .surface(.workBuddy),
            masterVolume: 0.8,
            language: .zhHans)

        expect(
            named.allSatisfy { $0.soundFileText == "ai-cue.mp3 · 小猫两声" },
            "已命名 AI 资产必须同时显示真实文件名与最终用户名称")
        expect(
            named.allSatisfy {
                $0.accessibilityLabel.contains("ai-cue.mp3")
                    && $0.accessibilityLabel.contains("小猫两声")
            },
            "VoiceOver 必须同时读出真实文件名与最终名称")
        expect(
            unnamed.allSatisfy { $0.soundFileText == "legacy.aiff" },
            "既有未命名资产必须继续显示文件名，不能伪造名称")
        expect(
            namedBroken.allSatisfy { $0.soundFileText == "文件缺失：ai-cue.mp3 · 小猫两声" },
            "命名资产缺失时必须同时显示缺失状态、真实文件名与最终名称")
        expect(
            namedBroken.allSatisfy {
                $0.accessibilityLabel.contains("ai-cue.mp3")
                    && $0.accessibilityLabel.contains("小猫两声")
            },
            "命名资产缺失时 VoiceOver 仍必须读出真实文件名与最终名称")
    }

    suite("能力格显式保留 support/implementation，视图无需从文案反推") {
        let binding = HostCapabilityCatalog.binding(host: .workBuddy, event: .notification)!
        let cell = HostCapabilityCellPresentation(
            host: .workBuddy,
            event: .notification,
            state: .unsupported,
            support: binding.support,
            implementation: binding.implementation,
            qualificationText: "fixture")
        let localized = localizedCapabilityCell(cell, language: .english)
        expect(localized.support == .partial, "能力格必须保留 partial support")
        expect(localized.implementation == .notImplemented, "能力格必须保留 notImplemented")
    }
}
