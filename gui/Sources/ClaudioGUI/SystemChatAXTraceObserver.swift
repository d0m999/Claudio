#if DEBUG
import AppKit
@preconcurrency import ApplicationServices
import ClaudioCore
import ClaudioGUICore
import Darwin
import Foundation
import Security

private enum ChatAXAttributeReadFailure: Error {
    case unreadable
}

private struct SystemChatAXSigningFacts: Equatable, Sendable {
    let signedBundleIdentity: ChatAXSignedBundleIdentity
    let mainExecutablePath: String
}

private struct SystemChatAXCodeSnapshot: Equatable, Sendable {
    let runningFacts: SystemChatAXSigningFacts
    let diskFacts: SystemChatAXSigningFacts
    let bundlePath: String
    let processIncarnation: SystemChatAXProcessIncarnation
}

private struct SystemChatAXProcessIncarnation: Equatable, Sendable {
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

private struct SystemChatAXRuntimeFacts: Equatable, Sendable {
    let signingFacts: SystemChatAXSigningFacts
    let processIncarnation: SystemChatAXProcessIncarnation
}

private struct SystemChatAXRuntimeBinding: Equatable, Sendable {
    let processIdentifier: pid_t
    let runtimeFacts: SystemChatAXRuntimeFacts
    let bundlePath: String
    let architecture: ChatAXCPUArchitecture
}

private enum SystemChatAXCodeIdentityReader {
    static func coherentSnapshot(
        processIdentifier: pid_t,
        bundleURL: URL
    ) -> SystemChatAXCodeSnapshot? {
        guard
            !Task.isCancelled,
            let incarnationBefore = currentProcessIncarnation(
                processIdentifier: processIdentifier),
            let dynamicCode = dynamicCode(processIdentifier: processIdentifier),
            let runningFacts = signingFacts(forDynamicCode: dynamicCode),
            !Task.isCancelled
        else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard
            SecCodeCopyStaticCode(dynamicCode, SecCSFlags(), &staticCode) == errSecSuccess,
            !Task.isCancelled,
            let staticCode,
            SecStaticCodeCheckValidity(
                staticCode,
                SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode),
                nil) == errSecSuccess,
            !Task.isCancelled,
            let diskFacts = signingFacts(forStaticCode: staticCode),
            !Task.isCancelled
        else {
            return nil
        }

        var rawBundleURL: CFURL?
        guard
            SecCodeCopyPath(staticCode, SecCSFlags(), &rawBundleURL) == errSecSuccess,
            let rawBundleURL,
            !Task.isCancelled
        else {
            return nil
        }
        let observedBundlePath = normalizedPath(rawBundleURL as URL)
        guard
            observedBundlePath == normalizedPath(bundleURL),
            runningFacts.mainExecutablePath == diskFacts.mainExecutablePath,
            let incarnationAfter = currentProcessIncarnation(
                processIdentifier: processIdentifier),
            incarnationAfter == incarnationBefore
        else {
            return nil
        }
        return SystemChatAXCodeSnapshot(
            runningFacts: runningFacts,
            diskFacts: diskFacts,
            bundlePath: observedBundlePath,
            processIncarnation: incarnationBefore)
    }

    static func runningRuntimeFacts(
        processIdentifier: pid_t
    ) -> SystemChatAXRuntimeFacts? {
        guard
            !Task.isCancelled,
            let incarnationBefore = currentProcessIncarnation(
                processIdentifier: processIdentifier),
            !Task.isCancelled,
            let dynamicCode = dynamicCode(processIdentifier: processIdentifier),
            !Task.isCancelled,
            let signingFacts = signingFacts(forDynamicCode: dynamicCode),
            !Task.isCancelled,
            let incarnationAfter = currentProcessIncarnation(
                processIdentifier: processIdentifier),
            incarnationAfter == incarnationBefore,
            !Task.isCancelled
        else {
            return nil
        }
        return SystemChatAXRuntimeFacts(
            signingFacts: signingFacts,
            processIncarnation: incarnationBefore)
    }

    static func diskSignedBundleIdentity(
        at bundleURL: URL
    ) -> ChatAXSignedBundleIdentity? {
        var staticCode: SecStaticCode?
        guard
            !Task.isCancelled,
            SecStaticCodeCreateWithPath(
                bundleURL as CFURL,
                SecCSFlags(),
                &staticCode) == errSecSuccess,
            !Task.isCancelled,
            let staticCode,
            SecStaticCodeCheckValidity(
                staticCode,
                SecCSFlags(rawValue: kSecCSStrictValidate),
                nil) == errSecSuccess,
            !Task.isCancelled,
            let facts = signingFacts(forStaticCode: staticCode),
            !Task.isCancelled
        else {
            return nil
        }
        return facts.signedBundleIdentity
    }

    private static func dynamicCode(
        processIdentifier: pid_t
    ) -> SecCode? {
        guard !Task.isCancelled else { return nil }
        let attributes =
            [
                kSecGuestAttributePid as String: NSNumber(value: processIdentifier)
            ] as CFDictionary
        var code: SecCode?
        guard
            SecCodeCopyGuestWithAttributes(
                nil,
                attributes,
                SecCSFlags(),
                &code) == errSecSuccess,
            !Task.isCancelled,
            let code,
            CFGetTypeID(code) == SecCodeGetTypeID(),
            SecCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess,
            !Task.isCancelled
        else {
            return nil
        }
        return code
    }

