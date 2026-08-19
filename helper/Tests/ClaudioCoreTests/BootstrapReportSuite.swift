import ClaudioCore
import Darwin
import Dispatch
import Foundation

private enum InjectedBootstrapInterruption: Error {
    case stop
}

@MainActor
private func bootstrapEnvironment(
    root: URL,
    executablePath: URL? = nil,
    afterJournal: @escaping @Sendable () throws -> Void = {},
    afterReport: @escaping @Sendable () throws -> Void = {}
) -> SetupEnvironment {
    SetupEnvironment(
        executablePath: executablePath ?? root.appendingPathComponent("bin/claudio"),
        claudioBinaryDestination: root.appendingPathComponent("bin/claudio"),
        userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true),
        configFile: root.appendingPathComponent("config.json"),
        settingsFile: root.appendingPathComponent("settings.json"),
        configLockFile: root.appendingPathComponent("config.lock"),
        settingsLockFile: root.appendingPathComponent("settings.lock"),
        packsLockFile: root.appendingPathComponent("packs.lock"),
        afterBootstrapJournalPersisted: afterJournal,
        afterBootstrapReportPublished: afterReport)
}

private func publishHealthyBootstrapRuntime(at root: URL) {
    let helper = root.appendingPathComponent("bin/claudio")
    writeBootstrapFixture("helper", to: helper)
    try! FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let pack = root.appendingPathComponent("packs/ready-pack", isDirectory: true)
    writeBootstrapFixture(
        #"{"id":"ready-pack","events":{"stop":"stop.mp3"}}"#,
        to: pack.appendingPathComponent("manifest.json"))
    writeBootstrapFixture("audio", to: pack.appendingPathComponent("stop.mp3"))
    writeBootstrapFixture(
        #"{"selected_pack":"ready-pack","events":{}}"#,
        to: root.appendingPathComponent("config.json"))
}

private func writeBootstrapFixture(_ contents: String, to url: URL) {
    try! FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(contents.utf8).write(to: url)
}

