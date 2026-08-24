import Foundation

struct TestProcessResult {
    let status: Int32
    let output: String
}

func guiTestRepositoryRoot(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

func runTestProcess(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL? = nil,
    environmentOverrides: [String: String] = [:]
) -> TestProcessResult {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectoryURL
    var environment = ProcessInfo.processInfo.environment
    environment.merge(environmentOverrides) { _, new in new }
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return TestProcessResult(status: -1, output: error.localizedDescription)
    }
    let output =
        String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return TestProcessResult(status: process.terminationStatus, output: output)
}

// The scanner support below mirrors `helper/Tests/ClaudioCoreTests/TestSupport.swift` — duplicated
// rather than shared across packages because each package's test executable is private to its own
// build. The process helpers above are GUI-harness-only support for release contract suites.

// MARK: - 源码扫描器：剥注释，**但认识字符串字面量**
//
// ## 它替掉的那个东西（`/codex review be332ff` 的 P2，三处独立命中）
//
// 本仓库有两套读源码的文本绊线（`LockSeparationSuite` 读 `helper/Sources`、`ViewWiringSuite` 读
// `gui/Sources` 的两个 target），它们的兜底**全是负向断言**（`!contains("playLockFile")`、
// `count == N`）。所以「分析文本里少了一段代码」这件事，只会让它们**更绿** —— 这是这两套绊线
// 唯一的、共同的致命失效模式。
//
// 上一版的剥注释函数在**每行第一个 `//`** 处无条件截断。于是一句
//
// ```swift
// let hint = "锁的说明见 https://claudio.dev/locks"; _ = write(…, lockFile: ClaudioPaths.playLockFile)
// ```
//
// 会被剪成 `let hint = "锁的说明见 https:` —— 该行剩下的**代码**在分析文本里根本不存在。
//
// `be332ff` 只给 helper 那一半配了守卫（「不许出现 `://`」），而且那条守卫**恒真**：它写的是
// `!codeOnly(path).contains("://")`，而 `codeOnly` 正是那个会在 `//` 处截断的函数 —— `://` 自带
// `//`，到达断言之前就已经被剪成 `https:`。GUI 这一半**连那条恒真的守卫都没有**：新增的
// `ClaudioGUICore` 普查（不许出现 `play.lock`）与 ClaudioGUI 的锁普查，被同一类行内 URL 一穿而过。
//
// 现在两个包共用同一个**位置感知**的小状态机（代码 / 行注释 / 块注释 / 单行字符串 / 多行字符串
// / **插值栈**），字符串字面量里的 `//` 不再是注释起点，两半的洞一起堵上。
//
// ## 而 `2f107b5` 那一版**只堵对了一半**（`/codex review 2f107b5` 的 P1）
//
// 它不建模**字符串插值**，于是插值里嵌套字符串的 `"` 被当成外层串的结尾，状态机倒相，串内 URL 的
// `//` 又成了注释起点 —— 同一个截断、同一个「锁永久隐身」，而 `unmodeledConstructs` **是空的**，
// 两个包的守卫全程沉默。它在 doc comment 里自称「知道自己不认识什么」，而那张清单当时只认得
// raw string 一样东西。**措辞比覆盖范围大，复发在自称已经治好它的那一刀里。**
//
// 完整推理见 `helper/Tests/ClaudioCoreTests/TestSupport.swift` 里同一节（含「为什么不是把 ban
// 挪到 raw source」，以及这张清单**兜不住什么**）。扫描器本体在下面的哨兵区块里，两包逐字相同，
// 由 `SourceScannerSuite` 逐字节强制。

// claudio:shared-scanner:begin
//
// ⚠️ 到 `claudio:shared-scanner:end` 为止的这一段，在**两个测试包里逐字相同**，而且这句「逐字相同」
// 不再是一句注释里的承诺 —— `SourceScannerSuite` 最后一条 suite 把两份文件读进来**逐字节比**
// （并且先正向断言自己确实抽到了那段扫描器，否则「两个空串相等」又是一条恒真守卫）。
// 改这里 = 两份一起改，否则那条 suite 当场变红。

/// 一份 Swift 源码**剥掉注释**之后的样子，外加一张「扫描器知道自己没读懂」的清单。
struct StrippedSwiftSource {
    /// 注释已剥掉、**字符串字面量原样保留**的代码文本。
    let code: String

    /// 注释已剥掉，且**字符串字面量的内容也已清空**（界定符 `"` / `"""` 保留、换行保留、
    /// **插值 `\(…)` 里的代码原样保留** —— 那本来就是代码，不是字符串内容）。
    ///
    /// ## 为什么需要第二路输出：`code` 里的字符串会把**按括号配平**的扫描带偏
    ///
    /// `AtomicWriteSuite` 要按配平括号取 `.write(…)` 的实参（按行取会漏掉每一次跨行调用）。
    /// 而 `code` 保留字符串内容，于是一句合法 Swift
    ///
    /// ```swift
    /// try data.write(to: dir.appendingPathComponent("pack (1.json"), options: .atomic)
    /// ```
    ///
    /// 里那个**字符串里的** `(` 会被计进深度，括号从此永不配平：这次**合法的原子写**被判成
    /// 「读不懂的写调用」当场假红，而扫描器还会 `break` 掉这个文件**剩下的每一处**写调用 ——
    /// 假红有人喊，被 `break` 吞掉的那些**没有人看得见**（`/codex review 3af8d5f` 实测）。
    ///
    /// 同一路输出也顺手关掉第二个洞：`code` 里一句**散文**（错误消息、doc 里的示例串）只要写着
    /// `.write(to:` 就会被当成调用点。清空串内容之后，它不再是。
    ///
    /// ⚠️ 它**不**替代 ``code``：需要看字符串**内容**的断言（hook 命令逐字、URL 白名单）必须继续
    /// 读 `code`。这一路只给「我要看**代码结构**，不要看字符串里写了什么」的扫描用。
    let codeWithoutStringLiterals: String

    /// 扫描器**已知自己没能正确读懂**的地方。非空 = `code` 不再可信：基于它的**负向**断言
    /// （`!contains`、`count == N`）都可能假绿 —— 一段消失的代码只会让它们更绿，这是两套源码
    /// 绊线唯一的、共同的致命失效模式。
    ///
    /// 两类来源，性质完全不同，必须分清楚：
    ///
    /// 1. **枚举出来的盲区** —— raw string（`#"…"#`）与扩展 regex 字面量（`#/…/#`）。两者都**能**
    ///    含有裸 `//`，而扫描器不建模它们。按**词法位置**记：只有**代码位置**的 `#"` 才算，
    ///    `hasPrefix("#")` 里的那个不算（`ClaudioColorHex.swift` / `ContrastRatio.swift` 里真有这
    ///    一行 —— 一条纯文本的 `#"` 守卫会在它们身上假红，然后被下一个人删掉，洞原样回来）。
    ///
    /// 2. **结构性失步** —— 扫完整份文件之后没有回到代码模式（块注释 / 多行字符串 / 插值没闭合），
    ///    或在单行字符串里撞见**裸换行**（合法 Swift 里不可能）。这一类不需要事先知道「是什么构造
    ///    把状态机带偏了」。
    ///
    /// ## ⚠️ 这张清单**不是**万能网，别再让措辞比覆盖范围大
    ///
    /// 第 1 类是白名单，而**白名单永远是不完整的** —— `/codex review 2f107b5` 的 P1 正是这么来的：
    /// 上一版只枚举了 raw string，于是 `"\(f("https://x"))"`（插值里嵌套字符串）把状态机带倒相、
    /// 吃掉一整行代码，却**一笔都不记**，两个 suite 的守卫全程沉默。
    ///
    /// 第 2 类看起来像是能兜住「所有想不到的构造」，**它兜不住**：一次在**行内**就重新同步回来的
    /// 失步逃得过它（上面那个插值 bug 就是——它靠行尾的 `\n` 把误开的 lineComment 关掉，扫完文件
    /// 稳稳停在代码模式，EOF 检查一声不吭）。它挡的只是把状态机**带出这一行**的那一类。
    ///
    /// 真正杀掉插值那个洞的是**把插值建模对**，外加 `SourceScannerSuite` 里钉死它的**正向**断言。
    /// 这张清单是兜底，不是主力。
    let unmodeledConstructs: [String]
}

