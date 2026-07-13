import ClaudioCore
import Foundation

// MARK: - 不变量：每一次「内容替换式写盘」都必须是原子的。全仓零豁免。
//
// ## 它为什么存在
//
// `SettingsInstaller.backupOriginalIfNeeded` 曾经是全仓**唯一**的非原子写（`try originalData
// .write(to: backupFile)`，没有 `options:`）——而它守的恰恰是全仓最重的那个承诺：用户
// pre-claudio `settings.json` 的**唯一一份副本**。
//
// 这不是「少写了个参数」那么轻。三件事合起来才是它的真形状：
//
// 1. `.claudio.bak` 按设计**永不刷新**（`fileExists` 闸门 = 「一次性备份」）；
// 2. 那道闸门认得的只有「有没有这个文件」，认不出「这是一份**残缺**的备份」；
// 3. `.claudio.bak` **没有任何程序化读者** —— 卸载刻意不从它还原（ENGINEERING.md:138）。它整个
//    存在的意义，就是在用户需要的那一天替他把东西还回去，而 CLI 的「备份见 settings.json.claudio.bak」、
//    onboarding 的信任文案（ENGINEERING.md:238）、`docs/distribution.md:93` 三处都向他承诺过它。
//
// 于是一次被打断的非原子写（进程被 kill、掉电）留下的半截文件，会**永久冒充**那份备份，而没有
// 任何代码、任何界面、任何测试会发现它。用户在需要它的那一天才会知道。
//
// ## 形状：递归枚举，不是名单
//
// 刻意**不**维护一张「要扫哪些文件」的名单。名单会过期成**假绿**：新加一个源文件、里面一次非原子
// 写，名单不认得它 → 一条都不红。所以这里递归枚举 `helper/Sources` + `gui/Sources` 下的每一个
// `.swift`。加文件不用改这里；加一次非原子写会当场红。
//
// 同理**不设白名单**。今天全仓 9 处内容替换式写盘，9 处原子 —— 不变量是**全称的**，一个豁免都
// 不需要。这很要紧：白名单永远不完整（`SourceScannerSuite` 的文件头记着这条教训的两次学费），
// 而一条「零豁免」的不变量没有让人往里塞东西的地方。真到了非豁免不可的那天，请在这里加断言 +
// 在被豁免处写清理由，而不是悄悄放行。
//
// ## ⚠️ 它**不**兜什么（措辞不得比覆盖范围大 —— 这个仓库栽在这上面十四次）
//
// 它只认 `Data.write(to:options:)` / `String.write(to:atomically:encoding:)` 这**一种**写盘出口。
// 它**看不见**：
//
// - **裸 fd 写**（`open(2)` + `write(2)`）。`Log.swift:112` 就是一处，而且它**故意**不走替换语义：
//   日志是 `O_APPEND` 上的单次 `write(2)` 追加，那是另一套原子性纪律（追加不是替换，把它改成
//   `.atomic` 反而会把整份日志覆盖掉）。所以下面第三条 suite 单独兜这个洞：**允许持有写意图 fd
//   的生产文件只有 `Log.swift`（日志追加）与 `FileLock.swift`（锁文件创建）**。第三个文件开始裸写
//   就当场红 —— 否则「用 `open(2)` 绕过这条绊线去写 config.json」是一条敞开的后门。
// - **`copyItem` / `moveItem` / `removeItem`**（`Setup.swift`、`Quarantine.swift`、`AudioImport.swift`）。
//   它们的原子性纪律是另一条（T17e 的 staging 目录 + `rename`），不归这里管，也不该归。
//
// ## 正向对照（第二条 suite）：一个抓不到非原子写的检测器，会把这条不变量变成恒真
//
// 把 `isAtomicWrite` 掏空成 `return true`、或者把 needle 打错一个字母让 `writeCallArguments`
// 一处都抓不到 —— 第一条 suite 会**全绿**，而它在失败消息里自称守着「用户配置的唯一副本」。
// 这与 `FileWriteWatch`（`gui/Tests/…/TestSupport.swift`）、`SourceScannerSuite` 是**逐字同一个
// 病**：守卫读的东西证明不了它声称守住的东西。
//
// 所以两道对照，缺一不可：
//
// - **反恒真的下界**：第一条 suite 断言真实源码里至少抓到 9 处写盘。needle 坏掉 → 0 处 → 当场红。
//   （`>= 9` 而不是 `== 9`：加一处**原子**写是好事，不该红。）
// - **喂合成输入、正向断言输出**：非原子写必须被抓出来；四种合法原子写法一处都不许误判；跨行调用
//   必须照样看得见（检测器按**配平括号**取实参，不按行 —— 按行会漏掉每一次换行的调用）。

