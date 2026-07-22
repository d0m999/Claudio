import Foundation

// Shared fixture helpers for the dependency-free harness (see `main.swift`).

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
// 会被剪成 `let hint = "锁的说明见 https:` —— 该行剩下的**代码**在分析文本里根本不存在，而那句
// `lockFile: ClaudioPaths.playLockFile` 对整套锁分离断言**永久隐身**。
//
// `be332ff` 给它配的守卫是「被扫的源文件里不许出现 `://`」，写法是 `!codeOnly(path).contains("://")`
// —— 而 `codeOnly` **正是那个会在 `//` 处截断的函数**：`://` 自带 `//`，它到达断言之前就已经被剪成
// `https:` 了。**那条守卫恒真，一个字节都守不住**，它却自称「真到了非放不可的那天会当场变红」。
// 一条永远不会红的断言不是护栏 —— 这正是这两个 suite 通篇在杀的那个病，复发在杀它的那一刀里。
//
// ## 为什么是「修扫描器」，不是「把 ban 挪到 raw source」
//
// 把守卫改成读原始文本的 `!raw.contains("://")` 确实能红。但它会在**第一个把 URL 写进 doc comment**
// 的人手上红 —— 而注释里的 URL 完全无害（剥注释本来就该把它剥掉）。一条会因为无害改动而红的断言，
// 会被下一个人删掉，然后洞原样回来。
//
// 所以这里直接把扫描器修对：一个**位置感知**的小状态机（代码 / 行注释 / 块注释 / 字符串 / 多行
// 字符串），字符串字面量里的 `//` 不再是注释起点。上面那句 `let hint = …` 现在整行保留，
// `playLockFile` 当场被负向断言逮住。
//
// ## 它知道自己不认识什么 —— 而**上一版把这句话说大了**（`/codex review 2f107b5` 的 P1）
//
// 上一版这里写着「扫描器不建模 raw string，而且它知道自己不认识」，并让两个 suite 各配一条守卫
// 盯着 ``StrippedSwiftSource/unmodeledConstructs``。**那张清单当时只有 raw string 一个来源**，
// 而扫描器的盲区不止一个：它**不建模字符串插值**。于是一句合法 Swift
//
// ```swift
// let hint = "\(fallback ?? "https://claudio.dev/locks")"; _ = write(lockFile: ClaudioPaths.playLockFile)
// ```
//
// 里，插值内那个嵌套字符串的 `"` 被当成**外层串的结尾**，状态机当场倒相回代码模式，紧接着 URL 的
// `//` 就成了「注释起点」—— 整行被剪成 `let hint = "\(fallback ?? "https:`，那句锁**永久隐身**，
// 而 `unmodeledConstructs` **是空的**：两条守卫一声不吭。**逐字是它自称已经治好的那个病。**
// （`helper/Sources` 里现有三处插值嵌套字符串 —— `Doctor.swift:439`/`:443`、`Subcommands.swift:135`
// —— 它们至今没触发截断，靠的是引号奇偶数凑巧对上，不是靠守卫。）
//
// 现在：插值是**被建模**的（`\(…)` 里面是代码，可嵌套，可含嵌套字符串），由 `SourceScannerSuite`
// 的**正向**断言钉死。清单本身也改了口径 —— 枚举盲区（raw string `#"…"#`、扩展 regex `#/…/#`）
// **加上**结构性失步兜底，且在它自己的 doc comment 里写明**它兜不住什么**（行内失步逃得过它）。
// 白名单永远是不完整的；把它当成万能网，就是这一节栽的那个跟头。
//
// 位置感知是必须的：`ClaudioColorHex.swift` 里的 `hasPrefix("#")` 逐字包含 `#"`，一条纯文本的
// `#"` 守卫会当场假红 —— 又一个「会因为无害改动而红、于是被下一个人删掉」的守卫。

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

