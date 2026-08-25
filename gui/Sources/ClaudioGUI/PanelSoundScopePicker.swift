import AppKit
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// 面板专属的声音作用域选择器。它只消费纯 presentation 与选择回调，不读取宿主配置、
/// 不判断回执，也不直接写声音配置。
@MainActor
struct PanelSoundScopePicker: View {
    let scopes: [PanelSoundScopePresentation]
    let selectedScope: PanelSoundScopePresentation
    let typeScale: CGFloat
    let language: ClaudioAppLanguage
    @Binding var isExpanded: Bool
    let focusedTarget: FocusState<PanelFocusTarget?>.Binding
    let onSelect: (PanelSoundScopeID) -> Void
    let onManageIntegrations: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedMenuTarget: PanelSoundScopePickerFocusTarget?
    @State private var hoveredScope: PanelSoundScopeID?
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
                    protectedOverflowHeight: menuHeight + 5,
                    onOutsideClick: { dismissMenu(returnFocus: false) }))
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
            dismissMenu(returnFocus: false)
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
                .font(.system(size: 11 * typeScale, weight: .semibold, design: .rounded))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            Spacer(minLength: 4)
            Text(l10n.text(.panelSoundScopeInheritanceCaption))
                .font(.system(size: 8.5 * typeScale, weight: .medium, design: .rounded))
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
                    .font(.system(size: 10 * typeScale, weight: .semibold))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(
                maxWidth: .infinity,
                minHeight: max(50, 50 * typeScale),
                alignment: .leading
            )
            .contentShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.section))
            .background(
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.section)
                    .fill(
                        isExpanded || triggerHovered
                            ? ClaudioTheme.elevated(colorScheme)
                            : ClaudioTheme.elevated(colorScheme).opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.section)
                    .strokeBorder(
                        isExpanded
                            ? ClaudioColor.hairlineStrong(colorScheme)
                            : ClaudioTheme.hairline(colorScheme),
                        lineWidth: isExpanded ? 1.5 : 1))
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

    private var menu: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: scopes.count > 4) {
                VStack(spacing: 3) {
                    ForEach(scopes) { scope in
                        scopeOption(scope)
                    }
                }
            }
            .frame(height: menuOptionsHeight)

            Divider()
                .padding(.vertical, 4)

            Button {
                dismissMenu(returnFocus: true)
                onManageIntegrations()
            } label: {
                Label(l10n.text(.panelConnectionsDiagnostics), systemImage: "stethoscope")
                    .font(.system(size: 10.5 * typeScale, weight: .medium, design: .rounded))
                    .foregroundColor(ClaudioTheme.text(colorScheme))
                    .frame(maxWidth: .infinity, minHeight: diagnosticsHeight, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focusedMenuTarget, equals: .integrations)
            .accessibilityLabel(l10n.text(.panelConnectionsDiagnostics))
            .accessibilityIdentifier("panel.sound-scope.integrations")
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(ClaudioTheme.surface(colorScheme))
        .overlay(
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.section)
                .strokeBorder(ClaudioColor.hairlineStrong(colorScheme), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.section))
        .shadow(
            color: ClaudioTheme.text(colorScheme).opacity(colorScheme == .dark ? 0.26 : 0.12),
            radius: 12,
            y: 6
        )
        .onMoveCommand(perform: moveMenuFocus)
        .onExitCommand { dismissMenu(returnFocus: true) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l10n.text(.panelSoundScope))
    }

    private func scopeOption(_ scope: PanelSoundScopePresentation) -> some View {
        let selected = scope.scope == selectedScope.scope
        let hovered = hoveredScope == scope.scope
        let target = PanelSoundScopePickerFocusTarget.scope(scope.scope)
        return Button {
            onSelect(scope.scope)
            dismissMenu(returnFocus: true)
        } label: {
            HStack(spacing: 9) {
                scopeIdentity(scope, prominent: false)
                Spacer(minLength: 8)
                statusBadge(scope)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: optionHeight, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control))
            .background(
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control)
                    .fill(selected || hovered ? ClaudioTheme.elevated(colorScheme) : .clear))
        }
        .buttonStyle(.plain)
        .focused($focusedMenuTarget, equals: target)
        .onHover { inside in hoveredScope = inside ? scope.scope : nil }
        .accessibilityLabel(scope.accessibilityLabel)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("panel.sound-scope.item.\(scope.scope.storedValue)")
    }

    private func scopeIdentity(
        _ scope: PanelSoundScopePresentation,
        prominent: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: prominent ? 3 : 2) {
            Text(scope.name)
                .font(
                    .system(
                        size: (prominent ? 13.5 : 11.5) * typeScale,
                        weight: .semibold,
                        design: .rounded)
                )
                .foregroundColor(ClaudioTheme.text(colorScheme))
                .lineLimit(1)
            Text(scope.summaryText)
                .font(
                    .system(
                        size: (prominent ? 10.5 : 9.5) * typeScale,
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
                .font(.system(size: 13 * typeScale, weight: .semibold))
                .accessibilityHidden(true)
            Text(scope.stateText)
                .font(.system(size: 10.5 * typeScale, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundColor(statusColor(scope.status))
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

    private var optionHeight: CGFloat { max(46, 46 * typeScale) }
    private var diagnosticsHeight: CGFloat { max(34, 34 * typeScale) }
    private var menuOptionsHeight: CGFloat {
        let content = CGFloat(scopes.count) * optionHeight + CGFloat(max(0, scopes.count - 1)) * 3
        return min(content, 250 * max(1, typeScale) - diagnosticsHeight - 21)
    }
    private var menuHeight: CGFloat { menuOptionsHeight + diagnosticsHeight + 21 }

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

    private func dismissMenu(returnFocus: Bool) {
        guard isExpanded else { return }
        isExpanded = false
        focusedMenuTarget = nil
        if returnFocus {
            DispatchQueue.main.async { focusedTarget.wrappedValue = .soundScope }
        }
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
