import ClaudioCore
import ClaudioGUICore
import Foundation

private final class ManualEventNoticeScheduler: @unchecked Sendable {
    private struct Item {
        let id: Int
        let delay: TimeInterval
        let callback: @MainActor () -> Void
    }

    private let lock = NSLock()
    private var nextID = 0
    private var items: [Item] = []

    func scheduler() -> EventNoticeScheduler {
        EventNoticeScheduler { [weak self] delay, callback in
            guard let self else { return EventNoticeCancellation {} }
            let id = self.add(delay: delay, callback: callback)
            return EventNoticeCancellation { [weak self] in
                self?.remove(id: id)
            }
        }
    }

    @discardableResult
    @MainActor
    func runNext(maxDelay: TimeInterval = .greatestFiniteMagnitude) -> Bool {
        let item: Item?
        lock.lock()
        if let index = items.firstIndex(where: { $0.delay <= maxDelay }) {
            item = items.remove(at: index)
        } else {
            item = nil
        }
        lock.unlock()
        item?.callback()
        return item != nil
    }

    private func add(
        delay: TimeInterval,
        callback: @escaping @MainActor () -> Void
    ) -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        items.append(Item(id: nextID, delay: delay, callback: callback))
        return nextID
    }

    private func remove(id: Int) {
        lock.lock()
        items.removeAll { $0.id == id }
        lock.unlock()
    }
}

@MainActor
private final class EventNoticeClock {
    var value: TimeInterval = 100
}

@MainActor
private func makeEventNotice(
    epoch: UUID,
    id: UUID = UUID(),
    source: HostEventSource? = HostEventSource(
        projectLabel: "same-name",
        projectKey: "project-key",
        sessionID: "12345678-abcdef")
) -> HostEventNotice {
    let binding = HostCapabilityCatalog.binding(host: .codex, nativeEvent: "Stop")!
    return HostEventNotice(
        id: id,
        receiverEpoch: epoch,
        surface: .codex,
        bindingID: binding.id,
        installationID: UUID(),
        nativeEvent: binding.nativeEvent!,
        event: binding.event,
        occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
        source: source)
}

