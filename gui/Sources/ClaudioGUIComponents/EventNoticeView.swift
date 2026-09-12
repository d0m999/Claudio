import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// Only the model projects source data and accepts versioned actions. Presentation state here
/// contains feedback identities, never another copy of a source or a reminder list.
@MainActor
public struct EventNoticeView: View {
    @ObservedObject private var model: EventNoticeModel
    @ObservedObject private var languageStore: ClaudioPreferences
    private let onViewSource: @MainActor (EventNoticeAction) -> Void
    private let onOpenRecent: (@MainActor () -> Void)?
    private let onCopySessionID: @MainActor (EventNoticeAction) -> Bool
    private let onClose: @MainActor () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var copyFeedback: EventNoticeAction?
    @State private var copySucceeded = false

    public init(
        model: EventNoticeModel,
        languageStore: ClaudioPreferences,
        onViewSource: @escaping @MainActor (EventNoticeAction) -> Void = { _ in },
        onOpenRecent: (@MainActor () -> Void)? = nil,
        onCopySessionID: @escaping @MainActor (EventNoticeAction) -> Bool = { _ in false },
        onClose: @escaping @MainActor () -> Void = {}
    ) {
        _model = ObservedObject(wrappedValue: model)
        _languageStore = ObservedObject(wrappedValue: languageStore)
        self.onViewSource = onViewSource
        self.onOpenRecent = onOpenRecent
        self.onCopySessionID = onCopySessionID
        self.onClose = onClose
    }

    public static func preferredHeight(for snapshot: EventNoticeModelSnapshot) -> CGFloat {
        if snapshot.isDetail { return 360 }
        if snapshot.isExpanded {
            return CGFloat(min(5, max(1, snapshot.recent.count))) * 54 + 92
                + (snapshot.needsRefresh ? 32 : 0) + (snapshot.droppedCount > 0 ? 28 : 0)
        }
        return 112
    }

