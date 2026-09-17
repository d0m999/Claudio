import AppKit
import SwiftUI

extension View {
    @ViewBuilder
    package func soundPacksLayoutProbe(_ identifier: String) -> some View {
        #if DEBUG
        background(SoundPacksLayoutReportingView(identifier: identifier))
        #else
        self
        #endif
    }
}

#if DEBUG
@MainActor
package enum SoundPacksLayoutRecorder {
    package private(set) static var frames: [String: CGRect] = [:]

    package static func reset() {
        frames.removeAll()
    }

    fileprivate static func record(_ identifier: String, frame: CGRect) {
        frames[identifier] = frame
    }
}

private struct SoundPacksLayoutReportingView: NSViewRepresentable {
    let identifier: String

    func makeNSView(context _: Context) -> SoundPacksLayoutReportingNSView {
        SoundPacksLayoutReportingNSView(identifier: identifier)
    }

    func updateNSView(_ view: SoundPacksLayoutReportingNSView, context _: Context) {
        view.probeIdentifier = identifier
        view.needsLayout = true
    }
}

private final class SoundPacksLayoutReportingNSView: NSView {
    var probeIdentifier: String

    init(identifier: String) {
        probeIdentifier = identifier
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        guard let contentView = window?.contentView else { return }
        SoundPacksLayoutRecorder.record(probeIdentifier, frame: convert(bounds, to: contentView))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }
}
#endif
