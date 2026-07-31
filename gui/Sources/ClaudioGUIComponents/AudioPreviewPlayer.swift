import AppKit
import Foundation

/// Shared short-audio preview boundary for both GUI surfaces.
@MainActor
public protocol AudioPreviewPlaying: AnyObject {
    func play(fileAt url: URL, volume: Float)
}

/// Retains the active `NSSound`; a local value would deallocate immediately and cut playback off.
@MainActor
public final class NSSoundAudioPreviewPlayer: AudioPreviewPlaying {
    private var currentSound: NSSound?

    public init() {}

    public func play(fileAt url: URL, volume: Float) {
        let sound = NSSound(contentsOf: url, byReference: true)
        sound?.volume = volume
        currentSound = sound
        sound?.play()
    }
}
