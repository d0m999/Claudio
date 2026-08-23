#if DEBUG
import ClaudioCore
import CryptoKit
import Foundation

package enum ChatAXCPUArchitecture: String, Codable, Sendable {
    case arm64
    case intel64 = "x86_64"
}

package struct ChatAXCodeSignature: Codable, Equatable, Sendable {
    package let teamIdentifier: String
    package let signingIdentifier: String
    package let cdHash: String

    package init(teamIdentifier: String, signingIdentifier: String, cdHash: String) {
        self.teamIdentifier = teamIdentifier
        self.signingIdentifier = signingIdentifier
        self.cdHash = cdHash
    }
}

package struct ChatAXSignedBundleIdentity: Equatable, Sendable {
    package let bundleIdentifier: String
    package let codeSignature: ChatAXCodeSignature
    package let shortVersion: String
    package let build: String

    package init(
        bundleIdentifier: String,
        codeSignature: ChatAXCodeSignature,
        shortVersion: String,
        build: String
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.codeSignature = codeSignature
        self.shortVersion = shortVersion
        self.build = build
    }
}

package enum ChatAXCodeIdentityBinding {
    package static func bind(
        runningBefore: ChatAXSignedBundleIdentity?,
        diskBefore: ChatAXSignedBundleIdentity?,
        runningAfter: ChatAXSignedBundleIdentity?,
        diskAfter: ChatAXSignedBundleIdentity?
    ) -> ChatAXSignedBundleIdentity? {
        guard
            let runningBefore,
            let diskBefore,
            let runningAfter,
            let diskAfter,
            runningBefore == diskBefore,
            diskBefore == runningAfter,
            runningAfter == diskAfter
        else {
            return nil
        }
        return runningBefore
    }
}

package struct ChatAXRuntimeValidationGate: Sendable {
    package struct Request: Equatable, Sendable {
        fileprivate let generation: UInt64
        fileprivate let identifier: UInt64
    }

    private var generation: UInt64 = 0
    private var nextIdentifier: UInt64 = 0
    private var pendingRequest: Request?
    private var sessionIsActive = false

    package init() {}

    package mutating func beginSession() {
        generation &+= 1
        pendingRequest = nil
        sessionIsActive = true
    }

    package mutating func endSession() {
        generation &+= 1
        pendingRequest = nil
        sessionIsActive = false
    }

    package mutating func beginValidation() -> Request? {
        guard sessionIsActive, pendingRequest == nil else { return nil }
        nextIdentifier &+= 1
        let request = Request(
            generation: generation,
            identifier: nextIdentifier)
        pendingRequest = request
        return request
    }

    package mutating func finishValidation(_ request: Request) -> Bool {
        guard sessionIsActive, request.generation == generation, pendingRequest == request else {
            return false
        }
        pendingRequest = nil
        return true
    }
}

package final class ChatAXRuntimeValidationWinner: @unchecked Sendable {
    private let lock = NSLock()
    private var hasWinner = false

    package init() {}

    package func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasWinner else { return false }
        hasWinner = true
        return true
    }
}

package final class ChatAXSystemQueryWorkerGate: @unchecked Sendable {
    package struct Lease: Sendable {
        fileprivate let identifier: UInt64
    }

    package static let shared = ChatAXSystemQueryWorkerGate()

    private let lock = NSLock()
    private var nextIdentifier: UInt64 = 0
    private var activeLease: Lease?

    private init() {}

    package func acquire() -> Lease? {
        lock.lock()
        defer { lock.unlock() }
        guard activeLease == nil else { return nil }
        nextIdentifier &+= 1
        let lease = Lease(identifier: nextIdentifier)
        activeLease = lease
        return lease
    }

    package func release(_ lease: Lease) {
        lock.lock()
        if activeLease?.identifier == lease.identifier {
            activeLease = nil
        }
        lock.unlock()
    }
}

package final class ChatAXRuntimeValidationCancellationGate: @unchecked Sendable {
    private enum State {
        case awaitingLease
        case cancelledBeforeLease
        case pending(ChatAXSystemQueryWorkerGate.Lease)
        case running(ChatAXSystemQueryWorkerGate.Lease)
        case terminal
    }

    private let lock = NSLock()
    private let workerGate: ChatAXSystemQueryWorkerGate
    private var state: State = .awaitingLease

    package init(workerGate: ChatAXSystemQueryWorkerGate = .shared) {
        self.workerGate = workerGate
    }

    package func bind(_ lease: ChatAXSystemQueryWorkerGate.Lease) -> Bool {
        lock.lock()
        switch state {
        case .awaitingLease:
            state = .pending(lease)
            lock.unlock()
            return true
        case .cancelledBeforeLease:
            state = .terminal
            lock.unlock()
            workerGate.release(lease)
            return false
        case .pending, .running, .terminal:
            lock.unlock()
            return false
        }
    }

    package func cancel() {
        lock.lock()
        let leaseToRelease: ChatAXSystemQueryWorkerGate.Lease?
        switch state {
        case .awaitingLease:
            state = .cancelledBeforeLease
            leaseToRelease = nil
        case .pending(let lease):
            state = .terminal
            leaseToRelease = lease
        case .cancelledBeforeLease, .running, .terminal:
            leaseToRelease = nil
        }
        lock.unlock()
        if let leaseToRelease {
            workerGate.release(leaseToRelease)
        }
    }

    package func beginOperation() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .pending(let lease) = state else { return false }
        state = .running(lease)
        return true
    }

    package func finishOperation() {
        lock.lock()
        guard case .running(let lease) = state else {
            lock.unlock()
            return
        }
        state = .terminal
        lock.unlock()
        workerGate.release(lease)
    }
}

