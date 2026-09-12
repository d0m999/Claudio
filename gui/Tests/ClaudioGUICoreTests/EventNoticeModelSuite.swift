import ClaudioCore
import ClaudioGUICore
import Combine
import Foundation

/// Deadline-driven manual scheduler shared with the action suites. Cancellation is thread safe.
final class ManualEventNoticeScheduler: @unchecked Sendable {
    private struct Item {
        let id: UUID
        let deadline: TimeInterval
        let callback: @MainActor () -> Void
    }
    private let lock = NSLock()
    private var items: [Item] = []
    @MainActor var time: TimeInterval = 100
    @MainActor func scheduler() -> EventNoticeScheduler {
        EventNoticeScheduler { [weak self] delay, callback in
            guard let self else { return EventNoticeCancellation {} }
            let id = UUID()
            self.add(Item(id: id, deadline: self.time + delay, callback: callback))
            return EventNoticeCancellation { [weak self] in self?.remove(id) }
        }
    }
    @MainActor func advance(_ duration: TimeInterval) {
        let target = time + duration
        while let item = take(until: target) {
            time = item.deadline
            item.callback()
        }
        time = target
    }
    private func add(_ item: Item) { lock.lock(); items.append(item); lock.unlock() }
    private func remove(_ id: UUID) { lock.lock(); items.removeAll { $0.id == id }; lock.unlock() }
    private func take(until deadline: TimeInterval) -> Item? {
        lock.lock()
        defer { lock.unlock() }
        guard
            let item = items.filter({ $0.deadline <= deadline }).min(by: {
                $0.deadline < $1.deadline
            })
        else { return nil }
        items.removeAll { $0.id == item.id }
        return item
    }
}

@MainActor
func attentionNotice(
    epoch: UUID, id: UUID = UUID(), installation: UUID = UUID(),
    native: String = "PermissionRequest", host: HostID = .codex,
    source: HostEventSource? = HostEventSource(
        projectLabel: "project", projectKey: "project-key", sessionID: "session-id",
        mainSessionIsKnown: true),
    reason: HostEventNoticeReason? = nil, observed: TimeInterval? = nil
) -> HostEventNotice {
    let binding = HostCapabilityCatalog.bindings(for: host).first { $0.nativeEvent == native }!
    return HostEventNotice(
        id: id, receiverEpoch: epoch, surface: host.surfaceID,
        bindingID: binding.id, installationID: installation, nativeEvent: native,
        event: binding.event, occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
        source: source,
        reason: reason, observedUptime: observed)
}

