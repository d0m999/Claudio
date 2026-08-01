import AppKit
import ClaudioCore
import ClaudioGUICore
import SwiftUI

/// Retained standard-window surface for both host integrations. The view receives already
/// composed presentation values from `IntegrationsWindowModel`; it owns geometry and interaction,
/// never host configuration inspection.
@MainActor
struct IntegrationsWindowView: View {
    @ObservedObject var model: IntegrationsWindowModel
    @ObservedObject var focusCoordinator: IntegrationsWindowFocusCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var focusedTarget: IntegrationsWindowFocusTarget?
    @State private var handledFocusRequestRevision = 0
    @State private var feedbackAnnouncer = IntegrationsFeedbackAnnouncementModel()

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                header
                sourceCards
                capabilitySection
                inspectorSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .background(ClaudioColor.panel(colorScheme))
        .frame(minWidth: 640, minHeight: 520)
        .onReceive(focusCoordinator.$requestRevision) { revision in
            guard revision > handledFocusRequestRevision else { return }
            handledFocusRequestRevision = revision
            applyInitialFocus()
        }
        .onChange(of: model.content) { _ in
            reconcileFocusWithVisibleControls()
        }
        .onChange(of: model.selection) { _ in
            reconcileFocusWithVisibleControls()
        }
        .onChange(of: model.feedback?.revision) { _ in
            announceFeedbackIfNeeded()
            reconcileFocusWithVisibleControls()
        }
        .onChange(of: model.isWindowKey) { isKey in
            if isKey { announceFeedbackIfNeeded() }
        }
        .animation(feedbackAnimation, value: model.feedback?.revision)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Claudio")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundColor(ClaudioColor.text(colorScheme))
                Text("声音来源与可听能力")
                    .font(.subheadline)
                    .foregroundColor(ClaudioColor.textSecondary(colorScheme))
            }
            Spacer(minLength: 12)
            Text("2 个声音来源")
                .font(.subheadline)
                .foregroundColor(ClaudioColor.textSecondary(colorScheme))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Claudio 集成，2 个声音来源")
    }

    private var sourceCards: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("声音来源")
                .font(.headline)
                .foregroundColor(ClaudioColor.text(colorScheme))
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .top, spacing: 12) {
                ForEach(model.content.sourceRows) { row in
                    sourceRowCard(row)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private func sourceRowCard(_ row: HostSourceRowPresentation) -> some View {
        let selection = IntegrationsWindowSelection.host(row.host)
        return Button {
            model.select(selection)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: sourceStatusSymbol(row.status))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(sourceStatusColor(row.status))
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.title)
                        .font(.system(.headline, design: .rounded))
                        .foregroundColor(ClaudioColor.text(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(row.readinessText)
                        .font(.subheadline)
                        .foregroundColor(ClaudioColor.text(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    if let detailText = row.detailText {
                        Text(detailText)
                            .font(.caption)
                            .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let operation = model.inFlightOperation, operation.host == row.host {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityHidden(true)
                            Text(operation.statusText)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
            .padding(14)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(ClaudioColor.surface2(colorScheme)))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        model.selection.host == row.host
                            ? ClaudioColor.clay(colorScheme)
                            : ClaudioColor.hairlineStrong(colorScheme),
                        lineWidth: model.selection.host == row.host ? 2 : 1))
        }
        .buttonStyle(.plain)
        .focused($focusedTarget, equals: .hostCard(row.host))
        .accessibilityLabel(sourceRowAccessibilityLabel(row))
        .accessibilityHint("选择后在下方查看配置证据与连接操作")
        .accessibilityAddTraits(model.selection == selection ? .isSelected : [])
    }

    @ViewBuilder
    private var capabilitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("可听能力")
                .font(.headline)
                .foregroundColor(ClaudioColor.text(colorScheme))
                .accessibilityAddTraits(.isHeader)

            switch layoutAdaptation.mode {
            case .capabilityMatrix:
                standardCapabilityMatrix
            case .eventCards:
                accessibilityEventCards
            }
        }
    }

    private var standardCapabilityMatrix: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                Text("事件")
                    .font(.caption)
                    .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                    .frame(width: 112, alignment: .leading)
                ForEach(model.content.matrix.hostColumns, id: \.self) { host in
                    Text(host.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ForEach(model.content.matrix.rows) { row in
                HStack(alignment: .top, spacing: 8) {
                    Label(row.title, systemImage: eventGlyphName(row.event))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(ClaudioColor.text(colorScheme))
                        .frame(width: 112, alignment: .leading)
                        .frame(minHeight: 50, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true)
                    ForEach(row.cells) { cell in
                        capabilityCellButton(cell, showsHostName: false)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
    }

    /// Maximum Dynamic Type: four event cards, each containing two full-width host subrows.
    private var accessibilityEventCards: some View {
        VStack(spacing: 12) {
            ForEach(model.content.matrix.rows) { row in
                VStack(alignment: .leading, spacing: 8) {
                    Label(row.title, systemImage: eventGlyphName(row.event))
                        .font(.headline)
                        .foregroundColor(ClaudioColor.event(row.event, colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(row.cells) { cell in
                        capabilityCellButton(cell, showsHostName: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(ClaudioColor.surface2(colorScheme)))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(ClaudioColor.hairlineStrong(colorScheme), lineWidth: 1))
            }
        }
    }

    private func capabilityCellButton(
        _ cell: HostCapabilityCellPresentation,
        showsHostName: Bool
    ) -> some View {
        let selection = IntegrationsWindowSelection.capability(
            host: cell.host,
            event: cell.event)
        return Button {
            model.select(selection)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: cellStatusSymbol(cell.state))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(cellStatusColor(cell.state))
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    if showsHostName {
                        Text(cell.host.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(ClaudioColor.text(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(cell.statusText)
                        .font(.subheadline)
                        .foregroundColor(ClaudioColor.text(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    if let nativeEventText = cell.nativeEventText {
                        Text(nativeEventText)
                            .font(.caption.monospaced())
                            .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let qualificationText = cell.qualificationText {
                        Text(qualificationText)
                            .font(.caption)
                            .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
            .padding(10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(ClaudioColor.panel(colorScheme)))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(
                        model.selection == selection
                            ? ClaudioColor.clay(colorScheme)
                            : ClaudioColor.hairlineStrong(colorScheme),
                        lineWidth: model.selection == selection ? 2 : 1))
        }
        .buttonStyle(.plain)
        .focused(
            $focusedTarget,
            equals: .capabilityCell(host: cell.host, event: cell.event))
        .accessibilityLabel(cell.accessibilityLabel)
        .accessibilityHint("选择后在下方查看原生事件、回执与连接操作")
        .accessibilityAddTraits(model.selection == selection ? .isSelected : [])
    }

    @ViewBuilder
    private var inspectorSection: some View {
        if let inspector = model.inspector {
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("检查器")
                        .font(.caption)
                        .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                    Text(inspector.title)
                        .font(.headline)
                        .foregroundColor(ClaudioColor.text(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    if let qualificationText = inspector.qualificationText {
                        Text(qualificationText)
                            .font(.subheadline)
                            .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(inspector.accessibilityLabel)

                VStack(alignment: .leading, spacing: 8) {
                    evidenceRow(label: "连接状态", value: inspector.connectionText)
                    evidenceRow(label: "配置来源", value: inspector.configurationSource)
                    evidenceRow(
                        label: "原生事件",
                        value: inspector.nativeEventText ?? "选择一个事件查看")
                    evidenceRow(
                        label: "最近真实回执",
                        value: inspector.latestReceiptText ?? "暂无当前安装代次的真实回执")
                }

                if let feedback = model.feedback {
                    feedbackRow(feedback)
                        .transition(reduceMotion ? .identity : .opacity)
                }

                if !visibleInspectorActions.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(visibleInspectorActions, id: \.self) { action in
                            inspectorButton(action)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func evidenceRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                .frame(width: 112, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .font(label == "原生事件" ? .caption.monospaced() : .caption)
                .foregroundColor(ClaudioColor.text(colorScheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)，\(value)")
    }

    private func feedbackRow(_ feedback: IntegrationsFeedback) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: feedbackSymbol(feedback.kind))
                .foregroundColor(feedbackColor(feedback.kind))
                .accessibilityHidden(true)
            Text(feedback.message)
                .font(.subheadline)
                .foregroundColor(ClaudioColor.text(colorScheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(feedback.accessibilityLabel)
            Button {
                model.dismissFeedback(revision: feedback.revision)
            } label: {
                Image(systemName: "xmark")
                    .frame(minWidth: 28, minHeight: 28)
            }
            .buttonStyle(.plain)
            .focused(
                $focusedTarget,
                equals: .dismissFeedback(revision: feedback.revision))
            .accessibilityLabel("关闭状态反馈")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(ClaudioColor.surface2(colorScheme)))
    }

    @ViewBuilder
    private func inspectorButton(_ action: IntegrationsWindowInspectorAction) -> some View {
        switch action {
        case .copyHooksCommand:
            Button("复制 /hooks") {
                perform(action)
            }
            .frame(maxWidth: .infinity, minHeight: 32)
            .focused($focusedTarget, equals: .inspectorAction(action))
            .disabled(model.isPerformingAction)

        case .redetect:
            Button("重新检测") {
                perform(action)
            }
            .frame(maxWidth: .infinity, minHeight: 32)
            .focused($focusedTarget, equals: .inspectorAction(action))
            .disabled(model.isPerformingAction)

        case .connect(let host):
            Button("连接 \(host.displayName)") {
                perform(action)
            }
            .frame(maxWidth: .infinity, minHeight: 32)
            .focused($focusedTarget, equals: .inspectorAction(action))
            .disabled(model.isPerformingAction)

        case .repair(let host):
            Button(
                integrationsInspectorActionTitle(
                    action,
                    hostStatus: model.content.sourceRows.first(where: { $0.host == host })?.status)
            ) {
                perform(action)
            }
            .frame(maxWidth: .infinity, minHeight: 32)
            .focused($focusedTarget, equals: .inspectorAction(action))
            .disabled(model.isPerformingAction)

        case .disconnect(let host):
            Button("断开 \(host.displayName)", role: .destructive) {
                perform(action)
            }
            .frame(maxWidth: .infinity, minHeight: 32)
            .focused($focusedTarget, equals: .inspectorAction(action))
            .disabled(model.isPerformingAction)
            .accessibilityHint("只移除这个宿主的 Claudio 连接")
        }
    }

    private func perform(_ action: IntegrationsWindowInspectorAction) {
        Task { await model.perform(action) }
    }

    /// 状态变化必须主动开口；静态 label 只在 VoiceOver 光标落上元素时才会被读到。关闭/过期传入
    /// `nil`，由纯去重模型保证不播；Reduce Motion 只影响上面的视觉 transition，不影响这条通道。
    private func announceFeedbackIfNeeded() {
        // Retained hosting view 在窗口关闭后仍会观察 model。只有该标准窗口真实可见、
        // 为 key 且 app active 时才主动播报；否则保留未消费的 revision，若反馈尚未
        // 过期，窗口重新成为 key 时由上面的 onChange 再尝试。
        guard model.isWindowVisible, model.isWindowKey, NSApp.isActive else { return }
        guard let sentence = feedbackAnnouncer.consume(model.feedback) else { return }
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
        return "\(row.accessibilityLabel)，\(operation.statusText)"
    }

    private var focusScope: IntegrationsWindowFocusScope {
        IntegrationsWindowFocusScope(
            matrix: model.content.matrix,
            inspectorActions: model.inspectorActions,
            feedbackRevision: model.feedback?.revision)
    }

    /// Pulling the buttons back out of the pure focus order makes visual and keyboard order one
    /// decision. In particular, `.disconnect` remains last even if a caller supplied it first.
    private var visibleInspectorActions: [IntegrationsWindowInspectorAction] {
        integrationsWindowFocusOrder(focusScope).compactMap { target in
            guard case .inspectorAction(let action) = target else { return nil }
            return action
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

    private var typeSizeTier: IntegrationsWindowTypeSizeTier {
        dynamicTypeSize.isAccessibilitySize ? .maximum : .standard
    }

    private var layoutAdaptation: IntegrationsWindowLayoutAdaptation {
        integrationsWindowLayoutAdaptation(for: typeSizeTier)
    }

    private var feedbackAnimation: Animation? {
        switch integrationsFeedbackTransition(reduceMotionEnabled: reduceMotion) {
        case .opacity: .easeOut(duration: 0.16)
        case .immediate: nil
        }
    }

    private func sourceStatusSymbol(_ status: HostSourceRowStatus) -> String {
        switch status {
        case .ready: "checkmark.circle.fill"
        case .awaitingActivation: "clock.fill"
        case .legacy: "arrow.triangle.2.circlepath.circle"
        case .notConnected: "link.badge.plus"
        case .needsAttention: "exclamationmark.circle.fill"
        }
    }

    private func sourceStatusColor(_ status: HostSourceRowStatus) -> Color {
        switch status {
        case .ready: ClaudioColor.success(colorScheme)
        case .awaitingActivation, .legacy, .notConnected:
            ClaudioColor.textSecondary(colorScheme)
        case .needsAttention: ClaudioColor.error(colorScheme)
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
        case .audible: ClaudioColor.success(colorScheme)
        case .missingSound, .degraded: ClaudioColor.error(colorScheme)
        case .muted, .notConnected, .awaitingActivation, .legacy, .unsupported:
            ClaudioColor.textSecondary(colorScheme)
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
        case .success: ClaudioColor.success(colorScheme)
        case .information: ClaudioColor.clay(colorScheme)
        case .failure: ClaudioColor.error(colorScheme)
        }
    }
}
