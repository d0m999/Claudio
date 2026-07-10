import ClaudioGUICore
import Foundation

// MARK: - sniffAudioFormat: content-based whitelist (T8 acceptance criterion 2 — "enforced
// BY CONTENT (magic bytes / container sniffing), not by trusting the file extension")

@MainActor
func runAudioFormatSniffSuites() {
    suite("sniffAudioFormat: recognizes every whitelisted format by its magic bytes") {
        expect(sniffAudioFormat(validWAVData()) == .wav, "a RIFF/WAVE header must sniff as .wav")
        expect(sniffAudioFormat(validAIFFData()) == .aiff, "a FORM/AIFF header must sniff as .aiff")
        expect(
            sniffAudioFormat(validMP3ID3Data()) == .mp3, "an ID3v2-tagged file must sniff as .mp3")
        expect(
            sniffAudioFormat(validMP3FrameSyncData()) == .mp3,
            "a bare MPEG frame-sync header must sniff as .mp3")
        expect(sniffAudioFormat(validM4AData()) == .m4a, "an ftyp/M4A +moov file must sniff as .m4a")
    }

    suite("sniffAudioFormat: rejects unrelated content regardless of what it claims to be") {
        expect(
            sniffAudioFormat(evilShellScriptData()) == nil,
            "a shell script's bytes must never sniff as any whitelisted audio format")
        expect(sniffAudioFormat(Data()) == nil, "empty data must not sniff as any format")
        expect(
            sniffAudioFormat(Data([0x00, 0x01, 0x02])) == nil,
            "too-short/garbage data must not sniff as any format")
    }

    suite("sniffAudioFormat: an ftyp box WITHOUT a moov marker does not pass as .m4a") {
        var data = Data([0x00, 0x00, 0x00, 0x18])
        data.append(Data("ftyp".utf8))
        data.append(Data("M4A ".utf8))
        data.append(Data(repeating: 0, count: 16))
        expect(
            sniffAudioFormat(data) == nil,
            "ftyp+audio-brand alone, without a moov box anywhere in the file, must not sniff as .m4a"
        )
    }

    suite("sniffAudioFormat: an ftyp box with a non-audio brand does not pass as .m4a") {
        var data = Data([0x00, 0x00, 0x00, 0x18])
        data.append(Data("ftyp".utf8))
        data.append(Data("M4V ".utf8))  // video brand, deliberately excluded
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        data.append(Data("moov".utf8))
        expect(
            sniffAudioFormat(data) == nil, "a video-family ftyp brand must not sniff as audio .m4a")
    }
}
