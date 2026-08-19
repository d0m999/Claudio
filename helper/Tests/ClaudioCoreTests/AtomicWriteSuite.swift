import ClaudioCore
import Foundation

// MARK: - 不变量：字节落进用户的文件，只能通过一条**原子**路径。而认不出的写法必须**红**，不是隐形。
//
// ## 它为什么存在
//
// `SettingsInstaller.backupOriginalIfNeeded` 曾经是一处非原子写（`try originalData.write(to: backupFile)`，
// 没有 `options:`）——而它守的恰恰是全仓最重的那个承诺：用户 pre-claudio `settings.json` 的**唯一一份副本**。
// `.claudio.bak` 按设计**永不刷新**（`fileExists` 闸门 = 「一次性备份」），那道闸门认得的只有「有没有这个
// 文件」，认不出「这是一份**残缺**的备份」，而它**没有任何程序化读者**（卸载刻意不从它还原）——它整个存在
// 的意义就是在用户需要的那一天替他把东西还回去。一次被打断的非原子写留下的半截文件会**永久冒充**它。
//
// ## ⚠️ 上一版这条绊线是**假的**，而它假在极性上（`/codex review 3af8d5f`，两个模型独立命中）
//
// 上一版的形状是：`needle = ".write("` → 找到调用点 → 查它原子不原子。三条 suite，自称「零豁免」。
// 它的失效模式不是「少查了一个调用点」，是**整类写盘从它眼皮底下走过去，而它全绿**。实测（把 PoC 写进
// `helper/Sources/`、真跑 `swift run claudio-tests`）：
//
// - 把 `backupOriginalIfNeeded` 的写换成 `FileManager.createFile(atPath:contents:)`（truncate + write，
//   货真价实的非原子内容替换）→ **✓ all 1195 checks passed**。**这条绊线存在的全部理由，原样复活，绊线沉默。**
// - 新建一个文件，里面 `fopen(path, "w") + fputs` / `creat(2) + write(2)` → **✓ 全绿**。而第三条 suite
//   在失败消息里自称堵住了「用 `open(2)` 绕过 `.write(to:` 去写 config.json」这条后门 —— 它锁的其实只是
//   `O_WRONLY` / `O_RDWR` / `O_APPEND` **三个词**，不是后门。
// - `try d.write (to: f)`（`write` 与 `(` 之间一个空格，合法 Swift，实测可编译）→ needle 不匹配 → 隐身。
// - `packages/shared/Sources/…` 下一句 `try data.write(to: url)` → **✓ 全绿**：树发现只看仓库根的
//   **直接**子目录，而「发现到的 == 期望的」那条断言**连红都不会红**（两边都还是那两棵老树）。
//
// 四条都是同一个病，而这个仓库为它交过学费：**一张「我认得什么」的清单，就是一张白名单，而白名单永远
// 不完整**（`SourceScannerSuite` 文件头记着这条教训的两次；`unmodeledConstructs` 的文档记着第三次）。
// 上一版把这句话写进了自己的文件头，然后在**检测器的 needle** 上原样再犯一次。
//
// ## 修法：把极性翻过来
//
// 不再问「我认得的那种写法，原子吗」。改成问：
//
//   **「凡是能把字节送进一个文件、或把一个文件放到一条路径上的调用，此刻出现在哪些生产文件里？
//     这份名单必须**逐字**等于台账。」**
//
// 于是**在词表覆盖到的那部分写盘表面上**，失效模式反过来了：一处 `createFile` / `fopen` /
// `OutputStream` / `NSKeyedArchiver` / 一个 `Process()` 起的子进程 —— 上一版 needle 完全看不见、
// 因而**全绿**的那些 —— 现在会让 surface 多出一个 token、台账对不上、**当场红**。这是与上一版的
// 实质区别：探测的写盘出口从 1 个（`.write(`）涨到了几十个，而它们的失效方向是**红，不是绿**。
//
// ⚠️ 但**别把这句话读成绝对的**（`/codex review 3af8d5f` 红队实测命中，措辞比覆盖范围大的第十六次）：
// 词表本身是有限的，一个**词表外**的写盘 API 仍然全绿。`copyfile(2)`、swift-system 的
// `FileDescriptor.writeAll`、`CGImageDestination…` 都被实测证明能带着一次真实的非原子写溜过去
// （前两个已补进词表，第三类没有 —— 图像写入不是这个 app 的写盘表面）。翻过来的是**同一处写盘换
// 一种已建模的写法**（换行 / 空格 / `createFile` 换 `.write(`）——那些现在都红；没翻过来、也翻不动的
// 是**一个我压根没听说过的写盘 API**。真要闭合这最后一条缝，只能上 SwiftSyntax 把「所有函数调用名」
// 整个抽出来比对（TODOS 里那条 L）。所以正确的读法是：**认不出的写法 ⇒ 红；认不出的 API ⇒ 仍绿
// （但比上一版那张 1 项 needle 的缝窄了几十倍）。**
//
// 四条 suite：
//
// - **① 围栏（极性翻转）** —— 「哪些生产文件碰了写盘表面」== 台账，逐字。外加树/包的发现是**递归**的
//   （嵌套 SPM 包不再整棵失明），以及「发现到的树 == 期望的树」「发现到的 Package.swift == 期望的」。
// - **② 围栏之内** —— 每一处**内容替换式**写盘都必须原子，而且**每个文件几处**是钉死的（计数绑调用点：
//   `/review e7c38ea` 的教训 —— 一个全仓总数的 `>= 9` 挡不住「某一处单独隐身、别处补上一处」）。
// - **③ 正向对照** —— 喂合成源码，**走整条真实管线**（`strippingComments` → 清空字符串字面量 → 取实参
//   → 判形状）。上一版的正向对照直接把裸字符串喂给最后两级，`strippingComments` 与字符串清空这两级
//   **一条正向断言都没有**。
// - **④ 裸 fd 的写意图** —— 谁可以持有 `O_WRONLY`/`O_RDWR`/`O_APPEND` 的 fd。它现在是 ① 的**子规则**
//   （`open(` 本身已经被 ① 围住了），只是把「写意图」这一层单独钉一次。
//
// ## ⚠️ 它**仍然**不兜什么（措辞不得比覆盖范围大 —— 这个仓库栽在这上面十五次）
//
// - **围栏的词汇表本身**（`byteWriting*` / `pathPublishing*` / `subprocess*`）还是一张枚举出来的清单。
//   区别在于**它漏一个词的代价是假绿，而它多一个词的代价只是台账里多一行**——所以它是**故意过宽**的
//   （`Process(` / `mmap(` / `rename(` 都在里面，哪怕它们大多数时候无害）。宁可让作者多写一行理由，
//   也不要让一次写盘隐身。真要再狠一点，只能上 SwiftSyntax —— 那是另一条 TODO，不由这一刀扛。
// - **原子性 ≠ 掉电持久性**。`.atomic` = 同目录临时文件 + `rename(2)`。`rename` 对**目录项**是原子的，
//   所以一次 `SIGKILL` 之后终态只有「没有」和「完整」两种。但全仓**没有任何 `fsync` / `F_FULLFSYNC`**，
//   而 POSIX 不保证掉电时数据块先于目录项落盘 —— 掉电这一半，这条不变量**给不了**。别再在失败消息里
//   声称它（上一版的失败消息与那条 commit 的正文都声称了，第十五次）。
// - **子进程写的东西**。`Process(` 在词汇表里，所以它**出现**会被围栏逮住，但它**写了什么**这条绊线
//   看不见（`afplay` 不写盘、`claude --version` 不写盘 —— 台账里为这两处子进程写着理由）。

