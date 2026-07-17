import AppKit
import ClaudioGUICore

/// Top-level (not a member of any view — its one production caller, ``EventRowView``'s
/// own row-level drop target, is only ever touched from SwiftUI's own main-actor context
/// anyway) and explicitly `@MainActor`: the caller only ever calls this from inside its
/// own `Task { @MainActor in ... }`, so keeping both sides on the same actor avoids
/// "sending non-Sendable `NSItemProvider` across an isolation boundary" entirely, rather
/// than fighting it with an unsafe opt-out. The `loadObject` completion handler below
/// still genuinely runs off the main actor at runtime (an AppKit implementation detail)
/// — that's why it must not capture `provider` itself (see the comment inside), only the
/// `Sendable` string already read from it. Drops (rather than failing the whole batch
/// over) any single provider that couldn't hand back a URL at all — as opposed to
/// resolving fine but then failing *validation*, which is `importAudioFile`'s job, not
/// this extraction step's.
///
/// Module-internal (not `private`): kept as its own top-level extraction step rather than
/// inlined into ``EventRowView`` (T16), the same shape a second call site could reuse
/// without a near-identical copy of the same AppKit plumbing, should one appear again.
@MainActor
func loadDropRequest(from provider: NSItemProvider) async -> AudioImportRequest? {
    // Read the Sendable `String?` up front, synchronously, on whatever isolation this
    // function is already running under — the `loadObject` completion handler below runs
    // on an arbitrary (non-main-actor) queue and must not capture `provider` itself (a
    // non-Sendable `NSObject` subclass) to stay clean under strict concurrency checking.
    let suggestedNameFallback = provider.suggestedName
    return await withCheckedContinuation { continuation in
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else {
                continuation.resume(returning: nil)
                return
            }
            let suggestedFileName = suggestedNameFallback ?? url.lastPathComponent
            continuation.resume(
                returning: AudioImportRequest(sourceURL: url, suggestedFileName: suggestedFileName))
        }
    }
}
