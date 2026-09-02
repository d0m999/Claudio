import ClaudioCore
import Darwin
import Foundation

/// A selected pack's shallow audio inventory. Normal library snapshots retain only ``deferred``;
/// the shared library loads this value off-main when a consumer actually inspects that pack.
public enum SoundPackAudioInventory: Sendable, Equatable {
    /// The full directory inventory is intentionally loaded only for an inspected/active pack.
    case deferred
    case available([PackAudioFile])
    case unavailable(PackAudioInventoryError)
}

/// Native targets validated during the same stable scan interval as their render facts.
/// Callers consume these immutable URLs through owner-signed actions; they never reconstruct
/// paths or repeat blocking filesystem checks on `MainActor`.
package struct SoundPackNativeTargets: Sendable, Equatable {
    package let directoryURL: URL
    package let eventAudioURLs: [Event: URL]
}

/// Immutable facts read from one installed sound pack. User configuration is deliberately absent:
/// selection, stars, mute flags, and panel placement are projections of a snapshot at consumption
/// time, not cache entries.
public struct SoundPackFacts: Sendable, Equatable {
    public let id: String
    public let name: String?
    public let isCC0: Bool
    public let factoryIntegrity: Bool?
    public let eventCoverage: [Event: CoverageState]
    public let eventAudioDisplayNames: [Event: String]
    public let cardState: PackCardState
    public let audioInventory: SoundPackAudioInventory
    package let nativeTargets: SoundPackNativeTargets?

    fileprivate let declaredAudioFileNames: [String]
    fileprivate let factoryDeclaredAudioFileNames: [String]
    fileprivate let fingerprint: SoundPackFingerprint?

    public init(
        id: String,
        name: String?,
        isCC0: Bool,
        factoryIntegrity: Bool?,
        eventCoverage: [Event: CoverageState],
        eventAudioDisplayNames: [Event: String] = [:],
        cardState: PackCardState,
        audioInventory: SoundPackAudioInventory
    ) {
        self.init(
            id: id,
            name: name,
            isCC0: isCC0,
            factoryIntegrity: factoryIntegrity,
            eventCoverage: eventCoverage,
            eventAudioDisplayNames: eventAudioDisplayNames,
            cardState: cardState,
            audioInventory: audioInventory,
            nativeTargets: nil,
            declaredAudioFileNames: [],
            factoryDeclaredAudioFileNames: [],
            fingerprint: nil)
    }

    fileprivate init(
        id: String,
        name: String?,
        isCC0: Bool,
        factoryIntegrity: Bool?,
        eventCoverage: [Event: CoverageState],
        eventAudioDisplayNames: [Event: String],
        cardState: PackCardState,
        audioInventory: SoundPackAudioInventory,
        nativeTargets: SoundPackNativeTargets?,
        declaredAudioFileNames: [String],
        factoryDeclaredAudioFileNames: [String],
        fingerprint: SoundPackFingerprint?
    ) {
        self.id = id
        self.name = name
        self.isCC0 = isCC0
        self.factoryIntegrity = factoryIntegrity
        self.eventCoverage = eventCoverage
        self.eventAudioDisplayNames = eventAudioDisplayNames
        self.cardState = cardState
        self.audioInventory = audioInventory
        self.nativeTargets = nativeTargets
        self.declaredAudioFileNames = declaredAudioFileNames
        self.factoryDeclaredAudioFileNames = factoryDeclaredAudioFileNames
        self.fingerprint = fingerprint
    }

    fileprivate func replacingFingerprint(_ fingerprint: SoundPackFingerprint) -> SoundPackFacts {
        SoundPackFacts(
            id: id,
            name: name,
            isCC0: isCC0,
            factoryIntegrity: factoryIntegrity,
            eventCoverage: eventCoverage,
            eventAudioDisplayNames: eventAudioDisplayNames,
            cardState: cardState,
            audioInventory: audioInventory,
            nativeTargets: nativeTargets,
            declaredAudioFileNames: declaredAudioFileNames,
            factoryDeclaredAudioFileNames: factoryDeclaredAudioFileNames,
            fingerprint: fingerprint)
    }

    #if DEBUG
    public var fingerprintedAudioFileCountForTesting: Int {
        declaredAudioFileNames.count
    }
    #endif
}

/// One successful, app-session-only read of the complete installed library.
public struct SoundPackLibrarySnapshot: Sendable, Equatable {
    public let revision: UInt64
    public let facts: [SoundPackFacts]
    public let factoryPackIDs: Set<String>

    fileprivate init(
        revision: UInt64,
        facts: [SoundPackFacts],
        factoryPackIDs: Set<String>
    ) {
        self.revision = revision
        self.facts = facts.sorted { $0.id < $1.id }
        self.factoryPackIDs = factoryPackIDs
    }

    public func fact(for packID: String) -> SoundPackFacts? {
        facts.first { $0.id == packID }
    }

