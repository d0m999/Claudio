import ClaudioCore
import Foundation

@MainActor
func runHostHookReceiptSuites() {
    suite("HostHookReceipt：最小脱敏 JSON 可形成当前 installation 的真实 activation evidence") {
        withTempDirectory { root in
            let store = HostHookReceiptStore(
                receiptsRoot: root.appendingPathComponent("receipts", isDirectory: true),
                locksRoot: root.appendingPathComponent("receipt-locks", isDirectory: true))
            let installationID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
            let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
            guard case .success = store.activate(host: .codex, installationID: installationID)
            else {
                expect(false, "测试前提：必须先发布当前 Codex installation")
                return
            }
            let markerPermissions = (try? FileManager.default.attributesOfItem(
                atPath: store.installationFile(host: .codex).path))?[.posixPermissions] as? NSNumber
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
                    "schema", "installation_id", "host", "native_event", "semantic_event",
                    "timestamp", "playback_result",
                ],
                "回执 schema 必须是封闭白名单，禁止 prompt/content/project/session/audio path 字段")
            expect(object["schema"] as? Int == 1, "首版回执 schema 必须固定为 1")
            expect(object["host"] as? String == "codex", "宿主必须使用稳定 HostID token")
            expect(
                object["semantic_event"] as? String == "notification",
                "语义事件必须保存声音包稳定键")
            expect(
                !String(decoding: data, as: UTF8.self).contains(root.path),
                "脱敏播放结果与整份回执都不得泄露任何绝对路径")

            let permissions = (try? FileManager.default.attributesOfItem(
                atPath: receiptFile.path))?[.posixPermissions] as? NSNumber
            expect(
                permissions.map { $0.intValue & 0o777 } == 0o600,
                "最终回执权限必须是 0600，got \(permissions?.stringValue ?? "<missing>")")
            expect(
                store.activationEvidence(
                    host: .codex, nativeEvent: "PermissionRequest",
                    installationID: installationID)
                    == HostReceiptEvidence(
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
            guard case .success = store.activate(
                host: .claudeCode, installationID: installationID)
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
            guard case .success = unwritableStore.activate(
                host: .claudeCode, installationID: installationID)
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
            guard case .success = lockFailureStore.activate(
                host: .claudeCode, installationID: installationID)
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

    suite("HostHookReceiptStore：损坏、旧代次、宿主或事件错位均不是 activation evidence") {
        withTempDirectory { root in
            let store = HostHookReceiptStore(
                receiptsRoot: root.appendingPathComponent("receipts", isDirectory: true),
                locksRoot: root.appendingPathComponent("receipt-locks", isDirectory: true))
            let currentID = UUID(uuidString: "12345678-1234-4234-8234-123456789abc")!
            let staleID = UUID(uuidString: "87654321-4321-4321-8321-cba987654321")!
            guard case .success = store.activate(host: .codex, installationID: currentID) else {
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
                store.activationEvidence(
                    host: .codex, nativeEvent: "PermissionRequest", installationID: currentID)
                    != nil,
                "播放失败不抹掉 hook 已真实触发这一 activation 事实")
            expect(
                store.activationEvidence(
                    host: .codex, nativeEvent: "PermissionRequest", installationID: staleID)
                    == nil,
                "旧配置或断开后的迟到回调不能点亮当前 installation")

            guard let file = store.receiptFile(host: .codex, nativeEvent: "PermissionRequest") else {
                expect(false, "PermissionRequest 必须有回执路径")
                return
            }
            writeFixture("{broken json", to: file)
            expect(
                store.activationEvidence(
                    host: .codex, nativeEvent: "PermissionRequest", installationID: currentID)
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
                store.activationEvidence(
                    host: .codex, nativeEvent: "PermissionRequest", installationID: currentID)
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
                store.activationEvidence(
                    host: .codex, nativeEvent: "PermissionRequest", installationID: currentID)
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
            guard case .success = store.activate(host: .codex, installationID: currentID) else {
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
                store.activationEvidence(
                    host: .codex, nativeEvent: "Stop", installationID: currentID)
                    == HostReceiptEvidence(
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
            guard case .success = store.activate(host: .claudeCode, installationID: installationID),
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
                store.activationEvidence(
                    host: .claudeCode, nativeEvent: "Stop", installationID: installationID)
                    == nil,
                "迟到回执不得重新点亮已断开的 installation")
        }
    }
}