@MainActor
func runBootstrapReportSuites() {
    suite("BootstrapReportStore：0600/0700、纯失败合并、不可逆记录保留与确认删除") {
        withTempDirectory { root in
            let directory = root.appendingPathComponent("reports", isDirectory: true)
            let store = BootstrapReportStore(directory: directory)
            let first = try! store.append(events: [.failure(code: "packs_lock_busy")])
            let merged = try! store.append(events: [.failure(code: "packs_lock_busy")])
            expect(first?.id == merged?.id, "相同纯失败必须按语义 fingerprint 合并")
            expect(merged?.occurrenceCount == 2, "合并后必须累计 occurrenceCount")

            let salvage = try! store.append(events: [
                .packSalvaged(packID: "user-pack", movedTo: "/private/salvage")
            ])
            let augmented = try! store.appendFailure(
                code: "host_hook_install_failure",
                preserving: salvage!.events)
            let records = try! store.records()
            expect(records.count == 2, "不可逆搬移记录不得覆盖纯失败记录")
            expect(
                augmented?.id == salvage?.id
                    && augmented?.events == [
                        .failure(code: "host_hook_install_failure"),
                        .packSalvaged(packID: "user-pack", movedTo: "/private/salvage"),
                    ],
                "后续 hook 失败必须扩展原记录且完整保留搬移事实")
            expect(
                bootstrapPermissions(directory) == 0o700,
                "bootstrap-reports 目录必须是 0700")
            for record in records {
                let file = directory.appendingPathComponent("\(record.id.uuidString).json")
                expect(bootstrapPermissions(file) == 0o600, "每条 report 必须是 0600")
            }

            try! store.acknowledge(augmented!.id)
            expect(
                (try! store.records()).map(\.id) == [merged!.id],
                "只有确认动作成功删除的记录才能从队列消失")
        }
    }

    suite("BootstrapReportStore：32 条上限、损坏文件与 symlink 都失败关闭") {
        withTempDirectory { root in
            let directory = root.appendingPathComponent("reports", isDirectory: true)
            let store = BootstrapReportStore(directory: directory)
            for index in 0..<BootstrapReportStore.maximumPendingRecords {
                _ = try! store.append(events: [
                    .packSalvaged(packID: "pack-\(index)", movedTo: "/private/\(index)")
                ])
            }
            do {
                try store.ensureCapacity()
                expect(false, "满 32 条时必须拒绝新的 bootstrap 修改")
            } catch let error as BootstrapReportStoreError {
                expect(error == .queueFull, "队列满必须保留 typed queueFull，got \(error)")
            } catch {
                expect(false, "队列满必须保留 BootstrapReportStoreError，got \(error)")
            }

            let record = try! store.records()[0]
            let recordURL = directory.appendingPathComponent("\(record.id.uuidString).json")
            try! FileManager.default.removeItem(at: recordURL)
            try! FileManager.default.createSymbolicLink(
                at: recordURL, withDestinationURL: root.appendingPathComponent("outside"))
            do {
                try store.acknowledge(record.id)
                expect(false, "确认不得跟随 symlink 删除外部目标")
            } catch let error as BootstrapReportStoreError {
                expect(
                    error == .unsafeRecord(path: recordURL.path),
                    "symlink 确认必须失败关闭，got \(error)")
            } catch {
                expect(false, "symlink 确认必须保留 typed error，got \(error)")
            }
        }
    }

    suite("bootstrap journal：中断后按实际磁盘恢复 helper、包和选包事实") {
        withTempDirectory { root in
            let interrupted = bootstrapEnvironment(root: root) {
                publishHealthyBootstrapRuntime(at: root)
                throw InjectedBootstrapInterruption.stop
            }
            guard case .failed(.reportingUnavailable, _) =
                performSharedRuntimeBootstrapExecution(environment: interrupted)
            else {
                expect(false, "注入的 journal 后中断必须留下 in-progress 执行")
                return
            }
            expect(
                FileManager.default.fileExists(atPath: interrupted.bootstrapJournalFile.path),
                "中断不得清除 journal")

            let resumed = performSharedRuntimeBootstrapExecution(
                environment: bootstrapEnvironment(root: root))
            guard case .completed = resumed else {
                expect(false, "健康 runtime 的下次启动必须完成调和，got \(resumed)")
                return
            }
            let records = try! BootstrapReportStore(
                directory: interrupted.bootstrapReportsDirectory).records()
            expect(records.count == 1, "中断副作用必须恢复为一条持久报告")
            let events = records.first?.events ?? []
            expect(
                events.contains(.failure(code: "interrupted_bootstrap"))
                    && events.contains(.helperCopied(path: interrupted.claudioBinaryDestination.path))
                    && events.contains(.packPublished(packID: "ready-pack"))
                    && events.contains(.selectionChanged(removed: nil, selected: "ready-pack")),
                "调和报告必须保留所有可观察副作用，got \(events)")
            expect(
                !FileManager.default.fileExists(atPath: interrupted.bootstrapJournalFile.path),
                "调和成功后必须原子清除旧 journal")
        }
    }

    suite("bootstrap journal：无副作用且 runtime 健康的空中断记录自动清理") {
        withTempDirectory { root in
            publishHealthyBootstrapRuntime(at: root)
            let interrupted = bootstrapEnvironment(root: root) {
                throw InjectedBootstrapInterruption.stop
            }
            _ = performSharedRuntimeBootstrapExecution(environment: interrupted)
            let resumed = performSharedRuntimeBootstrapExecution(
                environment: bootstrapEnvironment(root: root))
            guard case .completed = resumed else {
                expect(false, "无副作用的健康 runtime 必须正常恢复")
                return
            }
            let store = BootstrapReportStore(directory: interrupted.bootstrapReportsDirectory)
            expect((try! store.records()).isEmpty, "健康空 journal 不得制造虚假告警")
            expect(
                !FileManager.default.fileExists(atPath: interrupted.bootstrapJournalFile.path),
                "健康空 journal 必须自动清理")
        }
    }

    suite("bootstrap journal：最终 report 已写入而 journal 尚在时按 journal ID 幂等恢复") {
        withTempDirectory { root in
            let resources = root.appendingPathComponent("app/Resources", isDirectory: true)
            let source = resources.appendingPathComponent("bin/claudio")
            writeBootstrapFixture("helper", to: source)
            try! FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: source.path)
            let bundledPack = resources.appendingPathComponent("packs/shipped", isDirectory: true)
            writeBootstrapFixture(
                #"{"id":"shipped","events":{"stop":"stop.mp3"}}"#,
                to: bundledPack.appendingPathComponent("manifest.json"))
            writeBootstrapFixture("audio", to: bundledPack.appendingPathComponent("stop.mp3"))

            let interrupted = bootstrapEnvironment(
                root: root,
                executablePath: source,
                afterReport: { throw InjectedBootstrapInterruption.stop })
            guard case .completed = performSharedRuntimeBootstrapExecution(environment: interrupted)
            else {
                expect(false, "report 后中断前 bootstrap 本身必须已完成")
                return
            }
            let store = BootstrapReportStore(directory: interrupted.bootstrapReportsDirectory)
            let beforeRecovery = try! store.records()
            expect(beforeRecovery.count == 1, "journal 删除前必须已经只有一条最终报告")
            guard let report = beforeRecovery.first else { return }
            expect(
                FileManager.default.fileExists(atPath: interrupted.bootstrapJournalFile.path),
                "report 已发布后的中断必须保留最终 journal 供重试")

            _ = performSharedRuntimeBootstrapExecution(environment: bootstrapEnvironment(root: root))
            let afterRecovery = try! store.records()
            expect(
                afterRecovery.count == 1
                    && afterRecovery.first?.id == report.id
                    && afterRecovery.first?.occurrenceCount == 1,
                "journal replay 必须识别已发布的同一 ID，不能重复入队或合并计数")
            expect(
                !FileManager.default.fileExists(atPath: interrupted.bootstrapJournalFile.path),
                "幂等重放后必须删除已确认发布的最终 journal")
        }
    }

    suite("bootstrap journal：第二个调用等待活跃 owner，不把其 journal 误报为中断") {
        withTempDirectory { root in
            publishHealthyBootstrapRuntime(at: root)
            let environment = bootstrapEnvironment(root: root)
            let lock = FileLock(path: root.appendingPathComponent(".bootstrap-journal.json.lock").path)
            expect(lock.tryLock(), "测试必须先持有 bootstrap journal 锁")

            let started = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                started.signal()
                _ = performSharedRuntimeBootstrapExecution(environment: environment)
                finished.signal()
            }
            _ = started.wait(timeout: .now() + 1)
            expect(
                finished.wait(timeout: .now() + 0.1) == .timedOut,
                "持锁期间第二个 bootstrap 不得读取/恢复 live journal")
            lock.unlock()
            expect(
                finished.wait(timeout: .now() + 5) == .success,
                "释放锁后等待中的 bootstrap 必须继续完成")
            expect(
                (try! BootstrapReportStore(directory: environment.bootstrapReportsDirectory).records()).isEmpty,
                "仅锁竞争不能生成 interrupted_bootstrap 报告")
        }
    }
}

private func bootstrapPermissions(_ url: URL) -> Int? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.posixPermissions] as? NSNumber)?.intValue
}
