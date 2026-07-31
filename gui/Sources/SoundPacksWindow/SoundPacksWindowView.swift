import AppKit
import ClaudioCore
import ClaudioGUICore
import SwiftUI

/// Standard-window surface: full pack sidebar plus the selected pack's four mappings.
///
/// T9 adds a window-owned focus/VoiceOver/Dynamic Type layer. T11/T12/T17 orphan-file actions,
/// restore action, and star controls remain deliberately out of scope.
@MainActor
struct SoundPacksWindowView: View {
    @ObservedObject var model: SoundPacksWindowModel
    let userPacksDirectory: URL
    @ObservedObject var focusCoordinator: SoundPacksWindowFocusCoordinator

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var focusedTarget: SoundPacksWindowFocusTarget?
    @State private var handledFocusRequestRevision = 0

    var body: some View {
        Group {
            if layoutAdaptation.stacksPrimaryRegions {
                VSplitView {
                    sidebar
                        .frame(
                            minHeight: layoutAdaptation.sidebarMinimumHeight,
                            idealHeight: 180)
                    detail
                        .frame(
                            minWidth: 0,
                            maxWidth: .infinity,
                            minHeight: 200,
                            maxHeight: .infinity)
                }
            } else {
                HSplitView {
                    sidebar
                        .frame(
                            minWidth: layoutAdaptation.sidebarMinimumWidth,
                            idealWidth: layoutAdaptation.sidebarIdealWidth,
                            maxWidth: layoutAdaptation.sidebarMaximumWidth)
                    detail
                        .frame(
                            minWidth: layoutAdaptation.detailMinimumWidth,
                            maxWidth: .infinity,
                            maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 400)
        .onReceive(focusCoordinator.$requestRevision) { revision in
            guard revision > handledFocusRequestRevision else { return }
            handledFocusRequestRevision = revision
            applyInitialFocus()
        }
        .onChange(of: model.packCards.map(\.id)) { _ in
            reconcileFocusWithVisibleControls()
        }
        .onChange(of: model.selectedPackID) { _ in
            reconcileFocusWithVisibleControls()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("声音包")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 10)
                .padding(.top, 10)

            List(selection: selection) {
                ForEach(model.packCards, id: \.id) { card in
                    HStack(spacing: 6) {
                        Text(SelectedPackMetadata(id: card.id, name: card.name).displayName)
                            .lineLimit(layoutAdaptation.packNameLineLimit)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        if card.isSelected {
                            Image(systemName: "checkmark")
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .tag(Optional(card.id))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(packAccessibilityLabel(card))
                    .accessibilityAddTraits(
                        model.selectedPackID == card.id ? .isSelected : [])
                }
            }
            .focusable(!model.packCards.isEmpty)
            .focused($focusedTarget, equals: .packList)
            .accessibilityLabel("声音包列表")
            .accessibilityHint("使用上、下方向键选择要检查的声音包")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let card = selectedCard {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailHeader(card)

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.selectedEventRows, id: \.event) { row in
                            eventMappingRow(row)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        } else {
            VStack(spacing: 8) {
                Text("没有可管理的声音包")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("声音包出现后会列在左侧。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("没有可管理的声音包。声音包出现后会列在左侧。")
        }
    }

    @ViewBuilder
    private func detailHeader(_ card: PackCard) -> some View {
        if layoutAdaptation.stacksDetailHeader {
            VStack(alignment: .leading, spacing: 10) {
                detailIdentity(card)
                revealButton(card)
            }
        } else {
            HStack {
                detailIdentity(card)
                Spacer(minLength: 12)
                revealButton(card)
            }
        }
    }

    private func detailIdentity(_ card: PackCard) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(SelectedPackMetadata(id: card.id, name: card.name).displayName)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let label = licenseBadgeLabel(metaSlots.license) {
                Text(label)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func revealButton(_ card: PackCard) -> some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([
                userPacksDirectory.appendingPathComponent(card.id)
            ])
        } label: {
            Text("在访达中显示")
                .frame(minHeight: 44)
                .fixedSize(horizontal: false, vertical: true)
        }
        .focused($focusedTarget, equals: .revealSelectedPack)
        .accessibilityLabel(
            "在访达中显示「\(SelectedPackMetadata(id: card.id, name: card.name).displayName)」")
        .accessibilityHint("打开这个声音包所在的文件夹")
    }

    @ViewBuilder
    private func eventMappingRow(_ row: EventRow) -> some View {
        Group {
            if layoutAdaptation.stacksEventRows {
                VStack(alignment: .leading, spacing: 4) {
                    eventIdentity(row)
                    mappingValue(row.coverage)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    eventIdentity(row)
                    Spacer(minLength: 12)
                    mappingValue(row.coverage)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            soundPacksWindowEventAccessibilityLabel(
                eventName: row.event.manifestKey,
                coverage: row.coverage,
                enabled: row.enabled))
    }

    private func eventIdentity(_ row: EventRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.event.manifestKey)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Text(row.event.settingsName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func mappingValue(_ coverage: CoverageState) -> some View {
        Text(mappingText(coverage))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var selection: Binding<String?> {
        Binding(
            get: { model.selectedPackID },
            set: { newValue in
                if let newValue {
                    model.selectPackForInspection(newValue)
                }
            })
    }

    private var selectedCard: PackCard? {
        guard let selectedPackID = model.selectedPackID else { return nil }
        return model.packCards.first(where: { $0.id == selectedPackID })
    }

    private var focusScope: SoundPacksWindowFocusScope {
        SoundPacksWindowFocusScope(
            packIDs: model.packCards.map(\.id),
            selectedPackID: model.selectedPackID)
    }

    private func applyInitialFocus() {
        focusedTarget = soundPacksWindowFirstFocusTarget(focusScope)
    }

    private func reconcileFocusWithVisibleControls() {
        let order = soundPacksWindowFocusOrder(focusScope)
        if let focusedTarget, !order.contains(focusedTarget) {
            self.focusedTarget = order.first
        }
    }

    private var typeSizeTier: SoundPacksWindowTypeSizeTier {
        if dynamicTypeSize.isAccessibilitySize {
            return .accessibility
        }
        switch dynamicTypeSize {
        case .xxLarge, .xxxLarge:
            return .enlarged
        default:
            return .standard
        }
    }

    private var layoutAdaptation: SoundPacksWindowLayoutAdaptation {
        soundPacksWindowLayoutAdaptation(for: typeSizeTier)
    }

    private var metaSlots: PackRowMetaSlots {
        guard let card = selectedCard else {
            return PackRowMetaSlots(license: .none, missingCount: nil)
        }
        return packRowMetaSlots(
            isCC0: card.isCC0, state: card.state, factoryIntegrity: card.factoryIntegrity)
    }

    private func licenseBadgeLabel(_ badge: PackRowLicenseBadge) -> String? {
        switch badge {
        case .none:
            return nil
        case .cc0:
            return "CC0"
        case .modified:
            return "⚠ 已修改"
        }
    }

    private func mappingText(_ coverage: CoverageState) -> String {
        switch coverage {
        case .present(let fileName): return fileName
        case .unmapped: return "未配置"
        case .broken(let fileName): return "\(fileName) · 文件丢失"
        }
    }

    private func packAccessibilityLabel(_ card: PackCard) -> String {
        soundPacksWindowPackAccessibilityLabel(
            displayName: SelectedPackMetadata(id: card.id, name: card.name).displayName,
            isActivePack: card.isSelected,
            state: card.state,
            license: packRowMetaSlots(
                isCC0: card.isCC0,
                state: card.state,
                factoryIntegrity: card.factoryIntegrity
            ).license)
    }
}