// MARK: - 仓库与源码树

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

/// 仓库里今天真实存在的 SPM 包清单（按 `Package.swift` 数）。
///
/// 为什么单钉这一条：一个 target 可以在 `Package.swift` 里用自定义 `path:` 把源码放在**任何**目录名下
/// （`.target(name: "X", path: "Src")`）—— 那样一棵树叫不叫 `Sources` 都不一定，下面那个「找名叫
/// Sources 的目录」的发现算法**认不出它**。包的数量变了 = 必须有人回来看一眼这条不变量该不该管它。
private let expectedPackageManifests: Set<String> = ["helper/Package.swift", "gui/Package.swift"]

/// 仓库里**实际**有哪些生产源码树 —— 从磁盘**递归**发现，不从上面那个常量读。
///
/// ⚠️ 两版都栽在这一层，形状一模一样：
///
/// - 第一版把 `expectedProductionSourceTrees` **当扫描名单**用 → 加第三个 SPM 包，那棵树永久隐身。
/// - 第二版改成「发现」，但只 `contentsOfDirectory` 仓库根**一层**，再看有没有名叫 `Sources` 的子目录。
///   于是 `packages/shared/Sources/…`（`.package(path: "packages/shared")`，最常见的多包布局之一）
///   **依然**整棵失明 —— 而且更坏：`trees == expected` 那条本该逮住它的断言**连红都不会红**，因为
///   发现到的集合原样没变。实测：那棵树下一句 `try data.write(to: url)` → ✓ all 1195 checks passed。
///
/// 现在是**递归**的：仓库里任何一个名叫 `Sources` 的目录（隐藏目录除外 —— `.build` 里是依赖的源码，
/// 不是我们的生产码）。加一个包，无论嵌得多深，那棵树都会被**发现**并被扫；而「发现到的 == 期望的」
/// 当场红，逼作者回来确认一次。名单只能用来**发现变化**，永远不能用来**决定扫什么**。
private func discoveredProductionSourceTrees() -> Set<String> {
    let root = repoRoot()
    guard
        let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
    else { return [] }
    var trees: Set<String> = []
    for case let url as URL in walker {
        guard
            let isDirectory = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
            isDirectory
        else { continue }
        guard url.lastPathComponent == "Sources" else { continue }
        trees.insert(relativePath(of: url, under: root))
        // `Sources` 之下不会再有第二棵 `Sources` —— 不下钻，也省得把整棵树走两遍。
        walker.skipDescendants()
    }
    return trees
}

/// 仓库里**实际**有哪些 `Package.swift`（同样递归、同样跳隐藏目录）。
private func discoveredPackageManifests() -> Set<String> {
    let root = repoRoot()
    guard
        let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { return [] }
    var manifests: Set<String> = []
    for case let url as URL in walker where url.lastPathComponent == "Package.swift" {
        manifests.insert(relativePath(of: url, under: root))
    }
    return manifests
}

private func relativePath(of url: URL, under root: URL) -> String {
    let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard url.path.hasPrefix(rootPath) else { return url.path }
    return String(url.path.dropFirst(rootPath.count))
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
            found.append(relativePath(of: url, under: root))
        }
    }
    return found.sorted()
}

/// 一个生产源文件**剥掉注释、且清空字符串字面量内容**之后的样子。
///
/// 两级都必须有，各自堵一个洞：
///
/// - **剥注释**：本文件自己的 doc comment 里就白纸黑字写着 `try originalData.write(to: backupFile)`
///   （在讲那次翻车）。不剥注释，检测器会把**谈论代码的散文**当成调用点。
/// - **清空字符串内容**（`codeWithoutStringLiterals`，与剥注释**同一趟**扫出来，不是第二台扫描器）：
///   ① 按配平括号取实参的扫描会被**字符串里的括号**带偏 —— `"pack (1.json"` 里那个 `(` 让括号永不配平，
///   上一版会把这次**合法的原子写**判成假红，并且 `break` 掉这个文件**剩下的每一处**写调用（假红有人
///   喊，被 break 吞掉的那些没有人看得见）；② 一句写着 `.write(to:` 的**错误消息**会被当成调用点。
///
/// 剥注释那活儿由 `TestSupport.strippingComments` 干，它自己的行为由 `SourceScannerSuite` 喂合成输入
/// 钉死；这里只管**用**它，并在它自认读不懂的时候当场红。
@MainActor
private func scanProduction(_ relativePath: String) -> StrippedSwiftSource? {
    guard let data = try? Data(contentsOf: repoRoot().appendingPathComponent(relativePath)),
        let text = String(data: data, encoding: .utf8)
    else { return nil }
    return strippingComments(text)
}

// MARK: - 写盘表面的词汇表（**故意过宽**）

