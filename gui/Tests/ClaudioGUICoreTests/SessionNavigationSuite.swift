import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
func runSessionNavigationSuites() async {
    func model(_ clock: ManualEventNoticeScheduler) -> EventNoticeModel {
        EventNoticeModel(receiverEpoch: UUID(), now: { clock.time }, scheduler: clock.scheduler())
    }
    func capability(_ notice: HostEventNotice) -> SessionNavigationCapability {
        sessionNavigationCapability(
            for: notice,
            verifiedTarget: SessionNavigationTarget(
                surface: notice.surface, projectKey: notice.source?.projectKey,
                sessionID: notice.source!.sessionID!))
    }

    suite("Navigation：生产只有真实详情与有效 ID 复制能力") {
        let notice = attentionNotice(epoch: UUID())
        expect(sessionNavigationCapability(for: notice) == .viewSource, "生产不给精确返回")
        let unknown = attentionNotice(epoch: UUID(), source: nil)
        let unknownCapability = sessionNavigationCapability(for: unknown)
        expect(
            unknownCapability.canViewSource && !unknownCapability.canCopySessionID
                && !unknownCapability.canOpenSession,
            "缺失来源仍能查看解释，但无复制/导航能力")
        let partial = attentionNotice(
            epoch: UUID(), source: HostEventSource(projectLabel: "project", sessionID: nil))
        expect(!sessionNavigationCapability(for: partial).canCopySessionID, "仅项目不能承诺复制 ID")
        let mismatched = sessionNavigationCapability(
            for: notice,
            verifiedTarget: SessionNavigationTarget(
                surface: .codex, projectKey: "other", sessionID: "session-id"))
        expect(mismatched == .viewSource, "精确能力须完全匹配来源")
    }

    suite("Navigation：双击只派发一次、三秒超时恢复、迟到确认不能移除") {
        let clock = ManualEventNoticeScheduler()
        let model = model(clock)
        let notice = attentionNotice(epoch: model.receiverEpoch)
        _ = model.accept(notice)
        let action = model.snapshot.current!.action!
        var dispatched = 0
        var completions: [@MainActor (SessionNavigationActionResult) -> Void] = []
        let coordinator = SessionNavigationCoordinator(model: model, scheduler: clock.scheduler()) {
            _, complete in
            dispatched += 1
            completions.append(complete)
            return EventNoticeCancellation {}
        }
        for _ in 0..<2 {
            coordinator.openSession(
                capability(notice), action: action, generation: coordinator.capabilityGeneration)
        }
        expect(dispatched == 1 && coordinator.result == .started, "双击不重复派发")
        clock.advance(2.99)
        expect(coordinator.result == .started, "默认超时确为三秒")
        clock.advance(0.01)
        expect(coordinator.result == .timedOut && model.snapshot.totalCount == 1, "超时退出 busy 并保留提醒")
        completions[0](.exactReturnConfirmed)
        expect(coordinator.result == .timedOut && model.snapshot.totalCount == 1, "超时后的结果无效")
        coordinator.openSession(
            capability(notice), action: action, generation: coordinator.capabilityGeneration)
        expect(dispatched == 2, "超时后可显式重试")
        completions[1](.failed)
        expect(coordinator.result == .failed && model.snapshot.totalCount == 1, "失败保留提醒")
    }

    suite("Navigation：新版本/epoch/能力代次使旧结果失效，只有 exactReturnConfirmed 移除") {
        for change in ["version", "epoch", "capability", "cancel", "remove"] {
            let clock = ManualEventNoticeScheduler()
            let model = model(clock)
            let installation = UUID()
            let notice = attentionNotice(epoch: model.receiverEpoch, installation: installation)
            _ = model.accept(notice)
            let action = model.snapshot.current!.action!
            var completion: (@MainActor (SessionNavigationActionResult) -> Void)?
            let coordinator = SessionNavigationCoordinator(
                model: model, scheduler: clock.scheduler()
            ) { _, complete in
                completion = complete
                return EventNoticeCancellation {}
            }
            coordinator.openSession(
                capability(notice), action: action, generation: coordinator.capabilityGeneration)
            switch change {
            case "version":
                _ = model.accept(
                    attentionNotice(epoch: model.receiverEpoch, installation: installation))
            case "epoch": model.clearForPrivacy()
            case "capability": coordinator.replaceCapabilityGeneration(UUID())
            case "cancel": coordinator.cancel()
            default: _ = model.remove(action)
            }
            let expectedCount = model.snapshot.totalCount
            completion?(.exactReturnConfirmed)
            expect(
                model.snapshot.totalCount == expectedCount
                    && coordinator.result != .exactReturnConfirmed,
                "旧结果不得删除新版本或展示迟到成功：\(change)")
        }
        let clock = ManualEventNoticeScheduler()
        let model = model(clock)
        let notice = attentionNotice(epoch: model.receiverEpoch)
        _ = model.accept(notice)
        let action = model.snapshot.current!.action!
        final class Outcome { var value = SessionNavigationActionResult.succeeded }
        let outcome = Outcome()
        let coordinator = SessionNavigationCoordinator(model: model, scheduler: clock.scheduler()) {
            _, complete in
            complete(outcome.value)
            return EventNoticeCancellation {}
        }
        coordinator.openSession(
            capability(notice), action: action, generation: coordinator.capabilityGeneration)
        expect(model.snapshot.totalCount == 1, "通用成功不等同于精确会话确认")
        outcome.value = .exactReturnConfirmed
        coordinator.openSession(
            capability(notice), action: action, generation: coordinator.capabilityGeneration)
        expect(
            model.snapshot.totalCount == 0 && model.lastRemovalReason == .exactReturnConfirmed,
            "确认只消除对应版本")
    }

    suite("Navigation：复制如实反馈、陈旧 ID 不写入、隐私清空不改主动导出") {
        let clock = ManualEventNoticeScheduler()
        let model = model(clock)
        let installation = UUID()
        _ = model.accept(attentionNotice(epoch: model.receiverEpoch, installation: installation))
        let action = model.snapshot.current!.action!
        let coordinator = SessionNavigationCoordinator(model: model, scheduler: clock.scheduler())
        expect(
            !coordinator.copy(action) { _ in false } && coordinator.result == .copyFailed,
            "写入失败明确反馈")
        var clipboard: String?
        expect(
            coordinator.copy(action) {
                clipboard = $0; return true
            } && coordinator.result == .copied, "写入成功才反馈成功")
        expect(model.snapshot.totalCount == 1, "复制不移除")
        _ = model.accept(attentionNotice(epoch: model.receiverEpoch, installation: installation))
        var writes = 0
        expect(
            !coordinator.copy(action) { _ in
                writes += 1; return true
            } && writes == 0, "旧版本不得复制最新 ID")
        model.clearForPrivacy()
        expect(clipboard == "session-id" && coordinator.action == nil, "隐私清空状态但不擅自覆盖主动导出")
    }
}
