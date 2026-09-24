import ClaudioCore
import ClaudioLocalization
import Foundation

public func localizedWorkspaceError(_ error: WorkspaceSoundError, language: ClaudioAppLanguage)
    -> String
{
    let key: ClaudioL10nKey
    switch error {
    case .tooLarge: key = .workspaceTooLarge
    case .publishedConflict: key = .panelErrorConfigPublished
    case .invalidRule: key = .workspaceInvalidRule
    case .duplicateDirectory: key = .workspaceDuplicate
    case .staleRule: key = .workspaceUnavailable
    case .unsupportedSurface: key = .workspaceEvidencePending
    case .invalidPack: key = .workspacePackRepair
    case .configFailure: key = .workspaceSaveFailed
    case .lockBusy: key = .workspaceLockBusy
    }
    return ClaudioL10n(language: language).text(key)
}
