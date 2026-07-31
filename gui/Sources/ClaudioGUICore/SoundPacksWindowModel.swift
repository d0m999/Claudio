import ClaudioCore
import Combine
import Foundation

public enum SoundPacksWindowAudioActionError: Error, Sendable, Equatable {
    case noSelectedPack
    case selectionChanged
    case builtinReadOnly(packID: String)
    case notInInventory(fileName: String)
    case bind(ManifestBindError)
    case delete(OrphanAudioDeleteError)

    public var message: String {
        switch self {
        case .noSelectedPack:
            return "没有选中的声音包。"
        case .selectionChanged:
            return "正在查看的声音包已经改变，未删除任何文件；请在当前包里重新选择。"
        case .builtinReadOnly:
            return "内置声音包是只读的；请先复制为我的包，再修改音频。"
        case .notInInventory(let fileName):
            return "「\(fileName)」已不在这个声音包的可用音频列表里，请刷新后重试。"
        case .bind(let error):
            return soundPacksWindowBindErrorMessage(error)
        case .delete(let error):
            return soundPacksWindowDeleteErrorMessage(error)
        }
    }
}

private func soundPacksWindowBindErrorMessage(_ error: ManifestBindError) -> String {
    switch error {
    case .packNotFound(let packID):
        return "声音包「\(packID)」已找不到，无法分配音频。"
    case .unsafeFileName:
        return "这个音频文件名不安全，无法写入声音包清单。"
    case .fileNotFound(let fileName):
        return "音频「\(fileName)」已不在声音包里。"
    case .manifestUnreadable(let reason):
        return "manifest.json 无法安全读取，分配已中止：\(reason)"
    case .writeFailed(let reason):
        return "无法写入声音包清单：\(reason)"
    case .lockBusy:
        return "声音包正被另一个操作占用，请稍后重试。"
    case .lockFailed(let errno):
        return "无法取得声音包锁（errno \(errno)）。"
    }
}

private func soundPacksWindowDeleteErrorMessage(_ error: OrphanAudioDeleteError) -> String {
    switch error {
    case .builtinReadOnly:
        return "内置声音包是只读的；请先复制为我的包，再删除音频。"
    case .packNotFound(let packID):
        return "声音包「\(packID)」已找不到，未删除任何文件。"
    case .manifestUnreadable(let reason):
        return "manifest.json 无法安全读取，未删除任何文件：\(reason)"
    case .directoryUnreadable(let reason):
        return "声音包目录无法读取，未删除任何文件：\(reason)"
    case .unsafeFileName:
        return "这个音频文件名不安全，未删除任何文件。"
    case .fileNotFound(let fileName):
        return "音频「\(fileName)」已经不在声音包里。"
    case .stillReferenced(let fileName):
        return "音频「\(fileName)」仍被事件引用，不能删除。"
    case .deleteFailed(let reason):
        return "永久删除失败：\(reason)"
    case .lockBusy:
        return "声音包正被另一个操作占用，未删除任何文件。"
    case .lockFailed(let errno):
        return "无法取得声音包锁（errno \(errno)），未删除任何文件。"
    }
}

public enum SoundPacksWindowFactoryRestoreActionError: Error, Sendable, Equatable {
    case noSelectedPack
    case selectionChanged
    case notBuiltin(packID: String)
    /// The attempted pack id is retained even when a partial publish failure removes that pack
    /// from the visible library and the window must fall back to another selection. Every old
    /// tree salvaged during later retries remains attached throughout the lifecycle.
    case restore(
        packID: String,
        error: FactoryPackRestoreError,
        retainedSalvages: [SalvagedPack]
    )

    public var message: String {
        switch self {
        case .noSelectedPack:
            return "没有选中的声音包，未恢复任何内容。"
        case .selectionChanged:
            return "正在查看的声音包已经改变，未恢复任何内容；请在当前包里重新确认。"
        case .notBuiltin:
            return "只有内置声音包可以恢复出厂声音。"
        case .restore(let packID, let error, let retainedSalvages):
            return
                "声音包「\(packID)」："
                + factoryPackRestoreErrorMessage(
                    error,
                    retainedSalvages: retainedSalvages)
        }
    }
}

