import AppKit
import ClaudioGUIComponents
import ClaudioGUICore
import Combine
import Foundation
import SwiftUI

/// Native hit-target regression coverage for the shared full-row and compact control contracts.
/// The production `ClaudioGUI` target is an executable and cannot be imported here, so the suite
/// tests the public component styles through real SwiftUI buttons hosted in AppKit, while the
/// final source assertions bind those contracts to the production call sites.
@MainActor
func runHitTargetSuites() {
    suite("Claudio icon action：语义 radius 与交互状态优先级") {
        expect(ClaudioTheme.Radius.panel == 18, "panel radius 必须为 18")
        expect(ClaudioTheme.Radius.row == 13, "row radius 必须为 13")
        expect(ClaudioTheme.Radius.section == 13, "section 兼容别名必须保持 13")
        expect(ClaudioTheme.Radius.tile == 11, "tile radius 必须为 11")
        expect(ClaudioTheme.Radius.control == 6, "control radius 必须为 6")
        expect(ClaudioTheme.Radius.chip == 6, "chip radius 必须为 6")

        expect(
            ClaudioIconButtonInteractionState(
                isEnabled: true,
                isHovered: false,
                isFocused: false,
                isPressed: false) == .rest,
            "无交互输入必须解析为 rest")
        expect(
            ClaudioIconButtonInteractionState(
                isEnabled: true,
                isHovered: true,
                isFocused: false,
                isPressed: false) == .hovered,
            "hover 必须解析为 hovered")
        expect(
            ClaudioIconButtonInteractionState(
                isEnabled: true,
                isHovered: true,
                isFocused: true,
                isPressed: false) == .focused,
            "focus 必须覆盖 hover，以保留键盘焦点语义")
        expect(
            ClaudioIconButtonInteractionState(
                isEnabled: true,
                isHovered: true,
                isFocused: true,
                isPressed: true) == .pressed,
            "pressed 必须覆盖 focus/hover")
        expect(
            ClaudioIconButtonInteractionState(
                isEnabled: false,
                isHovered: true,
                isFocused: true,
                isPressed: true) == .disabled,
            "disabled 必须覆盖全部瞬时交互状态")
    }

    suite("Claudio icon action：Reduce Motion 只移除几何与补间反馈") {
        let hovered = ClaudioIconButtonInteractionState.hovered
        let pressed = ClaudioIconButtonInteractionState.pressed
        let disabled = ClaudioIconButtonInteractionState.disabled

        expect(hovered.transitionDuration(reduceMotion: false) == 0.12, "hover 应使用 120ms")
        expect(pressed.transitionDuration(reduceMotion: false) == 0.10, "pressed 应使用 100ms")
        expect(pressed.scale(reduceMotion: false) == 0.96, "pressed 应缩放到 0.96")
        expect(pressed.scale(reduceMotion: true) == 1, "Reduce Motion 下不得缩放")
        expect(
            hovered.transitionDuration(reduceMotion: true) == nil,
            "Reduce Motion 下颜色状态必须瞬时切换")
        expect(
            disabled.transitionDuration(reduceMotion: false) == nil,
            "disabled 不得保留误导性的交互动效")
    }

    suite("Claudio preview pulse：仅播放成功后提供一次 220ms 几何反馈") {
        expect(ClaudioPreviewPulseMotion.peakScale == 1.12, "试听 pulse 峰值必须为 1.12")
        expect(
            ClaudioPreviewPulseMotion.halfDuration == 0.11
                && ClaudioPreviewPulseMotion.totalDuration == 0.22,
            "试听 pulse 必须在 220ms 内完成放大与回落")
        expect(
            ClaudioPreviewPulseMotion.scale(isAtPeak: true, reduceMotion: false) == 1.12,
            "正常动效环境必须渲染 pulse 峰值")
        expect(
            ClaudioPreviewPulseMotion.scale(isAtPeak: true, reduceMotion: true) == 1,
            "Reduce Motion 下试听成功不得产生几何缩放")
        expect(
            ClaudioPreviewPulseMotion.scale(isAtPeak: false, reduceMotion: false) == 1,
            "pulse 完成后必须回到稳定比例")
    }

    suite("ClaudioFullRowButtonStyle：选中与未选中透明行的整行命中") {
        let recorder = HitTargetRecorder()
        let probe = NativeHitTargetProbe(
            rootView: ScopeRowsFixture(recorder: recorder),
            size: CGSize(width: 280, height: 150))
        defer { probe.close() }

        for x in [15.0, 140.0, 268.0] {
            expect(
                probe.click(x: x, yFromTop: 24),
                "选中 Global 行的前部、中部和尾部都必须能合成点击")
        }
        expect(
            recorder.actions == ["global", "global", "global"],
            "选中行的三个位置都只能触发 Global，实得 \(recorder.actions)")

        recorder.reset()
        for x in [15.0, 140.0, 268.0] {
            expect(
                probe.click(x: x, yFromTop: 56),
                "未选中透明 Codex 行的前部、中部和尾部都必须能合成点击")
        }
        expect(
            recorder.actions == ["codex", "codex", "codex"],
            "未选中透明行的三个位置都只能触发 Codex，实得 \(recorder.actions)")
    }

    suite("Sound Scope 行：行外、相邻行空隙和禁用行保持隔离") {
        let recorder = HitTargetRecorder()
        let probe = NativeHitTargetProbe(
            rootView: ScopeRowsFixture(recorder: recorder),
            size: CGSize(width: 280, height: 150))
        defer { probe.close() }

        expect(probe.click(x: 15, yFromTop: 41), "相邻作用域间隙不是 Sound Scope 选择按钮")
        expect(probe.click(x: 278, yFromTop: 56), "条目外部空白不能命中相邻 Sound Scope")
        expect(
            recorder.actions.isEmpty,
            "间隙和行外点击都不能切换作用域，实得 \(recorder.actions)")

        expect(probe.click(x: 15, yFromTop: 56), "相邻 Codex 行应只命中自身")
        expect(
            recorder.actions == ["codex"],
            "点击相邻行不能误触发 Global，实得 \(recorder.actions)")

        recorder.reset()
        for x in [15.0, 140.0, 268.0] {
            expect(probe.click(x: x, yFromTop: 90), "禁用 WorkBuddy 行仍应可命中但不可执行")
        }
        expect(
            recorder.actions.isEmpty,
            "禁用行不得执行选择动作，实得 \(recorder.actions)")
    }

    suite("复合行与紧凑控件：尾部动作不连带整行选择，28pt 边界可点击") {
        let compoundRecorder = HitTargetRecorder()
        let compoundProbe = NativeHitTargetProbe(
            rootView: CompoundRowFixture(recorder: compoundRecorder),
            size: CGSize(width: 280, height: 48))
        defer { compoundProbe.close() }

        expect(compoundProbe.click(x: 260, yFromTop: 24), "复合行尾部独立控件应能命中")
        expect(
            compoundRecorder.actions == ["tail"],
            "尾部控件只能执行自身动作，不得连带选择，实得 \(compoundRecorder.actions)")
        expect(compoundProbe.click(x: 100, yFromTop: 24), "复合行主体应能命中整行按钮")
        expect(
            compoundRecorder.actions == ["tail", "row"],
            "主体与尾部动作必须保持独立，实得 \(compoundRecorder.actions)")

        let targetRecorder = HitTargetRecorder()
        let targetProbe = NativeHitTargetProbe(
            rootView: CompactTargetsFixture(recorder: targetRecorder),
            size: CGSize(width: 160, height: 48))
        defer { targetProbe.close() }

        expect(targetProbe.click(x: 36, yFromTop: 36), "28×28 图标按钮的右下边界应可点击")
        expect(targetProbe.click(x: 76, yFromTop: 36), "28pt 紧凑纯文本动作的边界应可点击")
        expect(
            targetRecorder.actions == ["icon", "compact"],
            "图标与紧凑动作都只能触发自身，实得 \(targetRecorder.actions)")

        let disabledRecorder = HitTargetRecorder()
        let disabledProbe = NativeHitTargetProbe(
            rootView: DisabledIconTargetFixture(recorder: disabledRecorder),
            size: CGSize(width: 48, height: 48))
        defer { disabledProbe.close() }

        expect(disabledProbe.click(x: 24, yFromTop: 24), "禁用 icon action 的命中路由不应崩溃")
        expect(disabledRecorder.actions.isEmpty, "禁用 icon action 不得执行动作")
    }

    suite("Sound Scope 共享控件：真实挂载验证行级 pressed owner 与条件动作清理") {
        let model = SoundScopeControlsNativeModel()
        let recorder = SoundScopeControlsNativeRecorder()
        let probe = NativeHitTargetProbe(
            rootView: SoundScopeControlsNativeFixture(model: model, recorder: recorder),
            size: CGSize(width: 240, height: 110))
        defer { probe.close() }

        model.integrationActionHovered = true
        probe.settle()
        expect(
            recorder.state(for: "integration")?.actionHovered == true,
            "共享行 owner 必须接受当前条件动作的 hover Binding")
        expect(
            recorder.state(for: "scope")?.scopeHovered == false
                && recorder.state(for: "scope")?.actionHovered == false,
            "第一行动作 hover 不得污染相邻行的瞬时状态")

        expect(probe.mouseDown(x: 120, yFromTop: 26), "应能在第一行保持 mouse-down")
        probe.settle()
        expect(
            recorder.state(for: "integration")?.isPressed == true,
            "共享 ButtonStyle 必须把 native pressed 上报到所在行 owner")
        expect(
            recorder.state(for: "scope")?.isPressed == false,
            "第一行 pressed 不得触发整个 picker 或相邻行状态")
        expect(probe.mouseUp(x: 120, yFromTop: 26), "应能完成第一行 mouse-up")
        probe.settle(for: 0.13)

        model.hasIntegrationAction = false
        probe.settle()
        model.integrationActionHovered = false
        probe.settle()
        model.hasIntegrationAction = true
        probe.settle()
        expect(
            recorder.state(for: "integration")?.actionHovered == false,
            "条件胶囊卸载再恢复时不得复活陈旧 action hover")
    }

    suite("生产接线：声音包与 onboarding 使用显式命中合同") {
        let packGallery = productionSource("gui/Sources/ClaudioGUI/PackGalleryView.swift")
        let panelRows = productionSource("gui/Sources/ClaudioGUI/PanelRows.swift")

        expect(
            packGallery?.contains(".buttonStyle(ClaudioFullRowButtonStyle())") == true,
            "可复用声音包整行按钮必须使用显式整行命中合同")
        expect(
            panelRows?.contains(".buttonStyle(ClaudioFullRowButtonStyle())") == true,
            "onboarding 可展开失败行必须使用至少 28pt 的共享整行合同")
    }
}

