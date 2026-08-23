import ClaudioCore
import ClaudioGUICore
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
    var observedTarget: ChatAXObservedTarget?

    init(
        observedTarget: ChatAXObservedTarget?,
        signalsOnStart: [ChatAXStructuralSignal] = [],
        startSucceeds: Bool = true
    ) {
        self.observedTarget = observedTarget
        self.signalsOnStart = signalsOnStart
        self.startSucceeds = startSucceeds
    }

    func inspectTarget(
        requirements: ChatAXInspectionRequirements
    ) -> Result<ChatAXObservedTarget, ChatAXTargetInspectionFailure> {
        inspectedRequirements = requirements
        guard let observedTarget else { return .failure(.targetUnavailable) }
        return .success(observedTarget)
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
    surface: HostSurfaceID = .chatGPTDesktopAX
) -> ChatAXTargetIdentity {
    ChatAXTargetIdentity(
        bundleIdentifier: bundleIdentifier,
        codeSignature: codeSignature,
        shortVersion: shortVersion,
        build: build,
        frameworks: frameworks,
        architecture: architecture,
        surface: surface)
}

private func chatAXObservedTarget(
    processIdentifier: Int32 = 4242,
    identity: ChatAXTargetIdentity = chatAXIdentity()
) -> ChatAXObservedTarget {
    ChatAXObservedTarget(processIdentifier: processIdentifier, identity: identity)
}

@MainActor
func runChatAXTracerSuites() {
    suite("Chat AX tracer allowlist：七项身份必须逐字匹配，任一失配均 fail closed") {
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

        let signal = ChatAXStructuralSignal(
            sequence: 7,
            elapsedMilliseconds: 125,
            windowOrdinal: 2,
            kind: .generationControl(isVisible: true))
        expect(signal.kind.requiredAttributes == [.identifier, .enabled], "信号只声明必要属性")
        expect(signal.sequence == 7 && signal.windowOrdinal == 2, "信号只携带时序与结构编号")
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
        observer.observedTarget = chatAXObservedTarget(
            identity: chatAXIdentity(build: "mismatch"))
        expect(
            tracer.beginExplicitTrace(scenarioNumber: 1) == .refused(.identityMismatch),
            "身份失配不得触碰 observer")
        expect(observer.startCount == 0, "allowlist 失败必须在 observer 边界之前返回")

        observer.observedTarget = chatAXObservedTarget()
        expect(
            tracer.beginExplicitTrace(scenarioNumber: 1) == .started,
            "三项门禁都满足后才能启动")
        expect(tracer.isRunning && observer.startCount == 1, "显式启用必须只启动一次 observer")
        expect(
            observer.startedTarget == chatAXObservedTarget()
                && observer.approvedAttributes == Set(ChatAXApprovedAttribute.allCases),
            "observer 必须绑定独立检查得到的 PID/身份并只接收批准属性")

        observer.observedTarget = chatAXObservedTarget(
            identity: chatAXIdentity(shortVersion: "9.9.9"))
        tracer.revalidateTarget()
        expect(!tracer.isRunning && observer.stopCount == 1, "运行中身份失配必须确定 stop")

        observer.observedTarget = chatAXObservedTarget()
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

    suite("Chat AX tracer GUI 接线：真实 observer 只在 Debug 显式入口存活且从不弹权限") {
        guard
            let runtime = chatAXSource(
                "gui/Sources/ClaudioGUI/SystemChatAXTraceObserver.swift"),
            let app = chatAXSource("gui/Sources/ClaudioGUI/ClaudioGUIApp.swift")
        else {
            expect(false, "必须存在可编译的 GUI-only AX observer 与 app 生命周期接线")
            return
        }
        expect(runtime.contains("AXObserverCreate("), "真实 tracer 必须绑定 AXObserver")
        expect(runtime.contains("AXIsProcessTrusted()"), "只能静默检查现有 AX 权限")
        expect(
            runtime.contains("_ attribute: ChatAXApprovedAttribute")
                && runtime.contains("attribute.rawValue as CFString"),
            "真实属性读取器必须只接受封闭枚举，不能接受任意 AX 属性名")
        expect(
            !runtime.contains("AXIsProcessTrustedWithOptions"),
            "spike 不得触发生产权限提示")
        for prohibitedConstant in [
            "kAXValueAttribute", "kAXTitleAttribute", "kAXHelpAttribute",
            "kAXDescriptionAttribute", "kAXSelectedTextAttribute", "kAXChildrenAttribute",
        ] {
            expect(
                !runtime.contains(prohibitedConstant),
                "真实读取边界禁止出现 \(prohibitedConstant)")
        }
        expect(
            app.contains("#if DEBUG")
                && app.contains("startExplicitChatAXTracerIfConfigured")
                && app.contains("chatAXTracer?.guiWillTerminate()"),
            "app 只能通过 Debug 显式入口启动，并在 GUI 退出时确定 stop")
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
        for forbidden in [
            "prompt", "response", "conversationTitle", "helpText", "clipboard", "uiTree",
            "soundOutcome", "currentActivation",
        ] {
            expect(
                !json.localizedCaseInsensitiveContains(forbidden),
                "证据 JSON 禁止出现 \(forbidden) 字段")
        }

        tracer.endExplicitTrace()
        expect(tracer.evidence == evidence, "显式 stop 后仍只保留本次脱敏内存证据")
    }
}
