import ClaudioCore
import Foundation

// MARK: - claudio setup: v1 首次安装自举 (ENGINEERING.md T17)
//
// Fixture layout mirrors the real `release.yml` bundle shape:
//   <bundleRoot>/Contents/Resources/bin/claudio     (the "currently running" binary)
//   <bundleRoot>/Contents/Resources/packs/<id>/     (bundled packs, sibling of bin/)
// against a `<claudioRoot>` standing in for `~/.claudio/`.

@MainActor
private func makeBundleFixture(
    at bundleRoot: URL, packIDs: [String] = ["minimal-chime"]
) -> (executablePath: URL, packsDirectory: URL) {
    let binDirectory = bundleRoot.appendingPathComponent(
        "Contents/Resources/bin", isDirectory: true)
    let packsDirectory = bundleRoot.appendingPathComponent(
        "Contents/Resources/packs", isDirectory: true)
    let executablePath = binDirectory.appendingPathComponent("claudio")
    try? FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    try? Data("#!fake-binary-fixture".utf8).write(to: executablePath)
    for id in packIDs {
        let packDirectory = packsDirectory.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: packDirectory, withIntermediateDirectories: true)
        writeFixture(
            #"{ "schema": 1, "id": "\#(id)", "events": { "stop": "stop.mp3" } }"#,
            to: packDirectory.appendingPathComponent("manifest.json"))
    }
    return (executablePath, packsDirectory)
}

private func makeEnvironment(
    root: URL, executablePath: URL, claudioRootName: String = "claudio-root"
) -> SetupEnvironment {
    let claudioRoot = root.appendingPathComponent(claudioRootName, isDirectory: true)
    return SetupEnvironment(
        executablePath: executablePath,
        claudioBinaryDestination: claudioRoot.appendingPathComponent("bin/claudio"),
        userPacksDirectory: claudioRoot.appendingPathComponent("packs", isDirectory: true),
        configFile: claudioRoot.appendingPathComponent("config.json"),
        settingsFile: root.appendingPathComponent("settings.json"),
        configLockFile: claudioRoot.appendingPathComponent("config.lock"),
        settingsLockFile: claudioRoot.appendingPathComponent("settings.lock"),
        packsLockFile: claudioRoot.appendingPathComponent("packs.lock"))
}

