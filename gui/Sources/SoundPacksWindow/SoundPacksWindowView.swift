import AppKit
import ClaudioCore
import ClaudioGUICore
import SwiftUI

private struct PermanentAudioDeletionRequest: Identifiable {
    let packID: String
    let file: PackAudioFile

    var id: String { "\(packID)/\(file.fileName)" }
}

private struct FactoryPackRestoreRequest: Identifiable {
    enum Kind {
        case selectedPack
        case failedPublishRetry
    }

    let packID: String
    let displayName: String
    let kind: Kind

    var id: String { packID }
}

/// Standard-window surface: full pack sidebar plus the selected pack's four mappings.
///
/// T9 adds a window-owned focus/VoiceOver/Dynamic Type layer. T11 adds selected-pack audio
/// inventory, existing-audio assignment, and explicit confirmed orphan deletion.
@MainActor
struct SoundPacksWindowView: View {
    @ObservedObject var model: SoundPacksWindowModel
    let userPacksDirectory: URL
    @ObservedObject var focusCoordinator: SoundPacksWindowFocusCoordinator

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var focusedTarget: SoundPacksWindowFocusTarget?
    @State private var handledFocusRequestRevision = 0
    @State private var pendingPermanentDeletion: PermanentAudioDeletionRequest?
    @State private var pendingFactoryPackRestore: FactoryPackRestoreRequest?

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
        .onChange(of: model.selectedAudioFiles) { _ in
            reconcileFocusWithVisibleControls()
        }
        .onChange(of: model.factoryRestoreRetryPackID) { _ in
            if model.packCards.isEmpty, model.factoryRestoreRetryPackID != nil {
                focusedTarget = .retryFactoryRestore
            } else {
                reconcileFocusWithVisibleControls()
            }
        }
        .confirmationDialog(
            pendingPermanentDeletion.map { "永久删除「\($0.file.fileName)」？" } ?? "永久删除音频？",
            isPresented: Binding(
                get: { pendingPermanentDeletion != nil },
                set: { if !$0 { pendingPermanentDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingPermanentDeletion
        ) { request in
            Button("永久删除", role: .destructive) {
                model.deleteSelectedOrphanAudioFileAfterConfirmation(
                    request.file.fileName,
                    expectedPackID: request.packID)
                pendingPermanentDeletion = nil
            }
            Button("取消", role: .cancel) {
                pendingPermanentDeletion = nil
            }
        } message: { request in
            Text("「\(request.file.fileName)」会从这个声音包永久移除。此操作无法撤销。")
        }
        .confirmationDialog(
            pendingFactoryPackRestore.map {
                "用出厂版本替换「\($0.displayName)」？"
            } ?? "恢复出厂声音？",
            isPresented: Binding(
                get: { pendingFactoryPackRestore != nil },
                set: { if !$0 { pendingFactoryPackRestore = nil } }),
            titleVisibility: .visible,
            presenting: pendingFactoryPackRestore
        ) { request in
            Button("替换并恢复出厂声音", role: .destructive) {
                switch request.kind {
                case .selectedPack:
                    model.restoreSelectedFactoryPackAfterConfirmation(
                        expectedPackID: request.packID)
                case .failedPublishRetry:
                    model.retryFailedFactoryPackRestoreAfterConfirmation(
                        expectedPackID: request.packID)
                }
                pendingFactoryPackRestore = nil
            }
            Button("取消", role: .cancel) {
                pendingFactoryPackRestore = nil
            }
        } message: { request in
            Text(factoryRestoreConfirmationMessage(request))
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
        VStack(spacing: 0) {
            // Factory restore is a window-level operation status, not metadata for whichever card
            // happens to be selected after the disk reload. In particular, a publish failure after
            // salvage removes the attempted pack's active path; keeping this row inside the
            // selected-card branch would either hide it entirely or misattribute it to a fallback.
            if let outcome = model.factoryRestoreNotice {
                windowFactoryRestoreNoticeRow(
                    factoryPackRestoreNoticeMessage(outcome))
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
            }
            if let error = model.factoryRestoreActionError {
                factoryRestoreFailureSection(error)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
            }
            // Audio failures also belong to the window-level action surface. A lock-time
            // `packNotFound` reload can legitimately remove the last card before the failure is
            // published; keeping this row inside `selectedCard` would hide the refusal in empty
            // state.
            if let error = model.audioActionError {
                windowFailureRow(action: "音频操作", reason: error.message)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
            }

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

                        if let error = model.audioInventoryError {
                            windowFailureRow(
                                action: "读取包内音频",
                                reason: inventoryErrorMessage(error))
                        }

                        orphanAudioSection
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func detailHeader(_ card: PackCard) -> some View {
        if layoutAdaptation.stacksDetailHeader {
            VStack(alignment: .leading, spacing: 10) {
                detailIdentity(card)
                revealButton(card)
                if model.selectedPackIsBuiltinReadOnly {
                    factoryRestoreButton(card)
                }
            }
        } else {
            HStack {
                detailIdentity(card)
                Spacer(minLength: 12)
                revealButton(card)
                if model.selectedPackIsBuiltinReadOnly {
                    factoryRestoreButton(card)
                }
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

    private func factoryRestoreButton(_ card: PackCard) -> some View {
        let displayName = SelectedPackMetadata(id: card.id, name: card.name).displayName
        return Button("恢复出厂声音…") {
            pendingFactoryPackRestore = FactoryPackRestoreRequest(
                packID: card.id,
                displayName: displayName,
                kind: .selectedPack)
        }
        .frame(minHeight: 44)
        .focused($focusedTarget, equals: .restoreFactoryPack)
        .accessibilityLabel("恢复「\(displayName)」的出厂声音")
        .accessibilityHint("会先确认替换，并说明恢复前内容的保存方式")
    }

    @ViewBuilder
    private func eventMappingRow(_ row: EventRow) -> some View {
        Group {
            if layoutAdaptation.stacksEventRows {
                VStack(alignment: .leading, spacing: 4) {
                    eventIdentity(row)
                    eventAudioControl(row)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    eventIdentity(row)
                    Spacer(minLength: 12)
                    eventAudioControl(row)
                }
            }
        }
        .padding(.vertical, 4)
        // T9's read-only row could collapse all children into one status sentence. T11 adds a
        // real Menu to editable rows, so those children must remain in the VoiceOver tree or the
        // existing-audio action becomes keyboard-only. Built-in rows stay read-only and keep the
        // original single-element status treatment.
        .accessibilityElement(children: canEditSelectedPack ? .contain : .ignore)
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

    @ViewBuilder
    private func eventAudioControl(_ row: EventRow) -> some View {
        if canEditSelectedPack {
            Menu {
                ForEach(model.selectedAudioFiles) { file in
                    Button(file.isOrphan ? "\(file.fileName) · 未被使用" : file.fileName) {
                        model.assignSelectedAudioFile(file.fileName, to: row.event)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(mappingText(row.coverage))
                    Image(systemName: "chevron.down")
                        .accessibilityHidden(true)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(model.selectedAudioFiles.isEmpty)
            .focused($focusedTarget, equals: .eventAudio(row.event))
            .accessibilityLabel("\(row.event.manifestKey) 的声音文件")
            .accessibilityValue(mappingText(row.coverage))
            .accessibilityHint(
                model.selectedAudioFiles.isEmpty
                    ? "这个包里没有可复用的音频"
                    : "选择这个包里已有的音频")
        } else {
            mappingValue(row.coverage)
        }
    }

    @ViewBuilder
    private var orphanAudioSection: some View {
        let orphanFiles = model.selectedAudioFiles.filter(\.isOrphan)
        if !orphanFiles.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("未被使用的音频")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                ForEach(orphanFiles) { file in
                    orphanAudioRow(file)
                }
                if !canEditSelectedPack {
                    Text("内置声音包是只读的；请先复制为我的包，再分配或删除这些音频。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func orphanAudioRow(_ file: PackAudioFile) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("\(file.fileName) · 未被使用")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if canEditSelectedPack {
                Menu("分配…") {
                    ForEach(Event.allCases, id: \.self) { event in
                        Button(event.manifestKey) {
                            model.assignSelectedAudioFile(file.fileName, to: event)
                        }
                    }
                }
                .frame(minHeight: 44)
                .focused(
                    $focusedTarget,
                    equals: .orphanAssignment(fileName: file.fileName))
                .accessibilityLabel("分配 \(file.fileName)")
                .accessibilityHint("选择要使用这个音频的事件")

                Button("删除") {
                    if let selectedPackID = model.selectedPackID {
                        pendingPermanentDeletion = PermanentAudioDeletionRequest(
                            packID: selectedPackID,
                            file: file)
                    }
                }
                .frame(minHeight: 44)
                .focused(
                    $focusedTarget,
                    equals: .orphanDeletion(fileName: file.fileName))
                .accessibilityLabel("永久删除 \(file.fileName)")
                .accessibilityHint("会先显示不可撤销的确认")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func windowFailureRow(action: String, reason: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(reason)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            soundPacksWindowFailureAccessibilityLabel(action: action, reason: reason))
    }

    private func factoryRestoreFailureSection(
        _ error: SoundPacksWindowFactoryRestoreActionError
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            windowFailureRow(action: "恢复出厂声音", reason: error.message)
            if let packID = model.factoryRestoreRetryPackID {
                let displayName = SelectedPackMetadata(id: packID, name: nil).displayName
                Button("重试恢复「\(displayName)」…") {
                    pendingFactoryPackRestore = FactoryPackRestoreRequest(
                        packID: packID,
                        displayName: displayName,
                        kind: .failedPublishRetry)
                }
                .frame(minHeight: 44)
                .focused($focusedTarget, equals: .retryFactoryRestore)
                .accessibilityLabel("重试恢复「\(displayName)」的出厂声音")
                .accessibilityHint("会先确认，再重新发布完整的出厂版本")
            }
        }
    }

    private func factoryRestoreConfirmationMessage(
        _ request: FactoryPackRestoreRequest
    ) -> String {
        switch request.kind {
        case .selectedPack:
            return
                "当前内容会被出厂版本替换。恢复前的整个目录会原样搬到同级隐藏位置，"
                + "一个文件都不会删除；完成后会显示实际路径。"
        case .failedPublishRetry:
            return
                "将重新尝试发布完整的出厂版本。上次恢复前搬走的内容会继续原样保留，"
                + "一个文件都不会删除。"
        }
    }

    private func windowFactoryRestoreNoticeRow(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
    }

    private func inventoryErrorMessage(_ error: PackAudioInventoryError) -> String {
        switch error {
        case .packNotFound(let packID):
            return "声音包「\(packID)」已找不到。"
        case .manifestUnreadable(let reason):
            return "manifest.json 无法安全读取：\(reason)"
        case .directoryUnreadable(let reason):
            return "声音包目录无法读取：\(reason)"
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

    private var focusScope: SoundPacksWindowFocusScope {
        SoundPacksWindowFocusScope(
            packIDs: model.packCards.map(\.id),
            selectedPackID: model.selectedPackID,
            editableEvents: canEditSelectedPack && !model.selectedAudioFiles.isEmpty
                ? model.selectedEventRows.map(\.event) : [],
            orphanFileNames: canEditSelectedPack
                ? model.selectedAudioFiles.filter(\.isOrphan).map(\.fileName) : [],
            canEditSelectedPack: canEditSelectedPack,
            canRestoreFactoryPack: model.selectedPackIsBuiltinReadOnly,
            canRetryFactoryRestore: model.factoryRestoreRetryPackID != nil)
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

    private var canEditSelectedPack: Bool {
        selectedCard != nil && !model.selectedPackIsBuiltinReadOnly
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