    /// Projects disk facts into render cards using the config supplied *now*.
    public func packCards(
        config: ClaudioConfig,
        scope: PackCardReadScope = .fullLibrary,
        defaultStarredPackIDs: Set<String> = []
    ) -> [PackCard] {
        let selectedFacts: [SoundPackFacts]
        switch scope {
        case .fullLibrary:
            selectedFacts = facts
        case .panelStarredDisplay:
            let ids = starredPackDisplayIDs(
                orderedPackIDs: facts.map(\.id),
                starredPacks: config.starredPacks,
                defaultStarredPackIDs: defaultStarredPackIDs)
            let factsByID = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) })
            selectedFacts = ids.compactMap { factsByID[$0] }
        }
        var cards = selectedFacts.map { fact in
            PackCard(
                id: fact.id,
                name: fact.name,
                isCC0: fact.isCC0,
                factoryIntegrity: fact.factoryIntegrity,
                presentEvents: Set(
                    fact.eventCoverage.compactMap { event, coverage in
                        coverage.previewEnabled ? event : nil
                    }),
                state: fact.cardState,
                isSelected: fact.id == config.selectedPack)
        }
        if scope == .fullLibrary,
            isSafePackID(config.selectedPack),
            !config.selectedPack.isEmpty,
            fact(for: config.selectedPack) == nil
        {
            cards.append(missingSelectedPackPlaceholder(packID: config.selectedPack))
        }
        return cards
    }

    /// Projects the latest mute flags over cached per-event disk coverage.
    public func eventRows(packID: String, config: ClaudioConfig) -> [EventRow] {
        let coverage = fact(for: packID)?.eventCoverage ?? [:]
        return Event.allCases.map { event in
            EventRow(
                event: event,
                coverage: coverage[event] ?? .unmapped,
                enabled: config.isEnabled(event),
                audioDisplayName: fact(for: packID)?.eventAudioDisplayNames[event])
        }
    }

    public func selectedPackMetadata(packID: String) -> SelectedPackMetadata {
        SelectedPackMetadata(id: packID, name: fact(for: packID)?.name)
    }

    public func audioInventory(packID: String) -> SoundPackAudioInventory? {
        fact(for: packID)?.audioInventory
    }
}

public enum SoundPackLibraryError: Error, Sendable, Equatable {
    case rootNotDirectory(path: String)
    case rootUnreadable(path: String, reason: String)
    case scanFailed(reason: String)

    public var message: String {
        switch self {
        case .rootNotDirectory(let path):
            return "声音包位置不是文件夹：\(path)"
        case .rootUnreadable(let path, let reason):
            return "无法读取声音包位置 \(path)：\(reason)"
        case .scanFailed(let reason):
            return reason
        }
    }
}

/// Exhaustive replayed state for every library consumer.
public enum SoundPackLibraryState: Sendable, Equatable {
    case unloaded
    case loading(previous: SoundPackLibrarySnapshot?)
    case ready(SoundPackLibrarySnapshot)
    case failed(previous: SoundPackLibrarySnapshot?, error: SoundPackLibraryError)
}

enum SoundPackLibraryBrokenReasonToken: String, Sendable {
    case manifestIdentityMismatch = "sound-pack-library.manifest-identity-mismatch"
}

public enum SoundPackLibraryRefreshTrigger: Sendable, Equatable {
    case initial
    case panelPresentation
    case windowPresentation
    case applicationActivation
    case bootstrap
    case write
    case retry
}

/// Immutable input supplied to an injected scanner. The production scanner uses `previous` and
/// `invalidatedPackIDs` for metadata-based incremental reads; tests can deterministically exercise
/// actor scheduling without touching process-global paths.
public struct SoundPackLibraryScanRequest: Sendable {
    public let previous: SoundPackLibrarySnapshot?
    public let invalidatedPackIDs: Set<String>
    /// `true` when every prior fact must be rebuilt, even if its metadata fingerprint matches.
    /// This is separate from `invalidatedPackIDs`: an empty set otherwise means no targeted pack.
    public let invalidatesAll: Bool

    public init(
        previous: SoundPackLibrarySnapshot?,
        invalidatedPackIDs: Set<String>,
        invalidatesAll: Bool = false
    ) {
        self.previous = previous
        self.invalidatedPackIDs = invalidatedPackIDs
        self.invalidatesAll = invalidatesAll
    }
}

public struct SoundPackLibraryScanOutput: Sendable, Equatable {
    public let facts: [SoundPackFacts]
    public let factoryPackIDs: Set<String>

    public init(facts: [SoundPackFacts], factoryPackIDs: Set<String> = []) {
        self.facts = facts
        self.factoryPackIDs = factoryPackIDs
    }
}

private enum SoundPackBlockingIO {
    static let scanQueue = DispatchQueue(
        label: "com.claudio.sound-pack-library.scan",
        qos: .utility)
    static let inventoryQueue = DispatchQueue(
        label: "com.claudio.sound-pack-library.inventory",
        qos: .utility)
}

private final class SoundPackBlockingIOCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

public struct SoundPackLibraryScanner: Sendable {
    /// File-system work is blocking. A dedicated serial queue keeps it off Swift's cooperative
    /// executor while also preventing two app-session scans from competing for the same disk.
    private let operation:
        @Sendable (SoundPackLibraryScanRequest)
            -> Result<SoundPackLibraryScanOutput, SoundPackLibraryError>