/// `source` 剥掉注释之后的样子。**字符串字面量里的 `//` 不是注释起点。**
///
/// 位置感知的小状态机：代码 / 行注释 / 块注释 / 单行字符串 / 多行字符串，外加一个**插值栈**
/// （`\(…)` 里面是**代码**，可以嵌套，可以含嵌套字符串字面量）。
///
/// 它的每一条行为都由 `SourceScannerSuite` 喂**合成输入**做**正向**断言钉死 —— 所以它不可能像
/// 它替掉的那条 `!codeOnly(path).contains("://")` 守卫一样退化成恒真式（那条守卫读的是**被它守的
/// 那个函数**截断之后的文本，`://` 自带 `//`，到达断言之前早就被剪成 `https:` 了）。
func strippingComments(_ source: String) -> StrippedSwiftSource {
    enum Mode { case code, lineComment, blockComment, string, multilineString }

    var mode: Mode = .code
    var blockDepth = 0
    /// 插值栈。每进一层 `\(` 压一帧：闭合之后该回到哪个模式，以及**已经进入**的括号深度。
    /// 必须是栈而不是布尔 —— `"\(a("\(b)"))"` 是合法 Swift。
    var interpolations: [(returnMode: Mode, parenDepth: Int)] = []
    var code = ""
    /// ``StrippedSwiftSource/codeWithoutStringLiterals`` —— 与 `code` **同一趟**扫出来，不是第二台
    /// 扫描器。第二台扫描器会漂移，而漂移的那一半是**没有人在看**的那一半。
    ///
    /// 规则只有一条：**处在代码位置的字符进 `blanked`，处在字符串内容位置的不进。** 界定符
    /// （`"` / `"""`）是代码位置（它们界定的是结构），插值里的一切也是（那是代码），换行无条件保留
    /// （行结构塌掉会让失败消息里的行号变成谎话）。
    var blanked = ""
    var unmodeled: [String] = []
    var index = source.startIndex

    func upcoming(_ needle: String) -> Bool { source[index...].hasPrefix(needle) }
    func advance(_ distance: Int) {
        index =
            source.index(index, offsetBy: distance, limitedBy: source.endIndex) ?? source.endIndex
    }
    func note(_ construct: String) {
        if !unmodeled.contains(construct) { unmodeled.append(construct) }
    }
    /// `\(` —— 插值表达式**是代码**，不是字符串内容。
    ///
    /// 不建模它的代价（`/codex review 2f107b5` 的 P1，实测）：插值里嵌套字符串的那个 `"` 会被当成
    /// **外层串的结尾**，状态机当场倒相回代码模式，紧接着串内 URL 的 `//` 就成了「注释起点」——
    /// 一行 `let h = "\(f("https://x"))"; _ = write(lockFile: ClaudioPaths.playLockFile)` 被剪成
    /// `let h = "\(f("https:`，那句锁**永久隐身**，而负向兜底只会更绿。
    func enterInterpolation(returningTo returnMode: Mode) {
        interpolations.append((returnMode: returnMode, parenDepth: 0))
        mode = .code
        code += "\\("
        // `blanked` 也要吃这个 `(` —— 它的配平 `)` 会在下面的代码模式里被写进去。少写这个 `(`
        // 而多写那个 `)`，`blanked` 的括号就永久欠平，按括号取实参的扫描会从此读串。
        blanked += "\\("
        advance(2)
    }

    while index < source.endIndex {
        let character = source[index]
        switch mode {
        case .code:
            // 插值内部：数括号，数到配平的那个 `)` 就回到把我们送进来的那个字符串。
            // 字符串**里**的括号不参与计数 —— 状态机天然做到（那时 mode 是 .string）。
            if !interpolations.isEmpty {
                if character == "(" {
                    interpolations[interpolations.count - 1].parenDepth += 1
                    code.append(character)
                    blanked.append(character)
                    advance(1)
                    continue
                }
                if character == ")" {
                    if interpolations[interpolations.count - 1].parenDepth == 0 {
                        mode = interpolations.removeLast().returnMode
                    } else {
                        interpolations[interpolations.count - 1].parenDepth -= 1
                    }
                    code.append(character)
                    blanked.append(character)
                    advance(1)
                    continue
                }
            }
            // 两个**枚举出来的**盲区。都在代码位置认，都能含裸 `//`，都记一笔然后按普通字符往下走
            // （反正那条守卫已经红了，这之后的 `code` 本来就不该被信）。
            if upcoming("#\"") {
                note("raw string literal (#\"…\"#)")
                code.append(character)
                blanked.append(character)
                advance(1)
                continue
            }
            if upcoming("#/") {
                note("extended regex literal (#/…/#)")
                code.append(character)
                blanked.append(character)
                advance(1)
                continue
            }
            if upcoming("\"\"\"") {
                mode = .multilineString
                code += "\"\"\""
                blanked += "\"\"\""
                advance(3)
                continue
            }
            if upcoming("//") {
                mode = .lineComment
                advance(2)
                continue
            }
            if upcoming("/*") {
                mode = .blockComment
                blockDepth = 1
                advance(2)
                continue
            }
            // 开引号是**代码位置**（它界定结构），所以它进 `blanked`；从下一个字符起才是「内容」。
            if character == "\"" { mode = .string }
            code.append(character)
            blanked.append(character)
            advance(1)

        case .lineComment:
            // 换行**保留**：行结构不能塌，否则 `range(of:)` 那几条顺序断言（notePanelHidden 必须在
            // `guard NSApp.isActive` 之前）读到的相对位置就不再是源码里的相对位置。
            if character == "\n" {
                mode = .code
                code.append(character)
                blanked.append(character)
            }
            advance(1)

        case .blockComment:
            if upcoming("/*") {
                blockDepth += 1
                advance(2)
                continue
            }
            if upcoming("*/") {
                blockDepth -= 1
                advance(2)
                if blockDepth == 0 {
                    mode = .code
                    // 块注释在 Swift 里是**分词符**，不是零宽的。整段删掉会把它两侧的 token
                    // **粘起来**：`public/* MARK */func f()` 剥完变成 `publicfunc f()`，于是
                    // `\bfunc` 的词边界没了，两台识别器**同时**看不见这个声明 —— 差额为 0，
                    // 围栏全绿。红队实测确认（`/codex review 48cbc07` 后那轮，CommentGlue.swift
                    // 零 finding）。补一个空格还原分词，行数与行内顺序都不变（顺序断言读的是
                    // 相对位置，插一个空格不影响谁在谁前面）。
                    code.append(" ")
                    blanked.append(" ")
                }
                continue
            }
            if character == "\n" {
                code.append(character)
                blanked.append(character)
            }
            advance(1)

        case .string:
            // `\(` 必须在转义对之前认 —— 但 `\\(` **不是**插值：那是「转义反斜杠」+ 左括号，
            // `upcoming("\\(")` 在 `\\` 上不成立（头两个字符是 `\` `\`），于是它正确地落到下面的
            // 转义对里，整对吞掉，`(` 留在串内。
            if upcoming("\\(") {
                enterInterpolation(returningTo: .string)
                continue
            }
            code.append(character)
            if character == "\\" {
                // 转义序列：`"\"//\""` 里那个 `\"` **不**结束字符串。整对一起吞掉。
                // `blanked` 一个字都不吃：转义对是字符串**内容**，那个 `\"` 尤其不是界定符 ——
                // 把它当界定符写进去，`blanked` 的引号就会奇偶倒相。
                advance(1)
                if index < source.endIndex {
                    code.append(source[index])
                    advance(1)
                }
                continue
            }
            if character == "\"" {
                // 闭引号：界定符，进 `blanked`（内容不进）。
                blanked.append(character)
                mode = .code
                advance(1)
                continue
            }
            if character == "\n" {
                // 合法 Swift 的单行字符串不含裸换行 —— 走到这里 = 已经有某个没建模的构造把状态机
                // 带偏了。收手回代码模式（别把文件剩下的部分整份当字符串吞掉），并且**记一笔**。
                note("unterminated single-line string literal")
                blanked.append(character)
                mode = .code
                advance(1)
                continue
            }
            // 字符串**内容** —— `blanked` 里什么都不留。这一行就是「括号被字符串带偏」那个 bug
            // 的整个修复（`"pack (1.json"` 里的 `(` 到不了 `blanked`）。
            advance(1)

        case .multilineString:
            if upcoming("\\(") {
                enterInterpolation(returningTo: .multilineString)
                continue
            }
            if character == "\\" {
                code.append(character)
                advance(1)
                if index < source.endIndex {
                    code.append(source[index])
                    advance(1)
                }
                continue
            }
            if upcoming("\"\"\"") {
                mode = .code
                code += "\"\"\""
                blanked += "\"\"\""
                advance(3)
                continue
            }
            // 多行串里的换行**留着**（行结构 = 失败消息里的行号）；其余内容一律不留。
            if character == "\n" { blanked.append(character) }
            code.append(character)
            advance(1)
        }
    }

    // 收尾（结构性失步兜底，见 ``StrippedSwiftSource/unmodeledConstructs`` 的第 2 类 —— 连同那里
    // 写明的**它兜不住什么**）。合法 Swift 文件扫完必须停在代码模式，插值 / 块注释全部闭合。
    switch mode {
    case .code:
        break
    case .lineComment:
        // 文件以行注释收尾、且没有末尾换行 —— 合法，不是失步。
        break
    case .blockComment:
        note("unterminated block comment (/* …)")
    case .string:
        note("unterminated single-line string literal")
    case .multilineString:
        note("unterminated multi-line string literal (\"\"\" …)")
    }
    if !interpolations.isEmpty {
        note("unterminated string interpolation (\\( …)")
    }

    return StrippedSwiftSource(
        code: code, codeWithoutStringLiterals: blanked, unmodeledConstructs: unmodeled)
}

