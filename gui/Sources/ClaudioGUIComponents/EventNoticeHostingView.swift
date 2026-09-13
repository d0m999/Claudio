import AppKit
import SwiftUI

/// Window geometry belongs to the retained controller. A flexible ScrollView's minimum-width
/// measurement must not become the panel's minimum height (especially for wrapped English text).
@MainActor
public final class EventNoticeHostingView: NSHostingView<EventNoticeView> {
    public required init(rootView: EventNoticeView) {
        super.init(rootView: rootView)
        if #available(macOS 13.0, *) { sizingOptions = [] }
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}
