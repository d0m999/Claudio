import Foundation

// MARK: - 扫描器**自己**的回归网
//
// `LockSeparationSuite`（读 `helper/Sources`）与 `ViewWiringSuite`（读 `gui/Sources`）的兜底全是
// **负向**断言。于是这两套绊线共享同一个致命失效模式：**分析文本里少一段代码，它们只会更绿。**
// 而分析文本由 `strippingComments` 一个函数生产 —— 它是那两套绊线的**单点故障**。
//
// ## 这个 suite 的形状，以及它替掉的两代守卫
//
// - `be332ff` 想守这个洞，写的是 `!codeOnly(path).contains("://")` —— 用**那个会截断的函数的输出**
//   去检查「有没有会导致截断的输入」。`://` 自带 `//`，到达断言之前早已被剪成 `https:`。
//   **它恒真**，而它的失败消息自称「真到了非放不可的那天会当场变红」。
//
// - `2f107b5`（就是加这个 suite 的那个 commit）修对了扫描器的一半，然后把守卫换成
//   ``StrippedSwiftSource/unmodeledConstructs``「它知道自己不认识什么」。**那张清单当时只认得 raw
//   string 一样东西**，而扫描器还有第二个盲区：**插值**。于是 `"\(f("https://x"))"` 照样把状态机
//   带倒相、照样吃掉整行代码，而清单**是空的**，守卫一声不吭。措辞比覆盖范围大，复发在自称已经
//   治好它的那一刀里。
//
// 所以这个 suite 的形状是**唯一**不会退化成恒真式的那一种：**喂合成输入给扫描器，正向断言它的
// 输出**。喂的是它自己的输入，读的不是它自己的输出。白名单式的守卫（「我不认识 X」）永远漏得掉
// 下一个 X；**逐条钉死行为**漏不掉。
//
// 顺带钉死另一半：注释**必须**被剥掉。`Use.swift` / `SettingsInstaller.swift` 的 doc comment 里
// 白纸黑字写着 `ClaudioPaths/playLockFile`（写的正是「我**不**用这把锁」）—— 不剥注释，
// `!contains("playLockFile")` 那几条负向断言会因为**谈论代码的散文**而假红。两个方向都得钉：
// 剥太少 → 假红（没人受得了，会被删掉）；剥太多 → **假绿**（没人看得见，洞永远开着）。

