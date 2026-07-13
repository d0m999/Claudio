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

/// 一个源文件**剥掉注释**之后的样子。
///
/// 不剥注释，下面每一条负向断言都会被**谈论 `playLockFile` 的散文**判成假红 —— `Use.swift:50`
/// 与 `SettingsInstaller.swift:29` 的 doc comment 里都白纸黑字写着 `ClaudioPaths/playLockFile`
/// （写的正是「我**不**用这把锁」）。`ViewWiringSuite` 的第一版就是在这里翻的车，代价记在它的
/// 文件头上；这里不重犯。
@MainActor
private func codeOnly(_ relativePath: String) -> String? {
    guard let data = try? Data(contentsOf: repoRoot().appendingPathComponent(relativePath)),
        let text = String(data: data, encoding: .utf8)
    else { return nil }
    return text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            guard let range = line.range(of: "//") else { return String(line) }
            return String(line[line.startIndex..<range.lowerBound])
        }
        .joined(separator: "\n")
}

/// `source` 里每一处 `head(` 调用的**实参文本**（从左括号后到与之配平的右括号前）。
///
/// 为什么不能只数全文件的锁出现次数（`/codex review 840ea37` 的 P1）：计数**不绑定调用点**。
/// 「`configLockFile` 出现 2 次、`settingsLockFile` 出现 1 次」这三条计数断言，被下面这个
/// **成对交换**整体满足 ——
///
/// ```swift
/// switch selectPack(…, lockFile: environment.settingsLockFile)   // config.json 的写，守着 settings.lock
/// switch installClaudioHooks(…, lockFile: environment.configLockFile)  // settings.json 的写，守着 config.lock
/// ```
///
/// —— 总数仍是 2 config / 1 settings / 0 play，**全绿**，而接管路径在生产上两把锁全串了。
/// 上一版的措辞（「调用点**确实转发** SetupEnvironment 的锁」）比它实际守的范围（「数得对」）大。
/// 那正是这个文件通篇要杀的病，复发在杀它的那一刀里。锁必须**按调用点**绑。
///
/// `head` 要连 `switch` 一起传（`"switch installClaudioHooks"`）：`uninstallClaudioHooks(`
/// **逐字包含** `installClaudioHooks(`，光传函数名就会被一个 uninstall 调用满足 —— 本文件
/// 上一次翻的正是这个车。头由 `switch …(` 锚、尾由配平括号锚，两头锁死。
@MainActor
private func callArguments(of head: String, in source: String) -> [String] {
    let needle = head + "("
    var calls: [String] = []
    var cursor = source.startIndex
    while let hit = source.range(of: needle, range: cursor..<source.endIndex) {
        var depth = 1
        var index = hit.upperBound
        while index < source.endIndex, depth > 0 {
            switch source[index] {
            case "(": depth += 1
            case ")": depth -= 1
            default: break
            }
            if depth == 0 { break }
            index = source.index(after: index)
        }
        // 括号没配平 = 源码被截断或读串了。宁可回一个空实参让调用方当场红，也不要静默少数一处调用。
        guard depth == 0 else {
            calls.append("")
            break
        }
        calls.append(String(source[hit.upperBound..<index]))
        cursor = source.index(after: index)
    }
    return calls
}

