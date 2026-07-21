import ClaudioCore
import Foundation

// MARK: - 锁分离本身的回归网（阶段 A 的兑现点，`/codex review 803c639,b74b7f3` 逼出来的）
//
// 阶段 A 把一把 `play.lock` 拆成三把（`play.lock` / `config.lock` / `settings.lock`），理由是：
// 任何一次设置写都会占住 `play` 的去抖锁，于是同一瞬间到达的 Claude Code 事件被判成
// `.skippedDebounce` —— **静默、不记日志、用户少听一声提示音**。
//
// ## 这个 suite 为什么必须存在
//
// 阶段 A 落地之后，它的**全部前提一行测试都没钉住**。实测的变异（本轮评审的核心发现）：
//
// ```swift
// // Paths.swift —— 把 config 锁改回 play 锁，等于一行静默 revert 掉整个锁分离
// public static var configLockFile: URL { root.appendingPathComponent("play.lock") }
// ```
//
// `swift run claudio-tests` + `claudio-gui-tests` **全绿**（1030 + 1604）。因为：
//
// - `PathsSuite` 只断言每条路径「不含空格」「位于 ~/.claudio 下」—— 改完这两条依然成立。
// - `PlaySuite:170` 断言 `PlayEnvironment().lockFile == ClaudioPaths.playLockFile` —— 依然成立。
// - `EventMuteControllerSuite:17` 断言 `EventMuteController().lockFile == ClaudioPaths.configLockFile`
//   —— 变异后两边**都**指向 `~/.claudio/play.lock`，于是它**恒真**。它自己的断言消息写的是
//   「never playLockFile」，而那正是它唯一没检查的东西。
// - `ViewWiringSuite` 是**符号名**文本绊线（`ClaudioPaths.configLockFile`），符号名一个字没变。
// - `FileLockSuite` 的「不同路径的锁互不冲突」测的是**原语**，喂的是临时目录里现造的路径，
//   从来没喂过 `ClaudioPaths` 这三把真锁。
//
// 也就是说：**没有任何一条断言说过「这几把锁是不同的文件」**。一个 commit 的中心论点，
// 在它自己的测试树里是一句没人说过的话。这个文件就是来说这句话的。
//
// ## 两类断言，各挡各的
//
// 1. **值级**（下面第一条 suite）：四把锁两两不等。挡「`Paths.swift` 里某把锁被改回/复制粘贴成
//    另一把」——上面那个变异。这是纯字符串计算，不碰文件系统（理由见 `PathsSuite` 文件头）。
// 2. **默认值级**（第二条 suite）：生产调用点用的是哪把锁。`claudio install` / `claudio use`
//    在 `Subcommands.swift` 里是**全默认调用**的（`installClaudioHooks()` / `selectPack(packID)`），
//    而**每一个**现有测试都显式注入临时锁 —— 所以那几个默认值**在整个测试套件里从未被求值过**。
//    把 `SettingsInstaller.swift:121` 的默认值改成 `ClaudioPaths.playLockFile`，`claudio install`
//    当场回到 `play.lock` 上，吞提示音的窗口原样复活，而**全套测试依然全绿**。
//
// 第二类只能走源码文本绊线：Swift 读不到一个自由函数的默认实参（没有反射入口），而**调用它**
// 就意味着拿生产默认值去写真实的 `~/.claude/settings.json` —— 这个仓库的测试绝不做这件事。
// 同样的取舍、同样的理由，`ViewWiringSuite` / `ReleaseLayoutSuite` 已经立过先例。
//
// ⚠️ **诚实标注：文本绊线证明不了那行代码做对了，只能证明它还在。** 它挡的是「重构时漏掉 / 顺手
// 改回去」，而那恰恰是上面那个变异的形状。

