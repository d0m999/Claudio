import ClaudioCore
import ClaudioLocalization
import Combine
import Foundation

public enum SoundPacksWindowAudioActionError: Error, Sendable, Equatable {
    case writesStopped(statusText: SoundPacksWindowStatusText)
    case noSelectedPack
    case selectionChanged
    case builtinReadOnly(packID: String)
    case packUnavailable(packID: String)
    case notInInventory(fileName: String)
    case bind(ManifestBindError)
    case delete(OrphanAudioDeleteError)
    case importRejected(message: String)

    /// Keep application-owned failures semantic until the retained window resolves them. This
    /// lets an already-visible failure change language with the rest of the window rather than
    /// preserving whichever language happened to be active when the write failed.
    public var statusText: SoundPacksWindowStatusText {
        switch self {
        case .writesStopped(let statusText):
            return statusText
        case .noSelectedPack:
            return .localized(.soundPacksAudioErrorNoSelectedPack)
        case .selectionChanged:
            return .localized(.soundPacksAudioErrorSelectionChanged)
        case .builtinReadOnly:
            return .localized(.soundPacksAudioErrorBuiltinReadOnly)
        case .packUnavailable(let packID):
            return .literal("声音包 \(packID) 当前不在磁盘上")
        case .notInInventory(let fileName):
            return .localized(.soundPacksAudioErrorNotInInventory, fileName)
        case .bind(let error):
            return soundPacksWindowBindErrorText(error)
        case .delete(let error):
            return soundPacksWindowDeleteErrorText(error)
        case .importRejected(let message):
            // Import batches already retain their user-visible partial-result status with a
            // catalog key. Keep an opaque external rejection literal rather than pretending it
            // is an application-owned reason we can translate safely.
            return .literal(message)
        }
    }

    /// Compatibility projection for callers that have not yet adopted explicit language input.
    public var message: String { message(language: .zhHans) }

    public func message(language: ClaudioAppLanguage) -> String {
        statusText.resolve(language: language)
    }
}

public enum SoundPacksWindowStatusSeverity: Int, Sendable, Equatable {
    case failure
    case notice
}

/// Semantic text for retained management-window feedback. The compatibility `String` accessors
/// below intentionally resolve with the default language so existing core/announcement tests
/// keep their source-language contract; SwiftUI and AppKit callers resolve the same stored value
/// with the current app language instead of retaining a translated snapshot.
public enum SoundPacksWindowStatusText: Sendable, Equatable {
    case literal(String)
    case localized(key: ClaudioL10nKey, arguments: [String], background: Bool)

    public func resolve(language: ClaudioAppLanguage) -> String {
        switch self {
        case .literal(let value):
            return value
        case .localized(let key, let arguments, let background):
            let l10n = ClaudioL10n(language: language)
            let value = l10n.format(key, arguments: arguments)
            guard background else { return value }
            return l10n.text(.soundPacksStatusBackground) + value
        }
    }

    public static func localized(
        _ key: ClaudioL10nKey,
        _ arguments: String...,
        background: Bool = false
    ) -> Self {
        .localized(key: key, arguments: arguments, background: background)
    }

    public func asBackgroundOperation() -> Self {
        switch self {
        case .literal(let value):
            return .literal("后台操作：" + value)
        case .localized(let key, let arguments, _):
            return .localized(key: key, arguments: arguments, background: true)
        }
    }
}

public enum SoundPacksWindowStatusKind: String, Sendable, Equatable, Hashable {
    case audio
    case factoryRestore
    case factoryBatchRestore
    case starredPacks
    case packFork
    case packUse
    case packDeletion
}

public enum SoundPacksWindowStatusRecovery: Sendable, Equatable {
    case retryFactoryRestores(packIDs: [String])
}

/// One model-owned status projection. The View sorts nothing and invents no lifetime rules.
public struct SoundPacksWindowStatus: Identifiable, Sendable, Equatable {
    public let kind: SoundPacksWindowStatusKind
    public let severity: SoundPacksWindowStatusSeverity
    public let revision: Int
    public let actionText: SoundPacksWindowStatusText
    public let messageText: SoundPacksWindowStatusText
    public let packID: String?
    public let actionID: Int?
    public let recovery: SoundPacksWindowStatusRecovery?

    public var id: Int { revision }

    public var action: String { actionText.resolve(language: .zhHans) }
    public var message: String { messageText.resolve(language: .zhHans) }

    public func action(language: ClaudioAppLanguage) -> String {
        actionText.resolve(language: language)
    }

    public func message(language: ClaudioAppLanguage) -> String {
        messageText.resolve(language: language)
    }

    public init(
        kind: SoundPacksWindowStatusKind,
        severity: SoundPacksWindowStatusSeverity,
        revision: Int,
        action: String,
        message: String,
        packID: String? = nil,
        actionID: Int? = nil,
        recovery: SoundPacksWindowStatusRecovery? = nil
    ) {
        self.init(
            kind: kind,
            severity: severity,
            revision: revision,
            actionText: .literal(action),
            messageText: .literal(message),
            packID: packID,
            actionID: actionID,
            recovery: recovery)
    }

    public init(
        kind: SoundPacksWindowStatusKind,
        severity: SoundPacksWindowStatusSeverity,
        revision: Int,
        actionText: SoundPacksWindowStatusText,
        messageText: SoundPacksWindowStatusText,
        packID: String? = nil,
        actionID: Int? = nil,
        recovery: SoundPacksWindowStatusRecovery? = nil
    ) {
        self.kind = kind
        self.severity = severity
        self.revision = revision
        self.actionText = actionText
        self.messageText = messageText
        self.packID = packID
        self.actionID = actionID
        self.recovery = recovery
    }
}

public struct PackForkOutcome: Sendable, Equatable {
    public let sourcePackID: String
    public let newPackID: String
    public let displayName: String
}

public enum SoundPacksWindowPackForkActionError: Error, Sendable, Equatable {
    case writesStopped(statusText: SoundPacksWindowStatusText)
    case noSelectedPack
    case notBuiltin(packID: String)
    case occupancyReadFailed(reason: String)
    case allocation(PackForkIDAllocationError)
    case fork(PackForkError)
    case destinationAllocationExhausted(attempts: Int)
    case publishedButUnavailable(newID: String)

