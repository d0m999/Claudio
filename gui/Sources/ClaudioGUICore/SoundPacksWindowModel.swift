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
    case importRejected(message: String)

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
        case .importRejected(let message):
            return message
        }
    }
}

public enum SoundPacksWindowStatusSeverity: Int, Sendable, Equatable {
    case failure
    case notice
}

public enum SoundPacksWindowStatusKind: String, Sendable, Equatable, Hashable {
    case audio
    case factoryRestore
    case factoryBatchRestore
    case starredPacks
    case packFork
    case packUse
}

public enum SoundPacksWindowStatusRecovery: Sendable, Equatable {
    case retryFactoryRestores(packIDs: [String])
}

/// One model-owned status projection. The View sorts nothing and invents no lifetime rules.
public struct SoundPacksWindowStatus: Identifiable, Sendable, Equatable {
    public let kind: SoundPacksWindowStatusKind
    public let severity: SoundPacksWindowStatusSeverity
    public let revision: Int
    public let action: String
    public let message: String
    public let packID: String?
    public let actionID: Int?
    public let recovery: SoundPacksWindowStatusRecovery?

    public var id: Int { revision }
}

public struct PackForkOutcome: Sendable, Equatable {
    public let sourcePackID: String
    public let newPackID: String
    public let displayName: String
}

public enum SoundPacksWindowPackForkActionError: Error, Sendable, Equatable {
    case noSelectedPack
    case notBuiltin(packID: String)
    case occupancyReadFailed(reason: String)
    case allocation(PackForkIDAllocationError)
    case fork(PackForkError)
    case destinationAllocationExhausted(attempts: Int)
    case publishedButUnavailable(newID: String)

    public var message: String {
        switch self {
        case .noSelectedPack:
            return "没有选中的内置声音包，未创建任何副本。"
        case .notBuiltin:
            return "只有内置声音包需要复制；当前包已经可以直接编辑。"
        case .occupancyReadFailed(let reason):
            return "无法安全检查已有声音包名称，未创建任何副本：\(reason)"
        case .allocation(let error):
            return "无法分配安全且有限的新声音包名称，未覆盖任何文件：\(error)"
        case .destinationAllocationExhausted(let attempts):
            return "连续 \(attempts) 次发布都遇到外部占用；未覆盖任何现有文件，请稍后重试。"
        case .publishedButUnavailable(let newID):
            return "副本「\(newID)」已经安全写入，但暂时无法在窗口中读取；请在访达中检查后重开窗口。"
        case .fork(let error):
            return packForkFailureMessage(error)
        }
    }
}

private func packForkFailureMessage(_ error: PackForkError) -> String {
    switch error {
    case .unsafeNewID:
        return "生成的副本名称不安全，未写入或覆盖任何文件。"
    case .unsafeSourceID:
        return "内置声音包标识不安全，未写入或覆盖任何文件。"
    case .destinationAlreadyExists:
        return "目标名称刚被其他操作占用；未覆盖该项目，请重试。"
    case .sourceUnavailable:
        return "当前构建没有可复制的出厂声音，请重新安装 claudi0 后再试。"
    case .unsafeFactorySource:
        return "出厂声音来源不是安全的真实目录；未创建副本，请重新安装 claudi0。"
    case .copyFailed(let reason):
        return "准备完整副本失败，未发布半成品：\(reason)"
    case .manifestRewriteFailed(let reason):
        return "副本清单无法安全改写，暂存内容已清理：\(reason)"
    case .renameFailed(let reason):
        return "副本最终发布失败，未覆盖任何现有项目：\(reason)"
    }
}

public func packForkNoticeMessage(_ outcome: PackForkOutcome) -> String {
    "已创建并选中「\(outcome.displayName)」。原内置包未更改；当前使用的包与面板显示未改变。"
        + "需要时点「用这个包」或左侧星标。"
}

public struct SoundPacksWindowAudioImportCompletion: Sendable, Equatable {
    public let targetPackID: String
    public let result: AudioImportBatchResult
    public let previewFile: ImportedAudioFile?
    public let completedInBackground: Bool
}

public enum SoundPacksWindowPackUseActionError: Error, Sendable, Equatable {
    case noSelectedPack
    case use(UseError)

    public var message: String {
        switch self {
        case .noSelectedPack: return "没有选中的声音包，当前使用项未改变。"
        case .use(let error): return error.description
        }
    }
}

public struct FactoryPackBatchRestoreFailure: Sendable, Equatable {
    public let packID: String
    public let error: FactoryPackRestoreError
    public let retainedSalvages: [SalvagedPack]

    public init(
        packID: String,
        error: FactoryPackRestoreError,
        retainedSalvages: [SalvagedPack] = []
    ) {
        self.packID = packID
        self.error = error
        self.retainedSalvages = retainedSalvages
    }
}

public struct FactoryPackBatchRestoreOutcome: Sendable, Equatable {
    public let restoredPacks: [FactoryPackRestoreOutcome]
    public let failures: [FactoryPackBatchRestoreFailure]

    public var restoredPackIDs: [String] {
        restoredPacks.map(\.restoredPackID)
    }