/// 仓库根 —— 从 `#filePath` 推（编译期常量，不依赖 cwd）。
/// `helper/Tests/ClaudioCoreTests/AtomicWriteSuite.swift` → 上溯 4 层。
private func repoRoot(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

/// 今天真实存在的两棵生产源码树 —— 只是**期望值**，不是扫描的依据（见下）。
///
/// 测试树刻意不在里面：测试里到处是**故意的**非原子写、原地重写、FIFO
/// （`rewriteInPlaceRestoringContentAndModificationTime` 整个函数就是一次刻意的非原子原地写），
/// 扫它们只会换来一堆必须豁免的假红 —— 而豁免正是这条不变量最不该有的东西。
private let expectedProductionSourceTrees: Set<String> = ["helper/Sources", "gui/Sources"]

/// 仓库里**实际**有哪些 `<包>/Sources` —— 从磁盘发现，不从上面那个常量读。
///
/// ⚠️ 第一版这里是把 `expectedProductionSourceTrees` **当成扫描名单**用的，而那是同一个病在树这一层
/// 的复发：加第三个 SPM 包（`shared/Sources`…），名单不认得它 → 那棵树下每一次非原子写都**永久隐身**，
/// 而绊线全绿。文件那一层我用递归枚举绕开了这个坑，树这一层却又亲手挖了一个。
///
/// 现在两头都钉：扫的是**发现**到的树，而「发现到的 == 期望的」由下面第一条 suite 断言。加一个包 →
/// 那条断言当场红 → 作者必须回来看一眼这条不变量该不该管它。名单只能用来**发现变化**，不能用来
/// **决定扫什么**。
private func discoveredProductionSourceTrees() -> Set<String> {
    let root = repoRoot()
    guard
        let packages = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])
    else { return [] }
    var trees: Set<String> = []
    for package in packages {
        let sources = package.appendingPathComponent("Sources")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: sources.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            trees.insert(package.lastPathComponent + "/Sources")
        }
    }
    return trees
}

/// 每一棵**发现到的**树下的每一个 `.swift`，仓库相对路径，排序后返回
/// （枚举顺序不稳定，排序只是让失败消息可读）。
private func productionSwiftFiles() -> [String] {
    let root = repoRoot()
    var found: [String] = []
    for tree in discoveredProductionSourceTrees().sorted() {
        let treeURL = root.appendingPathComponent(tree)
        guard
            let walker = FileManager.default.enumerator(
                at: treeURL, includingPropertiesForKeys: nil)
        else { continue }
        for case let url as URL in walker where url.pathExtension == "swift" {
            found.append(tree + url.path.dropFirst(treeURL.path.count))
        }
    }
    return found.sorted()
}

/// 一个源文件剥掉注释之后的样子（字符串字面量原样保留）。
///
/// 必须剥注释：本文件自己的 doc comment 里就白纸黑字写着 `try originalData.write(to: backupFile)`
/// （在讲那次翻车），`SettingsInstaller.swift:585` 与 `ManifestBinding.swift:72` 的散文里也写着
/// `Data.write(to:options:.atomic)`。不剥注释，检测器会把**谈论代码的散文**当成调用点。
///
/// 两个方向都得钉：剥太少 → 假红（没人受得了，会被删掉）；剥太多 → **假绿**（一处被误吞进
/// 「字符串」的非原子写从此永久隐身）。剥注释这活儿由 `TestSupport.strippingComments` 干，它自己
/// 的行为由 `SourceScannerSuite` 喂合成输入钉死；这里只管**用**它，并在它自认读不懂的时候当场红。
@MainActor
private func scanProduction(_ relativePath: String) -> StrippedSwiftSource? {
    guard let data = try? Data(contentsOf: repoRoot().appendingPathComponent(relativePath)),
        let text = String(data: data, encoding: .utf8)
    else { return nil }
    return strippingComments(text)
}

