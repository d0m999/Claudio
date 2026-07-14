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
    /// The volume the auto-试听（on a successful import）should play at, resolved **at play
    /// time**, never at construction time (PLAN-MASTER-VOLUME.md D28). A `Double` value here
    /// instead of a closure would be captured once, in ``body``'s `.onAppear` below, and stay
    /// frozen at whatever the master volume was the instant the panel opened — the exact bug
    /// D28 exists to close. `previewVolume(for:)` (`ClaudioGUICore`) is the caller's normal way
    /// to produce this from a `ClaudioConfig`.
    private let currentVolume: () -> Double

    public init(viewModel: AudioImportViewModel, currentVolume: @escaping () -> Double) {
        self.viewModel = viewModel
        self.currentVolume = currentVolume
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
                viewModel.onImportSucceeded = { [previewPlayer, currentVolume] file in
                    previewPlayer.play(fileAt: file.destinationURL, volume: Float(currentVolume()))
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
            FailureRow(message: reason.message)
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
    /// 文字颜色**恒为** `text-2`，hover 时也不转黏土——hover 的视觉反馈由**描边 + `clay-soft` 底色**
    /// 承载（见 `body` 的 `.background`/`.overlay`）。
    ///
    /// ## 为什么（DESIGN.md 自己登记的「待拍板」冲突，本轮 /ship 拍板）
    ///
    /// DESIGN.md 的「拖入 drop-zone」原本写着「hover 命中 → 边框/**文字**转黏土」，但它同时规定正文文字
    /// 恒保 ≥ 4.5:1 对比度。这两条互相矛盾：亮色下 clay `#C4633C` 压在 panel `#FFFDF8` 上实测只有
    /// **3.97:1**——过得了非文字的 ≥ 3:1，过不了正文的 ≥ 4.5:1。
    ///
    /// 三条出路里选了 DESIGN.md 自己列的 option 1：**文字不动，hover 感交给边框与底色**。它零品牌代价
    /// （黏土仍然是 hover 的唯一强调色，只是不落在文字上），且不必为这一处把 clay 调出第二个色值——
    /// 「品牌强调唯一 = 黏土 #D97757」这条不能为了一个 hover 态开口子。
    private var promptLabel: some View {
        Button(action: openImportPanel) {
            Text("+ 拖入你自己的声音")
                .font(.system(size: 12.5 * typeScale))
                .foregroundColor(ClaudioColor.textSecondary(colorScheme))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("拖入或点按添加你自己的声音")
    }

    /// Opens the shared audio picker (``runAudioOpenPanel(allowsMultipleSelection:)`` —
    /// multi-select here, mirroring this zone's own multi-file `.onDrop` batch semantics),
    /// feeding every chosen file into the SAME hardened import pipeline a drop already uses.
    /// The panel itself is constructed ONCE, in `AudioOpenPanel.swift`, shared with
    /// ``EventRowView``'s row-end affordance — never a second, independently-configured
    /// picker. AppKit — compile-only here, manual-verify on a real Mac.
    private func openImportPanel() {
        let requests = runAudioOpenPanel(allowsMultipleSelection: true).map {
            AudioImportRequest(sourceURL: $0, suggestedFileName: $0.lastPathComponent)
        }
        guard !requests.isEmpty else { return }
        Task { @MainActor in
            await viewModel.handleDrop(requests: requests)
        }
    }

    // `rejectRow(_:)` 已删（2026-07-15 冗余审计 · A 类修复）—— 它是 DESIGN.md「拒绝行」的六份手抄副本
    // 之一，而且是**漂得最远**的那一份：另外三处注释都声称与它「完全一致 / verbatim / identical」，而它的
    // ✗ 图标**根本没设字号**（继承默认 body 字号，比其余五处的 11pt 大一圈），文字是 11.5pt 不是 11pt。
    // 现在这一态渲染的是 ``FailureRow``（`PanelRows.swift`），字号回到 DESIGN.md 字号阶梯的「次要 /
    // 状态 = 11」档（2026-07-15 拍板）。

    /// 导入成功那一行。**不是**「拒绝行」的镜像，所以没有折进 ``FailureRow``：它用的是 `success` 绿 +
    /// `text`（主文字色）+ 等宽文件名，而拒绝行是 `error` 真红图标 + `text-2` 说明 —— 两者只是恰好都
    /// 长成「一个图标 + 一行字」。
    ///
    /// 字号 **11.5 → 11**（2026-07-15 拍板）：11.5 不在 DESIGN.md 字号阶梯的任何一档上。它本可以留着
    /// 不动（它不属于本轮合并的那六份），但那会让同一个 drop-zone 里「拒绝 11pt / 成功 11.5pt」——
    /// 拿一处旧漂移换一处新漂移。
    private func successRow(_ file: ImportedAudioFile) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11 * typeScale))
                .foregroundColor(ClaudioColor.success(colorScheme))
            Text(file.fileName)
                // DESIGN.md 字体表：数据 / 文件名 = 等宽，tabular-nums。
                .font(.system(size: 11 * typeScale, design: .monospaced))
                .monospacedDigit()
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
