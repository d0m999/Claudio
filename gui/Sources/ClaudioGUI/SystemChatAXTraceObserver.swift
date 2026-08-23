#if DEBUG
import AppKit
@preconcurrency import ApplicationServices
import ClaudioCore
import ClaudioGUICore
import Foundation
import Security

/// 系统 AX 边界只接受封闭枚举，调用方无法传入任意属性名。
private struct SystemChatAXAttributeReader {
    let approvedAttributes: Set<ChatAXApprovedAttribute>

    func integer(
        _ attribute: ChatAXApprovedAttribute,
        from element: AXUIElement
    ) -> Int? {
        guard approvedAttributes.contains(attribute) else { return nil }
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
                requiredFrameworkNames: requirements.frameworkNames)
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
        guard !registered.isEmpty else { return false }

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

    fileprivate func handle(element: AXUIElement, targetWasDestroyed: Bool) {
        guard target != nil else { return }
        let kind: ChatAXStructuralSignalKind
        if targetWasDestroyed {
            kind = .applicationExited
        } else {
            kind = .unrelatedStructureChanged
        }
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
        if case .applicationExited = kind {
            invalidateTarget()
        }
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
                requiredFrameworkNames: Set(target.identity.frameworks.map(\.name)))
        else {
            return false
        }
        return observedIdentity == target.identity
    }

    private func identity(
        for application: NSRunningApplication,
        requiredFrameworkNames: Set<String>
    ) -> ChatAXTargetIdentity? {
        guard
            let bundleURL = application.bundleURL,
            let bundle = Bundle(url: bundleURL),
            let bundleIdentifier = bundle.bundleIdentifier,
            let shortVersion = bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            let codeSignature = codeSignature(at: bundleURL),
            let architecture = architecture(for: application)
        else {
            return nil
        }

        let frameworksDirectory =
            bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Frameworks", isDirectory: true)
        let frameworks = requiredFrameworkNames.sorted().compactMap { name in
            frameworkIdentity(
                at: frameworksDirectory.appendingPathComponent(name, isDirectory: true),
                name: name)
        }
        guard frameworks.count == requiredFrameworkNames.count else { return nil }
        return ChatAXTargetIdentity(
            bundleIdentifier: bundleIdentifier,
            codeSignature: codeSignature,
            shortVersion: shortVersion,
            build: build,
            frameworks: frameworks,
            architecture: architecture,
            surface: .chatGPTDesktopAX)
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
        traceObserver.handle(element: element, targetWasDestroyed: targetWasDestroyed)
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