/// 「能把字节送进一个文件」的成员调用。
///
/// `writeAll` 是 swift-system 的 `FileDescriptor.writeAll` —— `/codex review 3af8d5f` 红队实测：
/// `let fd = try FileDescriptor.open(p, .writeOnly, options: [.create, .truncate]); try fd.writeAll(b)`
/// 是一次完整的、非原子的内容替换，而它一个 `.write(` 都没有、flag 也不是字面 `O_*`，上一版三条 suite
/// 全绿。（`FileDescriptor.open` 是 `.open(` 成员形，认不了 —— `NSWorkspace.shared.open(` 也是 `.open(`——
/// 但 `.writeAll(` 够独特，它一出现就说明有人在拿裸 fd 写，台账里必须有它。）
private let byteWritingMembers = [
    "write", "writeAll", "createFile", "replaceItemAt", "writePropertyList", "writeToFile",
    "truncateFile", "archiveRootObject",
]
/// 「能把字节送进一个文件」的自由函数 —— 与成员调用**分开**认：`NSWorkspace.shared.open(` 不是
/// POSIX `open(2)`，把它们混为一谈只会换来一条没人受得了的假红，而假红最后总是被删掉的那一个。
private let byteWritingFunctions = [
    "open", "creat", "fopen", "fdopen", "freopen", "write", "pwrite", "writev",
    "fwrite", "fputs", "fputc", "fprintf", "truncate", "ftruncate", "mkstemp", "mmap",
    "mkdir", "fchmod",
    // `copyfile(2)` —— `/codex review 3af8d5f` 红队实测：`copyfile(src, dst, nil, COPYFILE_DATA)` 把 src
    // 的字节 truncate + 就地写进 dst 的同一个 inode（无 temp+rename），被 kill 会在最终路径留半截文件，
    // 而它既没有 `.write(` 也没有 O_ token，上一版全绿。它是纯 Foundation 自由函数，写盘表面的一员。
    "copyfile",
    // 类型构造器也是自由函数形状（前面不是 `.`）。三者都能把字节送进一个文件，而且**都不经过**
    // `.write(to:)` —— `OutputStream(url:append:)` 尤其是一条完整的、非原子的写盘管道。
    "OutputStream", "FileHandle", "NSKeyedArchiver",
]
/// 「能把一个文件放到一条路径上」的调用 —— **半截的它就是半截的文件**。`Setup.copySelfToFixedLocation`
/// 那处非原子写（`removeItem` + `copyItem` 直写最终路径）逐字活在这一类里，而上一版把整类 `copyItem` /
/// `moveItem` 豁免了，理由是「它们的原子性纪律是另一条（T17e 的 staging + rename）」—— 那句话对那个
/// 调用点是**字面意义上的假话**。豁免的理由必须对**每一个**被豁免的调用点成立，否则它只是一句托词。
private let pathPublishingMembers = [
    "copyItem", "moveItem", "linkItem", "createSymbolicLink", "replaceItem",
]
private let pathPublishingFunctions = [
    "rename", "renameatx_np", "link", "symlink", "unlink",
]
/// 一个子进程能写任何东西。它**出现**会被围栏逮住；它**写了什么**这条绊线看不见（台账里写理由）。
private let subprocessMembers: [String] = []
private let subprocessFunctions = ["Process", "posix_spawn", "posix_spawnp", "execve", "system"]

/// 这个文件此刻碰到了写盘表面的哪些 token（成员调用记成 `.name(`，自由函数记成 `name(`）。
private func diskWriteSurfaceTokens(in code: String) -> Set<String> {
    var tokens: Set<String> = []
    for name in byteWritingMembers + pathPublishingMembers + subprocessMembers
    where !callOpenParens(of: name, member: true, in: code).isEmpty {
        tokens.insert(".\(name)(")
    }
    for name in byteWritingFunctions + pathPublishingFunctions + subprocessFunctions
    where !callOpenParens(of: name, member: false, in: code).isEmpty {
        tokens.insert("\(name)(")
    }
    // Swift 通常把 POSIX 函数写成 `Darwin.rename(...)`。语法上它前面有 `.`，
    // 所以上面刻意排除成员调用的自由函数扫描会漏掉它。只补已知系统模块，
    // 不把 `NSWorkspace.shared.open(...)` 之类普通成员误报为 POSIX 写盘。
    for name in byteWritingFunctions + pathPublishingFunctions
    where hasNamespaceQualifiedCall(of: name, namespace: "Darwin", in: code) {
        tokens.insert("\(name)(")
    }
    return tokens
}

private func hasNamespaceQualifiedCall(
    of name: String,
    namespace: String,
    in source: String
) -> Bool {
    func previousNonWhitespace(before boundary: String.Index) -> String.Index? {
        guard boundary > source.startIndex else { return nil }
        var probe = source.index(before: boundary)
        while source[probe].isWhitespace {
            guard probe > source.startIndex else { return nil }
            probe = source.index(before: probe)
        }
        return probe
    }

    for openParen in callOpenParens(of: name, member: true, in: source) {
        guard let nameEnd = previousNonWhitespace(before: openParen),
            let nameStart = source.index(
                nameEnd, offsetBy: -(name.count - 1), limitedBy: source.startIndex),
            source[nameStart...nameEnd] == name,
            let dot = previousNonWhitespace(before: nameStart),
            source[dot] == ".",
            let namespaceEnd = previousNonWhitespace(before: dot),
            let namespaceStart = source.index(
                namespaceEnd, offsetBy: -(namespace.count - 1), limitedBy: source.startIndex),
            source[namespaceStart...namespaceEnd] == namespace
        else { continue }

        if namespaceStart > source.startIndex {
            let before = source[source.index(before: namespaceStart)]
            if before.isLetter || before.isNumber || before == "_" || before == "." { continue }
        }
        return true
    }
    return false
}

/// `source` 里每一处「调用 `name(`」的**左括号下标**。
///
/// - `member: true` → 只认成员调用 `.name(`。`.` 与 `name`、`name` 与 `(` 之间**允许空白与换行** ——
///   `try d.write (to: f)` 是合法 Swift（实测可编译），而上一版那个字面 needle `.write(` 认不出它，
///   于是那次非原子写从绊线眼皮底下整个走过去。
/// - `member: false` → 只认**自由函数** `name(`：`name` 前面那个非空白字符既不能是标识符字符
///   （`overwrite(` 里的 `write(` 不算），也不能是 `.`（`NSWorkspace.shared.open(` 不是 `open(2)`）。
///
/// 输入必须是**清空过字符串字面量**的代码（见 `codeWithoutStringLiterals`），否则一句散文就是一个调用点。
private func callOpenParens(of name: String, member: Bool, in source: String) -> [String.Index] {
    func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
    var results: [String.Index] = []
    var cursor = source.startIndex
    while let hit = source.range(of: name, range: cursor..<source.endIndex) {
        cursor = hit.upperBound
        if hit.lowerBound > source.startIndex {
            // 左边界：`name` 不能是某个更长标识符的尾巴（`overwrite(` 里的 `write(`）。
            let before = source[source.index(before: hit.lowerBound)]
            if isIdentifierCharacter(before) { continue }
            var probe = source.index(before: hit.lowerBound)
            while probe > source.startIndex, source[probe].isWhitespace {
                probe = source.index(before: probe)
            }
            if member {
                // 成员调用：`name` 前面（跳过空白）必须是 `.`。
                guard source[probe] == "." else { continue }
            } else {
                // 自由函数：前面是 `.` 说明它是某个东西的成员，不是我们要的那个自由函数。
                if source[probe] == "." { continue }
            }
        } else if member {
            // 文件开头就是 `name` —— 不可能是成员调用。
            continue
        }
        // 右边界：`name` 之后（跳过空白）必须是 `(`，而且 `name` 不能是更长标识符的头
        // （`writeOptions` 里的 `write` 后面跟的是 `O`，不是 `(`）。
        var probe = hit.upperBound
        while probe < source.endIndex, source[probe].isWhitespace {
            probe = source.index(after: probe)
        }
        guard probe < source.endIndex, source[probe] == "(" else { continue }
        results.append(probe)
    }
    return results
}

