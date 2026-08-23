#if DEBUG
import AppKit
@preconcurrency import ApplicationServices
import ClaudioCore
import ClaudioGUICore
import Foundation
import Security

private enum ChatAXAttributeReadFailure: Error {
    case unreadable
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
        deadline - ProcessInfo.processInfo.systemUptime >= Self.minimumQuerySeconds
    }

    func prepareForMessaging(_ element: AXUIElement) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining >= Self.minimumQuerySeconds else { return false }
        return AXUIElementSetMessagingTimeout(
            element,
            min(Self.maximumQuerySeconds, Float(remaining))) == .success
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
            AXUIElementCopyAttributeValue(element, relation.rawValue as CFString, &value)
                == .success,
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
            element, attribute.rawValue as CFString, &value)
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
    ) -> Int? {
        guard approvedAttributes.contains(attribute), prepareForMessaging(element) else {
            return nil
        }
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute.rawValue as CFString, &value)
                == .success,
            let number = value as? NSNumber
        else {
            return nil
        }
        return number.intValue
    }
}

/// 只沿当前焦点到当前窗口的 parent 链寻找最靠近窗口的已标识 anchor；绝不请求 children 或正文属性。
private struct SystemChatAXSurfaceSignatureReader {
    private static let approvedAttributes: Set<ChatAXApprovedAttribute> = [
        .identifier, .role, .subrole,
    ]

    private let reader = SystemChatAXAttributeReader(approvedAttributes: approvedAttributes)

    func readAnchorFacts(
        applicationElement: AXUIElement,
        expectedProcessIdentifier: pid_t
    ) -> ChatAXSurfaceAnchorFacts? {
        guard
            reader.prepareForMessaging(applicationElement),
            belongsToTarget(applicationElement, expectedProcessIdentifier)
        else {
            return nil
        }
        guard
            let focusedWindow = reader.element(.focusedWindow, from: applicationElement),
            let focusedElement = reader.element(.focusedUIElement, from: applicationElement),
            belongsToTarget(focusedWindow, expectedProcessIdentifier),
            belongsToTarget(focusedElement, expectedProcessIdentifier),
            let sampledLineage = lineage(
                from: focusedElement,
                through: focusedWindow,
                expectedProcessIdentifier: expectedProcessIdentifier),
            let facts = anchorFacts(in: sampledLineage),
            let confirmedWindow = reader.element(.focusedWindow, from: applicationElement),
            let confirmedElement = reader.element(.focusedUIElement, from: applicationElement),
            CFEqual(confirmedWindow, focusedWindow),
            CFEqual(confirmedElement, focusedElement),
            let confirmedLineage = lineage(
                from: confirmedElement,
                through: confirmedWindow,
                expectedProcessIdentifier: expectedProcessIdentifier),
            lineagesAreEqual(sampledLineage, confirmedLineage),
            anchorFacts(in: confirmedLineage) == facts,
            reader.hasRemainingTime
        else {
            return nil
        }
        return facts
    }

    private func lineage(
        from focusedElement: AXUIElement,
        through focusedWindow: AXUIElement,
        expectedProcessIdentifier: pid_t
    ) -> [AXUIElement]? {
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
            && observedProcessIdentifier == expectedProcessIdentifier
    }
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
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var nextSequence = 1

    func inspectTarget(
        requirements: ChatAXInspectionRequirements
    ) -> Result<ChatAXObservedTarget, ChatAXTargetInspectionFailure> {
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
        guard
            let identity = identity(
                for: application,
                requirements: requirements)
        else {
            return .failure(.identityUnreadable)
        }
        return .success(
            ChatAXObservedTarget(
                processIdentifier: application.processIdentifier,
                identity: identity))
    }

