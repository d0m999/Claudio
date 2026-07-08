import ClaudioGUICore
import Foundation

// MARK: - T8 shared fixtures: minimal, correct magic-byte headers for each whitelisted
// format, plus content that must NOT sniff as audio no matter what extension it's given,
// and the stub `AudioDurationProbing` conformance every import suite injects.
//
// Not `private` (unlike most single-suite-file helpers elsewhere in this target) — these
// are deliberately shared across `AudioFormatSniffSuite.swift`, `AudioImportSuite.swift`,
// `AudioImportBatchSuite.swift`, and `AudioImportViewModelSuite.swift`, mirroring how
// `TestSupport.swift`'s helpers are shared, just scoped to audio-import fixtures instead
// of generic filesystem fixtures.

/// A tiny-but-structurally-correct RIFF/WAVE header, followed by harmless padding — real
/// `afplay`/AVFoundation would likely refuse to actually *play* this (no real `fmt `/
/// `data` chunk payload), but `sniffAudioFormat` only inspects the container header, which
/// this satisfies exactly like a real WAV file's first 12 bytes would.
func validWAVData() -> Data {
    var data = Data("RIFF".utf8)
    data.append(contentsOf: [0x24, 0x00, 0x00, 0x00])
    data.append(Data("WAVEfmt ".utf8))
    data.append(Data(repeating: 0, count: 16))
    return data
}

func validAIFFData() -> Data {
    var data = Data("FORM".utf8)
    data.append(contentsOf: [0x00, 0x00, 0x00, 0x20])
    data.append(Data("AIFFCOMM".utf8))
    data.append(Data(repeating: 0, count: 16))
    return data
}

/// A real-world-shaped MP3: ID3v2 tag header first (the common case), not a bare frame
/// sync — see ``validMP3FrameSyncData()`` for that variant.
func validMP3ID3Data() -> Data {
    var data = Data("ID3".utf8)
    data.append(contentsOf: [0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    data.append(Data(repeating: 0, count: 32))
    return data
}

func validMP3FrameSyncData() -> Data {
    var data = Data([0xFF, 0xFB, 0x90, 0x00])
    data.append(Data(repeating: 0, count: 32))
    return data
}

/// `ftyp` box with an audio major brand (`"M4A "`), plus a `moov` marker elsewhere in the
/// file — both signals ``sniffAudioFormat(_:)`` requires for `.m4a`.
func validM4AData() -> Data {
    var data = Data([0x00, 0x00, 0x00, 0x18])
    data.append(Data("ftyp".utf8))
    data.append(Data("M4A ".utf8))
    data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
    data.append(Data("isomM4A ".utf8))
    data.append(Data("moov".utf8))
    data.append(Data(repeating: 0, count: 16))
    return data
}

/// A plain shell script — the extension-spoofing attack vector: this gets a `.mp3`
/// filename in the fixtures that use it, despite being unrelated content.
func evilShellScriptData() -> Data {
    Data("#!/bin/sh\necho pwned\n".utf8)
}

/// A stub `AudioDurationProbing` conformance — the DI seam T8 acceptance criterion 4
/// requires, so this Foundation-only test module never needs AVFoundation either.
struct StubDurationProbe: AudioDurationProbing {
    let fixedDuration: TimeInterval?
    func probeDuration(of fileURL: URL) -> TimeInterval? { fixedDuration }
}

@MainActor
func makeAudioImportEnvironment(
    userPacksDirectory: URL,
    bundledPacksDirectory: URL? = nil,
    duration: TimeInterval? = 1.0,
    maxFileSizeBytes: Int = 5 * 1024 * 1024,
    maxDurationSeconds: Double = 3.0
) -> AudioImportEnvironment {
    AudioImportEnvironment(
        userPacksDirectory: userPacksDirectory,
        bundledPacksDirectory: bundledPacksDirectory,
        durationProbe: StubDurationProbe(fixedDuration: duration),
        limits: AudioImportLimits(
            maxFileSizeBytes: maxFileSizeBytes, maxDurationSeconds: maxDurationSeconds)
    )
}