// MARK: - 围栏之内：内容替换式写盘的形状判定

/// `source` 里每一处 `.write(…)` 调用的**实参文本**（左括号后到配平右括号前）。
///
/// 按**配平括号**取，不按行 —— 一次跨行的写调用按行取只看得到半截实参，看不到下一行的
/// `options: .atomic`，会把一次合法的原子写判成非原子 → 假红 → 有人来「修」检测器 → 修松了 → 假绿。
///
/// 输入是**清空过字符串字面量**的代码，所以数括号是安全的：字符串里的 `(` 到不了这里。
private func writeCallArguments(in code: String) -> [String] {
    var calls: [String] = []
    for openParen in callOpenParens(of: "write", member: true, in: code) {
        var depth = 1
        var index = code.index(after: openParen)
        while index < code.endIndex, depth > 0 {
            switch code[index] {
            case "(": depth += 1
            case ")": depth -= 1
            default: break
            }
            if depth == 0 { break }
            index = code.index(after: index)
        }
        // 括号没配平 = 源码被截断或读串了。回一个空实参让调用方当场红（空实参不含 `options:`，
        // 判定为非原子）—— 但**不 break**：上一版在这里 `break` 掉了这个文件剩下的每一处写调用，
        // 那是把「吵」换成了「静默」，方向正好反了。
        guard depth == 0 else {
            calls.append("")
            continue
        }
        calls.append(String(code[code.index(after: openParen)..<index]))
    }
    return calls
}

/// `arguments` 按**顶层逗号**（括号 / 方括号 / 花括号深度为 0 的那些）切开、逐段 trim。
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

/// 这次 `.write(…)` 是一次**内容替换式**写盘吗（第一个顶层实参指向一条**路径**）？
///
/// 两个标签，不是一个：`Data.write(to:)`（URL）与 `String.write(toFile:atomically:encoding:)`（路径串）
/// 都是把一条路径的内容**整个换掉**。上一版只认 `to:`，于是一次**合法的原子** `write(toFile:atomically:true)`
/// 会被判成「读不懂的写调用」当场假红 —— 而失败消息给的理由（「它没有 to: 标签，所以不是把一个 URL 的
/// 内容整个换掉」）对它是错的。假红会被人删掉，而删掉之后真正的非原子写也就没人守了。
///
/// 不带路径标签的 `.write(`（`FileHandle.write(_:)` / `.write(contentsOf:)`）**不是**内容替换 ——
/// 但它**也不是**可以放过去的东西：一次 `FileHandle(forWritingTo: configFile)` 就能绕开这条不变量。
/// 所以不静默跳过，交给调用方当场红（而 `FileHandle(` 本身已经被围栏围住了）。
private func isContentReplacingWrite(_ arguments: String) -> Bool {
    guard let first = topLevelArguments(arguments).first else { return false }
    return first.hasPrefix("to:") || first.hasPrefix("toFile:")
}

/// 这次内容替换式写盘是原子的吗？**默认 fail closed。**
///
/// - `Data.write(to:options:)` → `options` 的**值**必须是一个**字面**含 `.atomic` 的选项字面量。
/// - `String.write(to:atomically:encoding:)` / `write(toFile:atomically:encoding:)` → `atomically:`
///   必须**字面**是 `true`。
private func isAtomicWrite(_ arguments: String) -> Bool {
    for argument in topLevelArguments(arguments) {
        if argument.hasPrefix("options:") {
            return optionsValueIsAtomic(String(argument.dropFirst("options:".count)))
        }
        if argument.hasPrefix("atomically:") {
            let value = argument.dropFirst("atomically:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value == "true"
        }
    }
    return false
}

/// `options:` 的**值**是不是一个字面含 `.atomic` 的选项字面量。只认两种形状，其余一律非原子：
///
/// - `.atomic`
/// - `[.a, .b, …]`，每一项都是 `.名字`，且其中**恰好有一项**是 `.atomic`
///
/// ⚠️ 上一版是 `argument.contains(".atomic")` —— 而它上面 50 行的文档正好在骂这个病
/// （「子串断言没有词边界」，`/review e7c38ea` 的 P2）。两条实测的假绿：
///
/// - `options: fast ? [] : .atomic` —— 一次在 `fast` 时**货真价实的非原子写**，判成原子（✓ 全绿）；
/// - `options: .atomicUnlessSandboxed` —— 无词边界，判成原子。
///
/// 而文档同时声称「`options:` 的值是个变量 → 也判非原子（fail closed）」—— 那句话只对
/// `options: writeOptions` 这一种**不含 `.atomic` 子串**的形状成立，而正向对照恰好只喂了这一种。
/// 现在它是真的了：**读不出确切形状 ⇒ 非原子**。宁可让一次「其实是原子的」写法当场红、逼作者写清楚，
/// 也不要让一次真的非原子写溜过去 —— 假红有人喊，假绿没人看得见。
private func optionsValueIsAtomic(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == ".atomic" { return true }
    guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return false }
    let elements = topLevelArguments(String(trimmed.dropFirst().dropLast()))
    guard !elements.isEmpty, elements.allSatisfy(isSimpleOptionMember) else { return false }
    return elements.contains(".atomic")
}

private func isSimpleOptionMember(_ element: String) -> Bool {
    guard element.hasPrefix(".") else { return false }
    let name = element.dropFirst()
    return !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
}

// MARK: - 台账

