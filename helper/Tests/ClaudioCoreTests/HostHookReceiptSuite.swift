import ClaudioCore
import Foundation

private let hostHookReceiptTestScope = "test-scope-v1"

@MainActor
func runHostHookReceiptSuites() {
    suite("HostHookReceipt：最小脱敏 JSON 可形成当前 installation 的真实 activation evidence") {
        withTempDirectory { root in
            let store = HostHookReceiptStore(
                receiptsRoot: root.appendingPathComponent("receipts", isDirectory: true),
                locksRoot: root.appendingPathComponent("receipt-locks", isDirectory: true))
            let installationID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
            let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
            guard
                case .success = store.activate(
                    host: .codex,
                    installationID: installationID,
                    scopeFingerprint: hostHookReceiptTestScope)
            else {
                expect(false, "测试前提：必须先发布当前 Codex installation")
                return
            }
            let markerPermissions =
                (try? FileManager.default.attributesOfItem(
                    atPath: store.installationFile(host: .codex).path))?[.posixPermissions]
                as? NSNumber
            expect(
                markerPermissions.map { $0.intValue & 0o777 } == 0o600,
                "active installation 标记也必须从最终路径保持 0600")
            let receipt = HostHookReceipt(
                installationID: installationID,
                host: .codex,
                nativeEvent: "PermissionRequest",
                semanticEvent: .notification,
                timestamp: timestamp,
                playbackResult: .played)

            guard case .success(.written) = store.store(receipt) else {
                expect(false, "有效回执必须成功原子落盘")
                return
            }
            guard
                let receiptFile = store.receiptFile(
                    host: .codex, nativeEvent: "PermissionRequest"),
                let data = try? Data(contentsOf: receiptFile),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                expect(false, "必须能从注入的 receiptsRoot 读回独立事件 JSON")
                return
            }

            expect(
                Set(object.keys) == [
                    "schema", "installation_id", "host", "binding_id", "native_event",
                    "semantic_event", "timestamp", "playback_result",
                ],
                "回执 schema 必须是封闭白名单，禁止 prompt/content/project/session/audio path 字段")
            expect(object["schema"] as? Int == 2, "当前回执 schema 必须固定为 2")
            expect(object["host"] as? String == "codex", "宿主必须使用稳定 HostID token")
            expect(
                object["semantic_event"] as? String == "notification",
                "语义事件必须保存声音包稳定键")
            expect(
                !String(decoding: data, as: UTF8.self).contains(root.path),
                "脱敏播放结果与整份回执都不得泄露任何绝对路径")

            let permissions =
                (try? FileManager.default.attributesOfItem(
                    atPath: receiptFile.path))?[.posixPermissions] as? NSNumber
            expect(
                permissions.map { $0.intValue & 0o777 } == 0o600,
                "最终回执权限必须是 0600，got \(permissions?.stringValue ?? "<missing>")")
            expect(
                store.receiptEvidence(
                    host: .codex, nativeEvent: "PermissionRequest",
                    installationID: installationID,
                    scopeFingerprint: hostHookReceiptTestScope)
                    == HostReceiptEvidence(
                        bindingID: HostCapabilityCatalog.binding(
                            host: .codex, nativeEvent: "PermissionRequest")!.id,
                        installationID: installationID,
                        nativeEvent: "PermissionRequest",
                        event: .notification,
                        timestamp: timestamp,
                        playbackResult: .played),
                "当前 installation 的真实回执必须形成 activation evidence")
        }
    }

    suite("HostHookReceiptStore：事件锁彼此独立，争用与文件系统失败均显式返回") {
        withTempDirectory { root in
            let store = HostHookReceiptStore(
                receiptsRoot: root.appendingPathComponent("receipts", isDirectory: true),
                locksRoot: root.appendingPathComponent("receipt-locks", isDirectory: true))
            let installationID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
            guard
                case .success = store.activate(
                    host: .claudeCode,
                    installationID: installationID,
                    scopeFingerprint: hostHookReceiptTestScope)
            else {
                expect(false, "测试前提：必须先发布当前 Claude Code installation")
                return
            }
            let stop = HostHookReceipt(
                installationID: installationID,
                host: .claudeCode,
                nativeEvent: "Stop",
                semanticEvent: .stop,
                timestamp: Date(timeIntervalSince1970: 1_800_000_010),
                playbackResult: .muted)
            let subagent = HostHookReceipt(
                installationID: installationID,
                host: .claudeCode,
                nativeEvent: "SubagentStop",
                semanticEvent: .subagentStop,
                timestamp: Date(timeIntervalSince1970: 1_800_000_011),
                playbackResult: .debounced)

            guard let stopLock = store.lockFile(host: .claudeCode, nativeEvent: "Stop") else {
                expect(false, "已支持事件必须有独立锁路径")
                return
            }
            let contended = withNonBlockingLock(path: stopLock.path) {
                expect(
                    store.store(stop) == .failure(.lockBusy),
                    "同一事件锁被占用时必须立即返回 lockBusy")
                expect(
                    store.store(subagent) == .success(.written),
                    "Stop 锁不能吞掉 SubagentStop 回执")
            }
            guard case .ran = contended else {
                expect(false, "测试自身必须先持有 Stop 回执锁")
                return
            }
            expect(store.store(stop) == .success(.written), "锁释放后 Stop 回执必须可写")
            expect(
                store.receiptFile(host: .claudeCode, nativeEvent: "Stop")
                    != store.receiptFile(host: .claudeCode, nativeEvent: "SubagentStop"),
                "每个宿主原生事件必须落到独立 JSON")

            let unsupported = HostHookReceipt(
                installationID: installationID,
                host: .codex,
                nativeEvent: "StopFailure",
                semanticEvent: .stopFailure,
                timestamp: Date(timeIntervalSince1970: 1_800_000_012),
                playbackResult: .unsupportedEvent)
            expect(
                store.store(unsupported) == .failure(.invalidReceipt),
                "Codex StopFailure/未知映射不能写成真实回执")

            let blockedReceiptRoot = root.appendingPathComponent("blocked-receipts")
            writeFixture("regular file blocks directory creation", to: blockedReceiptRoot)
            let unwritableStore = HostHookReceiptStore(
                receiptsRoot: blockedReceiptRoot.appendingPathComponent("receipts"),
                locksRoot: root.appendingPathComponent("write-failure-locks"),
                installationsRoot: root.appendingPathComponent("write-failure-installations"),
                installationLocksRoot: root.appendingPathComponent(
                    "write-failure-installation-locks"))
            guard
                case .success = unwritableStore.activate(
                    host: .claudeCode,
                    installationID: installationID,
                    scopeFingerprint: hostHookReceiptTestScope)
            else {
                expect(false, "测试前提：回执目录失败不应被 installation marker 失败遮蔽")
                return
            }
            if case .failure(.directoryCreationFailure) = unwritableStore.store(stop) {
                expect(true, "落盘目录失败已显式返回")
            } else {
                expect(false, "父路径被普通文件堵住时必须返回 directoryCreationFailure")
            }

            let blockedLockRoot = root.appendingPathComponent("blocked-locks")
            writeFixture("regular file blocks lock parent", to: blockedLockRoot)
            let lockFailureStore = HostHookReceiptStore(
                receiptsRoot: root.appendingPathComponent("lock-failure-receipts"),
                locksRoot: blockedLockRoot.appendingPathComponent("locks"),
                installationsRoot: root.appendingPathComponent("lock-failure-installations"),
                installationLocksRoot: root.appendingPathComponent(
                    "lock-failure-installation-locks"))
            guard
                case .success = lockFailureStore.activate(
                    host: .claudeCode,
                    installationID: installationID,
                    scopeFingerprint: hostHookReceiptTestScope)
            else {
                expect(false, "测试前提：事件锁失败不应被 installation marker 失败遮蔽")
                return
            }
            if case .failure(.lockFailed) = lockFailureStore.store(stop) {
                expect(true, "锁文件系统失败已显式返回")
            } else {
                expect(false, "锁父路径不可创建时必须返回 lockFailed，不能伪装成 lockBusy")
            }
        }
    }

    suite("HostHookReceipt：同毫秒不同微秒回执无损 round-trip 后仍能选出最新 evidence") {
        withTempDirectory { root in
            let store = HostHookReceiptStore(
                receiptsRoot: root.appendingPathComponent("receipts", isDirectory: true),
                locksRoot: root.appendingPathComponent("receipt-locks", isDirectory: true))
            let installationID = UUID(uuidString: "45454545-4545-4545-8545-454545454545")!
            let permissionTimestamp = Date(timeIntervalSince1970: 1_800_000_100.1234)
            let subagentTimestamp = Date(timeIntervalSince1970: 1_800_000_100.1235)
            guard
                case .success = store.activate(
                    host: .codex,
                    installationID: installationID,
                    scopeFingerprint: hostHookReceiptTestScope)
            else {
                expect(false, "测试前提：必须先发布当前 Codex installation")
                return
            }

            let permission = HostHookReceipt(
                installationID: installationID,
                host: .codex,
                nativeEvent: "PermissionRequest",
                semanticEvent: .notification,
                timestamp: permissionTimestamp,
                playbackResult: .played)
            let subagent = HostHookReceipt(
                installationID: installationID,
                host: .codex,
                nativeEvent: "SubagentStop",
                semanticEvent: .subagentStop,
                timestamp: subagentTimestamp,
                playbackResult: .muted)
            expect(store.store(permission) == .success(.written), "同秒第一条回执必须成功写入")
            expect(store.store(subagent) == .success(.written), "同秒第二条回执必须成功写入")

            let permissionEvidence = store.receiptEvidence(
                host: .codex,
                nativeEvent: "PermissionRequest",
                installationID: installationID,
                scopeFingerprint: hostHookReceiptTestScope)
            let subagentEvidence = store.receiptEvidence(
                host: .codex,
                nativeEvent: "SubagentStop",
                installationID: installationID,
                scopeFingerprint: hostHookReceiptTestScope)
            expect(
                permissionEvidence?.timestamp == permissionTimestamp,
                "PermissionRequest 小数秒必须逐值 round-trip")
            expect(
                subagentEvidence?.timestamp == subagentTimestamp,
                "SubagentStop 小数秒必须逐值 round-trip")
            let latest = [permissionEvidence, subagentEvidence]
                .compactMap { $0 }
                .max { $0.timestamp < $1.timestamp }
            expect(
                latest?.nativeEvent == "SubagentStop",
                "同一秒内较晚的 SubagentStop 必须成为最新结构化 evidence")

            let timestampValues = ["PermissionRequest", "SubagentStop"].compactMap {
                event -> Double? in
                guard let file = store.receiptFile(host: .codex, nativeEvent: event),
                    let data = try? Data(contentsOf: file),
                    let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return (root["timestamp"] as? NSNumber)?.doubleValue
            }
            expect(timestampValues.count == 2, "两份回执都必须保存数值 timestamp")
            expect(
                timestampValues.contains(permissionTimestamp.timeIntervalSince1970)
                    && timestampValues.contains(subagentTimestamp.timeIntervalSince1970)
                    && timestampValues[0] != timestampValues[1],
                "新回执必须无损保留同毫秒内不同的 epoch 小数，got \(timestampValues)")
        }
    }

    suite("HostHookReceipt：旧 schema-1 回执可解码但不能升级为当前 activation evidence") {
        withTempDirectory { root in
            let store = HostHookReceiptStore(
                receiptsRoot: root.appendingPathComponent("receipts", isDirectory: true),
                locksRoot: root.appendingPathComponent("receipt-locks", isDirectory: true))
            let installationID = UUID(uuidString: "56565656-5656-4656-8656-565656565656")!
            guard
                case .success = store.activate(
                    host: .codex,
                    installationID: installationID,
                    scopeFingerprint: hostHookReceiptTestScope),
                let file = store.receiptFile(host: .codex, nativeEvent: "PermissionRequest")
            else {
                expect(false, "测试前提：必须发布 installation 并取得回执路径")
                return
            }
            let legacyJSON =
                """
                {
                  "schema": 1,
                  "installation_id": "\(installationID.uuidString)",
                  "host": "codex",
                  "native_event": "PermissionRequest",
                  "semantic_event": "notification",
                  "timestamp": "2027-01-15T08:00:00Z",
                  "playback_result": "played"
                }
                """
            writeFixture(legacyJSON, to: file)
            let historyFile = store.historyRoot
                .appendingPathComponent(HostSurfaceID.codex.rawValue, isDirectory: true)
                .appendingPathComponent("legacy-schema-1.json")
            writeFixture(legacyJSON, to: historyFile)

            expect(
                store.receiptEvidence(
                    host: .codex,
                    nativeEvent: "PermissionRequest",
                    installationID: installationID,
                    scopeFingerprint: hostHookReceiptTestScope) == nil,
                "旧 schema-1 回执只能作为历史记录，不能点亮当前 activation")
            let history = store.receiptHistory(host: .codex)
            expect(history.count == 1, "旧 schema-1 无 binding_id 回执仍须保留为脱敏历史")
            expect(
                history.first?.bindingID
                    == HostEventBindingID(
                        rawValue: "legacy:codex:PermissionRequest"),
                "旧回执不得合成当前 catalog binding ID")
        }
    }

    suite("HostHookReceiptStore：损坏、旧代次、宿主或事件错位均不是 activation evidence") {
        withTempDirectory { root in
            let store = HostHookReceiptStore(
                receiptsRoot: root.appendingPathComponent("receipts", isDirectory: true),
                locksRoot: root.appendingPathComponent("receipt-locks", isDirectory: true))
            let currentID = UUID(uuidString: "12345678-1234-4234-8234-123456789abc")!
            let staleID = UUID(uuidString: "87654321-4321-4321-8321-cba987654321")!
            guard
                case .success = store.activate(
                    host: .codex,
                    installationID: currentID,
                    scopeFingerprint: hostHookReceiptTestScope)
            else {
                expect(false, "测试前提：必须先发布当前 Codex installation")
                return
            }
            let receipt = HostHookReceipt(
                installationID: currentID,
                host: .codex,
                nativeEvent: "PermissionRequest",
                semanticEvent: .notification,
                timestamp: Date(timeIntervalSince1970: 1_800_000_020),
                playbackResult: .playbackFailed)
            expect(store.store(receipt) == .success(.written), "播放失败也应留下脱敏真实回执")
            expect(
                store.receiptEvidence(
                    host: .codex, nativeEvent: "PermissionRequest", installationID: currentID,
                    scopeFingerprint: hostHookReceiptTestScope)
                    != nil,
                "播放失败不抹掉 hook 已真实触发这一 activation 事实")
            expect(
                store.receiptEvidence(
                    host: .codex, nativeEvent: "PermissionRequest", installationID: staleID,
                    scopeFingerprint: hostHookReceiptTestScope)
                    == nil,
                "旧配置或断开后的迟到回调不能点亮当前 installation")

            guard let file = store.receiptFile(host: .codex, nativeEvent: "PermissionRequest")
            else {
                expect(false, "PermissionRequest 必须有回执路径")
                return
            }
            writeFixture("{broken json", to: file)
            expect(
                store.receiptEvidence(
                    host: .codex, nativeEvent: "PermissionRequest", installationID: currentID,
                    scopeFingerprint: hostHookReceiptTestScope)
                    == nil,
                "损坏 JSON 必须失败关闭")

            writeFixture(
                """
                {
                  "schema": 1,
                  "installation_id": "\(currentID.uuidString)",
                  "host": "claude-code",
                  "native_event": "PermissionRequest",
                  "semantic_event": "notification",
                  "timestamp": "2027-01-15T08:00:00Z",
                  "playback_result": "played"
                }
                """, to: file)
            expect(
                store.receiptEvidence(
                    host: .codex, nativeEvent: "PermissionRequest", installationID: currentID,
                    scopeFingerprint: hostHookReceiptTestScope)
                    == nil,
                "路径与内容宿主不匹配时不能形成 evidence")

            writeFixture(
                """
                {
                  "schema": 1,
                  "installation_id": "\(currentID.uuidString)",
                  "host": "codex",
                  "native_event": "Stop",
                  "semantic_event": "stop",
                  "timestamp": "2027-01-15T08:00:00Z",
                  "playback_result": "played"
                }
                """, to: file)
            expect(
                store.receiptEvidence(
                    host: .codex, nativeEvent: "PermissionRequest", installationID: currentID,
                    scopeFingerprint: hostHookReceiptTestScope)
                    == nil,
                "路径与内容原生/语义事件不匹配时不能形成 evidence")
        }
    }

    suite("HostHookReceiptStore：重连后的迟到旧代次不能覆盖当前稳定回执") {
        withTempDirectory { root in
            let store = HostHookReceiptStore(
                receiptsRoot: root.appendingPathComponent("receipts", isDirectory: true),
                locksRoot: root.appendingPathComponent("receipt-locks", isDirectory: true))
            let oldID = UUID(uuidString: "01010101-1111-4111-8111-111111111111")!
            let currentID = UUID(uuidString: "02020202-2222-4222-8222-222222222222")!
            let currentTimestamp = Date(timeIntervalSince1970: 1_800_000_030)
            let lateTimestamp = Date(timeIntervalSince1970: 1_800_000_999)
            guard
                case .success = store.activate(
                    host: .codex,
                    installationID: currentID,
                    scopeFingerprint: hostHookReceiptTestScope)
            else {
                expect(false, "测试前提：必须发布重连后的当前 installation")
                return
            }
            guard case .success = store.deactivate(host: .codex, installationID: oldID) else {
                expect(false, "旧 disconnect 的精确撤销应是安全 no-op")
                return
            }
            expect(
                store.currentInstallationID(host: .codex) == currentID,
                "迟到的旧 disconnect 不得撤销已经发布的新连接代次")
            let current = HostHookReceipt(
                installationID: currentID,
                host: .codex,
                nativeEvent: "Stop",
                semanticEvent: .stop,
                timestamp: currentTimestamp,
                playbackResult: .played)
            let lateOld = HostHookReceipt(
                installationID: oldID,
                host: .codex,
                nativeEvent: "Stop",
                semanticEvent: .stop,
                timestamp: lateTimestamp,
                playbackResult: .playbackFailed)

            expect(store.store(current) == .success(.written), "当前代次回执必须先成功落盘")
            expect(
                store.store(lateOld) == .failure(.staleInstallation),
                "时间更晚的旧进程回执也必须按 installation ID 拒绝")
            expect(
                store.receiptEvidence(
                    host: .codex, nativeEvent: "Stop", installationID: currentID,
                    scopeFingerprint: hostHookReceiptTestScope)
                    == HostReceiptEvidence(
                        bindingID: HostCapabilityCatalog.binding(
                            host: .codex, nativeEvent: "Stop")!.id,
                        installationID: currentID,
                        nativeEvent: "Stop",
                        event: .stop,
                        timestamp: currentTimestamp,
                        playbackResult: .played),
                "旧代次迟到后，稳定路径仍必须保留当前代次原回执")
        }
    }

    suite("HostHookReceiptStore：断开撤销代次后，迟到回执被拒绝且不能恢复 activation") {
        withTempDirectory { root in
            let store = HostHookReceiptStore(
                receiptsRoot: root.appendingPathComponent("receipts", isDirectory: true),
                locksRoot: root.appendingPathComponent("receipt-locks", isDirectory: true))
            let installationID = UUID(uuidString: "03030303-3333-4333-8333-333333333333")!
            guard
                case .success = store.activate(
                    host: .claudeCode,
                    installationID: installationID,
                    scopeFingerprint: hostHookReceiptTestScope),
                case .success = store.deactivate(
                    host: .claudeCode, installationID: installationID)
            else {
                expect(false, "测试前提：installation 必须能被发布并撤销")
                return
            }
            let late = HostHookReceipt(
                installationID: installationID,
                host: .claudeCode,
                nativeEvent: "Stop",
                semanticEvent: .stop,
                timestamp: Date(timeIntervalSince1970: 1_800_000_040),
                playbackResult: .played)

            expect(
                store.store(late) == .failure(.staleInstallation),
                "断开后的在途 hook 不得再写入稳定回执")
            expect(
                store.receiptEvidence(
                    host: .claudeCode, nativeEvent: "Stop", installationID: installationID,
                    scopeFingerprint: hostHookReceiptTestScope)
                    == nil,
                "迟到回执不得重新点亮已断开的 installation")
        }
    }

    suite("HostHookReceiptStore：历史按 surface 保留 20 条 / 30 天，断开保留且可显式清除") {
        withTempDirectory { root in
            let store = HostHookReceiptStore(
                receiptsRoot: root.appendingPathComponent("receipts", isDirectory: true),
                locksRoot: root.appendingPathComponent("receipt-locks", isDirectory: true))
            let installationID = UUID(uuidString: "04040404-4444-4444-8444-444444444444")!
            guard
                case .success = store.activate(
                    host: .workBuddy, installationID: installationID, scopeFingerprint: "v1")
            else {
                expect(false, "测试前提：WorkBuddy installation 必须发布")
                return
            }
            let base = Date(
                timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            for index in 0..<25 {
                let receipt = HostHookReceipt(
                    installationID: installationID,
                    host: .workBuddy,
                    nativeEvent: "UserPromptSubmit",
                    semanticEvent: .taskStart,
                    timestamp: base.addingTimeInterval(Double(index)),
                    playbackResult: .played)
                expect(store.store(receipt) == .success(.written), "第 \(index) 条回执必须可写")
            }

            let bounded = store.receiptHistory(host: .workBuddy, now: base)
            expect(
                bounded.count == HostHookReceiptStore.historyLimitPerSurface,
                "每个 surface 只保留最近 20 条，得到 \(bounded.count)")
            expect(
                bounded.first?.timestamp == base.addingTimeInterval(24),
                "历史 API 必须按事件时间倒序返回最近回执")

            guard
                case .success = store.deactivate(
                    host: .workBuddy, installationID: installationID)
            else {
                expect(false, "断开必须成功撤销 activation")
                return
            }
            expect(
                store.receiptHistory(host: .workBuddy, now: base).count
                    == HostHookReceiptStore.historyLimitPerSurface,
                "断开只撤销 activation，不得删除脱敏历史")

            let historyDirectory = store.historyRoot.appendingPathComponent(
                HostSurfaceID.workBuddy.rawValue, isDirectory: true)
            if let expired = try? FileManager.default.contentsOfDirectory(
                at: historyDirectory, includingPropertiesForKeys: nil
            ).first {
                try? FileManager.default.setAttributes(
                    [.modificationDate: base.addingTimeInterval(-31 * 24 * 60 * 60)],
                    ofItemAtPath: expired.path)
            } else {
                expect(false, "测试前提：历史目录必须含回执")
            }
            expect(
                store.receiptHistory(host: .workBuddy, now: base).count
                    == HostHookReceiptStore.historyLimitPerSurface - 1,
                "超过 30 天的历史必须在读取时失效")

            if case .failure(let error) = store.clearReceiptHistory(host: .workBuddy) {
                expect(false, "用户显式清除必须成功：\(error.description)")
            }
            expect(store.receiptHistory(host: .workBuddy, now: base).isEmpty, "清除后历史必须为空")
            expect(
                store.receiptFile(host: .workBuddy, nativeEvent: "UserPromptSubmit")
                    .map { FileManager.default.fileExists(atPath: $0.path) } == true,
                "清除历史不得删除 current 稳定回执")
        }
    }

    suite("HostHookReceiptStore：历史快照有界、目录 no-follow，且 20 条外损坏仍可见") {
        withTempDirectory { root in
            let store = HostHookReceiptStore(
                receiptsRoot: root.appendingPathComponent("receipts", isDirectory: true),
                locksRoot: root.appendingPathComponent("receipt-locks", isDirectory: true))
            let installationID = UUID(uuidString: "05050505-5555-4555-8555-555555555555")!
            let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            expect(
                hostHookVoidResultSucceeded(
                    store.activate(
                        host: .workBuddy,
                        installationID: installationID,
                        scopeFingerprint: "history-snapshot")),
                "测试前提：WorkBuddy installation 必须发布")
            for index in 0..<HostHookReceiptStore.historyLimitPerSurface {
                let receipt = HostHookReceipt(
                    installationID: installationID,
                    host: .workBuddy,
                    nativeEvent: "UserPromptSubmit",
                    semanticEvent: .taskStart,
                    timestamp: now.addingTimeInterval(-Double(index)),
                    playbackResult: .played)
                expect(store.store(receipt) == .success(.written), "第 \(index) 条回执必须可写")
            }
            let history = store.historyRoot.appendingPathComponent(
                HostSurfaceID.workBuddy.rawValue,
                isDirectory: true)
            writeFixture("{broken", to: history.appendingPathComponent("extra-broken.json"))
            let snapshot = store.receiptHistorySnapshot(host: .workBuddy, now: now)
            expect(
                snapshot.receipts.count == HostHookReceiptStore.historyLimitPerSurface
                    && snapshot.state == .damaged(skippedItemCount: 1),
                "20 条有效回执外的损坏项必须独立计数，不能被 retained limit 遮蔽")

            let externalStore = HostHookReceiptStore(
                receiptsRoot: root.appendingPathComponent("external/receipts", isDirectory: true),
                locksRoot: root.appendingPathComponent("external/locks", isDirectory: true),
                historyRoot: root.appendingPathComponent("external/history", isDirectory: true))
            expect(
                hostHookVoidResultSucceeded(
                    externalStore.activate(
                        host: .workBuddy,
                        installationID: installationID,
                        scopeFingerprint: "external")),
                "测试前提：外部 fixture installation 必须发布")
            let externalReceipt = HostHookReceipt(
                installationID: installationID,
                host: .workBuddy,
                nativeEvent: "UserPromptSubmit",
                semanticEvent: .taskStart,
                timestamp: now,
                playbackResult: .played)
            expect(
                externalStore.store(externalReceipt) == .success(.written),
                "测试前提：外部目录必须含合法形状 receipt")

            let symlinkHistoryRoot = root.appendingPathComponent(
                "symlink-owner/history",
                isDirectory: true)
            try? FileManager.default.createDirectory(
                at: symlinkHistoryRoot,
                withIntermediateDirectories: true)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: symlinkHistoryRoot.path)
            let symlinkSurface = symlinkHistoryRoot.appendingPathComponent(
                HostSurfaceID.workBuddy.rawValue,
                isDirectory: true)
            let externalSurface = externalStore.historyRoot.appendingPathComponent(
                HostSurfaceID.workBuddy.rawValue,
                isDirectory: true)
            do {
                try FileManager.default.createSymbolicLink(
                    at: symlinkSurface,
                    withDestinationURL: externalSurface)
            } catch {
                expect(false, "测试前提：surface symlink 必须创建：\(error)")
            }
            let symlinkStore = HostHookReceiptStore(
                receiptsRoot: root.appendingPathComponent("symlink-owner/receipts"),
                locksRoot: root.appendingPathComponent("symlink-owner/locks"),
                historyRoot: symlinkHistoryRoot)
            let symlinkSnapshot = symlinkStore.receiptHistorySnapshot(host: .workBuddy, now: now)
            expect(
                symlinkSnapshot.receipts.isEmpty
                    && symlinkSnapshot.state == .damaged(skippedItemCount: 1),
                "surface 目录 symlink 必须失败关闭且可见为 damaged，不得投影外部合法 JSON")

            let symlinkRoot = root.appendingPathComponent("history-root-link", isDirectory: true)
            do {
                try FileManager.default.createSymbolicLink(
                    at: symlinkRoot,
                    withDestinationURL: externalStore.historyRoot)
            } catch {
                expect(false, "测试前提：history root symlink 必须创建：\(error)")
            }
            let symlinkRootStore = HostHookReceiptStore(
                receiptsRoot: root.appendingPathComponent("root-link-owner/receipts"),
                locksRoot: root.appendingPathComponent("root-link-owner/locks"),
                historyRoot: symlinkRoot)
            let symlinkRootSnapshot = symlinkRootStore.receiptHistorySnapshot(
                host: .workBuddy,
                now: now)
            expect(
                symlinkRootSnapshot.receipts.isEmpty
                    && symlinkRootSnapshot.state == .damaged(skippedItemCount: 1),
                "historyRoot 本身是 symlink 时必须 no-follow 失败关闭，不得穿透到外部 Surface")

            let hiddenFloodRoot = root.appendingPathComponent(
                "hidden-flood/history/\(HostSurfaceID.workBuddy.rawValue)",
                isDirectory: true)
            for index in 0...HostHookReceiptStore.historyDirectoryEntryLimit {
                writeFixture("hidden", to: hiddenFloodRoot.appendingPathComponent(".\(index)"))
            }
            let hiddenFloodStore = HostHookReceiptStore(
                receiptsRoot: root.appendingPathComponent("hidden-flood/receipts"),
                locksRoot: root.appendingPathComponent("hidden-flood/locks"),
                historyRoot: hiddenFloodRoot.deletingLastPathComponent())
            makeHistoryRootPrivate(hiddenFloodStore)
            let hiddenFloodSnapshot = hiddenFloodStore.receiptHistorySnapshot(
                host: .workBuddy,
                now: now)
            expect(
                hiddenFloodSnapshot.receipts.isEmpty
                    && hiddenFloodSnapshot.state
                        == .damaged(
                            skippedItemCount: HostHookReceiptStore.historyDirectoryEntryLimit + 1),
                "隐藏项也必须计入 128 项扫描上限，洪泛只能产生有界 damaged 快照")
        }
    }

    suite("HostHookReceiptStore：批量历史清理中途失败会恢复已 staging 的 Surface") {
        withTempDirectory { root in
            let store = HostHookReceiptStore(
                receiptsRoot: root.appendingPathComponent("receipts", isDirectory: true),
                locksRoot: root.appendingPathComponent("receipt-locks", isDirectory: true))
            for host in HostID.productVisibleCases {
                let fixture = store.historyRoot
                    .appendingPathComponent(host.surfaceID.rawValue, isDirectory: true)
                    .appendingPathComponent("keep.json")
                writeFixture("keep-\(host.rawValue)", to: fixture)
            }
            makeHistoryRootPrivate(store)

            let failed = store.clearReceiptHistory(
                hosts: HostID.productVisibleCases,
                beforeStaging: { host in
                    if host == .codex { throw CocoaError(.fileWriteUnknown) }
                })
            expect(
                !hostHookVoidResultSucceeded(failed),
                "第二个 Surface 前注入失败必须返回 failure")
            for host in HostID.productVisibleCases {
                let fixture = store.historyRoot
                    .appendingPathComponent(host.surfaceID.rawValue, isDirectory: true)
                    .appendingPathComponent("keep.json")
                expect(
                    (try? String(contentsOf: fixture, encoding: .utf8))
                        == "keep-\(host.rawValue)",
                    "失败后 \(host.rawValue) 历史必须逐字恢复，不能半清")
            }

            expect(
                hostHookVoidResultSucceeded(
                    store.clearReceiptHistory(hosts: HostID.productVisibleCases)),
                "无注入失败时批量清理必须成功")
            expect(
                HostID.productVisibleCases.allSatisfy {
                    !FileManager.default.fileExists(
                        atPath: store.historyRoot
                            .appendingPathComponent($0.surfaceID.rawValue, isDirectory: true).path)
                },
                "成功批量清理必须移除每个产品 Surface 的历史")
        }
    }

    suite("HostHookReceiptStore：root 替换失败关闭，提交后删除失败保留可重试 tombstone") {
        withTempDirectory { root in
            let rootSwapStore = HostHookReceiptStore(
                receiptsRoot: root.appendingPathComponent("swap/receipts", isDirectory: true),
                locksRoot: root.appendingPathComponent("swap/receipt-locks", isDirectory: true))
            for host in HostID.productVisibleCases {
                writeFixture(
                    "swap-\(host.rawValue)",
                    to: rootSwapStore.historyRoot
                        .appendingPathComponent(host.surfaceID.rawValue, isDirectory: true)
                        .appendingPathComponent("keep.json"))
            }
            makeHistoryRootPrivate(rootSwapStore)
            let originalRoot = root.appendingPathComponent("swap/original-history")
            var swappedRoot = false
            let swapResult = rootSwapStore.clearReceiptHistory(
                hosts: HostID.productVisibleCases,
                beforeStaging: { _ in
                    guard !swappedRoot else { return }
                    swappedRoot = true
                    try FileManager.default.moveItem(
                        at: rootSwapStore.historyRoot,
                        to: originalRoot)
                    try FileManager.default.createDirectory(
                        at: rootSwapStore.historyRoot,
                        withIntermediateDirectories: true)
                    writeFixture(
                        "replacement-must-survive",
                        to: rootSwapStore.historyRoot.appendingPathComponent("replacement.txt"))
                })
            expect(
                !hostHookVoidResultSucceeded(swapResult),
                "已打开 historyRoot 的公开路径被替换时必须在 commit 前失败关闭")
            expect(
                fixtureText(
                    rootSwapStore.historyRoot.appendingPathComponent("replacement.txt"))
                    == "replacement-must-survive",
                "descriptor-bound 清理不得删除替换后的 historyRoot 内容")
            for host in HostID.productVisibleCases {
                expect(
                    fixtureText(
                        originalRoot
                            .appendingPathComponent(host.surfaceID.rawValue, isDirectory: true)
                            .appendingPathComponent("keep.json")) == "swap-\(host.rawValue)",
                    "root swap 失败后原 descriptor 下的 \(host.rawValue) 历史必须保留")
            }

            let cleanupStore = HostHookReceiptStore(
                receiptsRoot: root.appendingPathComponent("cleanup/receipts", isDirectory: true),
                locksRoot: root.appendingPathComponent(
                    "cleanup/receipt-locks",
                    isDirectory: true))
            for host in HostID.productVisibleCases {
                writeFixture(
                    "cleanup-\(host.rawValue)",
                    to: cleanupStore.historyRoot
                        .appendingPathComponent(host.surfaceID.rawValue, isDirectory: true)
                        .appendingPathComponent("keep.json"))
            }
            makeHistoryRootPrivate(cleanupStore)
            let committed = cleanupStore.clearReceiptHistory(
                hosts: HostID.productVisibleCases,
                beforeCommittedCleanup: { removalIndex in
                    if removalIndex == 1 { throw CocoaError(.fileWriteUnknown) }
                })
            expect(
                hostHookVoidResultSucceeded(committed),
                "全部 Surface rename 已提交后，部分 tombstone 回收失败不得伪报可回滚 failure")
            expect(
                HostID.productVisibleCases.allSatisfy {
                    !FileManager.default.fileExists(
                        atPath: cleanupStore.historyRoot
                            .appendingPathComponent($0.surfaceID.rawValue, isDirectory: true).path)
                },
                "提交后的 live Surface 必须全部消失，不能暴露部分清除")
            let retainedTombstones = (try? FileManager.default.contentsOfDirectory(
                atPath: cleanupStore.historyRoot.path))?.filter { $0.hasPrefix(".clear-") } ?? []
            expect(
                retainedTombstones.count == 1
                    && UUID(
                        uuidString: String(retainedTombstones[0].dropFirst(".clear-".count))) != nil,
                "删除中途失败必须只留下 UUID 命名的私有可重试 tombstone")

            expect(
                hostHookVoidResultSucceeded(
                    cleanupStore.clearReceiptHistory(hosts: HostID.productVisibleCases)),
                "下一次清理必须先重试已提交 tombstone，再幂等返回成功")
            let remainingTombstones = (try? FileManager.default.contentsOfDirectory(
                atPath: cleanupStore.historyRoot.path))?.filter { $0.hasPrefix(".clear-") } ?? []
            expect(remainingTombstones.isEmpty, "重试必须回收上次部分删除留下的 tombstone")

            let recoveryStore = HostHookReceiptStore(
                receiptsRoot: root.appendingPathComponent("recovery/receipts", isDirectory: true),
                locksRoot: root.appendingPathComponent(
                    "recovery/receipt-locks",
                    isDirectory: true))
            let interruptedName = ".staging-\(UUID().uuidString.lowercased())"
            writeFixture(
                "interrupted-workbuddy",
                to: recoveryStore.historyRoot
                    .appendingPathComponent(interruptedName, isDirectory: true)
                    .appendingPathComponent(
                        HostSurfaceID.workBuddy.rawValue,
                        isDirectory: true)
                    .appendingPathComponent("keep.json"))
            writeFixture(
                "live-codex",
                to: recoveryStore.historyRoot
                    .appendingPathComponent(HostSurfaceID.codex.rawValue, isDirectory: true)
                    .appendingPathComponent("keep.json"))
            makeHistoryRootPrivate(recoveryStore)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: recoveryStore.historyRoot
                    .appendingPathComponent(interruptedName, isDirectory: true).path)
            let recoveredThenStopped = recoveryStore.clearReceiptHistory(
                hosts: [.codex],
                beforeStaging: { _ in throw CocoaError(.fileWriteUnknown) })
            expect(
                !hostHookVoidResultSucceeded(recoveredThenStopped),
                "遗留 staging 恢复后、当前事务 commit 前注入失败必须返回 failure")
            expect(
                fixtureText(
                    recoveryStore.historyRoot
                        .appendingPathComponent(
                            HostSurfaceID.workBuddy.rawValue,
                            isDirectory: true)
                        .appendingPathComponent("keep.json")) == "interrupted-workbuddy"
                    && fixtureText(
                        recoveryStore.historyRoot
                            .appendingPathComponent(
                                HostSurfaceID.codex.rawValue,
                                isDirectory: true)
                            .appendingPathComponent("keep.json")) == "live-codex",
                "下次 lock owner 必须先回滚 `.staging-*`，且当前失败仍保留全部 live 历史")
            expect(
                !FileManager.default.fileExists(
                    atPath: recoveryStore.historyRoot
                        .appendingPathComponent(interruptedName, isDirectory: true).path),
                "成功恢复后不得遗留未提交 staging marker")

            let otherSurfaceLock = FileLock(
                path: recoveryStore.installationLockFile(host: .workBuddy).path)
            expect(otherSurfaceLock.attemptLock() == .acquired, "测试前提：WorkBuddy lock 必须占用")
            let disjointClear = recoveryStore.clearReceiptHistory(hosts: [.codex])
            expect(
                hostHookVoidResultFailure(disjointClear) == .lockBusy,
                "即使只清 Codex，也必须持有全产品锁域，不能并发扫描 WorkBuddy staging")
            otherSurfaceLock.unlock()
        }
    }
}

private func hostHookVoidResultSucceeded<Failure>(_ result: Result<Void, Failure>) -> Bool {
    if case .success = result { return true }
    return false
}

private func hostHookVoidResultFailure<Failure>(_ result: Result<Void, Failure>) -> Failure? {
    if case .failure(let failure) = result { return failure }
    return nil
}

private func fixtureText(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
}

private func makeHistoryRootPrivate(_ store: HostHookReceiptStore) {
    try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: store.historyRoot.path)
}