/// `source` 里每一处 `.write(` 调用的**实参文本**（左括号后到配平右括号前）。
///
/// 按**配平括号**取，不按行 —— 一次跨行的写调用按行取只看得到半截实参，看不到下一行的
/// `options: .atomic`，会把一次合法的原子写判成非原子 → 假红 → 有人来「修」检测器 → 修松了 → 假绿。
///
/// ⚠️ needle 是 `.write(`，**不是** `.write(to:` —— 第一版就是后者，而它**匹配不到跨行调用**：
///
/// ```swift
/// try data.write(
///     to: settingsFile, options: .atomic)   // `(` 与 `to:` 之间隔着换行 → needle 不匹配
/// ```
///
/// 那样一次写盘会从这条绊线眼皮底下**整个走过去**，一条断言都不会跑在它身上 —— 而绊线全绿。
/// 这不是假想：本文件那条「跨行」正向对照**当场**逮住了它（第一版实测红）。needle 只锚函数名和
/// 左括号，`to:` 留给下面的形状判定去认。
private func writeCallArguments(in source: String) -> [String] {
    let needle = ".write("
    var calls: [String] = []
    var cursor = source.startIndex
    while let hit = source.range(of: needle, range: cursor..<source.endIndex) {
        // needle 以左括号结尾，所以实参从 needle 之后第一个字符开始，深度已经是 1。
        let argumentsBegin = hit.upperBound
        var depth = 1
        var index = argumentsBegin
        while index < source.endIndex, depth > 0 {
            switch source[index] {
            case "(": depth += 1
            case ")": depth -= 1
            default: break
            }
            if depth == 0 { break }
            index = source.index(after: index)
        }
        // 括号没配平 = 源码被截断或读串了。宁可回一个空实参让调用方当场红（空实参不含
        // `options:`，判定为非原子），也不要静默少数一处调用。
        guard depth == 0 else {
            calls.append("")
            break
        }
        calls.append(String(source[argumentsBegin..<index]))
        cursor = source.index(after: index)
    }
    return calls
}

/// `arguments` 按**顶层逗号**（括号 / 方括号 / 花括号深度为 0 的那些）切开、逐段 trim。
///
/// 不能直接 `contains("options: .atomic")`：子串断言没有词边界（`/review e7c38ea` 的 P2 —— 同一个
/// 病在 `LockSeparationSuite.argumentValue` 的文档里有完整案底）。`options: writeOptions(.atomic)`
/// 这种嵌套形状必须按标签**整段**取出来判，而不是在整串实参里碰运气找子串。
private func topLevelArguments(_ arguments: String) -> [String] {
    var parts: [String] = []
    var depth = 0
    var current = ""
    for character in arguments {
        switch character {
        case "(", "[", "{":
            depth += 1
            current.append(character)
        case ")", "]", "}":
            depth -= 1
            current.append(character)
        case "," where depth == 0:
            parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
            current = ""
        default:
            current.append(character)
        }
    }
    parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
    return parts.filter { !$0.isEmpty }
}

/// 这次 `.write(…)` 是一次**内容替换式**写盘吗（第一个顶层实参的标签是 `to:`）？
///
/// needle 放宽成 `.write(` 之后，它会同时抓到 `FileHandle.write(_:)` 这类**不经路径**的写
/// （`handle.write(data)`）。那种写不是「把一个 URL 的内容整个换掉」，`options:` / `atomically:`
/// 对它没有意义 —— 但它**也不是**可以放过去的东西：一次 `FileHandle(forWritingTo: configFile)`
/// 就能绕开这整条不变量。所以这里不静默跳过，交给调用方当场红（见第一条 suite）。
private func isContentReplacingWrite(_ arguments: String) -> Bool {
    topLevelArguments(arguments).first?.hasPrefix("to:") ?? false
}

