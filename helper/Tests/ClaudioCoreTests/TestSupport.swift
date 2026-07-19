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
// claudio:shared-scanner:end

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
