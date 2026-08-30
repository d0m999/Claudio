import AppKit
import ClaudioGUICore
import ClaudioLocalization

/// The retained Settings Sounds destination's single AppKit announcement exit.
///
/// This bridge intentionally lives in `SoundPacksWindow`, not the menu-bar panel target. Opening
/// Settings first closes the transient panel, so the surfaces do not compete for a live
/// announcement. Callers must supply the retained Settings window while it is actually key.
@MainActor
public enum SoundPacksWindowAccessibilityBridge {
    public static func post(
        _ moment: SoundPacksWindowAnnouncementMoment,
        facts: SoundPacksWindowAnnouncementFacts,
        language: ClaudioAppLanguage,
        window: NSWindow,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        let priority: NSAccessibilityPriorityLevel
        if case .writeFailed = moment {
            priority = .high
        } else {
            priority = .medium
        }

        let announcement = soundPacksWindowAnnouncement(
            moment,
            facts: facts,
            language: language)
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
