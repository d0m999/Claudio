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
}
