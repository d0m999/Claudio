import AppKit
import ClaudioCore
import ClaudioGUICore
import SwiftUI

/// T8's standard-window skeleton: full pack sidebar plus the selected pack's four mappings.
///
/// It intentionally stops before T9/T11/T12/T17: no window-specific focus/VoiceOver model,
/// orphan-file actions, restore action, or star controls live here yet.
@MainActor
struct SoundPacksWindowView: View {
    @ObservedObject var model: SoundPacksWindowModel
    let userPacksDirectory: URL

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 176, idealWidth: 176, maxWidth: 220)
            detail
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 560, minHeight: 400)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("声音包")
                .font(.headline)
                .padding(.horizontal, 10)
                .padding(.top, 10)

            List(selection: selection) {
                ForEach(model.packCards, id: \.id) { card in
                    HStack(spacing: 6) {
                        Text(SelectedPackMetadata(id: card.id, name: card.name).displayName)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if card.isSelected {
                            Image(systemName: "checkmark")
                        }
                    }
                    .tag(Optional(card.id))
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let card = selectedCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(SelectedPackMetadata(id: card.id, name: card.name).displayName)
                        .font(.title2.weight(.semibold))
                    if let label = licenseBadgeLabel(metaSlots.license) {
                        Text(label)
                            .font(.caption)
                    }
                    Spacer()
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            userPacksDirectory.appendingPathComponent(card.id)
                        ])
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.selectedEventRows, id: \.event) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.event.manifestKey)
                                    .font(.body)
                                Text(row.event.cliName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(mappingText(row.coverage))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()
            }
            .padding(20)
        } else {
            VStack(spacing: 8) {
                Text("没有可管理的声音包")
                    .font(.headline)
                Text("声音包出现后会列在左侧。")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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

}