    public var body: some View {
        let snapshot = model.snapshot
        VStack(alignment: .leading, spacing: 8) {
            if snapshot.isExpanded {
                header(snapshot)
                if snapshot.isDetail, let record = snapshot.current {
                    detail(record)
                } else {
                    list(snapshot)
                }
            } else if let record = snapshot.current {
                HStack(alignment: .top, spacing: 8) {
                    summary(record)
                    listButton
                    closeButton
                }
                if let action = record.action {
                    Button(l10n.text(.eventNoticeViewSource)) { onViewSource(action) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(minHeight: 28)
                        .disabled(!record.isActionable)
                        .accessibilityIdentifier("event-notice.view-source")
                }
            }
        }
        .padding(12)
        .frame(
            idealWidth: 440, maxWidth: .infinity,
            idealHeight: Self.preferredHeight(for: snapshot), maxHeight: .infinity,
            alignment: .topLeading
        )
        .background(ClaudioTheme.panelGradient(colorScheme))
        .overlay(
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.panel)
                .strokeBorder(
                    ClaudioTheme.hairline(colorScheme), lineWidth: ClaudioTheme.Metrics.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.panel))
        .onHover { model.setHovering($0) }
        .onExitCommand {
            if model.snapshot.isDetail { model.closeDetail() } else { onClose() }
        }
        // Observation keys contain only identity/validity, never a second source snapshot.
        .onChange(of: snapshot.current?.action) { action in
            if copyFeedback != action { copyFeedback = nil }
        }
        .onChange(of: snapshot.current?.isActionable) { actionable in
            if actionable != true { copyFeedback = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l10n.text(.eventNoticeRecent))
        .accessibilityIdentifier("event-notice.capsule")
    }

    private func header(_ snapshot: EventNoticeModelSnapshot) -> some View {
        HStack(spacing: 8) {
            if snapshot.isDetail {
                Button {
                    model.closeDetail()
                } label: {
                    Image(systemName: "chevron.left").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(l10n.text(.eventNoticeBack))
                .accessibilityIdentifier("event-notice.back")
            }
            Text(l10n.text(.eventNoticeRecent))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Spacer(minLength: 0)
            Text(String(model.badgeCount)).monospacedDigit()
                .font(.system(size: 11, weight: .medium, design: .rounded))
            closeButton
        }
    }

    private var listButton: some View {
        Button {
            if let onOpenRecent { onOpenRecent() } else { model.openRecent() }
        } label: {
            Text(l10n.text(.eventNoticeRecent) + " " + String(model.badgeCount))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .fixedSize()
                .frame(minWidth: 28, minHeight: 28)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityHint(l10n.text(.eventNoticeExpandHint))
        .accessibilityIdentifier("event-notice.recent")
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(l10n.text(.commonClose))
        .accessibilityIdentifier("event-notice.close")
    }

    private func list(_ snapshot: EventNoticeModelSnapshot) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 4) {
                if snapshot.needsRefresh {
                    Button(
                        snapshot.pendingCount > 0
                            ? l10n.format(.eventNoticeNewNotices, Int64(snapshot.pendingCount))
                            : l10n.text(.eventNoticeRefresh)
                    ) {
                        model.refreshRecent()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(minHeight: 28)
                    .accessibilityIdentifier("event-notice.refresh-recent")
                }
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        if snapshot.recent.isEmpty {
                            Text(l10n.text(.eventNoticeEmpty))
                                .font(.system(size: 12, design: .rounded))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                                .accessibilityIdentifier("event-notice.empty")
                        }
                        ForEach(snapshot.recent) { record in
                            HStack(spacing: 4) {
                                Button {
                                    if let action = record.action { onViewSource(action) }
                                } label: {
                                    summary(record).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .disabled(!record.isActionable)
                                .accessibilityIdentifier(
                                    "event-notice.recent.\(record.id.uuidString)")
                                if record.kind != .transient { removeButton(record) }
                            }
                            .frame(minHeight: 54)
                            .overlay(alignment: .bottom) { Divider() }
                        }
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: CGFloat(min(5, max(1, snapshot.recent.count))) * 54
                )
                .accessibilityIdentifier("event-notice.recent-list")
                Text(l10n.text(.eventNoticeRecentDisclaimer))
                    .font(.system(size: 10, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                if snapshot.droppedCount > 0 {
                    Text(l10n.text(.eventNoticeRecentOverflow))
                        .font(.system(size: 10, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("event-notice.recent-overflow")
                }
            }
        )
    }

    private func summary(_ record: EventNoticeRecord) -> some View {
        HStack(alignment: .center, spacing: 8) {
            ClaudioEventGlyph(event: record.event, size: 25).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(
                    EventNoticeProjection.primaryLine(for: record, language: languageStore.language)
                )
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(ClaudioTheme.text(colorScheme))
                .lineLimit(1)
                let secondary = EventNoticeProjection.secondaryLine(
                    for: record, language: languageStore.language)
                if !secondary.isEmpty {
                    Text(secondary).font(.system(size: 11, design: .rounded))
                        .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            EventNoticeProjection.accessibilitySummary(
                for: record, language: languageStore.language))
    }

    private func detail(_ record: EventNoticeRecord) -> AnyView {
        AnyView(
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(
                        EventNoticeProjection.primaryLine(
                            for: record, language: languageStore.language)
                    )
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    if record.isExpired {
                        Text(l10n.text(.eventNoticeExpired))
                    } else {
                        if let project = record.source?.projectLabel { Text(project) }
                        if record.source?.isParentSession == true {
                            Text(l10n.text(.eventNoticeParentSession))
                        }
                        if record.source?.completeness != .complete {
                            Text(l10n.text(.eventNoticeMissingSource))
                        }
                        if record.kind == .review { Text(l10n.text(.eventNoticeUnknownReason)) }
                        if let time = EventNoticeProjection.occurredAtText(
                            for: record, language: languageStore.language)
                        {
                            Text(l10n.text(.eventNoticeOccurredAt) + " · " + time)
                                .accessibilityIdentifier("event-notice.occurred-at")
                        }
                        if let sessionID = record.sessionID {
                            Text(l10n.text(.eventNoticeSessionID))
                            Text(sessionID).font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .accessibilityIdentifier("event-notice.session-id")
                        }
                        if !record.isActionable { Text(l10n.text(.eventNoticeStale)) }
                        if let action = record.action, record.sessionID != nil {
                            Button(l10n.text(.eventNoticeCopySession)) {
                                copySucceeded = onCopySessionID(action)
                                copyFeedback = action
                            }
                            .buttonStyle(.bordered)
                            .frame(minHeight: 28)
                            .disabled(!record.isActionable)
                            .accessibilityIdentifier("event-notice.copy-session")
                        }
                        if record.isActionable, copyFeedback == record.action, copyFeedback != nil {
                            Text(
                                l10n.text(
                                    copySucceeded ? .eventNoticeCopied : .eventNoticeCopyFailed)
                            )
                            .accessibilityIdentifier("event-notice.copy-result")
                        }
                        if record.kind != .transient { removeButton(record, withTitle: true) }
                    }
                }
                .font(.system(size: 12, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("event-notice.detail")
        )
    }

    private func removeButton(_ record: EventNoticeRecord, withTitle: Bool = false) -> some View {
        Button {
            if let action = record.action { _ = model.remove(action) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "minus.circle")
                if withTitle { Text(l10n.text(.eventNoticeRemove)) }
            }
            .frame(minWidth: 28, minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!record.isActionable)
        .accessibilityLabel(l10n.text(.eventNoticeRemove))
        .accessibilityHint(
            EventNoticeProjection.accessibilitySummary(
                for: record, language: languageStore.language)
        )
        .accessibilityIdentifier("event-notice.remove.\(record.id.uuidString)")
    }

    private var l10n: ClaudioL10n { ClaudioL10n(language: languageStore.language) }
}
