import ClaudioCore
import Combine
import Foundation

/// Drives the master-volume slider's write-back (ENGINEERING.md「面板 UI 线框」`🔊 主音量 ●———————`,
/// PLAN-MASTER-VOLUME.md 阶段 C4): a thin `@MainActor` wrapper around
/// ``setMasterVolume(_:configFile:lockFile:)`` (`ClaudioCore`) — this type owns no state beyond the
/// injectable write-target paths and never re-derives the read-modify-write itself (that logic,
/// and its concurrency stance, live entirely in `ClaudioCore`). Mirrors ``EventMuteController``'s
/// shape exactly — the mute button and the volume slider are siblings, same file, same lock,
/// same missing-config policy (D23 定稿①), only the payload differs.
@MainActor
public final class MasterVolumeController: ObservableObject {
    public var configFile: URL
    public var lockFile: URL

    /// The most recent ``setMasterVolume(_:configFile:lockFile:)`` failure, if any — `nil` before
    /// any call, and reset to `nil` on the next successful call. This is the third input
    /// ``panelWriteFailures(muteError:packSwitchError:masterVolumeError:)`` expects (D39).
    @Published public private(set) var lastError: SetMasterVolumeError?

    public init(
        configFile: URL = ClaudioPaths.configFile,
        lockFile: URL = ClaudioPaths.configLockFile
    ) {
        self.configFile = configFile
        self.lockFile = lockFile
    }

    /// Writes `volume` to `config.json`'s `master_volume`. Returns the **landed** (clamped) value
    /// on success — not necessarily the one passed in — so the slider can snap to the truth
    /// without re-reading the file, and clears ``lastError``. Returns `nil` on failure (and
    /// records it) — `config.json` is left byte-for-byte untouched on any failure path, since
    /// ``setMasterVolume(_:configFile:lockFile:)`` never partially writes.
    @discardableResult
    public func setVolume(_ volume: Double) -> Double? {
        switch setMasterVolume(volume, configFile: configFile, lockFile: lockFile) {
        case .success(.updated(let landed)):
            lastError = nil
            return landed
        case .failure(let error):
            lastError = error
            return nil
        }
    }
}

/// The volume `AudioPreviewPlaying` should preview at, given the config currently on disk
/// (D29): forwards ``ClaudioConfig/masterVolume`` through ``AfplayVolume/clamped(_:)`` — the one
/// clamp this repo has, not a second one rederived here. This is the testable half of the
/// gallery's preview-volume plumbing. The shared AppKit player lives in `ClaudioGUIComponents`;
/// this Foundation-only target deliberately exposes only the volume projection and does not import
/// AppKit. View-side playback remains covered by wiring guards plus the real-machine walkthrough.
public func previewVolume(for config: ClaudioConfig) -> Double {
    AfplayVolume.clamped(config.masterVolume)
}
