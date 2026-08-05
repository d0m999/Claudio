import ClaudioGUICore
import SwiftUI

/// The fixed-width content shared by the live interface-text popover and the DEBUG state
/// gallery. The selected level is always read from the binding, so a change made in another
/// Claudio surface is reflected here without a second local copy of the preference.
public struct InterfaceTextSizeStepperContent: View {
    private enum FocusTarget: Hashable {
        case decrease
        case increase
    }

    public static let popoverWidth: CGFloat = 280

    @Binding public var selection: ClaudioInterfaceTextSize
    private let managesFocus: Bool

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedTarget: FocusTarget?

    public init(
        selection: Binding<ClaudioInterfaceTextSize>,
        managesFocus: Bool = true
    ) {
        self._selection = selection
        self.managesFocus = managesFocus
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("界面文字")
                .font(ClaudioTheme.font(.sectionTitle))
                .foregroundColor(ClaudioTheme.text(colorScheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 13)

            Divider()
                .padding(.horizontal, 16)

            HStack(alignment: .center, spacing: 12) {
                decreaseButton
                currentLevel
                    .frame(maxWidth: .infinity)
                increaseButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 11)
            .padding(.bottom, 8)

            levelDots
                .frame(maxWidth: .infinity)
                .padding(.bottom, 13)
        }
        .frame(width: Self.popoverWidth)
        .onAppear {
            setInitialFocus()
        }
        .onChange(of: selection) { _ in
            reconcileFocus()
        }
    }

    private var decreaseButton: some View {
        Button {
            guard let smaller = selection.smaller else { return }
            selection = smaller
        } label: {
            Text("A")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.bordered)
        .disabled(selection.smaller == nil)
        .focused($focusedTarget, equals: .decrease)
        .accessibilityLabel("减小界面文字")
        .accessibilityValue(decreaseAccessibilityValue)
        .accessibilityIdentifier("panel.options.text-size.decrease")
    }

    private var increaseButton: some View {
        Button {
            guard let larger = selection.larger else { return }
            selection = larger
        } label: {
            Text("A")
                .font(.system(size: 25, weight: .medium, design: .rounded))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.bordered)
        .disabled(selection.larger == nil)
        .focused($focusedTarget, equals: .increase)
        .accessibilityLabel("增大界面文字")
        .accessibilityValue(increaseAccessibilityValue)
        .accessibilityIdentifier("panel.options.text-size.increase")
    }

    private var currentLevel: some View {
        VStack(spacing: 3) {
            Text(selection.displayName)
                .font(ClaudioTheme.font(.sectionTitle))
                .foregroundColor(ClaudioTheme.text(colorScheme))
                .lineLimit(1)

            Text("第 \(selection.levelNumber) 档，共 \(selection.levelCount) 档")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("当前界面文字")
        .accessibilityValue(
            "\(selection.displayName)，第 \(selection.levelNumber) 档，共 \(selection.levelCount) 档")
        .accessibilityIdentifier("panel.options.text-size.status")
    }

    private var levelDots: some View {
        HStack(spacing: 8) {
            ForEach(ClaudioInterfaceTextSize.allCases) { level in
                ZStack {
                    Circle()
                        .fill(
                            level == selection
                                ? ClaudioTheme.clay(colorScheme)
                                : ClaudioTheme.secondaryText(colorScheme).opacity(0.45))
                        .frame(
                            width: level == selection ? 9 : 6,
                            height: level == selection ? 9 : 6)

                    if level == selection {
                        Circle()
                            .stroke(ClaudioTheme.clay(colorScheme), lineWidth: 1.5)
                            .frame(width: 15, height: 15)
                    }
                }
                .frame(width: 16, height: 16)
            }
        }
        .accessibilityHidden(true)
    }

    private var decreaseAccessibilityValue: String {
        guard let smaller = selection.smaller else { return "已是最小档" }
        return "目标档位：\(smaller.displayName)"
    }

    private var increaseAccessibilityValue: String {
        guard let larger = selection.larger else { return "已是最大档" }
        return "目标档位：\(larger.displayName)"
    }

    private func setInitialFocus() {
        guard managesFocus else { return }
        focusedTarget = selection == .compact ? .increase : .decrease
    }

    private func reconcileFocus() {
        guard managesFocus else { return }

        switch (focusedTarget, selection) {
        case (.decrease, .compact):
            focusedTarget = .increase
        case (.increase, .maximum):
            focusedTarget = .decrease
        case (nil, _):
            focusedTarget = selection == .compact ? .increase : .decrease
        default:
            break
        }
    }
}