/// **写盘表面台账** —— 「哪个生产文件碰了写盘表面的哪些 token」。这是这条绊线的**围栏**。
///
/// 它与上一版那张 `rawWriteFileDescriptorHolders` 的区别，是这条绊线全部的意义所在：
/// 上一版的清单说的是「**我去找**这三个词」（漏一个词 = 那类写盘永久隐身 = 假绿）；
/// 这一张说的是「此刻**实际出现**的写盘调用，必须逐字等于这些」（多一个我没建模的 API = 台账对不上
/// = **当场红**）。前者漏了会绿，后者漏了会红。
///
/// 加一处写盘（哪怕是原子的、正确的）→ 这里当场红 → 你必须回来写一行理由。这是**故意**的成本：
/// 一个全仓总数的 `>= N` 挡不住「某一处单独隐身、别处补上一处」（`/review e7c38ea` 的教训，
/// 而上一版把它原样复发在了 `totalWriteSites >= 9` 上）。
private let diskWriteSurfaceLedger: [String: Set<String>] = [
    // —— helper ——
    // `config.json` 的唯一写者。一次原子写。
    "helper/Sources/ClaudioCore/ConfigMutation.swift": [".write("],
    // 锁文件。`flock(2)` 要一个 fd，而拿到 fd 的唯一办法就是 `open(2)`。它不写内容。
    "helper/Sources/ClaudioCore/FileLock.swift": ["open("],
    // 日志。轮转是两次原子写（截断 / 重写保留的尾部）；追加是 `O_APPEND` 上的单次 `write(2)` ——
    // **追加不是替换**，改成 `.atomic` 会用一行盖掉整份日志。它有自己的原子性纪律，不归 ② 管，
    // 所以 `.write(` 之外的那两个 token（`open(` / `write(`）在这里是**有意**的。
    "helper/Sources/ClaudioCore/Log.swift": [".write(", "open(", "write("],
    // `play.state` 的防抖戳（一次原子写）+ `afplay` 子进程。子进程不写盘（它只出声）。
    "helper/Sources/ClaudioCore/Play.swift": [".write(", "Process("],
    // 有界只读：`open(O_RDONLY | O_NOFOLLOW | O_NONBLOCK)`。它是**读者**，不是写者 ——
    // `O_RDONLY` 刻意不在 ④ 的写意图 flag 里。
    "helper/Sources/ClaudioCore/SafeFileRead.swift": ["open("],
    // Claude/Codex 配置事务：0600 起步的私有 staging fd 完整写入并 fsync；一次性备份用
    // RENAME_EXCL 发布；卷不支持该 flag 时，同目录 link(2) 仍以 EEXIST 保证不覆盖。
    // 最终配置用同目录 rename 替换，且两者都保留原文件权限。
    "helper/Sources/ClaudioCore/ConfigFileTransaction.swift": [
        "fchmod(", "link(", "mkstemp(", "rename(", "renameatx_np(", "unlink(", "write(",
    ],
    // Claudio 自有目录逐层 mkdir；最终节点以 O_NOFOLLOW|O_DIRECTORY 打开并 fchmod 0700。
    "helper/Sources/ClaudioCore/PrivateDirectory.swift": ["fchmod(", "mkdir(", "open("],
    // Bootstrap report/journal：0600 staging 完整写入并 fsync，随后同目录 rename 原子发布；
    // unlink 仅删除精确 UUID 报告、已调和 journal 或失败 staging。
    "helper/Sources/ClaudioCore/BootstrapReport.swift": [
        "fchmod(", "mkstemp(", "rename(", "unlink(", "write(",
    ],
    // 已知旧版 codex-notify：私有同目录 staging 写入后恢复执行权限，再以 rename(2) 原子替换。
    // 写入前在同一宿主锁内重读并比较预期内容，未知或并发修改版本 fail closed。
    "helper/Sources/ClaudioCore/ConcreteHostIntegrationAdapters.swift": [".write(", "rename("],
    // 回执与 active installation 标记从 mkstemp(3) 创建瞬间就是 0600；完整 write(2) + fsync
    // 后才以 rename(2) 原子替换稳定路径。unlink(2) 清 staging 及精确匹配的断开代次标记。
    "helper/Sources/ClaudioCore/HostHookReceipt.swift": [
        "fchmod(", "mkstemp(", "rename(", "unlink(", "write(",
    ],
    // 二进制与内置包的复制。**两处都是 staging + 同卷 rename**（`copyItem` 进暂存 → `moveItem` /
    // `replaceItemAt` 发布）。pristine minimal-chime 升级更严格：`renameatx_np(RENAME_SWAP)`
    // 原子交换 staging 与目标，再比较被隔离出来的原目录身份及完整字节；不匹配就原子交换回去。
    // `copySelfToFixedLocation` 曾经是 `removeItem` + `copyItem` 直写最终路径 —— 那是全仓真正的
    // 第二处非原子写，而当时的豁免理由（「copyItem 的纪律是 staging+rename」）对它是假话。
    // 现在它是真的了。
    "helper/Sources/ClaudioCore/Setup.swift": [
        ".copyItem(", ".moveItem(", ".replaceItemAt(", "renameatx_np(",
    ],
    // `/usr/bin/env claude --version` 子进程（探已装的 `claude` CLI 版本，`:319`/`:330`）。
    // 它读版本、不写盘 —— 但它跑的是**别人的**二进制，写没写盘不归这条不变量管（子进程那条免责在
    // 文件头写着）。（macOS 版本走 `ProcessInfo.processInfo.operatingSystemVersion`，无子进程，`:82`。）
    "helper/Sources/ClaudioCore/VersionCompatibility.swift": ["Process("],

    // —— gui ——
    // 导入音频：探测文件走一次 `.atomic`，最终音频走 `mkstemp` 私有 staging fd + 完整 `write(2)`
    // + `fsync` + `link(2)` 的不可覆盖发布，最后 `unlink(2)` 清 staging。源文件的 `open(O_RDONLY |
    // O_NOFOLLOW | O_NONBLOCK)` 仍只是有界只读；这里逐字记录的是整个受审计表面，不把低层安全
    // 发布误算成第二处内容替换式 `.write`。
    "gui/Sources/ClaudioGUICore/AudioImport.swift": [
        ".write(", "link(", "mkstemp(", "open(", "unlink(", "write(",
    ],
    // 包 manifest 的原子写。
    "gui/Sources/ClaudioGUICore/ManifestBinding.swift": [".write("],
    // 星标删除：锁内重验后的单目录项 `unlink(2)`；不跟随 symlink，也不递归删除目录。
    "gui/Sources/ClaudioGUICore/PackGallery.swift": ["unlink("],
    // T6 forkPack：出厂包整份目录拷进调用独占 staging（`.copyItem(`），成功后用
    // `renameatx_np(..., RENAME_EXCL)` 做同卷、原子、不可覆盖的目录发布。manifest 本身的写
    // 已记在 `ManifestBinding.swift`，这里不重复记。
    "gui/Sources/ClaudioGUICore/PackFork.swift": [".copyItem(", "renameatx_np("],
    // 恢复出厂包：完整 factory staging、旧安装 salvage 与同父目录发布。
    "gui/Sources/ClaudioGUICore/PackRestore.swift": [".copyItem(", ".moveItem("],
]

