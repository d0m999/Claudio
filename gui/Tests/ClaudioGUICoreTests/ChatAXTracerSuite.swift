import ClaudioCore
import ClaudioGUICore
import Dispatch
import Foundation

private func chatAXRepoRoot(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

private func chatAXSource(_ relativePath: String) -> String? {
    try? String(
        contentsOf: chatAXRepoRoot().appendingPathComponent(relativePath),
        encoding: .utf8)
}

private func chatAXLowLevelAttributeQueriesAreClosed(_ rawSource: String) -> Bool {
    let scanned = strippingComments(rawSource)
    guard scanned.unmodeledConstructs.isEmpty else { return false }
    let code = scanned.codeWithoutStringLiterals
    guard
        let reader = chatAXBracedDeclarationRegion(
            "private struct SystemChatAXAttributeReader", in: code),
        let elementReader = chatAXFunctionRegion("func element(", in: reader),
        let stringReader = chatAXFunctionRegion("func string(", in: reader),
        let integerReader = chatAXFunctionRegion("func integer(", in: reader)
    else {
        return false
    }

    let api = "AXUIElementCopyAttributeValue"
    let allCalls = callArguments(of: api, in: code)
    let readerCalls = callArguments(of: api, in: reader)
    let symbolHits = code.components(separatedBy: api).count - 1
    let expectedArguments = [
        "element, (relation as ChatAXApprovedRelation).rawValue as CFString, &value",
        "element, (attribute as ChatAXApprovedAttribute).rawValue as CFString, &value",
        "element, (attribute as ChatAXApprovedAttribute).rawValue as CFString, &value",
    ].sorted()
    let normalizedElementReader = collapsingWhitespace(elementReader)
    let normalizedStringReader = collapsingWhitespace(stringReader)
    let normalizedIntegerReader = collapsingWhitespace(integerReader)
    return symbolHits == allCalls.count
        && allCalls.count == readerCalls.count
        && readerCalls.map(collapsingWhitespace).sorted() == expectedArguments
        && normalizedElementReader.contains("_ relation: ChatAXApprovedRelation")
        && normalizedStringReader.contains("_ attribute: ChatAXApprovedAttribute")
        && normalizedIntegerReader.contains("_ attribute: ChatAXApprovedAttribute")
        && !normalizedElementReader.contains("let relation =")
        && !normalizedElementReader.contains("var relation =")
        && !normalizedStringReader.contains("let attribute =")
        && !normalizedStringReader.contains("var attribute =")
        && !normalizedIntegerReader.contains("let attribute =")
        && !normalizedIntegerReader.contains("var attribute =")
        && !code.contains("AXUIElementCopyMultipleAttributeValues")
        && !code.contains("AXUIElementCopyParameterizedAttributeValue")
}

private func chatAXBlockingValidationSample(_ blocker: DispatchSemaphore) -> Int {
    blocker.wait()
    return 7
}

private func chatAXSemaphoreWasSignaled(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTime
) -> Bool {
    semaphore.wait(timeout: timeout) == .success
}

private final class ChatAXThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

@MainActor
private final class ChatAXFixtureObserver: ChatAXTraceObserving {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var inspectedRequirements: ChatAXInspectionRequirements?
    private(set) var startedTarget: ChatAXObservedTarget?
    private(set) var approvedAttributes: Set<ChatAXApprovedAttribute> = []
    private var receive: ((ChatAXStructuralSignal) -> Void)?
    private var targetDidInvalidate: (() -> Void)?
    private let signalsOnStart: [ChatAXStructuralSignal]
    private let startSucceeds: Bool
    var observedTargets: [ChatAXObservedTarget]?
    var hasUnreadableProjection = false
    var inspectionFailure: ChatAXTargetInspectionFailure?
    var targetRevalidationOutcomeOverride: ChatAXTargetRevalidationOutcome?

    init(
        observedTarget: ChatAXObservedTarget?,
        signalsOnStart: [ChatAXStructuralSignal] = [],
        startSucceeds: Bool = true,
        inspectionFailure: ChatAXTargetInspectionFailure? = nil
    ) {
        observedTargets = observedTarget.map { [$0] }
        self.signalsOnStart = signalsOnStart
        self.startSucceeds = startSucceeds
        self.inspectionFailure = inspectionFailure
    }

    func inspectTarget(
        requirements: ChatAXInspectionRequirements
    ) -> Result<ChatAXTargetInspection, ChatAXTargetInspectionFailure> {
        inspectedRequirements = requirements
        if let inspectionFailure {
            return .failure(inspectionFailure)
        }
        guard let observedTargets else { return .failure(.targetUnavailable) }
        return .success(
            ChatAXTargetInspection(
                candidates: observedTargets,
                hasUnreadableProjection: hasUnreadableProjection))
    }

    func targetStillMatches(_ target: ChatAXObservedTarget) -> ChatAXTargetRevalidationOutcome {
        if let targetRevalidationOutcomeOverride { return targetRevalidationOutcomeOverride }
        return inspectionFailure == nil && observedTargets?.contains(target) == true
            ? .matches : .mismatch
    }

    func start(
        target: ChatAXObservedTarget,
        approvedAttributes: Set<ChatAXApprovedAttribute>,
        receive: @escaping (ChatAXStructuralSignal) -> Void,
        targetDidInvalidate: @escaping () -> Void
    ) -> Bool {
        startCount += 1
        startedTarget = target
        self.approvedAttributes = approvedAttributes
        self.receive = receive
        self.targetDidInvalidate = targetDidInvalidate
        for signal in signalsOnStart {
            receive(signal)
        }
        return startSucceeds
    }

    func stop() {
        stopCount += 1
        receive = nil
        targetDidInvalidate = nil
    }

    func emit(_ signal: ChatAXStructuralSignal) {
        receive?(signal)
    }

    func invalidateTarget() {
        targetDidInvalidate?()
    }

    func setObservedTarget(_ target: ChatAXObservedTarget?) {
        observedTargets = target.map { [$0] }
    }
}

private func chatAXIdentity(
    bundleIdentifier: String = "com.example.chat.fixture",
    codeSignature: ChatAXCodeSignature = ChatAXCodeSignature(
        teamIdentifier: "TEAMFIXTURE",
        signingIdentifier: "com.example.chat.fixture",
        cdHash: "fixture-cdhash-001"),
    shortVersion: String = "1.2.3",
    build: String = "456",
    frameworks: [ChatAXFrameworkIdentity] = [
        ChatAXFrameworkIdentity(name: "FixtureWeb.framework", shortVersion: "7.8.9", build: "89")
    ],
    architecture: ChatAXCPUArchitecture = .arm64,
    surface: HostSurfaceID = .chatGPTDesktopAX,
    surfaceSignature: ChatAXSurfaceSignature = chatAXSurfaceSignature("a")
) -> ChatAXTargetIdentity {
    ChatAXTargetIdentity(
        bundleIdentifier: bundleIdentifier,
        codeSignature: codeSignature,
        shortVersion: shortVersion,
        build: build,
        frameworks: frameworks,
        architecture: architecture,
        surface: surface,
        surfaceSignature: surfaceSignature)
}

private func chatAXSurfaceSignature(_ digit: Character) -> ChatAXSurfaceSignature {
    ChatAXSurfaceSignature(rawValue: String(repeating: String(digit), count: 64))!
}

private func chatAXObservedTarget(
    processIdentifier: Int32 = 4242,
    identity: ChatAXTargetIdentity = chatAXIdentity()
) -> ChatAXObservedTarget {
    ChatAXObservedTarget(processIdentifier: processIdentifier, identity: identity)
}

@MainActor
func runChatAXTracerSuites() async {
    suite("Chat AX tracer allowlist：完整身份与独立 surface 摘要必须逐字匹配") {
        let allowedIdentity = chatAXIdentity()
        let allowlist = ChatAXVersionAllowlist(identities: [allowedIdentity])

        expect(allowlist.allows(allowedIdentity), "完整 fixture 身份应命中 allowlist")

        let mismatches = [
            chatAXIdentity(bundleIdentifier: "com.example.other"),
            chatAXIdentity(
                codeSignature: ChatAXCodeSignature(
                    teamIdentifier: "OTHERTEAM",
                    signingIdentifier: "com.example.chat.fixture",
                    cdHash: "fixture-cdhash-001")),
            chatAXIdentity(shortVersion: "1.2.4"),
            chatAXIdentity(build: "457"),
            chatAXIdentity(
                frameworks: [
                    ChatAXFrameworkIdentity(
                        name: "FixtureWeb.framework", shortVersion: "7.8.10", build: "90")
                ]),
            chatAXIdentity(
                frameworks: [
                    ChatAXFrameworkIdentity(
                        name: "FixtureWeb.framework", shortVersion: "7.8.9", build: "89"),
                    ChatAXFrameworkIdentity(
                        name: "FixtureWeb.framework", shortVersion: "7.8.9", build: "89"),
                ]),
            chatAXIdentity(architecture: .intel64),
            chatAXIdentity(surface: .codex),
            chatAXIdentity(surfaceSignature: chatAXSurfaceSignature("b")),
        ]
        for mismatch in mismatches {
            expect(!allowlist.allows(mismatch), "任一身份字段失配都不得宽松命中")
        }

        let duplicateAllowlist = ChatAXVersionAllowlist(
            identities: [
                chatAXIdentity(
                    frameworks: [
                        ChatAXFrameworkIdentity(
                            name: "A.framework", shortVersion: "1", build: "1"),
                        ChatAXFrameworkIdentity(
                            name: "A.framework", shortVersion: "1", build: "1"),
                        ChatAXFrameworkIdentity(
                            name: "B.framework", shortVersion: "1", build: "1"),
                    ])
            ])
        expect(
            !duplicateAllowlist.allows(
                chatAXIdentity(
                    frameworks: [
                        ChatAXFrameworkIdentity(
                            name: "A.framework", shortVersion: "1", build: "1"),
                        ChatAXFrameworkIdentity(
                            name: "B.framework", shortVersion: "1", build: "1"),
                        ChatAXFrameworkIdentity(
                            name: "B.framework", shortVersion: "1", build: "1"),
                    ])),
            "framework 精确匹配必须保留多重集合计数")
    }

    suite("Chat AX tracer surface 摘要：只接受固定 lowercase SHA-256，并只派生 Chat 检查要求") {
        let digest = String(repeating: "a", count: 64)
        expect(ChatAXSurfaceSignature(rawValue: digest)?.rawValue == digest, "固定摘要应可构造")
        for invalidDigest in [
            String(repeating: "a", count: 63),
            String(repeating: "a", count: 65),
            String(repeating: "A", count: 64),
            String(repeating: "g", count: 64),
        ] {
            expect(
                ChatAXSurfaceSignature(rawValue: invalidDigest) == nil,
                "非 canonical SHA-256 必须 fail closed")
        }
        let invalidJSON = Data("\"\(String(repeating: "A", count: 64))\"".utf8)
        expect(
            (try? JSONDecoder().decode(ChatAXSurfaceSignature.self, from: invalidJSON)) == nil,
            "JSON 入口也必须拒绝非 canonical 摘要")

        let chatIdentity = chatAXIdentity(
            frameworks: [
                ChatAXFrameworkIdentity(
                    name: "FixtureWeb.framework", shortVersion: "7.8.9", build: "89")
            ])
        let secondChatIdentity = chatAXIdentity(
            shortVersion: "2.0.0",
            build: "900",
            frameworks: [
                ChatAXFrameworkIdentity(
                    name: "NextWeb.framework", shortVersion: "9.0.0", build: "900")
            ],
            surfaceSignature: chatAXSurfaceSignature("c"))
        let adjacentSurfaceIdentity = chatAXIdentity(
            bundleIdentifier: "com.example.shared-app.adjacent",
            frameworks: [
                ChatAXFrameworkIdentity(
                    name: "Adjacent.framework", shortVersion: "1", build: "1")
            ],
            surface: .codex,
            surfaceSignature: chatAXSurfaceSignature("b"))
        let requirements = ChatAXVersionAllowlist(
            identities: [chatIdentity, secondChatIdentity, adjacentSurfaceIdentity]
        ).inspectionRequirements
        expect(
            requirements.bundleIdentifiers == [chatIdentity.bundleIdentifier]
                && requirements.frameworkNameSets
                    == [
                        ["FixtureWeb.framework"],
                        ["NextWeb.framework"],
                    ]
                && requirements.surfaceSignatures
                    == [chatAXSurfaceSignature("a"), chatAXSurfaceSignature("c")],
            "系统 inspection 必须保留每条普通 Chat identity 自己的 framework 集合")
    }

    suite("Chat AX tracer inspection candidates：异构 framework projection 独立 exact 命中") {
        let legacyIdentity = chatAXIdentity(
            frameworks: [
                ChatAXFrameworkIdentity(
                    name: "LegacyWeb.framework", shortVersion: "1", build: "10")
            ])
        let currentIdentity = chatAXIdentity(
            shortVersion: "2.0.0",
            build: "900",
            frameworks: [
                ChatAXFrameworkIdentity(
                    name: "NextWeb.framework", shortVersion: "2", build: "20")
            ],
            surfaceSignature: chatAXSurfaceSignature("c"))
        let observer = ChatAXFixtureObserver(observedTarget: nil)
        observer.observedTargets = [
            chatAXObservedTarget(identity: chatAXIdentity(build: "unlisted")),
            chatAXObservedTarget(identity: currentIdentity),
        ]
        let tracer = ChatAXTracerSession(
            allowlist: ChatAXVersionAllowlist(
                identities: [legacyIdentity, currentIdentity]),
            observer: observer)
        tracer.guiDidBecomeAlive()

        expect(
            tracer.beginExplicitTrace(scenarioNumber: 33) == .started,
            "不同 framework 集的当前版本必须能从多个观察 projection 中独立命中")
        expect(
            observer.startedTarget?.identity == currentIdentity,
            "session 必须把 exact current projection 交给 observer，而不是候选列表第一项")
        tracer.endExplicitTrace()
    }

    suite("Chat AX tracer framework path：真实 Foundation 错误区分 missing 与 unreadable") {
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "claudio-chat-ax-framework-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        expect(
            chatAXFrameworkBundlePathState(
                at: fixtureRoot.appendingPathComponent("Missing.framework", isDirectory: true))
                == .missing,
            "不存在路径的 NSError bridge 必须稳定分类为 missing，而不是 unreadable")
        try! FileManager.default.createDirectory(
            at: fixtureRoot, withIntermediateDirectories: true)
        let frameworkDirectory = fixtureRoot.appendingPathComponent(
            "Present.framework", isDirectory: true)
        try! FileManager.default.createDirectory(
            at: frameworkDirectory, withIntermediateDirectories: false)
        expect(
            chatAXFrameworkBundlePathState(at: frameworkDirectory) == .directory,
            "真实目录必须允许后续读取 Bundle metadata")
        let malformedFramework = fixtureRoot.appendingPathComponent(
            "Malformed.framework", isDirectory: false)
        try! Data().write(to: malformedFramework)
        expect(
            chatAXFrameworkBundlePathState(at: malformedFramework) == .unreadable,
            "已存在但不是目录的 framework path 必须保持 unreadable")
    }

    suite("Chat AX tracer code identity：运行与磁盘四次取样必须绑定同一签名") {
        let runningIdentity = ChatAXSignedBundleIdentity(
            bundleIdentifier: "com.example.Chat",
            codeSignature: ChatAXCodeSignature(
                teamIdentifier: "TEAM",
                signingIdentifier: "com.example.Chat",
                cdHash: "running"),
            shortVersion: "1.0",
            build: "100")
        let replacedIdentity = ChatAXSignedBundleIdentity(
            bundleIdentifier: "com.example.Chat",
            codeSignature: ChatAXCodeSignature(
                teamIdentifier: "TEAM",
                signingIdentifier: "com.example.Chat",
                cdHash: "replaced"),
            shortVersion: "2.0",
            build: "200")
        let metadataDriftIdentity = ChatAXSignedBundleIdentity(
            bundleIdentifier: "com.example.Chat",
            codeSignature: runningIdentity.codeSignature,
            shortVersion: "1.0",
            build: "101")
        expect(
            ChatAXCodeIdentityBinding.bind(
                runningBefore: runningIdentity,
                diskBefore: runningIdentity,
                runningAfter: runningIdentity,
                diskAfter: runningIdentity) == runningIdentity,
            "只有运行/磁盘前后四次 exact identity 才能授权 PID candidate")
        for (label, runningBefore, diskBefore, runningAfter, diskAfter) in [
            (
                "old PID + replaced disk", runningIdentity, replacedIdentity,
                runningIdentity, replacedIdentity
            ),
            (
                "disk drift", runningIdentity, runningIdentity,
                runningIdentity, replacedIdentity
            ),
            (
                "PID drift", runningIdentity, runningIdentity,
                replacedIdentity, runningIdentity
            ),
            (
                "signed metadata drift", runningIdentity, runningIdentity,
                runningIdentity, metadataDriftIdentity
            ),
        ] {
            expect(
                ChatAXCodeIdentityBinding.bind(
                    runningBefore: runningBefore,
                    diskBefore: diskBefore,
                    runningAfter: runningAfter,
                    diskAfter: diskAfter) == nil,
                "\(label) 必须失败关闭，不能混拼 allowlist identity")
        }
        let unreadableSamples:
            [(
                ChatAXSignedBundleIdentity?,
                ChatAXSignedBundleIdentity?,
                ChatAXSignedBundleIdentity?,
                ChatAXSignedBundleIdentity?
            )] = [
                (nil, runningIdentity, runningIdentity, runningIdentity),
                (runningIdentity, nil, runningIdentity, runningIdentity),
                (runningIdentity, runningIdentity, nil, runningIdentity),
                (runningIdentity, runningIdentity, runningIdentity, nil),
            ]
        for samples in unreadableSamples {
            expect(
                ChatAXCodeIdentityBinding.bind(
                    runningBefore: samples.0,
                    diskBefore: samples.1,
                    runningAfter: samples.2,
                    diskAfter: samples.3) == nil,
                "四个 binding sample 任一个不可读都必须 fail closed")
        }
    }

    suite("Chat AX tracer validation gate：同代只允许一个检查且迟到结果不能误杀新会话") {
        var gate = ChatAXRuntimeValidationGate()
        gate.beginSession()
        guard let firstRequest = gate.beginValidation() else {
            expect(false, "当前 session 的第一次 runtime validation 必须可启动")
            return
        }
        expect(gate.beginValidation() == nil, "在途检查未完成时必须合并后续 timer tick")

        gate.endSession()
        gate.beginSession()
        guard let currentRequest = gate.beginValidation() else {
            expect(false, "新 session 必须能启动自己的 runtime validation")
            return
        }
        expect(
            !gate.finishValidation(firstRequest),
            "上一 session 的迟到结果必须被 generation gate 丢弃")
        expect(
            gate.beginValidation() == nil,
            "迟到旧结果不得错误清除当前 session 的 pending request")
        expect(
            gate.finishValidation(currentRequest),
            "只有当前 generation 的当前 request 可以提交结果")
        expect(gate.beginValidation() != nil, "当前检查完成后下一 timer tick 必须可继续")
    }

    suite("Chat AX tracer validation deadline：并发 producer 只能有一个 winner") {
        let winner = ChatAXRuntimeValidationWinner()
        let winningClaims = ChatAXThreadSafeCounter()
        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            if winner.claim() {
                winningClaims.increment()
            }
        }
        expect(winningClaims.value == 1, "operation 与 timeout 竞态必须恰好提交第一个结果")
        expect(!winner.claim(), "winner 决出后，任何迟到结果都不得覆盖首个结果")
    }

    suite("Chat AX tracer system query gate：所有 session 共用 single-flight lease") {
        let gate = ChatAXSystemQueryWorkerGate.shared
        guard let oldLease = gate.acquire() else {
            expect(false, "空闲 gate 必须允许旧 session 取得 lease")
            return
        }
        expect(gate.acquire() == nil, "旧 worker 持有 lease 时，新入口必须在查询前失败关闭")
        gate.release(oldLease)

        guard let currentLease = gate.acquire() else {
            expect(false, "旧 worker 退出后，新 session 必须能取得新 lease")
            return
        }
        gate.release(oldLease)
        expect(
            gate.acquire() == nil,
            "旧 lease 的迟到 release 不得清掉当前 session 的 lease")
        gate.release(currentLease)
        guard let recoveredLease = gate.acquire() else {
            expect(false, "当前 lease 正常释放后 gate 必须恢复")
            return
        }
        gate.release(recoveredLease)
    }

    suite("Chat AX tracer deferred query gate：contention 合并且不冒充 target drift") {
        var gate = ChatAXDeferredSystemQueryGate()
        expect(
            gate.enqueue(nowMilliseconds: 0, timeoutMilliseconds: 500) == nil,
            "未启动 session 不得积压 AX event")
        gate.beginSession()
        guard
            let first = gate.enqueue(nowMilliseconds: 100, timeoutMilliseconds: 500),
            let coalesced = gate.enqueue(nowMilliseconds: 200, timeoutMilliseconds: 500)
        else {
            expect(false, "活跃 session 必须能建立 deferred query request")
            return
        }
        expect(first == coalesced, "同一 session 的 contention event 必须合并为一次复验")
        expect(gate.hasPendingRequest, "worker busy 时 pending request 必须保持可重试")
        expect(
            gate.decide(
                first,
                nowMilliseconds: 300,
                workerLeaseAvailable: false) == .waiting,
            "同 session worker 正常持 lease 只能等待，不能当成 identity mismatch")
        expect(
            gate.decide(
                first,
                nowMilliseconds: 400,
                workerLeaseAvailable: true) == .ready,
            "lease 释放后合并请求必须只放行一次 exact query")
        expect(
            !gate.hasPendingRequest
                && gate.decide(
                    first,
                    nowMilliseconds: 401,
                    workerLeaseAvailable: true) == .stale,
            "已消费 request 不得 duplicate")

        guard let expiring = gate.enqueue(nowMilliseconds: 1_000, timeoutMilliseconds: 500)
        else {
            expect(false, "ready 后必须允许下一次独立 event")
            return
        }
        expect(
            gate.decide(
                expiring,
                nowMilliseconds: 1_500,
                workerLeaseAvailable: false) == .expired,
            "超过有界等待仍拿不到 lease 必须明确过期")
        gate.endSession()
        expect(
            gate.decide(
                expiring,
                nowMilliseconds: 1_501,
                workerLeaseAvailable: true) == .stale,
            "stop/restart 后旧 generation 的 deferred event 必须丢弃")
    }

    await suite("Chat AX tracer deadline：调用者预先取消时绝不启动 detached query") {
        let permission = DispatchSemaphore(value: 0)
        let operationStarts = ChatAXThreadSafeCounter()
        let cancelledTask = Task.detached {
            _ = chatAXBlockingValidationSample(permission)
            return await ChatAXRuntimeValidationDeadline.run(
                timeoutNanoseconds: 500_000_000
            ) {
                operationStarts.increment()
                return 17
            }
        }
        cancelledTask.cancel()
        permission.signal()
        expect(
            await cancelledTask.value == .cancelled,
            "预先取消的 caller 必须显式返回 cancelled")
        expect(operationStarts.value == 0, "stop 后尚未启动的旧 task 不得发出首次系统查询")

        let systemGate = ChatAXSystemQueryWorkerGate.shared
        guard let pendingLease = systemGate.acquire() else {
            expect(false, "预取消路径不得遗留 shared system-query lease")
            return
        }
        let pendingControl = ChatAXRuntimeValidationCancellationGate(
            workerGate: systemGate)
        expect(pendingControl.bind(pendingLease), "新取得的 lease 必须先进入 pending")
        pendingControl.cancel()
        expect(
            !pendingControl.beginOperation(),
            "cancel 与 detached start 的锁内仲裁必须让先发生的 cancel 胜出")
        guard let replacementLease = systemGate.acquire() else {
            expect(false, "pending operation 被取消时必须同步释放尚未使用的 lease")
            return
        }
        systemGate.release(replacementLease)

        guard let runningLease = systemGate.acquire() else {
            expect(false, "pending cancel 释放后必须能开始 running 对照")
            return
        }
        let runningControl = ChatAXRuntimeValidationCancellationGate(
            workerGate: systemGate)
        expect(
            runningControl.bind(runningLease) && runningControl.beginOperation(),
            "worker 开始前必须原子接管 lease")
        runningControl.cancel()
        expect(
            systemGate.acquire() == nil,
            "已经 running 的 worker 被取消时仍必须持 lease 到真实退出")
        runningControl.finishOperation()
        guard let afterRunningLease = systemGate.acquire() else {
            expect(false, "running worker 真实退出时必须释放 lease")
            return
        }
        systemGate.release(afterRunningLease)
    }

    await suite("Chat AX tracer validation deadline：阻塞 sampler 超时且即时结果直达") {
        let blocker = DispatchSemaphore(value: 0)
        let blockerStarted = DispatchSemaphore(value: 0)
        let blockerFinished = DispatchSemaphore(value: 0)
        let postCancellationPhases = ChatAXThreadSafeCounter()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            blocker.signal()
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let timedOut = await ChatAXRuntimeValidationDeadline.run(
            timeoutNanoseconds: 20_000_000
        ) {
            blockerStarted.signal()
            let sample = chatAXBlockingValidationSample(blocker)
            defer { blockerFinished.signal() }
            guard !Task.isCancelled else { return sample }
            postCancellationPhases.increment()
            return sample
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        expect(timedOut == .timedOut, "不可取消的阻塞 sampler 必须由 deadline fail closed")
        expect(elapsed < 0.5, "deadline 必须先于一秒 fallback 返回，不能永久占住 validation gate")
        expect(
            chatAXSemaphoreWasSignaled(blockerStarted, timeout: .now()),
            "测试必须证明超时发生时旧 worker 正阻塞在 sampler 内")

        let followerStarts = ChatAXThreadSafeCounter()
        let refusedFollower = await ChatAXRuntimeValidationDeadline.run(
            timeoutNanoseconds: 500_000_000
        ) {
            followerStarts.increment()
            return 9
        }
        expect(
            refusedFollower == .deferred && followerStarts.value == 0,
            "旧同步 worker 未退出前，新 validation 必须延后且不得堆叠第二个 worker")

        blocker.signal()
        expect(
            chatAXSemaphoreWasSignaled(blockerFinished, timeout: .now() + 1),
            "解除阻塞后，已取消 worker 必须及时退出")
        expect(
            postCancellationPhases.value == 0,
            "timeout 后恢复的 worker 必须在进入下一 sampler phase 前停止")

        var recovered: Int?
        for _ in 0..<100 where recovered == nil {
            let outcome = await ChatAXRuntimeValidationDeadline.run(
                timeoutNanoseconds: 500_000_000
            ) {
                11
            }
            if case .completed(let value) = outcome {
                recovered = value
            }
            if recovered == nil {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        expect(recovered == 11, "旧 worker 真实退出后，后续 session 必须可以恢复复验")

        for expected in 0..<100 {
            let sequential = await ChatAXRuntimeValidationDeadline.run(
                timeoutNanoseconds: 500_000_000
            ) {
                expected
            }
            expect(
                sequential == .completed(expected),
                "已完成 worker 必须在交付结果前释放 lease，连续调用不得瞬时假拒绝")
        }

        let immediate = await ChatAXRuntimeValidationDeadline.run(
            timeoutNanoseconds: 500_000_000
        ) {
            11
        }
        expect(
            immediate == .completed(11),
            "deadline seam 必须原样提交及时完成的 sampler 结果")
        let disabled = await ChatAXRuntimeValidationDeadline.run(timeoutNanoseconds: 0) {
            13
        }
        expect(disabled == .timedOut, "零 deadline 必须在启动 sampler 前失败关闭")
    }

    suite("Chat AX tracer surface canonicalization：固定 anchor vector 且任一结构漂移改摘要") {
        guard
            let facts = ChatAXSurfaceAnchorFacts(
                windowRole: "AXWindow",
                windowSubrole: "AXStandardWindow",
                anchorRole: "AXGroup",
                anchorSubrole: nil,
                anchorIdentifier: "chat-surface-root",
                anchorDepth: 1),
            let changedIdentifier = ChatAXSurfaceAnchorFacts(
                windowRole: "AXWindow",
                windowSubrole: "AXStandardWindow",
                anchorRole: "AXGroup",
                anchorSubrole: nil,
                anchorIdentifier: "codex-surface-root",
                anchorDepth: 1),
            let changedDepth = ChatAXSurfaceAnchorFacts(
                windowRole: "AXWindow",
                windowSubrole: "AXStandardWindow",
                anchorRole: "AXGroup",
                anchorSubrole: nil,
                anchorIdentifier: "chat-surface-root",
                anchorDepth: 2)
        else {
            expect(false, "固定 surface anchor fixture 必须合法")
            return
        }

        let signature = ChatAXSurfaceSignature.v1(anchorFacts: facts)
        expect(
            signature.rawValue
                == "858109d90671d7f20a24a860369330d2ed44786629f63cb5fd2e017b43653d22",
            "固定 typed facts 必须映射到审查后的 v1 literal，不得由测试重算生产结果")
        expect(
            ChatAXSurfaceSignature.v1(anchorFacts: changedIdentifier) != signature
                && ChatAXSurfaceSignature.v1(anchorFacts: changedDepth) != signature,
            "identifier 或结构深度任一漂移都必须改变摘要")
        let verifiedSurface = ChatAXSurfaceVerifier.verifyChat(
            anchorFacts: facts,
            allowedSignatures: [signature])
        expect(
            verifiedSurface?.signature == signature,
            "只有观察 facts 生成的 exact digest 才能取得 verified Chat surface")
        expect(
            ChatAXSurfaceVerifier.verifyChat(
                anchorFacts: changedIdentifier,
                allowedSignatures: [signature]) == nil,
            "Work/Codex/unknown anchor 不得借用 allowlist 中任意 Chat digest")
        expect(
            ChatAXSurfaceVerifier.verifyChat(
                anchorFacts: facts,
                allowedSignatures: []) == nil,
            "没有审查后的 Chat digest 时必须 fail closed")
        if let verifiedSurface {
            let observedIdentity = ChatAXTargetIdentity.observedChatGPTDesktopAX(
                bundleIdentifier: "com.example.chat.fixture",
                codeSignature: ChatAXCodeSignature(
                    teamIdentifier: "TEAMFIXTURE",
                    signingIdentifier: "com.example.chat.fixture",
                    cdHash: "fixture-cdhash-001"),
                shortVersion: "1.2.3",
                build: "456",
                frameworks: [
                    ChatAXFrameworkIdentity(
                        name: "FixtureWeb.framework", shortVersion: "7.8.9", build: "89")
                ],
                architecture: .arm64,
                verifiedSurface: verifiedSurface)
            expect(
                observedIdentity.surface == .chatGPTDesktopAX
                    && observedIdentity.surfaceSignature == signature,
                "受限 factory 必须把 verified wrapper 唯一映射为 Chat surface 与原摘要")
        }
        expect(
            ChatAXSurfaceAnchorFacts(
                windowRole: " AXWindow",
                windowSubrole: nil,
                anchorRole: "AXGroup",
                anchorSubrole: nil,
                anchorIdentifier: "chat-surface-root",
                anchorDepth: 1) == nil,
            "前后空白不得被 trim 后悄悄合并成另一个结构事实")
        expect(
            ChatAXSurfaceAnchorFacts(
                windowRole: "AXWindow",
                windowSubrole: nil,
                anchorRole: "AXGroup",
                anchorSubrole: nil,
                anchorIdentifier: "",
                anchorDepth: 1) == nil,
            "空 identifier 不足以独立识别 surface")
        expect(
            ChatAXSurfaceAnchorFacts(
                windowRole: "AXWindow",
                windowSubrole: nil,
                anchorRole: "AXGroup",
                anchorSubrole: nil,
                anchorIdentifier: "chat-surface-root",
                anchorDepth: 0) == nil,
            "anchor 必须是窗口下的有界 descendant")
    }

    suite("Chat AX tracer 属性边界：只暴露审查后的结构/状态元数据") {
        let allowedNames = Set(ChatAXApprovedAttribute.allCases.map(\.rawValue))
        expect(
            allowedNames == [
                "AXRole", "AXSubrole", "AXIdentifier", "AXEnabled", "AXSelected",
                "AXFocused", "AXWindowNumber",
            ],
            "属性 allowlist 必须是固定、可审查的封闭集合")

        let forbiddenNames = [
            "AXValue", "AXTitle", "AXHelp", "AXDescription", "AXSelectedText",
            "AXClipboard", "AXChildren",
        ]
        for forbiddenName in forbiddenNames {
            expect(
                !allowedNames.contains(forbiddenName),
                "可能携带正文或完整 UI tree 的属性 \(forbiddenName) 必须不可请求")
        }
        expect(
            Set(ChatAXApprovedRelation.allCases.map(\.rawValue))
                == ["AXFocusedUIElement", "AXFocusedWindow", "AXParent"],
            "surface traversal 必须恰好只允许 focus/window/parent 三种关系")

        let signal = ChatAXStructuralSignal(
            sequence: 7,
            elapsedMilliseconds: 125,
            windowOrdinal: 2,
            kind: .generationControl(isVisible: true))
        expect(signal.kind.requiredAttributes == [.identifier, .enabled], "信号只声明必要属性")
        expect(signal.sequence == 7 && signal.windowOrdinal == 2, "信号只携带时序与结构编号")
        expect(
            ChatAXStructuralSignalKind.applicationExited.requiredAttributes.isEmpty,
            "application exit 来自 lifecycle notification，不得声明 destroyed-element 查询")
        expect(
            ChatAXStructuralSignalKind.windowClosed.requiredAttributes == [.windowNumber],
            "仍存活的 window close 信号可以保留 window ordinal 契约")
    }

    suite("Chat AX tracer 候选检测：脱敏正控恰好一次 submit/end，负控与重复零事件") {
        var detector = ChatAXCandidateDetector(
            submitAssociationMilliseconds: 1_000,
            completionStabilityMilliseconds: 500)
        let positiveFixture = [
            ChatAXStructuralSignal(
                sequence: 1, elapsedMilliseconds: 0, windowOrdinal: 1,
                kind: .unrelatedStructureChanged),
            ChatAXStructuralSignal(
                sequence: 2, elapsedMilliseconds: 100, windowOrdinal: 1,
                kind: .composerSubmitted),
            ChatAXStructuralSignal(
                sequence: 3, elapsedMilliseconds: 150, windowOrdinal: 1,
                kind: .composerSubmitted),
            ChatAXStructuralSignal(
                sequence: 4, elapsedMilliseconds: 200, windowOrdinal: 1,
                kind: .generationControl(isVisible: true)),
            ChatAXStructuralSignal(
                sequence: 4, elapsedMilliseconds: 200, windowOrdinal: 1,
                kind: .generationControl(isVisible: true)),
            ChatAXStructuralSignal(
                sequence: 5, elapsedMilliseconds: 300, windowOrdinal: 1,
                kind: .assistantRegion(structureRevision: 10, isStable: true)),
            ChatAXStructuralSignal(
                sequence: 6, elapsedMilliseconds: 350, windowOrdinal: 1,
                kind: .generationControl(isVisible: false)),
            ChatAXStructuralSignal(
                sequence: 7, elapsedMilliseconds: 600, windowOrdinal: 1,
                kind: .unrelatedStructureChanged),
            ChatAXStructuralSignal(
                sequence: 8, elapsedMilliseconds: 700, windowOrdinal: 1,
                kind: .assistantRegion(structureRevision: 10, isStable: true)),
            ChatAXStructuralSignal(
                sequence: 9, elapsedMilliseconds: 850, windowOrdinal: 1,
                kind: .unrelatedStructureChanged),
            ChatAXStructuralSignal(
                sequence: 10, elapsedMilliseconds: 900, windowOrdinal: 1,
                kind: .stabilityCheckpoint),
            ChatAXStructuralSignal(
                sequence: 11, elapsedMilliseconds: 950, windowOrdinal: 1,
                kind: .generationControl(isVisible: false)),
        ]
        let outcomes = positiveFixture.map { detector.consume($0) }
        let events = outcomes.flatMap(\.semanticEvents)
        expect(events.map(\.event) == [.taskStart, .stop], "正控只能产生一次 submit/end")
        expect(events.map(\.signalSequence) == [4, 10], "无关结构不能确认 end，稳定检查才可以")
        expect(!outcomes[4].acceptedSignal, "重复 sequence 必须由 detector 唯一入口拒绝")

        var negativeDetector = ChatAXCandidateDetector()
        let negativeFixture = [
            ChatAXStructuralSignal(
                sequence: 1, elapsedMilliseconds: 0, windowOrdinal: 3,
                kind: .generationControl(isVisible: true)),
            ChatAXStructuralSignal(
                sequence: 2, elapsedMilliseconds: 100, windowOrdinal: 3,
                kind: .generationControl(isVisible: false)),
            ChatAXStructuralSignal(
                sequence: 3, elapsedMilliseconds: 800, windowOrdinal: 3,
                kind: .stabilityCheckpoint),
            ChatAXStructuralSignal(
                sequence: 4, elapsedMilliseconds: 900, windowOrdinal: 3,
                kind: .unrelatedStructureChanged),
        ]
        expect(
            negativeFixture.flatMap { negativeDetector.consume($0).semanticEvents }.isEmpty,
            "没有提交关联的结构变化不得猜成 semantic event")

        var epochDetector = ChatAXCandidateDetector(
            submitAssociationMilliseconds: 1_000,
            completionStabilityMilliseconds: 500)
        let staleEpochFixture = [
            ChatAXStructuralSignal(
                sequence: 1, elapsedMilliseconds: 0, windowOrdinal: 8,
                kind: .assistantRegion(structureRevision: 99, isStable: true)),
            ChatAXStructuralSignal(
                sequence: 2, elapsedMilliseconds: 100, windowOrdinal: 8,
                kind: .composerSubmitted),
            ChatAXStructuralSignal(
                sequence: 3, elapsedMilliseconds: 150, windowOrdinal: 8,
                kind: .generationControl(isVisible: true)),
            ChatAXStructuralSignal(
                sequence: 4, elapsedMilliseconds: 200, windowOrdinal: 8,
                kind: .generationControl(isVisible: false)),
            ChatAXStructuralSignal(
                sequence: 5, elapsedMilliseconds: 800, windowOrdinal: 8,
                kind: .stabilityCheckpoint),
        ]
        let staleEpochEvents = staleEpochFixture.flatMap {
            epochDetector.consume($0).semanticEvents
        }
        expect(
            staleEpochEvents.map(\.event) == [.taskStart],
            "旧 assistant stable 事实不得替新 generation 伪造 stop")
        let currentEpochEvents = [
            ChatAXStructuralSignal(
                sequence: 6, elapsedMilliseconds: 900, windowOrdinal: 8,
                kind: .assistantRegion(structureRevision: 100, isStable: true)),
            ChatAXStructuralSignal(
                sequence: 7, elapsedMilliseconds: 1_400, windowOrdinal: 8,
                kind: .stabilityCheckpoint),
            ChatAXStructuralSignal(
                sequence: 8, elapsedMilliseconds: 1_500, windowOrdinal: 8,
                kind: .stabilityCheckpoint),
        ].flatMap { epochDetector.consume($0).semanticEvents }
        expect(
            currentEpochEvents.map(\.event) == [.stop],
            "本 epoch 新 assistant stable 事实必须仍只确认一次 stop")

        var staleEpochState = ChatAXAssistantEpochState(
            isStable: true,
            structureRevision: 76,
            completionCandidateAt: 880)
        staleEpochState.resetForNewSubmit()
        expect(
            staleEpochState == ChatAXAssistantEpochState(),
            "compiled epoch seam 必须一次清空 stable、revision 与非空 completion candidate")

        var epochProbe = ChatAXCandidateDetector()
        _ = epochProbe.consume(
            ChatAXStructuralSignal(
                sequence: 1, elapsedMilliseconds: 0, windowOrdinal: 12,
                kind: .assistantRegion(structureRevision: 77, isStable: true)))
        expect(
            epochProbe.assistantEpochState(forWindowOrdinal: 12)
                == ChatAXAssistantEpochState(
                    isStable: true,
                    structureRevision: 77,
                    completionCandidateAt: nil),
            "compiled detector seam 必须暴露旧 assistant epoch 的真实 typed 状态")
        _ = epochProbe.consume(
            ChatAXStructuralSignal(
                sequence: 2, elapsedMilliseconds: 10, windowOrdinal: 12,
                kind: .composerSubmitted))
        expect(
            epochProbe.assistantEpochState(forWindowOrdinal: 12)
                == ChatAXAssistantEpochState(),
            "新 submit 必须通过 production transition 清空 stable、revision 与 candidate")
    }

    suite("Chat AX tracer 生命周期：默认关闭，且只在 GUI+显式启用+allowlist 命中时运行") {
        let allowedIdentity = chatAXIdentity()
        let observer = ChatAXFixtureObserver(observedTarget: chatAXObservedTarget())
        let tracer = ChatAXTracerSession(
            allowlist: ChatAXVersionAllowlist(identities: [allowedIdentity]),
            observer: observer)

        expect(!tracer.isRunning && observer.startCount == 0, "构造 tracer 不得隐式启动 observer")
        expect(
            tracer.beginExplicitTrace(scenarioNumber: 1) == .refused(.guiNotAlive),
            "GUI 未存活时即使显式调用也必须 fail closed")

        tracer.guiDidBecomeAlive()
        expect(observer.startCount == 0, "普通、后台或 harness GUI 启动本身都不得启动 observer")
        expect(
            tracer.beginExplicitTrace(scenarioNumber: -1) == .refused(.invalidScenario),
            "负场景编号必须报告输入错误，不得伪装成身份失配")
        for inspectionFailure in [
            ChatAXTargetInspectionFailure.targetUnavailable,
            .ambiguousTargets,
            .identityUnreadable,
        ] {
            observer.inspectionFailure = inspectionFailure
            expect(
                tracer.beginExplicitTrace(scenarioNumber: 1)
                    == .refused(.targetInspectionFailed(inspectionFailure)),
                "target inspection failure 必须原样保留：\(inspectionFailure)")
        }
        observer.inspectionFailure = nil
        observer.setObservedTarget(
            chatAXObservedTarget(
                identity: chatAXIdentity(build: "mismatch"))
        )
        expect(
            tracer.beginExplicitTrace(scenarioNumber: 1) == .refused(.allowlistMismatch),
            "身份失配不得触碰 observer")
        observer.setObservedTarget(
            chatAXObservedTarget(
                identity: chatAXIdentity(surface: .codex))
        )
        expect(
            tracer.beginExplicitTrace(scenarioNumber: 1) == .refused(.allowlistMismatch),
            "同 PID 的 Codex surface 负控不得被重新标成 Chat")
        observer.setObservedTarget(
            chatAXObservedTarget(
                identity: chatAXIdentity(surfaceSignature: chatAXSurfaceSignature("b")))
        )
        expect(
            tracer.beginExplicitTrace(scenarioNumber: 1) == .refused(.allowlistMismatch),
            "同 PID、版本与 Chat 常量但 Work/Codex 摘要失配时仍必须 fail closed")
        observer.observedTargets = []
        expect(
            tracer.beginExplicitTrace(scenarioNumber: 1) == .refused(.allowlistMismatch),
            "surface facts 可读但没有 verified Chat 候选时必须归类 allowlist mismatch")
        observer.hasUnreadableProjection = true
        expect(
            tracer.beginExplicitTrace(scenarioNumber: 1)
                == .refused(.targetInspectionFailed(.identityUnreadable)),
            "没有 exact 候选且存在真实不可读 projection 时必须保留 identityUnreadable")
        observer.observedTargets = [
            chatAXObservedTarget(identity: chatAXIdentity(build: "mismatch"))
        ]
        expect(
            tracer.beginExplicitTrace(scenarioNumber: 1)
                == .refused(.targetInspectionFailed(.identityUnreadable)),
            "非 exact 候选不得掩盖另一个可能匹配但不可读的 projection")
        expect(observer.startCount == 0, "allowlist 失败必须在 observer 边界之前返回")

        observer.hasUnreadableProjection = true
        observer.observedTargets = [
            chatAXObservedTarget(identity: chatAXIdentity(build: "mismatch")),
            chatAXObservedTarget(),
        ]
        expect(
            tracer.beginExplicitTrace(scenarioNumber: 1) == .started,
            "同一 PID 的多个 framework projection 中必须选择完整 exact match")
        expect(tracer.isRunning && observer.startCount == 1, "显式启用必须只启动一次 observer")
        expect(
            observer.startedTarget == chatAXObservedTarget()
                && observer.approvedAttributes == Set(ChatAXApprovedAttribute.allCases),
            "observer 必须绑定独立检查得到的 PID/身份并只接收批准属性")
        expect(
            observer.inspectedRequirements
                == ChatAXVersionAllowlist(identities: [allowedIdentity]).inspectionRequirements,
            "observer inspection 必须收到精确 Chat surface 摘要，不能由 adapter 自行补常量")
        expect(
            tracer.beginExplicitTrace(scenarioNumber: 2) == .refused(.alreadyRunning),
            "运行中重复显式启动必须保留 alreadyRunning 语义")
        expect(
            tracer.isRunning && observer.startCount == 1 && observer.stopCount == 0,
            "重复启动不得新建 observer，也不得停止当前 session")
        tracer.revalidateTarget()
        expect(
            tracer.isRunning && observer.stopCount == 0,
            "原 exact projection 仍存在时，无关 unreadable projection 不得误停 session")
        observer.targetRevalidationOutcomeOverride = .deferred
        tracer.revalidateTarget()
        expect(
            tracer.isRunning && observer.stopCount == 0,
            "另一个同 session 系统查询持 lease 时，同步复验必须 deferred，不能伪造 drift")
        observer.targetRevalidationOutcomeOverride = nil
        observer.hasUnreadableProjection = false

        observer.setObservedTarget(
            chatAXObservedTarget(
                identity: chatAXIdentity(surfaceSignature: chatAXSurfaceSignature("b")))
        )
        tracer.revalidateTarget()
        expect(!tracer.isRunning && observer.stopCount == 1, "运行中 surface 失配必须确定 stop")
        observer.invalidateTarget()
        tracer.revalidateTarget()
        expect(observer.stopCount == 1, "同一次 surface 漂移只能触发一次 stop")

        observer.setObservedTarget(chatAXObservedTarget())
        expect(
            tracer.beginExplicitTrace(scenarioNumber: 2) == .started,
            "失配停止后必须再次显式调用，不能自动恢复")
        observer.invalidateTarget()
        expect(!tracer.isRunning && observer.stopCount == 2, "observer 报告目标失效必须确定 stop")
        expect(
            tracer.beginExplicitTrace(scenarioNumber: 3) == .started,
            "目标失效后也必须重新显式启用")
        tracer.guiWillTerminate()
        expect(!tracer.isRunning && observer.stopCount == 3, "GUI 退出必须确定 stop")

        let failedObserver = ChatAXFixtureObserver(
            observedTarget: chatAXObservedTarget(),
            startSucceeds: false)
        let failedTracer = ChatAXTracerSession(
            allowlist: ChatAXVersionAllowlist(identities: [allowedIdentity]),
            observer: failedObserver)
        failedTracer.guiDidBecomeAlive()
        expect(
            failedTracer.beginExplicitTrace(scenarioNumber: 4) == .refused(.observerStartFailed),
            "observer 拒绝启动必须明确失败")
        expect(
            !failedTracer.isRunning && failedObserver.stopCount == 1,
            "observer 启动失败也必须防御性 stop，避免部分注册残留")
    }

    suite("Chat AX tracer debug 启动：三项显式输入缺一不可，普通环境保持关闭") {
        let identity = chatAXIdentity()
        let encoded = try! JSONEncoder().encode([identity])
        let allowlistJSON = String(data: encoded, encoding: .utf8)!
        expect(ChatAXDebugLaunchRequest(environment: [:]) == nil, "普通 app/harness 环境不得启用")
        expect(
            ChatAXDebugLaunchRequest(
                environment: ["CLAUDIO_CHAT_AX_TRACER_EXPLICIT_ENABLE": "1"]) == nil,
            "只有 enable 标志仍不得启用")
        expect(
            ChatAXDebugLaunchRequest(
                environment: [
                    "CLAUDIO_CHAT_AX_TRACER_EXPLICIT_ENABLE": "1",
                    "CLAUDIO_CHAT_AX_TRACER_SCENARIO": "-1",
                    "CLAUDIO_CHAT_AX_TRACER_ALLOWLIST_JSON": allowlistJSON,
                ]) == nil,
            "负场景编号必须 fail closed")
        expect(
            ChatAXDebugLaunchRequest(
                environment: [
                    "CLAUDIO_CHAT_AX_TRACER_EXPLICIT_ENABLE": "1",
                    "CLAUDIO_CHAT_AX_TRACER_SCENARIO": "16",
                    "CLAUDIO_CHAT_AX_TRACER_ALLOWLIST_JSON": "[]",
                ]) == nil,
            "空 allowlist 必须 fail closed")

        let request = ChatAXDebugLaunchRequest(
            environment: [
                "CLAUDIO_CHAT_AX_TRACER_EXPLICIT_ENABLE": "1",
                "CLAUDIO_CHAT_AX_TRACER_SCENARIO": "16",
                "CLAUDIO_CHAT_AX_TRACER_ALLOWLIST_JSON": allowlistJSON,
            ])
        expect(request?.scenarioNumber == 16, "显式场景编号必须逐字解析")
        expect(request?.allowlist.allows(identity) == true, "显式 allowlist 必须保留精确身份")
    }

    suite("Chat AX tracer release boundary：Core 只在 DEBUG 编译且无 public API") {
        guard
            let rawCore = chatAXSource(
                "gui/Sources/ClaudioGUICore/ChatAXTracer.swift")
        else {
            expect(false, "必须能读取 tracer Core source 才能验证 release 编译边界")
            return
        }
        let trimmedCore = rawCore.trimmingCharacters(in: .whitespacesAndNewlines)
        let scannedCore = strippingComments(rawCore)
        let core = scannedCore.codeWithoutStringLiterals
        expect(
            trimmedCore.hasPrefix("#if DEBUG\n") && trimmedCore.hasSuffix("#endif"),
            "完整 tracer Core 必须由单一 DEBUG 编译边界包围")
        expect(
            scannedCore.unmodeledConstructs.isEmpty
                && !core
                    .split(whereSeparator: { !$0.isLetter })
                    .contains("public"),
            "Debug-only tracer 的跨 target API 必须收窄为 package")
        guard
            let deadlineRegion = chatAXBracedDeclarationRegion(
                "package enum ChatAXRuntimeValidationDeadline {", in: core),
            let cancellationGateRegion = chatAXBracedDeclarationRegion(
                "package final class ChatAXRuntimeValidationCancellationGate", in: core)
        else {
            expect(false, "必须能定位 runtime deadline 的并发仲裁实现")
            return
        }
        let deadlineUsesFirstWinner: (String) -> Bool = { region in
            region.contains(".bufferingOldest(1)")
                && !region.contains(".bufferingNewest(")
                && region.components(separatedBy: "winner.claim()").count - 1 == 2
                && region.contains("workerGate.acquire()")
                && region.contains("cancellationGate.bind(workerLease)")
                && region.contains("defer { cancellationGate.finishOperation() }")
                && region.components(separatedBy: "cancellationGate.cancel()").count - 1
                    == 4
                && !region.contains("workerGate.release(workerLease)")
                && region.contains("return Task.isCancelled ? .cancelled : .deferred")
                && region.contains("withTaskCancellationHandler")
                && region.contains("cancellationGate.beginOperation()")
                && region.contains("onCancel:")
                && region.contains("!Task.isCancelled")
        }
        expect(
            deadlineUsesFirstWinner(deadlineRegion),
            "operation/timeout 只能由第一个 winner 提交，后到结果不得覆盖")
        let pendingLeaseCancellationIsImmediate: (String) -> Bool = { region in
            region.contains("case .pending(let lease):")
                && region.contains("state = .terminal")
                && region.contains("workerGate.release(leaseToRelease)")
                && region.contains("case .running(let lease) = state")
                && region.contains("workerGate.release(lease)")
        }
        expect(
            pendingLeaseCancellationIsImmediate(cancellationGateRegion),
            "未开始 worker 的 cancel/timeout 必须同步释放 lease，running worker 才延后释放")
        let leakedPendingLeaseMutation = cancellationGateRegion.replacingOccurrences(
            of: "workerGate.release(leaseToRelease)",
            with: "_ = leaseToRelease")
        expect(
            !pendingLeaseCancellationIsImmediate(leakedPendingLeaseMutation),
            "pending worker 从未启动也不得把 lease 遗留给未来 executor 调度")
        let newestBufferMutation = deadlineRegion.replacingOccurrences(
            of: ".bufferingOldest(1)",
            with: ".bufferingNewest(1)")
        expect(
            !deadlineUsesFirstWinner(newestBufferMutation),
            "deadline source gate 必须拒绝恢复后到结果覆盖首个结果的 buffer")
        let missingWorkerLeaseMutation = deadlineRegion.replacingOccurrences(
            of: "workerGate.acquire()",
            with: "workerGate.uncheckedLease()")
        expect(
            !deadlineUsesFirstWinner(missingWorkerLeaseMutation),
            "deadline source gate 必须拒绝为旧阻塞 sampler 堆叠新 worker")
        let missingCallerCancellationMutation = deadlineRegion.replacingOccurrences(
            of: "cancellationGate.beginOperation()",
            with: "true")
        expect(
            !deadlineUsesFirstWinner(missingCallerCancellationMutation),
            "deadline source gate 必须拒绝预取消 caller 启动 detached query")
    }

    suite("Chat AX tracer 系统边界：只用有界非正文 AX 事实且从不弹权限") {
        guard
            let rawRuntime = chatAXSource(
                "gui/Sources/ClaudioGUI/SystemChatAXTraceObserver.swift")
        else {
            expect(false, "必须存在可编译的 GUI-only AX observer")
            return
        }
        let scannedRuntime = strippingComments(rawRuntime)
        guard scannedRuntime.unmodeledConstructs.isEmpty else {
            expect(false, "observer 源码出现 scanner 无法建模的构造，不能继续 fail-open 检查")
            return
        }
        let runtime = scannedRuntime.codeWithoutStringLiterals
        expect(runtime.contains("AXObserverCreate("), "真实 tracer 必须绑定 AXObserver")
        expect(runtime.contains("AXIsProcessTrusted()"), "只能静默检查现有 AX 权限")
        expect(
            chatAXLowLevelAttributeQueriesAreClosed(rawRuntime),
            "每个低层 AX attribute query 都必须且只能位于 typed reader")
        let rawTitleOutsideReaderMutation = rawRuntime.replacingOccurrences(
            of: "\n#endif",
            with: """

                private func leakedTitle(_ element: AXUIElement) {
                    var value: CFTypeRef?
                    AXUIElementCopyAttributeValue(element, "AXTitle" as CFString, &value)
                }
                #endif
                """)
        expect(
            !chatAXLowLevelAttributeQueriesAreClosed(rawTitleOutsideReaderMutation),
            "reader 外直接读取 AXTitle 的可编译 mutation 必须让隐私 gate 变红")
        let rawTitleInsideReaderMutation = rawRuntime.replacingOccurrences(
            of: "(relation as ChatAXApprovedRelation).rawValue as CFString",
            with: "\"AXTitle\" as CFString")
        expect(
            !chatAXLowLevelAttributeQueriesAreClosed(rawTitleInsideReaderMutation),
            "typed reader 内也不得把封闭 relation 换成 raw AXTitle 字符串")
        let shadowedTypedParameterMutation =
            rawRuntime
            .replacingOccurrences(
                of: "private struct SystemChatAXAttributeReader {",
                with: """
                    private struct ChatAXUnapprovedAttribute { let rawValue: String }

                    private struct SystemChatAXAttributeReader {
                    """
            )
            .replacingOccurrences(
                of: "        var value: CFTypeRef?\n"
                    + "        let result = AXUIElementCopyAttributeValue(",
                with: "        let attribute = ChatAXUnapprovedAttribute(rawValue: \"AXTitle\")\n"
                    + "        var value: CFTypeRef?\n"
                    + "        let result = AXUIElementCopyAttributeValue("
            )
            .replacingOccurrences(
                of: "(attribute as ChatAXApprovedAttribute).rawValue",
                with: "attribute.rawValue")
        expect(
            !chatAXLowLevelAttributeQueriesAreClosed(shadowedTypedParameterMutation),
            "可编译的局部 shadow mutation 不得把 typed 参数悄悄换成 AXTitle")
        for prohibitedAPI in [
            "AXUIElementCopyMultipleAttributeValues",
            "AXUIElementCopyParameterizedAttributeValue",
        ] {
            let expandedQueryMutation = rawRuntime.replacingOccurrences(
                of: "AXUIElementCopyAttributeValue",
                with: prohibitedAPI)
            expect(
                !chatAXLowLevelAttributeQueriesAreClosed(expandedQueryMutation),
                "隐私 gate 必须明确拒绝 \(prohibitedAPI)")
        }
        expect(
            runtime.contains("_ attribute: ChatAXApprovedAttribute")
                && runtime.contains(
                    "(attribute as ChatAXApprovedAttribute).rawValue as CFString"),
            "真实属性读取器必须只接受封闭枚举，不能接受任意 AX 属性名")
        expect(
            !runtime.contains("AXIsProcessTrustedWithOptions"),
            "spike 不得触发生产权限提示")
        expect(
            runtime.contains("ChatAXApprovedRelation")
                && runtime.contains("focusedUIElement")
                && runtime.contains("focusedWindow")
                && runtime.contains("parent"),
            "surface 读取只能沿封闭的 focus/window/parent 关系")
        expect(
            runtime.contains("maximumAnchorDepth")
                && runtime.contains("ChatAXSurfaceVerifier.verifyChat("),
            "surface 检查必须有界，并通过 typed exact verifier 命中摘要")
        for prohibitedConstant in [
            "kAXValueAttribute", "kAXTitleAttribute", "kAXHelpAttribute",
            "kAXDescriptionAttribute", "kAXSelectedTextAttribute", "kAXChildrenAttribute",
        ] {
            expect(
                !runtime.contains(prohibitedConstant),
                "真实读取边界禁止出现 \(prohibitedConstant)")
        }
        guard
            let codeReaderTypeRegion = chatAXBracedDeclarationRegion(
                "private enum SystemChatAXCodeIdentityReader", in: runtime),
            let coherentCodeRegion = chatAXFunctionRegion(
                "static func coherentSnapshot(", in: codeReaderTypeRegion),
            let runningCodeRegion = chatAXFunctionRegion(
                "static func runningRuntimeFacts(", in: codeReaderTypeRegion),
            let dynamicCodeRegion = chatAXFunctionRegion(
                "private static func dynamicCode(", in: codeReaderTypeRegion),
            let processIncarnationRegion = chatAXFunctionRegion(
                "static func currentProcessIncarnation(", in: codeReaderTypeRegion),
            let normalizedPathRegion = chatAXFunctionRegion(
                "static func normalizedPath(", in: codeReaderTypeRegion),
            let dynamicSigningRegion = chatAXFunctionRegion(
                "private static func signingFacts(\n"
                    + "        forDynamicCode",
                in: codeReaderTypeRegion),
            let importedSigningRegion = chatAXFunctionRegion(
                "private static func signingFacts(\n"
                    + "        forImportedCode",
                in: codeReaderTypeRegion),
            let budgetTypeRegion = chatAXBracedDeclarationRegion(
                "private final class SystemChatAXReadBudget", in: runtime),
            let attributeReaderTypeRegion = chatAXBracedDeclarationRegion(
                "private struct SystemChatAXAttributeReader", in: runtime),
            let surfaceReaderTypeRegion = chatAXBracedDeclarationRegion(
                "private struct SystemChatAXSurfaceSignatureReader", in: runtime),
            let runtimeSamplerTypeRegion = chatAXBracedDeclarationRegion(
                "private enum SystemChatAXRuntimeSampler", in: runtime),
            let observerTypeRegion = chatAXBracedDeclarationRegion(
                "final class SystemChatAXTraceObserver: ChatAXTraceObserving", in: runtime),
            let inspectionRegion = chatAXFunctionRegion(
                "func inspectTarget(", in: observerTypeRegion),
            let identityRegion = chatAXFunctionRegion(
                "private func inspectIdentities(", in: observerTypeRegion),
            let frameworkSetRegion = chatAXFunctionRegion(
                "private func inspectFrameworkSet(", in: observerTypeRegion),
            let stableFrameworkSetRegion = chatAXFunctionRegion(
                "private func inspectStableFrameworkSet(", in: observerTypeRegion),
            let frameworkIdentityRegion = chatAXFunctionRegion(
                "private func inspectFrameworkIdentity(", in: observerTypeRegion),
            let revalidationRegion = chatAXFunctionRegion(
                "private func surfaceStillMatches(\n"
                    + "        _ target: ChatAXObservedTarget,\n"
                    + "        applicationElement:",
                in: observerTypeRegion),
            let startupBindingRegion = chatAXFunctionRegion(
                "private func startupRuntimeStillMatches(", in: observerTypeRegion),
            let scheduleValidationRegion = chatAXFunctionRegion(
                "private func scheduleBoundTargetValidation(", in: observerTypeRegion),
            let finishValidationRegion = chatAXFunctionRegion(
                "private func finishBoundTargetValidation(", in: observerTypeRegion),
            let targetStillMatchesRegion = chatAXFunctionRegion(
                "func targetStillMatches(", in: observerTypeRegion),
            let runtimeApplicationRegion = chatAXFunctionRegion(
                "private func runtimeApplicationStillMatches(", in: observerTypeRegion),
            let architectureRegion = chatAXFunctionRegion(
                "private func architecture(", in: observerTypeRegion),
            let anchorRegion = chatAXFunctionRegion(
                "func readAnchorFacts(", in: surfaceReaderTypeRegion),
            let startRegion = chatAXFunctionRegion("func start(", in: observerTypeRegion),
            let validationTimerRegion = chatAXBracedDeclarationRegion(
                "let validationTimer = Timer(", in: startRegion),
            let stopRegion = chatAXFunctionRegion("func stop()", in: observerTypeRegion),
            let handleRegion = chatAXFunctionRegion(
                "fileprivate func handle(", in: observerTypeRegion),
            let processObservedElementRegion = chatAXFunctionRegion(
                "private func processObservedElement(", in: observerTypeRegion),
            let enqueueDeferredEventRegion = chatAXFunctionRegion(
                "private func enqueueDeferredEvent(", in: observerTypeRegion),
            let retryDeferredEventRegion = chatAXFunctionRegion(
                "private func retryDeferredEvent(", in: observerTypeRegion),
            let destroyedRegion = chatAXBracedDeclarationRegion(
                "if targetWasDestroyed", in: handleRegion)
        else {
            expect(false, "必须能定位 production identity、observer 与 surface 复核函数")
            return
        }
        let hasCoherentPIDCodeSnapshots: (String) -> Bool = { region in
            let required = [
                "dynamicCode(processIdentifier: processIdentifier)",
                "SecCodeCopyStaticCode(",
                "SecStaticCodeCheckValidity(",
                "kSecCSStrictValidate",
                "kSecCSCheckNestedCode",
                "runningFacts.mainExecutablePath == diskFacts.mainExecutablePath",
                "incarnationAfter == incarnationBefore",
            ]
            return required.allSatisfy(region.contains)
                && region.components(separatedBy: "dynamicCode(").count - 1 == 1
                && region.components(separatedBy: "SecCodeCopyStaticCode(").count - 1 == 1
                && region.components(separatedBy: "currentProcessIncarnation(").count - 1
                    == 2
        }
        expect(
            hasCoherentPIDCodeSnapshots(coherentCodeRegion)
                && dynamicCodeRegion.contains("kSecGuestAttributePid")
                && dynamicCodeRegion.contains("SecCodeCopyGuestWithAttributes(")
                && dynamicCodeRegion.contains("CFGetTypeID(code) == SecCodeGetTypeID()")
                && dynamicCodeRegion.contains("SecCodeCheckValidity(")
                && runningCodeRegion.contains("dynamicCode(processIdentifier:")
                && runningCodeRegion.contains("signingFacts(forDynamicCode:")
                && runningCodeRegion.components(
                    separatedBy: "currentProcessIncarnation("
                ).count - 1 == 2
                && runningCodeRegion.contains("incarnationAfter == incarnationBefore")
                && processIncarnationRegion.contains("proc_pidinfo(")
                && processIncarnationRegion.contains("pbi_start_tvsec")
                && processIncarnationRegion.contains("pbi_start_tvusec")
                && codeReaderTypeRegion.contains("unsafeBitCast(")
                && codeReaderTypeRegion.contains("kSecCSDynamicInformation"),
            "code identity 必须从 PID 动态 SecCode 取样，并绑定实际运行架构的严格静态 origin")
        let pathOnlyCodeMutation = coherentCodeRegion.replacingOccurrences(
            of: "dynamicCode(processIdentifier: processIdentifier)",
            with: "staticCodeAtBundlePath(bundleURL)")
        expect(
            !hasCoherentPIDCodeSnapshots(pathOnlyCodeMutation),
            "code identity 契约必须拒绝退回只按 bundle path 检查磁盘签名")
        let missingIncarnationBracketMutation = coherentCodeRegion.replacingOccurrences(
            of: "incarnationAfter == incarnationBefore",
            with: "true")
        expect(
            !hasCoherentPIDCodeSnapshots(missingIncarnationBracketMutation),
            "code identity 契约必须拒绝在取样期间跨越 PID process incarnation")

        let identityUsesStableSnapshots: (String) -> Bool = { region in
            guard
                region.components(separatedBy: "coherentSnapshot(").count - 1 == 2,
                region.contains("inspectStableFrameworkSet("),
                region.contains("codeBefore == codeAfter"),
                region.contains("ChatAXCodeIdentityBinding.bind("),
                let beforeRange = region.range(of: "let codeBefore ="),
                let frameworksRange = region.range(of: "let frameworkInspections ="),
                let afterRange = region.range(of: "let codeAfter ="),
                let bindingRange = region.range(of: "ChatAXCodeIdentityBinding.bind("),
                let candidateRange = region.range(
                    of: "ChatAXTargetIdentity.observedChatGPTDesktopAX(")
            else {
                return false
            }
            return beforeRange.upperBound < frameworksRange.lowerBound
                && frameworksRange.upperBound < afterRange.lowerBound
                && afterRange.upperBound < bindingRange.lowerBound
                && bindingRange.upperBound < candidateRange.lowerBound
        }
        expect(
            identityUsesStableSnapshots(identityRegion)
                && stableFrameworkSetRegion.components(
                    separatedBy: "inspectFrameworkSet("
                ).count - 1 == 2
                && stableFrameworkSetRegion.contains("guard before == after")
                && !identityRegion.contains("Bundle(")
                && !frameworkIdentityRegion.contains("Bundle(")
                && frameworkIdentityRegion.contains("diskSignedBundleIdentity(at: url)"),
            "candidate 必须由 PID/磁盘双快照与稳定 framework 签名取样共同授权")
        let singleCodeSnapshotMutation = identityRegion.replacingOccurrences(
            of: "let codeAfter = SystemChatAXCodeIdentityReader.coherentSnapshot(",
            with: "let codeAfter = SystemChatAXCodeIdentityReader.cachedSnapshot(")
        expect(
            !identityUsesStableSnapshots(singleCodeSnapshotMutation),
            "identity 契约必须拒绝删除第二次完整 code snapshot")
        let unbracketedCandidateMutation = identityRegion.replacingOccurrences(
            of: "codeBefore == codeAfter,",
            with: "true,")
        expect(
            !identityUsesStableSnapshots(unbracketedCandidateMutation),
            "identity 契约必须拒绝忽略两次 code snapshot 的漂移")

        let staticValidationAPIsHaveClosedOwnership: (String) -> Bool = {
            candidateRuntime in
            guard
                let candidateReader = chatAXBracedDeclarationRegion(
                    "private enum SystemChatAXCodeIdentityReader",
                    in: candidateRuntime),
                let candidateCoherent = chatAXFunctionRegion(
                    "static func coherentSnapshot(", in: candidateReader),
                let candidateDisk = chatAXFunctionRegion(
                    "static func diskSignedBundleIdentity(", in: candidateReader)
            else {
                return false
            }
            var unownedRuntime = candidateRuntime
            unownedRuntime = unownedRuntime.replacingOccurrences(
                of: candidateCoherent,
                with: "")
            unownedRuntime = unownedRuntime.replacingOccurrences(
                of: candidateDisk,
                with: "")
            let prohibitedOutsideFullInspection = [
                "SecCodeCopyStaticCode(",
                "SecStaticCodeCreateWithPath(",
                "SecStaticCodeCheckValidity(",
            ]
            return candidateCoherent.components(
                separatedBy: "SecCodeCopyStaticCode("
            ).count - 1 == 1
                && candidateCoherent.components(
                    separatedBy: "SecStaticCodeCheckValidity("
                ).count - 1 == 1
                && candidateDisk.components(
                    separatedBy: "SecStaticCodeCreateWithPath("
                ).count - 1 == 1
                && candidateDisk.components(
                    separatedBy: "SecStaticCodeCheckValidity("
                ).count - 1 == 1
                && prohibitedOutsideFullInspection.allSatisfy {
                    !unownedRuntime.contains($0)
                }
        }
        expect(
            staticValidationAPIsHaveClosedOwnership(runtime),
            "完整静态 code 验证 API 只能属于两个显式 full-inspection 函数")
        let extractedStaticHelperMutation = runtime.replacingOccurrences(
            of: "    private static func dynamicCode(",
            with: """
                    static func staticOriginIsValid(processIdentifier: pid_t) -> Bool {
                        guard let dynamicCode = dynamicCode(
                            processIdentifier: processIdentifier)
                        else { return false }
                        var staticCode: SecStaticCode?
                        guard
                            SecCodeCopyStaticCode(dynamicCode, SecCSFlags(), &staticCode)
                                == errSecSuccess,
                            let staticCode
                        else { return false }
                        return SecStaticCodeCheckValidity(
                            staticCode,
                            SecCSFlags(rawValue: kSecCSStrictValidate),
                            nil) == errSecSuccess
                    }

                    private static func dynamicCode(
                """
        )
        .replacingOccurrences(
            of: "        guard\n            let sample = SystemChatAXRuntimeSampler.sample(",
            with: """
                            guard
                                SystemChatAXCodeIdentityReader.staticOriginIsValid(
                                    processIdentifier: target.processIdentifier),
                                let sample = SystemChatAXRuntimeSampler.sample(
                """)
        expect(
            extractedStaticHelperMutation.components(
                separatedBy: "staticOriginIsValid("
            ).count - 1 == 2
                && !staticValidationAPIsHaveClosedOwnership(extractedStaticHelperMutation),
            "全文件 ownership gate 必须拒绝 startup helper 传递调用新抽出的静态验证")

        let fullInspectionEntrypointsHaveClosedCallSites: (String) -> Bool = {
            candidateRuntime in
            guard
                let candidateReader = chatAXBracedDeclarationRegion(
                    "private enum SystemChatAXCodeIdentityReader",
                    in: candidateRuntime),
                chatAXFunctionRegion(
                    "static func coherentSnapshot(", in: candidateReader) != nil,
                chatAXFunctionRegion(
                    "static func diskSignedBundleIdentity(", in: candidateReader) != nil,
                let candidateObserver = chatAXBracedDeclarationRegion(
                    "final class SystemChatAXTraceObserver: ChatAXTraceObserving",
                    in: candidateRuntime),
                let candidateInspection = chatAXFunctionRegion(
                    "func inspectTarget(", in: candidateObserver),
                let candidateIdentity = chatAXFunctionRegion(
                    "private func inspectIdentities(", in: candidateObserver),
                let candidateStableFrameworkSet = chatAXFunctionRegion(
                    "private func inspectStableFrameworkSet(", in: candidateObserver),
                let candidateFrameworkSet = chatAXFunctionRegion(
                    "private func inspectFrameworkSet(", in: candidateObserver),
                let candidateFrameworkIdentity = chatAXFunctionRegion(
                    "private func inspectFrameworkIdentity(", in: candidateObserver)
            else {
                return false
            }
            return candidateRuntime.components(separatedBy: "coherentSnapshot(").count - 1 == 3
                && candidateIdentity.components(
                    separatedBy: "coherentSnapshot("
                ).count - 1 == 2
                && candidateRuntime.components(
                    separatedBy: "diskSignedBundleIdentity("
                ).count - 1 == 2
                && candidateFrameworkIdentity.components(
                    separatedBy: "diskSignedBundleIdentity("
                ).count - 1 == 1
                && candidateRuntime.components(separatedBy: "inspectIdentities(").count - 1
                    == 2
                && candidateInspection.components(
                    separatedBy: "inspectIdentities("
                ).count - 1 == 1
                && candidateRuntime.components(
                    separatedBy: "inspectStableFrameworkSet("
                ).count - 1 == 2
                && candidateIdentity.components(
                    separatedBy: "inspectStableFrameworkSet("
                ).count - 1 == 1
                && candidateRuntime.components(separatedBy: "inspectFrameworkSet(").count - 1
                    == 3
                && candidateStableFrameworkSet.components(
                    separatedBy: "inspectFrameworkSet("
                ).count - 1 == 2
                && candidateRuntime.components(
                    separatedBy: "inspectFrameworkIdentity("
                ).count - 1 == 2
                && candidateFrameworkSet.components(
                    separatedBy: "inspectFrameworkIdentity("
                ).count - 1 == 1
        }
        expect(
            fullInspectionEntrypointsHaveClosedCallSites(runtime),
            "full-inspection 入口及其 helper 调用图只能从 inspectTarget 到达")
        let wrappedFullInspectionMutation = runtime.replacingOccurrences(
            of: "    private static func dynamicCode(",
            with: """
                    static func runtimeFullSnapshot(
                        processIdentifier: pid_t,
                        bundleURL: URL
                    ) -> SystemChatAXCodeSnapshot? {
                        coherentSnapshot(
                            processIdentifier: processIdentifier,
                            bundleURL: bundleURL)
                    }

                    private static func dynamicCode(
                """
        )
        .replacingOccurrences(
            of: "        guard\n            let sample = SystemChatAXRuntimeSampler.sample(",
            with: """
                            guard
                                SystemChatAXCodeIdentityReader.runtimeFullSnapshot(
                                    processIdentifier: target.processIdentifier,
                                    bundleURL: URL(fileURLWithPath: binding.bundlePath)) != nil,
                                let sample = SystemChatAXRuntimeSampler.sample(
                """)
        expect(
            wrappedFullInspectionMutation.components(
                separatedBy: "runtimeFullSnapshot("
            ).count - 1 == 2
                && !fullInspectionEntrypointsHaveClosedCallSites(
                    wrappedFullInspectionMutation),
            "调用图 gate 必须拒绝 startup 通过新 wrapper 恢复 coherent full inspection")

        let runtimeRegionsContainNoFullInspection: ([String]) -> Bool = { regions in
            let combined = regions.joined(separator: "\n")
            let prohibited = [
                "SecStaticCodeCheckValidity(",
                "SecStaticCodeCreateWithPath(",
                "SecCodeCopyStaticCode(",
                "Bundle(",
                "inspectIdentities(",
                "inspectFramework",
                "coherentSnapshot(",
            ]
            return prohibited.allSatisfy { !combined.contains($0) }
        }
        let transitiveRuntimeRegions = [
            scheduleValidationRegion,
            finishValidationRegion,
            targetStillMatchesRegion,
            startupBindingRegion,
            runtimeSamplerTypeRegion,
            runningCodeRegion,
            dynamicCodeRegion,
            dynamicSigningRegion,
            importedSigningRegion,
            processIncarnationRegion,
            normalizedPathRegion,
            runtimeApplicationRegion,
            architectureRegion,
            surfaceReaderTypeRegion,
            attributeReaderTypeRegion,
            budgetTypeRegion,
        ]
        let runtimeCommitIsExact: (String) -> Bool = { region in
            region.contains("validationGate.finishValidation(request)")
                && region.contains("sample?.runtimeFacts == runtimeBinding.runtimeFacts")
                && region.contains(
                    "sample?.surfaceSignature == target.identity.surfaceSignature")
                && region.contains("runtimeApplicationStillMatches(")
                && !region.contains("surfaceStillMatches(")
        }
        let runtimeContentionDefers: (String) -> Bool = { region in
            guard
                let deferredRange = region.range(of: "case .deferred:"),
                let nextCaseRange = region.range(
                    of: "case .",
                    range: deferredRange.upperBound..<region.endIndex)
            else {
                return false
            }
            let deferredBranch = region[deferredRange.lowerBound..<nextCaseRange.lowerBound]
            return deferredBranch.contains("return")
                && !deferredBranch.contains("invalidateTarget()")
        }
        let runtimeConclusiveFailureInvalidates: (String) -> Bool = { region in
            guard
                let failureRange = region.range(of: "case .cancelled, .timedOut:"),
                let completedRange = region.range(
                    of: "case .completed",
                    range: failureRange.upperBound..<region.endIndex)
            else {
                return false
            }
            let failureBranch = region[failureRange.lowerBound..<completedRange.lowerBound]
            let completedBranch = region[completedRange.lowerBound..<region.endIndex]
            return failureBranch.contains("invalidateTarget()")
                && completedBranch.contains("invalidateTarget()")
        }
        let runtimeSamplerBracketsSurface: (String) -> Bool = { region in
            region.components(separatedBy: "runningRuntimeFacts(").count - 1 == 2
                && region.contains("readAnchorFacts(")
                && region.contains("factsAfter == factsBefore")
        }
        expect(
            runtimeRegionsContainNoFullInspection(transitiveRuntimeRegions)
                && scheduleValidationRegion.contains("validationGate.beginValidation()")
                && scheduleValidationRegion.contains("ChatAXRuntimeValidationDeadline.run(")
                && scheduleValidationRegion.contains("timeoutNanoseconds: 500_000_000")
                && scheduleValidationRegion.contains("SystemChatAXRuntimeSampler.sample(")
                && runtimeCommitIsExact(finishValidationRegion)
                && runtimeContentionDefers(finishValidationRegion)
                && runtimeConclusiveFailureInvalidates(finishValidationRegion)
                && targetStillMatchesRegion.contains("SystemChatAXRuntimeSampler.sample(")
                && runtimeSamplerBracketsSurface(runtimeSamplerTypeRegion)
                && runtimeApplicationRegion.contains("architecture(for: application)")
                && runtimeApplicationRegion.contains("normalizedPath(bundleURL)")
                && runtimeApplicationRegion.contains("currentProcessIncarnation(")
                && runtimeApplicationRegion.contains(
                    "== binding.runtimeFacts.processIncarnation")
                && !observerTypeRegion.contains("launchDate")
                && startRegion.contains("validationGate.beginSession()")
                && stopRegion.contains("validationTask?.cancel()")
                && stopRegion.contains("validationGate.endSession()"),
            "运行期必须在有 deadline 的后台 sampler 复核 code/incarnation/surface，MainActor 只提交")
        let contentionInvalidatesMutation = finishValidationRegion.replacingOccurrences(
            of: "case .deferred:\n            return",
            with: "case .deferred:\n            invalidateTarget()\n            return")
        expect(
            !runtimeContentionDefers(contentionInvalidatesMutation),
            "周期 validation 不得把 shared lease contention 冒充 target drift")
        let timeoutFailsOpenMutation = finishValidationRegion.replacingOccurrences(
            of: "case .cancelled, .timedOut:\n            invalidateTarget()",
            with: "case .cancelled, .timedOut:\n            return")
        expect(
            !runtimeConclusiveFailureInvalidates(timeoutFailsOpenMutation),
            "周期 validation 的 timeout 与 completed(nil) 必须继续 fail closed")
        let ownsGlobalSystemQueryLease: (String, String) -> Bool = { region, firstQuery in
            guard
                region.contains("let workerGate = ChatAXSystemQueryWorkerGate.shared"),
                let acquireRange = region.range(of: "let workerLease = workerGate.acquire()"),
                let releaseRange = region.range(
                    of: "defer { workerGate.release(workerLease) }"),
                let queryRange = region.range(of: firstQuery)
            else {
                return false
            }
            return acquireRange.lowerBound < releaseRange.lowerBound
                && releaseRange.lowerBound < queryRange.lowerBound
        }
        expect(
            ownsGlobalSystemQueryLease(inspectionRegion, "inspectIdentities(")
                && ownsGlobalSystemQueryLease(startRegion, "startupRuntimeStillMatches(")
                && ownsGlobalSystemQueryLease(
                    targetStillMatchesRegion,
                    "SystemChatAXRuntimeSampler.sample(")
                && ownsGlobalSystemQueryLease(handleRegion, "processObservedElement(")
                && ownsGlobalSystemQueryLease(
                    retryDeferredEventRegion,
                    "processObservedElement("),
            "full inspection、startup、同步复验与事件查询必须共用全局 system-query lease")
        let unleasedStartupMutation = startRegion.replacingOccurrences(
            of: "let workerLease = workerGate.acquire()",
            with: "let workerLease = workerGate.uncheckedLease()")
        expect(
            !ownsGlobalSystemQueryLease(
                unleasedStartupMutation,
                "startupRuntimeStillMatches("),
            "真实 startup 入口不得绕过旧阻塞 worker 的 single-flight gate")
        let contentionDefersWithoutInvalidating: (String) -> Bool = { region in
            guard
                let busyBranch = chatAXBracedDeclarationRegion(
                    "guard let workerLease = workerGate.acquire() else",
                    in: region)
            else {
                return false
            }
            return busyBranch.contains("enqueueDeferredEvent(element)")
                && !busyBranch.contains("invalidateTarget()")
        }
        expect(
            contentionDefersWithoutInvalidating(handleRegion)
                && targetStillMatchesRegion.contains("return .deferred")
                && enqueueDeferredEventRegion.contains(
                    "deferredSystemQueryGate.enqueue(")
                && enqueueDeferredEventRegion.contains(
                    "RunLoop.main.add(deferredEventTimer, forMode: .common)")
                && retryDeferredEventRegion.contains("case .waiting:")
                && retryDeferredEventRegion.contains("case .ready:")
                && stopRegion.contains("deferredEventTimer?.invalidate()")
                && stopRegion.contains("deferredSystemQueryGate.endSession()"),
            "正常 timer contention 必须在 common modes 合并延后；只有 exact mismatch/过期才可 stop")
        let defaultModeRetryMutation = enqueueDeferredEventRegion.replacingOccurrences(
            of: "RunLoop.main.add(deferredEventTimer, forMode: .common)",
            with: "RunLoop.main.add(deferredEventTimer, forMode: .default)")
        expect(
            !defaultModeRetryMutation.contains(
                "RunLoop.main.add(deferredEventTimer, forMode: .common)"),
            "deferred retry 不得退回 default-only run-loop mode")
        let contentionInvalidationMutation = handleRegion.replacingOccurrences(
            of: "enqueueDeferredEvent(element)\n            return",
            with: "invalidateTarget()\n            return")
        expect(
            !contentionDefersWithoutInvalidating(contentionInvalidationMutation),
            "event 入口不得把 shared lease busy 冒充 identity drift")
        let axReadsStopAfterCancellation: (String, String) -> Bool = {
            readerRegion, readBudgetRegion in
            guard
                let elementRegion = chatAXFunctionRegion("func element(", in: readerRegion),
                let stringRegion = chatAXFunctionRegion("func string(", in: readerRegion),
                let integerRegion = chatAXFunctionRegion("func integer(", in: readerRegion),
                let prepareRegion = chatAXFunctionRegion(
                    "func prepareForMessaging(", in: readBudgetRegion),
                let messagingTimeoutRange = prepareRegion.range(
                    of: "AXUIElementSetMessagingTimeout("),
                let postTimeoutCancellationRange = prepareRegion.range(
                    of: "Task.isCancelled",
                    range: messagingTimeoutRange.upperBound..<prepareRegion.endIndex)
            else {
                return false
            }
            return readBudgetRegion.contains(
                "guard !Task.isCancelled, remaining >= Self.minimumQuerySeconds")
                && messagingTimeoutRange.lowerBound < postTimeoutCancellationRange.lowerBound
                && [elementRegion, stringRegion, integerRegion].allSatisfy {
                    guard
                        let queryRange = $0.range(of: "AXUIElementCopyAttributeValue("),
                        let cancellationRange = $0.range(
                            of: "Task.isCancelled",
                            range: queryRange.upperBound..<$0.endIndex)
                    else {
                        return false
                    }
                    return queryRange.lowerBound < cancellationRange.lowerBound
                }
        }
        let runtimeSamplerStopsAfterCancellation: (String, String) -> Bool = {
            samplerRegion, runtimeFactsRegion in
            samplerRegion.components(separatedBy: "Task.isCancelled").count - 1 >= 5
                && runtimeFactsRegion.components(
                    separatedBy: "Task.isCancelled"
                ).count - 1 >= 5
        }
        let securityCallsStopAfterCancellation: (String) -> Bool = { readerRegion in
            chatAXFunctionContainsMarkersInOrder(
                [
                    "SecCodeCopyStaticCode(",
                    "Task.isCancelled",
                    "SecStaticCodeCheckValidity(",
                    "Task.isCancelled",
                ],
                inFunction: "static func coherentSnapshot(",
                source: readerRegion)
                && chatAXFunctionContainsMarkersInOrder(
                    [
                        "SecStaticCodeCreateWithPath(",
                        "Task.isCancelled",
                        "SecStaticCodeCheckValidity(",
                        "Task.isCancelled",
                    ],
                    inFunction: "static func diskSignedBundleIdentity(",
                    source: readerRegion)
                && chatAXFunctionContainsMarkersInOrder(
                    [
                        "SecCodeCopyGuestWithAttributes(",
                        "Task.isCancelled",
                        "SecCodeCheckValidity(",
                        "Task.isCancelled",
                    ],
                    inFunction: "private static func dynamicCode(",
                    source: readerRegion)
                && chatAXFunctionContainsMarkersInOrder(
                    ["proc_pidinfo(", "Task.isCancelled"],
                    inFunction: "static func currentProcessIncarnation(",
                    source: readerRegion)
                && chatAXFunctionContainsMarkersInOrder(
                    ["SecCodeCopySigningInformation(", "Task.isCancelled"],
                    inFunction: "private static func signingFacts(\n"
                        + "        forImportedCode",
                    source: readerRegion)
        }
        expect(
            axReadsStopAfterCancellation(attributeReaderTypeRegion, budgetTypeRegion)
                && runtimeSamplerStopsAfterCancellation(
                    runtimeSamplerTypeRegion,
                    runningCodeRegion)
                && securityCallsStopAfterCancellation(codeReaderTypeRegion),
            "timeout/stop 后恢复的旧 worker 必须在每个 sampler phase 与 AX query 边界停止")
        let uncancelledReaderMutation = attributeReaderTypeRegion.replacingOccurrences(
            of: "!Task.isCancelled",
            with: "true")
        expect(
            !axReadsStopAfterCancellation(uncancelledReaderMutation, budgetTypeRegion),
            "取消契约必须拒绝 AX reader 在旧 session 恢复后继续查询")
        let missingPostTimeoutCheckpointMutation = budgetTypeRegion.replacingOccurrences(
            of: "            !Task.isCancelled\n        else {",
            with: "            true\n        else {")
        expect(
            !axReadsStopAfterCancellation(
                attributeReaderTypeRegion,
                missingPostTimeoutCheckpointMutation),
            "取消契约必须拒绝 messaging timeout 返回后直接开始下一次 AX 查询")
        let uncancelledSamplerMutation = runtimeSamplerTypeRegion.replacingOccurrences(
            of: "!Task.isCancelled",
            with: "true")
        expect(
            !runtimeSamplerStopsAfterCancellation(
                uncancelledSamplerMutation,
                runningCodeRegion),
            "取消契约必须拒绝 runtime sampler 在 phase 间忽略 timeout")
        let uncancelledDynamicRegion = dynamicCodeRegion.replacingOccurrences(
            of: "!Task.isCancelled",
            with: "true")
        let uncancelledDynamicReader = codeReaderTypeRegion.replacingOccurrences(
            of: dynamicCodeRegion,
            with: uncancelledDynamicRegion)
        expect(
            !securityCallsStopAfterCancellation(uncancelledDynamicReader),
            "取消契约必须拒绝相邻 Security 调用之间没有 checkpoint")
        let timerOnlySchedulesLightweightValidation: (String) -> Bool = { region in
            region.components(separatedBy: "scheduleBoundTargetValidation()").count - 1 == 1
                && !region.contains("inspectIdentities(")
                && !region.contains("coherentSnapshot(")
                && !region.contains("SecStaticCodeCheckValidity(")
                && !region.contains("SecStaticCodeCreateWithPath(")
        }
        expect(
            timerOnlySchedulesLightweightValidation(validationTimerRegion)
                && startRegion.contains(
                    "RunLoop.main.add(validationTimer, forMode: .common)"),
            "一秒 timer 必须在 common modes 只调度轻量后台复验")
        let defaultModeValidationMutation = startRegion.replacingOccurrences(
            of: "RunLoop.main.add(validationTimer, forMode: .common)",
            with: "RunLoop.main.add(validationTimer, forMode: .default)")
        expect(
            !defaultModeValidationMutation.contains(
                "RunLoop.main.add(validationTimer, forMode: .common)"),
            "周期 identity validation 不得退回 default-only run-loop mode")
        let fullInspectionTimerMutation = validationTimerRegion.replacingOccurrences(
            of: "scheduleBoundTargetValidation()",
            with: "inspectIdentities(for: application, requirements: requirements)")
        expect(
            !timerOnlySchedulesLightweightValidation(fullInspectionTimerMutation),
            "timer 契约必须拒绝绕过 scheduler 直接恢复完整 identity inspection")
        let transitiveFullInspectionMutation = runningCodeRegion.replacingOccurrences(
            of: "let signingFacts = signingFacts(forDynamicCode: dynamicCode),",
            with: "let signingFacts = signingFacts(forDynamicCode: dynamicCode),\n"
                + "            SecStaticCodeCheckValidity(\n"
                + "                unsafeBitCast(dynamicCode, to: SecStaticCode.self),\n"
                + "                SecCSFlags(rawValue: kSecCSStrictValidate),\n"
                + "                nil) == errSecSuccess,")
        expect(
            !runtimeRegionsContainNoFullInspection(
                transitiveRuntimeRegions.map {
                    $0 == runningCodeRegion ? transitiveFullInspectionMutation : $0
                }),
            "性能契约必须拒绝在 runtime sampler 的传递 helper 中恢复完整静态验证")
        let missingRuntimeIdentityMutation = finishValidationRegion.replacingOccurrences(
            of: "sample?.runtimeFacts == runtimeBinding.runtimeFacts,",
            with: "sample != nil,")
        expect(
            !runtimeCommitIsExact(missingRuntimeIdentityMutation),
            "runtime 契约必须拒绝只看 PID/路径而不 exact 比较启动签名")
        let unbracketedSurfaceMutation = runtimeSamplerTypeRegion.replacingOccurrences(
            of: "factsAfter == factsBefore",
            with: "factsAfter.signingFacts == factsBefore.signingFacts")
        expect(
            !runtimeSamplerBracketsSurface(unbracketedSurfaceMutation),
            "surface 读取前后必须 exact 复核 code 与 process incarnation")

        let readerReusesSingleBudget: (String) -> Bool = { readerRegion in
            guard
                readerRegion.contains("private let budget: SystemChatAXReadBudget"),
                readerRegion.components(separatedBy: "SystemChatAXReadBudget()").count - 1
                    == 1,
                let prepareRegion = chatAXFunctionRegion(
                    "func prepareForMessaging(", in: readerRegion)
            else {
                return false
            }
            return prepareRegion.contains("budget.prepareForMessaging(element)")
                && !prepareRegion.contains("SystemChatAXReadBudget(")
        }
        expect(
            readerReusesSingleBudget(attributeReaderTypeRegion),
            "所有 AX query 必须复用 reader 持有的同一个端到端预算")
        let resettingBudgetMutation = attributeReaderTypeRegion.replacingOccurrences(
            of: "budget.prepareForMessaging(element)",
            with: "SystemChatAXReadBudget().prepareForMessaging(element)")
        expect(
            !readerReusesSingleBudget(resettingBudgetMutation),
            "预算契约必须拒绝每次 query 重建 deadline 的等价变异")
        for (declaration, query) in [
            ("func element(", "AXUIElementCopyAttributeValue("),
            ("func string(", "AXUIElementCopyAttributeValue("),
            ("func integer(", "AXUIElementCopyAttributeValue("),
        ] {
            expect(
                chatAXFunctionContainsMarkersInOrder(
                    ["prepareForMessaging(element)", query],
                    inFunction: declaration,
                    source: attributeReaderTypeRegion),
                "\(declaration) 必须在每次 AX query 前消费同一端到端预算")
        }
        for (declaration, typeRegion) in [
            ("private func belongsToTarget(", surfaceReaderTypeRegion),
            ("private func elementBelongsToTarget(", observerTypeRegion),
        ] {
            expect(
                chatAXFunctionContainsMarkersInOrder(
                    ["prepareForMessaging(element)", "AXUIElementGetPid("],
                    inFunction: declaration,
                    source: typeRegion),
                "\(declaration) 必须在 PID query 前消费同一端到端预算")
        }
        expect(
            chatAXFunctionContainsMarkersInOrder(
                [
                    "deadline - ProcessInfo.processInfo.systemUptime",
                    "AXUIElementSetMessagingTimeout(",
                ],
                inFunction: "func prepareForMessaging(",
                source: budgetTypeRegion)
                && runtime.contains("totalSeconds")
                && runtime.contains("maximumQuerySeconds"),
            "每次 AX 快照必须同时受端到端 deadline 与单查询 timeout 约束")
        expect(
            anchorRegion.contains("lineagesAreEqual(")
                && anchorRegion.components(separatedBy: "anchorFacts(in:").count - 1 == 2
                && anchorRegion.contains("expectedProcessIdentifier"),
            "surface facts 必须逐元素核对 PID，并对完整 lineage/facts 做前后双快照")
        let requiredNotifications = [
            "kAXFocusedUIElementChangedNotification",
            "kAXFocusedWindowChangedNotification",
            "kAXWindowCreatedNotification",
            "kAXUIElementDestroyedNotification",
            "kAXLayoutChangedNotification",
        ]
        let hasExactNotificationSet: (String) -> Bool = { region in
            let normalized = region.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let declaration =
                "let notifications: [CFString] = [ "
                + requiredNotifications.map { "\($0) as CFString," }.joined(separator: " ")
                + " ]"
            return normalized.contains(declaration)
                && requiredNotifications.allSatisfy {
                    region.components(separatedBy: $0).count - 1 == 1
                }
        }
        let reusesSingleFullInspectionAcrossRegistration: (String, String, String) -> Bool = {
            inspectRegion, registrationRegion, lightweightRegion in
            inspectRegion.components(separatedBy: "inspectIdentities(").count - 1 == 1
                && inspectRegion.contains("pendingInspection = SystemChatAXInspectedBinding(")
                && registrationRegion.contains("let inspectedBinding = pendingInspection")
                && registrationRegion.contains("inspectedBinding.candidates.contains(target)")
                && registrationRegion.components(
                    separatedBy: "startupRuntimeStillMatches("
                ).count - 1 == 2
                && !registrationRegion.contains("inspectIdentities(")
                && !registrationRegion.contains("coherentSnapshot(")
                && lightweightRegion.contains("SystemChatAXRuntimeSampler.sample(")
                && lightweightRegion.contains("sample.runtimeFacts == binding.runtimeFacts")
                && lightweightRegion.contains(
                    "sample.surfaceSignature == target.identity.surfaceSignature")
                && lightweightRegion.contains("runtimeApplicationStillMatches(")
        }
        expect(
            hasExactNotificationSet(startRegion)
                && startRegion.contains("registered.count == notifications.count")
                && startRegion.contains("AXObserverRemoveNotification(")
                && reusesSingleFullInspectionAcrossRegistration(
                    inspectionRegion,
                    startRegion,
                    startupBindingRegion),
            "必需通知必须全注册并回滚失败；注册前后都须精确复核目标")
        let reducedNotificationMutation = requiredNotifications.dropLast().reduce(startRegion) {
            partial, notification in
            partial.replacingOccurrences(
                of: notification,
                with: "kAXLayoutChangedNotification")
        }
        expect(
            !hasExactNotificationSet(reducedNotificationMutation),
            "通知契约必须拒绝只保留 layout notification 的等价变异")
        let pidOnlyStartupMutation = startupBindingRegion.replacingOccurrences(
            of: "sample.runtimeFacts == binding.runtimeFacts,",
            with: "binding.processIdentifier == target.processIdentifier,")
        expect(
            !reusesSingleFullInspectionAcrossRegistration(
                inspectionRegion,
                startRegion,
                pidOnlyStartupMutation),
            "启动绑定契约必须拒绝注册后只复核 PID、不复核完整 incarnation")
        expect(
            stopRegion.contains("pendingInspection = nil"),
            "full inspection cache 必须是一次性的，stop 后不能授权未来 start")
        let stopsWithoutMessagingDestroyedApplication: (String) -> Bool = { region in
            guard
                let observerRegion = chatAXBracedDeclarationRegion(
                    "if let axObserver", in: region),
                let registrationRegion = chatAXBracedDeclarationRegion(
                    "if let applicationElement", in: observerRegion),
                let registrationRange = observerRegion.range(of: registrationRegion),
                let runLoopRemovalRange = observerRegion.range(of: "CFRunLoopRemoveSource(")
            else {
                return false
            }
            return observerRegion.contains("if let axObserver {")
                && registrationRegion.contains("AXObserverRemoveNotification(")
                && registrationRange.upperBound < runLoopRemovalRange.lowerBound
        }
        expect(
            stopsWithoutMessagingDestroyedApplication(stopRegion),
            "stop 必须能在 application element 已销毁时跳过 AX 注销，但仍移除 run-loop source")
        let missingRegistrationGuardMutation = stopRegion.replacingOccurrences(
            of: "if let applicationElement {",
            with: "if true {")
        expect(
            !stopsWithoutMessagingDestroyedApplication(missingRegistrationGuardMutation),
            "销毁边界契约必须拒绝继续用失效 application element 注销通知")
        let validatesSurfaceBeforeUnrelatedSignal: (String) -> Bool = { region in
            let normalized = region.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let verification = "surfaceStillMatches(target)"
            let emission = "emitSignal(kind: .unrelatedStructureChanged"
            guard
                normalized.contains(
                    "guard elementBelongsToTarget(element, target: target), \(verification) else"),
                region.components(separatedBy: verification).count - 1 == 1,
                region.components(separatedBy: emission).count - 1 == 1,
                let verificationRange = region.range(of: verification),
                let emissionRange = region.range(of: emission)
            else {
                return false
            }
            return verificationRange.upperBound < emissionRange.lowerBound
        }
        expect(
            validatesSurfaceBeforeUnrelatedSignal(processObservedElementRegion)
                && runtime.components(
                    separatedBy: "processObservedElement("
                ).count - 1 == 3
                && handleRegion.components(
                    separatedBy: "processObservedElement("
                ).count - 1 == 1
                && retryDeferredEventRegion.components(
                    separatedBy: "processObservedElement("
                ).count - 1 == 1,
            "每个非销毁结构通知都必须在发布信号前立即复核 surface")
        let reorderedSurfaceMutation =
            processObservedElementRegion
            .replacingOccurrences(of: "surfaceStillMatches(target)", with: "__SURFACE_CHECK__")
            .replacingOccurrences(
                of: "emitSignal(kind: .unrelatedStructureChanged",
                with: "surfaceStillMatches(target); __UNRELATED_EMIT__"
            )
            .replacingOccurrences(
                of: "__SURFACE_CHECK__",
                with: "emitSignal(kind: .unrelatedStructureChanged")
        expect(
            !validatesSurfaceBeforeUnrelatedSignal(reorderedSurfaceMutation),
            "surface 契约必须拒绝先发布信号、后验证 identity 的等价变异")
        let recordsExitWithoutDestroyedElementQuery: (String) -> Bool = { region in
            let normalized = region.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let applicationDestroyedDeclaration =
                "if let applicationElement, CFEqual(element, applicationElement)"
            guard
                let applicationDestroyedRegion = chatAXBracedDeclarationRegion(
                    applicationDestroyedDeclaration, in: region),
                let applicationDestroyedRange = region.range(of: applicationDestroyedRegion),
                let invalidElementRange = applicationDestroyedRegion.range(
                    of: "self.applicationElement = nil"),
                let emissionRange = applicationDestroyedRegion.range(
                    of: "emitSignal(kind: .applicationExited, windowOrdinal: 0)"),
                let invalidationRange = region.range(of: "invalidateTarget()")
            else {
                return false
            }
            return normalized.contains("invalidateTarget()")
                && applicationDestroyedRegion.contains(
                    "emitSignal(kind: .applicationExited, windowOrdinal: 0)")
                && region.components(separatedBy: "emitSignal(").count - 1 == 1
                && region.components(separatedBy: "invalidateTarget()").count - 1 == 1
                && invalidElementRange.upperBound < emissionRange.lowerBound
                && applicationDestroyedRange.upperBound < invalidationRange.lowerBound
                && !region.contains("element:")
                && !region.contains("SystemChatAXAttributeReader")
                && !region.contains("prepareForMessaging")
                && !region.contains("AXUIElementGetPid")
                && !region.contains("AXUIElementCopyAttributeValue")
        }
        expect(
            recordsExitWithoutDestroyedElementQuery(destroyedRegion),
            "destroyed callback 必须只记录已知退出事实，不能再 query 失效 AX element")
        let destroyedElementQueryMutation = destroyedRegion.replacingOccurrences(
            of: "emitSignal(kind: .applicationExited, windowOrdinal: 0)",
            with: "emitSignal(kind: .applicationExited, element: element)")
        expect(
            !recordsExitWithoutDestroyedElementQuery(destroyedElementQueryMutation),
            "destroyed-element 契约必须拒绝回退到通用 AX emitter")
        let broadExitMutation = destroyedRegion.replacingOccurrences(
            of: "if let applicationElement, CFEqual(element, applicationElement)",
            with: "if targetWasDestroyed")
        expect(
            !recordsExitWithoutDestroyedElementQuery(broadExitMutation),
            "非 application destroyed callback 不得伪造 application-exit evidence")
        let lateInvalidElementMutation = destroyedRegion.replacingOccurrences(
            of: "self.applicationElement = nil\n"
                + "                emitSignal(kind: .applicationExited, windowOrdinal: 0)",
            with: "emitSignal(kind: .applicationExited, windowOrdinal: 0)\n"
                + "                self.applicationElement = nil")
        expect(
            !recordsExitWithoutDestroyedElementQuery(lateInvalidElementMutation),
            "application destroyed 必须在同步 receive 可能调用 stop 之前清空失效引用")
        let missingInvalidationMutation = destroyedRegion.replacingOccurrences(
            of: "invalidateTarget()", with: "")
        expect(
            !recordsExitWithoutDestroyedElementQuery(missingInvalidationMutation),
            "destroyed callback 必须始终确定 invalidate")
        let preservesReadableSurfaceMismatch: (String) -> Bool = { region in
            let verifier = "ChatAXSurfaceVerifier.verifyChat("
            let mismatch = "hasUnreadableProjection: false"
            guard
                region.components(separatedBy: verifier).count - 1 == 1,
                region.components(separatedBy: mismatch).count - 1 == 1,
                let verifierRange = region.range(of: verifier),
                let mismatchRange = region.range(of: mismatch)
            else {
                return false
            }
            return verifierRange.upperBound < mismatchRange.lowerBound
        }
        expect(
            identityRegion.contains("readAnchorFacts(")
                && preservesReadableSurfaceMismatch(identityRegion)
                && identityRegion.contains("requirements.frameworkNameSets.sorted")
                && identityRegion.contains("hasUnreadableProjection = true")
                && identityRegion.contains("ChatAXTargetIdentity.observedChatGPTDesktopAX("),
            "production identity 必须区分可读 mismatch，并逐 framework 集构造 verified 候选")
        let collapsedMismatchMutation = identityRegion.replacingOccurrences(
            of: "hasUnreadableProjection: false",
            with: "hasUnreadableProjection: true")
        expect(
            !preservesReadableSurfaceMismatch(collapsedMismatchMutation),
            "surface mismatch 契约必须拒绝重新折叠为 identityUnreadable")
        expect(
            inspectionRegion.contains("case .candidates(")
                && inspectionRegion.contains("let containsUnreadableProjection")
                && inspectionRegion.contains("let runtimeBinding")
                && inspectionRegion.contains("ChatAXTargetInspection(")
                && inspectionRegion.contains("return .success("),
            "system inspection 必须把零或多个可读候选交给公共 seam 进行 exact 选择")
        let distinguishesMissingFrameworkFromUnreadable: (String) -> Bool = { region in
            region.contains("chatAXFrameworkBundlePathState(at: url)")
                && region.contains("case .missing:")
                && region.components(separatedBy: "return .missing").count - 1 == 1
                && region.contains("case .unreadable:")
                && region.contains("return .unreadable")
                && !region.contains("fileExists(")
        }
        expect(
            distinguishesMissingFrameworkFromUnreadable(frameworkIdentityRegion)
                && frameworkSetRegion.contains(
                    "if hasMissingFramework { return .mismatch }")
                && frameworkSetRegion.contains(
                    "if hasUnreadableFramework { return .unreadable }"),
            "framework path absent 才是 mismatch；权限、I/O 或 metadata 失败必须保持 unreadable")
        let missingAsUnreadableMutation = frameworkIdentityRegion.replacingOccurrences(
            of: "return .missing", with: "return .unreadable")
        expect(
            !distinguishesMissingFrameworkFromUnreadable(missingAsUnreadableMutation),
            "framework path 分类契约必须拒绝把 missing 与 unreadable 重新折叠")
        expect(
            revalidationRegion.contains("readAnchorFacts(")
                && revalidationRegion.contains("ChatAXSurfaceVerifier.verifyChat("),
            "运行中复核必须重新观察 facts 并走同一个 exact verifier")
        expect(
            !runtime.contains("surface: .chatGPTDesktopAX")
                && !runtime.contains("surfaceSignatures.first"),
            "system adapter 不得绕过 verified wrapper 直接赋 Chat 常量或任选摘要")

        let decoyRuntime = """
            private final class DecoyObserver {
                private func inspectIdentities() {
                    readAnchorFacts()
                    ChatAXSurfaceVerifier.verifyChat()
                    ChatAXTargetIdentity.observedChatGPTDesktopAX()
                }
            }
            final class SystemChatAXTraceObserver: ChatAXTraceObserving {
                private func inspectIdentities() { bypassVerification() }
            }
            """
        let decoyCode = strippingComments(decoyRuntime).codeWithoutStringLiterals
        let realObserver = chatAXBracedDeclarationRegion(
            "final class SystemChatAXTraceObserver: ChatAXTraceObserving", in: decoyCode)
        let realIdentity = realObserver.flatMap {
            chatAXFunctionRegion("private func inspectIdentities(", in: $0)
        }
        expect(
            realIdentity?.contains("ChatAXSurfaceVerifier.verifyChat(") == false,
            "前置 decoy type 的正确链不得替真实 System observer identity 假绿")
    }

    suite("Chat AX tracer 证据：fixture 走 observer→detector→受限 JSON 完整路径") {
        let fixtureSignals = [
            ChatAXStructuralSignal(
                sequence: 1, elapsedMilliseconds: 0, windowOrdinal: 1,
                kind: .composerSubmitted),
            ChatAXStructuralSignal(
                sequence: 2, elapsedMilliseconds: 100, windowOrdinal: 1,
                kind: .generationControl(isVisible: true)),
            ChatAXStructuralSignal(
                sequence: 3, elapsedMilliseconds: 200, windowOrdinal: 1,
                kind: .assistantRegion(structureRevision: 1, isStable: true)),
            ChatAXStructuralSignal(
                sequence: 4, elapsedMilliseconds: 300, windowOrdinal: 1,
                kind: .generationControl(isVisible: false)),
            ChatAXStructuralSignal(
                sequence: 5, elapsedMilliseconds: 800, windowOrdinal: 1,
                kind: .stabilityCheckpoint),
        ]
        let allowedIdentity = chatAXIdentity()
        let observer = ChatAXFixtureObserver(
            observedTarget: chatAXObservedTarget(),
            signalsOnStart: fixtureSignals)
        let tracer = ChatAXTracerSession(
            allowlist: ChatAXVersionAllowlist(identities: [allowedIdentity]),
            observer: observer)
        tracer.guiDidBecomeAlive()
        expect(
            tracer.beginExplicitTrace(scenarioNumber: 16) == .started,
            "脱敏 fixture 必须经真实 observer seam 启动")
        expect(
            tracer.evidenceMaterializationCount == 0,
            "observer 同步送入全部 signals 后仍不得在热路径 materialize evidence")

        guard let evidence = tracer.evidence else {
            expect(false, "运行中的 tracer 必须提供内存证据")
            return
        }
        expect(evidence.targetIdentity == allowedIdentity, "证据必须绑定精确版本身份")
        expect(evidence.scenarioNumber == 16, "证据必须携带场景编号")
        expect(evidence.signals == fixtureSignals, "证据只保存已允许的结构信号时序")
        expect(evidence.semanticEvents.map(\.event) == [.taskStart, .stop], "完整路径必须产出两个语义")
        expect(
            evidence.counts
                == ChatAXTraceCounts(signalCount: 5, taskStartCount: 1, stopCount: 1),
            "计数必须与同一证据内的信号和事件一致")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard
            let data = try? encoder.encode(evidence),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let json = String(data: data, encoding: .utf8)
        else {
            expect(false, "受限证据必须可编码为 JSON")
            return
        }
        expect(
            Set(object.keys)
                == [
                    "targetIdentity", "scenarioNumber", "signals", "semanticEvents", "counts",
                ],
            "证据顶层不得混入日志、权限、声音或 activation 状态")
        expect(
            json.contains("\"surfaceSignature\":\"\(chatAXSurfaceSignature("a").rawValue)\"")
                && !json.contains("AXIdentifier"),
            "证据只允许保留 surface SHA-256，不得导出原始 AX identifier")
        for forbidden in [
            "prompt", "response", "conversationTitle", "helpText", "clipboard", "uiTree",
            "soundOutcome", "currentActivation",
        ] {
            expect(
                !json.localizedCaseInsensitiveContains(forbidden),
                "证据 JSON 禁止出现 \(forbidden) 字段")
        }
        expect(
            tracer.evidenceMaterializationCount == 1,
            "运行中显式读取 evidence 只 materialize 一次即时 snapshot")

        tracer.endExplicitTrace()
        expect(
            tracer.evidenceMaterializationCount == 2,
            "显式 stop 必须只 materialize 一次 immutable final evidence")
        let finalizedEvidence = tracer.evidence
        let countAfterFinalRead = tracer.evidenceMaterializationCount
        expect(finalizedEvidence == evidence, "显式 stop 后仍只保留本次脱敏内存证据")
        expect(
            countAfterFinalRead == 2 && tracer.evidence == finalizedEvidence
                && tracer.evidenceMaterializationCount == countAfterFinalRead,
            "停止后重复读取必须复用 final evidence，不得继续复制 arrays")
    }

    suite("Chat AX tracer evidence accumulator：高频 session 热路径与退出 finalization") {
        let allowedIdentity = chatAXIdentity()
        let observer = ChatAXFixtureObserver(observedTarget: chatAXObservedTarget())
        let tracer = ChatAXTracerSession(
            allowlist: ChatAXVersionAllowlist(identities: [allowedIdentity]),
            observer: observer)
        tracer.guiDidBecomeAlive()
        expect(
            tracer.beginExplicitTrace(scenarioNumber: 42) == .started,
            "高频 evidence fixture 必须经真实 Session.consume 路径启动")
        for sequence in 1...10_000 {
            observer.emit(
                ChatAXStructuralSignal(
                    sequence: sequence,
                    elapsedMilliseconds: sequence,
                    windowOrdinal: 1,
                    kind: .unrelatedStructureChanged))
        }
        expect(
            tracer.evidenceMaterializationCount == 0,
            "10k signal 的 Session.consume 热路径必须只累积，不得逐条 materialize")
        guard let retainedRunningSnapshot = tracer.evidence else {
            expect(false, "运行中必须能显式取得 10k signal snapshot")
            return
        }
        expect(
            tracer.evidenceMaterializationCount == 1
                && retainedRunningSnapshot.signals.count == 10_000
                && retainedRunningSnapshot.counts
                    == ChatAXTraceCounts(
                        signalCount: 10_000,
                        taskStartCount: 0,
                        stopCount: 0),
            "只有显式读取才 materialize 一次完整运行中 snapshot")

        let laterSignal = ChatAXStructuralSignal(
            sequence: 10_001,
            elapsedMilliseconds: 10_001,
            windowOrdinal: 1,
            kind: .unrelatedStructureChanged)
        observer.emit(laterSignal)
        expect(
            retainedRunningSnapshot.signals.count == 10_000
                && tracer.evidenceMaterializationCount == 1,
            "保留的运行中 snapshot 必须不可变，后续 append 也不得隐式 materialize")

        let exitSignal = ChatAXStructuralSignal(
            sequence: 10_002,
            elapsedMilliseconds: 10_002,
            windowOrdinal: 0,
            kind: .applicationExited)
        observer.emit(exitSignal)
        expect(
            !tracer.isRunning && observer.stopCount == 1
                && tracer.evidenceMaterializationCount == 2,
            "applicationExited 必须先记录 signal，再只生成一次 final snapshot 并停止")
        let finalEvidence = tracer.evidence
        let materializationsAfterFinalRead = tracer.evidenceMaterializationCount
        expect(
            finalEvidence?.targetIdentity == allowedIdentity
                && finalEvidence?.scenarioNumber == 42
                && finalEvidence?.signals.count == 10_002
                && finalEvidence?.signals.suffix(2) == [laterSignal, exitSignal],
            "final evidence 必须完整包含运行中 snapshot 之后的 signal 与退出事实")
        expect(
            materializationsAfterFinalRead == 2
                && tracer.evidence == finalEvidence
                && tracer.evidenceMaterializationCount == materializationsAfterFinalRead,
            "停止后重复读取必须复用 immutable final evidence")
    }
}
