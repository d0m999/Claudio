import AppKit
import ClaudioGUIComponents
import Foundation
import SwiftUI

/// Native hit-target regression coverage for the shared full-row and compact control contracts.
/// The production `ClaudioGUI` target is an executable and cannot be imported here, so the suite
/// tests the public component styles through real SwiftUI buttons hosted in AppKit, while the
/// final source assertions bind those contracts to the production call sites.
@MainActor
func runHitTargetSuites() {
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
                probe.click(x: x, yFromTop: 84),
                "未选中透明 Codex 行的前部、中部和尾部都必须能合成点击")
        }
        expect(
            recorder.actions == ["codex", "codex", "codex"],
            "未选中透明行的三个位置都只能触发 Codex，实得 \(recorder.actions)")
    }

    suite("Sound Scope 行：行外、分组间隙、相邻行和禁用行保持隔离") {
        let recorder = HitTargetRecorder()
        let probe = NativeHitTargetProbe(
            rootView: ScopeRowsFixture(recorder: recorder),
            size: CGSize(width: 280, height: 150))
        defer { probe.close() }

        expect(probe.click(x: 15, yFromTop: 50), "分组标题不是 Sound Scope 选择按钮")
        expect(probe.click(x: 15, yFromTop: 66), "分组间隙不是 Sound Scope 选择按钮")
        expect(probe.click(x: 278, yFromTop: 84), "条目外部空白不能命中相邻 Sound Scope")
        expect(
            recorder.actions.isEmpty,
            "标题、间隙和行外点击都不能切换作用域，实得 \(recorder.actions)")

        expect(probe.click(x: 15, yFromTop: 84), "相邻 Codex 行应只命中自身")
        expect(
            recorder.actions == ["codex"],
            "点击相邻行不能误触发 Global，实得 \(recorder.actions)")

        recorder.reset()
        for x in [15.0, 140.0, 268.0] {
            expect(probe.click(x: x, yFromTop: 112), "禁用 WorkBuddy 行仍应可命中但不可执行")
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
    }

    suite("生产接线：Events、声音包、onboarding 与 AI composer 使用显式命中合同") {
        let eventSettings = productionSource(
            "gui/Sources/ClaudioSettingsPresentation/EventSettingsWindowView.swift")
        let packGallery = productionSource("gui/Sources/ClaudioGUI/PackGalleryView.swift")
        let panelRows = productionSource("gui/Sources/ClaudioGUI/PanelRows.swift")
        let aiCue = productionSource(
            "gui/Sources/ClaudioSettingsPresentation/EventSettingsAICueView.swift")

        expect(
            eventSettings?.contains(".buttonStyle(ClaudioFullRowButtonStyle())") == true,
            "Events 的所有 Sound Scope 条目必须使用共享整行按钮样式")
        expect(
            packGallery?.contains(".buttonStyle(ClaudioFullRowButtonStyle())") == true,
            "可复用声音包整行按钮必须使用显式整行命中合同")
        expect(
            panelRows?.contains(".buttonStyle(ClaudioFullRowButtonStyle())") == true,
            "onboarding 可展开失败行必须使用至少 28pt 的共享整行合同")
        expect(
            aiCue?.contains(".buttonStyle(ClaudioCompactButtonStyle())") == true,
            "AI composer 的 plain 关闭动作必须复用经过原生点击验证的紧凑命中合同")
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
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        self.window = window
        self.hostingView = hostingView
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
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        return true
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
private struct ScopeRowsFixture: View {
    let recorder: HitTargetRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            scopeRow(id: "global", isSelected: true)
            Text("Claude Code")
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .padding(.horizontal, 12)
            Spacer().frame(height: 8)
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
