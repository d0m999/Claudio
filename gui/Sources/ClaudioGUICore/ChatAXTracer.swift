import ClaudioCore
import CryptoKit
import Foundation

public enum ChatAXCPUArchitecture: String, Codable, Sendable {
    case arm64
    case intel64 = "x86_64"
}

public struct ChatAXCodeSignature: Codable, Equatable, Sendable {
    public let teamIdentifier: String
    public let signingIdentifier: String
    public let cdHash: String

    public init(teamIdentifier: String, signingIdentifier: String, cdHash: String) {
        self.teamIdentifier = teamIdentifier
        self.signingIdentifier = signingIdentifier
        self.cdHash = cdHash
    }
}

public struct ChatAXFrameworkIdentity: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let shortVersion: String
    public let build: String

    public init(name: String, shortVersion: String, build: String) {
        self.name = name
        self.shortVersion = shortVersion
        self.build = build
    }
}

/// 由封闭、非正文 AX 结构事实生成的 SHA-256。只保留摘要，不导出原始 identifier。
public struct ChatAXSurfaceSignature: Codable, Equatable, Hashable, RawRepresentable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard
            rawValue.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression) != nil
        else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let signature = ChatAXSurfaceSignature(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Chat AX surface signature must be a lowercase SHA-256 digest")
        }
        self = signature
    }

    public func encode(to encoder: any Encoder) throws {
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
public struct ChatAXTargetIdentity: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let codeSignature: ChatAXCodeSignature
    public let shortVersion: String
    public let build: String
    public let frameworks: [ChatAXFrameworkIdentity]
    public let architecture: ChatAXCPUArchitecture
    public let surface: HostSurfaceID
    public let surfaceSignature: ChatAXSurfaceSignature

    public init(
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

public struct ChatAXInspectionRequirements: Equatable, Sendable {
    public let bundleIdentifiers: Set<String>
    public let frameworkNames: Set<String>
    public let surfaceSignatures: Set<ChatAXSurfaceSignature>

    public init(
        bundleIdentifiers: Set<String>,
        frameworkNames: Set<String>,
        surfaceSignatures: Set<ChatAXSurfaceSignature>
    ) {
        self.bundleIdentifiers = bundleIdentifiers
        self.frameworkNames = frameworkNames
        self.surfaceSignatures = surfaceSignatures
    }
}

public struct ChatAXObservedTarget: Equatable, Sendable {
    public let processIdentifier: Int32
    public let identity: ChatAXTargetIdentity

    public init(processIdentifier: Int32, identity: ChatAXTargetIdentity) {
        self.processIdentifier = processIdentifier
        self.identity = identity
    }
}

public struct ChatAXVersionAllowlist: Sendable {
    private let identities: [ChatAXTargetIdentity]

    public init(identities: [ChatAXTargetIdentity]) {
        self.identities = identities
    }

    public var inspectionRequirements: ChatAXInspectionRequirements {
        let chatIdentities = identities.filter { $0.surface == .chatGPTDesktopAX }
        return ChatAXInspectionRequirements(
            bundleIdentifiers: Set(chatIdentities.map(\.bundleIdentifier)),
            frameworkNames: Set(chatIdentities.flatMap(\.frameworks).map(\.name)),
            surfaceSignatures: Set(chatIdentities.map(\.surfaceSignature)))
    }

    public func allows(_ candidate: ChatAXTargetIdentity) -> Bool {
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
public struct ChatAXDebugLaunchRequest: Sendable {
    public let scenarioNumber: Int
    public let allowlist: ChatAXVersionAllowlist

    public init?(environment: [String: String]) {
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
public enum ChatAXApprovedAttribute: String, CaseIterable, Codable, Hashable, Sendable {
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
public enum ChatAXStructuralSignalKind: Codable, Equatable, Sendable {
    case composerSubmitted
    case generationControl(isVisible: Bool)
    case assistantRegion(structureRevision: Int, isStable: Bool)
    case unrelatedStructureChanged
    case stabilityCheckpoint
    case windowClosed
    case applicationExited

    public var requiredAttributes: Set<ChatAXApprovedAttribute> {
        switch self {
        case .composerSubmitted, .generationControl:
            [.identifier, .enabled]
        case .assistantRegion:
            [.identifier]
        case .unrelatedStructureChanged:
            [.role, .identifier]
        case .stabilityCheckpoint:
            []
        case .windowClosed, .applicationExited:
            [.windowNumber]
        }
    }
}

public struct ChatAXDetectedSemanticEvent: Codable, Equatable, Sendable {
    public let signalSequence: Int
    public let windowOrdinal: Int
    public let event: Event

    public init(signalSequence: Int, windowOrdinal: Int, event: Event) {
        self.signalSequence = signalSequence
        self.windowOrdinal = windowOrdinal
        self.event = event
    }
}

public struct ChatAXCandidateDetectionOutcome: Equatable, Sendable {
    public let acceptedSignal: Bool
    public let semanticEvents: [ChatAXDetectedSemanticEvent]

    public init(acceptedSignal: Bool, semanticEvents: [ChatAXDetectedSemanticEvent]) {
        self.acceptedSignal = acceptedSignal
        self.semanticEvents = semanticEvents
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
    var assistantRegionIsStable = false
    var assistantStructureRevision: Int?
    var completionCandidateAt: Int?
}

/// 从脱敏 fixture 与真实 observer 共用的结构信号中识别候选事件；不含计时器或文本猜测。
public struct ChatAXCandidateDetector: Sendable {
    public let submitAssociationMilliseconds: Int
    public let completionStabilityMilliseconds: Int

    private var lastSequence = 0
    private var lastElapsedMilliseconds = -1
    private var windows: [Int: ChatAXWindowCandidateState] = [:]

    public init(
        submitAssociationMilliseconds: Int = 1_000,
        completionStabilityMilliseconds: Int = 500
    ) {
        self.submitAssociationMilliseconds = max(0, submitAssociationMilliseconds)
        self.completionStabilityMilliseconds = max(0, completionStabilityMilliseconds)
    }

    public mutating func consume(
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
            }
        case .generationControl(let isVisible):
            state.generationControlIsVisible = isVisible
            if isVisible {
                state.completionCandidateAt = nil
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
            } else if state.phase == .generating, state.assistantRegionIsStable,
                state.completionCandidateAt == nil
            {
                state.completionCandidateAt = signal.elapsedMilliseconds
            }
        case .assistantRegion(let structureRevision, let isStable):
            let structureChanged = state.assistantStructureRevision != structureRevision
            state.assistantStructureRevision = structureRevision
            state.assistantRegionIsStable = isStable
            if !isStable {
                state.completionCandidateAt = nil
            } else if state.phase == .generating, !state.generationControlIsVisible,
                (state.completionCandidateAt == nil || structureChanged)
            {
                state.completionCandidateAt = signal.elapsedMilliseconds
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
            state.assistantRegionIsStable,
            let completionCandidateAt = state.completionCandidateAt,
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
}

/// 真实 AX 或脱敏 fixture observer 的唯一边界；它只能发布已收窄的结构信号。
public enum ChatAXTargetInspectionFailure: Error, Equatable, Sendable {
    case targetUnavailable
    case ambiguousTargets
    case identityUnreadable
}

@MainActor
public protocol ChatAXTraceObserving: AnyObject {
    func inspectTarget(
        requirements: ChatAXInspectionRequirements
    ) -> Result<ChatAXObservedTarget, ChatAXTargetInspectionFailure>
    func start(
        target: ChatAXObservedTarget,
        approvedAttributes: Set<ChatAXApprovedAttribute>,
        receive: @escaping (ChatAXStructuralSignal) -> Void,
        targetDidInvalidate: @escaping () -> Void
    ) -> Bool
    func stop()
}

public enum ChatAXTracerStartFailure: Equatable, Sendable {
    case guiNotAlive
    case invalidScenario
    case targetInspectionFailed(ChatAXTargetInspectionFailure)
    case allowlistMismatch
    case alreadyRunning
    case observerStartFailed
}

public enum ChatAXTracerStartOutcome: Equatable, Sendable {
    case started
    case refused(ChatAXTracerStartFailure)
}

public struct ChatAXTraceCounts: Codable, Equatable, Sendable {
    public let signalCount: Int
    public let taskStartCount: Int
    public let stopCount: Int

    public init(signalCount: Int, taskStartCount: Int, stopCount: Int) {
        self.signalCount = signalCount
        self.taskStartCount = taskStartCount
        self.stopCount = stopCount
    }
}

/// 可导出的唯一 tracer 证据形状；不含正文、权限、声音、日志或 Current Activation。
public struct ChatAXTraceEvidence: Codable, Equatable, Sendable {
    public let targetIdentity: ChatAXTargetIdentity
    public let scenarioNumber: Int
    public let signals: [ChatAXStructuralSignal]
    public let semanticEvents: [ChatAXDetectedSemanticEvent]
    public let counts: ChatAXTraceCounts

    public init(
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

/// 不接入 `HostIntegrationAdapter` 的 GUI-only spike session；构造与 GUI 启动均保持关闭。
@MainActor
public final class ChatAXTracerSession {
    public private(set) var isRunning = false
    public private(set) var isExplicitlyEnabled = false
    public private(set) var evidence: ChatAXTraceEvidence?

    private let allowlist: ChatAXVersionAllowlist
    private let observer: any ChatAXTraceObserving
    private var guiIsAlive = false
    private var observedTarget: ChatAXObservedTarget?
    private var scenarioNumber: Int?
    private var detector = ChatAXCandidateDetector()
    private var signals: [ChatAXStructuralSignal] = []
    private var semanticEvents: [ChatAXDetectedSemanticEvent] = []

    public init(
        allowlist: ChatAXVersionAllowlist,
        observer: any ChatAXTraceObserving
    ) {
        self.allowlist = allowlist
        self.observer = observer
    }

    public func guiDidBecomeAlive() {
        guiIsAlive = true
    }

    public func beginExplicitTrace(
        scenarioNumber: Int
    ) -> ChatAXTracerStartOutcome {
        guard guiIsAlive else { return .refused(.guiNotAlive) }
        guard !isRunning else { return .refused(.alreadyRunning) }
        guard scenarioNumber >= 0 else { return .refused(.invalidScenario) }

        let target: ChatAXObservedTarget
        switch observer.inspectTarget(requirements: allowlist.inspectionRequirements) {
        case .success(let inspectedTarget):
            target = inspectedTarget
        case .failure(let failure):
            return .refused(.targetInspectionFailed(failure))
        }
        guard allowlist.allows(target.identity) else {
            return .refused(.allowlistMismatch)
        }

        isExplicitlyEnabled = true
        observedTarget = target
        self.scenarioNumber = scenarioNumber
        detector = ChatAXCandidateDetector()
        signals = []
        semanticEvents = []
        isRunning = true
        refreshEvidence()
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
            evidence = nil
            return .refused(.observerStartFailed)
        }
        guard isRunning else {
            return .refused(.targetInspectionFailed(.targetUnavailable))
        }
        return .started
    }

    public func revalidateTarget() {
        guard isRunning else { return }
        guard
            case .success(let target) = observer.inspectTarget(
                requirements: allowlist.inspectionRequirements),
            target == observedTarget,
            allowlist.allows(target.identity)
        else {
            stopAndDisable()
            return
        }
    }

    public func endExplicitTrace() {
        stopAndDisable()
    }

    public func guiWillTerminate() {
        guiIsAlive = false
        stopAndDisable()
    }

    private func consume(_ signal: ChatAXStructuralSignal) {
        guard isRunning else { return }
        let outcome = detector.consume(signal)
        guard outcome.acceptedSignal else { return }
        signals.append(signal)
        semanticEvents.append(contentsOf: outcome.semanticEvents)
        refreshEvidence()
        if case .applicationExited = signal.kind {
            stopAndDisable()
        }
    }

    private func refreshEvidence() {
        guard let observedTarget, let scenarioNumber else { return }
        evidence = ChatAXTraceEvidence(
            targetIdentity: observedTarget.identity,
            scenarioNumber: scenarioNumber,
            signals: signals,
            semanticEvents: semanticEvents,
            counts: ChatAXTraceCounts(
                signalCount: signals.count,
                taskStartCount: semanticEvents.count(where: { $0.event == .taskStart }),
                stopCount: semanticEvents.count(where: { $0.event == .stop })))
    }

    private func stopAndDisable() {
        if isRunning {
            observer.stop()
        }
        isRunning = false
        isExplicitlyEnabled = false
        observedTarget = nil
        scenarioNumber = nil
        detector = ChatAXCandidateDetector()
    }
}

public struct ChatAXStructuralSignal: Codable, Equatable, Sendable {
    public let sequence: Int
    public let elapsedMilliseconds: Int
    public let windowOrdinal: Int
    public let kind: ChatAXStructuralSignalKind

    public init(
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
