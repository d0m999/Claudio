import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Foundation

private enum IsolationAssetViolation: Sendable, Equatable {
    case origin
    case mime
    case redirect
    case finalURL
    case authentication(Int)
}

/// Injected unary/asset URLSessions intercept every origin. SSE uses a separate rejecting fixture;
/// all credentials are fake and the file vault is rooted under withTempDirectory.
private final class IsolationNetwork: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: Set<Int> = []
    private var violations: [Int: IsolationAssetViolation] = [:]
    private var recorded: [URLRequest] = []
    private var postStatus = 200
    private var holdsPost = false
    private var held: [IsolationURLProtocol] = []
    private var body: Data?
    private var stops = 0

    func reset(
        failedAssets: Set<Int>, postStatus: Int = 200, holdPost: Bool = false,
        violations: [Int: IsolationAssetViolation] = [:]
    ) {
        lock.lock()
        defer { lock.unlock() }
        failures = failedAssets
        self.violations = violations
        recorded = []
        self.postStatus = postStatus
        holdsPost = holdPost
        held = []
        body = nil
        stops = 0
    }

    func response(for request: URLRequest, delivery: IsolationURLProtocol) -> (Int, String, Data)? {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
        if request.url?.host == "api.senseaudio.cn",
            request.url?.path == "/v1/sound-effects/generations", request.httpMethod == "POST"
        {
            body = isolationRequestBody(request)
            if holdsPost { held.append(delivery); return nil }
            return (
                postStatus, "application/json",
                Self.batchBody(invalidOrigin: violations.values.contains(.origin))
            )
        }
        for index in 0...2
        where request.url?.host == "dynamic.senseaudio.cn"
            && request.url?.path == "/isolated-\(index).mp3" && request.httpMethod == "GET"
        {
            switch violations[index] {
            case .mime: return (200, "audio/wav", Self.audio(index: index))
            case .redirect: return (302, "audio/mpeg", Data())
            case .authentication(let code): return (code, "audio/mpeg", Data())
            default: break
            }
            if failures.contains(index) { return (404, "audio/mpeg", Data()) }
            return (200, "audio/mpeg", Self.audio(index: index))
        }
        return (500, "application/json", Data())
    }

    func releasePost() {
        lock.lock()
        let deliveries = held
        let status = postStatus
        let invalidOrigin = violations.values.contains(.origin)
        held = []
        holdsPost = false
        lock.unlock()
        for delivery in deliveries {
            delivery.deliver(
                status: status, mime: "application/json",
                body: Self.batchBody(invalidOrigin: invalidOrigin))
        }
    }

    func hasHeldPost() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !held.isEmpty
    }

    func didStop() {
        lock.lock(); defer { lock.unlock() }
        stops += 1
    }

    func stopCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return stops
    }

    func postBody() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return body
    }

    fileprivate static func batchBody(invalidOrigin: Bool = false) -> Data {
        let items: [[String: Any]] = [2, 0, 1].map { index in
            [
                "variant_index": index, "status": "completed", "output_format": "mp3",
                "duration_seconds": 2,
                "audio_url": invalidOrigin && index == 1
                    ? "https://unexpected.invalid/isolated-1.mp3"
                    : "https://dynamic.senseaudio.cn/isolated-\(index).mp3",
            ]
        }
        return try! JSONSerialization.data(withJSONObject: [
            "status": "completed", "generation_id": "fixture-isolation", "items": items,
        ])
    }

    func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func finalURL(for request: URLRequest) -> URL {
        lock.lock(); defer { lock.unlock() }
        if violations[1] == .finalURL, request.url?.path == "/isolated-1.mp3" {
            return URL(string: "https://dynamic.senseaudio.cn/isolated-final-mismatch.mp3")!
        }
        return request.url!
    }

    static func audio(index: Int) -> Data {
        validMP3ID3Data() + Data([UInt8(index)])
    }
}

private final class IsolationURLProtocol: URLProtocol, @unchecked Sendable {
    static let network = IsolationNetwork()
    private let deliveryLock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let (status, mime, body) = Self.network.response(for: request, delivery: self) else {
            return
        }
        deliver(status: status, mime: mime, body: body)
    }

    func deliver(status: Int, mime: String, body: Data) {
        deliveryLock.lock()
        let canDeliver = !stopped
        deliveryLock.unlock()
        guard canDeliver else { return }
        let response = HTTPURLResponse(
            url: Self.network.finalURL(for: request), statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        deliveryLock.lock()
        stopped = true
        deliveryLock.unlock()
        Self.network.didStop()
    }
}

private func isolationRequestBody(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while body.count <= 16_384 {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { return nil }
        if count == 0 { return body }
        body.append(contentsOf: buffer.prefix(count))
    }
    return nil
}

private actor IsolationMetadata: AICueCredentialMetadataStoring {
    private var verification: AICueCredentialVerification? = .verified
    func verification(for profileID: AICueProviderProfileID) -> AICueCredentialVerification? {
        verification
    }
    func setVerification(
        _ value: AICueCredentialVerification?, for profileID: AICueProviderProfileID
    ) {
        verification = value
    }
}

private actor IsolationOtherCredentialVault: AICueCredentialVault {
    private var values: [AICueCredentialSlotID: SensitiveCredentialInput]
    init(_ values: [AICueCredentialSlotID: SensitiveCredentialInput]) { self.values = values }
    func containsCredential(in slotID: AICueCredentialSlotID) -> Bool { values[slotID] != nil }
    func credential(in slotID: AICueCredentialSlotID) -> SensitiveCredentialInput? {
        values[slotID]
    }
    func replaceCredential(_ value: SensitiveCredentialInput, in slotID: AICueCredentialSlotID) {
        values[slotID] = value
    }
    func deleteCredential(in slotID: AICueCredentialSlotID) { values.removeValue(forKey: slotID) }
}

