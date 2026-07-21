import ClaudioGUICore
import Foundation

// MARK: - T8 shared fixtures: minimal, correct magic-byte headers for each whitelisted
// format, plus content that must NOT sniff as audio no matter what extension it's given,
// and the stub `AudioDurationProbing` conformance every import suite injects.
//
// Not `private` (unlike most single-suite-file helpers elsewhere in this target) — these
// are deliberately shared across `AudioFormatSniffSuite.swift`, `AudioImportSuite.swift`,
// `AudioImportBatchSuite.swift`, and `AudioImportViewModelSuite.swift`, mirroring how
// `TestSupport.swift`'s helpers are shared, just scoped to audio-import fixtures instead
// of generic filesystem fixtures.

/// A tiny-but-structurally-correct RIFF/WAVE header, followed by harmless padding — real
/// `afplay`/AVFoundation would likely refuse to actually *play* this (no real `fmt `/
/// `data` chunk payload), but `sniffAudioFormat` only inspects the container header, which
/// this satisfies exactly like a real WAV file's first 12 bytes would.
func validWAVData() -> Data {
    var data = Data("RIFF".utf8)
    data.append(contentsOf: [0x24, 0x00, 0x00, 0x00])
    data.append(Data("WAVEfmt ".utf8))
    data.append(Data(repeating: 0, count: 16))
    return data
}

func validAIFFData() -> Data {
    var data = Data("FORM".utf8)
    data.append(contentsOf: [0x00, 0x00, 0x00, 0x20])
    data.append(Data("AIFFCOMM".utf8))
    data.append(Data(repeating: 0, count: 16))
    return data
}