    public init(
        operation:
            @escaping @Sendable (SoundPackLibraryScanRequest)
            -> Result<[SoundPackFacts], SoundPackLibraryError>
    ) {
        self.operation = { request in
            operation(request).map { SoundPackLibraryScanOutput(facts: $0) }
        }
    }

    public init(
        outputOperation:
            @escaping @Sendable (SoundPackLibraryScanRequest)
            -> Result<SoundPackLibraryScanOutput, SoundPackLibraryError>
    ) {
        operation = outputOperation
    }

    fileprivate func scan(_ request: SoundPackLibraryScanRequest) async
        -> Result<SoundPackLibraryScanOutput, SoundPackLibraryError>
    {
        await withCheckedContinuation { continuation in
            SoundPackBlockingIO.scanQueue.async {
                continuation.resume(returning: operation(request))
            }
        }
    }

    fileprivate static func live(environment: AudioImportEnvironment) -> SoundPackLibraryScanner {
        SoundPackLibraryScanner(outputOperation: { request in
            scanSoundPackLibrary(
                environment: environment,
                request: request,
                afterManifestRead: { _ in })
        })
    }

    #if DEBUG
    /// Production scanner with one deterministic observation point for atomic-replacement tests.
    public static func testingLive(
        environment: AudioImportEnvironment,
        onRequest: @escaping @Sendable (SoundPackLibraryScanRequest) -> Void = { _ in },
        afterManifestRead: @escaping @Sendable (String) -> Void
    ) -> SoundPackLibraryScanner {
        SoundPackLibraryScanner(outputOperation: { request in
            onRequest(request)
            return scanSoundPackLibrary(
                environment: environment,
                request: request,
                afterManifestRead: afterManifestRead)
        })
    }
    #endif
}

private struct SoundPackAudioInventoryLoader: Sendable {
    let operation: @Sendable (String) -> SoundPackAudioInventory

    static func live(environment: AudioImportEnvironment) -> Self {
        Self { packID in
            switch packAudioFiles(packID: packID, environment: environment) {
            case .success(let files): return .available(files)
            case .failure(let error): return .unavailable(error)
            }
        }
    }

