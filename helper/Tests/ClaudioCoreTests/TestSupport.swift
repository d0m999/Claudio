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
// ## 它知道自己不认识什么
//
// 扫描器不建模 raw string（`#"…"#`）。这不是靠注释里一句「目前源码里没有」维持的 ——
// ``StrippedSwiftSource/unmodeledConstructs`` 会在**代码位置**（不是字符串里）撞见 `#"` 时记一笔，
// 两个 suite 各有一条断言盯着它。注意这个位置感知是必须的：`ClaudioColorHex.swift` 里的
// `hasPrefix("#")` 逐字包含 `#"`，一条纯文本的 `#"` 守卫会当场假红 —— 又一个「会因为无害改动而红、
// 于是被删掉」的守卫。

/// 一份 Swift 源码**剥掉注释**之后的样子，外加一张「扫描器知道自己不认识」的构造清单。
///
/// 与 `gui/Tests/ClaudioGUICoreTests/TestSupport.swift` 里的那一份逐字相同 —— 按本仓库既定的
/// 「测试 helper 跨包复制而非共享」约定复制（两个 package 的测试可执行文件互相 import 不到）。
struct StrippedSwiftSource {
    /// 注释已剥掉、**字符串字面量原样保留**的代码文本。
    let code: String
    /// 扫描器不建模的词法构造（目前只有 raw string 字面量 `#"…"#`）。
    ///
    /// 非空 = `code` 不再可信：任何基于它的**负向**断言都可能假绿。见本节头部。
    let unmodeledConstructs: [String]
}

/// `source` 剥掉注释之后的样子。**字符串字面量里的 `//` 不是注释起点。**
///
/// 这个函数的每一条行为都由 `SourceScannerSuite` 喂合成输入钉死（正向断言，喂的是扫描器**自己**
/// 的输入 —— 所以它不可能像它替掉的那条 `://` 守卫一样变成恒真式：把这里换回「第一个 `//` 处无条件
/// 截断」，那个 suite 当场**红 6 条** —— 变异 M1a 实测，见它的文件头）。
func strippingComments(_ source: String) -> StrippedSwiftSource {
    enum Mode { case code, lineComment, blockComment, string, multilineString }

    var mode: Mode = .code
    var blockDepth = 0
    var code = ""
    var unmodeled: [String] = []
    var index = source.startIndex

    func upcoming(_ needle: String) -> Bool { source[index...].hasPrefix(needle) }
    func advance(_ distance: Int) {
        index =
            source.index(index, offsetBy: distance, limitedBy: source.endIndex) ?? source.endIndex
    }

    while index < source.endIndex {
        let character = source[index]
        switch mode {
        case .code:
            // Raw string：扫描器不建模它。记一笔（两个 suite 各有一条断言盯着这张清单），然后
            // 按普通字符串往下走 —— 反正那条断言已经红了，这之后的 `code` 本来就不该被信。
            if upcoming("#\"") {
                unmodeled.append("raw string literal (#\"…\"#)")
                code.append(character)
                advance(1)
                continue
            }
            if upcoming("\"\"\"") {
                mode = .multilineString
                code += "\"\"\""
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
            if character == "\"" { mode = .string }
            code.append(character)
            advance(1)

        case .lineComment:
            // 换行**保留**：行结构不能塌，否则 `range(of:)` 那几条顺序断言（notePanelHidden 必须在
            // `guard NSApp.isActive` 之前）读到的相对位置就不再是源码里的相对位置。
            if character == "\n" {
                mode = .code
                code.append(character)
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
            if character == "\n" { code.append(character) }
            advance(1)

        case .string:
            code.append(character)
            if character == "\\" {
                // 转义序列：`"\"//\""` 里那个 `\"` **不**结束字符串。整对一起吞掉。
                advance(1)
                if index < source.endIndex {
                    code.append(source[index])
                    advance(1)
                }
                continue
            }
            // 未闭合的单行字符串在 Swift 里编不过 —— 真撞上了就当场收手，别把文件剩下的部分
            // 整份当成字符串吞掉（那会让负向断言假绿，正是本节要杀的那个失效模式）。
            if character == "\"" || character == "\n" { mode = .code }
            advance(1)

        case .multilineString:
            if upcoming("\"\"\"") {
                mode = .code
                code += "\"\"\""
                advance(3)
                continue
            }
            code.append(character)
            advance(1)
        }
    }

    return StrippedSwiftSource(code: code, unmodeledConstructs: unmodeled)
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
