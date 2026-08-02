import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import SwiftUI
import UniformTypeIdentifiers

private struct PermanentAudioDeletionRequest: Identifiable {
    let packID: String
    let file: PackAudioFile

    var id: String { "\(packID)/\(file.fileName)" }
}

private struct FactoryPackRestoreRequest: Identifiable {
    enum Kind {
        case selectedPack
        case failedPublishRetry
        case allFactoryPacks
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

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ClaudioInterfaceTextSize.defaultsKey)
    private var interfaceTextSizeRaw = ClaudioInterfaceTextSize.defaultValue.rawValue
    @FocusState private var focusedTarget: SoundPacksWindowFocusTarget?
    @State private var handledFocusRequestRevision = 0
    @State private var pendingPermanentDeletion: PermanentAudioDeletionRequest?
    @State private var pendingFactoryPackRestore: FactoryPackRestoreRequest?
    @State private var previewPlayer = NSSoundAudioPreviewPlayer()
    @State private var isImportingAudio = false
    @State private var dropTargetEvent: Event?
    @State private var requestedRoute: SoundPacksWindowRoute = .overview

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
        .frame(minWidth: 640, minHeight: 480)
        .background(ClaudioTheme.panel(colorScheme))
        .environment(\.dynamicTypeSize, interfaceTextSize.dynamicTypeSize)
        .onReceive(focusCoordinator.$requestRevision) { revision in
            guard revision > handledFocusRequestRevision else { return }
            handledFocusRequestRevision = revision
            requestedRoute = focusCoordinator.requestedRoute
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
        .onChange(of: model.selectedEventRows) { _ in
            reconcileFocusWithVisibleControls()
        }
        .onChange(of: model.factoryRestoreRetryPackIDs) { _ in
            if model.packCards.isEmpty, let packID = model.factoryRestoreRetryPackIDs.first {
                focusedTarget = .retryFactoryRestore(packID: packID)
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
            .accessibilityLabel("永久删除 \(request.file.fileName)")
            .accessibilityHint("确认后无法撤销")
            .accessibilityIdentifier("sound-packs.confirm-delete")
            Button("取消", role: .cancel) {
                pendingPermanentDeletion = nil
            }
            .accessibilityLabel("取消永久删除")
            .accessibilityIdentifier("sound-packs.cancel-delete")
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
                case .allFactoryPacks:
                    model.restoreAllFactoryPacksAfterConfirmation()
                }
                pendingFactoryPackRestore = nil
            }
            .accessibilityLabel("恢复 \(request.displayName) 的出厂声音")
            .accessibilityHint("替换前会尽量保留当前内容以供恢复")
            .accessibilityIdentifier("sound-packs.confirm-factory-restore")
            Button("取消", role: .cancel) {
                pendingFactoryPackRestore = nil
            }
            .accessibilityLabel("取消恢复出厂声音")
            .accessibilityIdentifier("sound-packs.cancel-factory-restore")
        } message: { request in
            Text(factoryRestoreConfirmationMessage(request))
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("显示在面板")
                    .font(.headline)
                Spacer(minLength: 8)
                Text("· ★ \(model.starredPackIDs.count)/\(maxStarredPacks)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "显示在面板，\(model.starredPackIDs.count)/\(maxStarredPacks)"
            )
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 10)
            .padding(.top, 10)