/// `source` 里每一处 `head(` 调用的**实参文本**（从左括号后到与之配平的右括号前）。
///
/// ## 为什么不能只数全文件的出现次数（`/codex review 840ea37` 的 P1）
///
/// 计数**不绑定调用点**。「`configLockFile` 出现 2 次、`settingsLockFile` 出现 1 次」这三条计数
/// 断言，被下面这个**成对交换**整体满足 ——
///
/// ```swift
/// switch selectPack(…, lockFile: environment.settingsLockFile)
/// switch installClaudioHooks(…, lockFile: environment.configLockFile)
/// ```
///
/// —— 总数仍是 2 config / 1 settings / 0 play，**全绿**，而接管路径在生产上两把锁全串了。
/// 上一版的措辞（「调用点**确实转发** SetupEnvironment 的锁」）比它实际守的范围（「数得对」）大。
/// 锁必须**按调用点**绑。
///
/// `head` 有子串碰撞风险时要把上下文一起传（`"switch installClaudioHooks"`）：
/// `uninstallClaudioHooks(` **逐字包含** `installClaudioHooks(`，光传函数名就会被一个 uninstall
/// 调用满足。头由 `head(` 锚、尾由配平括号锚，两头锁死。
///
/// ## 极性：识别范围只许放宽，收窄就是 fail-open（`/codex review ceae86e` 的 P1）
///
/// 这个扫描器交出来的站点集合，下游是拿「**每一处**都必须转发对」去遍历的。所以：
///
/// * **多认一处** → 多查一处 → 最坏是误报（有人喊），fail-**closed**；
/// * **少认一处** → 那一处静默退出审查 → 真实构造可以随便写，fail-**open**，没有人会喊。
///
/// 上一版只认裸 `head(` 这**一种**构造形式，于是下面这些**全部编译得过、全部隐身**（实测五种，
/// 喂逐字照抄的本函数，识别出 **0** 处）：
///
/// ```swift
/// let a: SetupEnvironment = .init(…)            // 类型标注 + 上下文 .init
/// performFirstRunSetup(environment: .init(…))   // 实参位置的上下文 .init
/// let c = SetupEnvironment.init(…)              // 类型名在，但后面是 `.` 不是 `(`
/// let d = SetupEnvironment (…)                  // 中间一个空格
/// typealias SE = SetupEnvironment; SE(…)        // 别名
/// ```
///
/// `!calls.isEmpty` 那条兜底本来是把它做成**围栏**（认不出⇒红）的那一半，但它只要求「≥1 处」，
/// 于是一个死代码诱饵（`DecoySetupEnvironment(…)`，写得完全合规）就能把它喂饱，真实构造走上面
/// 任意一种形式隐身而去。左词边界杀死诱饵**替身**那一路；诱饵本身则由调用方的**精确计数**
/// （`count == N`，不再是 `!isEmpty`）当场逮住。
///
/// ## 空格形式已经认得，剩下的两类交给围栏（`/codex review 37745f2` 的 P1）
///
/// 上一版把「`SetupEnvironment (` 的空格形式、`typealias` 别名形式**仍然认不出**」如实写进了这段
/// doc，然后声称「真正兜住这一整类的是**行为测试**」。那句话是**假的**，Codex 逐字证了：一个
/// 死代码诱饵喂饱 `!calls.isEmpty`，真实构造改走 `typealias SE = SetupEnvironment; SE(…)` 之后
/// **文本层零覆盖**；再让它的实参从注入值**派生**出来（当时的 fixture 算得出），**行为层也全绿**。
/// 两条腿同时被拆掉 —— 一条被 doc 记录在案的洞，不会因为被记录而变成有人看守。
///
/// 所以这一刀两头都动：
///
/// * 空格形式（`head (…)`、`head .init (…)`）**直接认**（下面跳空白那一段）——单调放宽，fail-closed；
/// * `typealias` / 上下文推断的 `.init(` / `#if` 这些本函数**结构上**认不出的，交给
///   ``unmodeledConstructionShapes(of:in:)`` 记账，由调用方断言它为空 ——「认不出 ⇒ 红」。
///
/// 白名单永远不完整，所以**别再靠扩充白名单求完整**：完整性由那个围栏兜，本函数只管认得越多越好。
///
/// ⚠️ 必须喂 ``StrippedSwiftSource/codeWithoutStringLiterals``，不能喂 ``StrippedSwiftSource/code``：
/// 后者保留字符串**内容**，一句 `"pack (1.json"` 里的 `(` 会被计进深度、括号从此永不配平 ——
/// 那个洞的完整代价记在 `codeWithoutStringLiterals` 自己的 doc 里。
func callArguments(of head: String, in source: String) -> [String] {
    var calls: [String] = []
    var cursor = source.startIndex
    while let hit = source.range(of: head, range: cursor..<source.endIndex) {
        cursor = hit.upperBound
        // **左词边界**：命中前一个字符若是标识符字符，这不是对 `head` 的调用，而是某个
        // **以它结尾**的更长标识符 —— `DecoySetupEnvironment(` 逐字包含 `SetupEnvironment(`。
        // 那正是喂饱 `!calls.isEmpty` 的死代码诱饵（真实构造改走 `.init` 之类扫描器认不出的
        // 形式，诱饵替它背书，三条断言全绿）。
        //
        // ⚠️ **只排字母/数字/下划线，绝不排 `.`**。`ClaudioCore.SetupEnvironment(` 是一次
        // **真实**的限定构造，把它排掉 = 把一处构造点移出审查 = 下游那条「**每一处**都必须转发对」
        // 的循环少查一处 = fail-**open**。这条极性与直觉相反，写在这里免得下次被「顺手收紧」。
        if hit.lowerBound > source.startIndex,
            let previous = source[..<hit.lowerBound].last,
            previous.isLetter || previous.isNumber || previous == "_"
        {
            continue
        }
        // 右词边界 + 空格形式：`head` 与 `(` 之间允许空格 / tab，中间允许一个 `.init`。
        // 认得的四种：`head(`、`head (`、`head.init(`、`head .init (`。
        //
        // ⚠️ 只跳**同行**空白，不跳换行：Swift 里 `Foo\n(x)` 不是一次调用（那是两条语句），
        // 把换行也跳过去会开始把「一个裸类型名」和「下一行一个无关的括号表达式」缝成一处假调用点
        // —— 那是**多认**，方向上安全，但失败消息会开始指着不存在的调用点，没人读得懂。
        var probe = hit.upperBound
        while probe < source.endIndex, source[probe] == " " || source[probe] == "\t" {
            probe = source.index(after: probe)
        }
        if source[probe...].hasPrefix(".init") {
            probe = source.index(probe, offsetBy: 5)
            while probe < source.endIndex, source[probe] == " " || source[probe] == "\t" {
                probe = source.index(after: probe)
            }
        }
        // 后面不是 `(` ⇒ 这不是调用（`SetupEnvironmentFoo`、一句提到类型名的类型标注、
        // `SetupEnvironment.Kind` …）。跳过，不记。
        guard probe < source.endIndex, source[probe] == "(" else { continue }
        var depth = 1
        var index = source.index(after: probe)
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
        // 实参文本从**左括号之后**起算，不是从 `head` 之后 —— 空格形式下两者不再重合
        // （`head (a: 1)` 若从 `hit.upperBound` 起算会把 ` (` 也算进实参，`argumentValue`
        // 的第一个 piece 从此永远带一个前导 `(`、`hasPrefix(label + ":")` 永假 ⇒ 静默返回
        // `nil` ⇒ 下游那条相等断言拿 `<没有这个实参>` 当场红。方向上安全，但红得莫名其妙。）
        calls.append(String(source[source.index(after: probe)..<index]))
        cursor = source.index(after: index)
    }
    return calls
}

