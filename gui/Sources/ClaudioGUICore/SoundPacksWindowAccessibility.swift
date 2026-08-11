import ClaudioCore
import ClaudioLocalization
import Combine
import Foundation

/// One real keyboard stop in the Sound Packs standard window.
///
/// This identity space is intentionally window-owned. A standard, resizable `NSWindow` has a
/// different visual order and lifetime from the transient menu-bar panel, so none of the
/// `Panel*` accessibility types participate here.
public enum SoundPacksWindowFocusTarget: Sendable, Hashable {
    /// Library-level retry rendered in the status bar after an initial or refresh failure.
    case retryLibraryLoad
    /// The native pack `List` is one Tab stop; arrow keys move between its rows.
    case packList
    /// The selected pack's 「在访达中显示」 button.
    case revealSelectedPack
    case forkFactoryPack
    case addAudio
    /// A built-in pack's explicitly-confirmed 「恢复出厂声音…」 button.
    case restoreFactoryPack
    case useSelectedPack
    case restoreAllFactoryPacks
    case revealPacksDirectory
    /// Window-level retry after the attempted built-in disappeared during a failed publish.
    case retryFactoryRestore(packID: String)
    /// One selected-pack event mapping's existing-audio menu.
    case eventAudio(Event)
    /// One selected-pack event mapping's playable-audio preview button.
    case eventPreview(Event)
    /// One orphan row's 「分配…」 menu.
    case orphanAssignment(fileName: String)
    /// One orphan row's irreversible 「删除」 button.
    case orphanDeletion(fileName: String)
}

/// The visible facts needed to derive the window's current keyboard order.
public struct SoundPacksWindowFocusScope: Sendable, Equatable {
    public let packIDs: [String]
    public let selectedPackID: String?
    public let editableEvents: [Event]
    public let previewableEvents: [Event]
    public let orphanFileNames: [String]
    public let canEditSelectedPack: Bool
    public let canForkFactoryPack: Bool
    public let canAddAudio: Bool
    public let canRestoreFactoryPack: Bool
    public let canUseSelectedPack: Bool
    public let canRestoreAllFactoryPacks: Bool
    public let canRevealPacksDirectory: Bool
    public let canRetryLibraryLoad: Bool
    public let retryFactoryRestorePackIDs: [String]

    public init(
        packIDs: [String],
        selectedPackID: String?,
        editableEvents: [Event] = [],
        previewableEvents: [Event] = [],
        orphanFileNames: [String] = [],
        canEditSelectedPack: Bool = false,
        canForkFactoryPack: Bool = false,
        canAddAudio: Bool = false,
        canRestoreFactoryPack: Bool = false,
        canUseSelectedPack: Bool = false,
        canRestoreAllFactoryPacks: Bool = false,
        canRevealPacksDirectory: Bool = false,
        canRetryLibraryLoad: Bool = false,
        retryFactoryRestorePackIDs: [String] = []
    ) {
        self.packIDs = packIDs
        self.selectedPackID = selectedPackID
        self.editableEvents = editableEvents
        self.previewableEvents = previewableEvents
        self.orphanFileNames = orphanFileNames
        self.canEditSelectedPack = canEditSelectedPack
        self.canForkFactoryPack = canForkFactoryPack
        self.canAddAudio = canAddAudio
        self.canRestoreFactoryPack = canRestoreFactoryPack
        self.canUseSelectedPack = canUseSelectedPack
        self.canRestoreAllFactoryPacks = canRestoreAllFactoryPacks
        self.canRevealPacksDirectory = canRevealPacksDirectory
        self.canRetryLibraryLoad = canRetryLibraryLoad
        self.retryFactoryRestorePackIDs = retryFactoryRestorePackIDs
    }
}

