import ClaudioCore
import Foundation

// MARK: - 声音包 = 第三方分发的不可信内容（Codex [P1]/[P2] + 对抗审查 F2）
//
// 声音包是策展 / 第三方分发的（ENGINEERING.md：策展声音包——产品的核心分发模型），所以包目录里的
// 每一个条目都是**不可信输入**。两条攻击面，这一组 suite 逐条钉死：
//
// 1) `manifest.json` 不是它该是的东西。
//    - **已证实、今天就能触发**：读取**无大小上限**。裸 `Data(contentsOf:)` 会把一个 500MB 形状的
//      manifest 整份读进来再喂给 `JSONDecoder`（一份四事件 manifest 实际不到 1 KB）。变异验证时
//      这条确实变红：超限文件被完整读完，一路走到了解码器。
//    - **非正规文件（目录 / FIFO / socket）**：实测 Darwin 上 `Data(contentsOf:)` 会拒绝它们
//      （FIFO 抛 EACCES），并**不会**像评审最初判断的那样永久阻塞——真会挂死的是
//      `FileHandle(forReadingFrom:)`。所以下面这几条 FIFO/目录用例钉的是**契约**，不是当场救火：
//      「拒读，并且讲清楚是因为它不是正规文件」。把它从「Foundation 恰好帮我们挡了」升级成「我们
//      自己挡的、而且有测试」——否则哪天有人把这行改写成 FileHandle/InputStream，洞当场回来。
//    修复：`loadPackManifestData` 走 `readRegularFileBounded`（`O_NOFOLLOW` + `fstat` 正规文件闸门
//    + 1 MiB 上限），且 `Play.swift` 不再自己手写第二份 `Data(contentsOf:)`。
//
// 2) 音频文件不是普通文件——**这条是纯粹的、当场可触发的 bug**。一个名叫 `stop.mp3` 的**目录**
//    （或 FIFO）会让 `fileExists(atPath:)` 回答 `true` → 包显示 complete、`doctor` 一路绿灯、
//    `play` 照样 spawn afplay，而用户在真实事件里得到一片寂静（`/codex review` [P2]）。
//    修复：`doctor` / `play` 一律要求 `regularFileExists`（`stat` 判 `S_IFREG`）。

/// 「绝不阻塞」的判定阈值。正确实现是 `open(O_NONBLOCK)` + `fstat` 立刻拒绝，耗时以微秒计；给到 5 秒
/// 纯粹是为了在最慢的机器上也不误报——真退化成阻塞式读取的话，耗时是**无限**，不是 5.1 秒。
///
/// 这条断言是**前瞻性**的护栏，不是在抓当前的 bug：实测 `Data(contentsOf:)` 并不会挂在 FIFO 上
/// （见文件头）。它守的是「以后没人能把这条读路径换成一个会阻塞的 API」——`FileHandle` 实测就会。
private let nonHangingBudget: TimeInterval = 5

/// 记录 spawn 尝试而不真的起进程——`PlaySuite` 里那个同名 double 是 `private` 的（file-scope），
/// 这里需要自己的一份。
private final class RecordingSpawner: ProcessSpawning, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    func spawn(executablePath: String, arguments: [String]) -> Bool {
        lock.lock()
        _callCount += 1
        lock.unlock()
        return true
    }
}

@MainActor
private func makePlayEnvironment(
    root: URL, configFile: URL, packsDirectory: URL, spawner: any ProcessSpawning
) -> PlayEnvironment {
    PlayEnvironment(
        lockFile: root.appendingPathComponent("play.lock"),
        configFile: configFile,
        userPacksDirectory: packsDirectory,
        bundledPacksDirectory: nil,
        spawner: spawner,
        debounceStateFile: root.appendingPathComponent("play.state"),
        logFile: root.appendingPathComponent("claudio.log"),
        logLockFile: root.appendingPathComponent("claudio.log.lock"))
}