/// `source` 里**可能构造 `type`、而 ``callArguments(of:in:)`` 结构上认不出**的那些构造形状。
///
/// 非空 ⇒ 调用方必须**当场红**。这是把 `callArguments` 从**白名单**（只报它认得出的）补成
/// **围栏**（认不出 ⇒ 红）的那另一半。
///
/// ## 为什么必须有这个函数（`/codex review 37745f2` 的 P1）
///
/// `callArguments` 是一份白名单，而白名单永远不完整。上一版的处理方式是把「我认不出哪些」
/// **如实写进 doc comment**，再声称「真正兜住这一整类的是行为测试」。Codex 逐字拆了它：
///
/// ```swift
/// _ = SetupEnvironment(…, packsLockFile: environment.packsLockFile)  // 死代码诱饵，喂饱 !isEmpty
/// typealias SE = SetupEnvironment
/// let real = SE(…, packsLockFile: <从注入值派生出来的表达式>)         // 真实构造，文本层隐身
/// ```
///
/// 诱饵满足「≥1 处且那一处转发对」，真实构造走别名隐身；实参再从 fixture 的注入值**派生**
/// （当时的 fixture 算得出，见 `FixtureTargets` 那段），于是**行为测试也绿**。文本与行为两条腿
/// 同时被拆掉 —— 一个洞不会因为被写进注释而变成有人看守它。
///
/// ## 极性：宁可多报，绝不少报
///
/// 下游是「非空 ⇒ 红」。多报一条 = 有人喊、去看一眼、要么挪走那个构造要么教会扫描器，fail-**closed**；
/// 少报一条 = 那个形状静默退出审查，fail-**open**，没有人会喊。所以这里**不**去判断
/// `typealias Foo = Int` 与 `type` 无关：一律记账。三个被扫文件今天**四类**形状（`typealias` /
/// `#if` / 上下文 `.init(` / 未应用的 `.init` 引用）各 **0** 命中（`/review d7084be` 复测：三个
/// 文件里 `.init` 总共只出现一次，在 `OnboardingActions.swift` 的一句 doc comment 里，而这里喂的
/// 是**剥了注释**的文本），代价是零，而它把「未来某人引入一种新形状」这件事
/// 从「静默失效」变成「当场红」。
///
/// ## 认得出 vs 记一笔，边界在哪
///
/// 判据是**两根轴**，不是一句子串匹配。上一版只找逐字 `.init(`，于是两种形状同时漏网
/// （`/codex review d7084be` 的 P1 与 `/review d7084be` 的六路独立命中说的是同一件事）：
///
/// * **右轴 —— `.init` 后面（跳过同行空白）是不是 `(`。** 允许空白，与 `callArguments` 的
///   `head .init (` 逐字同轴。上一版这里是硬子串 `.init(`，而同一刀刚把 `callArguments` 教会跳
///   空白 —— **两个读模型从此不同轴**，`= .init (…)` 正好掉进缝里：`callArguments` 因为左边是
///   `=` 认不出，围栏因为那个空格记不了一笔。
/// * **右轴不成立（后面不是 `(`）⇒ 未应用的初始化器引用**（`let make = Foo.init` 之后 `make(…)`、
///   `map(Foo.init)`）。构造真的发生了，只是发生在另一个名字底下，`callArguments` 认得的四种写法
///   一种都对不上 ⇒ **不看左边，一律记一笔**。这一支是上一版最大的洞：只要另留一处完全合规的死
///   代码诱饵，就能同时喂饱 `count == 1` 与逐项实参相等断言，而真实构造一眼都没被看过。
/// * **左轴 —— `.init` 前面（跳过同行空白）是不是标识符字符。** 只在右轴成立（真的是一次调用）
///   时才看。`Foo.init(` / `Foo .init (`：要么 `Foo == type`（`callArguments` 认得），要么它构造的
///   压根不是 `type`，两种都无须记账。（残余：`Foo` 是 `type` 的别名 —— 那由 `typealias` 那条收掉。）
///   `Self.init(` / `super.init(` 同理不记：它们构造的是**所在类型自身**，而这个函数扫的是**调用方**
///   文件，不是 `type` 的定义处。如实记在这里，不声称封死。
/// * `= .init(` / `: .init(` / `(.init(` —— 左边不是标识符，**上下文推断**，构造的是什么由类型
///   检查器决定，本模块无从判定，可能正是 `type` ⇒ 记一笔。
///
/// ⚠️ `.init` 后面**紧跟**标识符字符（`.initialize(`）不是初始化器，整条跳过 —— 否则每一个
/// `.initialize(` 都会被当成「未应用的引用」记一笔，那是假红，而假红的守卫会被下一个人删掉。
///
/// ⚠️ **不要**把探针放宽成「任何前导点的成员调用」。`/review d7084be` 的红队开过这个方子，实测
/// 打回：`PanelView.swift` 里 41 行行首 SwiftUI 修饰符（`.padding(13)` / `.frame(width:)` /
/// `.onChange(of:)` …）会被逐条记账，`unmodeledShapes.isEmpty` 当场**永久**假红。记在这里免得
/// 下一轮再开一次同样的方子。
///
/// ⚠️ 与 `callArguments` 一样喂 ``StrippedSwiftSource/codeWithoutStringLiterals``：注释里谈论
/// `typealias` 的**散文**不该让它红（那正是本仓库反复栽的「假红的守卫会被下一个人删掉」）。
func unmodeledConstructionShapes(of type: String, in source: String) -> [String] {
    var shapes: [String] = []
    for (offset, line) in source.components(separatedBy: "\n").enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let location = "第 \(offset + 1) 行：\(trimmed)"

        if trimmed.contains("typealias") {
            shapes.append(
                "`typealias` —— 别名之后的构造（`SE(…)`）`callArguments(of: \"\(type)\", …)` 永远"
                    + "认不出，那一处会静默退出审查。\(location)")
        }
        if trimmed.contains("#if") {
            shapes.append(
                "条件编译 —— 扫描器不建模 `#if`，**非活跃**分支里的构造点与活跃的完全同形，会替"
                    + "真实构造喂饱「≥1 处 / 正好 N 处」那类断言。\(location)")
        }

        var cursor = line.startIndex
        while let hit = line.range(of: ".init", range: cursor..<line.endIndex) {
            cursor = hit.upperBound

            // `.initialize(` / `.initial` —— `.init` 只是更长标识符的前缀，压根不是初始化器。
            // 不先关掉它，下面那条「后面不是 `(` ⇒ 未应用的引用」会把它们逐条记成假红。
            if hit.upperBound < line.endIndex {
                let next = line[hit.upperBound]
                if next.isLetter || next.isNumber || next == "_" { continue }
            }

            // 右轴：跳过**同行**空白（不跳换行 —— 与 `callArguments` 同一条理由）之后是不是 `(`。
            var probe = hit.upperBound
            while probe < line.endIndex, line[probe] == " " || line[probe] == "\t" {
                probe = line.index(after: probe)
            }
            let applied = probe < line.endIndex && line[probe] == "("

            if !applied {
                shapes.append(
                    "未应用的初始化器引用 `.init` —— 构造 `\(type)` 的那一次调用被挪到了**另一个名字**"
                        + "底下（`let make = \(type).init` 之后 `make(…)`、`map(\(type).init)`），"
                        + "`callArguments` 认得的四种写法一种都对不上，那一处会静默退出审查。\(location)")
                continue
            }

            // 左轴：跳过**同行**空白之后，把左边那个标识符**整个**取出来，再问它像不像**类型名**。
            //
            // ⚠️ 只问「末字符是不是标识符字符」是不够的，而且那正是这一刀第一版新开的 fail-open：
            //    `return .init(` / `try .init(` / `await .init(` / `throw .init(` 的关键字末字符
            //    （`n` / `y` / `t` / `w`）全是标识符字符 ⇒ 被当成显式类型名**静默跳过**，而上一版
            //    （硬子串 `.init(`、只看紧邻前一个字符 = 空格）反而记得住。实测七种形状全漏
            //    （`/review d7084be` 红队 P1，本轮探针坐实）。
            var back = hit.lowerBound
            while back > line.startIndex {
                let candidate = line.index(before: back)
                if line[candidate] == " " || line[candidate] == "\t" {
                    back = candidate
                    continue
                }
                break
            }
            var identifierStart = back
            while identifierStart > line.startIndex {
                let candidate = line.index(before: identifierStart)
                let character = line[candidate]
                guard character.isLetter || character.isNumber || character == "_" else { break }
                identifierStart = candidate
            }
            let leftIdentifier = String(line[identifierStart..<back])
            // 判据是「**像类型名**」，不是「是标识符」——极性要求这一侧尽可能窄（跳过 = 静默退出
            // 审查 = fail-open；记一笔 = 有人喊 = fail-closed）。Swift 的类型名约定是首字母大写，
            // 于是全小写的关键字（`return` / `try` / `await` / `throw` / `case` / `in` / `is` / `as`…）
            // 与元类型**变量**（`let f = Foo.self` 之后 `f.init(…)`，红队 #9）**都落进记账那一侧** ——
            // 而这里不需要维护任何关键字清单：清单永远不完整，而不完整的清单在这一侧是 fail-open。
            let looksLikeTypeName =
                leftIdentifier.first.map { $0.isUppercase } == true
                || leftIdentifier == "self" || leftIdentifier == "super"
            if looksLikeTypeName {
                continue  // `Foo.init(` / `Foo .init (` / `self.init(` —— 见上面 doc 那段边界说明
            }

            shapes.append(
                "上下文推断的 `.init(` —— 它构造的可能正是 `\(type)`，而本模块无从判定，"
                    + "`callArguments` 会漏掉这一处。\(location)")
        }
    }
    return shapes
}

