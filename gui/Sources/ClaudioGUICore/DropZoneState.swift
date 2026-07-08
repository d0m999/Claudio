import Foundation

/// The drop-zone's UI state (ENGINEERING.md T8 · "拖入导入" 交互状态覆盖表 + DoD "拖入
/// idle/hover/reject×3/success"): idle (nothing happening) / hover (a drag is currently
/// over the zone) / reject (the last drop failed, carrying its specific reason) /
/// success (the last drop copied a file into the user pack).
///
/// A **pure value type** — the SwiftUI view renders off of it, but every state
/// *decision* lives in ``importAudioFile(sourceURL:suggestedFileName:packID:environment:)``
/// / ``AudioImportViewModel``, asserted by fixture tests, per the DoD requirement "状态
/// 正确性下沉 view-model / state fixture 测，非像素快照".
public enum DropZoneState: Sendable, Equatable {
    case idle
    case hover
    case reject(DropRejectionReason)
    case success(ImportedAudioFile)
}

/// Why a drop was refused. The first five cases are T8's five named hardening checks
/// (ENGINEERING.md T8 acceptance: "oversize / nonWhitelistFormat / pathTraversal /
/// overDuration / overwritesBuiltin each trigger the correct human refusal"); ``copyFailed``
/// is a defensive sixth case covering everything outside those five: a genuine,
/// unexpected I/O failure discovered *after* every one of those five already passed
/// (disk full, permission revoked mid-flight, the source vanishing between validation
/// and copy), **and** a source file that is itself a symlink — refused up front, before
/// any of the five even run, because trusting a symlink's own metadata `.size` (its
/// target path string's length, not the real target's size) would silently bypass the
/// size cap for an arbitrarily large target (`AudioImport.swift`'s `importAudioFile`,
/// step 3). Kept distinct rather than folded into one of the five, which would misreport
/// the real cause (project rule: never silently swallow an error).
public enum DropRejectionReason: Sendable, Equatable {
    /// The source file's size, in bytes, exceeded ``AudioImportLimits/maxFileSizeBytes``.
    case oversize(actualBytes: Int, maxBytes: Int)
    /// The source file's *content* (magic bytes/container structure) didn't match any of
    /// the wav/mp3/aiff/m4a whitelist — regardless of its file extension.
    case nonWhitelistFormat
    /// The destination filename derived from the drop failed ``safePackFileURL(_:in:)``'s
    /// containment check (empty / absolute / `..`-escaping / NUL-bearing / a symlink
    /// resolving outside the pack directory).
    case pathTraversal
    /// The source file's probed duration, in seconds, exceeded
    /// ``AudioImportLimits/maxDurationSeconds`` — or couldn't be determined at all
    /// (`actualSeconds == nil`), which is treated as failing the cap too, fail-closed
    /// (see ``AudioDurationProbing``'s doc comment).
    case overDuration(actualSeconds: TimeInterval?, maxSeconds: TimeInterval)
    /// `packID` currently resolves to a pack directory **only** via the bundled
    /// (built-in) root — see `importAudioFile`'s doc comment for the exact semantics
    /// this repo settled on for reconciling this with ENGINEERING.md §157-158.
    case overwritesBuiltin(packID: String)
    /// A real I/O failure after every validation check already passed.
    case copyFailed(reason: String)
}

extension DropRejectionReason {
    /// A single, human, Chinese sentence — never engineering phrasing (project rule:
    /// user-facing copy must read as "一句人话"). Mirrors `OnboardingCopy`'s reassurance
    /// tone: state the problem plainly, then say what to do next.
    public var message: String {
        switch self {
        case .oversize(let actualBytes, let maxBytes):
            let actualMB = Double(actualBytes) / 1_048_576
            let maxMB = Double(maxBytes) / 1_048_576
            return String(
                format: "这个文件有点大（约 %.1fMB），Claudio 目前只收 %.0fMB 以内的声音，换个小一点的文件试试。",
                actualMB, maxMB)

        case .nonWhitelistFormat:
            return "这个文件看着不是 wav / mp3 / aiff / m4a 里的任何一种，Claudio 认不出来，换个格式再试试。"

        case .pathTraversal:
            return "这个文件名 Claudio 不敢直接用，换个正常一点的名字再拖一次。"

        case .overDuration(let actualSeconds, let maxSeconds):
            guard let actualSeconds, actualSeconds.isFinite else {
                return "这段声音的时长读不出来，Claudio 没法确认是否够短，换一个文件再试试。"
            }
            return String(
                format: "这段声音有点长（约 %.1f 秒），Claudio 的提示音建议控制在 %.1f 秒以内，剪短一点再试试。",
                actualSeconds, maxSeconds)

        case .overwritesBuiltin(let packID):
            return "「\(packID)」是内置声音包，Claudio 不会用拖进来的文件悄悄顶替它——先建一份属于你自己的包，再拖进来。"

        case .copyFailed(let reason):
            return "这个文件没能存进去（\(reason)），要不再试一次？"
        }
    }
}