package enum ChatAXRuntimeValidationDeadlineOutcome<Value: Sendable>: Sendable {
    case completed(Value)
    case deferred
    case timedOut
    case cancelled
}

extension ChatAXRuntimeValidationDeadlineOutcome: Equatable where Value: Equatable {}

package struct ChatAXDeferredSystemQueryGate: Sendable {
    package struct Request: Equatable, Sendable {
        fileprivate let generation: UInt64
        fileprivate let identifier: UInt64
        fileprivate let deadlineMilliseconds: Int
    }

    package enum Decision: Equatable, Sendable {
        case stale
        case waiting
        case ready
        case expired
    }

    private var generation: UInt64 = 0
    private var nextIdentifier: UInt64 = 0
    private var sessionIsActive = false
    private var pendingRequest: Request?

    package init() {}

    package var hasPendingRequest: Bool { pendingRequest != nil }

    package mutating func beginSession() {
        generation &+= 1
        pendingRequest = nil
        sessionIsActive = true
    }

    package mutating func endSession() {
        generation &+= 1
        pendingRequest = nil
        sessionIsActive = false
    }

    package mutating func enqueue(
        nowMilliseconds: Int,
        timeoutMilliseconds: Int
    ) -> Request? {
        guard sessionIsActive, nowMilliseconds >= 0, timeoutMilliseconds >= 0 else { return nil }
        if let pendingRequest { return pendingRequest }
        let (candidateDeadline, overflowed) = nowMilliseconds.addingReportingOverflow(
            timeoutMilliseconds)
        nextIdentifier &+= 1
        let request = Request(
            generation: generation,
            identifier: nextIdentifier,
            deadlineMilliseconds: overflowed ? Int.max : candidateDeadline)
        pendingRequest = request
        return request
    }

    package mutating func decide(
        _ request: Request,
        nowMilliseconds: Int,
        workerLeaseAvailable: Bool
    ) -> Decision {
        guard
            sessionIsActive,
            request.generation == generation,
            pendingRequest == request
        else {
            return .stale
        }
        if nowMilliseconds >= request.deadlineMilliseconds {
            pendingRequest = nil
            return .expired
        }
        guard workerLeaseAvailable else { return .waiting }
        pendingRequest = nil
        return .ready
    }
}

package enum ChatAXRuntimeValidationDeadline {
    private static let workerGate = ChatAXSystemQueryWorkerGate.shared

    package static func run<Value: Sendable>(
        timeoutNanoseconds: UInt64,
        operation: @escaping @Sendable () async -> Value
    ) async -> ChatAXRuntimeValidationDeadlineOutcome<Value> {
        let cancellationGate = ChatAXRuntimeValidationCancellationGate()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return .cancelled }
            guard timeoutNanoseconds > 0 else { return .timedOut }
            guard let workerLease = workerGate.acquire() else {
                return Task.isCancelled ? .cancelled : .deferred
            }
            guard cancellationGate.bind(workerLease) else { return .cancelled }
            if Task.isCancelled {
                cancellationGate.cancel()
                return .cancelled
            }
            let winner = ChatAXRuntimeValidationWinner()
            let results = AsyncStream<ChatAXRuntimeValidationDeadlineOutcome<Value>>(
                bufferingPolicy: .bufferingOldest(1)
            ) { continuation in
                let operationTask = Task.detached {
                    guard cancellationGate.beginOperation() else { return }
                    defer { cancellationGate.finishOperation() }
                    guard !Task.isCancelled else { return }
                    let value = await operation()
                    guard !Task.isCancelled else { return }
                    let operationWon = winner.claim()
                    cancellationGate.finishOperation()
                    guard operationWon else { return }
                    continuation.yield(.completed(value))
                    continuation.finish()
                }
                let timeoutTask = Task.detached {
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return
                    }
                    guard winner.claim() else { return }
                    cancellationGate.cancel()
                    continuation.yield(.timedOut)
                    continuation.finish()
                }
                continuation.onTermination = { @Sendable _ in
                    cancellationGate.cancel()
                    operationTask.cancel()
                    timeoutTask.cancel()
                }
            }
            for await result in results {
                guard !Task.isCancelled else { return .cancelled }
                return result
            }
            return .cancelled
        } onCancel: {
            cancellationGate.cancel()
        }
    }
}

