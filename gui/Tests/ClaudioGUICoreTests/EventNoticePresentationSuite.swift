import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import Foundation
import SwiftUI

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
    suite("EventNoticeView：180pt 展开态的完整详情与动作可滚动到达") {
        _ = NSApplication.shared
        let epoch = UUID()
        var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
        let model = EventNoticeModel(
            receiverEpoch: epoch, now: { 100 },
            scheduler: EventNoticeScheduler { delay, callback in
                scheduled.append((delay, callback))
                return EventNoticeCancellation {}
            })
        let binding = HostCapabilityCatalog.binding(host: .codex, nativeEvent: "Stop")!
        let sessionID = String(repeating: "session-", count: 32)
        @MainActor func receive() {
            _ = model.accept(
                HostEventNotice(
                    receiverEpoch: epoch, surface: .codex, bindingID: binding.id,
                    installationID: UUID(), nativeEvent: binding.nativeEvent!, event: binding.event,
                    occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
                    source: HostEventSource(projectLabel: "project", sessionID: sessionID)))
        }
        for _ in 0..<51 { receive() }
        model.openRecent()
        receive()
        let preferences = ClaudioPreferences(previewLanguage: .zhHans)
        var viewedSource: UUID?
        var openRecentRequests = 0
        let hosting = NSHostingView(
            rootView: EventNoticeView(
                model: model, languageStore: preferences,
                onViewSource: { viewedSource = $0.id },
                onOpenRecent: {
                    openRecentRequests += 1
                    model.openRecent()
                }))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 180),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.setFrame(NSRect(x: 0, y: 0, width: 440, height: 180), display: true)
        panel.orderFront(nil)
        defer { panel.orderOut(nil); panel.close() }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        @MainActor func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        let views = descendants(hosting)
        let scrollViews = views.compactMap { $0 as? NSScrollView }
        expect(
            hosting.frame.height <= 180, "完整详情不能强迫 180pt panel 的 root 超高，实得 \(hosting.frame.height)"
        )
        expect(scrollViews.count == 1, "展开详情只应有一个滚动区域")
        guard let scroll = scrollViews.first, let document = scroll.documentView,
            let session = views.compactMap({ $0 as? NSTextField }).first(where: {
                $0.stringValue == sessionID
            })
        else {
            expect(false, "实际视图必须包含滚动区域和完整的可选中 session ID")
            return
        }
        expect(scroll.contentView.bounds.height >= 28, "滚动区域不能被固定详情挤到零高度")
        expect(session.isDescendant(of: document), "完整 session ID 必须属于可滚动文档，不能留在其外被裁切")
        guard session.isDescendant(of: document), scroll.contentView.bounds.height >= 28 else {
            return
        }
        let sessionFrame = session.convert(session.bounds, to: document)
        document.scrollToVisible(sessionFrame)
        hosting.layoutSubtreeIfNeeded()
        expect(
            scroll.contentView.bounds.intersects(sessionFrame),
            "滚动到 session ID 后必须进入可见视口")
        // The action row is the last 28pt row. Scroll to the end and exercise the actual source
        // button through AppKit; a button laid out outside the scroll region cannot pass this.
        let bottom = NSPoint(
            x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height))
        scroll.contentView.scroll(to: bottom)
        scroll.reflectScrolledClipView(scroll.contentView)
        hosting.layoutSubtreeIfNeeded()
        let actionPoint = document.convert(NSPoint(x: 32, y: document.bounds.maxY - 14), to: nil)
        @MainActor func click(_ point: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard
                    let event = NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: 0,
                        windowNumber: panel.windowNumber, context: nil, eventNumber: 1,
                        clickCount: 1,
                        pressure: 1)
                else { expect(false, "必须能生成原生动作点击"); return }
                panel.sendEvent(event)
            }
        }
        click(actionPoint)
        expect(viewedSource == model.snapshot.current?.id, "滚动到底后的来源按钮必须可点击且指向当前条目")
        model.closeRecent()
        // Deliver the specified 100ms badge coalescing callbacks without waiting on wall time.
        for (_, callback) in scheduled.filter({ $0.0 <= 0.1 }) { callback() }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        click(NSPoint(x: hosting.frame.width - 90, y: hosting.frame.height - 28))
        expect(
            openRecentRequests == 1 && model.snapshot.isExpanded,
            "紧凑胶囊的数量入口必须经 native controller 回调展开，才能接入 Settings 焦点移交")
    }

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
            "英文投影必须生成本地化短会话标签，实得 \(EventNoticeProjection.secondaryLine(for: record, language: .english))"
        )
        expect(
            EventNoticeProjection.secondaryLine(for: record, language: .zhHans)
                == "same-name · 会话 · 12345678",
            "中文投影必须生成中文短会话标签，实得 \(EventNoticeProjection.secondaryLine(for: record, language: .zhHans))"
        )

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
        let expired = EventNoticeRecord(
            id: record.id, event: record.event, occurredAt: record.occurredAt, notice: nil,
            status: .displayed, isExpired: true)
        for language in [ClaudioAppLanguage.english, .zhHans] {
            expect(
                EventNoticeProjection.occurredAtText(for: expired, language: language) == nil,
                "过期占位即使携带旧时间也不得继续生成可见时间文本")
        }
    }
}
