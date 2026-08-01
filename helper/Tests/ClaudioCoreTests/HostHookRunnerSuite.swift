import ClaudioCore
import Foundation

private final class HostHookRunnerSpawner: ProcessSpawning, @unchecked Sendable {
    private let succeeds: Bool
    private(set) var callCount = 0

    init(succeeds: Bool = true) { self.succeeds = succeeds }

    func spawn(executablePath: String, arguments: [String]) -> Bool {
        callCount += 1
        return succeeds
    }
}

@MainActor
func runHostHookRunnerSuites() {
    suite("host hook：严格映射，Codex StopFailure 与未知事件不播放也不写回执") {
        withTempDirectory { root in
            let spawner = HostHookRunnerSpawner()
            let environment = makeHostHookRunnerEnvironment(
                root: root, host: .codex, spawner: spawner)
            let id = UUID()
            expect(
                handleHostHook(
                    host: .codex, nativeEvent: "StopFailure", installationID: id,
                    environment: environment) == nil,
                "Codex StopFailure 必须失败关闭")
            expect(
                handleHostHook(
                    host: .codex, nativeEvent: "UserPromptSubmit", installationID: id,
                    environment: environment) == nil,
                "UserPromptSubmit 不得冒充需要你")
            expect(spawner.callCount == 0, "不支持/未知事件不得进入播放链")
            expect(
                !FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("receipts").path),
                "不支持事件不得伪造真实回执")
        }
    }

    suite("host hook：真实事件即使静音、未就绪或播放失败也留下脱敏回执") {
        withTempDirectory { root in
            let id = UUID(uuidString: "99999999-8888-4777-8666-555555555555")!
            let failedSpawner = HostHookRunnerSpawner(succeeds: false)
            let ready = makeHostHookRunnerEnvironment(
                root: root, host: .codex, spawner: failedSpawner, fixtureIsReady: true,
                activeInstallationID: id)
            let failed = handleHostHook(
                host: .codex, nativeEvent: "PermissionRequest", installationID: id,
                environment: ready)
            expect(failed?.playbackResult == .playbackFailed, "spawn 失败必须被回执脱敏记录")
            expect(failed?.receiptWritten == true, "播放失败不能抹掉真实 hook 回执")
            expect(
                ready.receiptStore.activationEvidence(
                    host: .codex, nativeEvent: "PermissionRequest", installationID: id) != nil,
                "播放失败的真实回调仍应形成 activation evidence")

            let missingRoot = root.appendingPathComponent("missing-case", isDirectory: true)
            try! FileManager.default.createDirectory(
                at: missingRoot, withIntermediateDirectories: true)
            let missing = makeHostHookRunnerEnvironment(
                root: missingRoot, host: .claudeCode, spawner: HostHookRunnerSpawner(),
                activeInstallationID: id)
            let notReady = handleHostHook(
                host: .claudeCode, nativeEvent: "Stop", installationID: id,
                environment: missing)
            expect(notReady?.playbackResult == .notReady, "未配置声音包应脱敏记录 not_ready")
            expect(notReady?.receiptWritten == true, "未就绪也必须证明宿主真实触发过")
        }
    }

    suite("host hook：宿主级防抖互不相吞，legacy play 的共享路径未改变") {
        withTempDirectory { root in
            let id = UUID()
            let instant = Date(timeIntervalSince1970: 4_000)
            let claude = makeHostHookRunnerEnvironment(
                root: root, host: .claudeCode, spawner: HostHookRunnerSpawner(),
                fixtureIsReady: true, now: instant, activeInstallationID: id)
            let codex = makeHostHookRunnerEnvironment(
                root: root, host: .codex, spawner: HostHookRunnerSpawner(),
                fixtureIsReady: true, now: instant, activeInstallationID: id)
            let firstClaude = handleHostHook(
                host: .claudeCode, nativeEvent: "Stop", installationID: id,
                environment: claude)
            let firstCodex = handleHostHook(
                host: .codex, nativeEvent: "Stop", installationID: id,
                environment: codex)
            let secondClaude = handleHostHook(
                host: .claudeCode, nativeEvent: "Notification", installationID: id,
                environment: claude)
            expect(firstClaude?.playbackResult == .played, "Claude 首次事件必须播放")
            expect(firstCodex?.playbackResult == .played, "同一时刻 Codex 不得被 Claude 去抖吞掉")
            expect(secondClaude?.playbackResult == .debounced, "同宿主 1.5 秒内第二事件必须去抖")
            expect(
                claude.playEnvironment.lockFile != codex.playEnvironment.lockFile
                    && claude.playEnvironment.debounceStateFile
                        != codex.playEnvironment.debounceStateFile,
                "两宿主必须使用不同 lock/state")
        }
    }
}

@MainActor
private func makeHostHookRunnerEnvironment(
    root: URL,
    host: HostID,
    spawner: any ProcessSpawning,
    fixtureIsReady: Bool = false,
    now: Date = Date(timeIntervalSince1970: 3_000),
    activeInstallationID: UUID? = nil
) -> HostHookEnvironment {
    let config = root.appendingPathComponent("config.json")
    let packs = root.appendingPathComponent("packs", isDirectory: true)
    if fixtureIsReady {
        let pack = packs.appendingPathComponent("test", isDirectory: true)
        try! FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        writeFixture(
            #"{"selected_pack":"test","master_volume":0.8,"events":{}}"#,
            to: config)
        writeFixture(
            #"{"id":"test","name":"Test","author":"Tests","version":"1","events":{"stop":"stop.mp3","notification":"notification.mp3","subagent_stop":"subagent.mp3"}}"#,
            to: pack.appendingPathComponent("manifest.json"))
        writeFixture("sound", to: pack.appendingPathComponent("stop.mp3"))
        writeFixture("sound", to: pack.appendingPathComponent("notification.mp3"))
        writeFixture("sound", to: pack.appendingPathComponent("subagent.mp3"))
    }
    let play = PlayEnvironment(
        afplayPath: "/usr/bin/afplay",
        lockFile: root.appendingPathComponent("\(host.rawValue)-play.lock"),
        configFile: config,
        userPacksDirectory: packs,
        spawner: spawner,
        debounceStateFile: root.appendingPathComponent("\(host.rawValue)-play.state"),
        now: { now },
        logFile: root.appendingPathComponent("claudio.log"),
        logLockFile: root.appendingPathComponent("claudio.log.lock"))
    let receiptStore = HostHookReceiptStore(
        receiptsRoot: root.appendingPathComponent("receipts", isDirectory: true),
        locksRoot: root.appendingPathComponent("receipt-locks", isDirectory: true))
    if let activeInstallationID,
        case .failure(let error) = receiptStore.activate(
            host: host, installationID: activeInstallationID)
    {
        expect(false, "测试 fixture 无法发布当前 installation：\(error.description)")
    }
    return HostHookEnvironment(
        host: host,
        playEnvironment: play,
        receiptStore: receiptStore,
        now: { now })
}
