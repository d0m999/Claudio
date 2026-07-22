import Foundation

/// Single source of truth for every Claudio filesystem location (ENGINEERING.md 决议 4).
///
/// All Claudio-owned state (config / packs / bin / log / lock) lives under `~/.claudio/`
/// — a dot-folder with **no space in its path**. `Application Support` was rejected
/// because its path contains a space, and hook commands are written into
/// `settings.json` as a raw string executed via `/bin/sh -c` (confirmed by spike): a
/// space would get split by the shell and break the hook. `~/.claudio/` is safe under
/// both shell and argv execution models.
///
/// The **only** exception is `settings.json` itself, which stays where Claude Code put
/// it: `~/.claude/settings.json`.
public enum ClaudioPaths {
    /// The current user's home directory — the anchor for every path below.
    private static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// `~/.claudio/` — root of all Claudio-owned state.
    public static var root: URL {
        home.appendingPathComponent(".claudio", isDirectory: true)
    }

    /// `~/.claudio/config.json` — the single source of truth for user settings (GUI
    /// writes, `claudio play` only reads; see ENGINEERING.md「工程落地细节 ⑥ config.json 归属」).
    public static var configFile: URL {
        root.appendingPathComponent("config.json")
    }

    /// `~/.claudio/packs/` — user-installed sound packs, one subdirectory per pack id.
    public static var packsDirectory: URL {
        root.appendingPathComponent("packs", isDirectory: true)
    }

    /// `~/.claudio/packs/<id>/` — a single user pack's directory.
    public static func packDirectory(id: String) -> URL {
        packsDirectory.appendingPathComponent(id, isDirectory: true)
    }

    /// `~/.claudio/bin/` — the fixed, idempotency-friendly path the helper binary lives at,
    /// placed by the app install (`claudio install` itself only writes `settings.json`
    /// hooks; running it already requires this binary to exist). ENGINEERING.md「工程落地细节 ③
    /// helper 固定安装路径 + 幂等标记」, T2/T4 — *not* 决议 3, which is the per-event on/off switch.
    public static var binDirectory: URL {
        root.appendingPathComponent("bin", isDirectory: true)
    }

    /// `~/.claudio/bin/claudio` — the fixed install path whose absolute string is the
    /// exact-match token every `settings.json` hook command keys off (ENGINEERING.md
    /// 工程落地细节 ③: idempotent install / precise uninstall both compare against this
    /// exact path, never a substring).
    public static var claudioBinary: URL {
        binDirectory.appendingPathComponent("claudio")
    }

    /// `~/.claudio/claudio.log` — rolling diagnostic log (ENGINEERING.md 决议 6, T6).
    public static var logFile: URL {
        root.appendingPathComponent("claudio.log")
    }

    /// `~/.claudio/claudio.log.lock` — the non-blocking lock guarding `claudio.log`'s
    /// rotate-then-append sequence against concurrent tearing across processes
    /// (ENGINEERING.md 决议 6, T6; see ``FileLock``). Deliberately a **separate** lock from
    /// ``playLockFile`` (`play.lock`) — logging must never contend with, or be gated by,
    /// `play`'s own debounce lock.
    public static var logLockFile: URL {
        root.appendingPathComponent("claudio.log.lock")
    }

    /// `~/.claudio/play.lock` — the non-blocking lock guarding `play`'s skip-style
    /// debounce (ENGINEERING.md 决议 1 + 5, T5). See ``FileLock``.
    public static var playLockFile: URL {
        root.appendingPathComponent("play.lock")
    }

    /// `~/.claudio/config.lock` — the non-blocking lock serializing `config.json`'s
    /// read-modify-**write** critical section across its writers: `selectPack` (`claudio use`,
    /// the gallery, and `performFirstRunSetup`) and `setEventEnabled` (the GUI mute button —
    /// in-process, it has no CLI surface).
    ///
    /// **Writers only.** No reader takes this lock, by design: `play` loads `config.json`
    /// *outside* its critical section (``playSoundEvent(_:environment:)``), and `doctor` / the
    /// panel read it with no lock at all. What makes a concurrent read safe is
    /// ``updateConfigJSON(at:onMissing:mutate:)``'s temp-file + `rename(2)` atomic
    /// write — a reader sees the whole old file or the whole new one, never a torn one. A
    /// future reader that *takes* this lock, or a writer that drops `.atomic` because it
    /// believes the lock covers readers, reintroduces exactly the class this split closed.
    ///
    /// Deliberately **separate** from ``playLockFile`` — a config write must never contend
    /// with, or be gated by, `play`'s own debounce lock (that contention is exactly what was
    /// silently swallowing prompt sounds before this split).
    public static var configLockFile: URL {
        root.appendingPathComponent("config.lock")
    }

