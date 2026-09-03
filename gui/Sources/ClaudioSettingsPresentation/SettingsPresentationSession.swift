import ClaudioGUICore
import ClaudioLocalization
import Combine

/// Presentation transaction owner for the unified Settings tree. It retains existing fact owners
/// without copying their write paths or taking over Settings route/window lifecycle; those mature
/// responsibilities remain in the executable until the later cutover.
@MainActor
package final class SettingsPresentationSession: ObservableObject {
    @Published
    package private(set) var state: SettingsPresentationState

    let dependencies: SettingsPresentationDependencies
    let actions: SettingsPresentationActions
    private var preferenceSnapshot: ClaudioPreferenceSnapshot
    private var loginProjection: LoginItemSettingsProjection
    private var platformActionFailure: SettingsPlatformActionFailure?
    private var pendingAnnouncement: SettingsPresentationAnnouncement?
    private var nextAnnouncementID: UInt64 = 0
    private var presentationRevision: UInt64 = 0
    private var isPublishingProjection = false
    private var projectionRepublishRequested = false
    private var preferenceCancellable: AnyCancellable?

    package init(
        dependencies: SettingsPresentationDependencies,
        actions: SettingsPresentationActions
    ) {
        self.dependencies = dependencies
        self.actions = actions
        preferenceSnapshot = dependencies.preferences.snapshot
        loginProjection = dependencies.loginItemSettings.projection
        state = Self.makeState(
            preferenceSnapshot: preferenceSnapshot,
            loginProjection: loginProjection,
            platformActionFailure: nil,
            pendingAnnouncement: nil,
            presentationRevision: 0)

        preferenceCancellable = dependencies.preferences.$snapshot
            .sink { [weak self] snapshot in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.preferenceSnapshot = snapshot
                    self.publishProjection()
                }
            }
    }

    package func setLanguageMode(_ languageMode: ClaudioLanguageMode) {
        dependencies.preferences.setLanguageMode(languageMode)
    }

    package func refreshLoginItem() {
        let previousProjection = loginProjection
        dependencies.loginItemSettings.refresh()
        loginProjection = dependencies.loginItemSettings.projection
        guard loginProjection != previousProjection else { return }
        guard loginProjection.registration != previousProjection.registration else {
            publishProjection()
            return
        }
        enqueueAnnouncement(.loginItemStatus(loginProjection.registration))
    }

    package func setLoginItemEnabled(_ enabled: Bool) {
        dependencies.loginItemSettings.setEnabled(enabled)
        loginProjection = dependencies.loginItemSettings.projection
        enqueueLoginItemResult()
    }

    package func retryLoginItemOperation() {
        dependencies.loginItemSettings.retryFailedOperation()
        loginProjection = dependencies.loginItemSettings.projection
        enqueueLoginItemResult()
    }

    @discardableResult
    package func perform(_ action: SettingsPlatformAction) -> SettingsPlatformActionResult {
        let result = actions.perform(action)
        platformActionFailure =
            result == .performed
            ? nil : SettingsPlatformActionFailure(action: action, result: result)
        if result != .performed {
            enqueueAnnouncement(.platformAction(action, result))
        } else {
            publishProjection()
        }
        return result
    }

    package func acknowledgeAnnouncement(
        id: UInt64,
        didPost: Bool
    ) {
        guard didPost, pendingAnnouncement?.id == id else { return }
        pendingAnnouncement = nil
        publishProjection()
    }

    private func enqueueLoginItemResult() {
        if let failure = loginProjection.failure {
            enqueueAnnouncement(.loginItemFailure(failure))
        } else {
            enqueueAnnouncement(.loginItemStatus(loginProjection.registration))
        }
    }

    private func enqueueAnnouncement(_ meaning: SettingsPresentationAnnouncement.Meaning) {
        nextAnnouncementID &+= 1
        pendingAnnouncement = SettingsPresentationAnnouncement(
            id: nextAnnouncementID,
            meaning: meaning)
        publishProjection()
    }

    private func publishProjection() {
        guard !isPublishingProjection else {
            projectionRepublishRequested = true
            return
        }
        isPublishingProjection = true
        defer { isPublishingProjection = false }

        repeat {
            projectionRepublishRequested = false
            let candidate = Self.makeState(
                preferenceSnapshot: preferenceSnapshot,
                loginProjection: loginProjection,
                platformActionFailure: platformActionFailure,
                pendingAnnouncement: pendingAnnouncement,
                presentationRevision: presentationRevision)
            if candidate != state {
                presentationRevision &+= 1
                state = Self.makeState(
                    preferenceSnapshot: preferenceSnapshot,
                    loginProjection: loginProjection,
                    platformActionFailure: platformActionFailure,
                    pendingAnnouncement: pendingAnnouncement,
                    presentationRevision: presentationRevision)
            }
        } while projectionRepublishRequested
    }

    private static func makeState(
        preferenceSnapshot: ClaudioPreferenceSnapshot,
        loginProjection: LoginItemSettingsProjection,
        platformActionFailure: SettingsPlatformActionFailure?,
        pendingAnnouncement: SettingsPresentationAnnouncement?,
        presentationRevision: UInt64
    ) -> SettingsPresentationState {
        SettingsPresentationState(
            languageMode: preferenceSnapshot.languageMode,
            language: preferenceSnapshot.language,
            interfaceTextSize: preferenceSnapshot.interfaceTextSize,
            recoveryIssues: preferenceSnapshot.recoveryIssues,
            loginItemRegistration: loginProjection.registration,
            loginItemFailure: loginProjection.failure,
            platformActionFailure: platformActionFailure,
            pendingAnnouncement: pendingAnnouncement,
            presentationRevision: presentationRevision)
    }
}
