import ClaudioCore
import ClaudioHookInput
import Foundation

private final class WorkBuddyNotificationProbe: ProcessSpawning, @unchecked Sendable {
    var arguments: [[String]] = []
    var scope: String? = "scope-current"
    var instant = Date(timeIntervalSince1970: 9_000)
    var authorizationChecks = 0
    var onSpawn: () -> Void = {}

    func spawn(executablePath: String, arguments: [String]) -> Bool {
        self.arguments.append(arguments)
        onSpawn()
        return true
    }
}

@MainActor
func runWorkBuddyNotificationSuites() {
    suite("WorkBuddy Notification：已验证 subtype 在发送前投影正确提醒原因") {
        for (subtype, expected) in [
            ("permission_prompt", HostEventNoticeReason.permission),
            ("idle_prompt", .informational),
        ] {
            withTempDirectory { root in
                let probe = WorkBuddyNotificationProbe()
                let notices = HostEventNoticeCollector()
                let id = UUID()
                let payload = Data(
                    #"{"hook_event_name":"Notification","notification_type":"\#(subtype)"}"#.utf8)
                let channel = HostEventNoticeChannel(
                    sourcePayload: payload, receiverEpoch: UUID(),
                    sender: { notice in
                        notices.append(notice)
                        return .sent
                    })
                let environment = notificationEnvironment(
                    root: root, id: id, probe: probe, eventNoticeChannel: channel)
                let outcome = validatedNotification(
                    subtype: subtype, id: id, environment: environment)
                expect(outcome?.receiptWritten == true, "有效通知必须通过输入门禁与 hook 主链")
                expect(notices.values.count == 1, "有效通知必须发送一条提示")
                expect(notices.values.first?.reason == expected, "\(subtype) 的提示原因必须正确")
                expect(notices.values.first?.isSemanticallyValid == true, "提示必须通过接收器的语义校验")
                expect(notices.values.first?.source == nil, "通知不得附带未经校准的 WorkBuddy 来源")
            }
        }
    }

    suite("WorkBuddy Notification：两个 subtype 无目录也使用默认组声音包与音量") {
        for subtype in WorkBuddyNotification.subtypes {
            withTempDirectory { root in
                let probe = WorkBuddyNotificationProbe()
                let id = UUID()
                let environment = notificationEnvironment(root: root, id: id, probe: probe)
                let outcome = validatedNotification(
                    subtype: subtype, id: id, environment: environment)
                expect(
                    outcome?.playbackResult == .played && outcome?.receiptWritten == true,
                    "\(subtype) 应播放并形成当前回执")
                expect(
                    probe.arguments.first == [
                        "-v", "0.37",
                        root.appendingPathComponent("packs/default/notification.mp3").path,
                    ],
                    "默认组独立音量及声音包必须到达播放器")
                expect(
                    environment.receiptStore.receiptEvidence(
                        host: .workBuddy, nativeEvent: "Notification", installationID: id,
                        scopeFingerprint: "scope-current")?.event == .notification,
                    "两个 subtype 共用 Notification 绑定与既有回执格式")
            }
        }
    }

    suite("WorkBuddy Notification：事件静音、零音量与动态静默分别遵守既有播放合同") {
        for mode in ["event", "volumeZero", "quiet"] {
            withTempDirectory { root in
                let probe = WorkBuddyNotificationProbe()
                let id = UUID()
                let environment = notificationEnvironment(root: root, id: id, probe: probe)
                if mode == "event" || mode == "volumeZero" {
                    writeFixture(
                        mode == "event"
                            ? #"{"selected_pack":"default","master_volume":0.37,"events":{"notification":false}}"#
                            : #"{"selected_pack":"default","master_volume":0}"#,
                        to: environment.playEnvironment.configFile)
                } else {
                    let quiet = environment.playEnvironment.dynamicQuietEnvironment
                    _ = DynamicQuietSnapshotPublisher(
                        snapshotFile: quiet.snapshotFile, revisionStateFile: quiet.revisionStateFile
                    ).publish(focusActive: true, now: probe.instant)
                }
                let outcome = validatedNotification(
                    subtype: "idle_prompt", id: id, environment: environment)
                expect(
                    outcome?.playbackResult == (mode == "volumeZero" ? .played : .muted)
                        && outcome?.receiptWritten == true, "静音与零音量保留各自的既有回执语义")
                if mode == "volumeZero" {
                    expect(
                        probe.arguments.first?.first == "-v"
                            && probe.arguments.first.flatMap { Double($0[1]) } == 0, "零音量必须传到播放器")
                } else {
                    expect(probe.arguments.isEmpty, "\(mode) 不得启动播放器")
                }
            }
        }
    }

    suite("WorkBuddy Notification：畸形、重复、未知类型及有界读取失败无播放或回执") {
        let invalidJSON = [
            "{}", "[]", "null", "{", "",
            #"{"hook_event_name":"Stop","notification_type":"idle_prompt"}"#,
            #"{"hook_event_name":7,"notification_type":"idle_prompt"}"#,
            #"{"hook_event_name":"Notification"}"#,
            #"{"hook_event_name":"Notification","notification_type":null}"#,
            #"{"hook_event_name":"Notification","notification_type":true}"#,
            #"{"hook_event_name":"Notification","notification_type":[]}"#,
            #"{"hook_event_name":"Notification","notification_type":"auth_success"}"#,
            #"{"hook_event_name":"Notification","notification_type":"permission_prompt|idle_prompt"}"#,
            #"{"hook_event_name":"Notification","hook_event_name":"Notification","notification_type":"idle_prompt"}"#,
            #"{"hook_event_name":"Notification","notification_type":"idle_prompt","notification_type":"idle_prompt"}"#,
            #"{"hook_event_name":"Notification","hook_\u0065vent_name":"Notification","notification_type":"idle_prompt"}"#,
            #"{"hook_event_name":"Notification","notification_type":"idle_prompt","notification_\u0074ype":"permission_prompt"}"#,
            String(repeating: " ", count: HookInputReader.defaultMaximumBytes + 1),
        ]
        var inputs = invalidJSON.map { HookInputReadResult(status: .data, data: Data($0.utf8)) }
        inputs += [.init(status: .tooLarge), .init(status: .timedOut), .init(status: .empty)]
        for input in inputs {
            withTempDirectory { root in
                let probe = WorkBuddyNotificationProbe()
                let id = UUID()
                let environment = notificationEnvironment(root: root, id: id, probe: probe)
                if WorkBuddyHookPayloadPolicy.accepts(nativeEvent: "Notification", input: input) {
                    _ = handleHostHook(
                        host: .workBuddy, nativeEvent: "Notification",
                        installationID: id, environment: environment)
                    expect(false, "非法 Notification 不得通过 CLI 输入门禁")
                }
                expect(probe.arguments.isEmpty, "非法输入不得播放")
                expect(
                    !FileManager.default.fileExists(
                        atPath: environment.receiptStore.receiptFile(
                            host: .workBuddy, nativeEvent: "Notification")!.path),
                    "非法输入不得产生回执")
            }
        }
    }

    suite("WorkBuddy Notification：与 Stop/SubagentStop 共享 1.5s，任务开始独立 250ms") {
        withTempDirectory { root in
            let probe = WorkBuddyNotificationProbe()
            let id = UUID()
            let environment = notificationEnvironment(root: root, id: id, probe: probe)
            func event(_ native: String) -> HostHookPlaybackResult? {
                handleHostHook(
                    host: .workBuddy, nativeEvent: native,
                    installationID: id, environment: environment)?.playbackResult
            }
            expect(event("UserPromptSubmit") == .played, "任务开始应播放")
            expect(event("Notification") == .played, "任务开始不能吞掉通知")
            probe.instant += 0.2
            expect(event("UserPromptSubmit") == .debounced, "250ms 内任务开始去抖")
            expect(event("Stop") == .debounced, "Stop 必须共享通知去抖")
            probe.instant += 0.1
            expect(event("UserPromptSubmit") == .played, "250ms 后任务开始可播放")
            expect(event("SubagentStop") == .debounced, "SubagentStop 仍在 lifecycle 去抖窗口")
            probe.instant += 1.21
            expect(event("Notification") == .played, "1.5s 后通知恢复播放")
        }
    }

    suite("WorkBuddy scope：入口与播放器启动前均拒绝旧版本、缺身份和断开") {
        for change in ["version", "missing", "disconnect", "reconnect"] {
            for beforeSpawn in [false, true] {
                withTempDirectory { root in
                    let probe = WorkBuddyNotificationProbe()
                    let id = UUID()
                    let store = notificationStore(root)
                    let changeInstallation: @Sendable () -> Void = {
                        switch change {
                        case "version": probe.scope = "scope-upgraded"
                        case "missing": probe.scope = nil
                        case "disconnect":
                            _ = store.deactivate(host: .workBuddy, installationID: id)
                        default:
                            _ = store.activate(
                                host: .workBuddy, installationID: UUID(),
                                scopeFingerprint: "scope-current")
                        }
                    }
                    let environment = notificationEnvironment(
                        root: root, id: id, probe: probe,
                        playbackAuthorized: {
                            probe.authorizationChecks += 1
                            if beforeSpawn && probe.authorizationChecks == 2 {
                                changeInstallation()
                            }
                            return true
                        })
                    if !beforeSpawn { changeInstallation() }
                    let outcome = validatedNotification(
                        subtype: "permission_prompt", id: id, environment: environment)
                    expect(
                        outcome?.playbackResult == .notReady && outcome?.receiptWritten == false,
                        "\(change) 在 \(beforeSpawn ? "启动前" : "入口") 必须拒绝")
                    expect(probe.arguments.isEmpty, "失效安装不得 spawn")
                    expect(
                        !FileManager.default.fileExists(
                            atPath: environment.playEnvironment.debounceStateFile.path),
                        "拒绝不能占用通知去抖窗口")
                }
            }
        }
    }

    suite("WorkBuddy scope：播放后的版本变化、同 ID scope 替换与重连拒绝迟到回执") {
        for change in ["version", "scope", "disconnect", "reconnect"] {
            withTempDirectory { root in
                let probe = WorkBuddyNotificationProbe()
                let id = UUID()
                let environment = notificationEnvironment(root: root, id: id, probe: probe)
                probe.onSpawn = {
                    switch change {
                    case "version": probe.scope = "scope-upgraded"
                    case "scope":
                        _ = environment.receiptStore.activate(
                            host: .workBuddy,
                            installationID: id, scopeFingerprint: "scope-upgraded")
                    case "disconnect":
                        _ = environment.receiptStore.deactivate(
                            host: .workBuddy, installationID: id)
                    default:
                        _ = environment.receiptStore.activate(
                            host: .workBuddy,
                            installationID: UUID(), scopeFingerprint: "scope-current")
                    }
                }
                let outcome = validatedNotification(
                    subtype: "idle_prompt", id: id, environment: environment)
                expect(
                    outcome?.playbackResult == .played && probe.arguments.count == 1,
                    "测试前提：竞争发生在真实 spawn seam 之后")
                expect(outcome?.receiptWritten == false, "\(change) 必须拒绝迟到回执")
            }
        }
    }

    suite("WorkBuddy 回执：在安装锁内核对完整 scope，不改变正式格式") {
        withTempDirectory { root in
            let probe = WorkBuddyNotificationProbe()
            let id = UUID()
            let environment = notificationEnvironment(root: root, id: id, probe: probe)
            let store = environment.receiptStore
            let receipt = HostHookReceipt(
                installationID: id, host: .workBuddy,
                nativeEvent: "Notification", semanticEvent: .notification,
                timestamp: probe.instant, playbackResult: .muted)
            let written = store.store(
                receipt, expectedScopeFingerprint: "scope-current",
                scopeFingerprint: {
                    if case .skipped = withNonBlockingLock(
                        path: store.installationLockFile(host: .workBuddy).path, {})
                    {
                        return "scope-current"
                    }
                    return nil
                })
            expect(written == .success(.written), "scope reader 必须在已有安装锁的临界区运行")
            let before = try! Data(
                contentsOf: store.receiptFile(host: .workBuddy, nativeEvent: "Notification")!)
            expect(
                store.store(receipt, scopeFingerprint: { "scope-other" })
                    == .failure(.staleInstallation),
                "直接回执写入不能绕过 scope 检查")
            expect(
                try! Data(
                    contentsOf: store.receiptFile(host: .workBuddy, nativeEvent: "Notification")!)
                    == before,
                "拒绝时保留已有回执字节")
            let json = try! JSONSerialization.jsonObject(with: before) as! [String: Any]
            expect(
                json["notification_type"] == nil && json["cwd"] == nil
                    && json["scope_fingerprint"] == nil,
                "subtype、目录及 scope 不扩展正式回执格式")
        }
    }
}

private func notificationStore(_ root: URL) -> HostHookReceiptStore {
    HostHookReceiptStore(
        receiptsRoot: root.appendingPathComponent("receipts"),
        locksRoot: root.appendingPathComponent("receipt-locks"))
}

@MainActor
private func notificationEnvironment(
    root: URL, id: UUID, probe: WorkBuddyNotificationProbe,
    playbackAuthorized: @escaping @Sendable () -> Bool = { true },
    eventNoticeChannel: HostEventNoticeChannel? = nil
) -> HostHookEnvironment {
    let pack = root.appendingPathComponent("packs/default")
    writeFixture(
        #"{"id":"default","name":"Default","author":"Tests","version":"1","events":{"task_start":"notification.mp3","stop":"notification.mp3","subagent_stop":"notification.mp3","notification":"notification.mp3"}}"#,
        to: pack.appendingPathComponent("manifest.json"))
    writeFixture("sound", to: pack.appendingPathComponent("notification.mp3"))
    let config = root.appendingPathComponent("config.json")
    writeFixture(
        #"{"selected_pack":"default","master_volume":0.37,"surface_overrides":{"workbuddy":{"selected_pack":"missing","master_volume":0.99}}}"#,
        to: config)
    let store = notificationStore(root)
    _ = store.activate(host: .workBuddy, installationID: id, scopeFingerprint: "scope-current")
    return HostHookEnvironment(
        host: .workBuddy,
        playEnvironment: PlayEnvironment(
            playbackAuthorized: playbackAuthorized,
            lockFile: root.appendingPathComponent("play.lock"), configFile: config,
            userPacksDirectory: root.appendingPathComponent("packs"), spawner: probe,
            debounceStateFile: root.appendingPathComponent("play.state"), now: { probe.instant },
            logFile: root.appendingPathComponent("log"),
            logLockFile: root.appendingPathComponent("log.lock")),
        receiptStore: store, eventNoticeChannel: eventNoticeChannel,
        scopeFingerprint: { probe.scope }, now: { probe.instant })
}

private func validatedNotification(
    subtype: String, id: UUID, environment: HostHookEnvironment
) -> HostHookHandlingOutcome? {
    let input = HookInputReadResult(
        status: .data,
        data: Data(#"{"hook_event_name":"Notification","notification_type":"\#(subtype)"}"#.utf8))
    guard WorkBuddyHookPayloadPolicy.accepts(nativeEvent: "Notification", input: input) else {
        return nil
    }
    return handleHostHook(
        host: .workBuddy, nativeEvent: "Notification",
        installationID: id, environment: environment)
}
