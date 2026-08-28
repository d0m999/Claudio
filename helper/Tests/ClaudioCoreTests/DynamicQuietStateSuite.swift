import ClaudioCore
import Darwin
import Foundation

@MainActor
func runDynamicQuietStateSuites() {
    suite("Dynamic Quiet publication：五字段最小快照、私有权限与组合原因判定") {
        withTempDirectory { root in
            let paths = dynamicQuietTestPaths(root)
            let now = Date(timeIntervalSince1970: 10_000)
            let publisher = DynamicQuietSnapshotPublisher(
                snapshotFile: paths.snapshot,
                revisionStateFile: paths.revision)
            let published = publisher.publish(focusActive: true, now: now, lifetime: 12)
            guard case .success(let snapshot) = published else {
                expect(false, "有效快照必须发布成功：\(published)")
                return
            }

            let object =
                (try? JSONSerialization.jsonObject(
                    with: Data(contentsOf: paths.snapshot))) as? [String: Any]
            expect(
                Set(object.map { Array($0.keys) } ?? [])
                    == ["schema", "revision", "expires_at", "focus_active", "calendar_busy"],
                "快照只能含 schema/revision/expiry/两个布尔原因")
            let serialized =
                String(
                    data: (try? Data(contentsOf: paths.snapshot)) ?? Data(), encoding: .utf8) ?? ""
            for forbidden in [
                "focus_name", "host", "path", "calendar_title", "calendar_id", "title",
                "location", "url", "attendee", "notes",
            ] {
                expect(!serialized.contains(forbidden), "快照不得包含私人字段 \(forbidden)")
            }
            expect(
                snapshot.schema == 2 && snapshot.focusActive && !snapshot.calendarBusy,
                "发布结果必须是 Focus-only v2")
            expect(fileMode(paths.directory) == 0o700, "动态静默目录必须是 0700")
            expect(fileMode(paths.snapshot) == 0o600, "动态静默快照必须从发布起就是 0600")
            expect(
                dynamicQuietDecision(environment: paths.environment(now: now)) == .quiet,
                "有效未过期 Focus 快照必须抑制 automatic playback")
            expect(fileMode(paths.revision) == 0o600, "helper revision 水位必须是 0600")

            guard
                case .success(let calendarOnly) = publisher.publish(
                    focusActive: false, calendarBusy: true, now: now, lifetime: 12)
            else {
                expect(false, "Calendar-only 原因快照必须发布成功")
                return
            }
            expect(calendarOnly.revision > snapshot.revision, "每次 publication revision 必须递增")
            expect(
                dynamicQuietDecision(environment: paths.environment(now: now)) == .quiet,
                "有效 Calendar busy 必须抑制 automatic playback")

            guard
                case .success = publisher.publish(
                    focusActive: false, calendarBusy: false, now: now, lifetime: 12)
            else {
                expect(false, "关闭组合原因快照必须发布成功")
                return
            }
            expect(
                dynamicQuietDecision(environment: paths.environment(now: now)) == .inactive,
                "两个 false 原因必须恢复正常 automatic playback")
        }
    }

    suite("Dynamic Quiet reader：损坏、额外字段、过期与异常远期 expiry 全部 fail safe") {
        withTempDirectory { root in
            let paths = dynamicQuietTestPaths(root)
            let now = Date(timeIntervalSince1970: 20_000)
            writeFixture("{broken", to: paths.snapshot)
            expect(
                dynamicQuietDecision(environment: paths.environment(now: now))
                    == .rejected(.malformed),
                "损坏 JSON 必须拒绝")

            writeFixture(
                #"{"schema":2,"revision":1,"expires_at":20012,"focus_active":true,"calendar_busy":false,"focus_name":"Private"}"#,
                to: paths.snapshot)
            expect(
                dynamicQuietDecision(environment: paths.environment(now: now))
                    == .rejected(.malformed),
                "任何额外私人字段都必须因精确 key set 被拒绝")

            writeFixture(
                #"{"schema":2,"revision":2,"expires_at":19999,"focus_active":true,"calendar_busy":false}"#,
                to: paths.snapshot)
            expect(
                dynamicQuietDecision(environment: paths.environment(now: now))
                    == .rejected(.expired),
                "过期快照不得继续静默")

            writeFixture(
                #"{"schema":2,"revision":3,"expires_at":20100,"focus_active":true,"calendar_busy":false}"#,
                to: paths.snapshot)
            expect(
                dynamicQuietDecision(environment: paths.environment(now: now))
                    == .rejected(.expiryTooDistant),
                "超出短 TTL 上限不得制造无限静默")
        }
    }

    suite("Dynamic Quiet reader：symlink、oversize、revision 倒退与读取失败全部 fail safe") {
        withTempDirectory { root in
            let paths = dynamicQuietTestPaths(root)
            let now = Date(timeIntervalSince1970: 30_000)
            let publisher = DynamicQuietSnapshotPublisher(
                snapshotFile: paths.snapshot,
                revisionStateFile: paths.revision)
            guard case .success = publisher.publish(focusActive: true, now: now) else {
                expect(false, "fixture publication 必须成功")
                return
            }
            let firstData = try! Data(contentsOf: paths.snapshot)
            expect(
                dynamicQuietDecision(environment: paths.environment(now: now)) == .quiet,
                "首个快照必须建立 accepted revision")
            guard case .success = publisher.publish(focusActive: true, now: now) else {
                expect(false, "第二代 fixture publication 必须成功")
                return
            }
            expect(
                dynamicQuietDecision(environment: paths.environment(now: now)) == .quiet,
                "第二代快照必须推进 accepted revision")
            try! firstData.write(to: paths.snapshot, options: .atomic)
            expect(
                dynamicQuietDecision(environment: paths.environment(now: now))
                    == .rejected(.revisionRollback),
                "旧快照回放必须被跨进程 revision 水位拒绝")

            try! FileManager.default.removeItem(at: paths.snapshot)
            let target = root.appendingPathComponent("outside.json")
            try! firstData.write(to: target)
            try! FileManager.default.createSymbolicLink(
                atPath: paths.snapshot.path, withDestinationPath: target.path)
            expect(
                dynamicQuietDecision(environment: paths.environment(now: now))
                    == .rejected(.notRegularFile),
                "snapshot symlink 必须 O_NOFOLLOW 拒绝")

            try! FileManager.default.removeItem(at: paths.snapshot)
            writeFixture(
                String(repeating: "x", count: maximumDynamicQuietSnapshotBytes + 1),
                to: paths.snapshot)
            expect(
                dynamicQuietDecision(environment: paths.environment(now: now))
                    == .rejected(.oversize),
                "oversize snapshot 必须有界拒绝")

            try! FileManager.default.removeItem(at: paths.snapshot)
            try! FileManager.default.createDirectory(
                at: paths.snapshot, withIntermediateDirectories: false)
            expect(
                dynamicQuietDecision(environment: paths.environment(now: now))
                    == .rejected(.notRegularFile),
                "目录等读取失败节点必须 fail safe")
        }
    }

    suite("Dynamic Quiet publisher：写失败不发布假成功，旧 true 也受短 TTL 约束") {
        withTempDirectory { root in
            let paths = dynamicQuietTestPaths(root)
            let now = Date(timeIntervalSince1970: 40_000)
            let publisher = DynamicQuietSnapshotPublisher(
                snapshotFile: paths.snapshot,
                revisionStateFile: paths.revision)
            guard
                case .success(let first) = publisher.publish(
                    focusActive: true, now: now, lifetime: 5)
            else {
                expect(false, "首代 fixture 必须发布")
                return
            }
            let oldData = try! Data(contentsOf: paths.snapshot)
            try! FileManager.default.removeItem(at: paths.snapshot)
            try! FileManager.default.createDirectory(
                at: paths.snapshot, withIntermediateDirectories: false)
            let failed = publisher.publish(focusActive: false, now: now, lifetime: 5)
            expect(failed == .failure(.writeFailed), "写失败必须显式返回失败")
            expect(
                publisher.publish(focusActive: false, now: now, lifetime: 0)
                    == .failure(.invalidLifetime), "无效 TTL 不得发布")
            try! FileManager.default.removeItem(at: paths.snapshot)
            try! oldData.write(to: paths.snapshot)
            expect(
                dynamicQuietDecision(
                    environment: paths.environment(now: now.addingTimeInterval(6)))
                    == .rejected(.expired),
                "即使清理 publication 失败，旧 true 快照也必须及时过期")
            expect(first.expiresAtEpochSeconds == 40_005, "fixture 必须验证精确短 TTL")
        }
    }

    suite("Dynamic Quiet reader：目录、schema 与 revision 水位故障都恢复正常播放") {
        withTempDirectory { root in
            let now = Date(timeIntervalSince1970: 50_000)
            let outside = root.appendingPathComponent("outside", isDirectory: true)
            let outsidePaths = dynamicQuietTestPaths(outside)
            let publisher = DynamicQuietSnapshotPublisher(
                snapshotFile: outsidePaths.snapshot,
                revisionStateFile: outsidePaths.revision)
            guard case .success(let snapshot) = publisher.publish(focusActive: true, now: now)
            else {
                expect(false, "测试快照必须发布成功")
                return
            }
            let linkedDirectory = root.appendingPathComponent("linked", isDirectory: true)
            try! FileManager.default.createSymbolicLink(
                atPath: linkedDirectory.path,
                withDestinationPath: outsidePaths.directory.path)
            let linkedEnvironment = DynamicQuietReadEnvironment(
                snapshotFile: linkedDirectory.appendingPathComponent("snapshot.json"),
                revisionStateFile: linkedDirectory.appendingPathComponent(
                    "accepted-revision.state"),
                lockFile: linkedDirectory.appendingPathComponent("reader.lock"),
                now: { now })
            expect(
                dynamicQuietDecision(environment: linkedEnvironment)
                    == .rejected(.unsafeDirectory),
                "snapshot 路径含用户 symlink 目录时必须拒绝")
            writeFixture(
                #"{"schema":3,"revision":\#(snapshot.revision + 1),"expires_at":50012,"focus_active":true,"calendar_busy":false}"#,
                to: outsidePaths.snapshot)
            expect(
                dynamicQuietDecision(environment: outsidePaths.environment(now: now))
                    == .rejected(.wrongSchema),
                "未知 snapshot schema 必须拒绝")

            writeFixture("broken", to: outsidePaths.revision)
            guard case .success = publisher.publish(focusActive: true, now: now) else {
                expect(false, "损坏水位场景的 snapshot 必须仍可发布")
                return
            }
            expect(
                dynamicQuietDecision(environment: outsidePaths.environment(now: now))
                    == .rejected(.revisionStateInvalid),
                "损坏 revision 水位不得被当作 revision 0")

            try! FileManager.default.removeItem(at: outsidePaths.revision)
            try! FileManager.default.setAttributes(
                [.posixPermissions: 0], ofItemAtPath: outsidePaths.snapshot.path)
            expect(
                dynamicQuietDecision(environment: outsidePaths.environment(now: now))
                    == .rejected(.unreadable),
                "不可读 regular snapshot 必须 fail safe")
            try! FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: outsidePaths.snapshot.path)
        }
    }

    suite("Dynamic Quiet reader：水位写失败、锁争用与锁系统错误都不静默") {
        withTempDirectory { root in
            let paths = dynamicQuietTestPaths(root)
            let now = Date(timeIntervalSince1970: 60_000)
            let publisher = DynamicQuietSnapshotPublisher(
                snapshotFile: paths.snapshot,
                revisionStateFile: paths.revision)
            guard case .success = publisher.publish(focusActive: true, now: now) else {
                expect(false, "测试快照必须发布成功")
                return
            }

            let failedWatermarkEnvironment = DynamicQuietReadEnvironment(
                snapshotFile: paths.snapshot,
                revisionStateFile: paths.revision,
                lockFile: paths.lock,
                now: { now },
                publishRevisionState: { _, _ in false })
            expect(
                dynamicQuietDecision(environment: failedWatermarkEnvironment)
                    == .rejected(.revisionStateWriteFailed),
                "无法原子推进 revision 水位时不得返回 quiet")

            let heldLock = FileLock(path: paths.lock.path)
            expect(heldLock.attemptLock() == .acquired, "测试必须先持有 Dynamic Quiet 锁")
            expect(
                dynamicQuietDecision(environment: paths.environment(now: now))
                    == .rejected(.lockBusy),
                "锁争用必须非阻塞并恢复正常播放")
            heldLock.unlock()

            let blockingParent = root.appendingPathComponent("lock-parent")
            writeFixture("not a directory", to: blockingParent)
            let brokenLockEnvironment = DynamicQuietReadEnvironment(
                snapshotFile: paths.snapshot,
                revisionStateFile: paths.revision,
                lockFile: blockingParent.appendingPathComponent("reader.lock"),
                now: { now })
            expect(
                dynamicQuietDecision(environment: brokenLockEnvironment)
                    == .rejected(.lockFailed),
                "真实 lock filesystem 错误不得伪装成争用或 quiet")
        }
    }
}

private struct DynamicQuietTestPaths {
    let directory: URL
    let snapshot: URL
    let revision: URL
    let lock: URL

    func environment(now: Date) -> DynamicQuietReadEnvironment {
        DynamicQuietReadEnvironment(
            snapshotFile: snapshot,
            revisionStateFile: revision,
            lockFile: lock,
            now: { now })
    }
}

private func dynamicQuietTestPaths(_ root: URL) -> DynamicQuietTestPaths {
    let paths = DynamicQuietPaths(rootDirectory: root)
    return DynamicQuietTestPaths(
        directory: paths.directory,
        snapshot: paths.snapshotFile,
        revision: paths.revisionStateFile,
        lock: paths.lockFile)
}

private func fileMode(_ url: URL) -> mode_t? {
    var status = stat()
    guard lstat(url.path, &status) == 0 else { return nil }
    return status.st_mode & 0o777
}