    func load(packID: String) async -> SoundPackAudioInventory {
        let cancellation = SoundPackBlockingIOCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                SoundPackBlockingIO.inventoryQueue.async {
                    guard !cancellation.isCancelled else {
                        continuation.resume(
                            returning: .unavailable(
                                .directoryUnreadable(reason: "音频清单读取已取消")))
                        return
                    }
                    continuation.resume(returning: operation(packID))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

private struct SoundPackLibraryInvalidation: Sendable {
    let revision: UInt64
    let packIDs: Set<String>
    let invalidatesAll: Bool
}

/// Synchronous mailbox used only at the write boundary. Incrementing this clock before a disk
/// mutation means a detached scan that started earlier cannot publish after that mutation, even if
/// the actor has not yet dequeued the invalidation message.
private final class SoundPackLibraryInvalidationMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var invalidatedPackIDs: Set<String> = []
    private var invalidatesAll = false

    func invalidate(packIDs: Set<String>) {
        lock.lock()
        revision &+= 1
        if packIDs.isEmpty {
            invalidatesAll = true
            invalidatedPackIDs.removeAll()
        } else if !invalidatesAll {
            invalidatedPackIDs.formUnion(packIDs)
        }
        lock.unlock()
    }

    func snapshot() -> SoundPackLibraryInvalidation {
        lock.lock()
        defer { lock.unlock() }
        return SoundPackLibraryInvalidation(
            revision: revision,
            packIDs: invalidatesAll ? [] : invalidatedPackIDs,
            invalidatesAll: invalidatesAll)
    }

    func isCurrent(_ candidateRevision: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return revision == candidateRevision
    }

    /// Linearizes publication against the nonisolated write boundary. If a writer invalidates
    /// first, `body` never runs; if publication wins, the writer cannot return from `invalidate`
    /// until the ready state has been fully published.
    func acknowledgeAndPerform(
        _ candidateRevision: UInt64,
        _ body: () -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard revision == candidateRevision else { return false }
        invalidatedPackIDs.removeAll()
        invalidatesAll = false
        body()
        return true
    }

    /// Runs a terminal publication only while the scan's revision is still current, without
    /// acknowledging pending invalidations. A failed scan has not rebuilt those invalidated facts,
    /// so clearing the mailbox here would lose the next refresh's work set.
    func performIfCurrent(
        _ candidateRevision: UInt64,
        _ body: () -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard revision == candidateRevision else { return false }
        body()
        return true
    }
}

/// App-lifetime owner of sound-pack scanning, incremental fingerprints, refresh coalescing, and the
/// session snapshot. It owns no UI or user configuration.
public actor SoundPackLibrary {
    private let scanner: SoundPackLibraryScanner
    private let inventoryLoader: SoundPackAudioInventoryLoader?
    #if DEBUG
    private let beforeReadyPublication: @Sendable () -> Void
    private let beforeFailurePublication: @Sendable () -> Void
    #endif
    private nonisolated let invalidationMailbox = SoundPackLibraryInvalidationMailbox()
    private var state: SoundPackLibraryState = .unloaded
    private var snapshot: SoundPackLibrarySnapshot?
    private var nextSnapshotRevision: UInt64 = 0
    private var continuations: [UUID: AsyncStream<SoundPackLibraryState>.Continuation] = [:]
    private var refreshInFlight = false
    private var activeInvalidationRevision: UInt64?
    private var followUpRequired = false
    private var refreshWaiters: [CheckedContinuation<SoundPackLibraryState, Never>] = []
    private var inventoryCache: [String: CachedAudioInventory] = [:]
    private var inventoryLRU: [String] = []
    private let inventoryCacheCapacity = 4

    public init(environment: AudioImportEnvironment) {
        scanner = .live(environment: environment)
        inventoryLoader = .live(environment: environment)
        #if DEBUG
        beforeReadyPublication = {}
        beforeFailurePublication = {}
        #endif
    }

    #if DEBUG
    /// Deterministic concurrency-test seams. They run after the early revision check and
    /// immediately before each mailbox-linearized terminal publication.
    public init(
        scanner: SoundPackLibraryScanner,
        inventoryOperation: (@Sendable (String) -> SoundPackAudioInventory)? = nil,
        beforeReadyPublication: @escaping @Sendable () -> Void = {},
        beforeFailurePublication: @escaping @Sendable () -> Void = {}
    ) {
        self.scanner = scanner
        inventoryLoader = inventoryOperation.map { SoundPackAudioInventoryLoader(operation: $0) }
        self.beforeReadyPublication = beforeReadyPublication
        self.beforeFailurePublication = beforeFailurePublication
    }
    #endif

    /// Every subscriber receives the current state immediately, then only newer states.
    public func states() -> AsyncStream<SoundPackLibraryState> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    /// Requests observed during a scan coalesce into exactly one follow-up scan. A presentation or
    /// activation can represent an external write that the in-flight scan has already passed, so
    /// silently folding it into that scan would make refresh-on-observation unreliable.
    public func requestRefresh(trigger: SoundPackLibraryRefreshTrigger) {
        guard !refreshInFlight else {
            // A later observation can arrive after this scan already passed the changed pack.
            // Keep exactly one follow-up instead of dropping that observation on the floor.
            followUpRequired = true
            return
        }
        startRefresh()
    }

    /// Requests a disk scan and returns only after the request is represented by a terminal state.
    /// If another scan is already in flight, the request joins the single coalesced follow-up scan
    /// instead of accepting that earlier scan's potentially stale result.
    public func refreshSnapshot(
        trigger: SoundPackLibraryRefreshTrigger
    ) async -> SoundPackLibraryState {
        await withCheckedContinuation { continuation in
            refreshWaiters.append(continuation)
            requestRefresh(trigger: trigger)
        }
    }

    /// Hydrates a newly attached consumer without turning a replayable ready snapshot into a new
    /// disk scan. Explicit presentation/activation refreshes continue to use `requestRefresh`.
    public func loadIfNeeded(trigger: SoundPackLibraryRefreshTrigger) {
        guard snapshot == nil, !refreshInFlight else { return }
        startRefresh()
    }

    #if DEBUG
    /// Deterministic harness synchronization; avoids wall-clock sleeps for negative scan checks.
    public func waitUntilIdleForTesting() async {
        for _ in 0..<3 { await Task.yield() }
        while refreshInFlight {
            await Task.yield()
        }
        for _ in 0..<3 { await Task.yield() }
    }

    public func inventoryCacheCountForTesting() -> Int {
        inventoryCache.count
    }

    /// Returns the actor's state so a harness can retain an older generation for replay.
    public func stateForTesting() -> SoundPackLibraryState {
        state
    }

    /// Replays a state through the production observation stream without changing the actor's
    /// actual state. This proves consumer-side duplicate/stale suppression without inventing a
    /// second callback or bypassing the app-lifetime library owner.
    public func replayStateForTesting(_ replayedState: SoundPackLibraryState? = nil) {
        let replayedState = replayedState ?? state
        for continuation in continuations.values {
            continuation.yield(replayedState)
        }
    }

    /// Suspends on the actor until a `refreshSnapshot` caller has installed its continuation and
    /// requested the in-flight follow-up. This is synchronization, not a wall-clock delay.
    public func waitUntilRefreshWaiterIsRegisteredForTesting() async {
        while refreshWaiters.isEmpty { await Task.yield() }
    }
    #endif

    /// Synchronous by design: callers invoke this immediately before a relevant disk mutation.
    /// The revision changes before control returns, while actor work is scheduled separately.
    public nonisolated func invalidate(packIDs: Set<String>) {
        invalidationMailbox.invalidate(packIDs: packIDs)
        Task { [weak self] in
            await self?.receiveInvalidation()
        }
    }

    /// Loads the shallow inventory only for the pack a consumer is actually presenting. Results
    /// are shared by both UI surfaces and retained in a four-entry fingerprint-keyed LRU.
    public func audioInventory(packID: String) async -> SoundPackAudioInventory {
        for _ in 0..<2 {
            guard let fact = snapshot?.fact(for: packID) else {
                return .unavailable(.packNotFound(packID: packID))
            }
            switch fact.audioInventory {
            case .available, .unavailable:
                return fact.audioInventory
            case .deferred:
                break
            }
            let fingerprint = fact.fingerprint
            if let cached = inventoryCache[packID], cached.fingerprint == fingerprint {
                touchInventoryCache(packID)
                return cached.inventory
            }
            guard let inventoryLoader else {
                return .unavailable(
                    .directoryUnreadable(reason: "当前扫描器没有提供音频清单加载器"))
            }
            let loaded = await inventoryLoader.load(packID: packID)
            guard snapshot?.fact(for: packID)?.fingerprint == fingerprint else { continue }
            if case .available = loaded {
                inventoryCache[packID] = CachedAudioInventory(
                    fingerprint: fingerprint,
                    inventory: loaded)
                touchInventoryCache(packID)
            }
            return loaded
        }
        return .unavailable(.directoryUnreadable(reason: "声音包在读取期间持续变化，请稍后重试"))
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func receiveInvalidation() {
        if refreshInFlight,
            activeInvalidationRevision != invalidationMailbox.snapshot().revision
        {
            followUpRequired = true
        }
    }

    private func startRefresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        followUpRequired = false
        publish(.loading(previous: snapshot))

        let scanner = self.scanner
        let previous = snapshot
        let invalidation = invalidationMailbox.snapshot()
        activeInvalidationRevision = invalidation.revision
        let request = SoundPackLibraryScanRequest(
            previous: previous,
            invalidatedPackIDs: invalidation.packIDs,
            invalidatesAll: invalidation.invalidatesAll)
        Task { [weak self] in
            let result = await scanner.scan(request)
            await self?.finishRefresh(result, invalidation: invalidation)
        }
    }

    private func finishRefresh(
        _ result: Result<SoundPackLibraryScanOutput, SoundPackLibraryError>,
        invalidation: SoundPackLibraryInvalidation
    ) {
        refreshInFlight = false
        activeInvalidationRevision = nil

        guard invalidationMailbox.isCurrent(invalidation.revision) else {
            followUpRequired = false
            startRefresh()
            return
        }

        if followUpRequired {
            followUpRequired = false
            startRefresh()
            return
        }

        let terminalState: SoundPackLibraryState
        switch result {
        case .success(let output):
            let candidateSnapshotRevision = nextSnapshotRevision &+ 1
            let next = SoundPackLibrarySnapshot(
                revision: candidateSnapshotRevision,
                facts: output.facts,
                factoryPackIDs: output.factoryPackIDs)
            pruneInventoryCache(for: next)
            #if DEBUG
            beforeReadyPublication()
            #endif
            let readyState = SoundPackLibraryState.ready(next)
            guard
                invalidationMailbox.acknowledgeAndPerform(
                    invalidation.revision,
                    {
                        nextSnapshotRevision = candidateSnapshotRevision
                        snapshot = next
                        publish(readyState)
                    })
            else {
                followUpRequired = false
                startRefresh()
                return
            }
            terminalState = readyState
        case .failure(let error):
            #if DEBUG
            beforeFailurePublication()
            #endif
            let failedState = SoundPackLibraryState.failed(previous: snapshot, error: error)
            guard
                invalidationMailbox.performIfCurrent(
                    invalidation.revision,
                    {
                        publish(failedState)
                    })
            else {
                followUpRequired = false
                startRefresh()
                return
            }
            terminalState = failedState
        }

        if followUpRequired {
            followUpRequired = false
            startRefresh()
            return
        }
        resumeRefreshWaiters(with: terminalState)
    }

    private func publish(_ next: SoundPackLibraryState) {
        state = next
        for continuation in continuations.values {
            continuation.yield(next)
        }
    }

    private func resumeRefreshWaiters(with state: SoundPackLibraryState) {
        let waiters = refreshWaiters
        refreshWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: state) }
    }

