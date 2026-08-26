import AppKit
import ClaudioGUICore
import ClaudioLocalization

/// The retained sound-pack presentations' single AppKit announcement exit.
///
/// This bridge intentionally lives in `SoundPacksWindow`, not the menu-bar panel target. Opening
/// either Settings or the legacy window first closes the transient panel, so those surfaces do not
/// compete for a live announcement. Callers must supply the presentation that is actually key.
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
