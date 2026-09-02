import ClaudioCore
import Foundation

/// The editor's only observable value. Every member is immutable and render-ready; mutable
/// implementation state, raw configuration and shared-library snapshots stay behind the owner.
package struct SoundPacksEditorPresentation: Equatable {
    package let revision: UInt64
    package let library: SoundPackLibraryPresentation
    package let mode: SoundPacksEditorModePresentation
    package let activities: [SoundPackEditorActivityPresentation]
    package let pendingConfirmation: SoundPackEditorConfirmation?
    package let pendingAnnouncement: SoundPackEditorAnnouncement?
}

package enum SoundPackLibraryPresentation: Equatable, Sendable {
    case unloaded
    case loading(previousAvailable: Bool)
    case ready(snapshotRevision: UInt64?)
    case failed(previousAvailable: Bool)

    package var isFresh: Bool {
        if case .ready = self { return true }
        return false
    }
}

package enum SoundPacksEditorModePresentation: Equatable {
    case inactive
    case sounds(SoundsEditorPresentation)
    case events(EventsSoundPackPresentation)
}

package enum SoundPacksEditorRouteState: Equatable, Sendable {
    case pendingFreshSnapshot
    case resolved(SoundPacksWindowRoute)
    case staleTarget(packID: String)
}

package enum SoundPackEditorScopeAvailability: Equatable, Sendable {
    case available(PanelSoundScopeID)
    case unavailable(SoundPackEditorFailure)
}

package struct SoundsEditorPresentation: Equatable {
    package let route: SoundPacksWindowRoute
    package let requestRevision: UInt64
    package let routeState: SoundPacksEditorRouteState
    package let scope: SoundPackEditorScopeAvailability
    package let packs: [SoundPackEditorPackPresentation]
    package let selectedPack: SoundPackEditorPackPresentation?
    package let eventRows: [SoundPackEditorEventPresentation]
    package let inventory: SoundPackEditorInventoryPresentation
    package let requestImportAction: SoundPackEditorAction?
    package let stopPreviewAction: SoundPackEditorAction
    package let retryLibraryAction: SoundPackEditorAction?
    package let restoreAllFactoryPacksAction: SoundPackEditorAction?
    package let recoveryActions: [SoundPackEditorRecoveryPresentation]
}

package struct EventsSoundPackPresentation: Equatable {
    package let route: EventSettingsWindowRoute
    package let requestRevision: UInt64
    package let scope: SoundPackEditorScopeAvailability
    package let packs: [SoundPackEditorPackPresentation]
    package let selectedPack: SoundPackEditorPackPresentation?
    package let adoptionPermit: SoundPackAdoptionPermit?
    package let retryLibraryAction: SoundPackEditorAction?
}

package struct SoundPackEditorPackPresentation: Identifiable, Equatable {
    package let id: String
    package let name: String?
    package let state: PackCardState
    package let availability: PackCardAvailability
    package let isSelected: Bool
    package let isStarred: Bool
    package let isBuiltinReadOnly: Bool
    package let inspectAction: SoundPackEditorAction
    package let useAction: SoundPackEditorAction?
    package let toggleStarAction: SoundPackEditorAction?
    package let forkAction: SoundPackEditorAction?
    package let deleteAction: SoundPackEditorAction?
    package let restoreAction: SoundPackEditorAction?
    package let revealAction: SoundPackEditorAction?
}

package struct SoundPackEditorEventPresentation: Identifiable, Equatable {
    package var id: Event { event }
    package let event: Event
    package let coverage: CoverageState
    package let enabled: Bool
    package let audioDisplayName: String?
    package let importAction: SoundPackEditorAction?
    package let previewAction: SoundPackEditorAction?
    package let clearAction: SoundPackEditorAction?
}

package enum SoundPackEditorInventoryPresentation: Equatable, Sendable {
    case idle
    case loading(previous: [SoundPackEditorAudioPresentation]?)
    case ready([SoundPackEditorAudioPresentation])
    case failed(previous: [SoundPackEditorAudioPresentation]?)
}

