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
        case .configMissing, .lockBusy, .surfaceLockBusy, .invalidPackID, .packNotFound,
            .manifestUnreadable:
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
        case .configPublishedButFailed: .configPublishedButFailed
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
        case .configPublishedButFailed: .configPublishedButFailed
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