private final class IsolationRejectingSSETransport: AICueSSETransport, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [AICueTransportRequest] = []
    func events(
        for request: AICueTransportRequest, authentication: AICueProviderAuthentication,
        credential: SensitiveCredentialInput
    ) -> AsyncThrowingStream<AICueSSEEvent, Error> {
        lock.withLock { captured.append(request) }
        return AsyncThrowingStream { $0.finish(throwing: AICueTransportError.transportFailure) }
    }
    func requests() -> [AICueTransportRequest] { lock.withLock { captured } }
}

private actor IsolationLateUnaryTransport: AICueUnaryTransport {
    private var started = false
    private var released = false
    private var delivered = false
    private var cancellationObserved = false
    private var calls = 0

    func send(
        _ request: AICueTransportRequest, authentication: AICueProviderAuthentication,
        credential: SensitiveCredentialInput
    ) async throws -> AICueHTTPResponse {
        calls += 1
        started = true
        let expires = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while !released, DispatchTime.now().uptimeNanoseconds < expires {
            cancellationObserved = cancellationObserved || Task.isCancelled
            // A bounded external response can ignore caller cancellation. No continuation is
            // left hanging, and the detached delay performs no network or credential operation.
            await Task.detached { try? await Task.sleep(nanoseconds: 5_000_000) }.value
        }
        guard released else { throw AICueTransportError.transportFailure }
        cancellationObserved = cancellationObserved || Task.isCancelled
        delivered = true
        return AICueHTTPResponse(
            statusCode: 200, headers: ["content-type": "application/json"],
            body: IsolationNetwork.batchBody(), finalURL: request.url)
    }

    func release() { released = true }
    func facts() -> (started: Bool, delivered: Bool, cancelled: Bool, calls: Int) {
        (started, delivered, cancellationObserved, calls)
    }
}

@MainActor
private struct IsolationRuntime {
    let runtime: AICueRuntime
    let viewModel: AICueGenerationViewModel
    let vault: SenseAudioFileCredentialVault
    let defaults: UserDefaults
    let defaultsName: String
    let generations: URL
    let sseTransport: IsolationRejectingSSETransport

    static func make(
        root: URL, otherCredentials: [AICueCredentialSlotID: SensitiveCredentialInput] = [:],
        unaryTransport: (any AICueUnaryTransport)? = nil
    ) async -> Self {
        let directory = root.resolvingSymlinksInPath().appendingPathComponent("Credentials")
        let vault = SenseAudioFileCredentialVault(directory: directory)
        try! await vault.replaceCredential(
            try! SensitiveCredentialInput("fixture-only-isolated-senseaudio"),
            in: .senseAudioChina)
        let registry = AICueProviderRegistry(
            evidenceGatedSenseAudioAssetPolicy: try! AICueAssetPolicy(
                allowedOrigins: [try! AICueAssetOrigin("https://dynamic.senseaudio.cn:443")],
                acceptedMediaTypes: ["audio/mpeg"]))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IsolationURLProtocol.self]
        let defaultsName = "com.claudio.tests.senseaudio-isolation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        let generations = root.appendingPathComponent("generations")
        let sseTransport = IsolationRejectingSSETransport()
        let appVault = AICueAppCredentialVault(
            keychain: IsolationOtherCredentialVault(otherCredentials), senseAudio: vault)
        let runtime = try! AICueRuntime(
            registry: registry, vault: appVault, temporaryRoot: generations,
            durationProbe: StubDurationProbe(fixedDuration: 1),
            unaryTransport: unaryTransport
                ?? AICueURLSessionUnaryTransport(configuration: configuration),
            sseTransport: sseTransport,
            assetFetcher: AICueURLSessionAssetFetcher(
                loader: AICueURLSessionAssetLoader(configuration: configuration),
                retrySleeper: IsolationRetrySleeper()),
            credentialMetadata: IsolationMetadata(), providerDefaults: defaults)
        try! runtime.providerPreferences.select(.senseAudioChina)
        let viewModel = AICueGenerationViewModel(
            credentialManager: runtime.credentialManager, generator: runtime.dispatcher,
            providerProfileID: .senseAudioChina, registry: registry,
            providerPreferences: runtime.providerPreferences)
        viewModel.begin(scope: .surface(.workBuddy), event: .stop)
        viewModel.updateDescription("短促 木琴 音效")
        return Self(
            runtime: runtime, viewModel: viewModel, vault: vault, defaults: defaults,
            defaultsName: defaultsName, generations: generations, sseTransport: sseTransport)
    }
}

private struct IsolationRetrySleeper: AICueAssetRetrySleeping {
    func sleep(seconds: Int) async throws {
        throw AICueAssetFetchError.retryBackoffFailure
    }
}

