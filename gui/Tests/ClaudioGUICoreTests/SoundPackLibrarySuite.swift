import ClaudioCore
import ClaudioGUICore
import Foundation

private actor SoundPackLibraryStateRecorder {
    private(set) var states: [SoundPackLibraryState] = []

    func append(_ state: SoundPackLibraryState) {
        states.append(state)
    }

    func containsReadyPack(named name: String) -> Bool {
        states.contains { state in
            guard case .ready(let snapshot) = state else { return false }
            return snapshot.facts.first?.name == name
        }
    }

    func containsReadyPack(named name: String, before newerName: String) -> Bool {
        guard
            let newerIndex = states.firstIndex(where: { state in
                guard case .ready(let snapshot) = state else { return false }
                return snapshot.facts.first?.name == newerName
            })
        else { return false }
        return states[..<newerIndex].contains { state in
            guard case .ready(let snapshot) = state else { return false }
            return snapshot.facts.first?.name == name
        }
    }

    func failedState() -> SoundPackLibraryState? {
        states.last { state in
            if case .failed = state { return true }
            return false
        }
    }

    func containsFailure(reason: String) -> Bool {
        states.contains { state in
            guard case .failed(_, let error) = state else { return false }
            return error.message.contains(reason)
        }
    }

    func readySnapshot(containing packID: String) -> SoundPackLibrarySnapshot? {
        for state in states.reversed() {
            guard case .ready(let snapshot) = state else { continue }
            if snapshot.fact(for: packID) != nil { return snapshot }
        }
        return nil
    }
}

private final class BlockingSoundPackScanner: @unchecked Sendable {
    private let lock = NSLock()
    private let firstEntered = DispatchSemaphore(value: 0)
    private let firstResume = DispatchSemaphore(value: 0)
    private var callCountStorage = 0
    private let firstFacts: [SoundPackFacts]
    private let laterFacts: [SoundPackFacts]

    init(firstFacts: [SoundPackFacts], laterFacts: [SoundPackFacts]? = nil) {
        self.firstFacts = firstFacts
        self.laterFacts = laterFacts ?? firstFacts
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCountStorage
    }

    func waitUntilFirstScanEntered() -> Bool {
        firstEntered.wait(timeout: .now() + 5) == .success
    }

    func allowFirstScanToFinish() {
        firstResume.signal()
    }

    func scan(_ request: SoundPackLibraryScanRequest) -> Result<
        [SoundPackFacts], SoundPackLibraryError
    > {
        lock.lock()
        callCountStorage += 1
        let call = callCountStorage
        lock.unlock()

        if call == 1 {
            firstEntered.signal()
            _ = firstResume.wait(timeout: .now() + 5)
            return .success(firstFacts)
        }
        return .success(laterFacts)
    }
}

private final class ScriptedSoundPackScanner: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<[SoundPackFacts], SoundPackLibraryError>]
    private var requestsStorage: [SoundPackLibraryScanRequest] = []

    init(_ results: [Result<[SoundPackFacts], SoundPackLibraryError>]) {
        self.results = results
    }

    func scan(_ request: SoundPackLibraryScanRequest) -> Result<
        [SoundPackFacts], SoundPackLibraryError
    > {
        lock.lock()
        defer { lock.unlock() }
        requestsStorage.append(request)
        guard !results.isEmpty else { return .failure(.scanFailed(reason: "测试结果已耗尽")) }
        return results.removeFirst()
    }

    var requests: [SoundPackLibraryScanRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requestsStorage
    }
}

private final class SecondScanBlockingSoundPackScanner: @unchecked Sendable {
    private let lock = NSLock()
    private let secondEntered = DispatchSemaphore(value: 0)
    private let secondResume = DispatchSemaphore(value: 0)
    private var callCountStorage = 0
    private let readyFacts: [SoundPackFacts]
    private let recoveredFacts: [SoundPackFacts]

    init(readyFacts: [SoundPackFacts], recoveredFacts: [SoundPackFacts]) {
        self.readyFacts = readyFacts
        self.recoveredFacts = recoveredFacts
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCountStorage
    }

    func waitUntilSecondScanEntered() -> Bool {
        secondEntered.wait(timeout: .now() + 5) == .success
    }

    func allowSecondScanToFinish() {
        secondResume.signal()
    }

    func scan(_ request: SoundPackLibraryScanRequest) -> Result<
        [SoundPackFacts], SoundPackLibraryError
    > {
        lock.lock()
        callCountStorage += 1
        let call = callCountStorage
        lock.unlock()
        switch call {
        case 1:
            return .success(readyFacts)
        case 2:
            secondEntered.signal()
            _ = secondResume.wait(timeout: .now() + 5)
            return .failure(.scanFailed(reason: "模拟刷新失败"))
        default:
            return .success(recoveredFacts)
        }
    }
}

private final class ForkRefreshBlockingSoundPackScanner: @unchecked Sendable {
    private let lock = NSLock()
    private let secondEntered = DispatchSemaphore(value: 0)
    private let secondResume = DispatchSemaphore(value: 0)
    private var callCountStorage = 0
    private let initialOutput: SoundPackLibraryScanOutput
    private let refreshedOutput: SoundPackLibraryScanOutput

    init(
        initialFacts: [SoundPackFacts],
        refreshedFacts: [SoundPackFacts],
        factoryPackIDs: Set<String>
    ) {
        initialOutput = SoundPackLibraryScanOutput(
            facts: initialFacts, factoryPackIDs: factoryPackIDs)
        refreshedOutput = SoundPackLibraryScanOutput(
            facts: refreshedFacts, factoryPackIDs: factoryPackIDs)
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCountStorage
    }

    func waitUntilSecondScanEntered() -> Bool {
        secondEntered.wait(timeout: .now() + 5) == .success
    }

    func allowSecondScanToFinish() {
        secondResume.signal()
    }

    func scan(_ request: SoundPackLibraryScanRequest) -> Result<
        SoundPackLibraryScanOutput, SoundPackLibraryError
    > {
        lock.lock()
        callCountStorage += 1
        let call = callCountStorage
        lock.unlock()
        if call == 2 {
            secondEntered.signal()
            _ = secondResume.wait(timeout: .now() + 5)
        }
        return .success(call == 1 ? initialOutput : refreshedOutput)
    }
}

private final class FirstPublicationBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)
    private var invocationCount = 0

    func pauseFirstPublication() {
        lock.lock()
        invocationCount += 1
        let shouldPause = invocationCount == 1
        lock.unlock()
        guard shouldPause else { return }
        entered.signal()
        _ = resume.wait(timeout: .now() + 5)
    }

    func waitUntilPaused() -> Bool {
        entered.wait(timeout: .now() + 5) == .success
    }

    func allowPublication() {
        resume.signal()
    }
}

private final class BlockingAudioInventoryLoader: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)
    private var callCountStorage = 0
    private let result: SoundPackAudioInventory

    init(result: SoundPackAudioInventory) {
        self.result = result
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCountStorage
    }

    func load(packID: String) -> SoundPackAudioInventory {
        lock.lock()
        callCountStorage += 1
        lock.unlock()
        entered.signal()
        _ = resume.wait(timeout: .now() + 5)
        return result
    }

    func allowLoadToFinish() {
        resume.signal()
    }
}

private final class SequencedBlockingAudioInventoryLoader: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)
    private var callCountStorage = 0
    private let results: [SoundPackAudioInventory]
    private let blockingCall: Int

    init(results: [SoundPackAudioInventory], blockingCall: Int) {
        self.results = results
        self.blockingCall = blockingCall
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCountStorage
    }

    func waitUntilBlocked() -> Bool {
        entered.wait(timeout: .now() + 5) == .success
    }

    func allowBlockedLoadToFinish() {
        resume.signal()
    }

    func load(packID: String) -> SoundPackAudioInventory {
        lock.lock()
        callCountStorage += 1
        let call = callCountStorage
        lock.unlock()
        if call == blockingCall {
            entered.signal()
            _ = resume.wait(timeout: .now() + 5)
        }
        guard !results.isEmpty else {
            return .unavailable(.directoryUnreadable(reason: "测试结果已耗尽"))
        }
        return results[min(call - 1, results.count - 1)]
    }
}

private final class ScriptedAudioInventoryLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [SoundPackAudioInventory]
    private var callCountStorage = 0

    init(results: [SoundPackAudioInventory]) {
        self.results = results
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCountStorage
    }

    func load(packID: String) -> SoundPackAudioInventory {
        lock.lock()
        defer { lock.unlock() }
        callCountStorage += 1
        guard !results.isEmpty else {
            return .unavailable(.directoryUnreadable(reason: "测试结果已耗尽"))
        }
        return results.removeFirst()
    }
}

private final class AtomicManifestReplacement: @unchecked Sendable {
    private let lock = NSLock()
    private let manifestURL: URL
    private let replacementData: Data
    private var didReplace = false
    private var callbackCountStorage = 0

    init(manifestURL: URL, replacement: String) {
        self.manifestURL = manifestURL
        replacementData = Data(replacement.utf8)
    }

    var callbackCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callbackCountStorage
    }

    func replaceOnce(afterReading packID: String) {
        guard packID == "pack-a" else { return }
        lock.lock()
        callbackCountStorage += 1
        let shouldReplace = !didReplace
        didReplace = true
        lock.unlock()
        if shouldReplace {
            try? replacementData.write(to: manifestURL, options: .atomic)
        }
    }
}

private final class RecordingDiskSoundPackScanner: @unchecked Sendable {
    private let lock = NSLock()
    private let environment: AudioImportEnvironment
    private let factoryPackIDs: Set<String>
    private var requestsStorage: [SoundPackLibraryScanRequest] = []

    init(environment: AudioImportEnvironment, factoryPackIDs: Set<String> = []) {
        self.environment = environment
        self.factoryPackIDs = factoryPackIDs
    }

    var requests: [SoundPackLibraryScanRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requestsStorage
    }

    var callCount: Int { requests.count }