package struct ChatAXFrameworkIdentity: Codable, Equatable, Hashable, Sendable {
    package let name: String
    package let shortVersion: String
    package let build: String

    package init(name: String, shortVersion: String, build: String) {
        self.name = name
        self.shortVersion = shortVersion
        self.build = build
    }
}

/// 由封闭、非正文 AX 结构事实生成的 SHA-256。只保留摘要，不导出原始 identifier。
package struct ChatAXSurfaceSignature: Codable, Equatable, Hashable, RawRepresentable, Sendable {
    package let rawValue: String

    package init?(rawValue: String) {
        guard
            rawValue.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression) != nil
        else {
            return nil
        }
        self.rawValue = rawValue
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let signature = ChatAXSurfaceSignature(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Chat AX surface signature must be a lowercase SHA-256 digest")
        }
        self = signature
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// GUI system adapter 与同包测试共享的 typed seam；原始 facts 只在调用栈内存活。
package struct ChatAXSurfaceAnchorFacts: Equatable, Sendable {
    package static let maximumAnchorDepth = 8

    package let windowRole: String
    package let windowSubrole: String?
    package let anchorRole: String
    package let anchorSubrole: String?
    package let anchorIdentifier: String
    package let anchorDepth: Int

    package init?(
        windowRole: String,
        windowSubrole: String?,
        anchorRole: String,
        anchorSubrole: String?,
        anchorIdentifier: String,
        anchorDepth: Int
    ) {
        guard
            Self.isValid(windowRole, maximumUTF8Count: 128),
            Self.isValidOptional(windowSubrole, maximumUTF8Count: 128),
            Self.isValid(anchorRole, maximumUTF8Count: 128),
            Self.isValidOptional(anchorSubrole, maximumUTF8Count: 128),
            Self.isValid(anchorIdentifier, maximumUTF8Count: 256),
            (1...Self.maximumAnchorDepth).contains(anchorDepth)
        else {
            return nil
        }
        self.windowRole = windowRole
        self.windowSubrole = windowSubrole
        self.anchorRole = anchorRole
        self.anchorSubrole = anchorSubrole
        self.anchorIdentifier = anchorIdentifier
        self.anchorDepth = anchorDepth
    }

    fileprivate var canonicalRepresentation: String {
        [
            "claudio.chat-ax-surface.v1",
            "windowRole=\(Self.encode(windowRole))",
            "windowSubrole=\(Self.encode(windowSubrole))",
            "anchorRole=\(Self.encode(anchorRole))",
            "anchorSubrole=\(Self.encode(anchorSubrole))",
            "anchorIdentifier=\(Self.encode(anchorIdentifier))",
            "anchorDepth=i\(anchorDepth)",
        ].joined(separator: "\n")
    }

    private static func isValidOptional(_ value: String?, maximumUTF8Count: Int) -> Bool {
        guard let value else { return true }
        return isValid(value, maximumUTF8Count: maximumUTF8Count)
    }

    private static func isValid(_ value: String, maximumUTF8Count: Int) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumUTF8Count
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func encode(_ value: String?) -> String {
        guard let value else { return "n" }
        return "s\(value.utf8.count):\(value)"
    }
}

extension ChatAXSurfaceSignature {
    package static func v1(anchorFacts: ChatAXSurfaceAnchorFacts) -> ChatAXSurfaceSignature {
        let digest = SHA256.hash(data: Data(anchorFacts.canonicalRepresentation.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return ChatAXSurfaceSignature(rawValue: digest)!
    }
}

/// 只有 exact allowlist 验证器能创建；system adapter 不能自行把任意摘要标成 Chat。
package struct ChatAXVerifiedChatSurface: Equatable, Sendable {
    package let signature: ChatAXSurfaceSignature

    fileprivate init(signature: ChatAXSurfaceSignature) {
        self.signature = signature
    }
}

package enum ChatAXSurfaceVerifier {
    package static func verifyChat(
        anchorFacts: ChatAXSurfaceAnchorFacts,
        allowedSignatures: Set<ChatAXSurfaceSignature>
    ) -> ChatAXVerifiedChatSurface? {
        let observedSignature = ChatAXSurfaceSignature.v1(anchorFacts: anchorFacts)
        guard allowedSignatures.contains(observedSignature) else { return nil }
        return ChatAXVerifiedChatSurface(signature: observedSignature)
    }
}

/// Tracer 只接受调用方已经从非 AX 内容边界取得的版本身份；这里没有 UI tree 或正文槽位。
package struct ChatAXTargetIdentity: Codable, Equatable, Sendable {
    package let bundleIdentifier: String
    package let codeSignature: ChatAXCodeSignature
    package let shortVersion: String
    package let build: String
    package let frameworks: [ChatAXFrameworkIdentity]
    package let architecture: ChatAXCPUArchitecture
    package let surface: HostSurfaceID
    package let surfaceSignature: ChatAXSurfaceSignature

    package init(
        bundleIdentifier: String,
        codeSignature: ChatAXCodeSignature,
        shortVersion: String,
        build: String,
        frameworks: [ChatAXFrameworkIdentity],
        architecture: ChatAXCPUArchitecture,
        surface: HostSurfaceID,
        surfaceSignature: ChatAXSurfaceSignature
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.codeSignature = codeSignature
        self.shortVersion = shortVersion
        self.build = build
        self.frameworks = frameworks
        self.architecture = architecture
        self.surface = surface
        self.surfaceSignature = surfaceSignature
    }
}

extension ChatAXTargetIdentity {
    /// 系统 adapter 的唯一 Chat 构造入口；surface 与摘要都来自不可伪造的 verified wrapper。
    package static func observedChatGPTDesktopAX(
        bundleIdentifier: String,
        codeSignature: ChatAXCodeSignature,
        shortVersion: String,
        build: String,
        frameworks: [ChatAXFrameworkIdentity],
        architecture: ChatAXCPUArchitecture,
        verifiedSurface: ChatAXVerifiedChatSurface
    ) -> ChatAXTargetIdentity {
        ChatAXTargetIdentity(
            bundleIdentifier: bundleIdentifier,
            codeSignature: codeSignature,
            shortVersion: shortVersion,
            build: build,
            frameworks: frameworks,
            architecture: architecture,
            surface: .chatGPTDesktopAX,
            surfaceSignature: verifiedSurface.signature)
    }
}

package struct ChatAXInspectionRequirements: Equatable, Sendable {
    package let bundleIdentifiers: Set<String>
    package let frameworkNameSets: Set<Set<String>>
    package let surfaceSignatures: Set<ChatAXSurfaceSignature>

    package init(
        bundleIdentifiers: Set<String>,
        frameworkNameSets: Set<Set<String>>,
        surfaceSignatures: Set<ChatAXSurfaceSignature>
    ) {
        self.bundleIdentifiers = bundleIdentifiers
        self.frameworkNameSets = frameworkNameSets
        self.surfaceSignatures = surfaceSignatures
    }
}

package struct ChatAXObservedTarget: Equatable, Sendable {
    package let processIdentifier: Int32
    package let identity: ChatAXTargetIdentity

    package init(processIdentifier: Int32, identity: ChatAXTargetIdentity) {
        self.processIdentifier = processIdentifier
        self.identity = identity
    }
}

/// 同一运行 PID 的完整 framework projections。空 candidates 且无 unreadable projection
/// 表示身份事实可读但不匹配；不可读 projection 只有在没有 exact candidate 时才决定错误类别。
package struct ChatAXTargetInspection: Equatable, Sendable {
    package let candidates: [ChatAXObservedTarget]
    package let hasUnreadableProjection: Bool

    package init(
        candidates: [ChatAXObservedTarget],
        hasUnreadableProjection: Bool
    ) {
        self.candidates = candidates
        self.hasUnreadableProjection = hasUnreadableProjection
    }
}

package enum ChatAXFrameworkBundlePathState: Equatable, Sendable {
    case missing
    case directory
    case unreadable
}

/// Foundation may bridge a missing-path failure as a dynamic `NSError`, so classify it by
/// Cocoa domain/code instead of relying on a conditional `CocoaError` cast.
package func chatAXFrameworkBundlePathState(
    at url: URL
) -> ChatAXFrameworkBundlePathState {
    let resourceValues: URLResourceValues
    do {
        resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
    } catch {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
            error.code == CocoaError.Code.fileReadNoSuchFile.rawValue
        {
            return .missing
        }
        return .unreadable
    }
    return resourceValues.isDirectory == true ? .directory : .unreadable
}

package struct ChatAXVersionAllowlist: Sendable {
    private let identities: [ChatAXTargetIdentity]

    package init(identities: [ChatAXTargetIdentity]) {
        self.identities = identities
    }

    package var inspectionRequirements: ChatAXInspectionRequirements {
        let chatIdentities = identities.filter { $0.surface == .chatGPTDesktopAX }
        return ChatAXInspectionRequirements(
            bundleIdentifiers: Set(chatIdentities.map(\.bundleIdentifier)),
            frameworkNameSets: Set(
                chatIdentities.map { Set($0.frameworks.map(\.name)) }),
            surfaceSignatures: Set(chatIdentities.map(\.surfaceSignature)))
    }

    package func allows(_ candidate: ChatAXTargetIdentity) -> Bool {
        guard candidate.hasCompleteVersionIdentity else { return false }
        return identities.contains { allowed in
            let allowedFrameworks = allowed.frameworks.sorted(by: frameworkIdentityPrecedes)
            let candidateFrameworks = candidate.frameworks.sorted(by: frameworkIdentityPrecedes)
            return allowed.bundleIdentifier == candidate.bundleIdentifier
                && allowed.codeSignature == candidate.codeSignature
                && allowed.shortVersion == candidate.shortVersion
                && allowed.build == candidate.build
                && allowedFrameworks == candidateFrameworks
                && allowed.architecture == candidate.architecture
                && allowed.surface == .chatGPTDesktopAX
                && candidate.surface == .chatGPTDesktopAX
                && allowed.surfaceSignature == candidate.surfaceSignature
        }
    }
}

/// Debug tracer 的三项显式启动输入；普通 app、后台进程和测试 harness 都不会生成请求。
package struct ChatAXDebugLaunchRequest: Sendable {
    package let scenarioNumber: Int
    package let allowlist: ChatAXVersionAllowlist

    package init?(environment: [String: String]) {
        guard environment["CLAUDIO_CHAT_AX_TRACER_EXPLICIT_ENABLE"] == "1",
            let scenarioText = environment["CLAUDIO_CHAT_AX_TRACER_SCENARIO"],
            let scenarioNumber = Int(scenarioText), scenarioNumber >= 0,
            let allowlistJSON = environment["CLAUDIO_CHAT_AX_TRACER_ALLOWLIST_JSON"],
            let allowlistData = allowlistJSON.data(using: .utf8),
            let identities = try? JSONDecoder().decode(
                [ChatAXTargetIdentity].self, from: allowlistData),
            !identities.isEmpty
        else {
            return nil
        }
        self.scenarioNumber = scenarioNumber
        allowlist = ChatAXVersionAllowlist(identities: identities)
    }
}

private func frameworkIdentityPrecedes(
    _ lhs: ChatAXFrameworkIdentity,
    _ rhs: ChatAXFrameworkIdentity
) -> Bool {
    if lhs.name != rhs.name { return lhs.name < rhs.name }
    if lhs.shortVersion != rhs.shortVersion { return lhs.shortVersion < rhs.shortVersion }
    return lhs.build < rhs.build
}

extension ChatAXTargetIdentity {
    fileprivate var hasCompleteVersionIdentity: Bool {
        !bundleIdentifier.isEmpty
            && !codeSignature.teamIdentifier.isEmpty
            && !codeSignature.signingIdentifier.isEmpty
            && !codeSignature.cdHash.isEmpty
            && !shortVersion.isEmpty
            && !build.isEmpty
            && !frameworks.isEmpty
            && frameworks.allSatisfy {
                !$0.name.isEmpty && !$0.shortVersion.isEmpty && !$0.build.isEmpty
            }
    }
}

/// 读取正文才能确认类型的属性不会出现在这里；observer 只能接收这个封闭枚举。
package enum ChatAXApprovedAttribute: String, CaseIterable, Codable, Hashable, Sendable {
    case role = "AXRole"
    case subrole = "AXSubrole"
    case identifier = "AXIdentifier"
    case enabled = "AXEnabled"
    case selected = "AXSelected"
    case focused = "AXFocused"
    case windowNumber = "AXWindowNumber"
}

/// Surface 取样允许沿用的全部 AX 关系；不包含 children 或任意调用方字符串。
package enum ChatAXApprovedRelation: String, CaseIterable, Sendable {
    case focusedUIElement = "AXFocusedUIElement"
    case focusedWindow = "AXFocusedWindow"
    case parent = "AXParent"
}

/// 候选检测器的输入是封闭的结构/状态事实；类型上没有任意 AXValue 或文本字段。
package enum ChatAXStructuralSignalKind: Codable, Equatable, Sendable {
    case composerSubmitted
    case generationControl(isVisible: Bool)
    case assistantRegion(structureRevision: Int, isStable: Bool)
    case unrelatedStructureChanged
    case stabilityCheckpoint
    case windowClosed
    case applicationExited

    package var requiredAttributes: Set<ChatAXApprovedAttribute> {
        switch self {
        case .composerSubmitted, .generationControl:
            [.identifier, .enabled]
        case .assistantRegion:
            [.identifier]
        case .unrelatedStructureChanged:
            [.role, .identifier]
        case .stabilityCheckpoint:
            []
        case .windowClosed:
            [.windowNumber]
        case .applicationExited:
            []
        }
    }
}

package struct ChatAXDetectedSemanticEvent: Codable, Equatable, Sendable {
    package let signalSequence: Int
    package let windowOrdinal: Int
    package let event: Event

    package init(signalSequence: Int, windowOrdinal: Int, event: Event) {
        self.signalSequence = signalSequence
        self.windowOrdinal = windowOrdinal
        self.event = event
    }
}

package struct ChatAXCandidateDetectionOutcome: Equatable, Sendable {
    package let acceptedSignal: Bool
    package let semanticEvents: [ChatAXDetectedSemanticEvent]

    package init(acceptedSignal: Bool, semanticEvents: [ChatAXDetectedSemanticEvent]) {
        self.acceptedSignal = acceptedSignal
        self.semanticEvents = semanticEvents
    }
}

package struct ChatAXAssistantEpochState: Equatable, Sendable {
    package var isStable: Bool
    package var structureRevision: Int?
    package var completionCandidateAt: Int?

    package init(
        isStable: Bool = false,
        structureRevision: Int? = nil,
        completionCandidateAt: Int? = nil
    ) {
        self.isStable = isStable
        self.structureRevision = structureRevision
        self.completionCandidateAt = completionCandidateAt
    }

    package mutating func resetForNewSubmit() {
        self = ChatAXAssistantEpochState()
    }
}

private struct ChatAXWindowCandidateState: Sendable {
    enum Phase: Sendable {
        case idle
        case generating
    }

    var phase: Phase = .idle
    var submittedAt: Int?
    var generationControlIsVisible = false
    var assistantEpoch = ChatAXAssistantEpochState()
}

/// 从脱敏 fixture 与真实 observer 共用的结构信号中识别候选事件；不含计时器或文本猜测。
package struct ChatAXCandidateDetector: Sendable {
    package let submitAssociationMilliseconds: Int
    package let completionStabilityMilliseconds: Int

    private var lastSequence = 0
    private var lastElapsedMilliseconds = -1
    private var windows: [Int: ChatAXWindowCandidateState] = [:]

    package init(
        submitAssociationMilliseconds: Int = 1_000,
        completionStabilityMilliseconds: Int = 500
    ) {
        self.submitAssociationMilliseconds = max(0, submitAssociationMilliseconds)
        self.completionStabilityMilliseconds = max(0, completionStabilityMilliseconds)
    }

    package mutating func consume(
        _ signal: ChatAXStructuralSignal
    ) -> ChatAXCandidateDetectionOutcome {
        guard signal.sequence > lastSequence,
            signal.elapsedMilliseconds >= lastElapsedMilliseconds,
            signal.windowOrdinal >= 0
        else {
            return ChatAXCandidateDetectionOutcome(acceptedSignal: false, semanticEvents: [])
        }
        lastSequence = signal.sequence
        lastElapsedMilliseconds = signal.elapsedMilliseconds

        if case .applicationExited = signal.kind {
            windows.removeAll()
            return ChatAXCandidateDetectionOutcome(acceptedSignal: true, semanticEvents: [])
        }
        if case .windowClosed = signal.kind {
            windows.removeValue(forKey: signal.windowOrdinal)
            return ChatAXCandidateDetectionOutcome(acceptedSignal: true, semanticEvents: [])
        }

        var state = windows[signal.windowOrdinal] ?? ChatAXWindowCandidateState()
        var detected: [ChatAXDetectedSemanticEvent] = []
        switch signal.kind {
        case .composerSubmitted:
            if state.phase == .idle, state.submittedAt == nil {
                state.submittedAt = signal.elapsedMilliseconds
                state.assistantEpoch.resetForNewSubmit()
            }
        case .generationControl(let isVisible):
            state.generationControlIsVisible = isVisible
            if isVisible {
                state.assistantEpoch.completionCandidateAt = nil
                if state.phase == .idle, let submittedAt = state.submittedAt {
                    let elapsed = signal.elapsedMilliseconds - submittedAt
                    if elapsed >= 0, elapsed <= submitAssociationMilliseconds {
                        state.phase = .generating
                        state.submittedAt = nil
                        detected.append(
                            ChatAXDetectedSemanticEvent(
                                signalSequence: signal.sequence,
                                windowOrdinal: signal.windowOrdinal,
                                event: .taskStart))
                    } else {
                        state.submittedAt = nil
                    }
                }
            } else if state.phase == .generating, state.assistantEpoch.isStable,
                state.assistantEpoch.completionCandidateAt == nil
            {
                state.assistantEpoch.completionCandidateAt = signal.elapsedMilliseconds
            }
        case .assistantRegion(let structureRevision, let isStable):
            let structureChanged = state.assistantEpoch.structureRevision != structureRevision
            state.assistantEpoch.structureRevision = structureRevision
            state.assistantEpoch.isStable = isStable
            if !isStable {
                state.assistantEpoch.completionCandidateAt = nil
            } else if state.phase == .generating, !state.generationControlIsVisible,
                (state.assistantEpoch.completionCandidateAt == nil || structureChanged)
            {
                state.assistantEpoch.completionCandidateAt = signal.elapsedMilliseconds
            }
        case .unrelatedStructureChanged, .stabilityCheckpoint:
            break
        case .windowClosed, .applicationExited:
            break
        }

        let canConfirmCompletion: Bool
        if case .stabilityCheckpoint = signal.kind {
            canConfirmCompletion = true
        } else {
            canConfirmCompletion = false
        }
        if canConfirmCompletion,
            state.phase == .generating,
            !state.generationControlIsVisible,
            state.assistantEpoch.isStable,
            let completionCandidateAt = state.assistantEpoch.completionCandidateAt,
            signal.elapsedMilliseconds - completionCandidateAt >= completionStabilityMilliseconds
        {
            detected.append(
                ChatAXDetectedSemanticEvent(
                    signalSequence: signal.sequence,
                    windowOrdinal: signal.windowOrdinal,
                    event: .stop))
            windows.removeValue(forKey: signal.windowOrdinal)
        } else {
            windows[signal.windowOrdinal] = state
        }
        return ChatAXCandidateDetectionOutcome(acceptedSignal: true, semanticEvents: detected)
    }

    package func assistantEpochState(
        forWindowOrdinal windowOrdinal: Int
    ) -> ChatAXAssistantEpochState? {
        windows[windowOrdinal]?.assistantEpoch
    }
}

/// 真实 AX 或脱敏 fixture observer 的唯一边界；它只能发布已收窄的结构信号。
package enum ChatAXTargetInspectionFailure: Error, Equatable, Sendable {
    case targetUnavailable
    case ambiguousTargets
    case identityUnreadable
}

package enum ChatAXTargetRevalidationOutcome: Equatable, Sendable {
    case matches
    case mismatch
    case deferred
}

@MainActor
package protocol ChatAXTraceObserving: AnyObject {
    /// 成功值可包含同一 PID 的多个 framework projection；空且无 unreadable projection
    /// 表示 identity/surface 已可读但不匹配，base identity 读取失败才直接返回 failure。
    func inspectTarget(
        requirements: ChatAXInspectionRequirements
    ) -> Result<ChatAXTargetInspection, ChatAXTargetInspectionFailure>
    func targetStillMatches(_ target: ChatAXObservedTarget) -> ChatAXTargetRevalidationOutcome
    func start(
        target: ChatAXObservedTarget,
        approvedAttributes: Set<ChatAXApprovedAttribute>,
        receive: @escaping (ChatAXStructuralSignal) -> Void,
        targetDidInvalidate: @escaping () -> Void
    ) -> Bool
    func stop()
}

package enum ChatAXTracerStartFailure: Equatable, Sendable {
    case guiNotAlive
    case invalidScenario
    case targetInspectionFailed(ChatAXTargetInspectionFailure)
    case allowlistMismatch
    case alreadyRunning
    case observerStartFailed
}

package enum ChatAXTracerStartOutcome: Equatable, Sendable {
    case started
    case refused(ChatAXTracerStartFailure)
}

package struct ChatAXTraceCounts: Codable, Equatable, Sendable {
    package let signalCount: Int
    package let taskStartCount: Int
    package let stopCount: Int

    package init(signalCount: Int, taskStartCount: Int, stopCount: Int) {
        self.signalCount = signalCount
        self.taskStartCount = taskStartCount
        self.stopCount = stopCount
    }
}

/// 可导出的唯一 tracer 证据形状；不含正文、权限、声音、日志或 Current Activation。
package struct ChatAXTraceEvidence: Codable, Equatable, Sendable {
    package let targetIdentity: ChatAXTargetIdentity
    package let scenarioNumber: Int
    package let signals: [ChatAXStructuralSignal]
    package let semanticEvents: [ChatAXDetectedSemanticEvent]
    package let counts: ChatAXTraceCounts

    package init(
        targetIdentity: ChatAXTargetIdentity,
        scenarioNumber: Int,
        signals: [ChatAXStructuralSignal],
        semanticEvents: [ChatAXDetectedSemanticEvent],
        counts: ChatAXTraceCounts
    ) {
        self.targetIdentity = targetIdentity
        self.scenarioNumber = scenarioNumber
        self.signals = signals
        self.semanticEvents = semanticEvents
        self.counts = counts
    }
}

@MainActor
package final class ChatAXTraceAccumulator {
    private var signals: [ChatAXStructuralSignal] = []
    private var semanticEvents: [ChatAXDetectedSemanticEvent] = []
    private var taskStartCount = 0
    private var stopCount = 0

    package private(set) var materializedSnapshotCount = 0

    package init() {}

    package func reset() {
        signals = []
        semanticEvents = []
        taskStartCount = 0
        stopCount = 0
        materializedSnapshotCount = 0
    }

    package func append(
        _ signal: ChatAXStructuralSignal,
        semanticEvents newSemanticEvents: [ChatAXDetectedSemanticEvent]
    ) {
        signals.append(signal)
        semanticEvents.append(contentsOf: newSemanticEvents)
        for semanticEvent in newSemanticEvents {
            switch semanticEvent.event {
            case .taskStart:
                taskStartCount += 1
            case .stop:
                stopCount += 1
            default:
                break
            }
        }
    }

    package func snapshot(
        targetIdentity: ChatAXTargetIdentity,
        scenarioNumber: Int
    ) -> ChatAXTraceEvidence {
        materializedSnapshotCount += 1
        return ChatAXTraceEvidence(
            targetIdentity: targetIdentity,
            scenarioNumber: scenarioNumber,
            signals: signals,
            semanticEvents: semanticEvents,
            counts: ChatAXTraceCounts(
                signalCount: signals.count,
                taskStartCount: taskStartCount,
                stopCount: stopCount))
    }
}

/// 不接入 `HostIntegrationAdapter` 的 GUI-only spike session；构造与 GUI 启动均保持关闭。
@MainActor
package final class ChatAXTracerSession {
    package private(set) var isRunning = false
    package private(set) var isExplicitlyEnabled = false
    package var evidence: ChatAXTraceEvidence? {
        if let finalizedEvidence { return finalizedEvidence }
        guard let evidenceTargetIdentity, let evidenceScenarioNumber else { return nil }
        return accumulator.snapshot(
            targetIdentity: evidenceTargetIdentity,
            scenarioNumber: evidenceScenarioNumber)
    }
    package var evidenceMaterializationCount: Int {
        accumulator.materializedSnapshotCount
    }

    private let allowlist: ChatAXVersionAllowlist
    private let observer: any ChatAXTraceObserving
    private var guiIsAlive = false
    private var observedTarget: ChatAXObservedTarget?
    private var scenarioNumber: Int?
    private var evidenceTargetIdentity: ChatAXTargetIdentity?
    private var evidenceScenarioNumber: Int?
    private var finalizedEvidence: ChatAXTraceEvidence?
    private var detector = ChatAXCandidateDetector()
    private let accumulator = ChatAXTraceAccumulator()

    package init(
        allowlist: ChatAXVersionAllowlist,
        observer: any ChatAXTraceObserving
    ) {
        self.allowlist = allowlist
        self.observer = observer
    }

    package func guiDidBecomeAlive() {
        guiIsAlive = true
    }

    package func beginExplicitTrace(
        scenarioNumber: Int
    ) -> ChatAXTracerStartOutcome {
        guard guiIsAlive else { return .refused(.guiNotAlive) }
        guard !isRunning else { return .refused(.alreadyRunning) }
        guard scenarioNumber >= 0 else { return .refused(.invalidScenario) }

        let inspection: ChatAXTargetInspection
        switch observer.inspectTarget(requirements: allowlist.inspectionRequirements) {
        case .success(let result):
            inspection = result
        case .failure(let failure):
            return .refused(.targetInspectionFailed(failure))
        }
        guard
            let target = inspection.candidates.first(where: {
                allowlist.allows($0.identity)
            })
        else {
            if inspection.hasUnreadableProjection {
                return .refused(.targetInspectionFailed(.identityUnreadable))
            }
            return .refused(.allowlistMismatch)
        }

        isExplicitlyEnabled = true
        observedTarget = target
        self.scenarioNumber = scenarioNumber
        evidenceTargetIdentity = target.identity
        evidenceScenarioNumber = scenarioNumber
        finalizedEvidence = nil
        detector = ChatAXCandidateDetector()
        accumulator.reset()
        isRunning = true
        guard
            observer.start(
                target: target,
                approvedAttributes: Set(ChatAXApprovedAttribute.allCases),
                receive: { [weak self] signal in
                    self?.consume(signal)
                },
                targetDidInvalidate: { [weak self] in
                    self?.stopAndDisable()
                })
        else {
            observer.stop()
            isRunning = false
            isExplicitlyEnabled = false
            observedTarget = nil
            self.scenarioNumber = nil
            evidenceTargetIdentity = nil
            evidenceScenarioNumber = nil
            finalizedEvidence = nil
            accumulator.reset()
            return .refused(.observerStartFailed)
        }
        guard isRunning else {
            return .refused(.targetInspectionFailed(.targetUnavailable))
        }
        return .started
    }

    package func revalidateTarget() {
        guard isRunning else { return }
        guard let observedTarget, allowlist.allows(observedTarget.identity) else {
            stopAndDisable()
            return
        }
        if observer.targetStillMatches(observedTarget) == .mismatch {
            stopAndDisable()
        }
    }

    package func endExplicitTrace() {
        stopAndDisable()
    }

    package func guiWillTerminate() {
        guiIsAlive = false
        stopAndDisable()
    }

    private func consume(_ signal: ChatAXStructuralSignal) {
        guard isRunning else { return }
        let outcome = detector.consume(signal)
        guard outcome.acceptedSignal else { return }
        accumulator.append(signal, semanticEvents: outcome.semanticEvents)
        if case .applicationExited = signal.kind {
            stopAndDisable()
        }
    }

    private func stopAndDisable() {
        if isRunning {
            observer.stop()
            if let evidenceTargetIdentity, let evidenceScenarioNumber {
                finalizedEvidence = accumulator.snapshot(
                    targetIdentity: evidenceTargetIdentity,
                    scenarioNumber: evidenceScenarioNumber)
            }
        }
        isRunning = false
        isExplicitlyEnabled = false
        observedTarget = nil
        scenarioNumber = nil
        evidenceTargetIdentity = nil
        evidenceScenarioNumber = nil
        detector = ChatAXCandidateDetector()
    }
}

package struct ChatAXStructuralSignal: Codable, Equatable, Sendable {
    package let sequence: Int
    package let elapsedMilliseconds: Int
    package let windowOrdinal: Int
    package let kind: ChatAXStructuralSignalKind

    package init(
        sequence: Int,
        elapsedMilliseconds: Int,
        windowOrdinal: Int,
        kind: ChatAXStructuralSignalKind
    ) {
        self.sequence = sequence
        self.elapsedMilliseconds = elapsedMilliseconds
        self.windowOrdinal = windowOrdinal
        self.kind = kind
    }
}
#endif