@MainActor
private final class HitTargetRecorder {
    private(set) var actions: [String] = []

    func record(_ action: String) {
        actions.append(action)
    }

    func reset() {
        actions.removeAll()
    }
}

/// A real AppKit event route around an `NSHostingView`; this intentionally does not call a Button's
/// action directly, because the regression is in SwiftUI/AppKit hit testing rather than in the
/// closure itself.
@MainActor
private final class NativeHitTargetProbe<Content: View> {
    private let window: NSWindow
    private let hostingView: NSHostingView<Content>
    private let size: CGSize
    private var eventNumber = 1

    init(rootView: Content, size: CGSize) {
        self.size = size
        _ = NSApplication.shared

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)
        window.contentView = hostingView
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = false
        window.orderFrontRegardless()

        self.window = window
        self.hostingView = hostingView
        settle()
    }

    func click(x: CGFloat, yFromTop: CGFloat) -> Bool {
        let location = NSPoint(x: x, y: size.height - yFromTop)
        guard
            let mouseDown = makeMouseEvent(type: .leftMouseDown, location: location),
            let mouseUp = makeMouseEvent(type: .leftMouseUp, location: location)
        else {
            return false
        }

        window.sendEvent(mouseDown)
        window.sendEvent(mouseUp)
        settle()
        return true
    }

    func mouseDown(x: CGFloat, yFromTop: CGFloat) -> Bool {
        let location = NSPoint(x: x, y: size.height - yFromTop)
        guard let event = makeMouseEvent(type: .leftMouseDown, location: location) else {
            return false
        }
        window.sendEvent(event)
        settle()
        return true
    }

    func mouseUp(x: CGFloat, yFromTop: CGFloat) -> Bool {
        let location = NSPoint(x: x, y: size.height - yFromTop)
        guard let event = makeMouseEvent(type: .leftMouseUp, location: location) else {
            return false
        }
        window.sendEvent(event)
        settle()
        return true
    }

    func settle(for duration: TimeInterval = 0.02) {
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: duration))
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }

    private func makeMouseEvent(type: NSEvent.EventType, location: NSPoint) -> NSEvent? {
        defer { eventNumber += 1 }
        return NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: 1,
            pressure: 1)
    }
}

