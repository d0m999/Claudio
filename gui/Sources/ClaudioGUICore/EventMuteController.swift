import ClaudioCore
import Combine
import Foundation

/// Drives the per-event mute write-back the operational panel's rows call into
/// (ENGINEERING.md 决议③, T15 D4): a thin `@MainActor` wrapper around
/// ``setEventEnabled(_:enabled:configFile:lockFile:)`` (`ClaudioCore`) — this type owns no
/// state beyond the injectable write-target paths and never re-derives the read-modify-write
/// itself (that logic, and its concurrency stance, live entirely in `ClaudioCore`, mirroring
/// `selectPack`'s own flock discipline). Mirrors `OnboardingViewModel`/`AudioImportViewModel`'s
/// shape: an injectable environment, a `@Published private(set)` outcome, no logic beyond
/// delegating to the free function.
@MainActor
public final class EventMuteController: ObservableObject {
    public var configFile: URL
    public var lockFile: URL

    /// The most recent ``setEventEnabled(_:enabled:configFile:lockFile:)`` failure, if any —
    /// `nil` before any call, and reset to `nil` on the next successful call. A future panel
    /// surface for this (a toast, an inline error) is out of T15's scope (compile-only/manual
    /// concern); this seam only tracks the outcome so one exists to wire up.
    @Published public private(set) var lastError: SetEventEnabledError?

    public init(
        configFile: URL = ClaudioPaths.configFile,
        lockFile: URL = ClaudioPaths.configLockFile
    ) {
        self.configFile = configFile
        self.lockFile = lockFile
    }

    /// Toggles `event`'s mute flag to `enabled`. Returns `true` on success (and clears
    /// ``lastError``); returns `false` on failure (and records it) — `config.json` is left
    /// byte-for-byte untouched on any failure path, since
    /// ``setEventEnabled(_:enabled:configFile:lockFile:)`` never partially writes.
    @discardableResult
    public func setEnabled(_ event: Event, enabled: Bool) -> Bool {
        switch setEventEnabled(event, enabled: enabled, configFile: configFile, lockFile: lockFile) {
        case .success:
            lastError = nil
            return true
        case .failure(let error):
            lastError = error
            return false
        }
    }
}