    static func currentProcessIncarnation(
        processIdentifier: pid_t
    ) -> SystemChatAXProcessIncarnation? {
        guard processIdentifier > 0, !Task.isCancelled else { return nil }
        var information = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard
            proc_pidinfo(
                processIdentifier,
                PROC_PIDTBSDINFO,
                0,
                &information,
                expectedSize) == expectedSize,
            !Task.isCancelled,
            information.pbi_pid == UInt32(processIdentifier),
            information.pbi_start_tvsec > 0,
            information.pbi_start_tvusec < 1_000_000
        else {
            return nil
        }
        return SystemChatAXProcessIncarnation(
            startSeconds: information.pbi_start_tvsec,
            startMicroseconds: information.pbi_start_tvusec)
    }

    private static func signingFacts(
        forDynamicCode code: SecCode
    ) -> SystemChatAXSigningFacts? {
        // The C API explicitly accepts SecCodeRef here, but Swift imports its parameter as
        // SecStaticCode. The runtime type check above makes this documented bridge explicit.
        let importedCode = unsafeBitCast(code, to: SecStaticCode.self)
        return signingFacts(
            forImportedCode: importedCode,
            flags: SecCSFlags(
                rawValue: kSecCSSigningInformation | kSecCSDynamicInformation))
    }

    private static func signingFacts(
        forStaticCode code: SecStaticCode
    ) -> SystemChatAXSigningFacts? {
        signingFacts(
            forImportedCode: code,
            flags: SecCSFlags(rawValue: kSecCSSigningInformation))
    }

    private static func signingFacts(
        forImportedCode code: SecStaticCode,
        flags: SecCSFlags
    ) -> SystemChatAXSigningFacts? {
        var rawInformation: CFDictionary?
        guard
            !Task.isCancelled,
            SecCodeCopySigningInformation(code, flags, &rawInformation) == errSecSuccess,
            !Task.isCancelled,
            let information = rawInformation as? [CFString: Any],
            let teamIdentifier = information[kSecCodeInfoTeamIdentifier] as? String,
            let signingIdentifier = information[kSecCodeInfoIdentifier] as? String,
            let cdHash = information[kSecCodeInfoUnique] as? Data,
            let mainExecutable = information[kSecCodeInfoMainExecutable] as? URL,
            let securedPList = information[kSecCodeInfoPList] as? [String: Any],
            let bundleIdentifier = securedPList["CFBundleIdentifier"] as? String,
            let shortVersion = securedPList["CFBundleShortVersionString"] as? String,
            let build = securedPList["CFBundleVersion"] as? String
        else {
            return nil
        }
        return SystemChatAXSigningFacts(
            signedBundleIdentity: ChatAXSignedBundleIdentity(
                bundleIdentifier: bundleIdentifier,
                codeSignature: ChatAXCodeSignature(
                    teamIdentifier: teamIdentifier,
                    signingIdentifier: signingIdentifier,
                    cdHash: cdHash.map { String(format: "%02x", $0) }.joined()),
                shortVersion: shortVersion,
                build: build),
            mainExecutablePath: normalizedPath(mainExecutable))
    }

    static func normalizedPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

private final class SystemChatAXReadBudget {
    private static let totalSeconds: TimeInterval = 0.25
    private static let maximumQuerySeconds: Float = 0.05
    private static let minimumQuerySeconds: TimeInterval = 0.001

    private let deadline: TimeInterval

    init(startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        deadline = startedAt + Self.totalSeconds
    }

    var hasRemainingTime: Bool {
        !Task.isCancelled
            && deadline - ProcessInfo.processInfo.systemUptime >= Self.minimumQuerySeconds
    }

    func prepareForMessaging(_ element: AXUIElement) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard !Task.isCancelled, remaining >= Self.minimumQuerySeconds else { return false }
        guard
            AXUIElementSetMessagingTimeout(
                element,
                min(Self.maximumQuerySeconds, Float(remaining))) == .success,
            !Task.isCancelled
        else {
            return false
        }
        return true
    }
}

private struct SystemChatAXAttributeReader {
    let approvedAttributes: Set<ChatAXApprovedAttribute>
    private let budget: SystemChatAXReadBudget

    init(
        approvedAttributes: Set<ChatAXApprovedAttribute>,
        budget: SystemChatAXReadBudget = SystemChatAXReadBudget()
    ) {
        self.approvedAttributes = approvedAttributes
        self.budget = budget
    }

    func prepareForMessaging(_ element: AXUIElement) -> Bool {
        budget.prepareForMessaging(element)
    }

    var hasRemainingTime: Bool { budget.hasRemainingTime }

    func element(
        _ relation: ChatAXApprovedRelation,
        from element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard
            prepareForMessaging(element),
            AXUIElementCopyAttributeValue(
                element,
                (relation as ChatAXApprovedRelation).rawValue as CFString,
                &value) == .success,
            !Task.isCancelled,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    func string(
        _ attribute: ChatAXApprovedAttribute,
        from element: AXUIElement,
        maximumUTF8Count: Int
    ) -> Result<String?, ChatAXAttributeReadFailure> {
        guard approvedAttributes.contains(attribute), prepareForMessaging(element) else {
            return .failure(.unreadable)
        }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            (attribute as ChatAXApprovedAttribute).rawValue as CFString,
            &value)
        guard !Task.isCancelled else { return .failure(.unreadable) }
        if result == .attributeUnsupported || result == .noValue {
            return .success(nil)
        }
        guard result == .success, let string = value as? String else {
            return .failure(.unreadable)
        }
        guard
            !string.isEmpty,
            string.utf8.count <= maximumUTF8Count,
            string == string.trimmingCharacters(in: .whitespacesAndNewlines),
            !string.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            return .failure(.unreadable)
        }
        return .success(string)
    }

    func integer(
        _ attribute: ChatAXApprovedAttribute,
        from element: AXUIElement
    ) -> Result<Int?, ChatAXAttributeReadFailure> {
        guard approvedAttributes.contains(attribute), prepareForMessaging(element) else {
            return .failure(.unreadable)
        }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            (attribute as ChatAXApprovedAttribute).rawValue as CFString,
            &value)
        guard !Task.isCancelled else { return .failure(.unreadable) }
        if result == .attributeUnsupported || result == .noValue {
            return .success(nil)
        }
        guard
            result == .success,
            let value,
            let ordinal = ChatAXWindowOrdinalDecoder.decode(value)
        else {
            return .failure(.unreadable)
        }
        return .success(ordinal)
    }
}

