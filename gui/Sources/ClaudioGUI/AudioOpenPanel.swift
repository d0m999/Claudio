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
