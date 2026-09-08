/// Tracks the most recently activated external application while a retained Claudio window is
/// visible. The generic payload keeps AppKit out of `ClaudioGUICore`, so lifecycle behavior can be
/// tested with simple values while `ClaudioGUI` stores the real `NSRunningApplication` proxy.
public struct RetainedWindowHandbackTracker<Application> {
    private var latestExternalApplication: Application?
    private var isClosingWindow = false

    public init() {}

    /// Starts a real hidden-to-visible presentation with the application active before the window
    /// took focus. A later external activation supersedes that fallback. Re-showing an already
    /// visible retained window must not call this because it would erase the current handback debt.
    public mutating func beginPresentation(returnTo application: Application? = nil) {
        isClosingWindow = false
        latestExternalApplication = application
    }

    /// Records only an external activation observed while this presentation is genuinely visible.
    /// Notifications arriving during close are ignored so they cannot refill state just consumed by
    /// ``consumeOnClose()``.
    public mutating func noteExternalActivation(
        _ application: Application,
        isWindowVisible: Bool,
        isCurrentApplication: Bool
    ) {
        guard !isClosingWindow, isWindowVisible, !isCurrentApplication else { return }
        latestExternalApplication = application
    }

    /// Ends the presentation and consumes its latest external application exactly once.
    public mutating func consumeOnClose() -> Application? {
        isClosingWindow = true
        let application = latestExternalApplication
        latestExternalApplication = nil
        return application
    }
}
