import ClaudioCore
import ClaudioGUICore
import ClaudioGUIComponents
import ClaudioLocalization
import Foundation

@MainActor
private func makePresentationRecord(
    source: HostEventSource?,
    occurredAt: Date? = Date(timeIntervalSince1970: 1_700_000_000)
) -> EventNoticeRecord {
    let binding = HostCapabilityCatalog.binding(host: .codex, nativeEvent: "Stop")!
    let epoch = UUID()
    let notice = HostEventNotice(
        receiverEpoch: epoch,
        surface: .codex,
        bindingID: binding.id,
        installationID: UUID(),
        nativeEvent: binding.nativeEvent!,
        event: binding.event,
        occurredAt: occurredAt ?? Date(),
        source: source)
    return EventNoticeRecord(
        id: notice.id,
        event: notice.event,
        occurredAt: occurredAt,
        notice: source == nil ? nil : notice,
        status: .displayed,
        isExpired: false)
}

@MainActor
func runEventNoticePresentationSuites() {
    suite("EventNoticePlacement：刘海与菜单栏共同决定顶部安全位置") {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        // 刘海屏且菜单栏常驻：visibleFrame 已让出菜单栏（24pt），刘海 32pt 中 8pt 侵入可见区。
        let visibleWithBar = CGRect(x: 0, y: 0, width: 1512, height: 958)
        let insetWithBar = EventNoticePlacement.effectiveTopSafeInset(
            screenFrame: frame, visibleFrame: visibleWithBar, safeAreaTop: 32)
        expect(insetWithBar == 8, "刘海超出菜单栏的部分才需要额外下移，实得 \(insetWithBar)")

        // 菜单栏自动隐藏：visibleFrame 顶到屏幕顶，整个刘海高度都必须避让。
        let insetHiddenBar = EventNoticePlacement.effectiveTopSafeInset(
            screenFrame: frame, visibleFrame: frame, safeAreaTop: 32)
        expect(insetHiddenBar == 32, "菜单栏隐藏时刘海全高都必须避让，实得 \(insetHiddenBar)")

        let yNotch = EventNoticePlacement.topAnchorY(
            screenFrame: frame, visibleFrame: frame, safeAreaTop: 32, height: 92)
        expect(
            yNotch == 982 - 32 - 12 - 92,
            "刘海屏顶边必须落在 safeArea 交集下 12pt，实得 \(yNotch)")

        // 无刘海普通屏：不额外下移。
        let yPlain = EventNoticePlacement.topAnchorY(
            screenFrame: frame, visibleFrame: visibleWithBar, safeAreaTop: 0, height: 92)
        expect(
            yPlain == visibleWithBar.maxY - 12 - 92,
            "无刘海屏幕保持可见区顶向下 12pt，实得 \(yPlain)")

        // 窄屏：宽度夹取下限与左右 16pt 边距。
        let narrowVisible = CGRect(x: 0, y: 0, width: 300, height: 800)
        let narrowWidth = EventNoticePlacement.clampedWidth(visibleFrame: narrowVisible)
        expect(
            narrowWidth == EventNoticePlacement.minimumWidth,
            "窄屏宽度必须夹到 280pt 下限，实得 \(narrowWidth)")
        let narrowX = EventNoticePlacement.clampedX(
            visibleFrame: narrowVisible, width: narrowWidth)
        expect(
            narrowX == 16,
            "窄屏无法居中时也必须保住左侧 16pt 边距，实得 \(narrowX)")
        let wideX = EventNoticePlacement.clampedX(visibleFrame: visibleWithBar, width: 440)
        expect(
            wideX == visibleWithBar.midX - 220,
            "宽屏必须水平居中，实得 \(wideX)")
    }

    suite("EventNoticeProjection：会话短标签由展示层本地化，不随 IPC 硬编码") {
        let record = makePresentationRecord(
            source: HostEventSource(
                projectLabel: "same-name",
                projectKey: "project-key",
                sessionID: "12345678-abcdef"))
        expect(
            EventNoticeProjection.secondaryLine(for: record, language: .english)
                == "same-name · Session · 12345678",
            "英文投影必须生成本地化短会话标签，实得 \(EventNoticeProjection.secondaryLine(for: record, language: .english))")
        expect(
            EventNoticeProjection.secondaryLine(for: record, language: .zhHans)
                == "same-name · 会话 · 12345678",
            "中文投影必须生成中文短会话标签，实得 \(EventNoticeProjection.secondaryLine(for: record, language: .zhHans))")

        let titled = makePresentationRecord(
            source: HostEventSource(
                projectLabel: "same-name",
                projectKey: "project-key",
                sessionID: "12345678-abcdef",
                sessionLabel: "adapter 可信标题"))
        expect(
            EventNoticeProjection.secondaryLine(for: titled, language: .zhHans)
                .contains("adapter 可信标题"),
            "adapter 显式可信标题必须优先于默认短标签")

        let parent = makePresentationRecord(
            source: HostEventSource(
                projectLabel: nil,
                sessionID: "12345678-abcdef",
                isParentSession: true))
        expect(
            EventNoticeProjection.secondaryLine(for: parent, language: .zhHans)
                .contains("父会话"),
            "父会话标注必须在投影中保留")
    }

    suite("EventNoticeProjection：可见文本与无障碍摘要同源，发生时间可读") {
        let record = makePresentationRecord(
            source: HostEventSource(
                projectLabel: "same-name",
                projectKey: "project-key",
                sessionID: "12345678-abcdef"))
        let primary = EventNoticeProjection.primaryLine(for: record, language: .zhHans)
        let secondary = EventNoticeProjection.secondaryLine(for: record, language: .zhHans)
        let summary = EventNoticeProjection.accessibilitySummary(
            for: record, language: .zhHans)
        expect(
            summary == "\(primary)，\(secondary)",
            "AX 摘要必须由同一投影的两行拼接，不得另造一份文案")
        expect(
            EventNoticeProjection.accessibilitySummary(for: nil, language: .english)
                == ClaudioL10n(language: .english).text(.eventNoticeUnknownSource),
            "空记录的无障碍摘要必须落在未知来源文案")

        let occurred = EventNoticeProjection.occurredAtText(for: record, language: .english)
        expect(occurred != nil && !occurred!.isEmpty, "发生时间必须生成可读文本")
        let noTime = EventNoticeRecord(
            id: UUID(), event: .stop, occurredAt: nil, notice: nil,
            status: .collapsed, isExpired: true)
        expect(
            EventNoticeProjection.occurredAtText(for: noTime, language: .english) == nil,
            "来源过期后不得伪造发生时间")
    }
}