/// `arguments`（``callArguments(of:in:)`` 切出来的实参文本）里 `label:` 那**一个顶层实参的值**，
/// trim 过。找不到该标签返回 `nil`。
///
/// ## 为什么必须是「相等」，不能是 `contains`（`/review e7c38ea` 的 P2）
///
/// ``callArguments(of:in:)`` 已经把**调用**的两头锚死了（头 `head(`、尾配平右括号）。但它交出来的
/// 实参文本，上一版是拿 `contains("lockFile: environment.configLockFile")` 去断的 —— **头锚死了，
/// 而 `lockFile: ` 之后那一段没锚**。于是每一种「以它开头、后面接着把它改掉」的写法都逐字包含那个
/// needle：
///
/// ```swift
/// lockFile: environment.configLockFile.deletingLastPathComponent()
///     .appendingPathComponent("play.lock")            // 真的是 ~/.claudio/play.lock
/// lockFile: isFirstRun ? environment.configLockFile : environment.settingsLockFile
/// ```
///
/// 两条都编得过，`arguments.contains(…)` 都**绿**，`!setup.contains("playLockFile")` 也绿（标识符
/// 一次没出现），`totalForwards == 3` 还是绿。这与 ``callArguments(of:in:)`` doc 里记着的那次翻车
/// （`uninstallClaudioHooks(` 逐字包含 `installClaudioHooks(`）**逐字同一个病**，只是搬到了实参上：
/// 子串断言没有词边界。
///
/// 这里按**顶层逗号**（括号 / 方括号 / 花括号深度为 0 的那些）把实参切开，再对 `label:` 那一段做
/// **相等**判定。相等才配叫「绑定」；`contains` 只是「以它开头」。
func argumentValue(_ label: String, in arguments: String) -> String? {
    var depth = 0
    var pieces: [String] = []
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
            pieces.append(current)
            current = ""
        default:
            current.append(character)
        }
    }
    pieces.append(current)

    let prefix = label + ":"
    return
        pieces
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { $0.hasPrefix(prefix) }
        .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
}
// claudio:shared-scanner:end