private struct SystemChatAXSurfaceLineageSnapshot {
    let elements: [AXUIElement]
    let anchorFacts: ChatAXSurfaceAnchorFacts

    var window: AXUIElement { elements[elements.count - 1] }
}

/// 把一次 query 中 `CFEqual` 的 AX object 映射为 Core 可验证、但不可持久化的 opaque token。
private final class SystemChatAXElementIdentityMap {
    private let sampleID = UUID()
    private var representatives: [AXUIElement] = []

    func identities(
        for elements: [AXUIElement]
    ) -> [ChatAXLineageNodeIdentity] {
        elements.map(identity(for:))
    }

    private func identity(
        for element: AXUIElement
    ) -> ChatAXLineageNodeIdentity {
        if let ordinal = representatives.firstIndex(where: { CFEqual($0, element) }) {
            return ChatAXLineageNodeIdentity(sampleID: sampleID, ordinal: ordinal)
        }
        let ordinal = representatives.count
        representatives.append(element)
        return ChatAXLineageNodeIdentity(sampleID: sampleID, ordinal: ordinal)
    }
}

/// 只沿 element → window 的 parent 链寻找最靠近窗口的已标识 anchor；绝不请求 children 或正文属性。
private struct SystemChatAXSurfaceSignatureReader {
    private static let approvedAttributes: Set<ChatAXApprovedAttribute> = [
        .identifier, .role, .subrole, .windowNumber,
    ]

    private let reader: SystemChatAXAttributeReader

    init(
        budget: SystemChatAXReadBudget = SystemChatAXReadBudget(),
        approvedAttributes: Set<ChatAXApprovedAttribute> = Self.approvedAttributes
    ) {
        reader = SystemChatAXAttributeReader(
            approvedAttributes: approvedAttributes.intersection(Self.approvedAttributes),
            budget: budget)
    }

    func readAnchorFacts(
        applicationElement: AXUIElement,
        expectedProcessIdentifier: pid_t
    ) -> ChatAXSurfaceAnchorFacts? {
        guard
            let before = focusedLineageSnapshot(
                applicationElement: applicationElement,
                expectedProcessIdentifier: expectedProcessIdentifier),
            let after = focusedLineageSnapshot(
                applicationElement: applicationElement,
                expectedProcessIdentifier: expectedProcessIdentifier),
            lineagesAreEqual(before.elements, after.elements),
            before.anchorFacts == after.anchorFacts,
            reader.hasRemainingTime
        else {
            return nil
        }
        return before.anchorFacts
    }

    func readVerifiedEventBinding(
        applicationElement: AXUIElement,
        eventElement: AXUIElement,
        expectedProcessIdentifier: pid_t,
        allowedSignatures: Set<ChatAXSurfaceSignature>
    ) -> ChatAXVerifiedEventSurfaceBinding? {
        guard
            let focusedBefore = focusedLineageSnapshot(
                applicationElement: applicationElement,
                expectedProcessIdentifier: expectedProcessIdentifier),
            let eventBefore = lineage(
                from: eventElement,
                through: focusedBefore.window,
                expectedProcessIdentifier: expectedProcessIdentifier),
            case .success(let rawWindowOrdinal) = reader.integer(
                .windowNumber,
                from: focusedBefore.window),
            let eventAfter = lineage(
                from: eventElement,
                through: focusedBefore.window,
                expectedProcessIdentifier: expectedProcessIdentifier),
            let focusedAfter = focusedLineageSnapshot(
                applicationElement: applicationElement,
                expectedProcessIdentifier: expectedProcessIdentifier),
            reader.hasRemainingTime
        else {
            return nil
        }
        let identityMap = SystemChatAXElementIdentityMap()
        return ChatAXEventSurfaceBindingVerifier.verify(
            ChatAXEventSurfaceBindingSample(
                focusedBefore: ChatAXSurfaceLineageSample(
                    nodes: identityMap.identities(for: focusedBefore.elements),
                    anchorFacts: focusedBefore.anchorFacts),
                focusedAfter: ChatAXSurfaceLineageSample(
                    nodes: identityMap.identities(for: focusedAfter.elements),
                    anchorFacts: focusedAfter.anchorFacts),
                eventBefore: identityMap.identities(for: eventBefore),
                eventAfter: identityMap.identities(for: eventAfter),
                windowOrdinal: rawWindowOrdinal ?? 0),
            allowedSignatures: allowedSignatures)
    }

    private func focusedLineageSnapshot(
        applicationElement: AXUIElement,
        expectedProcessIdentifier: pid_t
    ) -> SystemChatAXSurfaceLineageSnapshot? {
        guard
            belongsToTarget(applicationElement, expectedProcessIdentifier),
            let focusedWindow = reader.element(.focusedWindow, from: applicationElement),
            let focusedElement = reader.element(.focusedUIElement, from: applicationElement),
            let elements = lineage(
                from: focusedElement,
                through: focusedWindow,
                expectedProcessIdentifier: expectedProcessIdentifier),
            let facts = anchorFacts(in: elements)
        else {
            return nil
        }
        return SystemChatAXSurfaceLineageSnapshot(
            elements: elements,
            anchorFacts: facts)
    }

