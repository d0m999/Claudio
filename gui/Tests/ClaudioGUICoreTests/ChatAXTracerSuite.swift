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
    var observedTargets: [ChatAXObservedTarget]?
    var hasUnreadableProjection = false
    var inspectionFailure: ChatAXTargetInspectionFailure?

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
func runChatAXTracerSuites() {
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

        guard
            let rawCore = chatAXSource(
                "gui/Sources/ClaudioGUICore/ChatAXTracer.swift")
        else {
            expect(false, "必须能读取 detector production source 才能验证完整 epoch reset")
            return
        }
        let scannedCore = strippingComments(rawCore)
        guard scannedCore.unmodeledConstructs.isEmpty,
            let consumeRegion = chatAXFunctionRegion(
                "public mutating func consume(",
                in: scannedCore.codeWithoutStringLiterals),
            let submitRegion = chatAXBracedDeclarationRegion(
                "if state.phase == .idle, state.submittedAt == nil",
                in: consumeRegion)
        else {
            expect(false, "必须能定位真实 composer submit epoch block")
            return
        }
        let resetsCompleteEpoch: (String) -> Bool = { region in
            [
                "state.assistantRegionIsStable = false",
                "state.assistantStructureRevision = nil",
                "state.completionCandidateAt = nil",
            ].allSatisfy { region.components(separatedBy: $0).count - 1 == 1 }
        }
        expect(resetsCompleteEpoch(submitRegion), "新 submit 必须清空完整 assistant epoch 状态")
        for removedReset in [
            "state.assistantRegionIsStable = false",
            "state.assistantStructureRevision = nil",
            "state.completionCandidateAt = nil",
        ] {
            let incompleteReset = submitRegion.replacingOccurrences(of: removedReset, with: "")
            expect(
                !resetsCompleteEpoch(incompleteReset),
                "epoch reset 契约必须拒绝删除 \(removedReset)")
        }
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
            runtime.contains("_ attribute: ChatAXApprovedAttribute")
                && runtime.contains("attribute.rawValue as CFString"),
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
            let budgetTypeRegion = chatAXBracedDeclarationRegion(
                "private final class SystemChatAXReadBudget", in: runtime),
            let attributeReaderTypeRegion = chatAXBracedDeclarationRegion(
                "private struct SystemChatAXAttributeReader", in: runtime),
            let surfaceReaderTypeRegion = chatAXBracedDeclarationRegion(
                "private struct SystemChatAXSurfaceSignatureReader", in: runtime),
            let observerTypeRegion = chatAXBracedDeclarationRegion(
                "final class SystemChatAXTraceObserver: ChatAXTraceObserving", in: runtime),
            let inspectionRegion = chatAXFunctionRegion(
                "func inspectTarget(", in: observerTypeRegion),
            let identityRegion = chatAXFunctionRegion(
                "private func inspectIdentities(", in: observerTypeRegion),
            let frameworkSetRegion = chatAXFunctionRegion(
                "private func inspectFrameworkSet(", in: observerTypeRegion),
            let frameworkIdentityRegion = chatAXFunctionRegion(
                "private func inspectFrameworkIdentity(", in: observerTypeRegion),
            let revalidationRegion = chatAXFunctionRegion(
                "private func surfaceStillMatches(", in: observerTypeRegion),
            let anchorRegion = chatAXFunctionRegion(
                "func readAnchorFacts(", in: surfaceReaderTypeRegion),
            let startRegion = chatAXFunctionRegion("func start(", in: observerTypeRegion),
            let stopRegion = chatAXFunctionRegion("func stop()", in: observerTypeRegion),
            let handleRegion = chatAXFunctionRegion(
                "fileprivate func handle(", in: observerTypeRegion),
            let destroyedRegion = chatAXBracedDeclarationRegion(
                "if targetWasDestroyed", in: handleRegion)
        else {
            expect(false, "必须能定位 production identity、observer 与 surface 复核函数")
            return
        }
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
        expect(
            hasExactNotificationSet(startRegion)
                && startRegion.contains("registered.count == notifications.count")
                && startRegion.contains("AXObserverRemoveNotification(")
                && startRegion.components(separatedBy: "targetStillMatches(target)").count - 1
                    == 2,
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
            validatesSurfaceBeforeUnrelatedSignal(handleRegion),
            "每个非销毁结构通知都必须在发布信号前立即复核 surface")
        let reorderedSurfaceMutation =
            handleRegion
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
            let mismatch = "return .candidates([], hasUnreadableProjection: false)"
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
            of: "return .candidates([], hasUnreadableProjection: false)",
            with: "return .unreadable")
        expect(
            !preservesReadableSurfaceMismatch(collapsedMismatchMutation),
            "surface mismatch 契约必须拒绝重新折叠为 identityUnreadable")
        expect(
            inspectionRegion.contains(
                "case .candidates(let candidates, let containsUnreadableProjection)")
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

        tracer.endExplicitTrace()
        expect(tracer.evidence == evidence, "显式 stop 后仍只保留本次脱敏内存证据")
    }
}