            List(selection: selection) {
                ForEach(model.packCards, id: \.id) { card in
                    let starControl = model.starControl(for: card)
                    HStack(spacing: 6) {
                        starButton(card, control: starControl)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(SelectedPackMetadata(id: card.id, name: card.name).displayName)
                                .lineLimit(layoutAdaptation.packNameLineLimit)
                                .fixedSize(horizontal: false, vertical: true)
                            if let reason = starControl.disabledReason {
                                Text(reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityHidden(true)
                            }
                        }
                        Spacer(minLength: 4)
                        if card.isSelected {
                            ClaudioStatusCapsule("使用中", isEmphasized: true)
                        }
                    }
                    .frame(minHeight: ClaudioTheme.Metrics.regularControlHeight)
                    .contentShape(Rectangle())
                    .tag(Optional(card.id))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(packAccessibilityLabel(card))
                    .accessibilityValue(packAccessibilityValue(card))
                    .accessibilityHint("选择后在右侧查看；星标只控制主面板显示")
                    .accessibilityIdentifier("sound-packs.pack.\(card.id)")
                    .accessibilityAddTraits(
                        model.selectedPackID == card.id ? .isSelected : [])
                }
            }
            .focusable(!model.packCards.isEmpty)
            .focused($focusedTarget, equals: .packList)
            .accessibilityLabel("声音包列表")
            .accessibilityValue(
                selectedCard.map {
                    "正在查看 \(SelectedPackMetadata(id: $0.id, name: $0.name).displayName)"
                } ?? "未选择声音包")
            .accessibilityHint("使用上、下方向键选择要检查的声音包")
            .accessibilityIdentifier("sound-packs.pack-list")
        }
    }

    private func starButton(
        _ card: PackCard,
        control: SoundPacksWindowStarControl
    ) -> some View {
        let displayName = SelectedPackMetadata(id: card.id, name: card.name).displayName
        return Button {
            model.toggleStarredPack(card.id)
        } label: {
            Image(systemName: control.isStarred ? "star.fill" : "star")
                .font(.system(size: 13, weight: .semibold))
                .frame(
                    minWidth: ClaudioTheme.Metrics.iconTarget,
                    minHeight: ClaudioTheme.Metrics.iconTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!control.isEnabled)
        .help(control.disabledReason ?? "")
        .accessibilityLabel(
            control.isStarred
                ? "取消在面板显示「\(displayName)」"
                : "在面板显示「\(displayName)」")
        .accessibilityHint(
            control.disabledReason
                ?? (control.isStarred ? "取消后可腾出一个面板位置" : "最多显示 4 个声音包"))
        .accessibilityValue(control.isStarred ? "已固定" : "未固定")
        .accessibilityAddTraits(control.isStarred ? .isSelected : [])
        .accessibilityIdentifier("sound-packs.pack.\(card.id).star")
    }

    @ViewBuilder
    private var detail: some View {
        GeometryReader { geometry in
            let stacksDetail = soundPacksWindowDetailUsesStackedLayout(
                detailWidth: geometry.size.width,
                tier: typeSizeTier)
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Color.clear.frame(height: 0).id("detail-top")
                        if !model.windowStatuses.isEmpty {
                            windowStatusRegion
                                .padding(.horizontal, 20)
                                .padding(.top, 20)
                        }

                        if let card = selectedCard {
                            VStack(alignment: .leading, spacing: 16) {
                                detailHeader(card, stacks: stacksDetail)

                                if model.selectedPackIsBuiltinReadOnly {
                                    builtinCopyExplanation(card)
                                }

                                Divider()

                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(model.selectedEventRows, id: \.event) { row in
                                        eventMappingRow(
                                            row,
                                            stacks: layoutAdaptation.stacksEventRows
                                                || stacksDetail)
                                            .id("event-\(row.event.rawValue)")
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
                        } else {
                            emptyState
                        }
                    }
                        .frame(
                            maxWidth: .infinity,
                            minHeight: selectedCard == nil ? geometry.size.height : nil,
                            alignment: .topLeading)
                    }
                    .onChange(of: model.selectedPackID) { _ in
                        withAnimation(.easeOut(duration: 0.14)) {
                            proxy.scrollTo("detail-top", anchor: .top)
                        }
                    }
                    .onChange(of: requestedRoute) { route in
                        guard case .editEvent(_, let event) = route else { return }
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.14)) {
                                proxy.scrollTo("event-\(event.rawValue)", anchor: .center)
                            }
                        }
                    }
                }
                if let card = selectedCard {
                    Divider()
                    packActionBar(card, stacks: stacksDetail)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var windowStatusRegion: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.windowStatuses) { status in
                windowStatusRow(status)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func detailHeader(_ card: PackCard, stacks: Bool) -> some View {
        if stacks {
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
        VStack(alignment: .leading, spacing: 5) {
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
            if model.selectedPackIsBuiltinReadOnly {
                ClaudioStatusCapsule("内置包 · 复制后编辑")
                    .accessibilityLabel("内置声音包，只读；复制后可以编辑")
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
                .frame(minHeight: ClaudioTheme.Metrics.compactControlHeight)
                .fixedSize(horizontal: false, vertical: true)
        }
        .focused($focusedTarget, equals: .revealSelectedPack)
        .accessibilityLabel(
            "在访达中显示「\(SelectedPackMetadata(id: card.id, name: card.name).displayName)」")
        .accessibilityValue(userPacksDirectory.appendingPathComponent(card.id).path)
        .accessibilityHint("打开这个声音包所在的文件夹")
        .accessibilityIdentifier("sound-packs.reveal-selected")
    }

    private func factoryRestoreButton(_ card: PackCard) -> some View {
        let displayName = SelectedPackMetadata(id: card.id, name: card.name).displayName
        return Button("恢复出厂声音…") {
            pendingFactoryPackRestore = FactoryPackRestoreRequest(
                packID: card.id,
                displayName: displayName,
                kind: .selectedPack)
        }
        .frame(minHeight: ClaudioTheme.Metrics.compactControlHeight)
        .focused($focusedTarget, equals: .restoreFactoryPack)
        .accessibilityLabel("恢复「\(displayName)」的出厂声音")
        .accessibilityValue("内置只读声音包")
        .accessibilityHint("会先确认替换，并说明恢复前内容的保存方式")
        .accessibilityIdentifier("sound-packs.restore-selected-factory-pack")
    }

    private func builtinCopyExplanation(_ card: PackCard) -> some View {
        let discardsInstalledChanges: Bool = {
            if card.factoryIntegrity == false { return true }
            switch card.state {
            case .complete: return false
            case .partial, .broken: return true
            }
        }()
        let message = discardsInstalledChanges
            ? "副本来自出厂版本；当前修改、缺失或损坏内容不会带入。"
            : "从内置原版创建可编辑副本。"
        return Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .help(message)
            .accessibilityLabel(message)
    }

    @ViewBuilder
    private func packActionBar(_ card: PackCard, stacks: Bool) -> some View {
        if stacks {
            VStack(alignment: .leading, spacing: 8) {
                packActions(card, includeFlexibleSpace: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 8) {
                packActions(card, includeFlexibleSpace: true)
            }
        }
    }

    @ViewBuilder
    private func packActions(_ card: PackCard, includeFlexibleSpace: Bool) -> some View {
        let displayName = SelectedPackMetadata(id: card.id, name: card.name).displayName
        if model.selectedPackIsBuiltinReadOnly {
            Button("复制为我的包") {
                model.forkSelectedFactoryPack()
            }
            .buttonStyle(.borderedProminent)
            .tint(ClaudioSharedColor.clay(colorScheme))
            .frame(minHeight: ClaudioTheme.Metrics.regularControlHeight)
            .fixedSize(horizontal: false, vertical: true)
            .focused($focusedTarget, equals: .forkFactoryPack)
            .help(builtinCopyHelp(card))
            .accessibilityLabel("复制「\(displayName)」为我的包")
            .accessibilityValue("原包只读")
            .accessibilityHint(builtinCopyHelp(card))
            .accessibilityIdentifier("sound-packs.fork-selected-pack")

            factoryRestoreButton(card)
        } else {
            Button(isImportingAudio ? "正在添加…" : "+ 添加音频…") {
                chooseAndImportAudio()
            }
            .disabled(isImportingAudio)
            .frame(minHeight: ClaudioTheme.Metrics.regularControlHeight)
            .fixedSize(horizontal: false, vertical: true)
            .focused($focusedTarget, equals: .addAudio)
            .accessibilityLabel("向「\(displayName)」添加音频")
            .accessibilityValue(isImportingAudio ? "正在导入" : "可以选择文件")
            .accessibilityHint("选择 wav、mp3、aiff 或 m4a；导入后先显示为未被使用")
            .accessibilityIdentifier("sound-packs.add-audio")
        }

        if includeFlexibleSpace {
            Spacer(minLength: 8)
        }

        if card.isSelected {
            ClaudioStatusCapsule("使用中", isEmphasized: true)
                .accessibilityLabel("当前正在使用这个声音包")
        } else if model.selectedPackIsBuiltinReadOnly {
            Button("用这个包") {
                model.useSelectedPack()
            }
            .frame(minHeight: ClaudioTheme.Metrics.regularControlHeight)
            .focused($focusedTarget, equals: .useSelectedPack)
            .accessibilityLabel("使用「\(displayName)」")
            .accessibilityValue("当前未使用")
            .accessibilityHint("明确切换当前使用的声音包；不会自动添加星标")
            .accessibilityIdentifier("sound-packs.use-selected-pack")
        } else {
            Button("用这个包") {
                model.useSelectedPack()
            }
            .buttonStyle(.borderedProminent)
            .tint(ClaudioSharedColor.clay(colorScheme))
            .frame(minHeight: ClaudioTheme.Metrics.regularControlHeight)
            .focused($focusedTarget, equals: .useSelectedPack)
            .accessibilityLabel("使用「\(displayName)」")
            .accessibilityValue("当前未使用")
            .accessibilityHint("明确切换当前使用的声音包；不会自动添加星标")
            .accessibilityIdentifier("sound-packs.use-selected-pack")
        }
    }

    private func builtinCopyHelp(_ card: PackCard) -> String {
        if card.factoryIntegrity == false {
            return "从出厂版本创建可编辑副本；当前修改、缺失或损坏内容不会带入"
        }
        switch card.state {
        case .complete:
            return "从内置原版创建可编辑副本；原包、当前使用项与星标都不改变"
        case .partial, .broken:
            return "从出厂版本创建可编辑副本；当前修改、缺失或损坏内容不会带入"
        }
    }

    private func chooseAndImportAudio() {
        guard let expectedPackID = model.selectedPackID else { return }
        let requests = runAudioOpenPanel(allowsMultipleSelection: true).map {
            AudioImportRequest(sourceURL: $0, suggestedFileName: $0.lastPathComponent)
        }
        guard !requests.isEmpty else { return }
        isImportingAudio = true
        Task {
            defer { isImportingAudio = false }
            let result = await model.importSelectedAudioFiles(
                requests,
                expectedPackID: expectedPackID)
            guard
                case .success(let completion) = result,
                let previewFile = completion.previewFile
            else { return }
            if previewVolume(for: model.config) > 0 {
                previewPlayer.play(
                    fileAt: previewFile.destinationURL,
                    volume: Float(previewVolume(for: model.config)))
            }
        }
    }

    private func chooseAndBindAudio(to event: Event) {
        guard
            let sourceURL = runAudioOpenPanel(allowsMultipleSelection: false).first,
            let expectedPackID = model.selectedPackID
        else { return }
        let request = AudioImportRequest(
            sourceURL: sourceURL,
            suggestedFileName: sourceURL.lastPathComponent)
        importAndBind(request, to: event, expectedPackID: expectedPackID)
    }

    private func importAndBind(
        _ request: AudioImportRequest,
        to event: Event,
        expectedPackID: String
    ) {
        guard canEditSelectedPack, !isImportingAudio else { return }
        isImportingAudio = true
        Task {
            defer { isImportingAudio = false }
            let result = await model.importSelectedAudioFiles(
                [request],
                expectedPackID: expectedPackID)
            guard
                case .success(let completion) = result,
                let imported = completion.result.accepted.last,
                completion.targetPackID == model.selectedPackID,
                case .success = model.assignSelectedAudioFile(imported.fileName, to: event)
            else { return }
            if previewVolume(for: model.config) > 0 {
                previewPlayer.play(
                    fileAt: imported.destinationURL,
                    volume: Float(previewVolume(for: model.config)))
            }
        }
    }

    private func revealMappedAudio(for event: Event) {
        guard let fileURL = model.previewFileForSelectedEvent(event) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private func dropTargetBinding(for event: Event) -> Binding<Bool> {
        Binding(
            get: { dropTargetEvent == event },
            set: { isTargeted in
                if isTargeted {
                    dropTargetEvent = event
                } else if dropTargetEvent == event {
                    dropTargetEvent = nil
                }
            })
    }

    private func handleAudioDrop(_ providers: [NSItemProvider], onto event: Event) -> Bool {
        guard
            canEditSelectedPack,
            !isImportingAudio,
            let expectedPackID = model.selectedPackID,
            let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            })
        else { return false }

        Task { @MainActor in
            guard let request = await loadSoundPacksDropRequest(from: provider) else { return }
            importAndBind(request, to: event, expectedPackID: expectedPackID)
        }
        return true
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("没有可管理的声音包")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if model.hasFactoryPacks {
                Text("可以从 Claudio 的出厂资源恢复全部内置声音包。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("恢复内置声音包") {
                    pendingFactoryPackRestore = FactoryPackRestoreRequest(
                        packID: "all-factory-packs",
                        displayName: "所有内置声音包",
                        kind: .allFactoryPacks)
                }
                .buttonStyle(.borderedProminent)
                .tint(ClaudioSharedColor.clay(colorScheme))
                .frame(minHeight: ClaudioTheme.Metrics.regularControlHeight)
                .focused($focusedTarget, equals: .restoreAllFactoryPacks)
                .accessibilityLabel("恢复全部内置声音包")
                .accessibilityValue("当前没有可管理的声音包")
                .accessibilityHint("恢复后可以选择、星标和试听内置声音包")
                .accessibilityIdentifier("sound-packs.restore-all-factory-packs")
            } else {
                Text("当前构建没有出厂声音资源；重新安装 Claudio 可恢复内置声音包。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("在访达中打开声音包文件夹") {
                    revealPacksDirectory()
                }
                .frame(minHeight: ClaudioTheme.Metrics.regularControlHeight)
                .focused($focusedTarget, equals: .revealPacksDirectory)
                .accessibilityLabel("在访达中打开 Claudio 声音包文件夹")
                .accessibilityValue(userPacksDirectory.path)
                .accessibilityHint("当前构建没有可恢复的出厂资源")
                .accessibilityIdentifier("sound-packs.reveal-packs-directory")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func revealPacksDirectory() {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: userPacksDirectory.path,
            isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            NSWorkspace.shared.open(userPacksDirectory)
        } else {
            NSWorkspace.shared.open(userPacksDirectory.deletingLastPathComponent())
        }
    }

    @ViewBuilder
    private func windowStatusRow(_ status: SoundPacksWindowStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if status.severity == .failure {
                windowFailureRow(action: status.action, reason: status.message)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(status.message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(status.message)
            }
            if case .retryFactoryRestores(let packIDs)? = status.recovery {
                ForEach(packIDs, id: \.self) { packID in
                    let displayName = SelectedPackMetadata(id: packID, name: nil).displayName
                    Button("重试恢复「\(displayName)」…") {
                        pendingFactoryPackRestore = FactoryPackRestoreRequest(
                            packID: packID,
                            displayName: displayName,
                            kind: .failedPublishRetry)
                    }
                    .frame(minHeight: ClaudioTheme.Metrics.regularControlHeight)
                    .focused(
                        $focusedTarget,
                        equals: .retryFactoryRestore(packID: packID))
                    .accessibilityLabel("重试恢复「\(displayName)」")
                    .accessibilityValue("上一次恢复未完成")
                    .accessibilityHint("再次尝试安全恢复内置声音包")
                    .accessibilityIdentifier("sound-packs.retry-factory-restore.\(packID)")
                }
            }
        }
    }

    @ViewBuilder
    private func eventMappingRow(_ row: EventRow, stacks: Bool) -> some View {
        Group {
            if stacks {
                VStack(alignment: .leading, spacing: 8) {
                    eventIdentity(row)
                    eventControls(row)
                }
            } else {
                HStack(alignment: .center) {
                    eventIdentity(row)
                    Spacer(minLength: 12)
                    eventControls(row)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background {
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control)
                .fill(
                    dropTargetEvent == row.event
                        ? ClaudioTheme.clay(colorScheme).opacity(0.12)
                        : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control)
                .stroke(
                    dropTargetEvent == row.event
                        ? ClaudioTheme.clay(colorScheme)
                        : ClaudioTheme.hairline(colorScheme),
                    lineWidth: ClaudioTheme.Metrics.hairline)
        }
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: dropTargetBinding(for: row.event),
            perform: { providers in handleAudioDrop(providers, onto: row.event) })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            soundPacksWindowEventAccessibilityLabel(
                eventName: row.event.displayName,
                coverage: row.coverage,
                enabled: row.enabled))
        .accessibilityHint(
            canEditSelectedPack
                ? "可选择现有文件、选择并绑定新文件，或把音频文件拖到这一行"
                : "内置包是只读的；复制后可以编辑")
        .accessibilityIdentifier("sound-packs.event.\(row.event.rawValue)")
    }

    private func eventIdentity(_ row: EventRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                ClaudioEventGlyph(event: row.event, size: 24)
                Text(row.event.displayName)
                    .font(ClaudioTheme.font(.body).weight(.medium))
            }
            Text(row.event.manifestKey)
                .font(ClaudioTheme.font(.technical))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func mappingValue(_ coverage: CoverageState) -> some View {
        Text(mappingText(coverage))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func eventControls(_ row: EventRow) -> some View {
        let availability = previewAvailability(for: row)
        return HStack(spacing: 8) {
            eventAudioControl(row)
            Button {
                playPreview(for: row)
            } label: {
                Label("试听", systemImage: "play.fill")
            }
            .frame(minHeight: ClaudioTheme.Metrics.compactControlHeight)
            .disabled(!availability.isAvailable)
            .focused($focusedTarget, equals: .eventPreview(row.event))
            .accessibilityLabel("试听「\(row.event.displayName)」")
            .accessibilityValue(mappingText(row.coverage))
            .accessibilityHint(availability.accessibilityHint)
            .accessibilityIdentifier("sound-packs.event.\(row.event.rawValue).preview")
        }
    }

    @ViewBuilder
    private func eventAudioControl(_ row: EventRow) -> some View {
        if canEditSelectedPack {
            Menu {
                Section("已有文件") {
                    if model.selectedAudioFiles.isEmpty {
                        Text("这个包里还没有音频")
                    } else {
                        ForEach(model.selectedAudioFiles) { file in
                            Button(file.isOrphan ? "\(file.fileName) · 未被使用" : file.fileName) {
                                model.assignSelectedAudioFile(file.fileName, to: row.event)
                            }
                            .accessibilityLabel(
                                "把 \(file.fileName) 绑定到 \(row.event.displayName)")
                            .accessibilityIdentifier(
                                "sound-packs.event.\(row.event.rawValue).existing.\(file.fileName)")
                        }
                    }
                }
                Divider()
                Button("选择并绑定文件…") {
                    chooseAndBindAudio(to: row.event)
                }
                .accessibilityLabel("为 \(row.event.displayName) 选择并绑定文件")
                .accessibilityHint("文件会先通过安全导入检查")
                .accessibilityIdentifier(
                    "sound-packs.event.\(row.event.rawValue).choose-and-bind")
                Button("清除绑定", role: .destructive) {
                    model.clearSelectedEventBinding(row.event)
                }
                .disabled(!hasBinding(row.coverage))
                .accessibilityLabel("清除 \(row.event.displayName) 的声音绑定")
                .accessibilityHint("只移除 manifest 映射，不删除音频文件")
                .accessibilityIdentifier(
                    "sound-packs.event.\(row.event.rawValue).clear-binding")
                Button("在访达中显示") {
                    revealMappedAudio(for: row.event)
                }
                .disabled(!row.coverage.previewEnabled)
                .accessibilityLabel("在访达中显示 \(row.event.displayName) 的声音文件")
                .accessibilityHint("定位当前映射的安全包内文件")
                .accessibilityIdentifier(
                    "sound-packs.event.\(row.event.rawValue).reveal-mapping")
            } label: {
                Text(mappingText(row.coverage))
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: ClaudioTheme.Metrics.compactControlHeight)
            .focused($focusedTarget, equals: .eventAudio(row.event))
            .accessibilityLabel("\(row.event.displayName) 的声音映射")
            .accessibilityValue(mappingText(row.coverage))
            .accessibilityHint("选择已有文件、绑定新文件、清除绑定或在访达中显示")
            .accessibilityIdentifier("sound-packs.event.\(row.event.rawValue).mapping")
        } else {
            mappingValue(row.coverage)
                .accessibilityLabel("\(row.event.displayName) 的声音映射")
                .accessibilityValue(mappingText(row.coverage))
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
                        Button(event.displayName) {
                            model.assignSelectedAudioFile(file.fileName, to: event)
                        }
                        .accessibilityLabel(
                            "把 \(file.fileName) 分配给 \(event.displayName)")
                        .accessibilityIdentifier(
                            "sound-packs.orphan.\(file.fileName).event.\(event.rawValue)")
                    }
                }
                .frame(minHeight: ClaudioTheme.Metrics.compactControlHeight)
                .focused(
                    $focusedTarget,
                    equals: .orphanAssignment(fileName: file.fileName))
                .accessibilityLabel("分配 \(file.fileName)")
                .accessibilityValue("尚未被事件使用")
                .accessibilityHint("选择要使用这个音频的事件")
                .accessibilityIdentifier("sound-packs.orphan.\(file.fileName).assign")

                Button("删除") {
                    if let selectedPackID = model.selectedPackID {
                        pendingPermanentDeletion = PermanentAudioDeletionRequest(
                            packID: selectedPackID,
                            file: file)
                    }
                }
                .frame(minHeight: ClaudioTheme.Metrics.compactControlHeight)
                .focused(
                    $focusedTarget,
                    equals: .orphanDeletion(fileName: file.fileName))
                .accessibilityLabel("永久删除 \(file.fileName)")
                .accessibilityValue("尚未被事件使用")
                .accessibilityHint("会先显示不可撤销的确认")
                .accessibilityIdentifier("sound-packs.orphan.\(file.fileName).delete")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func windowFailureRow(action: String, reason: String) -> some View {
        FailureRow(message: reason)
        .accessibilityLabel(
            soundPacksWindowFailureAccessibilityLabel(action: action, reason: reason))
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
        case .allFactoryPacks:
            return
                "将恢复全部缺失或损坏的内置声音包。每个现有目录都会先完整搬到同级隐藏位置，"
                + "一个文件都不会删除；部分失败会逐项列出。"
        }
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

    private func previewAvailability(for row: EventRow) -> EventPreviewAvailability {
        eventPreviewAvailability(
            coverage: row.coverage,
            masterVolume: model.config.masterVolume)
    }

    private func playPreview(for row: EventRow) {
        guard let resolvedFile = model.previewFileForSelectedEvent(row.event) else { return }
        previewPlayer.play(
            fileAt: resolvedFile,
            volume: Float(previewVolume(for: model.config)))
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
            editableEvents: canEditSelectedPack ? model.selectedEventRows.map(\.event) : [],
            previewableEvents: model.selectedEventRows.filter {
                previewAvailability(for: $0).isAvailable
            }.map(\.event),
            orphanFileNames: canEditSelectedPack
                ? model.selectedAudioFiles.filter(\.isOrphan).map(\.fileName) : [],
            canEditSelectedPack: canEditSelectedPack,
            canForkFactoryPack: model.selectedPackIsBuiltinReadOnly,
            canAddAudio: canEditSelectedPack,
            canRestoreFactoryPack: model.selectedPackIsBuiltinReadOnly,
            canUseSelectedPack: selectedCard?.isSelected == false,
            canRestoreAllFactoryPacks: model.packCards.isEmpty && model.hasFactoryPacks,
            canRevealPacksDirectory: model.packCards.isEmpty && !model.hasFactoryPacks,
            retryFactoryRestorePackIDs: model.factoryRestoreRetryPackIDs)
    }

    private func applyInitialFocus() {
        switch requestedRoute {
        case .overview:
            focusedTarget = soundPacksWindowFirstFocusTarget(focusScope)
        case .editEvent(_, let event):
            if canEditSelectedPack {
                focusedTarget = .eventAudio(event)
            } else if focusScope.previewableEvents.contains(event) {
                focusedTarget = .eventPreview(event)
            } else {
                focusedTarget = soundPacksWindowFirstFocusTarget(focusScope)
            }
        }
    }

    private func reconcileFocusWithVisibleControls() {
        let order = soundPacksWindowFocusOrder(focusScope)
        if let focusedTarget, !order.contains(focusedTarget) {
            self.focusedTarget = order.first
        }
    }

    private var typeSizeTier: SoundPacksWindowTypeSizeTier {
        switch interfaceTextSize {
        case .compact, .standard: .standard
        case .large: .enlarged
        case .maximum: .accessibility
        }
    }

    private var interfaceTextSize: ClaudioInterfaceTextSize {
        ClaudioInterfaceTextSize(storedValue: interfaceTextSizeRaw)
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

    private func hasBinding(_ coverage: CoverageState) -> Bool {
        if case .unmapped = coverage { return false }
        return true
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

    private func packAccessibilityValue(_ card: PackCard) -> String {
        var values: [String] = []
        if model.selectedPackID == card.id { values.append("正在查看") }
        if model.starredPackIDs.contains(card.id) { values.append("显示在主面板") }
        if card.isSelected { values.append("使用中") }
        return values.isEmpty ? "未固定，未使用" : values.joined(separator: "，")
    }
}