    private func lineage(
        from focusedElement: AXUIElement,
        through focusedWindow: AXUIElement,
        expectedProcessIdentifier: pid_t
    ) -> [AXUIElement]? {
        guard
            belongsToTarget(focusedElement, expectedProcessIdentifier),
            belongsToTarget(focusedWindow, expectedProcessIdentifier)
        else {
            return nil
        }
        var lineage = [focusedElement]
        var current = focusedElement
        if CFEqual(current, focusedWindow) { return lineage }

        for _ in 0..<ChatAXSurfaceAnchorFacts.maximumAnchorDepth {
            guard
                let parent = reader.element(.parent, from: current),
                belongsToTarget(parent, expectedProcessIdentifier),
                !lineage.contains(where: { CFEqual($0, parent) })
            else {
                return nil
            }
            lineage.append(parent)
            if CFEqual(parent, focusedWindow) { return lineage }
            current = parent
        }
        return nil
    }

    private func lineagesAreEqual(_ lhs: [AXUIElement], _ rhs: [AXUIElement]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy(CFEqual)
    }

    private func anchorFacts(in focusedToWindowLineage: [AXUIElement])
        -> ChatAXSurfaceAnchorFacts?
    {
        let windowToFocused = focusedToWindowLineage.reversed()
        guard let window = windowToFocused.first else { return nil }
        guard
            case .success(let windowRole?) = reader.string(
                .role, from: window, maximumUTF8Count: 128),
            case .success(let windowSubrole) = reader.string(
                .subrole, from: window, maximumUTF8Count: 128)
        else {
            return nil
        }

        for (depth, element) in windowToFocused.dropFirst().enumerated() {
            guard
                case .success(let role?) = reader.string(
                    .role, from: element, maximumUTF8Count: 128),
                case .success(let subrole) = reader.string(
                    .subrole, from: element, maximumUTF8Count: 128),
                case .success(let identifier) = reader.string(
                    .identifier, from: element, maximumUTF8Count: 256)
            else {
                return nil
            }
            guard let identifier else { continue }
            return ChatAXSurfaceAnchorFacts(
                windowRole: windowRole,
                windowSubrole: windowSubrole,
                anchorRole: role,
                anchorSubrole: subrole,
                anchorIdentifier: identifier,
                anchorDepth: depth + 1)
        }
        return nil
    }

    private func belongsToTarget(
        _ element: AXUIElement,
        _ expectedProcessIdentifier: pid_t
    ) -> Bool {
        guard reader.prepareForMessaging(element) else { return false }
        var observedProcessIdentifier: pid_t = 0
        return AXUIElementGetPid(element, &observedProcessIdentifier) == .success
            && !Task.isCancelled
            && observedProcessIdentifier == expectedProcessIdentifier
    }
}

private struct SystemChatAXRuntimeSample: Equatable, Sendable {
    let runtimeFacts: SystemChatAXRuntimeFacts
    let surfaceSignature: ChatAXSurfaceSignature
}

private struct SystemChatAXEventQueryRequest: @unchecked Sendable {
    let element: AXUIElement
    let applicationElement: AXUIElement
    let target: ChatAXObservedTarget
    let runtimeBinding: SystemChatAXRuntimeBinding
    let approvedAttributes: Set<ChatAXApprovedAttribute>
}

private struct SystemChatAXEventQuerySample: Equatable, Sendable {
    let processIdentifier: pid_t
    let runtimeFacts: SystemChatAXRuntimeFacts
    let surfaceSignature: ChatAXSurfaceSignature
    let windowOrdinal: Int
}

private enum SystemChatAXRuntimeApplicationVerifier {
    static func matches(
        target: ChatAXObservedTarget,
        binding: SystemChatAXRuntimeBinding
    ) -> Bool {
        guard
            !Task.isCancelled,
            target.processIdentifier == binding.processIdentifier,
            target.identity.bundleIdentifier
                == binding.runtimeFacts.signingFacts.signedBundleIdentity.bundleIdentifier,
            target.identity.codeSignature
                == binding.runtimeFacts.signingFacts.signedBundleIdentity.codeSignature,
            target.identity.shortVersion
                == binding.runtimeFacts.signingFacts.signedBundleIdentity.shortVersion,
            target.identity.build
                == binding.runtimeFacts.signingFacts.signedBundleIdentity.build,
            target.identity.architecture == binding.architecture,
            let application = NSRunningApplication(
                processIdentifier: binding.processIdentifier),
            !application.isTerminated,
            !Task.isCancelled,
            application.bundleIdentifier == target.identity.bundleIdentifier,
            architecture(for: application) == binding.architecture,
            let bundleURL = application.bundleURL,
            SystemChatAXCodeIdentityReader.normalizedPath(bundleURL) == binding.bundlePath,
            !Task.isCancelled,
            SystemChatAXCodeIdentityReader.currentProcessIncarnation(
                processIdentifier: binding.processIdentifier)
                == binding.runtimeFacts.processIncarnation
        else {
            return false
        }
        return true
    }

    static func architecture(
        for application: NSRunningApplication
    ) -> ChatAXCPUArchitecture? {
        switch application.executableArchitecture {
        case NSBundleExecutableArchitectureARM64:
            .arm64
        case NSBundleExecutableArchitectureX86_64:
            .intel64
        default:
            nil
        }
    }
}

