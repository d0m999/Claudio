import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
func runProductUIModelsSuites() {
    suite("界面文字：四档、稳定持久化值与损坏偏好回落") {
        expect(ClaudioInterfaceTextSize.allCases.count == 4, "界面文字必须恰好四档")
        expect(
            Set(ClaudioInterfaceTextSize.allCases.map(\.rawValue)).count == 4,
            "四档持久化值必须唯一")
        expect(
            ClaudioInterfaceTextSize(storedValue: "large") == .large,
            "合法持久化值必须恢复原档")
        expect(
            ClaudioInterfaceTextSize(storedValue: "future-value") == .standard,
            "未知偏好必须安全回落到标准")
        expect(
            ClaudioInterfaceTextSize(storedValue: nil) == .standard,
            "缺失偏好必须安全回落到标准")
        expect(
            ClaudioInterfaceTextSize.allCases.map(\.rawValue)
                == ["compact", "standard", "large", "maximum"],
            "现有四档 raw value 不能因新增步进 API 改变")
        expect(
            ClaudioInterfaceTextSize.defaultsKey == "Claudio.InterfaceTextSize"
                && ClaudioInterfaceTextSize.defaultValue == .standard,
            "defaults key 与默认档位必须保持不变")
        expect(
            zip(
                ClaudioInterfaceTextSize.allCases.map(\.scale),
                ClaudioInterfaceTextSize.allCases.dropFirst().map(\.scale)
            ).allSatisfy(<),
            "四档缩放必须严格递增")
        expect(
            ClaudioInterfaceTextSize.allCases.map(\.scale) == [0.92, 1, 1.18, 1.42],
            "新增步进 API 不得改变现有四档 scale")
    }

    suite("界面文字：相邻档位、两端边界与档位序号") {
        let sizes = ClaudioInterfaceTextSize.allCases
        expect(
            sizes.map(\.smaller) == [nil, .compact, .standard, .large],
            "smaller 必须严格映射 compact ← standard ← large ← maximum")
        expect(
            sizes.map(\.larger) == [.standard, .large, .maximum, nil],
            "larger 必须严格映射 compact → standard → large → maximum")
        expect(
            sizes.map(\.levelNumber) == [1, 2, 3, 4],
            "档位序号必须从 1 到 4 且与 allCases 对齐")
        expect(
            sizes.allSatisfy { $0.levelCount == 4 },
            "每一档暴露的总档数必须固定为 4")
    }

    suite("面板声音包四态：固定包 1 行/上限 4 行、无固定、无包与读取失败互斥") {
        let cards = (0..<5).map { index in
            PackCard(
                id: "pack-\(index)",
                name: "包 \(index)",
                isCC0: false,
                presentEvents: Set(Event.allCases),
                state: .complete,
                isSelected: index == 4)
        }
        expect(
            panelPackSectionState(pinnedCards: [cards[0]], availablePackCount: 5)
                == .pinned([cards[0]]),
            "一个固定包必须原样呈现")
        expect(
            panelPackSectionState(pinnedCards: cards, availablePackCount: 5)
                == .pinned(Array(cards.prefix(4))),
            "防御性上限必须固定为四个，不能生成第五行")
        expect(
            panelPackSectionState(pinnedCards: [], availablePackCount: 5)
                == .noPinnedPacks(availablePackCount: 5),
            "有包但无固定项必须是可恢复的无固定态")
        expect(
            panelPackSectionState(pinnedCards: [], availablePackCount: 0) == .noPacks,
            "磁盘无包必须与无固定项区分")
        expect(
            panelPackSectionState(
                pinnedCards: [cards[0]], availablePackCount: 5, readFailureReason: "无法读取")
                == .readFailed(reason: "无法读取"),
            "读取失败优先于任何陈旧卡片")
    }

    suite("手工试听：事件静音不参与判定，主音量零、缺失、损坏均给明确原因") {
        let available = eventPreviewAvailability(
            coverage: .present(fileName: "stop.mp3"), masterVolume: 0.5)
        expect(available == .available(fileName: "stop.mp3"), "安全文件且音量非零必须可试听")
        expect(available.isAvailable, "available 必须是唯一可操作态")
        expect(
            eventPreviewAvailability(
                coverage: .present(fileName: "stop.mp3"), masterVolume: 0)
                == .masterVolumeZero(fileName: "stop.mp3"),
            "主音量零必须单独解释")
        expect(
            eventPreviewAvailability(coverage: .unmapped, masterVolume: 1) == .unmapped,
            "未绑定必须明确")
        expect(
            eventPreviewAvailability(
                coverage: .broken(fileName: "gone.mp3"), masterVolume: 1)
                == .missingOrDamaged(fileName: "gone.mp3"),
            "缺失或损坏必须明确")
        expect(
            eventPreviewAvailability(
                coverage: .present(fileName: "stop.mp3"),
                masterVolume: 1,
                safetyFailureReason: "不是安全正规文件")
                == .unsafeOrUnreadable(reason: "不是安全正规文件"),
            "安全闸门失败必须覆盖表面上的 present")
    }

    suite("集成恢复动作：每个能力状态都有唯一产品意图") {
        let host = HostID.claudeCode
        let event = Event.stop
        func cell(
            _ state: AudibilityCellState,
            muteReason: HostCapabilityMuteReason? = nil
        ) -> HostCapabilityCellPresentation {
            HostCapabilityCellPresentation(
                host: host,
                event: event,
                state: state,
                muteReason: muteReason,
                nativeEventText: HostCapabilityCatalog.binding(host: host, event: event)?.nativeEvent)
        }
        expect(
            integrationsRecoveryAction(for: cell(.audible), hostStatus: .ready) == .none,
            "可听格不制造伪恢复动作")
        expect(
            integrationsRecoveryAction(for: cell(.muted), hostStatus: .ready)
                == .unmute(host: host, event: event),
            "逐事件静音格首动作必须取消静音")
        let masterVolumeMutedCell = cell(.muted, muteReason: .masterVolumeZero)
        expect(
            masterVolumeMutedCell.statusText == "主音量为零"
                && masterVolumeMutedCell.accessibilityLabel.contains("主音量为零"),
            "总音量为零必须进入可见文案与无障碍名称，不能继续伪装逐事件静音")
        expect(
            integrationsRecoveryAction(for: masterVolumeMutedCell, hostStatus: .ready)
                == .explainMasterVolumeZero(host: host, event: event),
            "总音量为零只能解释正确恢复路径，不能派生只写 enabled 的虚假 unmute")
        expect(
            integrationsRecoveryAction(for: cell(.missingSound), hostStatus: .ready)
                == .configureSound(host: host, event: event),
            "缺声格必须打开映射编辑")
        expect(
            integrationsRecoveryAction(for: cell(.notConnected), hostStatus: .notConnected)
                == .connect(host),
            "未连接格必须提供连接")
        expect(
            integrationsRecoveryAction(for: cell(.legacy), hostStatus: .legacy) == .upgrade(host),
            "旧版连接必须提供升级")
        expect(
            integrationsRecoveryAction(for: cell(.degraded), hostStatus: .needsAttention)
                == .repair(host),
            "损坏格必须提供修复")
        expect(
            integrationsRecoveryAction(for: cell(.degraded), hostStatus: .legacy)
                == .upgrade(host),
            "旧版宿主即使格状态降级，主动作也必须明确为升级")
        expect(
            integrationsRecoveryAction(
                for: cell(.awaitingActivation), hostStatus: .awaitingActivation)
                == .redetect(host),
            "等待宿主确认时只能重新读取事实，不能重复写配置")
        expect(
            integrationsRecoveryAction(for: cell(.unsupported), hostStatus: .ready)
                == .explainUnsupported(host: host, event: event),
            "不支持必须只解释，不能伪装错误")
        expect(
            [
                .unmute(host: host, event: event),
                .explainMasterVolumeZero(host: host, event: event),
                .configureSound(host: host, event: event),
                .connect(host), .upgrade(host), .repair(host), .redetect(host),
                .explainUnsupported(host: host, event: event), .none,
            ].allSatisfy { (action: IntegrationsRecoveryAction) in
                switch action {
                case .none, .explainMasterVolumeZero, .explainUnsupported: action.title == nil
                default: action.title?.isEmpty == false
                }
            },
            "每个可操作恢复动作都必须有非空名称，解释态与无动作不得伪造按钮")
    }

    suite("配置路径：只把真实 home 前缀缩写为波浪号") {
        expect(
            abbreviatedConfigurationPath(
                "/Users/example/.claude/settings.json", homeDirectory: "/Users/example")
                == "~/.claude/settings.json",
            "home 内路径必须缩写")
        expect(
            abbreviatedConfigurationPath("~/.codex/hooks.json", homeDirectory: "/Users/example")
                == "~/.codex/hooks.json",
            "已经缩写的路径必须保持")
        expect(
            abbreviatedConfigurationPath("/tmp/hooks.json", homeDirectory: "/Users/example")
                == "/tmp/hooks.json",
            "home 外路径不得伪装成用户配置")
    }
}