package struct SoundPackEditorAudioPresentation: Identifiable, Equatable, Sendable {
    package var id: String { fileName }
    package let fileName: String
    package let isOrphan: Bool
    package let assignments: [SoundPackEditorAssignmentPresentation]
    package let deleteAction: SoundPackEditorAction?
    package let revealAction: SoundPackEditorAction?
}

package struct SoundPackEditorAssignmentPresentation: Identifiable, Equatable, Sendable {
    package var id: Event { event }
    package let event: Event
    package let action: SoundPackEditorAction
}

package struct SoundPackEditorRecoveryPresentation: Identifiable, Equatable, Sendable {
    package var id: String { packID }
    package let packID: String
    package let retryAction: SoundPackEditorAction
}

package struct SoundPackEditorAction: Hashable, Sendable {
    package struct ID: Hashable, Sendable {
        fileprivate let rawValue: UInt64

        init(rawValue: UInt64) {
            self.rawValue = rawValue
        }
    }

    package enum Kind: String, Hashable, Sendable {
        case inspect
        case use
        case toggleStar
        case fork
        case requestImport
        case assign
        case clear
        case preview
        case stopPreview
        case reveal
        case deletePack
        case deleteOrphan
        case restoreFactory
        case retryRestore
        case restoreAllFactory
        case retryLibrary
        case cancelOperation
        case confirm
        case cancelConfirmation
    }

    package let id: ID
    package let kind: Kind

    init(id: UInt64, kind: Kind) {
        self.id = ID(rawValue: id)
        self.kind = kind
    }
}

package struct SoundPackImportPermit: Hashable, Sendable {
    package struct ID: Hashable, Sendable {
        fileprivate let rawValue: UInt64

        init(rawValue: UInt64) {
            self.rawValue = rawValue
        }
    }

    package let id: ID

    init(id: UInt64) {
        self.id = ID(rawValue: id)
    }
}

package struct SoundPackAdoptionPermit: Hashable, Sendable {
    package struct ID: Hashable, Sendable {
        fileprivate let rawValue: UInt64

        init(rawValue: UInt64) {
            self.rawValue = rawValue
        }
    }

    package let id: ID

    init(id: UInt64) {
        self.id = ID(rawValue: id)
    }
}

