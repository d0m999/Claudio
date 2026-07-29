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

/// A deterministic non-cooperating writer for the post-`lstat` import race regression. The
/// import is synchronous in these suites, but the hook is `@Sendable` to model a real external
/// writer, so the tiny mutable box serializes its single creation explicitly.
final class OneShotSymlinkOccupier: @unchecked Sendable {
    private let targetURL: URL
    private let lock = NSLock()
    private var didOccupy = false

    init(targetURL: URL) {
        self.targetURL = targetURL
    }

    func occupy(_ candidateURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard !didOccupy else { return }
        didOccupy = true
        try? FileManager.default.createSymbolicLink(at: candidateURL, withDestinationURL: targetURL)
    }
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
/// ⚠️ **这一段在 e278736 之后换了理由，别把旧说法读成现状**：那之前
/// `AudioImportEnvironment.packsLockFile` 有一个指向**真实** `~/.claudio/packs.lock` 的默认值，
/// 漏传的后果与漏传 `userPacksDirectory` 完全不同 —— 后者当场断言失败（真实 packs 目录里没有
/// fixture），而前者只会**静默**地去用户机器上开一把真锁：测试照样全绿，只是在用户 `~/.claudio/`
/// 里落一个 0 字节文件、并与他正在运行的 Claudio.app 抢锁。b89a0ee 那次实锤就是这么来的
/// （四个 fixture 漏传、八十余个调用点在用户真实 home 上开锁，2421 条全绿）。
///
/// **那个默认值现在已经拆掉**（`/codex review 95d16a5,b89a0ee,37745f2` 的 P1-A），漏传是一次
/// **编译错误**，由 `ViewWiringSuite` 那条「`packsLockFile` 不许有默认值」+ 便利 init / `extension`
/// 围栏一起钉住。所以今天这个函数存在的理由**不再是**「防止忘记」，而是：
///
/// 1. 给「必须递一把锁」这件事一个**唯一**的、结构性不可派生的答案（见下一节）；
/// 2. 挡住那条编译器管不到的路 —— 显式递 `ClaudioPaths.packsLockFile`。编译器逼的是「必须传」，
///    不是「必须传对」，而那一种是**响**的（写下这一行的人知道自己在写什么，且它出现在 diff 里），
///    与「静默漏传」不是一类；不声称封死。
///
/// ## 为什么位置**故意**不可从 `userPacksDirectory` 派生
///
/// 生产代码取这把锁的唯一合法写法是 `environment.packsLockFile`。任何「就地算一个出来」的写法
/// （`userPacksDirectory` 的兄弟位、`<packs>/packs.lock`、硬编码 `ClaudioPaths.packsLockFile`）都必须
/// 让持锁行为测试**当场红**。
///
/// ⚠️ **上一版这里写的办法是错的，别把它读成仍然成立**：它说「唯一办法是换父目录（`injected-locks/`）
/// **且**换叶名」。那是一份**枚举**，而枚举不完 —— `/codex review 37745f2` 的 P2 一行就证伪了它：
/// 向上**两级**再拼死那两个固定名字，求值出来与注入值逐字相同，四条自证断言一条都不会红。一个
/// **固定**的位置无论挪到哪里，总有一条路径表达式能把它拼回来。
///
/// 现在走的是**结构性**不可派生：父目录与叶名各带一段运行时 `UUID`。生产源码既写不出它（编译期
/// 不存在），也没有任何路径表达式能从别的 fixture 路径派生出它（那些路径里根本没有这段字节）。
/// 这不再是「我想不出还有什么写法能算出它」，而是「不存在这样的写法」。两样都要带：只带父目录，
/// `<父目录>/packs.lock` 这种硬编码叶名的写法仍然算得出；只带叶名，同父下的派生仍然算得出。
///
/// 这条性质由 `ManifestBindingSuite` 的第一条 suite 与 `OnboardingActionsSuite` 的 `FixtureTargets`
/// 自证共同钉住（两条都用「同一个 root 构造两次，父目录与叶名必须两次都不同」这个**关系**来表达，
/// 而不是去读它用了哪个随机源 —— 后者会是「守卫读被它守的那个函数的输出」，恒真）。
///
/// ## 「全包唯一来源」这句话是**可执行**的，不是承诺
///
/// 上一版这句话是假的：`OnboardingActionsSuite` 的 `FixtureTargets.init` 里另有一段**同形**的内联
/// 构造（`injected-locks-<nonce>/gui-packs-lock-<nonce>`）。代价不是理论上的 —— d7084be 那一刀
/// 为了同一个病要改**两处**，而它的 commit message 自己写着「Codex 只点了 FixtureTargets，
/// `injectedPacksLock` 是同一个形状」。两份拷贝就是两次要记得一起改。
///
/// 现在 `FixtureTargets` 改调本函数，全包真的只剩这一处；而「只剩一处」这件事由 `ViewWiringSuite`
/// 那条构造点普查钉住（认得出第二处 ⇒ 红）。如实标注它的天花板：那条普查按**这一种形状**的目录名
/// 认人，一个换了名字的第二处构造它认不出来 —— 它守的是「同一个病原样复发」，不是「所有可能的
/// 第二来源」。
///
/// 父目录不用预建：`FileLock.attemptLock()` 撞上 ENOENT 会自愈建父目录再重试一次。
func injectedPacksLock(under root: URL) -> URL {
    let nonce = UUID().uuidString
    return
        root
        .appendingPathComponent("injected-locks-\(nonce)", isDirectory: true)
        .appendingPathComponent("test-packs-lock-\(nonce)")
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
    factoryPacksDirectory: URL? = nil,
    duration: TimeInterval? = 1.0,
    maxFileSizeBytes: Int = 5 * 1024 * 1024,
    maxDurationSeconds: Double = 3.0
) -> AudioImportEnvironment {
    AudioImportEnvironment(
        userPacksDirectory: userPacksDirectory,
        bundledPacksDirectory: bundledPacksDirectory,
        factoryPacksDirectory: factoryPacksDirectory,
        durationProbe: StubDurationProbe(fixedDuration: duration),
        limits: AudioImportLimits(
            maxFileSizeBytes: maxFileSizeBytes, maxDurationSeconds: maxDurationSeconds),
        // 见 ``injectedPacksLock(under:)``：漏掉这一行，本 factory 吸收的三十余个调用点会**静默**
        // 在用户真实的 `~/.claudio/packs.lock` 上开锁。这个 factory 是全包最高杠杆的那一个。
        packsLockFile: injectedPacksLock(besideUserPacks: userPacksDirectory)
    )
}