/// `url` 是不是真的落在 `root` **这棵子树里**（按**路径分量**判，不是按字符串前缀）。
///
/// ## 为什么不能写 `url.path.hasPrefix(root.path)`（`/codex review d7084be` P2 + `/review d7084be`）
///
/// 裸前缀没有分量边界：`root` 是 `/tmp/x/abc` 时，`/tmp/x/abc-escaped/packs.lock` 逐字通过
/// `hasPrefix("/tmp/x/abc")`，而它**在 root 之外** —— `withTempDirectory` 的 `removeItem` 清不掉它，
/// 测试从此在一个没人打扫的位置上开锁。这与 `callArguments` 当年那次「`uninstallClaudioHooks(` 逐字
/// 包含 `installClaudioHooks(`」是同一个病：**子串判据没有词边界**，只是这次的「词」是路径分量。
///
/// ⚠️ 极性提醒：同一个病换到**豁免**那一侧就是 fail-**open**（少豁免 = 多查一个文件 = 有人喊；
/// 多豁免 = 一个文件静默退出普查 = 没有人会喊）。`ViewWiringSuite` 的 `lockCensusExemptions` 就是
/// 那一侧，它按 `lastPathComponent` 全等判，不是这个函数。
///
/// ## 为什么归一化必须是**纯词法**的，不能用 `standardizedFileURL`
///
/// `standardizedFileURL`（以及 `NSString.standardizingPath`）会把开头的 `/private` 剥掉，**但只在
/// 结果仍指向一个真实存在的路径时才剥** —— 它是**存在性依赖**的。而这个函数的两个操作数存在性
/// 天然不同：`root` 已被 `withTempDirectory` 的 `createDirectory` 建出来，锁文件按设计**不存在**
/// （见 `injectedPacksLock` 的 doc：「父目录不用预建」）。于是两边被用**两套不同的规则**归一化。
///
/// 实测（本轮）：`root = /private/tmp`（存在）→ 归一成 `/tmp`；它下面一个**不存在**的子路径
/// 原样保留 `/private/tmp/…` ⇒ 一个货真价实的子孙被判 `false`，四条断言集体**假红**，失败消息还
/// 指着一条其实就在里面的路径说它跑到外面去了。今天默认 `TMPDIR` 是 `/var/folders/…` 所以够不到，
/// 但 `TMPDIR=/private/tmp` 是完全正常的设置。假红的守卫会被下一个人删掉 —— 这正是本仓库反复栽的跤。
///
/// 所以下面自己做词法归一（去 `.`、抵消 `..`），不碰文件系统，**两侧同规则**。
///
/// ⚠️ 天花板，如实记：这是一条**纯词法**判定，不解 symlink、不看 inode、不管大小写。
/// 一条用 symlink 跳出 `root` 的路径它拦不住。今天两个调用点的 root 与锁**同源派生**（都从
/// `withTempDirectory` 交出来的那一个 URL 长出来），所以够不到；换到别处复用前先读这一段。
private func lexicalPathComponents(_ url: URL) -> [String] {
    var components: [String] = []
    for component in url.pathComponents {
        if component == "." { continue }
        if component == "..", let last = components.last, last != "/", last != ".." {
            components.removeLast()
            continue
        }
        components.append(component)
    }
    return components
}

func isInside(_ url: URL, of root: URL) -> Bool {
    let rootComponents = lexicalPathComponents(root)
    let urlComponents = lexicalPathComponents(url)
    // 严格**真子孙**：`url == root` 不算「在里面」（一把等于 root 自己的锁不是一个文件）。
    guard urlComponents.count > rootComponents.count else { return false }
    return Array(urlComponents.prefix(rootComponents.count)) == rootComponents
}

/// Creates a unique temporary directory, runs `body` with its URL, and always removes it
/// afterwards (success or throw). Every test that touches the filesystem MUST use this
/// instead of any real `~/.claudio`/`~/.claude` path — see ``OnboardingEnvironment``'s
/// doc comment on why `$HOME` overrides don't work on Darwin.
@MainActor
func withTempDirectory<T>(_ body: (URL) throws -> T) rethrows -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("claudio-gui-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

/// Async overload of ``withTempDirectory(_:)`` — identical setup/teardown, but for suites
/// whose body must `await` (the `AudioImportViewModel` drop handlers are `async`, T8). The
/// sync overload above stays for every non-async suite; an async closure at the call site
/// selects this one.
@MainActor
func withTempDirectory<T: Sendable>(_ body: (URL) async throws -> T) async rethrows -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("claudio-gui-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

/// Writes `contents` to `url`, creating the parent directory if needed.
@MainActor
func writeFixture(_ contents: String, to url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? contents.write(to: url, atomically: true, encoding: .utf8)
}

/// Writes raw `data` to `url`, creating the parent directory if needed — the binary
/// counterpart to the `String` overload above, used by ``AudioImportSuite`` to plant
/// fixture files with real magic-byte headers (T8).
@MainActor
func writeFixture(_ data: Data, to url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
}

/// Creates a real symlink at `linkURL` pointing to `targetURL`, asserting it actually
/// took — mirrors `helper/Tests/ClaudioCoreTests/TestSupport.swift`'s `createSymlink`
/// exactly (duplicated per this package's established "duplicate rather than share test
/// helpers across packages" convention, see the header comment above).
@MainActor
func createSymlink(at linkURL: URL, pointingTo targetURL: URL) {
    try? FileManager.default.createDirectory(
        at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
    expect(
        (try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)) != nil,
        "createSymlink: no real symlink exists at \(linkURL.path) after creation — a test"
            + " relying on this fixture would silently not be testing a symlink escape at all")
}

/// Creates a real FIFO at `url` — 「路径上有东西，但它不是正规文件」这一族里
/// `fileExists(atPath:isDirectory:)` 也挡不住的那个代表（目录还能靠 `isDirectory:` 排掉，
/// FIFO / socket / 设备不能）。只有 ``regularFileExists(at:)``（`stat(2)` + `S_IFREG`）挡得住它，
/// 所以每一个「正规文件闸门」用例都拿它当最硬的输入。
///
/// 起初是 `CoverageStateSuite` 的私有 helper（当时是本目标里唯一的用户）；`ManifestBindingSuite`
/// 现在钉的是同一个谓词的**写**侧，两份 `mkfifo` 拷贝不值得，遂提到这里。仍不与 helper 侧的
/// `TestSupport.makeFIFO` 共享——那是另一个包的测试目标，见本文件顶部的「按包复制而非跨包共享」约定。
@MainActor
func makePackFIFO(at url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let created = url.withUnsafeFileSystemRepresentation { pathPointer -> Bool in
        guard let pathPointer else { return false }
        return mkfifo(pathPointer, 0o644) == 0
    }
    expect(
        created,
        "makePackFIFO: mkfifo 在 \(url.path) 失败 —— 依赖这个 fixture 的用例会在「其实什么都没测」"
            + "的情况下变绿（路径上压根没有 FIFO，拒绝是因为文件不存在，不是因为闸门起作用了）")
}

/// Creates an empty **non-executable** regular file at `url` (default perms, no execute
/// bit) — used to model a broken/partial helper install that `detectOnboardingState`
/// must still treat as `.helperMissing`.
@MainActor
func writeEmptyFile(at url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: Data())
}

/// Creates a small, **non-empty executable** (`0o755`) regular file at `url` — the realistic
/// stand-in for the installed `claudio` binary, which ships executable alongside the app (the
/// app places it; `claudio install` itself only writes `settings.json` hooks, and could not
/// run at all unless this binary already existed and were executable). `detectOnboardingState`
/// requires a runnable *non-empty* regular file, so every fixture that means "the helper is
/// installed" must use this, not ``writeEmptyFile(at:)`` or ``writeEmptyExecutableFile(at:)``.
@MainActor
func writeExecutableFile(at url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(
        atPath: url.path, contents: Data("#!/bin/sh\nexit 0\n".utf8),
        attributes: [.posixPermissions: 0o755])
}

/// Creates an empty (0-byte) but **executable** (`0o755`) regular file at `url` — models a
/// truncated / half-copied install where the execute bit is set but no real binary was ever
/// written. `detectOnboardingState` must still treat this as ``OnboardingState/helperMissing``,
/// since Claude Code could not actually run an empty file.
@MainActor
func writeEmptyExecutableFile(at url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(
        atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o755])
}