    private func touchInventoryCache(_ packID: String) {
        inventoryLRU.removeAll { $0 == packID }
        inventoryLRU.append(packID)
        while inventoryLRU.count > inventoryCacheCapacity {
            inventoryCache.removeValue(forKey: inventoryLRU.removeFirst())
        }
    }

    private func pruneInventoryCache(for snapshot: SoundPackLibrarySnapshot) {
        inventoryCache = inventoryCache.filter { packID, cached in
            snapshot.fact(for: packID)?.fingerprint == cached.fingerprint
        }
        inventoryLRU.removeAll { inventoryCache[$0] == nil }
    }
}

private struct SoundPackFileMetadata: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
}

private struct SoundPackNamedFileMetadata: Sendable, Equatable {
    let fileName: String
    let metadata: SoundPackFileMetadata?
}

private struct SoundPackFingerprint: Sendable, Equatable {
    let directory: SoundPackFileMetadata?
    let manifest: SoundPackFileMetadata?
    let declaredAudio: [SoundPackNamedFileMetadata]
    let factoryDirectory: SoundPackFileMetadata?
    let factoryManifest: SoundPackFileMetadata?
    let factoryDeclaredAudio: [SoundPackNamedFileMetadata]
}

private struct CachedAudioInventory: Sendable {
    let fingerprint: SoundPackFingerprint?
    let inventory: SoundPackAudioInventory
}

