import ClaudioCore
import Foundation

/// An injectable, synchronous probe for an audio file's duration — the seam that keeps
/// `ClaudioGUICore` Foundation-only (ENGINEERING.md T8 acceptance criterion 4: "Duration
/// needs AVFoundation, which must NOT be imported into Foundation-only ClaudioGUICore").
/// The real, AVFoundation-backed conformance lives in the `ClaudioGUI` app layer and is
/// injected at call sites there; tests inject a stub returning a fixed value (see
/// `AudioImportSuite.swift`) — the same DI pattern this module already uses throughout
/// (`OnboardingEnvironment`, `DoctorEnvironment` in `helper`).
public protocol AudioDurationProbing: Sendable {
    /// The duration of the audio file at `fileURL`, in seconds, or `nil` if it could not
    /// be determined (corrupt/unreadable). ``importAudioFile(sourceURL:suggestedFileName:packID:environment:)``
    /// treats `nil` as failing the duration cap — fail-closed, rather than silently
    /// letting an unmeasurable file through the size/duration gate.
    func probeDuration(of fileURL: URL) -> TimeInterval?
}

/// Numeric caps enforced by ``importAudioFile(sourceURL:suggestedFileName:packID:environment:)``.
public struct AudioImportLimits: Sendable, Equatable {
    /// ENGINEERING.md 决议 "拖入自带音频": "大小上限（如 5MB）".
    public let maxFileSizeBytes: Int

    /// A provisional cap for a short UI chime. T9 (ENGINEERING.md, not yet landed) owns
    /// the final, objective sound-quality standard ("单音时长上限 ≤~2s" among loudness
    /// normalization / peak limiting / silence trimming). T8 needs *a* concrete number
    /// now to enforce a cap at all — this errs slightly generous (3s) rather than
    /// guessing T9's exact final value, and is trivially retunable in this one place once
    /// T9 lands, without a second call spread across the codebase.
    public let maxDurationSeconds: Double

    public init(
        maxFileSizeBytes: Int = 5 * 1024 * 1024,
        maxDurationSeconds: Double = 3.0
    ) {
        self.maxFileSizeBytes = maxFileSizeBytes
        self.maxDurationSeconds = maxDurationSeconds
    }
}

/// Everything ``importAudioFile(sourceURL:suggestedFileName:packID:environment:)`` needs,
/// injectable for tests so they never touch the real `~/.claudio/packs/` (mirrors
/// `helper`'s `DoctorEnvironment` / gui's `OnboardingEnvironment` pattern exactly — see
/// `OnboardingEnvironment`'s doc comment for why a `$HOME` override wouldn't even work on
/// Darwin; tests must pass concrete fixture `URL`s instead, exactly as every other suite
/// in this package's test harness does with `withTempDirectory`).
public struct AudioImportEnvironment: Sendable {
    /// `~/.claudio/packs/` — copy destinations are always confined under here, never the
    /// read-only bundled pack root (ENGINEERING.md T8 acceptance criterion 1: "Drag-in =
    /// COPY the file into the user pack... never reference the original path").
    public var userPacksDirectory: URL

    /// The read-only, app-bundled pack root, if any (`nil` when there is no bundled pack
    /// distribution to consider, e.g. most test fixtures). Only ever *read* — to decide
    /// ``DropRejectionReason/overwritesBuiltin(packID:)`` — never written to.
    public var bundledPacksDirectory: URL?

    public var durationProbe: any AudioDurationProbing

    public var limits: AudioImportLimits

    public init(
        userPacksDirectory: URL = ClaudioPaths.packsDirectory,
        bundledPacksDirectory: URL? = nil,
        durationProbe: any AudioDurationProbing,
        limits: AudioImportLimits = AudioImportLimits()
    ) {
        self.userPacksDirectory = userPacksDirectory
        self.bundledPacksDirectory = bundledPacksDirectory
        self.durationProbe = durationProbe
        self.limits = limits
    }
}
