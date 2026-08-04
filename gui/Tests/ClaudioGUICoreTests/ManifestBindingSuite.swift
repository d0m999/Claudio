import ClaudioCore
import ClaudioGUICore
import Foundation

// MARK: - bindEventToManifest (ENGINEERING.md T16 D3): surgical RMW of manifest.json's raw
// JSON, preserving unknown top-level keys and sibling events — never a round-trip through
// PackManifest's Decodable/Encodable, which only models id+events and would silently drop
// name/author/license/version/schema.

/// ⚠️ `packsLockFile` 有一个**兜底默认值**（``injectedPacksLock(under:)``）—— 注意这是**本 suite 私有
/// helper 的**默认值，指向一条临时路径。
///
/// ⚠️ **这段的理由在 e278736 之后变了，别把旧说法读成现状**：它上一版写的是「而不是让它落回
/// `AudioImportEnvironment` 那个指向真实 `~/.claudio/packs.lock` 的默认值」——**那个默认值已经不
/// 存在了**（`/codex review 95d16a5,b89a0ee,37745f2` 的 P1-A 拆掉的），漏传现在是一次编译错误。
///
/// 当时的理由（记作历史，因为它解释了这个 helper 为什么长成这样）：忘了注入 `userPacksDirectory`
/// 的测试会**当场断言失败**（它去读真实 `~/.claudio/packs/`，里面没有 fixture）；而忘了注入这把锁
/// 只会**静默**地去用户机器上开一把真锁 —— 测试照样全绿，只是落了个文件、还与正在运行的
/// Claudio.app 抢锁。静默那种才是危险的那种。
///
/// 今天这个默认值还留着的理由变成了**省事 + 单源**：本 suite 是全包唯一真的会去**持有**这把锁的
/// 地方，几十个调用点各写一遍注入表达式毫无价值，而写错一处就让那一处的持锁断言失去分辨力。
///
/// ## 但兜底的**值**曾经是可派生的，那让一整类变异体在行为层隐身（`/codex review ceae86e` 的余波）
///
/// 上一版兜底写的是 `userPacksDirectory.deletingLastPathComponent()/packs.lock`（`<tmp>/packs`
/// → `<tmp>/packs.lock`），下面那三条持锁 suite 也各自手写同一个布局。于是把生产代码里的
///
/// ```swift
/// mutateManifestJSON(at: userPackDirectory, lockFile: environment.packsLockFile)
/// ```
///
/// 换成
///
/// ```swift
/// lockFile: environment.userPacksDirectory
///     .deletingLastPathComponent().appendingPathComponent("packs.lock")
/// ```
///
/// —— 这一手**已经不绑注入点**了（它绑的是包目录的位置），但求值出来**恰好等于**注入的那把锁，
/// 于是三条持锁 suite 全绿。而 `ManifestBinding.swift` 的锁转发在整个 `gui/Tests` 里**没有任何
/// 文本绊线**，所以那个变异体当时是**全仓零覆盖**的。
///
/// 现在注入值一律走 ``injectedPacksLock(under:)`` —— 父目录与叶名各带一段**运行时随机成分**，
/// 生产源码既写不出它也派生不出它 ⇒ 任何「从包目录/兄弟路径推出锁」的写法求值出来都 ≠ 注入值
/// ⇒ 持锁 suite 当场红。这条「不可派生」的性质本身由本文件第一条 suite 钉住，别当成可以顺手
/// 整理的风格问题。（上一版写的是「父目录与叶名两样都与任何自然派生不同」—— 那是**枚举**，
/// 而 `/codex review 37745f2` 的 P2 证明枚举不完：固定名字总能被向上若干级再拼回去。）
@MainActor
private func makeEnvironment(
    userPacksDirectory: URL,
    bundledPacksDirectory: URL? = nil,
    packsLockFile: URL? = nil
) -> AudioImportEnvironment {
    AudioImportEnvironment(
        userPacksDirectory: userPacksDirectory,
        bundledPacksDirectory: bundledPacksDirectory,
        durationProbe: StubDurationProbe(fixedDuration: 1.0),
        packsLockFile: packsLockFile
            ?? injectedPacksLock(under: userPacksDirectory.deletingLastPathComponent())
    )
}

/// 本文件注入给 `AudioImportEnvironment` 的那把包锁 —— **唯一来源**，三条持锁 suite 与
/// `makeEnvironment` 的兜底都走它。
///
/// ## 它的位置是承重的：**故意**不可从 `userPacksDirectory` 派生
///
/// 生产代码取这把锁的唯一合法写法是 `environment.packsLockFile`。任何「就地算一个出来」的写法
/// （`userPacksDirectory.deletingLastPathComponent()/packs.lock`、`<packs 目录>/packs.lock`、
/// 硬编码 `ClaudioPaths.packsLockFile`）都必须让持锁 suite **当场红**。做到这一点的办法，
/// 是让注入值待在那些表达式**算不出来**的地方 —— 而「算不出来」必须是**结构性**的，不能是一份
/// 「我想得到的派生写法都试过了」的清单：`root` 对生产代码可达，任何**固定**的父目录名 + 叶名
/// 都能被向上若干级再拼回去（`/codex review 37745f2` 的 P2 逐字演示过）。所以父目录与叶名各带
/// 一段运行时 `UUID`，两样都要带：只带父目录挡不住硬编码叶名再拼父目录的写法，只带叶名挡不住
/// 同父下的派生。
///
/// 父目录不用预建：`FileLock.attemptLock()` 撞上 ENOENT 会自愈建父目录再重试一次。
///
/// 这条性质由本文件第一条 suite（fixture 自证）钉住 —— 少了它，上面整段保护力就寄生在一个
/// **没有任何断言看着**的常量上，一次好意的「统一成生产布局」就全灭。
/// 实现住在 `AudioImportFixtures.swift`（全包唯一来源）—— 那里的 doc 写着为什么位置是承重的。
/// 本文件第一条 suite 是这条性质的**唯一**守卫，因为这里是全包唯一真的会去**持有**这把锁的地方。

/// `Result<Void, ManifestBindError>` isn't `Equatable` (`Void` isn't) — this extracts the
/// `.failure` payload so tests can compare it directly, `nil` for `.success` (a mismatch
/// any assertion below would still correctly flag).
private func failureError(_ result: Result<Void, ManifestBindError>) -> ManifestBindError? {
    if case .failure(let error) = result { return error }
    return nil
}

/// A `ProcessSpawning` that never actually launches anything — the joint "四个全清空"
/// test (T3) only needs `playSoundEvent` to reach `.notReady` before it would ever spawn
/// `afplay`, so this stub exists purely to satisfy `PlayEnvironment`'s initializer without
/// touching any real process.
private struct NoOpProcessSpawner: ProcessSpawning {
    func spawn(executablePath: String, arguments: [String]) -> Bool { false }
}

