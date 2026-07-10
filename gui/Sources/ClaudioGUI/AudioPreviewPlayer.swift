import AppKit
import Foundation

/// Plays a short local preview of a just-imported audio file — the "自动试听确认" step
/// (ENGINEERING.md T8 acceptance criterion 8: "复制进用户包 + 行内文件名更新 + 自动试听确认").
/// A small protocol (not a bare `NSSound` call inline in the view) so `AudioDropZoneView`
/// stays swappable, mirroring the DI pattern `ClaudioGUICore` uses throughout.
protocol AudioPreviewPlaying {
    func play(fileAt url: URL)
}

/// Real implementation: `NSSound` is the simplest correct way to play a short local audio
/// file for a UI preview on macOS — v1's drag-in chimes are capped at a few seconds
/// (``AudioImportLimits/maxDurationSeconds``), so there's no need for AVFoundation's
/// heavier playback engine just to confirm "yes, this is the sound you just dropped in".
///
/// A **class** holding the playing `NSSound` in a stored property, not a struct creating it
/// as a local: `NSSound.play()` starts playback asynchronously and returns immediately, and
/// `NSSound` **stops when it is deallocated**. A local sound would be released by ARC the
/// instant `play(fileAt:)` returned — cutting the auto-试听 (T8 acceptance criterion 8) off
/// before it was audible. Retaining it here (replaced on the next preview) keeps it alive
/// for the ≤ few-second chime; the owning `AudioDropZoneView` holds this player for its own
/// lifetime, so the reference chain lasts as long as the drop zone is on screen
/// (swift-reviewer T8 finding: NSSound not retained for playback duration).
final class NSSoundAudioPreviewPlayer: AudioPreviewPlaying {
    private var currentSound: NSSound?

    func play(fileAt url: URL) {
        let sound = NSSound(contentsOf: url, byReference: true)
        currentSound = sound
        sound?.play()
    }
}