@MainActor
func runSetupSuites() {

    // MARK: - 包目录锁（`/codex review b0ce657` 之后那次核查逼出来的）
    //
    // 这段包循环（`moveItem` 挪走用户整个包目录 → `copyItem`→`moveItem` 发布内置包）是
    // `manifest.json` 的**第二个写者**，而它此前零锁 —— GUI 侧的 `mutateManifestJSON` 也零锁。
    // 两个写者、两个进程、没有互斥，而 `docs/distribution.md` 与 `restoreBundledPacksHint`
    // 都在主动教用户「从 Terminal 跑一次 setup」——也就是说这条竞争是被文档鼓励的，不是理论的。
    //
    // 拿不到锁时**不许报成功**：这与本文件 `binaryQuarantined` / `noAvailablePack` 是同一条纪律
    // ——「只要这次安装注定是哑的，就不许把它报成成功」。包没发布出去而 hooks 写了，用户拿到的
    // 就是一台装完不响的机器。
    suite("performFirstRunSetup：包锁被占住时必须失败，绝不许静默跳过包却照样报成功") {
        withTempDirectory { root in
            let bundleRoot = root.appendingPathComponent("Claudio.app", isDirectory: true)
            let (executablePath, _) = makeBundleFixture(at: bundleRoot)
            let environment = makeEnvironment(root: root, executablePath: executablePath)

            let outcome = withNonBlockingLock(path: environment.packsLockFile.path) {
                performFirstRunSetup(environment: environment)
            }
            guard case .ran(let result) = outcome else {
                expect(false, "测试自身的前提坏了：外层那把包锁没拿到（\(outcome)）")
                return
            }
            expect(
                result == .failure(.packsLockBusy),
                "包锁被别人占住（GUI 正在写 manifest.json）时，setup 必须返回 `.packsLockBusy`，"
                    + "实得 \(result)。最坏的两种错法：① 把 `.skipped` 当成「没有包要复制」而报"
                    + "`.completed`——用户得到一台写了 hooks、却没有包的哑机器；② 跳过锁直接复制"
                    + "——那就等于没上锁，`moveItem` 会在 GUI 读到一半时把整个包目录挪走。")

            // hooks 一个字节都不许写：报失败就得是真失败，不许留下半个安装。
            let settingsExists = FileManager.default.fileExists(
                atPath: environment.settingsFile.path)
            expect(
                !settingsExists,
                "setup 因为包锁忙而失败，却已经把 hooks 写进 settings.json 了 —— "
                    + "「装完是哑的就不许报成功」这条纪律要求锁的判定发生在写 hooks **之前**。")
        }
    }
    suite(
        "performFirstRunSetup: 覆盖一个**已存在**的二进制 —— 新内容 + 新执行位，旧文件的元数据一个字节都不留"
    ) {
        // 这条测试站的位置，是上一版**没有任何测试站过**的地方：`copySelfToFixedLocation` 的
        // 「目标已存在」那条路。存量那条 executable 断言走的是「目标不存在」→ `moveItem`，
        // 而 `moveItem` 原样带走暂存的 0o755，所以它**恒绿**，逮不住下面这个 bug。
        //
        // 而这个 bug 是「把删了再拷改成原子发布」那一刀**自己引入**的：`replaceItemAt` 的默认行为是
        // **保留原文件的元数据**（权限位在其中）。实测：目标 0644 + 暂存 0755 → 默认选项发布出去是
        // **0644** —— 内容是新的，执行位是旧的。于是 `settings.json` 里那四条 hook 指向的二进制
        // 存在、完整、而**不可执行**，Claude Code 每一次事件都会撞上它。那正是那一刀在注释里
        // 自称已经消灭的三种坏终态之一。修法是 `.usingNewMetadataOnly`。
        withTempDirectory { root in
            let (executablePath, _) = makeBundleFixture(at: root.appendingPathComponent("bundle"))
            let environment = makeEnvironment(root: root, executablePath: executablePath)
            let destination = environment.claudioBinaryDestination

            // 一台「上一次安装留下了一个不可执行的二进制」的机器（用户 chmod 过、一次坏掉的旧安装、
            // 或任何别的原因 —— 这条路径要能把它**修好**，而不是把坏的执行位继承下来）。
            try? FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("#!stale-and-not-executable".utf8).write(to: destination, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: destination.path)

            _ = performFirstRunSetup(environment: environment)

            let published = try? String(contentsOf: destination, encoding: .utf8)
            expect(
                published == "#!fake-binary-fixture",
                "覆盖之后磁盘上必须是**新**的那份二进制，实际是 \(published ?? "<读不到>")")

            let permissions = (try? FileManager.default.attributesOfItem(
                atPath: destination.path))?[.posixPermissions] as? NSNumber
            expect(
                permissions.map { ($0.uint16Value & 0o111) != 0 } ?? false,
                "覆盖之后那个二进制必须是**可执行**的，实际 mode = "
                    + "\(permissions.map { String($0.uint16Value, radix: 8) } ?? "<读不到>")。"
                    + "`replaceItemAt` 默认**保留原文件的元数据**（权限位在其中）——不带 "
                    + "`.usingNewMetadataOnly`，这里会原样继承旧文件的 0644：内容是新的，执行位是旧的。"
                    + "而 `settings.json` 里那四条 hook 逐字指向这个文件，Claude Code 每一次事件都会"
                    + "执行它 —— 一个完整但不可执行的二进制，等于每一次事件都静默失败")

            // 暂存不许留在磁盘上（它是点开头的，留下来不致命，但留下来就说明发布那一步没走完）。
            let staging = destination.deletingLastPathComponent()
                .appendingPathComponent(
                    ".\(destination.lastPathComponent).tmp-\(ProcessInfo.processInfo.processIdentifier)")
            expect(
                !FileManager.default.fileExists(atPath: staging.path),
                "发布成功之后，暂存文件必须已经不在了（rename 会把它消耗掉）")
        }
    }

    suite(
        "performFirstRunSetup: 目标是一条指向真实文件的 symlink —— 必须发布出一份常规二进制，不能永久失败"
    ) {
        // 回归测试（`/codex review 3af8d5f` 红队实测逮住）：「原子发布」那一刀用 `fileExists` 判目标
        // 存不存在，而 `fileExists` **跟随 symlink**；`replaceItemAt` / `moveItem` 却是 lstat 语义。
        // 于是 `~/.claudio/bin/claudio` 是一条指向真实文件的 symlink 时，`fileExists` 说「在」→ 走
        // `replaceItemAt` → 它 lstat 看见那条链接、当场抛 → `.binaryCopyFailure`、二进制永不发布、
        // hooks 永不写、**每一次重跑都一字不差地失败**。姊妹的包复制路径（`Setup.swift:403`）早就为
        // 这个 bug 从 `fileExists` 换成了 `attributesOfItem`（lstat）—— 二进制路径当时漏了。
        withTempDirectory { root in
            let (executablePath, _) = makeBundleFixture(at: root.appendingPathComponent("bundle"))
            let environment = makeEnvironment(root: root, executablePath: executablePath)
            let destination = environment.claudioBinaryDestination

            // 一台机器：`bin/claudio` 是一条指向别处一份真实（旧）二进制的软链接。
            try? FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let elsewhere = root.appendingPathComponent("some-old-claudio")
            try? Data("#!OLD-EXTERNAL".utf8).write(to: elsewhere, options: .atomic)
            try? FileManager.default.createSymbolicLink(at: destination, withDestinationURL: elsewhere)

            let result = performFirstRunSetup(environment: environment)

            // 发布之后：`bin/claudio` 必须是一份**常规文件**（不再是链接），内容是新的、可执行。
            let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
            expect(
                attributes?[.type] as? FileAttributeType == .typeRegular,
                "覆盖一条 symlink 之后，`bin/claudio` 必须是一份**常规文件**（旧算法就是这么做的："
                    + "removeItem 删掉链接、copyItem 写一份新的）。实际 type = "
                    + "\(attributes?[.type].map { "\($0)" } ?? "<不存在>")。"
                    + "还是 symlink = 用了 `fileExists`（跟随链接）而不是 lstat，"
                    + "`replaceItemAt` 当场抛，二进制永不发布，setup 每次重跑都失败：\(result)")
            let published = try? String(contentsOf: destination, encoding: .utf8)
            expect(
                published == "#!fake-binary-fixture",
                "发布之后磁盘上必须是**新**的那份二进制，实际是 \(published ?? "<读不到>")")
            expect(
                (attributes?[.posixPermissions] as? NSNumber).map { ($0.uint16Value & 0o111) != 0 }
                    ?? false,
                "发布出来的二进制必须可执行")
            // 那份被指向的旧文件不该被动过（我们删的是**链接**，不是它指向的东西）。
            expect(
                (try? String(contentsOf: elsewhere, encoding: .utf8)) == "#!OLD-EXTERNAL",
                "removeItem 删的必须是 symlink 本身，不是它指向的那份文件 —— 后者一个字节都不该动")
        }
    }

    suite("performFirstRunSetup: running from inside a bundle copies binary + pack, selects default, installs hooks") {
        withTempDirectory { root in
            let (executablePath, _) = makeBundleFixture(at: root.appendingPathComponent("bundle"))
            let environment = makeEnvironment(root: root, executablePath: executablePath)

            let result = performFirstRunSetup(environment: environment)
            guard case .success(.completed(let copiedBinary, let copiedPacks, _, let packSelection, let hooksOutcome)) = result
            else {
                expect(false, "expected .success(.completed(...)), got \(result)")
                return
            }
            expect(copiedBinary, "binary should be copied when running from inside a bundle")
            expect(copiedPacks == ["minimal-chime"], "the bundled pack should be copied, got \(copiedPacks)")
            expect(packSelection == .selectedDefault(packID: "minimal-chime"), "a fresh config.json should default-select the copied pack")
            expect(hooksOutcome == .installed, "a fresh settings.json should get hooks installed")

            expect(
                FileManager.default.fileExists(atPath: environment.claudioBinaryDestination.path),
                "binary must actually exist at the fixed destination afterward")
            var isExecutable = false
            if let attributes = try? FileManager.default.attributesOfItem(
                atPath: environment.claudioBinaryDestination.path),
                let permissions = attributes[.posixPermissions] as? NSNumber
            {
                isExecutable = (permissions.uint16Value & 0o111) != 0
            }
            expect(isExecutable, "the copied binary must be marked executable")

            let packDirectory = environment.userPacksDirectory.appendingPathComponent(
                "minimal-chime", isDirectory: true)
            expect(
                FileManager.default.fileExists(
                    atPath: packDirectory.appendingPathComponent("manifest.json").path),
                "the copied pack's manifest.json must exist under the user pack root")
        }
    }

    suite("performFirstRunSetup: already running from the fixed destination only ensures hooks (no copy)") {
        withTempDirectory { root in
            let claudioRoot = root.appendingPathComponent("claudio-root", isDirectory: true)
            let destination = claudioRoot.appendingPathComponent("bin/claudio")
            let environment = SetupEnvironment(
                executablePath: destination,
                claudioBinaryDestination: destination,
                userPacksDirectory: claudioRoot.appendingPathComponent("packs", isDirectory: true),
                configFile: claudioRoot.appendingPathComponent("config.json"),
                settingsFile: root.appendingPathComponent("settings.json"),
                configLockFile: claudioRoot.appendingPathComponent("config.lock"),
                settingsLockFile: claudioRoot.appendingPathComponent("settings.lock"),
                packsLockFile: claudioRoot.appendingPathComponent("packs.lock"))
            // T17d：这个 fixture 原本一个包都没有，而 `alreadyInstalled` 会把整个复制块跳过 ——
            // 于是它描述的其实是一台**装完也不会响**的机器，只是当年没人问这个问题。现在
            // `.noAvailablePack` 会拦住它（这正是该拦的），所以把 fixture 补成它本来想描述的样子：
            // 一台**已经装好、包也在**的机器再跑一次 setup。本 suite 要钉的东西一个字没变 ——
            // `copiedBinary: false` + `copiedPacks: []`，也就是「重跑不该重复复制任何东西」。
            writeFixture(
                #"{ "schema": 1, "id": "minimal-chime", "events": {} }"#,
                to: environment.userPacksDirectory
                    .appendingPathComponent("minimal-chime", isDirectory: true)
                    .appendingPathComponent("manifest.json"))

            let result = performFirstRunSetup(environment: environment)
            expect(
                result
                    == .success(
                        .completed(
                            copiedBinary: false, copiedPacks: [], salvaged: [], packSelection: .selectedDefault(packID: "minimal-chime"),
                            hooksOutcome: .installed)),
                "re-running setup from the already-installed location must skip copy steps, got \(result)"
            )
        }
    }

    suite(
        "performFirstRunSetup: not running from a bundle (no sibling packs/) still copies the binary — but refuses to write hooks with zero packs"
    ) {
        withTempDirectory { root in
            // Regression test (Codex + Claude adversarial review, /ship pre-landing:
            // three independent passes, one verified empirically): the binary copy must
            // NOT be gated on a sibling packs/ directory existing. A dev build (or a
            // corrupted bundle missing Resources/packs/) still needs the binary copied to
            // the fixed destination — otherwise hooks get installed pointing at nothing.
            //
            // T17d（第四轮对抗评审 · Codex）**推翻了这条测试原来的结论，但没有推翻它的本意**。
            // 它当年防的是「hooks 指向一个不存在的二进制」，答案是「无论如何都先把二进制复制过去」。
            // 它没问的是下一个问题：二进制在了，**可是一个声音包都没有**呢？答案是同样的静默——
            // `play` 拿不到包返回 `.notReady`，fire-and-forget 拿不到退出码，用户永远听不到一声响，
            // 而面板亮着绿点。所以现在：二进制照复制（下面第二条断言原样保留，仍然钉着它），
            // 但 hooks **一条都不写**，并且大声失败。与 `.binaryQuarantined` 同一条纪律。
            let executablePath = root.appendingPathComponent("some-random-place/claudio")
            try? FileManager.default.createDirectory(
                at: executablePath.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("#!fake".utf8).write(to: executablePath)
            let environment = makeEnvironment(root: root, executablePath: executablePath)

            let result = performFirstRunSetup(environment: environment)
            guard case .failure(.noAvailablePack) = result else {
                expect(false, "零个声音包的 setup 必须大声失败，绝不能报成功，得到 \(result)")
                return
            }
            // 本 suite 的原始本意，一字未改：复制二进制**不能**被 packs/ 目录的存在与否卡住。
            expect(
                FileManager.default.fileExists(atPath: environment.claudioBinaryDestination.path),
                "the binary must actually exist at the fixed destination even with no sibling packs/")
            // 新长出来的牙：失败必须发生在写 hooks **之前**。settings.json 压根不该被创建出来——
            // 一个注定哑掉的安装，绝不允许在用户的 Claude Code 里留下任何痕迹。
            expect(
                !FileManager.default.fileExists(atPath: environment.settingsFile.path),
                "零个声音包时必须在写 hooks 之前就失败——settings.json 不该被创建")
        }
    }

    suite("performFirstRunSetup: never clobbers a same-id pack the user already has") {
        withTempDirectory { root in
            let (executablePath, _) = makeBundleFixture(at: root.appendingPathComponent("bundle"))
            let environment = makeEnvironment(root: root, executablePath: executablePath)
            let userPackDirectory = environment.userPacksDirectory.appendingPathComponent(
                "minimal-chime", isDirectory: true)
            writeFixture(
                "the user's own customized pack file",
                to: userPackDirectory.appendingPathComponent("custom.txt"))
            // T17e：这个 fixture 原本**只有** custom.txt，没有 manifest.json —— 而 setup 恰恰不会
            // 去覆盖一个同名的用户包，于是它描述的其实是一台「包目录在、manifest 不在」的机器：
            // `play` 走到 `loadPlayManifest` 就返回 `.notReady`，一声不响。新闸门（正确地）拦住了它。
            // 本 suite 要钉的东西一个字没变 —— **用户自己的文件必须原样活下来** —— 所以把 fixture
            // 补成一个真实用户包本来的样子：它当然有自己的 manifest.json。
            writeFixture(
                #"{ "schema": 1, "id": "minimal-chime", "events": {} }"#,
                to: userPackDirectory.appendingPathComponent("manifest.json"))

            let result = performFirstRunSetup(environment: environment)
            guard case .success(.completed(_, let copiedPacks, _, _, _)) = result else {
                expect(false, "expected success, got \(result)")
                return
            }
            expect(
                copiedPacks.isEmpty,
                "a pack id that already exists under the user root must not be reported as copied")
            expect(
                (try? String(
                    contentsOf: userPackDirectory.appendingPathComponent("custom.txt"),
                    encoding: .utf8)) == "the user's own customized pack file",
                "the user's existing pack contents must survive setup completely untouched")
        }
    }

    suite(
        "performFirstRunSetup: a pack that already exists (not copied this run) still gets selected when config.json is missing"
    ) {
        withTempDirectory { root in
            // Regression test (red team / `/ship` pre-landing review, T17): a pack surviving
            // from an earlier — possibly interrupted — `setup` run must still become the
            // default once config.json is missing, even though `copiedPackIDs` (this run)
            // never touched it. Simulated here the same way the sibling test above does: a
            // pre-existing user pack, no config.json yet.
            let (executablePath, _) = makeBundleFixture(at: root.appendingPathComponent("bundle"))
            let environment = makeEnvironment(root: root, executablePath: executablePath)
            let userPackDirectory = environment.userPacksDirectory.appendingPathComponent(
                "minimal-chime", isDirectory: true)
            writeFixture(
                #"{ "schema": 1, "id": "minimal-chime", "events": {} }"#,
                to: userPackDirectory.appendingPathComponent("manifest.json"))

            let result = performFirstRunSetup(environment: environment)
            guard case .success(.completed(_, let copiedPacks, _, let packSelection, _)) = result else {
                expect(false, "expected success, got \(result)")
                return
            }
            expect(
                copiedPacks.isEmpty,
                "setup: the pre-existing pack must not be reported as copied this run")
            expect(
                packSelection == .selectedDefault(packID: "minimal-chime"),
                "a pack that already exists on disk must still be selected as default when config.json is missing, got \(String(describing: packSelection))"
            )
        }
    }

    suite(
        "performFirstRunSetup: re-running from the already-installed location selects a default pack that exists but has no config.json yet"
    ) {
        withTempDirectory { root in
            // Regression test for the exact failure red team traced through
            // docs/distribution.md's troubleshooting flow: a user re-runs `claudio setup`
            // from the INSTALLED binary (`~/.claudio/bin/claudio setup`, `alreadyInstalled ==
            // true`) after an earlier run left a pack on disk but never wrote config.json
            // (e.g. that earlier run failed between the pack-copy and config-selection
            // steps). Before this fix, `alreadyInstalled` skipped the copy block entirely,
            // `copiedPackIDs` stayed empty, and default-pack selection — gated on
            // `copiedPackIDs.first` — could never fire again on any future re-run.
            let claudioRoot = root.appendingPathComponent("claudio-root", isDirectory: true)
            let destination = claudioRoot.appendingPathComponent("bin/claudio")
            let environment = SetupEnvironment(
                executablePath: destination,
                claudioBinaryDestination: destination,
                userPacksDirectory: claudioRoot.appendingPathComponent("packs", isDirectory: true),
                configFile: claudioRoot.appendingPathComponent("config.json"),
                settingsFile: root.appendingPathComponent("settings.json"),
                configLockFile: claudioRoot.appendingPathComponent("config.lock"),
                settingsLockFile: claudioRoot.appendingPathComponent("settings.lock"),
                packsLockFile: claudioRoot.appendingPathComponent("packs.lock"))
            writeFixture(
                #"{ "schema": 1, "id": "minimal-chime", "events": {} }"#,
                to: environment.userPacksDirectory.appendingPathComponent(
                    "minimal-chime/manifest.json"))

            let result = performFirstRunSetup(environment: environment)
            guard case .success(.completed(let copiedBinary, let copiedPacks, _, let packSelection, _)) =
                result
            else {
                expect(false, "expected success, got \(result)")
                return
            }
            expect(
                !copiedBinary && copiedPacks.isEmpty,
                "alreadyInstalled must still skip the copy steps entirely, got copiedBinary=\(copiedBinary) copiedPacks=\(copiedPacks)"
            )
            expect(
                packSelection == .selectedDefault(packID: "minimal-chime"),
                "an alreadyInstalled re-run must still be able to select a pack that already exists on disk, got \(String(describing: packSelection))"
            )
            expect(
                FileManager.default.fileExists(atPath: environment.configFile.path),
                "config.json must actually get created by this recovery path, not just reported")
        }
    }

    suite("performFirstRunSetup: an existing config.json's selected_pack is left untouched") {
        withTempDirectory { root in
            let (executablePath, _) = makeBundleFixture(at: root.appendingPathComponent("bundle"))
            let environment = makeEnvironment(root: root, executablePath: executablePath)
            writeFixture(
                #"{ "selected_pack": "some-other-pack", "master_volume": 0.6 }"#,
                to: environment.configFile)
            // T17e：这个 fixture 原本让 `selected_pack` 指向一个**磁盘上根本不存在**的包 —— 也就是
            // 说，它字面上就是 Codex [P1] 的现场（config 指着一个没了的包，setup 照样写 hooks 并
            // 报成功），只是当年它被当作一次**成功**钉了下来。新闸门（正确地）把它判红了。
            //
            // 本 suite 的本意是「已经存在的选择，setup 一个字都不许动」—— 那个本意与包在不在磁盘上
            // 毫无关系，下面两条断言原样保留、原样钉着。所以把 fixture 补成它本来想描述的那台机器：
            // 用户选过一个包，**而那个包真的在**。「他选的包没了」现在由 T17e 那组 suite 专门负责，
            // 并且断言的是失败。
            writeFixture(
                #"{ "schema": 1, "id": "some-other-pack", "events": {} }"#,
                to: environment.userPacksDirectory.appendingPathComponent(
                    "some-other-pack/manifest.json"))

            let result = performFirstRunSetup(environment: environment)
            guard case .success(.completed(_, _, _, let packSelection, _)) = result else {
                expect(false, "expected success, got \(result)")
                return
            }
            expect(
                packSelection == .untouched,
                "setup must never touch config.json when one already exists, got packSelection=\(String(describing: packSelection))"
            )
            let data = try? Data(contentsOf: environment.configFile)
            let config = data.flatMap { try? JSONDecoder().decode(ClaudioConfig.self, from: $0) }
            expect(
                config?.selectedPack == "some-other-pack",
                "the user's existing pack selection must survive setup untouched")
        }
    }

    suite(
        "performFirstRunSetup: a dot-prefixed directory in the user pack root (a killed setup's"
            + " `.<id>.tmp-<pid>` leftover, or any hidden dir) is NEVER eligible as the default"
            + " selection — even though it sorts BEFORE a real pack id, the real pack is chosen"
    ) {
        withTempDirectory { root in
            // alreadyInstalled path (executablePath == destination) so the copy step is skipped
            // and default selection runs against whatever is already on disk.
            let claudioRoot = root.appendingPathComponent("claudio-root", isDirectory: true)
            let destination = claudioRoot.appendingPathComponent("bin/claudio")
            let environment = SetupEnvironment(
                executablePath: destination,
                claudioBinaryDestination: destination,
                userPacksDirectory: claudioRoot.appendingPathComponent("packs", isDirectory: true),
                configFile: claudioRoot.appendingPathComponent("config.json"),
                settingsFile: root.appendingPathComponent("settings.json"),
                configLockFile: claudioRoot.appendingPathComponent("config.lock"),
                settingsLockFile: claudioRoot.appendingPathComponent("settings.lock"),
                packsLockFile: claudioRoot.appendingPathComponent("packs.lock"))
            // A dot-prefixed leftover that sorts before the real pack ('.' 0x2E < 'z'): without
            // the `!hasPrefix(".")` filter it would be scanned first and either be selected or
            // fail selection outright. With the filter it is skipped and `zeta-chime` wins.
            writeFixture(
                #"{ "schema": 1, "id": ".aaa-tmp", "events": {} }"#,
                to: environment.userPacksDirectory.appendingPathComponent(".aaa-tmp/manifest.json"))
            writeFixture(
                #"{ "schema": 1, "id": "zeta-chime", "events": {} }"#,
                to: environment.userPacksDirectory.appendingPathComponent(
                    "zeta-chime/manifest.json"))

            let result = performFirstRunSetup(environment: environment)
            guard case .success(.completed(_, _, _, let packSelection, _)) = result else {
                expect(false, "expected success, got \(result)")
                return
            }
            expect(
                packSelection == .selectedDefault(packID: "zeta-chime"),
                "the dot-prefixed leftover must be excluded from default selection despite sorting"
                    + " first; the real pack must be chosen, got \(String(describing: packSelection))"
            )
        }
    }

    suite("performFirstRunSetup: multiple bundled packs default-select the alphabetically-first one") {
        withTempDirectory { root in
            let (executablePath, _) = makeBundleFixture(
                at: root.appendingPathComponent("bundle"), packIDs: ["zebra-chime", "alpha-chime"])
            let environment = makeEnvironment(root: root, executablePath: executablePath)

            let result = performFirstRunSetup(environment: environment)
            guard case .success(.completed(_, let copiedPacks, _, let packSelection, _)) = result else {
                expect(false, "expected success, got \(result)")
                return
            }
            expect(
                copiedPacks == ["alpha-chime", "zebra-chime"],
                "packs should be copied in deterministic (sorted) order, got \(copiedPacks)")
            expect(
                packSelection == .selectedDefault(packID: "alpha-chime"),
                "default selection should be the deterministic (sorted) first pack, got \(String(describing: packSelection))"
            )
        }
    }

    suite(
        "currentExecutablePath: an absolute argv[0] behind a symlink resolves to the real target"
    ) {
        withTempDirectory { root in
            let realTarget = root.appendingPathComponent("real/claudio")
            writeFixture("#!fake-binary-fixture", to: realTarget)
            let symlinkPath = root.appendingPathComponent("link/claudio")
            createSymlink(at: symlinkPath, pointingTo: realTarget)

            let result = currentExecutablePath(arguments: [symlinkPath.path], currentDirectory: "/")
            expect(
                result == realTarget.resolvingSymlinksInPath(),
                "an absolute argv[0] behind a symlink must resolve to the real target, got \(result)"
            )
        }
    }

    suite(
        "currentExecutablePath: a bare/relative argv[0] resolves against the given currentDirectory, not the real process cwd"
    ) {
        withTempDirectory { root in
            let subdirectory = root.appendingPathComponent("subdir", isDirectory: true)
            let executablePath = subdirectory.appendingPathComponent("claudio")
            writeFixture("#!fake-binary-fixture", to: executablePath)

            let result = currentExecutablePath(
                arguments: ["claudio"], currentDirectory: subdirectory.path)
            expect(
                result == executablePath.resolvingSymlinksInPath(),
                "a relative argv[0] must resolve against the passed-in currentDirectory, got \(result)"
            )
        }
    }

    suite(
        "performFirstRunSetup: a binary destination whose parent directory is blocked by a regular file fails with .binaryCopyFailure"
    ) {
        withTempDirectory { root in
            let (executablePath, _) = makeBundleFixture(at: root.appendingPathComponent("bundle"))
            // A regular file occupies the path where the binary destination's containing
            // directory needs to be created — `createDirectory` cannot turn a file into a
            // directory, so `copySelfToFixedLocation` surfaces a real error via
            // `.binaryCopyFailure` (mirrors `PlaySuite`'s equivalent blocking-file fixture
            // for `.lockFailed`). Every other suite in this file only exercises
            // `performFirstRunSetup`'s `.success` side — this is its top-level `.failure`
            // passthrough at the binary-copy step.
            let blockingFile = root.appendingPathComponent("blocking-file")
            writeFixture("not a directory", to: blockingFile)
            let claudioRoot = root.appendingPathComponent("claudio-root", isDirectory: true)
            let environment = SetupEnvironment(
                executablePath: executablePath,
                claudioBinaryDestination: blockingFile.appendingPathComponent("subdir/bin/claudio"),
                userPacksDirectory: claudioRoot.appendingPathComponent("packs", isDirectory: true),
                configFile: claudioRoot.appendingPathComponent("config.json"),
                settingsFile: root.appendingPathComponent("settings.json"),
                configLockFile: claudioRoot.appendingPathComponent("config.lock"),
                settingsLockFile: claudioRoot.appendingPathComponent("settings.lock"),
                packsLockFile: claudioRoot.appendingPathComponent("packs.lock"))

            let result = performFirstRunSetup(environment: environment)
            guard case .failure(.binaryCopyFailure) = result else {
                expect(
                    false,
                    "a blocked binary destination parent must fail with .binaryCopyFailure, got \(result)"
                )
                return
            }
        }
    }

    // MARK: - 首次运行自举的判据是「还没有人选过包」，不是「config.json 不存在」
    //
    // 这条政策的成因（本轮 /ship 评审：Codex 对抗 + Claude 对抗独立命中）：hooks 装好但还没选包时，
    // 用户点一次静音钮**曾经**会创建一份 `selected_pack: ""` 的 config.json（`setEventEnabled`
    // 没有 pack 上下文，凭空编一个默认值等于伪造一次谁也没做过的选择）。旧判据
    // `!fileExists(configFile)` 从此永远为假——自举再也不会挑默认包，`play` 永远解析不出 pack，
    // **永久静音**，且没有任何东西会自愈。`noPackHasEverBeenSelected` 把判据换成「文件不存在 或
    // selected_pack 为空」修好了这个洞。
    //
    // D23 定稿①（见 `EventEnabled.swift`）已经把「静音钮创建这份 config」这条产地从根上拔除——
    // `setEventEnabled` 现在对缺失的 config.json fail closed，磁盘上不会再凭空长出
    // `selected_pack: ""`。这条政策本身仍然必须留着：一份手工编辑 / 第三方写出的 config.json
    // 一样可能把 `selected_pack` 留空，且 `.noConfig`（全新机器）走的是同一支。

    suite(
        "performFirstRunSetup: 一份已存在、selected_pack 为空串的 config.json（旧判据下永久静音的现场）"
            + " → 仍然选出默认包（regression pin：旧的 `!fileExists` 判据在这里必定失败）"
    ) {
        withTempDirectory { root in
            let (executablePath, _) = makeBundleFixture(at: root.appendingPathComponent("bundle"))
            let environment = makeEnvironment(root: root, executablePath: executablePath)
            // 模拟「hooks 已装好、用户点过一次静音，但从未选过包」的现场：`selected_pack` 是空串，
            // 而不是文件缺失——旧判据 `!fileExists(configFile)` 在这里恒为 false，自举永远不会触发。
            writeFixture(
                #"{ "selected_pack": "", "master_volume": 0.8, "events": { "stop": false } }"#,
                to: environment.configFile)

            let result = performFirstRunSetup(environment: environment)
            guard case .success(.completed(_, _, _, let packSelection, _)) = result else {
                expect(false, "expected success, got \(result)")
                return
            }
            expect(
                packSelection == .selectedDefault(packID: "minimal-chime"),
                "selected_pack 为空串必须被当成「还没有人选过包」，触发默认选包——旧判据下这里会"
                    + " packSelection == .untouched，got \(String(describing: packSelection))")

            let data = try? Data(contentsOf: environment.configFile)
            let config = data.flatMap { try? JSONDecoder().decode(ClaudioConfig.self, from: $0) }
            expect(
                config?.selectedPack == "minimal-chime",
                "磁盘上的 config.json 必须真的反映这次选包，got \(String(describing: config?.selectedPack))"
            )
            expect(
                config?.masterVolume == 0.8,
                "自举选包只拥有 selected_pack 这一个键——用户已经设过的 master_volume 必须原样保留")
        }
    }

    suite(
        "performFirstRunSetup: setEventEnabled 现在对缺失的 config fail closed（D23 定稿①）——"
            + " 静音钮再也造不出 selected_pack:\"\" 的 config，随后跑的仍是一次干净的全新安装"
    ) {
        withTempDirectory { root in
            let (executablePath, _) = makeBundleFixture(at: root.appendingPathComponent("bundle"))
            let environment = makeEnvironment(root: root, executablePath: executablePath)

            // 第一步：hooks 装好、还没有 config.json，用户点一次静音钮——这是 bug 报告里那个
            // 完全正常的用户操作，不是构造出来的畸形 fixture。它现在必须被拒绝，且不许在磁盘上
            // 留下任何 config.json（不再新建，不再伪造一次没人做过的选择）。
            let muteResult = setEventEnabled(
                .stop, enabled: false, configFile: environment.configFile,
                lockFile: environment.configLockFile)
            expect(
                muteResult == .failure(.configMissing),
                "config 缺失时静音必须 fail closed，got \(muteResult)")
            expect(
                !FileManager.default.fileExists(atPath: environment.configFile.path),
                "被拒绝的静音写入不许在磁盘上留下任何 config.json")

            // 第二步：（比如应用重启后）跑首次运行自举——它面对的是一台真正干净的全新机器，
            // 而不是一份被静音钮悄悄伪造出来的空包 config。
            let result = performFirstRunSetup(environment: environment)
            guard case .success(.completed(_, _, _, let packSelection, _)) = result else {
                expect(false, "expected success, got \(result)")
                return
            }
            expect(
                packSelection == .selectedDefault(packID: "minimal-chime"),
                "全新安装必须选出一个真实默认包，got \(String(describing: packSelection))")

            let afterSetup = try? Data(contentsOf: environment.configFile)
            let configAfterSetup = afterSetup.flatMap { try? JSONDecoder().decode(ClaudioConfig.self, from: $0) }
            expect(
                configAfterSetup?.selectedPack == "minimal-chime",
                "磁盘上的 config.json 必须真的反映自举选出的包")
        }
    }

    suite(
        "performFirstRunSetup: 一份读不出来 / 畸形的 config.json → 自举不选包、一个字节不改它 ——"
            + " 但也**不许把它报成成功**（T17e：本 suite 的本意原样保留，结论被推翻）"
    ) {
        withTempDirectory { root in
            // T17e（第五轮对抗评审 · Codex [P1] 的邻居）：这条 suite 上一版断言的是
            // 「hooks 安装本身与 config 是否可读无关，必须照常完成」——**那句话是错的**。
            //
            // `play` 的第一步就是 `loadPlayConfig`：一份解不开的 config.json → 返回 nil →
            // `.notReady` → 每一个事件**静默无声**。而 `play` 是 fire-and-forget，拿不到退出码、
            // 不写日志；面板此刻还会亮绿点说「已经接好了」（`detectOnboardingState` 只查二进制 +
            // hooks，不查 config）。所以「照常写 hooks 并报成功」正是 T17 存在的理由那句话
            // 的又一个形状：**装完后是哑的**。
            //
            // 本 suite 的**本意一字未改**，而且仍然被下面两条断言钉着：自举**不会**替用户选包，
            // 也**绝不**覆盖那份他读不懂的文件。改的只是结论——不写 hooks，大声失败。
            let (executablePath, _) = makeBundleFixture(at: root.appendingPathComponent("bundle"))
            let environment = makeEnvironment(root: root, executablePath: executablePath)
            let original = "{ not valid json"
            writeFixture(original, to: environment.configFile)

            let result = performFirstRunSetup(environment: environment)
            guard case .failure(.configUnusable) = result else {
                expect(
                    false,
                    "一份读不出来的 config = 每个事件都静默无声，绝不能报成功，got \(result)")
                return
            }
            // 本意 ①：自举没有能力修一份读不懂的 config，也绝不能把它当成新安装覆盖掉。
            expect(
                (try? String(contentsOf: environment.configFile, encoding: .utf8)) == original,
                "失败路径同样必须逐字保住用户那份 config——一个字节都不许动")
            // 本意 ②（新长出来的牙）：失败必须发生在写 hooks **之前**。
            expect(
                !FileManager.default.fileExists(atPath: environment.settingsFile.path),
                "config 读不出来时必须在写 hooks 之前就失败——settings.json 不该被创建")
            // 二进制照复制（与 `.noAvailablePack` 那条 suite 同一条纪律：复制二进制不被任何东西卡住）。
            expect(
                FileManager.default.fileExists(atPath: environment.claudioBinaryDestination.path),
                "复制二进制这一步在闸门之前，不该被这次失败连累")
        }
    }

    suite("performFirstRunSetup: re-running from inside the bundle a second time is idempotent") {
        withTempDirectory { root in
            let (executablePath, _) = makeBundleFixture(at: root.appendingPathComponent("bundle"))
            let environment = makeEnvironment(root: root, executablePath: executablePath)

            _ = performFirstRunSetup(environment: environment)
            let second = performFirstRunSetup(environment: environment)
            guard case .success(.completed(let copiedBinary, let copiedPacks, _, let packSelection, let hooksOutcome)) = second
            else {
                expect(false, "expected success on second run, got \(second)")
                return
            }
            expect(copiedBinary, "the binary copy step itself is not guarded — copying over itself is safe")
            expect(
                copiedPacks.isEmpty,
                "the pack should not be reported as newly copied the second time (destination already exists)"
            )
            expect(
                packSelection == .untouched,
                "config.json already exists after the first run, so the second run must not touch selected_pack"
            )
            expect(
                hooksOutcome == .alreadyInstalled,
                "hooks should already be installed on the second run")
        }
    }

    runSetupPackSelectionSuites()
}

// MARK: - T17e：setup 报成功时，selected_pack 一定指向一个 play 真的解析得出来的包
//
// 第五轮对抗评审（`/codex review e6d57ba,72d68e7` 的 [P1]）：`.noAvailablePack` 的守卫整个长在
// 「从没选过包」那条分支里。只要 `config.json` 里已经躺着一个**非空**的 `selected_pack`，那道守卫就
// **整段够不到** —— 哪怕它指向的目录早就没了。setup 照样写四条 hooks、照样报成功，而 `play` 每次都在
// `resolvePackDirectory` 上返回 `.notReady`：每一个事件静默无声。
//
// ## 第一版修法是错的，而且错得比原 bug 更狠（本轮对抗评审，两个独立 agent 各自实测复现）
//
// 第一版的答案是「硬失败：绝不替用户改选，那是伪造一次他没做过的选择」。推理听着对，后果是灾难：
// **换包的唯一界面（`PackGalleryView`）只在面板 `.installed` 时渲染**，而 `.installed` 需要 hooks。
// 于是「他选的包没了 + hooks 还没装」的用户被硬失败挡住 → 永远进不了 `.installed` → **永远够不到
// 那个能救他的画廊**，只剩一句要开终端的 `claudio use`。而在硬失败之前，他本来会拿到四行 `.unmapped`
// ＋画廊里躺着的 minimal-chime —— 点一下就好了。
// **一道用「用户看不见」论证出来的闸门，自己造出了真正的「用户够不着」。**
//
// 所以判据换成一句更强、也更好证的话：**setup 报成功时，`selected_pack` 一定指向一个 `play` 解析得
// 出来的包。** 达成它的手段按代价从小到大：①他的选择还好好的 → 什么都不动；②从没选过 → 挑一个能用
// 的；③**他选的包没了 / 坏了、但还有能用的 → 替他换上，并如实说出来**（他随时能在画廊里换回去）；
// ④一个能用的包都没有 → 这时画廊本来就是空的、hooks 写了也只是纯静音 → **才**硬失败。
//
// 「能用」＝ `resolvePackDirectory` ＋ `loadPackManifest` 都成功（与 `play` / `doctor` 逐字同源）。
// 音频文件在不在**不算** —— 那是「内容」：面板会逐行画成 `.unmapped` / `.broken`，用户看得见、拖一个
// 文件就能修。下面用两条「内容层」防线把这条线的另一侧也钉死，防的是**这次修复自己**收得过紧。

@MainActor
private func makeInstalledEnvironment(root: URL) -> SetupEnvironment {
    // alreadyInstalled 形状（executablePath == destination）：复制块整段跳过 —— 与「用户从
    // ~/.claudio/bin/claudio 重跑一次」的真实动线一致，也正是 [P1] 的现场。
    let claudioRoot = root.appendingPathComponent("claudio-root", isDirectory: true)
    let destination = claudioRoot.appendingPathComponent("bin/claudio")
    return SetupEnvironment(
        executablePath: destination,
        claudioBinaryDestination: destination,
        userPacksDirectory: claudioRoot.appendingPathComponent("packs", isDirectory: true),
        configFile: claudioRoot.appendingPathComponent("config.json"),
        settingsFile: root.appendingPathComponent("settings.json"),
        configLockFile: claudioRoot.appendingPathComponent("config.lock"),
        settingsLockFile: claudioRoot.appendingPathComponent("settings.lock"))
}

@MainActor
private func writePack(
    _ id: String, in packsDirectory: URL, events: String = #""stop": "stop.mp3""#
) {
    writeFixture(
        #"{ "schema": 1, "id": "\#(id)", "events": { \#(events) } }"#,
        to: packsDirectory.appendingPathComponent("\(id)/manifest.json"))
}

@MainActor
func runSetupPackSelectionSuites() {

    // MARK: 策略本身 —— 一张表逐格钉死
    //
    // 抽成纯函数不是为了好看，是为了它**能被测**：`.failConfigUnusable` / `.noConfig` 这些格子在真实
    // 临时目录里要么造不出来、要么造起来极其别扭。仓库里已有先例——`quarantineVerdict` 正是为了同一个
    // 理由被抽出来的（判据留在 IO 函数里时，把某个分支改回去，全套测试照样绿，实测确认过）。

    suite("T17e/策略: packSelectionPlan —— 六个格子逐格钉死") {
        let usable = ["minimal-chime", "zeta"]
        let none: [String] = []

        // ① 选择还好好的 → 一个字节都不动
        expect(
            packSelectionPlan(
                status: .complete(packID: "wobbuffet", events: ["stop"]), usablePackIDs: usable)
                == .keepExistingSelection,
            "一个完好的选择必须原样不动")
        expect(
            packSelectionPlan(
                status: .incomplete(packID: "wobbuffet", missingFiles: ["stop.mp3"]),
                usablePackIDs: usable) == .keepExistingSelection,
            "「声明了 stop.mp3、文件还没到」是**内容**层缺口（面板画成 .broken）——绝不能因此动他的选择")

        // ② 从没选过包（config 不在 / selected_pack 是空串）→ 挑第一个**能用**的
        expect(
            packSelectionPlan(status: .noConfig, usablePackIDs: usable)
                == .selectDefault(packID: "minimal-chime"),
            "全新机器：挑第一个能用的包")
        expect(
            packSelectionPlan(status: .packNotFound(packID: ""), usablePackIDs: usable)
                == .selectDefault(packID: "minimal-chime"),
            "selected_pack 是空串 = 还没有人选过包（无论这份空串来自全新机器还是一份手工编辑的"
                + " config）——必须挑默认包，而不是当成「他选的包坏了」")

        // ③ 他选的包没了 / 坏了、但还有能用的 → **替他换上**（被推翻的就是这一格）
        expect(
            packSelectionPlan(status: .packNotFound(packID: "wobbuffet"), usablePackIDs: usable)
                == .repairDeadSelection(removed: "wobbuffet", selected: "minimal-chime"),
            "他选的包不在了、而画廊里还有别的包——必须修好它，绝不能把他挡在画廊之外")
        expect(
            packSelectionPlan(
                status: .manifestUnreadable(packID: "wobbuffet", reason: "坏了"),
                usablePackIDs: usable)
                == .repairDeadSelection(removed: "wobbuffet", selected: "minimal-chime"),
            "manifest 坏掉的包与目录不在，对 `play` 是同一件事——同样修好它")

        // ④ 一个能用的包都没有 → 才硬失败
        expect(
            packSelectionPlan(status: .noConfig, usablePackIDs: none) == .failNoPackAtAll,
            "从没选过包 ＋ 一个包都没有 → 硬失败")
        expect(
            packSelectionPlan(status: .packNotFound(packID: "wobbuffet"), usablePackIDs: none)
                == .failDeadSelectionNoFallback(packID: "wobbuffet"),
            "他选的包没了、也没有任何能顶上的 → 硬失败，且必须说出是哪个包")
        expect(
            packSelectionPlan(
                status: .manifestUnreadable(packID: "wobbuffet", reason: "坏了"),
                usablePackIDs: none) == .failDeadSelectionNoFallback(packID: "wobbuffet"),
            "同上")

        // ⑤ config 读不出来 → 不选包、不覆盖它，也绝不在它之上写 hooks
        expect(
            packSelectionPlan(status: .configUnreadable(reason: "坏 JSON"), usablePackIDs: usable)
                == .failConfigUnusable(reason: "坏 JSON"),
            "读不出来的 config：`play` 第一步就返回 nil，每个事件静默无声——不许写 hooks")
        expect(
            packSelectionPlan(status: .configUnreadable(reason: "坏 JSON"), usablePackIDs: none)
                == .failConfigUnusable(reason: "坏 JSON"),
            "有没有可用包都一样：自举没有能力修一份读不懂的 config")
    }

    // MARK: 修复 —— [P1] 的现场，也是第一版修法翻车的地方

    suite(
        "T17e/修复: config 指向的包已经不在了、但画廊里还有别的包 → 替他换上一个能响的、hooks 照写"
            + "（**绝不能**把他挡在唯一能换包的那个界面之外）"
    ) {
        withTempDirectory { root in
            let environment = makeInstalledEnvironment(root: root)
            writeFixture(
                #"{ "selected_pack": "wobbuffet", "master_volume": 0.7 }"#, to: environment.configFile)
            writePack("minimal-chime", in: environment.userPacksDirectory)

            let result = performFirstRunSetup(environment: environment)
            guard case .success(.completed(_, _, _, let packSelection, let hooksOutcome)) = result else {
                expect(
                    false,
                    "还有能用的包时必须修好它并装完——硬失败会把用户永久挡在画廊之外，got \(result)")
                return
            }
            expect(
                packSelection
                    == .repairedDeadSelection(removed: "wobbuffet", selected: "minimal-chime"),
                "「我替你换了包」必须被结构化地说出来（CLI 会把它印成一行 ⚠），got \(packSelection)")
            expect(
                hooksOutcome == .installed,
                "hooks 必须照写——否则他永远进不了 .installed，也就永远看不到画廊")

            let data = try? Data(contentsOf: environment.configFile)
            let config = data.flatMap { try? JSONDecoder().decode(ClaudioConfig.self, from: $0) }
            expect(
                config?.selectedPack == "minimal-chime",
                "磁盘上的 config 必须真的指向那个能响的包，got \(String(describing: config?.selectedPack))")
            expect(
                config?.masterVolume == 0.7,
                "修选包只拥有 selected_pack 这一个键——用户设过的 master_volume 必须原样保留")
        }
    }

    suite(
        "T17e/修复: 一个能用的包都没有 → 这时才硬失败（画廊本来就是空的，写 hooks 只会得到纯静音）"
    ) {
        withTempDirectory { root in
            let environment = makeInstalledEnvironment(root: root)
            let original = #"{ "selected_pack": "wobbuffet" }"#
            writeFixture(original, to: environment.configFile)

            let result = performFirstRunSetup(environment: environment)
            guard case .failure(.selectedPackUnresolvable(let packID, let reason)) = result else {
                expect(false, "一个能用的包都没有 = 注定是哑的，绝不能报成功，got \(result)")
                return
            }
            expect(packID == "wobbuffet", "必须指名道姓说出是哪个包没了，got \(packID)")
            expect(
                reason.contains("/Applications/Claudio.app"),
                "失败必须给出一条**真的有效**的出路：从 app bundle 跑 setup 会把内置包补回来。"
                    + "（刻意不说「重新安装 Claudio」——cask 没有 zap，brew reinstall 一个字节都不碰"
                    + " ~/.claudio/，而所有中毒态都活在那里。）got \(reason)")
            expect(
                !FileManager.default.fileExists(atPath: environment.settingsFile.path),
                "必须在写 hooks 之前就失败——settings.json 不该被创建")
            expect(
                (try? String(contentsOf: environment.configFile, encoding: .utf8)) == original,
                "失败路径不许改用户的 config——一个字节都不动")
        }
    }

    suite(
        "T17e/修复: 用户真实的 settings.json 在失败路径上必须**逐字节**不变"
            + "（而不是「文件不存在」这种在真机上永远不成立的弱断言）"
    ) {
        withTempDirectory { root in
            let environment = makeInstalledEnvironment(root: root)
            writeFixture(#"{ "selected_pack": "wobbuffet" }"#, to: environment.configFile)
            let userSettings =
                #"{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "echo mine" } ] } ] } }"#
            writeFixture(userSettings, to: environment.settingsFile)

            let result = performFirstRunSetup(environment: environment)
            guard case .failure(.selectedPackUnresolvable) = result else {
                expect(false, "expected .selectedPackUnresolvable, got \(result)")
                return
            }
            expect(
                (try? String(contentsOf: environment.settingsFile, encoding: .utf8)) == userSettings,
                "一次注定不会响的安装，绝不允许在用户的 Claude Code 配置里留下任何痕迹——逐字节不变")
        }
    }

    // MARK: 选包与判据必须同源 —— 第一版的第二个 P1：setup 自己选中一个残骸，再被自己判死

    suite(
        "T17e/同源: packs/ 里有一个读不出 manifest 的残骸目录（字典序还排在真包前面）→"
            + " 选包必须跳过它、选中真正能用的那个（而不是选中残骸，再把一台全新机器判成装不上）"
    ) {
        withTempDirectory { root in
            let environment = makeInstalledEnvironment(root: root)
            try? FileManager.default.createDirectory(
                at: environment.userPacksDirectory.appendingPathComponent("aaa-not-a-pack"),
                withIntermediateDirectories: true)
            writePack("minimal-chime", in: environment.userPacksDirectory)

            let result = performFirstRunSetup(environment: environment)
            guard case .success(.completed(_, _, _, let packSelection, _)) = result else {
                expect(false, "一台**有一个好包**的机器必须装得上，got \(result)")
                return
            }
            expect(
                packSelection == .selectedDefault(packID: "minimal-chime"),
                "选包与判据必须同源：读不出 manifest 的目录不是包，绝不能被选中，got \(packSelection)")
        }
    }

    suite(
        "T17e/同源: packs/<id> 是一条逃出 packs/ 之外的符号链接 → `play` 的 resolvePackDirectory"
            + " 根本解析不出来（isReallyContained）→ 它不算能用的包（钉死 bundledPacksDirectory: nil 这条链）"
    ) {
        withTempDirectory { root in
            let environment = makeInstalledEnvironment(root: root)
            // 一个货真价实的包，但它躺在 packs/ **之外**，只用一条符号链接伪装成 packs/escapee。
            let outside = root.appendingPathComponent("outside", isDirectory: true)
            writePack("escapee", in: outside)
            try? FileManager.default.createDirectory(
                at: environment.userPacksDirectory, withIntermediateDirectories: true)
            createSymlink(
                at: environment.userPacksDirectory.appendingPathComponent("escapee"),
                pointingTo: outside.appendingPathComponent("escapee", isDirectory: true))

            let result = performFirstRunSetup(environment: environment)
            guard case .failure(.noAvailablePack) = result else {
                expect(
                    false,
                    "一条逃出 packs/ 的符号链接，`play` 根本解析不出来——setup 若把它当成能用的包，"
                        + "写下的就是一台注定静默的机器，got \(result)")
                return
            }
        }
    }

    // MARK: 被中断的复制留下的残骸 —— 重跑必须能治好它（docs 的承诺）

    suite(
        "T17e/自愈: 上一次复制被杀掉、留下半个包（有音频、没 manifest）→ 从 bundle 重跑 setup 必须"
            + "把残骸挪开、重新复制一份完整的、然后装成功（**而不是每一次重跑都一字不差地失败**）"
    ) {
        withTempDirectory { root in
            let (executablePath, _) = makeBundleFixture(at: root.appendingPathComponent("bundle"))
            let environment = makeEnvironment(root: root, executablePath: executablePath)
            // 半个包：`copyItem` 逐文件写最终路径（不是原子的），被杀掉就留下这个形状。
            writeFixture(
                "half-copied-audio",
                to: environment.userPacksDirectory.appendingPathComponent("minimal-chime/stop.mp3"))

            let result = performFirstRunSetup(environment: environment)
            guard
                case .success(
                    .completed(_, let copiedPacks, let salvaged, let packSelection, let hooksOutcome))
                    = result
            else {
                expect(
                    false,
                    "docs/distribution.md 白纸黑字承诺「重跑一次 setup 就能治好坏安装」——"
                        + "一个残缺包绝不能把 setup 永久焊死，got \(result)")
                return
            }
            expect(
                copiedPacks == ["minimal-chime"],
                "残骸必须被挪开、包被重新复制一遍（上一版会因为「目录已存在」而永远跳过它），got \(copiedPacks)"
            )
            expect(packSelection == .selectedDefault(packID: "minimal-chime"), "got \(packSelection)")
            expect(hooksOutcome == .installed, "治好之后必须真的装上")
            // **搬走一个用户目录，必须被说出来。** 那个目录里完全可能装着他自己导入的、磁盘上唯一一份
            // 音频（`AudioImport` 就是往 packs/<id>/ 里写转码后的字节）。上一版把它搬进一个点开头的隐藏
            // 目录、然后一个字都不说 —— 而 `PackGallery` 显式过滤点开头目录，于是它在**任何界面里都不
            // 存在**（T17e 第二轮对抗评审）。
            expect(
                salvaged.count == 1 && salvaged.first?.packID == "minimal-chime",
                "被挪开这件事必须是 outcome 的一等公民（CLI 会把它印成一行 ⚠），got \(salvaged)")
            expect(
                salvaged.first.map {
                    regularFileExists(
                        at: URL(fileURLWithPath: $0.movedTo).appendingPathComponent("stop.mp3"))
                } == true,
                "报告出来的那条路径必须**真的**指向被搬走的那份东西——用户要照着它去找回自己的文件，"
                    + "got \(String(describing: salvaged.first?.movedTo))")
            expect(
                regularFileExists(
                    at: environment.userPacksDirectory.appendingPathComponent(
                        "minimal-chime/manifest.json")),
                "补回来的必须是一个**完整**的包——manifest 真的在")
            // 残骸是被**挪开**，不是被删掉：里面可能有用户自己塞进去的东西，谁也没资格替他判「这个不重要」。
            let leftovers =
                ((try? FileManager.default.contentsOfDirectory(
                    atPath: environment.userPacksDirectory.path)) ?? [])
                .filter { $0.hasPrefix(".") && $0.contains("broken") }
            expect(
                leftovers.count == 1,
                "残骸必须被挪到一个点开头的名字下（→ 选包时天然排除），而不是被删掉，got \(leftovers)")
            // 而且**里面的东西必须原封不动**——「挪开」不是「挪开一个空壳」。
            expect(
                leftovers.first.map {
                    (try? String(
                        contentsOf: environment.userPacksDirectory
                            .appendingPathComponent($0).appendingPathComponent("stop.mp3"),
                        encoding: .utf8)) == "half-copied-audio"
                } == true,
                "被挪开的残骸里，用户的文件必须一个字节都不少")
        }
    }

    suite(
        "T17e/自愈: 连挪两次残骸（pid 复用 / 同一次运行里撞名）→ 绝不覆盖上一次挪走的那一份"
            + "（那里面装着用户的文件——一句顺手的 removeItem 就是一条数据丢失路径）"
    ) {
        withTempDirectory { root in
            let (executablePath, _) = makeBundleFixture(at: root.appendingPathComponent("bundle"))
            let environment = makeEnvironment(root: root, executablePath: executablePath)
            // 上一次挪走的残骸（名字正是本进程 pid 会用的那个），里面有用户的东西。
            let pid = ProcessInfo.processInfo.processIdentifier
            writeFixture(
                "user's precious file from an earlier rescue",
                to: environment.userPacksDirectory.appendingPathComponent(
                    ".minimal-chime.broken-\(pid)/precious.txt"))
            // 这一次又出现了一个新残骸。
            writeFixture(
                "half-copied-audio",
                to: environment.userPacksDirectory.appendingPathComponent("minimal-chime/stop.mp3"))

            let result = performFirstRunSetup(environment: environment)
            guard case .success = result else {
                expect(false, "expected success, got \(result)")
                return
            }
            expect(
                (try? String(
                    contentsOf: environment.userPacksDirectory.appendingPathComponent(
                        ".minimal-chime.broken-\(pid)/precious.txt"), encoding: .utf8))
                    == "user's precious file from an earlier rescue",
                "上一次挪走的残骸必须原封不动——新的那一份要自己另找一个名字")
            let rescued =
                ((try? FileManager.default.contentsOfDirectory(
                    atPath: environment.userPacksDirectory.path)) ?? [])
                .filter { $0.hasPrefix(".") && $0.contains("broken") }
            expect(rescued.count == 2, "两份残骸都要活着，got \(rescued)")
        }
    }

    suite(
        "T17e/原子: 复制在树的中途失败 → 最终路径 packs/<id> 上**一个字节都不能有**"
            + "（否则下一次重跑会把这堆半成品当成「已经在了」而永远跳过——正是上面那条死锁的成因）"
    ) {
        withTempDirectory { root in
            // 对抗评审实测：把 staging＋rename 退回「直接 copyItem 到最终路径」，全套测试**照样全绿**——
            // 也就是说原子性此前没有被任何一条断言钉住。这条 suite 就是那颗钉子。
            let bundleRoot = root.appendingPathComponent("bundle")
            let (executablePath, bundledPacks) = makeBundleFixture(at: bundleRoot)
            // 让复制在树的中途炸掉：包里放一个**读不出来**的文件（chmod 000）。copyItem 会先建好目录、
            // 复制一部分，然后在它身上失败——正是「被中断的复制」的形状，只是这次可复现。
            let unreadable = bundledPacks.appendingPathComponent("minimal-chime/locked.mp3")
            writeFixture("secret", to: unreadable)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
            let environment = makeEnvironment(root: root, executablePath: executablePath)

            let result = performFirstRunSetup(environment: environment)
            guard case .failure(.packCopyFailure) = result else {
                expect(false, "一次读不出源文件的复制必须如实失败，got \(result)")
                return
            }
            let destination = environment.userPacksDirectory.appendingPathComponent("minimal-chime")
            expect(
                !FileManager.default.fileExists(atPath: destination.path),
                "复制失败时最终路径上必须干干净净——半个包留在那里，就是下一次重跑的永久死锁")
            // 暂存目录也要收拾干净（它点开头，不会污染选包，但也不该越积越多）。
            let staging =
                ((try? FileManager.default.contentsOfDirectory(
                    atPath: environment.userPacksDirectory.path)) ?? [])
                .filter { $0.contains(".tmp-") }
            expect(staging.isEmpty, "失败路径必须清掉自己的暂存目录，got \(staging)")

            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: unreadable.path)  // 让 withTempDirectory 收得掉
        }
    }

    suite(
        "T17e/自愈: packs/<id> 是一条**悬空**符号链接 → 同样必须被挪开（fileExists 跟随链接、会说它「不存在」，"
            + "于是它从判据的缝里漏过去、直奔 moveItem 抛 EEXIST → 每次重跑一字不差地失败）"
    ) {
        withTempDirectory { root in
            let (executablePath, _) = makeBundleFixture(at: root.appendingPathComponent("bundle"))
            let environment = makeEnvironment(root: root, executablePath: executablePath)
            try? FileManager.default.createDirectory(
                at: environment.userPacksDirectory, withIntermediateDirectories: true)
            // 一条指向不存在之物的链接：lstat 看得见它，stat 看不见。
            createSymlink(
                at: environment.userPacksDirectory.appendingPathComponent("minimal-chime"),
                pointingTo: root.appendingPathComponent("gone-forever", isDirectory: true))

            let result = performFirstRunSetup(environment: environment)
            guard case .success(.completed(_, let copiedPacks, let salvaged, _, _)) = result else {
                expect(
                    false,
                    "一条悬空链接在 lstat 意义上**存在**、且显然不是一个能用的包——它必须走「挪开」这一格，"
                        + "而不是让 moveItem 撞上 EEXIST 把 setup 永久焊死，got \(result)")
                return
            }
            expect(copiedPacks == ["minimal-chime"], "挪开之后必须真的补一份干净的包，got \(copiedPacks)")
            expect(salvaged.map(\.packID) == ["minimal-chime"], "被挪开这件事必须被报告，got \(salvaged)")
            expect(
                regularFileExists(
                    at: environment.userPacksDirectory.appendingPathComponent(
                        "minimal-chime/manifest.json")),
                "最终路径上必须是一个真的包，而不是那条链接")
        }
    }

    suite("T17e/自愈: 一个 manifest 读得出来的同名用户包，绝不能被 bundle 里的同名包覆盖") {
        withTempDirectory { root in
            // 「挪开残骸」这条新逻辑最危险的失败模式，就是它误伤一个**真的**用户定制包。
            let (executablePath, _) = makeBundleFixture(at: root.appendingPathComponent("bundle"))
            let environment = makeEnvironment(root: root, executablePath: executablePath)
            let userPack = environment.userPacksDirectory.appendingPathComponent("minimal-chime")
            writeFixture(
                #"{ "schema": 1, "id": "minimal-chime", "events": { "stop": "mine.mp3" } }"#,
                to: userPack.appendingPathComponent("manifest.json"))
            writeFixture("the user's own sound", to: userPack.appendingPathComponent("mine.mp3"))

            let result = performFirstRunSetup(environment: environment)
            guard case .success(.completed(_, let copiedPacks, _, _, _)) = result else {
                expect(false, "expected success, got \(result)")
                return
            }
            expect(copiedPacks.isEmpty, "同名的**能用**的用户包必须原样跳过，got \(copiedPacks)")
            expect(
                (try? String(contentsOf: userPack.appendingPathComponent("mine.mp3"), encoding: .utf8))
                    == "the user's own sound",
                "用户自己的文件必须一个字节都不动")
            expect(
                (try? String(
                    contentsOf: userPack.appendingPathComponent("manifest.json"), encoding: .utf8))?
                    .contains("mine.mp3") == true,
                "用户自己的 manifest 必须原样活下来——绝不能被 bundle 的版本盖掉")
        }
    }

    // MARK: 「内容」层的缺口绝不能被判成安装失败 —— 这两条防的是**这次修复自己**收得过紧

    suite(
        "T17e/内容: manifest 声明了 stop.mp3、而文件此刻不在 → **必须照常装完**"
            + "（面板画成 .broken，用户看得见、拖一个文件就能修；拦住他等于把他挡在唯一能修好它的界面之外）"
    ) {
        withTempDirectory { root in
            let (executablePath, _) = makeBundleFixture(at: root.appendingPathComponent("bundle"))
            let environment = makeEnvironment(root: root, executablePath: executablePath)

            let result = performFirstRunSetup(environment: environment)
            guard case .success(.completed(_, _, _, let packSelection, let hooksOutcome)) = result else {
                expect(false, "「声明了却还没有文件」是内容层缺口——绝不能拦，got \(result)")
                return
            }
            // fixture 自检：这条 suite 只有在机器**真的**处于 .incomplete 时才证明了什么。没有它，
            // makeBundleFixture 哪天补上 stop.mp3，这条防线就会静默蒸发——而且照样绿。
            expect(
                checkPackIntegrity(
                    configFile: environment.configFile,
                    userPacksDirectory: environment.userPacksDirectory,
                    bundledPacksDirectory: nil)
                    == .incomplete(packID: "minimal-chime", missingFiles: ["stop.mp3"]),
                "fixture 自检：这台机器此刻必须真的是 .incomplete（声明了 stop.mp3、文件不在），"
                    + "否则这条防线什么都没防到")
            expect(packSelection == .selectedDefault(packID: "minimal-chime"), "got \(packSelection)")
            expect(hooksOutcome == .installed, "照常写 hooks")
        }
    }

    suite(
        "T17e/内容: manifest 一个事件都没声明（events: {}，一个刚建出来、还没导入声音的空包）→"
            + " **必须照常装完**（面板画四行 .unmapped，用户看得见）"
    ) {
        withTempDirectory { root in
            let environment = makeInstalledEnvironment(root: root)
            writePack("empty-pack", in: environment.userPacksDirectory, events: "")

            let result = performFirstRunSetup(environment: environment)
            guard case .success(.completed(_, _, _, let packSelection, let hooksOutcome)) = result else {
                expect(false, "一个空包不是坏管道——绝不能拦，got \(result)")
                return
            }
            expect(
                checkPackIntegrity(
                    configFile: environment.configFile,
                    userPacksDirectory: environment.userPacksDirectory,
                    bundledPacksDirectory: nil) == .complete(packID: "empty-pack", events: []),
                "fixture 自检：空 manifest 在 checkPackIntegrity 眼里是 .complete(events: [])——"
                    + "这条防线防的正是「判据要求 events 非空」这个变异")
            expect(packSelection == .selectedDefault(packID: "empty-pack"), "got \(packSelection)")
            expect(hooksOutcome == .installed, "照常写 hooks")
        }
    }
}
