import ClaudioCore
import ClaudioGUICore
import CoreFoundation
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
        && normalizedIntegerReader.components(
            separatedBy: "ChatAXWindowOrdinalDecoder.decode(value)"
        ).count - 1 == 1
        && normalizedIntegerReader.contains(
            "let ordinal = ChatAXWindowOrdinalDecoder.decode(value)")
        && !normalizedIntegerReader.contains(".intValue")
        && !normalizedIntegerReader.contains("value as")
        && !normalizedIntegerReader.contains("??")
        && normalizedIntegerReader.components(separatedBy: "return").count - 1 == 5
        && normalizedIntegerReader.components(separatedBy: ".success(").count - 1 == 2
        && normalizedIntegerReader.contains(
            "guard result == .success, let value, "
                + "let ordinal = ChatAXWindowOrdinalDecoder.decode(value) else { "
                + "return .failure(.unreadable) } return .success(ordinal)")
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

private final class ChatAXConcurrentSamplerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var active = 0
    private var maximumActive = 0

    func begin() {
        lock.lock()
        starts += 1
        active += 1
        maximumActive = max(maximumActive, active)
        lock.unlock()
    }

    func finish() {
        lock.lock()
        active -= 1
        lock.unlock()
    }

    var snapshot: (starts: Int, active: Int, maximumActive: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (starts, active, maximumActive)
    }
}

@MainActor
private func chatAXEventually(
    attempts: Int = 1_000,
    condition: () -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return condition()
}

