import AppKit
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// Shared native slider/commit lifecycle for every presentation of the one global master-volume
/// axis. Callers retain their own labels and focus identities; this control alone owns the
/// ``VolumeDragSession`` so drag coalescing, rollback, external rebase, close flush, and
/// termination flush cannot drift between the panel and unified Settings.
@MainActor
struct SharedMasterVolumeSlider<FocusTarget: Hashable>: View {
    let diskVolume: Double
    let isEnabled: Bool
    let language: ClaudioAppLanguage
    let focusedTarget: FocusState<FocusTarget?>.Binding
    let focusIdentity: FocusTarget
    let accessibilityIdentifier: String
    let percentageWidth: CGFloat
    let flushRevision: Int?
    let flushesOnDisappear: Bool
    let onCommit: (Double) -> Double?

    @State private var session: VolumeDragSession
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    init(
        diskVolume: Double,
        isEnabled: Bool,
        language: ClaudioAppLanguage,
        focusedTarget: FocusState<FocusTarget?>.Binding,
        focusIdentity: FocusTarget,
        accessibilityIdentifier: String,
        percentageWidth: CGFloat = 42,
        flushRevision: Int? = nil,
        flushesOnDisappear: Bool = false,
        onCommit: @escaping (Double) -> Double?
    ) {
        self.diskVolume = diskVolume
        self.isEnabled = isEnabled
        self.language = language
        self.focusedTarget = focusedTarget
        self.focusIdentity = focusIdentity
        self.accessibilityIdentifier = accessibilityIdentifier
        self.percentageWidth = percentageWidth
        self.flushRevision = flushRevision
        self.flushesOnDisappear = flushesOnDisappear
        self.onCommit = onCommit
        _session = State(initialValue: VolumeDragSession(baseline: diskVolume))
    }

    var body: some View {
        HStack(spacing: 7) {
            Slider(
                value: Binding(
                    get: { session.draft },
                    set: { value in
                        if session.isDragging {
                            session.drag(to: value)
                        } else {
                            commit(session.adjust(to: value))
                        }
                    }),
                in: 0...1,
                onEditingChanged: { editing in
                    if editing {
                        session.begin()
                    } else {
                        commit(session.end())
                    }
                })
            Text("\(Int((session.draft * 100).rounded()))%")
                .font(.system(size: 10.5 * typeScale, design: .monospaced))
                .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                .frame(width: percentageWidth, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .tint(ClaudioColor.clay(colorScheme))
        .focused(focusedTarget, equals: focusIdentity)
        .accessibilityLabel(ClaudioL10n(language: language).text(.panelMasterVolume))
        .accessibilityValue("\(Int((session.draft * 100).rounded()))%")
        .accessibilityIdentifier(accessibilityIdentifier)
        .disabled(!isEnabled)
        .onChange(of: diskVolume) { session.rebase(to: $0) }
        .onChange(of: flushRevision) { _ in flush() }
        .onDisappear {
            if flushesOnDisappear { flush() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
        ) { _ in
            flush()
        }
    }

    private func flush() {
        commit(session.flushPending())
    }

    private func commit(_ pendingValue: Double?) {
        guard let pendingValue else { return }
        if let landed = onCommit(pendingValue) {
            session.commitSucceeded(landed)
        } else {
            session.commitFailed()
        }
    }
}