@MainActor
func runLockSeparationSuites() {
    suite("四把锁是四个不同的文件 —— 锁分离的中心论点，此前零断言") {
        let locks: [(String, URL)] = [
            ("playLockFile", ClaudioPaths.playLockFile),
            ("configLockFile", ClaudioPaths.configLockFile),
            ("settingsLockFile", ClaudioPaths.settingsLockFile),
            ("logLockFile", ClaudioPaths.logLockFile),
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
            "四把锁的文件名出现重复：\(names) —— 它们必须是 play.lock / config.lock / "
                + "settings.lock / claudio.log.lock 四个不同的名字")

        // 正向钉死每一个名字。上面两条只保证「互不相同」，保证不了「是**这四个**」——
        // 把三把锁整体改名成 a.lock/b.lock/c.lock 仍然两两不等，但会把每一台**已经装过**
        // Claudio 的机器上正在被持有的那把锁甩掉（旧进程持 play.lock，新进程持 a.lock，
        // 互斥当场消失）。锁文件名是**跨版本、跨进程**的契约，不是实现细节。
        let expected: [(String, String)] = [
            ("playLockFile", "play.lock"),
            ("configLockFile", "config.lock"),
            ("settingsLockFile", "settings.lock"),
            ("logLockFile", "claudio.log.lock"),
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
        let defaultCalls: [(call: String, command: String, lock: String)] = [
            ("switch installClaudioHooks() {", "claudio install", "settings.lock"),
            ("switch uninstallClaudioHooks() {", "claudio uninstall", "settings.lock"),
            ("switch selectPack(packID) {", "claudio use", "config.lock"),
        ]
        for (call, command, lock) in defaultCalls {
            expect(
                subcommands.contains(call),
                "`\(command)` 在 Subcommands.swift 里必须仍然是全默认调用 `\(call)` —— 找不到它，"
                    + "要么调用形态变了、要么开始显式传锁了。两种情况下，这个命令用的还是不是 "
                    + "\(lock)，上面那条默认值 suite **一个字都没资格再说**")
        }

        // 负向兜底：Subcommands 在**任何位置**都不许出现 lockFile。它是三个 CLI 命令的
        // 总入口，锁的来源只有一个 —— 被调用函数的默认值。注释已被 `codeOnly` 剥掉，
        // 谈论锁的散文不会把这条判假红。
        expect(
            !subcommands.contains("lockFile"),
            "Subcommands.swift 的**代码**里出现了 lockFile —— CLI 一旦开始显式传锁，"
                + "`Use.swift` / `SettingsInstaller.swift` 里那几个默认值就成了摆设：改对它们没用，"
                + "改错它们也不会红。锁分离在生产上到底成不成立，从此取决于这里传了什么")
    }

    suite("SetupEnvironment 的两把锁默认值（运行期可求值 —— 它是 struct，不是自由函数）") {
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
            environment.configLockFile.path != environment.settingsLockFile.path,
            "SetupEnvironment 的两把锁必须是**不同的**两把 —— 接管路径同时写 config.json 与 "
                + "settings.json，共用一把锁就是把刚拆开的东西又焊回去")
        expect(
            environment.configLockFile.path != ClaudioPaths.playLockFile.path
                && environment.settingsLockFile.path != ClaudioPaths.playLockFile.path,
            "SetupEnvironment 的两把锁都不许是 play.lock —— 接管会在磁盘上写好几秒，"
                + "占住去抖锁就是在这几秒里静默吞掉用户的每一声提示音")
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
        guard let setup = codeOnly("helper/Sources/ClaudioCore/Setup.swift") else {
            expect(false, "读不到 Setup.swift —— 这条 suite 唯一的价值就是读它")
            return
        }

        // `selectPack` 的两个调用点（兜底包与用户选中的包）—— 两处都必须转发 config.lock。
        let selectPackCalls = callArguments(of: "switch selectPack", in: setup)
        expect(
            selectPackCalls.count == 2,
            "接管路径里必须正好有 2 处 `switch selectPack(…)` 调用（兜底包与用户选中的包），"
                + "实际 \(selectPackCalls.count) 处 —— 前提变了，下面那两条「每一处都转发 config.lock」"
                + "的断言就不再覆盖整条接管路径，必须重新想")
        for (ordinal, arguments) in selectPackCalls.enumerated() {
            expect(
                arguments.contains("lockFile: environment.configLockFile"),
                "接管路径第 \(ordinal + 1) 处 `switch selectPack(…)` 的实参里没有 "
                    + "`lockFile: environment.configLockFile` —— 这一处写的是 config.json，它必须"
                    + "守着 config.lock。锁传成别的（哪怕另一处 selectPack 传对了、全文件计数照样对得上），"
                    + "这一次 config.json 的写就跑到别人的锁下面去了")
        }

        // `installClaudioHooks` 那一处 —— 必须转发 settings.lock。
        //
        // ⚠️ `head` 连 `switch` 一起传：`uninstallClaudioHooks(` 逐字包含 `installClaudioHooks(`，
        // 只传函数名会被一个 uninstall 调用满足 —— 本文件上一次翻的正是这个车。
        let installCalls = callArguments(of: "switch installClaudioHooks", in: setup)
        expect(
            installCalls.count == 1,
            "接管路径里必须正好有 1 处 `switch installClaudioHooks(…)` 调用，"
                + "实际 \(installCalls.count) 处")
        for arguments in installCalls {
            expect(
                arguments.contains("lockFile: environment.settingsLockFile"),
                "接管路径的 `switch installClaudioHooks(…)` 实参里没有 "
                    + "`lockFile: environment.settingsLockFile` —— 这一处写的是 settings.json，"
                    + "它必须守着 settings.lock。传成 config.lock，settings.json 的写就跑到 config 的"
                    + "锁下面去了；而只要 selectPack 那两处反过来传 settings.lock，全文件计数还是对的")
        }

        // 负向兜底一：接管一个字节都不写 play.state，代码里不许出现 playLockFile。
        expect(
            !setup.contains("playLockFile"),
            "Setup.swift 的**代码**里出现了 playLockFile —— 接管写的是 config.json 与 settings.json，"
                + "一个字节都不写 play.state。让接管去占去抖锁，等于在用户点下「接管」之后那几秒里"
                + "把他的每一声提示音静默吞掉 —— 而那正是他最需要听见反馈的一刻")

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
