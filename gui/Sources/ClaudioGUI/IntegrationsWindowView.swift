import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import SwiftUI

/// Retained standard-window surface for capability comparison, diagnosis and in-place recovery.
/// The window consumes manager-owned presentation facts and never parses host files itself.
@MainActor
struct IntegrationsWindowView: View {
    @ObservedObject var model: IntegrationsWindowModel
    @ObservedObject var focusCoordinator: IntegrationsWindowFocusCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ClaudioInterfaceTextSize.defaultsKey)
    private var interfaceTextSizeRaw = ClaudioInterfaceTextSize.defaultValue.rawValue
    @FocusState private var focusedTarget: IntegrationsWindowFocusTarget?
    @State private var handledFocusRequestRevision = 0
    @State private var feedbackAnnouncer = IntegrationsFeedbackAnnouncementModel()
    @State private var pendingDisconnectHost: HostID?

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
                    stackedContent
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
                    Label("重新检测", systemImage: "arrow.clockwise")
                }
                .disabled(model.isPerformingAction)
                .accessibilityLabel("重新检测两个声音来源")
                .accessibilityHint("只重新读取连接、能力和真实回执，不修改配置")
                .accessibilityIdentifier("integrations.redetect")
            }
        }
        .confirmationDialog(
            pendingDisconnectHost.map { "断开 \($0.displayName)？" } ?? "断开声音来源？",
            isPresented: Binding(
                get: { pendingDisconnectHost != nil },
                set: { if !$0 { pendingDisconnectHost = nil } }),
            titleVisibility: .visible,
            presenting: pendingDisconnectHost
        ) { host in
            Button("断开 \(host.displayName)", role: .destructive) {
                pendingDisconnectHost = nil
                perform(.disconnect(host))
            }
            .accessibilityLabel("确认断开 \(host.displayName)")
            .accessibilityHint("只移除这个宿主的 claudi0 连接")
            .accessibilityIdentifier("integrations.confirm-disconnect.\(host.rawValue)")
            Button("取消", role: .cancel) {
                pendingDisconnectHost = nil
            }
            .accessibilityLabel("取消断开 \(host.displayName)")
            .accessibilityIdentifier("integrations.cancel-disconnect.\(host.rawValue)")
        } message: { host in
            Text("只移除 \(host.displayName) 的 claudi0 连接；另一个宿主、声音包和静音设置不会改变。")
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
        HStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                capabilitySection.padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                inspectorSection.padding(20)
            }
            .frame(width: max(300, width * 0.39))
            .frame(maxHeight: .infinity)
        }
    }

    private var stackedContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                capabilitySection
                Divider()
                inspectorSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private var sourceSummary: some View {
        HStack(spacing: 10) {
            ForEach(model.content.sourceRows) { row in
                sourceSummaryButton(row)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("声音来源摘要")
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
                            Text(operation.statusText)
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
                    : Color.clear)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(
                        model.selection.host == row.host
                            ? ClaudioTheme.clay(colorScheme)
                            : ClaudioTheme.hairline(colorScheme))
                    .frame(height: model.selection.host == row.host ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .focused($focusedTarget, equals: .hostCard(row.host))
        .accessibilityLabel(sourceRowAccessibilityLabel(row))
        .accessibilityValue(model.selection == selection ? "已选择" : "未选择")
        .accessibilityHint("选择后查看这个宿主的配置证据与连接操作")
        .accessibilityAddTraits(model.selection == selection ? .isSelected : [])
        .accessibilityIdentifier("integrations.host.\(row.host.rawValue)")
    }

    private var selectionSummary: some View {
        HStack(spacing: 8) {
            Image(systemName: "scope")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(model.inspector?.title ?? "选择一个声音来源或能力")
                .font(ClaudioTheme.font(.secondary).weight(.semibold))
                .lineLimit(interfaceTextSize == .maximum ? 3 : 1)
            Spacer(minLength: 8)
            if let text = model.inspector?.connectionText {
                ClaudioStatusCapsule(text, isEmphasized: false)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "当前选择，\(model.inspector?.accessibilityLabel ?? "尚未选择")")
    }

    @ViewBuilder
    private var capabilitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("可听能力")
                .font(ClaudioTheme.font(.sectionTitle))
                .accessibilityAddTraits(.isHeader)
            if usesNarrowCapabilityTable {
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
                    Text("事件")
                        .frame(width: 118, alignment: .leading)
                    ForEach(model.content.matrix.hostColumns, id: \.self) { host in
                        Text(host.displayName)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(ClaudioTheme.font(.caption).weight(.semibold))
                .foregroundStyle(.secondary)
                Divider().gridCellColumns(3)
                ForEach(model.content.matrix.rows) { row in
                    GridRow {
                        eventIdentity(row.event, title: row.title)
                            .frame(width: 118, alignment: .leading)
                            .padding(.vertical, 9)
                        ForEach(row.cells) { cell in
                            capabilityCellButton(cell, showsHostName: false)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Divider().gridCellColumns(3)
                }
            }
        } else {
            legacyCapabilityMatrix
        }
    }

    private var legacyCapabilityMatrix: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("事件").frame(width: 118, alignment: .leading)
                ForEach(model.content.matrix.hostColumns, id: \.self) { host in
                    Text(host.displayName).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(ClaudioTheme.font(.caption).weight(.semibold))
            .foregroundStyle(.secondary)
            Divider()
            ForEach(model.content.matrix.rows) { row in
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
            ForEach(model.content.matrix.rows) { row in
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
        .accessibilityValue(model.selection == selection ? "已选择" : "未选择")
        .accessibilityHint("选择后查看证据和当前状态对应的恢复动作")
        .accessibilityAddTraits(model.selection == selection ? .isSelected : [])
        .accessibilityIdentifier(
            "integrations.capability.\(cell.host.rawValue).\(cell.event.rawValue)")
    }

    @ViewBuilder
    private var inspectorSection: some View {
        if let inspector = model.inspector {
            VStack(alignment: .leading, spacing: 13) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("检查器")
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
                    evidenceRow(label: "连接状态", value: inspector.connectionText)
                    configurationEvidenceRow(inspector)
                    evidenceRow(label: "原生事件", value: inspector.nativeEventText ?? "选择一个事件查看")
                    evidenceRow(
                        label: "最近真实回执",
                        value: inspector.latestReceiptText ?? "暂无当前安装代次的真实回执")
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
                .font(label == "原生事件" ? ClaudioTheme.font(.technical) : ClaudioTheme.font(.caption))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)，\(value)")
    }

    private func configurationEvidenceRow(
        _ inspector: IntegrationsWindowInspectorPresentation
    ) -> some View {
        let fullPath = inspector.configurationSource
        let shortPath = abbreviatedConfigurationPath(fullPath)
        return VStack(alignment: .leading, spacing: 3) {
            Text("配置来源")
                .font(ClaudioTheme.font(.caption))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(shortPath)
                    .font(ClaudioTheme.font(.technical))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .help(fullPath)
                    .accessibilityLabel("配置来源")
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
                .accessibilityLabel("复制 \(inspector.host.displayName) 配置路径")
                .accessibilityValue(fullPath)
                .accessibilityHint("把完整路径复制到剪贴板")
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
            Text("主音量为零；请在菜单栏面板中调高主音量后再试。")
                .font(ClaudioTheme.font(.secondary))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("integrations.recovery.master-volume-zero")
        case .explainUnsupported(_, let event):
            Text("\(event.displayName) 不是这个宿主支持的能力；这不是连接错误，无需修复。")
                .font(ClaudioTheme.font(.secondary))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("integrations.recovery.explanation")
        default:
            recoveryButton(primaryRecoveryAction)
        }
    }

    private func recoveryButton(_ action: IntegrationsRecoveryAction) -> some View {
        Button(action.title ?? "恢复") {
            performRecovery(action)
        }
        .buttonStyle(.borderedProminent)
        .tint(ClaudioTheme.clay(colorScheme))
        .frame(maxWidth: .infinity, minHeight: ClaudioTheme.Metrics.regularControlHeight)
        .disabled(model.isPerformingAction)
        .focused($focusedTarget, equals: .recoveryAction(action))
        .accessibilityLabel(action.title ?? "恢复当前能力")
        .accessibilityHint(recoveryAccessibilityHint(action))
        .accessibilityIdentifier("integrations.recovery.primary")
    }

    private func feedbackRow(_ feedback: IntegrationsFeedback) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: feedbackSymbol(feedback.kind))
                .foregroundColor(feedbackColor(feedback.kind))
                .accessibilityHidden(true)
            Text(feedback.message)
                .font(ClaudioTheme.font(.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(feedback.accessibilityLabel)
            Button {
                model.dismissFeedback(revision: feedback.revision)
            } label: {
                Image(systemName: "xmark")
                    .frame(minWidth: ClaudioTheme.Metrics.iconTarget, minHeight: ClaudioTheme.Metrics.iconTarget)
            }
            .buttonStyle(.plain)
            .focused($focusedTarget, equals: .dismissFeedback(revision: feedback.revision))
            .accessibilityLabel("关闭状态反馈")
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
            Button("断开 \(host.displayName)", role: .destructive) {
                pendingDisconnectHost = host
            }
            .frame(maxWidth: .infinity, minHeight: ClaudioTheme.Metrics.regularControlHeight)
            .focused($focusedTarget, equals: .inspectorAction(action))
            .disabled(model.isPerformingAction)
            .accessibilityHint("会先确认；只移除这个宿主的 claudi0 连接")
            .accessibilityIdentifier("integrations.disconnect.\(host.rawValue)")
        default:
            Button(integrationsInspectorActionTitle(action, hostStatus: selectedHostStatus)) {
                perform(action)
            }
            .frame(maxWidth: .infinity, minHeight: ClaudioTheme.Metrics.regularControlHeight)
            .focused($focusedTarget, equals: .inspectorAction(action))
            .disabled(model.isPerformingAction)
            .accessibilityLabel(integrationsInspectorActionTitle(action, hostStatus: selectedHostStatus))
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
            inspectorActions: visibleInspectorActions,
            recoveryAction: primaryRecoveryAction,
            configurationPathHost: model.inspector?.host,
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
        if case .disconnect = action { return true }
        return false
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

    private var layoutAdaptation: IntegrationsWindowLayoutAdaptation {
        integrationsWindowLayoutAdaptation(for: typeSizeTier)
    }

    private var usesNarrowCapabilityTable: Bool {
        if case .eventCards = layoutAdaptation.mode { return true }
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
        case .opacity: .easeOut(duration: 0.16)
        case .immediate: nil
        }
    }

    private func recoveryAccessibilityHint(_ action: IntegrationsRecoveryAction) -> String {
        switch action {
        case .unmute: "只取消当前事件静音；不会改变声音映射"
        case .explainMasterVolumeZero: "请在菜单栏面板中调高主音量"
        case .configureSound: "打开声音包窗口并定位到当前事件"
        case .connect: "连接当前宿主"
        case .upgrade: "把旧版连接升级到当前格式"
        case .repair: "修复当前宿主的 claudi0 连接"
        case .redetect: "重新读取当前连接状态"
        case .explainUnsupported, .none: ""
        }
    }

    private func inspectorActionAccessibilityHint(
        _ action: IntegrationsWindowInspectorAction
    ) -> String {
        switch action {
        case .copyHooksCommand: "把 /hooks 复制到剪贴板，以便在 Codex 中完成授权"
        case .connect: "连接这个宿主"
        case .repair: "修复或升级这个宿主的连接"
        case .redetect: "重新读取连接状态"
        case .disconnect: "会先显示影响范围确认"
        }
    }

    private func actionIdentifier(_ action: IntegrationsWindowInspectorAction) -> String {
        switch action {
        case .copyHooksCommand: "copy-hooks"
        case .redetect: "redetect"
        case .connect(let host): "connect.\(host.rawValue)"
        case .repair(let host): "repair.\(host.rawValue)"
        case .disconnect(let host): "disconnect.\(host.rawValue)"
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
        case .ready: ClaudioTheme.success(colorScheme)
        case .awaitingActivation, .legacy, .notConnected: ClaudioTheme.secondaryText(colorScheme)
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