/// 仓库根 —— 从 `#filePath` 推（编译期常量，不依赖 cwd）。
/// `helper/Tests/ClaudioCoreTests/LockSeparationSuite.swift` → 上溯 4 层。
private func repoRoot(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

/// 本文件所有绊线扫描的那份名单 —— 一处定义，守卫（下面第一条 suite）与各条断言共用。
///
/// 名单本身也是一条断言：`Subcommands.swift` 在里面，因为 `claudio setup` 是**第四条** CLI 命令
/// （`/review e7c38ea`：它全默认构造 `SetupEnvironment`，两把锁全靠默认实参）。
@MainActor
private let scannedSourceFiles = [
    "helper/Sources/ClaudioCore/Setup.swift",
    "helper/Sources/ClaudioCore/Use.swift",
    "helper/Sources/ClaudioCore/EventEnabled.swift",
    "helper/Sources/ClaudioCore/SettingsInstaller.swift",
    "helper/Sources/ClaudioCore/Play.swift",
    "helper/Sources/ClaudioCore/Log.swift",
    "helper/Sources/claudio/Subcommands.swift",
]

/// 一个源文件被 ``strippingComments(_:)`` 扫过之后的样子（代码 + 「扫描器不认识的构造」清单）。
@MainActor
private func scan(_ relativePath: String) -> StrippedSwiftSource? {
    guard let data = try? Data(contentsOf: repoRoot().appendingPathComponent(relativePath)),
        let text = String(data: data, encoding: .utf8)
    else { return nil }
    return strippingComments(text)
}

/// 一个源文件**剥掉注释**之后的样子。
///
/// 不剥注释，下面每一条负向断言都会被**谈论 `playLockFile` 的散文**判成假红 —— `Use.swift:50`
/// 与 `SettingsInstaller.swift:29` 的 doc comment 里都白纸黑字写着 `ClaudioPaths/playLockFile`
/// （写的正是「我**不**用这把锁」）。`ViewWiringSuite` 的第一版就是在这里翻的车，代价记在它的
/// 文件头上；这里不重犯。
///
/// 剥注释的活儿由 `TestSupport.strippingComments` 干 —— 一个**认识字符串字面量**的位置感知状态机。
/// 上一版是「每行第一个 `//` 处无条件截断」，而 `be332ff` 给它配的那条守卫（「源文件里不许出现
/// `://`」）**恒真**：它检查的是**截断之后**的文本，而 `://` 自带 `//`，到达断言之前就已经被剪成
/// `https:`（`/codex review be332ff` 的 P2）。现在洞从根上没了，扫描器自己的行为由
/// `SourceScannerSuite` 喂合成输入钉死。
@MainActor
private func codeOnly(_ relativePath: String) -> String? {
    scan(relativePath)?.code
}

/// 同一个文件，剥注释**且清空字符串内容**之后的样子（界定符与插值里的代码保留）。
///
/// ``callArguments(of:in:)`` 这一路**必须**读它：那个切法按括号配平走，而 `code` 保留字符串
/// **内容** —— 实参表里一句带不配对括号的字面量（`"pack (1.json"`）会把深度算歪，从此那处调用
/// 的实参再也切不出来。见 ``StrippedSwiftSource/codeWithoutStringLiterals`` 自己的 doc。
///
/// ⚠️ 本文件的**负向**断言（`!setup.contains("playLockFile")` 那几条）**不**改读这一路：对
/// 「不许出现 X」而言，喂更少的文本是 fail-**open**（清掉的那段里正好有 X 就静默变绿），
/// 而喂保留字符串的 `code` 是 fail-closed（最坏只是假红，有人喊）。极性不同，读的路就不同。
@MainActor
private func codeWithoutStrings(_ relativePath: String) -> String? {
    scan(relativePath)?.codeWithoutStringLiterals
}

@MainActor
func runLockSeparationSuites() {
    suite("扫描器的前提：被它扫的源文件里，没有一处它自己不认识的构造") {
        // ## 这条替掉了什么（`/codex review be332ff` 的 P2）
        //
        // 上一版这里是一条「源文件里不许出现 `://`」的元断言。**理由是对的**：`codeOnly` 当时在
        // **第一个 `//`** 处无条件截断整行，于是一句
        //
        // ```swift
        // let hint = "锁的说明见 https://claudio.dev/locks"; _ = write(…, lockFile: ClaudioPaths.playLockFile)
        // ```
        //
        // 会被剪成 `let hint = "锁的说明见 https:` —— 后半行那句 `lockFile:` **在分析文本里根本不
        // 存在**，而本文件的兜底全是负向断言（`!contains`、`count == N`）：被剥掉的代码只会让它们
        // **更绿**。
        //
        // **而它的写法是 `!codeOnly(path).contains("://")` —— 它检查的是「截断之后」的文本。**
        // `://` 自带 `//`，到达断言之前就已经被剪成 `https:`：那条断言**恒真**，一个字节都守不住，
        // 而它的失败消息自称「真到了非放 URL 不可的那天，它会当场变红」。一条永远不会红的断言不是
        // 护栏 —— 这正是本文件通篇要杀的那个病（**措辞比覆盖范围大**），复发在杀它的那一刀里。
        //
        // ## 为什么不是「把 ban 挪到 raw source」
        //
        // `!raw.contains("://")` 确实红得起来 —— 也会在**第一个把 URL 写进 doc comment** 的人手上红，
        // 而注释里的 URL 完全无害（剥注释本来就该把它剥掉）。一条会因为无害改动而红的断言，会被下一个
        // 人删掉，然后洞原样回来。所以这次是把扫描器**修对**：`TestSupport.strippingComments` 现在是
        // 位置感知的（代码 / 行注释 / 块注释 / 字符串 / 多行字符串），字符串字面量里的 `//` 不再是
        // 注释起点。它自己的每一条行为由 `SourceScannerSuite` 喂**合成输入**钉死 —— 正向断言，喂的是
        // 扫描器自己的输入，所以那些断言不可能变成又一条恒真式。
        //
        // ## 那这条守的是什么
        //
        // 修好的扫描器仍然**不建模 raw string**（`#"…"#`）。它知道这一点：撞见一处就记进
        // `unmodeledConstructs`，这条断言盯着那张清单。与那条恒真的 `://` 的区别是：清单是在原始文本上
        // 按**词法位置**记的 —— 串内的 `#"`（`hasPrefix("#")`）不会误记（`SourceScannerSuite` 最后一条
        // 钉的就是这个）。既红得起来，也不会假红。
        for path in scannedSourceFiles {
            guard let scanned = scan(path) else {
                expect(false, "读不到 \(path) —— 下面每一条 suite 都指望它")
                continue
            }
            expect(
                scanned.unmodeledConstructs.isEmpty,
                "\(path) 里出现了扫描器不建模的词法构造：\(scanned.unmodeledConstructs) —— "
                    + "它剥出来的「代码」从此不可信。而本文件的兜底全是负向断言（`!contains`、"
                    + "`count == N`）：一段被误判成字符串 / 注释而消失的代码只会让它们**更绿**，"
                    + "一句藏在里面的 `lockFile: ClaudioPaths.playLockFile` 会对整套锁分离断言"
                    + "**永久隐身**。要么把这个构造挪走，要么先教 `strippingComments` 认识它")
        }
    }

    suite("五把锁是五个不同的文件 —— 锁分离的中心论点，此前零断言") {
        let locks: [(String, URL)] = [
            ("playLockFile", ClaudioPaths.playLockFile),
            ("configLockFile", ClaudioPaths.configLockFile),
            ("settingsLockFile", ClaudioPaths.settingsLockFile),
            ("logLockFile", ClaudioPaths.logLockFile),
            // 第五把（`/codex review b0ce657` 之后那次核查加的）：`manifest.json` 有两个写者
            // —— GUI 的 `mutateManifestJSON` 与 helper 的 `performFirstRunSetup`（目录粒度
            // 发布整棵包目录）。它必须与 `config.lock` 分开：`performFirstRunSetup` 会**同时**
            // 拿这两把（包循环一把、写 config 一把），合成一把就是自己锁自己。
            ("packsLockFile", ClaudioPaths.packsLockFile),
        ]

        // 两两不等。挡的是「某把锁被改回另一把」——一行就能静默 revert 掉整个阶段 A，
        // 而在这条断言之前，那一行不会让任何测试变红。
        for i in locks.indices {
            for j in locks.indices where j > i {
                let (nameA, lockA) = locks[i]
                let (nameB, lockB) = locks[j]
                expect(
                    lockA.path != lockB.path,
                    "\(nameA) 与 \(nameB) 解析到了同一个文件（\(lockA.path)）—— 两把锁指同一个文件"
                        + "就等于**没有分锁**。阶段 A 拆开它们，正是因为共用一把锁会让设置写占住 "
                        + "`play` 的去抖锁，把同一瞬间到达的事件判成 `.skippedDebounce`（静默、"
                        + "不记日志、用户少听一声提示音）")
            }
        }

        // 文件名本身也必须两两不同。上面那条在 `root` 相同时已经覆盖它，但把它单独说出来是为了
        // 让失败消息直接指到人看得懂的那一层（「config.lock 变成 play.lock 了」，而不是一串绝对路径）。
        let names = locks.map { $0.1.lastPathComponent }
        expect(
            Set(names).count == locks.count,
            "五把锁的文件名出现重复：\(names) —— 它们必须是 play.lock / config.lock / "
                + "settings.lock / claudio.log.lock / packs.lock 五个不同的名字")

        // 正向钉死每一个名字。上面两条只保证「互不相同」，保证不了「是**这四个**」——
        // 把几把锁整体改名成 a.lock/b.lock/c.lock 仍然两两不等，但会把每一台**已经装过**
        // Claudio 的机器上正在被持有的那把锁甩掉（旧进程持 play.lock，新进程持 a.lock，
        // 互斥当场消失）。锁文件名是**跨版本、跨进程**的契约，不是实现细节。
        let expected: [(String, String)] = [
            ("playLockFile", "play.lock"),
            ("configLockFile", "config.lock"),
            ("settingsLockFile", "settings.lock"),
            ("logLockFile", "claudio.log.lock"),
            ("packsLockFile", "packs.lock"),
        ]
        for (name, fileName) in expected {
            let actual = locks.first { $0.0 == name }?.1.lastPathComponent
            expect(
                actual == fileName,
                "\(name) 的文件名必须是 `\(fileName)`，实际是 `\(actual ?? "<nil>")` —— "
                    + "锁文件名是跨进程契约：改名 = 与所有**没有同时升级**的进程失去互斥")
        }
    }

    suite("生产默认值：每个写者默认拿的是它自己那把锁（源码绊线 —— 测试从不求值这些默认值）") {
        // `claudio install` → `installClaudioHooks()`，`claudio use` → `selectPack(packID)`，
        // 两条都是**全默认调用**（`Subcommands.swift:55` / `:93`，一个 lockFile 都不传）。
        // 而每一个现有测试都显式注入临时锁 —— 于是这些默认值在整个套件里**一次都没被求值过**。
        // 拿它们去跑真实调用来「测默认值」是不行的：那会写到真实的 `~/.claude/settings.json`。
        // 所以只能读源码文本。

        guard let use = codeOnly("helper/Sources/ClaudioCore/Use.swift"),
            let eventEnabled = codeOnly("helper/Sources/ClaudioCore/EventEnabled.swift"),
            let installer = codeOnly("helper/Sources/ClaudioCore/SettingsInstaller.swift"),
            let play = codeOnly("helper/Sources/ClaudioCore/Play.swift"),
            let log = codeOnly("helper/Sources/ClaudioCore/Log.swift")
        else {
            expect(false, "读不到 ClaudioCore 的源码 —— 这个 suite 唯一的价值就是读它们")
            return
        }

        // config.json 的两个写者 → config.lock
        expect(
            use.contains("lockFile: URL = ClaudioPaths.configLockFile"),
            "`selectPack` 的默认锁必须是 configLockFile —— `claudio use` 在 Subcommands.swift:93 "
                + "是全默认调用的。默认值写错，`claudio use` 当场回到 play.lock 上，一次换包就能"
                + "吞掉一声提示音，而没有任何测试会红")
        expect(
            eventEnabled.contains("lockFile: URL = ClaudioPaths.configLockFile"),
            "`setEventEnabled` 的默认锁必须是 configLockFile —— 它是 GUI 静音开关的写路径")

        // settings.json 的两个写者（install / uninstall）→ settings.lock
        let settingsDefaults =
            installer.components(separatedBy: "lockFile: URL = ClaudioPaths.settingsLockFile").count
            - 1
        expect(
            settingsDefaults == 4,
            "SettingsInstaller 里 `lockFile` 的默认值必须**处处**是 settingsLockFile（install 与 "
                + "uninstall 各两个重载 = 4 处），实际只找到 \(settingsDefaults) 处 —— 漏掉任何一处，"
                + "`claudio install` / `claudio uninstall` 就会回到 play.lock 上，settings.json 的"
                + "读-改-写重新占住 play 的去抖锁")

        // play 自己 → play.lock（正向，防止有人「统一」成 config.lock）
        expect(
            play.contains("lockFile: URL = ClaudioPaths.playLockFile"),
            "`play` 的默认锁必须是 playLockFile —— 它是去抖锁的**唯一**合法持有者")
        expect(
            log.contains("lockFile: URL = ClaudioPaths.logLockFile"),
            "`log` 的默认锁必须是 logLockFile —— 写日志绝不能被 play 的去抖锁挡住")

        // 负向兜底：config / settings 的写者在**任何位置**都不该出现 play 的去抖锁。
        // 注释已被 `codeOnly` 剥掉，所以 `Use.swift:50` / `SettingsInstaller.swift:29` 里
        // 那两句「我**不**用 playLockFile」的散文不会把这两条判假红。
        expect(
            !use.contains("playLockFile"),
            "Use.swift 的**代码**里出现了 playLockFile —— `selectPack` 写的是 config.json，"
                + "它一个字节都不写 play.state，碰 play 的锁只会重新把提示音吞掉")
        expect(
            !eventEnabled.contains("playLockFile"),
            "EventEnabled.swift 的**代码**里出现了 playLockFile —— 同上，静音开关写的是 config.json")
        expect(
            !installer.contains("playLockFile"),
            "SettingsInstaller.swift 的**代码**里出现了 playLockFile —— 装/卸 hook 写的是 "
                + "settings.json，与 play 的去抖毫无关系")
    }

    suite("CLI 的三个调用点仍是全默认调用 —— 上面那一排默认值的唯一活路（`/codex review d5ec97e,8f9cfa2`）") {
        // 上面那条 suite 钉的是**默认值**。可它整段的前提 ——「`claudio install` / `uninstall` /
        // `use` 是全默认调用的」—— 只以**注释**形式存在（就写在它自己第 130 行上）。而这个仓库
        // 自己的规矩是：该断言的地方不许放注释。这正是 D20 那条教训（「改默认值挡不住调用点」）
        // 第三次复发 —— 前两次分别在 GUI（`ViewWiringSuite`）和 `PanelView` 的构造点上。
        //
        // 变异：把 `Subcommands.swift:93` 改成
        //
        // ```swift
        // switch selectPack(packID, lockFile: ClaudioPaths.playLockFile) {
        // ```
        //
        // `claudio use` 当场回到 play.lock 上 —— 换一次包就吞一声提示音 —— 而
        // `Use.swift` 的默认值声明一个字没动，上面那条 suite 与整套 1000+ 断言**全绿**。
        // 默认值只有在没人覆盖它的时候才是默认值；「没人覆盖」得有人说出来。
        guard let subcommands = codeOnly("helper/Sources/claudio/Subcommands.swift") else {
            expect(false, "读不到 Subcommands.swift —— 这条 suite 唯一的价值就是读它")
            return
        }

        // 正向：三条调用必须**逐字**保持全默认形态。
        //
        // ⚠️ 每一条都连 `switch` 与 `{` 一起匹配，**两头都锚死**。这不是啰嗦 —— 本条断言的
        // 第一版写的是 `contains("installClaudioHooks()")`，而 `uninstallClaudioHooks()`
        // **逐字包含**它（就是 `un` + 它）。于是变异实测（把 `Subcommands.swift:55` 改成
        // `installClaudioHooks(lockFile: ClaudioPaths.playLockFile)`）时，install 这一行
        // 被第 72 行那个**没被碰过的 uninstall 调用**满足了，正向断言**结构上不可能变红** ——
        // 只有底下那条负向兜底救了场。一条措辞（「install 是全默认调用」）比它实际守的范围
        // （「文件里某处出现过这个子串」）更大的断言，正是这个 suite 存在的理由本身。
        // 子串断言没有词边界；`switch … {` 就是这里的词边界。
        // ⚠️ **四条，不是三条**（`/review e7c38ea` 的 P1-2）。上一版这里只列了 install / uninstall /
        // use，措辞却写着「它是**三个** CLI 命令的总入口」—— 而 `claudio setup`（`Subcommands.swift:107`，
        // v1 首次安装自举，仍在发布路径上）**也走锁**：它全默认构造 `SetupEnvironment`，两把锁全靠
        // `Setup.swift` 那两个默认实参。它当时既不在这份名单里，也（见下）躲得过负向兜底。
        // 又一次：措辞（「三个命令的总入口」）比覆盖范围（「这三行」）大，而漏掉的那一个是**首装**路径。
        let defaultCalls: [(call: String, command: String, lock: String)] = [
            ("switch installClaudioHooks() {", "claudio install", "settings.lock"),
            ("switch uninstallClaudioHooks() {", "claudio uninstall", "settings.lock"),
            ("switch selectPack(packID) {", "claudio use", "config.lock"),
            (
                "SetupEnvironment(executablePath: currentExecutablePath())", "claudio setup",
                "config.lock + settings.lock"
            ),
        ]
        for (call, command, lock) in defaultCalls {
            expect(
                subcommands.contains(call),
                "`\(command)` 在 Subcommands.swift 里必须仍然是全默认调用 `\(call)` —— 找不到它，"
                    + "要么调用形态变了、要么开始显式传锁了。两种情况下，这个命令用的还是不是 "
                    + "\(lock)，上面那条默认值 suite **一个字都没资格再说**")
        }

        // 负向兜底：Subcommands 在**任何位置**都不许出现任何锁。它是**四个** CLI 命令的总入口，
        // 锁的来源只有一个 —— 被调用函数（与 `SetupEnvironment`）的默认值。注释已被 `codeOnly`
        // 剥掉，谈论锁的散文不会把这条判假红。
        //
        // ⚠️ **大小写不敏感**（`/review e7c38ea` 的 P1-2）。上一版断的是 `!contains("lockFile")`，
        // 而子串匹配**大小写敏感** —— `configLockFile` / `settingsLockFile` / `playLockFile` 里那个
        // `L` 全是**大写**的，一个都不是 `lockFile` 的子串（`"lockFile" in "configLockFile" == false`）。
        // 于是把 `claudio setup` 那一行改成
        //
        // ```swift
        // let environment = SetupEnvironment(
        //     executablePath: currentExecutablePath(), configLockFile: ClaudioPaths.playLockFile)
        // ```
        //
        // —— `claudio setup`（首次安装！）在写 config.json 时占住 play 的去抖锁 —— 而这条负向兜底
        // 与上面那份名单**两条都碰不到它**。措辞（「任何位置都不许出现 lockFile」）比它实际数的那
        // 一种大小写写法大。一个 `lowercased()` 把三种标识符一起收进来。
        expect(
            !subcommands.lowercased().contains("lockfile"),
            "Subcommands.swift 的**代码**里出现了锁（lockFile / configLockFile / settingsLockFile，"
                + "大小写不敏感地数）—— CLI 一旦开始显式传锁，`Use.swift` / `SettingsInstaller.swift` / "
                + "`Setup.swift` 里那几个默认值就成了摆设：改对它们没用，改错它们也不会红。"
                + "锁分离在生产上到底成不成立，从此取决于这里传了什么")
    }

    suite("SetupEnvironment 的三把锁默认值（运行期可求值 —— 它是 struct，不是自由函数）") {
        // `performFirstRunSetup` 是 GUI「接管」CTA 落到磁盘上的那条路径，它**同时**写
        // config.json（selectPack ×2）和 settings.json（installClaudioHooks）。这两把锁必须
        // 是不同的两把，且都不是 play 的。
        //
        // 这一条不需要源码绊线：`SetupEnvironment` 是个 struct，默认实参在 `init` 上，
        // 构造一个就能把它们读出来 —— 纯值读取，不碰文件系统（`executablePath` 只是被存起来，
        // 构造函数不会去 stat 它）。
        let environment = SetupEnvironment(
            executablePath: URL(fileURLWithPath: "/nonexistent/claudio"))

        expect(
            environment.configLockFile.path == ClaudioPaths.configLockFile.path,
            "SetupEnvironment.configLockFile 默认必须是 config.lock，实际是 "
                + "\(environment.configLockFile.lastPathComponent)")
        expect(
            environment.settingsLockFile.path == ClaudioPaths.settingsLockFile.path,
            "SetupEnvironment.settingsLockFile 默认必须是 settings.lock，实际是 "
                + "\(environment.settingsLockFile.lastPathComponent)")
        expect(
            environment.packsLockFile.path == ClaudioPaths.packsLockFile.path,
            "SetupEnvironment.packsLockFile 默认必须是 packs.lock，实际是 "
                + "\(environment.packsLockFile.lastPathComponent)")
        expect(
            Set([
                environment.configLockFile.path, environment.settingsLockFile.path,
                environment.packsLockFile.path,
            ]).count == 3,
            "SetupEnvironment 的三把锁必须是**三把不同**的 —— 接管路径同时写 config.json、"
                + "settings.json 与 packs/ 下的整棵包目录，共用一把锁就是把刚拆开的东西又焊回去。"
                + "尤其 packs 与 config 合并 = `performFirstRunSetup` 自己锁自己（它两把都要），"
                + "非阻塞锁下不是死锁，是每一次 setup 都当场 `.skipped`")
        expect(
            environment.configLockFile.path != ClaudioPaths.playLockFile.path
                && environment.settingsLockFile.path != ClaudioPaths.playLockFile.path,
            "SetupEnvironment 的两把锁都不许是 play.lock —— 接管会在磁盘上写好几秒，"
                + "占住去抖锁就是在这几秒里静默吞掉用户的每一声提示音")
    }

    suite("包锁重试的**生产默认值**（测试全都显式注入，所以默认值没人求值过）") {
        // 台账实测逼出来的一条（R1）：把 `PacksLockRetry` 的默认 `attempts` 从 10 砍成 1 ——
        // 等于把「setup 侧放宽」整个取消 —— **两个包 3678 条断言全绿**。因为 `SetupSuite` 里
        // 那条时序测试显式注入了 `PacksLockRetry(attempts: 50, delay: 0.01)`，从来没碰过默认值。
        // 这与本文件开头记的那个病**逐字同形**：默认值有人写、没人求值，改错它不会红。
        let defaults = PacksLockRetry()
        expect(
            defaults.attempts > 1,
            "`PacksLockRetry` 默认必须**真的重试**（attempts > 1），实得 \(defaults.attempts) —— "
                + "1 次等于回到非阻塞语义，而「只放宽 setup 侧」这个决定的全部内容就是这次重试。"
                + "GUI 侧那几毫秒的 manifest 写会重新变成「整个安装当场失败」。")
        expect(
            defaults.delay > 0,
            "`PacksLockRetry` 默认的 delay 必须 > 0（实得 \(defaults.delay)）—— 0 延迟的 N 次重试"
                + "会在几微秒内烧完全部预算，等于没等：`flock` 的持有者还没来得及做完一次 33ms 的"
                + "包复制，重试就已经耗尽了。")
        // 预算下限绑在**实测**上，不是拍脑袋：内置包 508K、整棵复制实测 33ms，GUI 侧临界区更短。
        // 250ms 能盖住 7 个以上那样的窗口。这里断的是下限，不是具体的 10×50ms —— 调参不该变红，
        // 把预算调到盖不住实测窗口才该变红。
        //
        // 预算是**间隔之和**，不是「尝试次数 × 间隔」：`attempts` 次尝试之间只有 `attempts - 1` 次
        // `Thread.sleep`（第一次尝试前不睡，最后一次失败之后也不睡 —— 见 `performFirstRunSetup`
        // 的重试循环里那句 `if attempt < retry.attempts`）。写成 `attempts * delay` 会把预算算大
        // 一整个 `delay`，这条断言于是在为一段**生产上不存在的等待**背书 —— 而它守的恰恰是
        // 「预算够不够盖住实测的 33ms 窗口」。（`/codex review 48b6730` 的 P2。同一个错模型当时还长在
        // ``PacksLockRetry`` 的 doc 与 `SetupSuite` 的四处上 —— :45 的参数说明、:69 的余量估算、:88 的
        // 行内注释、以及 :104 那句**会印给用户**的失败消息 —— 一并扫掉了。措辞按实际清扫范围写：
        // 本注释的第一稿只写「PacksLockRetry 的 doc 上，一并改了」，把剩下四处说没了。）
        //
        // ⚠️ 这一改**吃掉了**上面两条的独立性，别当成加了一道防线：新式 `(attempts-1) * delay >= 0.25`
        // 在 `attempts <= 1` 时恒假、在 `delay == 0` 时也恒假，所以它**严格蕴含** `attempts > 1` 与
        // `delay > 0` 两条 —— 那两条自本次改式起没有专属靶子了，留着只为给出更具体的失败消息。
        // （旧式 `attempts * delay >= 0.25` 反而与它们独立：`attempts = 1, delay = 0.25` 能同时满足旧式
        // 与「预算够」却完全不重试。也就是说独立性是被**我这一刀**消掉的。本注释第一稿写的是
        // 「两根不同的轴各自独立成立」，正好说反 —— 红队 F3 逮到。）
        // 真要一根独立的轴，该断的是**重试循环本身**（注入 attempts = 2 断言它真睡了一次，形状见
        // `SetupSuite` 那条时序测试），不是继续在默认值上加谓词。
        let budget = Double(defaults.attempts - 1) * defaults.delay
        expect(
            budget >= 0.25,
            "`PacksLockRetry` 的默认总预算是 \(budget)s，低于 0.25s 下限 —— 实测一次内置包发布"
                + "（508K，整棵复制）要 33ms，预算至少要盖住若干个这样的窗口才有意义。")
        expect(
            SetupEnvironment(executablePath: URL(fileURLWithPath: "/nonexistent/claudio"))
                .packsLockRetry == defaults,
            "SetupEnvironment 必须默认转发 `PacksLockRetry()` —— 它自己另起一套默认值，"
                + "上面三条就只在钉一个没人用的类型")
    }

    suite("接管路径的调用点确实转发 SetupEnvironment 的锁（上面那四条断言的唯一活路）") {
        // 上面那条 suite 求值的是 `SetupEnvironment` 的**默认属性**。而 `performFirstRunSetup`
        // 完全可以把它们晾在一边，直接朝下游写死一把锁 —— 于是那四条断言继续绿着，
        // 而接管路径在生产上拿的是别的锁。这与 CLI 那条（Subcommands）是**同一个洞**：
        // 默认值有人钉，调用点没人钉。区别只是这条路径更要命 —— 它是 GUI「接管」CTA 落到
        // 磁盘上的那一下，同时写 config.json（selectPack ×2）与 settings.json（install ×1），
        // 在磁盘上要写好几秒。
        //
        // 变异：把 `Setup.swift:551` 的 `lockFile: environment.settingsLockFile` 改成
        // `lockFile: ClaudioPaths.playLockFile` —— 接管的那几秒占住去抖锁，用户在**最需要
        // 反馈的那一刻**被静音，而 `SetupEnvironment` 的默认值一个字没动，四条断言全绿。
        //
        // ## 为什么是按调用点绑锁，而不是数计数（`/codex review 840ea37` 的 P1）
        //
        // 这条 suite 的**上一版**断的是三个全文件计数（config 出现 2 次 / settings 1 次 / play 0 次）。
        // 计数不绑定调用点：把一处 `selectPack` 的锁与 `installClaudioHooks` 的锁**成对交换**，
        // 三个计数原样成立、**全绿**，而 config.json 的写守着 settings.lock、settings.json 的写
        // 守着 config.lock —— 两把锁在生产上全串了。措辞（「确实转发」）比覆盖范围（「数得对」）大，
        // 正是本 commit 通篇要杀的病，当时复发在杀它的那一刀里。变异台账当初只测了**单边**改写
        // （settings→play、config→play），成对交换这一类没进台账，于是没被想到。
        // 详见 `callArguments(of:in:)` 的文档。
        //
        // ⚠️ 这条 suite 读**两路**，因为它下面两类断言的**极性相反**，安全的那一侧也就相反：
        //
        //  · `setupStructure`（`codeWithoutStrings`，清空字符串内容）喂 `callArguments` ——
        //    它按括号配平切实参，而保留字符串内容会让实参表里一句带不配对括号的字面量
        //    （`"pack (1.json"`）把深度算歪，从此那处调用的实参再也切不出来。
        //  · `setup`（`codeOnly`，**保留**字符串内容）喂下面两条**负向**兜底。这一路不能换：
        //    `!setup.contains("play.lock")` 的 needle 本身就是一句**字符串字面量**，清空之后它
        //    **永远命中不了** —— 而那条断言存在的全部理由，正是拦住值级假名
        //    `ClaudioPaths.root.appendingPathComponent("play.lock")`（见它自己上方那段注释）。
        //    换句话说：对负向断言，喂更少的文本是 fail-**open**。
        //
        // 这两处此前共用一个 `codeOnly` 绑定。切换时我先把两处一起换成了 `codeWithoutStrings`，
        // 当场把上面那条值级假名兜底打死了 —— 一次「同一个变量喂给极性相反的两类断言」的典型事故。
        guard let setupStructure = codeWithoutStrings("helper/Sources/ClaudioCore/Setup.swift"),
            let setup = codeOnly("helper/Sources/ClaudioCore/Setup.swift")
        else {
            expect(false, "读不到 Setup.swift —— 这条 suite 唯一的价值就是读它")
            return
        }

        // ## 围栏：`callArguments` 认不出的形状 ⇒ 当场红（`/codex review 37745f2` 的 P1）
        //
        // 下面两条是**精确计数**（2 处 / 1 处），比「≥1 处」强得多 —— 一个死代码诱饵会把计数顶到
        // 3 而当场红。但计数守不住另一件事：**扫描器根本没数到的那一处**。`#if` 就是这样一条路 ——
        // 扫描器不建模条件编译，一个 `#if false` 里的调用点与活跃分支的完全同形，它会顶替真实
        // 调用点凑够那个计数，而真实调用点搬到别处、锁随便传。
        //
        // ⚠️ 如实说明适用性：这里的 `head` 是**函数调用**（`switch selectPack`），不是类型构造。
        // 所以这个围栏记的三类里，只有 `#if` 那一类对本处是真正对口的；`typealias` 与上下文
        // `.init(` 是**保守多报**（对函数调用它们不构成隐身路）。之所以照样用同一个函数而不是
        // 手写第三条 `#if` grep：极性是「多报 = 有人喊 = fail-closed」，而三处分散的 grep 会在
        // 下一次「新增一种认不出的形状」时漏改其中一处 —— 这个仓库栽过那一跤。
        let unmodeledShapes = unmodeledConstructionShapes(
            of: "switch selectPack", in: setupStructure)
        expect(
            unmodeledShapes.isEmpty,
            "`Setup.swift` 里出现了扫描器认不出的构造/条件编译形状：\(unmodeledShapes) —— 下面两条"
                + "**计数**断言会被非活跃分支里的调用点顶替着凑数，而真实调用点可以搬走、锁随便传，"
                + "没有任何人会喊。要么把它挪走，要么先把 `callArguments` 教会这个形状再放行")

        // `selectPack` 的两个调用点（兜底包与用户选中的包）—— 两处都必须转发 config.lock。
        let selectPackCalls = callArguments(of: "switch selectPack", in: setupStructure)
        expect(
            selectPackCalls.count == 2,
            "接管路径里必须正好有 2 处 `switch selectPack(…)` 调用（兜底包与用户选中的包），"
                + "实际 \(selectPackCalls.count) 处 —— 前提变了，下面那两条「每一处都转发 config.lock」"
                + "的断言就不再覆盖整条接管路径，必须重新想")
        for (ordinal, arguments) in selectPackCalls.enumerated() {
            let lock = argumentValue("lockFile", in: arguments)
            expect(
                lock == "environment.configLockFile",
                "接管路径第 \(ordinal + 1) 处 `switch selectPack(…)` 的 `lockFile:` 实参必须**正好是** "
                    + "`environment.configLockFile`，实际是 `\(lock ?? "<没有这个实参>")` —— 这一处写的是 "
                    + "config.json，它必须守着 config.lock。锁传成别的（哪怕另一处 selectPack 传对了、"
                    + "全文件计数照样对得上），这一次 config.json 的写就跑到别人的锁下面去了。"
                    + "**相等**，不是 `contains`：`environment.configLockFile.deletingLastPathComponent()"
                    + ".appendingPathComponent(\"play.lock\")` 逐字包含前者，拿到的却是去抖锁")
        }

        // `installClaudioHooks` 那一处 —— 必须转发 settings.lock。
        //
        // ⚠️ `head` 连 `switch` 一起传：`uninstallClaudioHooks(` 逐字包含 `installClaudioHooks(`，
        // 只传函数名会被一个 uninstall 调用满足 —— 本文件上一次翻的正是这个车。
        let installCalls = callArguments(of: "switch installClaudioHooks", in: setupStructure)
        expect(
            installCalls.count == 1,
            "接管路径里必须正好有 1 处 `switch installClaudioHooks(…)` 调用，"
                + "实际 \(installCalls.count) 处")
        for arguments in installCalls {
            let lock = argumentValue("lockFile", in: arguments)
            expect(
                lock == "environment.settingsLockFile",
                "接管路径的 `switch installClaudioHooks(…)` 的 `lockFile:` 实参必须**正好是** "
                    + "`environment.settingsLockFile`，实际是 `\(lock ?? "<没有这个实参>")` —— 这一处"
                    + "写的是 settings.json，它必须守着 settings.lock。传成 config.lock，settings.json "
                    + "的写就跑到 config 的锁下面去了；而只要 selectPack 那两处反过来传 settings.lock，"
                    + "全文件计数还是对的")
        }

        // 负向兜底一：接管一个字节都不写 play.state，代码里不许出现 play 的去抖锁。
        //
        // ⚠️ 连**值级假名**一起拦（`/review e7c38ea`）：只禁标识符 `playLockFile` 拦不住
        // `ClaudioPaths.root.appendingPathComponent("play.lock")` —— 它拿到的是**同一把**锁，而那个
        // 标识符一次都不出现。上面那两条 `argumentValue` 的相等判定已经把这两处调用点的锁钉死了，
        // 这一条是**全文件**的兜底：将来 Setup.swift 里长出第三个写者时，它得先撞上这一条。
        expect(
            !setup.contains("playLockFile") && !setup.contains("play.lock"),
            "Setup.swift 的**代码**里出现了 playLockFile 或字面量 `play.lock` —— 接管写的是 config.json "
                + "与 settings.json，一个字节都不写 play.state。让接管去占去抖锁，等于在用户点下「接管」"
                + "之后那几秒里把他的每一声提示音静默吞掉 —— 而那正是他最需要听见反馈的一刻")

        // 负向兜底二：全文件正好 3 处锁转发 —— 上面按调用点绑死的就是这 3 处。多出第 4 处，
        // 说明接管路径长出了一个上面三条断言**没在看**的锁写者：当场红，逼人回这里想清楚它该拿哪把锁。
        let totalForwards = setup.components(separatedBy: "lockFile:").count - 1
        expect(
            totalForwards == 3,
            "Setup.swift 的代码里必须正好有 3 处 `lockFile:` 转发（selectPack ×2 + installClaudioHooks ×1），"
                + "实际 \(totalForwards) 处 —— 上面几条断言按调用点绑死的就是这 3 处。多出一处，就是接管"
                + "路径上多了一个没人盯着锁的写者")
    }
}
