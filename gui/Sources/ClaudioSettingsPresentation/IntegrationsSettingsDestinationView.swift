import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// Production Integrations destination. It owns no host configuration or capability-matrix
/// state; all facts and asynchronous lifecycle behavior come from the Core model.
@MainActor
struct IntegrationsSettingsDestinationView: View {
    @ObservedObject var model: IntegrationDestinationModel
    @ObservedObject var focusCoordinator: IntegrationDestinationFocusCoordinator
    @ObservedObject var languageStore: ClaudioPreferences
    let onManageEvents: @MainActor (HostID) -> Void
    let onAnnouncement: @MainActor (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedTarget: IntegrationDestinationFocusTarget?
    @State private var handledFocusRequestRevision = 0
    @State private var feedbackAnnouncer = IntegrationsFeedbackAnnouncementModel()

    private var l10n: ClaudioL10n { ClaudioL10n(language: languageStore.language) }

    init(
        model: IntegrationDestinationModel,
        focusCoordinator: IntegrationDestinationFocusCoordinator,
        languageStore: ClaudioPreferences,
        onManageEvents: @escaping @MainActor (HostID) -> Void,
        onAnnouncement: @escaping @MainActor (String) -> Void
    ) {
        self.model = model
        self.focusCoordinator = focusCoordinator
        self.languageStore = languageStore
        self.onManageEvents = onManageEvents
        self.onAnnouncement = onAnnouncement
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    pageHeader
                    sectionLabel(l10n.text(.integrationsAgentSection))
                    agentSection
                    Text(l10n.text(.integrationsAgentHint))
                        .font(ClaudioTheme.font(.secondary))
                        .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)

                    if !model.content.isUnavailable, let facts = model.selectedHostFacts {
                        sectionLabel(
                            l10n.format(
                                .integrationsConnectionSection,
                                localizedHostName(facts.host, language: languageStore.language)),
                            topPadding: 30)
                        connectionSection(facts)
                        infoCallout
                    } else {
                        unavailableSection
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 52)
                .padding(.vertical, 60)
            }
            .accessibilityIdentifier("integrations.destination.scroll")