/// Tab order follows the standard window's visual reading order: sidebar list, then detail action.
///
/// An empty list is deliberately absent rather than becoming a dead opening focus. A stale
/// selection also cannot create a focus target for a detail button that is not rendered.
public func soundPacksWindowFocusOrder(
    _ scope: SoundPacksWindowFocusScope
) -> [SoundPacksWindowFocusTarget] {
    var order: [SoundPacksWindowFocusTarget] = []
    if scope.canRetryLibraryLoad {
        order.append(.retryLibraryLoad)
    }
    if !scope.packIDs.isEmpty {
        order.append(.packList)
    }
    order.append(
        contentsOf: scope.retryFactoryRestorePackIDs.map {
            .retryFactoryRestore(packID: $0)
        })
    if scope.packIDs.isEmpty {
        if scope.canRestoreAllFactoryPacks {
            order.append(.restoreAllFactoryPacks)
        } else if scope.canRevealPacksDirectory {
            order.append(.revealPacksDirectory)
        }
    }
    if let selectedPackID = scope.selectedPackID,
        scope.packIDs.contains(selectedPackID)
    {
        order.append(.revealSelectedPack)
        // Event and orphan controls live in the scrolling detail region above the fixed bottom
        // action bar. Keep this pure order identical to that visible hierarchy.
        for event in Event.allCases {
            if scope.canEditSelectedPack, scope.editableEvents.contains(event) {
                order.append(.eventAudio(event))
            }
            if scope.previewableEvents.contains(event) {
                order.append(.eventPreview(event))
            }
        }
        if scope.canEditSelectedPack {
            for fileName in scope.orphanFileNames {
                order.append(.orphanAssignment(fileName: fileName))
                order.append(.orphanDeletion(fileName: fileName))
            }
        }
        if scope.canForkFactoryPack {
            order.append(.forkFactoryPack)
        }
        if scope.canAddAudio {
            order.append(.addAudio)
        }
        if scope.canRestoreFactoryPack {
            order.append(.restoreFactoryPack)
        }
        if scope.canUseSelectedPack {
            order.append(.useSelectedPack)
        }
    }
    return order
}

public func soundPacksWindowFirstFocusTarget(
    _ scope: SoundPacksWindowFocusScope
) -> SoundPacksWindowFocusTarget? {
    soundPacksWindowFocusOrder(scope).first
}

/// A monotonic request channel from the retained `NSWindow` owner to SwiftUI's real FocusState.
///
/// The owner increments this only for a real hidden→visible presentation (first open or retained
/// reopen). Re-invoking show while already visible leaves focus untouched. The view remembers the
/// last revision it handled, so ordinary body recomputation does not steal focus back.
@MainActor
public final class SoundPacksWindowFocusCoordinator: ObservableObject {
    @Published public private(set) var requestRevision = 0
    @Published public private(set) var requestedRoute: SoundPacksWindowRoute = .overview

    public init() {}

    public func requestInitialFocus(route: SoundPacksWindowRoute = .overview) {
        requestedRoute = route
        requestRevision += 1
    }

    public func requestRoute(_ route: SoundPacksWindowRoute) {
        requestedRoute = route
        requestRevision += 1
    }
}

/// Tracks status announcements across the AppKit bridge's asynchronous key-window recheck.
/// A revision is consumed only after `NSAccessibility.post` is actually reached; an attempt that
/// loses key status remains retryable when the retained window becomes key again.
public struct SoundPacksWindowStatusAnnouncementTracker: Sendable, Equatable {
    public private(set) var lastPostedRevision = 0
    private var inFlightRevisions: Set<Int> = []

    public init() {}

    public mutating func beginAttempt(revision: Int, isWindowKey: Bool) -> Bool {
        guard
            isWindowKey,
            revision > lastPostedRevision,
            !inFlightRevisions.contains(revision)
        else { return false }
        inFlightRevisions.insert(revision)
        return true
    }

    public mutating func finishAttempt(revision: Int, didPost: Bool) {
        inFlightRevisions.remove(revision)
        if didPost {
            lastPostedRevision = max(lastPostedRevision, revision)
        }
    }
}

/// Window-specific Dynamic Type tiers. They describe this standard window, not the panel's width
/// ladder.
public enum SoundPacksWindowTypeSizeTier: Sendable, CaseIterable {
    case standard
    case enlarged
    case accessibility
}

/// Reflow decisions consumed by `SoundPacksWindowView`.
///
/// At accessibility sizes the two main regions stack vertically, preserving useful line length at
/// up to 400% text scaling. Detail content remains scrollable, and critical controls never rely on
/// a single-line truncation to fit.
public struct SoundPacksWindowLayoutAdaptation: Sendable, Equatable {
    public let stacksPrimaryRegions: Bool
    public let stacksDetailHeader: Bool
    public let stacksEventRows: Bool
    public let sidebarMinimumWidth: Double
    public let sidebarIdealWidth: Double
    public let sidebarMaximumWidth: Double
    public let detailMinimumWidth: Double
    public let sidebarMinimumHeight: Double
    public let packNameLineLimit: Int?