private func scanSoundPackLibrary(
    environment: AudioImportEnvironment,
    request: SoundPackLibraryScanRequest,
    afterManifestRead: @Sendable (String) -> Void
) -> Result<SoundPackLibraryScanOutput, SoundPackLibraryError> {
    let factoryPackIDs: Set<String>
    if let factoryRoot = environment.factoryPacksDirectory {
        switch readablePackDirectoryIDs(in: factoryRoot, absence: .failure) {
        case .success(let ids): factoryPackIDs = Set(ids)
        case .failure(let error): return .failure(error)
        }
    } else {
        factoryPackIDs = []
    }

    let orderedIDs: [String]
    switch installedPackIDs(environment: environment) {
    case .success(let ids): orderedIDs = ids
    case .failure(let error): return .failure(error)
    }

    let previousByID = Dictionary(
        uniqueKeysWithValues: (request.previous?.facts ?? []).map { ($0.id, $0) })
    var facts: [SoundPackFacts] = []
    facts.reserveCapacity(orderedIDs.count)

    for id in orderedIDs {
        if !request.invalidatesAll,
            !request.invalidatedPackIDs.contains(id),
            let previous = previousByID[id],
            let previousFingerprint = previous.fingerprint,
            currentFingerprint(
                id: id,
                environment: environment,
                factoryPackIDs: factoryPackIDs,
                declaredAudioFileNames: previous.declaredAudioFileNames,
                factoryDeclaredAudioFileNames: previous.factoryDeclaredAudioFileNames)
                == previousFingerprint
        {
            facts.append(previous)
            continue
        }
        facts.append(
            readSoundPackFacts(
                id: id,
                environment: environment,
                factoryPackIDs: factoryPackIDs,
                afterManifestRead: afterManifestRead))
    }
    return .success(
        SoundPackLibraryScanOutput(facts: facts, factoryPackIDs: factoryPackIDs))
}

private func installedPackIDs(
    environment: AudioImportEnvironment
) -> Result<[String], SoundPackLibraryError> {
    var seen: Set<String> = []
    var ids: [String] = []
    let roots = [environment.userPacksDirectory, environment.bundledPacksDirectory].compactMap {
        $0
    }
    for root in roots {
        let rootIDs: [String]
        switch readablePackDirectoryIDs(in: root, absence: .empty) {
        case .success(let loaded): rootIDs = loaded
        case .failure(let error): return .failure(error)
        }
        for id in rootIDs where seen.insert(id).inserted {
            ids.append(id)
        }
    }
    return .success(ids.sorted())
}

private enum SoundPackRootAbsencePolicy {
    case empty
    case failure
}

private func readablePackDirectoryIDs(
    in root: URL,
    absence: SoundPackRootAbsencePolicy
) -> Result<[String], SoundPackLibraryError> {
    var status = stat()
    var statusErrno: Int32 = 0
    let statusResult = root.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else {
            statusErrno = EINVAL
            return -1
        }
        let result = fstatat(AT_FDCWD, path, &status, 0)
        if result != 0 { statusErrno = errno }
        return result
    }
    if statusResult != 0 {
        if statusErrno == ENOENT {
            switch absence {
            case .empty:
                return .success([])
            case .failure:
                return .failure(
                    .rootUnreadable(path: root.path, reason: "配置的声音包位置不存在"))
            }
        }
        if statusErrno == ENOTDIR {
            return .failure(.rootNotDirectory(path: root.path))
        }
        return .failure(
            .rootUnreadable(
                path: root.path,
                reason: String(cString: strerror(statusErrno))))
    }
    guard (status.st_mode & S_IFMT) == S_IFDIR else {
        return .failure(.rootNotDirectory(path: root.path))
    }
    do {
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        return .success(
            entries.filter { id in
                guard !id.hasPrefix(".") else { return false }
                var entryIsDirectory: ObjCBool = false
                let entry = root.appendingPathComponent(id, isDirectory: true)
                return FileManager.default.fileExists(
                    atPath: entry.path, isDirectory: &entryIsDirectory)
                    && entryIsDirectory.boolValue
            })
    } catch {
        return .failure(
            .rootUnreadable(path: root.path, reason: error.localizedDescription))
    }
}

