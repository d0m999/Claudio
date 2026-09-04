/// Closed vocabulary for Settings-only effects implemented by native executable adapters.
package enum SettingsPlatformAction: Equatable, Sendable {
    case openLoginItemsSettings
    case openCalendarPrivacySettings
}

package enum SettingsPlatformActionResult: Equatable, Sendable {
    case performed
    case unavailable
    case failed
}

/// Concrete dispatcher shared by production and recording tests. This is deliberately not a
/// service locator: callers must submit one exhaustive ``SettingsPlatformAction`` value.
@MainActor
package struct SettingsPresentationActions {
    private let handler: @MainActor (SettingsPlatformAction) -> SettingsPlatformActionResult
    private let onEventAudibilityInputsChanged: @MainActor () -> Void

    package init(
        handler: @escaping @MainActor (SettingsPlatformAction) -> SettingsPlatformActionResult,
        onEventAudibilityInputsChanged: @escaping @MainActor () -> Void
    ) {
        self.handler = handler
        self.onEventAudibilityInputsChanged = onEventAudibilityInputsChanged
    }

    package func perform(_ action: SettingsPlatformAction) -> SettingsPlatformActionResult {
        handler(action)
    }

    package func notifyEventAudibilityInputsChanged() {
        onEventAudibilityInputsChanged()
    }
}