/// 仓库根 —— 从 `#filePath` 推（编译期常量，不依赖 cwd）。
/// `<pkg>/Tests/<Module>Tests/SourceScannerSuite.swift` → 上溯 4 层。两个包同深度。
private func repoRoot(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

/// 递归枚举 `directoryURL` 下**所有** `.swift` 源文件（含任意深度的子目录），返回
/// `(相对子路径, URL)` 列表，按子路径排序（确定序）。
///
/// ⚠️ 用 `enumerator`（会下钻子目录），**不是** `contentsOfDirectory`（只读一层）：SwiftPM
/// 会编译 target 子目录里的源文件，所以一个落在 `ClaudioGUICore/Feature/PackWriter.swift`
/// 的 manifest 新写者也必须能被 T3 内容围栏纳入 —— 非递归会把它编译进去却漏出围栏，围栏对它
/// 静默为绿，违背它自称的「任意 .swift 自动纳入」（/codex review 327d211 的 P1）。
///
/// 相对子路径**保留子目录前缀**（`Feature/Nested.swift`，不是拍平成 `Nested.swift`）：两个不同
/// 目录下的同名文件不许撞车，围栏的诊断消息/具名钉子也才指得对地方。
///
/// 名字碰巧带 `.swift` 的**目录**用 `isRegularFile` 挡掉 —— 否则真文件那步 `String(contentsOf:)`
/// 读它会失败、退化成假红。
///
/// T3 内容围栏与「递归纳入自证有牙」那条 suite 喂的是**同一个**函数：有人把它改回非递归，那条
/// suite 的嵌套 fixture 会当场消失、变红。
private func recursivelyEnumeratedSwiftFiles(under directoryURL: URL)
    -> [(relativeSubpath: String, url: URL)]
{
    let basePath = directoryURL.standardizedFileURL.path
    let enumerator = FileManager.default.enumerator(
        at: directoryURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles])
    return (enumerator?.compactMap { $0 as? URL } ?? [])
        .filter { url in
            url.pathExtension == "swift"
                && ((try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false)
        }
        .map { url -> (relativeSubpath: String, url: URL) in
            let full = url.standardizedFileURL.path
            let subpath =
                full.hasPrefix(basePath + "/")
                ? String(full.dropFirst(basePath.count + 1))
                : url.lastPathComponent
            return (subpath, url)
        }
        .sorted { $0.relativeSubpath < $1.relativeSubpath }
}

/// 一份 `TestSupport.swift` 里两行哨兵之间的那段文本（含哨兵本身）。
///
/// ⚠️ 哨兵按**整行精确匹配**，不是 `contains` —— 区块内部的散文里就**提到过**这两个 token
/// （「到 …:end 为止的这一段」）。用 `contains` 会把那句散文当成结束哨兵，抽出三行注释就收工，
/// 而下面那条 `helperRegion == guiRegion` 会拿两坨同样的三行散文比出**恒真绿**。
/// 这不是假想：第一版就是 `contains` 写的，被本 suite 自己的正向控制当场逮住。
private let scannerRegionBegin = "// claudio:shared-scanner:begin"
private let scannerRegionEnd = "// claudio:shared-scanner:end"

private func sharedScannerRegion(of relativePath: String) -> String? {
    guard
        let text = try? String(
            contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
    else { return nil }
    let lines = text.components(separatedBy: "\n")
    func indexOfSentinel(_ sentinel: String) -> Int? {
        lines.firstIndex {
            $0.trimmingCharacters(in: .whitespaces) == sentinel
        }
    }
    guard let begin = indexOfSentinel(scannerRegionBegin),
        let end = indexOfSentinel(scannerRegionEnd),
        begin < end
    else { return nil }
    return lines[begin...end].joined(separator: "\n")
}

// MARK: - T3 @MainActor 正向绊线的两个原语（/codex review dcab3de,7e97bc4 的 P1）
//
// 并发 token 黑名单那条腿只挡「变异步」，挡不住「同步但脱离主 actor」。manifest.json 零锁的并发
// 安全靠「全同步 **且** 全在 @MainActor」两条腿，黑名单只钉住了「全同步」。这两个 helper 让绊线
// 正向钉住第二条腿：文件里**每一个枚举得到的**导出写函数都得带 @MainActor —— 不是一份会忘记
// 更新的写死名字清单，新写者（forkPack / restoreFactoryPack）落地即自动纳入。
//
// ⚠️ 「每一个**枚举得到的**」这个限定词是认真的，别读成「每一个」——见下面 `exportedPublicFuncNames`
// 的已知盲区。这条腿是**探针，不是围栏**：它认不出的写函数形状是**静默跳过**，不是红。

/// `public` 与 `func` 之间允许出现的东西：空白 / 修饰符（`static` `final` `class` `override`
/// `mutating`…）/ 其它属性。**全部是字母、空白、`@`、`_`** —— 一个标点都不含。
///
/// 这正是它作为围栏的依据：任意**函数体**或参数表都带 `(){}:,` 之类标点，于是这个 run
/// **跨不过**上一个声明，`public` 必须是**这一个** func 自己的修饰词才会匹配。
private let publicFuncModifierRun = "[\\sA-Za-z@_]*"

/// 一段**已剥注释**的代码里所有**导出**函数的名字。绊线要对每一个都断言 @MainActor。
///
/// 认 `public func` / `public static func` / `public final func` / `public class func` /
/// `public override func` / 换行排版 / `@_spi(X) public func` —— 即 `public` 与 `func` 之间
/// 只隔着修饰符与属性的**任何**形态（见 ``publicFuncModifierRun``）。
///
/// 上一版只逐字捞 `public func `，于是 `public static func` 的写者**不匹配、不报错、悄悄溜过**
/// ——而这个形态在本模块里**已经在用**（`PreviewFixtures.swift` / `VolumeDragSession.swift`）。
/// 一个 `public static func` 的**同步**写者不含任何被禁 token，两条腿会同时放行，而它不在
/// @MainActor 上、任意后台线程可以同步调它 —— 正是 `PLAN-SOUND-MANAGER.md` 点名那个「唯一
/// critical gap」的确切形状。红队实测：旧版下往 `ManifestBinding.swift` 塞一个这样的写者，
/// 2099 条断言**全绿**。所以这条从探针升成围栏。
///
/// ⚠️ 仍然诚实地留着的限度（**不是**围栏的部分，别读成「不可能漏」）：
/// - 只认 `public`。`package` / `open` 的写者不在内。
/// - 靠 `@MainActor extension` 或类型级隔离、函数头上不带注解的写者，会被
///   ``hasMainActorIsolation`` 判成「未隔离」而**假红**（假红是安全侧，但它会招来「把绊线删掉」
///   那种修法——真出现了，请扩 ``hasMainActorIsolation``，别删断言）。
private func exportedPublicFuncNames(in code: String) -> [String] {
    let pattern = "public\(publicFuncModifierRun)\\bfunc\\s+([A-Za-z_][A-Za-z0-9_]*)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let text = code as NSString
    return regex
        .matches(in: code, range: NSRange(location: 0, length: text.length))
        .map { text.substring(with: $0.range(at: 1)) }
}

// MARK: - T3 并发绊线的判据（一份，正反两侧共用）
//
// ⚠️ **这是一份「已知构造」的黑名单，不是完备围栏。** 它只认得下面枚举的这些 token；Swift 里
// 「离开主线程 / 引入并发」的写法远不止这些（自定义 `actor` 上的隔离、C 回调、Combine 的
// `subscribe(on:)`、`NSXPCConnection`、GCD 的 C API …… 都不在内）。别把它读成「本文件不可能变并发」。
//
// 另一条腿（`@MainActor`）**也不是**完备围栏，别把两条腿加起来读成「不可能漏」：它枚举写函数
// 靠逐字匹配 `public func `，认不出的形状（`public static func`、`extension` 里的类型级隔离……）
// 是**静默跳过**——详见 `exportedPublicFuncNames` 头上那段已知盲区。
//
// 所以诚实的说法是：**两条腿都是探针，各自覆盖一组已知形态，合起来仍有缺口。**
//  · 黑名单挡「变异步 / 派发 / 起线程」这组已知 token —— 这是 @MainActor 挡不住的形态
//    （`@MainActor public func f() async` 编译得过，跨 await 的读-改-写照样能交错）。
//  · @MainActor 挡「同步但脱离主 actor」，覆盖**枚举得到的**每个 `public func`。
// 真正兜底的不是这两条腿，是 code review 和「所有写者都必须经 `mutateManifestJSON`」这条纪律。
private let bannedConcurrencyTokens = [
    "async", "Task", "DispatchQueue", "Thread", "OperationQueue",
    ".detached", "withCheckedContinuation", "pthread",
]

/// 一段**已剥注释**的代码里命中的并发 token；空 = 清白。
///
/// 读 `codeWithoutStringLiterals`（字符串**内容**被清空、界定符与插值代码保留）而不是 `code`：
/// 这条断的是「代码里有没有并发构造」，而一句**写着** `"…async…"` 的错误消息 / 文案 / 测试
/// fixture 不是并发代码。用 `code` 会让真文件因为自己的一句提示文案假红，然后被下一个人删掉
/// ——本文件开头记的「剥太少 → 假红 → 守卫被删」，字符串这一侧是同一个病。
///
/// 真文件那条绊线与它的合成正向控制共用**这一个**函数、且都传整个 `StrippedSwiftSource`，
/// 所以连「读哪个字段」都不可能在两侧漂移。判据一旦静默失灵（token 拼错、`filter` 写反、
/// `strippingComments` 把代码吃光），`hits.isEmpty` 就是一句恒真绿，而下面那条自证有牙的 suite
/// ——逐 token 各一条手写脏 fixture、外加一条 token↔fixture 配平断言——会当场把它逮出来。
private func bannedConcurrencyHits(in scanned: StrippedSwiftSource) -> [String] {
    bannedConcurrencyTokens.filter { scanned.codeWithoutStringLiterals.contains($0) }
}

/// 一段**已剥注释**的代码里，名为 `name` 的 `public func` 是否带 @MainActor 隔离。
///
/// `@MainActor` 与 `func` 之间只允许空白 / 访问修饰符 / 其它属性（都落在 ``publicFuncModifierRun``），
/// 而任意函数体都含 `{}()` 之类标点 —— 于是这个 run **不可能跨过上一个函数体**：`name` 必须带
/// **它自己**那一个 @MainActor 才会匹配，前一个函数头上的 @MainActor 算不到它身上（下面那条合成
/// 控制里的 `naked` 反例逐字钉着这一点）。
///
/// 匹配到 `func` 而不是 `public func`，与 ``exportedPublicFuncNames`` 认的形态对齐：
/// `@MainActor public static func f` 里 `public` 与 `static` 都落在同一个 run 里。两边若不对齐，
/// 枚举器捞得到、隔离检查却匹配不上，每个 `static` 写者都会**假红**。
private func hasMainActorIsolation(funcName name: String, in code: String) -> Bool {
    code.range(
        of: "@MainActor\(publicFuncModifierRun)\\bfunc\\s+\(name)\\b",
        options: .regularExpression) != nil
}

@MainActor
func runSourceScannerSuites() {

    suite("扫描器：字符串字面量里的 `//` 不是注释起点（be332ff 那条恒真守卫真正想守的东西）") {
        // 这**就是** `be332ff` 的元断言想拦、却因为自身恒真而拦不住的那一行输入。
        // 朴素截断版把它剪成 `let hint = "锁的说明见 https:` —— 后半行那句
        // `lockFile: ClaudioPaths.playLockFile` 对整套锁分离断言**永久隐身**。
        let source = #"""
            let hint = "锁的说明见 https://claudio.dev/locks"; _ = write(lockFile: ClaudioPaths.playLockFile)
            """#
        let scanned = strippingComments(source)
        expect(
            scanned.code.contains("playLockFile"),
            "行内 URL 之后的**代码**必须活下来。它没活下来 = 扫描器又在 `//` 处无条件截断了，"
                + "而两个 suite 的负向兜底会因此**更绿**：一句藏在 URL 后面的 "
                + "`lockFile: ClaudioPaths.playLockFile` 对整套锁分离断言永久隐身。得到：\(scanned.code)")
        expect(
            scanned.code.contains("ClaudioPaths"),
            "整行都得在，不只是那个标识符。得到：\(scanned.code)")
    }

    // MARK: 插值 —— `/codex review 2f107b5` 的 P1，逐字是上面那个病的第二个入口

    suite("扫描器：插值里的**嵌套字符串**不结束外层串（2f107b5 那条守卫全程沉默的洞）") {
        // 这一行是合法 Swift。上一版扫描器把 `\(` 只当成一个转义对吞掉、模式仍停在 .string，
        // 于是插值内 `"https://…"` 的**开引号**被当成外层串的**闭引号** —— 状态机倒相回代码模式，
        // 紧接着 URL 的 `//` 成了注释起点，整行被剪成 `let hint = "\(fallback ?? "https:`。
        //
        // 而 `unmodeledConstructs` **是空的**：它只认得 raw string。两个包的守卫一个字都没说。
        let source = #"""
            let hint = "\(fallback ?? "https://claudio.dev/locks")"; _ = write(lockFile: ClaudioPaths.playLockFile)
            """#
        let scanned = strippingComments(source)
        expect(
            scanned.code.contains("playLockFile"),
            "插值里嵌套字符串之后的**代码**必须活下来。它没活下来 = `\\(…)` 里的那个 `\"` 被当成外层串"
                + "的结尾，状态机倒相，串内 URL 的 `//` 又成了注释起点 —— 同一个截断、同一个「锁永久"
                + "隐身」，而负向兜底只会更绿。得到：\(scanned.code)")
        expect(
            scanned.code.contains("claudio.dev"),
            "插值里那个字符串的**内容**是数据，必须原样留下（它不是注释）。得到：\(scanned.code)")
        expect(
            scanned.unmodeledConstructs.isEmpty,
            "插值是**被建模**的构造，不该记进「我不认识」的清单 —— 记了 = 两个 suite 的 unmodeled "
                + "守卫会在每一个用了插值的源文件上假红，然后被下一个人删掉。得到：\(scanned.unmodeledConstructs)")
    }

    // ## ⚠️⚠️ 下面四条的输入，第一版**全都没有牙**（变异台账 M2/M3/M4/M5 实测，第十一次）
    //
    // 它们当时喂的输入长这样：`"\(format(name, "https://a/b"))"; _ = write(lockFile: …playLockFile)`，
    // 断言 `code.contains("playLockFile")`。看着挺像回事 —— **而 M3（插值栈退化成标志位）与 M4
    // （括号不计数）两条变异，两个包 2776 条断言零红，双双存活。**
    //
    // 根因是一句必须写死在这里、否则下一个人还会再犯的话：
    //
    // > **状态机倒相成 `.string` 并不吃代码** —— 字符串内容照样 `code.append`。只有倒相进 `.code`
    // > **而且那个位置上有 `//`**，才会开出一条假注释、把整行剩下的代码吃掉。
    //
    // 上面那份输入里，误判区（正确实现在插值内、变异实现已弹回串内的那一段）**一个 `//` 都没有**，
    // 而且引号奇偶自我抵消 —— 变异版与原版的 `code` **逐字节相同**，`unmodeledConstructs` 都是 `[]`。
    // 一条断言若对它点名要杀的那个缺陷永远红不了，它就是恒真的；suite 名字与失败消息把因果写得
    // 越具体，越是在骗读它的人。
    //
    // 修法统一：**把 `//`（或一条真注释）放进误判区内部**，让「倒相」这件事真的有后果。
    // 每条的推演都写在各自的注释里 —— 它们现在全部经定向变异实测会红。

    suite("扫描器：插值里的括号要配平（第一个 `)` 不结束插值 —— 误判区内含 `//`）") {
        // 变异（`)` 无条件闭合插值，不数括号）下的推演：
        //   `\(` 进插值 → `prefix` → `(` → `name` → `)` **误判为插值结束**，弹回 .string
        //   → ` + ` 当串内容 → `"` **被当成串尾**，弹回 .code
        //   → 撞上 `//x` 里的 `//` → **开出一条假行注释**，吃掉整行剩下的代码
        //   → `playLockFile` 消失。
        // 正确实现：`)` 只把括号深度从 1 减到 0，插值继续；`"//x"` 是插值内的字符串字面量。
        //
        // 那个 `"//x"` 就是这条断言的牙。第一版没有它，M4 存活。
        let source = #"""
            let hint = "\(prefix(name) + "//x")"; _ = write(lockFile: ClaudioPaths.playLockFile)
            """#
        let scanned = strippingComments(source)
        expect(
            scanned.code.contains("playLockFile"),
            "插值里的括号必须配平之后才算闭合 —— 第一个 `)` 就弹回字符串，接着那个闭引号会把状态机"
                + "带回代码模式，`\"//x\"` 里的 `//` 当场开出一条假行注释，整行剩下的代码被吃掉，"
                + "而负向兜底只会更绿。得到：\(scanned.code)")
        expect(
            scanned.code.contains("//x"),
            "`\"//x\"` 是插值内的**字符串字面量**，是数据不是注释，必须原样留下。得到：\(scanned.code)")
    }

    suite("扫描器：嵌套插值 —— 插值栈不能是个标志位（误判区末尾挂一条真注释）") {
        // `"\(outer("\(inner)"))"` 是合法 Swift。变异（`enterInterpolation` 用**覆盖**而不是**压栈**）：
        //   外层 `\(` 记下一帧 → `(` 把深度记到 1 → 内层 `\(` **把那一帧连同深度一起覆盖掉**
        //   → 内层 `)` 弹回串内、栈空 → 之后的 `)` `)` 变成普通代码字符
        //   → 真正的闭引号 `"` **反而开了一个新串** → 行尾那条**真注释**于是落在「串内」，被当成数据留下。
        //
        // 所以这条的牙是行尾那条真注释，不是 `playLockFile`（它在变异下照样活着 —— 串内容也会被
        // append，这正是第一版没牙的原因）。同一个手法，`""` 那条 suite 已经用过一次。
        let source = #"""
            let hint = "\(outer("\(inner)"))"; _ = write(lockFile: ClaudioPaths.playLockFile)  // 这句注释必须被剥掉
            """#
        let scanned = strippingComments(source)
        expect(
            !scanned.code.contains("这句注释必须被剥掉"),
            "内层插值闭合之后，外层插值**必须还在**（它的括号深度不能被内层覆盖掉）—— 否则真正的闭"
                + "引号会被当成「开一个新串」，行尾那条真注释就落进了串内，被当成代码文本留下来。"
                + "注释文本活着 = 插值栈退化成了标志位。得到：\(scanned.code)")
        expect(
            scanned.code.contains("playLockFile"),
            "整行代码都得在。得到：\(scanned.code)")
    }

    suite("扫描器：多行字符串里的插值 —— 插值内是**代码**，那里的块注释必须被剥掉") {
        // 第一版这条完全没牙（M2 实测）：`.multilineString` 里单个 `"` 本就不是终止符，`\` 又会把
        // `(` 当转义对整对吞掉 —— 于是「不建模多行串插值」在一份只含嵌套字符串的输入上**毫无后果**，
        // 输出逐字节相同。它的名字（「多行串里的插值同样算数」）比它的杀伤力大。
        //
        // 真正能区分两个实现的，是**只在代码位置才成立**的事：插值表达式里的 `/* … */` 是**注释**，
        // 必须被剥掉；而不建模插值时，它落在多行串内部，会被当成**数据**原样留下。
        let source = #"""
            let help = """
                锁的说明见 \(base ?? "https://claudio.dev/locks" /* 这段块注释在插值里 —— 那是代码位置 */)
                """
            _ = write(lockFile: ClaudioPaths.playLockFile)
            """#
        let scanned = strippingComments(source)
        expect(
            !scanned.code.contains("这段块注释在插值里"),
            "多行字符串里的 `\\(…)` 内部是**代码**，那里的块注释必须被剥掉 —— 它活下来了，说明扫描器"
                + "根本没进插值，整段被当成多行串的内容照抄。得到：\(scanned.code)")
        expect(
            scanned.code.contains("claudio.dev"),
            "插值里那个**字符串字面量**的内容是数据，必须留下（剥的是注释，不是插值本身）。"
                + "得到：\(scanned.code)")
        expect(
            scanned.code.contains("playLockFile"),
            "多行串闭合之后必须回到代码模式。得到：\(scanned.code)")
    }

    suite("扫描器：`\\\\(` **不是**插值起点 —— 而那个 `//` 必须落在假插值**内部**") {
        // 反向的错：把 `\\(`（转义反斜杠 + 左括号）误当插值起点，就会在本该是**字符串内容**的地方
        // 进入代码模式。删掉 `.string` 的转义对处理正是这个后果 —— 第一个 `\` 被当普通字符吃掉，
        // **第二个 `\` 与它后面的 `(` 就凑成了 `\(`**，扫描器一头扎进假插值。
        //
        // 第一版把 `//` 放在假插值**配平之后**（`"\\(x) // …"`），于是它**行内自愈**：`)` 关掉假插值、
        // 弹回串内，`//` 仍是串内容 —— 输出逐字节相同，两条断言双双假绿（M5 实测）。
        // 现在 `//` 落在 `\\(` 与 `)` **之间**：假插值里那个 `//` 会开出一条真的行注释，吃掉整行。
        let source = #"""
            let literal = "\\(x // 这不是注释，它在串内) 串还没完"; _ = write(lockFile: ClaudioPaths.playLockFile)
            """#
        let scanned = strippingComments(source)
        expect(
            scanned.code.contains("playLockFile"),
            "`\\\\` 是**转义反斜杠**，它后面那个 `(` 只是普通字符 —— 把 `\\\\(` 读成插值起点，就会在"
                + "串内进入代码模式，那里的 `//` 当场开出一条假行注释，整行剩下的代码消失。"
                + "得到：\(scanned.code)")
        expect(
            scanned.code.contains("这不是注释，它在串内"),
            "那个 `//` 仍在**串内**，是数据不是注释，必须原样留下。得到：\(scanned.code)")
    }

    // MARK: 注释侧（剥太少 → 假红 → 守卫被删）

    suite("扫描器：真正的行尾注释仍然被剥掉（剥太少 → 负向断言假红 → 守卫被删）") {
        let source = #"""
            _ = write(lockFile: environment.configLockFile)  // 绝不是 ClaudioPaths.playLockFile
            """#
        let scanned = strippingComments(source)
        expect(
            scanned.code.contains("configLockFile"),
            "代码得留下。得到：\(scanned.code)")
        expect(
            !scanned.code.contains("playLockFile"),
            "行尾注释里**谈论** playLockFile 的散文必须被剥掉 —— 否则 `!contains(\"playLockFile\")` "
                + "会因为一句「我不用这把锁」的注释而假红。得到：\(scanned.code)")
    }

    suite("扫描器：整行 doc comment 里的 URL —— 不假红，也不吃掉下一行") {
        // 这条是「为什么不能把 ban 挪到 raw source」的可执行版本：注释里的 URL 完全无害，
        // 一条 `!raw.contains("://")` 会在第一个往 doc comment 里写 URL 的人手上红，
        // 然后被删掉，洞原样回来。
        let source = #"""
            /// 锁的完整说明见 https://claudio.dev/locks
            _ = write(lockFile: environment.settingsLockFile)
            """#
        let scanned = strippingComments(source)
        expect(
            !scanned.code.contains("claudio.dev"),
            "注释整行都该没了。得到：\(scanned.code)")
        expect(
            scanned.code.contains("settingsLockFile"),
            "注释里的 `//` 绝不能吃掉**下一行**的代码。得到：\(scanned.code)")
    }

    suite("扫描器：转义引号不结束字符串（`\"\\\" // …\"` 里那个 `//` 仍在串内）") {
        let source = #"""
            let quote = "他说 \" // 这不是注释"; _ = write(lockFile: ClaudioPaths.playLockFile)
            """#
        let scanned = strippingComments(source)
        expect(
            scanned.code.contains("playLockFile"),
            "转义引号被当成串尾 → 后面那个 `//` 被当成注释起点 → 整行剩下的代码消失。"
                + "得到：\(scanned.code)")
    }

    suite("扫描器：多行字符串里的 `//` 不截断，字符串结束之后的代码照常在") {
        let source = #"""
            let help = """
                锁的说明见 https://claudio.dev/locks
                """
            _ = write(lockFile: ClaudioPaths.playLockFile)
            """#
        let scanned = strippingComments(source)
        expect(
            scanned.code.contains("claudio.dev"),
            "多行字符串的**内容**是数据，不是注释，必须原样留下。得到：\(scanned.code)")
        expect(
            scanned.code.contains("playLockFile"),
            "多行字符串闭合之后的代码必须回到代码模式 —— 它没回来 = 文件剩下的部分被整份当成"
                + "字符串吞掉，而负向断言会因此**全部假绿**。得到：\(scanned.code)")
    }

    suite("扫描器：空字符串字面量 `\"\"` 不把后面的代码吞掉") {
        // ⚠️ 这条的第一版**没有牙**（变异台账当场发现）：它喂的输入里**一个 `//` 都没有**，
        // 于是任何一个「不会凭空发明注释」的实现都能过 —— 包括它要杀的那个朴素截断版。一条对它
        // 声称要防的缺陷永远红不了的断言，正是本 suite 存在的理由在**测试自己身上**的复刻。
        //
        // 现在行尾挂一条**真注释**：`""` 若被误读成「开了一个没关的串」，那么这一行剩下的一切
        // （包括那个 `//`）都会被当成**字符串内容**照抄进 `code` —— 注释文本活下来，第二条断言
        // 当场红。这才是这条断言真正守的那个缺陷。
        let source = #"""
            let empty = ""; _ = write(lockFile: ClaudioPaths.playLockFile)  // 这句注释必须被剥掉
            """#
        let scanned = strippingComments(source)
        expect(
            scanned.code.contains("playLockFile"),
            "`\"\"` 的第二个引号必须闭合第一个（而不是开启一个新串，把后面全吞掉）。"
                + "得到：\(scanned.code)")
        expect(
            !scanned.code.contains("这句注释必须被剥掉"),
            "`\"\"` 之后那个 `//` 必须仍然被当成注释起点 —— 注释文本活下来 = 扫描器把 `\"\"` 误读成"
                + "「开了一个没关的串」，于是这一行剩下的代码与注释全被当成字符串内容照抄。"
                + "得到：\(scanned.code)")
    }

    suite("扫描器：块注释被剥掉（`/* … */` 里的代码不算代码）") {
        let source = #"""
            /* let dead = ClaudioPaths.playLockFile */ let alive = ClaudioPaths.configLockFile
            """#
        let scanned = strippingComments(source)
        expect(
            !scanned.code.contains("playLockFile"),
            "块注释里的东西不是代码。得到：\(scanned.code)")
        expect(
            scanned.code.contains("configLockFile"),
            "块注释**之后**的代码必须回来。得到：\(scanned.code)")
    }

    suite("扫描器：行结构保住（顺序断言靠它 —— notePanelHidden 必须在 guard 之前）") {
        // `ViewWiringSuite` 有一条断言比的是两个 `range(of:)` 的相对位置。剥注释时若把换行也吞掉，
        // 相对位置还在、但行号全乱；更糟的是把整段代码折成一行，`components(separatedBy:)` 的计数
        // 会跟着变。这条钉的是「剥的是注释，不是行」。
        let source = #"""
            first()  // 注释一
            // 整行注释
            second()
            """#
        let scanned = strippingComments(source)
        expect(
            scanned.code.components(separatedBy: "\n").count
                == source.components(separatedBy: "\n").count,
            "行数必须与原文一致（剥的是注释，不是行）。原文 "
                + "\(source.components(separatedBy: "\n").count) 行，得到 "
                + "\(scanned.code.components(separatedBy: "\n").count) 行")
        guard let first = scanned.code.range(of: "first"),
            let second = scanned.code.range(of: "second")
        else {
            expect(false, "两句代码都该在：\(scanned.code)")
            return
        }
        expect(first.lowerBound < second.lowerBound, "顺序不能乱")
    }

    // MARK: 「我不认识」清单 —— 枚举盲区 + 结构性失步兜底

    suite("扫描器：撞见 raw string 要**记一笔**，而不是安静地给出一份不可信的文本") {
        let source = #"""
            let pattern = ##"a//b"##
            """#
        let scanned = strippingComments(source)
        expect(
            !scanned.unmodeledConstructs.isEmpty,
            "扫描器不建模 raw string（它能含裸 `//`）。它必须自己说出来 —— 这张清单被两个 suite 各一条"
                + "断言盯着。不说 = 一份不可信的 `code` 被当成可信的，负向断言在上面假绿")
    }

    suite("扫描器：扩展 regex 字面量 `#/…/#` 也要记一笔（它能含裸 `//`）") {
        // `#/https://x/#` 是合法 Swift，而扫描器不建模它：那个 `//` 会被当成注释起点，吃掉整行。
        // 仓库现在一个都没有 —— 但「现在没有」正是上一版对 raw string 说过、然后被插值打脸的话。
        let source = #"""
            let matcher = #/https://claudio.dev/#
            _ = write(lockFile: ClaudioPaths.playLockFile)
            """#
        let scanned = strippingComments(source)
        expect(
            !scanned.unmodeledConstructs.isEmpty,
            "扫描器不建模扩展 regex 字面量。不记账 = 它安静地吃掉那一行，负向兜底更绿。"
                + "得到：\(scanned.unmodeledConstructs)")
    }

    suite("扫描器：`hasPrefix(\"#\")` **不是** raw string（守卫必须位置感知，否则它自己会假红）") {
        // 这条不是洁癖，它挡的是一整类「守卫因为无害改动而红 → 被下一个人删掉 → 洞原样回来」：
        // `ClaudioColorHex.swift` / `ContrastRatio.swift` 里真的有 `hasPrefix("#")`，
        // 它逐字包含 `#"`。一条纯文本的 `#"` 守卫会在这两个文件上当场假红。
        let source = #"""
            if hexString.hasPrefix("#") { hexString.removeFirst() }
            """#
        let scanned = strippingComments(source)
        expect(
            scanned.unmodeledConstructs.isEmpty,
            "字符串**里面**的 `#\"` 不是 raw string 起点 —— 只有**代码位置**的才是。"
                + "得到：\(scanned.unmodeledConstructs)")
        expect(
            scanned.code.contains("hasPrefix"),
            "这一行是正常代码，必须原样留下。得到：\(scanned.code)")
    }

    suite("扫描器：结构性失步要记一笔 —— **四个** note 站点各一条 fixture，一个都不许漏") {
        // 这是清单的**第 2 类**来源：不靠「我们想得到是什么构造」。
        //
        // ⚠️ 它**不是**万能网，别再让措辞比覆盖范围大：一次在**行内**就重新同步回来的失步逃得过它
        // （2f107b5 那个插值 bug 就是 —— 它靠行尾的 `\n` 关掉误开的 lineComment，扫完文件稳稳停在
        // 代码模式，EOF 检查一声不吭）。它挡的只是把状态机**带出这一行**的那一类。真正杀掉插值那个
        // 洞的是上面那几条**正向**断言，不是这一条。
        //
        // ⚠️⚠️ 第一版只覆盖了**四个 note 站点里的两个**（变异台账 M8 实测）：`unterminated
        // multi-line string` 与 `unterminated string interpolation` **零 fixture** —— 单删这两个
        // 分支，两个包 2776 条断言**一条都不会红**。suite 的名字写着「结构性失步要记一笔」，而它
        // 只钉住了一半。措辞比覆盖范围大，复发在杀它的那一刀里。现在四个站点各一条。
        func unmodeled(_ source: String) -> [String] {
            strippingComments(source).unmodeledConstructs
        }

        let unterminatedBlock = "/* 这个块注释没有关\n_ = write(lockFile: ClaudioPaths.playLockFile)\n"
        expect(
            !unmodeled(unterminatedBlock).isEmpty,
            "块注释没闭合 = 它后面的**所有代码**都被当成注释吃掉了，而负向兜底会因此全部假绿。"
                + "扫描器必须记一笔。得到：\(unmodeled(unterminatedBlock))")

        let unterminatedString = "let x = \"没关的串\n_ = write(lockFile: ClaudioPaths.playLockFile)\n"
        expect(
            !unmodeled(unterminatedString).isEmpty,
            "单行字符串里撞见**裸换行**，在合法 Swift 里不可能 —— 出现了就说明状态机已经被带偏。"
                + "得到：\(unmodeled(unterminatedString))")

        let unterminatedMultiline = "let x = \"\"\"\n没关的多行串\n_ = write(lockFile: ClaudioPaths.playLockFile)\n"
        expect(
            !unmodeled(unterminatedMultiline).isEmpty,
            "多行字符串没闭合 = 文件剩下的部分被整份当成字符串内容 —— 那份 `code` 不再可信。"
                + "扫描器必须记一笔。得到：\(unmodeled(unterminatedMultiline))")

        let unterminatedInterpolation = "let x = \"\\(compute(\n"
        expect(
            !unmodeled(unterminatedInterpolation).isEmpty,
            "插值没闭合（扫完文件插值栈还非空）= 状态机被带偏了，之后的模式判断全不可信。"
                + "扫描器必须记一笔。得到：\(unmodeled(unterminatedInterpolation))")
    }

    suite("扫描器：正常源码**不**记账（兜底不能假红 —— 假红的守卫会被删掉）") {
        // 上面那两条兜底若太敏感，它会在每一个正常文件上红，然后被下一个人删掉，洞原样回来。
        // 这条是它们的反向控制：一份用满了「插值 / 嵌套插值 / 转义 / 多行串 / 注释」的正常源码，
        // 清单必须是**空的**。
        let source = #"""
            /// doc: 见 https://claudio.dev/locks
            func describe(_ items: [String], base: String?) -> String {
                let joined = items.joined(separator: ", ")  // 行尾注释
                let url = "\(base ?? "https://claudio.dev")/locks"
                let quoted = "他说 \"你好\""
                let block = """
                    多行：\(joined) 与 \(url)
                    """
                /* 块注释里也写点 https://x//y */
                return "\(quoted)\(block)"
            }
            """#
        let scanned = strippingComments(source)
        expect(
            scanned.unmodeledConstructs.isEmpty,
            "这是一份**完全正常**的 Swift 源码（插值 / 嵌套插值 / 转义引号 / 多行串 / 两种注释都有）。"
                + "在它身上记账 = 兜底假红，两个 suite 的 unmodeled 守卫会在真实源文件上一起红，"
                + "然后被下一个人删掉。得到：\(scanned.unmodeledConstructs)")
        expect(
            scanned.code.contains("joined(separator:"),
            "正常代码必须原样活着。得到：\(scanned.code)")
        expect(
            !scanned.code.contains("块注释里也写点"),
            "块注释必须被剥掉。得到：\(scanned.code)")
    }

    // MARK: `codeWithoutStringLiterals` —— 字符串内容清空、界定符与插值代码保留
    //
    // ⚠️ 上一版这个字段的行为**只**由 helper 包的 `AtomicWriteSuite` suite ③ 钉着（`/codex review
    // 3af8d5f` 红队命中）。而它是**共享**扫描器的输出：gui 包里逐字节相同的那一份，`AtomicWriteSuite`
    // 不在那儿跑 —— 于是共享扫描器的这半个契约，在 gui 包里一条正向断言都没有。这个 suite 是**共享**
    // 的（跟着哨兵区块一起复制进两个包），所以现在两个包各自都钉住了它。

    suite("扫描器：`codeWithoutStringLiterals` 清空字符串**内容**、但界定符与插值里的代码原样留下") {
        // 字符串内容清空：里面的 `(` 不许把「按配平括号取实参」的扫描带偏（`"pack (1.json"` 那个 bug）。
        let paren = strippingComments(#"let p = f("pack (1.json", .atomic)"#)
        expect(
            !paren.codeWithoutStringLiterals.contains("pack (1.json"),
            "字符串**内容**必须清空。得到：\(paren.codeWithoutStringLiterals)")
        expect(
            paren.codeWithoutStringLiterals.filter { $0 == "(" }.count
                == paren.codeWithoutStringLiterals.filter { $0 == ")" }.count,
            "清空之后括号必须配平（串里那个 `(` 不能留下）。得到：\(paren.codeWithoutStringLiterals)")
        // 界定符保留：开闭引号是**代码位置**，去掉它们会让引号奇偶倒相。
        expect(
            paren.codeWithoutStringLiterals.filter { $0 == "\"" }.count == 2,
            "开闭引号（界定符）必须留下，只清内容。得到：\(paren.codeWithoutStringLiterals)")

        // 一句写着 `.write(to:` 的**散文串**不许变成调用点。
        let prose = strippingComments(#"let hint = "改成 data.write(to: f) 就好了""#)
        expect(
            !prose.codeWithoutStringLiterals.contains("write(to: f)"),
            "字符串里的散文清空后不能再像一处调用。得到：\(prose.codeWithoutStringLiterals)")

        // 插值 `\(…)` 里面是**代码**，不是内容 —— 清空字符串绝不能把它一起吃掉
        // （`/codex review 2f107b5` 那个 P1 的形状：一处藏在插值里的写调用永久隐身）。
        let interp = strippingComments(##"log("wrote \(write(lockFile: ClaudioPaths.playLockFile)) ok")"##)
        expect(
            interp.codeWithoutStringLiterals.contains("playLockFile"),
            "插值里的代码是代码，必须活着 —— 把它一起清空 = 藏在插值里的写调用永久隐身。"
                + "得到：\(interp.codeWithoutStringLiterals)")
        // 而插值**外面**的串内容仍要清掉。
        expect(
            !interp.codeWithoutStringLiterals.contains("wrote"),
            "插值外的字符串内容仍要清空。得到：\(interp.codeWithoutStringLiterals)")

        // 换行保留：行结构塌掉会让失败消息里的行号变成谎话。
        let multiline = strippingComments("let a = \"x\"\nlet b = \"y\"")
        expect(
            multiline.codeWithoutStringLiterals.contains("\n"),
            "换行必须留下（行号 = 失败消息的可读性）。得到：\(multiline.codeWithoutStringLiterals)")
    }

    // MARK: 两个包里的那一份，逐字相同 —— 这条不再是注释里的承诺

    suite("扫描器：两个测试包里的哨兵区块**逐字节相同**（`/codex review 2f107b5` 的 P2）") {
        // 扫描器是跨包**复制**的（两个 package 的测试可执行文件互相 import 不到）。上一版在
        // doc comment 里写着「与另一包里的那一份逐字相同」—— 而**没有任何东西执行这句话**。
        // 只改一份，两个包的 census 就会跑在不同的扫描器语义上，而注释仍然声称它们是同一份。
        //
        // ⚠️ 这条守的是**漂移**，不是**正确性**：两份被同样地改错，它照样绿（行为由上面那一批
        // 正向断言守）。别把它读成比它更大的东西。
        let helperPath = "helper/Tests/ClaudioCoreTests/TestSupport.swift"
        let guiPath = "gui/Tests/ClaudioGUICoreTests/TestSupport.swift"

        guard let helperRegion = sharedScannerRegion(of: helperPath),
            let guiRegion = sharedScannerRegion(of: guiPath)
        else {
            expect(
                false,
                "两份 TestSupport.swift 里都必须有 `claudio:shared-scanner:begin` / `:end` 哨兵 —— "
                    + "抽不出来 = 下面那条 `==` 会拿两个空串比出恒真，**又一条永远不会红的守卫**")
            return
        }

        // ⚠️ 正向控制，这条不能省：少了它，哨兵被改名 / 区块被清空会让两边同时抽到空串，
        //    下面的 `==` **恒真**。这正是本文件通篇在杀的那个形状。
        for (path, region) in [(helperPath, helperRegion), (guiPath, guiRegion)] {
            expect(
                region.contains("func strippingComments"),
                "\(path) 的哨兵区块里必须真的装着扫描器本体 —— 抽到的不是它，下面那条逐字节比较"
                    + "就是在比两坨无关的文本（或两个空串）")
            expect(
                region.contains("func enterInterpolation"),
                "\(path) 的哨兵区块里必须装着**插值**那一段 —— 它是 `/codex review 2f107b5` P1 的修复"
                    + "本体。抽到一个没有它的区块 = 比较的不是我们以为在比的东西")
        }

        // 失败消息报**第一处不同的那一行**，不是字符数。
        // 变异台账 M10 逮到的可用性缺陷：等长漂移（改个词、换个等长的变量名）下，只报字符数会打印出
        // 「helper 8587 字符 / gui 8587 字符」—— 两个**相同**的数字后面跟着「它们不一样」，读消息的人
        // 会先怀疑守卫本身有 bug，而不是去看漂移。一条让人读不懂的失败消息，和一条不会红的断言，
        // 在「下一个人会把它删掉」这件事上是等价的。
        let helperLines = helperRegion.components(separatedBy: "\n")
        let guiLines = guiRegion.components(separatedBy: "\n")
        var firstDifference = "（找不到不同的行 —— 两份只在行数上不同）"
        for offset in 0..<min(helperLines.count, guiLines.count)
        where helperLines[offset] != guiLines[offset] {
            firstDifference =
                "哨兵区块第 \(offset + 1) 行：\n"
                + "      helper: \(helperLines[offset])\n"
                + "      gui   : \(guiLines[offset])"
            break
        }
        expect(
            helperRegion == guiRegion,
            "两个包里的扫描器已经不一样了 —— 只改一份，两套 census 就跑在不同语义上，而各自的 doc "
                + "comment 仍然声称它们是同一份。第一处不同：\(firstDifference)\n"
                + "    （helper \(helperLines.count) 行 / gui \(guiLines.count) 行）。改一份 = 两份一起改")
    }

    // MARK: T3 并发绊线 —— manifest.json 唯一的并发安全保证是「全同步 + 全在 @MainActor」，
    // 不是锁（PLAN-SOUND-MANAGER.md §2.1：`grep -iE 'lock' ManifestBinding.swift` 是空的）。
    // 本计划会往 manifest.json 上加三个新写者（`clearEventBinding` / 未来的 `forkPack` /
    // `restoreFactoryPack`）和一个新 UI 面（管理窗口）—— 一次善意的 `async` 重构会让这条无锁的
    // 读-改-写在并发绑定/清除下静默丢更新，而且**没有任何运行时会报错**。这是这一批改动里
    // 唯一没有运行时防护的 critical gap（§4c「并发不变式」表格最后一行），这条源码绊线是它
    // **唯一**的守卫——不是写在文档里的一句话，是一条会响的东西。
    //
    // 这条绊线只属于 gui 包：`ManifestBinding.swift` / `PackFork.swift` 是 gui 侧文件，helper
    // 没有对应物，所以不进两包共享的哨兵区块（上面那条「逐字节相同」钉的是 `TestSupport.swift`
    // 里的扫描器本体，不是这个文件，两个包的 `SourceScannerSuite.swift` 允许在这类内容上分叉）。
    suite(
        "绊线（T3）：ClaudioGUICore 里**每个**经 mutateManifestJSON 的文件，其导出写函数不带已知并发 "
            + "token（黑名单，非完备）且逐个带 @MainActor；PackFork/PackRestore 未落地哨兵"
    ) {
        // 【纳入判据 —— 内容推导的围栏，不是路径白名单】
        //
        // 上一版（含本次修复的第一稿）是一份写死的**路径**清单。路径清单结构上不可能是围栏：
        // 任何一个 manifest 写者只要落在清单外的文件里，整条绊线一条断言都不跑，而且**没有
        // 任何东西认不出它**。这不是假想——`PLAN-SOUND-MANAGER.md:596` 白纸黑字把 T12 的
        // `restoreFactoryPack` 放在**新 `PackRestore.swift`** 里，而清单（和它上面那句自称
        // 守着 `forkPack` / `restoreFactoryPack` 的注释）只列了 `PackFork.swift`。措辞比覆盖
        // 范围大，第 N 次复发在自称治好它的那一刀里。
        //
        // 所以纳入判据改成**从内容推导**：`ClaudioGUICore`（**含任意深度子目录，递归枚举**）里
        // 任何一个 `.swift` 文件，只要它的代码（已剥注释）里出现 `mutateManifestJSON` —— T3 定下的
        // **唯一** manifest 读-改-写原语，所有写者都必须经它 —— 就自动纳入这条绊线。
        // `PackFork.swift`、`PackRestore.swift`、以及今天还没有人命名的第三个文件（哪怕它落在
        // `ClaudioGUICore/Feature/` 这样的子目录里 —— SwiftPM 照样编译它），落地那天自动被检查，
        // 不需要谁记得回来改一份清单。
        //
        // ⚠️ 枚举**必须递归**（`recursivelyEnumeratedSwiftFiles` 用 `enumerator` 下钻，不是
        // `contentsOfDirectory` 只读一层）：/codex review 327d211 的 P1 —— 非递归时一个落在子目录
        // 的 manifest 写者会被编译却漏出围栏，围栏对它静默为绿，正是这里自称的「任意 .swift」比实际
        // 覆盖范围大的又一次复发。今天 `ClaudioGUICore` 是平的，递归与否产出同一批文件，所以这条
        // 不靠真实布局背书 —— 下面「递归纳入自证有牙」那条 suite 拿一棵含嵌套 .swift 的临时树钉死
        // 它，改回非递归当场红。
        //
        // ⚠️ **已知限度**（写在这里，免得下一个人把它读成「不可能漏」）：**绕开原语**、自己
        // read-modify-write `manifest.json` 的写者不会被这条判据纳入。挡那一种的不是这里，是
        // 下面的哨兵组 + code review。这条围栏守的是「经原语的写者不许变并发」，不是「没有人
        // 能绕开原语」。
        let coreRelativeDirectory = "gui/Sources/ClaudioGUICore"
        let coreDirectoryURL = repoRoot().appendingPathComponent(coreRelativeDirectory)
        let coreSwiftFiles = recursivelyEnumeratedSwiftFiles(under: coreDirectoryURL)

        // 目录枚举本身不许静默失明：目录被改名/移走 → 枚举出空数组 → 下面「每个纳入的文件都
        // 得清白」对空集恒真。这条把那种失明变成红。
        expect(
            !coreSwiftFiles.isEmpty,
            "\(coreRelativeDirectory) 里一个 .swift 都没枚举到 —— 目录被改名/移走了，纳入判据"
                + "扫不到任何文件，整条绊线退化成对空集恒真。把目录路径更新到新位置。")

        var enrolledManifestWriterFiles: [(path: String, scanned: StrippedSwiftSource)] = []
        for entry in coreSwiftFiles {
            let relativePath = "\(coreRelativeDirectory)/\(entry.relativeSubpath)"
            guard let text = try? String(contentsOf: entry.url, encoding: .utf8) else {
                expect(
                    false,
                    "\(relativePath) 枚举得到却读不到 —— 纳入判据对它无从判起，它若是个 manifest "
                        + "写者就完全不设防。别让绊线在一次文件权限/编码问题上静默漏掉一个文件。")
                continue
            }
            let scanned = strippingComments(text)
            if scanned.code.contains("mutateManifestJSON") {
                enrolledManifestWriterFiles.append((relativePath, scanned))
            }
        }

        // 判据自身不许瞎：纳入集合空 = 「每个纳入的文件都得清白」对空集恒真，整条围栏是空话。
        // `mutateManifestJSON` 被改名、`strippingComments` 把代码吃光、`contains` 写反——任何
        // 一种都会走到这里。
        let enrolledPaths = enrolledManifestWriterFiles.map(\.path)
        expect(
            !enrolledPaths.isEmpty,
            "纳入判据一个 manifest 写者文件都没逮到 —— 判据瞎了（`mutateManifestJSON` 被改名？"
                + "剥注释把代码吃光了？`contains` 写反了？）。下面『每个纳入的文件都得清白』因此"
                + "是一句对空集的恒真绿，整条围栏形同虚设。")

        // 再钉一条**具名**的：今天已知的那个写者文件得在里面。
        //
        // ⚠️ 这条红的时候有**两种**成因，别只报一种（消息里两条都写上）：判据真瞎了，或者这个
        // 文件被合法改名了。后者不是 bug——内容围栏会自动跟着改名后的文件走（实测：改名成
        // `ManifestWriters.swift` 后它照样被纳入、照样受检），只是这条具名的钉子需要有人更新。
        // 一次改名理应让人回来重读这条绊线，所以这个红是有意保留的，但它的诊断必须诚实。
        expect(
            enrolledPaths.contains("\(coreRelativeDirectory)/ManifestBinding.swift"),
            "纳入结果里没有 ManifestBinding.swift。两种可能，请自行分辨：\n"
                + "  · 它被改名/移走了 —— 内容围栏已经自动跟上（实际纳入见下），**不是**漏检；"
                + "把这条具名钉子里的文件名更新过去即可。\n"
                + "  · 判据瞎了 —— 若『实际纳入』也是空的或明显不对，那是 `mutateManifestJSON` "
                + "被改名 / 剥注释吃光了代码。\n"
                + "实际纳入：\(enrolledPaths)")

        // 【哨兵组】守的是上面那条围栏**唯一**盖不住的那件事：新写者**绕开原语**。
        //
        // 这两个文件是计划点名的未来 manifest 写者（`PLAN-SOUND-MANAGER.md:743` 的 T6
        // `PackFork.swift` / `:596` 的 T12 `PackRestore.swift`）。今天正向断言它们**尚不存在**；
        // 落地当天这条哨兵变红，逼一个人回来**确认新写者确实经 `mutateManifestJSON`**——确认了，
        // 它就已经被上面的围栏自动纳入，这条哨兵删掉即可；没经原语，围栏漏得掉它，得在这里补。
        // 哨兵不重复围栏的工作，它守的正是围栏的盲区。
        let pendingManifestWriterPaths = [
            "\(coreRelativeDirectory)/PackFork.swift",
            "\(coreRelativeDirectory)/PackRestore.swift",
        ]
        for relativePath in pendingManifestWriterPaths {
            let fileURL = repoRoot().appendingPathComponent(relativePath)
            expect(
                !FileManager.default.fileExists(atPath: fileURL.path),
                "\(relativePath) 出现了 —— 计划点名的一个 manifest 新写者落地了。回来确认一件"
                    + "上面那条内容围栏**盖不住**的事：它是不是真的经 `mutateManifestJSON` 写 "
                    + "manifest？\n"
                    + "  · 是 → 它已被自动纳入（并发 token + @MainActor 两条腿都在跑），把这条路径"
                    + "从 `pendingManifestWriterPaths` 删掉即可。\n"
                    + "  · 否 → 它绕开了原语，围栏漏得掉它，manifest.json 的零锁读-改-写多了一个"
                    + "不设防的写者。要么让它经原语，要么在这里补一条针对它的检查。\n"
                    + "（PLAN-SOUND-MANAGER.md §2.1 / 4c「并发不变式」）")
        }

        for entry in enrolledManifestWriterFiles {
            let relativePath = entry.path
            let scanned = entry.scanned
            expect(
                scanned.unmodeledConstructs.isEmpty,
                "\(relativePath) 里出现了扫描器不认识的构造：\(scanned.unmodeledConstructs) —— "
                    + "下面几条负向断言会在一份不可信的『code』上跑，形同虚设")
            // 第一条腿：已知并发构造的黑名单（**不是**完备围栏，见 `bannedConcurrencyTokens`
            // 头上那段）。判据走共用的 `bannedConcurrencyHits` —— 下面那条自证有牙的 suite 拿
            // 手写的脏 fixture 喂的正是这同一个函数，所以它静默失灵会被逮到，不会退化成恒真绿。
            let concurrencyHits = bannedConcurrencyHits(in: scanned)
            expect(
                concurrencyHits.isEmpty,
                "\(relativePath) 的代码里出现了 \(concurrencyHits) —— manifest.json 今天零锁，"
                    + "唯一的并发安全保证是「全同步 + 全在 @MainActor」（PLAN-SOUND-MANAGER.md "
                    + "§2.1）。任何一个 manifest 写函数一旦变成 async / 派发任务 / 上队列 / 起线程，"
                    + "这条不变式会在没有任何运行时报错的情况下静默失效 —— 这条源码绊线是它唯一的"
                    + "守卫，得到的代码：\(scanned.code)")

            // 第二条腿（/codex review dcab3de,7e97bc4 的 P1）：上面三条负向断言挡「变异步」，
            // 挡不住「同步但脱离主 actor」——一个 `public func` 少写一个 @MainActor（或被人标了
            // `nonisolated`），任意后台线程就能同步调它，两个读-改-写交错、丢更新，零运行时报错。
            // 所以这里**正向**钉住：这些文件里每个导出写函数都必须 @MainActor 隔离。
            let exported = exportedPublicFuncNames(in: scanned.code)
            expect(
                !exported.isEmpty,
                "\(relativePath) 里一个 `public func` 都没枚举到 —— 枚举器瞎了，下面那条『每个都得 "
                    + "@MainActor』就退化成对空集恒真。得到的代码开头：\(scanned.code.prefix(200))")
            for name in exported where !hasMainActorIsolation(funcName: name, in: scanned.code) {
                expect(
                    false,
                    "\(relativePath) 的导出写函数 `\(name)` 没有 @MainActor 隔离 —— manifest.json 零锁，"
                        + "并发安全靠「全同步 + 全在 @MainActor」两条腿。少了 @MainActor（或被标 "
                        + "nonisolated），它就能被后台线程同步调用，两个读-改-写交错丢更新且零运行时"
                        + "报错。给它加回 @MainActor（PLAN-SOUND-MANAGER.md §2.1 / 4c「并发不变式」）。")
            }
        }
    }

    // 上面那条内容围栏的**递归枚举**自证有牙。今天 `ClaudioGUICore` 是平的，递归与非递归产出
    // 同一批文件 —— 真实布局给不了「递归确实在下钻」的任何背书，有人把
    // `recursivelyEnumeratedSwiftFiles` 改回 `contentsOfDirectory`（只读一层）时，真文件那条围栏
    // 一条断言都不会变。这条 suite 拿一棵**含嵌套子目录 .swift** 的临时树喂**同一个**枚举函数，
    // 正向钉死：嵌套文件必须被枚举到、相对子路径必须带子目录前缀。改回非递归 → 嵌套 fixture 消失
    // → 这条当场红（/codex review 327d211 的 P1：非递归漏掉 SwiftPM 会编译的子目录写者）。
    suite("绊线（T3）递归纳入自证有牙：子目录里的 .swift 必须被枚举到，相对路径带子目录前缀") {
        withTempDirectory { root in
            // 刻意嵌套的树：顶层一个、子目录一层一个、更深一层一个。非递归只看得见顶层那个。
            writeFixture(
                "@MainActor public func top() {}", to: root.appendingPathComponent("Top.swift"))
            writeFixture(
                "@MainActor public func nested() {}",
                to: root.appendingPathComponent("Feature/Nested.swift"))
            writeFixture(
                "@MainActor public func deep() {}",
                to: root.appendingPathComponent("Feature/Deep/Deeper.swift"))
            // 干扰项：一个非 .swift 文件、一个名字带 .swift 的**目录**。两者都不许混进来。
            writeFixture("not swift", to: root.appendingPathComponent("Feature/README.md"))
            try? FileManager.default.createDirectory(
                at: root.appendingPathComponent("Bogus.swift"), withIntermediateDirectories: true)

            let subpaths = recursivelyEnumeratedSwiftFiles(under: root).map(\.relativeSubpath)

            // 顶层那个必须在 —— 基本枚举没坏（对照组：这条即便非递归也绿）。
            expect(
                subpaths.contains("Top.swift"),
                "顶层 Top.swift 没被枚举到 —— 枚举器整个瞎了。实际：\(subpaths)")
            // 【关键腿】子目录里的必须在。改回 `contentsOfDirectory` → 这条消失、当场红。
            expect(
                subpaths.contains("Feature/Nested.swift"),
                "子目录里的 Feature/Nested.swift 没被枚举到 —— 枚举退回了非递归（`contentsOfDirectory` "
                    + "只读一层）。SwiftPM 会编译子目录源文件，一个落在那里的 manifest 写者会被围栏"
                    + "静默漏掉（/codex review 327d211 的 P1）。用 `enumerator` 递归。实际：\(subpaths)")
            // 递归不是只下钻一层：更深一层也得在。
            expect(
                subpaths.contains("Feature/Deep/Deeper.swift"),
                "更深一层的 Feature/Deep/Deeper.swift 没被枚举到 —— 递归只下钻了一层。实际：\(subpaths)")
            // 相对路径必须**带子目录前缀**，不能被拍平成 lastPathComponent —— 否则两个不同目录下的
            // 同名文件会撞车，围栏的诊断消息/具名钉子/哨兵路径全指错地方，子目录写者被报成像在顶层。
            expect(
                !subpaths.contains("Nested.swift") && !subpaths.contains("Deeper.swift"),
                "子目录文件的相对路径被拍平成了 lastPathComponent（丢了子目录前缀）。实际：\(subpaths)")
            // 非 .swift 文件不许纳入。
            expect(
                !subpaths.contains(where: { $0.hasSuffix("README.md") }),
                "非 .swift 文件混进来了。实际：\(subpaths)")
            // 名字带 .swift 的**目录**不许被当成源文件纳入 —— 否则真文件那步 `String(contentsOf:)`
            // 读它会失败，退化成假红。
            expect(
                !subpaths.contains("Bogus.swift"),
                "一个名字带 .swift 的目录被当成源文件纳入了 —— 会在读取那步假红。实际：\(subpaths)")
        }
    }

    // 上面那条**并发 token** 绊线自证有牙。缺了它，这条腿和 @MainActor 那条腿就不对称：
    // @MainActor 一直有合成控制（下面那条），而黑名单这条从落地起只有一次**手工**变异背书——
    // 手工变异不进 CI，判据明天静默失灵（token 拼错、`filter` 写反、`strippingComments` 把代码
    // 吃光）没有任何东西会响，真文件那条 `hits.isEmpty` 直接变成恒真绿。
    //
    // ⚠️ 脏 fixture 全部是**手写的字面量**，绝不由 `bannedConcurrencyTokens` 插值拼出来。
    // 拿清单自己去造输入，清单里写错的那一项（比如 `"asyncc"`）也会在 fixture 里原样出现、
    // 于是照样命中——那种「自证」是恒真的，正是本文件开头记着的那个病的又一次复发。
    suite("绊线（T3）并发 token 判据自证有牙：脏源码必须命中、清白必须放行、只在注释里提到不算") {
        // 正控：每一种并发写法都是独立手写的代码形状，并各自钉住**它自己那一个** token。
        //
        // （这些 fixture 只作为**文本**喂给扫描器，不参与编译，所以不要求可独立编译——形状取自
        // 真实写法即可。别把注释读成「这是能跑的代码」。）
        //
        // ⚠️ 断言是 `hits.contains(expected)`，**不是** `!hits.isEmpty`。后者太弱，会漏掉整整一类
        // 回归：`DispatchQueue.main.async { }` 这段 fixture 同时含 `DispatchQueue` **和** `async`，
        // 于是就算有人把 `DispatchQueue` 从清单里删掉，它也会靠 `async` 照样命中、照样绿 —— 那条
        // 「自证」只证明了「清单非空」，没证明「这一项还在」。逐项钉死才有每 token 的分辨力。
        //
        // `expected` 是照着 fixture 的意图**手写**的字面量，不是从 `bannedConcurrencyTokens` 取的
        // ——所以清单里某一项被写错（`"asyncc"`）时，对应 fixture 的 hits 会是空的、当场红。
        let dirtySamples: [(label: String, expected: String, source: String)] = [
            ("async 函数", "async", "@MainActor\npublic func writer() async { _ = 1 }"),
            ("Task 派发", "Task", "@MainActor\npublic func writer() { Task { _ = 1 } }"),
            (
                "DispatchQueue", "DispatchQueue",
                "@MainActor\npublic func writer() { DispatchQueue.main.async { _ = 1 } }"
            ),
            ("Thread", "Thread", "@MainActor\npublic func writer() { Thread.detachNewThread { _ = 1 } }"),
            (
                "OperationQueue", "OperationQueue",
                "@MainActor\npublic func writer() { OperationQueue.main.addOperation { } }"
            ),
            (".detached", ".detached", "@MainActor\npublic func writer() { let h = pool.detached; _ = h }"),
            (
                "withCheckedContinuation", "withCheckedContinuation",
                "@MainActor\npublic func writer() { _ = withCheckedContinuation { c in c.resume() } }"
            ),
            ("pthread", "pthread", "@MainActor\npublic func writer() { var t = pthread_t(); _ = t }"),
        ]
        for sample in dirtySamples {
            let scanned = strippingComments(sample.source)
            let hits = bannedConcurrencyHits(in: scanned)
            expect(
                hits.contains(sample.expected),
                "『\(sample.label)』这段脏源码必须命中 `\(sample.expected)` 这一项 —— 没命中 = 清单里"
                    + "这一项被删了/写错了，而真文件那条 `hits.isEmpty` 对这种并发写法就此恒真、"
                    + "整条「全同步」绊线对它是一句空话。实际命中：\(hits)，"
                    + "code：\(scanned.codeWithoutStringLiterals)")
        }

        // 配平围栏：清单里**每一个** token 都必须有一条属于自己的脏 fixture，反之亦然。
        //
        // 少了这条，上面那组逐项断言就只是一份**白名单**：明天有人往 `bannedConcurrencyTokens`
        // 里加第 9 个 token，不配 fixture 也全绿 —— 那一项拼没拼对、`strippingComments` 会不会
        // 把它吃掉，全无人验证，而它守的那种并发写法看着像「已经守住了」。认不出 ⇒ 红。
        //
        // 这条不构成自指：fixture 的 `source` 是手写的真实写法，配平只强制「每项都得有人举证」，
        // 举证本身仍由那段手写代码完成。
        expect(
            Set(dirtySamples.map(\.expected)) == Set(bannedConcurrencyTokens),
            "并发 token 清单与脏 fixture 没配平 —— 每个 token 必须有一条手写 fixture 证明它真的"
                + "会命中，否则那一项是没有任何控制的白名单条目。\n"
                + "  只在清单里、没有 fixture：\(Set(bannedConcurrencyTokens).subtracting(dirtySamples.map(\.expected)).sorted())\n"
                + "  只在 fixture 里、不在清单：\(Set(dirtySamples.map(\.expected)).subtracting(bannedConcurrencyTokens).sorted())")

        // 空集正控（对照 @MainActor 那条腿的 `exported.isEmpty`）：判据不许恒命中。
        // 恒命中 = 真文件永远假红 → 下一个人把整条绊线删掉，洞比现在更大。
        let clean = strippingComments("@MainActor\npublic func writer(x: Int) { _ = x }")
        expect(
            bannedConcurrencyHits(in: clean).isEmpty,
            "清白的同步写函数必须放行 —— 恒命中 = 真文件永远假红，绊线会被下一个人删掉。"
                + "得到命中：\(bannedConcurrencyHits(in: clean))")

        // 剥注释这一步必须真的发生：`ManifestBinding.swift` 的 doc comment 里白纸黑字写着
        // 「一条禁 async/Task/DispatchQueue」（它在描述这条绊线本身）。不剥注释，真文件当场假红。
        // 这条把「真文件今天为什么是绿的」钉成断言，而不是一个碰巧。
        let commentOnly = strippingComments(
            "/// 这条绊线禁 async / Task / DispatchQueue。\n@MainActor\npublic func writer() { _ = 1 }")
        expect(
            bannedConcurrencyHits(in: commentOnly).isEmpty,
            "只在注释里**谈论** async/Task/DispatchQueue 不算并发代码 —— 判成命中 = 真文件因为"
                + "自己的 doc comment 假红。得到命中：\(bannedConcurrencyHits(in: commentOnly))"
                + "，code：\(commentOnly.code)")
    }

    // 上面那条 @MainActor 绊线自证有牙：@MainActor 缺失 / 存在 / 挂在**别的**函数上，三种情形
    // `hasMainActorIsolation` 都要分辨对。少了这条合成控制，`hasMainActorIsolation` 一旦恒真（比如
    // 正则写错、恒返回 non-nil），真文件那条 for 循环永远不进 body，整条绊线就是一句恒真绿。
    suite("绊线（T3）@MainActor 检查自证有牙：缺失→未隔离、存在→已隔离、隔壁函数的不算数") {
        let missing = strippingComments("public func writerWithout(x: Int) { _ = x }")
        expect(
            exportedPublicFuncNames(in: missing.code) == ["writerWithout"],
            "枚举器必须逮到这个 public func。得到：\(exportedPublicFuncNames(in: missing.code))")
        expect(
            !hasMainActorIsolation(funcName: "writerWithout", in: missing.code),
            "没有 @MainActor 的 public func 必须被判为『未隔离』—— 判成 true = 真文件那条 for 循环"
                + "永远不进 body，整条 @MainActor 绊线恒真。得到 code：\(missing.code)")

        let present = strippingComments("@MainActor\npublic func writerWith(x: Int) { _ = x }")
        expect(
            hasMainActorIsolation(funcName: "writerWith", in: present.code),
            "带 @MainActor 的 public func 必须被判为『已隔离』—— 判成 false = 真文件永远假红，"
                + "然后被下一个人删掉。得到 code：\(present.code)")

        // `public static func` / `public final func` —— 红队实测逃过旧版枚举器的那两个形态
        // （旧版只逐字捞 `public func `，一个不带 @MainActor 的 `public static func` 写者塞进
        // ManifestBinding.swift，2099 条断言全绿）。枚举器必须捞到它们，隔离检查必须两侧对齐。
        let staticNaked = strippingComments("public static func staticWriter() { _ = 1 }")
        expect(
            exportedPublicFuncNames(in: staticNaked.code) == ["staticWriter"],
            "`public static func` 必须被枚举到 —— 捞不到 = 这个形状的写者对整条 @MainActor 腿隐身，"
                + "而它正是「同步但脱离主 actor」那个 critical gap 的确切形状。"
                + "得到：\(exportedPublicFuncNames(in: staticNaked.code))")
        expect(
            !hasMainActorIsolation(funcName: "staticWriter", in: staticNaked.code),
            "没有 @MainActor 的 `public static func` 必须判为『未隔离』。得到 code：\(staticNaked.code)")

        let staticIsolated = strippingComments(
            "@MainActor\npublic static func staticSafe() { _ = 1 }")
        expect(
            hasMainActorIsolation(funcName: "staticSafe", in: staticIsolated.code),
            "带 @MainActor 的 `public static func` 必须判为『已隔离』—— 判成 false = 每一个 static "
                + "写者都假红，绊线会被下一个人删掉。得到 code：\(staticIsolated.code)")

        let finalIsolated = strippingComments(
            "@MainActor\npublic final func finalSafe() { _ = 1 }")
        expect(
            exportedPublicFuncNames(in: finalIsolated.code) == ["finalSafe"]
                && hasMainActorIsolation(funcName: "finalSafe", in: finalIsolated.code),
            "`public final func` 两侧都得认。得到：\(exportedPublicFuncNames(in: finalIsolated.code))")

        // 反向：`public` 与 `func` 之间**隔着一个声明**（含标点）时绝不能误配。
        // 误配 = 一个非 public 的 func 被当成导出写者，绊线开始对私有实现细节假红。
        let notExported = strippingComments("public struct Box { func hidden() { _ = 1 } }")
        expect(
            exportedPublicFuncNames(in: notExported.code).isEmpty,
            "`public struct` 之后的**非 public** func 不许被算成导出写函数 —— `{` 是标点，修饰符 run "
                + "跨不过去。误算 = 绊线对私有实现假红。得到：\(exportedPublicFuncNames(in: notExported.code))")

        // 关键反例：@MainActor 挂在**上一个**函数上，中间隔着一个含 `{}` 的函数体，绝不能被算到
        // 下一个裸函数头上。误算 = 少写 @MainActor 的写函数从这个缝里溜过绊线。
        let crossTalk = strippingComments(
            "@MainActor\npublic func isolated() {}\npublic func naked() {}")
        expect(
            hasMainActorIsolation(funcName: "isolated", in: crossTalk.code),
            "`isolated` 自己带 @MainActor，必须判为已隔离。得到 code：\(crossTalk.code)")
        expect(
            !hasMainActorIsolation(funcName: "naked", in: crossTalk.code),
            "`naked` 自己没有 @MainActor —— 前一个函数的 @MainActor 隔着一个函数体（含 `{}`），不许"
                + "被算到它头上。误算 = 少写 @MainActor 的写函数溜过绊线。得到 code：\(crossTalk.code)")
    }
}
