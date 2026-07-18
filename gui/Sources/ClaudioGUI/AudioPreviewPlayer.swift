import AppKit
import Foundation

/// Plays a short local preview of a just-imported audio file — the "自动试听确认" step
/// (ENGINEERING.md T8 acceptance criterion 8: "复制进用户包 + 行内文件名更新 + 自动试听确认").
/// A small protocol (not a bare `NSSound` call inline in the view) so `PanelView`'s own
/// player stays swappable, mirroring the DI pattern `ClaudioGUICore` uses throughout.
///
/// `volume` (PLAN-MASTER-VOLUME.md D2): every preview — currently just the row-level 试听
/// ▶ button (`PanelView/playPreview(for:)`) — must play at the panel's current master
/// volume, not always at `NSSound`'s own default of `1.0`. (The fake drop-zone's own
/// auto-试听 on a successful import used to be a second caller here; it was removed along
/// with `AudioDropZoneView` — see PLAN-SOUND-MANAGER.md T1/T2 — and is slated (T2) to be
/// re-wired via each per-row ``AudioImportViewModel``'s `onImportSucceeded` hook, closing
/// over this same `PanelView`-owned player — `EventRowView` itself owns no player, only an
/// `onPreview` callback.) The caller resolves the volume
/// value (via ``previewVolume(for:)``, `ClaudioGUICore`, the one clamp this repo has),
/// never this protocol's conforming type re-deriving its own clamp table.
protocol AudioPreviewPlaying {
    func play(fileAt url: URL, volume: Float)
}

/// Real implementation: `NSSound` is the simplest correct way to play a short local audio
/// file for a UI preview on macOS — v1's drag-in chimes are capped at a few seconds
/// (``AudioImportLimits/maxDurationSeconds``), so there's no need for AVFoundation's
/// heavier playback engine just to confirm "yes, this is the sound you just dropped in".
///
/// A **class** holding the playing `NSSound` in a stored property, not a struct creating it
/// as a local: `NSSound.play()` starts playback asynchronously and returns immediately, and
/// `NSSound` **stops when it is deallocated**. A local sound would be released by ARC the
/// instant `play(fileAt:)` returned — cutting the preview (T8 acceptance criterion 8) off
/// before it was audible. Retaining it here (replaced on the next preview) keeps it alive
/// for the ≤ few-second chime; the owning `PanelView` holds this player for its own
/// lifetime, so the reference chain lasts as long as the panel is on screen
/// (swift-reviewer T8 finding: NSSound not retained for playback duration).
final class NSSoundAudioPreviewPlayer: AudioPreviewPlaying {
    private var currentSound: NSSound?

    func play(fileAt url: URL, volume: Float) {
        let sound = NSSound(contentsOf: url, byReference: true)
        sound?.volume = volume
        currentSound = sound
        sound?.play()
    }
}