/// The visible success notice for a factory restore. A non-`nil` salvage path is deliberately
/// embedded verbatim: moving the old tree without telling the user where it went would be a
/// silent data-loss experience even though no bytes were deleted.
public func factoryPackRestoreNoticeMessage(
    _ outcome: FactoryPackRestoreOutcome
) -> String {
    if !outcome.retainedSalvages.isEmpty {
        return
            "「\(outcome.restoredPackID)」已恢复为出厂版本。恢复前的内容已原样搬到 "
            + outcome.retainedSalvages.map(\.movedTo).joined(separator: "；")
            + "；一个文件都没删。"
    }
    return
        "「\(outcome.restoredPackID)」已恢复为出厂版本。此前没有已安装内容，"
        + "因此没有文件需要搬走。"
}

private func factoryPackRestoreErrorMessage(
    _ error: FactoryPackRestoreError,
    retainedSalvages: [SalvagedPack]
) -> String {
    let message: String
    switch error {
    case .unsafePackID:
        message = "声音包标识不安全，恢复已中止，磁盘内容未更改。"
    case .factoryUnavailable:
        message = "当前构建没有可用的出厂声音来源，磁盘内容未更改。请重新安装 Claudio 后再试。"
    case .notBuiltinPack:
        message = "这个声音包不是内置包，不能恢复出厂声音。"
    case .unsafeFactorySource:
        message = "出厂声音来源不是安全的真实目录，恢复已中止，当前安装未更改。请重新安装 Claudio。"
    case .invalidFactoryContents(let reason):
        message = "出厂声音内容不完整，恢复已中止，当前安装未更改。请重新安装 Claudio：\(reason)"
    case .stagingFailed(let reason):
        message = "无法准备完整的出厂副本，当前安装未更改：\(reason)"
    case .salvageFailed(let reason):
        message = "恢复前的内容无法安全搬走，因此没有替换任何东西：\(reason)"
    case .publishFailed(let reason, let salvaged):
        if let salvaged {
            let allSalvages = appendingFactoryPackRestoreSalvage(
                salvaged,
                to: retainedSalvages)
            return
                "出厂副本未能发布。恢复前的内容已原样搬到 "
                + allSalvages.map(\.movedTo).joined(separator: "；")
                + "；"
                + "一个文件都没删。请保留该目录并重试：\(reason)"
        } else if !retainedSalvages.isEmpty {
            return
                "出厂副本仍未能发布。已搬走的内容仍原样保留在 "
                + retainedSalvages.map(\.movedTo).joined(separator: "；")
                + "；一个文件都没删。请保留该目录并重试：\(reason)"
        }
        return "出厂副本未能发布，且没有旧内容需要搬走。请重试：\(reason)"
    }
    guard !retainedSalvages.isEmpty else { return message }
    return
        message
        + " 已搬走的内容仍原样保留在 "
        + retainedSalvages.map(\.movedTo).joined(separator: "；")
        + "；一个文件都没删。"
}

private func factoryPackRestoreSalvage(
    in error: FactoryPackRestoreError
) -> SalvagedPack? {
    guard case .publishFailed(_, let salvaged) = error else { return nil }
    return salvaged
}

/// 管理窗口的磁盘读模型。它列出完整包库，不应用面板的星标显示集，也不持有 `NSWindow`。
///
/// 所有 reload 与未来写 completion 都在 `@MainActor` 同步完成。窗口自己的 config/manifest 写者
/// 必须先完成落盘，再调用 ``completeSynchronousWrite(_:)``；这个 API 不接受 async closure，
/// 因而不会把「刷新已发布」与「字节尚未落盘」拆成两个时刻。
@MainActor
public final class SoundPacksWindowModel: ObservableObject {
    @Published public private(set) var configState: PanelConfigState
    @Published public private(set) var config: ClaudioConfig
    @Published public private(set) var packCards: [PackCard]
    @Published public private(set) var selectedPackID: String?
    @Published public private(set) var selectedEventRows: [EventRow]
    /// Selected pack only: one shallow `readdir`, never one scan per event row or per pack card.
    @Published public private(set) var selectedAudioFiles: [PackAudioFile]
    @Published public private(set) var audioInventoryError: PackAudioInventoryError?
    /// The full, uncapped window-side star selection (`starred_packs ∩ disk`). This deliberately
    /// does not reuse the panel's four-row display set: a manually written fifth star must remain
    /// visible here so the user can remove it without silently truncating config.json.
    @Published public private(set) var starredPackIDs: [String]
    /// A rejected T16 star write remains visible at window level even if the selected pack changes
    /// or the panel has zero rows. The View renders the exact reason through the shared FailureRow.
    @Published public private(set) var starredPacksError: SetStarredPacksError?
    /// The most recent assignment/deletion failure. The window renders this in-place and clears it
    /// only after a later successful audio action or a different pack selection.
    @Published public private(set) var audioActionError: SoundPacksWindowAudioActionError?
    /// A successful restore remains visible until the user selects a different pack or starts a
    /// later restore. It carries the exact salvage path whenever an old tree was moved.
    @Published public private(set) var factoryRestoreNotice: FactoryPackRestoreOutcome?
    /// Restore has its own failure surface so a failed replacement never masquerades as an audio
    /// assignment/deletion error.
    @Published public private(set) var factoryRestoreActionError:
        SoundPacksWindowFactoryRestoreActionError?