@MainActor
private final class SoundScopeControlsNativeModel: ObservableObject {
    @Published var hasIntegrationAction = true
    @Published var integrationActionHovered = false
}

@MainActor
private final class SoundScopeControlsNativeRecorder {
    private var states: [String: PanelSoundScopeRowTransientState] = [:]

    func recordState(_ state: PanelSoundScopeRowTransientState, for row: String) {
        states[row] = state
    }

    func state(for row: String) -> PanelSoundScopeRowTransientState? {
        states[row]
    }
}

@MainActor
private struct SoundScopeControlsNativeFixture: View {
    @ObservedObject var model: SoundScopeControlsNativeModel
    let recorder: SoundScopeControlsNativeRecorder

    @StateObject private var actionCoordinator = PanelSoundScopeActionCoordinator()
    @FocusState private var focusedTarget: PanelSoundScopePickerFocusTarget?

    var body: some View {
        VStack(spacing: 8) {
            PanelSoundScopeRowInteractionContainer(
                hasAction: model.hasIntegrationAction
            ) { state, actionHovered in
                Group {
                    if model.hasIntegrationAction {
                        PanelSoundScopeSuccessfulActionButton(
                            action: {},
                            actionCoordinator: actionCoordinator,
                            reduceMotion: false,
                            focusedTarget: $focusedTarget,
                            target: .integrationAction(.global),
                            policy: .integrationAction,
                            onHover: { actionHovered.wrappedValue = $0 }
                        ) {
                            Text("Integration")
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .contentShape(Rectangle())
                        }
                        .onChange(of: model.integrationActionHovered) {
                            actionHovered.wrappedValue = $0
                        }
                    } else {
                        Color.clear.frame(height: 36)
                    }
                }
                .background(
                    SoundScopeTransientStateProbe(
                        row: "integration",
                        state: state,
                        recorder: recorder))
            }

            PanelSoundScopeRowInteractionContainer(hasAction: false) { state, _ in
                PanelSoundScopeSuccessfulActionButton(
                    action: {},
                    actionCoordinator: actionCoordinator,
                    reduceMotion: false,
                    focusedTarget: $focusedTarget,
                    target: .scope(.surface(.codex)),
                    policy: .scopeAction,
                    onHover: { _ in }
                ) {
                    Text("Scope")
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .contentShape(Rectangle())
                }
                .background(
                    SoundScopeTransientStateProbe(
                        row: "scope",
                        state: state,
                        recorder: recorder))
            }
        }
        .padding(10)
        .frame(width: 240, height: 110, alignment: .top)
    }
}