// MARK: - 「这个文件到底有没有被**碰过**」——一次观测，不是一次终态比较
//
// ## 它补的那颗牙（`/codex review ee026db` 的 P2）
//
// `ee026db` 把几条持锁断言从「里面没有 claudio 的 hook」（`hookCommands(…).allSatisfy { !… }` ——
// 空数组恒真）换成了**字节比较**：`fileBytes(after) == fileBytes(before)`。那一刀砍掉了恒真，
// 却没砍掉它紧接着那句话：失败消息写的是「settings.json **一个字节都没被碰过**」，而字节比较
// 只证明**终态相同**。
//
// 一个「写完再回滚」的实现（写 hooks → 撞上 config.lock → 把 settings.json 删回去）会让 before 与
// after **都是「无文件」**，字节比较全程绿。而那个窗口里，用户的 `~/.claude/settings.json` 里真的
// 躺过四条指向 helper 的 hook —— Claude Code 每一个事件都要读这个文件，进程若在窗口里崩掉，痕迹
// 就永久留下。这条分支叫 `feat/lock-separation`，它整个存在的前提就是**这个文件有并发的读者与
// 写者**：「窗口期」正是这个威胁模型里唯一算数的东西。措辞比覆盖范围大，第十一次。
//
// ## 这一版观测的是**事件**，不是状态差。两半，各补各的盲区
//
// 1. **目录级 kqueue**（`EVFILT_VNODE` / `NOTE_WRITE|NOTE_DELETE|NOTE_RENAME`，挂在文件**所在目录**
//    的 fd 上）：目录项的增 / 删 / 改名都会在内核里排一个事件，动作跑完之后零超时轮询就取得到。
//    `Data.write(options: .atomic)` 是「同目录临时文件 + rename」（`SettingsInstaller.atomicWrite`
//    的契约），所以创建、原子替换、删除 —— 写盘的每一种形状 —— 都逃不过它。**写了又删掉**：目录
//    响，字节比较一声不吭。
//
// 2. **`stat(2)` 身份快照**（dev / ino / size / mtime / **ctime**）：目录 watch 有一个已知盲区 ——
//    对一个**已存在**的文件做**非原子的原地重写**不动任何目录项。ctime 补上它，而且 ctime 是这里
//    唯一**伪造不了**的字段：`utimensat` 能把 mtime 按回过去（实测：设成 100 秒前也照设不误），
//    但那一次调用自己就会把 ctime 顶到「现在」。userspace 没有任何系统调用能把 ctime 设回去。
//
// **读不会让任何一半响**：读只动 atime，而 atime 刻意不在快照里（一条会被「读了一次」弄红的断言，
// 会被下一个人删掉）。
//
// ## ⚠️ 一个观测不到写的观测器，会把每一条「没被碰过」变成恒真 —— 同一个病，升了一层
//
// 把 ``FileWriteWatch/observedWrite()`` 掏空成 `return false`（一次手滑、一次「先临时关掉调试一下」），
// 每一条「必须没被碰过」就永远绿，而它们在失败消息里自称守着「一次注定不会响的安装，绝不允许在用户的
// Claude Code 里留下新的痕迹」（`Setup.swift:491`）。这与 `2f107b5` 那条恒真守卫是**逐字同一个形状**：
// 守卫读的东西证明不了它声称守住的东西。**实测（第一轮台账 A1）：把 `observedWrite()` 换成
// `return false`，四条持锁 suite 一条都不红，而 `isArmed` 也一声不吭**（它是独立字段，照常武装成功）。
//
// 所以真正兜住这一类的，只有**正向对照**，而且必须一半一个：
//
// - **写观测器①**（写了又删掉）—— 只有目录 kqueue 看得见。它顺带兜住「目录 fd 指错了一个**存在但
//   不相干**的目录」这种 `isArmed` 抓不到的失效。
// - **写观测器②**（原地重写并把内容与 mtime 都恢复）—— 只有 ctime 看得见。
// - **写观测器③**（settings.json 是 dotfiles 符号链接，穿过它写目标）—— 只有 `stat(2)` 的跟随语义
//   看得见（换成 `lstat` 当场变红，而其余整套台账一条都不红）。
//
// 三条各自钉死一处，互不代偿：任一处被打瞎，对应那条对照当场红，而**其余全绿**（三轮变异逐条实测）。
//
// ``FileWriteWatch/isArmed`` 是另一道**更早**的闸（`makePackFIFO` / `createSymlink` 的先例：fixture
// 必须先证明自己真的生效了）。但它只管得着目录那一半 —— 见它自己的文档，那里记着我在这一刀里
// 亲手写下、又被台账当场证伪的一句假话。
//
// ## ⚠️ 它**不**兜什么（别再让措辞比覆盖范围大）
//
// `observedWrite()` 没有假阴性，但目录那一半有**假阳性**：它响的是「这个目录里有东西变了」，
// 而不是「**这个文件**变了」。所以它只能用在**被观测文件是该目录唯一写者**的地方：
//
// - `~/.claude/`（fixture 里的 `dot-claude/`）—— claudio 对它的全部写入只经由 `settings.json`
//   与它的一次性备份，所以四条持锁 suite 都用得上；
// - `~/.claudio/`（fixture 里的 `.claudio/`）—— 二进制、声音包、两把锁文件都住在这里，**接管
//   期间它一直在被写**。所以 `config.json` 的观测只在**断开**那两条 suite 里成立（那时接管早已
//   跑完，`.claudio/` 全程安静）；接管那两条里它会假阳，别往那里加。

/// 一个文件此刻的**身份** —— 不只是它的字节。
///
/// `nil` = 这条路径上此刻没有文件。**存在性本身是身份的一部分**：`nil` → 非 `nil` 是一次创建，
/// 反过来是一次删除。
///
/// **ctime 是这张快照的要害**，因为它是唯一伪造不了的字段：一个「原地重写、再把内容与 mtime 都
/// 恢复回去」的写者能让 dev / ino / size / mtime 全部原样，但 ctime 会被顶到「现在」——
/// `utimensat` 自己那一次调用就会顶它。
///
/// atime **刻意不在**里面：读文件会动它。
private struct FileIdentity: Equatable {
    let device: Int64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let attributesChangedSeconds: Int64
    let attributesChangedNanoseconds: Int64

    init?(of url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        attributesChangedSeconds = Int64(info.st_ctimespec.tv_sec)
        attributesChangedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
    }
}

/// 从构造那一刻起，`file` 有没有被**写过** —— 哪怕它此刻的字节与构造那一刻逐字相同。
/// 完整推理（含它不兜什么）见上面那节。
final class FileWriteWatch {
    /// 被观测的那条路径，**原样**，不做 `resolvingSymlinksInPath()`。
    ///
    /// 第一版在这里调了 `resolvingSymlinksInPath()`，并在文档里声称「否则一次穿过链接写到目标的
    /// 安装会一声不响」。**那句话是假的**：``FileIdentity`` 用的是 `stat(2)`，而 `stat` 本来就
    /// **跟随符号链接** —— 对着链接自己 stat，拿到的就是**目标**的 dev / ino / ctime。所以那一行
    /// 解析对身份快照毫无影响，是一行纯装饰，而它的文档在替它撒谎。
    ///
    /// （dotfiles 的 stow / chezmoi 确实会把 `settings.json` 做成符号链接，而 `atomicWrite` 也确实
    /// 写的是 `resolvingSymlinksInPath()` 之后的目标。真正让观测跟得上的是 `stat` 的跟随语义，
    /// 不是那次解析。`SymlinkedSettings` 那条正向对照就钉这件事：换成 `lstat` 当场变红。）
    private let file: URL
    /// 目录项那一半盯的是**未解析**的父目录 —— 刻意的：一个把符号链接**整个替换**成正规文件的写者
    /// 根本不碰目标（`stat` 那一半看不见），但它改了**这里**的目录项。两条路各盖一种，合起来没有缺口。
    private let entryDirectory: URL
    private let directoryDescriptor: Int32
    private let queue: Int32
    private let identityBefore: FileIdentity?
    private var sawDirectoryEvent = false