private enum SystemChatAXEventQuerySampler {
    static func sample(
        _ request: SystemChatAXEventQueryRequest
    ) -> SystemChatAXEventQuerySample? {
        let processIdentifier = request.target.processIdentifier
        guard
            !Task.isCancelled,
            request.runtimeBinding.processIdentifier == processIdentifier,
            let factsBefore = SystemChatAXCodeIdentityReader.runningRuntimeFacts(
                processIdentifier: processIdentifier),
            factsBefore == request.runtimeBinding.runtimeFacts,
            !Task.isCancelled
        else {
            return nil
        }
        let budget = SystemChatAXReadBudget()
        guard
            let verifiedBinding = SystemChatAXSurfaceSignatureReader(
                budget: budget,
                approvedAttributes: request.approvedAttributes
            ).readVerifiedEventBinding(
                applicationElement: request.applicationElement,
                eventElement: request.element,
                expectedProcessIdentifier: processIdentifier,
                allowedSignatures: [request.target.identity.surfaceSignature]),
            !Task.isCancelled,
            let factsAfter = SystemChatAXCodeIdentityReader.runningRuntimeFacts(
                processIdentifier: processIdentifier),
            factsAfter == factsBefore,
            verifiedBinding.surfaceSignature == request.target.identity.surfaceSignature,
            !Task.isCancelled,
            SystemChatAXRuntimeApplicationVerifier.matches(
                target: request.target,
                binding: request.runtimeBinding),
            !Task.isCancelled
        else {
            return nil
        }
        return SystemChatAXEventQuerySample(
            processIdentifier: processIdentifier,
            runtimeFacts: factsBefore,
            surfaceSignature: verifiedBinding.surfaceSignature,
            windowOrdinal: verifiedBinding.windowOrdinal)
    }
}

private enum SystemChatAXRuntimeSampler {
    static func sample(
        processIdentifier: pid_t,
        expectedSurfaceSignature: ChatAXSurfaceSignature
    ) -> SystemChatAXRuntimeSample? {
        sample(
            processIdentifier: processIdentifier,
            expectedSurfaceSignature: expectedSurfaceSignature,
            applicationElement: AXUIElementCreateApplication(processIdentifier))
    }

    static func sample(
        processIdentifier: pid_t,
        expectedSurfaceSignature: ChatAXSurfaceSignature,
        applicationElement: AXUIElement
    ) -> SystemChatAXRuntimeSample? {
        guard
            !Task.isCancelled,
            let factsBefore = SystemChatAXCodeIdentityReader.runningRuntimeFacts(
                processIdentifier: processIdentifier),
            !Task.isCancelled,
            let anchorFacts = SystemChatAXSurfaceSignatureReader().readAnchorFacts(
                applicationElement: applicationElement,
                expectedProcessIdentifier: processIdentifier),
            !Task.isCancelled,
            let verifiedSurface = ChatAXSurfaceVerifier.verifyChat(
                anchorFacts: anchorFacts,
                allowedSignatures: [expectedSurfaceSignature]),
            !Task.isCancelled,
            let factsAfter = SystemChatAXCodeIdentityReader.runningRuntimeFacts(
                processIdentifier: processIdentifier),
            factsAfter == factsBefore,
            !Task.isCancelled
        else {
            return nil
        }
        return SystemChatAXRuntimeSample(
            runtimeFacts: factsBefore,
            surfaceSignature: verifiedSurface.signature)
    }
}

private struct SystemChatAXInspectedBinding {
    let candidates: [ChatAXObservedTarget]
    let runtimeBinding: SystemChatAXRuntimeBinding
}

private enum SystemChatAXIdentityInspection {
    case candidates(
        [ChatAXTargetIdentity],
        hasUnreadableProjection: Bool,
        runtimeBinding: SystemChatAXRuntimeBinding)
    case unreadable
}

private enum SystemChatAXFrameworkIdentityInspection: Equatable {
    case observed(ChatAXFrameworkIdentity)
    case missing
    case unreadable
}

private enum SystemChatAXFrameworkSetInspection: Equatable {
    case candidate([ChatAXFrameworkIdentity])
    case mismatch
    case unreadable
}

@MainActor
final class SystemChatAXTraceObserver: ChatAXTraceObserving {
    private var axObserver: AXObserver?
    private var applicationElement: AXUIElement?
    private var registeredNotifications: [CFString] = []
    private var target: ChatAXObservedTarget?
    private var approvedAttributes: Set<ChatAXApprovedAttribute> = []
    private var receive: ((ChatAXStructuralSignal) -> Void)?
    private var targetDidInvalidate: (() -> Void)?
    private var validationTimer: Timer?
    private var validationTask: Task<Void, Never>?
    private var validationGate = ChatAXRuntimeValidationGate()
    private var eventQueryCoordinator:
        ChatAXEventQueryCoordinator<SystemChatAXEventQueryRequest, SystemChatAXEventQuerySample>?
    private var runtimeBinding: SystemChatAXRuntimeBinding?
    private var pendingInspection: SystemChatAXInspectedBinding?
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var nextSequence = 1

