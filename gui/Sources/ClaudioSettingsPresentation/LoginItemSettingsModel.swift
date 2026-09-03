import ClaudioGUICore
import Combine

/// Pure presentation owner for ServiceManagement facts supplied by the executable adapter.
/// Registration remains a system fact: failed requests preserve the last observed value and retry
/// repeats the exact failed intent rather than optimistically changing the toggle.
@MainActor
package final class LoginItemSettingsModel: ObservableObject {
    @Published
    package private(set) var projection: LoginItemSettingsProjection

    private let adapter: LoginItemServiceAdapter

    package init(adapter: LoginItemServiceAdapter) {
        self.adapter = adapter
        projection = makeLoginItemSettingsProjection(registration: adapter.status())
    }

    package func refresh() {
        projection = makeLoginItemSettingsProjection(registration: adapter.status())
    }

    package func setEnabled(_ enabled: Bool) {
        projection = projectLoginItemRequest(enabled, from: projection, using: adapter)
    }

    package func retryFailedOperation() {
        guard let failure = projection.failure else { return }
        projection = projectLoginItemRequest(
            failure.requestedEnabled,
            from: makeLoginItemSettingsProjection(registration: projection.registration),
            using: adapter)
    }
}
