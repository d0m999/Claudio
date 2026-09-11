import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// 面板专属的声音作用域选择器。它只消费纯 presentation 与选择回调，不读取宿主配置、
/// 不判断回执，也不直接写声音配置。异常状态行的行内状态动作只把宿主身份经
/// `onOpenIntegration` 上抛，由 MenuBarController 提交既有 typed route。
@MainActor
struct PanelSoundScopePicker: View {
    let scopes: [PanelSoundScopePresentation]
    let selectedScope: PanelSoundScopePresentation
    let language: ClaudioAppLanguage
    let availableMenuHeight: CGFloat
    @Binding var isExpanded: Bool
    let focusedTarget: FocusState<PanelFocusTarget?>.Binding
    let onSelect: (PanelSoundScopeID) -> Void
    let onOpenIntegration: (HostID) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedMenuTarget: PanelSoundScopePickerFocusTarget?
    @State private var hoveredScope: PanelSoundScopeID?
    @State private var hoveredIntegrationAction: PanelSoundScopeID?
    @State private var triggerHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            heading
            VStack(spacing: 0) {
                trigger
                if isExpanded {
                    menu
                        .padding(.top, 5)
                        .frame(height: 0, alignment: .top)
                        .zIndex(2)
                }
            }
            .background(
                PanelSoundScopeOutsideClickMonitor(
                    isActive: isExpanded,
                    protectedOverflowHeight: CGFloat(menuLayout.totalHeight) + 5,
                    onOutsideClick: dismissMenuAndRestoreTriggerFocus))
        }
        .zIndex(isExpanded ? 100 : 0)
        .onChange(of: isExpanded) { expanded in
            if expanded {
                focusSelectedMenuItem()
            } else {
                focusedMenuTarget = nil
            }
        }
        .onChange(of: focusedMenuTarget) { target in
            guard isExpanded, target == nil, focusedTarget.wrappedValue != .soundScope else {
                return
            }
            dismissMenuAndRestoreTriggerFocus()
        }
        .onDisappear {
            isExpanded = false
            focusedMenuTarget = nil
        }
        .accessibilityElement(children: .contain)
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(l10n.text(.panelSoundScope))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            Spacer(minLength: 4)
            Text(l10n.text(.panelSoundScopeInheritanceCaption))
                .font(.system(size: 8.5, weight: .medium, design: .rounded))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var trigger: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 9) {
                scopeIdentity(selectedScope, prominent: true)
                Spacer(minLength: 8)
                statusBadge(selectedScope)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(
                maxWidth: .infinity,
                minHeight: 50,
                alignment: .leading
            )
            .contentShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.section))
            .background(
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.section)
                    .fill(
                        triggerHighlighted
                            ? ClaudioTheme.claySoft(colorScheme)
                            : ClaudioTheme.surface(colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.section)
                    .strokeBorder(
                        triggerHighlighted
                            ? ClaudioTheme.clay(colorScheme)
                            : ClaudioTheme.hairline(colorScheme),
                        lineWidth: triggerHighlighted ? 1.5 : 1)
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: triggerHighlighted)
        }
        .buttonStyle(.plain)
        .focused(focusedTarget, equals: .soundScope)
        .onHover { triggerHovered = $0 }
        .accessibilityLabel(l10n.text(.panelSoundScope))
        .accessibilityValue(selectedScope.accessibilityLabel)
        .accessibilityHint(
            l10n.text(isExpanded ? .panelSoundScopeCollapseHint : .panelSoundScopeExpandHint)
        )
        .accessibilityIdentifier("panel.sound-scope")
    }

    private var triggerHighlighted: Bool {
        isExpanded || triggerHovered || focusedTarget.wrappedValue == .soundScope
    }

    private var menu: some View {
        VStack(spacing: 0) {
            ScrollView(
                .vertical,
                showsIndicators: menuLayout.optionsHeight < menuLayout.optionsContentHeight
            ) {
                VStack(spacing: 3) {
                    ForEach(scopes) { scope in
                        scopeOption(scope)
                    }
                }
            }
            .frame(height: CGFloat(menuLayout.optionsHeight))

        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .frame(height: CGFloat(menuLayout.totalHeight), alignment: .top)
        .clipped()
        .background(ClaudioTheme.surface(colorScheme))
        .overlay(
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.section)
                .strokeBorder(
                    ClaudioTheme.hairline(colorScheme),
                    lineWidth: ClaudioTheme.Metrics.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.section))
        .shadow(
            color: ClaudioTheme.text(colorScheme).opacity(colorScheme == .dark ? 0.26 : 0.12),
            radius: 12,
            y: 6
        )
        .onMoveCommand(perform: moveMenuFocus)
        .onExitCommand(perform: dismissMenuAndRestoreTriggerFocus)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l10n.text(.panelSoundScope))
    }

    private func scopeOption(_ scope: PanelSoundScopePresentation) -> some View {
        let selected = scope.scope == selectedScope.scope
        // 行级 hover：选择按钮与行内胶囊之间的间距、以及胶囊本身，都属于这行被绘制的区域。
        let hovered =
            hoveredScope == scope.scope || hoveredIntegrationAction == scope.scope
        let target = PanelSoundScopePickerFocusTarget.scope(scope.scope)
        let focused = focusedMenuTarget == target
        return HStack(spacing: 4) {
            Button {
                onSelect(scope.scope)
                dismissMenuAndRestoreTriggerFocus()
            } label: {
                HStack(spacing: 9) {
                    scopeIdentity(scope, prominent: false)
                    Spacer(minLength: 8)
                    if panelSoundScopeIntegrationActionHost(scope) == nil {
                        statusBadge(scope)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(
                    maxWidth: .infinity,
                    minHeight: CGFloat(menuLayout.optionHeight),
                    alignment: .leading
                )
                .contentShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control))
            }
            .buttonStyle(.plain)
            .focused($focusedMenuTarget, equals: target)
            .accessibilityLabel(scope.accessibilityLabel)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityIdentifier("panel.sound-scope.item.\(scope.scope.storedValue)")

            if let actionHost = panelSoundScopeIntegrationActionHost(scope) {
                integrationActionButton(scope, host: actionHost)
            }
        }
        // 行高/行宽的唯一来源是上方按钮 label 的 frame（它同时承重点击热区），这里不再重复约束。
        // 描边收进 .background 的 ZStack，让选择与行内动作共享一张完整行面；行内胶囊另在
        // 自身尾部留出几何间距，避免它的描边与这里的行尾描边占用同一像素。
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control)
                    .fill(
                        selected
                            ? ClaudioTheme.claySoft(colorScheme)
                            : hovered || focused
                                ? ClaudioTheme.elevated(colorScheme)
                                : .clear)
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control)
                    .strokeBorder(
                        selected
                            ? ClaudioTheme.clay(colorScheme)
                            : hovered || focused
                                ? ClaudioTheme.hairline(colorScheme)
                                : .clear,
                        lineWidth: ClaudioTheme.Metrics.hairline)
            }
        )
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.12),
            value: selected || hovered || focused
        )
        .onHover { inside in hoveredScope = inside ? scope.scope : nil }
    }

    /// 行内状态动作：异常状态行的状态徽标成为独立按钮（描边胶囊 + ›），点击只把宿主身份
    /// 经 `onOpenIntegration` 上抛——不改变当前选中作用域，也不在菜单内复制任何修复动作。
    /// 命中目标 29pt 高于紧凑控件 token 28pt，是 DESIGN.md 行内动作合同的显式要求。
    /// 静止填充跟随所在行：选中行上胶囊保持透明描边（行级 claySoft 透出来），并从
    /// 行尾描边内收，避免两条描边相交；未选中行继续使用不透明 surface。
    private func integrationActionButton(
        _ scope: PanelSoundScopePresentation,
        host: HostID
    ) -> some View {
        let target = PanelSoundScopePickerFocusTarget.integrationAction(scope.scope)
        let focused = focusedMenuTarget == target
        let hovered = hoveredIntegrationAction == scope.scope
        let rowSelected = scope.scope == selectedScope.scope
        return Button {
            onOpenIntegration(host)
            dismissMenuAndRestoreTriggerFocus()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: statusSymbol(scope))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(statusColor(scope.status))
                    .accessibilityHidden(true)
                Text(scope.stateText)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundColor(ClaudioTheme.text(colorScheme))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 29)
            .contentShape(Capsule())
            .background(
                Capsule()
                    .fill(
                        hovered || focused
                            ? ClaudioTheme.elevated(colorScheme)
                            : rowSelected
                                ? .clear
                                : ClaudioTheme.surface(colorScheme))
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        hovered || focused
                            ? statusColor(scope.status)
                            : ClaudioTheme.hairline(colorScheme),
                        lineWidth: ClaudioTheme.Metrics.hairline)
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: hovered || focused)
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focusedMenuTarget, equals: .integrationAction(scope.scope))
        .onHover { inside in hoveredIntegrationAction = inside ? scope.scope : nil }
        .accessibilityLabel(
            panelSoundScopeIntegrationActionLabel(name: scope.name, language: language)
        )
        .accessibilityIdentifier("panel.sound-scope.integration-action.\(scope.scope.storedValue)")
        .padding(.trailing, 4)
    }

    private func scopeIdentity(
        _ scope: PanelSoundScopePresentation,
        prominent: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: prominent ? 3 : 2) {
            Text(scope.name)
                .font(
                    .system(
                        size: prominent ? 13.5 : 11.5,
                        weight: .semibold,
                        design: .rounded)
                )
                .foregroundColor(ClaudioTheme.text(colorScheme))
                .lineLimit(1)
            Text(scope.summaryText)
                .font(
                    .system(
                        size: prominent ? 10.5 : 9.5,
                        weight: .medium,
                        design: .rounded)
                )
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusBadge(_ scope: PanelSoundScopePresentation) -> some View {
        HStack(spacing: 5) {
            Image(systemName: statusSymbol(scope))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(statusColor(scope.status))
                .accessibilityHidden(true)
            Text(scope.stateText)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .lineLimit(1)
        }
        .fixedSize()
    }

    private func statusSymbol(_ scope: PanelSoundScopePresentation) -> String {
        if scope.scope == .global { return "checkmark.circle.fill" }
        return switch scope.status {
        case .ready: "checkmark.circle.fill"
        case .awaitingActivation: "exclamationmark.circle.fill"
        case .legacy: "arrow.triangle.2.circlepath.circle.fill"
        case .notConnected: "minus.circle"
        case .needsAttention: "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(_ status: HostSourceRowStatus) -> Color {
        switch status {
        case .ready: ClaudioTheme.success(colorScheme)
        case .awaitingActivation, .legacy: ClaudioColor.warning(colorScheme)
        case .notConnected: ClaudioTheme.secondaryText(colorScheme)
        case .needsAttention: ClaudioTheme.error(colorScheme)
        }
    }

    private var menuLayout: PanelSoundScopeMenuLayout {
        panelSoundScopeMenuLayout(
            scopeCount: scopes.count,
            typeScale: 1,
            availableHeight: Double(availableMenuHeight))
    }

    private var menuFocusOrder: [PanelSoundScopePickerFocusTarget] {
        panelSoundScopePickerFocusOrder(scopes: scopes.map(\.scope))
    }

    private func focusSelectedMenuItem() {
        let selected = PanelSoundScopePickerFocusTarget.scope(selectedScope.scope)
        DispatchQueue.main.async {
            focusedMenuTarget = menuFocusOrder.contains(selected) ? selected : menuFocusOrder.first
        }
    }

    private func moveMenuFocus(_ direction: MoveCommandDirection) {
        let delta: Int
        switch direction {
        case .down: delta = 1
        case .up: delta = -1
        default: return
        }
        guard !menuFocusOrder.isEmpty else { return }
        let currentIndex =
            focusedMenuTarget.flatMap(menuFocusOrder.firstIndex(of:))
            ?? (delta > 0 ? -1 : menuFocusOrder.count)
        let nextIndex = min(max(0, currentIndex + delta), menuFocusOrder.count - 1)
        focusedMenuTarget = menuFocusOrder[nextIndex]
    }

    private func dismissMenuAndRestoreTriggerFocus() {
        guard isExpanded else { return }
        isExpanded = false
        focusedMenuTarget = nil
        DispatchQueue.main.async { focusedTarget.wrappedValue = .soundScope }
    }

    private var l10n: ClaudioL10n { ClaudioL10n(language: language) }
}

private struct PanelSoundScopeOutsideClickMonitor: NSViewRepresentable {
    let isActive: Bool
    let protectedOverflowHeight: CGFloat
    let onOutsideClick: @MainActor () -> Void

    func makeNSView(context _: Context) -> PanelSoundScopeOutsideClickMonitorView {
        let view = PanelSoundScopeOutsideClickMonitorView()
        view.configure(
            isActive: isActive,
            protectedOverflowHeight: protectedOverflowHeight,
            onOutsideClick: onOutsideClick)
        return view
    }

    func updateNSView(
        _ nsView: PanelSoundScopeOutsideClickMonitorView,
        context _: Context
    ) {
        nsView.configure(
            isActive: isActive,
            protectedOverflowHeight: protectedOverflowHeight,
            onOutsideClick: onOutsideClick)
    }

    static func dismantleNSView(
        _ nsView: PanelSoundScopeOutsideClickMonitorView,
        coordinator _: ()
    ) {
        nsView.stopMonitoring()
    }
}

@MainActor
private final class PanelSoundScopeOutsideClickMonitorView: NSView {
    private var eventMonitor: Any?
    private var protectedOverflowHeight: CGFloat = 0
    private var onOutsideClick: (@MainActor () -> Void)?

    func configure(
        isActive: Bool,
        protectedOverflowHeight: CGFloat,
        onOutsideClick: @escaping @MainActor () -> Void
    ) {
        self.protectedOverflowHeight = protectedOverflowHeight
        self.onOutsideClick = onOutsideClick
        if isActive {
            startMonitoring()
        } else {
            stopMonitoring()
        }
    }

    func stopMonitoring() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    private func startMonitoring() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) {
            [weak self] event in
            let eventWindowID = event.window.map({ ObjectIdentifier($0) })
            let eventLocation = event.locationInWindow
            MainActor.assumeIsolated { [weak self] in
                guard let self,
                    self.window.map({ ObjectIdentifier($0) }) == eventWindowID
                else { return }
                let location = self.convert(eventLocation, from: nil)
                let pickerBounds = self.bounds.insetBy(dx: -2, dy: -2)
                let menuBounds = CGRect(
                    x: self.bounds.minX - 2,
                    y: self.bounds.minY - self.protectedOverflowHeight - 2,
                    width: self.bounds.width + 4,
                    height: self.protectedOverflowHeight + 4)
                guard !pickerBounds.union(menuBounds).contains(location) else { return }
                self.onOutsideClick?()
            }
            return event
        }
    }
}