    /// **目录那一半**真的武装起来了吗（目录 fd 开到了、`kevent` 注册成功了）。
    ///
    /// ⚠️ **它管不着身份快照那一半** —— 这句话第一版写的是「`false` 时 ``observedWrite()`` 会永远
    /// 返回 `false`，一条恒假的守卫」，而**那是假的**（第二轮台账 R2a 实测反证）：`identityBefore`
    /// 在 `open()` **之前**就拍好了，与 fd / kevent 无关。于是武装失败的观测器不是**瞎**，是**半瞎**：
    /// 任何改动 dev / ino / size / mtime / ctime 的写它照样看得见（一次真实的 `atomicWrite` 安装就是），
    /// 它丢掉的**恰好**是终态身份不变的那一类 —— 「写了又删掉」（nil → nil），以及「把符号链接整个
    /// 替换成正规文件」（目标没动）。而「写了又删掉」正是 `/codex review ee026db` 指出的那一类，
    /// 也正是这整套观测存在的理由。**覆盖损失是要害的，但不是「全归零」。**
    ///
    /// （措辞比覆盖范围大，第十一次 —— 这一次复发在**杀掉它的那一刀自己的文档里**。留着这段话，
    /// 是因为下一个人会本能地想把 `identityBefore` 挪进 guard 后面「让它真的恒假」——不必，
    /// 半瞎比全瞎好，而 `isArmed` 的断言会先于一切当场变红。）
    ///
    /// 每个调用点都必须先断言它（七处，第二轮台账下 7/7 全红）。
    let isArmed: Bool

    init(watching file: URL) {
        self.file = file
        entryDirectory = file.deletingLastPathComponent()
        identityBefore = FileIdentity(of: file)

        let descriptor = open(entryDirectory.path, O_EVTONLY)
        let kernelQueue = kqueue()
        directoryDescriptor = descriptor
        queue = kernelQueue
        guard descriptor >= 0, kernelQueue >= 0 else {
            isArmed = false
            return
        }

        var change = kevent()
        change.ident = UInt(descriptor)
        change.filter = Int16(EVFILT_VNODE)
        change.flags = UInt16(EV_ADD | EV_ENABLE | EV_CLEAR)
        // 刻意**不**要 `NOTE_ATTRIB`：目录的属性变化（例如 readdir 顶 atime）与「有人写了这个文件」
        // 无关，收它只会换来一条时不时假红、然后被人删掉的断言。目录项的增 / 删 / 改名就够了 ——
        // 创建、原子替换（temp + rename）、删除，全在这三条里。
        change.fflags = UInt32(NOTE_WRITE | NOTE_DELETE | NOTE_RENAME)
        isArmed = kevent(kernelQueue, &change, 1, nil, 0, nil) == 0
    }

    /// 构造之后，这个文件被写过吗？**幂等**：问几次答案都一样（见下面那段缓存）。
    func observedWrite() -> Bool {
        if !sawDirectoryEvent {
            var event = kevent()
            var immediately = timespec(tv_sec: 0, tv_nsec: 0)
            // `EV_CLEAR`：事件取一次就被内核清掉。**必须缓存**，否则第二次调用会返回 `false` ——
            // 一条「问第二遍就翻供」的守卫，正是这里最不该出现的东西（今天每个调用点都只问一次，
            // 所以这段缓存**没有任何断言在钉它** —— 除了「写观测器①」里那条刻意问两遍的断言）。
            sawDirectoryEvent = kevent(queue, nil, 0, &event, 1, &immediately) > 0
        }
        return sawDirectoryEvent || FileIdentity(of: file) != identityBefore
    }

    deinit {
        if directoryDescriptor >= 0 { close(directoryDescriptor) }
        if queue >= 0 { close(queue) }
    }
}

/// 原地重写 `url`，再把**内容与 mtime 都恢复**成动作前的样子 —— 一个尽力伪装成「没碰过」的写者。
///
/// 它是 ``FileWriteWatch`` 里 ctime 那一半唯一的正向对照，所以它必须真的把**除 ctime 之外**的每
/// 一个字段都按回原样：inode 不变（原地写，不是 temp + rename）、size 不变、内容逐字不变、mtime
/// 逐纳秒不变。于是「观测器看见了这次写」**只可能**是因为 ctime。
///
/// 这条纪律不是洁癖：少了它，这条对照会**因为错误的理由**变绿（比如 mtime 其实没恢复），而 ctime
/// 那一半其实是死的 —— 一条自称在钉 ctime、实则在钉 mtime 的对照，比没有对照更坏。所以恢复是否
/// 真的成功，就地断言。
@MainActor
func rewriteInPlaceRestoringContentAndModificationTime(_ url: URL) {
    guard let original = try? Data(contentsOf: url) else {
        expect(false, "rewriteInPlaceRestoringContentAndModificationTime: \(url.path) 读不出来")
        return
    }
    var before = stat()
    expect(stat(url.path, &before) == 0, "test setup: \(url.path) stat 失败")

    // ① 原地写进不一样的内容（不动目录项 → 目录 watch 全程安静）。
    let descriptor = open(url.path, O_WRONLY | O_TRUNC)
    expect(descriptor >= 0, "test setup: \(url.path) 打不开来做原地写")
    let scribble = Array(#"{"scribbled":true}"#.utf8)
    _ = scribble.withUnsafeBufferPointer { write(descriptor, $0.baseAddress, $0.count) }
    close(descriptor)

    // ② 把内容原样写回去。
    let restore = open(url.path, O_WRONLY | O_TRUNC)
    expect(restore >= 0, "test setup: \(url.path) 打不开来做内容恢复")
    let bytes = Array(original)
    _ = bytes.withUnsafeBufferPointer { write(restore, $0.baseAddress, $0.count) }
    close(restore)

    // ③ 把 atime / mtime 也按回原值。`utimensat` 做得到 —— 而它**做不到**的正是 ctime：这一次
    //    调用自己就会把 ctime 顶到「现在」。
    let times = [before.st_atimespec, before.st_mtimespec]
    expect(
        times.withUnsafeBufferPointer { utimensat(AT_FDCWD, url.path, $0.baseAddress, 0) } == 0,
        "test setup: utimensat 没能把 mtime 按回去")

    // ④ 就地证明「除 ctime 外一切原样」—— 否则这条对照钉的不是 ctime。
    var after = stat()
    expect(stat(url.path, &after) == 0, "test setup: 重写之后 stat 失败")
    expect(
        (try? Data(contentsOf: url)) == original,
        "test setup: 内容没能恢复成逐字相同 —— 这条对照会因为「字节变了」而绿，而 ctime 那一半"
            + "其实是死的")
    expect(
        after.st_ino == before.st_ino && after.st_size == before.st_size,
        "test setup: 原地写必须保住 inode 与 size（inode 变了 = 这是一次 temp+rename，目录 watch"
            + " 会看见它，于是这条对照钉的不再是 ctime）")
    expect(
        after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec
            && after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
        "test setup: mtime 没能恢复成逐纳秒相同 —— 这条对照会因为 mtime 变了而绿，钉不到 ctime")
    expect(
        after.st_ctimespec.tv_sec != before.st_ctimespec.tv_sec
            || after.st_ctimespec.tv_nsec != before.st_ctimespec.tv_nsec,
        "test setup: ctime 竟然没变 —— 那么 `FileWriteWatch` 的身份快照那一半在这台机器上兜不住"
            + "「原地重写」，别再声称它兜得住")
}
