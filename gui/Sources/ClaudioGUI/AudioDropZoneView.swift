import AppKit
import ClaudioGUICore
import SwiftUI
import UniformTypeIdentifiers

/// The "+ 拖入你自己的声音" drop zone (DESIGN.md "拖入 drop-zone" component + ENGINEERING.md
/// T8): renders idle/hover/reject/success purely off ``AudioImportViewModel/state`` —
/// every validation *decision* already happened in `ClaudioGUICore` before this view ever
/// re-renders (DoD: "状态正确性下沉 view-model / state fixture 测，非像素快照"). This view
/// only lays pixels out and wires the system drag-and-drop callback + the auto-preview
/// side effect (via ``AudioPreviewPlaying``) — none of T8's actual hardening logic lives
/// here.
public struct AudioDropZoneView: View {
    @ObservedObject private var viewModel: AudioImportViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false
    /// Dynamic-Type scale factor for this zone's fixed `.system(size:)` text (a11y fix) — see
    /// ``EventRowView``'s `typeScale` for the full rationale.
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    private let previewPlayer: AudioPreviewPlaying

    public init(viewModel: AudioImportViewModel) {
        self.viewModel = viewModel
        self.previewPlayer = NSSoundAudioPreviewPlayer()
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovering ? ClaudioColor.claySoft(colorScheme) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isHovering ? ClaudioColor.clay(colorScheme) : ClaudioColor.hairlineStrong(colorScheme),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                    )
            )
            .onDrop(of: [UTType.fileURL], isTargeted: hoverBinding, perform: handleDrop)
            .onAppear {
                viewModel.onImportSucceeded = { [previewPlayer] file in
                    previewPlayer.play(fileAt: file.destinationURL)
                }
            }
    }

    private var hoverBinding: Binding<Bool> {
        Binding(
            get: { isHovering },
            set: { newValue in
                isHovering = newValue
                if newValue {
                    viewModel.hover()
                } else {
                    viewModel.cancelHover()
                }
            }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .hover:
            promptLabel
        case .reject(let reason):
            rejectRow(reason)
        case .success(let file):
            successRow(file)
        }
    }

    /// A real `Button` (a11y-architect FIX 2, CRITICAL — WCAG 2.1.1): this control's own
    /// accessibility label has always promised "拖入或点按" (drag OR TAP), but until this
    /// fix it only ever handled `.onDrop` (attached to `body`, still preserved unchanged) —
    /// a keyboard/VoiceOver/Switch Control user had no way to activate it. Tapping now opens
    /// ``openImportPanel()`` (an `NSOpenPanel`, multi-select), feeding every chosen file into
    /// the SAME ``AudioImportViewModel/handleDrop(requests:)`` batch pipeline a multi-file
    /// drop already uses — never a second import path.
    private var promptLabel: some View {
        Button(action: openImportPanel) {
            Text("+ 拖入你自己的声音")
                .font(.system(size: 12.5 * typeScale))
                .foregroundColor(isHovering ? ClaudioColor.clay(colorScheme) : ClaudioColor.textSecondary(colorScheme))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("拖入或点按添加你自己的声音")
    }

    /// Opens an `NSOpenPanel` (multi-select — mirrors this zone's own multi-file `.onDrop`
    /// batch semantics) scoped to the same wav/mp3/aiff/m4a whitelist ``AudioFormat``
    /// documents, feeding every chosen file into the SAME hardened import pipeline a drop
    /// already uses. `allowedContentTypes` is a picker-UX nicety only, never the actual
    /// security boundary (see ``audioOpenPanelContentTypes``'s doc comment). AppKit —
    /// compile-only here, manual-verify on a real Mac.
    private func openImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = audioOpenPanelContentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        let requests = panel.urls.map {
            AudioImportRequest(sourceURL: $0, suggestedFileName: $0.lastPathComponent)
        }
        guard !requests.isEmpty else { return }
        Task { @MainActor in
            await viewModel.handleDrop(requests: requests)
        }
    }

    private func rejectRow(_ reason: DropRejectionReason) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(ClaudioColor.error(colorScheme))
            Text(reason.message)
                .font(.system(size: 11.5 * typeScale))
                .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func successRow(_ file: ImportedAudioFile) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(ClaudioColor.success(colorScheme))
            Text(file.fileName)
                .font(.system(size: 11.5 * typeScale, design: .monospaced))
                .foregroundColor(ClaudioColor.text(colorScheme))
        }
        .accessibilityLabel("已导入 \(file.fileName)")
    }

    /// Extracts every dropped item's real on-disk URL + suggested filename, then hands
    /// the whole batch to the view-model in one call — a single-file drop and a
    /// multi-file drop both flow through ``AudioImportViewModel/handleDrop(requests:)``
    /// (partial-success semantics apply uniformly, T8 acceptance criterion 7).
    ///
    /// Loads providers **sequentially**, not concurrently: `NSItemProvider` isn't
    /// `Sendable`, and drag-and-drop batches here are a handful of small local chime
    /// files at most — the concurrency-checker-fighting required to fan these out onto
    /// parallel child tasks isn't worth it for that workload. Sequential `await`s inside
    /// one `@MainActor` `Task` stay provably race-free without any unsafe opt-outs.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        Task { @MainActor in
            var requests: [AudioImportRequest] = []
            for provider in providers {
                if let request = await loadDropRequest(from: provider) {
                    requests.append(request)
                }
            }
            guard !requests.isEmpty else { return }
            await viewModel.handleDrop(requests: requests)
        }
        return true
    }
}

/// Top-level (not a member of ``AudioDropZoneView``, which is only ever touched from
/// SwiftUI's own main-actor context anyway) and explicitly `@MainActor`: `handleDrop`
/// only ever calls this from inside its own `Task { @MainActor in ... }`, so keeping both
/// sides on the same actor avoids "sending non-Sendable `NSItemProvider` across an
/// isolation boundary" entirely, rather than fighting it with an unsafe opt-out. The
/// `loadObject` completion handler below still genuinely runs off the main actor at
/// runtime (an AppKit implementation detail) — that's why it must not capture `provider`
/// itself (see the comment inside), only the `Sendable` string already read from it.
/// Drops (rather than failing the whole batch over) any single provider that couldn't
/// hand back a URL at all — as opposed to resolving fine but then failing *validation*,
/// which is `importAudioFile`'s job, not this extraction step's.
///
/// Module-internal (not `private`) so `EventRowView` (T16) reuses this exact
/// `NSItemProvider` → `AudioImportRequest` extraction for its own row-level drop target,
/// instead of a second, near-identical copy of the same AppKit plumbing.
@MainActor
func loadDropRequest(from provider: NSItemProvider) async -> AudioImportRequest? {
    // Read the Sendable `String?` up front, synchronously, on whatever isolation this
    // function is already running under — the `loadObject` completion handler below runs
    // on an arbitrary (non-main-actor) queue and must not capture `provider` itself (a
    // non-Sendable `NSObject` subclass) to stay clean under strict concurrency checking.
    let suggestedNameFallback = provider.suggestedName
    return await withCheckedContinuation { continuation in
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else {
                continuation.resume(returning: nil)
                return
            }
            let suggestedFileName = suggestedNameFallback ?? url.lastPathComponent
            continuation.resume(
                returning: AudioImportRequest(sourceURL: url, suggestedFileName: suggestedFileName))
        }
    }
}