/// 本测试包注入给 `SetupEnvironment.packsLockFile` 的那把包锁 —— 结构性不可从 `claudioRoot` /
/// `userPacksDirectory` 派生（同源做法与 gui 侧 `AudioImportFixtures.swift` 的
/// `injectedPacksLock(under:)` 逐字一致，见那里的完整论证）。
///
/// ## 为什么 `SetupSuite.swift` 原来的写法（`claudioRoot.appendingPathComponent("packs.lock")`）不够
///
/// `claudioRoot` 同时也是 `userPacksDirectory` 的父目录（`claudioRoot/packs`）——于是
/// `userPacksDirectory.deletingLastPathComponent().appendingPathComponent("packs.lock")` 逐字
/// 拼得回注入值。若 `Setup.swift` 未来某次重构悄悄把 `withNonBlockingLock(path:
/// environment.packsLockFile.path)` 换成「就地从 `userPacksDirectory` 算一个」，两个表达式求值
/// 出来仍是**同一个 URL**——所有持锁行为测试（外部占住锁、断言 `performFirstRunSetup` 被挡住）
/// 全部继续绿，规不出「读的是被注入的字段」还是「重新算了一遍碰巧算对」。
///
/// 结构性不可派生的做法与 gui 侧相同：父目录与叶名各带一段运行时 `UUID`，生产源码既写不出它
/// （编译期不存在），也没有任何路径表达式能从 `claudioRoot`/`userPacksDirectory` 派生出它。
///
/// ⚠️ 与 gui 侧的差异如实标注：`SetupEnvironment.packsLockFile` **保留**着默认值
/// `= ClaudioPaths.packsLockFile`（`LockSeparationSuite.swift`「SetupEnvironment 的三把锁默认值」
/// 那条专门钉的就是这个默认值本身，CLI 生产构造 `SetupEnvironment(executablePath:)` 时依赖它
/// 落到真实 `~/.claudio/packs.lock`）——这与 gui 侧「default 是纯地雷、已被拆除」不是同一类。
/// 本函数解决的是本文件另一件事：`SetupSuite.swift` 的 fixture **显式**传值时，那个值本身
/// 不该是可从别的 fixture 字段派生出来的。
func injectedSetupPacksLock(under root: URL) -> URL {
    let nonce = UUID().uuidString
    return
        root
        .appendingPathComponent("injected-setup-locks-\(nonce)", isDirectory: true)
        .appendingPathComponent("setup-packs-lock-\(nonce)")
}

/// Creates a unique temporary directory, runs `body` with its URL, and always removes it
/// afterwards (success or throw). Tests that touch the filesystem (`FileLock`, `doctor`
/// pack/settings probes) MUST use this instead of any real `~/.claudio` or `~/.claude`
/// path — those are the user's actual machine state.
@MainActor
func withTempDirectory<T>(_ body: (URL) throws -> T) rethrows -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("claudio-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

/// Writes `contents` to `url`, creating the parent directory if needed.
@MainActor
func writeFixture(_ contents: String, to url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? contents.write(to: url, atomically: true, encoding: .utf8)
}

/// Creates a **FIFO** (named pipe) at `url` — the hostile-pack fixture for "this path has
/// something at it, but that something is not a file". Sound packs are third-party-distributed
/// content (ENGINEERING.md: 策展声音包), so a `manifest.json` / `stop.mp3` that is really a FIFO
/// is reachable, not hypothetical.
///
/// Two different behaviors ride on this fixture, and they are NOT the same strength of claim:
/// - `FileManager.fileExists(atPath:)` answers **`true`** for a FIFO — proven, and the whole
///   reason `doctor`/`play` must require ``regularFileExists(at:)`` instead (a pack whose
///   `stop.mp3` is a FIFO would otherwise report `.complete` and then play silence).
/// - `Data(contentsOf:)` does **not** hang on a FIFO on Darwin (measured: it throws `EACCES`).
///   `FileHandle(forReadingFrom:)` **does** hang forever (measured). So the manifest reader's
///   `O_NONBLOCK` + `fstat` gate is what turns "never blocks on hostile pack content" into our
///   own tested contract instead of a borrowed Foundation implementation detail — see
///   `SafeFileRead.swift`'s header.
///
/// Verifies the FIFO was really created (rather than swallowing an `mkfifo` failure), since a
/// silently-missing FIFO would let a caller's "rejected / notReady" assertion pass for the
/// wrong reason — never having exercised a FIFO at all (same reasoning as ``createSymlink``).
@MainActor
func makeFIFO(at url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let created = url.withUnsafeFileSystemRepresentation { pathPointer -> Bool in
        guard let pathPointer else { return false }
        return mkfifo(pathPointer, 0o644) == 0
    }
    expect(
        created,
        "makeFIFO: mkfifo failed at \(url.path) — a test relying on this fixture would silently"
            + " not be testing a FIFO (hostile pack content) at all")
}

/// Creates `linkURL` as a symbolic link pointing at `targetURL`, creating `linkURL`'s
/// parent directory if needed. Exists solely so tests can construct symlink-escape
/// fixtures (a pack directory, or a file inside one, that resolves outside its pack
/// root) to exercise ``isReallyContained(_:inside:)`` and friends. Production code must
/// never itself create symlinks — this helper is test-only.
///
/// Verifies the link was actually created (rather than swallowing a `createSymbolicLink`
/// failure via `try?`), since a silently-missing symlink would let a caller's "resolves to
/// nil / missing" assertion pass for the wrong reason — never having exercised a symlink
/// at all — and quietly stop testing what it claims to test (Codex review, second pass).
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