@MainActor
private func chatAXPumpRunLoop(
    mode: RunLoop.Mode,
    until deadline: Date,
    condition: () -> Bool
) -> Bool {
    while !condition(), Date() < deadline {
        _ = RunLoop.main.run(
            mode: mode,
            before: min(deadline, Date(timeIntervalSinceNow: 0.01)))
    }
    return condition()
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

    suite("Chat AX tracer event query gate：每代只运行一个并合并最新 successor") {
        var gate = ChatAXEventQueryGate()
        expect(
            gate.enqueue(elapsedMilliseconds: 10) == nil,
            "未启动 session 不得创建 event query")
        gate.beginSession()
        guard
            case .start(let first)? = gate.enqueue(elapsedMilliseconds: 100),
            case .coalesced(let second)? = gate.enqueue(elapsedMilliseconds: 200),
            case .coalesced(let latest)? = gate.enqueue(elapsedMilliseconds: 300)
        else {
            expect(false, "第一条 event 必须启动，后续 event 必须合并")
            return
        }
        expect(first.elapsedMilliseconds == 100, "active request 必须保留 callback 抵达时间")
        expect(latest.elapsedMilliseconds == 300, "coalescing 必须保留最新 callback 的抵达时间")
        expect(second != latest, "更新 pending 必须产生独立 token，让旧结果可判 stale")
        expect(
            gate.complete(first) == .start(latest),
            "active 完成后只能启动最新 coalesced successor")
        expect(
            gate.complete(second) == .stale,
            "被后续 callback 替换的 pending token 永不得提交")
        expect(gate.complete(latest) == .idle, "successor 完成后 gate 必须恢复 idle")

        guard case .start(let oldGeneration)? = gate.enqueue(elapsedMilliseconds: 400) else {
            expect(false, "idle gate 必须允许下一次 query")
            return
        }
        gate.endSession()
        gate.beginSession()
        guard case .start(let newGeneration)? = gate.enqueue(elapsedMilliseconds: 500) else {
            expect(false, "restart 必须允许新 generation query")
            return
        }
        expect(
            gate.complete(oldGeneration) == .stale,
            "stop/restart 后迟到旧结果不得清理或提交新 generation")
        expect(gate.complete(newGeneration) == .idle, "新 generation 必须独立完成")
    }

    await suite("Chat AX tracer event coordinator：后台 heartbeat 与 storm latest-wins") {
        let permits = DispatchSemaphore(value: 0)
        let probe = ChatAXConcurrentSamplerProbe()
        var committed: [(elapsedMilliseconds: Int, sample: Int)] = []
        var invalidationCount = 0
        let coordinator = ChatAXEventQueryCoordinator<Int, Int>(
            contentionTimeoutMilliseconds: 750,
            attemptTimeoutNanoseconds: 2_000_000_000,
            sampler: { input in
                probe.begin()
                defer { probe.finish() }
                _ = chatAXBlockingValidationSample(permits)
                return input
            },
            didProduce: { elapsedMilliseconds, sample in
                committed.append((elapsedMilliseconds, sample))
            },
            didInvalidate: {
                invalidationCount += 1
            })
        coordinator.beginSession()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            permits.signal()
            permits.signal()
        }

        let enqueueStartedAt = ProcessInfo.processInfo.systemUptime
        coordinator.enqueue(1, elapsedMilliseconds: 123)
        let enqueueElapsed = ProcessInfo.processInfo.systemUptime - enqueueStartedAt
        let mainActorHeartbeat = ChatAXThreadSafeCounter()
        Task { @MainActor in
            mainActorHeartbeat.increment()
        }
        for value in 2...1_001 {
            coordinator.enqueue(value, elapsedMilliseconds: 122 + value)
        }
        expect(
            enqueueElapsed < 0.1,
            "阻塞 sampler 必须在后台运行，MainActor enqueue 不得等待")
        expect(
            await chatAXEventually { probe.snapshot.starts == 1 },
            "notification storm 期间只能启动第一个 sampler")
        expect(
            await chatAXEventually {
                mainActorHeartbeat.value == 1 && probe.snapshot.active == 1
            },
            "阻塞 sampler 未释放时，后排入的独立 MainActor heartbeat 仍必须运行")
        expect(
            probe.snapshot.starts == 1 && committed.isEmpty,
            "active sampler 阻塞时 1000 条 callback 只能 latest-wins 合并，不能堆 worker")

        permits.signal()
        expect(
            await chatAXEventually {
                committed.count == 1 && probe.snapshot.starts == 2
            },
            "active 完成后必须只启动一个 latest successor")
        permits.signal()
        expect(
            await chatAXEventually { committed.count == 2 },
            "latest successor 必须可以独立完成")
        expect(
            committed.map(\.sample) == [1, 1_001]
                && committed.map(\.elapsedMilliseconds) == [123, 1_123],
            "storm 只能提交首条与最新 payload，并保留各自 callback arrival time")
        expect(
            probe.snapshot.maximumActive == 1 && invalidationCount == 0,
            "event sampler 必须 single-flight，正常 coalescing 不得 invalidate")
        coordinator.endSession()
    }

    await suite("Chat AX tracer event coordinator：shared lease busy 只延后并可恢复") {
        let systemGate = ChatAXSystemQueryWorkerGate.shared
        guard let blockingLease = systemGate.acquire() else {
            expect(false, "deferred fixture 必须先取得唯一 shared lease")
            return
        }
        let samplerStarts = ChatAXThreadSafeCounter()
        var committed: [(elapsedMilliseconds: Int, sample: Int)] = []
        var invalidationCount = 0
        let coordinator = ChatAXEventQueryCoordinator<Int, Int>(
            contentionTimeoutMilliseconds: 2_000,
            attemptTimeoutNanoseconds: 500_000_000,
            retryInterval: 0.005,
            sampler: { input in
                samplerStarts.increment()
                return input
            },
            didProduce: { elapsedMilliseconds, sample in
                committed.append((elapsedMilliseconds, sample))
            },
            didInvalidate: {
                invalidationCount += 1
            })
        coordinator.beginSession()
        coordinator.enqueue(17, elapsedMilliseconds: 321)
        try? await Task.sleep(nanoseconds: 40_000_000)
        expect(
            samplerStarts.value == 0 && committed.isEmpty && invalidationCount == 0,
            "shared lease contention 不得启动 sampler、emit 或冒充 identity drift")

        systemGate.release(blockingLease)
        expect(
            await chatAXEventually { committed.count == 1 },
            "shared lease 恢复后 common-mode retry 必须完成原请求")
        expect(
            samplerStarts.value == 1
                && committed.first?.elapsedMilliseconds == 321
                && committed.first?.sample == 17
                && invalidationCount == 0,
            "deferred recovery 必须只采样并提交一次，且保留 arrival time")
        coordinator.endSession()
    }

    await suite("Chat AX tracer event coordinator：deferred retry 在 common run-loop mode 恢复") {
        let trackingMode = RunLoop.Mode("ChatAXEventTrackingTestMode")
        CFRunLoopAddCommonMode(
            CFRunLoopGetMain(),
            CFRunLoopMode(rawValue: trackingMode.rawValue as CFString))
        let systemGate = ChatAXSystemQueryWorkerGate.shared
        guard let blockingLease = systemGate.acquire() else {
            expect(false, "common-mode fixture 必须先取得 shared lease")
            return
        }
        let samplerStarts = ChatAXThreadSafeCounter()
        let clockReads = ChatAXThreadSafeCounter()
        var committed: [Int] = []
        var invalidationCount = 0
        let coordinator = ChatAXEventQueryCoordinator<Int, Int>(
            contentionTimeoutMilliseconds: 1_000,
            attemptTimeoutNanoseconds: 500_000_000,
            retryInterval: 0.05,
            clockMilliseconds: {
                clockReads.increment()
                return 1_000
            },
            sampler: { input in
                samplerStarts.increment()
                return input
            },
            didProduce: { _, sample in
                committed.append(sample)
            },
            didInvalidate: {
                invalidationCount += 1
            })
        coordinator.beginSession()
        coordinator.enqueue(23, elapsedMilliseconds: 456)
        expect(
            await chatAXEventually { clockReads.value >= 3 },
            "释放 lease 前必须确认首次 attempt 已 deferred 且 retry timer 已排入")
        expect(
            clockReads.value >= 3
                && samplerStarts.value == 0
                && committed.isEmpty
                && invalidationCount == 0,
            "已安装 retry 时仍不得绕过 busy lease 偷跑 sampler")

        systemGate.release(blockingLease)
        let retryFiredInTrackingMode = chatAXPumpRunLoop(
            mode: trackingMode,
            until: Date(timeIntervalSinceNow: 0.75)
        ) {
            samplerStarts.value == 1
        }
        expect(
            retryFiredInTrackingMode,
            "common-mode retry 必须只泵 event-tracking mode 也能启动；default-only timer 会失败")
        expect(
            await chatAXEventually { committed == [23] },
            "tracking-mode retry 启动后必须正常提交原请求")
        expect(
            samplerStarts.value == 1 && invalidationCount == 0,
            "common-mode 恢复必须只运行并提交一次，不得误失效")
        coordinator.endSession()
    }

    await suite("Chat AX tracer event coordinator：contention 总期限到期只失效一次") {
        let systemGate = ChatAXSystemQueryWorkerGate.shared
        guard let blockingLease = systemGate.acquire() else {
            expect(false, "expiry fixture 必须先取得唯一 shared lease")
            return
        }
        let samplerStarts = ChatAXThreadSafeCounter()
        var commitCount = 0
        var invalidationCount = 0
        let coordinator = ChatAXEventQueryCoordinator<Int, Int>(
            contentionTimeoutMilliseconds: 100,
            attemptTimeoutNanoseconds: 500_000_000,
            retryInterval: 0.005,
            sampler: { input in
                samplerStarts.increment()
                return input
            },
            didProduce: { _, _ in
                commitCount += 1
            },
            didInvalidate: {
                invalidationCount += 1
            })
        coordinator.beginSession()
        coordinator.enqueue(18, elapsedMilliseconds: 322)
        expect(
            await chatAXEventually { invalidationCount == 1 },
            "shared lease 超过 bounded contention deadline 必须确定 fail closed")
        expect(
            samplerStarts.value == 0 && commitCount == 0,
            "contention expiry 前后都不得绕过 shared lease 启动 sampler")

        systemGate.release(blockingLease)
        try? await Task.sleep(nanoseconds: 30_000_000)
        expect(
            samplerStarts.value == 0 && commitCount == 0 && invalidationCount == 1,
            "expired request 在 lease 恢复后不得复活或重复 invalidate")
        coordinator.endSession()
    }

    await suite("Chat AX tracer event coordinator：timeout 与 unreadable 只失效一次") {
        let permits = DispatchSemaphore(value: 0)
        let probe = ChatAXConcurrentSamplerProbe()
        var timeoutCommits = 0
        var timeoutInvalidations = 0
        let timeoutCoordinator = ChatAXEventQueryCoordinator<Int, Int>(
            contentionTimeoutMilliseconds: 500,
            attemptTimeoutNanoseconds: 20_000_000,
            sampler: { input in
                probe.begin()
                defer { probe.finish() }
                _ = chatAXBlockingValidationSample(permits)
                return input
            },
            didProduce: { _, _ in
                timeoutCommits += 1
            },
            didInvalidate: {
                timeoutInvalidations += 1
            })
        timeoutCoordinator.beginSession()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            permits.signal()
        }
        timeoutCoordinator.enqueue(1, elapsedMilliseconds: 10)
        expect(
            await chatAXEventually { probe.snapshot.starts == 1 },
            "timeout fixture 必须真的启动阻塞 sampler")
        expect(
            await chatAXEventually { timeoutInvalidations == 1 },
            "attempt timeout 必须确定 fail closed")
        permits.signal()
        expect(
            await chatAXEventually { probe.snapshot.active == 0 },
            "迟到 worker 必须最终退出并归还 shared lease")
        try? await Task.sleep(nanoseconds: 20_000_000)
        expect(
            timeoutCommits == 0 && timeoutInvalidations == 1,
            "timeout 后的迟到 completion 不得 emit 或重复 invalidate")
        timeoutCoordinator.endSession()

        var unreadableCommits = 0
        var unreadableInvalidations = 0
        let unreadableCoordinator = ChatAXEventQueryCoordinator<Int, Int>(
            sampler: { _ in nil },
            didProduce: { _, _ in
                unreadableCommits += 1
            },
            didInvalidate: {
                unreadableInvalidations += 1
            })
        unreadableCoordinator.beginSession()
        unreadableCoordinator.enqueue(2, elapsedMilliseconds: 20)
        expect(
            await chatAXEventually { unreadableInvalidations == 1 },
            "unreadable/mismatch 的 nil sample 必须确定 fail closed")
        try? await Task.sleep(nanoseconds: 20_000_000)
        expect(
            unreadableCommits == 0 && unreadableInvalidations == 1,
            "nil sample 不得 emit 或重复 invalidate")
        unreadableCoordinator.endSession()
    }

    await suite("Chat AX tracer event coordinator：stop/restart 丢弃旧 generation 结果") {
        let oldPermit = DispatchSemaphore(value: 0)
        let probe = ChatAXConcurrentSamplerProbe()
        var committed: [(elapsedMilliseconds: Int, sample: Int)] = []
        var invalidationCount = 0
        let coordinator = ChatAXEventQueryCoordinator<Int, Int>(
            contentionTimeoutMilliseconds: 2_000,
            attemptTimeoutNanoseconds: 1_000_000_000,
            retryInterval: 0.005,
            sampler: { input in
                probe.begin()
                defer { probe.finish() }
                if input == 1 {
                    _ = chatAXBlockingValidationSample(oldPermit)
                }
                return input
            },
            didProduce: { elapsedMilliseconds, sample in
                committed.append((elapsedMilliseconds, sample))
            },
            didInvalidate: {
                invalidationCount += 1
            })
        coordinator.beginSession()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            oldPermit.signal()
        }
        coordinator.enqueue(1, elapsedMilliseconds: 100)
        expect(
            await chatAXEventually { probe.snapshot.starts == 1 },
            "旧 generation sampler 必须已进入运行态")

        coordinator.endSession()
        coordinator.beginSession()
        coordinator.enqueue(2, elapsedMilliseconds: 200)
        try? await Task.sleep(nanoseconds: 20_000_000)
        expect(
            committed.isEmpty && invalidationCount == 0 && probe.snapshot.starts == 1,
            "旧 worker 未退出时新 generation 必须 deferred，不能堆第二个 worker")
        oldPermit.signal()
        expect(
            await chatAXEventually { committed.count == 1 },
            "旧 worker 退出后新 generation 必须独立恢复")
        expect(
            committed.first?.sample == 2
                && committed.first?.elapsedMilliseconds == 200
                && invalidationCount == 0
                && probe.snapshot.maximumActive == 1,
            "旧 generation 的迟到结果不得 emit、invalidate 或清除新请求")
        coordinator.endSession()
    }

    await suite("Chat AX tracer event coordinator：reentrant restart 不启动旧 successor") {
        let oldSuccessorStarts = ChatAXThreadSafeCounter()
        let newGenerationStarts = ChatAXThreadSafeCounter()
        var committed: [Int] = []
        var invalidationCount = 0
        var coordinator: ChatAXEventQueryCoordinator<Int, Int>!
        coordinator = ChatAXEventQueryCoordinator<Int, Int>(
            sampler: { input in
                if input == 2 { oldSuccessorStarts.increment() }
                if input == 3 { newGenerationStarts.increment() }
                return input
            },
            didProduce: { _, sample in
                committed.append(sample)
                if sample == 1 {
                    coordinator.endSession()
                    coordinator.beginSession()
                    coordinator.enqueue(3, elapsedMilliseconds: 300)
                }
            },
            didInvalidate: {
                invalidationCount += 1
            })
        coordinator.beginSession()
        coordinator.enqueue(1, elapsedMilliseconds: 100)
        coordinator.enqueue(2, elapsedMilliseconds: 200)
        expect(
            await chatAXEventually { committed.count == 2 },
            "didProduce 内 stop/restart 后的新 generation 必须独立完成")
        expect(
            committed == [1, 3]
                && oldSuccessorStarts.value == 0
                && newGenerationStarts.value == 1
                && invalidationCount == 0,
            "reentrant callback 后必须重验 generation，不能启动已 promote 的旧 successor")
        coordinator.endSession()
        coordinator = nil
    }

    await suite("Chat AX tracer event coordinator：先 promote successor 再发布 reentrant callback") {
        var committed: [Int] = []
        var invalidationCount = 0
        var coordinator: ChatAXEventQueryCoordinator<Int, Int>!
        coordinator = ChatAXEventQueryCoordinator<Int, Int>(
            sampler: { input in input },
            didProduce: { _, sample in
                committed.append(sample)
                if sample == 1 {
                    coordinator.enqueue(3, elapsedMilliseconds: 300)
                }
            },
            didInvalidate: {
                invalidationCount += 1
            })
        coordinator.beginSession()
        coordinator.enqueue(1, elapsedMilliseconds: 100)
        coordinator.enqueue(2, elapsedMilliseconds: 200)
        expect(
            await chatAXEventually { committed.count == 3 },
            "首个 publish 内重入 enqueue 后，既有 successor 与新 pending 都必须完成")
        expect(
            committed == [1, 2, 3] && invalidationCount == 0,
            "coordinator 必须在 didProduce 前 promote 既有 successor，不能被重入请求覆盖")
        coordinator.endSession()
        coordinator = nil
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

    suite("Chat AX tracer event surface：callback lineage 必须绑定同一 Chat anchor/window") {
        let sampleID = UUID(uuidString: "00000000-0000-0000-0000-000000000053")!
        let otherSampleID = UUID(uuidString: "00000000-0000-0000-0000-000000000054")!
        let node: (Int, UUID) -> ChatAXLineageNodeIdentity = { ordinal, namespace in
            ChatAXLineageNodeIdentity(sampleID: namespace, ordinal: ordinal)
        }
        let focusedLeaf = node(1, sampleID)
        let eventLeaf = node(2, sampleID)
        let otherEventLeaf = node(3, sampleID)
        let anchor = node(4, sampleID)
        let otherAnchor = node(5, sampleID)
        let window = node(6, sampleID)
        let otherWindow = node(7, sampleID)
        let focusedLineage = [focusedLeaf, anchor, window]
        let eventLineage = [eventLeaf, anchor, window]
        guard
            let facts = ChatAXSurfaceAnchorFacts(
                windowRole: "AXWindow",
                windowSubrole: "AXStandardWindow",
                anchorRole: "AXGroup",
                anchorSubrole: nil,
                anchorIdentifier: "chat-surface-root",
                anchorDepth: 1),
            let driftedFacts = ChatAXSurfaceAnchorFacts(
                windowRole: "AXWindow",
                windowSubrole: "AXStandardWindow",
                anchorRole: "AXGroup",
                anchorSubrole: nil,
                anchorIdentifier: "codex-surface-root",
                anchorDepth: 1)
        else {
            expect(false, "event surface fixtures 必须合法")
            return
        }
        let makeSample:
            (
                [ChatAXLineageNodeIdentity],
                [ChatAXLineageNodeIdentity],
                [ChatAXLineageNodeIdentity],
                [ChatAXLineageNodeIdentity],
                ChatAXSurfaceAnchorFacts,
                ChatAXSurfaceAnchorFacts,
                Int
            ) -> ChatAXEventSurfaceBindingSample = {
                focusedBefore,
                focusedAfter,
                eventBefore,
                eventAfter,
                factsBefore,
                factsAfter,
                windowOrdinal in
                ChatAXEventSurfaceBindingSample(
                    focusedBefore: ChatAXSurfaceLineageSample(
                        nodes: focusedBefore, anchorFacts: factsBefore),
                    focusedAfter: ChatAXSurfaceLineageSample(
                        nodes: focusedAfter, anchorFacts: factsAfter),
                    eventBefore: eventBefore,
                    eventAfter: eventAfter,
                    windowOrdinal: windowOrdinal)
            }
        let stableSample = makeSample(
            focusedLineage,
            focusedLineage,
            eventLineage,
            eventLineage,
            facts,
            facts,
            42)
        let signature = ChatAXSurfaceSignature.v1(anchorFacts: facts)
        let verified = ChatAXEventSurfaceBindingVerifier.verify(
            stableSample,
            allowedSignatures: [signature])
        expect(
            verified?.surfaceSignature == signature && verified?.windowOrdinal == 42,
            "同一 sample、anchor 与 window 内的不同 descendant event 必须 exact 通过")

        let maximumDepthLineage = (20...28).map { node($0, sampleID) }
        if let maximumDepthFacts = ChatAXSurfaceAnchorFacts(
            windowRole: "AXWindow",
            windowSubrole: nil,
            anchorRole: "AXGroup",
            anchorSubrole: nil,
            anchorIdentifier: "deep-chat-surface-root",
            anchorDepth: ChatAXSurfaceAnchorFacts.maximumAnchorDepth)
        {
            let maximumDepthSample = makeSample(
                maximumDepthLineage,
                maximumDepthLineage,
                maximumDepthLineage,
                maximumDepthLineage,
                maximumDepthFacts,
                maximumDepthFacts,
                99)
            expect(
                ChatAXEventSurfaceBindingVerifier.verify(
                    maximumDepthSample,
                    allowedSignatures: [
                        ChatAXSurfaceSignature.v1(anchorFacts: maximumDepthFacts)
                    ])?.windowOrdinal == 99,
                "maximumAnchorDepth 的边界 lineage 必须可验证，不能有 off-by-one")
        } else {
            expect(false, "maximum depth fixture 必须合法")
        }

        let tooDeep = (10...19).map { node($0, sampleID) }
        let crossNamespaceEvent = [
            node(2, otherSampleID),
            node(4, otherSampleID),
            node(6, otherSampleID),
        ]
        let invalidSamples = [
            makeSample(
                focusedLineage, focusedLineage,
                [eventLeaf, anchor, otherWindow], [eventLeaf, anchor, otherWindow],
                facts, facts, 42),
            makeSample(
                focusedLineage, focusedLineage,
                [eventLeaf, otherAnchor, window], [eventLeaf, otherAnchor, window],
                facts, facts, 42),
            makeSample(
                focusedLineage, focusedLineage,
                [eventLeaf, window], [eventLeaf, window],
                facts, facts, 42),
            makeSample(
                [focusedLeaf, anchor, focusedLeaf, window],
                [focusedLeaf, anchor, focusedLeaf, window],
                eventLineage, eventLineage, facts, facts, 42),
            makeSample(
                tooDeep, tooDeep, eventLineage, eventLineage, facts, facts, 42),
            makeSample(
                focusedLineage, [focusedLeaf, otherAnchor, window],
                eventLineage, eventLineage, facts, facts, 42),
            makeSample(
                focusedLineage, focusedLineage,
                eventLineage, [otherEventLeaf, anchor, window], facts, facts, 42),
            makeSample(
                focusedLineage, focusedLineage,
                eventLineage, eventLineage, facts, driftedFacts, 42),
            makeSample(
                focusedLineage, focusedLineage,
                crossNamespaceEvent, crossNamespaceEvent, facts, facts, 42),
            makeSample(
                focusedLineage, focusedLineage,
                [node(-1, sampleID), anchor, window],
                [node(-1, sampleID), anchor, window],
                facts, facts, 42),
            makeSample(
                focusedLineage, focusedLineage,
                eventLineage, eventLineage, facts, facts, -1),
        ]
        for invalidSample in invalidSamples {
            expect(
                ChatAXEventSurfaceBindingVerifier.verify(
                    invalidSample,
                    allowedSignatures: [signature]) == nil,
                "other window/anchor、drift、loop、depth、namespace 或负 ordinal 必须拒绝")
        }
        expect(
            ChatAXEventSurfaceBindingVerifier.verify(
                stableSample,
                allowedSignatures: [chatAXSurfaceSignature("b")]) == nil,
            "未列入 allowlist 的 surface signature 必须拒绝")
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

    suite("Chat AX tracer window ordinal：只接受无损、非负的整数 CFNumber") {
        let accepted: [(CFTypeRef, Int)] = [
            (NSNumber(value: 0), 0),
            (NSNumber(value: Int8(1)), 1),
            (NSNumber(value: Int16(2)), 2),
            (NSNumber(value: Int32(3)), 3),
            (NSNumber(value: Int64(4)), 4),
            (NSNumber(value: 7), 7),
            (NSNumber(value: UInt8.max), Int(UInt8.max)),
            (NSNumber(value: UInt16.max), Int(UInt16.max)),
            (NSNumber(value: UInt32.max), Int(UInt32.max)),
            (NSNumber(value: Int.max), Int.max),
            (NSNumber(value: UInt64(Int.max)), Int.max),
        ]
        for (value, expected) in accepted {
            expect(
                ChatAXWindowOrdinalDecoder.decode(value) == expected,
                "合法整数 CFNumber 必须无损解码为 window ordinal：\(expected)")
        }

        let rejected: [CFTypeRef] = [
            kCFBooleanFalse,
            kCFBooleanTrue,
            NSNumber(value: -1),
            NSNumber(value: Int.min),
            NSNumber(value: Float(3.75)),
            NSNumber(value: Float(3.0)),
            NSNumber(value: Float.nan),
            NSNumber(value: Float.infinity),
            NSNumber(value: -Float.infinity),
            NSNumber(value: 3.75),
            NSNumber(value: 3.0),
            NSNumber(value: Double.nan),
            NSNumber(value: Double.infinity),
            NSNumber(value: -Double.infinity),
            NSNumber(value: UInt64(Int.max) + 1),
            NSNumber(value: UInt64.max),
            NSDecimalNumber(string: "3"),
            NSDecimalNumber.notANumber,
            "7" as CFString,
            kCFNull,
        ]
        for value in rejected {
            expect(
                ChatAXWindowOrdinalDecoder.decode(value) == nil,
                "boolean、浮点、负数、溢出或非数字 CF value 必须 fail closed")
        }
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

        var nonnegativeTimeDetector = ChatAXCandidateDetector()
        let negativeTimeOutcome = nonnegativeTimeDetector.consume(
            ChatAXStructuralSignal(
                sequence: 1, elapsedMilliseconds: -1, windowOrdinal: 3,
                kind: .composerSubmitted))
        let recoveredTimeOutcome = nonnegativeTimeDetector.consume(
            ChatAXStructuralSignal(
                sequence: 1, elapsedMilliseconds: Int.max, windowOrdinal: 3,
                kind: .composerSubmitted))
        expect(
            !negativeTimeOutcome.acceptedSignal && recoveredTimeOutcome.acceptedSignal,
            "负 elapsed 必须 fail closed 且不能推进 sequence，避免后续 association 算术溢出")

        var expiredSubmitDetector = ChatAXCandidateDetector(
            submitAssociationMilliseconds: 1_000,
            completionStabilityMilliseconds: 500)
        let expiredSubmitEvents = [
            ChatAXStructuralSignal(
                sequence: 1, elapsedMilliseconds: 0, windowOrdinal: 4,
                kind: .composerSubmitted),
            ChatAXStructuralSignal(
                sequence: 2, elapsedMilliseconds: 2_000, windowOrdinal: 4,
                kind: .composerSubmitted),
            ChatAXStructuralSignal(
                sequence: 3, elapsedMilliseconds: 2_100, windowOrdinal: 4,
                kind: .generationControl(isVisible: true)),
        ].flatMap { expiredSubmitDetector.consume($0).semanticEvents }
        expect(
            expiredSubmitEvents
                == [
                    ChatAXDetectedSemanticEvent(
                        signalSequence: 3,
                        windowOrdinal: 4,
                        event: .taskStart)
                ],
            "过期 pending submit 必须由下一次真实 submit 替换并恰好关联一次 task start")

        var expiredEpochDetector = ChatAXCandidateDetector(
            submitAssociationMilliseconds: 1_000,
            completionStabilityMilliseconds: 500)
        _ = expiredEpochDetector.consume(
            ChatAXStructuralSignal(
                sequence: 1, elapsedMilliseconds: 0, windowOrdinal: 6,
                kind: .composerSubmitted))
        _ = expiredEpochDetector.consume(
            ChatAXStructuralSignal(
                sequence: 2, elapsedMilliseconds: 100, windowOrdinal: 6,
                kind: .assistantRegion(structureRevision: 88, isStable: true)))
        _ = expiredEpochDetector.consume(
            ChatAXStructuralSignal(
                sequence: 3, elapsedMilliseconds: 2_000, windowOrdinal: 6,
                kind: .composerSubmitted))
        expect(
            expiredEpochDetector.assistantEpochState(forWindowOrdinal: 6)
                == ChatAXAssistantEpochState(),
            "替换过期 submit 必须通过 production seam 清空旧 assistant epoch")

        var duplicateSubmitDetector = ChatAXCandidateDetector(
            submitAssociationMilliseconds: 1_000,
            completionStabilityMilliseconds: 500)
        let duplicateSubmitEvents = [
            ChatAXStructuralSignal(
                sequence: 1, elapsedMilliseconds: 0, windowOrdinal: 5,
                kind: .composerSubmitted),
            ChatAXStructuralSignal(
                sequence: 2, elapsedMilliseconds: 900, windowOrdinal: 5,
                kind: .composerSubmitted),
            ChatAXStructuralSignal(
                sequence: 3, elapsedMilliseconds: 1_500, windowOrdinal: 5,
                kind: .generationControl(isVisible: true)),
        ].flatMap { duplicateSubmitDetector.consume($0).semanticEvents }
        expect(
            duplicateSubmitEvents.isEmpty,
            "关联窗内 duplicate submit 不得刷新 pending 时间戳后伪造 task start")

        var boundarySubmitDetector = ChatAXCandidateDetector(
            submitAssociationMilliseconds: 1_000,
            completionStabilityMilliseconds: 500)
        let boundarySubmitEvents = [
            ChatAXStructuralSignal(
                sequence: 1, elapsedMilliseconds: 0, windowOrdinal: 7,
                kind: .composerSubmitted),
            ChatAXStructuralSignal(
                sequence: 2, elapsedMilliseconds: 1_000, windowOrdinal: 7,
                kind: .composerSubmitted),
            ChatAXStructuralSignal(
                sequence: 3, elapsedMilliseconds: 1_501, windowOrdinal: 7,
                kind: .generationControl(isVisible: true)),
        ].flatMap { boundarySubmitDetector.consume($0).semanticEvents }
        expect(
            boundarySubmitEvents.isEmpty,
            "恰好位于 association 边界的 submit 仍是 duplicate，不得按 >= 提前换 epoch")

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

    suite("Chat AX tracer release boundary：Core/GUI whole-file DEBUG 且无 public API") {
        guard
            let rawCore = chatAXSource(
                "gui/Sources/ClaudioGUICore/ChatAXTracer.swift"),
            let rawRuntime = chatAXSource(
                "gui/Sources/ClaudioGUI/SystemChatAXTraceObserver.swift")
        else {
            expect(false, "必须能读取 tracer Core 与 GUI source 才能验证 release 编译边界")
            return
        }
        let hasWholeFileDebugBoundary: (String) -> Bool = { rawSource in
            let scanned = strippingComments(rawSource)
            guard scanned.unmodeledConstructs.isEmpty else { return false }
            let lines = scanned.codeWithoutStringLiterals
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard lines.first == "#if DEBUG", lines.last == "#endif" else {
                return false
            }
            let conditionalKeywords = ["#if", "#elseif", "#else", "#endif"]
            let conditionalDirectives = lines.compactMap { line in
                conditionalKeywords.first { keyword in
                    guard line.hasPrefix(keyword) else { return false }
                    let remainder = line.dropFirst(keyword.count)
                    guard let first = remainder.first else { return true }
                    return first.isWhitespace
                        || ((keyword == "#if" || keyword == "#elseif") && first == "(")
                }
            }
            return conditionalDirectives == ["#if", "#endif"]
        }
        let splitDebugBoundary: (String) -> String = { rawSource in
            var mutation = rawSource
            if let opening = mutation.range(of: "#if DEBUG\n") {
                mutation.replaceSubrange(opening, with: "#if DEBUG\n#endif\n")
            }
            if let closing = mutation.range(of: "\n#endif", options: .backwards) {
                mutation.replaceSubrange(closing, with: "\n#if DEBUG\n#endif")
            }
            return mutation
        }
        let scannedCore = strippingComments(rawCore)
        let core = scannedCore.codeWithoutStringLiterals
        expect(
            hasWholeFileDebugBoundary(rawCore) && hasWholeFileDebugBoundary(rawRuntime),
            "完整 tracer Core 与 GUI observer 必须各由单一 DEBUG 编译边界包围")
        expect(
            !hasWholeFileDebugBoundary(splitDebugBoundary(rawCore)),
            "Core gate 必须拒绝两个空 DEBUG guard 夹着 Release declarations 的 mutation")
        expect(
            !hasWholeFileDebugBoundary(splitDebugBoundary(rawRuntime)),
            "GUI gate 必须拒绝两个空 DEBUG guard 夹着 Release declarations 的 mutation")
        for (name, source) in [("Core", rawCore), ("GUI", rawRuntime)] {
            let beforeGuardMutation = "private let releaseLeak = 1\n" + source
            expect(
                !hasWholeFileDebugBoundary(beforeGuardMutation),
                "\(name) DEBUG guard 前出现任何真实 declaration 都必须失败")
            let afterGuardMutation = source + "\nprivate let releaseLeak = 1\n"
            expect(
                !hasWholeFileDebugBoundary(afterGuardMutation),
                "\(name) DEBUG guard 后出现任何真实 declaration 都必须失败")
            let movedDeclarationMutation = source.replacingOccurrences(
                of: "#if DEBUG\n",
                with: "#if DEBUG\n#endif\nprivate let releaseLeak = 1\n#if DEBUG\n")
            expect(
                !hasWholeFileDebugBoundary(movedDeclarationMutation),
                "\(name) declaration 被移到 outer DEBUG guard 之外必须失败")
        }
        let nestedDecoyMutation = rawCore.replacingOccurrences(
            of: "#if DEBUG\n",
            with: "#if DEBUG\n#if DEBUG\n#endif\n")
        expect(
            !hasWholeFileDebugBoundary(nestedDecoyMutation),
            "第二对 nested/decoy DEBUG directives 不得被单一 whole-file gate 接受")
        let tabbedElseifLeakMutation = rawCore.replacingOccurrences(
            of: "\n#endif",
            with: "\n#elseif\t!DEBUG\nprivate let releaseLeak = 1\n#endif")
        expect(
            !hasWholeFileDebugBoundary(tabbedElseifLeakMutation),
            "tab 分隔的合法 #elseif 也必须被识别，不能藏匿 Release declaration")
        let parenthesizedElseifLeakMutation = rawCore.replacingOccurrences(
            of: "\n#endif",
            with: "\n#elseif(!DEBUG)\nprivate let releaseLeak = 1\n#endif")
        expect(
            !hasWholeFileDebugBoundary(parenthesizedElseifLeakMutation),
            "无空格的合法 #elseif(...) 也必须被识别，不能藏匿 Release declaration")
        let tabbedElseLeakMutation = rawRuntime.replacingOccurrences(
            of: "\n#endif",
            with: "\n#else\t\nprivate let releaseLeak = 1\n#endif")
        expect(
            !hasWholeFileDebugBoundary(tabbedElseLeakMutation),
            "带 trailing tab 的 #else 也必须被识别，不能绕过 GUI whole-file gate")
        let commentDecoyControl =
            "// #if DEBUG\n// #endif\n" + rawCore
            + "\n/* #if DEBUG\n#endif */\n"
        expect(
            hasWholeFileDebugBoundary(commentDecoyControl),
            "注释中的条件编译字样不能污染真实 whole-file directive 计数")
        let stringDecoyDeclaration =
            "private let directiveDecoy = \"\"\"\n"
            + "#elseif !DEBUG\n#else\n#endif\n\"\"\"\n"
        let stringDecoyControl = rawRuntime.replacingOccurrences(
            of: "#if DEBUG\n",
            with: "#if DEBUG\n" + stringDecoyDeclaration)
        expect(
            hasWholeFileDebugBoundary(stringDecoyControl),
            "字符串中的条件编译字样不能污染真实 whole-file directive 计数")
        expect(
            scannedCore.unmodeledConstructs.isEmpty
                && !core
                    .split(whereSeparator: { !$0.isLetter })
                    .contains("public"),
            "Debug-only tracer 的跨 target API 必须收窄为 package")
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
        let permissiveIntegerBridgeMutation = rawRuntime.replacingOccurrences(
            of: "let ordinal = ChatAXWindowOrdinalDecoder.decode(value)",
            with: "let ordinal = (value as? NSNumber)?.intValue")
        expect(
            !chatAXLowLevelAttributeQueriesAreClosed(permissiveIntegerBridgeMutation),
            "typed reader 不能绕过 exact decoder，把 boolean/float 经 NSNumber 静默转整数")
        let decoyDecoderMutation = rawRuntime.replacingOccurrences(
            of: "let ordinal = ChatAXWindowOrdinalDecoder.decode(value)",
            with: """
                _ = ChatAXWindowOrdinalDecoder.decode(value)
                            let ordinal = (value as? NSNumber)?.intValue
                """)
        expect(
            !chatAXLowLevelAttributeQueriesAreClosed(decoyDecoderMutation),
            "保留一次 decoder decoy 也不能掩护实际 NSNumber.intValue 数据流")
        let fallbackBridgeMutation = rawRuntime.replacingOccurrences(
            of: "let ordinal = ChatAXWindowOrdinalDecoder.decode(value)",
            with: "let ordinal = ChatAXWindowOrdinalDecoder.decode(value) ?? (value as? Int)")
        expect(
            !chatAXLowLevelAttributeQueriesAreClosed(fallbackBridgeMutation),
            "decoder 返回 nil 后不得通过 CF bridge 回退，把 boolean 重新解释为 Int")
        let earlyIntegerSuccessMutation = rawRuntime.replacingOccurrences(
            of: "        guard\n            result == .success,",
            with: "        if result == .success { return .success(0) }\n"
                + "        guard\n            result == .success,")
        expect(
            !chatAXLowLevelAttributeQueriesAreClosed(earlyIntegerSuccessMutation),
            "typed reader 不得在 decoder guard 前新增早退 success 路径")
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
            let elementIdentityMapTypeRegion = chatAXBracedDeclarationRegion(
                "private final class SystemChatAXElementIdentityMap", in: runtime),
            let eventBindingRegion = chatAXFunctionRegion(
                "func readVerifiedEventBinding(", in: surfaceReaderTypeRegion),
            let focusedLineageRegion = chatAXFunctionRegion(
                "private func focusedLineageSnapshot(", in: surfaceReaderTypeRegion),
            let lineageRegion = chatAXFunctionRegion(
                "private func lineage(", in: surfaceReaderTypeRegion),
            let runtimeApplicationVerifierTypeRegion = chatAXBracedDeclarationRegion(
                "private enum SystemChatAXRuntimeApplicationVerifier", in: runtime),
            let runtimeApplicationMatchesRegion = chatAXFunctionRegion(
                "static func matches(", in: runtimeApplicationVerifierTypeRegion),
            let runtimeApplicationArchitectureRegion = chatAXFunctionRegion(
                "static func architecture(", in: runtimeApplicationVerifierTypeRegion),
            let eventQuerySamplerTypeRegion = chatAXBracedDeclarationRegion(
                "private enum SystemChatAXEventQuerySampler", in: runtime),
            let eventQuerySampleRegion = chatAXFunctionRegion(
                "static func sample(", in: eventQuerySamplerTypeRegion),
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
            let commitObservedEventRegion = chatAXFunctionRegion(
                "private func commitObservedEvent(", in: observerTypeRegion),
            let elapsedSignalRegion = chatAXFunctionRegion(
                "private func emitSignal(\n"
                    + "        kind: ChatAXStructuralSignalKind,\n"
                    + "        windowOrdinal: Int,\n"
                    + "        elapsedMilliseconds:",
                in: observerTypeRegion),
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
            eventQuerySamplerTypeRegion,
            runningCodeRegion,
            dynamicCodeRegion,
            dynamicSigningRegion,
            importedSigningRegion,
            processIncarnationRegion,
            normalizedPathRegion,
            runtimeApplicationVerifierTypeRegion,
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
                && (region.contains("readAnchorFacts(")
                    || region.contains("readVerifiedEventBinding("))
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
                && runtimeSamplerBracketsSurface(eventQuerySampleRegion)
                && eventQuerySampleRegion.contains(
                    "SystemChatAXRuntimeApplicationVerifier.matches(")
                && runtimeApplicationMatchesRegion.contains("architecture(for: application)")
                && runtimeApplicationMatchesRegion.contains("normalizedPath(bundleURL)")
                && runtimeApplicationMatchesRegion.contains("currentProcessIncarnation(")
                && runtimeApplicationMatchesRegion.contains(
                    "== binding.runtimeFacts.processIncarnation")
                && runtimeApplicationRegion.contains(
                    "SystemChatAXRuntimeApplicationVerifier.matches(")
                && architectureRegion.contains(
                    "SystemChatAXRuntimeApplicationVerifier.architecture(")
                && runtimeApplicationArchitectureRegion.contains(
                    "application.executableArchitecture")
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
                    "SystemChatAXRuntimeSampler.sample("),
            "full inspection、startup 与同步复验必须共用全局 system-query lease")
        let unleasedStartupMutation = startRegion.replacingOccurrences(
            of: "let workerLease = workerGate.acquire()",
            with: "let workerLease = workerGate.uncheckedLease()")
        expect(
            !ownsGlobalSystemQueryLease(
                unleasedStartupMutation,
                "startupRuntimeStillMatches("),
            "真实 startup 入口不得绕过旧阻塞 worker 的 single-flight gate")
        expect(
            targetStillMatchesRegion.contains("return .deferred")
                && !handleRegion.contains("ChatAXSystemQueryWorkerGate")
                && !handleRegion.contains("workerGate.acquire()"),
            "event callback 不得在 MainActor 争抢 lease；周期同步复验的 contention 仍须 deferred")
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
        let eventSamplerUsesBoundedCancellation: (String, String) -> Bool = {
            sampleRegion, surfaceRegion in
            chatAXFunctionContainsMarkersInOrder(
                [
                    "!Task.isCancelled",
                    "runningRuntimeFacts(",
                    "factsBefore == request.runtimeBinding.runtimeFacts",
                    "!Task.isCancelled",
                    "SystemChatAXReadBudget()",
                    "readVerifiedEventBinding(",
                    "!Task.isCancelled",
                    "runningRuntimeFacts(",
                    "factsAfter == factsBefore",
                    "verifiedBinding.surfaceSignature == request.target.identity.surfaceSignature",
                    "!Task.isCancelled",
                    "SystemChatAXRuntimeApplicationVerifier.matches(",
                    "!Task.isCancelled",
                ],
                inFunction: "static func sample(",
                source: sampleRegion)
                && chatAXFunctionContainsMarkersInOrder(
                    ["prepareForMessaging(element)", "AXUIElementGetPid(", "Task.isCancelled"],
                    inFunction: "private func belongsToTarget(",
                    source: surfaceRegion)
                && chatAXFunctionContainsMarkersInOrder(
                    [
                        "focusedLineageSnapshot(",
                        "lineage(",
                        "reader.integer(",
                        "lineage(",
                        "focusedLineageSnapshot(",
                        "reader.hasRemainingTime",
                    ],
                    inFunction: "func readVerifiedEventBinding(",
                    source: surfaceRegion)
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
                && eventSamplerUsesBoundedCancellation(
                    eventQuerySampleRegion,
                    surfaceReaderTypeRegion)
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
        let uncancelledEventSamplerMutation = eventQuerySampleRegion.replacingOccurrences(
            of: "!Task.isCancelled",
            with: "true")
        expect(
            !eventSamplerUsesBoundedCancellation(
                uncancelledEventSamplerMutation,
                surfaceReaderTypeRegion),
            "取消契约必须拒绝 event sampler 在 PID/surface/window phase 间忽略 timeout")
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
        expect(
            chatAXFunctionContainsMarkersInOrder(
                ["prepareForMessaging(element)", "AXUIElementGetPid("],
                inFunction: "private func belongsToTarget(",
                source: surfaceReaderTypeRegion),
            "lineage 中每个 element 必须在 PID query 前消费同一端到端预算")
        let eventSamplerReusesSingleAXBudget: (String) -> Bool = { region in
            let normalized = collapsingWhitespace(region)
            guard
                region.components(separatedBy: "SystemChatAXReadBudget()").count - 1 == 1,
                region.components(separatedBy: "budget: budget").count - 1 == 1,
                let factsRange = region.range(of: "let factsBefore ="),
                let budgetRange = region.range(of: "let budget = SystemChatAXReadBudget()"),
                let bindingRange = region.range(of: "readVerifiedEventBinding(")
            else {
                return false
            }
            return factsRange.lowerBound < budgetRange.lowerBound
                && budgetRange.lowerBound < bindingRange.lowerBound
                && normalized.contains(
                    "SystemChatAXSurfaceSignatureReader( budget: budget, "
                        + "approvedAttributes: request.approvedAttributes )")
                && !region.contains("SystemChatAXSurfaceSignatureReader()")
        }
        expect(
            eventSamplerReusesSingleAXBudget(eventQuerySampleRegion),
            "event PID、surface 与 window 必须在 runtime facts 后共享同一个 AX deadline budget")
        let splitEventBudgetMutation = eventQuerySampleRegion.replacingOccurrences(
            of: "budget: budget,",
            with: "budget: SystemChatAXReadBudget(),")
        expect(
            !eventSamplerReusesSingleAXBudget(splitEventBudgetMutation),
            "event sampler 不得为 surface 另起一份 AX budget")
        if let integerRegion = chatAXFunctionRegion(
            "func integer(", in: attributeReaderTypeRegion)
        {
            let distinguishesMissingIntegerFromFailure: (String) -> Bool = { region in
                let normalized = collapsingWhitespace(region)
                return region.contains("Result<Int?, ChatAXAttributeReadFailure>")
                    && normalized.contains(
                        "if result == .attributeUnsupported || result == .noValue { "
                            + "return .success(nil) }")
                    && normalized.contains(
                        "guard result == .success, let value, "
                            + "let ordinal = ChatAXWindowOrdinalDecoder.decode(value) else { "
                            + "return .failure(.unreadable) } return .success(ordinal)")
                    && normalized.components(separatedBy: "return").count - 1 == 5
                    && normalized.components(separatedBy: ".success(").count - 1 == 2
                    && region.components(separatedBy: "return .failure(.unreadable)").count - 1
                        == 3
            }
            expect(
                distinguishesMissingIntegerFromFailure(integerRegion),
                "AXWindowNumber 缺失可降级为 0，但 query/type/budget 失败必须保持 unreadable")
            let maskedIntegerFailureMutation = integerRegion.replacingOccurrences(
                of: "return .failure(.unreadable)",
                with: "return .success(nil)")
            expect(
                !distinguishesMissingIntegerFromFailure(maskedIntegerFailureMutation),
                "typed integer gate 必须拒绝把真实 AX 错误伪装成无 window number")
            let swappedMissingAndTypeFailureMutation =
                integerRegion
                .replacingOccurrences(
                    of: """
                        if result == .attributeUnsupported || result == .noValue {
                                    return .success(nil)
                                }
                        """,
                    with: """
                        if result == .attributeUnsupported || result == .noValue {
                                    return .failure(.unreadable)
                                }
                        """
                )
                .replacingOccurrences(
                    of: """
                        let ordinal = ChatAXWindowOrdinalDecoder.decode(value)
                                else {
                                    return .failure(.unreadable)
                                }
                        """,
                    with: """
                        let ordinal = ChatAXWindowOrdinalDecoder.decode(value)
                                else {
                                    return .success(nil)
                                }
                        """)
            expect(
                !distinguishesMissingIntegerFromFailure(swappedMissingAndTypeFailureMutation),
                "缺失 fallback 与类型失败分支不能对调后仍让分类 gate 假绿")
        } else {
            expect(false, "必须能定位 typed integer reader")
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
            anchorRegion.components(separatedBy: "focusedLineageSnapshot(").count - 1 == 2
                && anchorRegion.contains("lineagesAreEqual(before.elements, after.elements)")
                && anchorRegion.contains("before.anchorFacts == after.anchorFacts")
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
        let productionEventCoordinatorIsWired: (String, String, String) -> Bool = {
            observerSource, startSource, stopSource in
            guard
                let constructionRange = startSource.range(
                    of: "ChatAXEventQueryCoordinator<"),
                let retentionRange = startSource.range(
                    of: "self.eventQueryCoordinator = eventQueryCoordinator"),
                let beginRange = startSource.range(of: "eventQueryCoordinator.beginSession()"),
                let sourceRange = startSource.range(of: "CFRunLoopAddSource("),
                let endRange = stopSource.range(of: "eventQueryCoordinator?.endSession()"),
                let clearRange = stopSource.range(of: "eventQueryCoordinator = nil"),
                let targetClearRange = stopSource.range(of: "target = nil")
            else {
                return false
            }
            return observerSource.components(
                separatedBy: "private var eventQueryCoordinator:"
            ).count - 1 == 1
                && !observerSource.contains("weak var eventQueryCoordinator")
                && !observerSource.contains("unowned var eventQueryCoordinator")
                && startSource.components(
                    separatedBy: "self.eventQueryCoordinator = eventQueryCoordinator"
                ).count - 1 == 1
                && startSource.components(
                    separatedBy: "self.eventQueryCoordinator ="
                ).count - 1 == 1
                && callArguments(of: "endSession", in: startSource).isEmpty
                && constructionRange.lowerBound < retentionRange.lowerBound
                && retentionRange.lowerBound < beginRange.lowerBound
                && beginRange.lowerBound < sourceRange.lowerBound
                && startSource.contains("SystemChatAXEventQuerySampler.sample(request)")
                && startSource.contains("[weak self] elapsedMilliseconds, sample")
                && startSource.contains("self?.commitObservedEvent(")
                && startSource.contains("[weak self] in")
                && startSource.contains("self?.invalidateTarget()")
                && endRange.lowerBound < clearRange.lowerBound
                && clearRange.lowerBound < targetClearRange.lowerBound
        }
        expect(
            productionEventCoordinatorIsWired(observerTypeRegion, startRegion, stopRegion),
            "真实 observer 必须把 sampler/commit/invalidation 接到同一 generation coordinator")
        let missingEventBeginMutation = startRegion.replacingOccurrences(
            of: "eventQueryCoordinator.beginSession()",
            with: "_ = eventQueryCoordinator")
        expect(
            !productionEventCoordinatorIsWired(
                observerTypeRegion, missingEventBeginMutation, stopRegion),
            "AXObserver source 生效前必须启动 event coordinator session")
        let endedEventSessionDuringStartMutation = startRegion.replacingOccurrences(
            of: "eventQueryCoordinator.beginSession()",
            with: "eventQueryCoordinator.beginSession()\n"
                + "        eventQueryCoordinator.endSession()")
        expect(
            !productionEventCoordinatorIsWired(
                observerTypeRegion, endedEventSessionDuringStartMutation, stopRegion),
            "start 不能在 run-loop source 生效前结束 event coordinator session")
        let optionallyEndedEventSessionDuringStartMutation = startRegion.replacingOccurrences(
            of: "eventQueryCoordinator.beginSession()",
            with: "eventQueryCoordinator.beginSession()\n"
                + "        self.eventQueryCoordinator?.endSession()")
        expect(
            !productionEventCoordinatorIsWired(
                observerTypeRegion,
                optionallyEndedEventSessionDuringStartMutation,
                stopRegion),
            "start 不能经 Optional property 提前结束 event coordinator session")
        let missingEventEndMutation = stopRegion.replacingOccurrences(
            of: "eventQueryCoordinator?.endSession()",
            with: "_ = eventQueryCoordinator")
        expect(
            !productionEventCoordinatorIsWired(
                observerTypeRegion, startRegion, missingEventEndMutation),
            "stop 必须先推进 event generation，再清理 target 与 callback")
        let missingEventRetentionMutation = startRegion.replacingOccurrences(
            of: "self.eventQueryCoordinator = eventQueryCoordinator",
            with: "_ = eventQueryCoordinator")
        expect(
            !productionEventCoordinatorIsWired(
                observerTypeRegion, missingEventRetentionMutation, stopRegion),
            "start 必须持有 event coordinator，不能让局部实例在首个 callback 前释放")
        let weakEventCoordinatorMutation = observerTypeRegion.replacingOccurrences(
            of: "private var eventQueryCoordinator:",
            with: "private weak var eventQueryCoordinator:")
        expect(
            !productionEventCoordinatorIsWired(
                weakEventCoordinatorMutation, startRegion, stopRegion),
            "event coordinator property 必须强持有 session，不能退化为 weak storage")
        for emptyValue in ["nil", ".none", "Optional.none"] {
            let clearedEventCoordinatorMutation = startRegion.replacingOccurrences(
                of: "eventQueryCoordinator.beginSession()",
                with: "eventQueryCoordinator.beginSession()\n"
                    + "        self.eventQueryCoordinator = \(emptyValue)")
            expect(
                !productionEventCoordinatorIsWired(
                    observerTypeRegion, clearedEventCoordinatorMutation, stopRegion),
                "start 不得以任何 Optional 空值清空刚持有的 coordinator")
        }
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
        let mainActorEventCallbackOnlyEnqueues: (String) -> Bool = { region in
            guard
                let arrivalRange = region.range(
                    of: "let arrivalElapsedMilliseconds = traceElapsedMilliseconds"),
                let destroyedRange = region.range(of: "if targetWasDestroyed"),
                let destroyedBranch = chatAXBracedDeclarationRegion(
                    "if targetWasDestroyed", in: region),
                let destroyedBranchRange = region.range(of: destroyedBranch),
                let requestRange = region.range(of: "let request = SystemChatAXEventQueryRequest("),
                let enqueueRange = region.range(of: "eventQueryCoordinator.enqueue(")
            else {
                return false
            }
            let nonDestroyed = String(region[destroyedBranchRange.upperBound...])
            let requiredBindingGuard = """
                guard
                            let applicationElement,
                            let runtimeBinding,
                            let eventQueryCoordinator
                        else
                """
            guard
                let failureBranch = chatAXBracedDeclarationRegion(
                    requiredBindingGuard, in: nonDestroyed),
                let failureBranchRange = nonDestroyed.range(of: failureBranch),
                let nonDestroyedRequestRange = nonDestroyed.range(
                    of: "let request = SystemChatAXEventQueryRequest(")
            else {
                return false
            }
            return arrivalRange.lowerBound < destroyedRange.lowerBound
                && destroyedRange.lowerBound < requestRange.lowerBound
                && requestRange.lowerBound < enqueueRange.lowerBound
                && region.components(separatedBy: "traceElapsedMilliseconds").count - 1 == 1
                && region.contains("runtimeBinding: runtimeBinding")
                && region.contains("approvedAttributes: approvedAttributes")
                && region.contains("elapsedMilliseconds: arrivalElapsedMilliseconds")
                && callArguments(of: "invalidateTarget", in: nonDestroyed).count == 1
                && callArguments(of: "invalidateTarget", in: failureBranch).count == 1
                && failureBranch.components(separatedBy: "return").count - 1 == 1
                && failureBranchRange.upperBound < nonDestroyedRequestRange.lowerBound
                && callArguments(
                    of: "SystemChatAXEventQueryRequest", in: nonDestroyed
                ).count == 1
                && callArguments(
                    of: "eventQueryCoordinator.enqueue", in: nonDestroyed
                ).count == 1
                && nonDestroyed.filter { $0 == "(" }.count == 3
                && !nonDestroyed.contains("emitSignal(")
        }
        let backgroundEventSampleIsExact: (String, String, String, String, String) -> Bool = {
            sampleRegion, bindingRegion, identityMapRegion, focusedRegion, parentRegion in
            let integerReads = callArguments(
                of: "reader.integer",
                in: bindingRegion
            ).map(collapsingWhitespace)
            let normalizedSample = collapsingWhitespace(sampleRegion)
            let normalizedBinding = collapsingWhitespace(bindingRegion)
            return sampleRegion.components(separatedBy: "runningRuntimeFacts(").count - 1 == 2
                && sampleRegion.contains("factsBefore == request.runtimeBinding.runtimeFacts")
                && sampleRegion.contains("readVerifiedEventBinding(")
                && sampleRegion.contains("eventElement: request.element")
                && sampleRegion.contains("applicationElement: request.applicationElement")
                && sampleRegion.contains(
                    "allowedSignatures: [request.target.identity.surfaceSignature]")
                && sampleRegion.contains(
                    "verifiedBinding.surfaceSignature == request.target.identity.surfaceSignature")
                && normalizedSample.contains(
                    "surfaceSignature: verifiedBinding.surfaceSignature, "
                        + "windowOrdinal: verifiedBinding.windowOrdinal")
                && sampleRegion.contains("factsAfter == factsBefore")
                && sampleRegion.contains("SystemChatAXRuntimeApplicationVerifier.matches(")
                && bindingRegion.components(
                    separatedBy: "focusedLineageSnapshot("
                ).count - 1 == 2
                && normalizedBinding.contains(
                    "let eventBefore = lineage( from: eventElement, "
                        + "through: focusedBefore.window")
                && normalizedBinding.contains(
                    "let eventAfter = lineage( from: eventElement, "
                        + "through: focusedBefore.window")
                && bindingRegion.components(separatedBy: "from: eventElement").count - 1 == 2
                && bindingRegion.components(
                    separatedBy: "through: focusedBefore.window"
                ).count - 1 == 2
                && integerReads == [".windowNumber, from: focusedBefore.window"]
                && bindingRegion.components(
                    separatedBy: "SystemChatAXElementIdentityMap()"
                ).count - 1 == 1
                && bindingRegion.components(
                    separatedBy: "identityMap.identities(for:"
                ).count - 1 == 4
                && bindingRegion.components(
                    separatedBy: "ChatAXEventSurfaceBindingVerifier.verify("
                ).count - 1 == 1
                && normalizedBinding.contains("windowOrdinal: rawWindowOrdinal ?? 0")
                && identityMapRegion.components(separatedBy: "CFEqual(").count - 1 == 1
                && identityMapRegion.contains("private let sampleID = UUID()")
                && identityMapRegion.contains("representatives.firstIndex(")
                && identityMapRegion.contains("representatives.append(element)")
                && focusedRegion.contains("let focusedWindow = reader.element(")
                && focusedRegion.contains("let focusedElement = reader.element(")
                && focusedRegion.contains("let elements = lineage(")
                && parentRegion.contains(
                    "belongsToTarget(focusedElement, expectedProcessIdentifier)")
                && parentRegion.contains(
                    "belongsToTarget(focusedWindow, expectedProcessIdentifier)")
                && parentRegion.contains("let parent = reader.element(.parent, from: current)")
                && !sampleRegion.contains("emitSignal(")
        }
        let eventCommitUsesArrivalTime: (String, String) -> Bool = {
            commitRegion, emitterRegion in
            guard
                let pidRange = commitRegion.range(
                    of: "sample.processIdentifier == target.processIdentifier"),
                let runtimeRange = commitRegion.range(
                    of: "sample.runtimeFacts == runtimeBinding.runtimeFacts"),
                let surfaceRange = commitRegion.range(
                    of: "sample.surfaceSignature == target.identity.surfaceSignature"),
                let emissionRange = commitRegion.range(
                    of: "emitSignal(")
            else {
                return false
            }
            return pidRange.lowerBound < runtimeRange.lowerBound
                && runtimeRange.lowerBound < surfaceRange.lowerBound
                && surfaceRange.lowerBound < emissionRange.lowerBound
                && commitRegion.contains("elapsedMilliseconds: elapsedMilliseconds")
                && !commitRegion.contains("traceElapsedMilliseconds")
                && emitterRegion.contains("elapsedMilliseconds: elapsedMilliseconds")
                && !emitterRegion.contains("traceElapsedMilliseconds")
                && chatAXFunctionContainsMarkersInOrder(
                    ["let sequence = nextSequence", "nextSequence += 1", "receive?("],
                    inFunction: "private func emitSignal(",
                    source: emitterRegion)
        }
        expect(
            mainActorEventCallbackOnlyEnqueues(handleRegion)
                && backgroundEventSampleIsExact(
                    eventQuerySampleRegion,
                    eventBindingRegion,
                    elementIdentityMapTypeRegion,
                    focusedLineageRegion,
                    lineageRegion)
                && eventCommitUsesArrivalTime(
                    commitObservedEventRegion,
                    elapsedSignalRegion)
                && runtime.components(separatedBy: ".unrelatedStructureChanged").count - 1
                    == 1,
            "非销毁 callback 必须只捕获 arrival 并 enqueue；后台 exact 复核后才能按抵达时间提交")
        let directMainActorQueryMutation = handleRegion.replacingOccurrences(
            of: "let request = SystemChatAXEventQueryRequest(",
            with: "_ = SystemChatAXCodeIdentityReader.runningRuntimeFacts("
                + "processIdentifier: target.processIdentifier)\n"
                + "        let request = SystemChatAXEventQueryRequest(")
        expect(
            !mainActorEventCallbackOnlyEnqueues(directMainActorQueryMutation),
            "source gate 必须拒绝在 MainActor callback 恢复 PID/surface/runtime query")
        let directSamplerWrapperMutations = [
            "_ = SystemChatAXEventQuerySampler.sample(request)",
            """
            _ = SystemChatAXRuntimeSampler.sample(
                processIdentifier: target.processIdentifier,
                expectedSurfaceSignature: target.identity.surfaceSignature)
            """,
            "_ = runtimeApplicationStillMatches(target: target, binding: runtimeBinding)",
        ]
        for query in directSamplerWrapperMutations {
            let mutation = handleRegion.replacingOccurrences(
                of: "eventQueryCoordinator.enqueue(",
                with: "\(query)\n        eventQueryCoordinator.enqueue(")
            expect(
                !mainActorEventCallbackOnlyEnqueues(mutation),
                "source gate 必须拒绝 MainActor callback 通过现成 sampler/verifier 同步查询")
        }
        let relocatedInvalidationMutation =
            handleRegion
            .replacingOccurrences(
                of: "else {\n            invalidateTarget()\n            return\n        }",
                with:
                    "else {\n            return\n        }"
            )
            .replacingOccurrences(
                of: "elapsedMilliseconds: arrivalElapsedMilliseconds)",
                with: "elapsedMilliseconds: arrivalElapsedMilliseconds)\n"
                    + "        invalidateTarget()")
        expect(
            !mainActorEventCallbackOnlyEnqueues(relocatedInvalidationMutation),
            "normal callback 不得在 enqueue 后无条件 invalidate；失效只属于 guard failure")
        let decoyFailureBranchMutation =
            handleRegion
            .replacingOccurrences(
                of: "else {\n            invalidateTarget()\n            return\n        }",
                with:
                    "else {\n            return\n        }"
            )
            .replacingOccurrences(
                of: "        guard\n            let applicationElement,",
                with: """
                            if target.processIdentifier >= 0 {
                            } else {
                                invalidateTarget()
                                return
                            }
                            guard
                                let applicationElement,
                    """)
        expect(
            !mainActorEventCallbackOnlyEnqueues(decoyFailureBranchMutation),
            "失效分支必须绑定真实 runtime-state guard，不能由无关 decoy else 代替")
        let missingEventSurfaceMutation = eventQuerySampleRegion.replacingOccurrences(
            of: "verifiedBinding.surfaceSignature == request.target.identity.surfaceSignature",
            with: "true")
        expect(
            !backgroundEventSampleIsExact(
                missingEventSurfaceMutation,
                eventBindingRegion,
                elementIdentityMapTypeRegion,
                focusedLineageRegion,
                lineageRegion),
            "event sampler 必须拒绝只取到某个 surface 而不 exact 匹配 allowlist 摘要")
        let wrongWindowAttributeMutation = eventBindingRegion.replacingOccurrences(
            of: ".windowNumber,",
            with: ".enabled,")
        expect(
            !backgroundEventSampleIsExact(
                eventQuerySampleRegion,
                wrongWindowAttributeMutation,
                elementIdentityMapTypeRegion,
                focusedLineageRegion,
                lineageRegion),
            "event sampler 必须精确读取 AXWindowNumber，不能接受其他 NSNumber-compatible 属性")
        let wrongWindowElementMutation = eventBindingRegion.replacingOccurrences(
            of: "from: focusedBefore.window",
            with: "from: eventElement")
        expect(
            !backgroundEventSampleIsExact(
                eventQuerySampleRegion,
                wrongWindowElementMutation,
                elementIdentityMapTypeRegion,
                focusedLineageRegion,
                lineageRegion),
            "window ordinal 必须来自 verified focused window，不能来自任意 callback element")
        let wrongEventElementMutation = eventQuerySampleRegion.replacingOccurrences(
            of: "eventElement: request.element",
            with: "eventElement: request.applicationElement")
        expect(
            !backgroundEventSampleIsExact(
                wrongEventElementMutation,
                eventBindingRegion,
                elementIdentityMapTypeRegion,
                focusedLineageRegion,
                lineageRegion),
            "event binding 必须从真实 callback element 起步，不能用 application focus 替代")
        let discardedWindowOrdinalMutation = eventBindingRegion.replacingOccurrences(
            of: "windowOrdinal: rawWindowOrdinal ?? 0",
            with: "windowOrdinal: 0")
        expect(
            !backgroundEventSampleIsExact(
                eventQuerySampleRegion,
                discardedWindowOrdinalMutation,
                elementIdentityMapTypeRegion,
                focusedLineageRegion,
                lineageRegion),
            "event sampler 必须把 typed window number 写入 sample，不能读取后硬编码为零")
        let reusedEventAfterMutation = eventBindingRegion.replacingOccurrences(
            of: "let eventAfter = lineage(",
            with: "let eventAfter = eventBefore; _ = lineage(")
        expect(
            !backgroundEventSampleIsExact(
                eventQuerySampleRegion,
                reusedEventAfterMutation,
                elementIdentityMapTypeRegion,
                focusedLineageRegion,
                lineageRegion),
            "event lineage 必须在 window read 后重新采样，不能复用 before 快照")
        let splitIdentityMapMutation = eventBindingRegion.replacingOccurrences(
            of: "eventAfter: identityMap.identities(for: eventAfter)",
            with: "eventAfter: SystemChatAXElementIdentityMap().identities(for: eventAfter)")
        expect(
            !backgroundEventSampleIsExact(
                eventQuerySampleRegion,
                splitIdentityMapMutation,
                elementIdentityMapTypeRegion,
                focusedLineageRegion,
                lineageRegion),
            "四条 lineage 必须共用一个 opaque identity namespace")
        let pointerIdentityMutation = elementIdentityMapTypeRegion.replacingOccurrences(
            of: "CFEqual($0, element)",
            with: "$0 === element")
        expect(
            !backgroundEventSampleIsExact(
                eventQuerySampleRegion,
                eventBindingRegion,
                pointerIdentityMutation,
                focusedLineageRegion,
                lineageRegion),
            "AX element identity 必须使用 CFEqual，不能退化为 wrapper 指针相等")
        let wrongLineageEndpointMutation = eventBindingRegion.replacingOccurrences(
            of: "through: focusedBefore.window",
            with: "through: eventElement")
        expect(
            !backgroundEventSampleIsExact(
                eventQuerySampleRegion,
                wrongLineageEndpointMutation,
                elementIdentityMapTypeRegion,
                focusedLineageRegion,
                lineageRegion),
            "event parent lineage 必须终止于 verified focused window")
        let completionTimestampMutation = commitObservedEventRegion.replacingOccurrences(
            of: "elapsedMilliseconds: elapsedMilliseconds",
            with: "elapsedMilliseconds: traceElapsedMilliseconds")
        expect(
            !eventCommitUsesArrivalTime(completionTimestampMutation, elapsedSignalRegion),
            "event evidence 不得把后台 sampler 完成时间伪装成 callback 抵达时间")
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
                    of: "emitSignal("),
                let invalidationRange = region.range(of: "invalidateTarget()")
            else {
                return false
            }
            return normalized.contains("invalidateTarget()")
                && normalized.contains("kind: .applicationExited")
                && normalized.contains("windowOrdinal: 0")
                && normalized.contains(
                    "elapsedMilliseconds: arrivalElapsedMilliseconds")
                && region.components(separatedBy: "emitSignal(").count - 1 == 1
                && region.components(separatedBy: "invalidateTarget()").count - 1 == 1
                && invalidElementRange.upperBound < emissionRange.lowerBound
                && applicationDestroyedRange.upperBound < invalidationRange.lowerBound
                && callArguments(of: "CFEqual", in: region).count == 1
                && callArguments(of: "emitSignal", in: region).count == 1
                && callArguments(of: "invalidateTarget", in: region).count == 1
                && region.filter { $0 == "(" }.count == 3
        }
        expect(
            recordsExitWithoutDestroyedElementQuery(destroyedRegion),
            "destroyed callback 必须只记录已知退出事实，不能再 query 失效 AX element")
        let destroyedElementQueryMutation = destroyedRegion.replacingOccurrences(
            of: "self.applicationElement = nil",
            with: "var destroyedPID: pid_t = 0\n"
                + "                AXUIElementGetPid(element, &destroyedPID)\n"
                + "                self.applicationElement = nil")
        expect(
            !recordsExitWithoutDestroyedElementQuery(destroyedElementQueryMutation),
            "destroyed-element 契约必须拒绝回退到通用 AX emitter")
        let destroyedSamplerMutation = destroyedRegion.replacingOccurrences(
            of: "self.applicationElement = nil",
            with: "_ = SystemChatAXRuntimeSampler.sample(\n"
                + "                    processIdentifier: target.processIdentifier,\n"
                + "                    expectedSurfaceSignature: target.identity.surfaceSignature)\n"
                + "                self.applicationElement = nil")
        expect(
            !recordsExitWithoutDestroyedElementQuery(destroyedSamplerMutation),
            "destroyed-element 契约必须拒绝通过现成 sampler wrapper 间接查询")
        let broadExitMutation = destroyedRegion.replacingOccurrences(
            of: "if let applicationElement, CFEqual(element, applicationElement)",
            with: "if targetWasDestroyed")
        expect(
            !recordsExitWithoutDestroyedElementQuery(broadExitMutation),
            "非 application destroyed callback 不得伪造 application-exit evidence")
        let lateInvalidElementMutation = destroyedRegion.replacingOccurrences(
            of: "self.applicationElement = nil\n"
                + "                emitSignal(\n"
                + "                    kind: .applicationExited,\n"
                + "                    windowOrdinal: 0,\n"
                + "                    elapsedMilliseconds: arrivalElapsedMilliseconds)",
            with: "emitSignal(\n"
                + "                    kind: .applicationExited,\n"
                + "                    windowOrdinal: 0,\n"
                + "                    elapsedMilliseconds: arrivalElapsedMilliseconds)\n"
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
            runtimeSamplerTypeRegion.contains("readAnchorFacts(")
                && runtimeSamplerTypeRegion.contains("ChatAXSurfaceVerifier.verifyChat(")
                && eventQuerySampleRegion.contains("readVerifiedEventBinding(")
                && eventBindingRegion.contains("ChatAXEventSurfaceBindingVerifier.verify(")
                && !observerTypeRegion.contains("surfaceStillMatches(")
                && !observerTypeRegion.contains("elementBelongsToTarget("),
            "周期与 event 后台复核必须共用 exact surface verifier，observer 不得保留 dead 快捷路径")
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