    func inspectTarget(
        requirements: ChatAXInspectionRequirements
    ) -> Result<ChatAXTargetInspection, ChatAXTargetInspectionFailure> {
        pendingInspection = nil
        let applications = requirements.bundleIdentifiers
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        let uniqueApplications = Dictionary(
            applications.map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        .values
        .filter { !$0.isTerminated }

        guard !uniqueApplications.isEmpty else { return .failure(.targetUnavailable) }
        guard uniqueApplications.count == 1, let application = uniqueApplications.first else {
            return .failure(.ambiguousTargets)
        }
        let workerGate = ChatAXSystemQueryWorkerGate.shared
        guard let workerLease = workerGate.acquire() else {
            return .failure(.identityUnreadable)
        }
        defer { workerGate.release(workerLease) }
        let identities: [ChatAXTargetIdentity]
        let hasUnreadableProjection: Bool
        let inspectedRuntimeBinding: SystemChatAXRuntimeBinding
        switch inspectIdentities(for: application, requirements: requirements) {
        case .candidates(
            let candidates,
            let containsUnreadableProjection,
            let runtimeBinding):
            identities = candidates
            hasUnreadableProjection = containsUnreadableProjection
            inspectedRuntimeBinding = runtimeBinding
        case .unreadable:
            return .failure(.identityUnreadable)
        }
        let observedCandidates = identities.map {
            ChatAXObservedTarget(
                processIdentifier: application.processIdentifier,
                identity: $0)
        }
        pendingInspection = SystemChatAXInspectedBinding(
            candidates: observedCandidates,
            runtimeBinding: inspectedRuntimeBinding)
        return .success(
            ChatAXTargetInspection(
                candidates: observedCandidates,
                hasUnreadableProjection: hasUnreadableProjection))
    }

    func start(
        target: ChatAXObservedTarget,
        approvedAttributes: Set<ChatAXApprovedAttribute>,
        receive: @escaping (ChatAXStructuralSignal) -> Void,
        targetDidInvalidate: @escaping () -> Void
    ) -> Bool {
        let inspectedBinding = pendingInspection
        stop()
        guard
            AXIsProcessTrusted(),
            let inspectedBinding,
            inspectedBinding.candidates.contains(target)
        else {
            return false
        }
        let workerGate = ChatAXSystemQueryWorkerGate.shared
        guard let workerLease = workerGate.acquire() else { return false }
        defer { workerGate.release(workerLease) }

        let applicationElement = AXUIElementCreateApplication(target.processIdentifier)
        guard
            startupRuntimeStillMatches(
                target: target,
                binding: inspectedBinding.runtimeBinding,
                applicationElement: applicationElement)
        else {
            return false
        }

        var createdObserver: AXObserver?
        guard
            AXObserverCreate(
                target.processIdentifier,
                systemChatAXObserverCallback,
                &createdObserver) == .success,
            let createdObserver
        else {
            return false
        }

        let attributeReader = SystemChatAXAttributeReader(
            approvedAttributes: approvedAttributes)
        guard attributeReader.prepareForMessaging(applicationElement) else { return false }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let notifications: [CFString] = [
            kAXFocusedUIElementChangedNotification as CFString,
            kAXFocusedWindowChangedNotification as CFString,
            kAXWindowCreatedNotification as CFString,
            kAXUIElementDestroyedNotification as CFString,
            kAXLayoutChangedNotification as CFString,
        ]
        let registered = notifications.filter {
            AXObserverAddNotification(createdObserver, applicationElement, $0, refcon) == .success
        }
        guard
            registered.count == notifications.count,
            startupRuntimeStillMatches(
                target: target,
                binding: inspectedBinding.runtimeBinding,
                applicationElement: applicationElement)
        else {
            for notification in registered {
                AXObserverRemoveNotification(createdObserver, applicationElement, notification)
            }
            return false
        }

        self.target = target
        self.approvedAttributes = approvedAttributes
        self.receive = receive
        self.targetDidInvalidate = targetDidInvalidate
        runtimeBinding = inspectedBinding.runtimeBinding
        let eventQueryCoordinator = ChatAXEventQueryCoordinator<
            SystemChatAXEventQueryRequest,
            SystemChatAXEventQuerySample
        >(
            sampler: { request in
                SystemChatAXEventQuerySampler.sample(request)
            },
            didProduce: { [weak self] elapsedMilliseconds, sample in
                self?.commitObservedEvent(
                    sample,
                    elapsedMilliseconds: elapsedMilliseconds)
            },
            didInvalidate: { [weak self] in
                self?.invalidateTarget()
            })
        self.eventQueryCoordinator = eventQueryCoordinator
        eventQueryCoordinator.beginSession()
        validationGate.beginSession()
        axObserver = createdObserver
        self.applicationElement = applicationElement
        registeredNotifications = registered
        startedAt = ProcessInfo.processInfo.systemUptime
        nextSequence = 1
        CFRunLoopAddSource(
            CFRunLoopGetMain(), AXObserverGetRunLoopSource(createdObserver), .commonModes)
        let validationTimer = Timer(timeInterval: 1, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleBoundTargetValidation()
            }
        }
        self.validationTimer = validationTimer
        RunLoop.main.add(validationTimer, forMode: .common)
        return true
    }

    func stop() {
        validationTimer?.invalidate()
        validationTimer = nil
        validationTask?.cancel()
        validationTask = nil
        validationGate.endSession()
        eventQueryCoordinator?.endSession()
        eventQueryCoordinator = nil
        if let axObserver {
            if let applicationElement {
                for notification in registeredNotifications {
                    AXObserverRemoveNotification(axObserver, applicationElement, notification)
                }
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes)
        }
        axObserver = nil
        applicationElement = nil
        registeredNotifications = []
        target = nil
        runtimeBinding = nil
        pendingInspection = nil
        approvedAttributes = []
        receive = nil
        targetDidInvalidate = nil
    }

    fileprivate func handle(
        element: AXUIElement,
        targetWasDestroyed: Bool
    ) {
        guard let target else { return }
        let arrivalElapsedMilliseconds = traceElapsedMilliseconds
        if targetWasDestroyed {
            if let applicationElement, CFEqual(element, applicationElement) {
                self.applicationElement = nil
                emitSignal(
                    kind: .applicationExited,
                    windowOrdinal: 0,
                    elapsedMilliseconds: arrivalElapsedMilliseconds)
            }
            invalidateTarget()
            return
        }
        guard
            let applicationElement,
            let runtimeBinding,
            let eventQueryCoordinator
        else {
            invalidateTarget()
            return
        }
        let request = SystemChatAXEventQueryRequest(
            element: element,
            applicationElement: applicationElement,
            target: target,
            runtimeBinding: runtimeBinding,
            approvedAttributes: approvedAttributes)
        eventQueryCoordinator.enqueue(
            request,
            elapsedMilliseconds: arrivalElapsedMilliseconds)
    }