@MainActor
func runManifestBindingSuites() async {

    suite("fixture 自证：注入的包锁必须**不可**从 `userPacksDirectory` 派生出来") {
        // ## 这条守的是「下面三条持锁 suite 赖以成立的前提」，不是产品行为
        //
        // `ManifestBinding.swift` 里那两处 `mutateManifestJSON(at:lockFile: environment.packsLockFile)`
        // 的**锁转发**，在整个 `gui/Tests` 里**没有任何文本绊线**（`ViewWiringSuite` 那套只读
        // `PanelView.swift` / `OnboardingActions.swift`，够不到这里）。所以能分辨「转发对了」与
        // 「就地算了一个出来」的，**只有**下面那三条持锁 suite —— 而它们能分辨的唯一理由，是注入的
        // 锁待在任何自然派生都算不出来的位置上。
        //
        // 那个位置是 ``injectedPacksLock(under:)`` 里的一个常量。常量没有守卫：谁把它「统一成生产
        // 布局」（`<tmp>/packs.lock`，看起来整齐得多、还和 `ClaudioPaths` 一致），三条持锁 suite
        // **一条都不会红**，而 `lockFile:` 那一手退回全仓零覆盖。
        //
        // 这正是本仓库反复栽的形状：一条断言的分辨力寄生在另一处**没有人在断言**的事实上。
        //
        // ## 判据从「枚举四条派生源」换成「结构性不可派生」（`/codex review 37745f2` 的 P2）
        //
        // 上一版枚举了三条生产代码写得出来的「就地算一个」，外加一条叶名。那是一份**白名单**：
        // `root` 对生产代码可达（`userPacksDirectory.deletingLastPathComponent()`），把当时那两个
        // **固定**名字（`injected-locks` / `test-packs-lock`）向上若干级再拼回去，求值出来与注入值
        // 逐字相同，而那四条一条都不会红。Codex 在姊妹 fixture 上逐字演示过这一手。
        //
        // 现在注入锁带一段运行时 `UUID`，那四条在它面前**恒真**（生产写不出 UUID），留着就是四条
        // 永远不会红的断言。换成下面两条：直接钉「路径含运行时才存在的成分」这个**结构性**性质 ——
        // 上面那四种派生只是它的推论，而它还挡住了所有没被枚举到的派生写法。
        //
        // 判据用**两次调用的关系**表达，不去读它用了哪个随机源（那会是「守卫读被它守的那个函数的
        // 输出」，恒真）。父目录与叶名**分开断**：只带一段随机的实现会让另一半仍然可派生，而合并
        // 成一条 `!=` 对那种半吊子实现零分辨力。
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let environment = makeEnvironment(userPacksDirectory: userPacks)
            let injected = environment.packsLockFile
            let second = injectedPacksLock(besideUserPacks: userPacks)

            expect(
                injected.lastPathComponent != second.lastPathComponent,
                "注入包锁的**叶名**在两次调用之间相同（都是 \(injected.lastPathComponent)）—— 叶名里"
                    + "没有运行时成分，于是「就地算锁的写法里硬编码这个叶名、再从别处拼出父目录」"
                    + "求值出来会撞上注入值，下面三条持锁 suite 全绿而那一手已经不绑注入点了。"
                    + "`ManifestBinding` 的锁转发**没有任何文本绊线**兜底，那三条是唯一的守卫")
            expect(
                injected.deletingLastPathComponent().path
                    != second.deletingLastPathComponent().path,
                "注入包锁的**父目录**在两次调用之间相同（都是 "
                    + "\(injected.deletingLastPathComponent().path)）—— 父目录里没有运行时成分，于是"
                    + "「从 userPacksDirectory 向上若干级再拼死这个目录名」求值出来会撞上注入值。"
                    + "Codex 用的正是这一手")

            // ⚠️ 正向对照，这条不能省：上面两条 `!=` 只说明「两次调用不同」，一个
            //    **完全不管 root**、每次返回 `/tmp/<uuid>` 的实现也能让它们全绿 —— 而那样的锁根本
            //    不在被测的临时目录里，三条持锁 suite 会在一个与 fixture 无关的位置上开锁。
            //    ⚠️ 判据是**路径分量**（``isInside(_:of:)``），不是 `hasPrefix(root.path)`。裸前缀没有
            //       分量边界：`<root>-escaped/packs.lock` 逐字通过 `hasPrefix(root.path)` 而它在 root
            //       之外，于是这条本该 fail-closed 的对照对「把锁写到 root 的兄弟位」那一类**恒绿**
            //       （`/codex review d7084be` P2 坐实）。
            expect(
                isInside(injected, of: root) && isInside(second, of: root),
                "注入的包锁跑到了 fixture 的 root（\(root.path)）之外 —— 随机成分必须长在这棵临时目录"
                    + "**里面**，否则测试会在别处开锁、`withTempDirectory` 也清理不掉它。"
                    + "实得 \(injected.path) / \(second.path)")
            expect(
                injected.path != ClaudioPaths.packsLockFile.path,
                "注入的包锁等于**生产默认值**（\(ClaudioPaths.packsLockFile.path)）—— 那正是这套 fixture "
                    + "存在的全部理由要拦住的东西：测试会去用户真实 `~/.claudio` 上开一把锁，"
                    + "并与他正在运行的 Claudio.app 抢锁")
        }
    }

    suite(
        "bindEventToManifest: binding an unmapped event sets it, and recomputes to .present via packCoverage"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": {} }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let before = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: environment)
            expect(
                before.first { $0.event == .stop }?.coverage == .unmapped,
                "setup: stop must start unmapped")

            let result = bindEventToManifest(
                event: .stop, fileName: "stop.mp3", packID: "my-pack", environment: environment)
            guard case .success = result else {
                expect(false, "expected .success, got \(result)")
                return
            }

            let after = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: environment)
            expect(
                after.first { $0.event == .stop }?.coverage == .present(fileName: "stop.mp3"),
                "after a successful bind, stop must recompute to .present, got"
                    + " \(String(describing: after.first { $0.event == .stop }?.coverage))")
        }
    }

    suite(
        "bindEventToManifest: preserves unknown top-level keys (name/author/license/schema) and sibling events"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
            writeFixture(
                #"""
                { "id": "my-pack", "name": "极简铃音", "author": "Test Author",
                  "license": "CC0-1.0", "schema": 1,
                  "events": { "notification": "ping.mp3" } }
                """#, to: manifestFile)
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/ping.mp3"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "stop.mp3", packID: "my-pack", environment: environment)
            guard case .success = result else {
                expect(false, "expected .success, got \(result)")
                return
            }

            guard let rewrittenData = try? Data(contentsOf: manifestFile),
                let rewritten = try? JSONSerialization.jsonObject(with: rewrittenData)
                    as? [String: Any]
            else {
                expect(false, "rewritten manifest.json must still be valid JSON")
                return
            }
            expect(rewritten["name"] as? String == "极简铃音", "unknown key `name` must survive the RMW")
            expect(
                rewritten["author"] as? String == "Test Author",
                "unknown key `author` must survive the RMW")
            expect(
                rewritten["license"] as? String == "CC0-1.0",
                "unknown key `license` must survive the RMW")
            expect(rewritten["schema"] as? Int == 1, "unknown key `schema` must survive the RMW")

            guard let events = rewritten["events"] as? [String: String] else {
                expect(false, "rewritten manifest.json must still have an events object")
                return
            }
            expect(
                events["notification"] == "ping.mp3",
                "the sibling `notification` event must survive the RMW untouched, got \(events)")
            expect(
                events["stop"] == "stop.mp3",
                "the newly-bound `stop` event must be set, got \(events)")
        }
    }

    suite("bindEventToManifest: creates the `events` object when the manifest has none at all") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
            writeFixture(#"{ "id": "my-pack" }"#, to: manifestFile)
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "stop.mp3", packID: "my-pack", environment: environment)
            guard case .success = result else {
                expect(false, "expected .success, got \(result)")
                return
            }

            guard let rewrittenData = try? Data(contentsOf: manifestFile),
                let rewritten = try? JSONSerialization.jsonObject(with: rewrittenData)
                    as? [String: Any],
                let events = rewritten["events"] as? [String: String]
            else {
                expect(false, "rewritten manifest.json must have a valid events object")
                return
            }
            expect(
                events["stop"] == "stop.mp3",
                "a manifest with no prior events object must gain one with the new binding, got \(events)"
            )
        }
    }

    suite(
        "bindEventToManifest: a malformed non-object `events` field (e.g. a JSON array) fails CLOSED — .manifestUnreadable, manifest.json left byte-for-byte unchanged"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
            let originalRawJSON = #"{ "id": "my-pack", "events": ["stop.mp3", "ping.mp3"] }"#
            writeFixture(originalRawJSON, to: manifestFile)
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "stop.mp3", packID: "my-pack", environment: environment)

            expect(
                { if case .manifestUnreadable = failureError(result) { return true } else { return false } }(),
                "a non-object `events` field (a JSON array here) must fail CLOSED as"
                    + " .manifestUnreadable, never be silently coerced into a fresh {}, got \(result)"
            )
            expect(
                (try? String(contentsOf: manifestFile, encoding: .utf8)) == originalRawJSON,
                "a rejected bind must leave manifest.json completely untouched on disk")
        }
    }

    suite("bindEventToManifest: rebinding an already-mapped event overwrites its filename") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
            writeFixture(
                #"{ "id": "my-pack", "events": { "stop": "old-stop.mp3" } }"#, to: manifestFile)
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/old-stop.mp3"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/new-stop.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "new-stop.mp3", packID: "my-pack", environment: environment)
            guard case .success = result else {
                expect(false, "expected .success, got \(result)")
                return
            }

            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: environment)
            expect(
                rows.first { $0.event == .stop }?.coverage == .present(fileName: "new-stop.mp3"),
                "rebinding must overwrite the old filename, got"
                    + " \(String(describing: rows.first { $0.event == .stop }?.coverage))")
        }
    }

    suite("bindEventToManifest: an unresolvable packID is rejected as .packNotFound") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "stop.mp3", packID: "ghost-pack", environment: environment)
            expect(
                failureError(result) == .packNotFound(packID: "ghost-pack"),
                "an unresolvable packID must be rejected as .packNotFound, got \(result)")
        }
    }

    suite("bindEventToManifest: binding into a pack that exists ONLY as a bundled pack is refused") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let bundledPacks = root.appendingPathComponent("bundled")
            writeFixture(
                #"{ "id": "minimal-chime", "events": {} }"#,
                to: bundledPacks.appendingPathComponent("minimal-chime/manifest.json"))
            writeFixture(
                "fake-audio", to: bundledPacks.appendingPathComponent("minimal-chime/stop.mp3"))
            let environment = makeEnvironment(
                userPacksDirectory: userPacks, bundledPacksDirectory: bundledPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "stop.mp3", packID: "minimal-chime", environment: environment)
            expect(
                failureError(result) == .packNotFound(packID: "minimal-chime"),
                "binding must never write into the read-only bundled pack root, got \(result)")
            expect(
                (try? String(
                    contentsOf: bundledPacks.appendingPathComponent("minimal-chime/manifest.json"),
                    encoding: .utf8))?.contains("stop") == false,
                "the bundled pack's manifest.json must be completely untouched")
        }
    }

    suite("bindEventToManifest: a path-traversal filename is rejected as .unsafeFileName") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": {} }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "../../evil.mp3", packID: "my-pack", environment: environment)
            expect(
                failureError(result) == .unsafeFileName,
                "a `../`-escaping filename must be rejected as .unsafeFileName, got \(result)")
        }
    }

    suite(
        "bindEventToManifest: a destination filename that is a symlink escaping the pack dir is rejected as .unsafeFileName"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": {} }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            let outside = root.appendingPathComponent("outside-secret", isDirectory: true)
            try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            createSymlink(
                at: userPacks.appendingPathComponent("my-pack/evil.mp3"), pointingTo: outside)
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "evil.mp3", packID: "my-pack", environment: environment)
            expect(
                failureError(result) == .unsafeFileName,
                "a symlink-escaping filename must be rejected as .unsafeFileName, got \(result)")
        }
    }

    suite("bindEventToManifest: a safe filename that doesn't actually exist is rejected as .fileNotFound")
    {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": {} }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "never-imported.mp3", packID: "my-pack",
                environment: environment)
            expect(
                failureError(result) == .fileNotFound(fileName: "never-imported.mp3"),
                "a filename that passes containment but doesn't exist on disk must be rejected as"
                    + " .fileNotFound (never silently bind a phantom file), got \(result)")
        }
    }

    // 正规文件闸门的**写**侧（`/codex review` [P2]）。`coverageState`（读侧）、`doctor`、`play` 早已
    // 只认 ``regularFileExists(at:)``（`stat(2)` + `S_IFREG`），而绑定曾经用 `FileManager.fileExists(atPath:)`
    // —— 它对目录 / FIFO / socket / 设备一律回答 `true`。于是一个名叫 `stop.mp3` 的**目录**能被绑成功、
    // 写进 manifest，面板下一次刷新立刻把同一条路径判成 `.broken`：用户看到「导入成功」，拿到的是一条坏行。
    // 写路径必须在**写进 manifest 之前**挡住它，而不是写完了再由读路径去发现。下面两条钉的是同一个闸门的
    // 两个最硬输入：目录（`fileExists(atPath:isDirectory:)` 尚能排掉）与 FIFO（连它也排不掉）。
    suite("bindEventToManifest: 一个名叫 stop.mp3 的**目录** → .fileNotFound，且一个字节都不写") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
            let originalRawJSON = #"{ "id": "my-pack", "events": {} }"#
            writeFixture(originalRawJSON, to: manifestFile)
            // 这个目录**存在**、名字就叫 stop.mp3、路径**在包内**、containment 检查也**通过** ——
            // 唯一能挡住它的就是正规文件闸门本身。
            try? FileManager.default.createDirectory(
                at: userPacks.appendingPathComponent("my-pack/stop.mp3"),
                withIntermediateDirectories: true)
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "stop.mp3", packID: "my-pack", environment: environment)
            expect(
                failureError(result) == .fileNotFound(fileName: "stop.mp3"),
                "一个目录不是可播放的文件 —— 绑定必须拒（否则报成功、写进 manifest，面板刷新立刻 .broken），"
                    + "got \(result)")
            expect(
                (try? String(contentsOf: manifestFile, encoding: .utf8)) == originalRawJSON,
                "被拒的绑定必须让 manifest.json 逐字节原封不动")
        }
    }

    suite(
        "bindEventToManifest: 一个名叫 stop.mp3 的 FIFO → .fileNotFound（`fileExists` 会说它在；`stat`+S_IFREG 不会）"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
            let originalRawJSON = #"{ "id": "my-pack", "events": {} }"#
            writeFixture(originalRawJSON, to: manifestFile)
            // FIFO 是那条「`fileExists(atPath:isDirectory:)` 也救不了你」的用例：它连目录都不是，
            // 只有 `stat` + `S_IFREG` 能判掉。
            makePackFIFO(at: userPacks.appendingPathComponent("my-pack/stop.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "stop.mp3", packID: "my-pack", environment: environment)
            expect(
                failureError(result) == .fileNotFound(fileName: "stop.mp3"),
                "FIFO 不是可播放的文件 —— 绑定必须拒，got \(result)")
            expect(
                (try? String(contentsOf: manifestFile, encoding: .utf8)) == originalRawJSON,
                "被拒的绑定必须让 manifest.json 逐字节原封不动")
        }
    }

    // Distinct from the corrupt-manifest suite below: `{ not valid json` READS fine and only
    // fails `JSONSerialization`, so it exercises the "顶层不是 JSON 对象" guard. A manifest.json
    // that is ABSENT fails one step earlier — inside `loadPackManifestData` — the only
    // `bindEventToManifest` failure branch with no test at all. Reachable for real: importing
    // into a pack directory that exists (importAudioFile created it) but has no manifest yet.
    suite("bindEventToManifest: a MISSING manifest.json (pack dir exists, file present) is rejected as .manifestUnreadable") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            // Pack directory + the audio file exist; manifest.json deliberately does NOT.
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "stop.mp3", packID: "my-pack", environment: environment)
            guard case .manifestUnreadable(let reason) = failureError(result) else {
                expect(false, "a missing manifest.json must be rejected as .manifestUnreadable, got \(result)")
                return
            }
            expect(
                reason.contains("不存在或不可读"),
                "the reason must be loadPackManifestData's own unreadable message (not the"
                    + " top-level-not-an-object one), got \(reason)")
            expect(
                !FileManager.default.fileExists(
                    atPath: userPacks.appendingPathComponent("my-pack/manifest.json").path),
                "a refused bind must never CREATE a manifest.json — binding only ever edits one"
                    + " that already exists")
        }
    }

    suite(
        "bindEventToManifest: a VALID-JSON but non-object top level (a JSON array) fails closed as .manifestUnreadable, file untouched"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
            // Parses cleanly as JSON, so it clears `JSONSerialization.jsonObject` — but it is
            // an ARRAY, so the `as? [String: Any]` half of the same guard must reject it. A
            // separate sub-path from the `{ not valid json` case below, which never parses.
            let originalRawJSON = #"[{ "id": "my-pack" }]"#
            writeFixture(originalRawJSON, to: manifestFile)
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "stop.mp3", packID: "my-pack", environment: environment)
            expect(
                { if case .manifestUnreadable = failureError(result) { return true } else { return false } }(),
                "a valid-JSON top-level ARRAY must fail closed as .manifestUnreadable, never be"
                    + " coerced into an object, got \(result)")
            expect(
                (try? String(contentsOf: manifestFile, encoding: .utf8)) == originalRawJSON,
                "a rejected bind must leave manifest.json byte-for-byte untouched")
        }
    }

    suite("bindEventToManifest: a corrupt manifest.json is rejected as .manifestUnreadable") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture("{ not valid json", to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "stop.mp3", packID: "my-pack", environment: environment)
            expect(
                { if case .manifestUnreadable = failureError(result) { return true } else { return false } }(),
                "expected .failure(.manifestUnreadable), got \(result)")
        }
    }

    // MARK: - bindEventToManifest now routes its write through ClaudioCore's shared
    // ``encodeJSONObjectForWriting(_:path:)`` (本轮 /ship 评审), the exact same primitive
    // `config.json`'s read-modify-write already uses. This closes TWO holes at once — see
    // `ManifestBinding.swift`'s own doc comment on the call site for the full story:
    //   (a) float normalization: plain `JSONSerialization` renders non-integer Doubles with
    //       `%.17g`, so a bind used to rewrite a clean `0.8` in some unknown top-level key as
    //       `0.80000000000000004`.
    //   (b) uncatchable abort: a manifest containing `-1e400` parses to `-inf`, and
    //       `JSONSerialization.data(withJSONObject:)` throws an Objective-C
    //       `NSInvalidArgumentException` that Swift's `do/catch` cannot catch — process abort
    //       (empirically exit 134). Only NEGATIVE overflow reaches this point: `1e400`
    //       (positive) is rejected by Foundation at PARSE time already.

    suite(
        "bindEventToManifest: an unknown top-level key holding a clean float (0.8) survives the RMW as raw bytes \"0.8\" — never JSONSerialization's dirty %.17g rendering"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
            writeFixture(
                #"{ "id": "my-pack", "events": {}, "night_dim": { "level": 0.8 } }"#,
                to: manifestFile)
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "stop.mp3", packID: "my-pack", environment: environment)
            guard case .success = result else {
                expect(false, "expected .success, got \(result)")
                return
            }

            guard let rawBytes = try? String(contentsOf: manifestFile, encoding: .utf8) else {
                expect(false, "rewritten manifest.json must still be readable as UTF-8")
                return
            }
            expect(
                !rawBytes.contains("0.80000000000000004"),
                "raw bytes must NEVER contain JSONSerialization's dirty %.17g rendering of 0.8 — the"
                    + " exact hole encodeJSONObjectForWriting closes, got:\n\(rawBytes)")
            // `(?!\d)` rules out matching the "0.8" PREFIX of the dirty rendering above — this
            // must find a whole "0.8" token, not just its first three characters.
            expect(
                rawBytes.range(of: #"0\.8(?!\d)"#, options: .regularExpression) != nil,
                "raw bytes must still literally contain the clean float 0.8 for the unknown"
                    + " `night_dim.level` key, got:\n\(rawBytes)")
        }
    }

    suite(
        "bindEventToManifest: an unknown top-level key holding a LARGE INTEGER survives the RMW byte-for-byte — never routed through Double, which would lose precision above 2^53"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
            // 2^53 + 1 — the smallest integer a Double can no longer represent exactly. If
            // normalization ever routed integers through `doubleValue` (it must not — only
            // non-integer numbers are normalized), this exact literal would come back corrupted.
            writeFixture(
                #"{ "id": "my-pack", "events": {}, "schema_epoch": 9007199254740993 }"#,
                to: manifestFile)
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "stop.mp3", packID: "my-pack", environment: environment)
            guard case .success = result else {
                expect(false, "expected .success, got \(result)")
                return
            }

            guard let rawBytes = try? String(contentsOf: manifestFile, encoding: .utf8) else {
                expect(false, "rewritten manifest.json must still be readable as UTF-8")
                return
            }
            expect(
                rawBytes.contains("9007199254740993"),
                "the large integer must survive byte-for-byte — routing it through Double would"
                    + " silently lose precision, got:\n\(rawBytes)")
        }
    }

    suite(
        "bindEventToManifest: a float NESTED INSIDE AN ARRAY under an unknown top-level key is also normalized cleanly — the recursion must reach into arrays, not just objects"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
            writeFixture(
                #"{ "id": "my-pack", "events": {}, "fade_curve": [0.1, 0.35, 0.8] }"#,
                to: manifestFile)
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "stop.mp3", packID: "my-pack", environment: environment)
            guard case .success = result else {
                expect(false, "expected .success, got \(result)")
                return
            }

            guard let rawBytes = try? String(contentsOf: manifestFile, encoding: .utf8) else {
                expect(false, "rewritten manifest.json must still be readable as UTF-8")
                return
            }
            expect(
                !rawBytes.contains("0.34999999999999998"),
                "an array element must be normalized too — %.17g's dirty rendering of 0.35 must"
                    + " never appear, got:\n\(rawBytes)")
            expect(
                rawBytes.range(of: #"0\.35(?!\d)"#, options: .regularExpression) != nil,
                "the array's middle element must survive as the clean 0.35, got:\n\(rawBytes)")
        }
    }

    suite(
        "bindEventToManifest: a manifest.json containing -1e400 (parses to -inf) is rejected as .failure(.writeFailed) WITHOUT aborting the process, and is left byte-for-byte untouched"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
            // `x` is just an unknown sibling key — every read-side guard above (packID
            // resolution, filename containment, regular-file check, `events`/`id` validation)
            // passes without ever looking at it, so this reaches the write step, which is
            // exactly the path that used to abort the process before this fix.
            let originalRawJSON = #"{ "id": "my-pack", "events": {}, "x": -1e400 }"#
            writeFixture(originalRawJSON, to: manifestFile)
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            // Reaching the assertions below at all (rather than the whole test process dying
            // with exit 134 before this fix) IS the fix working.
            let result = bindEventToManifest(
                event: .stop, fileName: "stop.mp3", packID: "my-pack", environment: environment)

            guard case .failure(.writeFailed) = result else {
                expect(false, "expected .failure(.writeFailed), got \(result)")
                return
            }
            expect(
                (try? String(contentsOf: manifestFile, encoding: .utf8)) == originalRawJSON,
                "a manifest containing an unwritable -inf must be left byte-for-byte untouched on"
                    + " disk")
        }
    }

    // MARK: - .writeFailed: the one ManifestBindError case that had no test at all
    //
    // Every OTHER branch above is exercised: `.packNotFound`, `.unsafeFileName`,
    // `.fileNotFound`, `.manifestUnreadable` (six different shapes), and now `.writeFailed`
    // via the `-1e400` encode-side rejection just above. This suite hits the OTHER
    // `.writeFailed` call site — the final `Data.write(to:options:.atomic)` throwing after
    // `encodeJSONObjectForWriting` itself already succeeded.

    suite(
        "bindEventToManifest: a write that genuinely can't land (pack directory made unwritable AFTER every read-side guard passes) is reported as .failure(.writeFailed)"
    ) {
        guard geteuid() != 0 else {
            print("  ⚠ skipped: running as root — chmod can't block root's own writes")
            return
        }
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let packDirectory = userPacks.appendingPathComponent("my-pack", isDirectory: true)
            let manifestFile = packDirectory.appendingPathComponent("manifest.json")
            writeFixture(#"{ "id": "my-pack", "events": {} }"#, to: manifestFile)
            writeFixture("fake-audio", to: packDirectory.appendingPathComponent("stop.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            // Strip write permission from the pack DIRECTORY itself, not the file: every
            // read-side guard (packID resolution, filename containment, regular-file check,
            // manifest read, events/id validation, encodeJSONObjectForWriting's own validation)
            // only needs read+execute and must still all pass — only the FINAL atomic write
            // (which needs to create a sibling temp file in this directory before renaming it
            // over manifest.json) can fail.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o500], ofItemAtPath: packDirectory.path)
            defer {
                // Restore write access so the enclosing withTempDirectory's cleanup can remove it.
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: packDirectory.path)
            }

            let result = bindEventToManifest(
                event: .stop, fileName: "stop.mp3", packID: "my-pack", environment: environment)

            guard case .failure(.writeFailed) = result else {
                expect(
                    false,
                    "expected .failure(.writeFailed) when the pack directory can't be written to,"
                        + " got \(result)")
                return
            }
        }
    }

    // MARK: - EventRowImportViewModel: import → bind, wired end to end

    await suite("EventRowImportViewModel: a successful drop imports AND binds to the row's event") {
        await withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": {} }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)
            let importViewModel = AudioImportViewModel(packID: "my-pack", environment: environment)
            let rowViewModel = EventRowImportViewModel(
                event: .notification, importViewModel: importViewModel)

            let sourceURL = root.appendingPathComponent("source/chime.wav")
            writeFixture(validWAVData(), to: sourceURL)
            await rowViewModel.handleDrop(sourceURL: sourceURL, suggestedFileName: "chime.wav")

            guard case .success = importViewModel.state else {
                expect(false, "expected the import itself to succeed, got \(importViewModel.state)")
                return
            }
            guard case .success = rowViewModel.bindResult else {
                expect(
                    false,
                    "expected the bind to succeed, got \(String(describing: rowViewModel.bindResult))")
                return
            }

            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: environment)
            expect(
                rows.first { $0.event == .notification }?.coverage == .present(fileName: "chime.wav"),
                "after a real drop through the view-model, notification must recompute to .present,"
                    + " got \(String(describing: rows.first { $0.event == .notification }?.coverage))"
            )
        }
    }

    await suite("EventRowImportViewModel: a rejected import never attempts to bind") {
        await withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": {} }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)
            let importViewModel = AudioImportViewModel(packID: "my-pack", environment: environment)
            let rowViewModel = EventRowImportViewModel(event: .stop, importViewModel: importViewModel)

            let sourceURL = root.appendingPathComponent("source/evil.mp3")
            writeFixture(evilShellScriptData(), to: sourceURL)
            await rowViewModel.handleDrop(sourceURL: sourceURL, suggestedFileName: "evil.mp3")

            guard case .reject = importViewModel.state else {
                expect(false, "setup: the import must be rejected, got \(importViewModel.state)")
                return
            }
            expect(
                rowViewModel.bindResult == nil,
                "a rejected import must never even attempt a bind, got"
                    + " \(String(describing: rowViewModel.bindResult))")
        }
    }

    // The THIRD outcome `EventRowImportViewModel`'s doc comment explicitly promises to keep
    // distinguishable ("two different failure surfaces with two different causes, never folded
    // into one") but nothing tested: the import itself SUCCEEDS (file copied in) while the
    // subsequent bind FAILS. Reachable whenever the pack directory has no readable manifest.json
    // — `importAudioFile` creates the pack dir and copies the file without needing a manifest,
    // then `bindEventToManifest` refuses because there's nothing to read-modify-write.
    await suite(
        "EventRowImportViewModel: an import that SUCCEEDS but whose bind FAILS records .failure in bindResult while state stays .success"
    ) {
        await withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            // No manifest.json anywhere — the pack dir is created by the import itself.
            let environment = makeEnvironment(userPacksDirectory: userPacks)
            let importViewModel = AudioImportViewModel(packID: "my-pack", environment: environment)
            let rowViewModel = EventRowImportViewModel(event: .stop, importViewModel: importViewModel)

            let sourceURL = root.appendingPathComponent("source/chime.wav")
            writeFixture(validWAVData(), to: sourceURL)
            await rowViewModel.handleDrop(sourceURL: sourceURL, suggestedFileName: "chime.wav")

            guard case .success = importViewModel.state else {
                expect(
                    false,
                    "the IMPORT itself must still succeed (the file really was copied in), got"
                        + " \(importViewModel.state)")
                return
            }
            guard case .failure(let error) = rowViewModel.bindResult else {
                expect(
                    false,
                    "the BIND must fail and be recorded — a successful import with an unreadable"
                        + " manifest must never silently report a clean bind, got"
                        + " \(String(describing: rowViewModel.bindResult))")
                return
            }
            expect(
                { if case .manifestUnreadable = error { return true } else { return false } }(),
                "the recorded bind failure must be .manifestUnreadable, got \(error)")
            expect(
                FileManager.default.fileExists(
                    atPath: userPacks.appendingPathComponent("my-pack/chime.wav").path),
                "the imported file must still be on disk — the failed bind rolls back nothing,"
                    + " which is exactly why the two surfaces stay distinguishable")
        }
    }

    // MARK: - EventRowImportViewModel.clearBinding() (PLAN-SOUND-MANAGER.md §2.5/T2): the
    // file-name `Menu`'s 「清除绑定」 item's caller-facing entry point (`EventRowView.clearBinding()`,
    // compile-only/manual-verify — no ViewInspector in this repo). `clearEventBinding` itself is
    // already thoroughly pinned at the Core level (`clearEventBinding` suites above, T3) — these
    // close the ONE gap those don't reach: the view-model seam the menu item actually calls
    // through, publishing into the SAME `bindResult` surface a failed bind already reports
    // through (this type's own doc comment).

    suite("EventRowImportViewModel.clearBinding(): clears a bound event — bindResult becomes .success, coverage recomputes to .unmapped, the file itself is untouched") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": { "stop": "stop.mp3" } }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)
            let importViewModel = AudioImportViewModel(
                packID: "my-pack",
                environment: environment,
                previewState: .reject(.nonWhitelistFormat))
            let rowViewModel = EventRowImportViewModel(event: .stop, importViewModel: importViewModel)

            rowViewModel.clearBinding()

            guard case .success = rowViewModel.bindResult else {
                expect(
                    false,
                    "clearBinding() must record .success in bindResult — the SAME surface a failed"
                        + " bind reports through, got \(String(describing: rowViewModel.bindResult))")
                return
            }
            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: environment)
            expect(
                rows.first { $0.event == .stop }?.coverage == .unmapped,
                "after clearBinding(), stop must recompute to .unmapped (never .broken — a"
                    + " deliberate clear must not be disguised as a packaging defect), got"
                    + " \(String(describing: rows.first { $0.event == .stop }?.coverage))")
            expect(
                FileManager.default.fileExists(
                    atPath: userPacks.appendingPathComponent("my-pack/stop.mp3").path),
                "clearBinding() must never delete the audio file — only the manifest key")
            expect(
                importViewModel.state == .idle,
                "a newer clear action must remove an older import rejection so it cannot hide the bindResult")
        }
    }

    suite("EventRowImportViewModel.clearBinding(): idempotent on an already-unmapped event — .success, a true no-op") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": {} }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)
            let importViewModel = AudioImportViewModel(packID: "my-pack", environment: environment)
            let rowViewModel = EventRowImportViewModel(
                event: .notification, importViewModel: importViewModel)

            rowViewModel.clearBinding()

            guard case .success = rowViewModel.bindResult else {
                expect(
                    false,
                    "clearing an already-unmapped event must still succeed (idempotent), got"
                        + " \(String(describing: rowViewModel.bindResult))")
                return
            }
        }
    }

    suite("EventRowImportViewModel.clearBinding(): an unresolvable packID surfaces as .failure(.packNotFound) in bindResult — the SAME surface a failed bind already reports through, never a second, unrendered failure path") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let environment = makeEnvironment(userPacksDirectory: userPacks)
            let importViewModel = AudioImportViewModel(packID: "ghost-pack", environment: environment)
            let rowViewModel = EventRowImportViewModel(event: .stop, importViewModel: importViewModel)

            rowViewModel.clearBinding()

            expect(
                failureError(rowViewModel.bindResult ?? .success(())) == .packNotFound(packID: "ghost-pack"),
                "an unresolvable pack must surface .packNotFound through bindResult, got"
                    + " \(String(describing: rowViewModel.bindResult))")
        }
    }

    // MARK: - EventRowImportViewModel.retarget(to:) — the pack-switch state leak, one layer
    // deeper than ``AudioImportViewModel/retarget(to:)`` (see AudioImportViewModelSuite.swift
    // for that layer). This one has TWO things to clear on a REAL pack switch: the nested
    // `importViewModel`'s `state` AND this row's own `bindResult` — a stale "绑定失败：
    // manifest 读不动" left over from pack A displayed on pack B's row would be a pure
    // misreport, since the row never even attempted to bind into B. Same load-bearing
    // condition as the layer below: only clears when the packID actually changes, because
    // `refresh()` also runs right after a bind on the SAME pack completes.

    await suite(
        "EventRowImportViewModel.retarget(to:): switching to a DIFFERENT pack clears bindResult to nil for BOTH a successful bind and a failed bind, and resets the nested importViewModel"
    ) {
        await withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            // pack-a HAS a manifest — a drop here binds successfully.
            writeFixture(
                #"{ "id": "pack-a", "events": {} }"#,
                to: userPacks.appendingPathComponent("pack-a/manifest.json"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let successImportViewModel = AudioImportViewModel(
                packID: "pack-a", environment: environment)
            let successRowViewModel = EventRowImportViewModel(
                event: .notification, importViewModel: successImportViewModel)
            let goodSource = root.appendingPathComponent("source/chime.wav")
            writeFixture(validWAVData(), to: goodSource)
            await successRowViewModel.handleDrop(
                sourceURL: goodSource, suggestedFileName: "chime.wav")
            guard case .success = successRowViewModel.bindResult else {
                expect(
                    false,
                    "setup: the bind must succeed, got"
                        + " \(String(describing: successRowViewModel.bindResult))")
                return
            }

            successRowViewModel.retarget(to: "pack-c")
            expect(
                successRowViewModel.bindResult == nil,
                "retargeting to a DIFFERENT pack must clear a successful bindResult, got"
                    + " \(String(describing: successRowViewModel.bindResult))")
            expect(
                successRowViewModel.importViewModel.state == .idle,
                "retargeting to a DIFFERENT pack must also reset the nested importViewModel's"
                    + " state, got \(successRowViewModel.importViewModel.state)")
            expect(
                successRowViewModel.importViewModel.packID == "pack-c",
                "retargeting must repoint the nested importViewModel's packID too")

            // pack-b has NO manifest.json — a drop here imports fine but the bind fails.
            let failImportViewModel = AudioImportViewModel(
                packID: "pack-b", environment: environment)
            let failRowViewModel = EventRowImportViewModel(
                event: .stop, importViewModel: failImportViewModel)
            let goodSource2 = root.appendingPathComponent("source/chime2.wav")
            writeFixture(validWAVData(), to: goodSource2)
            await failRowViewModel.handleDrop(sourceURL: goodSource2, suggestedFileName: "chime2.wav")
            guard case .failure = failRowViewModel.bindResult else {
                expect(
                    false,
                    "setup: the bind must fail (no manifest.json in pack-b), got"
                        + " \(String(describing: failRowViewModel.bindResult))")
                return
            }

            failRowViewModel.retarget(to: "pack-c")
            expect(
                failRowViewModel.bindResult == nil,
                "retargeting to a DIFFERENT pack must clear a FAILED bindResult too — a stale bind"
                    + " failure from a pack the row no longer shows would be a pure misreport, got"
                    + " \(String(describing: failRowViewModel.bindResult))")
            expect(
                failRowViewModel.importViewModel.state == .idle,
                "retargeting to a DIFFERENT pack must reset the nested importViewModel's state even"
                    + " when the LAST thing it recorded was a bind failure, got"
                    + " \(failRowViewModel.importViewModel.state)")
        }
    }

    await suite(
        "EventRowImportViewModel.retarget(to:): retargeting to the SAME pack PRESERVES bindResult AND the nested importViewModel's state — the mutation-killer for the shared `packID != newPackID` guard"
    ) {
        await withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": {} }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let importViewModel = AudioImportViewModel(packID: "my-pack", environment: environment)
            let rowViewModel = EventRowImportViewModel(
                event: .notification, importViewModel: importViewModel)
            let sourceURL = root.appendingPathComponent("source/chime.wav")
            writeFixture(validWAVData(), to: sourceURL)
            await rowViewModel.handleDrop(sourceURL: sourceURL, suggestedFileName: "chime.wav")
            guard case .success = rowViewModel.bindResult else {
                expect(
                    false,
                    "setup: the bind must succeed, got \(String(describing: rowViewModel.bindResult))")
                return
            }
            guard case .success(let importedBeforeRetarget) = importViewModel.state else {
                expect(false, "setup: the import must have succeeded, got \(importViewModel.state)")
                return
            }

            // Exactly what `PanelView.refresh()` does right after THIS bind completed: it
            // re-asserts the same packID the row is already showing.
            rowViewModel.retarget(to: "my-pack")

            guard case .success = rowViewModel.bindResult else {
                expect(
                    false,
                    "retargeting to the SAME pack must PRESERVE a just-produced bindResult — the"
                        + " very scenario refresh()-after-bind creates — got"
                        + " \(String(describing: rowViewModel.bindResult))")
                return
            }
            expect(
                importViewModel.state == .success(importedBeforeRetarget),
                "retargeting to the SAME pack must preserve the nested importViewModel's state too,"
                    + " got \(importViewModel.state)")
            expect(importViewModel.packID == "my-pack", "packID must stay unchanged")
        }
    }

    // MARK: - Fail closed on any manifest shape PackManifest could not decode afterwards
    // (T16 review 修复④)
    //
    // These two shapes used to be WRITTEN and reported as a successful bind — and then the very
    // next `loadPackManifest`/`packCoverage` failed to decode the result, so the freshly-bound row
    // rendered 「未配置」 (`.unmapped`) with no error anywhere. A "success" the UI immediately
    // contradicts is the worst of both worlds; refusing is what this path's fail-closed design
    // already intends everywhere else. Each suite asserts BOTH halves: the refusal, and that the
    // malformed manifest was left byte-for-byte untouched.

    suite(
        "bindEventToManifest: an `events` object holding a NON-STRING value ({\"stop\": 1}) fails closed — PackManifest could not decode the result, so the bind must not claim success"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
            // `events` IS a JSON object (so it clears the existing non-object guard) but one of its
            // values is a number — `PackManifest.events` is `[String: String]`, so decoding this
            // throws no matter what we add to it.
            let originalRawJSON = #"{ "id": "my-pack", "events": { "stop": 1 } }"#
            writeFixture(originalRawJSON, to: manifestFile)
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/ping.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .notification, fileName: "ping.mp3", packID: "my-pack",
                environment: environment)

            expect(
                { if case .manifestUnreadable = failureError(result) { return true } else { return false } }(),
                "must fail closed as .manifestUnreadable rather than write a manifest nothing can"
                    + " decode, got \(result)")
            expect(
                (try? String(contentsOf: manifestFile, encoding: .utf8)) == originalRawJSON,
                "a refused bind must leave the malformed manifest byte-for-byte untouched")
            // The half that makes the old behavior indefensible: had the bind "succeeded", THIS is
            // what the user would have seen for the row they just configured.
            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: environment)
            expect(
                rows.first { $0.event == .notification }?.coverage == .unmapped,
                "coverage still can't decode this manifest — which is exactly why reporting the bind"
                    + " as a success would have left the row silently 未配置, got"
                    + " \(String(describing: rows.first { $0.event == .notification }?.coverage))")
        }
    }

    suite(
        "bindEventToManifest: a manifest with no valid top-level `id` (missing / non-string / empty) fails closed — PackManifest requires a non-empty string id"
    ) {
        // Three shapes, one contract. `id` missing and `id` non-string both make `PackManifest`'s
        // `Decodable` throw outright; an EMPTY id is not a legal pack id anywhere in this codebase
        // (`isSafePackID("")` is false), so a manifest carrying one is malformed too and must never
        // be treated as a live bind target.
        let malformed: [(label: String, json: String)] = [
            ("missing id", #"{ "events": {} }"#),
            ("non-string id", #"{ "id": 42, "events": {} }"#),
            ("empty id", #"{ "id": "", "events": {} }"#),
        ]
        for shape in malformed {
            withTempDirectory { root in
                let userPacks = root.appendingPathComponent("packs")
                let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
                writeFixture(shape.json, to: manifestFile)
                writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))
                let environment = makeEnvironment(userPacksDirectory: userPacks)

                let result = bindEventToManifest(
                    event: .stop, fileName: "stop.mp3", packID: "my-pack", environment: environment)

                expect(
                    { if case .manifestUnreadable = failureError(result) { return true } else { return false } }(),
                    "\(shape.label): must fail closed as .manifestUnreadable, never write a manifest"
                        + " PackManifest can't decode and call it a success, got \(result)")
                expect(
                    (try? String(contentsOf: manifestFile, encoding: .utf8)) == shape.json,
                    "\(shape.label): the malformed manifest must be left byte-for-byte untouched")
            }
        }
    }

    // MARK: - EventRowImportViewModel must never re-read MUTABLE state across the `await`
    // (T16 review 修复③ — Codex [P2] + Claude 对抗 F6, two axes of one root cause)
    //
    // `GatedDurationProbe` makes the race deterministic instead of timing-dependent: the import
    // pipeline blocks inside the (off-main-actor) duration probe until this test explicitly
    // releases it, so "a drop is in flight" is a state the test can hold open and act during — no
    // sleeps, no yields-and-hope.

    await suite(
        "EventRowImportViewModel: switching packs MID-IMPORT binds into the pack the bytes were copied into — never the pack selected while the import was in flight (TOCTOU: it would edit a DIFFERENT pack's manifest)"
    ) {
        await withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let manifestA = userPacks.appendingPathComponent("pack-a/manifest.json")
            let manifestB = userPacks.appendingPathComponent("pack-b/manifest.json")
            let originalB = #"{ "id": "pack-b", "events": {} }"#
            writeFixture(#"{ "id": "pack-a", "events": {} }"#, to: manifestA)
            writeFixture(originalB, to: manifestB)
            // pack-b ALREADY holds a file of the same name — so a mis-targeted bind would not merely
            // fail with .fileNotFound, it would SUCCEED into the wrong pack's manifest. This is the
            // difference between "the bug is loud" and "the bug silently rewrites another pack".
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("pack-b/chime.wav"))

            let probe = GatedDurationProbe(fixedDuration: 1.0)
            let environment = AudioImportEnvironment(
                userPacksDirectory: userPacks, bundledPacksDirectory: nil, durationProbe: probe,
                packsLockFile: injectedPacksLock(under: root))
            let importViewModel = AudioImportViewModel(packID: "pack-a", environment: environment)
            let rowViewModel = EventRowImportViewModel(event: .stop, importViewModel: importViewModel)

            let sourceURL = root.appendingPathComponent("source/chime.wav")
            writeFixture(validWAVData(), to: sourceURL)

            let drop = Task {
                await rowViewModel.handleDrop(sourceURL: sourceURL, suggestedFileName: "chime.wav")
            }
            // Yield so `drop` actually starts and reaches its `Task.detached` suspension; the import
            // then runs off the main actor and parks inside the probe, where we hold it.
            await Task.yield()
            expect(
                probe.waitUntilProbing(timeout: 5) == .success,
                "setup: the import must really be in flight inside the probe, otherwise this test"
                    + " isn't constructing the race at all")

            // Exactly what `PanelView.refresh()` does on a pack switch: repoint every row's packID.
            importViewModel.packID = "pack-b"
            probe.release()
            _ = await drop.value

            guard case .success = rowViewModel.bindResult else {
                expect(
                    false,
                    "the bind must succeed against pack-a (where the bytes landed), got"
                        + " \(String(describing: rowViewModel.bindResult))")
                return
            }
            expect(
                FileManager.default.fileExists(
                    atPath: userPacks.appendingPathComponent("pack-a/chime.wav").path),
                "setup sanity: the import copied the file into pack-a, the pack selected when it began")

            let rowsA = packCoverage(
                packID: "pack-a", config: ClaudioConfig(selectedPack: "pack-a"),
                environment: environment)
            expect(
                rowsA.first { $0.event == .stop }?.coverage == .present(fileName: "chime.wav"),
                "pack-a — the pack that RECEIVED the file — must be the one whose manifest gained the"
                    + " binding, got \(String(describing: rowsA.first { $0.event == .stop }?.coverage))")
            expect(
                (try? String(contentsOf: manifestB, encoding: .utf8)) == originalB,
                "pack-b's manifest must be byte-for-byte untouched: the user switched to it, they"
                    + " never dropped anything into it — binding there would silently rewrite a pack"
                    + " the drop had nothing to do with")
        }
    }

    await suite(
        "EventRowImportViewModel: a CONCURRENT rejected drop on the same row cannot cancel a valid drop's bind (the bind follows the drop's OWN outcome, never the shared `state`) — no orphaned file"
    ) {
        await withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": {} }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))

            let probe = GatedDurationProbe(fixedDuration: 1.0)
            let environment = AudioImportEnvironment(
                userPacksDirectory: userPacks, bundledPacksDirectory: nil, durationProbe: probe,
                packsLockFile: injectedPacksLock(under: root))
            let importViewModel = AudioImportViewModel(packID: "my-pack", environment: environment)
            let rowViewModel = EventRowImportViewModel(event: .stop, importViewModel: importViewModel)

            let goodURL = root.appendingPathComponent("source/chime.wav")
            writeFixture(validWAVData(), to: goodURL)
            let evilURL = root.appendingPathComponent("source/evil.mp3")
            writeFixture(evilShellScriptData(), to: evilURL)

            // Drop A (valid) goes first and parks inside the probe — its file is on its way in.
            let dropA = Task {
                await rowViewModel.handleDrop(sourceURL: goodURL, suggestedFileName: "chime.wav")
            }
            await Task.yield()
            expect(
                probe.waitUntilProbing(timeout: 5) == .success,
                "setup: drop A must be in flight before drop B is issued")

            // Drop B (content-sniff rejected — a shell script wearing a .mp3 name) never reaches the
            // probe, so it completes FIRST and publishes `.reject` into the row's shared state.
            await rowViewModel.handleDrop(sourceURL: evilURL, suggestedFileName: "evil.mp3")
            guard case .reject = importViewModel.state else {
                expect(false, "setup: drop B must be rejected, got \(importViewModel.state)")
                return
            }

            probe.release()
            _ = await dropA.value

            // A's file was already copied into the pack. If A's bind decision consulted the shared
            // `state` (which B had just set to `.reject`) instead of A's own returned outcome, A
            // would silently skip binding: file on disk, row still 未配置, zero errors reported —
            // an orphan.
            guard case .success = rowViewModel.bindResult else {
                expect(
                    false,
                    "drop A's bind must be driven by A's OWN import outcome, not by whatever the"
                        + " shared state holds after a sibling drop, got"
                        + " \(String(describing: rowViewModel.bindResult))")
                return
            }
            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: environment)
            expect(
                rows.first { $0.event == .stop }?.coverage == .present(fileName: "chime.wav"),
                "the valid drop's file must end up BOUND, never copied-in-but-unbound, got"
                    + " \(String(describing: rows.first { $0.event == .stop }?.coverage))")
        }
    }

    // MARK: - mutateManifestJSON (T3 新原语) — 直接测原语本身，不经 bind/clear
    //
    // `bindEventToManifest`（上面几十条 suite）已经把这个原语的每一条 fail-closed 校验、写侧的
    // 数字规范化/`-inf` 拒绝、未知顶层键保真都间接练到了 —— 但那全部是**通过 bind** 练到的，而
    // bind 自己还有两道原语没有的文件预检（`safePackFileURL`/`regularFileExists`）。这里直接调
    // `mutateManifestJSON`，把原语的契约从 bind 的契约里剥出来单独钉住：它是一个**目录级**、
    // **顶层**的读-改-写，不认识 `packID`，也不关心文件是否存在。

    suite(
        "mutateManifestJSON: transform 能改**顶层**任意字段，不仅仅是 events —— forkPack（T6）改写顶层 id / 删 license 需要的正是这条"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
            writeFixture(
                #"""
                { "id": "my-pack", "name": "极简铃音", "license": "CC0-1.0",
                  "events": { "stop": "stop.mp3" } }
                """#, to: manifestFile)

            let result = mutateManifestJSON(
                at: userPacks.appendingPathComponent("my-pack"),
                lockFile: injectedPacksLock(under: root)
            ) {
                json in
                json["id"] = "my-pack-copy"
                json["name"] = "极简铃音 的副本"
                json.removeValue(forKey: "license")
            }
            guard case .success = result else {
                expect(false, "expected .success, got \(result)")
                return
            }

            guard let rewrittenData = try? Data(contentsOf: manifestFile),
                let rewritten = try? JSONSerialization.jsonObject(with: rewrittenData)
                    as? [String: Any]
            else {
                expect(false, "rewritten manifest.json must still be valid JSON")
                return
            }
            expect(rewritten["id"] as? String == "my-pack-copy", "顶层 id 必须被改写")
            expect(rewritten["name"] as? String == "极简铃音 的副本", "顶层 name 必须被改写")
            expect(rewritten["license"] == nil, "license 必须被整个删掉，不是改成别的值")
            expect(
                (rewritten["events"] as? [String: String])?["stop"] == "stop.mp3",
                "transform 没碰的 events 必须原样保留")
        }
    }

    suite("mutateManifestJSON: events 存在但不是 JSON 对象 → .manifestUnreadable，transform 从不被调用，字节不变") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
            let originalRawJSON = #"{ "id": "my-pack", "events": ["stop.mp3"] }"#
            writeFixture(originalRawJSON, to: manifestFile)

            var transformCalled = false
            let result = mutateManifestJSON(
                at: userPacks.appendingPathComponent("my-pack"),
                lockFile: injectedPacksLock(under: root)
            ) {
                _ in
                transformCalled = true
            }

            expect(
                { if case .manifestUnreadable = failureError(result) { return true } else { return false } }(),
                "a non-object `events` must fail closed as .manifestUnreadable, got \(result)")
            expect(!transformCalled, "the fail-closed guard must run BEFORE transform, never after")
            expect(
                (try? String(contentsOf: manifestFile, encoding: .utf8)) == originalRawJSON,
                "a rejected mutation must leave manifest.json byte-for-byte untouched")
        }
    }

    suite(
        "mutateManifestJSON: events 对象里出现非字符串取值 → .manifestUnreadable，transform 从不被调用，字节不变"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
            let originalRawJSON = #"{ "id": "my-pack", "events": { "stop": 1 } }"#
            writeFixture(originalRawJSON, to: manifestFile)

            var transformCalled = false
            let result = mutateManifestJSON(
                at: userPacks.appendingPathComponent("my-pack"),
                lockFile: injectedPacksLock(under: root)
            ) {
                _ in
                transformCalled = true
            }

            expect(
                { if case .manifestUnreadable = failureError(result) { return true } else { return false } }(),
                "a non-string `events` value must fail closed as .manifestUnreadable, got \(result)")
            expect(!transformCalled, "the fail-closed guard must run BEFORE transform, never after")
            expect(
                (try? String(contentsOf: manifestFile, encoding: .utf8)) == originalRawJSON,
                "a rejected mutation must leave manifest.json byte-for-byte untouched")
        }
    }

    suite(
        "mutateManifestJSON: 顶层 id 缺失 / 非字符串 / 空 → .manifestUnreadable，transform 从不被调用，字节不变"
    ) {
        let malformed: [(label: String, json: String)] = [
            ("missing id", #"{ "events": {} }"#),
            ("non-string id", #"{ "id": 42, "events": {} }"#),
            ("empty id", #"{ "id": "", "events": {} }"#),
        ]
        for shape in malformed {
            withTempDirectory { root in
                let userPacks = root.appendingPathComponent("packs")
                let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
                writeFixture(shape.json, to: manifestFile)

                var transformCalled = false
                let result = mutateManifestJSON(
                    at: userPacks.appendingPathComponent("my-pack"),
                    lockFile: injectedPacksLock(under: root)
                ) {
                    _ in
                    transformCalled = true
                }

                expect(
                    { if case .manifestUnreadable = failureError(result) { return true } else { return false } }(),
                    "\(shape.label): must fail closed as .manifestUnreadable, got \(result)")
                expect(
                    !transformCalled,
                    "\(shape.label): the fail-closed guard must run BEFORE transform, never after")
                expect(
                    (try? String(contentsOf: manifestFile, encoding: .utf8)) == shape.json,
                    "\(shape.label): a rejected mutation must leave manifest.json byte-for-byte untouched"
                )
            }
        }
    }

    suite("mutateManifestJSON: a MISSING manifest.json is rejected as .manifestUnreadable, transform never called") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            // The pack directory exists (created by the temp-dir scaffold below) but has no
            // manifest.json at all.
            try? FileManager.default.createDirectory(
                at: userPacks.appendingPathComponent("my-pack"), withIntermediateDirectories: true)

            var transformCalled = false
            let result = mutateManifestJSON(
                at: userPacks.appendingPathComponent("my-pack"),
                lockFile: injectedPacksLock(under: root)
            ) {
                _ in
                transformCalled = true
            }

            guard case .manifestUnreadable(let reason) = failureError(result) else {
                expect(false, "a missing manifest.json must be rejected as .manifestUnreadable, got \(result)")
                return
            }
            expect(reason.contains("不存在或不可读"), "reason must be loadPackManifestData's own message, got \(reason)")
            expect(!transformCalled, "the fail-closed guard must run BEFORE transform, never after")
        }
    }

    suite(
        "mutateManifestJSON: a manifest containing -1e400 (parses to -inf) is rejected as .writeFailed WITHOUT aborting, byte-for-byte untouched"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
            let originalRawJSON = #"{ "id": "my-pack", "events": {}, "x": -1e400 }"#
            writeFixture(originalRawJSON, to: manifestFile)

            // Reaching the assertions below at all (rather than the process dying with exit
            // 134) IS the fix working — the primitive must inherit this from
            // `encodeJSONObjectForWriting`, not merely `bindEventToManifest`.
            let result = mutateManifestJSON(
                at: userPacks.appendingPathComponent("my-pack"),
                lockFile: injectedPacksLock(under: root)
            ) {
                json in
                json["untouched"] = "value"
            }

            guard case .failure(.writeFailed) = result else {
                expect(false, "expected .failure(.writeFailed), got \(result)")
                return
            }
            expect(
                (try? String(contentsOf: manifestFile, encoding: .utf8)) == originalRawJSON,
                "a manifest containing an unwritable -inf must be left byte-for-byte untouched on disk"
            )
        }
    }

    // MARK: - clearEventBinding (T3 新) — bindEventToManifest 的对偶：从 events 里删掉一个 key，
    // 从不删文件，recompute 到 .unmapped 而不是 .broken（PLAN-SOUND-MANAGER.md §2.1）。

    suite("clearEventBinding: 清除一个已绑定的 event → recompute 到 .unmapped，且文件仍在磁盘上") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": { "stop": "stop.mp3" } }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = clearEventBinding(event: .stop, packID: "my-pack", environment: environment)
            guard case .success = result else {
                expect(false, "expected .success, got \(result)")
                return
            }

            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: environment)
            expect(
                rows.first { $0.event == .stop }?.coverage == .unmapped,
                "after a clear, stop must recompute to .unmapped, got"
                    + " \(String(describing: rows.first { $0.event == .stop }?.coverage))")
            expect(
                FileManager.default.fileExists(
                    atPath: userPacks.appendingPathComponent("my-pack/stop.mp3").path),
                "clearing a binding must NEVER delete the underlying audio file — only the"
                    + " manifest key")
        }
    }

    suite(
        "clearEventBinding: 清除一个本来就 unmapped 的 event → 幂等成功（events 里没有这个 key，以及 events 整个不存在两种子情形）"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "pack-a", "events": { "notification": "ping.mp3" } }"#,
                to: userPacks.appendingPathComponent("pack-a/manifest.json"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("pack-a/ping.mp3"))
            writeFixture(
                #"{ "id": "pack-b" }"#, to: userPacks.appendingPathComponent("pack-b/manifest.json"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            // pack-a: events 对象存在，但没有 "stop" 这个 key.
            let resultA = clearEventBinding(event: .stop, packID: "pack-a", environment: environment)
            guard case .success = resultA else {
                expect(false, "clearing an already-unmapped event (key absent) must succeed, got \(resultA)")
                return
            }
            let rowsA = packCoverage(
                packID: "pack-a", config: ClaudioConfig(selectedPack: "pack-a"),
                environment: environment)
            expect(
                rowsA.first { $0.event == .stop }?.coverage == .unmapped,
                "must still read as .unmapped, got"
                    + " \(String(describing: rowsA.first { $0.event == .stop }?.coverage))")
            expect(
                rowsA.first { $0.event == .notification }?.coverage == .present(fileName: "ping.mp3"),
                "the sibling notification binding must survive an unrelated event's clear untouched")

            // pack-b: events 字段整个不存在.
            let resultB = clearEventBinding(event: .stop, packID: "pack-b", environment: environment)
            guard case .success = resultB else {
                expect(
                    false,
                    "clearing an event on a manifest with NO events object at all must still succeed"
                        + " as a no-op, got \(resultB)")
                return
            }

            // 再清一次（同一个已经是 unmapped 的 event）——幂等的第二个证明：连续两次调用都成功.
            let resultAAgain = clearEventBinding(
                event: .stop, packID: "pack-a", environment: environment)
            guard case .success = resultAAgain else {
                expect(false, "clearing the SAME already-cleared event twice must still succeed, got \(resultAAgain)")
                return
            }
        }
    }

    suite("clearEventBinding: 保留未知顶层键（name/author/license/schema）与其它 sibling events") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
            writeFixture(
                #"""
                { "id": "my-pack", "name": "极简铃音", "author": "Test Author",
                  "license": "CC0-1.0", "schema": 1,
                  "events": { "stop": "stop.mp3", "notification": "ping.mp3" } }
                """#, to: manifestFile)
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/ping.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = clearEventBinding(event: .stop, packID: "my-pack", environment: environment)
            guard case .success = result else {
                expect(false, "expected .success, got \(result)")
                return
            }

            guard let rewrittenData = try? Data(contentsOf: manifestFile),
                let rewritten = try? JSONSerialization.jsonObject(with: rewrittenData)
                    as? [String: Any],
                let events = rewritten["events"] as? [String: String]
            else {
                expect(false, "rewritten manifest.json must still be valid JSON with an events object")
                return
            }
            expect(rewritten["name"] as? String == "极简铃音", "unknown key `name` must survive the clear")
            expect(rewritten["author"] as? String == "Test Author", "unknown key `author` must survive")
            expect(rewritten["license"] as? String == "CC0-1.0", "unknown key `license` must survive")
            expect(rewritten["schema"] as? Int == 1, "unknown key `schema` must survive")
            expect(events["stop"] == nil, "the cleared `stop` key must be gone, got \(events)")
            expect(
                events["notification"] == "ping.mp3",
                "the sibling `notification` event must survive the clear untouched, got \(events)")
        }
    }

    suite("clearEventBinding: 一个无法解析的 packID → .packNotFound") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = clearEventBinding(
                event: .stop, packID: "ghost-pack", environment: environment)
            expect(
                failureError(result) == .packNotFound(packID: "ghost-pack"),
                "an unresolvable packID must be rejected as .packNotFound, got \(result)")
        }
    }

    suite("clearEventBinding: 只存在于只读 bundled 包根的 pack 被拒绝为 .packNotFound，bundled 的 manifest 一字节不动") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let bundledPacks = root.appendingPathComponent("bundled")
            let bundledManifest = bundledPacks.appendingPathComponent("minimal-chime/manifest.json")
            let originalBundledJSON = #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#
            writeFixture(originalBundledJSON, to: bundledManifest)
            writeFixture(
                "fake-audio", to: bundledPacks.appendingPathComponent("minimal-chime/stop.mp3"))
            let environment = makeEnvironment(
                userPacksDirectory: userPacks, bundledPacksDirectory: bundledPacks)

            let result = clearEventBinding(
                event: .stop, packID: "minimal-chime", environment: environment)
            expect(
                failureError(result) == .packNotFound(packID: "minimal-chime"),
                "clearing must never write into the read-only bundled pack root, got \(result)")
            expect(
                (try? String(contentsOf: bundledManifest, encoding: .utf8)) == originalBundledJSON,
                "the bundled pack's manifest.json must be completely untouched")
        }
    }

    // 对比 broken：同一份起点，两条完全不同的路径产生完全不同的读数——一条是真实的打包缺陷
    // （文件被外部删掉，manifest 仍然声称它在），另一条是用户主动清除（manifest 不再声明它）。
    // §2.1b 拍板「真打包错误不被伪装成正常静默」反向也成立：一次主动清除不得被伪装成打包缺陷。
    suite(
        "clearEventBinding 对比 broken：外部删文件 → doctor 报缺陷 + .broken；主动清除 → doctor .complete + .unmapped"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let configFile = root.appendingPathComponent("config.json")

            // pack-broken：manifest 仍然声明 stop -> stop.mp3，但那个文件被外部删掉了 —— 真实缺陷。
            writeFixture(
                #"{ "id": "pack-broken", "events": { "stop": "stop.mp3" } }"#,
                to: userPacks.appendingPathComponent("pack-broken/manifest.json"))
            let brokenFile = userPacks.appendingPathComponent("pack-broken/stop.mp3")
            writeFixture("fake-audio", to: brokenFile)
            try? FileManager.default.removeItem(at: brokenFile)

            // pack-cleared：一开始与 pack-broken 完全同构，但走 clearEventBinding 而不是删文件。
            writeFixture(
                #"{ "id": "pack-cleared", "events": { "stop": "stop.mp3" } }"#,
                to: userPacks.appendingPathComponent("pack-cleared/manifest.json"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("pack-cleared/stop.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)
            let clearResult = clearEventBinding(
                event: .stop, packID: "pack-cleared", environment: environment)
            guard case .success = clearResult else {
                expect(false, "setup: clearing pack-cleared's stop binding must succeed, got \(clearResult)")
                return
            }

            let brokenRows = packCoverage(
                packID: "pack-broken", config: ClaudioConfig(selectedPack: "pack-broken"),
                environment: environment)
            expect(
                brokenRows.first { $0.event == .stop }?.coverage == .broken(fileName: "stop.mp3"),
                "an externally-deleted declared file must read as .broken, got"
                    + " \(String(describing: brokenRows.first { $0.event == .stop }?.coverage))")

            let clearedRows = packCoverage(
                packID: "pack-cleared", config: ClaudioConfig(selectedPack: "pack-cleared"),
                environment: environment)
            expect(
                clearedRows.first { $0.event == .stop }?.coverage == .unmapped,
                "a deliberately-cleared event must read as .unmapped, never .broken, got"
                    + " \(String(describing: clearedRows.first { $0.event == .stop }?.coverage))")

            writeFixture(#"{"selected_pack": "pack-broken"}"#, to: configFile)
            let brokenIntegrity = checkPackIntegrity(
                configFile: configFile, userPacksDirectory: userPacks, bundledPacksDirectory: nil)
            guard case .incomplete(let brokenPackID, let missingFiles) = brokenIntegrity else {
                expect(false, "doctor must report pack-broken as .incomplete, got \(brokenIntegrity)")
                return
            }
            expect(brokenPackID == "pack-broken", "the packID on the report must be pack-broken")
            expect(missingFiles == ["stop.mp3"], "doctor must list the missing declared file, got \(missingFiles)")

            writeFixture(#"{"selected_pack": "pack-cleared"}"#, to: configFile)
            let clearedIntegrity = checkPackIntegrity(
                configFile: configFile, userPacksDirectory: userPacks, bundledPacksDirectory: nil)
            guard case .complete(let clearedPackID, let clearedEvents) = clearedIntegrity else {
                expect(false, "doctor must report pack-cleared as .complete — a cleared key is no longer declared, so it can never appear on the missing-files list, got \(clearedIntegrity)")
                return
            }
            expect(clearedPackID == "pack-cleared", "the packID on the report must be pack-cleared")
            expect(clearedEvents.isEmpty, "no events remain declared after the clear, got \(clearedEvents)")
        }
    }

    // §2.1b：「五个事件全被清空」—— 三个子系统给三个不同但都正确的答案，且这条分歧是被理解过的，
    // 不是被忽略的（PLAN-SOUND-MANAGER.md §2.1b）。三者必须写在同一个测试里，否则下一个人会看到
    // 「doctor 说完整、包行说缺 5 个」觉得是 bug，去「修好」其中一个，当场破坏另外两个。
    suite(
        "五个事件全部清空的三方回答同时钉死：doctor .complete / play 全部 .notReady / 面板包行 partial(0/5)，且五个音频文件全部原封不动"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(#"{"selected_pack": "my-pack"}"#, to: configFile)
            writeFixture(
                #"""
                { "id": "my-pack", "events": {
                    "task_start": "task.mp3", "stop": "stop.mp3", "stop_failure": "fail.mp3",
                    "notification": "ping.mp3", "subagent_stop": "sub.mp3" } }
                """#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            let fileNames = ["task.mp3", "stop.mp3", "fail.mp3", "ping.mp3", "sub.mp3"]
            for fileName in fileNames {
                writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/\(fileName)"))
            }
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            for event in Event.allCases {
                let result = clearEventBinding(
                    event: event, packID: "my-pack", environment: environment)
                guard case .success = result else {
                    expect(false, "clearing \(event) must succeed, got \(result)")
                    return
                }
            }

            // ① doctor：manifest 什么都没声明 → 没有缺失文件 → .complete（问的是「声明的文件在不在」）。
            let integrity = checkPackIntegrity(
                configFile: configFile, userPacksDirectory: userPacks, bundledPacksDirectory: nil)
            guard case .complete(let packID, let events) = integrity else {
                expect(false, "doctor must report an events:{} pack as .complete, got \(integrity)")
                return
            }
            expect(packID == "my-pack", "packID on the report must be my-pack")
            expect(events.isEmpty, "no events remain declared, got \(events)")

            // ② play：五个事件全静默（问的是「这个事件要不要出声」，unmapped = 刻意静默）。
            let playEnvironment = PlayEnvironment(
                lockFile: root.appendingPathComponent("play.lock"),
                configFile: configFile,
                userPacksDirectory: userPacks,
                bundledPacksDirectory: nil,
                spawner: NoOpProcessSpawner(),
                debounceStateFile: root.appendingPathComponent("play.state"),
                logFile: root.appendingPathComponent("claudio.log"),
                logLockFile: root.appendingPathComponent("claudio.log.lock"))
            for event in Event.allCases {
                let outcome = playSoundEvent(event.cliName, environment: playEnvironment)
                expect(
                    outcome == .notReady,
                    "\(event) must be .notReady with every event cleared, got \(outcome)")
            }

            // ③ 面板包行：问的是「覆盖了几个事件」→ partial(0/5)「缺 5 个」。
            let cards = availablePacks(
                config: ClaudioConfig(selectedPack: "my-pack"), environment: environment)
            guard let card = cards.first(where: { $0.id == "my-pack" }) else {
                expect(false, "my-pack must appear in availablePacks")
                return
            }
            expect(
                card.state == .partial(present: 0, total: 5),
                "the pack row must read partial(0/5) — 「缺 5 个」, got \(card.state)")
            expect(card.presentEvents.isEmpty, "no event glyph should be lit, got \(card.presentEvents)")

            // 三方分歧之外的那条硬约束：清除绝不删文件——全部四个音频文件必须原封不动地留在磁盘上。
            for fileName in fileNames {
                expect(
                    FileManager.default.fileExists(
                        atPath: userPacks.appendingPathComponent("my-pack/\(fileName)").path),
                    "\(fileName) must still be on disk — clearing only ever edits manifest keys")
            }
        }
    }

    // MARK: - 包目录锁（`/codex review b0ce657` 之后那次核查逼出来的）
    //
    // 那次核查坐实了两件事，两件都推翻了本文件此前赖以成立的前提：
    //  ① `manifest.json` **有第二个写者** —— helper 的 `performFirstRunSetup` 以**目录粒度**发布
    //     整棵包目录（`Setup.swift` 的 `copyItem`→`moveItem`），还会在 manifest 解不开时把用户
    //     整个包目录挪走。那段循环当时零锁（本轮已一并上锁，共用同一把），而 T3 源码围栏
    //     **两重**看不见它（只扫 `gui/Sources`，
    //     且纳入判据要求文件里含 `mutateManifestJSON` 这个 token）。
    //  ② GUI 自己把它派到主 actor 外（`OnboardingActions` 的 `Task.detached`）—— 所以「所有
    //     manifest 写都在 @MainActor」这句不变式**在本进程内就是假的**。
    //
    // 于是 `manifest.json` 从「靠单写者 + @MainActor 序列化」改成「靠一把真锁序列化」，与
    // `config.json` 一直以来的做法对齐。下面三条钉的是那把锁**真的在承重**。

    suite("mutateManifestJSON：包锁被占住时 bind 必须报 .lockBusy，且磁盘一个字节都不许动") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let packsLock = injectedPacksLock(under: root)
            let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
            writeFixture(#"{ "id": "my-pack", "events": {} }"#, to: manifestFile)
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))
            let environment = makeEnvironment(
                userPacksDirectory: userPacks, packsLockFile: packsLock)

            // 在锁被持有期间发起一次 bind。`FileLock` 每次自己 `open(2)`，同进程的第二个 open file
            // description 与第一个照样争用 `flock` —— 所以这条不需要另起进程就能造出真争用。
            let outcome = withNonBlockingLock(path: packsLock.path) {
                bindEventToManifest(
                    event: .stop, fileName: "stop.mp3", packID: "my-pack",
                    environment: environment)
            }
            guard case .ran(let result) = outcome else {
                expect(false, "测试自身的前提坏了：外层那把锁没拿到（\(outcome)）")
                return
            }
            expect(
                failureError(result) == .lockBusy,
                "包锁被别人占住时 bind 必须返回 `.lockBusy`，实得 \(result)。"
                    + "`withNonBlockingLock` 是**非阻塞**的：争用即 `.skipped`，body 根本不跑。"
                    + "把 `.skipped` 映射成 `.success` 会让用户点完「设置声音」什么都没发生、"
                    + "而且没有任何提示（面板只在 `.failure` 上出文案）；映射成别的 case 则会把"
                    + "「另一个写者正占着」说成别的原因。")

            // body 没跑，就不许有半次写 —— 这条钉的是「整段读-改-写都在锁里」，不是「锁在某处存在」。
            let onDisk = try? String(contentsOf: manifestFile, encoding: .utf8)
            expect(
                onDisk?.contains("stop.mp3") == false,
                "bind 因为锁忙而失败，manifest 却被改了 —— 说明读-改-写没有**整段**在锁的作用域里"
                    + "（典型写法错误：只把最后那次 `write` 包进锁，读和改在锁外）。实得：\(onDisk ?? "<读不出>")")
        }
    }

    suite("mutateManifestJSON：成功跑完必须把锁还回去（不许一直持有 / 不许泄漏 fd）") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let packsLock = injectedPacksLock(under: root)
            writeFixture(
                #"{ "id": "my-pack", "events": {} }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))
            let environment = makeEnvironment(
                userPacksDirectory: userPacks, packsLockFile: packsLock)

            let result = bindEventToManifest(
                event: .stop, fileName: "stop.mp3", packID: "my-pack", environment: environment)
            guard case .success = result else {
                expect(false, "前提：这次 bind 应当成功，实得 \(result)")
                return
            }

            // 锁还回去了 ⇒ 现在还能再拿到。拿不到 = 上一次调用把锁一直攥着，
            // 于是**下一次** bind、以及任何一次 `claudio setup`，都会永久 `.lockBusy`。
            let reacquired = withNonBlockingLock(path: packsLock.path) { true }
            guard case .ran = reacquired else {
                expect(
                    false,
                    "一次成功的 bind 之后包锁没有被释放（实得 \(reacquired)）—— 之后每一次 "
                        + "bind 与每一次 `claudio setup` 都会永久报「忙」")
                return
            }
            expect(true, "成功路径释放了包锁")
        }
    }

    suite("clearEventBinding：与 bind 同等待遇 —— 锁被占住时也必须报 .lockBusy") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let packsLock = injectedPacksLock(under: root)
            let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
            writeFixture(
                #"{ "id": "my-pack", "events": { "stop": "stop.mp3" } }"#, to: manifestFile)
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))
            let environment = makeEnvironment(
                userPacksDirectory: userPacks, packsLockFile: packsLock)

            let outcome = withNonBlockingLock(path: packsLock.path) {
                clearEventBinding(event: .stop, packID: "my-pack", environment: environment)
            }
            guard case .ran(let result) = outcome else {
                expect(false, "测试自身的前提坏了：外层那把锁没拿到（\(outcome)）")
                return
            }
            expect(
                failureError(result) == .lockBusy,
                "clear 是 bind 的对偶，走的是**同一个**原语，锁待遇必须一样，实得 \(result) —— "
                    + "只给 bind 上锁而漏掉 clear，等于两个写者里只序列化了一个。")
            let onDisk = try? String(contentsOf: manifestFile, encoding: .utf8)
            expect(
                onDisk?.contains("stop.mp3") == true,
                "clear 因为锁忙而失败，绑定却已经被抹掉了 —— 读-改-写没有整段在锁里。实得：\(onDisk ?? "<读不出>")")
        }
    }
}

/// A duration probe that BLOCKS inside ``probeDuration(of:)`` until a test explicitly releases it —
/// the seam that makes "an import is in flight" a state a test can HOLD OPEN, rather than a timing
/// window it has to race (no sleeps, no yield-and-pray).
///
/// It works precisely because ``AudioImportViewModel/handleDrop(requests:)`` runs the import
/// pipeline on a `Task.detached`: the probe blocks a background thread, never the `@MainActor`, so
/// the test can keep driving the view-model (switching packs, issuing a second drop) while the
/// first import sits parked here.
///
/// `@unchecked Sendable`: its only mutable state is the two semaphores, which are themselves
/// thread-safe by construction.
private final class GatedDurationProbe: AudioDurationProbing, @unchecked Sendable {
    private let fixedDuration: TimeInterval?
    /// Signaled BY the probe (on the import's background thread) once it is really running.
    private let probing = DispatchSemaphore(value: 0)
    /// Signaled BY the test to let the parked import finish.
    private let resume = DispatchSemaphore(value: 0)

    init(fixedDuration: TimeInterval?) { self.fixedDuration = fixedDuration }

    func probeDuration(of fileURL: URL) -> TimeInterval? {
        probing.signal()
        resume.wait()
        return fixedDuration
    }

    /// Blocks the caller until the import has actually entered the probe. Bounded by `timeout` so a
    /// mis-constructed test fails an assertion instead of hanging the whole harness forever.
    func waitUntilProbing(timeout seconds: TimeInterval) -> DispatchTimeoutResult {
        probing.wait(timeout: .now() + seconds)
    }

    /// Lets the parked import proceed (copy the bytes in, return its outcome).
    func release() { resume.signal() }
}
