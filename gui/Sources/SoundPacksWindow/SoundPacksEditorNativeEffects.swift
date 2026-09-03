import AppKit
import ClaudioGUIComponents
import ClaudioGUICore
import Combine
import Foundation
import UniformTypeIdentifiers

/// The native seam for semantic effects already validated by `SoundPacksEditorOwner`.
/// Implementations execute the supplied values verbatim; target derivation remains in the owner.
@MainActor
package protocol SoundPacksEditorNativeEffectsAdapter: AnyObject {
    func selectAudioFiles(allowsMultipleSelection: Bool) -> [URL]
    func playAudio(fileURL: URL, volume: Double)
    func stopAudio()
    func revealInFinder(fileURL: URL)
}

/// Native lifecycle signals whose reliability differs between retained AppKit windows and their
/// transient SwiftUI destinations.
package enum SoundPacksEditorNativeLifecycleEvent: Sendable {
    case settingsWindowWillClose
    case soundsViewDisappeared
}

/// Exhaustively translates the Foundation-only owner effect into one native side effect. Picker
/// selections become the only async domain operation the view needs to feed back to the owner.
@MainActor
package final class SoundPacksEditorNativeEffectsDispatcher: ObservableObject {
    private let adapter: any SoundPacksEditorNativeEffectsAdapter
    private var operationTasks: [UUID: Task<Void, Never>] = [:]

    package init(adapter: any SoundPacksEditorNativeEffectsAdapter) {
        self.adapter = adapter
    }

    package func dispatch(
        _ effect: SoundPackEditorNativeEffect
    ) -> SoundPacksEditorOperation? {
        switch effect {
        case .selectAudioFiles(let permit, let bindTo):
            let sources = adapter.selectAudioFiles(
                allowsMultipleSelection: bindTo == nil)
            return .importAudio(permit: permit, sources: sources, bindTo: bindTo)
        case .playAudio(let fileURL, let volume):
            adapter.playAudio(fileURL: fileURL, volume: volume)
            return nil
        case .stopAudio:
            adapter.stopAudio()
            return nil
        case .reveal(let fileURL):
            adapter.revealInFinder(fileURL: fileURL)
            return nil
        }
    }

    /// Consumes only the instantaneous native-effect branch. Async owner operations are retained
    /// here so SwiftUI callers never own mutation Tasks or duplicate busy state.
    package func consume(
        _ result: SoundPacksEditorCommandResult,
        owner: SoundPacksEditorOwner
    ) {
        guard case .nativeEffect(let effect) = result,
            let operation = dispatch(effect)
        else { return }
        perform(operation, owner: owner)
    }

    /// Stops preview through the owner's single-use capability before retiring the relevant
    /// editor context. A late Sounds disappearance must not retire an Events context that has
    /// already taken over the shared owner; closing the retained Settings window retires either.
    package func handleLifecycle(
        _ event: SoundPacksEditorNativeLifecycleEvent,
        owner: SoundPacksEditorOwner
    ) {
        switch event {
        case .soundsViewDisappeared:
            guard case .sounds(let sounds) = owner.presentation.mode else { return }
            consume(owner.send(.invoke(sounds.stopPreviewAction)), owner: owner)
            _ = owner.send(.activate(.inactive))
        case .settingsWindowWillClose:
            switch owner.presentation.mode {
            case .inactive:
                return
            case .sounds(let sounds):
                consume(owner.send(.invoke(sounds.stopPreviewAction)), owner: owner)
            case .events:
                break
            }
            _ = owner.send(.activate(.inactive))
        }
    }

    /// Captures the owner-signed Event permit before the item-provider suspension. A provider
    /// cancellation performs the empty operation exactly once, returning typed `cancelled`,
    /// consuming that permit, and re-signing only the replacement capability.
    package func consumeDrop(
        _ providers: [NSItemProvider],
        action: SoundPackEditorAction,
        owner: SoundPacksEditorOwner
    ) {
        guard case .importPermit(let permit, let bindTo) = owner.send(.prepareDrop(action))
        else { return }
        let provider = providers.first {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        let operationID = UUID()
        let task = Task { @MainActor in
            let source: URL?
            if let provider {
                source = await loadSoundPacksDropURL(from: provider)
            } else {
                source = nil
            }
            let result = await owner.perform(
                .importAudio(
                    permit: permit,
                    sources: source.map { [$0] } ?? [],
                    bindTo: bindTo))
            consumeFollowUp(from: result, owner: owner)
            self.operationTasks.removeValue(forKey: operationID)
        }
        operationTasks[operationID] = task
    }

    private func perform(
        _ operation: SoundPacksEditorOperation,
        owner: SoundPacksEditorOwner
    ) {
        let operationID = UUID()
        let task = Task { @MainActor in
            let result = await owner.perform(operation)
            consumeFollowUp(from: result, owner: owner)
            self.operationTasks.removeValue(forKey: operationID)
        }
        operationTasks[operationID] = task
    }

    private func consumeFollowUp(
        from result: SoundPacksEditorOperationResult,
        owner: SoundPacksEditorOwner
    ) {
        let action: SoundPackEditorAction?
        switch result {
        case .imported(let outcome):
            action = outcome.previewAction
        case .adopted(let outcome):
            action = outcome.previewAction
        case .adoptionOrphan, .rejected:
            action = nil
        }
        guard let action else { return }
        consume(owner.send(.invoke(action)), owner: owner)
    }

    #if DEBUG
    package func waitForOperationsToFinishForTesting() async {
        while !operationTasks.isEmpty {
            let tasks = Array(operationTasks.values)
            for task in tasks { await task.value }
        }
    }
    #endif
}

/// Production AppKit adapter. `NSSoundAudioPreviewPlayer` retains one active sound and stops it
/// before replacing it, while picker and Finder calls stay on the MainActor.
@MainActor
package final class SystemSoundPacksEditorNativeEffectsAdapter:
    SoundPacksEditorNativeEffectsAdapter
{
    private let previewPlayer: NSSoundAudioPreviewPlayer

    package init(previewPlayer: NSSoundAudioPreviewPlayer = NSSoundAudioPreviewPlayer()) {
        self.previewPlayer = previewPlayer
    }

    package func selectAudioFiles(allowsMultipleSelection: Bool) -> [URL] {
        runAudioOpenPanel(allowsMultipleSelection: allowsMultipleSelection)
    }

    package func playAudio(fileURL: URL, volume: Double) {
        previewPlayer.play(fileAt: fileURL, volume: Float(volume))
    }

    package func stopAudio() {
        previewPlayer.stop()
    }

    package func revealInFinder(fileURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}