/// A fact and its fingerprint must describe one stable read interval. Reading facts first and
/// fingerprinting afterwards can bind old bytes to a newer inode when a manifest is atomically
/// replaced mid-scan, making every later incremental refresh reuse the stale fact.
private func readSoundPackFacts(
    id: String,
    environment: AudioImportEnvironment,
    factoryPackIDs: Set<String>,
    afterManifestRead: @Sendable (String) -> Void
) -> SoundPackFacts {
    for _ in 0..<3 {
        let declaredBefore = installedDeclaredFileNames(id: id, environment: environment)
        let factoryDeclaredBefore = factoryDeclaredFileNames(
            id: id, environment: environment, factoryPackIDs: factoryPackIDs)
        let before = currentFingerprint(
            id: id,
            environment: environment,
            factoryPackIDs: factoryPackIDs,
            declaredAudioFileNames: declaredBefore,
            factoryDeclaredAudioFileNames: factoryDeclaredBefore)
        let facts = readSoundPackFactsOnce(
            id: id,
            environment: environment,
            factoryPackIDs: factoryPackIDs,
            afterManifestRead: afterManifestRead)
        let after = currentFingerprint(
            id: id,
            environment: environment,
            factoryPackIDs: factoryPackIDs,
            declaredAudioFileNames: facts.declaredAudioFileNames,
            factoryDeclaredAudioFileNames: facts.factoryDeclaredAudioFileNames)
        guard before == after else { continue }
        return facts.replacingFingerprint(after)
    }

    let reason = "声音包在读取期间持续变化，请稍后重试"
    return SoundPackFacts(
        id: id,
        name: nil,
        isCC0: false,
        factoryIntegrity: nil,
        eventCoverage: [:],
        eventAudioDisplayNames: [:],
        cardState: .broken(reason: reason),
        audioInventory: .unavailable(.manifestUnreadable(reason: reason)),
        nativeTargets: nil,
        declaredAudioFileNames: [],
        factoryDeclaredAudioFileNames: [],
        fingerprint: nil)
}

private func readSoundPackFactsOnce(
    id: String,
    environment: AudioImportEnvironment,
    factoryPackIDs: Set<String>,
    afterManifestRead: @Sendable (String) -> Void
) -> SoundPackFacts {
    guard
        let packDirectory = resolvePackDirectory(
            id: id,
            userPacksDirectory: environment.userPacksDirectory,
            bundledPacksDirectory: environment.bundledPacksDirectory)
    else {
        return brokenSoundPackFacts(
            id: id,
            reason: "声音包目录未找到",
            inventoryError: .packNotFound(packID: id),
            environment: environment,
            factoryPackIDs: factoryPackIDs,
            packDirectory: nil)
    }

    let manifestData: Data
    switch loadPackManifestData(in: packDirectory) {
    case .success(let data): manifestData = data
    case .failure(let error):
        return brokenSoundPackFacts(
            id: id,
            reason: error.reason,
            inventoryError: .manifestUnreadable(reason: error.reason),
            environment: environment,
            factoryPackIDs: factoryPackIDs,
            packDirectory: packDirectory)
    }

    let manifest: PackManifest
    do {
        manifest = try JSONDecoder().decode(PackManifest.self, from: manifestData)
    } catch {
        let reason = PackManifestLoadError.decodeFailed(reason: error.localizedDescription).reason
        return brokenSoundPackFacts(
            id: id,
            reason: reason,
            inventoryError: .manifestUnreadable(reason: reason),
            environment: environment,
            factoryPackIDs: factoryPackIDs,
            packDirectory: packDirectory)
    }
    guard manifest.id == id else {
        let reason = SoundPackLibraryBrokenReasonToken.manifestIdentityMismatch.rawValue
        return brokenSoundPackFacts(
            id: id,
            reason: reason,
            inventoryError: .manifestUnreadable(reason: reason),
            environment: environment,
            factoryPackIDs: factoryPackIDs,
            packDirectory: packDirectory)
    }
    guard let declaredAudioFileNames = currentEventAudioFileNames(in: manifest) else {
        return brokenSoundPackFacts(
            id: id,
            reason: oversizedSoundPackManifestAudioPathReason,
            inventoryError: .manifestUnreadable(
                reason: oversizedSoundPackManifestAudioPathReason),
            environment: environment,
            factoryPackIDs: factoryPackIDs,
            packDirectory: packDirectory)
    }
    afterManifestRead(id)

    let coverageRows = packCoverage(
        manifest: manifest,
        packDirectory: packDirectory,
        config: ClaudioConfig(selectedPack: ""))
    let eventCoverage = Dictionary(
        uniqueKeysWithValues: coverageRows.map { ($0.event, $0.coverage) })
    let eventAudioDisplayNames = Dictionary(
        uniqueKeysWithValues: coverageRows.compactMap { row in
            row.audioDisplayName.map { (row.event, $0) }
        })
    let presentCount = eventCoverage.values.filter(\.previewEnabled).count
    let cardState: PackCardState =
        presentCount == Event.allCases.count
        ? .complete
        : .partial(present: presentCount, total: Event.allCases.count)
    let metadata = packMetadata(manifestData: manifestData)
    let factoryDeclaredAudioFileNames = factoryDeclaredFileNames(
        id: id, environment: environment, factoryPackIDs: factoryPackIDs)
    let eventAudioURLs = Dictionary(
        uniqueKeysWithValues: coverageRows.compactMap { row -> (Event, URL)? in
            guard case .present(let fileName) = row.coverage,
                let target = safePackFileURL(fileName, in: packDirectory)
            else { return nil }
            return (row.event, target)
        })
    return SoundPackFacts(
        id: id,
        name: metadata.name,
        isCC0: metadata.isCC0,
        factoryIntegrity: factoryIntegrity(
            packID: id,
            environment: environment,
            currentDirectory: packDirectory,
            currentManifestData: manifestData,
            builtinPackIDs: factoryPackIDs),
        eventCoverage: eventCoverage,
        eventAudioDisplayNames: eventAudioDisplayNames,
        cardState: cardState,
        audioInventory: .deferred,
        nativeTargets: SoundPackNativeTargets(
            directoryURL: packDirectory.standardizedFileURL,
            eventAudioURLs: eventAudioURLs),
        declaredAudioFileNames: declaredAudioFileNames,
        factoryDeclaredAudioFileNames: factoryDeclaredAudioFileNames,
        fingerprint: nil)
}

