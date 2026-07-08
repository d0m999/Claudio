import AVFoundation
import ClaudioGUICore
import Foundation

/// The real ``AudioDurationProbing`` implementation, backed by AVFoundation — deliberately
/// lives in the `ClaudioGUI` executable layer, not `ClaudioGUICore` (ENGINEERING.md T8
/// acceptance criterion 4: `ClaudioGUICore` must stay Foundation-only / dependency-free
/// for the `swift run --package-path gui claudio-gui-tests` harness, which has no
/// AVFoundation-backed simulator/device to exercise real audio decoding anyway). Tests
/// inject a stub conforming to `AudioDurationProbing` instead of this type — see
/// `AudioImportSuite.swift`'s `StubDurationProbe`.
struct AVFoundationAudioDurationProbe: AudioDurationProbing {
    func probeDuration(of fileURL: URL) -> TimeInterval? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let asset = AVURLAsset(url: fileURL)
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }
}