/// 这次 `.write(to:…)` 是原子的吗？
///
/// 两种合法出口，各自的原子性开关不同 —— 只认一种就会把另一种判成假红：
///
/// - `Data.write(to:options:)` → `options` 里必须有 `.atomic`（`[.atomic, .withoutOverwriting]`
///   这种集合字面量也算）。
/// - `String.write(to:atomically:encoding:)` → `atomically:` 必须**字面**是 `true`（`Play.swift:319`
///   的 `play.state` 走的正是这条）。
///
/// **默认 fail closed**：两个标签一个都没有 → 非原子。`options:` 的值是个变量（`options: writeOptions`）
/// → 也判非原子，因为这里读不出那个变量里到底有没有 `.atomic`。宁可让一次「其实是原子的」写法
/// 当场红、逼作者写清楚，也不要让一次真的非原子写溜过去 —— 这条不变量守的是用户配置的唯一副本，
/// 假红有人喊，假绿没人看得见。
private func isAtomicWrite(_ arguments: String) -> Bool {
    for argument in topLevelArguments(arguments) {
        if argument.hasPrefix("options:") {
            return argument.contains(".atomic")
        }
        if argument.hasPrefix("atomically:") {
            let value = argument.dropFirst("atomically:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value == "true"
        }
    }
    return false
}

/// 写意图的 `open(2)` flag。`O_RDONLY` 刻意不在里面 —— `SafeFileRead` 的有界只读走的正是它，
/// 它不是写者。
private let writeIntentOpenFlags = ["O_WRONLY", "O_RDWR", "O_APPEND"]

/// 允许持有**写意图裸 fd** 的生产文件。名单短、且每一条都有非要不可的理由：
///
/// - `Log.swift` —— 日志追加。`O_APPEND` 上的单次 `write(2)`，是**追加**不是**替换**：改成
///   `.atomic` 会用一行覆盖掉整份日志。它有自己的原子性纪律，不归上面那条不变量管。
/// - `FileLock.swift` —— 锁文件本身。`flock(2)` 要一个 fd，而拿到 fd 的唯一办法就是 `open(2)`。
///
/// 这张名单是这条不变量的**后门锁**：没有它，任何人都能用 `open(2)` + `write(2)` 写 config.json /
/// settings.json，而上面那条「每一处写盘都原子」一声不吭 —— 它只认 `.write(to:`。
private let rawWriteFileDescriptorHolders: Set<String> = [
    "helper/Sources/ClaudioCore/Log.swift",
    "helper/Sources/ClaudioCore/FileLock.swift",
]

@MainActor
func runAtomicWriteSuites() {
    suite("写盘绊线：全仓每一处内容替换式写盘都必须是原子的（零豁免）") {
        // 先钉「我扫的是不是全部的树」。加一个 SPM 包而不回来看这条不变量，是这条绊线唯一一种
        // 会**整棵树静默失明**的失效方式 —— 而它不会红，除非这里正面断言。
        let trees = discoveredProductionSourceTrees()
        expect(
            trees == expectedProductionSourceTrees,
            "仓库里的生产源码树变了。期望 \(expectedProductionSourceTrees.sorted())，"
                + "实际发现 \(trees.sorted())。多出来的那棵树下的每一次非原子写，这条绊线在你更新"
                + "`expectedProductionSourceTrees` 之前都**看得见**（扫描按发现走），但你必须回来"
                + "确认一次：这条「每一处写盘都原子」的不变量，该不该管那个新包")

        let files = productionSwiftFiles()
        // 反恒真①：枚举器坏掉（路径推错、`enumerator` 返回 nil）→ 0 个文件 → 下面每一条
        // 「每一处写盘都原子」都会因为**一处写盘都没有**而恒真。先钉住「我真的看到了源码」。
        expect(
            files.count >= 50,
            "只枚举到 \(files.count) 个生产源文件（今天 57 个）—— 枚举器坏了。"
                + "0 个文件 = 0 处写盘 = 下面每一条断言恒真绿，而它们自称守着用户配置的唯一副本")

        var totalWriteSites = 0
        for path in files {
            guard let scanned = scanProduction(path) else {
                expect(false, "读不到 \(path) —— 这条绊线指望能读到每一个生产源文件")
                continue
            }
            // 扫描器自认读不懂的构造 = `code` 不再可信。而这条绊线的失效模式恰恰是**少看见一段
            // 代码只会更绿**：一次藏在被误判成字符串的区间里的非原子写会永久隐身。
            expect(
                scanned.unmodeledConstructs.isEmpty,
                "\(path) 里出现了 `strippingComments` 不建模的词法构造：\(scanned.unmodeledConstructs)"
                    + " —— 它剥出来的「代码」从此不可信，而一次消失在里面的非原子写只会让这条"
                    + "绊线**更绿**。要么把这个构造挪走，要么先教 `strippingComments` 认识它")

            for arguments in writeCallArguments(in: scanned.code) {
                totalWriteSites += 1
                // 不经 `to:` 的写（`FileHandle.write(_:)`、`fileHandle.write(contentsOf:)`）——
                // 一次 `FileHandle(forWritingTo: configFile)` 就能绕开这整条不变量。不静默跳过。
                guard isContentReplacingWrite(arguments) else {
                    expect(
                        false,
                        "\(path) 有一处这条绊线读不懂的写调用：`.write(\(arguments))` —— 它没有 `to:`"
                            + "标签，所以不是「把一个 URL 的内容整个换掉」，`options:` / `atomically:`"
                            + "对它没有意义。但它**也不是**能放过去的东西：一次"
                            + "`FileHandle(forWritingTo: configFile)` 就从这条不变量底下整个走过去了。"
                            + "要么改用 `Data.write(to:options:.atomic)`，要么在 `AtomicWriteSuite` 里"
                            + "就地为它写一条断言 —— 别让它无声无息")
                    continue
                }
                expect(
                    isAtomicWrite(arguments),
                    "\(path) 有一处**非原子**的内容替换式写盘：`.write(\(arguments))`。"
                        + "非原子写被打断（kill / 掉电）会在磁盘上留下半截文件，而它的每一个读者"
                        + "——包括那些只用 `fileExists` 判存在的——都会把它当成一份完整的文件。"
                        + "改成 `options: .atomic`（`Data`）或 `atomically: true`（`String`）："
                        + "同目录临时文件 + `rename(2)`，终态只有「没有」和「完整」两种。"
                        + "真要豁免，请在 `AtomicWriteSuite` 里就地写清理由——别悄悄放行")
            }
        }

        // 反恒真②：needle 打错一个字母、或 `writeCallArguments` 被改坏 → 一处也抓不到 →
        // 上面那个 for 一次都不进 → 整条 suite 恒真绿。`>= 9` 是今天的真实数（ConfigMutation 1、
        // Play 1、Log 2、SettingsInstaller 2、ManifestBinding 1、AudioImport 2）；用 `>=` 而不是
        // `==`，是因为**新增一处原子写是好事**，不该逼人来改这个数字（那种数字最后总会被人调大
        // 了事，而不是去看为什么）。
        expect(
            totalWriteSites >= 9,
            "全仓只抓到 \(totalWriteSites) 处 `.write(to:` 调用（今天真实是 9 处）—— 检测器瞎了。"
                + "抓不到调用点的检测器，会让上面每一条「必须原子」变成一条恒真断言")
    }

    suite("写盘绊线的正向对照：检测器必须真的抓得到非原子写，也必须不误伤四种合法写法") {
        // 这一条是上面那条唯一的兜底。掏空 `isAtomicWrite` 成 `return true`、或把 needle 打错，
        // 上面那条不会红（它只会一处写盘都找不到，然后被 `>= 9` 那条逮住——所以两条都得有）。
        // 这里喂**合成源码**给检测器、正向断言它的输出：读的不是它自己的输出，是它自己的输入。

        let nonAtomic = "try originalData.write(to: backupFile)"
        let sites = writeCallArguments(in: nonAtomic)
        expect(
            sites.count == 1,
            "检测器没抓到这次写调用（抓到 \(sites.count) 处）—— 它抓不到的每一处，都是一条恒真断言")
        expect(
            sites.first.map { !isAtomicWrite($0) } ?? false,
            "一次没有 `options:` 的 `Data.write(to:)` **必须**被判为非原子。判它原子 = 这条绊线"
                + "对着它要杀的那一行（`SettingsInstaller` 的备份写，修之前逐字长这样）一声不吭")

        // 四种合法写法，一处都不许误判成非原子——误判会换来假红，而假红最后总是被删掉的那一个。
        let legal = [
            "try data.write(to: configFile, options: .atomic)",
            "try Data(wholeLines).write(to: logFile, options: .atomic)",
            "try data.write(to: f, options: [.atomic, .withoutOverwriting])",
            "try? String(stamp).write(to: stateFile, atomically: true, encoding: .utf8)",
        ]
        for source in legal {
            let arguments = writeCallArguments(in: source)
            expect(
                arguments.count == 1 && arguments.first.map(isAtomicWrite) == true,
                "这是一次**合法的原子写**，却被判成非原子：`\(source)` —— 假红会被人删掉，"
                    + "而删掉之后，真正的非原子写也就没人守了")
        }

        // 跨行调用：今天全仓 9 处写盘都是单行，所以**没有任何真实源码在钉这一条**。而按行截断的
        // 检测器在这里会只看到 `to: settingsFile,`、看不到下一行的 `options: .atomic`，把一次合法
        // 原子写判成非原子。配平括号才看得全。
        let multiline = """
            try data.write(
                to: settingsFile,
                options: .atomic)
            """
        let multilineArguments = writeCallArguments(in: multiline)
        expect(
            multilineArguments.count == 1
                && multilineArguments.first.map(isAtomicWrite) == true,
            "一次**跨行**的原子写没被认出来 —— 检测器在按行截断，而不是按配平括号取实参。"
                + "今天没有跨行的写调用，所以除了这一条，没有任何东西在钉它")

        // `atomically: false` 是 `String.write` 的合法写法，也是一次真的非原子写。
        let atomicallyFalse = "try s.write(to: f, atomically: false, encoding: .utf8)"
        expect(
            writeCallArguments(in: atomicallyFalse).first.map { !isAtomicWrite($0) } ?? false,
            "`atomically: false` 是一次货真价实的非原子写，必须红")

        // `options:` 的值读不出来时必须 fail closed。
        let opaqueOptions = "try data.write(to: f, options: writeOptions)"
        expect(
            writeCallArguments(in: opaqueOptions).first.map { !isAtomicWrite($0) } ?? false,
            "`options:` 是个变量时，这里读不出它含不含 `.atomic` —— 必须判非原子（fail closed）。"
                + "判它原子 = 任何人都能用一个变量把非原子写藏过这条绊线")
    }

    suite("写盘绊线的后门锁：只有 Log（日志追加）与 FileLock（锁文件）可以持有写意图的裸 fd") {
        // 上面那条不变量只认 `.write(to:` 这一个出口。一个 `open(O_WRONLY)` + `write(2)` 写
        // config.json 的新路径，会从它眼皮底下整个走过去。所以这里正面钉住「谁可以裸写」。
        var holders: Set<String> = []
        for path in productionSwiftFiles() {
            guard let code = scanProduction(path)?.code else { continue }
            if writeIntentOpenFlags.contains(where: { code.contains($0) }) {
                holders.insert(path)
            }
        }
        expect(
            holders == rawWriteFileDescriptorHolders,
            "持有写意图裸 fd（\(writeIntentOpenFlags.joined(separator: " / "))）的生产文件变了。"
                + "期望 \(rawWriteFileDescriptorHolders.sorted())，实际 \(holders.sorted())。"
                + "多出来的那个文件在用 `open(2)` + `write(2)` 写盘 —— 那条路径**绕过**了"
                + "「每一处写盘都必须原子」那条绊线（它只认 `.write(to:`）。要么改用"
                + "`Data.write(to:options:.atomic)`，要么在这里加进名单并写清为什么非裸写不可"
                + "（Log 是因为追加不是替换，FileLock 是因为 `flock(2)` 要一个 fd）")
        // 反恒真：`writeIntentOpenFlags` 被清空 / `code` 全是空串 → `holders` 为空集，而空集
        // 与一个非空的期望集不相等，上面那条会红。但如果有人把期望集也改空，两个空集就相等了——
        // 所以再正面钉一次「名单本身非空」。
        expect(
            !rawWriteFileDescriptorHolders.isEmpty && holders.count >= 2,
            "裸写名单空了 —— 两个空集相等，上面那条断言于是恒真。Log 与 FileLock 都真的在裸写，"
                + "它们必须被这条绊线看见")
    }
}