private func brokenSoundPackFacts(
    id: String,
    reason: String,
    inventoryError: PackAudioInventoryError,
    environment: AudioImportEnvironment,
    factoryPackIDs: Set<String>,
    packDirectory: URL?
) -> SoundPackFacts {
    let factoryNames = factoryDeclaredFileNames(
        id: id, environment: environment, factoryPackIDs: factoryPackIDs)
    return SoundPackFacts(
        id: id,
        name: nil,
        isCC0: false,
        factoryIntegrity: factoryIntegrity(
            packID: id,
            environment: environment,
            currentDirectory: packDirectory,
            currentManifestData: nil,
            builtinPackIDs: factoryPackIDs),
        eventCoverage: [:],
        eventAudioDisplayNames: [:],
        cardState: .broken(reason: reason),
        audioInventory: .unavailable(inventoryError),
        nativeTargets: packDirectory.map {
            SoundPackNativeTargets(
                directoryURL: $0.standardizedFileURL,
                eventAudioURLs: [:])
        },
        declaredAudioFileNames: [],
        factoryDeclaredAudioFileNames: factoryNames,
        fingerprint: nil)
}

private func installedDeclaredFileNames(
    id: String,
    environment: AudioImportEnvironment
) -> [String] {
    guard
        let directory = resolvePackDirectory(
            id: id,
            userPacksDirectory: environment.userPacksDirectory,
            bundledPacksDirectory: environment.bundledPacksDirectory),
        case .success(let manifest) = loadPackManifest(in: directory),
        manifest.id == id
    else { return [] }
    return currentEventAudioFileNames(in: manifest) ?? []
}

private func factoryDeclaredFileNames(
    id: String,
    environment: AudioImportEnvironment,
    factoryPackIDs: Set<String>
) -> [String] {
    guard
        factoryPackIDs.contains(id),
        let factoryRoot = environment.factoryPacksDirectory,
        case .success(let manifest) = loadPackManifest(
            in: factoryRoot.appendingPathComponent(id, isDirectory: true))
    else { return [] }
    return currentEventAudioFileNames(in: manifest) ?? []
}

private func currentFingerprint(
    id: String,
    environment: AudioImportEnvironment,
    factoryPackIDs: Set<String>,
    declaredAudioFileNames: [String],
    factoryDeclaredAudioFileNames: [String]
) -> SoundPackFingerprint {
    let packDirectory = resolvePackDirectory(
        id: id,
        userPacksDirectory: environment.userPacksDirectory,
        bundledPacksDirectory: environment.bundledPacksDirectory)
    let factoryDirectory =
        factoryPackIDs.contains(id)
        ? environment.factoryPacksDirectory?.appendingPathComponent(id, isDirectory: true)
        : nil
    return SoundPackFingerprint(
        directory: packDirectory.flatMap { fileMetadata(at: $0, followsSymlink: true) },
        manifest: packDirectory.flatMap {
            fileMetadata(at: $0.appendingPathComponent("manifest.json"), followsSymlink: true)
        },
        declaredAudio: namedFileMetadata(
            names: declaredAudioFileNames, directory: packDirectory),
        factoryDirectory: factoryDirectory.flatMap {
            fileMetadata(at: $0, followsSymlink: true)
        },
        factoryManifest: factoryDirectory.flatMap {
            fileMetadata(at: $0.appendingPathComponent("manifest.json"), followsSymlink: true)
        },
        factoryDeclaredAudio: namedFileMetadata(
            names: factoryDeclaredAudioFileNames, directory: factoryDirectory))
}

private func namedFileMetadata(
    names: [String],
    directory: URL?
) -> [SoundPackNamedFileMetadata] {
    names.sorted().map { fileName in
        let fileURL = directory.flatMap { safePackFileURL(fileName, in: $0) }
        return SoundPackNamedFileMetadata(
            fileName: fileName,
            metadata: fileURL.flatMap { fileMetadata(at: $0, followsSymlink: true) })
    }
}

private func fileMetadata(at url: URL, followsSymlink: Bool) -> SoundPackFileMetadata? {
    var status = stat()
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return fstatat(
            AT_FDCWD,
            path,
            &status,
            followsSymlink ? 0 : AT_SYMLINK_NOFOLLOW)
    }
    guard result == 0 else { return nil }
    return SoundPackFileMetadata(
        device: UInt64(status.st_dev),
        inode: UInt64(status.st_ino),
        mode: UInt32(status.st_mode),
        size: Int64(status.st_size),
        modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
        modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec),
        changedSeconds: Int64(status.st_ctimespec.tv_sec),
        changedNanoseconds: Int64(status.st_ctimespec.tv_nsec))
}
