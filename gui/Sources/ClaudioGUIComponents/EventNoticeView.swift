import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// Compact C-direction capsule. It renders the immutable notice projection supplied by
/// `EventNoticeModel`; no host adapter, transcript, or route lookup lives in this view.
@MainActor
public struct EventNoticeView: View {
    @ObservedObject private var model: EventNoticeModel
    @ObservedObject private var languageStore: ClaudioPreferences

    private let onViewSource: @MainActor (HostEventNotice) -> Void
    private let onOpenRecent: (@MainActor () -> Void)?
    private let onCopySessionID: @MainActor (String) -> Bool
    private let onClose: @MainActor () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var copiedRecordID: UUID?

    public init(
        model: EventNoticeModel,
        languageStore: ClaudioPreferences,
        onViewSource: @escaping @MainActor (HostEventNotice) -> Void = { _ in },
        onOpenRecent: (@MainActor () -> Void)? = nil,
        onCopySessionID: @escaping @MainActor (String) -> Bool = { _ in false },
        onClose: @escaping @MainActor () -> Void = {}
    ) {
        _model = ObservedObject(wrappedValue: model)
        _languageStore = ObservedObject(wrappedValue: languageStore)
        self.onViewSource = onViewSource
        self.onOpenRecent = onOpenRecent
        self.onCopySessionID = onCopySessionID
        self.onClose = onClose
    }

    public var body: some View {
        let snapshot = model.snapshot
        VStack(alignment: .leading, spacing: 8) {
            if let current = snapshot.current {
                currentNotice(current, snapshot: snapshot)
            }
        }
        .frame(width: 440, alignment: .topLeading)
        .padding(12)
        .frame(maxHeight: 180, alignment: .topLeading)
        .background(ClaudioTheme.panelGradient(colorScheme))
        .overlay(
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.panel)
                .strokeBorder(
                    ClaudioTheme.hairline(colorScheme),
                    lineWidth: ClaudioTheme.Metrics.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.panel))
        .onHover { model.setHovering($0) }
        .onExitCommand {
            if model.snapshot.isExpanded {
                model.closeRecent()
            } else {
                onClose()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            EventNoticeProjection.accessibilitySummary(
                for: snapshot.current, language: languageStore.language)
        )
        .accessibilityIdentifier("event-notice.capsule")
    }

    @ViewBuilder
    private func currentNotice(
        _ record: EventNoticeRecord,
        snapshot: EventNoticeModelSnapshot
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            ClaudioEventGlyph(event: record.event, size: 25)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(primaryLine(record))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(ClaudioTheme.text(colorScheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(secondaryLine(record))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if model.badgeCount > 0 || snapshot.isExpanded {
                Button {
                    if snapshot.isExpanded {
                        model.closeRecent()
                    } else if let onOpenRecent {
                        onOpenRecent()
                    } else {
                        model.openRecent()
                    }
                } label: {
                    Text(
                        model.badgeCount > 0
                            ? l10n.format(.eventNoticeOtherCount, Int64(model.badgeCount))
                            : l10n.text(.eventNoticeRecent)
                    )
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .frame(minWidth: 28, minHeight: 28)
                .accessibilityLabel(l10n.text(.eventNoticeRecent))
                .accessibilityHint(
                    l10n.text(
                        snapshot.isExpanded
                            ? .eventNoticeCollapseHint
                            : .eventNoticeExpandHint)
                )
                .accessibilityIdentifier("event-notice.recent")
            }
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(l10n.text(.commonClose))
            .accessibilityIdentifier("event-notice.close")
        }

        if snapshot.isExpanded {
            Divider().overlay(ClaudioTheme.hairline(colorScheme))
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 8) {
                    recentList(snapshot.recent)
                    detailActions(for: record, includeFullSessionID: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("event-notice.recent-list")
        } else {
            detailActions(for: record, includeFullSessionID: false)
        }
    }

    private func recentList(_ records: [EventNoticeRecord]) -> some View {
        let snapshot = model.snapshot
        return VStack(alignment: .leading, spacing: 4) {
            // Frozen while reading: new arrivals only move the badge until the user explicitly
            // asks for them, so focus never drifts across a changing list (SPEC S5/D6).
            if snapshot.pendingCount > 0 {
                Button {
                    model.refreshRecent()
                } label: {
                    Text(l10n.format(.eventNoticeNewNotices, Int64(snapshot.pendingCount)))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(minHeight: 28)
                .accessibilityIdentifier("event-notice.refresh-recent")
            }
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(records.prefix(50))) { record in
                    Button {
                        model.selectRecent(id: record.id)
                    } label: {
                        recentRow(record)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("event-notice.recent.\(record.id.uuidString)")
                }
            }
            Text(l10n.text(.eventNoticeRecentDisclaimer))
                .font(.system(size: 9, design: .rounded))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            if snapshot.droppedCount > 0 {
                Text(l10n.text(.eventNoticeRecentOverflow))
                    .font(.system(size: 9, design: .rounded))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    .accessibilityIdentifier("event-notice.recent-overflow")
            }
        }
    }

    private func recentRow(_ record: EventNoticeRecord) -> some View {
        HStack(spacing: 7) {
            Image(systemName: claudioEventGlyphName(record.event))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(ClaudioTheme.event(record.event, colorScheme))
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(primaryLine(record))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(secondaryLine(record))
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if record.id == model.snapshot.current?.id {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(ClaudioTheme.clay(colorScheme))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 6)
        .frame(minHeight: 30)
        .background(
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control)
                .fill(
                    record.id == model.snapshot.current?.id
                        ? ClaudioTheme.claySoft(colorScheme) : Color.clear))
    }

    @ViewBuilder
    private func detailActions(
        for record: EventNoticeRecord,
        includeFullSessionID: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if includeFullSessionID {
                if let occurredAtText = EventNoticeProjection.occurredAtText(
                    for: record, language: languageStore.language)
                {
                    Text(l10n.text(.eventNoticeOccurredAt))
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    Text(occurredAtText)
                        .font(.system(size: 10, design: .rounded))
                        .accessibilityIdentifier("event-notice.occurred-at")
                }
                if let sessionID = record.source?.sessionID {
                    Text(l10n.text(.eventNoticeSessionID))
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    Text(sessionID)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("event-notice.session-id")
                }
            }

            HStack(spacing: 7) {
                if let notice = record.notice,
                    sessionNavigationCapability(for: notice).canViewSource
                {
                    Button(l10n.text(.eventNoticeViewSource)) {
                        onViewSource(notice)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(minHeight: 28)
                    .accessibilityIdentifier("event-notice.view-source")

                    if let sessionID = notice.source?.sessionID {
                        Button(
                            copiedRecordID == record.id
                                ? l10n.text(.eventNoticeCopied)
                                : l10n.text(.eventNoticeCopySession)
                        ) {
                            if onCopySessionID(sessionID) { copiedRecordID = record.id }
                        }
                        .buttonStyle(.plain)
                        .frame(minWidth: 28, minHeight: 28)
                        .accessibilityIdentifier("event-notice.copy-session")
                    }
                } else if record.isExpired {
                    Text(l10n.text(.eventNoticeExpired))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                } else {
                    Text(l10n.text(.eventNoticeNavigationUnavailable))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func primaryLine(_ record: EventNoticeRecord) -> String {
        EventNoticeProjection.primaryLine(for: record, language: languageStore.language)
    }

    private func secondaryLine(_ record: EventNoticeRecord) -> String {
        EventNoticeProjection.secondaryLine(for: record, language: languageStore.language)
    }

    private var l10n: ClaudioL10n { ClaudioL10n(language: languageStore.language) }
}
