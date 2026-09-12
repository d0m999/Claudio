import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

/// Single owner of the capsule/list text projection. Visible text and accessibility text are
/// generated here together so they can never drift into two hand-made copies, and so the
/// session label is localized at presentation time instead of arriving pre-rendered over IPC.
public enum EventNoticeProjection {
    public static func primaryLine(
        for record: EventNoticeRecord,
        language: ClaudioAppLanguage
    ) -> String {
        let l10n = ClaudioL10n(language: language)
        let host = record.notice?.host?.displayName ?? l10n.text(.eventNoticeUnknownSource)
        let event: String
        if record.isExpired { return l10n.text(.eventNoticeExpired) }
        switch record.kind {
        case .permission: event = l10n.text(.eventNoticePermission)
        case .needsInput: event = l10n.text(.eventNoticeNeedsInput)
        case .review: event = l10n.text(.eventNoticeReview)
        case .transient:
            event =
                record.event == .notification
                ? l10n.text(.eventNoticeInformational)
                : localizedEventName(record.event, language: language)
        case .interrupted: event = localizedEventName(record.event, language: language)
        }
        return "\(host) · \(event)"
    }

    public static func secondaryLine(
        for record: EventNoticeRecord,
        language: ClaudioAppLanguage
    ) -> String {
        let l10n = ClaudioL10n(language: language)
        guard let source = record.source else { return "" }
        var components: [String] = []
        if let project = source.projectLabel { components.append(project) }
        if let session = sessionLabel(for: source, language: language) {
            components.append(session)
            if source.isParentSession { components.append(l10n.text(.eventNoticeParentSession)) }
        }
        return components.joined(separator: " · ")
    }

    /// An adapter-supplied trusted label wins; otherwise the default short label is projected
    /// and localized here from the stable session ID prefix.
    public static func sessionLabel(
        for source: HostEventSource,
        language: ClaudioAppLanguage
    ) -> String? {
        if let explicit = source.sessionLabel { return explicit }
        guard let sessionID = source.sessionID else { return nil }
        return ClaudioL10n(language: language).format(
            .eventNoticeSessionShort, String(sessionID.prefix(8)))
    }

    public static func occurredAtText(
        for record: EventNoticeRecord,
        language: ClaudioAppLanguage
    ) -> String? {
        guard !record.isExpired, let occurredAt = record.occurredAt else { return nil }
        let locale = Locale(identifier: language.rawValue)
        return occurredAt.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }

    public static func accessibilitySummary(
        for record: EventNoticeRecord?,
        language: ClaudioAppLanguage
    ) -> String {
        let l10n = ClaudioL10n(language: language)
        guard let record else { return l10n.text(.eventNoticeUnknownSource) }
        return [
            primaryLine(for: record, language: language),
            secondaryLine(for: record, language: language),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: language == .english ? ", " : "，")
    }
}
