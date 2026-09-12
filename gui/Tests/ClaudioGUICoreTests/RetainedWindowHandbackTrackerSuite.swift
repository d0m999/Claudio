import ClaudioGUICore

@MainActor
func runRetainedWindowHandbackTrackerSuites() {
    suite("RetainedWindowHandbackTracker：Settings 移交延迟动作保留最新宿主与原面板目标") {
        var tracker = RetainedWindowHandbackTracker<String>()
        tracker.beginPresentation(returnTo: "Original Host")
        tracker.noteExternalActivation(
            "Latest Host", isWindowVisible: true, isCurrentApplication: false)
        var restored: [String] = []
        let restoreAfterNotice = tracker.consumeOnClose { application in
            restored.append("settings-button / \(application ?? "missing")")
        }
        expect(restored.isEmpty, "Settings 互斥关闭只能移交动作，不能提前激活宿主或面板")
        expect(tracker.consumeOnClose() == nil, "Settings 的旧 close 回调不能重复消费已转交债务")
        tracker.beginPresentation(returnTo: "Next Presentation")
        restoreAfterNotice()
        expect(
            restored == ["settings-button / Latest Host"],
            "提示关闭必须恢复原面板目标和移交时的最新外部宿主，不受下一次展示污染")
        expect(
            tracker.consumeOnClose() == "Next Presentation",
            "执行旧的归还动作不能消费下一次 Settings 的债务")
    }

    suite("RetainedWindowHandbackTracker：只消费可见期间最近一次外部激活，关闭后不回填旧债务") {
        var tracker = RetainedWindowHandbackTracker<String>()
        tracker.beginPresentation(returnTo: "App Before Presentation")

        expect(
            tracker.consumeOnClose() == "App Before Presentation",
            "没有后续外部 activation 时必须交回打开 retained window 前的原始 app")

        tracker.beginPresentation(returnTo: "App Before Presentation")

        tracker.noteExternalActivation(
            "hidden-app", isWindowVisible: false, isCurrentApplication: false)
        tracker.noteExternalActivation(
            "Claudio", isWindowVisible: true, isCurrentApplication: true)
        tracker.noteExternalActivation(
            "App A", isWindowVisible: true, isCurrentApplication: false)
        tracker.noteExternalActivation(
            "App B", isWindowVisible: true, isCurrentApplication: false)

        expect(
            tracker.consumeOnClose() == "App B",
            "窗口可见期间从 A 切到 B 后，关闭必须只交回最近的 B")

        tracker.noteExternalActivation(
            "close-race", isWindowVisible: true, isCurrentApplication: false)
        expect(
            tracker.consumeOnClose() == nil,
            "关闭已经开始后到达的 activation notification 不得重新填回刚消费的 handback")

        tracker.beginPresentation()
        tracker.noteExternalActivation(
            "App C", isWindowVisible: true, isCurrentApplication: false)
        expect(
            tracker.consumeOnClose() == "App C",
            "retained window 下一次真实展示必须开启全新 handback 代次")
    }
}