    public init(
        stacksPrimaryRegions: Bool,
        stacksDetailHeader: Bool,
        stacksEventRows: Bool,
        sidebarMinimumWidth: Double,
        sidebarIdealWidth: Double,
        sidebarMaximumWidth: Double,
        detailMinimumWidth: Double,
        sidebarMinimumHeight: Double,
        packNameLineLimit: Int?
    ) {
        self.stacksPrimaryRegions = stacksPrimaryRegions
        self.stacksDetailHeader = stacksDetailHeader
        self.stacksEventRows = stacksEventRows
        self.sidebarMinimumWidth = sidebarMinimumWidth
        self.sidebarIdealWidth = sidebarIdealWidth
        self.sidebarMaximumWidth = sidebarMaximumWidth
        self.detailMinimumWidth = detailMinimumWidth
        self.sidebarMinimumHeight = sidebarMinimumHeight
        self.packNameLineLimit = packNameLineLimit
    }
}

extension SoundPacksWindowLayoutAdaptation {
    public var stacksActionBar: Bool { stacksDetailHeader }
}

public func soundPacksWindowLayoutAdaptation(
    for tier: SoundPacksWindowTypeSizeTier
) -> SoundPacksWindowLayoutAdaptation {
    switch tier {
    case .standard:
        SoundPacksWindowLayoutAdaptation(
            stacksPrimaryRegions: false,
            stacksDetailHeader: false,
            stacksEventRows: false,
            sidebarMinimumWidth: 176,
            sidebarIdealWidth: 176,
            sidebarMaximumWidth: 220,
            detailMinimumWidth: 380,
            sidebarMinimumHeight: 0,
            packNameLineLimit: 1)
    case .enlarged:
        SoundPacksWindowLayoutAdaptation(
            stacksPrimaryRegions: false,
            stacksDetailHeader: true,
            stacksEventRows: true,
            sidebarMinimumWidth: 196,
            sidebarIdealWidth: 220,
            sidebarMaximumWidth: 280,
            detailMinimumWidth: 360,
            sidebarMinimumHeight: 0,
            packNameLineLimit: nil)
    case .accessibility:
        SoundPacksWindowLayoutAdaptation(
            stacksPrimaryRegions: true,
            stacksDetailHeader: true,
            stacksEventRows: true,
            sidebarMinimumWidth: 0,
            sidebarIdealWidth: 0,
            sidebarMaximumWidth: .greatestFiniteMagnitude,
            detailMinimumWidth: 0,
            sidebarMinimumHeight: 160,
            packNameLineLimit: nil)
    }
}

/// Detail rows must respond to the space the split view actually gives them. A restored narrow
/// window can make the detail column compact even at the standard text setting, while the larger
/// text tiers still force the safer stacked shape regardless of width.
public func soundPacksWindowDetailUsesStackedLayout(
    detailWidth: Double,
    tier: SoundPacksWindowTypeSizeTier
) -> Bool {
    soundPacksWindowLayoutAdaptation(for: tier).stacksDetailHeader || detailWidth < 460
}

/// VoiceOver label for one native list row. Selection itself is exposed by the List; this sentence
/// supplies the independent active-pack, integrity, completeness, and license facts.
public func soundPacksWindowPackAccessibilityLabel(
    displayName: String,
    isActivePack: Bool,
    state: PackCardState,
    license: PackRowLicenseBadge
) -> String {
    var facts = [displayName]
    if isActivePack { facts.append("当前正在使用") }

    switch state {
    case .complete:
        facts.append("\(Event.allCases.count) 个事件均已配置")
    case .partial(let present, let total):
        facts.append("\(present)/\(total) 个事件已配置，缺 \(max(0, total - present)) 个")
    case .broken(let reason):
        facts.append("声音包不可用：\(reason)")
    }

    switch license {
    case .none:
        break
    case .cc0:
        facts.append("CC0")
    case .modified:
        facts.append("内置包已被修改")
    }

    return facts.joined(separator: "，")
}

/// VoiceOver label for one read-only event mapping status row.
///
/// Broken and intentionally-unmapped are distinct sentences. A missing file is explicitly called
/// an error instead of being flattened into ordinary secondary-colored metadata.
public func soundPacksWindowEventAccessibilityLabel(
    eventName: String,
    coverage: CoverageState,
    enabled: Bool
) -> String {
    let enabledFact = enabled ? "已启用" : "已静音"
    switch coverage {
    case .present(let fileName):
        return "\(eventName)，声音 \(fileName)，\(enabledFact)"
    case .unmapped:
        return "\(eventName)，未配置声音，\(enabledFact)"
    case .broken(let fileName):
        return "\(eventName)，错误，声音文件 \(fileName) 丢失，\(enabledFact)"
    }
}