@MainActor
private func isolationWait(_ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date(timeIntervalSinceNow: 3)
    while !condition(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

@MainActor
private func isolationWaitAsync(_ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

@MainActor
func runSenseAudioIsolationSuites() async {
    await suite("SenseAudio 隔离串联：transport 实际交付取消后的成功，真实 engine/VM 丢弃") {
        await withTempDirectory { root in
            IsolationURLProtocol.network.reset(failedAssets: [])
            let late = IsolationLateUnaryTransport()
            let fixture = await IsolationRuntime.make(root: root, unaryTransport: late)
            defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
            fixture.viewModel.startGeneration(locale: "zh-Hans")
            guard await isolationWaitAsync({ await late.facts().started }) else {
                fixture.viewModel.returnToDescription()
                await late.release()
                expect(false, "真实 Provider 必须到达受控 transport")
                return
            }
            fixture.viewModel.returnToDescription()
            fixture.viewModel.updateDescription("取消后的新描述")
            expect(
                await isolationWaitAsync { await late.facts().cancelled },
                "取消必须传播到正在处理的真实 Provider transport")
            await late.release()
            expect(await isolationWaitAsync { await late.facts().delivered }, "必须真的交付迟到 200 成功")
            expect(
                await isolationWait { isolationGenerationIsEmpty(fixture.generations) },
                "取消清理 generation")
            for _ in 0..<100 { await Task.yield() }
            expect(
                fixture.viewModel.phase == .editing && fixture.viewModel.generation == nil
                    && fixture.viewModel.failure == nil
                    && fixture.viewModel.soundDescription == "取消后的新描述",
                "迟到成功不得复活候选、错误或覆盖新描述")
            expect(await late.facts().calls == 1, "取消和迟到成功不重发 POST")
            expect(IsolationURLProtocol.network.requests().isEmpty, "取消后的 batch 不开始 GET")
        }
    }
    await suite("SenseAudio 隔离装配：有假 Qwen Key 时必须到达拒绝 SSE 接缝，不能真实联网") {
        await withTempDirectory { root in
            IsolationURLProtocol.network.reset(failedAssets: [])
            let fixture = await IsolationRuntime.make(
                root: root,
                otherCredentials: [
                    .qwenSingapore: try! SensitiveCredentialInput("fixture-only-qwen")
                ])
            defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
            var observed: AICueGenerationError?
            do {
                _ = try await fixture.runtime.dispatcher.generate(
                    description: "请说“完成”", locale: "zh-Hans", providerProfileID: .qwenSingapore,
                    deadline: .startingNow())
            } catch let error as AICueGenerationError { observed = error } catch {}
            expect(observed == .provider(.transportFailure), "显式 Qwen 生成从受控 SSE 失败返回")
            expect(fixture.sseTransport.requests().count == 1, "有假 Key 不能由缺凭据先挡住 SSE 接缝")
            expect(
                IsolationURLProtocol.network.requests().isEmpty, "Qwen 不走 unary/asset，也不 fallback")
            expect(isolationGenerationIsEmpty(fixture.generations), "受控 SSE 失败清理真实 generation")
        }
    }
    await suite("SenseAudio 隔离串联：安全违约整批失败、保凭据、清理并可重新生成") {
        let violations: [IsolationAssetViolation] = [
            .origin, .mime, .redirect, .finalURL, .authentication(401), .authentication(403),
        ]
        for violation in violations {
            await withTempDirectory { root in
                IsolationURLProtocol.network.reset(failedAssets: [], violations: [1: violation])
                let fixture = await IsolationRuntime.make(root: root)
                defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
                fixture.viewModel.startGeneration(locale: "zh-Hans")
                expect(await isolationWait { fixture.viewModel.phase == .editing }, "违约必须恢复编辑")
                expect(
                    fixture.viewModel.failure == .generation(.provider(.invalidAudioResponse))
                        && fixture.viewModel.generation == nil,
                    "首项成功也不能发布安全违约 partial")
                expect(fixture.viewModel.soundDescription == "短促 木琴 音效", "整批失败保留描述")
                expect(
                    await isolationWait { isolationGenerationIsEmpty(fixture.generations) },
                    "违约清理临时候选")
                let requests = IsolationURLProtocol.network.requests()
                expect(requests.filter { $0.httpMethod == "POST" }.count == 1, "违约不追加 POST")
                expect(
                    requests.filter { $0.httpMethod == "GET" }.count
                        == (violation == .origin ? 0 : 2),
                    "origin 预检失败零 GET；第二项违约不下载第三项")
                expect(
                    requests.filter { $0.httpMethod == "GET" }.allSatisfy {
                        $0.value(forHTTPHeaderField: "Authorization") == nil
                            && $0.value(forHTTPHeaderField: "Cookie") == nil
                            && $0.value(forHTTPHeaderField: "Referer") == nil
                    }, "故障路径 GET 仍匿名")
                expect(
                    await fixture.runtime.credentialManager.status(for: .senseAudioChina)
                        == .stored(verification: .verified, hasPendingReplacement: false),
                    "资源违约不拒绝 API Key")
                let key = root.appendingPathComponent("Credentials/senseaudio-cn.key")
                expect(
                    (try? Data(contentsOf: key)) == Data("fixture-only-isolated-senseaudio".utf8),
                    "资源违约不删除或替换假 Key")
                IsolationURLProtocol.network.reset(failedAssets: [])
                fixture.viewModel.startGeneration(locale: "zh-Hans")
                expect(
                    await isolationWait { fixture.viewModel.phase == .candidatesReady }, "下次显式生成可恢复"
                )
                expect(fixture.viewModel.generation?.completion == .complete, "恢复后恰好三个有效候选")
                fixture.viewModel.returnToDescription()
                expect(
                    await isolationWait { isolationGenerationIsEmpty(fixture.generations) },
                    "恢复候选也清理")
            }
        }
    }
    await suite("SenseAudio 隔离串联：URLSession→runtime→VM 的 1/3 保留候选 3 与原始字节") {
        await withTempDirectory { root in
            IsolationURLProtocol.network.reset(failedAssets: [0, 1])
            let fixture = await IsolationRuntime.make(root: root)
            defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
            fixture.viewModel.startGeneration(locale: "zh-Hans")
            expect(await isolationWait { fixture.viewModel.phase != .generating }, "受控生成必须在短窗口终止")
            guard let generation = fixture.viewModel.generation else {
                expect(false, "1/3 必须发布真实 generation，不是预置 gallery state")
                return
            }
            expect(generation.completion == .partial, "一个有效候选必须是 partial")
            expect(
                generation.candidates.map(\.identity) == [
                    .numbered(AICueCandidateOrdinal(rawValue: 3)!)
                ],
                "1/3 不能把候选 3 压缩为候选 1")
            let presentation = SettingsPresentationFixtures.generalLogin(
                temporaryParent: root,
                route: .events(scope: .surface(.workBuddy), event: .stop),
                availability: PreviewFixtures.settingsRouteAvailability,
                aiCueViewModel: fixture.viewModel)
            presentation.beginEventTransientActivity(scope: .surface(.workBuddy), event: .stop)
            SettingsMountRecorder.reset()
            let probe = SettingsRootNativeProbe(session: presentation.session)
            expect(
                SettingsMountRecorder.identifiers.contains("event-settings.ai-cue.composer"),
                "真实生成后的 VM 必须能挂载生产 composer，不是独立替代 view")
            probe.close()
            let candidate = generation.candidates.last!
            expect(
                (try? Data(contentsOf: candidate.asset.fileURL))
                    == IsolationNetwork.audio(index: 2),
                "展示候选必须使用对应 GET 返回的字节，不是其他事件的旧音频")
            let requests = IsolationURLProtocol.network.requests()
            expect(requests.filter { $0.httpMethod == "POST" }.count == 1, "受控生成 POST 零重试")
            expect(requests.filter { $0.httpMethod == "GET" }.count == 3, "404 不得触发 GET 重试")
            expect(
                requests.filter { $0.httpMethod == "GET" }.allSatisfy {
                    $0.value(forHTTPHeaderField: "Authorization") == nil
                        && $0.value(forHTTPHeaderField: "Cookie") == nil
                        && $0.value(forHTTPHeaderField: "Referer") == nil
                }, "真实 URLSession GET 不得继承 POST 认证")
            fixture.viewModel.returnToDescription()
            expect(
                await isolationWait {
                    !FileManager.default.fileExists(atPath: candidate.asset.fileURL.path)
                },
                "修改描述必须经真实 dispatcher/engine 清理临时候选")
        }
    }
    await suite("SenseAudio 隔离串联：2/3 保留 [1,3]，zero 恢复编辑并整批清理") {
        for failedAssets: Set<Int> in [[1], [0, 1, 2]] {
            await withTempDirectory { root in
                IsolationURLProtocol.network.reset(failedAssets: failedAssets)
                let fixture = await IsolationRuntime.make(root: root)
                defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
                fixture.viewModel.startGeneration(locale: "zh-Hans")
                expect(await isolationWait { fixture.viewModel.phase != .generating }, "受控故障必须终止")
                if failedAssets.count == 1 {
                    guard let generation = fixture.viewModel.generation else {
                        expect(false, "2/3 必须发布可用候选")
                        return
                    }
                    expect(generation.completion == .partial, "2/3 必须为 partial")
                    expect(
                        generation.candidates.map(\.identity)
                            == [1, 3].map { .numbered(AICueCandidateOrdinal(rawValue: $0)!) },
                        "下载失败的候选 2 不得导致 sibling 重新编号")
                    for (candidate, index) in zip(generation.candidates, [0, 2]) {
                        expect(
                            (try? Data(contentsOf: candidate.asset.fileURL))
                                == IsolationNetwork.audio(index: index), "每项必须保留各自 GET 字节")
                    }
                    fixture.viewModel.returnToDescription()
                } else {
                    expect(
                        fixture.viewModel.phase == .editing && fixture.viewModel.generation == nil
                            && fixture.viewModel.failure
                                == .generation(.insufficientValidCandidates),
                        "zero 不得发布 complete/partial，必须显示可恢复生成错误")
                    expect(fixture.viewModel.soundDescription == "短促 木琴 音效", "失败保留原描述")
                }
                expect(
                    await isolationWait { isolationGenerationIsEmpty(fixture.generations) },
                    "丢弃或零候选失败必须清理 generation child")
                let requests = IsolationURLProtocol.network.requests()
                expect(requests.filter { $0.httpMethod == "POST" }.count == 1, "不追加 POST")
                expect(requests.filter { $0.httpMethod == "GET" }.count == 3, "404 无重试")
                expect(
                    try! await fixture.vault.containsCredential(in: .senseAudioChina),
                    "asset 失败不得删除现有假凭据")
            }
        }
    }
    await suite("SenseAudio 隔离串联：挂起真实 POST 时描述拒写且请求内容不变") {
        await withTempDirectory { root in
            IsolationURLProtocol.network.reset(failedAssets: [], holdPost: true)
            let fixture = await IsolationRuntime.make(root: root)
            defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
            fixture.viewModel.startGeneration(locale: "zh-Hans")
            guard await isolationWait({ IsolationURLProtocol.network.hasHeldPost() }) else {
                fixture.viewModel.returnToDescription()
                expect(false, "实际 URLSession POST 必须到达受控挂起边界")
                return
            }
            fixture.viewModel.updateDescription("这个变化必须被拒绝")
            expect(fixture.viewModel.phase == .generating, "修改不能取消或重启生成")
            expect(fixture.viewModel.soundDescription == "短促 木琴 音效", "状态层保留原描述")
            IsolationURLProtocol.network.releasePost()
            expect(await isolationWait { fixture.viewModel.phase == .candidatesReady }, "原请求仍能完成")
            expect(fixture.viewModel.generation?.plan.soundDescription == "短促 木琴 音效", "方案不串描述")
            let body = IsolationURLProtocol.network.postBody().flatMap {
                (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
            }
            expect(body?["text"] as? String == "短促 木琴 音效", "实际传输 body 使用原声音描述")
            expect(body?["model"] as? String == "senseaudio-sfx-1.0-260626", "model 固定")
            expect(body?["variants_count"] as? Int == 3, "native batch 固定请求 3 项")
            expect(
                IsolationURLProtocol.network.requests().filter { $0.httpMethod == "POST" }.count
                    == 1,
                "拒写没有新增生成 POST")
            fixture.viewModel.returnToDescription()
            expect(
                await isolationWait { isolationGenerationIsEmpty(fixture.generations) }, "完整候选也须清理")
        }
    }
    await suite("SenseAudio 隔离串联：主动取消停止 URLSession，释放迟到响应不复活候选") {
        await withTempDirectory { root in
            IsolationURLProtocol.network.reset(failedAssets: [], holdPost: true)
            let fixture = await IsolationRuntime.make(root: root)
            defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
            fixture.viewModel.startGeneration(locale: "zh-Hans")
            guard await isolationWait({ IsolationURLProtocol.network.hasHeldPost() }) else {
                fixture.viewModel.returnToDescription()
                expect(false, "取消前必须存在真正挂起的网络任务")
                return
            }
            fixture.viewModel.returnToDescription()
            expect(fixture.viewModel.phase == .editing, "显式取消恢复编辑")
            expect(fixture.viewModel.soundDescription == "短促 木琴 音效", "显式取消保留描述")
            expect(
                await isolationWait { IsolationURLProtocol.network.stopCount() > 0 },
                "任务到达 stopLoading")
            IsolationURLProtocol.network.releasePost()
            expect(
                await isolationWait { isolationGenerationIsEmpty(fixture.generations) }, "取消整批清理")
            try? await Task.sleep(nanoseconds: 50_000_000)
            expect(
                fixture.viewModel.phase == .editing && fixture.viewModel.generation == nil
                    && fixture.viewModel.failure == nil, "受控迟到响应释放后不得复活 UI")
            fixture.viewModel.updateDescription("取消后可以编辑")
            expect(fixture.viewModel.soundDescription == "取消后可以编辑", "取消后恢复修改")
            let requests = IsolationURLProtocol.network.requests()
            expect(requests.filter { $0.httpMethod == "POST" }.count == 1, "取消不追加 POST")
            expect(requests.allSatisfy { $0.httpMethod != "GET" }, "取消的 batch 不开始下载")
        }
    }
    await suite("SenseAudio 隔离串联：401/503 无重试，真 manager 投影 rejected/verified 且保留假 Key") {
        for status in [401, 503] {
            await withTempDirectory { root in
                IsolationURLProtocol.network.reset(failedAssets: [], postStatus: status)
                let fixture = await IsolationRuntime.make(root: root)
                defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
                fixture.viewModel.startGeneration(locale: "zh-Hans")
                expect(await isolationWait { fixture.viewModel.phase == .editing }, "API 失败恢复编辑")
                let providerError: AICueProviderError =
                    status == 401 ? .invalidCredential : .serviceUnavailable
                expect(
                    fixture.viewModel.failure == .generation(.provider(providerError)),
                    "错误从真实 adapter 传至 VM")
                let credentialStatus = AICueCredentialStatus.stored(
                    verification: status == 401 ? .rejected : .verified,
                    hasPendingReplacement: false)
                expect(
                    await fixture.runtime.credentialManager.status(for: .senseAudioChina)
                        == credentialStatus,
                    "401 只拒绝验证状态，503 不损坏验证事实")
                await fixture.viewModel.refreshCredentialStatus()
                expect(
                    fixture.viewModel.credentialStatus == credentialStatus, "VM 投影与真实 manager 一致")
                expect(
                    try! await fixture.vault.containsCredential(in: .senseAudioChina), "错误不删除假 Key")
                expect(fixture.viewModel.soundDescription == "短促 木琴 音效", "错误保描述")
                expect(
                    await isolationWait { isolationGenerationIsEmpty(fixture.generations) },
                    "错误不留临时批次")
                let requests = IsolationURLProtocol.network.requests()
                expect(requests.filter { $0.httpMethod == "POST" }.count == 1, "401/503 不重试生成")
                expect(requests.allSatisfy { $0.httpMethod != "GET" }, "API 失败不下载旧 URL")
            }
        }
    }
    await suite("SenseAudio 隔离串联：缺失/权限异常假凭据在网络前失败，保描述且不修复权限") {
        for missing in [true, false] {
            await withTempDirectory { root in
                IsolationURLProtocol.network.reset(failedAssets: [])
                let fixture = await IsolationRuntime.make(root: root)
                defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
                let file = root.appendingPathComponent("Credentials/senseaudio-cn.key")
                if missing {
                    try! await fixture.vault.deleteCredential(in: .senseAudioChina)
                } else {
                    try! FileManager.default.setAttributes(
                        [.posixPermissions: 0o644], ofItemAtPath: file.path)
                }
                fixture.viewModel.startGeneration(locale: "zh-Hans")
                expect(await isolationWait { fixture.viewModel.phase == .editing }, "凭据异常恢复编辑")
                expect(
                    fixture.viewModel.failure
                        == .generation(missing ? .credentialRequired : .credentialUnavailable),
                    "异常使用现有 typed 凭据错误")
                await fixture.viewModel.refreshCredentialStatus()
                expect(
                    fixture.viewModel.credentialStatus == (missing ? .missing : .unavailable),
                    "不伪装已验证")
                expect(IsolationURLProtocol.network.requests().isEmpty, "凭据异常 POST/GET 均为零")
                expect(fixture.viewModel.soundDescription == "短促 木琴 音效", "凭据异常保原描述")
                expect(isolationGenerationIsEmpty(fixture.generations), "凭据异常不留批次")
                if !missing {
                    let attributes = try! FileManager.default.attributesOfItem(atPath: file.path)
                    expect(
                        (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o644,
                        "生成不擅自修复坏权限或覆盖凭据")
                    expect(
                        try! Data(contentsOf: file)
                            == Data("fixture-only-isolated-senseaudio".utf8),
                        "仅检查临时假 Key 字节，异常不改写内容")
                }
            }
        }
    }
    await suite("SenseAudio 隔离串联：真实候选→VM→owner 采用落盘，再关闭隔离 gate 保留采用与凭据") {
        await withTempDirectory { root in
            IsolationURLProtocol.network.reset(failedAssets: [])
            let fixture = await IsolationRuntime.make(root: root)
            defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
            fixture.viewModel.startGeneration(locale: "zh-Hans")
            guard await isolationWait({ fixture.viewModel.phase == .candidatesReady }),
                let generation = fixture.viewModel.generation,
                let candidate = generation.candidates.first
            else { expect(false, "采用必须来源于真实 engine 输出"); return }
            let editorRoot = root.appendingPathComponent("editor")
            let editor = isolationEditor(root: editorRoot)
            guard let permit = await isolationAdoptionPermit(editor, generationID: generation.id)
            else {
                fixture.viewModel.returnToDescription(); return
            }
            let manifest = editorRoot.appendingPathComponent("packs/workbuddy-pack/manifest.json")
            let globalManifest = editorRoot.appendingPathComponent(
                "packs/global-pack/manifest.json")
            let globalBefore = try! Data(contentsOf: globalManifest)
            let configBefore = try! Data(contentsOf: editor.configFile)
            fixture.viewModel.updateDisplayName("隔离木琴")
            var result: SoundPacksEditorOperationResult?
            fixture.viewModel.adopt(candidateID: candidate.id, permit: permit) {
                candidate, name, permit in
                let terminal = await editor.owner.perform(
                    .adoptAICue(candidate: candidate, displayName: name, permit: permit))
                result = terminal
                return terminal
            }
            expect(await isolationWait { fixture.viewModel.phase != .adopting }, "真实采用必须终止")
            guard case .adopted(let outcome) = result else {
                expect(false, "采用必须返回 owner 的真实 adopted，不是伪造闭包成功")
                fixture.viewModel.returnToDescription(); return
            }
            expect(
                fixture.viewModel.phase == .applied && fixture.viewModel.failure == nil, "VM 采用成功投影"
            )
            expect(fixture.viewModel.adoptionOutcome?.finalDisplayName == "隔离木琴", "采用名称回显")
            let adoptedBytes = try! Data(contentsOf: outcome.importedFile.destinationURL)
            expect(adoptedBytes == IsolationNetwork.audio(index: 0), "采用字节必须等于候选 1 的 GET 字节")
            let manifestBytes = try! Data(contentsOf: manifest)
            let object = try! JSONSerialization.jsonObject(with: manifestBytes) as! [String: Any]
            expect(
                (object["events"] as? [String: String])?["stop"] == outcome.importedFile.fileName,
                "读回磁盘 Event binding")
            expect(
                (object["audio_names"] as? [String: String])?[outcome.importedFile.fileName]
                    == "隔离木琴", "读回磁盘名称绑定")
            expect((object["future"] as? [String: Bool])?["keep"] == true, "未知字段保留")
            expect(try! Data(contentsOf: globalManifest) == globalBefore, "采用不污染 Global 包")
            expect(try! Data(contentsOf: editor.configFile) == configBefore, "采用不改 Surface 选择与其他配置")
            expect(
                await isolationWait { isolationGenerationIsEmpty(fixture.generations) },
                "采用完成清理临时候选")

            let countBeforeRollback = IsolationURLProtocol.network.requests().count
            let closedRegistry = AICueProviderRegistry(evidenceGatedSenseAudioAssetPolicy: nil)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [IsolationURLProtocol.self]
            let closedRuntime = try! AICueRuntime(
                registry: closedRegistry, vault: fixture.vault, temporaryRoot: fixture.generations,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                unaryTransport: AICueURLSessionUnaryTransport(configuration: configuration),
                sseTransport: IsolationRejectingSSETransport(),
                assetFetcher: AICueURLSessionAssetFetcher(
                    loader: AICueURLSessionAssetLoader(configuration: configuration),
                    retrySleeper: IsolationRetrySleeper()),
                credentialMetadata: IsolationMetadata(), providerDefaults: fixture.defaults)
            let closedVM = AICueGenerationViewModel(
                credentialManager: closedRuntime.credentialManager,
                generator: closedRuntime.dispatcher,
                registry: closedRegistry, providerPreferences: closedRuntime.providerPreferences)
            expect(
                !closedRuntime.generatorProfileIDs.contains(.senseAudioChina),
                "关闭 gate 移除 SenseAudio 引擎")
            expect(closedVM.providerProfileID == .elevenLabsGlobal, "失效偏好只解析为默认 Provider，不发备用请求")
            expect(
                fixture.defaults.string(forKey: AICueProviderPreferences.defaultsKey)
                    == AICueProviderProfileID.senseAudioChina.rawValue,
                "回滚不覆盖原始 Provider 偏好")
            do {
                _ = try await closedRuntime.dispatcher.generate(
                    description: "短促 木琴 音效", locale: "zh-Hans", providerProfileID: .senseAudioChina,
                    deadline: .startingNow())
                expect(false, "关闭 gate 后不能直接生成 SenseAudio")
            } catch {
                expect(
                    error as? AICueGenerationError == .providerUnavailable,
                    "关闭 gate 在 dispatcher 边界拒绝")
            }
            expect(
                IsolationURLProtocol.network.requests().count == countBeforeRollback,
                "隔离回滚不产生 POST/GET")
            expect(try! await fixture.vault.containsCredential(in: .senseAudioChina), "回滚保留假本地凭据")
            expect(try! Data(contentsOf: manifest) == manifestBytes, "回滚保留已采用绑定及未知字段")
            expect(
                try! Data(contentsOf: outcome.importedFile.destinationURL) == adoptedBytes,
                "回滚保留已采用音频")
            expect(try! Data(contentsOf: editor.configFile) == configBefore, "回滚不改来源配置")
        }
    }
    await suite("SenseAudio 隔离串联：采用前 generation 漂移零写，VM 保候选与原描述") {
        await withTempDirectory { root in
            IsolationURLProtocol.network.reset(failedAssets: [])
            let fixture = await IsolationRuntime.make(root: root)
            defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
            fixture.viewModel.startGeneration(locale: "zh-Hans")
            guard await isolationWait({ fixture.viewModel.phase == .candidatesReady }),
                let generation = fixture.viewModel.generation,
                let candidate = generation.candidates.first
            else { expect(false, "失败采用必须使用真实候选"); return }
            let editorRoot = root.appendingPathComponent("editor")
            let editor = isolationEditor(root: editorRoot)
            guard let permit = await isolationAdoptionPermit(editor, generationID: generation.id)
            else {
                fixture.viewModel.returnToDescription(); return
            }
            let pack = editorRoot.appendingPathComponent("packs/workbuddy-pack")
            let manifest = pack.appendingPathComponent("manifest.json")
            let before = try! Data(contentsOf: manifest)
            let entries = try! FileManager.default.contentsOfDirectory(atPath: pack.path)
            let configBefore = try! Data(contentsOf: editor.configFile)
            _ = editor.owner.send(
                .activate(
                    .events(
                        route: EventSettingsWindowRoute(scope: .surface(.workBuddy), event: .stop),
                        requestRevision: 2, candidateGenerationID: UUID())))
            var result: SoundPacksEditorOperationResult?
            fixture.viewModel.adopt(candidateID: candidate.id, permit: permit) {
                candidate, name, permit in
                let terminal = await editor.owner.perform(
                    .adoptAICue(candidate: candidate, displayName: name, permit: permit))
                result = terminal
                return terminal
            }
            fixture.viewModel.updateDescription("采用中也应拒写")
            expect(
                fixture.viewModel.phase == .adopting
                    && fixture.viewModel.soundDescription == "短促 木琴 音效",
                "采用 task 执行前已锁定描述")
            expect(await isolationWait { fixture.viewModel.phase == .candidatesReady }, "拒绝恢复候选态")
            expect(result == .rejected(.stalePermit), "真实 owner 消费过期 permit 后拒绝")
            expect(fixture.viewModel.failure == .adoption(.rejected), "失败诚实投影，不伪造采用成功")
            expect(fixture.viewModel.generation?.id == generation.id, "失败保留同一批候选")
            expect(try! Data(contentsOf: manifest) == before, "失败保旧 manifest 全字节")
            expect(
                Set(try! FileManager.default.contentsOfDirectory(atPath: pack.path))
                    == Set(entries), "前置拒绝没有落盘孤儿")
            expect(try! Data(contentsOf: editor.configFile) == configBefore, "失败保配置")
            expect(
                try! Data(contentsOf: candidate.asset.fileURL) == IsolationNetwork.audio(index: 0),
                "候选仍可供后续恢复")
            fixture.viewModel.returnToDescription()
            expect(
                await isolationWait { isolationGenerationIsEmpty(fixture.generations) },
                "修改描述能清理失败保留的候选")
            expect(
                IsolationURLProtocol.network.requests().filter { $0.httpMethod == "POST" }.count
                    == 1, "采用失败无新增 POST")
        }
    }
    await suite("SenseAudio 隔离串联：导入后取消/漂移保旧绑定，owner 与 VM 诚实报告 recoverable orphan") {
        for cancel in [true, false] {
            await withTempDirectory { root in
                IsolationURLProtocol.network.reset(failedAssets: [])
                let fixture = await IsolationRuntime.make(root: root)
                defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
                fixture.viewModel.startGeneration(locale: "zh-Hans")
                guard await isolationWait({ fixture.viewModel.phase == .candidatesReady }),
                    let generation = fixture.viewModel.generation,
                    let candidate = generation.candidates.last
                else { expect(false, "孤儿用例必须使用真实 engine 候选"); return }
                let gate = IsolationPostImportGate()
                defer { gate.release() }
                let editorRoot = root.appendingPathComponent("editor")
                let editor = isolationEditor(root: editorRoot, afterImport: { gate.pauseWorker() })
                guard
                    let permit = await isolationAdoptionPermit(editor, generationID: generation.id)
                else {
                    fixture.viewModel.returnToDescription(); return
                }
                let pack = editorRoot.appendingPathComponent("packs/workbuddy-pack")
                let manifest = pack.appendingPathComponent("manifest.json")
                let manifestBefore = try! Data(contentsOf: manifest)
                let oldAudio = try! Data(contentsOf: pack.appendingPathComponent("stop.mp3"))
                let configBefore = try! Data(contentsOf: editor.configFile)
                let entriesBefore = Set(
                    try! FileManager.default.contentsOfDirectory(atPath: pack.path))
                let scansBefore = editor.recorder.requests.count
                fixture.viewModel.updateDisplayName("孤儿不应绑定")
                var result: SoundPacksEditorOperationResult?
                fixture.viewModel.adopt(candidateID: candidate.id, permit: permit) {
                    candidate, name, permit in
                    let terminal = await editor.owner.perform(
                        .adoptAICue(candidate: candidate, displayName: name, permit: permit))
                    result = terminal
                    return terminal
                }
                guard await isolationWait({ gate.hasEntered() }) else {
                    gate.release()
                    _ = await isolationWait { fixture.viewModel.phase != .adopting }
                    fixture.viewModel.returnToDescription()
                    expect(false, "采用必须到达导入后、绑定前的既有测试边界")
                    return
                }
                let newEntries = Set(
                    try! FileManager.default.contentsOfDirectory(atPath: pack.path)
                ).subtracting(entriesBefore)
                expect(newEntries.count == 1, "gate 前已经真实复制且只复制一个文件")
                if let fileName = newEntries.first {
                    expect(
                        try! Data(contentsOf: pack.appendingPathComponent(fileName))
                            == IsolationNetwork.audio(index: 2),
                        "导入文件使用候选 3 的真实受控 GET 字节")
                }
                expect(try! Data(contentsOf: manifest) == manifestBefore, "gate 位于最终 binding 之前")
                expect(editor.recorder.requests.count == scansBefore, "gate 位于唯一 refresh 之前")
                fixture.viewModel.updateDescription("采用中修改必须拒绝")
                fixture.viewModel.returnToDescription()
                expect(
                    fixture.viewModel.phase == .adopting
                        && fixture.viewModel.soundDescription == "短促 木琴 音效",
                    "采用中改描述/返回不能穿透采用保护")
                if cancel {
                    if let action = editor.owner.presentation.activities.last(where: {
                        $0.kind == .adoptAICue && $0.phase == .busy
                    })?.cancelAction {
                        expect(
                            editor.owner.send(.invoke(action)) == .applied,
                            "已有 owner cancel capability 命中真实任务")
                    } else {
                        expect(false, "忙状态必须提供取消 capability")
                    }
                } else {
                    _ = editor.owner.send(
                        .activate(
                            .events(
                                route: EventSettingsWindowRoute(
                                    scope: .surface(.workBuddy), event: .stop),
                                requestRevision: 2, candidateGenerationID: UUID())))
                }
                gate.release()
                expect(
                    await isolationWait { fixture.viewModel.phase == .candidatesReady }, "采用故障恢复候选态"
                )
                guard case .adoptionOrphan(let imported, let failure) = result else {
                    expect(false, "真实 owner 必须返回孤儿而非成功或假回滚")
                    fixture.viewModel.returnToDescription(); return
                }
                expect(!gate.didTimeout(), "测试 gate 不靠超时释放")
                expect(failure == (cancel ? .cancelled : .targetChanged), "owner 保留准确孤儿原因")
                expect(
                    fixture.viewModel.failure
                        == .adoption(.importedButNotBound(fileName: imported.fileName)),
                    "VM 诚实显示已导入但未绑定")
                expect(fixture.viewModel.generation?.id == generation.id, "采用故障保留原候选")
                expect(
                    try! Data(contentsOf: manifest) == manifestBefore, "旧 manifest/binding 全字节保留")
                expect(
                    try! Data(contentsOf: pack.appendingPathComponent("stop.mp3")) == oldAudio,
                    "旧音频全字节保留")
                expect(try! Data(contentsOf: editor.configFile) == configBefore, "Surface 配置未改变")
                expect(
                    try! Data(contentsOf: imported.destinationURL)
                        == IsolationNetwork.audio(index: 2), "孤儿真实存在且可恢复")
                expect(
                    Set(try! FileManager.default.contentsOfDirectory(atPath: pack.path))
                        .subtracting(entriesBefore) == [imported.fileName],
                    "不伪造完全回滚，只留唯一 recoverable orphan")
                expect(
                    await isolationWait { editor.recorder.requests.count == scansBefore + 1 },
                    "changed-on-disk 触发 refresh")
                await editor.library.waitUntilIdleForTesting()
                expect(
                    editor.recorder.requests.count == scansBefore + 1
                        && editor.recorder.requests.last?.invalidatedPackIDs == ["workbuddy-pack"],
                    "仅一次 exact pack refresh")
                fixture.viewModel.returnToDescription()
                expect(
                    await isolationWait { isolationGenerationIsEmpty(fixture.generations) },
                    "返回编辑清理临时候选")
                expect(
                    FileManager.default.fileExists(atPath: imported.destinationURL.path),
                    "清理候选不误删已导入孤儿")
                expect(
                    try! await fixture.vault.containsCredential(in: .senseAudioChina), "采用故障不损坏假凭据")
                expect(
                    IsolationURLProtocol.network.requests().filter { $0.httpMethod == "POST" }.count
                        == 1, "采用故障不追加生成")
            }
        }
    }
}

/// Only the pre-existing DEBUG import-finalization boundary is delayed. No production API is added.
private final class IsolationPostImportGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var timedOut = false

    func pauseWorker() {
        condition.lock()
        defer { condition.unlock() }
        entered = true
        let deadline = Date(timeIntervalSinceNow: 5)
        while !released {
            if !condition.wait(until: deadline) { timedOut = true; break }
        }
    }

    func hasEntered() -> Bool {
        condition.lock(); defer { condition.unlock() }
        return entered
    }

    func didTimeout() -> Bool {
        condition.lock(); defer { condition.unlock() }
        return timedOut
    }

    func release() {
        condition.lock(); defer { condition.unlock() }
        released = true
        condition.broadcast()
    }
}

@MainActor
private func isolationEditor(
    root: URL, afterImport: (@Sendable () -> Void)? = nil
) -> SoundEditorFixture {
    makeSoundEditorFixture(
        root: root, packIDs: ["global-pack", "workbuddy-pack"],
        durationProbe: StubDurationProbe(fixedDuration: 1),
        config: ClaudioConfig(
            selectedPack: "global-pack",
            surfaceOverrides: [
                HostSurfaceID.workBuddy.rawValue: SurfaceSoundOverride(
                    selectedPack: "workbuddy-pack")
            ]),
        afterFinalImportCancellationSampleForTesting: afterImport)
}

@MainActor
private func isolationAdoptionPermit(_ editor: SoundEditorFixture, generationID: UUID) async
    -> SoundPackAdoptionPermit?
{
    _ = editor.owner.send(
        .activate(
            .events(
                route: EventSettingsWindowRoute(scope: .surface(.workBuddy), event: .stop),
                requestRevision: 1, candidateGenerationID: generationID)))
    await waitForSoundEditorReady(editor.owner, library: editor.library)
    guard case .events(let events) = editor.owner.presentation.mode,
        let permit = events.adoptionPermit
    else {
        expect(false, "隔离 Surface 独立包必须可签发采用 permit")
        return nil
    }
    return permit
}

private func isolationGenerationIsEmpty(_ root: URL) -> Bool {
    guard FileManager.default.fileExists(atPath: root.path) else { return true }
    guard let contents = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
        return false
    }
    return contents.isEmpty
}