@MainActor
func runPackContentSafetySuites() {

    // MARK: - (1) manifest.json 是不可信输入

    suite(
        "loadPackManifest: manifest.json 是 FIFO → .unreadable，拒读原因讲清「不是正规文件」，且绝不阻塞"
    ) {
        withTempDirectory { root in
            let packDirectory = root.appendingPathComponent("evil-pack", isDirectory: true)
            makeFIFO(at: packDirectory.appendingPathComponent("manifest.json"))

            let started = Date()
            let result = loadPackManifest(in: packDirectory)
            let elapsed = Date().timeIntervalSince(started)

            guard case .failure(.unreadable(let reason)) = result else {
                expect(false, "FIFO 形状的 manifest.json 必须被拒读为 .unreadable，got \(result)")
                return
            }
            expect(
                reason.contains("正规文件"),
                "拒读原因必须讲清「这不是个正规文件」，而不是含糊的读取失败，got \(reason)")
            expect(
                elapsed < nonHangingBudget,
                "读一个 FIFO 形状的 manifest 必须立刻返回。这是前瞻性护栏：换成任何会阻塞的读 API"
                    + "（FileHandle 实测就会等一个永远不来的写端）都会把菜单栏 app / Claude Code hook"
                    + " 挂死。耗时 \(elapsed)s")
        }
    }

    suite("loadPackManifest: manifest.json 是目录 → .unreadable（不是崩溃，也不是「读到了空」）") {
        withTempDirectory { root in
            let packDirectory = root.appendingPathComponent("evil-pack", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: packDirectory.appendingPathComponent("manifest.json"),
                withIntermediateDirectories: true)

            let result = loadPackManifest(in: packDirectory)
            guard case .failure(.unreadable(let reason)) = result else {
                expect(false, "目录形状的 manifest.json 必须被拒读为 .unreadable，got \(result)")
                return
            }
            expect(reason.contains("正规文件"), "拒读原因必须讲清「这不是个正规文件」，got \(reason)")
        }
    }

    suite("loadPackManifest: manifest.json 超过 1 MiB 上限 → .unreadable，绝不整份吞进内存") {
        withTempDirectory { root in
            let packDirectory = root.appendingPathComponent("evil-pack", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: packDirectory, withIntermediateDirectories: true)
            // 一份四事件 manifest 实际不到 1 KB。这里刚好越过 1 MiB 上限一个字节——足以证明闸门在
            // 生效，又不用真的在测试里写一个 500MB 的文件。
            let oversize = Data(repeating: UInt8(ascii: "{"), count: (1 << 20) + 1)
            try? oversize.write(to: packDirectory.appendingPathComponent("manifest.json"))

            let result = loadPackManifest(in: packDirectory)
            guard case .failure(.unreadable(let reason)) = result else {
                expect(false, "超限的 manifest.json 必须被拒读为 .unreadable，got \(result)")
                return
            }
            expect(
                reason.contains("大小上限"),
                "拒读原因必须讲清是超了大小上限（而不是「解析失败」——它压根没被解析），got \(reason)")
        }
    }

    suite("loadPackManifest: 上限之内的正常 manifest.json 仍然照常读取（闸门不能误伤）") {
        withTempDirectory { root in
            let packDirectory = root.appendingPathComponent("minimal-chime", isDirectory: true)
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                to: packDirectory.appendingPathComponent("manifest.json"))

            let result = loadPackManifest(in: packDirectory)
            guard case .success(let manifest) = result else {
                expect(false, "一份普通的小 manifest 必须照常解码，got \(result)")
                return
            }
            expect(manifest.events == ["stop": "stop.mp3"], "解码结果必须原封不动")
        }
    }

    suite("checkPackIntegrity: manifest.json 是 FIFO → .manifestUnreadable，doctor 照常返回") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDir = root.appendingPathComponent("packs")
            writeFixture(#"{ "selected_pack": "evil-pack" }"#, to: configFile)
            makeFIFO(at: packsDir.appendingPathComponent("evil-pack/manifest.json"))

            let started = Date()
            let status = checkPackIntegrity(
                configFile: configFile, userPacksDirectory: packsDir, bundledPacksDirectory: nil)
            let elapsed = Date().timeIntervalSince(started)

            guard case .manifestUnreadable(let packID, _) = status else {
                expect(false, "FIFO 形状的 manifest 必须报 .manifestUnreadable，got \(status)")
                return
            }
            expect(packID == "evil-pack", "manifestUnreadable 必须带上包 id")
            expect(
                elapsed < nonHangingBudget,
                "`claudio doctor` 遇到恶意包必须照常返回，绝不挂住。耗时 \(elapsed)s")
        }
    }

    suite(
        "playSoundEvent: manifest.json 是 FIFO → .notReady、不 spawn、且绝不阻塞（hook 绝不阻断 Claude Code）"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDir = root.appendingPathComponent("packs")
            writeFixture(#"{ "selected_pack": "evil-pack" }"#, to: configFile)
            makeFIFO(at: packsDir.appendingPathComponent("evil-pack/manifest.json"))
            let spawner = RecordingSpawner()
            let env = makePlayEnvironment(
                root: root, configFile: configFile, packsDirectory: packsDir, spawner: spawner)

            let started = Date()
            let outcome = playSoundEvent("stop", environment: env)
            let elapsed = Date().timeIntervalSince(started)

            expect(
                outcome == .notReady,
                "读不了的 manifest 是一个静默的「还没准备好」状态，got \(outcome)")
            expect(spawner.callCount == 0, "manifest 都没读成，绝不该 spawn afplay")
            expect(
                elapsed < nonHangingBudget,
                "`claudio play` 跑在 Claude Code 的同步 hook 路径上——这条读路径永远不许换成一个会在恶意"
                    + " 包内容上阻塞的 API，否则卡住的是 Claude Code 本身。耗时 \(elapsed)s")
        }
    }

    // MARK: - (1b) 符号链接：manifest 与音频文件必须给出**同一个**答案
    //
    // 本轮评审的发现：manifest 那条路曾用 `O_NOFOLLOW`（**拒绝**一切符号链接），而音频那条路
    // （`regularFileExists`）刻意用 `stat` 而非 `lstat`（**跟随**符号链接，注释明写「包内一个指向同包内
    // 真实文件的符号链接是合法的」）。于是同一个「包内合法符号链接」，manifest 拒绝、音频放行——**同一个
    // 合法性判断给出了相反答案**：包作者手工把 manifest 链到 repo 里的包会莫名其妙变 broken，而它的音频
    // 文件却好好的。
    //
    // 选的是「与音频一致」（放开跟随），因为 `O_NOFOLLOW` **从来不是**拦逃逸的那道门——`isReallyContained`
    // （解析符号链接后再判包含）才是，而它已经在位。放开之后安全性等价，下面三条把这个契约钉死：
    //   合法（包内链接、目标是包内正规文件）→ 读；
    //   目标不是正规文件（链接到 FIFO）      → 仍然拒（`fstat` 闸门跟着 fd 走，跟随与否都在）；
    //   逃出包目录                          → 仍然拒（`isReallyContained`，不是 O_NOFOLLOW）。

    suite(
        "loadPackManifest: manifest.json 是包内、指向同包内真实文件的符号链接 → 照常读取（与音频文件同一句话）"
    ) {
        withTempDirectory { root in
            let packDirectory = root.appendingPathComponent("minimal-chime", isDirectory: true)
            let realManifest = packDirectory.appendingPathComponent("manifest.real.json")
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#, to: realManifest)
            createSymlink(
                at: packDirectory.appendingPathComponent("manifest.json"), pointingTo: realManifest)

            let result = loadPackManifest(in: packDirectory)
            guard case .success(let manifest) = result else {
                expect(
                    false,
                    "包内指向包内真实文件的 manifest 符号链接是**合法**的——音频文件那条路一直是这么判的"
                        + "（`regularFileExists` 跟随符号链接），manifest 这条路必须说同一句话，got \(result)")
                return
            }
            expect(manifest.events == ["stop": "stop.mp3"], "解码结果必须原封不动")
        }
    }

    suite("loadPackManifest: manifest.json 是指向包内 FIFO 的符号链接 → 仍然拒读（正规文件闸门跟着 fd 走）") {
        withTempDirectory { root in
            // 放开「跟随符号链接」绝不等于放开「读非正规文件」：`fstat` 判 `S_IFREG` 绑定在打开的那个
            // fd 上，跟随之后落在 FIFO 上照样被挡下，一个字节都不读，且 `O_NONBLOCK` 保证立刻返回。
            let packDirectory = root.appendingPathComponent("evil-pack", isDirectory: true)
            let fifo = packDirectory.appendingPathComponent("real.fifo")
            makeFIFO(at: fifo)
            createSymlink(
                at: packDirectory.appendingPathComponent("manifest.json"), pointingTo: fifo)

            let started = Date()
            let result = loadPackManifest(in: packDirectory)
            let elapsed = Date().timeIntervalSince(started)

            guard case .failure(.unreadable(let reason)) = result else {
                expect(false, "链接到 FIFO 的 manifest 必须被拒读，got \(result)")
                return
            }
            expect(reason.contains("正规文件"), "拒读原因必须讲清「目标不是正规文件」，got \(reason)")
            expect(elapsed < nonHangingBudget, "跟随符号链接之后也绝不许阻塞。耗时 \(elapsed)s")
        }
    }

    suite("loadPackManifest: manifest.json 是逃出包目录的符号链接 → 仍然拒读（挡它的是 isReallyContained，不是 O_NOFOLLOW）") {
        withTempDirectory { root in
            // 这条是放开 `O_NOFOLLOW` 之后最重要的回归护栏：逃逸必须**依然**被挡死。挡它的一直是
            // `isReallyContained`（解析符号链接后判包含）——如果哪天有人把那道闸门拆了，`O_NOFOLLOW`
            // 已经不在那儿兜底了，这条会当场变红。
            let packDirectory = root.appendingPathComponent("minimal-chime", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: packDirectory, withIntermediateDirectories: true)
            let outsideManifest = root.appendingPathComponent("secret-manifest.json")
            writeFixture(#"{ "id": "minimal-chime", "events": {} }"#, to: outsideManifest)
            createSymlink(
                at: packDirectory.appendingPathComponent("manifest.json"),
                pointingTo: outsideManifest)

            let result = loadPackManifest(in: packDirectory)
            guard case .failure(.unreadable) = result else {
                expect(false, "逃出包目录的 manifest 符号链接必须继续被拒读，got \(result)")
                return
            }
        }
    }

    suite("checkPackIntegrity: 一个 manifest.json 与音频文件**都是**包内符号链接的包 → .complete") {
        withTempDirectory { root in
            // 端到端：两条读路径现在对「包内合法符号链接」给出同一个答案。以前这个包会报
            // .manifestUnreadable（manifest 那条路拒绝），而它的音频文件明明是被放行的——同一个包，
            // 两条路互相打架。
            let configFile = root.appendingPathComponent("config.json")
            let packsDir = root.appendingPathComponent("packs")
            let packDirectory = packsDir.appendingPathComponent("minimal-chime", isDirectory: true)
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)

            let realManifest = packDirectory.appendingPathComponent("manifest.real.json")
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#, to: realManifest)
            createSymlink(
                at: packDirectory.appendingPathComponent("manifest.json"), pointingTo: realManifest)
            let realAudio = packDirectory.appendingPathComponent("real-stop.mp3")
            writeFixture("fake-audio", to: realAudio)
            createSymlink(
                at: packDirectory.appendingPathComponent("stop.mp3"), pointingTo: realAudio)

            let status = checkPackIntegrity(
                configFile: configFile, userPacksDirectory: packsDir, bundledPacksDirectory: nil)
            expect(
                status == .complete(packID: "minimal-chime", events: ["stop"]),
                "manifest 与音频都是包内符号链接的包必须一致地报 .complete，got \(status)")
        }
    }

    // MARK: - (2) 音频文件必须是正规文件，不能只是「路径上有东西」

    suite(
        "checkPackIntegrity: 名叫 stop.mp3 的**目录**必须报 .incomplete——绝不能把一个发不出声的包报成 complete"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDir = root.appendingPathComponent("packs")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            // `fileExists(atPath:)` 对目录一律回答 `true`（`fileExists(atPath:isDirectory:)` 也只能
            // 排掉目录，排不掉 FIFO/socket）——旧实现会把这个包报成 complete、doctor 一路绿灯，然后
            // 用户在真实事件里得到一片寂静（`/codex review` [P2]）。
            try? FileManager.default.createDirectory(
                at: packsDir.appendingPathComponent("minimal-chime/stop.mp3"),
                withIntermediateDirectories: true)

            let status = checkPackIntegrity(
                configFile: configFile, userPacksDirectory: packsDir, bundledPacksDirectory: nil)
            expect(
                status == .incomplete(packID: "minimal-chime", missingFiles: ["stop.mp3"]),
                "一个目录不是音频文件——必须报缺失，got \(status)")
        }
    }

    suite("checkPackIntegrity: 名叫 stop.mp3 的 FIFO 同样必须报 .incomplete") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDir = root.appendingPathComponent("packs")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            makeFIFO(at: packsDir.appendingPathComponent("minimal-chime/stop.mp3"))

            let status = checkPackIntegrity(
                configFile: configFile, userPacksDirectory: packsDir, bundledPacksDirectory: nil)
            expect(
                status == .incomplete(packID: "minimal-chime", missingFiles: ["stop.mp3"]),
                "FIFO 不是音频文件——必须报缺失（`fileExists` 会说它在），got \(status)")
        }
    }

    suite(
        "checkPackIntegrity: 包内指向同包内真实文件的符号链接仍然算 .complete（正规文件闸门不能误伤合法包）"
    ) {
        withTempDirectory { root in
            // 回归护栏：`regularFileExists` 刻意用 `stat`（跟随符号链接）而不是 `lstat`。包内的一个
            // 符号链接指向同包内的真实音频文件是合法的（`isReallyContained` 放行它，gui 的 coverage
            // 也把它算作 .present）——被拒的只能是「目标不是正规文件」和「逃出包目录」。
            let configFile = root.appendingPathComponent("config.json")
            let packsDir = root.appendingPathComponent("packs")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop-link.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            let realFile = packsDir.appendingPathComponent("minimal-chime/real-stop.mp3")
            writeFixture("fake-audio", to: realFile)
            createSymlink(
                at: packsDir.appendingPathComponent("minimal-chime/stop-link.mp3"),
                pointingTo: realFile)

            let status = checkPackIntegrity(
                configFile: configFile, userPacksDirectory: packsDir, bundledPacksDirectory: nil)
            expect(
                status == .complete(packID: "minimal-chime", events: ["stop"]),
                "包内符号链接指向包内真实文件，必须继续算作在位，got \(status)")
        }
    }

    suite("playSoundEvent: 名叫 stop.mp3 的目录 → .notReady，绝不 spawn afplay 去放一个目录") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDir = root.appendingPathComponent("packs")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            try? FileManager.default.createDirectory(
                at: packsDir.appendingPathComponent("minimal-chime/stop.mp3"),
                withIntermediateDirectories: true)
            let spawner = RecordingSpawner()
            let env = makePlayEnvironment(
                root: root, configFile: configFile, packsDirectory: packsDir, spawner: spawner)

            let outcome = playSoundEvent("stop", environment: env)
            expect(
                outcome == .notReady,
                "一个目录不是音频文件——必须报 .notReady（旧实现会报 .played 然后一片寂静），got \(outcome)")
            expect(spawner.callCount == 0, "绝不该拿一个目录去 spawn afplay")
        }
    }

    suite("playSoundEvent: 名叫 stop.mp3 的 FIFO → .notReady，绝不 spawn") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDir = root.appendingPathComponent("packs")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            makeFIFO(at: packsDir.appendingPathComponent("minimal-chime/stop.mp3"))
            let spawner = RecordingSpawner()
            let env = makePlayEnvironment(
                root: root, configFile: configFile, packsDirectory: packsDir, spawner: spawner)

            let outcome = playSoundEvent("stop", environment: env)
            expect(
                outcome == .notReady,
                "FIFO 不是音频文件——必须报 .notReady，got \(outcome)")
            expect(spawner.callCount == 0, "绝不该拿一个 FIFO 去 spawn afplay（afplay 会挂在那儿读它）")
        }
    }
}