    func scan(_ request: SoundPackLibraryScanRequest) -> Result<
        SoundPackLibraryScanOutput, SoundPackLibraryError
    > {
        lock.lock()
        requestsStorage.append(request)
        lock.unlock()
        let config = ClaudioConfig(selectedPack: "")
        let cards = availablePacks(config: config, environment: environment)
        let facts = cards.map { card -> SoundPackFacts in
            let rows = packCoverage(packID: card.id, config: config, environment: environment)
            let coverage = Dictionary(uniqueKeysWithValues: rows.map { ($0.event, $0.coverage) })
            let inventory: SoundPackAudioInventory
            switch packAudioFiles(packID: card.id, environment: environment) {
            case .success(let files): inventory = .available(files)
            case .failure(let error): inventory = .unavailable(error)
            }
            return SoundPackFacts(
                id: card.id,
                name: card.name,
                isCC0: card.isCC0,
                factoryIntegrity: card.factoryIntegrity,
                eventCoverage: coverage,
                cardState: card.state,
                audioInventory: inventory)
        }
        return .success(
            SoundPackLibraryScanOutput(facts: facts, factoryPackIDs: factoryPackIDs))
    }
}

private enum InjectedFactoryPublishFailure: Error {
    case firstAttempt
}

private final class FailFirstFactoryPublish: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFailed = false

    func call() throws {
        lock.lock()
        let shouldFail = !hasFailed
        hasFailed = true
        lock.unlock()
        if shouldFail { throw InjectedFactoryPublishFailure.firstAttempt }
    }
}