@MainActor
private struct SoundScopeTransientStateProbe: View {
    let row: String
    let state: PanelSoundScopeRowTransientState
    let recorder: SoundScopeControlsNativeRecorder

    var body: some View {
        Color.clear
            .onAppear { recorder.recordState(state, for: row) }
            .onChange(of: state) { recorder.recordState($0, for: row) }
    }
}

@MainActor
private struct ScopeRowsFixture: View {
    let recorder: HitTargetRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            scopeRow(id: "global", isSelected: true)
            scopeRow(id: "codex", isSelected: false)
            scopeRow(id: "workbuddy", isSelected: false)
                .disabled(true)
        }
        .padding(10)
        .frame(width: 280, height: 150, alignment: .topLeading)
    }

    private func scopeRow(id: String, isSelected: Bool) -> some View {
        Button {
            recorder.record(id)
        } label: {
            HStack(spacing: 10) {
                Text(id)
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .padding(.horizontal, 12)
            .background(isSelected ? Color.primary.opacity(0.06) : Color.clear)
        }
        .buttonStyle(ClaudioFullRowButtonStyle())
    }
}

@MainActor
private struct CompoundRowFixture: View {
    let recorder: HitTargetRecorder

    var body: some View {
        HStack(spacing: 8) {
            Button {
                recorder.record("row")
            } label: {
                Text("Event")
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(ClaudioFullRowButtonStyle())

            Button {
                recorder.record("tail")
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(ClaudioIconButtonStyle())
        }
        .padding(10)
        .frame(width: 280, height: 48, alignment: .center)
    }
}

@MainActor
private struct CompactTargetsFixture: View {
    let recorder: HitTargetRecorder

    var body: some View {
        HStack(spacing: 12) {
            Button {
                recorder.record("icon")
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(ClaudioIconButtonStyle())

            Button("×") {
                recorder.record("compact")
            }
            .buttonStyle(ClaudioCompactButtonStyle())
        }
        .padding(10)
        .frame(width: 160, height: 48, alignment: .topLeading)
    }
}

@MainActor
private struct DisabledIconTargetFixture: View {
    let recorder: HitTargetRecorder

    var body: some View {
        Button {
            recorder.record("disabled-icon")
        } label: {
            Image(systemName: "play.fill")
        }
        .buttonStyle(ClaudioIconButtonStyle())
        .disabled(true)
        .padding(10)
        .frame(width: 48, height: 48)
    }
}

@MainActor
private func productionSource(_ relativePath: String) -> String? {
    let fileURL = URL(fileURLWithPath: "\(#filePath)")
    let root =
        fileURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try? String(
        contentsOf: root.appendingPathComponent(relativePath),
        encoding: .utf8)
}