    func start(
        target: ChatAXObservedTarget,
        approvedAttributes: Set<ChatAXApprovedAttribute>,
        receive: @escaping (ChatAXStructuralSignal) -> Void,
        targetDidInvalidate: @escaping () -> Void
    ) -> Bool {
        stop()
        guard AXIsProcessTrusted(), targetStillMatches(target) else { return false }

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

        let applicationElement = AXUIElementCreateApplication(target.processIdentifier)
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
        guard registered.count == notifications.count, targetStillMatches(target) else {
            for notification in registered {
                AXObserverRemoveNotification(createdObserver, applicationElement, notification)
            }
            return false
        }

        self.target = target
        self.approvedAttributes = approvedAttributes
        self.receive = receive
        self.targetDidInvalidate = targetDidInvalidate
        axObserver = createdObserver
        self.applicationElement = applicationElement
        registeredNotifications = registered
        startedAt = ProcessInfo.processInfo.systemUptime
        nextSequence = 1
        CFRunLoopAddSource(
            CFRunLoopGetMain(), AXObserverGetRunLoopSource(createdObserver), .commonModes)
        validationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.validateBoundTarget()
            }
        }
        return true
    }

    func stop() {
        validationTimer?.invalidate()
        validationTimer = nil
        if let axObserver, let applicationElement {
            for notification in registeredNotifications {
                AXObserverRemoveNotification(axObserver, applicationElement, notification)
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes)
        }
        axObserver = nil
        applicationElement = nil
        registeredNotifications = []
        target = nil
        approvedAttributes = []
        receive = nil
        targetDidInvalidate = nil
    }

    fileprivate func handle(
        element: AXUIElement,
        targetWasDestroyed: Bool
    ) {
        guard let target else { return }
        if targetWasDestroyed {
            if let applicationElement, CFEqual(element, applicationElement) {
                emitSignal(kind: .applicationExited, element: element)
            }
            invalidateTarget()
            return
        }
        guard elementBelongsToTarget(element, target: target), surfaceStillMatches(target) else {
            invalidateTarget()
            return
        }
        emitSignal(kind: .unrelatedStructureChanged, element: element)
    }

    private func emitSignal(kind: ChatAXStructuralSignalKind, element: AXUIElement) {
        let reader = SystemChatAXAttributeReader(approvedAttributes: approvedAttributes)
        let windowOrdinal = max(0, reader.integer(.windowNumber, from: element) ?? 0)
        let elapsed = max(
            0,
            Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000))
        receive?(
            ChatAXStructuralSignal(
                sequence: nextSequence,
                elapsedMilliseconds: elapsed,
                windowOrdinal: windowOrdinal,
                kind: kind))
        nextSequence += 1
    }

    private func validateBoundTarget() {
        guard let target else { return }
        guard targetStillMatches(target) else {
            invalidateTarget()
            return
        }
    }

    private func invalidateTarget() {
        let callback = targetDidInvalidate
        stop()
        callback?()
    }

    private func targetStillMatches(_ target: ChatAXObservedTarget) -> Bool {
        guard
            let application = NSRunningApplication(
                processIdentifier: target.processIdentifier),
            !application.isTerminated,
            let observedIdentity = identity(
                for: application,
                requirements: ChatAXInspectionRequirements(
                    bundleIdentifiers: [target.identity.bundleIdentifier],
                    frameworkNames: Set(target.identity.frameworks.map(\.name)),
                    surfaceSignatures: [target.identity.surfaceSignature]))
        else {
            return false
        }
        return observedIdentity == target.identity
    }

    private func surfaceStillMatches(_ target: ChatAXObservedTarget) -> Bool {
        guard
            let applicationElement,
            let anchorFacts = SystemChatAXSurfaceSignatureReader().readAnchorFacts(
                applicationElement: applicationElement,
                expectedProcessIdentifier: target.processIdentifier),
            let verifiedSurface = ChatAXSurfaceVerifier.verifyChat(
                anchorFacts: anchorFacts,
                allowedSignatures: [target.identity.surfaceSignature])
        else {
            return false
        }
        return verifiedSurface.signature == target.identity.surfaceSignature
    }

    private func elementBelongsToTarget(
        _ element: AXUIElement,
        target: ChatAXObservedTarget
    ) -> Bool {
        let reader = SystemChatAXAttributeReader(approvedAttributes: [])
        guard reader.prepareForMessaging(element) else { return false }
        var observedProcessIdentifier: pid_t = 0
        return AXUIElementGetPid(element, &observedProcessIdentifier) == .success
            && observedProcessIdentifier == target.processIdentifier
    }

    private func identity(
        for application: NSRunningApplication,
        requirements: ChatAXInspectionRequirements
    ) -> ChatAXTargetIdentity? {
        guard
            let bundleURL = application.bundleURL,
            let bundle = Bundle(url: bundleURL),
            let bundleIdentifier = bundle.bundleIdentifier,
            let shortVersion = bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            let codeSignature = codeSignature(at: bundleURL),
            let architecture = architecture(for: application),
            let anchorFacts = SystemChatAXSurfaceSignatureReader().readAnchorFacts(
                applicationElement: AXUIElementCreateApplication(
                    application.processIdentifier),
                expectedProcessIdentifier: application.processIdentifier),
            let verifiedSurface = ChatAXSurfaceVerifier.verifyChat(
                anchorFacts: anchorFacts,
                allowedSignatures: requirements.surfaceSignatures)
        else {
            return nil
        }

        let frameworksDirectory =
            bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Frameworks", isDirectory: true)
        let frameworks = requirements.frameworkNames.sorted().compactMap { name in
            frameworkIdentity(
                at: frameworksDirectory.appendingPathComponent(name, isDirectory: true),
                name: name)
        }
        guard frameworks.count == requirements.frameworkNames.count else { return nil }
        return ChatAXTargetIdentity.observedChatGPTDesktopAX(
            bundleIdentifier: bundleIdentifier,
            codeSignature: codeSignature,
            shortVersion: shortVersion,
            build: build,
            frameworks: frameworks,
            architecture: architecture,
            verifiedSurface: verifiedSurface)
    }

    private func frameworkIdentity(at url: URL, name: String) -> ChatAXFrameworkIdentity? {
        guard
            let bundle = Bundle(url: url),
            let shortVersion = bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        else {
            return nil
        }
        return ChatAXFrameworkIdentity(name: name, shortVersion: shortVersion, build: build)
    }

    private func architecture(
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

    private func codeSignature(at bundleURL: URL) -> ChatAXCodeSignature? {
        var staticCode: SecStaticCode?
        guard
            SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode)
                == errSecSuccess,
            let staticCode,
            SecStaticCodeCheckValidity(
                staticCode,
                SecCSFlags(rawValue: kSecCSStrictValidate),
                nil) == errSecSuccess
        else {
            return nil
        }

        var signingInformation: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &signingInformation) == errSecSuccess,
            let information = signingInformation as? [CFString: Any],
            let teamIdentifier = information[kSecCodeInfoTeamIdentifier] as? String,
            let signingIdentifier = information[kSecCodeInfoIdentifier] as? String,
            let cdHash = information[kSecCodeInfoUnique] as? Data
        else {
            return nil
        }
        return ChatAXCodeSignature(
            teamIdentifier: teamIdentifier,
            signingIdentifier: signingIdentifier,
            cdHash: cdHash.map { String(format: "%02x", $0) }.joined())
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