    public var message: String {
        switch self {
        case .writesStopped(let statusText):
            return statusText.resolve(language: .zhHans)
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

    public var statusText: SoundPacksWindowStatusText {
        switch self {
        case .writesStopped(let statusText): return statusText
        default: return .literal(message)
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
    "已创建并选中「\(outcome.displayName)」。原内置包未更改；需要时可点「用这个包」。"
}

public struct SoundPacksWindowAudioImportCompletion: Sendable, Equatable {
    public let targetPackID: String
    public let result: AudioImportBatchResult
    public let previewFile: ImportedAudioFile?
    public let completedInBackground: Bool
}

public enum SoundPacksWindowPackUseActionError: Error, Sendable, Equatable {
    case noSelectedPack
    case invalidScope(HostSurfaceID)
    case writesStopped(statusText: SoundPacksWindowStatusText)
    case use(UseError)
    case surface(SurfaceSoundMutationError)

    public var statusText: SoundPacksWindowStatusText {
        switch self {
        case .noSelectedPack:
            return .literal("没有选中的声音包，当前使用项未改变。")
        case .invalidScope(let surface):
            return .localized(.soundPacksInvalidScope, surface.rawValue)
        case .writesStopped(let statusText): return statusText
        case .use(let error): return .literal(error.description)
        case .surface(let error): return .literal(error.description)
        }
    }

    public var message: String { statusText.resolve(language: .zhHans) }
}

public enum SoundPacksWindowPackDeletionActionError: Error, Sendable, Equatable {
    case writesStopped(statusText: SoundPacksWindowStatusText)
    case noSelectedPack
    case selectionChanged
    case delete(UserSoundPackDeletionError)

    public var statusText: SoundPacksWindowStatusText {
        switch self {
        case .writesStopped(let statusText): return statusText
        case .noSelectedPack: return .localized(.soundPacksPackDeleteNoSelection)
        case .selectionChanged: return .localized(.soundPacksPackDeleteSelectionChanged)
        case .delete(.unsafePackID): return .localized(.soundPacksPackDeleteUnsafeID)
        case .delete(.builtinReadOnly): return .localized(.soundPacksPackDeleteBuiltin)
        case .delete(.activePack): return .localized(.soundPacksPackDeleteErrorActive)
        case .delete(.configUnavailable): return .localized(.soundPacksPackDeleteConfigUnavailable)
        case .delete(.packNotFound): return .localized(.soundPacksPackDeleteNotFound)
        case .delete(.unsafePackEntry): return .localized(.soundPacksPackDeleteUnsafeEntry)
        case .delete(.trashFailed(let reason)):
            return .localized(.soundPacksPackDeleteFailed, reason)
        case .delete(.isolationChangedRetained(let path)):
            return .localized(.soundPacksPackDeleteIsolationRetained, path)
        case .delete(.trashFailedRetained(let reason, let path)):
            return .localized(.soundPacksPackDeleteTrashRetained, reason, path)
        case .delete(.lockBusy): return .localized(.soundPacksPackDeleteLockBusy)
        case .delete(.lockFailed(let errno)):
            return .localized(.soundPacksPackDeleteLockFailed, "\(errno)")
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

private func soundPacksWindowBindErrorText(
    _ error: ManifestBindError
) -> SoundPacksWindowStatusText {
    switch error {
    case .packNotFound(let packID):
        return .localized(.soundPacksBindErrorPackNotFound, packID)
    case .unsafeFileName:
        return .localized(.soundPacksBindErrorUnsafeFileName)
    case .fileNotFound(let fileName):
        return .localized(.soundPacksBindErrorFileNotFound, fileName)
    case .manifestUnreadable(let reason):
        return .localized(.soundPacksBindErrorManifestUnreadable, reason)
    case .writeFailed(let reason):
        return .localized(.soundPacksBindErrorWriteFailed, reason)
    case .lockBusy:
        return .localized(.soundPacksBindErrorLockBusy)
    case .lockFailed(let errno):
        return .localized(.soundPacksBindErrorLockFailed, "\(errno)")
    case .targetChanged:
        return .literal("目标事件在操作期间已改变；已保留导入文件，未覆盖现有绑定。")
    }
}

private func soundPacksWindowDeleteErrorText(
    _ error: OrphanAudioDeleteError
) -> SoundPacksWindowStatusText {
    switch error {
    case .builtinReadOnly:
        return .localized(.soundPacksDeleteErrorBuiltinReadOnly)
    case .packNotFound(let packID):
        return .localized(.soundPacksDeleteErrorPackNotFound, packID)
    case .manifestUnreadable(let reason):
        return .localized(.soundPacksDeleteErrorManifestUnreadable, reason)
    case .directoryUnreadable(let reason):
        return .localized(.soundPacksDeleteErrorDirectoryUnreadable, reason)
    case .unsafeFileName:
        return .localized(.soundPacksDeleteErrorUnsafeFileName)
    case .fileNotFound(let fileName):
        return .localized(.soundPacksDeleteErrorFileNotFound, fileName)
    case .stillReferenced(let fileName):
        return .localized(.soundPacksDeleteErrorStillReferenced, fileName)
    case .deleteFailed(let reason):
        return .localized(.soundPacksDeleteErrorFailed, reason)
    case .lockBusy:
        return .localized(.soundPacksDeleteErrorLockBusy)
    case .lockFailed(let errno):
        return .localized(.soundPacksDeleteErrorLockFailed, "\(errno)")
    }
}

public enum SoundPacksWindowFactoryRestoreActionError: Error, Sendable, Equatable {
    case writesStopped(statusText: SoundPacksWindowStatusText)
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
        case .writesStopped(let statusText):
            return statusText.resolve(language: .zhHans)
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

    public var statusText: SoundPacksWindowStatusText {
        switch self {
        case .writesStopped(let statusText): return statusText
        default: return .literal(message)
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
    case .writesStopped(let reason):
        message = reason
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

/// One semantic projection shared by the visible scope banner and every rejected write status.
/// Invalid/diagnostic identities take precedence over config damage so VoiceOver cannot describe
/// a different failure from the one shown on screen.
public func soundPacksWindowScopeFailureStatusText(
    managedSurface: HostSurfaceID?,
    config: ClaudioConfig
) -> SoundPacksWindowStatusText? {
    guard isValidSoundPacksWindowSurface(managedSurface) else {
        return .localized(
            .soundPacksInvalidScope,
            managedSurface?.rawValue ?? "Global")
    }
    guard let managedSurface else { return nil }
    guard
        config.surfaceOverridesMalformed
            || config.invalidSurfaceOverrideKeys.contains(managedSurface.rawValue)
    else {
        return nil
    }
    let displayName =
        HostID.productVisibleCases.first(where: {
            $0.surfaceID == managedSurface
        })?.displayName ?? managedSurface.rawValue
    return .localized(.soundPacksDamagedScope, displayName)
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
    /// `nil` 明确表示正在管理 Global；非 nil 只有产品 registry Surface 才能获得写权限。
    @Published public private(set) var managedSurface: HostSurfaceID?
    @Published public private(set) var managedScopeFailureReason: String?
    public var managedScopeIsInvalid: Bool {
        !isValidSoundPacksWindowSurface(managedSurface)
    }
    /// Every production mutation consumes this one fail-closed scope decision. Browsing, preview,
    /// Finder reveal, and route changes remain read-only and available when writes are stopped.
    public var writesAllowed: Bool { managedScopeFailureReason == nil }
    public var managedScopeFailureStatusText: SoundPacksWindowStatusText? {
        soundPacksWindowScopeFailureStatusText(
            managedSurface: managedSurface,
            config: baseConfig)
    }
    private var writesStoppedStatusText: SoundPacksWindowStatusText {
        managedScopeFailureStatusText
            ?? .localized(.soundPacksDamagedScope, managedSurface?.rawValue ?? "Global")
    }
    private var writesStoppedReason: String {
        writesStoppedStatusText.resolve(language: .zhHans)
    }
    public var managedSurfaceProfileIsMalformed: Bool {
        guard let managedSurface else { return false }
        return baseConfig.surfaceOverridesMalformed
            || baseConfig.invalidSurfaceOverrideKeys.contains(managedSurface.rawValue)
    }
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

    public var selectedPackIsReferenced: Bool {
        guard let selectedPackID else { return false }
        return referencedSoundPackIDs(in: baseConfig).contains(selectedPackID)
    }

    public var selectedPackIsMissingPlaceholder: Bool {
        guard let selectedPackID else { return false }
        return packCards.first(where: { $0.id == selectedPackID })?.availability
            == .missingSelectedPlaceholder
    }

    public var selectedPackCanRestoreFactory: Bool {
        guard let selectedPackID else { return false }
        return builtinPackIDs.contains(selectedPackID)
    }

    public var factoryPackIDs: [String] { builtinPackIDs.sorted() }

    public var hasFactoryPacks: Bool { !builtinPackIDs.isEmpty }

    public var starredPacksFailureReason: String? {
        starredPacksError.map(soundPacksWindowStarredPacksFailureReason)
    }

    private let configFile: URL
    private let lockFile: URL
    private let environment: AudioImportEnvironment
    private let audioImportExecutor = SoundPackAudioImportExecutor()
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
    private var baseConfig: ClaudioConfig
    /// Exact shared-library lifecycle used by the deep editor projection. The legacy
    /// `libraryPresentationState` intentionally folds `.unloaded` into `.loading`; the new seam
    /// must not lose that identity or infer freshness from cards.
    private var editorLibraryPresentation: SoundPackLibraryPresentation
    private var lastAcceptedEditorLibraryState: SoundPackLibraryState?
    private var editorTransitionDepth = 0
    private var editorSettlePending = false
    var onEditorStateSettled: ((SoundPacksEditorModelSeed) -> Void)?

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
        baseConfig = loadedConfig
        managedSurface = nil
        managedScopeFailureReason = nil
        if !readSource.readsSharedSnapshot {
            let loadedCards = availablePacks(
                config: loadedConfig, environment: environment,
                synthesizeMissingSelectedPlaceholder: true)
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
            editorLibraryPresentation = .ready
        } else {
            packCards = []
            starredPackIDs = []
            selectedPackID = nil
            selectedEventRows = []
            selectedAudioInventoryState = .idle
            libraryPresentationState = .loading
            editorLibraryPresentation = .unloaded
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
                    self.withEditorStateTransition {
                        self.reload(
                            followActivePack: true,
                            refreshSoundPackLibrary:
                                self.refreshCoordinator.windowReloadRequiresLibraryRefresh)
                    }
                }
            }
        windowContentRefreshCancellable = refreshCoordinator.$windowContentReloadRevision
            .dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.withEditorStateTransition {
                        self.reload(
                            followActivePack: false,
                            refreshSoundPackLibrary:
                                self.refreshCoordinator.windowContentReloadRequiresLibraryRefresh)
                    }
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
        windowStatuses: [SoundPacksWindowStatus] = [],
        factoryRestoreActionError: SoundPacksWindowFactoryRestoreActionError? = nil,
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
        baseConfig = previewConfig
        managedSurface = nil
        managedScopeFailureReason = nil
        self.packCards = packCards
        self.selectedPackID = selectedPackID
        self.selectedEventRows = selectedEventRows
        selectedAudioInventoryState = .ready(selectedAudioFiles)
        self.starredPackIDs = starredPackIDs
        starredPacksError = nil
        audioActionError = nil
        factoryRestoreNotice = nil
        self.factoryRestoreActionError = factoryRestoreActionError
        packForkNotice = nil
        packForkActionError = nil
        packUseActionError = nil
        self.windowStatuses = windowStatuses
        self.libraryPresentationState = libraryPresentationState
        switch libraryPresentationState {
        case .loading:
            editorLibraryPresentation = .loading(previousAvailable: false)
        case .refreshing:
            editorLibraryPresentation = .loading(previousAvailable: true)
        case .ready:
            editorLibraryPresentation = .ready
        case .refreshFailed:
            editorLibraryPresentation = .failed(
                previousAvailable: true,
                reason: .scanFailed)
        case .loadFailed:
            editorLibraryPresentation = .failed(
                previousAvailable: false,
                reason: .scanFailed)
        }
    }
    #endif

    /// 侧栏只改变窗口正在查看的包，不写 config，也不改变面板当前包。
    @discardableResult
    public func selectPackForInspection(_ packID: String) -> Bool {
        selectPackForInspection(packID, selectionAnnouncementSuppression: nil)
    }

    /// 窗口路由先调用此方法再选择包。未知/诊断 Surface 保留为显式错误态，绝不降级到 Global。
    public func setManagedSurface(_ surface: HostSurfaceID?) {
        guard managedSurface != surface || managedScopeFailureReason != nil else { return }
        managedSurface = surface
        let loadedState = loadPanelConfig(from: configFile)
        configState = loadedState
        baseConfig = loadedState.resolvedConfig
        applyManagedScopeConfig()
        reload(followActivePack: true, refreshSoundPackLibrary: false)
    }

    /// The public entry point represents a user-owned selection, so it cancels both halves of a
    /// pending fork auto-selection. The private path below is used only when a synchronous fork
    /// selects its just-created pack and must suppress that one programmatic selection announcement.
    @discardableResult
    private func selectPackForInspection(
        _ packID: String,
        selectionAnnouncementSuppression: String?
    ) -> Bool {
        guard packCards.contains(where: { $0.id == packID }) else { return false }
        pendingFollowActivePack = false
        pendingInspectionPackID = nil
        suppressedSelectionAnnouncementPackID = selectionAnnouncementSuppression
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

    /// Coalesces every nested synchronous model change into one settled seed. The owner uses this
    /// around its command implementations; library and inventory completions use it at their own
    /// logical boundaries. It never spans an `await`.
    func withEditorStateTransition<T>(_ body: () throws -> T) rethrows -> T {
        editorTransitionDepth += 1
        defer {
            editorSettlePending = true
            editorTransitionDepth -= 1
            publishEditorStateIfSettled()
        }
        return try body()
    }

    func editorProjectionSeed() -> SoundPacksEditorModelSeed {
        let configAllowsWrites: Bool
        switch configState {
        case .operational, .needsPack:
            configAllowsWrites = true
        case .malformed, .unwritable:
            configAllowsWrites = false
        }
        return SoundPacksEditorModelSeed(
            library: editorLibraryPresentation,
            announcementLibraryState: libraryPresentationState,
            installedPackIDs: librarySnapshot.map { Set($0.facts.map(\.id)) }
                ?? Set(
                    packCards.compactMap { card in
                        card.availability == .installed ? card.id : nil
                    }),
            snapshotRevision: librarySnapshot?.revision,
            selectionGeneration: UInt64(inspectionSelectionRevision),
            managedSurface: managedSurface,
            writesAllowed: writesAllowed && configAllowsWrites,
            config: config,
            packCards: packCards,
            nativeTargetsByPackID: Dictionary(
                uniqueKeysWithValues: (librarySnapshot?.facts ?? []).compactMap { fact in
                    fact.nativeTargets.map { (fact.id, $0) }
                }),
            referencedPackIDs: referencedSoundPackIDs(in: baseConfig),
            selectedPackID: selectedPackID,
            selectedEventRows: selectedEventRows,
            selectedAudioInventoryState: selectedAudioInventoryState,
            starredPackIDs: starredPackIDs,
            builtinPackIDs: builtinPackIDs,
            factoryRestoreRetryPackIDs: factoryRestoreRetryPackIDs,
            windowStatuses: windowStatuses)
    }

    private func markEditorStateSettled() {
        editorSettlePending = true
        publishEditorStateIfSettled()
    }

    private func publishEditorStateIfSettled() {
        guard editorTransitionDepth == 0, editorSettlePending else { return }
        editorSettlePending = false
        onEditorStateSettled?(editorProjectionSeed())
    }

    @discardableResult
    public func forkSelectedFactoryPack(
        maximumPublishCollisions: Int = 8
    ) -> Result<PackForkOutcome, SoundPacksWindowPackForkActionError> {
        packForkNotice = nil
        packForkActionError = nil
        clearWindowStatus(.packFork)

        guard writesAllowed else {
            return finishPackFork(.failure(.writesStopped(statusText: writesStoppedStatusText)))
        }

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

            let mutation = beginSoundPackMutation(packIDs: [newPackID])
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
                        invalidatingPackIDs: [newPackID],
                        mutation: mutation)
                    return finishPackFork(.success(outcome), publishCompletion: false)
                }
                completeSynchronousWrite(.succeeded, mutation: mutation)
                guard
                    let card = packCards.first(where: { $0.id == newPackID })
                else {
                    return finishPackFork(
                        .failure(.publishedButUnavailable(newID: newPackID)),
                        publishCompletion: false)
                }
                selectPackForInspection(
                    newPackID,
                    selectionAnnouncementSuppression: newPackID)
                let outcome = PackForkOutcome(
                    sourcePackID: sourcePackID,
                    newPackID: newPackID,
                    displayName: SelectedPackMetadata(id: card.id, name: card.name).displayName)
                return finishPackFork(.success(outcome), publishCompletion: false)
            case .failure(.destinationAlreadyExists):
                finishSoundPackMutation(mutation)
                occupied.insert(newPackID)
                if attempt == attemptLimit {
                    return finishPackFork(
                        .failure(.destinationAllocationExhausted(attempts: attemptLimit)))
                }
            case .failure(let error):
                finishSoundPackMutation(mutation)
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
        guard isValidSoundPacksWindowSurface(managedSurface) else {
            return finishPackUse(.failure(.invalidScope(managedSurface!)))
        }
        guard writesAllowed else {
            return finishPackUse(.failure(.writesStopped(statusText: writesStoppedStatusText)))
        }
        if let managedSurface {
            switch setSurfacePack(
                selectedPackID,
                surface: managedSurface,
                configFile: configFile,
                userPacksDirectory: environment.userPacksDirectory,
                bundledPacksDirectory: environment.bundledPacksDirectory,
                lockFile: lockFile)
            {
            case .success:
                return finishPackUse(.success(.selected(packID: selectedPackID)))
            case .failure(let error):
                return finishPackUse(.failure(.surface(error)))
            }
        } else {
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
    }

    /// Imports picked files off the MainActor while binding completion to the pack and action that
    /// started it. A later selection never inherits this result or its automatic preview.
    public func importSelectedAudioFiles(
        _ requests: [AudioImportRequest],
        expectedPackID: String
    ) async -> Result<SoundPacksWindowAudioImportCompletion, SoundPacksWindowAudioActionError> {
        guard writesAllowed else {
            return .failure(.writesStopped(statusText: writesStoppedStatusText))
        }
        guard selectedPackID == expectedPackID else {
            return .failure(.selectionChanged)
        }
        guard !selectedPackIsMissingPlaceholder else {
            return .failure(.packUnavailable(packID: expectedPackID))
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
        let targetName =
            packCards.first(where: { $0.id == expectedPackID }).map {
                SelectedPackMetadata(id: $0.id, name: $0.name).displayName
            } ?? expectedPackID
        clearWindowStatus(.audio)
        audioActionError = nil
        let mutation = beginSoundPackMutation(packIDs: [expectedPackID])

        let execution = await audioImportExecutor.execute(
            SoundPackAudioImportJob(
                requests: requests,
                packID: expectedPackID,
                environment: environment))
        let batch: AudioImportBatchResult
        switch execution {
        case .cancelledBeforeWrite:
            finishSoundPackMutation(mutation)
            return .failure(.importRejected(message: "导入已取消，未添加任何音频。"))
        case .completed(let result, _):
            batch = result
        }
        let isLatestAction = actionRevision == audioImportActionRevision
        let isStillInspectingTarget =
            selectedPackID == expectedPackID
            && inspectionSelectionRevision == expectedSelectionRevision
        if !batch.accepted.isEmpty {
            completeSynchronousWrite(
                .succeeded,
                invalidatingPackIDs: [expectedPackID],
                mutation: mutation)
        } else {
            finishSoundPackMutation(mutation)
        }

        if isLatestAction {
            if batch.rejected.isEmpty {
                setWindowStatus(
                    kind: .audio,
                    severity: .notice,
                    actionText: .localized(.soundPacksStatusAddAudio),
                    messageText: .localized(
                        .soundPacksStatusAudioImported,
                        targetName,
                        "\(batch.accepted.count)",
                        background: !isStillInspectingTarget),
                    packID: isStillInspectingTarget ? expectedPackID : nil,
                    actionID: actionRevision)
            } else {
                let rejectionDetails = batch.rejected.map {
                    "\($0.sourceFileName)：\($0.reason.message)"
                }.joined(separator: "；")
                let message =
                    "「\(targetName)」已导入 \(batch.accepted.count) 个，"
                    + "另有 \(batch.rejected.count) 个未导入：\(rejectionDetails)"
                audioActionError = .importRejected(message: message)
                setWindowStatus(
                    kind: .audio,
                    severity: .failure,
                    actionText: .localized(.soundPacksStatusAddAudio),
                    messageText: .localized(
                        .soundPacksStatusAudioPartial,
                        targetName,
                        "\(batch.accepted.count)",
                        "\(batch.rejected.count)",
                        rejectionDetails,
                        background: !isStillInspectingTarget),
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
            nonEmptyRegularFileExists(at: resolvedFile)
        else {
            reload(followActivePack: false)
            return nil
        }
        return resolvedFile
    }

    var editorImportEnvironment: AudioImportEnvironment { environment }

    /// Re-observes a target that the off-main import boundary found missing before any duration
    /// probe or destination write. The shared library remains the sole publisher of disk facts;
    /// this waiter only settles that observation into the editor projection.
    func refreshEditorObservationForMutation() async -> SoundPacksEditorModelSeed {
        #if DEBUG
        guard readSource.readsSharedSnapshot else {
            reloadSynchronously(followActivePack: false)
            return editorProjectionSeed()
        }
        #endif

        let refreshed = await soundPackLibrary.refreshSnapshot(trigger: .windowPresentation)
        configState = loadPanelConfig(from: configFile)
        baseConfig = configState.resolvedConfig
        applyManagedScopeConfig()
        switch refreshed {
        case .ready(let snapshot):
            _ = applyReadySnapshot(snapshot, followActivePack: false)
        case .unloaded, .loading, .failed:
            consumeLibraryState(refreshed)
        }
        return editorProjectionSeed()
    }

    /// Opens the existing two-sided invalidation fence for one editor-owned compound mutation.
    /// The async executor receives only immutable import values; writer coordination stays here.
    func beginEditorCompoundMutation(packID: String) -> SoundPackLibraryMutation? {
        audioImportActionRevision += 1
        clearWindowStatus(.audio)
        audioActionError = nil
        return beginSoundPackMutation(packIDs: [packID])
    }

    /// Closes a compound mutation without asking the shared library to scan when no bytes landed.
    func finishEditorCompoundMutationWithoutChange(
        _ mutation: SoundPackLibraryMutation?
    ) {
        finishSoundPackMutation(mutation)
    }

    /// Completes one compound import/bind envelope with exactly one shared-library refresh.
    func finishEditorCompoundMutation(
        packID: String,
        mutation: SoundPackLibraryMutation?,
        changedDespiteFailure: Bool
    ) {
        completeSynchronousWrite(
            changedDespiteFailure ? .changedDespiteFailure : .succeeded,
            invalidatingPackIDs: [packID],
            mutation: mutation)
    }

    /// Uses the existing lock-time manifest writer without opening or completing a second refresh.
    func bindEditorImportedAudioFile(
        _ importedFile: ImportedAudioFile,
        to event: Event,
        packID: String,
        expectedEventBinding: ManifestEventBindingExpectation?
    ) -> Result<Void, ManifestBindError> {
        guard importedFile.packID == packID else {
            return .failure(.packNotFound(packID: packID))
        }
        return bindEventToManifest(
            event: event,
            fileName: importedFile.fileName,
            packID: packID,
            environment: environment,
            expectedEventBinding: expectedEventBinding)
    }

    /// Uses the atomic name+Event manifest primitive inside the caller's compound refresh envelope.
    func bindEditorAICue(
        _ importedFile: ImportedAudioFile,
        displayName: AICueDisplayName,
        target: AICueAdoptionTarget,
        expectedEventBinding: ManifestEventBindingExpectation
    ) -> Result<AICueManifestBindingOutcome, ManifestBindError> {
        guard importedFile.packID == target.packID else {
            return .failure(.packNotFound(packID: target.packID))
        }
        return bindAICueToManifest(
            event: target.event,
            fileName: importedFile.fileName,
            displayName: displayName,
            packID: target.packID,
            environment: environment,
            expectedEventBinding: expectedEventBinding)
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
        guard writesAllowed else {
            return finishStarredPacksUpdate(
                .failure(.writesStopped(reason: writesStoppedReason)))
        }
        return finishStarredPacksUpdate(
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
        guard writesAllowed else {
            return finishStarredPacksUpdate(
                .failure(.writesStopped(reason: writesStoppedReason)))
        }
        return finishStarredPacksUpdate(
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
            let messageText: SoundPacksWindowStatusText
            if case .writesStopped = error {
                messageText = writesStoppedStatusText
            } else {
                messageText = .literal(soundPacksWindowStarredPacksFailureReason(error))
            }
            setWindowStatus(
                kind: .starredPacks,
                severity: .failure,
                actionText: .localized(.soundPacksStatusUpdateStars),
                messageText: messageText)
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
        baseConfig = configState.resolvedConfig
        applyManagedScopeConfig()
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

    /// Re-reads only configuration and reprojects the currently retained library facts. The
    /// owner calls this before validating a capability so a malformed or changed scope wins over
    /// stale UI identity without inventing a sound-pack scan.
    func refreshEditorConfigProjection() {
        #if DEBUG
        guard readSource.readsSharedSnapshot else {
            reloadSynchronously(followActivePack: false)
            return
        }
        #endif
        configState = loadPanelConfig(from: configFile)
        baseConfig = configState.resolvedConfig
        applyManagedScopeConfig()
        if let librarySnapshot {
            applySnapshot(librarySnapshot, followActivePack: false)
        }
    }

    #if DEBUG
    private func reloadSynchronously(followActivePack: Bool) {
        let previousSelection = selectedPackID
        let loadedState = loadPanelConfig(from: configFile)
        let loadedConfig = loadedState.resolvedConfig
        configState = loadedState
        baseConfig = loadedConfig
        applyManagedScopeConfig()
        let scopedConfig = config
        let loadedCards = availablePacks(
            config: scopedConfig, environment: environment,
            synthesizeMissingSelectedPlaceholder: true)

        let nextSelection: String?
        if followActivePack,
            loadedCards.contains(where: { $0.id == scopedConfig.selectedPack })
        {
            nextSelection = scopedConfig.selectedPack
        } else if let previousSelection,
            loadedCards.contains(where: { $0.id == previousSelection })
        {
            nextSelection = previousSelection
        } else if loadedCards.contains(where: { $0.id == scopedConfig.selectedPack }) {
            nextSelection = scopedConfig.selectedPack
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

        packCards = loadedCards
        starredPackIDs = soundPacksWindowStarredPackIDs(
            installedPackIDs: loadedCards.map(\.id),
            starredPacks: scopedConfig.starredPacks,
            defaultStarredPackIDs: builtinPackIDs)
        selectedPackID = nextSelection
        selectedEventRows =
            nextSelection.map {
                packCoverage(packID: $0, config: scopedConfig, environment: environment)
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
        guard state != lastAcceptedEditorLibraryState else { return }
        if let currentRevision = librarySnapshot?.revision {
            guard let incomingRevision = state.snapshotRevision,
                incomingRevision >= currentRevision
            else { return }
            if case .ready(let snapshot) = state,
                snapshot.revision == currentRevision
            {
                return
            }
        }
        lastAcceptedEditorLibraryState = state

        editorTransitionDepth += 1
        defer {
            editorSettlePending = true
            editorTransitionDepth -= 1
            publishEditorStateIfSettled()
        }

        switch state {
        case .unloaded:
            editorLibraryPresentation = .unloaded
            libraryPresentationState = .loading
        case .loading(let previous):
            editorLibraryPresentation = .loading(previousAvailable: previous != nil)
            libraryPresentationState = previous == nil ? .loading : .refreshing
            if let previous {
                librarySnapshot = previous
                applySnapshot(previous, followActivePack: pendingFollowActivePack)
            }
        case .ready(let snapshot):
            editorLibraryPresentation = .ready
            librarySnapshot = snapshot
            applySnapshot(snapshot, followActivePack: pendingFollowActivePack)
            pendingFollowActivePack = false
            libraryPresentationState = .ready
        case .failed(let previous, let error):
            let reason: SoundPackEditorLibraryFailureReason
            switch error {
            case .rootNotDirectory, .rootUnreadable:
                reason = .locationUnavailable
            case .scanFailed:
                reason = .scanFailed
            }
            editorLibraryPresentation = .failed(
                previousAvailable: previous != nil,
                reason: reason)
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

    /// 从完整 base config 投影当前管理作用域。Surface 只替换 effective pack/events；星标、
    /// 未知字段写入边界与顶层配置事实仍归 base。坏覆盖与非产品 Surface 均 fail closed。
    private func applyManagedScopeConfig() {
        guard isValidSoundPacksWindowSurface(managedSurface) else {
            let surface = managedSurface!
            managedScopeFailureReason =
                "未知声音作用域 \(surface.rawValue)，已停止写入；不会回退到 Global。"
            var failed = baseConfig
            failed.selectedPack = ""
            failed.eventsEnabled = Dictionary(
                uniqueKeysWithValues: Event.allCases.map { ($0.cliName, false) })
            config = failed
            return
        }
        switch baseConfig.resolveSoundProfile(for: managedSurface) {
        case .success(let profile):
            managedScopeFailureReason = nil
            var effective = baseConfig
            effective.selectedPack = profile.selectedPack
            effective.eventsEnabled = profile.eventsEnabled
            config = effective
        case .failure:
            let name = managedSurface?.rawValue ?? "global"
            managedScopeFailureReason =
                "\(name) 的声音覆盖已损坏；已停止该来源写入，不会回退到 Global。"
            var failed = baseConfig
            failed.selectedPack = ""
            failed.eventsEnabled = Dictionary(
                uniqueKeysWithValues: Event.allCases.map { ($0.cliName, false) })
            config = failed
        }
    }

    /// Assigns one already-enumerated pack audio file via T3's sole bind primitive.
    @discardableResult
    public func assignSelectedAudioFile(
        _ fileName: String,
        to event: Event
    ) -> Result<Void, SoundPacksWindowAudioActionError> {
        guard writesAllowed else {
            return finishAudioAction(.failure(.writesStopped(statusText: writesStoppedStatusText)))
        }
        guard let selectedPackID else {
            return finishAudioAction(.failure(.noSelectedPack))
        }
        guard !selectedPackIsMissingPlaceholder else {
            return finishAudioAction(.failure(.packUnavailable(packID: selectedPackID)))
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
        guard writesAllowed else {
            return finishAudioAction(.failure(.writesStopped(statusText: writesStoppedStatusText)))
        }
        guard let selectedPackID else {
            return finishAudioAction(.failure(.noSelectedPack))
        }
        guard !selectedPackIsMissingPlaceholder else {
            return finishAudioAction(.failure(.packUnavailable(packID: selectedPackID)))
        }
        guard selectedPackID == importedFile.packID else {
            return finishAudioAction(.failure(.selectionChanged))
        }
        guard !builtinPackIDs.contains(selectedPackID) else {
            return finishAudioAction(.failure(.builtinReadOnly(packID: selectedPackID)))
        }
        return bindSelectedAudioFile(importedFile.fileName, to: event, packID: selectedPackID)
    }

    public func aiCueAdoptionEligibility(for event: Event) -> AICueAdoptionEligibility {
        guard writesAllowed else { return .ineligible(.writesStopped) }
        return ClaudioGUICore.aiCueAdoptionEligibility(
            surface: managedSurface,
            event: event,
            selectedPackID: selectedPackID,
            config: baseConfig,
            packCards: packCards,
            builtinPackIDs: builtinPackIDs)
    }

    public func captureAICueAdoptionTarget(
        for event: Event
    ) -> Result<AICueAdoptionTarget, AICueAdoptionIneligibility> {
        switch aiCueAdoptionEligibility(for: event) {
        case .eligible(let target): return .success(target)
        case .ineligible(let reason): return .failure(reason)
        }
    }

    /// Imports the chosen private candidate first, then re-proves the explicit target immediately
    /// before one atomic name+event manifest mutation. A failed second phase leaves the old event
    /// mapping untouched and reports the already-imported file honestly as an orphan.
    public func adoptAICue(
        _ request: AICueAdoptionRequest
    ) async -> Result<AICueAdoptionOutcome, AICueAdoptionError> {
        let candidate = request.candidate
        let displayName = request.displayName
        let target = request.target
        guard await refreshAICueAdoptionSnapshot() else {
            return .failure(.ineligible(.configurationUnavailable))
        }
        switch captureAICueAdoptionTarget(for: target.event) {
        case .success(let current) where current == target:
            break
        case .success:
            return .failure(.ineligible(.targetChanged))
        case .failure(let reason):
            return .failure(.ineligible(reason))
        }

        let importRequest = AudioImportRequest(
            sourceURL: candidate.asset.fileURL,
            suggestedFileName:
                "ai-cue-\(candidate.id.uuidString.lowercased())."
                + candidate.asset.sniffedFormat.rawValue)
        let completion: SoundPacksWindowAudioImportCompletion
        switch await importSelectedAudioFiles([importRequest], expectedPackID: target.packID) {
        case .failure(let error):
            return .failure(.importUnavailable(error))
        case .success(let result):
            completion = result
        }
        guard let imported = completion.result.accepted.first else {
            if let rejection = completion.result.rejected.first {
                return .failure(.importRejected(rejection.reason))
            }
            return .failure(
                .importUnavailable(
                    .importRejected(message: "生成候选未能导入，当前声音未改变。")))
        }

        switch captureAICueAdoptionTarget(for: target.event) {
        case .success(let current) where current == target:
            break
        case .success:
            return .failure(
                .importedButNotBound(
                    imported: imported,
                    reason: .ineligible(.targetChanged)))
        case .failure(let reason):
            return .failure(
                .importedButNotBound(
                    imported: imported,
                    reason: .ineligible(reason)))
        }

        let mutation = beginSoundPackMutation(packIDs: [target.packID])
        switch bindAICueToManifest(
            event: target.event,
            fileName: imported.fileName,
            displayName: displayName,
            packID: target.packID,
            environment: environment)
        {
        case .success(let binding):
            _ = finishAudioAction(
                .success(()),
                invalidatingPackID: target.packID,
                mutation: mutation)
            return .success(
                AICueAdoptionOutcome(
                    target: target,
                    importedFile: imported,
                    finalDisplayName: binding.finalDisplayName))
        case .failure(let error):
            _ = finishAudioAction(
                .failure(.bind(error)),
                invalidatingPackID: target.packID,
                mutation: mutation)
            return .failure(
                .importedButNotBound(
                    imported: imported,
                    reason: .manifest(error)))
        }
    }

    private func refreshAICueAdoptionSnapshot() async -> Bool {
        #if DEBUG
        guard readSource.readsSharedSnapshot else {
            reloadSynchronously(followActivePack: true)
            return true
        }
        #endif

        pendingFollowActivePack = true
        let refreshed = await soundPackLibrary.refreshSnapshot(trigger: .windowPresentation)
        configState = loadPanelConfig(from: configFile)
        baseConfig = configState.resolvedConfig
        applyManagedScopeConfig()
        guard case .ready(let snapshot) = refreshed else { return false }
        return applyReadySnapshot(snapshot, followActivePack: true)
    }

    /// The observation stream may apply a later library state before the refresh waiter resumes on
    /// MainActor. Never let that older waiter result roll the model back. A later refresh/failure at
    /// the same or a higher revision is also a reason to stop instead of reviving stale ready UI.
    private func applyReadySnapshot(
        _ refreshedSnapshot: SoundPackLibrarySnapshot,
        followActivePack: Bool
    ) -> Bool {
        if let currentSnapshot = librarySnapshot,
            currentSnapshot.revision >= refreshedSnapshot.revision
        {
            guard libraryPresentationState == .ready else { return false }
            applySnapshot(currentSnapshot, followActivePack: followActivePack)
            if followActivePack { pendingFollowActivePack = false }
            return true
        }
        if followActivePack { pendingFollowActivePack = true }
        consumeLibraryState(.ready(refreshedSnapshot))
        return true
    }

    #if DEBUG
    /// Deterministic seam for proving that a delayed refresh waiter cannot replace a newer state.
    public func applyAICueAdoptionSnapshotForTesting(
        _ snapshot: SoundPackLibrarySnapshot
    ) -> Bool {
        pendingFollowActivePack = true
        return applyReadySnapshot(snapshot, followActivePack: true)
    }

    public func consumeSoundPackLibraryStateForTesting(_ state: SoundPackLibraryState) {
        consumeLibraryState(state)
    }
    #endif

    @discardableResult
    private func bindSelectedAudioFile(
        _ fileName: String,
        to event: Event,
        packID: String
    ) -> Result<Void, SoundPacksWindowAudioActionError> {
        let mutation = beginSoundPackMutation(packIDs: [packID])

        switch bindEventToManifest(
            event: event,
            fileName: fileName,
            packID: packID,
            environment: environment)
        {
        case .success:
            return finishAudioAction(
                .success(()),
                invalidatingPackID: packID,
                mutation: mutation)
        case .failure(let error):
            return finishAudioAction(
                .failure(.bind(error)),
                invalidatingPackID: packID,
                refreshAfterFailure: manifestBindFailureInvalidatesWindowReadModel(error),
                mutation: mutation)
        }
    }

    /// Clears one selected event through the same audited manifest mutation primitive as the
    /// former panel editor. Built-in packs remain read-only and every outcome refreshes the
    /// window-owned read model through ``finishAudioAction(_:)``.
    @discardableResult
    public func clearSelectedEventBinding(
        _ event: Event
    ) -> Result<Void, SoundPacksWindowAudioActionError> {
        guard writesAllowed else {
            return finishAudioAction(.failure(.writesStopped(statusText: writesStoppedStatusText)))
        }
        guard let selectedPackID else {
            return finishAudioAction(.failure(.noSelectedPack))
        }
        guard !selectedPackIsMissingPlaceholder else {
            return finishAudioAction(.failure(.packUnavailable(packID: selectedPackID)))
        }
        guard !builtinPackIDs.contains(selectedPackID) else {
            return finishAudioAction(.failure(.builtinReadOnly(packID: selectedPackID)))
        }
        let mutation = beginSoundPackMutation(packIDs: [selectedPackID])
        switch clearEventBinding(
            event: event,
            packID: selectedPackID,
            environment: environment)
        {
        case .success:
            return finishAudioAction(
                .success(()),
                invalidatingPackID: selectedPackID,
                mutation: mutation)
        case .failure(let error):
            return finishAudioAction(
                .failure(.bind(error)),
                invalidatingPackID: selectedPackID,
                refreshAfterFailure: manifestBindFailureInvalidatesWindowReadModel(error),
                mutation: mutation)
        }
    }

    /// Moves the explicitly confirmed, inactive user pack to Trash through the shared packs lock.
    /// The expected ID closes the confirmation-to-action selection race; active and built-in
    /// packs remain fail-closed.
    @discardableResult
    public func deleteSelectedUserPackAfterConfirmation(
        expectedPackID: String
    ) -> Result<UserSoundPackDeletionOutcome, SoundPacksWindowPackDeletionActionError> {
        guard writesAllowed else {
            return finishPackDeletion(
                .failure(.writesStopped(statusText: writesStoppedStatusText)))
        }
        guard let selectedPackID else {
            return finishPackDeletion(.failure(.noSelectedPack))
        }
        guard selectedPackID == expectedPackID else {
            return finishPackDeletion(.failure(.selectionChanged))
        }

        let mutation = beginSoundPackMutation(packIDs: [selectedPackID])
        #if DEBUG
        let moveToTrash =
            environment.moveUserPackToTrashForTesting ?? moveUserSoundPackToTrash
        #else
        let moveToTrash = moveUserSoundPackToTrash
        #endif
        let result = deleteUserSoundPack(
            packID: selectedPackID,
            configFile: configFile,
            configLockFile: lockFile,
            environment: environment,
            moveToTrash: moveToTrash
        )
        .mapError(SoundPacksWindowPackDeletionActionError.delete)
        return finishPackDeletion(
            result,
            invalidatedPackID: selectedPackID,
            mutation: mutation)
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
        guard writesAllowed else {
            return finishAudioAction(.failure(.writesStopped(statusText: writesStoppedStatusText)))
        }
        guard let selectedPackID else {
            return finishAudioAction(.failure(.noSelectedPack))
        }
        guard !selectedPackIsMissingPlaceholder else {
            return finishAudioAction(.failure(.packUnavailable(packID: selectedPackID)))
        }
        guard selectedPackID == expectedPackID else {
            return finishAudioAction(.failure(.selectionChanged))
        }
        let mutation = beginSoundPackMutation(packIDs: [selectedPackID])

        switch deleteOrphanAudioFile(
            fileName: fileName,
            packID: selectedPackID,
            environment: environment)
        {
        case .success:
            return finishAudioAction(
                .success(()),
                invalidatingPackID: selectedPackID,
                mutation: mutation)
        case .failure(let error):
            return finishAudioAction(
                .failure(.delete(error)),
                invalidatingPackID: selectedPackID,
                refreshAfterFailure: deleteFailureInvalidatesWindowReadModel(error),
                mutation: mutation)
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
        guard writesAllowed else {
            return finishFactoryRestore(
                .failure(.writesStopped(statusText: writesStoppedStatusText)))
        }
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
        guard writesAllowed else {
            // The confirmation can outlive its scope. Reject the stale write without finishing
            // the existing recovery lifecycle: that state owns the missing pack's retry identity
            // and every salvage path the user still needs after the scope is repaired.
            return .failure(.writesStopped(statusText: writesStoppedStatusText))
        }
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
        let ids = factoryPackIDs
        guard writesAllowed else {
            let failures = ids.map {
                FactoryPackBatchRestoreFailure(
                    packID: $0,
                    error: .writesStopped(reason: writesStoppedReason))
            }
            let outcome = FactoryPackBatchRestoreOutcome(
                restoredPacks: [],
                failures: failures)
            // A stale confirmation is not a new batch attempt. Keep the previous failures,
            // retry payload, completion count, and salvage paths intact for the repaired scope.
            return outcome
        }

        factoryBatchRestoreFailures = []
        factoryBatchRestoredCount = 0
        factoryBatchRetainedSalvages = []
        clearWindowStatus(.factoryBatchRestore)
        let mutation = beginSoundPackMutation(packIDs: Set(ids))
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
                invalidatingPackIDs: Set(ids),
                mutation: mutation)
        } else {
            completeSynchronousWrite(.failed, mutation: mutation)
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

        let mutation = beginSoundPackMutation(packIDs: [packID])
        switch restoreFactoryPack(id: packID, environment: environment) {
        case .success(let outcome):
            let visibleOutcome = resolveFactoryBatchRestoreFailure(with: outcome).outcome
            completeSynchronousWrite(
                .succeeded,
                invalidatingPackIDs: [packID],
                mutation: mutation)
            publishFactoryBatchRestoreStatus()
            return .success(visibleOutcome)
        case .failure(let error):
            let retainedSalvages = appendingFactoryPackRestoreSalvage(
                factoryPackRestoreSalvage(in: error),
                to: previousFailure.retainedSalvages)
            let diskChangedDespiteFailure = factoryPackRestoreSalvage(in: error) != nil
            completeSynchronousWrite(
                diskChangedDespiteFailure ? .changedDespiteFailure : .failed,
                invalidatingPackIDs: diskChangedDespiteFailure ? [packID] : [],
                mutation: mutation)
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
        let retainedSalvagePaths =
            factoryBatchRetainedSalvages
            .map(\.movedTo)
            .joined(separator: "；")
        if factoryBatchRestoreFailures.isEmpty {
            setWindowStatus(
                kind: .factoryBatchRestore,
                severity: .notice,
                actionText: .localized(.soundPacksStatusRestoreBuiltins),
                messageText: factoryBatchRetainedSalvages.isEmpty
                    ? .localized(.soundPacksStatusBatchRestored, "\(factoryBatchRestoredCount)")
                    : .localized(
                        .soundPacksStatusBatchRestoredWithSalvage,
                        "\(factoryBatchRestoredCount)",
                        retainedSalvagePaths))
            return
        }

        if factoryBatchRestoreFailures.allSatisfy({ failure in
            if case .writesStopped = failure.error { return true }
            return false
        }) {
            setWindowStatus(
                kind: .factoryBatchRestore,
                severity: .failure,
                actionText: .localized(.soundPacksStatusRestoreBuiltins),
                messageText: writesStoppedStatusText)
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
            actionText: .localized(.soundPacksStatusRestoreBuiltins),
            messageText: factoryBatchRetainedSalvages.isEmpty
                ? .localized(
                    .soundPacksStatusBatchPartial,
                    "\(factoryBatchRestoredCount)",
                    "\(factoryBatchRestoreFailures.count)",
                    details)
                : .localized(
                    .soundPacksStatusBatchPartialWithSalvage,
                    "\(factoryBatchRestoredCount)",
                    "\(factoryBatchRestoreFailures.count)",
                    details,
                    retainedSalvagePaths),
            recovery: .retryFactoryRestores(
                packIDs: factoryBatchRestoreFailures.map(\.packID)))
    }

    private func restoreFactoryPackAfterConfirmation(
        packID: String,
        retainedSalvages: [SalvagedPack] = []
    ) -> Result<FactoryPackRestoreOutcome, SoundPacksWindowFactoryRestoreActionError> {
        let mutation = beginSoundPackMutation(packIDs: [packID])
        switch restoreFactoryPack(id: packID, environment: environment) {
        case .success(let outcome):
            let visibleOutcome = FactoryPackRestoreOutcome(
                restoredPackID: outcome.restoredPackID,
                salvaged: retainedSalvages.first ?? outcome.salvaged,
                retainedSalvages: appendingFactoryPackRestoreSalvage(
                    outcome.salvaged,
                    to: retainedSalvages))
            return finishFactoryRestore(.success(visibleOutcome), mutation: mutation)
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
                diskChangedDespiteFailure: diskChangedDespiteFailure,
                mutation: mutation)
        }
    }

    private func finishAudioAction(
        _ result: Result<Void, SoundPacksWindowAudioActionError>,
        invalidatingPackID: String? = nil,
        refreshAfterFailure: Bool = false,
        mutation: SoundPackLibraryMutation? = nil
    ) -> Result<Void, SoundPacksWindowAudioActionError> {
        switch result {
        case .success:
            audioActionError = nil
            clearWindowStatus(.audio)
            completeSynchronousWrite(
                .succeeded,
                invalidatingPackIDs: invalidatingPackID.map { [$0] } ?? [],
                mutation: mutation)
        case .failure(let error):
            audioActionError = error
            setWindowStatus(
                kind: .audio,
                severity: .failure,
                actionText: .localized(.soundPacksStatusAddAudio),
                messageText: error.statusText,
                packID: selectedPackID)
            completeSynchronousWrite(.failed, mutation: mutation)
            if invalidatingPackID != nil, refreshAfterFailure {
                reload(followActivePack: false)
            }
        }
        return result
    }

    private func finishFactoryRestore(
        _ result: Result<
            FactoryPackRestoreOutcome,
            SoundPacksWindowFactoryRestoreActionError
        >,
        diskChangedDespiteFailure: Bool = false,
        mutation: SoundPackLibraryMutation? = nil
    ) -> Result<FactoryPackRestoreOutcome, SoundPacksWindowFactoryRestoreActionError> {
        switch result {
        case .success(let outcome):
            let batchResolution = resolveFactoryBatchRestoreFailure(with: outcome)
            let visibleOutcome = batchResolution.outcome
            factoryRestoreActionError = nil
            completeSynchronousWrite(
                .succeeded,
                invalidatingPackIDs: [outcome.restoredPackID],
                mutation: mutation)
            if batchResolution.didResolve {
                publishFactoryBatchRestoreStatus()
            }
            // A retry can make a previously absent pack selectable again. `reload` correctly
            // clears old pack-scoped status when that changes selection, so publish the success
            // notice after the reload to keep the new outcome visible.
            factoryRestoreNotice = visibleOutcome
            let retainedSalvagePaths = visibleOutcome.retainedSalvages
                .map(\.movedTo)
                .joined(separator: "；")
            setWindowStatus(
                kind: .factoryRestore,
                severity: .notice,
                actionText: .localized(.soundPacksStatusRestoreFactory),
                messageText: visibleOutcome.retainedSalvages.isEmpty
                    ? .localized(
                        .soundPacksStatusFactoryRestored,
                        visibleOutcome.restoredPackID)
                    : .localized(
                        .soundPacksStatusFactoryRestoredWithSalvage,
                        visibleOutcome.restoredPackID,
                        retainedSalvagePaths),
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
                    invalidatingPackIDs: factoryRestorePackID(in: visibleError).map { [$0] } ?? [],
                    mutation: mutation)
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
                actionText: .localized(.soundPacksStatusRestoreFactory),
                messageText: visibleError.statusText,
                recovery: factoryRestoreRetryPackID.map {
                    .retryFactoryRestores(packIDs: [$0])
                })
            if outcome == .failed {
                completeSynchronousWrite(outcome, mutation: mutation)
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
                actionText: .localized(.soundPacksStatusCopyPack),
                messageText: .localized(
                    .soundPacksStatusPackCopied,
                    outcome.displayName),
                packID: outcome.newPackID)
        case .failure(let error):
            packForkNotice = nil
            packForkActionError = error
            setWindowStatus(
                kind: .packFork,
                severity: .failure,
                actionText: .localized(.soundPacksStatusCopyPack),
                messageText: error.statusText)
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
                actionText: .localized(.soundPacksStatusUsePack),
                messageText: .localized(
                    .soundPacksStatusPackUsed,
                    displayName(for: packID)),
                packID: packID)
        case .failure(let error):
            packUseActionError = error
            setWindowStatus(
                kind: .packUse,
                severity: .failure,
                actionText: .localized(.soundPacksStatusUsePack),
                messageText: error.statusText,
                packID: selectedPackID)
            completeSynchronousWrite(.failed)
        }
        return result
    }

    private func finishPackDeletion(
        _ result: Result<
            UserSoundPackDeletionOutcome,
            SoundPacksWindowPackDeletionActionError
        >,
        invalidatedPackID: String? = nil,
        mutation: SoundPackLibraryMutation? = nil
    ) -> Result<UserSoundPackDeletionOutcome, SoundPacksWindowPackDeletionActionError> {
        switch result {
        case .success(let outcome):
            let name = displayName(for: outcome.packID)
            completeSynchronousWrite(
                .succeeded,
                invalidatingPackIDs: [outcome.packID],
                mutation: mutation)
            setWindowStatus(
                kind: .packDeletion,
                severity: .notice,
                actionText: .localized(.soundPacksStatusDeletePack),
                messageText: .localized(.soundPacksStatusPackTrashed, name))
        case .failure(let error):
            setWindowStatus(
                kind: .packDeletion,
                severity: .failure,
                actionText: .localized(.soundPacksStatusDeletePack),
                messageText: error.statusText,
                packID: selectedPackID)
            if let invalidatedPackID {
                if packDeletionFailureChangedDisk(error) {
                    completeSynchronousWrite(
                        .changedDespiteFailure,
                        invalidatingPackIDs: [invalidatedPackID],
                        mutation: mutation)
                } else {
                    completeSynchronousWrite(.failed, mutation: mutation)
                    if packDeletionFailureInvalidatesWindowReadModel(error) {
                        reload(followActivePack: false)
                    }
                }
            } else {
                completeSynchronousWrite(.failed, mutation: mutation)
            }
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
        setWindowStatus(
            kind: kind,
            severity: severity,
            actionText: .literal(action),
            messageText: .literal(message),
            packID: packID,
            actionID: actionID,
            recovery: recovery)
    }

    private func setWindowStatus(
        kind: SoundPacksWindowStatusKind,
        severity: SoundPacksWindowStatusSeverity,
        actionText: SoundPacksWindowStatusText,
        messageText: SoundPacksWindowStatusText,
        packID: String? = nil,
        actionID: Int? = nil,
        recovery: SoundPacksWindowStatusRecovery? = nil
    ) {
        statusRevision += 1
        statusByKind[kind] = SoundPacksWindowStatus(
            kind: kind,
            severity: severity,
            revision: statusRevision,
            actionText: actionText,
            messageText: messageText,
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
        statusByKind[.audio] = SoundPacksWindowStatus(
            kind: status.kind,
            severity: status.severity,
            revision: status.revision,
            actionText: status.actionText,
            messageText: status.messageText.asBackgroundOperation(),
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

    private func manifestBindFailureInvalidatesWindowReadModel(
        _ error: ManifestBindError
    ) -> Bool {
        switch error {
        case .packNotFound, .fileNotFound, .manifestUnreadable, .targetChanged:
            return true
        case .unsafeFileName, .writeFailed, .lockBusy, .lockFailed:
            return false
        }
    }

    private func packDeletionFailureChangedDisk(
        _ error: SoundPacksWindowPackDeletionActionError
    ) -> Bool {
        switch error {
        case .delete(.isolationChangedRetained), .delete(.trashFailedRetained):
            return true
        case .writesStopped, .noSelectedPack, .selectionChanged, .delete:
            return false
        }
    }

    private func packDeletionFailureInvalidatesWindowReadModel(
        _ error: SoundPacksWindowPackDeletionActionError
    ) -> Bool {
        switch error {
        case .delete(.packNotFound), .delete(.unsafePackEntry):
            return true
        case .writesStopped, .noSelectedPack, .selectionChanged, .delete:
            return false
        }
    }

    private func reloadSelectedAudioInventory(packID: String) {
        if packCards.first(where: { $0.id == packID })?.availability
            == .missingSelectedPlaceholder
        {
            audioInventoryTask?.cancel()
            selectedAudioInventoryPackID = nil
            selectedAudioInventoryState = .ready([])
            return
        }
        if readSource.readsSharedSnapshot {
            audioInventoryTask?.cancel()
            let previous = selectedAudioInventoryPackID == packID ? selectedAudioFiles : nil
            let selectionGeneration = inspectionSelectionRevision
            selectedAudioInventoryPackID = packID
            selectedAudioInventoryState = .loading(previous: previous)
            audioInventoryTask = Task { @MainActor [weak self, soundPackLibrary] in
                let inventory = await soundPackLibrary.audioInventory(packID: packID)
                guard !Task.isCancelled, let self, self.selectedPackID == packID,
                    self.inspectionSelectionRevision == selectionGeneration
                else { return }
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
                self.markEditorStateSettled()
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
        completeSynchronousWrite(
            outcome,
            invalidatingPackIDs: invalidatingPackIDs,
            mutation: nil)
    }

    @discardableResult
    private func completeSynchronousWrite(
        _ outcome: SoundPacksWindowWriteOutcome,
        invalidatingPackIDs: Set<String> = [],
        mutation: SoundPackLibraryMutation?
    ) -> SoundPacksRefreshEffect {
        var needsLegacyRefresh = false
        if let mutation {
            if !soundPackLibrary.endMutation(mutation, changed: outcome != .failed),
                outcome != .failed,
                !invalidatingPackIDs.isEmpty
            {
                // A replayed or foreign token cannot release a mutation fence. Preserve the
                // current library's read-model safety without crashing production.
                soundPackLibrary.invalidate(packIDs: invalidatingPackIDs)
                needsLegacyRefresh = true
            }
        } else if outcome != .failed, readSource.readsSharedSnapshot,
            !invalidatingPackIDs.isEmpty
        {
            // Compatibility for callers that only use the pre-transaction public completion API.
            soundPackLibrary.invalidate(packIDs: invalidatingPackIDs)
            needsLegacyRefresh = true
        }
        if outcome != .failed {
            if !readSource.readsSharedSnapshot {
                reload(followActivePack: false)
            } else {
                configState = loadPanelConfig(from: configFile)
                baseConfig = configState.resolvedConfig
                applyManagedScopeConfig()
                if let librarySnapshot {
                    applySnapshot(librarySnapshot, followActivePack: false)
                }
                if needsLegacyRefresh {
                    Task { await soundPackLibrary.requestRefresh(trigger: .write) }
                }
            }
        }
        return refreshCoordinator.completeWindowWrite(outcome)
    }

    private func beginSoundPackMutation(packIDs: Set<String>) -> SoundPackLibraryMutation? {
        guard readSource.readsSharedSnapshot, !packIDs.isEmpty else { return nil }
        return soundPackLibrary.beginMutation(packIDs: packIDs)
    }

    private func finishSoundPackMutation(_ mutation: SoundPackLibraryMutation?) {
        guard let mutation else { return }
        _ = soundPackLibrary.endMutation(mutation, changed: false)
    }
}

extension SoundPackLibraryState {
    fileprivate var snapshotRevision: UInt64? {
        switch self {
        case .unloaded:
            nil
        case .loading(let previous), .failed(let previous, _):
            previous?.revision
        case .ready(let snapshot):
            snapshot.revision
        }
    }
}

private func factoryRestorePackID(
    in error: SoundPacksWindowFactoryRestoreActionError
) -> String? {
    switch error {
    case .restore(let packID, _, _): return packID
    case .writesStopped, .noSelectedPack, .selectionChanged, .notBuiltin: return nil
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