@MainActor
func runEventNoticeModelSuites() {
    suite("EventNoticeModel：单条提示完成淡入、四秒阅读后淡出并保留近期记录") {
        let epoch = UUID()
        let clock = EventNoticeClock()
        let scheduler = ManualEventNoticeScheduler()
        let model = EventNoticeModel(
            receiverEpoch: epoch,
            now: { clock.value },
            scheduler: scheduler.scheduler())
        let notice = makeEventNotice(epoch: epoch)

        expect(model.accept(notice) == .accepted, "合法事件必须进入提示模型")
        expect(
            model.snapshot.phase == .entering && model.snapshot.current?.id == notice.id,
            "首条事件必须成为当前提示并先进入淡入态")
        expect(scheduler.runNext(maxDelay: EventNoticeModel.fadeDuration), "淡入回调必须可执行")
        expect(
            model.snapshot.phase == .visible
                && model.snapshot.remainingTime == EventNoticeModel.displayDuration,
            "淡入完成后必须从完整四秒开始阅读计时")
        expect(
            scheduler.runNext(maxDelay: EventNoticeModel.displayDuration),
            "四秒阅读计时器必须可执行")
        expect(model.snapshot.phase == .exiting, "阅读时间到后必须进入淡出态")
        expect(scheduler.runNext(maxDelay: EventNoticeModel.fadeDuration), "淡出回调必须可执行")
        expect(
            model.snapshot.phase == .hidden
                && model.snapshot.current == nil
                && model.snapshot.recent.count == 1
                && model.snapshot.recent[0].status == .collapsed,
            "淡出后应隐藏当前面板但保留近期记录，不把收起冒充为已处理")
        model.openRecent()
        expect(
            model.snapshot.isExpanded && model.snapshot.current?.id == notice.id,
            "当前提示收起后仍必须能从近期入口重新打开，而不是丢失记录")
    }

    suite("EventNoticeModel：hover 与键盘聚焦共同暂停，全部解除后只恢复剩余时间") {
        let epoch = UUID()
        let clock = EventNoticeClock()
        let scheduler = ManualEventNoticeScheduler()
        let model = EventNoticeModel(
            receiverEpoch: epoch,
            now: { clock.value },
            scheduler: scheduler.scheduler())
        _ = model.accept(makeEventNotice(epoch: epoch))
        _ = scheduler.runNext(maxDelay: EventNoticeModel.fadeDuration)

        clock.value += 2
        model.setHovering(true)
        expect(
            model.snapshot.pauseReasons == .hover
                && model.snapshot.remainingTime == 2,
            "悬停必须冻结当前剩余两秒")
        model.setKeyboardFocused(true)
        model.setHovering(false)
        expect(
            model.snapshot.pauseReasons == .keyboardFocus
                && model.snapshot.remainingTime == 2,
            "多个暂停原因解除一个后仍必须保持暂停")
        model.setKeyboardFocused(false)
        expect(
            model.snapshot.pauseReasons.isEmpty && model.snapshot.remainingTime == 2,
            "全部暂停原因解除后必须恢复原剩余时间，而不是重新给四秒")
        expect(scheduler.runNext(maxDelay: 2), "剩余计时器必须按两秒恢复")
        expect(model.snapshot.phase == .exiting, "恢复的计时器到期必须触发淡出")
    }

    suite("EventNoticeModel：展开冻结列表，新事件只增数量，显式刷新后才进入列表") {
        let epoch = UUID()
        let clock = EventNoticeClock()
        let scheduler = ManualEventNoticeScheduler()
        let model = EventNoticeModel(
            receiverEpoch: epoch,
            now: { clock.value },
            scheduler: scheduler.scheduler())
        let first = makeEventNotice(epoch: epoch)
        let second = makeEventNotice(epoch: epoch)
        let third = makeEventNotice(epoch: epoch)
        _ = model.accept(first)
        _ = scheduler.runNext(maxDelay: EventNoticeModel.fadeDuration)
        _ = model.accept(second)

        model.openRecent()
        expect(
            model.snapshot.isExpanded
                && model.snapshot.pauseReasons.contains(.expanded)
                && model.snapshot.recent.count == 2
                && model.snapshot.remainingTime == EventNoticeModel.displayDuration,
            "显式展开必须冻结现有列表并暂停且重置四秒阅读区间")
        _ = model.accept(third)
        expect(
            model.snapshot.recent.count == 2 && model.snapshot.pendingCount == 1,
            "展开期间的新事件不得替换当前内容或偷偷改变冻结列表")
        model.refreshRecent()
        expect(
            model.snapshot.recent.count == 3 && model.snapshot.pendingCount == 0,
            "显式刷新后新事件才进入近期列表")
        model.selectRecent(id: second.id)
        expect(
            model.snapshot.current?.id == second.id
                && model.snapshot.recent.first(where: { $0.id == first.id })?.status == .collapsed,
            "选择动作必须按 UUID 切换到原事件，不依赖数组位置")
        model.closeRecent()
        expect(
            !model.snapshot.isExpanded && model.snapshot.pauseReasons.isEmpty,
            "关闭列表必须解除 expanded 暂停原因")
    }

    suite("EventNoticeModel：事件身份即时保留，近期数量按一百毫秒合并") {
        let epoch = UUID()
        let clock = EventNoticeClock()
        let scheduler = ManualEventNoticeScheduler()
        let model = EventNoticeModel(
            receiverEpoch: epoch,
            now: { clock.value },
            scheduler: scheduler.scheduler())
        _ = model.accept(makeEventNotice(epoch: epoch))
        _ = scheduler.runNext(maxDelay: EventNoticeModel.fadeDuration)
        _ = model.accept(makeEventNotice(epoch: epoch))
        _ = model.accept(makeEventNotice(epoch: epoch))
        expect(
            model.snapshot.recent.count == 3 && model.snapshot.pendingCount == 2
                && model.badgeCount == 0,
            "事件快照必须即时保留三条，但数量徽标不能逐条重绘")
        expect(!scheduler.runNext(maxDelay: 0.099), "一百毫秒 debounce 不得提前发布徽标")
        expect(scheduler.runNext(maxDelay: 0.1), "一百毫秒后必须发布合并后的数量")
        expect(model.badgeCount == 2, "徽标必须只发布最终真实数量，不合并事件身份")
    }

    suite("EventNoticeModel：容量保护当前项、丢弃计数有界且不按项目名称合并") {
        let epoch = UUID()
        let clock = EventNoticeClock()
        let scheduler = ManualEventNoticeScheduler()
        let model = EventNoticeModel(
            receiverEpoch: epoch,
            now: { clock.value },
            scheduler: scheduler.scheduler())
        let first = makeEventNotice(epoch: epoch)
        _ = model.accept(first)
        _ = scheduler.runNext(maxDelay: EventNoticeModel.fadeDuration)
        for _ in 1..<EventNoticeModel.maximumRecentCount {
            _ = model.accept(makeEventNotice(epoch: epoch))
        }
        expect(
            model.snapshot.recent.count == EventNoticeModel.maximumRecentCount,
            "近期记录上限必须是五十条")
        _ = model.accept(makeEventNotice(epoch: epoch))
        expect(
            model.snapshot.recent.count == EventNoticeModel.maximumRecentCount
                && model.snapshot.current?.id == first.id
                && model.snapshot.droppedCount == 1,
            "第五十一条不得淘汰当前阅读项，且只能增加真实丢弃计数")
    }

    suite("EventNoticeModel：静默不补播，TTL 清除来源，关闭与代次隔离旧消息") {
        let epoch = UUID()
        let nextEpoch = UUID()
        let clock = EventNoticeClock()
        let scheduler = ManualEventNoticeScheduler()
        let model = EventNoticeModel(
            receiverEpoch: epoch,
            now: { clock.value },
            scheduler: scheduler.scheduler())
        let quietNotice = makeEventNotice(epoch: epoch)
        model.setAutomaticallySuppressed(true)
        expect(model.accept(quietNotice) == .accepted, "静默期间仍应保留允许的近期信息")
        expect(
            model.snapshot.phase == .hidden && model.snapshot.current == nil,
            "静默期间不得自动展示提示")
        model.setAutomaticallySuppressed(false)
        expect(
            model.snapshot.phase == .hidden && model.snapshot.current == nil,
            "解除静默不得集中补播静默期间事件")

        let visible = makeEventNotice(epoch: epoch)
        _ = model.accept(visible)
        _ = scheduler.runNext(maxDelay: EventNoticeModel.fadeDuration)
        model.setHovering(true)
        clock.value += EventNoticeModel.retentionDuration
        model.expireNow()
        expect(
            model.snapshot.current?.isExpired == true
                && model.snapshot.current?.notice == nil
                && model.snapshot.current?.occurredAt == nil
                && model.snapshot.current?.source == nil,
            "TTL 到期必须擦除来源与导航目标，但保留当前安全焦点占位")
        model.setHovering(false)
        expect(
            model.snapshot.phase == .visible && model.snapshot.remainingTime == nil,
            "TTL 优先于暂停，来源过期后解除悬停不得重新启动阅读倒计时")

        let afterExpiry = makeEventNotice(epoch: epoch)
        expect(
            model.accept(afterExpiry) == .accepted
                && model.snapshot.current?.id == afterExpiry.id,
            "当前占位已过期后到达的新事件必须重新成为当前提示")

        model.setEnabled(false)
        expect(
            model.snapshot.recent.isEmpty && model.snapshot.phase == .hidden,
            "关闭提示偏好必须立即清空来源和展示")
        expect(model.accept(visible) == .ignoredDisabled, "关闭后旧消息不得进入模型")
        model.setEnabled(true)
        expect(model.accept(visible) == .staleEpoch, "重新开启后旧代次消息仍必须失效")
        let currentEpoch = model.receiverEpoch
        expect(
            model.accept(makeEventNotice(epoch: currentEpoch)) == .accepted,
            "重新开启后的新代次消息必须可以进入模型")
        model.replaceReceiverEpoch(nextEpoch)
        expect(
            model.snapshot.recent.isEmpty && model.snapshot.receiverEpoch == nextEpoch,
            "receiver 代次更换必须清空旧展示事实")
    }

    suite("EventNoticeModel：冻结列表中选中条目的 TTL 同时擦除当前与近期发生时间") {
        let epoch = UUID()
        let clock = EventNoticeClock()
        let scheduler = ManualEventNoticeScheduler()
        let model = EventNoticeModel(
            receiverEpoch: epoch, now: { clock.value }, scheduler: scheduler.scheduler())
        let first = makeEventNotice(epoch: epoch)
        let selected = makeEventNotice(epoch: epoch)
        _ = model.accept(first)
        _ = model.accept(selected)
        model.openRecent()
        model.selectRecent(id: selected.id)
        expect(model.snapshot.current?.occurredAt == selected.occurredAt, "有效详情保留发生时间")
        clock.value += EventNoticeModel.retentionDuration
        model.expireNow()
        expect(
            model.snapshot.current?.id == selected.id && model.snapshot.current?.isExpired == true,
            "到期后仍保留当前选中身份，不自动跳到另一条")
        expect(model.snapshot.current?.occurredAt == nil, "选中详情到期后立即擦除发生时间")
        expect(
            model.snapshot.recent.count == 1
                && model.snapshot.recent.allSatisfy {
                    $0.isExpired && $0.notice == nil && $0.source == nil && $0.occurredAt == nil
                },
            "冻结列表只能保留无来源、无发生时间的选中占位")
    }

    suite("EventNoticeModel：重复 UUID、陈旧代次和非法 notice 都 fail closed") {
        let epoch = UUID()
        let clock = EventNoticeClock()
        let scheduler = ManualEventNoticeScheduler()
        let model = EventNoticeModel(
            receiverEpoch: epoch,
            now: { clock.value },
            scheduler: scheduler.scheduler())
        let notice = makeEventNotice(epoch: epoch)
        expect(model.accept(notice) == .accepted, "首条合法 notice 必须接受")
        expect(model.accept(notice) == .duplicate, "重复 UUID 必须丢弃")
        expect(
            model.accept(makeEventNotice(epoch: UUID())) == .staleEpoch,
            "陈旧 receiver epoch 必须丢弃")
        let binding = HostCapabilityCatalog.binding(host: .codex, nativeEvent: "Stop")!
        let invalid = HostEventNotice(
            receiverEpoch: epoch,
            surface: .codex,
            bindingID: binding.id,
            installationID: UUID(),
            nativeEvent: "not-a-real-event",
            event: binding.event,
            occurredAt: Date())
        expect(model.accept(invalid) == .invalid, "不匹配 binding 的 notice 必须拒绝")
    }

    suite("EventNoticeModel：相同到达时间的记录按接收次序确定排序") {
        let epoch = UUID()
        let clock = EventNoticeClock()
        let scheduler = ManualEventNoticeScheduler()
        let model = EventNoticeModel(
            receiverEpoch: epoch,
            now: { clock.value },
            scheduler: scheduler.scheduler())
        // 固定时钟让三条记录拿到完全相同的 expiresAt；次序只能来自到达序，不得依赖排序稳定性。
        let first = makeEventNotice(epoch: epoch)
        let second = makeEventNotice(epoch: epoch)
        let third = makeEventNotice(epoch: epoch)
        _ = model.accept(first)
        _ = model.accept(second)
        _ = model.accept(third)
        expect(
            model.snapshot.recent.map(\.id) == [third.id, second.id, first.id],
            "相同 expiresAt 的记录必须按到达先后确定排序（最新在前），不得依赖 sorted 稳定性")
    }
}
