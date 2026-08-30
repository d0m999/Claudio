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
/// The only exceptions are host-owned configuration files. They stay under each host's
/// documented user configuration root and are modified only through their exact adapter.
public enum ClaudioPaths {
    /// The current user's home directory — the anchor for every path below.
    private static var home: URL {
        #if DEBUG
        // 真实 CLI 子进程测试同时隔离 ~/.claude 与 ~/.codex。Release 完全不编译该入口。
        if let testHome = ProcessInfo.processInfo.environment["CLAUDIO_TEST_HOME"],
            testHome.hasPrefix("/")
        {
            return URL(fileURLWithPath: testHome, isDirectory: true)
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// `~/.claudio/` — root of all Claudio-owned state.
    public static var root: URL {
        #if DEBUG
        // 真实 CLI 子进程契约测试需要把所有 hook I/O 隔离到临时目录。Release 构建完全
        // 不编译这条分支，因此用户环境无法通过进程变量改写生产固定路径。
        if let testRoot = ProcessInfo.processInfo.environment["CLAUDIO_TEST_ROOT"],
            testRoot.hasPrefix("/")
        {
            return URL(fileURLWithPath: testRoot, isDirectory: true)
        }
        #endif
        return home.appendingPathComponent(".claudio", isDirectory: true)
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

    /// `~/.claudio/bin/claudi0` — the user-facing CLI alias introduced by the brand rename.
    /// Host hooks deliberately keep using ``claudioBinary`` so existing exact-match ownership
    /// and uninstall behavior remain stable across upgrades.
    public static var claudi0Binary: URL {
        binDirectory.appendingPathComponent("claudi0")
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

    /// Claude Code 现代 adapter 与 legacy install 共用同一配置文件，因此必须共用同一把锁。
    public static var claudeIntegrationLockFile: URL { settingsLockFile }

    /// Codex hooks 配置拥有独立文件与独立锁；不得与 Claude 或声音播放互相争用。
    public static var codexIntegrationLockFile: URL {
        root.appendingPathComponent("codex-hooks.lock")
    }

    /// WorkBuddy Desktop hooks 配置拥有独立锁；不与 standalone CodeBuddy、Claude 或 Codex 共用。
    public static var workBuddyIntegrationLockFile: URL {
        root.appendingPathComponent("workbuddy-hooks.lock")
    }

    /// 宿主级连接/断开事务锁。配置文件自己的锁只保护一次 JSON
    /// read-modify-write；这把独立锁覆盖「配置变换 + legacy wrapper 迁移
    /// + active installation marker 发布/撤销」的整个操作，防止两个 CLI/GUI
    /// 进程交错成「已断开配置 + 仍有效旧 marker」。它不能与内层配置锁
    /// 同路径，否则非阻塞 `flock` 会让进程自己争用自己。
    public static func hostIntegrationOperationLockFile(_ host: HostID) -> URL {
        root.appendingPathComponent("\(host.rawValue)-operation.lock")
    }

    /// 双宿主回执与宿主级去抖状态的 Claudio 自有根目录。
    public static var integrationsDirectory: URL {
        root.appendingPathComponent("integrations", isDirectory: true)
    }

    public static var receiptsDirectory: URL {
        integrationsDirectory.appendingPathComponent("receipts", isDirectory: true)
    }

    /// 未确认的 shared-bootstrap 诊断状态；只含 Claudio 私有、可删除的语义记录。
    public static var bootstrapReportsDirectory: URL {
        root.appendingPathComponent("bootstrap-reports", isDirectory: true)
    }

    public static var bootstrapJournalFile: URL {
        root.appendingPathComponent("bootstrap-journal.json")
    }

    /// GUI 发布、helper 只消费的短期动态静默事实。目录与文件均不承载 Focus 名称、宿主内容或
    /// 个人路径；独立目录使权限与跨进程 revision 水位不污染 config / receipt 语义。
    public static var dynamicQuietDirectory: URL {
        dynamicQuietPaths.directory
    }

    public static var dynamicQuietSnapshotFile: URL {
        dynamicQuietPaths.snapshotFile
    }

    public static var dynamicQuietRevisionStateFile: URL {
        dynamicQuietPaths.revisionStateFile
    }

    public static var dynamicQuietLockFile: URL {
        dynamicQuietPaths.lockFile
    }

    private static var dynamicQuietPaths: DynamicQuietPaths {
        DynamicQuietPaths(rootDirectory: root)
    }

    public static var receiptLocksDirectory: URL {
        integrationsDirectory.appendingPathComponent("receipt-locks", isDirectory: true)
    }

    /// 当前宿主 installation 代次的最小标记。它与事件回执分开，断开/重连后可在
    /// 写入点拒绝迟到的旧 hook，而不是等旧回执覆盖后才在读取时发现。
    public static var activeInstallationsDirectory: URL {
        integrationsDirectory.appendingPathComponent("installations", isDirectory: true)
    }

    public static var activeInstallationLocksDirectory: URL {
        integrationsDirectory.appendingPathComponent("installation-locks", isDirectory: true)
    }

    /// 新版 hook 按宿主分锁、分时间戳；Claude 与 Codex 在 1.5 秒内的真实事件不会互相吞掉。
    public static func hostPlayLockFile(_ host: HostID) -> URL {
        integrationsDirectory.appendingPathComponent("\(host.rawValue)-play.lock")
    }

    public static func hostDebounceStateFile(_ host: HostID) -> URL {
        integrationsDirectory.appendingPathComponent("\(host.rawValue)-play.state")
    }

    /// `UserPromptSubmit` 专用 250ms 时间戳。它与 lifecycle 的 1.5s 时间戳分离，
    /// 但仍复用同一宿主的非阻塞播放锁，避免真正并发 spawn 互相踩踏。
    public static func hostTaskStartDebounceStateFile(_ host: HostID) -> URL {
        integrationsDirectory.appendingPathComponent("\(host.rawValue)-task-start.state")
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

    /// Codex 可组合 hooks 的公开配置文件。fresh connect 只操作这里，不接管 `notify`。
    public static var codexHooksFile: URL {
        home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("hooks.json")
    }

    /// 只用于旧版 `codex-notify` 冲突检测；fresh connect 不写该文件。
    public static var codexConfigFile: URL {
        home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml")
    }

    /// WorkBuddy Desktop 的用户级配置。项目级 `.workbuddy` / `.codebuddy` 永不由 Claudio 写入。
    public static var workBuddySettingsFile: URL {
        home
            .appendingPathComponent(".workbuddy", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    public static var legacyCodexNotifyWrapper: URL {
        binDirectory.appendingPathComponent("codex-notify")
    }
}
