import Foundation

// Shared fixture helpers for the dependency-free harness (see `main.swift`). Mirrors
// `helper/Tests/ClaudioCoreTests/TestSupport.swift` — duplicated rather than shared
// across packages, since each package's test executable is private to its own build
// (same reasoning `helper/` already established).

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
                if blockDepth == 0 { mode = .code }
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
func withTempDirectory<T>(_ body: (URL) async throws -> T) async rethrows -> T {
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
