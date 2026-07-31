import AppKit
import ClaudioGUICore

/// The standard window's single AppKit announcement exit.
///
/// This bridge intentionally lives in `SoundPacksWindow`, not the menu-bar panel target. Opening
/// the window first closes the transient panel, so the two surfaces do not compete for a live
/// announcement.
@MainActor
enum SoundPacksWindowAccessibilityBridge {
    static func post(
        _ moment: SoundPacksWindowAnnouncementMoment,
        facts: SoundPacksWindowAnnouncementFacts,
        window: NSWindow,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        let priority: NSAccessibilityPriorityLevel
        if case .writeFailed = moment {
            priority = .high
        } else {
            priority = .medium
        }

        let announcement = soundPacksWindowAnnouncement(moment, facts: facts)
        let priorityValue = priority.rawValue
        DispatchQueue.main.async { [weak window] in
            MainActor.assumeIsolated {
                guard let window, window.isKeyWindow else {
                    completion?(false)
                    return
                }
                NSAccessibility.post(
                    element: window,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: announcement,
                        .priority: priorityValue,
                    ])
                completion?(true)
            }
        }
    }
}
