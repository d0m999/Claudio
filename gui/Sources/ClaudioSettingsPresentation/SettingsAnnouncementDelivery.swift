import Foundation

/// Coordinates one native announcement attempt without owning the platform effect itself.
/// The caller keeps the semantic debt unless its native adapter reports success.
package enum SettingsAnnouncementDelivery {
    @MainActor
    @discardableResult
    package static func attempt(
        _ announcement: SettingsPresentationAnnouncement,
        post: @MainActor () -> Bool,
        acknowledgeSuccess: @MainActor (UInt64) -> Void
    ) -> Bool {
        guard post() else { return false }
        acknowledgeSuccess(announcement.id)
        return true
    }
}
