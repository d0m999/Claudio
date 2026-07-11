import AppKit
import UniformTypeIdentifiers

/// The `NSOpenPanel` content-type allow-list shared by every "点按选择文件" entry point
/// (a11y-architect FIX 2): ``EventRowView``'s row-end import-bind affordance and
/// ``AudioDropZoneView``'s prompt both open a picker scoped to this same wav/mp3/aiff/m4a
/// set — mirroring ``AudioFormat``'s v1 whitelist (ENGINEERING.md 决议 "拖入自带音频":
/// "格式白名单（wav/mp3/aiff/m4a）"), never a second, independently-chosen list.
///
/// This is a **picker UX nicety only**, not the actual security boundary: a file whose
/// extension/UTI lies still passes this filter, but still gets real magic-byte content
/// sniffing (``sniffAudioFormat(_:)``) inside `importAudioFile`'s existing hardened
/// pipeline before it's ever copied in — exactly as a drag-and-drop already does.
let audioOpenPanelContentTypes: [UTType] = [.wav, .mp3, .aiff, .mpeg4Audio]

/// Runs the shared audio picker and returns whatever the user chose (empty on cancel) —
/// the ONE `NSOpenPanel` construction both "点按选择文件" entry points go through
/// (`/ship` 评审: the identical six-line panel setup had been copy-pasted into BOTH
/// ``EventRowView/openImportPanel()`` and ``AudioDropZoneView/openImportPanel()``, while
/// THIS file existed precisely to be their shared seam — a second copy is exactly how the
/// two pickers silently drift apart on the whitelist, on `canChooseDirectories`, or on any
/// future hardening flag).
///
/// `allowsMultipleSelection` is the only axis the two call sites genuinely differ on: a
/// single event row binds exactly one file, the drop zone batches many (mirroring each
/// one's own `.onDrop` semantics). Everything else — the ``audioOpenPanelContentTypes``
/// whitelist, files-not-directories — is identical BY CONSTRUCTION here, not by two
/// independent developers remembering to keep it so.
///
/// `@MainActor` (like ``loadDropRequest(from:)``): `NSOpenPanel` is main-actor-only, and
/// both callers are `@MainActor` SwiftUI views. Compile-only on this machine — the modal
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
