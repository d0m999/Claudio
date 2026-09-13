import ClaudioCore
import Foundation

private let hostHookRunnerTestScope = "test-scope-v1"

private final class HostHookRunnerSpawner: ProcessSpawning, @unchecked Sendable {
    private let succeeds: Bool
    private let onSpawn: @Sendable () -> Void
    private(set) var callCount = 0

    init(succeeds: Bool = true, onSpawn: @escaping @Sendable () -> Void = {}) {
        self.succeeds = succeeds
        self.onSpawn = onSpawn
    }

    func spawn(executablePath: String, arguments: [String]) -> Bool {
        callCount += 1
        onSpawn()
        return succeeds
    }
}

private final class HostEventNoticeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var notices: [HostEventNotice] = []

    func append(_ notice: HostEventNotice) {
        lock.lock()
        notices.append(notice)
        lock.unlock()
    }

    var values: [HostEventNotice] {
        lock.lock()
        defer { lock.unlock() }
        return notices
    }
}

@MainActor
func runHostHookRunnerSuites() {
    suite("host hook：UserPromptSubmit 严格映射任务开始，Codex StopFailure 与未知事件失败关闭") {
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
                    host: .codex, nativeEvent: "SomethingNew", installationID: id,
                    environment: environment) == nil,
                "未知事件必须失败关闭")
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
                ready.receiptStore.receiptEvidence(
                    host: .codex,
                    nativeEvent: "PermissionRequest",
                    installationID: id,
                    scopeFingerprint: hostHookRunnerTestScope) != nil,
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

    suite("host hook：有效 Dynamic Quiet 只抑制自动播放并保留既有 muted receipt 语义") {
        withTempDirectory { root in
            let id = UUID(uuidString: "77777777-8888-4999-8AAA-BBBBBBBBBBBB")!
            let now = Date(timeIntervalSince1970: 3_000)
            let spawner = HostHookRunnerSpawner()
            let environment = makeHostHookRunnerEnvironment(
                root: root,
                host: .codex,
                spawner: spawner,
                fixtureIsReady: true,
                now: now,
                activeInstallationID: id)
            let publisher = DynamicQuietSnapshotPublisher(
                snapshotFile: environment.playEnvironment.dynamicQuietEnvironment.snapshotFile,
                revisionStateFile:
                    environment.playEnvironment.dynamicQuietEnvironment.revisionStateFile)
            guard case .success = publisher.publish(focusActive: true, now: now) else {
                expect(false, "测试 Focus 快照必须发布成功")
                return
            }

            let outcome = handleHostHook(
                host: .codex,
                nativeEvent: "PermissionRequest",
                installationID: id,
                environment: environment)
            expect(outcome?.playbackResult == .muted, "动态静默继续复用既有 muted receipt 语义")
            expect(outcome?.receiptWritten == true, "动态静默不得吞掉真实 host callback 回执")
            expect(spawner.callCount == 0, "Focus 生效时 automatic playback 不得 spawn")
        }
    }

    suite("host hook：拒绝的 Dynamic Quiet 快照正常播放且只记录脱敏诊断码") {
        withTempDirectory { root in
            let id = UUID(uuidString: "88888888-9999-4AAA-8BBB-CCCCCCCCCCCC")!
            let now = Date(timeIntervalSince1970: 3_100)
            let spawner = HostHookRunnerSpawner()
            let environment = makeHostHookRunnerEnvironment(
                root: root,
                host: .codex,
                spawner: spawner,
                fixtureIsReady: true,
                now: now,
                activeInstallationID: id)
            let snapshot = environment.playEnvironment.dynamicQuietEnvironment.snapshotFile
            let publisher = DynamicQuietSnapshotPublisher(
                snapshotFile: snapshot,
                revisionStateFile:
                    environment.playEnvironment.dynamicQuietEnvironment.revisionStateFile)
            guard case .success = publisher.publish(focusActive: false, now: now) else {
                expect(false, "测试目录必须先以生产 publisher 建立私有权限")
                return
            }
            let privateSentinel = "Focus: Secret Project"
            writeFixture(#"{"focus_name":"\#(privateSentinel)"}"#, to: snapshot)

            let outcome = handleHostHook(
                host: .codex,
                nativeEvent: "PermissionRequest",
                installationID: id,
                environment: environment)
            expect(outcome?.playbackResult == .played, "拒绝快照必须 fail safe 为正常 automatic playback")
            expect(spawner.callCount == 1, "损坏动态事实不得静默或阻止既有播放")

            let logData = try? Data(contentsOf: environment.playEnvironment.logFile)
            let log = logData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            expect(
                log.contains("dynamic_quiet_snapshot_malformed"),
                "拒绝快照必须留下固定脱敏诊断码")
            expect(
                !log.contains(privateSentinel) && !log.contains(root.path),
                "诊断不得包含快照内容或本机路径")
        }
    }

    suite("host hook：任务开始 250ms 与 lifecycle 1.5s 分轨，且宿主之间互不相吞") {
        withTempDirectory { root in
            let id = UUID()
            let instant = Date(timeIntervalSince1970: 4_000)
            let claude = makeHostHookRunnerEnvironment(
                root: root, host: .claudeCode, spawner: HostHookRunnerSpawner(),
                fixtureIsReady: true, now: instant, activeInstallationID: id)
            let codex = makeHostHookRunnerEnvironment(
                root: root, host: .codex, spawner: HostHookRunnerSpawner(),
                fixtureIsReady: true, now: instant, activeInstallationID: id)
            let firstClaudeStart = handleHostHook(
                host: .claudeCode, nativeEvent: "UserPromptSubmit", installationID: id,
                environment: claude)
            let secondClaudeStart = handleHostHook(
                host: .claudeCode, nativeEvent: "UserPromptSubmit", installationID: id,
                environment: claude)
            let firstCodexStart = handleHostHook(
                host: .codex, nativeEvent: "UserPromptSubmit", installationID: id,
                environment: codex)
            let firstClaudeLifecycle = handleHostHook(
                host: .claudeCode, nativeEvent: "Stop", installationID: id,
                environment: claude)
            let secondClaudeLifecycle = handleHostHook(
                host: .claudeCode, nativeEvent: "Notification", installationID: id,
                environment: claude)
            expect(firstClaudeStart?.playbackResult == .played, "Claude 首次任务开始必须播放")
            expect(secondClaudeStart?.playbackResult == .debounced, "250ms 内重复任务开始必须去抖")
            expect(firstCodexStart?.playbackResult == .played, "同一时刻 Codex 不得被 Claude 去抖吞掉")
            expect(
                firstClaudeLifecycle?.playbackResult == .played,
                "任务开始时间戳不得压掉紧随其后的 lifecycle")
            expect(
                secondClaudeLifecycle?.playbackResult == .debounced,
                "同宿主 1.5 秒内第二个 lifecycle 必须去抖")
            expect(
                claude.playEnvironment.lockFile != codex.playEnvironment.lockFile
                    && claude.playEnvironment.debounceStateFile
                        != codex.playEnvironment.debounceStateFile
                    && claude.taskStartDebounceStateFile
                        != codex.taskStartDebounceStateFile
                    && claude.taskStartDebounceStateFile
                        != claude.playEnvironment.debounceStateFile,
                "两宿主及两条去抖时间轴必须使用不同 state；同宿主仍共用播放锁")
        }
    }

    suite("host hook：任务开始在静音与缺音状态也会独立去抖并写回执") {
        withTempDirectory { root in
            let id = UUID()
            let muted = makeHostHookRunnerEnvironment(
                root: root, host: .claudeCode, spawner: HostHookRunnerSpawner(),
                fixtureIsReady: true, taskStartMuted: true, activeInstallationID: id)
            let first = handleHostHook(
                host: .claudeCode, nativeEvent: "UserPromptSubmit", installationID: id,
                environment: muted)
            let second = handleHostHook(
                host: .claudeCode, nativeEvent: "UserPromptSubmit", installationID: id,
                environment: muted)
            expect(first?.playbackResult == .muted, "首次静音回调必须记录 muted")
            expect(second?.playbackResult == .debounced, "静音重复回调仍须写 debounced")

            let missingRoot = root.appendingPathComponent("missing-start", isDirectory: true)
            try! FileManager.default.createDirectory(
                at: missingRoot, withIntermediateDirectories: true)
            let missing = makeHostHookRunnerEnvironment(
                root: missingRoot, host: .codex, spawner: HostHookRunnerSpawner(),
                activeInstallationID: id)
            let missingFirst = handleHostHook(
                host: .codex, nativeEvent: "UserPromptSubmit", installationID: id,
                environment: missing)
            let missingSecond = handleHostHook(
                host: .codex, nativeEvent: "UserPromptSubmit", installationID: id,
                environment: missing)
            expect(missingFirst?.playbackResult == .notReady, "首次缺音必须记录 notReady")
            expect(missingSecond?.playbackResult == .debounced, "缺音重复回调仍须去抖")
        }
    }

    suite("host hook：来源提示是旁路 best-effort，不改变播放、回执与 CLI 结果") {
        withTempDirectory { root in
            let id = UUID()
            let spawner = HostHookRunnerSpawner()
            let base = makeHostHookRunnerEnvironment(
                root: root,
                host: .codex,
                spawner: spawner,
                fixtureIsReady: true,
                activeInstallationID: id)
            let collector = HostEventNoticeCollector()
            let epoch = UUID()
            let environment = HostHookEnvironment(
                host: base.host,
                playEnvironment: base.playEnvironment,
                taskStartDebounceStateFile: base.taskStartDebounceStateFile,
                taskStartDebounceInterval: base.taskStartDebounceInterval,
                receiptStore: base.receiptStore,
                activityStore: base.activityStore,
                eventNoticeChannel: HostEventNoticeChannel(
                    sourcePayload: Data(
                        #"{"cwd":"/tmp/same-name","session_id":"12345678-secret"}"#.utf8),
                    receiverEpoch: epoch,
                    sender: { notice in
                        collector.append(notice)
                        return .sent
                    }),
                now: base.now)
            let outcome = handleHostHook(
                host: .codex,
                nativeEvent: "Stop",
                installationID: id,
                environment: environment)
            let notices = collector.values
            expect(outcome?.playbackResult == .played, "来源旁路失败不得改变既有播放结果")
            expect(outcome?.receiptWritten == true, "来源旁路失败不得改变既有回执结果")
            expect(notices.count == 1, "当前 installation 的有效事件必须发送一条 notice")
            expect(
                notices.first?.receiverEpoch == epoch
                    && notices.first?.source?.projectLabel == "same-name"
                    && notices.first?.source?.sessionID == "12345678-secret",
                "notice 必须携带脱敏后的项目与会话来源，而非回执内容")
            let receiptData = base.receiptStore.receiptFile(
                host: .codex,
                nativeEvent: "Stop"
            )
            .flatMap { try? Data(contentsOf: $0) }
            let receiptText = receiptData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let logText = (try? String(contentsOf: base.playEnvironment.logFile)) ?? ""
            expect(
                !receiptText.contains("12345678-secret") && !logText.contains("12345678-secret"),
                "项目/会话 sentinel 不得进入回执或日志")

            let droppedEnvironment = HostHookEnvironment(
                host: base.host,
                playEnvironment: PlayEnvironment(
                    surfaceID: base.playEnvironment.surfaceID,
                    afplayPath: base.playEnvironment.afplayPath,
                    lockFile: root.appendingPathComponent("second-play.lock"),
                    configFile: base.playEnvironment.configFile,
                    userPacksDirectory: base.playEnvironment.userPacksDirectory,
                    bundledPacksDirectory: base.playEnvironment.bundledPacksDirectory,
                    spawner: spawner,
                    debounceStateFile: root.appendingPathComponent("second-play.state"),
                    now: base.playEnvironment.now,
                    logFile: base.playEnvironment.logFile,
                    logLockFile: base.playEnvironment.logLockFile),
                receiptStore: base.receiptStore,
                eventNoticeChannel: HostEventNoticeChannel(
                    sourcePayload: Data(#"{"cwd":"/tmp/same-name"}"#.utf8),
                    receiverEpoch: epoch,
                    sender: { _ in .dropped(.endpointClosed) }),
                now: base.now)
            let dropped = handleHostHook(
                host: .codex,
                nativeEvent: "PermissionRequest",
                installationID: id,
                environment: droppedEnvironment)
            expect(
                dropped?.playbackResult == .played && dropped?.receiptWritten == true,
                "发送失败不得改变既有 hook 成功退出所依赖的播放与回执语义")
            let logAfterDrop = (try? String(contentsOf: base.playEnvironment.logFile)) ?? ""
            expect(
                logAfterDrop.contains("endpoint_closed"),
                "已知发送失败必须在日志留下固定脱敏诊断码")
            expect(
                !logAfterDrop.contains("same-name"),
                "诊断码不得夹带来源 payload 内容")
        }
    }

    suite("host hook：playback stub 连续 100 次的返回延迟 p95 不超过 100ms") {
        withTempDirectory { root in
            let id = UUID()
            let spawner = HostHookRunnerSpawner()
            let base = makeHostHookRunnerEnvironment(
                root: root, host: .codex, spawner: spawner,
                fixtureIsReady: true, activeInstallationID: id)
            var durations: [TimeInterval] = []
            let collector = HostEventNoticeCollector()
            durations.reserveCapacity(100)

            for index in 0..<100 {
                // 每次使用独立的短时 timestamp，确保测到完整 resolve → stub spawn → receipt
                // 主路径，而不是第 2 次起全部走 debounced 快路径。
                let environment = HostHookEnvironment(
                    host: .codex,
                    playEnvironment: base.playEnvironment,
                    taskStartDebounceStateFile: root.appendingPathComponent(
                        "performance-task-start-\(index).state"),
                    receiptStore: base.receiptStore,
                    eventNoticeChannel: HostEventNoticeChannel(
                        sourcePayload: Data(
                            #"{"cwd":"/tmp/project","session_id":"s","hook_event_name":"UserPromptSubmit"}"#
                                .utf8),
                        receiverEpoch: UUID(),
                        sender: {
                            collector.append($0); return .sent
                        }),
                    now: base.now)
                let started = ProcessInfo.processInfo.systemUptime
                let outcome = handleHostHook(
                    host: .codex, nativeEvent: "UserPromptSubmit", installationID: id,
                    environment: environment)
                durations.append(ProcessInfo.processInfo.systemUptime - started)
                expect(outcome?.playbackResult == .played, "第 \(index + 1) 次必须经过 playback stub")
            }

            let p95 = durations.sorted()[94]
            expect(spawner.callCount == 100, "100 次主路径必须全部调用 playback stub")
            expect(collector.values.count == 100, "来源解析、规范化和发送必须纳入相同延迟门槛")
            print(
                "  helper source-enabled hook p95: \(String(format: "%.2f", p95 * 1_000))ms (100 calls, playback/send stub)"
            )
            expect(
                p95 <= 0.100,
                "hook 返回延迟 p95 必须 ≤ 100ms，实测 \(String(format: "%.2f", p95 * 1_000))ms")
        }
    }

    suite("host hook：真实 pipe/socket 来源增量 p95 保持 30ms 门槛") {
        withTempDirectory { root in
            let id = UUID()
            let spawner = HostHookRunnerSpawner()
            let base = makeHostHookRunnerEnvironment(
                root: root, host: .codex, spawner: spawner,
                fixtureIsReady: true, activeInstallationID: id)
            let received = HostEventNoticeCollector()
            guard
                let receiver = try? EventNoticeReceiver(
                    descriptorFile: root.appendingPathComponent("performance-descriptor.json"),
                    ownerLockFile: root.appendingPathComponent("performance-owner.lock"),
                    currentInstallationID: { $0 == .codex ? id : nil },
                    callback: { received.append($0) })
            else {
                expect(false, "性能 fixture 必须有真实 receiver")
                return
            }
            receiver.start()
            defer { receiver.stop() }
            let descriptor = receiver.descriptor
            let payload = Data(
                #"{"cwd":"/tmp/project","session_id":"performance-session","hook_event_name":"UserPromptSubmit","prompt":"PRIVATE_SENTINEL"}"#
                    .utf8)
            var enabled: [TimeInterval] = []
            var disabled: [TimeInterval] = []
            for index in 0..<100 {
                var pair: [Bool: TimeInterval] = [:]
                for withSource in index.isMultiple(of: 2) ? [false, true] : [true, false] {
                    let pipe = withSource ? Pipe() : nil
                    pipe?.fileHandleForWriting.write(payload)
                    let started = ProcessInfo.processInfo.systemUptime
                    let channel = pipe.map {
                        HostEventNoticeChannel(
                            sourcePayload: HookInputReader.read(
                                from: $0.fileHandleForReading.fileDescriptor
                            ).data,
                            receiverEpoch: descriptor.epoch, observedUptime: started,
                            sender: { EventNoticeTransport.send($0, to: descriptor) })
                    }
                    let environment = HostHookEnvironment(
                        host: .codex, playEnvironment: base.playEnvironment,
                        taskStartDebounceStateFile: root.appendingPathComponent(
                            "delta-\(index)-\(withSource).state"),
                        receiptStore: base.receiptStore, eventNoticeChannel: channel, now: base.now)
                    let outcome = handleHostHook(
                        host: .codex, nativeEvent: "UserPromptSubmit", installationID: id,
                        environment: environment)
                    pair[withSource] = ProcessInfo.processInfo.systemUptime - started
                    pipe?.fileHandleForWriting.closeFile()
                    pipe?.fileHandleForReading.closeFile()
                    expect(outcome?.playbackResult == .played, "每次基准都必须走相同的完整 playback stub 路径")
                }
                enabled.append(pair[true]!)
                disabled.append(pair[false]!)
            }
            let p95Enabled = enabled.sorted()[94]
            let p95Disabled = disabled.sorted()[94]
            let p95Delta = zip(enabled, disabled).map { $0 - $1 }.sorted()[94]
            for _ in 0..<100 {
                if received.values.count == 100 { break }
                Thread.sleep(forTimeInterval: 0.005)
            }
            expect(received.values.count == 100, "100 次 source-enabled 基准必须到达真实 receiver")
            print(
                "  helper source delta p95: \(String(format: "%.2f", p95Delta * 1000))ms; enabled \(String(format: "%.2f", p95Enabled * 1000))ms; disabled \(String(format: "%.2f", p95Disabled * 1000))ms (100 pairs, real pipe/socket, playback stub)"
            )
            expect(p95Delta <= 0.030, "同进程来源增量 p95 必须 ≤ 30ms，不包括进程/构建冷启动")
        }
    }

    suite("host hook：观察时间在播放前捕获，入口时间跨过声音失败仍保留") {
        withTempDirectory { root in
            let id = UUID()
            let clock = HostHookUptimeClock(100)
            let spawner = HostHookRunnerSpawner(succeeds: false, onSpawn: { clock.set(200) })
            let base = makeHostHookRunnerEnvironment(
                root: root, host: .codex, spawner: spawner,
                fixtureIsReady: true, activeInstallationID: id)
            for entryObservation in [nil, 50.0] {
                clock.set(100)
                let collector = HostEventNoticeCollector()
                let environment = HostHookEnvironment(
                    host: .codex, playEnvironment: base.playEnvironment,
                    taskStartDebounceStateFile: root.appendingPathComponent(UUID().uuidString),
                    receiptStore: base.receiptStore,
                    eventNoticeChannel: HostEventNoticeChannel(
                        sourcePayload: nil, receiverEpoch: UUID(), observedUptime: entryObservation,
                        sender: {
                            collector.append($0); return .sent
                        }),
                    now: base.now, uptime: { clock.value })
                let result = handleHostHook(
                    host: .codex, nativeEvent: "UserPromptSubmit", installationID: id,
                    environment: environment)
                expect(result?.playbackResult == .playbackFailed, "测试必须实际经过播放失败")
                expect(
                    collector.values.first?.observedUptime == (entryObservation ?? 100),
                    "不得以播放后的时间替代 hook 入口或归约前观察")
            }
        }
    }
}

private final class HostHookUptimeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: TimeInterval
    init(_ value: TimeInterval) { storedValue = value }
    var value: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
    func set(_ value: TimeInterval) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

@MainActor
private func makeHostHookRunnerEnvironment(
    root: URL,
    host: HostID,
    spawner: any ProcessSpawning,
    fixtureIsReady: Bool = false,
    taskStartMuted: Bool = false,
    now: Date = Date(timeIntervalSince1970: 3_000),
    activeInstallationID: UUID? = nil
) -> HostHookEnvironment {
    let config = root.appendingPathComponent("config.json")
    let packs = root.appendingPathComponent("packs", isDirectory: true)
    if fixtureIsReady {
        let pack = packs.appendingPathComponent("test", isDirectory: true)
        try! FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        writeFixture(
            taskStartMuted
                ? #"{"selected_pack":"test","master_volume":0.8,"events":{"task_start":false}}"#
                : #"{"selected_pack":"test","master_volume":0.8,"events":{}}"#,
            to: config)
        writeFixture(
            #"{"id":"test","name":"Test","author":"Tests","version":"1","events":{"task_start":"task_start.mp3","stop":"stop.mp3","notification":"notification.mp3","subagent_stop":"subagent.mp3"}}"#,
            to: pack.appendingPathComponent("manifest.json"))
        writeFixture("sound", to: pack.appendingPathComponent("task_start.mp3"))
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
            host: host,
            installationID: activeInstallationID,
            scopeFingerprint: hostHookRunnerTestScope)
    {
        expect(false, "测试 fixture 无法发布当前 installation：\(error.description)")
    }
    return HostHookEnvironment(
        host: host,
        playEnvironment: play,
        taskStartDebounceStateFile: root.appendingPathComponent(
            "\(host.rawValue)-task-start.state"),
        receiptStore: receiptStore,
        now: { now })
}
