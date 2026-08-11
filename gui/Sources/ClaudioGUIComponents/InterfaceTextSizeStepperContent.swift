import ClaudioGUICore
import ClaudioLocalization
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
    private let language: ClaudioAppLanguage
    private let managesFocus: Bool
    private let showsTitle: Bool

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedTarget: FocusTarget?

    public init(
        selection: Binding<ClaudioInterfaceTextSize>,
        managesFocus: Bool = true,
        language: ClaudioAppLanguage = .zhHans,
        showsTitle: Bool = true
    ) {
        self._selection = selection
        self.managesFocus = managesFocus
        self.language = language
        self.showsTitle = showsTitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsTitle {
                Text(l10n.text(.interfaceTextSize))
                    .font(ClaudioTheme.font(.sectionTitle))
                    .foregroundColor(ClaudioTheme.text(colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)

                Divider()
                    .padding(.horizontal, 16)
            }

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

    private var l10n: ClaudioL10n { ClaudioL10n(language: language) }

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
        .accessibilityLabel(l10n.text(.interfaceTextSizeDecrease))
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
        .accessibilityLabel(l10n.text(.interfaceTextSizeIncrease))
        .accessibilityValue(increaseAccessibilityValue)
        .accessibilityIdentifier("panel.options.text-size.increase")
    }

    private var currentLevel: some View {
        VStack(spacing: 3) {
            Text(selection.localizedDisplayName(language))
                .font(ClaudioTheme.font(.sectionTitle))
                .foregroundColor(ClaudioTheme.text(colorScheme))
                .lineLimit(1)

            Text(l10n.format(.interfaceTextSizeLevel, Int64(selection.levelNumber)))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(l10n.text(.interfaceTextSizeCurrent))
        .accessibilityValue(
            "\(selection.localizedDisplayName(language))\(language == .english ? ", " : "，")"
                + l10n.format(.interfaceTextSizeLevel, Int64(selection.levelNumber)))
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
        guard let smaller = selection.smaller else { return l10n.text(.interfaceTextSizeMinimum) }
        return l10n.format(
            .interfaceTextSizeLevel,
            Int64(smaller.levelNumber))
    }

    private var increaseAccessibilityValue: String {
        guard let larger = selection.larger else { return l10n.text(.interfaceTextSizeMaximum) }
        return l10n.format(
            .interfaceTextSizeLevel,
            Int64(larger.levelNumber))
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

/// The complete 280pt interface popover: a visible native segmented language control followed by
/// the existing four-level text-size control. The two languages remain visible at all times;
/// changing one updates the shared store without dismissing this child popover.
@MainActor
public struct InterfaceSettingsPopoverContent: View {
    @Binding public var selection: ClaudioInterfaceTextSize
    @ObservedObject private var languageStore: ClaudioLanguageStore

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedTarget: FocusTarget?

    private enum FocusTarget: Hashable {
        case language
    }

    public init(
        selection: Binding<ClaudioInterfaceTextSize>,
        languageStore: ClaudioLanguageStore
    ) {
        self._selection = selection
        self.languageStore = languageStore
    }

    public var body: some View {
        let l10n = ClaudioL10n(language: languageStore.language)
        VStack(alignment: .leading, spacing: 0) {
            Text(l10n.text(.interfaceTitle))
                .font(ClaudioTheme.font(.sectionTitle))
                .foregroundColor(ClaudioTheme.text(colorScheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 13)
                .padding(.bottom, 10)

            Picker(l10n.text(.interfaceLanguage), selection: languageBinding) {
                Text(l10n.text(.interfaceChinese)).tag(ClaudioAppLanguage.zhHans)
                Text(l10n.text(.interfaceEnglish)).tag(ClaudioAppLanguage.english)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .accessibilityLabel(l10n.text(.interfaceLanguage))
            .accessibilityIdentifier("panel.options.language")
            .focused($focusedTarget, equals: .language)

            Divider()
                .padding(.horizontal, 16)
                .padding(.top, 12)

            InterfaceTextSizeStepperContent(
                selection: $selection,
                managesFocus: false,
                language: languageStore.language,
                showsTitle: false)
        }
        .frame(width: InterfaceTextSizeStepperContent.popoverWidth)
        .onAppear { focusedTarget = .language }
        .onChange(of: languageStore.language) { _ in
            // Keep the language control as the active focus owner after an immediate switch;
            // the next Tab enters the text-size buttons in the same popover.
            focusedTarget = .language
        }
        .onDisappear { focusedTarget = nil }
    }

    private var languageBinding: Binding<ClaudioAppLanguage> {
        Binding(
            get: { languageStore.language },
            set: { languageStore.setLanguage($0) })
    }
}