    private func commitObservedEvent(
        _ sample: SystemChatAXEventQuerySample,
        elapsedMilliseconds: Int
    ) {
        guard
            let target,
            let runtimeBinding,
            sample.processIdentifier == target.processIdentifier,
            sample.runtimeFacts == runtimeBinding.runtimeFacts,
            sample.surfaceSignature == target.identity.surfaceSignature
        else {
            invalidateTarget()
            return
        }
        emitSignal(
            kind: .unrelatedStructureChanged,
            windowOrdinal: sample.windowOrdinal,
            elapsedMilliseconds: elapsedMilliseconds)
    }

    private func emitSignal(kind: ChatAXStructuralSignalKind, windowOrdinal: Int) {
        emitSignal(
            kind: kind,
            windowOrdinal: windowOrdinal,
            elapsedMilliseconds: traceElapsedMilliseconds)
    }

    private func emitSignal(
        kind: ChatAXStructuralSignalKind,
        windowOrdinal: Int,
        elapsedMilliseconds: Int
    ) {
        let sequence = nextSequence
        nextSequence += 1
        receive?(
            ChatAXStructuralSignal(
                sequence: sequence,
                elapsedMilliseconds: elapsedMilliseconds,
                windowOrdinal: windowOrdinal,
                kind: kind))
    }