    /// `~/.claudio/settings.lock` — the non-blocking lock guarding install/uninstall of
    /// the Claudio hooks in `~/.claude/settings.json` (``SettingsInstaller``).
    /// Deliberately **separate** from both ``playLockFile`` and ``configLockFile`` — a
    /// settings.json install/uninstall must never contend with `play`'s debounce lock or
    /// a concurrent `config.json` read/write.
    public static var settingsLockFile: URL {
        root.appendingPathComponent("settings.lock")
    }

    /// `~/.claudio/packs.lock` — the non-blocking lock serializing the **three** writers of
    /// `~/.claudio/packs/`: the GUI's `mutateManifestJSON(at:lockFile:_:)` (bind/clear,
    /// `manifest.json`, byte level), the GUI's `importAudioFile` (drag-in persist step —
    /// create the pack directory + the atomic audio-file write), and the CLI's
    /// ``performFirstRunSetup(environment:)`` pack-publish loop (directory level — it
    /// `moveItem`s a whole user pack aside and `moveItem`s a bundled copy in).
    ///
    /// ⚠️ **这句「三个写者」曾经写的是「两个」，直到 `importAudioFile` 补上这把锁为止** —— 它此前
    /// 一直在 `packs/` 子树里建目录、原子写文件，却从不持锁，与下面「为什么它必须存在」那段治的是
    /// 同一类洞（同用户并发写者 + 无锁 = 丢更新 / 目录被换掉），只是入口从 `manifest.json` 换成了
    /// 音频文件本身。别把「两个写者」再读成穷举——加一个新的 `packs/` 写者，就要把这一行也改了。
    ///
    /// ## 为什么它必须存在（`/codex review b0ce657` 之后那次核查）
    /// `manifest.json` 此前是**零锁**的，理由写在 `ManifestBinding.swift` 的散文里：「只有一个
    /// 写者，而且全部在 `@MainActor` 上同步跑」。核查逐条证伪了这句话：
    ///  · `performFirstRunSetup` 是第二个写者，在第二个进程里，当时零锁 —— 而
    ///    `restoreBundledPacksHint` 与 `docs/distribution.md` 都在**主动教用户**去 Terminal 跑它。
    ///  · GUI 自己还把它派到主 actor 外（`OnboardingActions` 的 `Task.detached`），所以
    ///    「全部在 @MainActor」在**本进程内**也已经是假的。
    ///  · `.atomic` 写只挡撕裂（读者看到的要么整份旧的、要么整份新的），**挡不住丢更新**，
    ///    更挡不住 `moveItem` 在别人读到一半时把整个包目录换掉。
    ///
    /// ## 为什么是**一把**锁而不是每包一把
    /// 每包一把的锁文件只能住在包目录里，而 setup 的救砖路径会把**整个包目录挪走** —— 锁会跟着
    /// 一起走，互斥当场消失。所以锁住在 `packs/` **外面**，一把管整个 `packs/` 子树，与
    /// `config.lock` 管整个 `config.json` 同构。代价是一次 bind 会与一次**别的包**的 setup 争用；
    /// setup 罕见且短，这个代价是划算的。
    ///
    /// ## 为什么与 ``configLockFile`` 分开
    /// `performFirstRunSetup` 会**同时**需要这两把（包循环一把、写 `config.json` 一把）。合成
    /// 一把就是自己锁自己 —— 非阻塞锁下那不是死锁，是当场 `.skipped`，setup 每一次都失败。
    public static var packsLockFile: URL {
        root.appendingPathComponent("packs.lock")
    }

    /// `~/.claudio/play.state` — the single shared "last played" timestamp `play`'s
    /// time-based debounce reads and overwrites (ENGINEERING.md「并发 / 进程堆积处理」:
    /// 距上次播放（**任意**事件）< 1.5s 就跳过；决议 5: "一把锁 + 一个共享时间戳",
    /// deliberately event-agnostic, not a per-event map). Always read/written from *inside*
    /// `play.lock`'s critical section — see ``FileLock`` and `Play.swift` — never on its own,
    /// which would reopen the exact cross-process TOCTOU race decision 5 calls out
    /// (ENGINEERING.md「工程落地细节 ⑤ 跨进程并发」).
    public static var debounceStateFile: URL {
        root.appendingPathComponent("play.state")
    }

    /// `~/.claude/settings.json` — the only Claudio-relevant path outside `~/.claudio/`.
    public static var claudeSettingsFile: URL {
        home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }
}