            if let feedback = model.feedback {
                feedbackToast(feedback)
                    .padding(.trailing, 24)
                    .padding(.bottom, 24)
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.dynamicTypeSize, languageStore.interfaceTextSize.dynamicTypeSize)
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { model.pendingConfirmation != nil },
                set: { isPresented in
                    if !isPresented { model.cancelPendingAction() }
                }),
            titleVisibility: .visible,
            presenting: model.pendingConfirmation
        ) { confirmation in
            confirmationButtons(confirmation)
        } message: { confirmation in
            Text(confirmationMessage(confirmation))
        }
        .onReceive(focusCoordinator.$requestRevision) { revision in
            guard
                revision > handledFocusRequestRevision,
                focusCoordinator.consumeRequest(revision)
            else { return }
            handledFocusRequestRevision = revision
            applyFocusRequest(focusCoordinator.requestedTarget)
        }
        .onChange(of: model.selectedHost) { _ in reconcileFocus() }
        .onChange(of: model.feedback?.revision) { _ in
            announceFeedbackIfNeeded()
            reconcileFocus()
        }
        .onChange(of: model.isWindowKey) { isKey in
            if isKey { announceFeedbackIfNeeded() }
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.16),
            value: model.feedback?.revision)
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n.text(.settingsDestinationIntegrations))
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(ClaudioTheme.text(colorScheme))
                .accessibilityAddTraits(.isHeader)
                .focusable()
                .focused($focusedTarget, equals: .title)
                .accessibilityIdentifier("integrations.destination.title")
            Text(l10n.text(.integrationsDestinationSubtitle))
                .font(ClaudioTheme.font(.body))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionLabel(_ title: String, topPadding: CGFloat = 30) -> some View {
        Text(title)
            .font(ClaudioTheme.font(.caption).weight(.semibold))
            .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            .textCase(.uppercase)
            .padding(.top, topPadding)
            .padding(.bottom, 10)
            .accessibilityAddTraits(.isHeader)
    }

    private var agentSection: some View {
        SettingsSectionCard {
            VStack(spacing: 0) {
                ForEach(model.agentControls) { agent in
                    agentRow(agent)
                    if agent.host != model.agentControls.last?.host {
                        Divider()
                    }
                }
            }
        }
        .accessibilityIdentifier("integrations.destination.agent-list")
    }

    private func agentRow(_ agent: IntegrationAgentConnectionControlPresentation) -> some View {
        HStack(spacing: 12) {
            Button {
                _ = model.selectHost(agent.host)
            } label: {
                Text(agent.title)
                    .font(ClaudioTheme.font(.body).weight(.semibold))
                    .foregroundColor(ClaudioTheme.text(colorScheme))
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focusedTarget, equals: .agent(agent.host))
            .accessibilityLabel(agent.title)
            .accessibilityValue(
                "\(localizedAgentStatus(agent.status))，\(agent.coverageText)"
            )
            .accessibilityAddTraits(model.selectedHost == agent.host ? .isSelected : [])
            .accessibilityIdentifier("integrations.destination.agent.\(agent.host.rawValue)")

            ClaudioStatusCapsule(localizedAgentStatus(agent.status), isEmphasized: agent.isOn)
                .fixedSize()
            Text(agent.coverageText)
                .font(ClaudioTheme.font(.technical))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .monospacedDigit()
                .accessibilityLabel(l10n.text(.integrationsCoverage))
            Toggle(
                "",
                isOn: Binding(
                    get: { agent.isOn },
                    set: { _ in model.requestToggle(for: agent.host) })
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(ClaudioTheme.clay(colorScheme))
            .disabled(!agent.isToggleEnabled)
            .focused($focusedTarget, equals: .toggle(agent.host))
            .accessibilityLabel(
                l10n.format(
                    agent.isOn ? .integrationsDisable : .integrationsEnable,
                    agent.title)
            )
            .accessibilityIdentifier("integrations.destination.toggle.\(agent.host.rawValue)")

            if agent.isInFlight, let operation = model.inFlightOperation {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(localizedInFlightStatus(operation))
                    .font(ClaudioTheme.font(.caption).weight(.semibold))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    model.selectedHost == agent.host
                        ? Color.primary.opacity(0.06) : Color.clear))
    }

    private func connectionSection(_ facts: IntegrationDestinationHostFacts) -> some View {
        let section = integrationConnectionSectionPresentation(for: facts)
        return SettingsSectionCard {
            VStack(spacing: 0) {
                ForEach(section.rows) { row in
                    connectionRow(row, facts: facts)
                    if row.kind != .receiptHistory { Divider() }
                }
            }
        }
        .accessibilityIdentifier("integrations.destination.connection-group")
    }

    private func connectionRow(
        _ row: IntegrationConnectionRowPresentation,
        facts: IntegrationDestinationHostFacts
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(localizedConnectionRowTitle(row.kind))
                    .font(ClaudioTheme.font(.body).weight(.semibold))
                    .foregroundColor(ClaudioTheme.text(colorScheme))
                Text(localizedConnectionRowCaption(row.kind, facts: facts))
                    .font(ClaudioTheme.font(.caption))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 7) {
                if row.kind == .connectionStatus {
                    ClaudioStatusCapsule(
                        localizedAgentStatus(facts.status), isEmphasized: facts.status == .ready)
                } else if row.kind == .mechanism, let value = row.value {
                    Text(value)
                        .font(ClaudioTheme.font(.technical))
                        .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                        .monospacedDigit()
                }
                ForEach(row.actions, id: \.self) { action in
                    connectionActionButton(action, facts: facts)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(minHeight: 58, alignment: .center)
        .padding(.vertical, 5)
        .focused($focusedTarget, equals: .connectionRow(row.kind))
        .accessibilityIdentifier("integrations.destination.row.\(row.kind.rawValue)")
    }

    @ViewBuilder
    private func connectionActionButton(
        _ action: IntegrationConnectionRowAction,
        facts: IntegrationDestinationHostFacts
    ) -> some View {
        Group {
            switch action {
            case .redetect:
                Button(l10n.text(.actionRedetect)) { perform(.redetect) }
                    .accessibilityIdentifier(
                        "integrations.destination.redetect.\(facts.host.rawValue)")
            case .copyHooks:
                Button(l10n.text(.actionCopyHooks)) { perform(.copyHooksCommand) }
                    .accessibilityIdentifier(
                        "integrations.destination.copy-hooks.\(facts.host.rawValue)")
            case .repair(let host):
                Button(
                    localizedHostIntegrationUserActionTitle(
                        .repair(host),
                        hostStatus: facts.status,
                        language: languageStore.language)
                ) { perform(.repair(host)) }
            case .copyConfigurationSource(let host):
                Button(l10n.format(.integrationsCopyPathLabel, host.displayName)) {
                    _ = model.copyConfigurationSource(for: host)
                }
                .focused($focusedTarget, equals: .copyConfigurationSource(host))
                .accessibilityValue(facts.configurationSource ?? "")
                .accessibilityHint(l10n.text(.integrationsCopyPathHint))
                .accessibilityIdentifier("integrations.destination.copy-source.\(host.rawValue)")
            case .manageEvents(let host):
                Button(l10n.text(.settingsIntegrationsManageEvents)) {
                    onManageEvents(host)
                }
                .accessibilityHint(l10n.text(.settingsIntegrationsManageEventsHint))
                .accessibilityIdentifier("integrations.destination.manage-events.\(host.rawValue)")
            case .clearReceiptHistory(let host):
                Button(l10n.format(.actionClearReceiptHistory, host.displayName)) {
                    model.requestClearReceiptHistory(for: host)
                }
                .accessibilityHint(l10n.text(.actionClearReceiptHistoryHint))
                .accessibilityIdentifier("integrations.destination.clear-receipts.\(host.rawValue)")
            }
        }
        .buttonStyle(.borderless)
        .disabled(model.isPerformingAction)
    }

    private var unavailableSection: some View {
        SettingsSectionCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(l10n.text(.integrationsUnavailableTitle))
                    .font(ClaudioTheme.font(.body).weight(.semibold))
                Text(model.content.unavailableReason ?? l10n.text(.integrationsStoreUnavailable))
                    .font(ClaudioTheme.font(.caption))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                Button(l10n.text(.actionRedetect)) { perform(.redetect) }
                    .disabled(model.isPerformingAction)
            }
        }
        .padding(.top, 30)
    }

    private var infoCallout: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .accessibilityHidden(true)
            Text(l10n.text(.integrationsActivationCallout))
                .font(ClaudioTheme.font(.caption))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 18)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("integrations.destination.info-callout")
    }

    private func feedbackToast(_ feedback: IntegrationsFeedback) -> some View {
        HStack(spacing: 10) {
            Image(systemName: feedbackSymbol(feedback.kind))
                .foregroundColor(feedbackColor(feedback.kind))
                .accessibilityHidden(true)
            Text(feedback.message(language: languageStore.language))
                .font(ClaudioTheme.font(.caption).weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.dismissFeedback(revision: feedback.revision)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(ClaudioIconButtonStyle())
            .accessibilityLabel(l10n.text(.integrationsCloseFeedback))
            .accessibilityIdentifier("integrations.destination.feedback.dismiss")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ClaudioTheme.hairline(colorScheme)))
        .shadow(radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(feedback.localizedAccessibilityLabel(language: languageStore.language))
        .accessibilityIdentifier("integrations.destination.feedback.toast")
    }

    private var confirmationTitle: String {
        guard let confirmation = model.pendingConfirmation else {
            return l10n.text(.integrationsDisconnectTitle)
        }
        switch confirmation {
        case .disconnect(let host):
            return l10n.format(.integrationsDisconnectConfirm, host.displayName)
        case .clearReceiptHistory(let host):
            return l10n.format(.integrationsClearReceiptHistoryConfirm, host.displayName)
        }
    }

    @ViewBuilder
    private func confirmationButtons(
        _ confirmation: IntegrationDestinationConfirmation
    ) -> some View {
        switch confirmation {
        case .disconnect(let host):
            Button(l10n.format(.actionDisconnect, host.displayName), role: .destructive) {
                submitConfirmation(confirmation)
            }
            Button(l10n.text(.commonCancel), role: .cancel) {
                model.cancelPendingAction()
            }
        case .clearReceiptHistory(let host):
            Button(l10n.format(.actionClearReceiptHistory, host.displayName), role: .destructive) {
                submitConfirmation(confirmation)
            }
            Button(l10n.text(.commonCancel), role: .cancel) {
                model.cancelPendingAction()
            }
        }
    }

    private func submitConfirmation(
        _ confirmation: IntegrationDestinationConfirmation
    ) {
        guard let action = model.consumePendingAction(confirmation) else { return }
        Task { await model.perform(action) }
    }

    private func confirmationMessage(_ confirmation: IntegrationDestinationConfirmation) -> String {
        switch confirmation {
        case .disconnect(let host):
            return l10n.format(.integrationsDisconnectMessage, host.displayName)
        case .clearReceiptHistory(let host):
            return l10n.format(.integrationsClearReceiptHistoryMessage, host.displayName)
        }
    }

    private func applyFocusRequest(_ target: IntegrationDestinationFocusTarget?) {
        switch target {
        case .title:
            focusedTarget = .title
        case .agent(let host) where model.agent(for: host) != nil:
            focusedTarget = .agent(host)
        case .toggle(let host) where model.agent(for: host) != nil:
            focusedTarget = .toggle(host)
        case .connectionRow(let kind) where model.connectionSection?.row(kind) != nil:
            focusedTarget = .connectionRow(kind)
        case .copyConfigurationSource(let host)
        where model.selectedHostFacts?.configurationSource != nil && model.selectedHost == host:
            focusedTarget = .copyConfigurationSource(host)
        default:
            focusedTarget =
                model.selectedHost.map(IntegrationDestinationFocusTarget.agent)
                ?? model.agentControls.first.map { .agent($0.host) }
        }
    }

    private func reconcileFocus() {
        guard let focusedTarget else { return }
        switch focusedTarget {
        case .title:
            break
        case .agent(let host), .toggle(let host):
            guard model.agent(for: host) != nil else { self.focusedTarget = nil; return }
        case .connectionRow(let kind):
            guard model.connectionSection?.row(kind) != nil else {
                self.focusedTarget = nil; return
            }
        case .copyConfigurationSource(let host):
            guard model.selectedHostFacts?.configurationSource != nil,
                model.selectedHost == host
            else { self.focusedTarget = nil; return }
        case .dismissFeedback:
            break
        }
    }

    private func announceFeedbackIfNeeded() {
        guard model.isWindowVisible, model.isWindowKey,
            let sentence = feedbackAnnouncer.consume(
                model.feedback,
                language: languageStore.language)
        else { return }
        onAnnouncement(sentence)
    }

    private func localizedAgentStatus(_ status: HostSourceRowStatus) -> String {
        switch status {
        case .ready: return l10n.text(.integrationsStatusReady)
        case .awaitingActivation: return l10n.text(.integrationsStatusAwaiting)
        case .legacy: return l10n.text(.integrationsStatusLegacy)
        case .notConnected: return l10n.text(.integrationsStatusNotConnected)
        case .needsAttention: return l10n.text(.integrationsStatusNeedsAttention)
        }
    }

    private func localizedConnectionRowTitle(_ kind: IntegrationConnectionRowKind) -> String {
        switch kind {
        case .connectionStatus: return l10n.text(.integrationsConnection)
        case .mechanism: return l10n.text(.integrationsMechanism)
        case .eventsAndSounds: return l10n.text(.integrationsEventsAndSounds)
        case .receiptHistory: return l10n.text(.integrationsReceiptHistory)
        }
    }

    private func localizedConnectionRowCaption(
        _ kind: IntegrationConnectionRowKind,
        facts: IntegrationDestinationHostFacts
    ) -> String {
        switch kind {
        case .connectionStatus:
            let localizedRow = localizedHostSourceRow(
                facts.row,
                language: languageStore.language)
            let diagnosis: String
            if facts.status == .ready, facts.latestReceiptEvidence != nil {
                diagnosis = l10n.text(.integrationsActivatedDescription)
            } else {
                switch facts.status {
                case .notConnected: diagnosis = l10n.text(.integrationsNotConnectedDescription)
                case .needsAttention:
                    diagnosis =
                        localizedRow.detailText ?? l10n.text(.integrationsNeedsAttentionDescription)
                case .ready, .awaitingActivation, .legacy:
                    diagnosis = l10n.text(.integrationsConfiguredWaitingDescription)
                }
            }
            let diagnosisWithDetail: String
            if facts.status == .needsAttention {
                diagnosisWithDetail = diagnosis
            } else if let detail = localizedRow.detailText {
                diagnosisWithDetail = "\(diagnosis) \(detail)"
            } else {
                diagnosisWithDetail = diagnosis
            }
            if let receipt = localizedReceipt(facts) {
                return "\(diagnosisWithDetail) \(l10n.format(.integrationsLatestReceipt, receipt))"
            }
            return "\(diagnosisWithDetail) \(l10n.text(.integrationsNoReceipt))"
        case .mechanism:
            let mechanism = localizedMechanism(facts.mechanism)
            guard let source = facts.configurationSource else {
                return "\(mechanism) · \(l10n.text(.integrationsNoConfigurationSource))"
            }
            let configurationSourceValue = l10n.format(
                .integrationsConfigurationSourceValue,
                abbreviatedConfigurationPath(source))
            return "\(mechanism) · \(configurationSourceValue)"
        case .eventsAndSounds:
            return l10n.format(.integrationsSurfaceEventsCaption, facts.host.displayName)
        case .receiptHistory:
            return l10n.text(.integrationsReceiptPolicy)
        }
    }

    private func localizedMechanism(_ mechanism: HostIntegrationMechanism) -> String {
        switch mechanism {
        case .nativeHooks: return l10n.text(.integrationsMechanismNativeHooks)
        case .accessibilityBeta: return l10n.text(.integrationsMechanismAccessibilityBeta)
        }
    }

    private func localizedReceipt(_ facts: IntegrationDestinationHostFacts) -> String? {
        guard let evidence = facts.latestReceiptEvidence else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "\(facts.host.displayName) · "
            + "\(localizedEventName(evidence.event, language: languageStore.language)) · "
            + "\(formatter.string(from: evidence.timestamp)) · "
            + localizedPlaybackResult(evidence.playbackResult, language: languageStore.language)
    }

    private func localizedInFlightStatus(
        _ operation: IntegrationDestinationInFlightPresentation
    ) -> String {
        switch operation.action {
        case .redetect: return l10n.text(.actionRedetectInProgress)
        case .connect: return l10n.text(.actionConnectInProgress)
        case .repair:
            return operation.isUpgrade
                ? l10n.text(.actionUpgradeInProgress)
                : l10n.text(.actionRepairInProgress)
        case .disconnect: return l10n.text(.actionDisconnectInProgress)
        case .clearReceiptHistory: return l10n.text(.actionClearReceiptHistoryInProgress)
        case .copyHooksCommand: return l10n.text(.actionCopyHooks)
        }
    }

    private func perform(_ action: HostIntegrationUserAction) {
        Task { await model.perform(action) }
    }

    private func feedbackSymbol(_ kind: IntegrationsFeedbackKind) -> String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .information: return "info.circle.fill"
        case .failure: return "xmark.circle.fill"
        }
    }

    private func feedbackColor(_ kind: IntegrationsFeedbackKind) -> Color {
        switch kind {
        case .success: return ClaudioTheme.success(colorScheme)
        case .information: return ClaudioTheme.clay(colorScheme)
        case .failure: return ClaudioTheme.error(colorScheme)
        }
    }
}
