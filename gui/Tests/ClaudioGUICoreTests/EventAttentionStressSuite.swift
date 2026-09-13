import ClaudioCore
import ClaudioGUICore
import Combine
import Foundation

private final class EventNoticeTimerProbe: Sendable {}

@MainActor
func runEventAttentionStressSuites() async {
    await suite("Attention timers：取消及释放 token 不保留30分钟闭包") {
        for explicitCancel in [true, false] {
            weak var retained: EventNoticeTimerProbe?
            autoreleasepool {
                let probe = EventNoticeTimerProbe()
                retained = probe
                let cancellation = EventNoticeScheduler.live.schedule(after: 1800) {
                    withExtendedLifetime(probe) {}
                }
                if explicitCancel { cancellation.cancel() }
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while retained != nil && ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            expect(retained == nil, "取消/释放token后实际捕获对象释放，不等旧TTL截止")
        }
    }

    await suite("Attention ingress：一千事件十秒，批次让出 MainActor、徽标有进展且无资源累积") {
        let model = EventNoticeModel(receiverEpoch: UUID())
        var maximumBatch = 0
        var reductions = 0
        var latency: [TimeInterval] = []
        let ingress = EventNoticeIngress { notices in
            maximumBatch = max(maximumBatch, notices.count)
            reductions += 1
            let count = model.acceptBatch(notices).count
            for notice in notices.prefix(count) {
                if let observation = notice.observedUptime {
                    latency.append(ProcessInfo.processInfo.systemUptime - observation)
                }
            }
            return count
        }
        let started = ProcessInfo.processInfo.systemUptime
        var firstChange: TimeInterval?
        let changes = model.$snapshot.sink { snapshot in
            if snapshot.totalCount > 0 && firstChange == nil {
                firstChange = ProcessInfo.processInfo.systemUptime
            }
        }
        var firstBadgeDelay: TimeInterval?
        let sink = model.$badgeCount.sink { count in
            if count > 0 && firstBadgeDelay == nil {
                firstBadgeDelay = ProcessInfo.processInfo.systemUptime - (firstChange ?? started)
            }
        }
        var withinBounds = true
        for index in 0..<1000 {
            let target = started + Double(index) / 100
            let delay = target - ProcessInfo.processInfo.systemUptime
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            ingress.enqueue(
                attentionNotice(
                    epoch: model.receiverEpoch, observed: ProcessInfo.processInfo.systemUptime))
            let usage = model.resourceUsage
            withinBounds =
                withinBounds && ingress.pendingCount <= 128
                && usage.latestVersions <= 50 && usage.readingVersions <= 50
                && usage.transientVersions <= 1
                && usage.deduplicationEntries <= 256 && usage.observationEntries <= 256
                && usage.timers <= 3
        }
        let drainDeadline = ProcessInfo.processInfo.systemUptime + 1
        while ingress.pendingCount > 0 && ProcessInfo.processInfo.systemUptime < drainDeadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let p95 =
            latency.isEmpty
            ? TimeInterval.infinity
            : latency.sorted()[min(latency.count - 1, Int(Double(latency.count) * 0.95))]
        expect(
            ingress.pendingCount == 0 && model.snapshot.totalCount == 50 && model.badgeCount == 50,
            "压力结束保留50项且徽标无饥饿")
        expect(withinBounds && maximumBatch <= 32 && reductions <= 1000, "全部来源/元数据/任务批次有界")
        expect(p95 <= 0.1, "accepted envelope → model p95 不超过100ms，实测 \(p95 * 1000)ms")
        expect(
            firstBadgeDelay != nil && firstBadgeDelay! < 10,
            "徽标必须在突发结束前进展；100ms 截止由手动时钟回归验证，实际调度单独记录")
        print(
            String(
                format:
                    "  synthetic stress: events=1000 duration=%.3fs p95=%.3fms first-badge=%.3fms batches=%d",
                ProcessInfo.processInfo.systemUptime - started, p95 * 1000,
                (firstBadgeDelay ?? -1) * 1000, reductions))
        ingress.clear()
        model.clearForPrivacy()
        expect(
            ingress.pendingCount == 0 && model.resourceUsage.timers == 0
                && model.resourceUsage.latestVersions == 0,
            "清空后无待处理来源及计时器")
        withExtendedLifetime((sink, changes)) {}
    }

    await suite("Attention ingress：容量128，隐私清空后旧队列不能回填") {
        let model = EventNoticeModel(receiverEpoch: UUID())
        let ingress = EventNoticeIngress { model.acceptBatch($0).count }
        for _ in 0..<200 { ingress.enqueue(attentionNotice(epoch: model.receiverEpoch)) }
        expect(ingress.pendingCount == 128, "尚未让出MainActor时容量确为128")
        model.clearForPrivacy()
        ingress.clear()
        ingress.enqueue(attentionNotice(epoch: model.receiverEpoch))
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while ingress.pendingCount > 0 && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        expect(model.snapshot.totalCount == 1, "只接收新epoch一项")
        model.clearForPrivacy()
    }
}