    /// Every pre-existing entry retained by successful restores in this batch.
    /// Failure-side salvages remain attached to their typed errors and visible status text.
    public var retainedSalvages: [SalvagedPack] {
        restoredPacks.flatMap(\.retainedSalvages)
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
        message = "当前构建没有可用的出厂声音来源，磁盘内容未更改。请重新安装 claudi0 后再试。"
    case .notBuiltinPack:
        message = "这个声音包不是内置包，不能恢复出厂声音。"
    case .unsafeFactorySource:
        message = "出厂声音来源不是安全的真实目录，恢复已中止，当前安装未更改。请重新安装 claudi0。"
    case .invalidFactoryContents(let reason):
        message = "出厂声音内容不完整，恢复已中止，当前安装未更改。请重新安装 claudi0：\(reason)"
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
/// config 投影与所有写 completion 都在 `@MainActor` 同步完成；声音包读取由共享
/// ``SoundPackLibrary`` 在 actor 外的 utility task 执行。窗口自己的 config/manifest 写者仍必须先
/// 完成落盘，再调用 ``completeSynchronousWrite(_:invalidatingPackIDs:)``；这个 API 不接受 async
/// closure，因而不会把「刷新已发布」与「字节尚未落盘」拆成两个时刻。
@MainActor
public final class SoundPacksWindowModel: ObservableObject {
    @Published public private(set) var configState: PanelConfigState
    @Published public private(set) var config: ClaudioConfig
    @Published public private(set) var packCards: [PackCard]
    @Published public private(set) var selectedPackID: String?
    @Published public private(set) var selectedEventRows: [EventRow]
    /// Selected pack only: one shared, on-demand shallow `readdir`, never one scan per pack card.
    @Published public private(set) var selectedAudioInventoryState:
        SoundPackAudioInventoryPresentationState

    public var selectedAudioFiles: [PackAudioFile] { selectedAudioInventoryState.files }
    public var audioInventoryError: PackAudioInventoryError? {
        selectedAudioInventoryState.error
    }
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
    @Published public private(set) var packForkNotice: PackForkOutcome?
    @Published public private(set) var packForkActionError: SoundPacksWindowPackForkActionError?
    @Published public private(set) var packUseActionError: SoundPacksWindowPackUseActionError?
    @Published public private(set) var windowStatuses: [SoundPacksWindowStatus]
    @Published public private(set) var libraryPresentationState: SoundPackLibraryPresentationState

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

    /// Every failed restore that still has a window-level retry action. Batch failures are kept
    /// independently from the selected card so a successful sibling cannot hide their recovery.
    public var factoryRestoreRetryPackIDs: [String] {
        var ids: [String] = []
        for status in windowStatuses {
            guard case .retryFactoryRestores(let packIDs)? = status.recovery else { continue }
            for packID in packIDs where !ids.contains(packID) {
                ids.append(packID)
            }
        }
        return ids
    }

    public var selectedPackIsBuiltinReadOnly: Bool {
        selectedPackID.map(builtinPackIDs.contains) ?? false
    }

    public var factoryPackIDs: [String] { builtinPackIDs.sorted() }

    public var hasFactoryPacks: Bool { !builtinPackIDs.isEmpty }

    public var starredPacksFailureReason: String? {
        starredPacksError.map(soundPacksWindowStarredPacksFailureReason)
    }

    private let configFile: URL
    private let lockFile: URL
    private let environment: AudioImportEnvironment
    /// Factory contents are app-bundle-static for this model's lifetime. Cache the one derivation
    /// so SwiftUI body evaluation never turns a read-only check into repeated factory `readdir`.
    private var builtinPackIDs: Set<String>
    private let soundPackLibrary: SoundPackLibrary
    private let readSource: SoundPackReadSource
    private var librarySnapshot: SoundPackLibrarySnapshot?
    private var libraryObservationTask: Task<Void, Never>?
    private var audioInventoryTask: Task<Void, Never>?
    private var selectedAudioInventoryPackID: String?
    private var pendingFollowActivePack = true
    private var pendingInspectionPackID: String?
    private let refreshCoordinator: SoundPacksRefreshCoordinator
    private var windowRefreshCancellable: AnyCancellable?
    private var windowContentRefreshCancellable: AnyCancellable?
    private var statusRevision = 0
    private var statusByKind: [SoundPacksWindowStatusKind: SoundPacksWindowStatus] = [:]
    private var audioImportActionRevision = 0
    /// Monotonic identity for the inspection session, not merely its current pack ID. Returning
    /// A→B→A must not let an operation started in the first A session inherit foreground status.
    private var inspectionSelectionRevision = 0
    private var suppressedSelectionAnnouncementPackID: String?
    private var factoryBatchRestoreFailures: [FactoryPackBatchRestoreFailure] = []
    private var factoryBatchRestoredCount = 0
    private var factoryBatchRetainedSalvages: [SalvagedPack] = []

    private var factoryRestoreRetainedSalvages: [SalvagedPack] {
        guard case .restore(_, _, let retainedSalvages)? = factoryRestoreActionError
        else {
            return []
        }
        return retainedSalvages
    }

    public convenience init(
        configFile: URL,
        lockFile: URL = ClaudioPaths.configLockFile,
        environment: AudioImportEnvironment,
        soundPackLibrary: SoundPackLibrary,
        refreshCoordinator: SoundPacksRefreshCoordinator
    ) {
        self.init(
            configFile: configFile,
            lockFile: lockFile,
            environment: environment,
            soundPackLibrary: soundPackLibrary,
            readSource: .sharedLibrary,
            refreshCoordinator: refreshCoordinator)
    }

    #if DEBUG
    /// Synchronous compatibility path for the existing disk mutation harness. The shipped target
    /// has no initializer that can omit the app-lifetime shared library.
    public convenience init(
        configFile: URL,
        lockFile: URL = ClaudioPaths.configLockFile,
        environment: AudioImportEnvironment,
        refreshCoordinator: SoundPacksRefreshCoordinator
    ) {
        self.init(
            configFile: configFile,
            lockFile: lockFile,
            environment: environment,
            soundPackLibrary: SoundPackLibrary(environment: environment),
            readSource: .directDiskFixture,
            refreshCoordinator: refreshCoordinator)
    }
    #endif

    private init(
        configFile: URL,
        lockFile: URL,
        environment: AudioImportEnvironment,
        soundPackLibrary: SoundPackLibrary,
        readSource: SoundPackReadSource,
        refreshCoordinator: SoundPacksRefreshCoordinator
    ) {
        self.configFile = configFile
        self.lockFile = lockFile
        self.environment = environment
        self.soundPackLibrary = soundPackLibrary
        self.readSource = readSource
        self.builtinPackIDs = readSource.readsSharedSnapshot ? [] : environment.builtinPackIDs
        self.refreshCoordinator = refreshCoordinator

        let loadedState = loadPanelConfig(from: configFile)
        let loadedConfig = loadedState.resolvedConfig

        configState = loadedState
        config = loadedConfig
        if !readSource.readsSharedSnapshot {
            let loadedCards = availablePacks(config: loadedConfig, environment: environment)
            let initialSelection =
                loadedCards.contains(where: { $0.id == loadedConfig.selectedPack })
                ? loadedConfig.selectedPack
                : loadedCards.first?.id
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
                selectedAudioInventoryState = .ready(files)
            case .failure(let error)?:
                selectedAudioInventoryState = .failed(previous: nil, error: error)
            case nil:
                selectedAudioInventoryState = .idle
            }
            libraryPresentationState = .ready
        } else {
            packCards = []
            starredPackIDs = []
            selectedPackID = nil
            selectedEventRows = []
            selectedAudioInventoryState = .idle
            libraryPresentationState = .loading
        }
        audioActionError = nil
        starredPacksError = nil
        factoryRestoreNotice = nil
        factoryRestoreActionError = nil
        packForkNotice = nil
        packForkActionError = nil
        packUseActionError = nil
        windowStatuses = []

        windowRefreshCancellable = refreshCoordinator.$windowReloadRevision
            .dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reload(
                        followActivePack: true,
                        refreshSoundPackLibrary:
                            self.refreshCoordinator.windowReloadRequiresLibraryRefresh)
                }
            }
        windowContentRefreshCancellable = refreshCoordinator.$windowContentReloadRevision
            .dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reload(
                        followActivePack: false,
                        refreshSoundPackLibrary:
                            self.refreshCoordinator.windowContentReloadRequiresLibraryRefresh)
                }
            }

        guard readSource.readsSharedSnapshot else { return }
        libraryObservationTask = Task { @MainActor [weak self, soundPackLibrary] in
            let stream = await soundPackLibrary.states()
            await soundPackLibrary.loadIfNeeded(trigger: .initial)
            for await state in stream {
                guard !Task.isCancelled else { return }
                self?.consumeLibraryState(state)
            }
        }
    }

    deinit {
        libraryObservationTask?.cancel()
        audioInventoryTask?.cancel()
    }

    #if DEBUG
    /// Deterministic, disk-free construction for the repository state gallery. The injected
    /// environment is retained only to satisfy action seams; gallery frames never execute them.
    public init(
        previewConfig: ClaudioConfig,
        packCards: [PackCard],
        selectedPackID: String?,
        selectedEventRows: [EventRow],
        selectedAudioFiles: [PackAudioFile] = [],
        builtinPackIDs: Set<String> = [],
        starredPackIDs: [String] = [],
        libraryPresentationState: SoundPackLibraryPresentationState = .ready,
        environment: AudioImportEnvironment,
        refreshCoordinator: SoundPacksRefreshCoordinator
    ) {
        self.configFile = URL(fileURLWithPath: "/dev/null/claudio-preview-config.json")
        self.lockFile = URL(fileURLWithPath: "/dev/null/claudio-preview-config.lock")
        self.environment = environment
        self.builtinPackIDs = builtinPackIDs
        self.soundPackLibrary = SoundPackLibrary(environment: environment)
        self.readSource = .directDiskFixture
        self.refreshCoordinator = refreshCoordinator
        configState = previewConfig.selectedPack.isEmpty ? .needsPack : .operational(previewConfig)
        config = previewConfig
        self.packCards = packCards
        self.selectedPackID = selectedPackID
        self.selectedEventRows = selectedEventRows
        selectedAudioInventoryState = .ready(selectedAudioFiles)
        self.starredPackIDs = starredPackIDs
        starredPacksError = nil
        audioActionError = nil
        factoryRestoreNotice = nil
        factoryRestoreActionError = nil
        packForkNotice = nil
        packForkActionError = nil
        packUseActionError = nil
        windowStatuses = []
        self.libraryPresentationState = libraryPresentationState
    }
    #endif

    /// 侧栏只改变窗口正在查看的包，不写 config，也不改变面板当前包。
    @discardableResult
    public func selectPackForInspection(_ packID: String) -> Bool {
        guard packCards.contains(where: { $0.id == packID }) else { return false }
        pendingFollowActivePack = false
        pendingInspectionPackID = nil
        guard selectedPackID != packID else { return true }
        inspectionSelectionRevision += 1
        selectedPackID = packID
        if !readSource.readsSharedSnapshot {
            selectedEventRows = packCoverage(
                packID: packID, config: config, environment: environment)
        } else {
            selectedEventRows = librarySnapshot?.eventRows(packID: packID, config: config) ?? []
        }
        reloadSelectedAudioInventory(packID: packID)
        audioActionError = nil
        factoryRestoreNotice = nil
        factoryRestoreActionError = nil
        clearWindowStatus(.audio)
        clearWindowStatus(.factoryRestore)
        if packForkNotice?.newPackID != packID {
            packForkNotice = nil
            if packForkActionError == nil { clearWindowStatus(.packFork) }
        }
        return true
    }

    /// The controller calls this from the `selectedPackID` publisher before posting a normal
    /// selection announcement. A fork consumes exactly one matching token, then its compound
    /// success status becomes the sole announcement.
    public func consumeSelectionAnnouncementSuppression(for packID: String?) -> Bool {
        guard let packID, suppressedSelectionAnnouncementPackID == packID else { return false }
        suppressedSelectionAnnouncementPackID = nil
        return true
    }

    @discardableResult
    public func forkSelectedFactoryPack(
        maximumPublishCollisions: Int = 8
    ) -> Result<PackForkOutcome, SoundPacksWindowPackForkActionError> {
        packForkNotice = nil
        packForkActionError = nil
        clearWindowStatus(.packFork)

        guard let sourcePackID = selectedPackID else {
            return finishPackFork(.failure(.noSelectedPack))
        }
        guard builtinPackIDs.contains(sourcePackID) else {
            return finishPackFork(.failure(.notBuiltin(packID: sourcePackID)))
        }

        var occupied: Set<String>
        do {
            occupied = try occupiedPackBasenames(in: environment.userPacksDirectory)
        } catch {
            return finishPackFork(
                .failure(.occupancyReadFailed(reason: error.localizedDescription)))
        }

        let attemptLimit = max(1, maximumPublishCollisions)
        for attempt in 1...attemptLimit {
            let newPackID: String
            switch nextForkPackID(for: sourcePackID, occupiedBasenames: occupied) {
            case .success(let candidate): newPackID = candidate
            case .failure(let error): return finishPackFork(.failure(.allocation(error)))
            }

            beginSoundPackMutation(packIDs: [newPackID])
            switch forkPack(fromID: sourcePackID, newID: newPackID, environment: environment) {
            case .success:
                if readSource.readsSharedSnapshot {
                    pendingInspectionPackID = newPackID
                    suppressedSelectionAnnouncementPackID = newPackID
                    let outcome = PackForkOutcome(
                        sourcePackID: sourcePackID,
                        newPackID: newPackID,
                        displayName: displayName(for: sourcePackID))
                    completeSynchronousWrite(
                        .succeeded,
                        invalidatingPackIDs: [newPackID])
                    return finishPackFork(.success(outcome), publishCompletion: false)
                }
                completeSynchronousWrite(.succeeded)
                guard
                    let card = packCards.first(where: { $0.id == newPackID })
                else {
                    return finishPackFork(
                        .failure(.publishedButUnavailable(newID: newPackID)),
                        publishCompletion: false)
                }
                suppressedSelectionAnnouncementPackID = newPackID
                selectPackForInspection(newPackID)
                let outcome = PackForkOutcome(
                    sourcePackID: sourcePackID,
                    newPackID: newPackID,
                    displayName: SelectedPackMetadata(id: card.id, name: card.name).displayName)
                return finishPackFork(.success(outcome), publishCompletion: false)
            case .failure(.destinationAlreadyExists):
                finishSoundPackMutation(packIDs: [newPackID])
                if readSource.readsSharedSnapshot { reload(followActivePack: false) }
                occupied.insert(newPackID)
                if attempt == attemptLimit {
                    return finishPackFork(
                        .failure(.destinationAllocationExhausted(attempts: attemptLimit)))
                }
            case .failure(let error):
                return finishPackFork(.failure(.fork(error)))
            }
        }
        return finishPackFork(
            .failure(.destinationAllocationExhausted(attempts: attemptLimit)))
    }

    @discardableResult
    public func useSelectedPack() -> Result<UseOutcome, SoundPacksWindowPackUseActionError> {
        packUseActionError = nil
        clearWindowStatus(.packUse)
        guard let selectedPackID else {
            return finishPackUse(.failure(.noSelectedPack))
        }
        let result = selectPack(
            selectedPackID,
            configFile: configFile,
            userPacksDirectory: environment.userPacksDirectory,
            bundledPacksDirectory: environment.bundledPacksDirectory,
            lockFile: lockFile)
        switch result {
        case .success(let outcome): return finishPackUse(.success(outcome))
        case .failure(let error): return finishPackUse(.failure(.use(error)))
        }
    }

    /// Imports picked files off the MainActor while binding completion to the pack and action that
    /// started it. A later selection never inherits this result or its automatic preview.
    public func importSelectedAudioFiles(
        _ requests: [AudioImportRequest],
        expectedPackID: String
    ) async -> Result<SoundPacksWindowAudioImportCompletion, SoundPacksWindowAudioActionError> {
        guard selectedPackID == expectedPackID else {
            return .failure(.selectionChanged)
        }
        guard !builtinPackIDs.contains(expectedPackID) else {
            return .failure(.builtinReadOnly(packID: expectedPackID))
        }
        guard !requests.isEmpty else {
            return .success(
                SoundPacksWindowAudioImportCompletion(
                    targetPackID: expectedPackID,
                    result: AudioImportBatchResult(accepted: [], rejected: []),
                    previewFile: nil,
                    completedInBackground: false))
        }

        audioImportActionRevision += 1
        let actionRevision = audioImportActionRevision
        let expectedSelectionRevision = inspectionSelectionRevision
        let environment = self.environment
        let targetName =
            packCards.first(where: { $0.id == expectedPackID }).map {
                SelectedPackMetadata(id: $0.id, name: $0.name).displayName
            } ?? expectedPackID
        clearWindowStatus(.audio)
        audioActionError = nil
        beginSoundPackMutation(packIDs: [expectedPackID])

        let batch = await Task.detached {
            importAudioFiles(requests, packID: expectedPackID, environment: environment)
        }.value
        let isLatestAction = actionRevision == audioImportActionRevision
        let isStillInspectingTarget =
            selectedPackID == expectedPackID
            && inspectionSelectionRevision == expectedSelectionRevision
        if !batch.accepted.isEmpty {
            completeSynchronousWrite(
                .succeeded,
                invalidatingPackIDs: [expectedPackID])
        } else {
            finishSoundPackMutation(packIDs: [expectedPackID])
            reload(followActivePack: false)
        }

        if isLatestAction {
            let backgroundPrefix = isStillInspectingTarget ? "" : "后台操作："
            if batch.rejected.isEmpty {
                setWindowStatus(
                    kind: .audio,
                    severity: .notice,
                    action: "添加音频",
                    message: "\(backgroundPrefix)已向「\(targetName)」添加 \(batch.accepted.count) 个音频；"
                        + "它们会先显示为未被使用，请从事件菜单分配。",
                    packID: isStillInspectingTarget ? expectedPackID : nil,
                    actionID: actionRevision)
            } else {
                let rejectionDetails = batch.rejected.map {
                    "\($0.sourceFileName)：\($0.reason.message)"
                }.joined(separator: "；")
                let message =
                    "\(backgroundPrefix)「\(targetName)」已导入 \(batch.accepted.count) 个，"
                    + "另有 \(batch.rejected.count) 个未导入：\(rejectionDetails)"
                audioActionError = .importRejected(message: message)
                setWindowStatus(
                    kind: .audio,
                    severity: .failure,
                    action: "添加音频",
                    message: message,
                    packID: isStillInspectingTarget ? expectedPackID : nil,
                    actionID: actionRevision)
            }
        }

        return .success(
            SoundPacksWindowAudioImportCompletion(
                targetPackID: expectedPackID,
                result: batch,
                previewFile: isLatestAction && isStillInspectingTarget
                    ? batch.accepted.last : nil,
                completedInBackground: !isStillInspectingTarget))
    }

    /// Resolves a preview from the current read model through the same audited pack/file gates as
    /// runtime playback. A stale `.present` row triggers an immediate read-model refresh so the
    /// window visibly becomes `.broken` instead of accepting a click with no explanation.
    public func previewFileForSelectedEvent(_ event: Event) -> URL? {
        guard
            let selectedPackID,
            let row = selectedEventRows.first(where: { $0.event == event }),
            case .present(let fileName) = row.coverage,
            let packDirectory = resolvePackDirectory(
                id: selectedPackID,
                userPacksDirectory: environment.userPacksDirectory,
                bundledPacksDirectory: environment.bundledPacksDirectory),
            let resolvedFile = safePackFileURL(fileName, in: packDirectory),
            regularFileExists(at: resolvedFile)
        else {
            reload(followActivePack: false)
            return nil
        }
        return resolvedFile
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
        finishStarredPacksUpdate(
            ClaudioCore.toggleStarredPack(
                packID,
                configFile: configFile,
                lockFile: lockFile,
                userPacksDirectory: environment.userPacksDirectory,
                defaultStarredPackIDs: builtinPackIDs))
    }

    #if DEBUG
    /// Exact replacement remains only as a disk-harness seam. The shipped UI exposes the atomic
    /// membership writer above, so a retained model can never overwrite an external sibling star.
    @discardableResult
    public func updateStarredPacks(
        to ids: [String]
    ) -> Result<SetStarredPacksOutcome, SetStarredPacksError> {
        finishStarredPacksUpdate(
            setStarredPacks(
                ids,
                configFile: configFile,
                lockFile: lockFile,
                userPacksDirectory: environment.userPacksDirectory,
                defaultStarredPackIDs: builtinPackIDs,
                materializeDefaultStarredPacks: false))
    }
    #endif

    private func finishStarredPacksUpdate(
        _ result: Result<SetStarredPacksOutcome, SetStarredPacksError>
    ) -> Result<SetStarredPacksOutcome, SetStarredPacksError> {
        switch result {
        case .success:
            starredPacksError = nil
            clearWindowStatus(.starredPacks)
            completeSynchronousWrite(.succeeded)
        case .failure(let error):
            starredPacksError = error
            setWindowStatus(
                kind: .starredPacks,
                severity: .failure,
                action: "更新星标",
                message: soundPacksWindowStarredPacksFailureReason(error))
            completeSynchronousWrite(.failed)
        }
        return result
    }

    /// 窗口即将展示或已收到外部切包通知时重读 config、立即投影旧快照，并请求后台刷新共享库。
    ///
    /// `followActivePack == true` 只用于「popover 刚成功切包」与首次展示；普通窗口内写保留用户
    /// 正在查看的侧栏项，不把一次 manifest 编辑误当成选包动作。
    public func reload(followActivePack: Bool) {
        reload(followActivePack: followActivePack, refreshSoundPackLibrary: true)
    }

    private func reload(
        followActivePack: Bool,
        refreshSoundPackLibrary: Bool
    ) {
        #if DEBUG
        guard readSource.readsSharedSnapshot else {
            reloadSynchronously(followActivePack: followActivePack)
            return
        }
        #endif
        pendingFollowActivePack = pendingFollowActivePack || followActivePack
        configState = loadPanelConfig(from: configFile)
        config = configState.resolvedConfig
        if let librarySnapshot {
            applySnapshot(librarySnapshot, followActivePack: pendingFollowActivePack)
        }
        if refreshSoundPackLibrary {
            Task { await soundPackLibrary.requestRefresh(trigger: .windowPresentation) }
        } else {
            // A config-only projection has no future library result that could satisfy a missing
            // target. Keeping this intent would let an unrelated later refresh override a manual
            // sidebar selection.
            pendingFollowActivePack = false
        }
    }

    public func retrySoundPackLibraryRefresh() {
        guard readSource.readsSharedSnapshot else {
            reload(followActivePack: false)
            return
        }
        Task { await soundPackLibrary.requestRefresh(trigger: .retry) }
    }

    #if DEBUG
    private func reloadSynchronously(followActivePack: Bool) {
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
            inspectionSelectionRevision += 1
            audioActionError = nil
            factoryRestoreNotice = nil
            factoryRestoreActionError = nil
            preserveCompletedAudioImportStatusAsBackgroundIfNeeded()
            clearWindowStatus(.factoryRestore)
            if packForkNotice?.newPackID != nextSelection {
                packForkNotice = nil
                if packForkActionError == nil { clearWindowStatus(.packFork) }
            }
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
            selectedAudioInventoryState = .idle
            selectedAudioInventoryPackID = nil
        }
    }
    #endif

    private func consumeLibraryState(_ state: SoundPackLibraryState) {
        switch state {
        case .unloaded:
            libraryPresentationState = .loading
        case .loading(let previous):
            libraryPresentationState = previous == nil ? .loading : .refreshing
            if let previous {
                librarySnapshot = previous
                applySnapshot(previous, followActivePack: pendingFollowActivePack)
            }
        case .ready(let snapshot):
            librarySnapshot = snapshot
            applySnapshot(snapshot, followActivePack: pendingFollowActivePack)
            pendingFollowActivePack = false
            libraryPresentationState = .ready
        case .failed(let previous, let error):
            if let previous {
                librarySnapshot = previous
                applySnapshot(previous, followActivePack: pendingFollowActivePack)
                libraryPresentationState = .refreshFailed(reason: error.message)
            } else {
                librarySnapshot = nil
                builtinPackIDs = []
                packCards = []
                starredPackIDs = []
                selectedPackID = nil
                selectedEventRows = []
                selectedAudioInventoryState = .idle
                selectedAudioInventoryPackID = nil
                audioInventoryTask?.cancel()
                libraryPresentationState = .loadFailed(reason: error.message)
            }
            pendingFollowActivePack = false
        }
    }

    private func applySnapshot(
        _ snapshot: SoundPackLibrarySnapshot,
        followActivePack: Bool
    ) {
        let previousSelection = selectedPackID
        builtinPackIDs = snapshot.factoryPackIDs
        let loadedCards = snapshot.packCards(config: config)
        let nextSelection: String?
        var consumedInspectionIntent = false
        if let pendingInspectionPackID,
            loadedCards.contains(where: { $0.id == pendingInspectionPackID })
        {
            nextSelection = pendingInspectionPackID
            self.pendingInspectionPackID = nil
            consumedInspectionIntent = true
        } else if followActivePack,
            loadedCards.contains(where: { $0.id == config.selectedPack })
        {
            nextSelection = config.selectedPack
        } else if let previousSelection,
            loadedCards.contains(where: { $0.id == previousSelection })
        {
            nextSelection = previousSelection
        } else if loadedCards.contains(where: { $0.id == config.selectedPack }) {
            nextSelection = config.selectedPack
        } else {
            nextSelection = loadedCards.first?.id
        }

        if nextSelection != previousSelection {
            inspectionSelectionRevision += 1
            audioActionError = nil
            factoryRestoreNotice = nil
            // A publish failure can legitimately remove the attempted built-in from `packCards`
            // after its old tree was salvaged. That automatic fallback selection must not erase
            // the only retry identity. Explicit user selection still clears it in
            // `selectPackForInspection`.
            let preservesMissingPackRetry = factoryRestoreRetryPackID != nil
            if !preservesMissingPackRetry {
                factoryRestoreActionError = nil
                clearWindowStatus(.factoryRestore)
            }
            preserveCompletedAudioImportStatusAsBackgroundIfNeeded()
            if packForkNotice?.newPackID != nextSelection {
                packForkNotice = nil
                if packForkActionError == nil { clearWindowStatus(.packFork) }
            }
        }

        packCards = loadedCards
        starredPackIDs = soundPacksWindowStarredPackIDs(
            installedPackIDs: loadedCards.map(\.id),
            starredPacks: config.starredPacks,
            defaultStarredPackIDs: builtinPackIDs)
        selectedPackID = nextSelection
        selectedEventRows =
            nextSelection.map {
                snapshot.eventRows(packID: $0, config: config)
            } ?? []
        if followActivePack,
            consumedInspectionIntent || nextSelection == config.selectedPack
        {
            pendingFollowActivePack = false
        }
        if let nextSelection {
            reloadSelectedAudioInventory(packID: nextSelection)
        } else {
            selectedAudioInventoryState = .idle
            selectedAudioInventoryPackID = nil
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
        return bindSelectedAudioFile(fileName, to: event, packID: selectedPackID)
    }

    /// Binds a file returned by the immediately preceding import. The async shared-library
    /// inventory may still be projecting the pre-import directory, so this path trusts the
    /// import result's pack identity and lets the audited manifest primitive re-check the file.
    @discardableResult
    public func assignImportedAudioFile(
        _ importedFile: ImportedAudioFile,
        to event: Event
    ) -> Result<Void, SoundPacksWindowAudioActionError> {
        guard let selectedPackID else {
            return finishAudioAction(.failure(.noSelectedPack))
        }
        guard selectedPackID == importedFile.packID else {
            return finishAudioAction(.failure(.selectionChanged))
        }
        guard !builtinPackIDs.contains(selectedPackID) else {
            return finishAudioAction(.failure(.builtinReadOnly(packID: selectedPackID)))
        }
        return bindSelectedAudioFile(importedFile.fileName, to: event, packID: selectedPackID)
    }

    @discardableResult
    private func bindSelectedAudioFile(
        _ fileName: String,
        to event: Event,
        packID: String
    ) -> Result<Void, SoundPacksWindowAudioActionError> {
        beginSoundPackMutation(packIDs: [packID])

        switch bindEventToManifest(
            event: event,
            fileName: fileName,
            packID: packID,
            environment: environment)
        {
        case .success:
            return finishAudioAction(.success(()), invalidatingPackID: packID)
        case .failure(let error):
            return finishAudioAction(
                .failure(.bind(error)), invalidatingPackID: packID)
        }
    }

    /// Clears one selected event through the same audited manifest mutation primitive as the
    /// former panel editor. Built-in packs remain read-only and every outcome refreshes the
    /// window-owned read model through ``finishAudioAction(_:)``.
    @discardableResult
    public func clearSelectedEventBinding(
        _ event: Event
    ) -> Result<Void, SoundPacksWindowAudioActionError> {
        guard let selectedPackID else {
            return finishAudioAction(.failure(.noSelectedPack))
        }
        guard !builtinPackIDs.contains(selectedPackID) else {
            return finishAudioAction(.failure(.builtinReadOnly(packID: selectedPackID)))
        }
        beginSoundPackMutation(packIDs: [selectedPackID])
        switch clearEventBinding(
            event: event,
            packID: selectedPackID,
            environment: environment)
        {
        case .success:
            return finishAudioAction(.success(()), invalidatingPackID: selectedPackID)
        case .failure(let error):
            return finishAudioAction(
                .failure(.bind(error)), invalidatingPackID: selectedPackID)
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
        beginSoundPackMutation(packIDs: [selectedPackID])

        switch deleteOrphanAudioFile(
            fileName: fileName,
            packID: selectedPackID,
            environment: environment)
        {
        case .success:
            return finishAudioAction(.success(()), invalidatingPackID: selectedPackID)
        case .failure(let error):
            if deleteFailureInvalidatesWindowReadModel(error) {
                // The lock-time check has disproved the confirmation-time snapshot. Re-read every
                // window-owned projection (cards, event rows, and inventory) without publishing a
                // fake local write completion to the panel.
                reload(followActivePack: false)
            }
            return finishAudioAction(
                .failure(.delete(error)),
                invalidatingPackID: selectedPackID,
                refreshAfterFailure: deleteFailureInvalidatesWindowReadModel(error))
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
        if factoryRestoreRetryPackID == expectedPackID {
            guard builtinPackIDs.contains(expectedPackID) else {
                return finishFactoryRestore(.failure(.notBuiltin(packID: expectedPackID)))
            }
            return restoreFactoryPackAfterConfirmation(
                packID: expectedPackID,
                retainedSalvages: factoryRestoreRetainedSalvages)
        }
        guard
            builtinPackIDs.contains(expectedPackID),
            factoryBatchRestoreFailures.contains(where: { $0.packID == expectedPackID })
        else {
            return finishFactoryRestore(.failure(.selectionChanged))
        }
        return retryFactoryPackFromBatchAfterConfirmation(packID: expectedPackID)
    }

    /// Empty-library recovery means all factory IDs, never an arbitrary `Set.first`. Each core
    /// restore remains independently fail-closed; UI refresh is emitted once after the batch.
    @discardableResult
    public func restoreAllFactoryPacksAfterConfirmation() -> FactoryPackBatchRestoreOutcome {
        factoryBatchRestoreFailures = []
        factoryBatchRestoredCount = 0
        factoryBatchRetainedSalvages = []
        clearWindowStatus(.factoryBatchRestore)

        let ids = factoryPackIDs
        beginSoundPackMutation(packIDs: Set(ids))
        var restored: [FactoryPackRestoreOutcome] = []
        var failures: [FactoryPackBatchRestoreFailure] = []
        var diskChanged = false

        for packID in ids {
            switch restoreFactoryPack(id: packID, environment: environment) {
            case .success(let outcome):
                restored.append(outcome)
                diskChanged = true
            case .failure(let error):
                failures.append(
                    FactoryPackBatchRestoreFailure(
                        packID: packID,
                        error: error,
                        retainedSalvages: appendingFactoryPackRestoreSalvage(
                            factoryPackRestoreSalvage(in: error),
                            to: [])))
                if factoryPackRestoreSalvage(in: error) != nil { diskChanged = true }
            }
        }

        if diskChanged {
            completeSynchronousWrite(
                failures.isEmpty ? .succeeded : .changedDespiteFailure,
                invalidatingPackIDs: Set(ids))
        } else {
            finishSoundPackMutation(packIDs: Set(ids))
            if readSource.readsSharedSnapshot { reload(followActivePack: false) }
            completeSynchronousWrite(.failed)
        }

        let outcome = FactoryPackBatchRestoreOutcome(
            restoredPacks: restored,
            failures: failures)
        factoryBatchRestoreFailures = failures
        factoryBatchRestoredCount = restored.count
        factoryBatchRetainedSalvages = outcome.retainedSalvages
        publishFactoryBatchRestoreStatus()
        return outcome
    }

    private func retryFactoryPackFromBatchAfterConfirmation(
        packID: String
    ) -> Result<FactoryPackRestoreOutcome, SoundPacksWindowFactoryRestoreActionError> {
        guard
            let previousFailure = factoryBatchRestoreFailures.first(where: {
                $0.packID == packID
            })
        else {
            return .failure(.selectionChanged)
        }

        beginSoundPackMutation(packIDs: [packID])
        switch restoreFactoryPack(id: packID, environment: environment) {
        case .success(let outcome):
            let visibleOutcome = resolveFactoryBatchRestoreFailure(with: outcome).outcome
            completeSynchronousWrite(.succeeded, invalidatingPackIDs: [packID])
            publishFactoryBatchRestoreStatus()
            return .success(visibleOutcome)
        case .failure(let error):
            let retainedSalvages = appendingFactoryPackRestoreSalvage(
                factoryPackRestoreSalvage(in: error),
                to: previousFailure.retainedSalvages)
            let diskChangedDespiteFailure = factoryPackRestoreSalvage(in: error) != nil
            completeSynchronousWrite(
                diskChangedDespiteFailure ? .changedDespiteFailure : .failed,
                invalidatingPackIDs: diskChangedDespiteFailure ? [packID] : [])
            if !diskChangedDespiteFailure {
                finishSoundPackMutation(packIDs: [packID])
                if readSource.readsSharedSnapshot { reload(followActivePack: false) }
            }
            if let index = factoryBatchRestoreFailures.firstIndex(where: {
                $0.packID == packID
            }) {
                factoryBatchRestoreFailures[index] = FactoryPackBatchRestoreFailure(
                    packID: packID,
                    error: error,
                    retainedSalvages: retainedSalvages)
            }
            publishFactoryBatchRestoreStatus()
            return .failure(
                .restore(
                    packID: packID,
                    error: error,
                    retainedSalvages: retainedSalvages))
        }
    }

    /// Resolves one retained batch failure through any successful restore path, including a
    /// selected-card restore after another process recreated the missing pack. The oldest salvage
    /// remains the primary visible path and every later moved entry is appended in occurrence order.
    private func resolveFactoryBatchRestoreFailure(
        with outcome: FactoryPackRestoreOutcome
    ) -> (outcome: FactoryPackRestoreOutcome, didResolve: Bool) {
        guard
            let index = factoryBatchRestoreFailures.firstIndex(where: {
                $0.packID == outcome.restoredPackID
            })
        else {
            return (outcome, false)
        }
        let previousFailure = factoryBatchRestoreFailures.remove(at: index)
        let retainedSalvages = appendingFactoryPackRestoreSalvages(
            outcome.retainedSalvages,
            to: previousFailure.retainedSalvages)
        let visibleOutcome = FactoryPackRestoreOutcome(
            restoredPackID: outcome.restoredPackID,
            salvaged: previousFailure.retainedSalvages.first ?? outcome.salvaged,
            retainedSalvages: retainedSalvages)
        factoryBatchRestoredCount += 1
        factoryBatchRetainedSalvages = appendingFactoryPackRestoreSalvages(
            visibleOutcome.retainedSalvages,
            to: factoryBatchRetainedSalvages)
        return (visibleOutcome, true)
    }

    /// A selected-card attempt can fail again after a batch failure's missing pack was recreated.
    /// Keep the batch failure alive, but merge the newer salvage into both failure projections so a
    /// later selection change cannot discard the only record of moved user content.
    private func retainFactoryRestoreFailureInBatch(
        _ error: SoundPacksWindowFactoryRestoreActionError
    ) -> (error: SoundPacksWindowFactoryRestoreActionError, didRetain: Bool) {
        guard
            case .restore(
                packID: let packID,
                error: let restoreError,
                retainedSalvages: let retainedSalvages) = error,
            let index = factoryBatchRestoreFailures.firstIndex(where: {
                $0.packID == packID
            })
        else {
            return (error, false)
        }
        let mergedSalvages = appendingFactoryPackRestoreSalvages(
            retainedSalvages,
            to: factoryBatchRestoreFailures[index].retainedSalvages)
        factoryBatchRestoreFailures[index] = FactoryPackBatchRestoreFailure(
            packID: packID,
            error: restoreError,
            retainedSalvages: mergedSalvages)
        return (
            .restore(
                packID: packID,
                error: restoreError,
                retainedSalvages: mergedSalvages),
            true
        )
    }

    private func publishFactoryBatchRestoreStatus() {
        let retainedSuccessNotice: String
        if factoryBatchRetainedSalvages.isEmpty {
            retainedSuccessNotice = ""
        } else {
            retainedSuccessNotice =
                " 恢复前的内容已原样搬到 "
                + factoryBatchRetainedSalvages.map(\.movedTo).joined(separator: "；")
                + "；一个文件都没删。"
        }
        if factoryBatchRestoreFailures.isEmpty {
            setWindowStatus(
                kind: .factoryBatchRestore,
                severity: .notice,
                action: "恢复内置声音包",
                message:
                    "已恢复 \(factoryBatchRestoredCount) 个内置声音包。"
                    + retainedSuccessNotice)
            return
        }

        let details = factoryBatchRestoreFailures.map {
            "\($0.packID)："
                + factoryPackRestoreErrorMessage(
                    $0.error,
                    retainedSalvages: $0.retainedSalvages)
        }.joined(separator: "；")
        setWindowStatus(
            kind: .factoryBatchRestore,
            severity: .failure,
            action: "恢复内置声音包",
            message:
                "已恢复 \(factoryBatchRestoredCount) 个；"
                + "\(factoryBatchRestoreFailures.count) 个失败：\(details)"
                + retainedSuccessNotice,
            recovery: .retryFactoryRestores(
                packIDs: factoryBatchRestoreFailures.map(\.packID)))
    }

    private func restoreFactoryPackAfterConfirmation(
        packID: String,
        retainedSalvages: [SalvagedPack] = []
    ) -> Result<FactoryPackRestoreOutcome, SoundPacksWindowFactoryRestoreActionError> {
        beginSoundPackMutation(packIDs: [packID])
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
        _ result: Result<Void, SoundPacksWindowAudioActionError>,
        invalidatingPackID: String? = nil,
        refreshAfterFailure: Bool = true
    ) -> Result<Void, SoundPacksWindowAudioActionError> {
        switch result {
        case .success:
            audioActionError = nil
            clearWindowStatus(.audio)
            completeSynchronousWrite(
                .succeeded,
                invalidatingPackIDs: invalidatingPackID.map { [$0] } ?? [])
        case .failure(let error):
            audioActionError = error
            setWindowStatus(
                kind: .audio,
                severity: .failure,
                action: "音频操作",
                message: error.message,
                packID: selectedPackID)
            completeSynchronousWrite(.failed)
            if refreshAfterFailure, let invalidatingPackID {
                finishSoundPackMutation(packIDs: [invalidatingPackID])
                if readSource.readsSharedSnapshot { reload(followActivePack: false) }
            }
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
            let batchResolution = resolveFactoryBatchRestoreFailure(with: outcome)
            let visibleOutcome = batchResolution.outcome
            factoryRestoreActionError = nil
            completeSynchronousWrite(
                .succeeded,
                invalidatingPackIDs: [outcome.restoredPackID])
            if batchResolution.didResolve {
                publishFactoryBatchRestoreStatus()
            }
            // A retry can make a previously absent pack selectable again. `reload` correctly
            // clears old pack-scoped status when that changes selection, so publish the success
            // notice after the reload to keep the new outcome visible.
            factoryRestoreNotice = visibleOutcome
            setWindowStatus(
                kind: .factoryRestore,
                severity: .notice,
                action: "恢复出厂声音",
                message: factoryPackRestoreNoticeMessage(visibleOutcome),
                packID: visibleOutcome.restoredPackID)
            return .success(visibleOutcome)
        case .failure(let error):
            let batchRetention = retainFactoryRestoreFailureInBatch(error)
            let visibleError = batchRetention.error
            let outcome: SoundPacksWindowWriteOutcome
            if diskChangedDespiteFailure {
                // The original tree is now safely in salvage, so the visible pack path changed
                // even though publishing the factory copy failed. Reload both UIs before keeping
                // the error visible; otherwise they would continue to show a pack that no longer
                // exists at the active path.
                outcome = .changedDespiteFailure
                completeSynchronousWrite(
                    outcome,
                    invalidatingPackIDs: factoryRestorePackID(in: visibleError).map { [$0] } ?? [])
            } else {
                outcome = .failed
            }
            factoryRestoreNotice = nil
            factoryRestoreActionError = visibleError
            if batchRetention.didRetain {
                publishFactoryBatchRestoreStatus()
            }
            setWindowStatus(
                kind: .factoryRestore,
                severity: .failure,
                action: "恢复出厂声音",
                message: visibleError.message,
                recovery: factoryRestoreRetryPackID.map {
                    .retryFactoryRestores(packIDs: [$0])
                })
            if outcome == .failed {
                completeSynchronousWrite(outcome)
                if let packID = factoryRestorePackID(in: visibleError) {
                    finishSoundPackMutation(packIDs: [packID])
                    if readSource.readsSharedSnapshot { reload(followActivePack: false) }
                }
            }
            return .failure(visibleError)
        }
    }

    private func finishPackFork(
        _ result: Result<PackForkOutcome, SoundPacksWindowPackForkActionError>,
        publishCompletion: Bool = true
    ) -> Result<PackForkOutcome, SoundPacksWindowPackForkActionError> {
        switch result {
        case .success(let outcome):
            packForkActionError = nil
            packForkNotice = outcome
            setWindowStatus(
                kind: .packFork,
                severity: .notice,
                action: "复制为我的包",
                message: packForkNoticeMessage(outcome),
                packID: outcome.newPackID)
        case .failure(let error):
            packForkNotice = nil
            packForkActionError = error
            setWindowStatus(
                kind: .packFork,
                severity: .failure,
                action: "复制为我的包",
                message: error.message)
            if publishCompletion { completeSynchronousWrite(.failed) }
        }
        return result
    }

    private func finishPackUse(
        _ result: Result<UseOutcome, SoundPacksWindowPackUseActionError>
    ) -> Result<UseOutcome, SoundPacksWindowPackUseActionError> {
        switch result {
        case .success(.selected(let packID)):
            packUseActionError = nil
            completeSynchronousWrite(.succeeded)
            setWindowStatus(
                kind: .packUse,
                severity: .notice,
                action: "用这个包",
                message: "现在使用「\(displayName(for: packID))」。星标列表没有改变。",
                packID: packID)
        case .failure(let error):
            packUseActionError = error
            setWindowStatus(
                kind: .packUse,
                severity: .failure,
                action: "用这个包",
                message: error.message,
                packID: selectedPackID)
            completeSynchronousWrite(.failed)
        }
        return result
    }

    private func displayName(for packID: String) -> String {
        guard let card = packCards.first(where: { $0.id == packID }) else { return packID }
        return SelectedPackMetadata(id: card.id, name: card.name).displayName
    }

    private func setWindowStatus(
        kind: SoundPacksWindowStatusKind,
        severity: SoundPacksWindowStatusSeverity,
        action: String,
        message: String,
        packID: String? = nil,
        actionID: Int? = nil,
        recovery: SoundPacksWindowStatusRecovery? = nil
    ) {
        statusRevision += 1
        statusByKind[kind] = SoundPacksWindowStatus(
            kind: kind,
            severity: severity,
            revision: statusRevision,
            action: action,
            message: message,
            packID: packID,
            actionID: actionID,
            recovery: recovery)
        publishWindowStatuses()
    }

    private func clearWindowStatus(_ kind: SoundPacksWindowStatusKind) {
        guard statusByKind.removeValue(forKey: kind) != nil else { return }
        publishWindowStatuses()
    }

    /// A retained window may be hidden when an async import completes. Following the active pack
    /// on reopen must not erase that only result before VoiceOver can announce it. Preserve its
    /// original revision (so an already-announced result is not replayed), detach it from the old
    /// pack selection, and make the original target explicit in the existing message.
    private func preserveCompletedAudioImportStatusAsBackgroundIfNeeded() {
        guard let status = statusByKind[.audio], status.actionID != nil else {
            clearWindowStatus(.audio)
            return
        }
        let message =
            status.message.hasPrefix("后台操作：")
            ? status.message
            : "后台操作：" + status.message
        statusByKind[.audio] = SoundPacksWindowStatus(
            kind: status.kind,
            severity: status.severity,
            revision: status.revision,
            action: status.action,
            message: message,
            packID: nil,
            actionID: status.actionID,
            recovery: status.recovery)
        publishWindowStatuses()
    }

    private func publishWindowStatuses() {
        windowStatuses = statusByKind.values.sorted {
            if $0.severity != $1.severity { return $0.severity.rawValue < $1.severity.rawValue }
            return $0.revision > $1.revision
        }
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
        if readSource.readsSharedSnapshot {
            audioInventoryTask?.cancel()
            let previous = selectedAudioInventoryPackID == packID ? selectedAudioFiles : nil
            selectedAudioInventoryPackID = packID
            selectedAudioInventoryState = .loading(previous: previous)
            audioInventoryTask = Task { @MainActor [weak self, soundPackLibrary] in
                let inventory = await soundPackLibrary.audioInventory(packID: packID)
                guard !Task.isCancelled, let self, self.selectedPackID == packID else { return }
                switch inventory {
                case .available(let files):
                    self.selectedAudioInventoryState = .ready(files)
                case .unavailable(let error):
                    self.selectedAudioInventoryState = .failed(
                        previous: previous, error: error)
                case .deferred:
                    self.selectedAudioInventoryState = .failed(
                        previous: previous,
                        error: .directoryUnreadable(reason: "音频清单尚未完成读取"))
                }
            }
            return
        }
        #if DEBUG
        switch packAudioFiles(packID: packID, environment: environment) {
        case .success(let files):
            selectedAudioInventoryState = .ready(files)
            selectedAudioInventoryPackID = packID
        case .failure(let error):
            selectedAudioInventoryState = .failed(previous: nil, error: error)
            selectedAudioInventoryPackID = packID
        }
        #endif
    }

    /// 窗口内一个同步写者的统一 completion。
    ///
    /// 成功或失败前已经改变磁盘时，先刷新窗口自己的读模型，再发布面板 full reload；没有落盘变化
    /// 的失败两边都不假刷新。未来 T11/T12/T17 的每个写者都应收口到这里，而不是各自选择
    /// `reloadConfigOnly()`。
    @discardableResult
    public func completeSynchronousWrite(
        _ outcome: SoundPacksWindowWriteOutcome,
        invalidatingPackIDs: Set<String> = []
    ) -> SoundPacksRefreshEffect {
        if outcome != .failed {
            finishSoundPackMutation(packIDs: invalidatingPackIDs)
            if !readSource.readsSharedSnapshot || !invalidatingPackIDs.isEmpty {
                reload(followActivePack: false)
            } else {
                configState = loadPanelConfig(from: configFile)
                config = configState.resolvedConfig
                if let librarySnapshot {
                    applySnapshot(librarySnapshot, followActivePack: false)
                }
            }
        }
        return refreshCoordinator.completeWindowWrite(outcome)
    }

    private func beginSoundPackMutation(packIDs: Set<String>) {
        guard readSource.readsSharedSnapshot, !packIDs.isEmpty else { return }
        soundPackLibrary.invalidate(packIDs: packIDs)
    }

    private func finishSoundPackMutation(packIDs: Set<String>) {
        guard readSource.readsSharedSnapshot, !packIDs.isEmpty else { return }
        soundPackLibrary.invalidate(packIDs: packIDs)
    }
}

private func factoryRestorePackID(
    in error: SoundPacksWindowFactoryRestoreActionError
) -> String? {
    switch error {
    case .restore(let packID, _, _): return packID
    case .noSelectedPack, .selectionChanged, .notBuiltin: return nil
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

private func appendingFactoryPackRestoreSalvages(
    _ salvages: [SalvagedPack],
    to retainedSalvages: [SalvagedPack]
) -> [SalvagedPack] {
    salvages.reduce(retainedSalvages) { retained, salvage in
        appendingFactoryPackRestoreSalvage(salvage, to: retained)
    }
}