private func soundPackLibraryRepositoryRoot(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func libraryFacts(
    id: String = "pack-a",
    name: String,
    coverage: [Event: CoverageState] = [.stop: .present(fileName: "stop.mp3")],
    audioInventory: SoundPackAudioInventory = .available([
        PackAudioFile(fileName: "stop.mp3", isOrphan: false)
    ])
) -> SoundPackFacts {
    SoundPackFacts(
        id: id,
        name: name,
        isCC0: false,
        factoryIntegrity: nil,
        eventCoverage: coverage,
        cardState: .partial(
            present: coverage.values.filter(\.previewEnabled).count, total: Event.allCases.count),
        audioInventory: audioInventory)
}

@MainActor
private func recordLibraryStates(
    from library: SoundPackLibrary,
    into recorder: SoundPackLibraryStateRecorder
) -> Task<Void, Never> {
    Task {
        let stream = await library.states()
        for await state in stream {
            await recorder.append(state)
            if Task.isCancelled { return }
        }
    }
}

@MainActor
private func waitForLibraryCondition(
    timeoutNanoseconds: UInt64 = 5_000_000_000,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if await condition() { return true }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return await condition()
}

@MainActor
func runSoundPackLibrarySuites() async {
    suite("SoundPackLibrary composition root：只有真实 app bundle 配置必需 factory root") {
        let releaseBundle = URL(fileURLWithPath: "/Applications/claudi0.app", isDirectory: true)
        expect(
            applicationFactoryPacksDirectory(bundleURL: releaseBundle)?.path
                == "/Applications/claudi0.app/Contents/Resources/packs",
            "正式 .app 必须配置固定 factory root，目录真正缺失时交给 library fail closed")

        let swiftRunBundle = URL(
            fileURLWithPath: "/tmp/Claudio/gui/.build/arm64-apple-macosx/debug",
            isDirectory: true)
        expect(
            applicationFactoryPacksDirectory(bundleURL: swiftRunBundle) == nil,
            "SwiftPM 可执行的 resourceURL 不是 app factory root，开发态不得伪造必需目录")
    }

    suite("SoundPackLibrary composition root：生产只构造一个实例并接入双消费者与激活刷新") {
        let sourceURL = soundPackLibraryRepositoryRoot()
            .appendingPathComponent("gui/Sources/ClaudioGUI/MenuBarController.swift")
        let source = (try? String(contentsOf: sourceURL, encoding: .utf8)) ?? ""
        expect(!source.isEmpty, "必须能读取真实 composition root")
        expect(
            source.components(separatedBy: "SoundPackLibrary(environment: audioEnvironment)")
                .count - 1 == 1,
            "MenuBarController 必须只构造一个 app-lifetime SoundPackLibrary")
        expect(
            source.contains(
                "SoundPacksWindowController(\n            configFile: ClaudioPaths.configFile,\n            environment: audioEnvironment,\n            soundPackLibrary: soundPackLibrary"
            )
                && source.contains("languageStore: languageStore")
                && source.contains(
                    "PanelView(\n            audioEnvironment: audioEnvironment,\n            focusCoordinator: focusCoordinator,\n            hostIntegrations: hostIntegrations,\n            bootstrapReports: bootstrapReports,\n            languageStore: languageStore,\n            soundPackLibrary: soundPackLibrary"
                ),
            "同一个局部实例必须同时注入管理窗口与面板")
        expect(
            source.contains("NSApplication.didBecomeActiveNotification")
                && source.contains("soundPackLibrary.requestRefresh(")
                && source.contains("trigger: .applicationActivation")
                && source.contains("refreshWindowConfigProjection()"),
            "app 激活必须同时刷新共享库与保留窗口的 config 投影")
    }

    await suite("SoundPackLibrary 注入：面板与管理窗口共享一次扫描，构造过程不等待磁盘") {
        await withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDirectory = root.appendingPathComponent("packs", isDirectory: true)
            writeFixture(
                #"{"selected_pack":"pack-a","events":{"stop":false},"starred_packs":["pack-a"]}"#,
                to: configFile)
            writeFixture(
                #"{"id":"pack-a","name":"共享包","events":{"stop":"stop.mp3"}}"#,
                to:
                    packsDirectory
                    .appendingPathComponent("pack-a", isDirectory: true)
                    .appendingPathComponent("manifest.json"))
            let scanner = BlockingSoundPackScanner(firstFacts: [libraryFacts(name: "共享包")])
            let library = SoundPackLibrary(
                scanner: SoundPackLibraryScanner(operation: scanner.scan))
            let coordinator = SoundPacksRefreshCoordinator()
            let environment = AudioImportEnvironment(
                userPacksDirectory: packsDirectory,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: root.appendingPathComponent("packs.lock"))

            let panel = PanelConfigController(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                soundPackLibrary: library,
                soundPacksRefreshCoordinator: coordinator)
            let window = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                soundPackLibrary: library,
                refreshCoordinator: coordinator)

            expect(panel.packSectionState == .loading, "面板构造必须立即返回加载态")
            expect(panel.packCards.isEmpty, "首次扫描未完成前不能伪造包卡")
            expect(panel.eventRows.isEmpty, "首次扫描未完成前不能把未知映射伪装成未配置")
            expect(window.libraryPresentationState == .loading, "窗口构造必须立即返回加载态")
            expect(window.packCards.isEmpty, "窗口构造不能同步偷跑一次扫描")
            expect(
                await waitForLibraryCondition { scanner.callCount == 1 },
                "共享扫描必须在后台开始")
            scanner.allowFirstScanToFinish()

            let bothReady = await waitForLibraryCondition {
                await MainActor.run {
                    panel.packCards.first?.name == "共享包"
                        && window.packCards.first?.name == "共享包"
                        && panel.libraryPresentationState == .ready
                        && window.libraryPresentationState == .ready
                }
            }
            expect(bothReady, "两个消费者必须从同一快照各自完成投影")
            expect(scanner.callCount == 1, "双消费者首次 hydration 只能触发一次扫描")
            expect(
                panel.eventRows.first(where: { $0.event == .stop })?.enabled == false,
                "面板必须把最新 config 的静音轴叠到共享磁盘事实")
            expect(window.selectedPackID == "pack-a", "窗口必须从同一快照跟随 active pack")

            let starWrite = window.updateStarredPacks(to: [])
            if case .success = starWrite {
                expect(true, "前提：config-only 星标写必须成功")
            } else {
                expect(false, "前提：config-only 星标写失败，得到 \(starWrite)")
            }
            expect(
                await waitForLibraryCondition {
                    await MainActor.run {
                        panel.config.starredPacks == [] && panel.packCards.isEmpty
                    }
                },
                "星标写必须让面板用原 snapshot 重投影为空显示集")
            await library.waitUntilIdleForTesting()
            expect(
                scanner.callCount == 1,
                "纯 config 写不得触发第二次声音包扫描，实际 \(scanner.callCount) 次")

            expect(panel.setMasterVolume(0.4) == 0.4, "面板 config-only 写必须成功")
            expect(
                await waitForLibraryCondition {
                    await MainActor.run { window.config.masterVolume == 0.4 }
                },
                "保留窗口必须收到 config-only 投影刷新")
            await library.waitUntilIdleForTesting()
            expect(
                scanner.callCount == 1,
                "面板 config-only 写通知窗口时也不得扫描，实际 \(scanner.callCount) 次")
        }
    }

    await suite("SoundPacksWindowModel 导入后绑定：共享清单尚未完成时仍绑定导入结果") {
        await withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDirectory = root.appendingPathComponent("packs", isDirectory: true)
            let packDirectory = packsDirectory.appendingPathComponent("pack-a", isDirectory: true)
            let source = root.appendingPathComponent("incoming.wav")
            writeFixture(#"{"selected_pack":"pack-a","events":{}}"#, to: configFile)
            writeFixture(
                #"{"id":"pack-a","name":"我的包","events":{}}"#,
                to: packDirectory.appendingPathComponent("manifest.json"))
            writeFixture("existing", to: packDirectory.appendingPathComponent("existing.mp3"))
            writeFixture(validWAVData(), to: source)

            let environment = AudioImportEnvironment(
                userPacksDirectory: packsDirectory,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: root.appendingPathComponent("packs.lock"))
            let loader = SequencedBlockingAudioInventoryLoader(
                results: [
                    .available([PackAudioFile(fileName: "existing.mp3", isOrphan: true)]),
                    .available([
                        PackAudioFile(fileName: "existing.mp3", isOrphan: true),
                        PackAudioFile(fileName: "incoming.wav", isOrphan: true),
                    ]),
                ],
                blockingCall: 2)
            let library = SoundPackLibrary(
                scanner: .testingLive(environment: environment) { _ in },
                inventoryOperation: loader.load)
            let model = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                soundPackLibrary: library,
                refreshCoordinator: SoundPacksRefreshCoordinator())

            expect(
                await waitForLibraryCondition {
                    await MainActor.run {
                        model.selectedPackID == "pack-a"
                            && model.selectedAudioFiles.contains {
                                $0.fileName == "existing.mp3"
                            }
                    }
                },
                "前提：共享模型必须先完成 pack-a 的旧 inventory")

            let importedResult = await model.importSelectedAudioFiles(
                [AudioImportRequest(sourceURL: source, suggestedFileName: "incoming.wav")],
                expectedPackID: "pack-a")
            guard
                case .success(let completion) = importedResult,
                let imported = completion.result.accepted.last
            else {
                expect(false, "导入必须成功，得到 " + String(describing: importedResult))
                return
            }
            expect(
                await waitForLibraryCondition { loader.callCount >= 2 },
                "导入完成后的共享 inventory 必须进入受控慢读取，当前调用次数 "
                    + String(loader.callCount))
            expect(loader.waitUntilBlocked(), "第二次 inventory 调用必须停在受控闸门")
            defer { loader.allowBlockedLoadToFinish() }

            let staleBinding = model.assignSelectedAudioFile("incoming.wav", to: .notification)
            guard case .failure(.notInInventory(fileName: "incoming.wav")) = staleBinding else {
                expect(false, "旧 inventory 必须拒绝尚未投影的新文件，得到 "
                    + String(describing: staleBinding))
                return
            }
            let directBinding = model.assignImportedAudioFile(imported, to: .notification)
            guard case .success = directBinding else {
                expect(false, "导入结果必须绕过旧 inventory 成功绑定，得到 (directBinding)")
                return
            }
            expect(
                await waitForLibraryCondition {
                    await MainActor.run {
                        model.selectedEventRows.first(where: { $0.event == .notification })?.coverage
                            == .present(fileName: "incoming.wav")
                    }
                },
                "绑定成功后共享快照必须最终投影新映射")
        }
    }

    await suite("SoundPacksWindowModel fork：刷新期间手动选包会清除延迟副本目标") {
        await withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDirectory = root.appendingPathComponent("packs", isDirectory: true)
            let factoryDirectory = root.appendingPathComponent("factory", isDirectory: true)
            writeFixture(#"{"selected_pack":"builtin","events":{}}"#, to: configFile)
            writeFixture(
                #"{"id":"builtin","name":"内置","events":{"stop":"stop.mp3"}}"#,
                to: factoryDirectory
                    .appendingPathComponent("builtin", isDirectory: true)
                    .appendingPathComponent("manifest.json"))
            writeFixture(
                "factory-audio",
                to: factoryDirectory
                    .appendingPathComponent("builtin", isDirectory: true)
                    .appendingPathComponent("stop.mp3"))
            writeFixture(
                #"{"id":"builtin","name":"内置","events":{}}"#,
                to: packsDirectory
                    .appendingPathComponent("builtin", isDirectory: true)
                    .appendingPathComponent("manifest.json"))

            let builtin = libraryFacts(id: "builtin", name: "内置")
            let other = libraryFacts(id: "other", name: "另一个", coverage: [:], audioInventory: .available([]))
            let forked = libraryFacts(
                id: "builtin-copy", name: "副本", coverage: [:], audioInventory: .available([]))
            let scanner = ForkRefreshBlockingSoundPackScanner(
                initialFacts: [builtin, other],
                refreshedFacts: [builtin, other, forked],
                factoryPackIDs: ["builtin"])
            let environment = AudioImportEnvironment(
                userPacksDirectory: packsDirectory,
                factoryPacksDirectory: factoryDirectory,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: root.appendingPathComponent("packs.lock"))
            let library = SoundPackLibrary(
                scanner: SoundPackLibraryScanner(outputOperation: scanner.scan))
            let model = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                soundPackLibrary: library,
                refreshCoordinator: SoundPacksRefreshCoordinator())

            expect(
                await waitForLibraryCondition {
                    await MainActor.run { model.selectedPackID == "builtin" }
                },
                "前提：共享模型必须先选中内置包")
            let forkResult = model.forkSelectedFactoryPack()
            guard case .success(let outcome) = forkResult else {
                expect(false, "fork 必须成功，得到 " + String(describing: forkResult))
                return
            }
            expect(
                await waitForLibraryCondition { scanner.callCount >= 2 },
                "fork 后的共享库刷新必须停在发布新副本之前，当前调用次数 "
                    + String(scanner.callCount))
            expect(scanner.waitUntilSecondScanEntered(), "第二次 library scan 必须停在受控闸门")
            expect(model.selectPackForInspection("other"), "用户必须能够手动选择另一个包")
            scanner.allowSecondScanToFinish()
            expect(
                await waitForLibraryCondition {
                    await MainActor.run {
                        model.selectedPackID == "other"
                            && model.packCards.contains { $0.id == outcome.newPackID }
                    }
                },
                "刷新完成后必须保留用户选择，不得跳回 fork 副本")
            expect(
                model.selectPackForInspection(outcome.newPackID),
                "刷新完成后用户必须仍能手动选择新副本")
            expect(
                !model.consumeSelectionAnnouncementSuppression(for: outcome.newPackID),
                "手动取消 fork 自动选择后，首次选择新副本必须保留正常 VoiceOver 选中播报")
        }
    }

    await suite("SoundPackLibrary 按需清单：慢读取有独立 loading，不伪装成真实空包") {
        await withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(#"{"selected_pack":"pack-a","events":{}}"#, to: configFile)
            let scanner = ScriptedSoundPackScanner([
                .success([
                    libraryFacts(
                        name: "慢清单包",
                        audioInventory: .deferred)
                ])
            ])
            let loader = BlockingAudioInventoryLoader(
                result: .available([PackAudioFile(fileName: "stop.mp3", isOrphan: false)]))
            let library = SoundPackLibrary(
                scanner: SoundPackLibraryScanner(operation: scanner.scan),
                inventoryOperation: loader.load)
            let environment = AudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true),
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: root.appendingPathComponent("packs.lock"))
            let model = SoundPacksWindowModel(
                configFile: configFile,
                environment: environment,
                soundPackLibrary: library,
                refreshCoordinator: SoundPacksRefreshCoordinator())

            expect(
                await waitForLibraryCondition { loader.callCount == 1 },
                "清单读取必须真正进入受控慢路径")
            guard case .loading(let previous) = model.selectedAudioInventoryState else {
                expect(false, "库 ready 后、清单未完成时窗口必须保持独立 loading")
                loader.allowLoadToFinish()
                return
            }
            expect(previous == nil, "首次清单读取不能伪造旧文件")

            loader.allowLoadToFinish()
            expect(
                await waitForLibraryCondition {
                    await MainActor.run {
                        model.selectedAudioFiles == [
                            PackAudioFile(fileName: "stop.mp3", isOrphan: false)
                        ] && !model.selectedAudioInventoryState.isLoading
                    }
                },
                "读取完成后窗口必须收敛到 ready 清单")
        }
    }

    await suite("SoundPackLibrary 按需清单：瞬时失败不进入会话缓存，成功结果才复用") {
        let scanner = ScriptedSoundPackScanner([
            .success([libraryFacts(name: "可重试清单", audioInventory: .deferred)])
        ])
        let loader = ScriptedAudioInventoryLoader(results: [
            .unavailable(.directoryUnreadable(reason: "瞬时 EMFILE")),
            .available([PackAudioFile(fileName: "recovered.mp3", isOrphan: true)]),
        ])
        let library = SoundPackLibrary(
            scanner: SoundPackLibraryScanner(operation: scanner.scan),
            inventoryOperation: loader.load)
        await library.requestRefresh(trigger: .initial)
        await library.waitUntilIdleForTesting()

        let first = await library.audioInventory(packID: "pack-a")
        guard case .unavailable(let firstError) = first else {
            expect(false, "第一次受控读取必须返回瞬时失败")
            return
        }
        expect(
            firstError == .directoryUnreadable(reason: "瞬时 EMFILE"),
            "第一次失败必须原样返回")
        let second = await library.audioInventory(packID: "pack-a")
        expect(
            second == .available([PackAudioFile(fileName: "recovered.mp3", isOrphan: true)]),
            "相同指纹下第二次读取必须能从瞬时失败恢复")
        let third = await library.audioInventory(packID: "pack-a")
        expect(third == second, "成功清单应进入有界 LRU")
        expect(loader.callCount == 2, "失败不缓存、成功缓存，底层应精确调用两次")
    }

    await suite("SoundPackLibrary factory IDs：生产快照把内置只读事实送达两个消费者") {
        await withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(
                #"{"selected_pack":"factory-a","events":{},"starred_packs":["factory-a"]}"#,
                to: configFile)
            let facts = libraryFacts(id: "factory-a", name: "内置包")
            let scanner = SoundPackLibraryScanner(outputOperation: { _ in
                .success(
                    SoundPackLibraryScanOutput(
                        facts: [facts], factoryPackIDs: ["factory-a"]))
            })
            let library = SoundPackLibrary(scanner: scanner)
            let environment = AudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true),
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: root.appendingPathComponent("packs.lock"))
            let coordinator = SoundPacksRefreshCoordinator()
            let panel = PanelConfigController(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                soundPackLibrary: library,
                soundPacksRefreshCoordinator: coordinator)
            let window = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                soundPackLibrary: library,
                refreshCoordinator: coordinator)

            expect(
                await waitForLibraryCondition {
                    await MainActor.run {
                        panel.selectedPackIsBuiltinReadOnly
                            && window.selectedPackIsBuiltinReadOnly
                            && window.factoryPackIDs == ["factory-a"]
                            && window.hasFactoryPacks
                    }
                },
                "factoryPackIDs 必须穿过生产 snapshot 并驱动两个只读投影")
            let edit = window.clearSelectedEventBinding(.stop)
            guard case .failure(.builtinReadOnly(let packID)) = edit else {
                expect(false, "内置包编辑必须 fail closed，得到 \(edit)")
                return
            }
            expect(packID == "factory-a", "只读拒绝必须保留准确 pack id")
        }
    }

    await suite("SoundPackLibrary 五态：首次失败、重试与双消费者恢复") {
        await withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(
                #"{"selected_pack":"pack-a","events":{},"starred_packs":["pack-a"]}"#,
                to: configFile)
            let scanner = ScriptedSoundPackScanner([
                .failure(.scanFailed(reason: "首次没有权限")),
                .success([libraryFacts(name: "重试恢复")]),
            ])
            let library = SoundPackLibrary(
                scanner: SoundPackLibraryScanner(operation: scanner.scan))
            let environment = AudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true),
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: root.appendingPathComponent("packs.lock"))
            let coordinator = SoundPacksRefreshCoordinator()
            let panel = PanelConfigController(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                soundPackLibrary: library,
                soundPacksRefreshCoordinator: coordinator)
            let window = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                soundPackLibrary: library,
                refreshCoordinator: coordinator)

            expect(
                await waitForLibraryCondition {
                    await MainActor.run {
                        panel.libraryPresentationState
                            == .loadFailed(reason: "首次没有权限")
                            && window.libraryPresentationState
                                == .loadFailed(reason: "首次没有权限")
                            && panel.eventRows.isEmpty
                            && window.selectedEventRows.isEmpty
                    }
                },
                "无 previous 的失败必须映射为 hard failure，且不伪造事件事实")
            panel.retrySoundPackLibraryRefresh()
            expect(
                await waitForLibraryCondition {
                    await MainActor.run {
                        panel.libraryPresentationState == .ready
                            && window.libraryPresentationState == .ready
                            && panel.packCards.first?.name == "重试恢复"
                            && window.packCards.first?.name == "重试恢复"
                    }
                },
                "任一消费者触发重试后，两侧必须从同一 ready 快照恢复")
        }
    }

    await suite("SoundPackLibrary 五态：后台刷新保留旧快照，失败后可再次重试") {
        await withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(
                #"{"selected_pack":"pack-a","events":{},"starred_packs":["pack-a"]}"#,
                to: configFile)
            let scanner = SecondScanBlockingSoundPackScanner(
                readyFacts: [libraryFacts(name: "可继续显示")],
                recoveredFacts: [libraryFacts(name: "恢复后的结果")])
            let library = SoundPackLibrary(
                scanner: SoundPackLibraryScanner(operation: scanner.scan))
            let environment = AudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true),
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: root.appendingPathComponent("packs.lock"))
            let coordinator = SoundPacksRefreshCoordinator()
            let panel = PanelConfigController(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                soundPackLibrary: library,
                soundPacksRefreshCoordinator: coordinator)
            let window = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                soundPackLibrary: library,
                refreshCoordinator: coordinator)
            expect(
                await waitForLibraryCondition {
                    await MainActor.run {
                        panel.packCards.first?.name == "可继续显示"
                            && window.packCards.first?.name == "可继续显示"
                    }
                },
                "前提：第一次 ready 必须到达两个消费者")

            await library.requestRefresh(trigger: .applicationActivation)
            expect(scanner.waitUntilSecondScanEntered(), "第二次刷新必须进入受控失败点")
            expect(
                await waitForLibraryCondition {
                    await MainActor.run {
                        panel.libraryPresentationState == .refreshing
                            && window.libraryPresentationState == .refreshing
                            && panel.packCards.first?.name == "可继续显示"
                            && window.packCards.first?.name == "可继续显示"
                    }
                },
                "loading(previous) 必须映射为 refreshing 并继续显示旧快照")
            scanner.allowSecondScanToFinish()
            expect(
                await waitForLibraryCondition {
                    await MainActor.run {
                        panel.libraryPresentationState
                            == .refreshFailed(reason: "模拟刷新失败")
                            && window.libraryPresentationState
                                == .refreshFailed(reason: "模拟刷新失败")
                            && panel.packCards.first?.name == "可继续显示"
                            && window.packCards.first?.name == "可继续显示"
                    }
                },
                "failed(previous) 必须保留 stale 数据并明确区分 refresh failure")
            window.retrySoundPackLibraryRefresh()
            expect(
                await waitForLibraryCondition {
                    await MainActor.run {
                        panel.libraryPresentationState == .ready
                            && window.libraryPresentationState == .ready
                            && panel.packCards.first?.name == "恢复后的结果"
                            && window.packCards.first?.name == "恢复后的结果"
                    }
                },
                "刷新失败后的窗口重试必须让两个消费者共同恢复")
        }
    }

    await suite("SoundPackLibrary 写后失效：同步 manifest 写保持原语不变，两侧异步收敛到新事实") {
        await withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDirectory = root.appendingPathComponent("packs", isDirectory: true)
            let packDirectory = packsDirectory.appendingPathComponent("pack-a", isDirectory: true)
            writeFixture(
                #"{"selected_pack":"pack-a","events":{},"starred_packs":["pack-a"]}"#,
                to: configFile)
            writeFixture(
                #"{"id":"pack-a","name":"可编辑包","events":{"stop":"stop.mp3"}}"#,
                to: packDirectory.appendingPathComponent("manifest.json"))
            writeFixture("audio", to: packDirectory.appendingPathComponent("stop.mp3"))
            let environment = AudioImportEnvironment(
                userPacksDirectory: packsDirectory,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: root.appendingPathComponent("packs.lock"))
            let library = SoundPackLibrary(environment: environment)
            let coordinator = SoundPacksRefreshCoordinator()
            let panel = PanelConfigController(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                soundPackLibrary: library,
                soundPacksRefreshCoordinator: coordinator)
            let window = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                soundPackLibrary: library,
                refreshCoordinator: coordinator)

            expect(
                await waitForLibraryCondition {
                    await MainActor.run {
                        window.selectedEventRows.first(where: { $0.event == .stop })?.coverage
                            == .present(fileName: "stop.mp3")
                            && panel.eventRows.first(where: { $0.event == .stop })?.coverage
                                == .present(fileName: "stop.mp3")
                    }
                },
                "前提：两侧必须先看到 stop 映射")

            let write = window.clearSelectedEventBinding(.stop)
            if case .success = write {
                expect(true, "既有同步写原语照常成功")
            } else {
                expect(false, "既有同步写原语必须照常成功，得到 \(write)")
            }

            let converged = await waitForLibraryCondition {
                await MainActor.run {
                    window.selectedEventRows.first(where: { $0.event == .stop })?.coverage
                        == .unmapped
                        && panel.eventRows.first(where: { $0.event == .stop })?.coverage
                            == .unmapped
                        && window.libraryPresentationState == .ready
                        && panel.libraryPresentationState == .ready
                }
            }
            expect(converged, "写成功后的 revision 失效必须让两个消费者收敛到 unmapped")
        }
    }

    await suite("SoundPackLibrary 生产写链：assign/delete/import/clear 精确失效并让双消费者收敛") {
        await withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDirectory = root.appendingPathComponent("packs", isDirectory: true)
            let packDirectory = packsDirectory.appendingPathComponent("pack-a", isDirectory: true)
            writeFixture(
                #"{"selected_pack":"pack-a","events":{},"starred_packs":["pack-a"]}"#,
                to: configFile)
            writeFixture(
                #"{"id":"pack-a","name":"生产写包","events":{"stop":"stop.mp3"}}"#,
                to: packDirectory.appendingPathComponent("manifest.json"))
            writeFixture("audio", to: packDirectory.appendingPathComponent("stop.mp3"))
            writeFixture("audio", to: packDirectory.appendingPathComponent("unused.mp3"))
            writeFixture("audio", to: packDirectory.appendingPathComponent("spare.mp3"))
            let environment = AudioImportEnvironment(
                userPacksDirectory: packsDirectory,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: root.appendingPathComponent("packs.lock"))
            let scanner = RecordingDiskSoundPackScanner(environment: environment)
            let library = SoundPackLibrary(
                scanner: SoundPackLibraryScanner(outputOperation: scanner.scan))
            let coordinator = SoundPacksRefreshCoordinator()
            let panel = PanelConfigController(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                soundPackLibrary: library,
                soundPacksRefreshCoordinator: coordinator)
            let window = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                soundPackLibrary: library,
                refreshCoordinator: coordinator)
            expect(
                await waitForLibraryCondition {
                    await MainActor.run {
                        window.selectedAudioFiles.contains { $0.fileName == "unused.mp3" }
                            && panel.eventRows.first(where: { $0.event == .stop })?.coverage
                                == .present(fileName: "stop.mp3")
                    }
                },
                "前提：生产模型必须先完成共享 hydration 与 selected inventory 投影")
            expect(scanner.callCount == 1, "双消费者初始只允许一次扫描")

            var previousCallCount = scanner.callCount
            let assign = window.assignSelectedAudioFile("unused.mp3", to: .notification)
            if case .success = assign {
                expect(true, "assign 前提必须成功")
            } else {
                expect(false, "assign 失败：\(assign)")
            }
            expect(
                await waitForLibraryCondition {
                    await MainActor.run {
                        scanner.callCount == previousCallCount + 1
                            && window.selectedEventRows.first(where: {
                                $0.event == .notification
                            })?.coverage == .present(fileName: "unused.mp3")
                            && panel.eventRows.first(where: { $0.event == .notification })?.coverage
                                == .present(fileName: "unused.mp3")
                    }
                },
                "assign 成功必须扫描一次并让双消费者看到新映射")
            expect(
                scanner.requests.last?.invalidatedPackIDs == ["pack-a"],
                "assign 必须只失效目标 pack-a")

            previousCallCount = scanner.callCount
            let delete = window.deleteSelectedOrphanAudioFileAfterConfirmation(
                "spare.mp3", expectedPackID: "pack-a")
            if case .success = delete {
                expect(true, "delete 前提必须成功")
            } else {
                expect(false, "delete 失败：\(delete)")
            }
            expect(
                await waitForLibraryCondition {
                    await MainActor.run {
                        scanner.callCount == previousCallCount + 1
                            && !window.selectedAudioFiles.contains { $0.fileName == "spare.mp3" }
                    }
                },
                "delete 成功必须扫描一次并刷新 inventory")
            expect(
                scanner.requests.last?.invalidatedPackIDs == ["pack-a"],
                "delete 必须只失效目标 pack-a")

            let importSource = root.appendingPathComponent("incoming.wav")
            writeFixture(validWAVData(), to: importSource)
            previousCallCount = scanner.callCount
            let imported = await window.importSelectedAudioFiles(
                [AudioImportRequest(sourceURL: importSource, suggestedFileName: "incoming.wav")],
                expectedPackID: "pack-a")
            guard case .success(let completion) = imported else {
                expect(false, "import 前提必须成功：\(imported)")
                return
            }
            expect(completion.result.accepted.count == 1, "import 必须真正接受一个文件")
            expect(
                await waitForLibraryCondition {
                    await MainActor.run {
                        scanner.callCount == previousCallCount + 1
                            && window.selectedAudioFiles.contains { $0.fileName == "incoming.wav" }
                    }
                },
                "import 成功必须扫描一次并刷新 selected inventory")
            expect(
                scanner.requests.last?.invalidatedPackIDs == ["pack-a"],
                "import 必须只失效目标 pack-a")

            previousCallCount = scanner.callCount
            let clear = window.clearSelectedEventBinding(.notification)
            if case .success = clear {
                expect(true, "clear 前提必须成功")
            } else {
                expect(false, "clear 失败：\(clear)")
            }
            expect(
                await waitForLibraryCondition {
                    await MainActor.run {
                        scanner.callCount == previousCallCount + 1
                            && window.selectedEventRows.first(where: {
                                $0.event == .notification
                            })?.coverage == .unmapped
                            && panel.eventRows.first(where: { $0.event == .notification })?.coverage
                                == .unmapped
                    }
                },
                "clear 成功必须扫描一次并让双消费者收敛")
            expect(
                scanner.requests.last?.invalidatedPackIDs == ["pack-a"],
                "clear 必须只失效目标 pack-a")

            previousCallCount = scanner.callCount
            let rejected = window.assignSelectedAudioFile("missing.mp3", to: .taskStart)
            guard case .failure(.notInInventory(fileName: "missing.mp3")) = rejected else {
                expect(false, "无效 inventory 项必须在写前拒绝：\(rejected)")
                return
            }
            await library.waitUntilIdleForTesting()
            expect(
                scanner.callCount == previousCallCount,
                "写前即可证明无磁盘变化的失败不得发布假失效或扫描")
        }
    }

    await suite("SoundPackLibrary 生产写链：restore retry、fork 与 batch restore 精确失效") {
        await withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            let factoryPacks = root.appendingPathComponent("factory", isDirectory: true)
            @MainActor func writePack(at root: URL, id: String, name: String) {
                let directory = root.appendingPathComponent(id, isDirectory: true)
                writeFixture(
                    #"{"id":"\#(id)","name":"\#(name)","license":"CC0-1.0","events":{"stop":"stop.mp3"}}"#,
                    to: directory.appendingPathComponent("manifest.json"))
                writeFixture("audio-\(name)", to: directory.appendingPathComponent("stop.mp3"))
            }
            writePack(at: factoryPacks, id: "factory-a", name: "出厂 A")
            writePack(at: factoryPacks, id: "factory-b", name: "出厂 B")
            writePack(at: userPacks, id: "factory-a", name: "用户改过的 A")
            writeFixture(
                #"{"selected_pack":"factory-a","events":{},"starred_packs":["factory-a","factory-b"]}"#,
                to: configFile)
            let publishFailure = FailFirstFactoryPublish()
            let environment = AudioImportEnvironment(
                userPacksDirectory: userPacks,
                factoryPacksDirectory: factoryPacks,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: root.appendingPathComponent("packs.lock"),
                beforeFactoryPackRestorePublish: publishFailure.call)
            let scanner = RecordingDiskSoundPackScanner(
                environment: environment,
                factoryPackIDs: ["factory-a", "factory-b"])
            let library = SoundPackLibrary(
                scanner: SoundPackLibraryScanner(outputOperation: scanner.scan))
            let coordinator = SoundPacksRefreshCoordinator()
            let panel = PanelConfigController(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                soundPackLibrary: library,
                soundPacksRefreshCoordinator: coordinator)
            let window = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                soundPackLibrary: library,
                refreshCoordinator: coordinator)
            expect(
                await waitForLibraryCondition {
                    await MainActor.run {
                        window.selectedPackID == "factory-a"
                            && window.selectedPackIsBuiltinReadOnly
                            && panel.selectedPackIsBuiltinReadOnly
                    }
                },
                "前提：factory-a 必须通过生产快照成为只读选中包")

            var previousCallCount = scanner.callCount
            let failedRestore = window.restoreSelectedFactoryPackAfterConfirmation(
                expectedPackID: "factory-a")
            guard
                case .failure(.restore(let failedID, .publishFailed, _)) = failedRestore
            else {
                expect(false, "首个 restore 必须命中注入的 publish failure：\(failedRestore)")
                return
            }
            expect(failedID == "factory-a", "restore failure 必须保留目标 id")
            expect(
                await waitForLibraryCondition {
                    await MainActor.run {
                        scanner.callCount == previousCallCount + 1
                            && window.factoryRestoreRetryPackID == "factory-a"
                    }
                },
                "salvage 后 publish 失败仍改变磁盘，必须刷新并暴露 retry")
            await library.waitUntilIdleForTesting()
            expect(
                scanner.requests.last?.invalidatedPackIDs == ["factory-a"],
                "失败但已 salvage 的 restore 必须失效 factory-a")

            previousCallCount = scanner.callCount
            let retried = window.retryFailedFactoryPackRestoreAfterConfirmation(
                expectedPackID: "factory-a")
            guard case .success(let retryOutcome) = retried else {
                expect(false, "第二次 restore retry 必须成功：\(retried)")
                return
            }
            expect(
                retryOutcome.restoredPackID == "factory-a"
                    && !retryOutcome.retainedSalvages.isEmpty,
                "retry 成功仍必须保留第一次 salvage 的可告知路径")
            expect(
                await waitForLibraryCondition {
                    await MainActor.run {
                        scanner.callCount == previousCallCount + 1
                            && window.packCards.contains { $0.id == "factory-a" }
                            && window.factoryRestoreRetryPackID == nil
                    }
                },
                "retry 成功必须扫描一次、恢复包并清除 retry")
            await library.waitUntilIdleForTesting()
            expect(
                scanner.requests.last?.invalidatedPackIDs == ["factory-a"],
                "restore retry 必须精确失效 factory-a")

            expect(window.selectPackForInspection("factory-a"), "恢复后的内置包必须可重新选择")
            previousCallCount = scanner.callCount
            let fork = window.forkSelectedFactoryPack()
            guard case .success(let forkOutcome) = fork else {
                expect(false, "fork 必须成功：\(fork)")
                return
            }
            let forkPublished = await waitForLibraryCondition {
                await MainActor.run {
                    scanner.callCount >= previousCallCount + 1
                        && window.packCards.contains { $0.id == forkOutcome.newPackID }
                        && window.selectedPackID == forkOutcome.newPackID
                }
            }
            await library.waitUntilIdleForTesting()
            expect(
                forkPublished,
                "fork 成功必须扫描一次并选择新副本；calls=\(scanner.callCount)/\(previousCallCount) cards=\(window.packCards.map(\.id)) selected=\(String(describing: window.selectedPackID)) requests=\(scanner.requests.map { Array($0.invalidatedPackIDs).sorted() })")
            expect(
                scanner.requests.last?.invalidatedPackIDs == [forkOutcome.newPackID],
                "fork 必须只失效新发布的 pack id；requests=\(scanner.requests.map { Array($0.invalidatedPackIDs).sorted() })")

            previousCallCount = scanner.callCount
            let batch = window.restoreAllFactoryPacksAfterConfirmation()
            expect(
                batch.failures.isEmpty
                    && Set(batch.restoredPacks.map(\.restoredPackID))
                        == Set(["factory-a", "factory-b"]),
                "batch 必须处理全部 factory IDs")
            expect(
                await waitForLibraryCondition {
                    await MainActor.run {
                        scanner.callCount == previousCallCount + 1
                            && window.packCards.contains { $0.id == "factory-a" }
                            && window.packCards.contains { $0.id == "factory-b" }
                    }
                },
                "batch restore 必须只发布一次刷新并让两个内置包可见")
            expect(
                scanner.requests.last?.invalidatedPackIDs == ["factory-a", "factory-b"],
                "batch restore 必须在一个请求中保留完整 factory ID 集")
        }
    }

    await suite("PanelConfigController：config-only 发现外部切到新包时升级后台库刷新") {
        await withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(
                #"{"selected_pack":"pack-a","events":{},"starred_packs":["pack-a"]}"#,
                to: configFile)
            let scanner = BlockingSoundPackScanner(
                firstFacts: [libraryFacts(name: "旧包")],
                laterFacts: [libraryFacts(id: "pack-b", name: "外部新增包")])
            let library = SoundPackLibrary(
                scanner: SoundPackLibraryScanner(operation: scanner.scan))
            let environment = AudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true),
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: root.appendingPathComponent("packs.lock"))
            let panel = PanelConfigController(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                soundPackLibrary: library)

            expect(
                await waitForLibraryCondition { scanner.callCount == 1 },
                "前提：首次共享扫描必须开始")
            scanner.allowFirstScanToFinish()
            expect(
                await waitForLibraryCondition {
                    await MainActor.run { panel.packCards.first?.name == "旧包" }
                },
                "前提：面板必须先投影旧包")

            writeFixture(
                #"{"selected_pack":"pack-b","events":{},"starred_packs":["pack-b"]}"#,
                to: configFile)
            panel.reloadConfigOnly()

            expect(
                await waitForLibraryCondition {
                    await MainActor.run {
                        scanner.callCount == 2
                            && panel.config.selectedPack == "pack-b"
                            && panel.packCards.first?.id == "pack-b"
                    }
                },
                "selected_pack 跳到旧快照外时必须升级刷新并收敛到新包")
        }
    }

    await suite("PanelConfigController：切到已有快照内的包只重投影，不重复扫描") {
        await withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDirectory = root.appendingPathComponent("packs", isDirectory: true)
            for id in ["pack-a", "pack-b"] {
                writeFixture(
                    #"{"id":"\#(id)","name":"\#(id)","events":{"stop":"stop.mp3"}}"#,
                    to:
                        packsDirectory
                        .appendingPathComponent(id, isDirectory: true)
                        .appendingPathComponent("manifest.json"))
                writeFixture(
                    "audio",
                    to:
                        packsDirectory
                        .appendingPathComponent(id, isDirectory: true)
                        .appendingPathComponent("stop.mp3"))
            }
            writeFixture(
                #"{"selected_pack":"pack-a","events":{},"starred_packs":["pack-a","pack-b"]}"#,
                to: configFile)
            let scanner = BlockingSoundPackScanner(
                firstFacts: [
                    libraryFacts(id: "pack-a", name: "A"),
                    libraryFacts(id: "pack-b", name: "B"),
                ])
            let library = SoundPackLibrary(
                scanner: SoundPackLibraryScanner(operation: scanner.scan))
            let coordinator = SoundPacksRefreshCoordinator()
            let environment = AudioImportEnvironment(
                userPacksDirectory: packsDirectory,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: root.appendingPathComponent("packs.lock"))
            let panel = PanelConfigController(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                soundPackLibrary: library,
                soundPacksRefreshCoordinator: coordinator)
            let window = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                soundPackLibrary: library,
                refreshCoordinator: coordinator)

            expect(
                await waitForLibraryCondition { scanner.callCount == 1 },
                "前提：首次共享扫描必须开始")
            scanner.allowFirstScanToFinish()
            expect(
                await waitForLibraryCondition {
                    await MainActor.run { panel.packCards.count == 2 }
                },
                "前提：快照必须同时包含两个包")

            let outcome = panel.switchPack(to: "pack-b")
            expect(outcome == .succeeded, "切包写必须成功")
            coordinator.completePanelPackSwitch(outcome)
            expect(panel.config.selectedPack == "pack-b", "切包后必须立即用旧快照重投影")
            expect(
                await waitForLibraryCondition {
                    await MainActor.run { window.selectedPackID == "pack-b" }
                },
                "已打开窗口必须用同一旧快照跟随 active pack")
            expect(window.selectPackForInspection("pack-a"), "用户必须能手动改看 pack-a")
            coordinator.completePanelConfigChange(.changed)
            expect(
                await waitForLibraryCondition {
                    await MainActor.run { window.selectedPackID == "pack-a" }
                },
                "一次性跟随意图消费后，config-only 刷新不得把手动选择拉回 active pack")
            writeFixture(
                #"{"selected_pack":"pack-a","events":{},"starred_packs":["pack-a","pack-b"]}"#,
                to: configFile)
            panel.reloadConfigOnly()
            expect(panel.config.selectedPack == "pack-a", "外部切回已有包也必须立即重投影")

            await library.waitUntilIdleForTesting()
            expect(
                scanner.callCount == 1,
                "selected_pack 只属于 config；目标已在快照内时不得扫描，实际 \(scanner.callCount) 次")
        }
    }

    await suite("SoundPackLibrary：在途观察请求合并为一次 follow-up，新订阅者重放最终值") {
        let scanner = BlockingSoundPackScanner(
            firstFacts: [libraryFacts(name: "观察前旧结果")],
            laterFacts: [libraryFacts(name: "观察后新结果")])
        let library = SoundPackLibrary(
            scanner: SoundPackLibraryScanner(operation: scanner.scan))
        let recorder = SoundPackLibraryStateRecorder()
        let observation = recordLibraryStates(from: library, into: recorder)
        defer { observation.cancel() }

        await library.requestRefresh(trigger: .initial)
        expect(scanner.waitUntilFirstScanEntered(), "第一次扫描必须真正开始")
        for _ in 0..<12 {
            await library.requestRefresh(trigger: .panelPresentation)
        }
        scanner.allowFirstScanToFinish()

        let becameReady = await waitForLibraryCondition {
            await recorder.containsReadyPack(named: "观察后新结果")
        }
        expect(becameReady, "扫描期间到达的观察请求必须由 follow-up 读到最终事实")
        expect(scanner.callCount == 2, "多次在途观察必须合并成一次 follow-up")
        expect(
            !(await recorder.containsReadyPack(
                named: "观察前旧结果", before: "观察后新结果")),
            "收到较晚观察请求后，已过时的在途结果不得短暂发布")

        let replayStream = await library.states()
        var replayIterator = replayStream.makeAsyncIterator()
        let replayed = await replayIterator.next()
        guard case .ready(let replayedSnapshot)? = replayed else {
            expect(false, "新订阅者必须立即收到当前 ready 状态，得到 \(String(describing: replayed))")
            return
        }
        expect(replayedSnapshot.facts.first?.name == "观察后新结果", "重放必须携带最终快照")
    }

    await suite("SoundPackLibrary：显式新鲜度请求等待下一次终态而不是重放旧快照") {
        let scanner = ScriptedSoundPackScanner([
            .success([libraryFacts(name: "采用前旧事实")]),
            .success([libraryFacts(name: "采用前新事实")]),
        ])
        let library = SoundPackLibrary(
            scanner: SoundPackLibraryScanner(operation: scanner.scan))
        let recorder = SoundPackLibraryStateRecorder()
        let observation = recordLibraryStates(from: library, into: recorder)
        defer { observation.cancel() }

        await library.requestRefresh(trigger: .initial)
        expect(
            await waitForLibraryCondition {
                await recorder.containsReadyPack(named: "采用前旧事实")
            },
            "前提：首次快照必须已经发布")

        let refreshed = await library.refreshSnapshot(trigger: .windowPresentation)
        guard case .ready(let snapshot) = refreshed else {
            expect(false, "显式新鲜度请求必须返回 terminal ready，实得 \(refreshed)")
            return
        }
        expect(snapshot.facts.first?.name == "采用前新事实", "等待结果必须来自本次新扫描")
        expect(scanner.requests.count == 2, "一次显式新鲜度请求必须恰好追加一次扫描")
    }

    await suite("SoundPackLibrary：显式新鲜度等待者加入在途刷新并只接收合并后的终态") {
        let scanner = BlockingSoundPackScanner(
            firstFacts: [libraryFacts(name: "等待者加入前旧事实")],
            laterFacts: [libraryFacts(name: "等待者请求后的新事实")])
        let library = SoundPackLibrary(
            scanner: SoundPackLibraryScanner(operation: scanner.scan))
        let recorder = SoundPackLibraryStateRecorder()
        let observation = recordLibraryStates(from: library, into: recorder)
        defer { observation.cancel() }

        await library.requestRefresh(trigger: .initial)
        expect(scanner.waitUntilFirstScanEntered(), "前提：第一次扫描必须保持在途")
        let awaitedRefresh = Task {
            await library.refreshSnapshot(trigger: .windowPresentation)
        }
        await library.waitUntilRefreshWaiterIsRegisteredForTesting()
        scanner.allowFirstScanToFinish()

        let refreshed = await awaitedRefresh.value
        guard case .ready(let snapshot) = refreshed else {
            expect(false, "在途等待者必须收到 coalesced terminal ready，实得 \(refreshed)")
            return
        }
        expect(snapshot.facts.first?.name == "等待者请求后的新事实", "等待者不得收到加入前的旧终态")
        expect(scanner.callCount == 2, "在途等待者与其他观察请求必须只合并成一次 follow-up")
        expect(
            !(await recorder.containsReadyPack(
                named: "等待者加入前旧事实", before: "等待者请求后的新事实")),
            "代表请求之前的在途结果不得短暂发布或提前恢复等待者")
    }

    await suite("SoundPacksWindowModel：延迟返回的旧刷新 waiter 不得覆盖更高 revision") {
        await withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(
                #"{"selected_pack":"workbuddy-pack","events":{}}"#,
                to: configFile)
            let scanner = ScriptedSoundPackScanner([
                .success([libraryFacts(id: "workbuddy-pack", name: "旧 revision")]),
                .success([libraryFacts(id: "workbuddy-pack", name: "新 revision")]),
            ])
            let library = SoundPackLibrary(
                scanner: SoundPackLibraryScanner(operation: scanner.scan))
            let environment = AudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true),
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: root.appendingPathComponent("packs.lock"))
            let model = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                soundPackLibrary: library,
                refreshCoordinator: SoundPacksRefreshCoordinator())

            expect(
                await waitForLibraryCondition {
                    await MainActor.run { model.packCards.first?.name == "旧 revision" }
                },
                "前提：模型必须先消费初始 revision")
            let replayStream = await library.states()
            var replayIterator = replayStream.makeAsyncIterator()
            guard case .ready(let oldSnapshot)? = await replayIterator.next() else {
                expect(false, "必须能捕获初始 ready snapshot")
                return
            }

            guard
                case .ready(let newSnapshot) =
                    await library.refreshSnapshot(trigger: .windowPresentation)
            else {
                expect(false, "第二次扫描必须发布更高 ready revision")
                return
            }
            expect(newSnapshot.revision > oldSnapshot.revision, "fixture 必须建立严格 revision 顺序")
            expect(
                await waitForLibraryCondition {
                    await MainActor.run {
                        model.libraryPresentationState == .ready
                            && model.packCards.first?.name == "新 revision"
                    }
                },
                "前提：观察流必须先把更高 revision 应用到模型")

            expect(
                model.applyAICueAdoptionSnapshotForTesting(oldSnapshot),
                "旧 waiter 返回时仍可继续使用模型已持有的更新 ready snapshot")
            expect(model.packCards.first?.name == "新 revision", "旧 waiter 结果不得把模型降级")

            model.consumeSoundPackLibraryStateForTesting(.loading(previous: oldSnapshot))
            expect(
                model.libraryPresentationState == .ready
                    && model.packCards.first?.name == "新 revision",
                "延迟的旧 loading observation 不得覆盖 waiter 已应用的更高 revision")
            model.consumeSoundPackLibraryStateForTesting(
                .failed(
                    previous: oldSnapshot,
                    error: .scanFailed(reason: "延迟旧失败")))
            expect(
                model.libraryPresentationState == .ready
                    && model.packCards.first?.name == "新 revision",
                "延迟的旧 failed observation 不得覆盖 waiter 已应用的更高 revision")
        }
    }

    await suite("SoundPackLibrary：写入失效使在途旧结果不可发布，并且最多追加一次扫描") {
        let scanner = BlockingSoundPackScanner(
            firstFacts: [libraryFacts(name: "旧结果")],
            laterFacts: [libraryFacts(name: "新结果")])
        let library = SoundPackLibrary(
            scanner: SoundPackLibraryScanner(operation: scanner.scan))
        let recorder = SoundPackLibraryStateRecorder()
        let observation = recordLibraryStates(from: library, into: recorder)
        defer { observation.cancel() }

        await library.requestRefresh(trigger: .initial)
        expect(scanner.waitUntilFirstScanEntered(), "前提：旧扫描必须在途")
        library.invalidate(packIDs: ["pack-a"])
        library.invalidate(packIDs: ["pack-a"])
        scanner.allowFirstScanToFinish()

        let becameReady = await waitForLibraryCondition {
            await recorder.containsReadyPack(named: "新结果")
        }
        expect(becameReady, "失效后必须追加覆盖最新 revision 的扫描")
        expect(scanner.callCount == 2, "多次在途失效必须合并成一次 follow-up，实际 \(scanner.callCount) 次")
        expect(
            !(await recorder.containsReadyPack(named: "旧结果", before: "新结果")),
            "失效前启动的旧结果绝不能短暂发布并覆盖写后事实")
    }

    await suite("SoundPackLibrary：通过早期 revision 检查后再失效，旧 ready 仍不得发布") {
        let scanner = BlockingSoundPackScanner(
            firstFacts: [libraryFacts(name: "临界窗口旧结果")],
            laterFacts: [libraryFacts(name: "临界窗口新结果")])
        scanner.allowFirstScanToFinish()
        let barrier = FirstPublicationBarrier()
        let library = SoundPackLibrary(
            scanner: SoundPackLibraryScanner(operation: scanner.scan),
            beforeReadyPublication: barrier.pauseFirstPublication)
        let recorder = SoundPackLibraryStateRecorder()
        let observation = recordLibraryStates(from: library, into: recorder)
        defer { observation.cancel() }

        await library.requestRefresh(trigger: .initial)
        expect(barrier.waitUntilPaused(), "测试必须精确停在早期检查之后、锁内发布之前")
        library.invalidate(packIDs: ["pack-a"])
        barrier.allowPublication()

        expect(
            await waitForLibraryCondition {
                await recorder.containsReadyPack(named: "临界窗口新结果")
            },
            "临界窗口失效必须追加最新扫描")
        expect(scanner.callCount == 2, "临界窗口也只能追加一次 follow-up")
        expect(
            !(await recorder.containsReadyPack(
                named: "临界窗口旧结果", before: "临界窗口新结果")),
            "mailbox 锁内二次检查必须阻止旧 ready 短暂发布")
    }

    await suite("SoundPackLibrary：通过早期 revision 检查后再失效，旧 failed 仍不得发布") {
        let scanner = ScriptedSoundPackScanner([
            .failure(.scanFailed(reason: "临界窗口旧失败")),
            .success([libraryFacts(name: "失败临界窗口新结果")]),
        ])
        let barrier = FirstPublicationBarrier()
        let library = SoundPackLibrary(
            scanner: SoundPackLibraryScanner(operation: scanner.scan),
            beforeFailurePublication: barrier.pauseFirstPublication)
        let recorder = SoundPackLibraryStateRecorder()
        let observation = recordLibraryStates(from: library, into: recorder)
        defer { observation.cancel() }

        await library.requestRefresh(trigger: .initial)
        expect(barrier.waitUntilPaused(), "测试必须精确停在失败的早期检查之后、锁内发布之前")
        library.invalidate(packIDs: ["pack-a"])
        barrier.allowPublication()

        expect(
            await waitForLibraryCondition {
                await recorder.containsReadyPack(named: "失败临界窗口新结果")
            },
            "临界窗口失效必须跳过旧失败并追加最新扫描")
        expect(scanner.requests.count == 2, "失败临界窗口也只能追加一次 follow-up")
        expect(
            !(await recorder.containsFailure(reason: "临界窗口旧失败")),
            "mailbox 锁内二次检查必须阻止失效后的旧 failed 短暂发布")
    }

    await suite("SoundPackLibrary：空 packIDs 表示全量失效，不得退化成未失效增量扫描") {
        let scanner = ScriptedSoundPackScanner([
            .success([libraryFacts(name: "初始")]),
            .success([libraryFacts(name: "全量刷新")]),
        ])
        let library = SoundPackLibrary(
            scanner: SoundPackLibraryScanner(operation: scanner.scan))
        let recorder = SoundPackLibraryStateRecorder()
        let observation = recordLibraryStates(from: library, into: recorder)
        defer { observation.cancel() }

        await library.requestRefresh(trigger: .initial)
        expect(
            await waitForLibraryCondition { await recorder.containsReadyPack(named: "初始") },
            "前提：首次扫描必须成功")
        library.invalidate(packIDs: [])
        await library.requestRefresh(trigger: .bootstrap)
        expect(
            await waitForLibraryCondition { await recorder.containsReadyPack(named: "全量刷新") },
            "全量失效后必须完成下一次扫描")

        let requests = scanner.requests
        expect(requests.count == 2, "应精确执行两次扫描，得到 \(requests.count)")
        if requests.count == 2 {
            expect(!requests[0].invalidatesAll, "首次读取没有需要失效的旧快照")
            expect(requests[1].invalidatesAll, "空 packIDs 必须保留全量失效语义")
            expect(requests[1].invalidatedPackIDs.isEmpty, "全量失效不应伪造定向 pack id")
        }
    }

    await suite("SoundPackLibrary：刷新失败保留上一成功快照，不伪装为空库") {
        let previousFacts = [libraryFacts(name: "可继续显示")]
        let scanner = ScriptedSoundPackScanner([
            .success(previousFacts),
            .failure(.scanFailed(reason: "模拟根目录读取失败")),
        ])
        let library = SoundPackLibrary(
            scanner: SoundPackLibraryScanner(operation: scanner.scan))
        let recorder = SoundPackLibraryStateRecorder()
        let observation = recordLibraryStates(from: library, into: recorder)
        defer { observation.cancel() }

        await library.requestRefresh(trigger: .initial)
        expect(
            await waitForLibraryCondition { await recorder.containsReadyPack(named: "可继续显示") },
            "前提：第一次扫描必须成功")
        await library.requestRefresh(trigger: .retry)
        let failed = await waitForLibraryCondition { await recorder.failedState() != nil }
        expect(failed, "第二次扫描失败必须发布 failed")
        guard case .failed(let previous, let error)? = await recorder.failedState() else {
            expect(false, "失败状态必须携带旧快照与错误")
            return
        }
        expect(previous?.facts == previousFacts, "刷新失败必须保留上一成功快照")
        expect(error.message.contains("模拟根目录读取失败"), "失败原因必须如实保留")
    }

    await suite("SoundPackLibrary 失败边界：坏包降级为 broken，坏根目录才让整库失败") {
        await withTempDirectory { root in
            let packsDirectory = root.appendingPathComponent("packs", isDirectory: true)
            writeFixture(
                "not-json",
                to:
                    packsDirectory
                    .appendingPathComponent("broken-pack", isDirectory: true)
                    .appendingPathComponent("manifest.json"))
            let environment = AudioImportEnvironment(
                userPacksDirectory: packsDirectory,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: root.appendingPathComponent("packs.lock"))
            let library = SoundPackLibrary(environment: environment)
            let recorder = SoundPackLibraryStateRecorder()
            let observation = recordLibraryStates(from: library, into: recorder)
            defer { observation.cancel() }

            await library.requestRefresh(trigger: .initial)
            expect(
                await waitForLibraryCondition {
                    await recorder.readySnapshot(containing: "broken-pack") != nil
                },
                "单包损坏不能升级成整库 failed")
            if let snapshot = await recorder.readySnapshot(containing: "broken-pack") {
                guard case .broken = snapshot.fact(for: "broken-pack")?.cardState else {
                    expect(false, "损坏 manifest 必须投影为 broken 卡片")
                    return
                }
                expect(true, "损坏 manifest 已被隔离在单包")
            }
        }

        await withTempDirectory { root in
            let invalidRoot = root.appendingPathComponent("packs")
            writeFixture("not-a-directory", to: invalidRoot)
            let environment = AudioImportEnvironment(
                userPacksDirectory: invalidRoot,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: root.appendingPathComponent("packs.lock"))
            let library = SoundPackLibrary(environment: environment)
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(#"{"selected_pack":"pack-a","events":{}}"#, to: configFile)
            let panel = PanelConfigController(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                soundPackLibrary: library)
            let recorder = SoundPackLibraryStateRecorder()
            let observation = recordLibraryStates(from: library, into: recorder)
            defer { observation.cancel() }

            await library.requestRefresh(trigger: .initial)
            expect(
                await waitForLibraryCondition { await recorder.failedState() != nil },
                "根路径不是目录时必须发布整库 failed")
            guard case .failed(let previous, let error)? = await recorder.failedState() else {
                expect(false, "必须拿到根目录失败状态")
                return
            }
            expect(previous == nil, "首次根目录失败不能伪造一份空 ready snapshot")
            expect(panel.eventRows.isEmpty, "首次读取失败后未知事件映射仍不得伪装成未配置")
            expect(
                error.message.contains("不是文件夹"),
                "根目录失败必须保留可见原因，得到 \(error.message)")
        }
    }

    await suite("SoundPackLibrary 根目录错误：用户根 ENOENT 可为空，配置 factory 根消失保留旧快照") {
        await withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            let factoryPacks = root.appendingPathComponent("factory", isDirectory: true)
            for packsRoot in [userPacks, factoryPacks] {
                writeFixture(
                    #"{"id":"factory-a","events":{"stop":"stop.mp3"}}"#,
                    to:
                        packsRoot
                        .appendingPathComponent("factory-a", isDirectory: true)
                        .appendingPathComponent("manifest.json"))
                writeFixture(
                    "audio",
                    to:
                        packsRoot
                        .appendingPathComponent("factory-a", isDirectory: true)
                        .appendingPathComponent("stop.mp3"))
            }
            let environment = AudioImportEnvironment(
                userPacksDirectory: userPacks,
                factoryPacksDirectory: factoryPacks,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: root.appendingPathComponent("packs.lock"))
            let library = SoundPackLibrary(environment: environment)
            let recorder = SoundPackLibraryStateRecorder()
            let observation = recordLibraryStates(from: library, into: recorder)
            defer { observation.cancel() }

            await library.requestRefresh(trigger: .initial)
            expect(
                await waitForLibraryCondition {
                    await recorder.readySnapshot(containing: "factory-a") != nil
                },
                "前提：可读 factory 根必须先产出一份只读快照")
            try? FileManager.default.removeItem(at: factoryPacks)

            await library.requestRefresh(trigger: .applicationActivation)
            expect(
                await waitForLibraryCondition { await recorder.failedState() != nil },
                "配置过的 factory 根消失必须失败，不能伪装成可选空目录")
            guard case .failed(let previous, let error)? = await recorder.failedState() else {
                expect(false, "异常 factory 根必须发布带旧快照的 failed")
                return
            }
            expect(
                previous?.factoryPackIDs == Set(["factory-a"]),
                "根读取失败必须保留上一份 factory 只读身份")
            expect(error.message.contains(factoryPacks.path), "根错误必须指出真实失败路径")
        }
    }

    await suite("SoundPackLibrary manifest 边界：未知事件不进指纹，当前事件路径长度有硬上限") {
        await withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            var events: [String: String] = ["stop": "stop.mp3"]
            for index in 0..<2_000 {
                events["future-event-\(index)"] = "future-audio-\(index).mp3"
            }
            let manifest = try? JSONSerialization.data(
                withJSONObject: ["id": "pack-a", "events": events],
                options: [.sortedKeys])
            if let manifest {
                try? FileManager.default.createDirectory(
                    at: packs.appendingPathComponent("pack-a", isDirectory: true),
                    withIntermediateDirectories: true)
                try? manifest.write(
                    to:
                        packs
                        .appendingPathComponent("pack-a", isDirectory: true)
                        .appendingPathComponent("manifest.json"),
                    options: .atomic)
            }
            let environment = AudioImportEnvironment(
                userPacksDirectory: packs,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: root.appendingPathComponent("packs.lock"))
            let library = SoundPackLibrary(environment: environment)
            let recorder = SoundPackLibraryStateRecorder()
            let observation = recordLibraryStates(from: library, into: recorder)
            defer { observation.cancel() }
            await library.requestRefresh(trigger: .initial)
            expect(
                await waitForLibraryCondition {
                    await recorder.readySnapshot(containing: "pack-a") != nil
                },
                "含大量未知事件的前向兼容 manifest 仍须可读")
            let fact = await recorder.readySnapshot(containing: "pack-a")?.fact(for: "pack-a")
            expect(
                fact?.fingerprintedAudioFileCountForTesting == 1,
                "指纹只允许保留五个当前事件中的声明，不得按未知 key 放大")
        }

        await withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            let oversized = String(
                repeating: "x",
                count: 1_025)
            writeFixture(
                #"{"id":"pack-a","events":{"stop":"\#(oversized)"}}"#,
                to:
                    packs
                    .appendingPathComponent("pack-a", isDirectory: true)
                    .appendingPathComponent("manifest.json"))
            let environment = AudioImportEnvironment(
                userPacksDirectory: packs,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: root.appendingPathComponent("packs.lock"))
            let library = SoundPackLibrary(environment: environment)
            let recorder = SoundPackLibraryStateRecorder()
            let observation = recordLibraryStates(from: library, into: recorder)
            defer { observation.cancel() }
            await library.requestRefresh(trigger: .initial)
            expect(
                await waitForLibraryCondition {
                    await recorder.readySnapshot(containing: "pack-a") != nil
                },
                "单包超限必须隔离为 broken，不能拖垮整库")
            let fact = await recorder.readySnapshot(containing: "pack-a")?.fact(for: "pack-a")
            guard case .broken(let reason)? = fact?.cardState else {
                expect(false, "超长当前事件文件名必须标成 broken")
                return
            }
            expect(reason.contains("过长"), "broken 必须给出有界、可行动原因")
            expect(
                fact?.fingerprintedAudioFileCountForTesting == 0,
                "超限字符串不得进入 app-lifetime 指纹")
        }
    }

    await suite("SoundPackLibrarySnapshot：磁盘事实与 config 投影正交") {
        let scanner = ScriptedSoundPackScanner([.success([libraryFacts(name: "磁盘名")])])
        let library = SoundPackLibrary(
            scanner: SoundPackLibraryScanner(operation: scanner.scan))
        let stream = await library.states()
        let stateTask = Task { () -> SoundPackLibrarySnapshot? in
            for await state in stream {
                if case .ready(let snapshot) = state { return snapshot }
            }
            return nil
        }

        await library.requestRefresh(trigger: .initial)
        guard let snapshot = await stateTask.value else {
            expect(false, "必须得到一份快照")
            return
        }
        let firstConfig = ClaudioConfig(
            selectedPack: "pack-a", eventsEnabled: [Event.stop.cliName: false],
            starredPacks: ["pack-a"])
        let secondConfig = ClaudioConfig(
            selectedPack: "other", eventsEnabled: [Event.stop.cliName: true],
            starredPacks: [])

        expect(
            snapshot.packCards(config: firstConfig, scope: .fullLibrary).first?.isSelected == true,
            "选中态必须由当前 config 投影")
        expect(
            snapshot.eventRows(packID: "pack-a", config: firstConfig).first(where: {
                $0.event == .stop
            })?.enabled == false,
            "静音态必须由当前 config 投影")
        expect(
            snapshot.packCards(config: secondConfig, scope: .fullLibrary).first?.isSelected
                == false,
            "同一快照应随新 config 改变选中投影")
        expect(
            snapshot.eventRows(packID: "pack-a", config: secondConfig).first(where: {
                $0.event == .stop
            })?.enabled == true,
            "同一快照应随新 config 改变静音投影")
        expect(
            snapshot.packCards(
                config: secondConfig,
                scope: .panelStarredDisplay,
                defaultStarredPackIDs: []
            ).isEmpty,
            "面板显示集必须由最新 starred_packs 投影，不能固化进磁盘快照")
    }

    await suite("SoundPackLibrary 内存：全库扫描延迟 inventory，按需结果只保留四包 LRU") {
        await withTempDirectory { root in
            let packsDirectory = root.appendingPathComponent("packs", isDirectory: true)
            for index in 0..<5 {
                let id = "pack-\(index)"
                let directory = packsDirectory.appendingPathComponent(id, isDirectory: true)
                writeFixture(
                    #"{"id":"\#(id)","name":"\#(id)","events":{"stop":"stop.mp3"}}"#,
                    to: directory.appendingPathComponent("manifest.json"))
                writeFixture("audio", to: directory.appendingPathComponent("stop.mp3"))
            }
            let environment = AudioImportEnvironment(
                userPacksDirectory: packsDirectory,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: root.appendingPathComponent("packs.lock"))
            let library = SoundPackLibrary(environment: environment)
            let recorder = SoundPackLibraryStateRecorder()
            let observation = recordLibraryStates(from: library, into: recorder)
            defer { observation.cancel() }
            await library.requestRefresh(trigger: .initial)
            expect(
                await waitForLibraryCondition {
                    await recorder.readySnapshot(containing: "pack-4") != nil
                },
                "前提：五包 snapshot 必须完成")
            guard let snapshot = await recorder.readySnapshot(containing: "pack-4") else {
                expect(false, "读不到 ready snapshot")
                return
            }
            expect(
                snapshot.facts.allSatisfy { $0.audioInventory == .deferred },
                "全库 cold scan 不得枚举并常驻每个包的 orphan inventory")
            for index in 0..<5 {
                let inventory = await library.audioInventory(packID: "pack-\(index)")
                guard case .available(let files) = inventory else {
                    expect(false, "按需 inventory 必须可读取 pack-\(index)：\(inventory)")
                    return
                }
                expect(files.map(\.fileName) == ["stop.mp3"], "按需 inventory 必须保持真实内容")
            }
            expect(
                await library.inventoryCacheCountForTesting() == 4,
                "app-lifetime inventory cache 必须有硬容量上限 4")
        }
    }

    await suite("SoundPackLibrary 指纹：app 激活刷新能发现未经过本进程的 manifest 变化") {
        await withTempDirectory { root in
            let packsDirectory = root.appendingPathComponent("packs", isDirectory: true)
            let packDirectory = packsDirectory.appendingPathComponent("pack-a", isDirectory: true)
            let manifestURL = packDirectory.appendingPathComponent("manifest.json")
            writeFixture(
                #"{"id":"pack-a","name":"外部修改前","events":{"stop":"stop.mp3"}}"#,
                to: manifestURL)
            writeFixture("audio", to: packDirectory.appendingPathComponent("stop.mp3"))
            let environment = AudioImportEnvironment(
                userPacksDirectory: packsDirectory,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: root.appendingPathComponent("packs.lock"))
            let library = SoundPackLibrary(environment: environment)
            let recorder = SoundPackLibraryStateRecorder()
            let observation = recordLibraryStates(from: library, into: recorder)
            defer { observation.cancel() }

            await library.requestRefresh(trigger: .initial)
            expect(
                await waitForLibraryCondition {
                    await recorder.containsReadyPack(named: "外部修改前")
                },
                "前提：首次读取必须发布原 manifest")

            writeFixture(
                #"{"id":"pack-a","name":"外部修改后的更长名称","events":{"stop":"stop.mp3"}}"#,
                to: manifestURL)
            await library.requestRefresh(trigger: .applicationActivation)

            expect(
                await waitForLibraryCondition {
                    await recorder.containsReadyPack(named: "外部修改后的更长名称")
                },
                "无显式 invalidate 的外部 manifest 变化必须由 metadata fingerprint 发现")
        }
    }

    await suite("SoundPackLibrary 稳定读次：扫描中原子替换 manifest 不得把旧事实绑定到新指纹") {
        await withTempDirectory { root in
            let packsDirectory = root.appendingPathComponent("packs", isDirectory: true)
            let packDirectory = packsDirectory.appendingPathComponent("pack-a", isDirectory: true)
            let manifestURL = packDirectory.appendingPathComponent("manifest.json")
            writeFixture(
                #"{"id":"pack-a","name":"旧名字","events":{"stop":"stop.mp3"}}"#,
                to: manifestURL)
            writeFixture("audio", to: packDirectory.appendingPathComponent("stop.mp3"))
            let replacement = AtomicManifestReplacement(
                manifestURL: manifestURL,
                replacement:
                    #"{"id":"pack-a","name":"新名字","events":{"stop":"stop.mp3"}}"#)
            let environment = AudioImportEnvironment(
                userPacksDirectory: packsDirectory,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: root.appendingPathComponent("packs.lock"))
            let library = SoundPackLibrary(
                scanner: .testingLive(
                    environment: environment,
                    afterManifestRead: replacement.replaceOnce))

            await library.requestRefresh(trigger: .initial)
            let firstReady = await waitForLibraryCondition {
                let stream = await library.states()
                var iterator = stream.makeAsyncIterator()
                guard case .ready(let snapshot)? = await iterator.next() else { return false }
                return snapshot.fact(for: "pack-a")?.name == "新名字"
            }
            expect(firstReady, "不稳定的旧读次必须被丢弃并有界重读到新 manifest")
            expect(
                replacement.callbackCount == 2,
                "首次扫描应恰好经历一次被丢弃读次和一次稳定重读，实际 \(replacement.callbackCount)")

            await library.requestRefresh(trigger: .applicationActivation)
            await library.waitUntilIdleForTesting()
            let replay = await library.states()
            var iterator = replay.makeAsyncIterator()
            guard case .ready(let snapshot)? = await iterator.next() else {
                expect(false, "激活刷新后必须仍有 ready 快照")
                return
            }
            expect(snapshot.fact(for: "pack-a")?.name == "新名字", "后续增量刷新不得复活旧事实")
            expect(
                replacement.callbackCount == 2,
                "稳定新指纹应命中缓存，后续刷新不应再次读 manifest")
        }
    }
}
