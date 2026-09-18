import ClaudioCore
import ClaudioLocalization
import Foundation

/// A presentation category, separate from the typed failure identity and its diagnostic detail.
public enum PanelErrorCopyCategory: Sendable, Equatable {
    case configMalformed
    case configUnwritable
    case configMissing
    case configReadFailure
    case configWriteFailure
    case configPublishedButFailed
    case configPublishedPathChanged
    case lockBusy
    case lockFailed
    case surfaceLockBusy
    case surfaceLockFailed
    case invalidPackID
    case packNotFound
    case manifestUnreadable
    case surfaceOverrideMalformed

    public var key: ClaudioL10nKey {
        switch self {
        case .configMalformed: .panelErrorConfigMalformed
        case .configUnwritable: .panelErrorConfigUnwritable
        case .configMissing: .panelErrorConfigMissing
        case .configReadFailure: .panelErrorConfigRead
        case .configWriteFailure: .panelErrorConfigWrite
        case .configPublishedButFailed: .panelErrorConfigPublished
        case .configPublishedPathChanged: .panelErrorConfigPublishedPathChanged
        case .lockBusy: .panelErrorLockBusy
        case .lockFailed: .panelErrorLockFailed
        case .surfaceLockBusy: .panelErrorSurfaceLockBusy
        case .surfaceLockFailed: .panelErrorSurfaceLockFailed
        case .invalidPackID: .panelErrorInvalidPackID
        case .packNotFound: .panelErrorPackNotFound
        case .manifestUnreadable: .panelErrorManifestUnreadable
        case .surfaceOverrideMalformed: .panelErrorSurfaceOverrideMalformed
        }
    }

    /// The existing Finder action helps only when the configuration location needs repair.
    public var offersConfigRecovery: Bool {
        switch self {
        case .configMalformed, .configUnwritable, .configReadFailure, .configWriteFailure,
            .configPublishedButFailed, .lockFailed, .surfaceLockFailed,
            .surfaceOverrideMalformed:
            true
        case .configMissing, .configPublishedPathChanged, .lockBusy, .surfaceLockBusy,
            .invalidPackID, .packNotFound, .manifestUnreadable:
            false
        }
    }
}

extension PanelConfigState {
    public var errorCopyCategory: PanelErrorCopyCategory? {
        switch self {
        case .malformed: .configMalformed
        case .unwritable: .configUnwritable
        case .operational, .needsPack: nil
        }
    }
}

extension PanelWriteFailureReason {
    public var copyCategory: PanelErrorCopyCategory {
        switch self {
        case .configReadFailure: .configReadFailure
        case .configWriteFailure: .configWriteFailure
        // A missing recovery path means the published file's original path changed. The
        // pinned directory may have moved, or the file entry may have been replaced.
        case .configPublishedButFailed(_, let recoveryPath):
            recoveryPath == nil ? .configPublishedPathChanged : .configPublishedButFailed
        case .lockBusy: .lockBusy
        case .lockFailed: .lockFailed
        case .invalidPackID: .invalidPackID
        case .packNotFound: .packNotFound
        case .manifestUnreadable: .manifestUnreadable
        }
    }
}

extension SurfaceSoundMutationError {
    public var panelCopyCategory: PanelErrorCopyCategory {
        switch self {
        case .invalidPackID: .invalidPackID
        case .packNotFound: .packNotFound
        case .manifestUnreadable: .manifestUnreadable
        case .configReadFailure: .configReadFailure
        case .configWriteFailure: .configWriteFailure
        // Surface writes use the same post-publication recovery-path contract.
        case .configPublishedButFailed(_, let recoveryPath):
            recoveryPath == nil ? .configPublishedPathChanged : .configPublishedButFailed
        case .configMissing: .configMissing
        case .lockBusy: .surfaceLockBusy
        case .lockFailed: .surfaceLockFailed
        }
    }

    public var panelRecoveryFile: URL? {
        if case .configPublishedButFailed(_, let recoveryPath) = self,
            let recoveryPath
        {
            return URL(fileURLWithPath: recoveryPath)
        }
        return nil
    }
}

extension PanelWriteFailureSource {
    public var key: ClaudioL10nKey {
        switch self {
        case .mute: .panelWriteFailureMute
        case .packSwitch: .panelWriteFailurePackSwitch
        case .masterVolume: .panelWriteFailureMasterVolume
        }
    }
}

public struct PanelWriteFailureRow: Sendable, Identifiable {
    public let reason: PanelWriteFailureReason
    public let message: String

    public var id: PanelWriteFailureReason { reason }
}

/// Preserve each typed failure; name the attempted action when two rows share visible copy.
public func panelWriteFailureRows(
    items: [PanelWriteFailure], l10n: ClaudioL10n
) -> [PanelWriteFailureRow] {
    let copy = items.map { l10n.text($0.reason.copyCategory.key) }
    var counts: [String: Int] = [:]
    for message in copy { counts[message, default: 0] += 1 }
    return zip(items, copy).map { item, message in
        let visibleMessage =
            counts[message, default: 0] > 1
            ? l10n.format(
                .panelWriteFailureWithSource,
                arguments: [l10n.text(item.source.key), message])
            : message
        return PanelWriteFailureRow(reason: item.reason, message: visibleMessage)
    }
}