@MainActor
func runEventNoticeModelSuites() {
    func makeModel(_ scheduler: ManualEventNoticeScheduler, verified: Set<HostSurfaceID> = [])
        -> EventNoticeModel
    {
        EventNoticeModel(
            receiverEpoch: UUID(), now: { scheduler.time }, scheduler: scheduler.scheduler(),
            verifiedSubmissionSurfaces: verified)
    }

    suite("Attention：普通事件仅四秒展示，无排队、历史或收起后来源") {
        let clock = ManualEventNoticeScheduler()
        let model = makeModel(clock)
        let first = attentionNotice(epoch: model.receiverEpoch, native: "Stop")
        expect(model.accept(first) == .accepted, "普通事件有效")
        clock.advance(0.18)
        expect(
            model.snapshot.current?.id == first.id && model.snapshot.remainingTime == 4, "淡入后完整四秒")
        clock.advance(2)
        _ = model.accept(attentionNotice(epoch: model.receiverEpoch, native: "Stop"))
        expect(
            model.snapshot.current?.id == first.id && model.snapshot.remainingTime == 2, "新事件不替换或延长"
        )
        expect(model.snapshot.recent.isEmpty && model.snapshot.totalCount == 0, "普通事件不成为历史")
        clock.advance(2.18)
        expect(
            model.snapshot.phase == .hidden && model.resourceUsage.transientVersions == 0,
            "展示完即释放来源")
        model.openRecent()
        expect(
            model.snapshot.isExpanded && model.snapshot.current == nil
                && model.snapshot.recent.isEmpty, "零项仍可打开")
        model.dismiss(animated: false)
    }

    suite("Attention：暂停交叠只恢复剩余时间，展开不会重置横幅倒计时") {
        let clock = ManualEventNoticeScheduler()
        let model = makeModel(clock)
        _ = model.accept(attentionNotice(epoch: model.receiverEpoch))
        clock.advance(2.18)
        model.setHovering(true)
        model.setKeyboardFocused(true)
        clock.advance(20)
        model.setHovering(false)
        expect(model.snapshot.remainingTime == 2, "仍聚焦时保持暂停")
        model.setKeyboardFocused(false)
        clock.advance(1)
        expect(model.snapshot.phase == .visible, "剩余时间尚未结束")
        clock.advance(1.18)
        expect(model.snapshot.phase == .hidden && model.snapshot.totalCount == 1, "收起保留待接手项")
    }

    suite("Attention：完整身份归并、版本冻结与陈旧动作拒绝") {
        let clock = ManualEventNoticeScheduler()
        let model = makeModel(clock)
        let installation = UUID()
        let first = attentionNotice(epoch: model.receiverEpoch, installation: installation)
        _ = model.accept(first)
        clock.advance(0.18)
        let banner = model.snapshot.current!
        model.openRecent()
        let frozen = model.snapshot.recent
        let action = frozen[0].action!
        _ = model.accept(
            attentionNotice(
                epoch: model.receiverEpoch, installation: installation,
                source: HostEventSource(
                    projectLabel: "updated label", projectKey: "project-key",
                    sessionID: "session-id", mainSessionIsKnown: true)))
        expect(model.snapshot.totalCount == 1 && model.snapshot.pendingCount == 1, "同完整会话更新一行")
        expect(
            model.snapshot.recent[0].notice == frozen[0].notice
                && model.snapshot.recent[0].version == 1, "完整内容与版本冻结")
        expect(!model.snapshot.recent[0].isActionable && model.remove(action) == .stale, "陈旧移除拒绝")
        expect(model.viewSource(action) == .stale && model.snapshot.totalCount == 1, "陈旧来源动作不绑定最新")
        model.refreshRecent()
        let latest = model.snapshot.recent[0]
        expect(
            latest.id == banner.id && latest.version == 2
                && latest.source?.projectLabel == "updated label", "刷新后同稳定 ID 新版本")
        expect(model.viewSource(latest.action!) == .applied, "当前版本详情可打开")
        expect(model.snapshot.isDetail && model.snapshot.totalCount == 1, "查看不移除")
        expect(model.copySessionID(latest.action!) { $0 == "session-id" }, "复制真实写入结果")
        expect(model.snapshot.totalCount == 1, "复制不移除")
        expect(model.remove(latest.action!) == .applied && model.badgeCount == 0, "手动移除立即发布真实零数")
        expect(
            model.snapshot.current?.notice == nil && model.snapshot.current?.occurredAt == nil,
            "详情移除后无来源安全占位")
    }

    suite("Attention：不完整/parent/未知主会话与不同项目安装独立保留") {
        let clock = ManualEventNoticeScheduler()
        let model = makeModel(clock)
        let installation = UUID()
        let sources: [HostEventSource?] = [
            nil,
            HostEventSource(projectLabel: "project", sessionID: "session-id"),
            HostEventSource(
                projectLabel: "project", projectKey: "key", sessionID: "session-id",
                isParentSession: true),
            HostEventSource(projectLabel: "project", projectKey: "key", sessionID: "session-id"),
        ]
        for source in sources {
            for _ in 0..<2 {
                _ = model.accept(
                    attentionNotice(
                        epoch: model.receiverEpoch, installation: installation, source: source))
            }
        }
        expect(model.snapshot.totalCount == 8, "身份不足不能猜测归并")
        for key in ["a", "b"] {
            _ = model.accept(
                attentionNotice(
                    epoch: model.receiverEpoch, installation: installation,
                    source: HostEventSource(
                        projectLabel: "same", projectKey: key, sessionID: "session-id",
                        mainSessionIsKnown: true)))
        }
        _ = model.accept(attentionNotice(epoch: model.receiverEpoch))
        expect(model.snapshot.totalCount == 11, "项目键与安装代次参与身份")
    }

    suite("Attention：重复 UUID 不续期，旧观察不替换，冻结版本各自 TTL") {
        let clock = ManualEventNoticeScheduler()
        let model = makeModel(clock)
        let installation = UUID()
        let first = attentionNotice(
            epoch: model.receiverEpoch, installation: installation, observed: clock.time)
        _ = model.accept(first)
        model.openRecent()
        let original = model.snapshot.recent[0]
        _ = model.viewSource(original.action!)
        clock.advance(100)
        expect(model.accept(first) == .duplicate, "重复 UUID 不增加版本或延长期限")
        _ = model.accept(
            attentionNotice(
                epoch: model.receiverEpoch, installation: installation, observed: clock.time))
        let old = attentionNotice(
            epoch: model.receiverEpoch, installation: installation, observed: 150)
        expect(model.accept(old) == .staleObservation, "倒序观察不能覆盖新提醒")
        clock.advance(1700)
        expect(model.snapshot.totalCount == 1, "新版本自身尚未过期")
        expect(
            model.snapshot.current?.notice == nil && model.snapshot.current?.occurredAt == nil,
            "冻结旧版本到期擦除来源与时间")
        model.refreshRecent()
        expect(model.snapshot.recent[0].version == 2, "新版只经刷新展示")
        clock.advance(100)
        expect(
            model.snapshot.totalCount == 0 && model.snapshot.recent.allSatisfy { $0.notice == nil },
            "新版本独立过期")
    }

    suite("Attention：Stop 不清，生产后续提交关闭，可信主会话严格后序才移除") {
        for verified in [false, true] {
            let clock = ManualEventNoticeScheduler()
            let model = makeModel(clock, verified: verified ? [.codex] : [])
            let installation = UUID()
            _ = model.accept(
                attentionNotice(
                    epoch: model.receiverEpoch, installation: installation, observed: 100))
            clock.advance(1)
            _ = model.accept(
                attentionNotice(
                    epoch: model.receiverEpoch, installation: installation, native: "Stop",
                    observed: 101))
            expect(model.snapshot.totalCount == 1, "Stop 从不移除")
            for time in [nil, 100, 99, 10000, -1] as [TimeInterval?] {
                _ = model.accept(
                    attentionNotice(
                        epoch: model.receiverEpoch, installation: installation,
                        native: "UserPromptSubmit", observed: time))
                expect(model.snapshot.totalCount == 1, "缺失/相等/旧/未来/异常时间不移除")
            }
            let parent = HostEventSource(
                projectLabel: "project", projectKey: "project-key", sessionID: "session-id",
                isParentSession: true)
            _ = model.accept(
                attentionNotice(
                    epoch: model.receiverEpoch, installation: installation,
                    native: "UserPromptSubmit", source: parent, observed: 101))
            expect(model.snapshot.totalCount == 1, "parent 不移除主会话")
            _ = model.accept(
                attentionNotice(
                    epoch: model.receiverEpoch, installation: installation,
                    native: "UserPromptSubmit", observed: 101))
            expect(model.snapshot.totalCount == (verified ? 0 : 1), "仅明确验证 adapter 的主会话后序提交清除")
            if verified {
                expect(model.lastRemovalReason == .subsequentSubmission, "区分移除原因")
                expect(
                    model.accept(
                        attentionNotice(
                            epoch: model.receiverEpoch, installation: installation, observed: 100.5)
                    ) == .staleObservation, "移除后迟到提醒不能回填")
            }
        }
    }

    suite("Attention：0/1/5/6/50/51 容量，冻结详情保护与安全占位") {
        let clock = ManualEventNoticeScheduler()
        let model = makeModel(clock)
        for count in 1...51 {
            _ = model.accept(attentionNotice(epoch: model.receiverEpoch))
            if [1, 5, 6, 50, 51].contains(count) {
                expect(model.snapshot.totalCount == min(50, count), "容量与首屏数无关：\(count)")
            }
            if count == 1 {
                model.openRecent()
                _ = model.viewSource(model.snapshot.recent[0].action!)
            }
        }
        expect(
            model.snapshot.current?.notice != nil && model.snapshot.totalCount == 50, "当前详情免于容量淘汰")
        expect(model.snapshot.droppedCount == 1 && model.lastRemovalReason == .capacity, "如实记录容量淘汰")
        model.refreshRecent()
        expect(model.snapshot.recent.count == 50, "全部五十项可达")
    }

    suite("Attention：容量压力也不能擦除正在阅读的横幅") {
        let clock = ManualEventNoticeScheduler()
        let model = makeModel(clock)
        let first = attentionNotice(epoch: model.receiverEpoch)
        _ = model.accept(first)
        clock.advance(0.18)
        model.setHovering(true)
        for _ in 0..<100 { _ = model.accept(attentionNotice(epoch: model.receiverEpoch)) }
        expect(
            model.snapshot.current?.notice == first && model.snapshot.current?.version == 1,
            "容量淘汰必须保留当前横幅的完整阅读内容")
    }

    suite("Attention：静默不补播，锁屏与睡眠交叠，禁用和 epoch 隔离") {
        let clock = ManualEventNoticeScheduler()
        let model = makeModel(clock)
        model.setAutomaticallySuppressed(true)
        _ = model.accept(attentionNotice(epoch: model.receiverEpoch, native: "Stop"))
        _ = model.accept(attentionNotice(epoch: model.receiverEpoch))
        expect(
            model.snapshot.totalCount == 1 && model.resourceUsage.transientVersions == 0, "静默只保留关注项"
        )
        model.setAutomaticallySuppressed(false)
        expect(model.snapshot.phase == .hidden, "解除不补播")
        model.openRecent()
        model.setAutomaticallySuppressed(true)
        expect(model.snapshot.isExpanded, "动态静默不打断用户主动阅读列表")
        let previous = attentionNotice(epoch: model.receiverEpoch)
        model.setSystemPrivacy(.screenLocked, active: true)
        model.setSystemPrivacy(.sleeping, active: true)
        model.setSystemPrivacy(.screenLocked, active: false)
        expect(!model.canReceive && model.snapshot.totalCount == 0, "只解锁不能越过睡眠边界")
        expect(
            model.accept(attentionNotice(epoch: model.receiverEpoch)) == .ignoredDisabled, "挂起期间拒收")
        model.setEnabled(false)
        model.setEnabled(true)
        expect(!model.canReceive, "重开偏好也不能越过睡眠")
        model.setSystemPrivacy(.sleeping, active: false)
        expect(model.canReceive && model.accept(previous) == .staleEpoch, "全部恢复仍拒绝旧 ingress")
        _ = model.accept(attentionNotice(epoch: model.receiverEpoch))
        model.clearForPrivacy()
        expect(
            model.resourceUsage.latestVersions == 0 && model.resourceUsage.readingVersions == 0
                && model.resourceUsage.deduplicationEntries == 0
                && model.resourceUsage.observationEntries == 0
                && model.resourceUsage.timers == 0, "隐私清空所有来源、元数据及计时器")
    }

    suite("Attention：不透明 ID 按字节区分，元数据淘汰不破坏仍保留的版本") {
        let clock = ManualEventNoticeScheduler()
        let model = makeModel(clock)
        let installation = UUID()
        for session in ["caf\u{e9}", "cafe\u{301}"] {
            _ = model.accept(
                attentionNotice(
                    epoch: model.receiverEpoch, installation: installation,
                    source: HostEventSource(
                        projectLabel: "project", projectKey: "project-key",
                        sessionID: session, mainSessionIsKnown: true)))
        }
        expect(model.snapshot.totalCount == 2, "Unicode 规范等价不能合并两个不透明 ID")
        model.clearForPrivacy()
        clock.advance(1)
        let first = attentionNotice(
            epoch: model.receiverEpoch, installation: installation, observed: clock.time)
        _ = model.accept(first)
        model.openRecent()
        _ = model.viewSource(model.snapshot.recent[0].action!)
        clock.advance(1)
        for _ in 0..<300 {
            _ = model.accept(attentionNotice(epoch: model.receiverEpoch, observed: clock.time))
        }
        expect(model.accept(first) == .duplicate, "当前保留 UUID 即使退出去重元数据仍不续期")
        expect(
            model.accept(
                attentionNotice(
                    epoch: model.receiverEpoch, installation: installation, observed: 100.5))
                == .staleObservation,
            "保留版本自身的观察顺序不依赖可淘汰元数据")
        expect(model.snapshot.current?.version == 1, "冻结详情不被旧事件延长")
    }

    suite("Attention：Notification 原因与未实现 binding 的诚实分类") {
        let clock = ManualEventNoticeScheduler()
        let model = makeModel(clock)
        let cases: [(HostEventNoticeReason?, EventNoticeKind, Int)] = [
            (.permission, .permission, 1),
            (.needsInput, .needsInput, 1), (.informational, .transient, 0), (.review, .review, 1),
            (nil, .review, 1),
        ]
        for (reason, kind, count) in cases {
            model.clearForPrivacy()
            _ = model.accept(
                attentionNotice(
                    epoch: model.receiverEpoch, native: "Notification", host: .claudeCode,
                    reason: reason))
            expect(
                model.snapshot.current?.kind == kind && model.snapshot.totalCount == count,
                "原因分类 \(String(describing: reason))")
        }
        expect(
            model.accept(
                attentionNotice(
                    epoch: model.receiverEpoch, native: "Notification", host: .workBuddy))
                == .invalid, "WorkBuddy 未实现能力不升级")
    }

    suite("Attention：批量一次发布、持续到达徽标不饥饿、元数据有界且到期释放") {
        let clock = ManualEventNoticeScheduler()
        let model = makeModel(clock)
        var publishes = 0
        let sink = model.$snapshot.sink { _ in publishes += 1 }
        let batch = (0..<32).map { _ in
            attentionNotice(epoch: model.receiverEpoch, observed: clock.time)
        }
        let reduced = model.acceptBatch(batch)
        expect(publishes == 2 && !reduced.isEmpty && reduced.count <= 32, "初始快照加一次有界批次发布")
        _ = model.accept(contentsOf: batch.dropFirst(reduced.count))
        clock.advance(0.05)
        for _ in 0..<32 {
            _ = model.accept(attentionNotice(epoch: model.receiverEpoch, observed: clock.time))
        }
        clock.advance(0.05)
        expect(model.badgeCount == 50, "最早变化一百毫秒内发布最新数")
        for _ in 0..<1000 {
            _ = model.accept(attentionNotice(epoch: model.receiverEpoch, observed: clock.time))
        }
        let usage = model.resourceUsage
        expect(
            usage.latestVersions <= 50 && usage.readingVersions <= 50
                && usage.transientVersions <= 1
                && usage.deduplicationEntries == 256 && usage.observationEntries == 256
                && usage.timers <= 3, "全部常驻集合有界")
        clock.advance(1801)
        expect(
            model.snapshot.totalCount == 0 && model.resourceUsage.deduplicationEntries == 0
                && model.resourceUsage.observationEntries == 0 && model.resourceUsage.timers == 0,
            "截止计时器清理，空闲无轮询")
        withExtendedLifetime(sink) {}
    }
}