    private var traceElapsedMilliseconds: Int {
        max(
            0,
            Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000))
    }

    private func scheduleBoundTargetValidation() {
        guard
            let binding = runtimeBinding,
            let target,
            let request = validationGate.beginValidation()
        else {
            return
        }
        let processIdentifier = binding.processIdentifier
        let expectedSurfaceSignature = target.identity.surfaceSignature
        validationTask = Task { [weak self] in
            let outcome = await ChatAXRuntimeValidationDeadline.run(
                timeoutNanoseconds: 500_000_000
            ) {
                SystemChatAXRuntimeSampler.sample(
                    processIdentifier: processIdentifier,
                    expectedSurfaceSignature: expectedSurfaceSignature)
            }
            guard !Task.isCancelled else { return }
            self?.finishBoundTargetValidation(
                request: request,
                outcome: outcome)
        }
    }

    private func finishBoundTargetValidation(
        request: ChatAXRuntimeValidationGate.Request,
        outcome: ChatAXRuntimeValidationDeadlineOutcome<SystemChatAXRuntimeSample?>
    ) {
        guard validationGate.finishValidation(request) else { return }
        validationTask = nil
        switch outcome {
        case .deferred:
            return
        case .cancelled, .timedOut:
            invalidateTarget()
            return
        case .completed(let sample):
            guard
                let target,
                let runtimeBinding,
                sample?.runtimeFacts == runtimeBinding.runtimeFacts,
                sample?.surfaceSignature == target.identity.surfaceSignature,
                runtimeApplicationStillMatches(target: target, binding: runtimeBinding)
            else {
                invalidateTarget()
                return
            }
        }
    }

    private func invalidateTarget() {
        let callback = targetDidInvalidate
        stop()
        callback?()
    }

    func targetStillMatches(
        _ target: ChatAXObservedTarget
    ) -> ChatAXTargetRevalidationOutcome {
        let workerGate = ChatAXSystemQueryWorkerGate.shared
        guard let workerLease = workerGate.acquire() else { return .deferred }
        defer { workerGate.release(workerLease) }
        guard
            let runtimeBinding,
            runtimeBinding.processIdentifier == target.processIdentifier,
            let sample = SystemChatAXRuntimeSampler.sample(
                processIdentifier: target.processIdentifier,
                expectedSurfaceSignature: target.identity.surfaceSignature),
            sample.runtimeFacts == runtimeBinding.runtimeFacts,
            sample.surfaceSignature == target.identity.surfaceSignature,
            runtimeApplicationStillMatches(target: target, binding: runtimeBinding)
        else {
            return .mismatch
        }
        return .matches
    }

    private func runtimeApplicationStillMatches(
        target: ChatAXObservedTarget,
        binding: SystemChatAXRuntimeBinding
    ) -> Bool {
        SystemChatAXRuntimeApplicationVerifier.matches(
            target: target,
            binding: binding)
    }

    private func inspectIdentities(
        for application: NSRunningApplication,
        requirements: ChatAXInspectionRequirements,
        applicationElement providedApplicationElement: AXUIElement? = nil
    ) -> SystemChatAXIdentityInspection {
        let processIdentifier = application.processIdentifier
        guard
            !application.isTerminated,
            let bundleURL = application.bundleURL,
            let architectureBefore = architecture(for: application),
            let codeBefore = SystemChatAXCodeIdentityReader.coherentSnapshot(
                processIdentifier: processIdentifier,
                bundleURL: bundleURL),
            let anchorFacts = SystemChatAXSurfaceSignatureReader().readAnchorFacts(
                applicationElement: providedApplicationElement
                    ?? AXUIElementCreateApplication(processIdentifier),
                expectedProcessIdentifier: processIdentifier)
        else {
            return .unreadable
        }

        let frameworksDirectory =
            bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Frameworks", isDirectory: true)
        let frameworkNameSets = requirements.frameworkNameSets.sorted(by: {
            $0.sorted().lexicographicallyPrecedes($1.sorted())
        })
        let frameworkInspections = frameworkNameSets.map {
            inspectStableFrameworkSet(named: $0, in: frameworksDirectory)
        }

        guard
            let confirmedApplication = NSRunningApplication(
                processIdentifier: processIdentifier),
            !confirmedApplication.isTerminated,
            let confirmedBundleURL = confirmedApplication.bundleURL,
            SystemChatAXCodeIdentityReader.normalizedPath(confirmedBundleURL)
                == SystemChatAXCodeIdentityReader.normalizedPath(bundleURL),
            let architectureAfter = architecture(for: confirmedApplication),
            architectureAfter == architectureBefore,
            let codeAfter = SystemChatAXCodeIdentityReader.coherentSnapshot(
                processIdentifier: processIdentifier,
                bundleURL: confirmedBundleURL),
            codeBefore == codeAfter,
            let signedBundleIdentity = ChatAXCodeIdentityBinding.bind(
                runningBefore: codeBefore.runningFacts.signedBundleIdentity,
                diskBefore: codeBefore.diskFacts.signedBundleIdentity,
                runningAfter: codeAfter.runningFacts.signedBundleIdentity,
                diskAfter: codeAfter.diskFacts.signedBundleIdentity)
        else {
            return .unreadable
        }

        let runtimeBinding = SystemChatAXRuntimeBinding(
            processIdentifier: processIdentifier,
            runtimeFacts: SystemChatAXRuntimeFacts(
                signingFacts: codeBefore.runningFacts,
                processIncarnation: codeBefore.processIncarnation),
            bundlePath: codeBefore.bundlePath,
            architecture: architectureBefore)
        guard
            let verifiedSurface = ChatAXSurfaceVerifier.verifyChat(
                anchorFacts: anchorFacts,
                allowedSignatures: requirements.surfaceSignatures)
        else {
            return .candidates(
                [],
                hasUnreadableProjection: false,
                runtimeBinding: runtimeBinding)
        }

        var identities: [ChatAXTargetIdentity] = []
        var hasUnreadableProjection = false
        for frameworkInspection in frameworkInspections {
            switch frameworkInspection {
            case .candidate(let frameworks):
                identities.append(
                    ChatAXTargetIdentity.observedChatGPTDesktopAX(
                        bundleIdentifier: signedBundleIdentity.bundleIdentifier,
                        codeSignature: signedBundleIdentity.codeSignature,
                        shortVersion: signedBundleIdentity.shortVersion,
                        build: signedBundleIdentity.build,
                        frameworks: frameworks,
                        architecture: architectureBefore,
                        verifiedSurface: verifiedSurface))
            case .mismatch:
                break
            case .unreadable:
                hasUnreadableProjection = true
            }
        }
        return .candidates(
            identities,
            hasUnreadableProjection: hasUnreadableProjection,
            runtimeBinding: runtimeBinding)
    }

    private func startupRuntimeStillMatches(
        target: ChatAXObservedTarget,
        binding: SystemChatAXRuntimeBinding,
        applicationElement: AXUIElement
    ) -> Bool {
        guard
            let sample = SystemChatAXRuntimeSampler.sample(
                processIdentifier: target.processIdentifier,
                expectedSurfaceSignature: target.identity.surfaceSignature,
                applicationElement: applicationElement),
            sample.runtimeFacts == binding.runtimeFacts,
            sample.surfaceSignature == target.identity.surfaceSignature,
            runtimeApplicationStillMatches(target: target, binding: binding)
        else {
            return false
        }
        return true
    }

    private func inspectStableFrameworkSet(
        named frameworkNames: Set<String>,
        in frameworksDirectory: URL
    ) -> SystemChatAXFrameworkSetInspection {
        let before = inspectFrameworkSet(
            named: frameworkNames,
            in: frameworksDirectory)
        let after = inspectFrameworkSet(
            named: frameworkNames,
            in: frameworksDirectory)
        guard before == after else { return .unreadable }
        return before
    }

    private func inspectFrameworkSet(
        named frameworkNames: Set<String>,
        in frameworksDirectory: URL
    ) -> SystemChatAXFrameworkSetInspection {
        var frameworks: [ChatAXFrameworkIdentity] = []
        var hasMissingFramework = false
        var hasUnreadableFramework = false
        for name in frameworkNames.sorted() {
            switch inspectFrameworkIdentity(
                at: frameworksDirectory.appendingPathComponent(name, isDirectory: true),
                name: name)
            {
            case .observed(let framework):
                frameworks.append(framework)
            case .missing:
                hasMissingFramework = true
            case .unreadable:
                hasUnreadableFramework = true
            }
        }
        if hasMissingFramework { return .mismatch }
        if hasUnreadableFramework { return .unreadable }
        return .candidate(frameworks)
    }

    private func inspectFrameworkIdentity(
        at url: URL,
        name: String
    ) -> SystemChatAXFrameworkIdentityInspection {
        switch chatAXFrameworkBundlePathState(at: url) {
        case .missing:
            return .missing
        case .unreadable:
            return .unreadable
        case .directory:
            break
        }
        guard
            let signedBundleIdentity =
                SystemChatAXCodeIdentityReader
                .diskSignedBundleIdentity(at: url)
        else {
            return .unreadable
        }
        return .observed(
            ChatAXFrameworkIdentity(
                name: name,
                shortVersion: signedBundleIdentity.shortVersion,
                build: signedBundleIdentity.build))
    }

    private func architecture(
        for application: NSRunningApplication
    ) -> ChatAXCPUArchitecture? {
        SystemChatAXRuntimeApplicationVerifier.architecture(for: application)
    }

}

private func systemChatAXObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let traceObserver = Unmanaged<SystemChatAXTraceObserver>.fromOpaque(refcon)
        .takeUnretainedValue()
    let targetWasDestroyed = notification == kAXUIElementDestroyedNotification as CFString
    MainActor.assumeIsolated {
        traceObserver.handle(
            element: element,
            targetWasDestroyed: targetWasDestroyed)
    }
}

@MainActor
func startExplicitChatAXTracerIfConfigured(
    environment: [String: String]
) -> ChatAXTracerSession? {
    guard let request = ChatAXDebugLaunchRequest(environment: environment) else { return nil }
    let tracer = ChatAXTracerSession(
        allowlist: request.allowlist,
        observer: SystemChatAXTraceObserver())
    tracer.guiDidBecomeAlive()
    guard tracer.beginExplicitTrace(scenarioNumber: request.scenarioNumber) == .started else {
        tracer.guiWillTerminate()
        return nil
    }
    return tracer
}
#endif