/// **内容替换式写盘的调用点台账** —— 哪个文件里有几处 `.write(to:…)` / `.write(toFile:…)`。
///
/// 计数**绑调用点**（`/review e7c38ea`：上一版是一个全仓总数 `totalWriteSites >= 9`，它挡的只是
/// 「检测器整个瞎掉」；一处写盘单独从检测器眼皮底下消失、而别处新增一处，它照样绿）。
private let contentReplacingWriteSites: [String: Int] = [
    "helper/Sources/ClaudioCore/ConfigMutation.swift": 1,
    "helper/Sources/ClaudioCore/Log.swift": 2,
    "helper/Sources/ClaudioCore/Play.swift": 1,
    "helper/Sources/ClaudioCore/ConcreteHostIntegrationAdapters.swift": 1,
    "gui/Sources/ClaudioGUICore/AudioImport.swift": 1,
    "gui/Sources/ClaudioGUICore/ManifestBinding.swift": 1,
]

/// 写意图的 `open(2)` flag。`O_RDONLY` 刻意不在里面 —— `SafeFileRead` / `AudioImport` 的有界只读走的
/// 正是它，它们不是写者。
private let writeIntentOpenFlags = ["O_WRONLY", "O_RDWR", "O_APPEND"]

/// 允许持有**写意图裸 fd** 的生产文件。
///
/// - `Log.swift` —— 日志追加（`O_APPEND` 上的单次 `write(2)`，追加不是替换）。
/// - `FileLock.swift` —— 锁文件本身（`flock(2)` 要一个 fd）。
private let rawWriteFileDescriptorHolders: Set<String> = [
    "helper/Sources/ClaudioCore/Log.swift",
    "helper/Sources/ClaudioCore/FileLock.swift",
]

// MARK: - Suites