    /// The built-in id whose restore lifecycle can be retried even when its visible installed
    /// directory no longer exists and therefore cannot appear in ``packCards``. After the first
    /// partial publish failure, later failures remain retryable while the retained salvage is live.
    public var factoryRestoreRetryPackID: String? {
        guard
            case .restore(let packID, let error, let retainedSalvages)? =
                factoryRestoreActionError
        else {
            return nil
        }
        if !retainedSalvages.isEmpty {
            return packID
        }
        if case .publishFailed = error {
            return packID
        }
        return nil
    }

    public var selectedPackIsBuiltinReadOnly: Bool {
        selectedPackID.map(builtinPackIDs.contains) ?? false
    }

    public var starredPacksFailureReason: String? {
        starredPacksError.map(soundPacksWindowStarredPacksFailureReason)
    }

    private let configFile: URL
    private let lockFile: URL
    private let environment: AudioImportEnvironment
    /// Factory contents are app-bundle-static for this model's lifetime. Cache the one derivation
    /// so SwiftUI body evaluation never turns a read-only check into repeated factory `readdir`.
    private let builtinPackIDs: Set<String>
    private let refreshCoordinator: SoundPacksRefreshCoordinator
    private var windowRefreshCancellable: AnyCancellable?
    private var windowContentRefreshCancellable: AnyCancellable?

    private var factoryRestoreRetainedSalvages: [SalvagedPack] {
        guard case .restore(_, _, let retainedSalvages)? = factoryRestoreActionError
        else {
            return []
        }
        return retainedSalvages
    }

