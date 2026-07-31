import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
private func packAudioEnvironment(
    userPacksDirectory: URL,
    factoryPacksDirectory: URL? = nil
) -> AudioImportEnvironment {
    AudioImportEnvironment(
        userPacksDirectory: userPacksDirectory,
        bundledPacksDirectory: nil,
        factoryPacksDirectory: factoryPacksDirectory,
        durationProbe: StubDurationProbe(fixedDuration: 1),
        packsLockFile: userPacksDirectory.deletingLastPathComponent()
            .appendingPathComponent("packs.lock"))
}

@MainActor
private func inventoryFiles(
    _ result: Result<[PackAudioFile], PackAudioInventoryError>
) -> [PackAudioFile]? {
    guard case .success(let files) = result else { return nil }
    return files
}

@MainActor
private func deleteFailure(
    _ result: Result<Void, OrphanAudioDeleteError>
) -> OrphanAudioDeleteError? {
    guard case .failure(let error) = result else { return nil }
    return error
}

@MainActor
func runPackAudioInventorySuites() {
    suite("packAudioFiles：只枚举包根直属正规音频，按真实文件名排序并标出未引用文件") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs")
            let pack = packs.appendingPathComponent("my-pack")
            writeFixture(
                #"{ "id": "my-pack", "events": { "stop": "./stop.mp3", "notification": "stop.mp3" } }"#,
                to: pack.appendingPathComponent("manifest.json"))
            writeFixture("audio", to: pack.appendingPathComponent("stop.mp3"))
            writeFixture("audio", to: pack.appendingPathComponent("Spare.WAV"))
            writeFixture("not audio", to: pack.appendingPathComponent("notes.txt"))
            writeFixture("hidden", to: pack.appendingPathComponent(".hidden.mp3"))
            writeFixture("nested", to: pack.appendingPathComponent("nested/ignored.m4a"))
            try? FileManager.default.createDirectory(
                at: pack.appendingPathComponent("directory.aiff"),
                withIntermediateDirectories: true)

            let files = inventoryFiles(
                packAudioFiles(
                    packID: "my-pack",
                    environment: packAudioEnvironment(userPacksDirectory: packs)))

            expect(
                files == [
                    PackAudioFile(fileName: "Spare.WAV", isOrphan: true),
                    PackAudioFile(fileName: "stop.mp3", isOrphan: false),
                ],
                "应只列直属、非隐藏、正规音频；./stop.mp3 与 stop.mp3 必须归一为同一引用，实得 "
                    + "\(String(describing: files))")
        }
    }

    suite("packAudioFiles：引用判定服从文件系统真实大小写语义，不把大小写别名误报成孤儿") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs")
            let pack = packs.appendingPathComponent("case-pack")
            writeFixture(
                #"{ "id": "case-pack", "events": { "stop": "ping.mp3" } }"#,
                to: pack.appendingPathComponent("manifest.json"))
            writeFixture("audio", to: pack.appendingPathComponent("Ping.MP3"))

            let lowerCasePath = pack.appendingPathComponent("ping.mp3")
            let files = inventoryFiles(
                packAudioFiles(
                    packID: "case-pack",
                    environment: packAudioEnvironment(userPacksDirectory: packs)))

            if regularFileExists(at: lowerCasePath) {
                expect(
                    files == [PackAudioFile(fileName: "Ping.MP3", isOrphan: false)],
                    "大小写不敏感卷上 manifest 的 ping.mp3 指到真实 Ping.MP3，不得误报孤儿")
            } else {
                expect(
                    files == [PackAudioFile(fileName: "Ping.MP3", isOrphan: true)],
                    "大小写敏感卷上 ping.mp3 与 Ping.MP3 是不同路径，必须诚实标成未引用")
            }
        }
    }

    suite("packAudioFiles：manifest 不可读时 fail closed，不提供可分配或可删除的伪孤儿列表") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs")
            let pack = packs.appendingPathComponent("broken-pack")
            writeFixture("{ nope", to: pack.appendingPathComponent("manifest.json"))
            writeFixture("audio", to: pack.appendingPathComponent("spare.mp3"))

            let result = packAudioFiles(
                packID: "broken-pack",
                environment: packAudioEnvironment(userPacksDirectory: packs))

            guard case .failure(.manifestUnreadable) = result else {
                expect(false, "manifest 不可读必须返回 .manifestUnreadable，实得 \(result)")
                return
            }
            expect(true, "manifest 不可读时没有伪造孤儿列表")
        }
    }

    suite("packAudioFiles/delete：包内外符号链接都不是可分配或可删除的正规音频行") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs")
            let pack = packs.appendingPathComponent("link-pack")
            let direct = pack.appendingPathComponent("direct.mp3")
            let internalLink = pack.appendingPathComponent("internal.mp3")
            let external = root.appendingPathComponent("outside.mp3")
            let escapeLink = pack.appendingPathComponent("escape.mp3")
            let disguisedDirectory = pack.appendingPathComponent("folder.mp3")
            let directoryChild = disguisedDirectory.appendingPathComponent("keep.txt")
            writeFixture(
                #"{ "id": "link-pack", "events": {} }"#,
                to: pack.appendingPathComponent("manifest.json"))
            writeFixture("direct", to: direct)
            writeFixture("outside", to: external)
            writeFixture("keep", to: directoryChild)
            try? FileManager.default.createSymbolicLink(at: internalLink, withDestinationURL: direct)
            try? FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: external)
            let environment = packAudioEnvironment(userPacksDirectory: packs)

            let files = inventoryFiles(
                packAudioFiles(packID: "link-pack", environment: environment))
            expect(
                files == [PackAudioFile(fileName: "direct.mp3", isOrphan: true)],
                "lstat 必须只放行真实目录项；包内/逃逸 symlink 都不能伪装成音频行，实得 \(String(describing: files))")

            let escapedDelete = deleteOrphanAudioFile(
                fileName: "escape.mp3", packID: "link-pack", environment: environment)
            expect(
                deleteFailure(escapedDelete) == .unsafeFileName,
                "逃逸 symlink 必须在 containment 闸门拒绝，实得 \(escapedDelete)")
            expect(regularFileExists(at: external), "拒删逃逸 symlink 绝不能碰包外目标")

            let internalDelete = deleteOrphanAudioFile(
                fileName: "internal.mp3", packID: "link-pack", environment: environment)
            expect(
                deleteFailure(internalDelete) == .fileNotFound(fileName: "internal.mp3"),
                "包内 symlink 也不是可删正规音频行，实得 \(internalDelete)")
            expect(
                (try? FileManager.default.attributesOfItem(atPath: internalLink.path)) != nil,
                "拒删后 symlink 目录项必须仍在")
            expect(regularFileExists(at: direct), "拒删包内 symlink 不能碰它指向的正规文件")

            let directoryDelete = deleteOrphanAudioFile(
                fileName: "folder.mp3", packID: "link-pack", environment: environment)
            expect(
                deleteFailure(directoryDelete) == .fileNotFound(fileName: "folder.mp3"),
                "伪装成 .mp3 的目录必须拒删，绝不能递归删除，实得 \(directoryDelete)")
            expect(regularFileExists(at: directoryChild), "拒删目录后其内容必须原样保留")
        }
    }

    suite("deleteOrphanAudioFile：引用中的文件拒删；孤儿只在显式删除调用后消失") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs")
            let pack = packs.appendingPathComponent("my-pack")
            let used = pack.appendingPathComponent("used.mp3")
            let orphan = pack.appendingPathComponent("orphan.mp3")
            writeFixture(
                #"{ "id": "my-pack", "events": { "stop": "used.mp3" } }"#,
                to: pack.appendingPathComponent("manifest.json"))
            writeFixture("used", to: used)
            writeFixture("orphan", to: orphan)
            let environment = packAudioEnvironment(userPacksDirectory: packs)

            let refused = deleteOrphanAudioFile(
                fileName: "used.mp3", packID: "my-pack", environment: environment)
            expect(
                deleteFailure(refused) == .stillReferenced(fileName: "used.mp3"),
                "仍被事件引用的音频必须拒删，实得 \(refused)")
            expect(regularFileExists(at: used), "拒删后引用文件必须仍在")

            let deleted = deleteOrphanAudioFile(
                fileName: "orphan.mp3", packID: "my-pack", environment: environment)
            if case .failure(let error) = deleted {
                expect(false, "孤儿的显式删除应成功，实得 \(error)")
            } else {
                expect(true, "孤儿显式删除成功")
            }
            expect(!regularFileExists(at: orphan), "成功返回后孤儿目录项必须已经消失")
            expect(regularFileExists(at: used), "删除孤儿不得波及引用文件")
        }
    }

    suite("deleteOrphanAudioFile：陈旧孤儿快照不作数，删除时必须在锁内重读 manifest") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs")
            let pack = packs.appendingPathComponent("my-pack")
            let orphan = pack.appendingPathComponent("orphan.mp3")
            let manifest = pack.appendingPathComponent("manifest.json")
            writeFixture(
                #"{ "id": "my-pack", "events": {} }"#,
                to: manifest)
            writeFixture("orphan", to: orphan)
            let environment = packAudioEnvironment(userPacksDirectory: packs)
            expect(
                inventoryFiles(packAudioFiles(packID: "my-pack", environment: environment))
                    == [PackAudioFile(fileName: "orphan.mp3", isOrphan: true)],
                "前提：确认对话框打开时 orphan.mp3 的确是孤儿")

            writeFixture(
                #"{ "id": "my-pack", "events": { "notification": "orphan.mp3" } }"#,
                to: manifest)
            let refused = deleteOrphanAudioFile(
                fileName: "orphan.mp3", packID: "my-pack", environment: environment)

            expect(
                deleteFailure(refused) == .stillReferenced(fileName: "orphan.mp3"),
                "确认后 manifest 新增引用时必须以 lock-time 重读结果拒删，实得 \(refused)")
            expect(regularFileExists(at: orphan), "锁内二次判定拒删后文件必须原样保留")
        }
    }

    suite("deleteOrphanAudioFile：packs.lock 被占用时不运行任何删除") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs")
            let pack = packs.appendingPathComponent("my-pack")
            let orphan = pack.appendingPathComponent("orphan.mp3")
            writeFixture(
                #"{ "id": "my-pack", "events": {} }"#,
                to: pack.appendingPathComponent("manifest.json"))
            writeFixture("orphan", to: orphan)
            let environment = packAudioEnvironment(userPacksDirectory: packs)

            let outer = withNonBlockingLock(path: environment.packsLockFile.path) {
                deleteOrphanAudioFile(
                    fileName: "orphan.mp3", packID: "my-pack", environment: environment)
            }
            guard case .ran(let result) = outer else {
                expect(false, "测试前提：外层必须取得注入的 packs.lock")
                return
            }
            expect(
                deleteFailure(result) == .lockBusy,
                "同一把 packs.lock 被占用时删除必须立即返回 .lockBusy，实得 \(result)")
            expect(regularFileExists(at: orphan), "lockBusy 时删除临界区不得运行")
        }
    }

    suite("deleteOrphanAudioFile：内置包恒只读，即使用户目录里有可写副本也拒删") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs")
            let factory = root.appendingPathComponent("factory")
            writeFixture(
                #"{ "id": "builtin", "events": {} }"#,
                to: packs.appendingPathComponent("builtin/manifest.json"))
            let orphan = packs.appendingPathComponent("builtin/orphan.mp3")
            writeFixture("audio", to: orphan)
            writeFixture(
                #"{ "id": "builtin", "events": {} }"#,
                to: factory.appendingPathComponent("builtin/manifest.json"))
            writeFixture("factory", to: factory.appendingPathComponent("builtin/base.mp3"))

            let result = deleteOrphanAudioFile(
                fileName: "orphan.mp3",
                packID: "builtin",
                environment: packAudioEnvironment(
                    userPacksDirectory: packs,
                    factoryPacksDirectory: factory))

            expect(
                deleteFailure(result) == .builtinReadOnly(packID: "builtin"),
                "内置包删除必须拒绝为 .builtinReadOnly，实得 \(result)")
            expect(regularFileExists(at: orphan), "只读拒绝后用户自加音频也必须原样保留")
        }
    }

    suite("EventRowImportViewModel.bindExistingFile：复用包内音频走 bindEventToManifest 并转 present") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs")
            let pack = packs.appendingPathComponent("my-pack")
            writeFixture(
                #"{ "id": "my-pack", "events": {} }"#,
                to: pack.appendingPathComponent("manifest.json"))
            writeFixture("audio", to: pack.appendingPathComponent("spare.mp3"))
            let environment = packAudioEnvironment(userPacksDirectory: packs)
            let importViewModel = AudioImportViewModel(
                packID: "my-pack",
                environment: environment,
                previewState: .reject(.nonWhitelistFormat))
            let viewModel = EventRowImportViewModel(
                event: .notification,
                importViewModel: importViewModel)
            expect(
                importViewModel.state == .reject(.nonWhitelistFormat),
                "前提：这一行仍显示上一次无效导入的拒绝")

            viewModel.bindExistingFile("spare.mp3")

            expect(
                viewModel.bindResult != nil,
                "复用包内文件必须把真实 bind outcome 发布到既有 bindResult 表面")
            expect(
                packCoverage(
                    packID: "my-pack",
                    config: ClaudioConfig(selectedPack: "my-pack"),
                    environment: environment
                ).first(where: { $0.event == .notification })?.coverage
                    == .present(fileName: "spare.mp3"),
                "分配后 notification 行必须转为 .present(spare.mp3)")
            expect(
                importViewModel.state == .idle,
                "成功复用包内音频后必须清掉旧导入拒绝，不能让 EventRowView 继续优先显示陈旧错误")
        }
    }
}
