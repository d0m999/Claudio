import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
private func navigationNotice(
    epoch: UUID = UUID(),
    source: HostEventSource? = HostEventSource(
        projectLabel: "project",
        projectKey: "project-key",
        sessionID: "session-id",
        sessionLabel: "session · session")
) -> HostEventNotice {
    let binding = HostCapabilityCatalog.binding(host: .codex, nativeEvent: "Stop")!
    return HostEventNotice(
        receiverEpoch: epoch,
        surface: .codex,
        bindingID: binding.id,
        installationID: UUID(),
        nativeEvent: binding.nativeEvent!,
        event: binding.event,
        occurredAt: Date(),
        source: source)
}

@MainActor
func runSessionNavigationSuites() async {
    suite("SessionNavigation：未经验证的 route 只允许查看来源与复制，不伪造精确跳转") {
        let notice = navigationNotice()
        let capability = sessionNavigationCapability(for: notice)
        expect(
            capability == .viewSource
                && capability.canViewSource
                && capability.canCopySessionID
                && !capability.canOpenSession,
            "没有 verified target 时必须 fail closed 为 viewSource")

        let target = SessionNavigationTarget(
            surface: .codex,
            projectKey: "project-key",
            sessionID: "session-id")
        let verified = sessionNavigationCapability(for: notice, verifiedTarget: target)
        expect(
            verified == .viewSession(target) && verified.canOpenSession,
            "只有完全匹配的已验证 target 才能显示查看会话能力")
        let mismatched = sessionNavigationCapability(
            for: notice,
            verifiedTarget: SessionNavigationTarget(
                surface: .codex,
                projectKey: "other-key",
                sessionID: "session-id"))
        expect(mismatched == .viewSource, "项目 key 不匹配不得误跳到其他同名项目")
        expect(
            sessionNavigationCapability(for: navigationNotice(source: nil)) == .unavailable,
            "没有安全来源时不得显示任何导航动作")
    }

    await suite("SessionNavigationCoordinator：动作结果可观察且迟到结果不会覆盖复制状态") {
        let target = SessionNavigationTarget(
            surface: .codex,
            projectKey: "project-key",
            sessionID: "session-id")
        var navigatedTarget: SessionNavigationTarget?
        let coordinator = SessionNavigationCoordinator { target in
            navigatedTarget = target
            await Task.yield()
            return .succeeded
        }
        coordinator.openSession(.viewSession(target))
        expect(coordinator.result == .started, "有效导航动作启动时必须先发布 started")
        try? await Task.sleep(nanoseconds: 1_000_000)
        expect(
            coordinator.result == .succeeded && navigatedTarget == target,
            "完成的导航结果必须与原 target 对应")

        coordinator.openSession(.viewSession(target))
        coordinator.markCopied()
        await Task.yield()
        expect(
            coordinator.result == .copied,
            "复制动作必须使先前在途导航结果失效，不得迟到抢焦点")
        coordinator.openSession(.viewSource)
        expect(coordinator.result == .unavailable, "未验证能力不得启动精确导航")
    }
}