    public init(
        configFile: URL,
        lockFile: URL = ClaudioPaths.configLockFile,
        environment: AudioImportEnvironment,
        refreshCoordinator: SoundPacksRefreshCoordinator
    ) {
        self.configFile = configFile
        self.lockFile = lockFile
        self.environment = environment
        self.builtinPackIDs = environment.builtinPackIDs
        self.refreshCoordinator = refreshCoordinator

        let loadedState = loadPanelConfig(from: configFile)
        let loadedConfig = loadedState.resolvedConfig
        let loadedCards = availablePacks(config: loadedConfig, environment: environment)
        let initialSelection =
            loadedCards.contains(where: { $0.id == loadedConfig.selectedPack })
            ? loadedConfig.selectedPack
            : loadedCards.first?.id

        configState = loadedState
        config = loadedConfig
        packCards = loadedCards
        starredPackIDs = soundPacksWindowStarredPackIDs(
            installedPackIDs: loadedCards.map(\.id),
            starredPacks: loadedConfig.starredPacks,
            defaultStarredPackIDs: builtinPackIDs)
        selectedPackID = initialSelection
        selectedEventRows =
            initialSelection.map {
                packCoverage(packID: $0, config: loadedConfig, environment: environment)
            } ?? []
        let initialAudioInventory = initialSelection.map {
            packAudioFiles(packID: $0, environment: environment)
        }
        switch initialAudioInventory {
        case .success(let files)?:
            selectedAudioFiles = files
            audioInventoryError = nil
        case .failure(let error)?:
            selectedAudioFiles = []
            audioInventoryError = error
        case nil:
            selectedAudioFiles = []
            audioInventoryError = nil
        }
        audioActionError = nil
        starredPacksError = nil
        factoryRestoreNotice = nil
        factoryRestoreActionError = nil

        windowRefreshCancellable = refreshCoordinator.$windowReloadRevision
            .dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reload(followActivePack: true)
                }
            }
        windowContentRefreshCancellable = refreshCoordinator.$windowContentReloadRevision
            .dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reload(followActivePack: false)
                }
            }
    }

    /// 侧栏只改变窗口正在查看的包，不写 config，也不改变面板当前包。
    public func selectPackForInspection(_ packID: String) {
        guard packCards.contains(where: { $0.id == packID }) else { return }
        selectedPackID = packID
        selectedEventRows = packCoverage(
            packID: packID, config: config, environment: environment)
        reloadSelectedAudioInventory(packID: packID)
        audioActionError = nil
        factoryRestoreNotice = nil
        factoryRestoreActionError = nil
    }

    /// The star state for one full-library sidebar row. Existing stars stay removable even when a
    /// malformed hand edit exceeds four, while new stars are explicitly disabled at the shared cap.
    public func starControl(for card: PackCard) -> SoundPacksWindowStarControl {
        soundPacksWindowStarControl(
            packID: card.id,
            rawStarredPackIDs: starredPackIDs,
            isPackBroken: {
                if case .broken = card.state { return true }
                return false
            }())
    }

    /// Toggle one sidebar star. SwiftUI calls this only for an enabled `★` / `☆` button; the
    /// writer remains the authoritative >4 guard for stale or programmatic callers.
    @discardableResult
    public func toggleStarredPack(
        _ packID: String
    ) -> Result<SetStarredPacksOutcome, SetStarredPacksError> {
        let nextIDs: [String]
        if starredPackIDs.contains(packID) {
            nextIDs = starredPackIDs.filter { $0 != packID }
        } else {
            nextIDs = starredPackIDs + [packID]
        }
        return updateStarredPacks(to: nextIDs)
    }

    /// Performs T16's one public writer and publishes a full two-surface refresh only after the
    /// synchronous config write succeeds. This method is public so the write/error seam remains
    /// directly testable without importing the SwiftUI window target; the view only invokes it via
    /// ``toggleStarredPack(_:)``.
    @discardableResult
    public func updateStarredPacks(
        to ids: [String]
    ) -> Result<SetStarredPacksOutcome, SetStarredPacksError> {
        let result = setStarredPacks(
            ids,
            configFile: configFile,
            lockFile: lockFile,
            userPacksDirectory: environment.userPacksDirectory,
            defaultStarredPackIDs: builtinPackIDs,
            materializeDefaultStarredPacks: false)
        switch result {
        case .success:
            starredPacksError = nil
            completeSynchronousWrite(.succeeded)
        case .failure(let error):
            starredPacksError = error
            completeSynchronousWrite(.failed)
        }
        return result
    }

    /// 窗口即将展示或已收到外部切包通知时重读磁盘。
    ///
    /// `followActivePack == true` 只用于「popover 刚成功切包」与首次展示；普通窗口内写保留用户
    /// 正在查看的侧栏项，不把一次 manifest 编辑误当成选包动作。
    public func reload(followActivePack: Bool) {
        let previousSelection = selectedPackID
        let loadedState = loadPanelConfig(from: configFile)
        let loadedConfig = loadedState.resolvedConfig
        let loadedCards = availablePacks(config: loadedConfig, environment: environment)

        let nextSelection: String?
        if followActivePack,
            loadedCards.contains(where: { $0.id == loadedConfig.selectedPack })
        {
            nextSelection = loadedConfig.selectedPack
        } else if let previousSelection,
            loadedCards.contains(where: { $0.id == previousSelection })
        {
            nextSelection = previousSelection
        } else if loadedCards.contains(where: { $0.id == loadedConfig.selectedPack }) {
            nextSelection = loadedConfig.selectedPack
        } else {
            nextSelection = loadedCards.first?.id
        }
        if nextSelection != previousSelection {
            audioActionError = nil
            factoryRestoreNotice = nil
            factoryRestoreActionError = nil
        }

        configState = loadedState
        config = loadedConfig
        packCards = loadedCards
        starredPackIDs = soundPacksWindowStarredPackIDs(
            installedPackIDs: loadedCards.map(\.id),
            starredPacks: loadedConfig.starredPacks,
            defaultStarredPackIDs: builtinPackIDs)
        selectedPackID = nextSelection
        selectedEventRows =
            nextSelection.map {
                packCoverage(packID: $0, config: loadedConfig, environment: environment)
            } ?? []
        if let nextSelection {
            reloadSelectedAudioInventory(packID: nextSelection)
        } else {
            selectedAudioFiles = []
            audioInventoryError = nil
        }
    }

    /// Assigns one already-enumerated pack audio file via T3's sole bind primitive.
    @discardableResult
    public func assignSelectedAudioFile(
        _ fileName: String,
        to event: Event
    ) -> Result<Void, SoundPacksWindowAudioActionError> {
        guard let selectedPackID else {
            return finishAudioAction(.failure(.noSelectedPack))
        }
        guard !builtinPackIDs.contains(selectedPackID) else {
            return finishAudioAction(.failure(.builtinReadOnly(packID: selectedPackID)))
        }
        guard selectedAudioFiles.contains(where: { $0.fileName == fileName }) else {
            return finishAudioAction(.failure(.notInInventory(fileName: fileName)))
        }

        switch bindEventToManifest(
            event: event,
            fileName: fileName,
            packID: selectedPackID,
            environment: environment)
        {
        case .success:
            return finishAudioAction(.success(()))
        case .failure(let error):
            return finishAudioAction(.failure(.bind(error)))
        }
    }

    /// Executes the irreversible deletion only after the SwiftUI confirmation has completed.
    ///
    /// The explicit method name keeps this action out of any reversible bind/clear path. The core
    /// function re-reads the manifest under `packs.lock`, so confirmation against a stale row still
    /// cannot delete a file that became referenced in the meantime.
    @discardableResult
    public func deleteSelectedOrphanAudioFileAfterConfirmation(
        _ fileName: String,
        expectedPackID: String
    ) -> Result<Void, SoundPacksWindowAudioActionError> {
        guard let selectedPackID else {
            return finishAudioAction(.failure(.noSelectedPack))
        }
        guard selectedPackID == expectedPackID else {
            return finishAudioAction(.failure(.selectionChanged))
        }

        switch deleteOrphanAudioFile(
            fileName: fileName,
            packID: selectedPackID,
            environment: environment)
        {
        case .success:
            return finishAudioAction(.success(()))
        case .failure(let error):
            if deleteFailureInvalidatesWindowReadModel(error) {
                // The lock-time check has disproved the confirmation-time snapshot. Re-read every
                // window-owned projection (cards, event rows, and inventory) without publishing a
                // fake local write completion to the panel.
                reload(followActivePack: false)
            }
            return finishAudioAction(.failure(.delete(error)))
        }
    }

    /// Executes the directory replacement only after the window's explicit confirmation.
    ///
    /// The expected id prevents a stale confirmation from restoring a newly-selected pack. The
    /// success path publishes the returned salvage outcome after the shared full reload, so a
    /// selection repaired by that reload cannot clear the user-visible path.
    @discardableResult
    public func restoreSelectedFactoryPackAfterConfirmation(
        expectedPackID: String
    ) -> Result<FactoryPackRestoreOutcome, SoundPacksWindowFactoryRestoreActionError> {
        guard let selectedPackID else {
            return finishFactoryRestore(.failure(.noSelectedPack))
        }
        guard selectedPackID == expectedPackID else {
            return finishFactoryRestore(.failure(.selectionChanged))
        }
        guard builtinPackIDs.contains(selectedPackID) else {
            return finishFactoryRestore(.failure(.notBuiltin(packID: selectedPackID)))
        }

        return restoreFactoryPackAfterConfirmation(packID: selectedPackID)
    }

    /// Retries a failed factory publish using the id retained by the window-level failure state.
    ///
    /// This path deliberately does not depend on `selectedPackID`: after salvage succeeds and
    /// publish fails, the attempted built-in no longer has an installed directory and cannot be a
    /// selectable `PackCard`. The pending failure identity is revalidated at confirmation time so a
    /// stale dialog cannot restore an unrelated pack.
    @discardableResult
    public func retryFailedFactoryPackRestoreAfterConfirmation(
        expectedPackID: String
    ) -> Result<FactoryPackRestoreOutcome, SoundPacksWindowFactoryRestoreActionError> {
        guard factoryRestoreRetryPackID == expectedPackID else {
            return finishFactoryRestore(.failure(.selectionChanged))
        }
        guard builtinPackIDs.contains(expectedPackID) else {
            return finishFactoryRestore(.failure(.notBuiltin(packID: expectedPackID)))
        }
        return restoreFactoryPackAfterConfirmation(
            packID: expectedPackID,
            retainedSalvages: factoryRestoreRetainedSalvages)
    }

    private func restoreFactoryPackAfterConfirmation(
        packID: String,
        retainedSalvages: [SalvagedPack] = []
    ) -> Result<FactoryPackRestoreOutcome, SoundPacksWindowFactoryRestoreActionError> {
        switch restoreFactoryPack(id: packID, environment: environment) {
        case .success(let outcome):
            let visibleOutcome = FactoryPackRestoreOutcome(
                restoredPackID: outcome.restoredPackID,
                salvaged: retainedSalvages.first ?? outcome.salvaged,
                retainedSalvages: appendingFactoryPackRestoreSalvage(
                    outcome.salvaged,
                    to: retainedSalvages))
            return finishFactoryRestore(.success(visibleOutcome))
        case .failure(let error):
            let diskChangedDespiteFailure = factoryPackRestoreSalvage(in: error) != nil
            return finishFactoryRestore(
                .failure(
                    .restore(
                        packID: packID,
                        error: error,
                        retainedSalvages: appendingFactoryPackRestoreSalvage(
                            factoryPackRestoreSalvage(in: error),
                            to: retainedSalvages))),
                diskChangedDespiteFailure: diskChangedDespiteFailure)
        }
    }

    private func finishAudioAction(
        _ result: Result<Void, SoundPacksWindowAudioActionError>
    ) -> Result<Void, SoundPacksWindowAudioActionError> {
        switch result {
        case .success:
            audioActionError = nil
            completeSynchronousWrite(.succeeded)
        case .failure(let error):
            audioActionError = error
            completeSynchronousWrite(.failed)
        }
        return result
    }

    private func finishFactoryRestore(
        _ result: Result<
            FactoryPackRestoreOutcome,
            SoundPacksWindowFactoryRestoreActionError
        >,
        diskChangedDespiteFailure: Bool = false
    ) -> Result<FactoryPackRestoreOutcome, SoundPacksWindowFactoryRestoreActionError> {
        switch result {
        case .success(let outcome):
            factoryRestoreActionError = nil
            completeSynchronousWrite(.succeeded)
            // A retry can make a previously absent pack selectable again. `reload` correctly
            // clears old pack-scoped status when that changes selection, so publish the success
            // notice after the reload to keep the new outcome visible.
            factoryRestoreNotice = outcome
        case .failure(let error):
            let outcome: SoundPacksWindowWriteOutcome
            if diskChangedDespiteFailure {
                // The original tree is now safely in salvage, so the visible pack path changed
                // even though publishing the factory copy failed. Reload both UIs before keeping
                // the error visible; otherwise they would continue to show a pack that no longer
                // exists at the active path.
                outcome = .changedDespiteFailure
                completeSynchronousWrite(outcome)
            } else {
                outcome = .failed
            }
            factoryRestoreNotice = nil
            factoryRestoreActionError = error
            if outcome == .failed {
                completeSynchronousWrite(outcome)
            }
        }
        return result
    }

    private func deleteFailureInvalidatesWindowReadModel(
        _ error: OrphanAudioDeleteError
    ) -> Bool {
        switch error {
        case .packNotFound, .manifestUnreadable, .directoryUnreadable, .fileNotFound,
            .stillReferenced:
            return true
        case .builtinReadOnly, .unsafeFileName, .deleteFailed, .lockBusy, .lockFailed:
            return false
        }
    }

    private func reloadSelectedAudioInventory(packID: String) {
        switch packAudioFiles(packID: packID, environment: environment) {
        case .success(let files):
            selectedAudioFiles = files
            audioInventoryError = nil
        case .failure(let error):
            selectedAudioFiles = []
            audioInventoryError = error
        }
    }

    /// 窗口内一个同步写者的统一 completion。
    ///
    /// 成功或失败前已经改变磁盘时，先刷新窗口自己的读模型，再发布面板 full reload；没有落盘变化
    /// 的失败两边都不假刷新。未来 T11/T12/T17 的每个写者都应收口到这里，而不是各自选择
    /// `reloadConfigOnly()`。
    @discardableResult
    public func completeSynchronousWrite(
        _ outcome: SoundPacksWindowWriteOutcome
    ) -> SoundPacksRefreshEffect {
        if outcome != .failed {
            reload(followActivePack: false)
        }
        return refreshCoordinator.completeWindowWrite(outcome)
    }
}

private func appendingFactoryPackRestoreSalvage(
    _ salvaged: SalvagedPack?,
    to retainedSalvages: [SalvagedPack]
) -> [SalvagedPack] {
    guard let salvaged, !retainedSalvages.contains(salvaged) else {
        return retainedSalvages
    }
    return retainedSalvages + [salvaged]
}