package struct SoundPackEditorOperationID: Hashable, Sendable {
    fileprivate let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

package enum SoundPackEditorActivityKind: String, Equatable, Sendable {
    case use
    case toggleStar
    case fork
    case importAudio
    case assign
    case clear
    case deletePack
    case deleteOrphan
    case restoreFactory
    case restoreAllFactory
    case adoptAICue
}

package enum SoundPackEditorActivityPhase: Equatable, Sendable {
    case busy
    case succeeded
    case failed(SoundPackEditorFailure)
    case partial(accepted: Int, rejected: Int)
    case orphan(fileName: String, failure: SoundPackEditorFailure)
    case cancelled(changedOnDisk: Bool)
}

package struct SoundPackEditorActivityPresentation: Identifiable, Equatable {
    package var id: SoundPackEditorOperationID { operationID }
    package let operationID: SoundPackEditorOperationID
    package let kind: SoundPackEditorActivityKind
    package let phase: SoundPackEditorActivityPhase
    package let packID: String?
    package let event: Event?
    package let cancelAction: SoundPackEditorAction?
}

package struct SoundPackEditorConfirmation: Identifiable, Equatable {
    package struct ID: Hashable, Sendable {
        fileprivate let rawValue: UInt64

        init(rawValue: UInt64) {
            self.rawValue = rawValue
        }
    }

    package enum Kind: String, Equatable, Sendable {
        case deletePack
        case deleteOrphan
        case restoreFactory
        case retryRestore
        case restoreAllFactory
    }

    package let id: ID
    package let kind: Kind
    package let packID: String?
    package let fileName: String?
    package let confirmAction: SoundPackEditorAction
    package let cancelAction: SoundPackEditorAction
}

package enum SoundPackEditorAnnouncementKind: Equatable, Sendable {
    case windowStatus(SoundPacksWindowStatusKind)
    case operationSucceeded(SoundPackEditorActivityKind)
}

package struct SoundPackEditorAnnouncement: Identifiable, Equatable {
    package struct ID: Hashable, Sendable {
        fileprivate let rawValue: UInt64

        init(rawValue: UInt64) {
            self.rawValue = rawValue
        }
    }

    package let id: ID
    package let kind: SoundPackEditorAnnouncementKind
    package let actionText: SoundPacksWindowStatusText?
    package let messageText: SoundPacksWindowStatusText?
}

package enum SoundPacksEditorContext: Equatable, Sendable {
    case inactive
    case sounds(route: SoundPacksWindowRoute, requestRevision: UInt64)
    case events(
        route: EventSettingsWindowRoute,
        requestRevision: UInt64,
        candidateGenerationID: UUID? = nil)
}

package enum SoundPacksEditorCommand: Equatable, Sendable {
    case activate(SoundPacksEditorContext)
    case invoke(SoundPackEditorAction)
    case completePanelPackSwitch(PanelPackSwitchOutcome)
    case acknowledgeAnnouncement(id: SoundPackEditorAnnouncement.ID, didPost: Bool)
}

package enum SoundPacksEditorCommandResult: Equatable, Sendable {
    case unchanged
    case applied
    case accepted(SoundPackEditorOperationID)
    case confirmation(SoundPackEditorConfirmation)
    case nativeEffect(SoundPackEditorNativeEffect)
    case rejected(SoundPackEditorFailure)
}

package enum SoundPackEditorNativeEffect: Equatable, Sendable {
    case selectAudioFiles(permit: SoundPackImportPermit, bindTo: Event?)
    case playAudio(fileURL: URL, volume: Double)
    case stopAudio
    case reveal(fileURL: URL)
}

package enum SoundPacksEditorOperation: Equatable, Sendable {
    case importAudio(permit: SoundPackImportPermit, sources: [URL], bindTo: Event?)
    case adoptAICue(
        candidate: AICueCandidate,
        displayName: AICueDisplayName,
        permit: SoundPackAdoptionPermit)
}

package enum SoundPacksEditorOperationResult: Equatable, Sendable {
    case imported(SoundPackEditorImportOutcome)
    case adopted(AICueAdoptionOutcome)
    case adoptionOrphan(imported: ImportedAudioFile, failure: SoundPackEditorFailure)
    case rejected(SoundPackEditorFailure)
}

package struct SoundPackEditorImportOutcome: Equatable, Sendable {
    package let accepted: [ImportedAudioFile]
    package let rejected: [RejectedAudioFile]
    package let boundEvent: Event?
    package let completedInBackground: Bool
    package let orphan: ImportedAudioFile?
}

package enum SoundPackEditorFailure: Error, Equatable, Sendable {
    case staleAction
    case staleConfirmation
    case stalePermit
    case invalidScope
    case scopeUnavailable
    case packUnavailable
    case builtinReadOnly
    case actionUnavailable
    case invalidImport
    case importRejected
    case targetChanged
    case mutationFailed
    case unsafeTarget
    case cancelled
}

/// One settled implementation snapshot. This is deliberately `internal`: the owner consumes it
/// synchronously to build the package presentation, while callers can observe only that final
/// immutable value.
struct SoundPacksEditorModelSeed {
    let library: SoundPackLibraryPresentation
    let installedPackIDs: Set<String>
    let snapshotRevision: UInt64?
    let selectionGeneration: UInt64
    let managedSurface: HostSurfaceID?
    let writesAllowed: Bool
    let config: ClaudioConfig
    let packCards: [PackCard]
    let selectedPackID: String?
    let selectedEventRows: [EventRow]
    let selectedAudioInventoryState: SoundPackAudioInventoryPresentationState
    let starredPackIDs: [String]
    let builtinPackIDs: Set<String>
    let factoryRestoreRetryPackIDs: [String]
    let windowStatuses: [SoundPacksWindowStatus]
}
