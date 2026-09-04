import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Combine
import SwiftUI

@MainActor
struct UsageSettingsView: View {
    @ObservedObject var model: UsageSettingsModel
    @ObservedObject var preferences: ClaudioPreferences
    let focusedTarget: FocusState<SettingsWindowFocusTarget?>.Binding
    let onAnnouncement: @MainActor (String) -> Void

    @State private var confirmation: UsageClearConfirmation?

    private var l10n: ClaudioL10n { ClaudioL10n(language: preferences.language) }

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
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label(l10n.text(.settingsUsageRefresh), systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.isOperationActive)
            .focused(focusedTarget, equals: SettingsWindowFocusTarget.firstAction(.usage))
            .accessibilityIdentifier("settings.usage.refresh")

            historySection.settingsSectionSurface()
            logSection.settingsSectionSurface()
            privacySection.settingsSectionSurface()

            if let feedback = model.feedback {
                feedbackView(feedback)
            }
        }
        .frame(maxWidth: 700, alignment: .leading)
        .settingsMountIdentity(SettingsPresentationAccessibilityID.destination(.usage))
        .task { model.refresh() }
        .onReceive(model.$feedback.dropFirst().compactMap { $0 }) { feedback in
            onAnnouncement(feedbackText(feedback))
        }
        .alert(item: $confirmation) { target in
            switch target {
            case .history:
                Alert(
                    title: Text(l10n.text(.settingsUsageClearHistoryTitle)),
                    message: Text(l10n.text(.settingsUsageClearHistoryMessage)),
                    primaryButton: .destructive(Text(l10n.text(.settingsUsageClearHistory))) {
                        model.clearHistory()
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

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n.text(.settingsUsageHistoryTitle))
                .font(.headline)

            ForEach(model.presentation.surfaces) { surface in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(localizedHostName(surface.host, language: preferences.language))
                            .font(.headline)
                        Spacer()
                        Text(l10n.format(.settingsUsageSurfaceCount, Int64(surface.retainedCount)))
                            .foregroundColor(.secondary)
                    }

                    historyState(surface.sourceState)

                    if surface.events.isEmpty {
                        Text(l10n.text(.settingsUsageHistoryNone))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(surface.events) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(
                                    localizedEventName(event.event, language: preferences.language)
                                )
                                .font(.subheadline.weight(.semibold))
                                Text(
                                    event.resultCounts.map {
                                        l10n.format(
                                            .settingsUsageResultCount,
                                            localizedUsagePlaybackResult($0.result),
                                            Int64($0.count))
                                    }.joined(separator: " · ")
                                )
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(12)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings.usage.surface.\(surface.id)")
            }

            Button(role: .destructive) {
                confirmation = .history
            } label: {
                actionLabel(
                    title: l10n.text(.settingsUsageClearHistory),
                    action: .clearHistory,
                    systemImage: "clock.badge.xmark")
            }
            .disabled(model.isOperationActive)
            .accessibilityIdentifier("settings.usage.clear-history")
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n.text(.settingsUsageLogTitle))
                .font(.headline)
            Text(l10n.text(.settingsUsageLogDescription))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(logStateText(model.presentation.log.state), systemImage: logStateIcon)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.usage.log-state")

            Text(model.presentation.log.path)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .accessibilityIdentifier("settings.usage.log-path")

            if model.presentation.log.failures.isEmpty {
                Text(l10n.text(.settingsUsageLogNoFailures))
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(model.presentation.log.failures.enumerated()), id: \.offset) {
                    _, failure in
                    Text(logFailureText(failure))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button(l10n.text(.settingsUsageRevealLog)) {
                    model.revealLog()
                }
                .disabled(model.isOperationActive)
                .accessibilityIdentifier("settings.usage.reveal-log")

                Button(l10n.text(.settingsUsageCopyLogPath)) {
                    model.copyLogPath()
                }
                .disabled(model.isOperationActive)
                .accessibilityIdentifier("settings.usage.copy-log-path")

                Button(role: .destructive) {
                    confirmation = .log
                } label: {
                    actionLabel(
                        title: l10n.text(.settingsUsageClearLog),
                        action: .clearLog,
                        systemImage: "trash")
                }
                .disabled(model.isOperationActive)
                .accessibilityIdentifier("settings.usage.clear-log")
            }
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n.text(.settingsUsagePrivacyTitle))
                .font(.headline)
            Label(l10n.text(.settingsUsagePrivacyHost), systemImage: "lock.shield")
                .fixedSize(horizontal: false, vertical: true)
            Label(l10n.text(.settingsUsagePrivacyProvider), systemImage: "network")
                .fixedSize(horizontal: false, vertical: true)
            Text(l10n.text(.settingsUsagePrivacyBilling))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(model.presentation.providerDisclosures) { disclosure in
                Text(
                    l10n.format(
                        .settingsUsageProviderDisclosure,
                        l10n.text(disclosure.displayNameKey),
                        disclosure.profileID.rawValue,
                        disclosure.regionID ?? "global")
                )
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(
                    "settings.usage.provider.\(disclosure.profileID.rawValue)")
            }
        }
    }

    @ViewBuilder
    private func historyState(_ state: UsageHistorySourceState) -> some View {
        switch state {
        case .available:
            EmptyView()
        case .missing:
            statusLabel(l10n.text(.settingsUsageHistoryMissing), icon: "minus.circle")
        case .damaged(let count):
            statusLabel(
                l10n.format(.settingsUsageHistoryDamaged, Int64(count)),
                icon: "exclamationmark.triangle.fill")
        case .unreadable:
            statusLabel(
                l10n.text(.settingsUsageHistoryUnreadable),
                icon: "exclamationmark.triangle.fill")
        }
    }

    private func statusLabel(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func actionLabel(
        title: String,
        action: UsageSettingsAction,
        systemImage: String
    ) -> some View {
        Group {
            if model.activeActions.contains(action) {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(l10n.text(.settingsUsageActionInProgress))
                }
            } else {
                Label(title, systemImage: systemImage)
            }
        }
    }

    private func feedbackView(_ feedback: UsageSettingsFeedback) -> some View {
        let failure = feedback.failure
        return Label(
            feedbackText(feedback),
            systemImage: failure == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .foregroundColor(failure == nil ? .green : .red)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("settings.usage.feedback")
    }

    private func feedbackText(_ feedback: UsageSettingsFeedback) -> String {
        if let failure = feedback.failure {
            return switch failure {
            case .historyLockBusy: l10n.text(.settingsUsageFailureHistoryLockBusy)
            case .logLockBusy: l10n.text(.settingsUsageFailureLogLockBusy)
            case .historyClearFailed: l10n.text(.settingsUsageFailureHistoryClear)
            case .logClearFailed: l10n.text(.settingsUsageFailureLogClear)
            case .finderFailed: l10n.text(.settingsUsageFailureFinder)
            case .clipboardFailed: l10n.text(.settingsUsageFailureClipboard)
            }
        }
        return switch feedback.action {
        case .clearHistory: l10n.text(.settingsUsageActionHistoryCleared)
        case .clearLog: l10n.text(.settingsUsageActionLogCleared)
        case .revealLog: l10n.text(.settingsUsageActionLogRevealed)
        case .copyLogPath: l10n.text(.settingsUsageActionLogPathCopied)
        }
    }

    private func logStateText(_ state: UsageDiagnosticLogState) -> String {
        switch state {
        case .available(let size):
            return l10n.format(.settingsUsageLogAvailable, formattedByteCount(size))
        case .missing:
            return l10n.text(.settingsUsageLogMissing)
        case .damaged(let size, let skipped):
            return l10n.format(
                .settingsUsageLogDamaged,
                formattedByteCount(size),
                Int64(skipped))
        case .unreadable:
            return l10n.text(.settingsUsageLogUnreadable)
        }
    }

    private var logStateIcon: String {
        switch model.presentation.log.state {
        case .available: "doc.text"
        case .missing: "doc.badge.ellipsis"
        case .damaged, .unreadable: "exclamationmark.triangle.fill"
        }
    }

    private func logFailureText(_ failure: UsageLogFailureSummary) -> String {
        let category: String =
            switch failure.category {
            case .playbackLaunch: l10n.text(.settingsUsageLogFailurePlaybackLaunch)
            case .playbackLock: l10n.text(.settingsUsageLogFailurePlaybackLock)
            case .receiptWrite: l10n.text(.settingsUsageLogFailureReceiptWrite)
            case .other: l10n.text(.settingsUsageLogFailureOther)
            }
        let event =
            failure.event.map {
                localizedEventName($0, language: preferences.language)
            } ?? l10n.text(.settingsUsageLogFailureUnknownEvent)
        return l10n.format(
            .settingsUsageLogFailureSummary,
            event,
            category)
    }

    private func formattedByteCount(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    private func localizedUsagePlaybackResult(_ result: UsagePlaybackResultCategory) -> String {
        switch result {
        case .played: l10n.text(.hostPlaybackPlayed)
        case .muted: l10n.text(.hostPlaybackMuted)
        case .debounced: l10n.text(.hostPlaybackDebounced)
        case .failed: l10n.text(.hostPlaybackFailed)
        }
    }
}

private enum UsageClearConfirmation: String, Identifiable {
    case history
    case log

    var id: String { rawValue }
}
