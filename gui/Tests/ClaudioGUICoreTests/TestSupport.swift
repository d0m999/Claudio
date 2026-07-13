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
// 现在两个包共用同一个**位置感知**的小状态机（代码 / 行注释 / 块注释 / 字符串 / 多行字符串），
// 字符串字面量里的 `//` 不再是注释起点，两半的洞一起堵上。完整推理见
// `helper/Tests/ClaudioCoreTests/TestSupport.swift` 里同一节（含「为什么不是把 ban 挪到 raw source」）。

/// 一份 Swift 源码**剥掉注释**之后的样子，外加一张「扫描器知道自己不认识」的构造清单。
///
/// 与 `helper/Tests/ClaudioCoreTests/TestSupport.swift` 里的那一份逐字相同 —— 按本文件头部的
/// 「测试 helper 跨包复制而非共享」约定复制。
struct StrippedSwiftSource {
    /// 注释已剥掉、**字符串字面量原样保留**的代码文本。
    let code: String
    /// 扫描器不建模的词法构造（目前只有 raw string 字面量 `#"…"#`）。
    ///
    /// 非空 = `code` 不再可信：任何基于它的**负向**断言都可能假绿。
    ///
    /// 这张清单是**位置感知**的（只在代码位置撞见 `#"` 才记）—— 必须如此：`ClaudioColorHex.swift`
    /// 与 `ContrastRatio.swift` 里的 `hasPrefix("#")` 逐字包含 `#"`，一条纯文本的 `#"` 守卫会当场
    /// 假红，然后被下一个人删掉，洞原样回来。
    let unmodeledConstructs: [String]
}

/// `source` 剥掉注释之后的样子。**字符串字面量里的 `//` 不是注释起点。**
///
/// 每一条行为都由 `SourceScannerSuite` 喂合成输入钉死（正向断言 —— 所以它不可能像它替掉的那条
/// `://` 守卫一样变成恒真式）。
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
            // 换行**保留**：行结构不能塌，否则 `range(of:)` 那几条顺序断言（`notePanelHidden()` 必须
            // 在 `guard NSApp.isActive` 之前）读到的相对位置就不再是源码里的相对位置。
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
