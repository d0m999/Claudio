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
    suite("EventNoticeView：五行列表及小屏长详情实际挂载可滚动到达") {
        _ = NSApplication.shared
        @MainActor func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for language in [ClaudioAppLanguage.english, .zhHans] {
                for count in [0, 1, 5, 7, 50] {
                    let clock = ManualEventNoticeScheduler()
                    let model = EventNoticeModel(
                        receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler())
                    let sessionID = String(repeating: "S", count: 256)
                    for _ in 0..<count {
                        _ = model.accept(
                            attentionNotice(
                                epoch: model.receiverEpoch,
                                source: HostEventSource(
                                    projectLabel: "project", sessionID: sessionID)))
                    }
                    model.openRecent()
                    let preferences = ClaudioPreferences(previewLanguage: language)
                    var copyCalls = 0
                    let hosting = EventNoticeHostingView(
                        rootView: EventNoticeView(
                            model: model, languageStore: preferences,
                            onViewSource: { _ = model.viewSource($0) },
                            onCopySessionID: { action in
                                copyCalls += 1
                                return model.copySessionID(action) { _ in false }
                            }, onClose: { model.dismiss(animated: false) }))
                    let height = EventNoticeView.preferredHeight(for: model.snapshot)
                    let panel = NSPanel(
                        contentRect: NSRect(x: 0, y: 0, width: 440, height: height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                        defer: false)
                    panel.isReleasedWhenClosed = false
                    panel.appearance = NSAppearance(named: appearance)
                    panel.contentView = hosting
                    panel.setFrame(NSRect(x: 0, y: 0, width: 440, height: height), display: true)
                    panel.orderFront(nil)
                    defer { panel.orderOut(nil); panel.close() }
                    hosting.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
                    expect(
                        abs(hosting.frame.height - height) <= 1,
                        "窗口遵循模型布局高度：count=\(count) actual=\(hosting.frame.height) expected=\(height)"
                    )
                    let scrolls = descendants(hosting).compactMap { $0 as? NSScrollView }
                    expect(scrolls.count == 1, "列表单个滚动区域：\(count)")
                    if count >= 5, let scroll = scrolls.first {
                        expect(
                            scroll.contentView.bounds.height >= 270,
                            "标准五行视口至少270pt：\(scroll.contentView.bounds.height)")
                        if count > 5, let document = scroll.documentView {
                            expect(
                                document.bounds.height > scroll.contentView.bounds.height,
                                "第六行起存在可滚动内容，count=\(count) document=\(document.bounds.height) viewport=\(scroll.contentView.bounds.height)"
                            )
                            document.scrollToVisible(
                                NSRect(x: 0, y: document.bounds.maxY - 30, width: 100, height: 28))
                            expect(
                                scroll.contentView.bounds.maxY >= document.bounds.maxY - 32,
                                "末行可滚动到达")
                        }
                    }
                    if let directory = ProcessInfo.processInfo.environment[
                        "CLAUDIO_ATTENTION_SCREENSHOT_DIR"], count == 0 || count == 7
                    {
                        let output = URL(fileURLWithPath: directory, isDirectory: true)
                        try? FileManager.default.createDirectory(
                            at: output, withIntermediateDirectories: true)
                        if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
                        {
                            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                            try? bitmap.representation(using: .png, properties: [:])?.write(
                                to: output.appendingPathComponent(
                                    "list-\(appearance.rawValue)-\(language.rawValue)-\(count).png")
                            )
                        }
                    }
                    guard count > 0, let action = model.snapshot.recent.first?.action else {
                        continue
                    }
                    _ = model.viewSource(action)
                    panel.setFrame(NSRect(x: 0, y: 0, width: 300, height: 180), display: true)
                    hosting.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
                    let views = descendants(hosting)
                    guard let scroll = views.compactMap({ $0 as? NSScrollView }).first,
                        let document = scroll.documentView,
                        let session = views.compactMap({ $0 as? NSTextField }).first(where: {
                            $0.stringValue == sessionID
                        })
                    else { expect(false, "详情必须实际挂载完整 session ID 与滚动文档"); continue }
                    expect(session.isDescendant(of: document), "完整 ID 在可滚动区域内")
                    let frame = session.convert(session.bounds, to: document)
                    document.scrollToVisible(frame)
                    expect(scroll.contentView.bounds.intersects(frame), "小屏完整 ID 可滚动到达")
                    expect(
                        hosting.frame.height <= 180 && scroll.contentView.bounds.height >= 28,
                        "小屏不溢出且动作区域可达")
                    // The last row is remove (28pt); the preceding row is copy (28pt), with
                    // a 10pt gap. Exercise native mouse delivery, as in the pre-existing detail test.
                    let originalDetailHeight = document.bounds.height
                    let copyRect = NSRect(
                        x: 0, y: document.bounds.maxY - 66, width: 110, height: 28)
                    document.scrollToVisible(copyRect)
                    hosting.layoutSubtreeIfNeeded()
                    let point = document.convert(NSPoint(x: 45, y: copyRect.midY), to: nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(
                            with: type, location: point,
                            modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                            context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
                        {
                            panel.sendEvent(event)
                        }
                    }
                    expect(copyCalls == 1, "滚动后的真实复制按钮回送捕获版本")
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
                    hosting.layoutSubtreeIfNeeded()
                    expect(
                        document.bounds.height > originalDetailHeight,
                        "复制失败反馈增加实际滚动内容：\(language.rawValue) \(appearance.rawValue)")
                    document.scrollToVisible(
                        NSRect(x: 0, y: document.bounds.maxY - 28, width: 110, height: 28))
                    expect(
                        scroll.contentView.bounds.maxY >= document.bounds.maxY - 1,
                        "错误反馈出现后末尾动作仍可滚动到达")
                    if count == 1,
                        let directory = ProcessInfo.processInfo.environment[
                            "CLAUDIO_ATTENTION_SCREENSHOT_DIR"],
                        let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
                    {
                        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?.write(
                            to: URL(fileURLWithPath: directory, isDirectory: true)
                                .appendingPathComponent(
                                    "copy-failed-\(appearance.rawValue)-\(language.rawValue).png"))
                    }
                }
            }
        }
    }

    suite("EventNoticeProjection：信息性通知不显示等待介入") {
        let clock = ManualEventNoticeScheduler()
        let model = EventNoticeModel(
            receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler())
        _ = model.accept(
            attentionNotice(
                epoch: model.receiverEpoch, native: "Notification", host: .claudeCode,
                reason: .informational))
        guard let record = model.snapshot.current else { expect(false, "信息通知应有瞬时投影"); return }
        expect(
            EventNoticeProjection.primaryLine(for: record, language: .zhHans)
                == "Claude Code · 信息通知", "中文信息性通知不猜测等待介入")
        expect(
            EventNoticeProjection.primaryLine(for: record, language: .english)
                == "Claude Code · Information", "英文与中文含义一致")
    }

    suite("EventNoticeProjection：瞬时横幅根标签中性，待接手与展开态保留紧迫语义") {
        for language in [ClaudioAppLanguage.english, .zhHans] {
            let transientClock = ManualEventNoticeScheduler()
            let transientModel = EventNoticeModel(
                receiverEpoch: UUID(), now: { transientClock.time },
                scheduler: transientClock.scheduler())
            _ = transientModel.accept(
                attentionNotice(epoch: transientModel.receiverEpoch, native: "Stop"))
            let transient = transientModel.snapshot.current!
            expect(
                EventNoticeProjection.accessibilityLabel(
                    for: transientModel.snapshot, language: language)
                    == EventNoticeProjection.accessibilitySummary(
                        for: transient, language: language),
                "未展开瞬时横幅必须使用当前事件的中性摘要：\(language.rawValue)")

            let needsYou = ClaudioL10n(language: language).text(.eventNoticeRecent)
            expect(
                EventNoticeProjection.accessibilityLabel(
                    for: transientModel.snapshot, language: language) != needsYou,
                "普通进展不得播报为需要用户处理：\(language.rawValue)")
            _ = transientModel.viewSource(transient.action!)
            expect(
                EventNoticeProjection.accessibilityLabel(
                    for: transientModel.snapshot, language: language) == needsYou,
                "详情态保留已有根标签：\(language.rawValue)")

            let attentionClock = ManualEventNoticeScheduler()
            let attentionModel = EventNoticeModel(
                receiverEpoch: UUID(), now: { attentionClock.time },
                scheduler: attentionClock.scheduler())
            _ = attentionModel.accept(attentionNotice(epoch: attentionModel.receiverEpoch))
            expect(
                EventNoticeProjection.accessibilityLabel(
                    for: attentionModel.snapshot, language: language) == needsYou,
                "待接手横幅继续播报 Needs You/需要你：\(language.rawValue)")
            attentionModel.openRecent()
            expect(
                EventNoticeProjection.accessibilityLabel(
                    for: attentionModel.snapshot, language: language) == needsYou,
                "展开列表继续播报 Needs You/需要你：\(language.rawValue)")
        }
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
            narrowWidth == 268,
            "窄屏必须优先保留双侧 16pt 边距，实得 \(narrowWidth)")
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