/// A write-failure row's window-owned Name/Value sentence. T11/T12/T17 callers supply the visible
/// action and the same actionable reason they render; VoiceOver never receives a color-only error.
public func soundPacksWindowFailureAccessibilityLabel(
    action: String,
    reason: String
) -> String {
    if action.isEmpty {
        return reason.isEmpty ? "操作失败" : "操作失败：\(reason)"
    }
    return reason.isEmpty ? "\(action)失败" : "\(action)失败：\(reason)"
}

public enum SoundPacksWindowAnnouncementMoment: Sendable, Equatable {
    case windowOpened
    case libraryStateChanged
    case selectionChanged
    case writeSucceeded(message: String)
    case writeFailed(action: String, reason: String)
}

public struct SoundPacksWindowAnnouncementFacts: Sendable, Equatable {
    public let packCount: Int
    public let selectedPackName: String?
    public let libraryPresentationState: SoundPackLibraryPresentationState

    public init(
        packCount: Int,
        selectedPackName: String?,
        libraryPresentationState: SoundPackLibraryPresentationState = .ready
    ) {
        self.packCount = packCount
        self.selectedPackName = selectedPackName
        self.libraryPresentationState = libraryPresentationState
    }
}

/// Window-owned VoiceOver announcement policy for presentation, inspection selection, and future
/// write failures.
public func soundPacksWindowAnnouncement(
    _ moment: SoundPacksWindowAnnouncementMoment,
    facts: SoundPacksWindowAnnouncementFacts,
    language: ClaudioAppLanguage = .zhHans
) -> String {
    let l10n = ClaudioL10n(language: language)
    switch moment {
    case .windowOpened:
        switch facts.libraryPresentationState {
        case .loading:
            return l10n.text(.soundPacksAnnouncementWindowLoading)
        case .loadFailed(let reason):
            return l10n.format(
                .soundPacksAnnouncementWindowFailure,
                libraryFailureAnnouncement(reason: reason, refresh: false, language: language))
        case .refreshFailed(let reason):
            return l10n.format(
                .soundPacksAnnouncementWindowFailure,
                libraryFailureAnnouncement(reason: reason, refresh: true, language: language))
        case .ready, .refreshing:
            break
        }
        guard facts.packCount > 0 else {
            return l10n.text(.soundPacksAnnouncementWindowEmpty)
        }
        if let selectedPackName = facts.selectedPackName {
            return l10n.format(
                .soundPacksAnnouncementWindowSelected,
                "\(facts.packCount)",
                selectedPackName)
        }
        return l10n.format(.soundPacksAnnouncementWindowUnselected, "\(facts.packCount)")
    case .libraryStateChanged:
        switch facts.libraryPresentationState {
        case .loading:
            return l10n.text(.soundPacksAnnouncementLibraryLoading)
        case .refreshing:
            return l10n.text(.soundPacksAnnouncementLibraryRefreshing)
        case .loadFailed(let reason):
            return libraryFailureAnnouncement(reason: reason, refresh: false, language: language)
        case .refreshFailed(let reason):
            return libraryFailureAnnouncement(reason: reason, refresh: true, language: language)
        case .ready:
            if facts.packCount == 0 {
                return l10n.text(.soundPacksAnnouncementLibraryReadyEmpty)
            }
            return l10n.format(.soundPacksAnnouncementLibraryReadyCount, "\(facts.packCount)")
        }
    case .selectionChanged:
        guard let selectedPackName = facts.selectedPackName else {
            return l10n.text(.soundPacksAnnouncementSelectionNone)
        }
        return l10n.format(.soundPacksAnnouncementSelectionSelected, selectedPackName)
    case .writeSucceeded(let message):
        return message
    case .writeFailed(let action, let reason):
        return localizedSoundPacksFailureAccessibilityLabel(
            action: action,
            reason: reason,
            language: language)
    }
}

private func libraryFailureAnnouncement(
    reason: String,
    refresh: Bool,
    language: ClaudioAppLanguage
) -> String {
    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedReason: String
    if trimmed.last.map({ "。！？!?".contains($0) }) == true {
        normalizedReason = String(trimmed.dropLast())
    } else {
        normalizedReason = trimmed
    }
    let l10n = ClaudioL10n(language: language)
    if refresh {
        return l10n.format(.soundPacksAnnouncementLibraryRefreshFailed, normalizedReason)
    }
    return l10n.format(.soundPacksAnnouncementLibraryLoadFailed, normalizedReason)
}
