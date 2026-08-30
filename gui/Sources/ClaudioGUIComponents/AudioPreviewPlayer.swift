import AppKit
import ClaudioGUICore
import Foundation

/// Retains the active `NSSound`; a local value would deallocate immediately and cut playback off.
@MainActor
public final class NSSoundAudioPreviewPlayer: AudioPreviewPlaying {
    private var currentSound: NSSound?

    public init() {}

    @discardableResult
    public func play(fileAt url: URL, volume: Float) -> Bool {
        currentSound?.stop()
        currentSound = nil
        guard let sound = NSSound(contentsOf: url, byReference: true) else { return false }
        sound.volume = volume
        currentSound = sound
        guard sound.play() else {
            currentSound = nil
            return false
        }
        return true
    }

    public func stop() {
        currentSound?.stop()
        currentSound = nil
    }
}