@MainActor
func runAtomicWriteSuites() {
    var scanned: [String: StrippedSwiftSource] = [:]

    suite("写盘绊线①：围栏 —— 碰了写盘表面的生产文件，必须逐字等于台账（认不出 ⇒ 红，不是隐形）") {
        // 先钉「我扫的是不是全部的树」。加一个 SPM 包而不回来看这条不变量，是这条绊线唯一一种会
        // **整棵树静默失明**的失效方式 —— 而它不会红，除非这里正面断言。
        let trees = discoveredProductionSourceTrees()
        expect(
            trees == expectedProductionSourceTrees,
            "仓库里的生产源码树变了。期望 \(expectedProductionSourceTrees.sorted())，"
                + "实际发现 \(trees.sorted())。发现是**递归**的，所以多出来的那棵树（哪怕嵌在"
                + "`packages/…` 底下）**已经被扫了**；你必须回来确认一次：这条不变量该不该管那个新包")

        // 而「叫 Sources 的目录」认不出一个用了自定义 `path:` 的 target。包的数量是第二道闸。
        let manifests = discoveredPackageManifests()
        expect(
            manifests == expectedPackageManifests,
            "仓库里的 SPM 包变了。期望 \(expectedPackageManifests.sorted())，实际 \(manifests.sorted())。"
                + "一个 target 可以用 `path:` 把源码放在任何目录名下 —— 那样上面那个「找名叫 Sources "
                + "的目录」的发现算法**认不出它**，而这条绊线会对整棵树失明。回来看一眼")

        let files = productionSwiftFiles()
        // 反恒真①：枚举器坏掉（路径推错、`enumerator` 返回 nil）→ 0 个文件 → 下面每一条都会因为
        // **一个文件都没看见**而恒真。先钉住「我真的看到了源码」。
        expect(
            files.count >= 50,
            "只枚举到 \(files.count) 个生产源文件（今天 57 个）—— 枚举器坏了。"
                + "0 个文件 = 0 处写盘 = 下面每一条断言恒真绿，而它们自称守着用户配置的唯一副本")

        var surface: [String: Set<String>] = [:]
        for path in files {
            guard let source = scanProduction(path) else {
                expect(false, "读不到 \(path) —— 这条绊线指望能读到每一个生产源文件")
                continue
            }
            scanned[path] = source
            // 扫描器自认读不懂的构造 = 它的输出不再可信。而这条绊线的失效模式恰恰是**少看见一段代码
            // 只会更绿**：一次藏在被误判成字符串的区间里的非原子写会永久隐身。
            expect(
                source.unmodeledConstructs.isEmpty,
                "\(path) 里出现了 `strippingComments` 不建模的词法构造：\(source.unmodeledConstructs)"
                    + " —— 它剥出来的代码从此不可信，而一次消失在里面的非原子写只会让这条绊线**更绿**。"
                    + "要么把这个构造挪走，要么先教 `strippingComments` 认识它")

            let tokens = diskWriteSurfaceTokens(in: source.codeWithoutStringLiterals)
            if !tokens.isEmpty { surface[path] = tokens }
        }

        // **围栏本体。** 这一条红了，说明有人往生产码里加了一处这条绊线**没建模过**的写盘出口
        // （`createFile` / `fopen` / `OutputStream` / 一个新起的子进程…）。上一版对这些**全绿**。
        expect(
            surface == diskWriteSurfaceLedger,
            "写盘表面台账对不上。\n"
                + "  只在磁盘上有（**新的写盘出口，这条绊线没见过**）："
                + "\(surface.filter { diskWriteSurfaceLedger[$0.key] != $0.value }.mapValues { $0.sorted() })\n"
                + "  只在台账里有（写盘没了？那就把它从台账里删掉）："
                + "\(diskWriteSurfaceLedger.filter { surface[$0.key] != $0.value }.mapValues { $0.sorted() })\n"
                + "  这条绊线的形状是**围栏**，不是**探针**：它不去猜你用了哪种写法，它要求"
                + "「能把字节送进文件、或把文件放上路径」的**每一个**调用都在台账里、且写着理由。"
                + "新增的那一处：要么改成一次原子写（`Data.write(to:options:.atomic)`，或"
                + "「暂存 + 同卷 rename」），要么在 `diskWriteSurfaceLedger` 里加一行并写清**为什么"
                + "它不需要原子性** —— 别悄悄放行。上一版的 needle 只认 `.write(`，于是一行"
                + "`FileManager.createFile(atPath:contents:)` 把用户配置的唯一副本写回非原子，"
                + "1195 条断言全绿（实测）")

        // 反恒真②：词汇表被清空 / `diskWriteSurfaceTokens` 被改坏 → `surface` 为空字典，而空字典
        // 与一个非空台账不相等 → 上面那条会红。但如果有人把台账也清空，两个空字典就相等了 ——
        // 所以再正面钉一次「台账本身非空，且它认得的文件真的都被扫到了」。
        expect(
            !diskWriteSurfaceLedger.isEmpty && surface.count >= 10,
            "写盘表面台账空了（或只认出 \(surface.count) 个文件）—— 两个空字典相等，上面那条于是恒真。"
                + "今天真实有 \(diskWriteSurfaceLedger.count) 个生产文件在碰写盘表面，它们必须被看见")
    }

    suite("写盘绊线②：围栏之内 —— 每一处内容替换式写盘都必须原子，且**每个文件几处**是钉死的") {
        var sites: [String: Int] = [:]
        for (path, source) in scanned {
            for arguments in writeCallArguments(in: source.codeWithoutStringLiterals) {
                // 不带路径标签的写（`FileHandle.write(_:)` / `.write(contentsOf:)`）—— 一次
                // `FileHandle(forWritingTo: configFile)` 就能绕开这整条不变量。不静默跳过。
                guard isContentReplacingWrite(arguments) else {
                    expect(
                        false,
                        "\(path) 有一处这条绊线读不懂的写调用：`.write(\(arguments))` —— 它的第一个实参"
                            + "既不是 `to:` 也不是 `toFile:`，所以它不是「把一条路径的内容整个换掉」。"
                            + "但它**也不是**能放过去的东西：一次 `FileHandle(forWritingTo: configFile)` "
                            + "就从这条不变量底下整个走过去了。要么改用 `Data.write(to:options:.atomic)`，"
                            + "要么在这里就地为它写一条断言 —— 别让它无声无息")
                    continue
                }
                sites[path, default: 0] += 1
                expect(
                    isAtomicWrite(arguments),
                    "\(path) 有一处**非原子**的内容替换式写盘：`.write(\(arguments))`。"
                        + "非原子写被 kill 打断会在磁盘上留下半截文件，而它的每一个读者——包括那些只用"
                        + "`fileExists` 判存在的——都会把它当成一份完整的文件。改成 `options: .atomic`"
                        + "（`Data`）或 `atomically: true`（`String`）：同目录临时文件 + `rename(2)`，"
                        + "**被 kill 之后**终态只有「没有」和「完整」两种。"
                        + "（⚠️ 掉电不在此列 —— 全仓没有 `fsync`/`F_FULLFSYNC`，rename 不保证数据块先于"
                        + "目录项落盘。别再声称它。）"
                        + "真要豁免，请在这里就地写清理由——别悄悄放行")
            }
        }

        // 计数**绑调用点**。`>= N` 的全仓总数挡不住「某一处单独隐身、别处补上一处」——
        // 上一版正是这么假绿的（实测：把备份那处换成 `createFile`，再随便加一处原子写把总数顶回 9）。
        expect(
            sites == contentReplacingWriteSites,
            "内容替换式写盘的**调用点**变了。期望 \(contentReplacingWriteSites.sorted { $0.key < $1.key })，"
                + "实际 \(sites.sorted { $0.key < $1.key })。少了 = 检测器在这个文件上瞎了（而瞎掉只会"
                + "更绿）；多了 = 新增了一处写盘，请确认它是原子的，然后把这个数字改对。"
                + "**不要**把它改成一个下界 —— 一个总数的下界正是上一版假绿的那道门")
    }

    suite("写盘绊线③：正向对照 —— 喂合成源码，**走整条真实管线**（剥注释 → 清空字符串 → 取实参 → 判形状）") {
        // ⚠️ 上一版的「正向对照」把裸字符串直接喂给 `writeCallArguments` / `isAtomicWrite`，
        // 于是 `strippingComments` 与字符串清空这两级**一条正向断言都没有**，而它们恰恰是真实扫描
        // 路径的**头两级**。这里走的是与 suite ①② 逐字同一条管线。
        func pipeline(_ source: String) -> String {
            strippingComments(source).codeWithoutStringLiterals
        }

        // —— 检测器必须真的抓得到非原子写 ——
        let nonAtomic = pipeline("try originalData.write(to: backupFile)")
        expect(
            writeCallArguments(in: nonAtomic).count == 1,
            "检测器没抓到这次写调用 —— 它抓不到的每一处，都是一条恒真断言")
        expect(
            writeCallArguments(in: nonAtomic).first.map { !isAtomicWrite($0) } ?? false,
            "一次没有 `options:` 的 `Data.write(to:)` **必须**被判为非原子 —— 那正是 `SettingsInstaller` "
                + "的备份写修之前逐字的样子")

        // —— 空格逃逸（上一版实测隐身，且这行合法 Swift、真的能编译）——
        let spaced = pipeline("try originalData.write (to: backupFile)")
        expect(
            writeCallArguments(in: spaced).count == 1
                && writeCallArguments(in: spaced).first.map { !isAtomicWrite($0) } == true,
            "`.write (to:` —— `write` 与 `(` 之间一个空格，合法 Swift。上一版的字面 needle `.write(` "
                + "认不出它，那次非原子写从绊线眼皮底下整个走过去")

        // —— 跨行调用：按行截断的检测器会看不到下一行的 `options: .atomic`，把合法原子写判成非原子 ——
        let multiline = pipeline(
            """
            try data.write(
                to: settingsFile,
                options: .atomic)
            """)
        expect(
            writeCallArguments(in: multiline).count == 1
                && writeCallArguments(in: multiline).first.map(isAtomicWrite) == true,
            "一次**跨行**的原子写没被认出来 —— 检测器在按行截断，而不是按配平括号取实参")

        // —— 四种合法原子写法，一处都不许误判（假红会被人删掉，删掉之后真正的非原子写也就没人守了）——
        let legal = [
            "try data.write(to: configFile, options: .atomic)",
            "try data.write(to: f, options: [.atomic, .withoutOverwriting])",
            "try? String(stamp).write(to: stateFile, atomically: true, encoding: .utf8)",
            "try s.write(toFile: path, atomically: true, encoding: .utf8)",
        ]
        for source in legal {
            let arguments = writeCallArguments(in: pipeline(source))
            expect(
                arguments.count == 1 && arguments.first.map(isContentReplacingWrite) == true
                    && arguments.first.map(isAtomicWrite) == true,
                "这是一次**合法的原子写**，却没被认出来（或被判成非原子）：`\(source)`。"
                    + "`write(toFile:atomically:)` 这一条是上一版实测的假红 —— 它只认 `to:`")
        }

        // —— fail closed：读不出确切形状 ⇒ 非原子。上一版这几条**全是假绿** ——
        let failClosed = [
            "try s.write(to: f, atomically: false, encoding: .utf8)",
            "try data.write(to: f, options: writeOptions)",
            "try data.write(to: f, options: fast ? [] : .atomic)",
            "try data.write(to: f, options: .atomicUnlessSandboxed)",
            "try data.write(to: f, options: makeOptions(.atomic))",
        ]
        for source in failClosed {
            let arguments = writeCallArguments(in: pipeline(source))
            expect(
                arguments.count == 1 && arguments.first.map { !isAtomicWrite($0) } == true,
                "读不出确切形状的 `options:` / `atomically:` **必须**判非原子（fail closed）：`\(source)`。"
                    + "上一版是 `contains(\".atomic\")` —— `fast ? [] : .atomic` 在 `fast` 时是一次货真价实"
                    + "的非原子写，而它判成原子（实测全绿）")
        }

        // —— 字符串字面量：里面的括号不许把配平带偏，里面的散文不许变成调用点 ——
        let parenInString = pipeline(
            """
            try data.write(to: dir.appendingPathComponent("pack (1.json"), options: .atomic)
            try other.write(to: logFile, options: .atomic)
            """)
        let parenSites = writeCallArguments(in: parenInString)
        expect(
            parenSites.count == 2 && parenSites.allSatisfy(isAtomicWrite),
            "字符串里一个 `(` 就把括号配平带偏了：抓到 \(parenSites.count) 处（应为 2），"
                + "\(parenSites)。上一版会把第一次**合法的原子写**判成假红，并且 `break` 掉这个文件"
                + "**剩下的每一处**写调用 —— 假红有人喊，被 break 吞掉的那些没有人看得见")

        let proseInString = pipeline(
            """
            let hint = "改成 data.write(to: f) 就好了"
            """)
        expect(
            writeCallArguments(in: proseInString).isEmpty,
            "一句**散文**（错误消息 / 文档里的示例串）被当成了调用点 —— 那是假红的来源，"
                + "而假红最后总是被删掉的那一个")

        // —— 插值里的**代码**必须活着（清空字符串内容 ≠ 清空插值）——
        let inInterpolation = pipeline(
            """
            log("wrote \\(try! data.write(to: f)) bytes")
            """)
        expect(
            writeCallArguments(in: inInterpolation).count == 1
                && writeCallArguments(in: inInterpolation).first.map { !isAtomicWrite($0) } == true,
            "插值 `\\(…)` 里面是**代码**，不是字符串内容。把它一起清空 = 一处藏在插值里的非原子写"
                + "永久隐身，而这正是 `/codex review 2f107b5` 那个 P1 的形状")

        // —— 围栏的词汇表本身也要有正向对照：头三行是上一版实测**全绿**的三次非原子写 ——
        let evasions = [
            (
                "FileManager.default.createFile(atPath: configFile.path, contents: data)",
                ".createFile("
            ),
            ("let handle = fopen(configFile.path, \"w\")", "fopen("),
            ("let fd = creat(path, 0o600)", "creat("),
            ("let stream = OutputStream(url: f, append: false)", "OutputStream("),
            ("let h = FileHandle(forWritingTo: configFile)", "FileHandle("),
            ("try fileManager.copyItem(at: source, to: destination)", ".copyItem("),
            ("let result = Darwin.rename(source, destination)", "rename("),
        ]
        for (source, token) in evasions {
            let tokens = diskWriteSurfaceTokens(in: pipeline(source))
            expect(
                tokens.contains(token),
                "围栏没认出 `\(token)`：`\(source)` → \(tokens.sorted())。"
                    + "上一版对 `createFile` / `fopen` / `creat` **全绿**（实测把它们写进 helper/Sources "
                    + "之后 `swift run claudio-tests` 一声不吭）—— 那正是这次翻转极性要杀的东西")
        }

        // —— 而围栏不许误伤：`NSWorkspace.shared.open(` 不是 POSIX `open(2)`，`overwrite(` 不是 `write(` ——
        let notWrites = [
            "NSWorkspace.shared.open(backupDirectory)",
            "let n = overwrite(count)",
            "let options = writeOptions(for: file)",
        ]
        for source in notWrites {
            let tokens = diskWriteSurfaceTokens(in: pipeline(source))
            expect(
                tokens.isEmpty,
                "围栏误伤：`\(source)` → \(tokens.sorted())。它不是一次写盘，而一条假红最后总是"
                    + "被删掉的那一个 —— 删掉之后，真正的写盘也就没人围了")
        }
    }

    suite("写盘绊线④：写意图的裸 fd —— 只有 Log（日志追加）与 FileLock（锁文件）可以持有") {
        // 围栏（①）已经把 `open(` 围住了：谁在 open 都得在台账里。这一条再往里钉一层：那几个 open
        // 里，**带写意图**的只能是这两个。`SafeFileRead` / `AudioImport` 的 `open` 是 `O_RDONLY`。
        var holders: Set<String> = []
        for (path, source) in scanned {
            let code = source.codeWithoutStringLiterals
            if writeIntentOpenFlags.contains(where: { code.contains($0) }) { holders.insert(path) }
        }
        expect(
            holders == rawWriteFileDescriptorHolders,
            "持有写意图裸 fd（\(writeIntentOpenFlags.joined(separator: " / "))）的生产文件变了。"
                + "期望 \(rawWriteFileDescriptorHolders.sorted())，实际 \(holders.sorted())。"
                + "多出来的那个文件在用 `open(2)` + `write(2)` 写盘 —— 要么改用"
                + "`Data.write(to:options:.atomic)`，要么在这里加进名单并写清为什么非裸写不可"
                + "（Log 是因为追加不是替换，FileLock 是因为 `flock(2)` 要一个 fd）")
        // 反恒真：flag 表被清空 / `code` 全是空串 → `holders` 为空集；而空集与一个非空期望集不相等，
        // 上面那条会红。但如果有人把期望集也改空，两个空集就相等了 —— 所以正面钉一次「名单非空」。
        expect(
            !rawWriteFileDescriptorHolders.isEmpty && holders.count >= 2,
            "裸写名单空了 —— 两个空集相等，上面那条断言于是恒真。Log 与 FileLock 都真的在裸写，"
                + "它们必须被这条绊线看见")
    }
}
