import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// The production Activity & Diagnostics destination. It renders the shared activity projection;
/// it never reads receipt history or derives counts from playback outcomes.
@MainActor
struct ActivityDiagnosticsView: View {
    @ObservedObject var model: ActivityDiagnosticsModel
    @ObservedObject var preferences: ClaudioPreferences
    let focusedTarget: FocusState<SettingsWindowFocusTarget?>.Binding
    let onAnnouncement: (@MainActor (String) -> Void)?

    @State private var confirmation: ActivityDiagnosticsConfirmation?

    private var l10n: ClaudioL10n { ClaudioL10n(language: preferences.language) }
    private var global: ActivityOverviewPresentation { model.presentation.projection.global }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(l10n.text(.settingsUsageDescription))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(l10n.text(.settingsUsageScopeNotice), systemImage: "info.circle")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                model.refresh()
            } label: {
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Label(l10n.text(.settingsUsageRefresh), systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.isOperationActive)
            .focused(focusedTarget, equals: SettingsWindowFocusTarget.firstAction(.usage))
            .accessibilityIdentifier("settings.activity.refresh")

            summaryCards
            sourcesSection
            eventSection
            logSection
            privacySection

            HStack(spacing: 12) {
                Button(role: .destructive) {
                    confirmation = .activity
                } label: {
                    actionLabel(
                        title: l10n.text(.settingsUsageClearHistory),
                        action: .clearActivity,
                        systemImage: "chart.bar.xaxis")
                }
                .disabled(model.isOperationActive)
                .accessibilityIdentifier("settings.activity.clear")

                Button(role: .destructive) {
                    confirmation = .log
                } label: {
                    actionLabel(
                        title: l10n.text(.settingsUsageClearLog),
                        action: .clearLog,
                        systemImage: "trash")
                }
                .disabled(model.isOperationActive)
                .accessibilityIdentifier("settings.activity.clear-log")
            }

            if let feedback = model.feedback {
                feedbackView(feedback)
            }
        }
        .frame(maxWidth: 820, alignment: .leading)
        .task { model.refresh() }
        .onReceive(model.$feedback.dropFirst().compactMap { $0 }) { feedback in
            onAnnouncement?(feedbackText(feedback))
        }
        .alert(item: $confirmation) { target in
            switch target {
            case .activity:
                Alert(
                    title: Text(l10n.text(.settingsUsageClearHistoryTitle)),
                    message: Text(l10n.text(.settingsUsageClearHistoryMessage)),
                    primaryButton: .destructive(Text(l10n.text(.settingsUsageClearHistory))) {
                        model.clearActivity()
                    },
                    secondaryButton: .cancel(Text(l10n.text(.commonCancel))))
            case .log:
                Alert(
                    title: Text(l10n.text(.settingsUsageClearLogTitle)),
                    message: Text(l10n.text(.settingsUsageClearLogMessage)),
                    primaryButton: .destructive(Text(l10n.text(.settingsUsageClearLog))) {
                        model.clearLog()
                    },
                    secondaryButton: .cancel(Text(l10n.text(.commonCancel))))
            }
        }
    }

    private var summaryCards: some View {
        HStack(alignment: .top, spacing: 12) {
            summaryCard(
                title: l10n.text(.settingsActivityTodayMessages),
                value: countText(global.todayMessages),
                status: global.todayStatus,
                identifier: "settings.activity.summary.today")
            summaryCard(
                title: l10n.text(.settingsActivitySevenDayMessages),
                value: countText(global.sevenDayMessages),
                status: global.sevenDayStatus,
                identifier: "settings.activity.summary.seven-days")
            summaryCard(
                title: l10n.text(.settingsActivitySevenDaySubtasks),
                value: countText(global.sevenDaySubtasks),
                status: global.sevenDayStatus,
                identifier: "settings.activity.summary.subtasks")
        }
    }

    private func summaryCard(
        title: String,
        value: String,
        status: ActivityOverviewStatus,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(statusText(status))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n.text(.settingsUsageHistoryTitle)).font(.headline)
            ForEach(HostID.productVisibleCases, id: \.self) { host in
                let overview = model.presentation.projection.surfaces[host]
                sourceCard(host: host, overview: overview)
            }
        }
        .settingsSectionSurface()
    }

    private func sourceCard(
        host: HostID,
        overview: ActivityOverviewPresentation?
    ) -> some View {
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(localizedHostName(host, language: preferences.language))
                    .font(.headline)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(integrationStatusText(overview?.integrationStatus))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(coverageText(overview))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            HStack(spacing: 16) {
                sourceMetric(
                    title: l10n.text(.settingsActivityTodayMessages),
                    value: overview?.todayMessages)
                sourceMetric(
                    title: l10n.text(.settingsActivitySevenDayMessages),
                    value: overview?.sevenDayMessages)
                sourceMetric(
                    title: l10n.text(.settingsActivitySevenDaySubtasks),
                    value: overview?.sevenDaySubtasks)
            }
            Text(statusText(overview?.sevenDayStatus ?? .unavailable))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.activity.source.\(host.rawValue)")
    }

    private func sourceMetric(title: String, value: UInt64?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(countText(value))
                .font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var eventSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n.text(.settingsActivityEventsTitle)).font(.headline)
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Text(l10n.text(.settingsActivityRangeToday))
                    .frame(width: 52, alignment: .trailing)
                Text(l10n.text(.settingsActivityRangeSevenDays))
                    .frame(width: 52, alignment: .trailing)
                Text(l10n.text(.settingsActivityCoverage))
                    .frame(width: 42, alignment: .trailing)
            }
            .font(.caption2)
            .foregroundColor(.secondary)
            ForEach(global.eventRows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(localizedEventName(row.event, language: preferences.language))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(countText(row.todayCount))
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                    Text(countText(row.sevenDayCount))
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                    Text(row.coverage.fractionText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(
                    "\(countText(row.todayCount)), \(countText(row.sevenDayCount)), \(row.coverage.fractionText)")
                .accessibilityIdentifier("settings.activity.event.\(row.event.cliName)")
            }
        }
        .settingsSectionSurface()
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n.text(.settingsUsageLogTitle)).font(.headline)
            Text(l10n.text(.settingsUsageLogDescription))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(logStateText(model.presentation.log.state), systemImage: logStateIcon)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.activity.log-state")
            Text(model.presentation.log.path)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .accessibilityIdentifier("settings.activity.log-path")
            HStack(spacing: 12) {
                Button(l10n.text(.settingsUsageRevealLog)) { model.revealLog() }
                    .disabled(model.isOperationActive)
                    .accessibilityIdentifier("settings.activity.reveal-log")
                Button(l10n.text(.settingsUsageCopyLogPath)) { model.copyLogPath() }
                    .disabled(model.isOperationActive)
                    .accessibilityIdentifier("settings.activity.copy-log-path")
            }
        }
        .settingsSectionSurface()
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n.text(.settingsUsagePrivacyTitle)).font(.headline)
            Label(l10n.text(.settingsUsagePrivacyHost), systemImage: "lock.shield")
            Label(l10n.text(.settingsUsagePrivacyProvider), systemImage: "network")
            Text(l10n.text(.settingsUsagePrivacyBilling))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .settingsSectionSurface()
    }

    private func actionLabel(
        title: String,
        action: ActivityDiagnosticsAction,
        systemImage: String
    ) -> some View {
        Group {
            if model.activeActions.contains(action) {
                HStack { ProgressView().controlSize(.small); Text(l10n.text(.settingsUsageActionInProgress)) }
            } else {
                Label(title, systemImage: systemImage)
            }
        }
    }

    private func feedbackView(_ feedback: ActivityDiagnosticsFeedback) -> some View {
        Label(
            feedbackText(feedback),
            systemImage: feedback.failure == nil
                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundColor(feedback.failure == nil ? .green : .red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("settings.activity.feedback")
    }

    private func feedbackText(_ feedback: ActivityDiagnosticsFeedback) -> String {
        if let failure = feedback.failure {
            switch failure {
            case .activityLockBusy: return l10n.text(.settingsActivityFailureLockBusy)
            case .activityClearFailed: return l10n.text(.settingsActivityFailureClear)
            case .logLockBusy: return l10n.text(.settingsUsageFailureLogLockBusy)
            case .logClearFailed: return l10n.text(.settingsUsageFailureLogClear)
            case .finderFailed: return l10n.text(.settingsUsageFailureFinder)
            case .clipboardFailed: return l10n.text(.settingsUsageFailureClipboard)
            }
        }
        switch feedback.action {
        case .clearActivity: return l10n.text(.settingsActivityActionCleared)
        case .clearLog: return l10n.text(.settingsUsageActionLogCleared)
        case .revealLog: return l10n.text(.settingsUsageActionLogRevealed)
        case .copyLogPath: return l10n.text(.settingsUsageActionLogPathCopied)
        }
    }

    private func statusText(_ status: ActivityOverviewStatus) -> String {
        switch status {
        case .ready: return l10n.text(.settingsActivityStatusReady)
        case .empty: return l10n.text(.settingsActivityStatusEmpty)
        case .unobserved: return l10n.text(.settingsActivityStatusUnobserved)
        case .unavailable: return l10n.text(.settingsActivityStatusUnavailable)
        case .stale(let date):
            return l10n.format(.settingsActivityStatusStale, date.formatted(date: .abbreviated, time: .shortened) as NSString)
        case .partial(let date):
            return l10n.format(.settingsActivityStatusPartial, date.formatted(date: .abbreviated, time: .shortened) as NSString)
        }
    }

    private func coverageText(_ overview: ActivityOverviewPresentation?) -> String {
        guard let overview else { return "—" }
        let supported = overview.eventRows.filter { $0.availability == .supported }.count
        return l10n.format(.settingsActivityCoverage, Int64(supported), Int64(overview.eventRows.count))
    }

    private func integrationStatusText(_ status: ActivityIntegrationStatus?) -> String {
        guard let status else { return "—" }
        switch status {
        case .connected: return l10n.text(.settingsActivityConnectionConnected)
        case .awaitingReceipt: return l10n.text(.settingsActivityConnectionAwaiting)
        case .notConnected: return l10n.text(.settingsActivityConnectionNotConnected)
        case .unavailable: return l10n.text(.settingsActivityConnectionUnavailable)
        }
    }

    private func countText(_ count: UInt64?) -> String {
        count.map { String($0) } ?? "—"
    }

    private func logStateText(_ state: ActivityDiagnosticLogState) -> String {
        switch state {
        case .available(let size): l10n.format(.settingsUsageLogAvailable, formattedByteCount(size))
        case .missing: l10n.text(.settingsUsageLogMissing)
        case .damaged(let size, let skipped):
            l10n.format(.settingsUsageLogDamaged, formattedByteCount(size), Int64(skipped))
        case .unreadable: l10n.text(.settingsUsageLogUnreadable)
        }
    }

    private var logStateIcon: String {
        switch model.presentation.log.state {
        case .available: "doc.text"
        case .missing: "doc.badge.ellipsis"
        case .damaged, .unreadable: "exclamationmark.triangle.fill"
        }
    }

    private func formattedByteCount(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

private enum ActivityDiagnosticsConfirmation: String, Identifiable {
    case activity
    case log

    var id: String { rawValue }
}
