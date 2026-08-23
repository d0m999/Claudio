import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// Retained standard-window surface for capability comparison, diagnosis and in-place recovery.
/// The window consumes manager-owned presentation facts and never parses host files itself.
@MainActor
struct IntegrationsWindowView: View {
    @ObservedObject var model: IntegrationsWindowModel
    @ObservedObject var focusCoordinator: IntegrationsWindowFocusCoordinator
    @ObservedObject var languageStore: ClaudioLanguageStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ClaudioInterfaceTextSize.defaultsKey)
    private var interfaceTextSizeRaw = ClaudioInterfaceTextSize.defaultValue.rawValue
    @FocusState private var focusedTarget: IntegrationsWindowFocusTarget?
    @State private var handledFocusRequestRevision = 0
    @State private var feedbackAnnouncer = IntegrationsFeedbackAnnouncementModel()
    @State private var pendingDisconnectHost: HostID?
    @State private var pendingReceiptHistoryHost: HostID?

    private var l10n: ClaudioL10n { ClaudioL10n(language: languageStore.language) }

    private var localizedSourceRows: [HostSourceRowPresentation] {
        localizedHostSourceRows(model.content.sourceRows, language: languageStore.language)
    }

    private var localizedMatrix: HostCapabilityMatrixPresentation {
        localizedCapabilityMatrix(model.content.matrix, language: languageStore.language)
    }

    private var localizedProductGroups: [HostSourceProductGroupPresentation] {
        hostSourceProductGroups(from: localizedSourceRows)
    }

    private var localizedInspector: IntegrationsWindowInspectorPresentation? {
        guard let raw = model.inspector else { return nil }
        let localizedRow = localizedSourceRows.first(where: { $0.host == raw.host })
        let localizedCell: HostCapabilityCellPresentation?
        if case .capability(_, let event) = raw.selection {
            localizedCell = localizedMatrix.cell(host: raw.host, event: event)
        } else {
            localizedCell = nil
        }
        let title: String
        let connectionText: String
        let nativeEventText: String?
        let qualificationText: String?
        let accessibilityLabel: String
        switch raw.selection {
        case .host:
            title = localizedRow?.title ?? raw.title
            connectionText = localizedRow?.readinessText ?? raw.connectionText
            nativeEventText = raw.nativeEventText
            qualificationText = localizedRow?.detailText
            accessibilityLabel = localizedRow?.accessibilityLabel ?? raw.accessibilityLabel
        case .capability(_, let event):
            title =
                "\(localizedEventName(event, language: languageStore.language)) · "
                + (localizedRow?.title ?? raw.host.displayName)
            connectionText = localizedCell?.statusText ?? raw.connectionText
            nativeEventText = localizedCell?.nativeEventText
            qualificationText = localizedCell?.qualificationText
            accessibilityLabel = localizedCell?.accessibilityLabel ?? raw.accessibilityLabel
        }
        return IntegrationsWindowInspectorPresentation(
            selection: raw.selection,
            host: raw.host,
            title: title,
            connectionText: connectionText,
            configurationSource: raw.configurationSource.map {
                localizedConfigurationSource($0, language: languageStore.language)
            },
            nativeEventText: nativeEventText,
            latestReceiptText: localizedLatestReceiptText(
                raw.latestReceiptText,
                language: languageStore.language),
            qualificationText: qualificationText,
            accessibilityLabel: accessibilityLabel,
            actions: raw.actions)
    }

    private func localizedInFlightStatus(_ operation: IntegrationsInFlightPresentation) -> String {
        switch operation.action {
        case .redetect: return l10n.text(.actionRedetectInProgress)
        case .connect: return l10n.text(.actionConnectInProgress)
        case .repair:
            return operation.isUpgrade
                ? l10n.text(.actionUpgradeInProgress)
                : l10n.text(.actionRepairInProgress)
        case .disconnect: return l10n.text(.actionDisconnectInProgress)
        case .clearReceiptHistory: return l10n.text(.actionClearReceiptHistoryInProgress)
        case .copyHooksCommand: return operation.statusText
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            sourceSummary
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            Divider()
            selectionSummary
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
            Divider()
            GeometryReader { geometry in
                if usesSideBySideLayout(width: geometry.size.width) {
                    sideBySideContent(width: geometry.size.width)
                } else {
                    stackedContent(width: geometry.size.width)
                }
            }
        }
        .background(ClaudioTheme.panel(colorScheme))
        .frame(minWidth: 640, minHeight: 520)
        .environment(\.dynamicTypeSize, interfaceTextSize.dynamicTypeSize)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    perform(.redetect)
                } label: {
                    Label(l10n.text(.integrationsRedetect), systemImage: "arrow.clockwise")
                }
                .disabled(model.isPerformingAction)
                .accessibilityLabel(l10n.text(.integrationsRedetectLabel))
                .accessibilityHint(l10n.text(.integrationsRedetectHint))
                .accessibilityIdentifier("integrations.redetect")
            }
        }
        .confirmationDialog(
            pendingDisconnectHost.map {
                l10n.format(.integrationsDisconnectConfirm, $0.displayName)
            } ?? l10n.text(.integrationsDisconnectTitle),
            isPresented: Binding(
                get: { pendingDisconnectHost != nil },
                set: { if !$0 { pendingDisconnectHost = nil } }),
            titleVisibility: .visible,
            presenting: pendingDisconnectHost
        ) { host in
            Button(l10n.format(.actionDisconnect, host.displayName), role: .destructive) {
                pendingDisconnectHost = nil
                perform(.disconnect(host))
            }
            .accessibilityLabel(l10n.format(.integrationsDisconnectConfirm, host.displayName))
            .accessibilityHint(l10n.text(.integrationsDisconnectHint))
            .accessibilityIdentifier("integrations.confirm-disconnect.\(host.rawValue)")
            Button(l10n.text(.commonCancel), role: .cancel) {
                pendingDisconnectHost = nil
            }
            .accessibilityLabel(l10n.format(.actionDisconnect, host.displayName))
            .accessibilityIdentifier("integrations.cancel-disconnect.\(host.rawValue)")
        } message: { host in
            Text(l10n.format(.integrationsDisconnectMessage, host.displayName))
        }
        .confirmationDialog(
            pendingReceiptHistoryHost.map {
                l10n.format(.integrationsClearReceiptHistoryConfirm, $0.displayName)
            } ?? l10n.text(.integrationsClearReceiptHistoryTitle),
            isPresented: Binding(
                get: { pendingReceiptHistoryHost != nil },
                set: { if !$0 { pendingReceiptHistoryHost = nil } }),
            titleVisibility: .visible,
            presenting: pendingReceiptHistoryHost
        ) { host in
            Button(l10n.format(.actionClearReceiptHistory, host.displayName), role: .destructive) {
                pendingReceiptHistoryHost = nil
                perform(.clearReceiptHistory(host))
            }
            .accessibilityLabel(
                l10n.format(.integrationsClearReceiptHistoryConfirm, host.displayName)
            )
            .accessibilityHint(l10n.text(.actionClearReceiptHistoryHint))
            .accessibilityIdentifier("integrations.confirm-clear-receipts.\(host.rawValue)")
            Button(l10n.text(.commonCancel), role: .cancel) {
                pendingReceiptHistoryHost = nil
            }
            .accessibilityIdentifier("integrations.cancel-clear-receipts.\(host.rawValue)")
        } message: { host in
            Text(l10n.format(.integrationsClearReceiptHistoryMessage, host.displayName))
        }
        .onReceive(focusCoordinator.$requestRevision) { revision in
            guard revision > handledFocusRequestRevision else { return }
            handledFocusRequestRevision = revision
            applyInitialFocus()
        }
        .onChange(of: model.content) { _ in reconcileFocusWithVisibleControls() }
        .onChange(of: model.selection) { _ in reconcileFocusWithVisibleControls() }
        .onChange(of: model.feedback?.revision) { _ in
            announceFeedbackIfNeeded()
            reconcileFocusWithVisibleControls()
        }
        .onChange(of: model.isWindowKey) { isKey in
            if isKey { announceFeedbackIfNeeded() }
        }
        .animation(feedbackAnimation, value: model.feedback?.revision)
    }

    private func sideBySideContent(width: CGFloat) -> some View {
        let inspectorWidth = max(300, width * 0.39)
        let capabilityWidth = max(0, width - inspectorWidth - 41)
        return HStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                capabilitySection(availableWidth: capabilityWidth).padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                inspectorSection.padding(20)
            }
            .frame(width: inspectorWidth)
            .frame(maxHeight: .infinity)
        }
    }

    private func stackedContent(width: CGFloat) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                capabilitySection(availableWidth: max(0, width - 40))
                Divider()
                inspectorSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private var sourceSummary: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(localizedProductGroups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.title)
                        .font(ClaudioTheme.font(.caption).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.surfaces) { row in
                        sourceSummaryButton(row)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(group.title)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l10n.text(.integrationsSourcesSummary))
    }

    private func sourceSummaryButton(_ row: HostSourceRowPresentation) -> some View {
        let selection = IntegrationsWindowSelection.host(row.host)
        return Button {
            model.select(selection)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: sourceStatusSymbol(row.status))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(sourceStatusColor(row.status))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(ClaudioTheme.font(.sectionTitle))
                    Text(row.readinessText)
                        .font(ClaudioTheme.font(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let operation = model.inFlightOperation, operation.host == row.host {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small).accessibilityHidden(true)
                            Text(localizedInFlightStatus(operation))
                                .font(ClaudioTheme.font(.caption).weight(.semibold))
                        }
                    }
                }
                Spacer(minLength: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .padding(.horizontal, 9)
            .contentShape(Rectangle())
            .background(
                model.selection.host == row.host
                    ? ClaudioTheme.clay(colorScheme).opacity(0.1)
                    : Color.clear
            )
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(
                        model.selection.host == row.host
                            ? ClaudioTheme.clay(colorScheme)
                            : ClaudioTheme.hairline(colorScheme)
                    )
                    .frame(height: model.selection.host == row.host ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .focused($focusedTarget, equals: .hostCard(row.host))
        .accessibilityLabel(sourceRowAccessibilityLabel(row))
        .accessibilityValue(
            l10n.text(
                model.selection == selection ? .integrationsSelected : .integrationsNotSelected)
        )
        .accessibilityHint(l10n.text(.integrationsCellHint))
        .accessibilityAddTraits(model.selection == selection ? .isSelected : [])
        .accessibilityIdentifier("integrations.host.\(row.host.rawValue)")
    }

    private var selectionSummary: some View {
        HStack(spacing: 8) {
            Image(systemName: "scope")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(localizedInspector?.title ?? l10n.text(.integrationsSelectionEmpty))
                .font(ClaudioTheme.font(.secondary).weight(.semibold))
                .lineLimit(interfaceTextSize == .maximum ? 3 : 1)
            Spacer(minLength: 8)
            if let text = localizedInspector?.connectionText {
                ClaudioStatusCapsule(text, isEmphasized: false)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            languageStore.language == .english
                ? "\(l10n.text(.integrationsSelectionLabel)), \(localizedInspector?.accessibilityLabel ?? l10n.text(.integrationsSelectionEmpty))"
                : "\(l10n.text(.integrationsSelectionLabel))，\(localizedInspector?.accessibilityLabel ?? l10n.text(.integrationsSelectionEmpty))"
        )
    }

    @ViewBuilder
    private func capabilitySection(availableWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n.text(.integrationsCapability))
                .font(ClaudioTheme.font(.sectionTitle))
                .accessibilityAddTraits(.isHeader)
            if usesNarrowCapabilityTable(availableWidth: availableWidth) {
                narrowCapabilityTable
            } else {
                standardCapabilityMatrix
            }
        }
    }

    @ViewBuilder
    private var standardCapabilityMatrix: some View {
        if #available(macOS 13.0, *) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    Text(l10n.text(.integrationsEvent))
                        .frame(width: 118, alignment: .leading)
                    ForEach(localizedMatrix.hostColumns, id: \.self) { host in
                        Text(host.displayName)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(ClaudioTheme.font(.caption).weight(.semibold))
                .foregroundStyle(.secondary)
                Divider().gridCellColumns(localizedMatrix.hostColumns.count + 1)
                ForEach(localizedMatrix.rows) { row in
                    GridRow {
                        eventIdentity(row.event, title: row.title)
                            .frame(width: 118, alignment: .leading)
                            .padding(.vertical, 9)
                        ForEach(row.cells) { cell in
                            capabilityCellButton(cell, showsHostName: false)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Divider().gridCellColumns(localizedMatrix.hostColumns.count + 1)
                }
            }
        } else {
            legacyCapabilityMatrix
        }
    }

    private var legacyCapabilityMatrix: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(l10n.text(.integrationsEvent)).frame(width: 118, alignment: .leading)
                ForEach(localizedMatrix.hostColumns, id: \.self) { host in
                    Text(host.displayName).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(ClaudioTheme.font(.caption).weight(.semibold))
            .foregroundStyle(.secondary)
            Divider()
            ForEach(localizedMatrix.rows) { row in
                HStack(spacing: 0) {
                    eventIdentity(row.event, title: row.title)
                        .frame(width: 118, alignment: .leading)
                    ForEach(row.cells) { cell in
                        capabilityCellButton(cell, showsHostName: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Divider()
            }
        }
    }

    private var narrowCapabilityTable: some View {
        VStack(spacing: 0) {
            ForEach(localizedMatrix.rows) { row in
                VStack(alignment: .leading, spacing: 7) {
                    eventIdentity(row.event, title: row.title)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(row.cells) { cell in
                        capabilityCellButton(cell, showsHostName: true)
                    }
                }
                .padding(.vertical, 10)
                Divider()
            }
        }
    }

    private func eventIdentity(_ event: Event, title: String) -> some View {
        HStack(spacing: 7) {
            ClaudioEventGlyph(event: event, size: 23)
            Text(title)
                .font(ClaudioTheme.font(.secondary).weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func capabilityCellButton(
        _ cell: HostCapabilityCellPresentation,
        showsHostName: Bool
    ) -> some View {
        let selection = IntegrationsWindowSelection.capability(host: cell.host, event: cell.event)
        return Button {
            model.select(selection)
        } label: {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: cellStatusSymbol(cell.state))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(cellStatusColor(cell.state))
                    .frame(width: 17, height: 17)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    if showsHostName {
                        Text(cell.host.displayName)
                            .font(ClaudioTheme.font(.secondary).weight(.semibold))
                    }
                    Text(cell.statusText)
                        .font(ClaudioTheme.font(.secondary))
                    if let native = cell.nativeEventText {
                        Text(native)
                            .font(ClaudioTheme.font(.technical))
                            .foregroundStyle(.secondary)
                    }
                    if let qualification = cell.qualificationText {
                        Text(qualification)
                            .font(ClaudioTheme.font(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 2)
            }
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .topLeading)
            .padding(8)
            .contentShape(Rectangle())
            .background(
                model.selection == selection
                    ? ClaudioTheme.clay(colorScheme).opacity(0.12)
                    : Color.clear)
        }
        .buttonStyle(.plain)
        .focused($focusedTarget, equals: .capabilityCell(host: cell.host, event: cell.event))
        .accessibilityLabel(cell.accessibilityLabel)
        .accessibilityValue(
            l10n.text(
                model.selection == selection ? .integrationsSelected : .integrationsNotSelected)
        )
        .accessibilityHint(l10n.text(.integrationsCellHint))
        .accessibilityAddTraits(model.selection == selection ? .isSelected : [])
        .accessibilityIdentifier(
            "integrations.capability.\(cell.host.rawValue).\(cell.event.rawValue)")
    }

    @ViewBuilder
    private var inspectorSection: some View {
        if let inspector = localizedInspector {
            VStack(alignment: .leading, spacing: 13) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.text(.integrationsInspector))
                        .font(ClaudioTheme.font(.caption))
                        .foregroundStyle(.secondary)
                    Text(inspector.title)
                        .font(ClaudioTheme.font(.sectionTitle))
                        .fixedSize(horizontal: false, vertical: true)
                    if let qualification = inspector.qualificationText {
                        Text(qualification)
                            .font(ClaudioTheme.font(.secondary))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(inspector.accessibilityLabel)

                VStack(alignment: .leading, spacing: 8) {
                    evidenceRow(
                        label: l10n.text(.integrationsConnection), value: inspector.connectionText)
                    if let configurationSource = inspector.configurationSource {
                        configurationEvidenceRow(inspector, source: configurationSource)
                    }
                    evidenceRow(
                        label: l10n.text(.integrationsNativeEvent),
                        value: inspector.nativeEventText ?? l10n.text(.integrationsChooseEvent))
                    evidenceRow(
                        label: l10n.text(.integrationsRecentReceipt),
                        value: inspector.latestReceiptText ?? l10n.text(.integrationsNoReceipt))
                }

                if let feedback = model.feedback {
                    feedbackRow(feedback)
                        .transition(reduceMotion ? .identity : .opacity)
                }

                recoveryRegion

                if !visibleInspectorActions.isEmpty {
                    Divider()
                    VStack(spacing: 8) {
                        ForEach(visibleInspectorActions, id: \.self) { action in
                            inspectorButton(action)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func evidenceRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(ClaudioTheme.font(.caption))
                .foregroundStyle(.secondary)
            Text(value)
                .font(
                    label == l10n.text(.integrationsNativeEvent)
                        ? ClaudioTheme.font(.technical)
                        : ClaudioTheme.font(.caption)
                )
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            languageStore.language == .english
                ? "\(label), \(value)"
                : "\(label)，\(value)")
    }

    private func configurationEvidenceRow(
        _ inspector: IntegrationsWindowInspectorPresentation,
        source: String
    ) -> some View {
        let fullPath = source
        let shortPath = abbreviatedConfigurationPath(fullPath)
        return VStack(alignment: .leading, spacing: 3) {
            Text(l10n.text(.integrationsConfigurationSource))
                .font(ClaudioTheme.font(.caption))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(shortPath)
                    .font(ClaudioTheme.font(.technical))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .help(fullPath)
                    .accessibilityLabel(l10n.text(.integrationsConfigurationSource))
                    .accessibilityValue(fullPath)
                Spacer(minLength: 4)
                Button {
                    model.copyConfigurationPath()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(
                            minWidth: ClaudioTheme.Metrics.iconTarget,
                            minHeight: ClaudioTheme.Metrics.iconTarget)
                }
                .buttonStyle(.borderless)
                .focused($focusedTarget, equals: .copyConfigurationPath(inspector.host))
                .accessibilityLabel(
                    l10n.format(.integrationsCopyPathLabel, inspector.host.displayName)
                )
                .accessibilityValue(fullPath)
                .accessibilityHint(l10n.text(.integrationsCopyPathHint))
                .accessibilityIdentifier("integrations.copy-path.\(inspector.host.rawValue)")
            }
        }
    }

    @ViewBuilder
    private var recoveryRegion: some View {
        switch primaryRecoveryAction {
        case .none:
            EmptyView()
        case .explainMasterVolumeZero:
            Text(l10n.text(.integrationsMasterVolumeZero))
                .font(ClaudioTheme.font(.secondary))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("integrations.recovery.master-volume-zero")
        case .explainUnsupported(_, let event):
            Text(
                l10n.format(
                    .integrationsUnsupported,
                    localizedEventName(event, language: languageStore.language))
            )
            .font(ClaudioTheme.font(.secondary))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("integrations.recovery.explanation")
        default:
            recoveryButton(primaryRecoveryAction)
        }
    }

    private func recoveryButton(_ action: IntegrationsRecoveryAction) -> some View {
        Button(localizedRecoveryTitle(action)) {
            performRecovery(action)
        }
        .buttonStyle(.borderedProminent)
        .tint(ClaudioTheme.clay(colorScheme))
        .frame(maxWidth: .infinity, minHeight: ClaudioTheme.Metrics.regularControlHeight)
        .disabled(model.isPerformingAction)
        .focused($focusedTarget, equals: .recoveryAction(action))
        .accessibilityLabel(localizedRecoveryTitle(action))
        .accessibilityHint(recoveryAccessibilityHint(action))
        .accessibilityIdentifier("integrations.recovery.primary")
    }

    private func feedbackRow(_ feedback: IntegrationsFeedback) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: feedbackSymbol(feedback.kind))
                .foregroundColor(feedbackColor(feedback.kind))
                .accessibilityHidden(true)
            Text(feedback.message(language: languageStore.language))
                .font(ClaudioTheme.font(.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(
                    feedback.localizedAccessibilityLabel(language: languageStore.language))
            Button {
                model.dismissFeedback(revision: feedback.revision)
            } label: {
                Image(systemName: "xmark")
                    .frame(
                        minWidth: ClaudioTheme.Metrics.iconTarget,
                        minHeight: ClaudioTheme.Metrics.iconTarget)
            }
            .buttonStyle(.plain)
            .focused($focusedTarget, equals: .dismissFeedback(revision: feedback.revision))
            .accessibilityLabel(l10n.text(.integrationsCloseFeedback))
            .accessibilityIdentifier("integrations.feedback.dismiss")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control)
                .fill(ClaudioTheme.elevated(colorScheme)))
    }

    @ViewBuilder
    private func inspectorButton(_ action: IntegrationsWindowInspectorAction) -> some View {
        switch action {
        case .disconnect(let host):
            Button(l10n.format(.actionDisconnect, host.displayName), role: .destructive) {
                pendingDisconnectHost = host
            }
            .frame(maxWidth: .infinity, minHeight: ClaudioTheme.Metrics.regularControlHeight)
            .focused($focusedTarget, equals: .inspectorAction(action))
            .disabled(model.isPerformingAction)
            .accessibilityLabel(l10n.format(.actionDisconnect, host.displayName))
            .accessibilityHint(l10n.text(.actionDisconnectHint))
            .accessibilityIdentifier("integrations.disconnect.\(host.rawValue)")
        case .clearReceiptHistory(let host):
            Button(l10n.format(.actionClearReceiptHistory, host.displayName), role: .destructive) {
                pendingReceiptHistoryHost = host
            }
            .frame(maxWidth: .infinity, minHeight: ClaudioTheme.Metrics.regularControlHeight)
            .focused($focusedTarget, equals: .inspectorAction(action))
            .disabled(model.isPerformingAction)
            .accessibilityLabel(l10n.format(.actionClearReceiptHistory, host.displayName))
            .accessibilityHint(l10n.text(.actionClearReceiptHistoryHint))
            .accessibilityIdentifier("integrations.clear-receipts.\(host.rawValue)")
        default:
            Button(localizedInspectorActionTitle(action, hostStatus: selectedHostStatus)) {
                perform(action)
            }
            .frame(maxWidth: .infinity, minHeight: ClaudioTheme.Metrics.regularControlHeight)
            .focused($focusedTarget, equals: .inspectorAction(action))
            .disabled(model.isPerformingAction)
            .accessibilityLabel(
                localizedInspectorActionTitle(action, hostStatus: selectedHostStatus)
            )
            .accessibilityHint(inspectorActionAccessibilityHint(action))
            .accessibilityIdentifier("integrations.action.\(actionIdentifier(action))")
        }
    }

    private func perform(_ action: IntegrationsWindowInspectorAction) {
        Task { await model.perform(action) }
    }

    private func performRecovery(_ action: IntegrationsRecoveryAction) {
        Task { await model.performRecovery(action) }
    }

    private func announceFeedbackIfNeeded() {
        guard model.isWindowVisible, model.isWindowKey, NSApp.isActive else { return }
        guard
            let sentence = feedbackAnnouncer.consume(
                model.feedback,
                language: languageStore.language)
        else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: sentence,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    private func sourceRowAccessibilityLabel(_ row: HostSourceRowPresentation) -> String {
        guard let operation = model.inFlightOperation, operation.host == row.host else {
            return row.accessibilityLabel
        }
        let separator = languageStore.language == .english ? ", " : "，"
        return "\(row.accessibilityLabel)\(separator)\(localizedInFlightStatus(operation))"
    }

    private var focusScope: IntegrationsWindowFocusScope {
        IntegrationsWindowFocusScope(
            matrix: model.content.matrix,
            hostOrder: hostSurfacePresentationOrder(from: model.content.sourceRows),
            inspectorActions: visibleInspectorActions,
            recoveryAction: primaryRecoveryAction,
            configurationPathHost: model.inspector?.configurationSource == nil
                ? nil : model.inspector?.host,
            feedbackRevision: model.feedback?.revision)
    }

    /// Re-detection belongs exclusively to the window toolbar. An awaiting cell may derive
    /// `.redetect` as its semantic recovery, but rendering that same operation again inside
    /// the inspector would create two indistinguishable primary actions.
    private var primaryRecoveryAction: IntegrationsRecoveryAction {
        if case .redetect = model.recoveryAction { return .none }
        return model.recoveryAction
    }

    private var visibleInspectorActions: [IntegrationsWindowInspectorAction] {
        let actions = model.inspectorActions.filter { action in
            action != .redetect && !duplicatesRecovery(action)
        }
        let safe = actions.filter { !isDestructive($0) }
        let destructive = actions.filter(isDestructive)
        return safe + destructive
    }

    private func isDestructive(_ action: IntegrationsWindowInspectorAction) -> Bool {
        switch action {
        case .disconnect, .clearReceiptHistory: true
        default: false
        }
    }

    private func duplicatesRecovery(_ action: IntegrationsWindowInspectorAction) -> Bool {
        switch (primaryRecoveryAction, action) {
        case (.connect(let first), .connect(let second)),
            (.upgrade(let first), .repair(let second)),
            (.repair(let first), .repair(let second)):
            return first == second
        default:
            return false
        }
    }

    private func applyInitialFocus() {
        focusedTarget = integrationsWindowFocusOrder(focusScope).first
    }

    private func reconcileFocusWithVisibleControls() {
        let order = integrationsWindowFocusOrder(focusScope)
        if let focusedTarget, !order.contains(focusedTarget) {
            self.focusedTarget = order.first
        }
    }

    private var interfaceTextSize: ClaudioInterfaceTextSize {
        ClaudioInterfaceTextSize(storedValue: interfaceTextSizeRaw)
    }

    private var typeSizeTier: IntegrationsWindowTypeSizeTier {
        interfaceTextSize == .maximum ? .maximum : .standard
    }

    private func layoutAdaptation(availableWidth: CGFloat) -> IntegrationsWindowLayoutAdaptation {
        integrationsWindowLayoutAdaptation(
            for: typeSizeTier,
            availableWidth: Double(availableWidth),
            hostCount: localizedMatrix.hostColumns.count)
    }

    private func usesNarrowCapabilityTable(availableWidth: CGFloat) -> Bool {
        if case .eventCards = layoutAdaptation(availableWidth: availableWidth).mode { return true }
        return false
    }

    private func usesSideBySideLayout(width: CGFloat) -> Bool {
        width >= 760 && interfaceTextSize != .maximum
    }

    private var selectedHostStatus: HostSourceRowStatus? {
        model.content.sourceRows.first(where: { $0.host == model.selection.host })?.status
    }

    private var feedbackAnimation: Animation? {
        switch integrationsFeedbackTransition(reduceMotionEnabled: reduceMotion) {
        case .opacity: return .easeOut(duration: 0.16)
        case .immediate: return nil
        }
    }

    private func recoveryAccessibilityHint(_ action: IntegrationsRecoveryAction) -> String {
        switch action {
        case .unmute: return l10n.text(.actionUnmuteHint)
        case .explainMasterVolumeZero: return l10n.text(.integrationsMasterVolumeZero)
        case .configureSound: return l10n.text(.actionConfigureSoundHint)
        case .connect: return l10n.text(.actionConnectHint)
        case .upgrade: return l10n.text(.actionUpgradeHint)
        case .repair: return l10n.text(.actionRepairHint)
        case .redetect: return l10n.text(.actionRedetectHint)
        case .explainUnsupported, .none: return ""
        }
    }

    private func inspectorActionAccessibilityHint(
        _ action: IntegrationsWindowInspectorAction
    ) -> String {
        switch action {
        case .copyHooksCommand: return l10n.text(.actionCopyHooksHint)
        case .connect: return l10n.text(.actionConnectHint)
        case .repair: return l10n.text(.actionRepairHint)
        case .redetect: return l10n.text(.actionRedetectHint)
        case .disconnect: return l10n.text(.actionDisconnectHint)
        case .clearReceiptHistory: return l10n.text(.actionClearReceiptHistoryHint)
        }
    }

    private func localizedRecoveryTitle(_ action: IntegrationsRecoveryAction) -> String {
        switch action {
        case .unmute: return l10n.text(.actionUnmute)
        case .configureSound: return l10n.text(.actionConfigureSound)
        case .connect(let host): return l10n.format(.actionConnect, host.displayName)
        case .upgrade: return l10n.text(.actionUpgrade)
        case .repair(let host): return l10n.format(.actionRepair, host.displayName)
        case .redetect: return l10n.text(.actionRedetect)
        case .explainMasterVolumeZero, .explainUnsupported, .none: return ""
        }
    }

    private func localizedInspectorActionTitle(
        _ action: IntegrationsWindowInspectorAction,
        hostStatus: HostSourceRowStatus?
    ) -> String {
        switch action {
        case .copyHooksCommand: return l10n.text(.actionCopyHooks)
        case .redetect: return l10n.text(.actionRedetect)
        case .connect(let host): return l10n.format(.actionConnect, host.displayName)
        case .repair(let host):
            return hostStatus == .legacy
                ? l10n.text(.actionUpgrade)
                : l10n.format(.actionRepair, host.displayName)
        case .disconnect(let host): return l10n.format(.actionDisconnect, host.displayName)
        case .clearReceiptHistory(let host):
            return l10n.format(.actionClearReceiptHistory, host.displayName)
        }
    }

    private func actionIdentifier(_ action: IntegrationsWindowInspectorAction) -> String {
        switch action {
        case .copyHooksCommand: "copy-hooks"
        case .redetect: "redetect"
        case .connect(let host): "connect.\(host.rawValue)"
        case .repair(let host): "repair.\(host.rawValue)"
        case .disconnect(let host): "disconnect.\(host.rawValue)"
        case .clearReceiptHistory(let host): "clear-receipts.\(host.rawValue)"
        }
    }

    private func sourceStatusSymbol(_ status: HostSourceRowStatus) -> String {
        switch status {
        case .ready: "checkmark.circle.fill"
        case .awaitingActivation: "clock.fill"
        case .legacy: "arrow.triangle.2.circlepath.circle"
        case .notConnected: "link.badge.plus"
        case .unavailable: "lock.circle"
        case .needsAttention: "exclamationmark.circle.fill"
        }
    }

    private func sourceStatusColor(_ status: HostSourceRowStatus) -> Color {
        switch status {
        case .ready: ClaudioTheme.success(colorScheme)
        case .awaitingActivation, .legacy, .notConnected, .unavailable:
            ClaudioTheme.secondaryText(colorScheme)
        case .needsAttention: ClaudioTheme.error(colorScheme)
        }
    }

    private func cellStatusSymbol(_ state: AudibilityCellState) -> String {
        switch state {
        case .audible: "speaker.wave.2.fill"
        case .muted: "speaker.slash.fill"
        case .missingSound: "waveform.badge.exclamationmark"
        case .notConnected: "link.badge.plus"
        case .awaitingActivation: "clock.fill"
        case .legacy: "arrow.triangle.2.circlepath.circle"
        case .unsupported: "minus.circle"
        case .degraded: "exclamationmark.circle.fill"
        }
    }

    private func cellStatusColor(_ state: AudibilityCellState) -> Color {
        switch state {
        case .audible: ClaudioTheme.success(colorScheme)
        case .missingSound, .degraded: ClaudioTheme.error(colorScheme)
        case .muted, .notConnected, .awaitingActivation, .legacy, .unsupported:
            ClaudioTheme.secondaryText(colorScheme)
        }
    }

    private func feedbackSymbol(_ kind: IntegrationsFeedbackKind) -> String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .information: "info.circle.fill"
        case .failure: "xmark.circle.fill"
        }
    }

    private func feedbackColor(_ kind: IntegrationsFeedbackKind) -> Color {
        switch kind {
        case .success: ClaudioTheme.success(colorScheme)
        case .information: ClaudioTheme.clay(colorScheme)
        case .failure: ClaudioTheme.error(colorScheme)
        }
    }
}
