import AppKit
import UniformTypeIdentifiers

/// The `NSOpenPanel` content-type allow-list for the "点按选择文件" entry point
/// (a11y-architect FIX 2): ``EventRowView``'s row-end import-bind affordance opens a
/// picker scoped to this same wav/mp3/aiff/m4a set — mirroring ``AudioFormat``'s v1
/// whitelist (ENGINEERING.md 决议 "拖入自带音频": "格式白名单（wav/mp3/aiff/m4a）"), never a
/// second, independently-chosen list.
///
/// This is a **picker UX nicety only**, not the actual security boundary: a file whose
/// extension/UTI lies still passes this filter, but still gets real magic-byte content
/// sniffing (``sniffAudioFormat(_:)``) inside `importAudioFile`'s existing hardened
/// pipeline before it's ever copied in — exactly as a drag-and-drop already does.
let audioOpenPanelContentTypes: [UTType] = [.wav, .mp3, .aiff, .mpeg4Audio]

/// Runs the shared audio picker and returns whatever the user chose (empty on cancel) —
/// the ONE `NSOpenPanel` construction the "点按选择文件" entry point goes through
/// (`/ship` 评审: kept as its own shared seam — ``EventRowView/openImportPanel()`` is the
/// sole production caller today, but a second "点按选择文件" entry point should reuse this
/// exact function rather than copy-pasting the six-line panel setup, which is how a past
/// second copy silently drifted on the whitelist / `canChooseDirectories` / hardening
/// flags before it was consolidated here).
///
/// `allowsMultipleSelection` stays a parameter (rather than a hardcoded `false`) so a
/// future multi-file "点按选择文件" entry point can opt in without a second, parallel
/// panel construction. Everything else — the ``audioOpenPanelContentTypes`` whitelist,
/// files-not-directories — is fixed BY CONSTRUCTION here, not left for each caller to
/// re-decide.
///
/// `@MainActor` (like ``loadDropRequest(from:)``): `NSOpenPanel` is main-actor-only, and
/// its caller is an `@MainActor` SwiftUI view. Compile-only on this machine — the modal
/// panel itself is manual-verify on a real Mac.
@MainActor
func runAudioOpenPanel(allowsMultipleSelection: Bool) -> [URL] {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = audioOpenPanelContentTypes
    panel.allowsMultipleSelection = allowsMultipleSelection
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    guard panel.runModal() == .OK else { return [] }
    return panel.urls
}
