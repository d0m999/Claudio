import Foundation

/// The v1 drag-in whitelist: the four container formats `afplay` can already play
/// (ENGINEERING.md 决议 "拖入自带音频": "格式白名单（wav/mp3/aiff/m4a）"). Deliberately
/// closed — anything else is ``DropRejectionReason/nonWhitelistFormat``, never a silent
/// pass-through.
public enum AudioFormat: String, Sendable, Equatable, CaseIterable {
    case wav
    case mp3
    case aiff
    case m4a
}

/// Sniffs `data`'s real container format from its magic bytes/header structure —
/// deliberately ignoring any file extension or claimed UTI. An attacker renaming
/// `evil.sh` → `evil.mp3` must still be rejected by what the bytes actually are, never by
/// trusting the name on disk (ENGINEERING.md T8 acceptance criterion 2). Returns `nil`
/// for anything outside the wav/mp3/aiff/m4a whitelist, including empty/too-short data.
public func sniffAudioFormat(_ data: Data) -> AudioFormat? {
    if isRIFFWave(data) { return .wav }
    if isAIFFContainer(data) { return .aiff }
    if isM4AContainer(data) { return .m4a }
    if isMP3Stream(data) { return .mp3 }
    return nil
}

/// WAV: a RIFF container whose form type is `WAVE` — `"RIFF" <4-byte size> "WAVE"`.
private func isRIFFWave(_ data: Data) -> Bool {
    matches(data, atByteOffset: 0, ascii: "RIFF") && matches(data, atByteOffset: 8, ascii: "WAVE")
}

/// AIFF / AIFF-C: an IFF `FORM` container whose form type is `AIFF` or `AIFC` —
/// `"FORM" <4-byte size> "AIFF"|"AIFC"`.
private func isAIFFContainer(_ data: Data) -> Bool {
    guard matches(data, atByteOffset: 0, ascii: "FORM") else { return false }
    return matches(data, atByteOffset: 8, ascii: "AIFF") || matches(data, atByteOffset: 8, ascii: "AIFC")
}

/// M4A: an ISO base media (MPEG-4) container carrying an audio brand — a leading `ftyp`
/// box (`<4-byte size> "ftyp" <4-byte major brand> ...`) whose major brand is one of the
/// audio-family brands, *plus* a `moov` box present somewhere in the file (the
/// movie/track metadata box every non-streamed MPEG-4 file must carry) as a second,
/// independent structural signal beyond the brand tag alone — matching the task's spec:
/// "…ftyp with an audio brand like M4A / mp42/isom+moov". `mp4v`/`M4V ` (video-family
/// brands) are deliberately excluded: this whitelist is audio-only.
private func isM4AContainer(_ data: Data) -> Bool {
    guard matches(data, atByteOffset: 4, ascii: "ftyp") else { return false }
    let audioBrands: Set<String> = ["M4A ", "M4B ", "mp42", "mp41", "isom"]
    guard let majorBrand = asciiString(data, atByteOffset: 8, length: 4),
        audioBrands.contains(majorBrand)
    else {
        return false
    }
    return containsASCIIMarker(data, "moov")
}

/// MP3: either an ID3v2 tag header (`"ID3"`, the common case for real-world MP3 files) or
/// a bare MPEG audio frame sync (a `0xFF` byte followed by a byte whose top 3 bits are
/// also set — the 11-bit frame-sync pattern `0xFFEx…`) at the very start of the file.
private func isMP3Stream(_ data: Data) -> Bool {
    if matches(data, atByteOffset: 0, ascii: "ID3") { return true }
    guard data.count >= 2 else { return false }
    let first = data[data.startIndex]
    let second = data[data.startIndex + 1]
    return first == 0xFF && (second & 0xE0) == 0xE0
}

/// Whether `data` has `ascii`'s bytes at byte offset `offset` (counted from `data`'s own
/// `startIndex`, so this stays correct for `Data` slices too, not just freshly-loaded
/// whole buffers).
private func matches(_ data: Data, atByteOffset offset: Int, ascii: String) -> Bool {
    asciiString(data, atByteOffset: offset, length: ascii.utf8.count) == ascii
}

/// Reads `length` bytes at byte offset `offset` and decodes them as ASCII, or `nil` if
/// out of bounds.
private func asciiString(_ data: Data, atByteOffset offset: Int, length: Int) -> String? {
    guard offset >= 0, length >= 0, data.count >= offset + length else { return nil }
    let start = data.index(data.startIndex, offsetBy: offset)
    let end = data.index(start, offsetBy: length)
    return String(bytes: data[start..<end], encoding: .ascii)
}

/// Whether the 4-byte ASCII `marker` appears anywhere in `data`. Built on `Data`'s own
/// `range(of:)` (a Foundation-provided, already-tested byte search) rather than a
/// hand-rolled scan — acceptable to run over the whole buffer here since every caller has
/// already been through the 5MB size cap before this ever runs.
private func containsASCIIMarker(_ data: Data, _ marker: String) -> Bool {
    guard let markerData = marker.data(using: .ascii) else { return false }
    return data.range(of: markerData) != nil
}
