import ClaudioCore
import ClaudioGUICore
import Foundation

/// A fresh identity for each native confirmation, even when the same rule is requested again.
package struct WorkspaceDeletionRequest: Equatable, Identifiable {
    package let id: UUID
    package let target: WorkspaceSoundDeleteTarget

    package init(target: WorkspaceSoundDeleteTarget) {
        id = UUID()
        self.target = target
    }
}

package enum WorkspaceDeleteReadback: Equatable {
    case originalPresent
    case absent
    case replaced
    case unavailable

    package init(target: WorkspaceSoundDeleteTarget, configState: PanelConfigState) {
        guard case .operational(let config) = configState, !config.workspaceRulesMalformed else {
            self = .unavailable
            return
        }
        guard let current = config.workspaceRules.first(where: { $0.id == target.id }) else {
            self = .absent
            return
        }
        self = current.directory == target.directory ? .originalPresent : .replaced
    }
}

package enum WorkspaceDeleteFeedback: Equatable {
    case succeeded(WorkspaceSoundDeleteTarget)
    case failed(WorkspaceSoundDeleteTarget, WorkspaceSoundError, WorkspaceDeleteReadback?)
}

package struct WorkspaceDeletionPresentation: Equatable {
    package var pending: WorkspaceDeletionRequest?
    package var feedback: WorkspaceDeleteFeedback?
}