/// A real-world-shaped MP3: ID3v2 tag header first (the common case), not a bare frame
/// sync — see ``validMP3FrameSyncData()`` for that variant.
func validMP3ID3Data() -> Data {
    var data = Data("ID3".utf8)
    data.append(contentsOf: [0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    data.append(Data(repeating: 0, count: 32))
    return data
}

func validMP3FrameSyncData() -> Data {
    var data = Data([0xFF, 0xFB, 0x90, 0x00])
    data.append(Data(repeating: 0, count: 32))
    return data
}

/// `ftyp` box with an audio major brand (`"M4A "`), plus a `moov` marker elsewhere in the
/// file — both signals ``sniffAudioFormat(_:)`` requires for `.m4a`.
func validM4AData() -> Data {
    var data = Data([0x00, 0x00, 0x00, 0x18])
    data.append(Data("ftyp".utf8))
    data.append(Data("M4A ".utf8))
    data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
    data.append(Data("isomM4A ".utf8))
    data.append(Data("moov".utf8))
    data.append(Data(repeating: 0, count: 16))
    return data
}

/// A plain shell script — the extension-spoofing attack vector: this gets a `.mp3`
/// filename in the fixtures that use it, despite being unrelated content.
func evilShellScriptData() -> Data {
    Data("#!/bin/sh\necho pwned\n".utf8)
}

/// A stub `AudioDurationProbing` conformance — the DI seam T8 acceptance criterion 4
/// requires, so this Foundation-only test module never needs AVFoundation either.
struct StubDurationProbe: AudioDurationProbing {
    let fixedDuration: TimeInterval?
    func probeDuration(of fileURL: URL) -> TimeInterval? { fixedDuration }
}

/// A stub that additionally *records* which URL (and its on-disk bytes) it was handed, so a
/// test can assert the import pipeline probes duration on a validated copy of the bytes it
/// will persist — never by re-opening the original `sourceURL` (T8 codex P2: closes the
/// same-user TOCTOU window between the content read and the duration probe).
///
/// `@unchecked Sendable`: it carries mutable recorded state, but the suites that use it call
/// `importAudioFile` **synchronously** on the `@MainActor` (unlike `AudioImportViewModel`,
/// which hops the pipeline onto a `Task.detached`), so the recording is only ever written
/// and read from that one actor — no actual cross-thread access occurs.
final class RecordingDurationProbe: AudioDurationProbing, @unchecked Sendable {
    let fixedDuration: TimeInterval?
    private(set) var probedURL: URL?
    private(set) var probedBytes: Data?

    init(fixedDuration: TimeInterval?) { self.fixedDuration = fixedDuration }

    func probeDuration(of fileURL: URL) -> TimeInterval? {
        probedURL = fileURL
        probedBytes = try? Data(contentsOf: fileURL)
        return fixedDuration
    }
}

/// 本测试包注入给 `AudioImportEnvironment` / `mutateManifestJSON` 的那把包锁 —— **全包唯一来源**。
///
/// ## 为什么每个 fixture 都必须显式递它
///
/// `AudioImportEnvironment.packsLockFile` 的默认值是**真实**的 `~/.claudio/packs.lock`。忘记注入的
/// 后果与忘记注入 `userPacksDirectory` **完全不同**：后者会当场断言失败（真实 packs 目录里没有
/// fixture），而前者只会**静默**地去用户机器上开一把真锁 —— 测试照样全绿，只是在用户
/// `~/.claudio/` 里落一个 0 字节文件、并与他正在运行的 Claudio.app 抢锁。静默那种才是危险的。
///
/// ## 为什么位置**故意**不可从 `userPacksDirectory` 派生
///
/// 生产代码取这把锁的唯一合法写法是 `environment.packsLockFile`。任何「就地算一个出来」的写法
/// （`userPacksDirectory` 的兄弟位、`<packs>/packs.lock`、硬编码 `ClaudioPaths.packsLockFile`）都必须
/// 让持锁行为测试**当场红**。做到这一点的唯一办法是让注入值待在那些表达式**算不出来**的地方：
/// 换父目录（`injected-locks/`）**且**换叶名（不是 `packs.lock`）。只换一样都不够。
///
/// 这条性质由 `ManifestBindingSuite` 的第一条 suite（fixture 自证）钉住 —— 那是本包唯一真的会去
/// **持有**这把锁的地方，也是唯一能分辨「转发对了」与「就地算了一个」的地方。
///
/// 父目录不用预建：`FileLock.attemptLock()` 撞上 ENOENT 会自愈建父目录再重试一次。
func injectedPacksLock(under root: URL) -> URL {
    root
        .appendingPathComponent("injected-locks", isDirectory: true)
        .appendingPathComponent("test-packs-lock")
}

/// `userPacksDirectory` 的兄弟位上那把注入锁 —— 给只拿得到 packs 目录、拿不到 `root` 的 fixture 用。
///
/// 各 suite 的布局一律是 `<root>/packs`，所以 `deletingLastPathComponent()` 就是 `root`。
@MainActor
func injectedPacksLock(besideUserPacks userPacksDirectory: URL) -> URL {
    injectedPacksLock(under: userPacksDirectory.deletingLastPathComponent())
}

@MainActor
func makeAudioImportEnvironment(
    userPacksDirectory: URL,
    bundledPacksDirectory: URL? = nil,
    duration: TimeInterval? = 1.0,
    maxFileSizeBytes: Int = 5 * 1024 * 1024,
    maxDurationSeconds: Double = 3.0
) -> AudioImportEnvironment {
    AudioImportEnvironment(
        userPacksDirectory: userPacksDirectory,
        bundledPacksDirectory: bundledPacksDirectory,
        durationProbe: StubDurationProbe(fixedDuration: duration),
        limits: AudioImportLimits(
            maxFileSizeBytes: maxFileSizeBytes, maxDurationSeconds: maxDurationSeconds),
        // 见 ``injectedPacksLock(under:)``：漏掉这一行，本 factory 吸收的三十余个调用点会**静默**
        // 在用户真实的 `~/.claudio/packs.lock` 上开锁。这个 factory 是全包最高杠杆的那一个。
        packsLockFile: injectedPacksLock(besideUserPacks: userPacksDirectory)
    )
}
