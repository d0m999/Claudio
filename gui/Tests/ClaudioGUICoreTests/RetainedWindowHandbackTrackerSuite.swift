import ClaudioGUICore

@MainActor
func runRetainedWindowHandbackTrackerSuites() {
    suite("RetainedWindowHandbackTracker：只消费可见期间最近一次外部激活，关闭后不回填旧债务") {
        var tracker = RetainedWindowHandbackTracker<String>()
        tracker.beginPresentation()

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
