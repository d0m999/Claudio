import Foundation

/// `claudio setup` — v1 Terminal 首次安装自举（ENGINEERING.md T17, Distribution Plan「接管
/// 机制」v1 过渡）.
///
/// Closes the gap a codex review of T11+T12 (commits 10f00cf/f31987b) surfaced: `release.yml`
/// ships the helper CLI + `minimal-chime` inside `Claudio.app`'s `Contents/Resources/`, but
/// nothing ever copies either out to `~/.claudio/` — "the app install" `Paths.swift`
/// documents as owning that step doesn't exist anywhere in code, and the real menu bar
/// shell that would trigger it (T15) hasn't landed. This is the interim, Terminal-runnable
/// substitute: run once from *inside* the app bundle (e.g.
/// `/Applications/Claudio.app/Contents/Resources/bin/claudio setup`) and it places the
/// binary, seeds a default pack selection, and installs hooks — the same three side effects
/// T15's onboarding CTA is expected to trigger automatically once it exists.

// MARK: - Environment (injectable, mirrors `PlayEnvironment`/`DoctorEnvironment`)

public struct SetupEnvironment: Sendable {
    /// The absolute, symlink-resolved path to the binary currently executing `claudio
    /// setup`. Real callers derive this from `CommandLine.arguments[0]` via
    /// ``currentExecutablePath(arguments:currentDirectory:)`` — there's no meaningful
    /// static default, since it's inherently "wherever this process happens to be running
    /// from".
    public let executablePath: URL
    public let claudioBinaryDestination: URL
    public let userPacksDirectory: URL
    public let configFile: URL
    public let settingsFile: URL
    /// Guards the `selectPack` read-modify-write against `config.json` (T17e's pack-selection
    /// repair step below writes through here). Deliberately **separate** from
    /// ``settingsLockFile`` — the two files (`config.json`, `settings.json`) have independent
    /// writers and must never contend with, or be gated by, each other's lock.
    public let configLockFile: URL
    /// Guards ``installClaudioHooks(settingsFile:claudioBinaryPath:lockFile:)``'s
    /// read-modify-write against `settings.json`. Deliberately **separate** from
    /// ``configLockFile`` — see that property's doc comment.
    public let settingsLockFile: URL
    /// Guards the pack-publish loop below — the **directory-level** writer of
    /// `manifest.json`（`moveItem` 挪走用户整个包目录、`copyItem`→`moveItem` 发布内置包）。
    /// 与 GUI 的 `mutateManifestJSON(at:lockFile:_:)` 共用同一把 `~/.claudio/packs.lock`：
    /// 这两个才是 `manifest.json` 真正的两个写者，此前它们之间零互斥。
    /// 见 ``ClaudioPaths/packsLockFile``。
    public let packsLockFile: URL

    public init(
        executablePath: URL,
        claudioBinaryDestination: URL = ClaudioPaths.claudioBinary,
        userPacksDirectory: URL = ClaudioPaths.packsDirectory,
        configFile: URL = ClaudioPaths.configFile,
        settingsFile: URL = ClaudioPaths.claudeSettingsFile,
        configLockFile: URL = ClaudioPaths.configLockFile,
        settingsLockFile: URL = ClaudioPaths.settingsLockFile,
        packsLockFile: URL = ClaudioPaths.packsLockFile
    ) {
        self.executablePath = executablePath
        self.claudioBinaryDestination = claudioBinaryDestination
        self.userPacksDirectory = userPacksDirectory
        self.configFile = configFile
        self.settingsFile = settingsFile
        self.configLockFile = configLockFile
        self.settingsLockFile = settingsLockFile
        self.packsLockFile = packsLockFile
    }
}

/// ``performFirstRunSetup(environment:)`` 的**包发布临界区** —— 只在持有 `packs.lock` 时被调用。
///
/// 单独抽成一个函数，而不是在调用点内联一个闭包，有两个理由：
///  ① 原来的代码里散着五处 `return .failure(...)`。内联进闭包之后那些 `return` 会变成「从闭包
///     返回」，函数照常往下走去写 hooks —— 一次静默的语义改变，编译器不会喊。
///  ② 「锁的作用域 == 整段发布」在源码上一眼可判：临界区是一个函数体，而不是一段后来者可能
///     不小心挪出去半截的内联代码。同一个理由见 `ManifestBinding.swift` 的 `performManifestMutation`。
private func publishBundledPacks(
    from bundledPacksDirectory: URL, environment: SetupEnvironment
) -> Result<(copied: [String], salvaged: [SalvagedPack]), SetupError> {
    var copiedPackIDs: [String] = []
    var salvagedPacks: [SalvagedPack] = []
    let packIDs =
        ((try? FileManager.default.contentsOfDirectory(atPath: bundledPacksDirectory.path)) ?? [])
        .sorted()
    if !packIDs.isEmpty {
        // Hoisted out of the per-pack loop below: the destination directory never
        // changes across iterations, so creating it once (idempotent — `createDirectory`
        // no-ops if it already exists) does the same work as calling it once per pack,
        // minus the redundant mkdir/stat syscalls.
        do {
            try FileManager.default.createDirectory(
                at: environment.userPacksDirectory, withIntermediateDirectories: true)
        } catch {
            return .failure(
                .packCopyFailure(reason: "创建 ~/.claudio/packs 失败：\(error.localizedDescription)")
            )
        }
    }
    for id in packIDs {
        let source = bundledPacksDirectory.appendingPathComponent(id, isDirectory: true)
        guard directoryExists(at: source) else { continue }
        let destination = environment.userPacksDirectory.appendingPathComponent(
            id, isDirectory: true)

        // Never clobber a same-id pack the user already has (could be their own
        // customized copy) — mirrors `resolvePackDirectory`'s "user root wins"
        // rule by simply not overwriting it in the first place.
        //
        // T17e：判据从「目录存在」收紧成「目录存在**且它真的是一个包**（manifest 读得出来）」。
        // 上一版把**任何**同名目录都当成「用户自己的定制包」而跳过 —— 包括一次**被杀掉的
        // setup 留下的半个包**（`copyItem` 逐文件写最终路径，不是原子的）。于是：残骸永远
        // 不会被补全 → 它不是一个能用的包 → 这台机器一个能用的包都没有 → setup 每一次重跑都
        // 一字不差地失败。**永久死锁**，而 `docs/distribution.md` 白纸黑字承诺「重跑一次
        // setup 就能治好坏安装」。（T17e 对抗评审实测复现。）
        //
        // 一个 manifest 都读不出来的目录**不是**用户的包，它是一堆残骸。所以：挪开它，重来。
        if isUsablePack(id, in: environment.userPacksDirectory) { continue }

        // `fileExists` **跟随符号链接**：一条指向不存在之物的悬空链接，它回答「不存在」。于是
        // 那条链接会从这个判据的缝里漏过去，直奔下面的 `moveItem` —— 而 `moveItem` 用的是 lstat
        // 语义，它看得见那条链接，抛 EEXIST。结果：`.packCopyFailure`，hooks 不写，**每一次重跑
        // 都一字不差地失败**，而报错指向的是一个刚刚被 catch 块删掉的隐藏暂存目录（对抗评审实测：
        // NSCocoaErrorDomain 516 / EEXIST）。
        //
        // 这一格在本函数**自己**的契约里（「目标存在、但它不是一个能用的包 → 挪开它」）本来就该
        // 走挪开分支：一条悬空链接在 lstat 意义上**存在**，而且显然不是一个能用的包。所以判据必须
        // 与 `moveItem` 用同一套语义 —— `attributesOfItem` 就是 lstat 语义（不跟随链接）。
        if (try? FileManager.default.attributesOfItem(atPath: destination.path)) != nil {
            // **挪走，不是删掉**：那堆残骸里可能有用户自己塞进去的东西（谁也没资格替他判
            // 「这个文件不重要」）。点开头 → `availablePackIDs` 天然把它排除在选包之外。
            //
            // 名字撞了就往后找一个没人占的，**绝不覆盖已经挪过去的那一份**：pid 会被系统复用
            // （重启之后尤其容易），而一句顺手的 `removeItem(aside)` 在那一刻删掉的，正是上一次
            // 挪走的、里面装着用户文件的那个目录 —— 一条真实的数据丢失路径。
            let base = ".\(id).broken-\(ProcessInfo.processInfo.processIdentifier)"
            var aside = environment.userPacksDirectory.appendingPathComponent(
                base, isDirectory: true)
            var attempt = 1
            while FileManager.default.fileExists(atPath: aside.path) {
                attempt += 1
                aside = environment.userPacksDirectory.appendingPathComponent(
                    "\(base)-\(attempt)", isDirectory: true)
            }
            do {
                try FileManager.default.moveItem(at: destination, to: aside)
                salvagedPacks.append(
                    SalvagedPack(packID: id, movedTo: aside.path))
            } catch {
                return .failure(
                    .packCopyFailure(
                        reason:
                            "\(id)：\(destination.path) 是一个读不出 manifest 的目录"
                            + "（多半是上一次安装被中断留下的残骸，也可能是你自己的包的 manifest 坏了），"
                            + "而它挪不开：\(error.localizedDescription)。"
                            + "把它改个名或删掉，再跑一次 setup。"))
            }
        }

        // **原子复制**（T17e）：先写进一个点开头的暂存目录，成功之后再 rename 到最终名字。
        // 同卷 rename 是原子的，所以一次被杀掉的 setup 只可能留下 `.<id>.tmp-<pid>`（点开头 →
        // `availablePackIDs` 选包时天然被排除），**永远不会在最终路径上留下半个包**。
        // 上一版的注释早就声称这里是这么做的 —— 而代码里根本没有。谎言恰好盖住了新闸门最现实
        // 的触发输入（T17e 对抗评审）。现在它是真的了。
        // ⚠️ 那个留下的暂存目录**不会被自动清掉**（`:444` 的 `removeItem` 只删当前 pid 那一份）——
        // 与 `copySelfToFixedLocation` 的 `.claudio.tmp-…` 同理，危害为零、不顺手 glob 删的理由
        // 也同理（会误删并发存活的 setup 的暂存）。
        let staging = environment.userPacksDirectory.appendingPathComponent(
            ".\(id).tmp-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        do {
            try FileManager.default.copyItem(at: source, to: staging)
            // `copyItem` carries `com.apple.quarantine` across (see Quarantine.swift).
            // Audio files aren't exec-gated the way the binary is, so this one is
            // hygiene rather than load-bearing — but leaving half the tree we just
            // wrote stamped 「从网上来的」 only invites someone to rediscover the same
            // xattr later, in a context where it DOES bite.
            stripQuarantineAttribute(at: staging)
            try FileManager.default.moveItem(at: staging, to: destination)
            copiedPackIDs.append(id)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            return .failure(
                .packCopyFailure(reason: "\(id)：\(error.localizedDescription)"))
        }
    }

    return .success((copied: copiedPackIDs, salvaged: salvagedPacks))
}

// MARK: - 这次 setup 该拿「选包」怎么办（T17e 的全部政策，一个纯函数）

/// 一次 setup 对 `config.json` 的 `selected_pack` 所能做的全部事情。
public enum PackSelectionPlan: Sendable, Equatable {
    /// 用户已有的选择解析得出来 —— 一个字节都不动它。
    case keepExistingSelection
    /// 还没有人选过包（config 不在，或 `selected_pack` 是空串）→ 挑一个默认的。
    case selectDefault(packID: String)
    /// **他选的那个包已经不在了 / 坏了**，但磁盘上还有能用的 → 替他换上一个，并**如实说出来**。
    ///
    /// 这条是 T17e 第二轮对抗评审（两个独立 agent 各自实测复现）逼出来的**推翻**：本函数的上一版
    /// 在这里是**硬失败**（「绝不替用户改选，那是伪造一次他没做过的选择」）。那个推理听起来对，
    /// 后果却是灾难性的 —— 因为**换包的唯一界面（`PackGalleryView`）只在面板 `.installed` 时渲染**，
    /// 而 `.installed` 需要 hooks。于是「他选的包没了 + hooks 还没装」的用户被硬失败挡住 →
    /// 永远进不了 `.installed` → **永远够不到那个能救他的画廊**，只剩一句要开终端的 `claudio use`。
    /// 而在硬失败之前，他本来会拿到四行 `.unmapped` + 画廊里躺着的 minimal-chime —— **点一下就好了**。
    ///
    /// 「不伪造选择」这条原则本身没错，它防的是 `setEventEnabled` 那条路（**从没选过包**时凭空
    /// 编一个默认值）。但一个**指向不存在之物的选择不是选择，是一根悬空的指针**：保住它，保住的
    /// 不是用户的意愿，而是一台哑机器。所以这里修好它，并且把「我替你换了」这件事一路传到
    /// ``SetupOutcome`` → CLI 的摘要里 —— 用户随时可以在画廊里换回去（那正是他现在够得到的界面）。
    case repairDeadSelection(removed: String, selected: String)
    /// 还没有人选过包，而且磁盘上一个能用的包都没有。
    case failNoPackAtAll
    /// 他选的包没了 / 坏了，而且**没有任何一个能顶上的包** —— 此时画廊本来就是空的，
    /// 写 hooks 只会得到纯静音，所以这是真正该硬失败的那个格子。
    case failDeadSelectionNoFallback(packID: String)
    /// `config.json` 读不出来 —— 不选包、更不覆盖它（自举没有能力修一份读不懂的文件），
    /// 但也绝不在它之上写 hooks：`play` 的第一步就会返回 nil → 每个事件静默无声。
    case failConfigUnusable(reason: String)
}

/// T17e 的全部政策，一个纯函数 —— 于是它能被一张表逐格钉死（`SetupSuite`）。
///
/// **它刻意不碰磁盘**：抽成纯函数不是为了好看，是为了它能被测。仓库里已有先例
/// （`quarantineVerdict(getxattrReturned:errnoValue:)` —— 判据留在 IO 函数里的话，把某个分支改回去
/// 全套测试照样绿，实测确认过）。这里同样：`.failConfigUnusable` / `.failDeadSelectionNoFallback`
/// 这些格子在真实临时目录里要么造不出来、要么造起来极其别扭，判据一旦混在 IO 里就必然失守。
///
/// - Parameters:
///   - status: 这台机器此刻的包完整性 —— 由 ``checkPackIntegrity(configFile:userPacksDirectory:bundledPacksDirectory:)``
///     给出，也就是 `doctor` 用的那条链，与 `play` 的解析路径**逐字同源**。绝不在这里另写一套「可用」
///     的定义：两套判据不一致的那一天，就是又一次静默失声的那一天。
///   - usablePackIDs: 磁盘上**真正能用**的包（目录解析得出来 **且** manifest 读得出来），已排序。
///     判据必须与 `status` 同源 —— 上一版这里用的是「目录存在」，于是 setup 会**自己**选中一个
///     读不出 manifest 的残骸目录，再被自己的闸门判死：一台全新机器直接装不上（对抗评审实测）。
public func packSelectionPlan(
    status: PackIntegrityStatus, usablePackIDs: [String]
) -> PackSelectionPlan {
    switch status {
    case .complete, .incomplete:
        // 「内容」层的缺口（某个事件没声音 / 声明了但文件不在）**不是**坏管道：面板的四行覆盖度会把它
        // 逐行画成 `.unmapped` / `.broken`，用户看得见、拖一个文件进去就能修。拦住他只会把他挡在
        // 唯一能修好它的界面之外。
        return .keepExistingSelection

    case .configUnreadable(let reason):
        return .failConfigUnusable(reason: reason)

    // `selected_pack` 是空串 = 还没有人选过包。这条路必须留着，但它的产地已经变了（D23 定稿①）：
    // 静音钮再也不会写出这份 config 了——`setEventEnabled` 现在对缺失的 config.json fail closed
    // （见 `EventEnabled.swift`），磁盘上不会再凭空长出一份 `selected_pack: ""`。这一支今天只在
    // 两种情况下被走到：`.noConfig`（全新机器，与这一支本就是同一件事）；或者一份手工编辑 /
    // 第三方写出的 config.json 恰好把 `selected_pack` 留空——那同样是「还没有人选」，不是「选了
    // 一个空的」，不该被当成 packNotFound 硬失败。`resolvePackDirectory("")` 解不出来，于是它
    // 在这里表现为 `.packNotFound("")` —— 与「config 压根不在」是同一件事。
    case .noConfig, .packNotFound(""):
        guard let first = usablePackIDs.first else { return .failNoPackAtAll }
        return .selectDefault(packID: first)

    case .packNotFound(let packID):
        guard let first = usablePackIDs.first else {
            return .failDeadSelectionNoFallback(packID: packID)
        }
        return .repairDeadSelection(removed: packID, selected: first)

    case .manifestUnreadable(let packID, _):
        guard let first = usablePackIDs.first else {
            return .failDeadSelectionNoFallback(packID: packID)
        }
        return .repairDeadSelection(removed: packID, selected: first)
    }
}

/// `argv[0]` — absolute if invoked with a full path (the common case when a user pastes
/// the path printed by `docs/distribution.md`'s Terminal instructions; also true once
/// re-invoked from the fixed `~/.claudio/bin/claudio` destination), relative-to-`currentDirectory`
/// if invoked as `./claudio` or `../some/dir/claudio`.
///
/// **Known gap (Codex adversarial review, `/ship` pre-landing, tracked in TODOS.md):**
/// a bare name with no `/` at all (e.g. plain `claudio`, found via a `$PATH` lookup the
/// *shell* performed) is NOT actually resolved against `PATH` here — it falls into the
/// same branch as `./claudio` and gets treated as relative to `currentDirectory`, which is
/// wrong: the shell may have found the real binary somewhere else on `PATH` entirely. This
/// only misresolves when Claudio isn't invoked with a `/` in the command at all, which
/// `docs/distribution.md`'s own instructions never do — but it's still a latent bug for
/// anyone who's added `~/.claudio/bin` to their own `PATH` and runs bare `claudio setup`
/// from an unrelated directory.
public func currentExecutablePath(
    arguments: [String] = CommandLine.arguments,
    currentDirectory: String = FileManager.default.currentDirectoryPath
) -> URL {
    let raw = arguments[0]
    let url =
        raw.hasPrefix("/")
        ? URL(fileURLWithPath: raw)
        : URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: currentDirectory, isDirectory: true))
    return url.resolvingSymlinksInPath()
}

// MARK: - Outcome / errors

public enum SetupOutcome: Sendable, Equatable {
    /// `copiedPacks` lists the bundled-pack ids that were newly copied into
    /// `userPacksDirectory` this run (empty if none were new, or if setup wasn't running
    /// from inside a bundle at all). `packSelection` 说的是这次 setup 对 `selected_pack`
    /// **做了什么**——见 ``PackSelectionPlan``。它刻意不是一个 `String?`：一次「替你换掉了一个
    /// 已经不在的包」与一次「首次默认选包」在用户那里是**两件完全不同的事**，前者必须被说出来
    /// （`printSetupSummary` 会把它印成一行 ⚠），而 `String?` 结构上就说不出这个区别。
    case completed(
        copiedBinary: Bool, copiedPacks: [String], salvaged: [SalvagedPack],
        packSelection: PackSelectionOutcome, hooksOutcome: InstallOutcome)
}

/// 一个**读不出 manifest** 的同名目录被原样搬走了（不是删掉）—— 它必须能被说出来。
///
/// 搬走一个用户目录，是这次 setup 里代价最大的一个「我替你做了一个你没让我做的决定」。而那个目录里
/// 完全可能装着**他自己导入的音频**（`AudioImport` 把转码后的字节写进 `packs/<id>/`，那往往是那份声音
/// 在磁盘上唯一的副本）—— 只要他把同一个包的 `manifest.json` 弄坏了（手改时多打一个逗号、解压了一个没写
/// `id` 字段的第三方包），这个目录就会被判成「不是一个能用的包」。
///
/// 上一版把它搬进一个**点开头**的隐藏目录，然后一个字都不说：`PackGallery` 显式过滤点开头目录，
/// 于是它在**任何界面里都不存在**；`SetupOutcome` 结构上也承载不了这件事。用户的音频就那样从他的世界里
/// 消失了，而 Claudio 报告的是成功（T17e 第二轮对抗评审）。
///
/// 现在它是 outcome 的一等公民：CLI 会把它印成一行 ⚠，连同**绝对路径**和一句「一个文件都没有删」。
public struct SalvagedPack: Sendable, Equatable {
    public let packID: String
    /// 它现在在哪儿 —— 绝对路径，用户复制粘贴就能去看。
    public let movedTo: String

    public init(packID: String, movedTo: String) {
        self.packID = packID
        self.movedTo = movedTo
    }
}

/// 这次 setup 对 `selected_pack` 实际做了什么（``PackSelectionPlan`` 里那三条**成功**分支的结果）。
public enum PackSelectionOutcome: Sendable, Equatable {
    /// 用户已有的选择好好的 —— 一个字节都没动。
    case untouched
    /// 首次自举挑了一个默认包。
    case selectedDefault(packID: String)
    /// 他选的包已经不在了 / 读不出来 —— 替他换上了**另一个还读得出来的包**。**必须让他知道。**
    ///
    /// 措辞刻意不是「一个能响的」（T17g，codex 独立评审逮到）：顶替者只过了一道 ``isUsablePack(_:in:)``，
    /// 而那个函数自己的文档写得很清楚 —— 它查目录、查 manifest，**一个字节的音频都不查**。
    /// `usablePackIDs.first` 又是按字典序挑的，所以完全可能挑中一个只映了部分事件的用户自导入包：
    /// 换完之后，那些没映到的事件依旧是哑的。
    ///
    /// 这条区别不是咬文嚼字 —— GUI 侧的告知文案曾照着「能响的」这个措辞对用户承诺「这样每个事件都还能
    /// 出声」，而用户在同一张面板上就能看见三行「未配置」。文案已改；这里的措辞跟着改，免得下一个人
    /// 又从这句注释里读出那个错误的保证。
    case repairedDeadSelection(removed: String, selected: String)
}

public enum SetupError: Error, Sendable, Equatable, CustomStringConvertible {
    case binaryCopyFailure(reason: String)
    /// 取不到 `~/.claudio/packs.lock` —— GUI 此刻正在写 `manifest.json`（bind/clear）。
    /// 包**一个都没发布**，hooks 也**一个字节都没写**。
    ///
    /// 为什么是失败而不是「跳过包、照常装」：与 ``binaryQuarantined`` / ``noAvailablePack``
    /// 同一条纪律 —— **只要这次安装注定是哑的，就不许把它报成成功**。包没发布出去而 hooks
    /// 写了，用户拿到的正是一台亮着绿点、`doctor` 也过、却永远不响的机器。
    case packsLockBusy
    /// 取包锁时撞上真的系统错误（不是争用）。与 ``packsLockBusy`` 分开的理由同 ``FileLock``：
    /// 把真错误说成「忙，等一下重试」会让用户永远重试下去。
    case packsLockFailed(errno: Int32)
    case packCopyFailure(reason: String)
    /// The installed `~/.claudio/bin/claudio` still carries `com.apple.quarantine` after we
    /// tried to strip it (see ``Quarantine.swift``). Hooks are deliberately **not** written in
    /// this case: every one of them would be SIGKILLed by Gatekeeper the moment Claude Code ran
    /// it, and `play` is fire-and-forget, so the user would get an install that reports success,
    /// shows a green dot, passes `doctor` — and never makes a sound. A loud failure here is the
    /// only honest outcome.
    case binaryQuarantined(reason: String)
    /// 一个包都没有，而且此前也从没选过包 —— 于是这次 setup 会写下四条 hooks，指向一个
    /// **`selected_pack` 为空**的 config。
    ///
    /// 后果与 ``binaryQuarantined`` **一字不差**：`claudio play` 拿不到包会返回 `.notReady`，
    /// 而 `play` 是 fire-and-forget（拿不到退出码、不写日志），所以每一个 Claude Code 事件都会
    /// **静默无声**；面板照样亮绿点说「已经接好了」（`detectOnboardingState` 只查二进制 + hooks，
    /// 不查包）。这正是 T17 存在的理由那句话——「装完后是哑的」——的又一个形状。
    ///
    /// 所以 hooks 在这里同样**不写**。这不是保守，这是与 ``binaryQuarantined`` 同一条纪律：
    /// **只要这次安装注定是哑的，就不许把它报成成功。**
    ///
    /// ⚠️ 这条错误**推翻了一条既有的回归测试的断言**（`SetupSuite`「no sibling packs/ still copies
    /// the binary」，Codex + Claude 上一轮 `/ship` 对抗评审加的）。那条测试的**本意**原样成立、
    /// 且仍被钉着：二进制的复制**不能**被 packs/ 目录的存在与否卡住（它在这条失败返回之前就已经
    /// 落盘了）。它当年防的是「hooks 指向一个不存在的二进制」；它没想到的是「hooks 指向一个有
    /// 二进制、却没有任何包的安装」—— 同样的静默，另一个成因。
    case noAvailablePack(reason: String)
    /// 他选的那个包已经不在了 / 读不出来，**而且磁盘上没有任何一个能顶上的包**（T17e）。
    ///
    /// ## 为什么只有「没有任何能顶上的包」时才失败
    ///
    /// 因为**换包的唯一界面（`PackGalleryView`）只在面板 `.installed` 时渲染**，而 `.installed`
    /// 需要 hooks。所以只要磁盘上还有一个能用的包，硬失败就等于**把用户永久挡在唯一能救他的界面
    /// 之外**（T17e 第二轮对抗评审实测复现：两个独立 agent 各自走通了这条死路）。那种情况下正确的
    /// 动作是**修好它**——见 ``PackSelectionPlan/repairDeadSelection(removed:selected:)``。
    ///
    /// 走到这条错误时，画廊里**本来就一个包都没有**：写 hooks 只会得到一台纯静音的机器，而用户
    /// 在 app 里无论如何都点不出声音来。此时大声失败是唯一诚实的动作，与 ``binaryQuarantined`` /
    /// ``noAvailablePack`` 同一条纪律：**只要这次安装注定是哑的，就不许把它报成成功。**
    case selectedPackUnresolvable(packID: String, reason: String)
    /// `config.json` 存在，却**读不出来** —— 不是正规文件 / 超过 64 KiB / 根本不是 JSON。
    ///
    /// `play` 的第一步 `loadPlayConfig` 就返回 nil → `.notReady` → 每一个事件静默无声。而这台机器
    /// 在 app 里也**修不好**：面板的静音钮 / 画廊都要走 `updateConfigJSON` 的 fail-closed 写路径，
    /// 它会（正确地）拒绝重写一份读不懂的文件。所以 hooks 同样不写。
    ///
    /// ⚠️ 这条错误**推翻了一条既有回归测试的结论**（`SetupSuite`「一份读不出来 / 畸形的
    /// config.json」，它当年断言「hooks 安装本身与 config 是否可读无关，必须照常完成」——**那句话
    /// 是错的**：一条读不到 config 的 hook，就是一条什么都不会响的 hook）。那条测试的**本意**原样
    /// 成立、且仍被钉着：自举**不会**替用户选包，更**绝不覆盖**那份他读不懂的文件——这次失败路径
    /// 上一个字节都不会动它。自举没有能力修一份读不懂的 config（`doctor` 会把可执行的修复指令直接
    /// 告诉用户）；它唯一该做的，是拒绝在这之上写下四条注定不会响的 hooks。
    case configUnusable(reason: String)
    case useFailure(UseError)
    case installFailure(SettingsUpdateError)

    public var description: String {
        switch self {
        case .binaryCopyFailure(let reason):
            "复制二进制到 ~/.claudio/bin/claudio 失败：\(reason)"
        case .packsLockBusy:
            "声音包目录正被另一个操作占用（多半是 Claudio 面板此刻正在写声音包清单）——"
                + "这次什么都没做（没有复制任何包，也没有写入任何 hooks），过一会儿再跑一次。"
        case .packsLockFailed(let errno):
            "取声音包目录的锁失败了（errno \(errno)）——这不是「忙」，是 ~/.claudio 那边出了真问题，"
                + "重试也不会好。这次什么都没做（没有复制任何包，也没有写入任何 hooks）。"
        case .packCopyFailure(let reason):
            "复制内置声音包失败：\(reason)"
        case .binaryQuarantined(let reason):
            "macOS 仍在隔离 ~/.claudio/bin/claudio，它一执行就会被系统杀掉（所以这次没有写入任何 hooks）：\(reason)"
        // 「这次没有写入任何 hooks」——刻意不说成「Claudio 没有碰过你的 Claude Code」。在**修复**动线上
        // （用户重跑 setup 去救一台已经哑了的机器），四条 hooks 本来就**已经躺在** settings.json 里了；
        // 说成后者就是在唯一一次报告失败的时候撒谎（T17e 完备性批评者命中）。
        case .noAvailablePack(let reason):
            "一个声音包都没有，装完也不会有任何声音（所以这次没有写入任何 hooks）：\(reason)"
        case .selectedPackUnresolvable(let packID, let reason):
            "你选中的声音包 \"\(packID)\" 已经不在了（或读不出来），而且没有任何一个能顶上的包，"
                + "装完不会有任何声音（所以这次没有写入任何 hooks，也没有改动 config.json）：\(reason)"
        case .configUnusable(let reason):
            "config.json 读不出来，装完不会有任何声音（所以这次没有写入任何 hooks，也没有改动这个文件）："
                + "\(reason)"
        case .useFailure(let error):
            "首次默认选包失败：\(error.description)"
        case .installFailure(let error):
            "写 settings.json hooks 失败：\(error.description)"
        }
    }
}

// MARK: - Entry point

/// Runs the full first-run bootstrap. Safe to call repeatedly (idempotent): if
/// `executablePath` is already `claudioBinaryDestination` (i.e. this is a rerun of the
/// already-installed copy, not a fresh run from inside the app bundle), the binary/pack
/// copy steps are skipped entirely and only the hooks step runs — reusing
/// ``installClaudioHooks(settingsFile:claudioBinaryPath:lockFile:)``'s own idempotency.
public func performFirstRunSetup(environment: SetupEnvironment) -> Result<SetupOutcome, SetupError> {
    let alreadyInstalled =
        environment.executablePath.standardizedFileURL.path
        == environment.claudioBinaryDestination.standardizedFileURL.path

    var copiedBinary = false
    var copiedPackIDs: [String] = []
    var salvagedPacks: [SalvagedPack] = []

    if !alreadyInstalled {
        // Copying the binary must NOT be gated on whether a sibling `packs/` exists
        // (Codex + Claude adversarial review, /ship pre-landing: three independent passes
        // converged on this — one verified it empirically in an isolated scratch package).
        // The earlier version nested this inside `if directoryExists(at: bundledPacksDirectory)`,
        // so any invocation that isn't literally running from inside a fully-assembled app
        // bundle (a raw dev build, or a bundle whose Resources/packs/ is missing/corrupted)
        // would skip the binary copy ENTIRELY yet still fall through to
        // `installClaudioHooks` below — writing real hook entries pointing at a
        // `claudioBinaryDestination` that doesn't exist, returning `.success`, and (per
        // `printSetupSummary`) printing a message claiming the binary is "already there."
        // Every subsequent Claude Code event would then silently fail to play a sound with
        // zero signal anything was wrong — the exact "install completes but stays broken"
        // failure class T17 exists to eliminate. Unconditionally attempting the copy here
        // means a real failure now surfaces as a real `SetupError`, never a false success.
        switch copySelfToFixedLocation(
            from: environment.executablePath, to: environment.claudioBinaryDestination
        ) {
        case .success: copiedBinary = true
        case .failure(let error): return .failure(error)
        }

        // Bundled packs ship as a sibling of the binary's containing directory:
        // `Contents/Resources/bin/claudio` ↔ `Contents/Resources/packs/` (release.yml).
        // Its mere presence is also how `setup` tells "running from inside a bundle" apart
        // from "running some other copy of this binary from an arbitrary directory" — if
        // there's no sibling `packs/`, there's no bundled pack to copy, but (unlike the
        // binary above) that's genuinely fine: the user's existing/future packs are
        // untouched either way.
        let bundledPacksDirectory =
            environment.executablePath
            .deletingLastPathComponent()  // .../Contents/Resources/bin
            .deletingLastPathComponent()  // .../Contents/Resources
            .appendingPathComponent("packs", isDirectory: true)  // .../Contents/Resources/packs

        if directoryExists(at: bundledPacksDirectory) {
            // 整段包发布都在 `packs.lock` 里。这一段是 `manifest.json` 的**目录级**写者：它会把
            // 用户整个包目录 `moveItem` 挪走、再 `moveItem` 一份内置包进来。GUI 侧的
            // `mutateManifestJSON` 是字节级写者，两者此前零互斥 —— 而 `restoreBundledPacksHint`
            // 正在主动教用户去 Terminal 跑这条命令，所以那是被文档鼓励的竞争，不是理论上的。
            //
            // 拿不到锁时**返回失败，不是跳过包继续装**：hooks 还没写，此刻失败是干净的；
            // 跳过包却照常写 hooks，用户拿到的是一台亮绿点、doctor 也过、却永远不响的机器
            // （与 `.binaryQuarantined` / `.noAvailablePack` 同一条纪律）。
            let published = withNonBlockingLock(path: environment.packsLockFile.path) {
                publishBundledPacks(from: bundledPacksDirectory, environment: environment)
            }
            switch published {
            case .ran(.success(let result)):
                copiedPackIDs = result.copied
                salvagedPacks = result.salvaged
            case .ran(.failure(let error)):
                return .failure(error)
            case .skipped:
                return .failure(.packsLockBusy)
            case .failed(let errno):
                return .failure(.packsLockFailed(errno: errno))
            }
        }
    }

    // This is the ONLY place quarantine is stripped from the binary, and the ONLY place the strip
    // is verified. `copySelfToFixedLocation` deliberately does NOT strip (see its own comment) —
    // an earlier draft had it strip too, and this comment still claimed it did long after that
    // line was deleted, which is exactly the kind of stale claim that gets the surviving one
    // deleted next ("the copy path already handles it").
    //
    // Unconditional, and deliberately OUTSIDE the `if !alreadyInstalled` block above: a re-run
    // where `alreadyInstalled` is true skips the copy ENTIRELY, so a destination
    // binary left quarantined by an earlier (pre-fix, or interrupted) install would never get
    // cleaned — setup would keep cheerfully re-writing hooks pointing at a binary macOS kills on
    // sight. "The bootstrap can always heal a broken install by re-running" is a promise this
    // repo makes in `docs/distribution.md`; it has to be true for this failure too.
    stripQuarantineAttribute(at: environment.claudioBinaryDestination)
    if hasQuarantineAttribute(at: environment.claudioBinaryDestination) {
        return .failure(
            .binaryQuarantined(
                reason:
                    "已尝试解除隔离但没成功（\(environment.claudioBinaryDestination.path)）。"
                    + "可以手动跑一次：xattr -dr com.apple.quarantine \(environment.claudioBinaryDestination.path)"
            ))
    }

    // 写 hooks 之前的最后一件事，也是这次 setup 唯一还没兑现的不变式（T17e）：
    //
    //   **setup 返回成功时，`config.json` 的 `selected_pack` 一定指向一个 `play` 真的解析得出来的包。**
    //
    // 判据由 `checkPackIntegrity`（= `doctor` 的那条链，与 `play` 逐字同源）给出，政策由纯函数
    // `packSelectionPlan` 决定。位置是要害：整段在 `installClaudioHooks` **之前** —— 一次注定不会
    // 响的安装，绝不允许在用户的 Claude Code 里留下新的痕迹。
    let packSelection: PackSelectionOutcome
    switch packSelectionPlan(
        status: checkPackIntegrity(
            configFile: environment.configFile,
            userPacksDirectory: environment.userPacksDirectory,
            // `nil` 是**刻意**的，而且是这道判据正确性的关键：生产环境里的 `claudio play` 用的就是
            // `PlayEnvironment` 的默认值 `nil`（它只看 `~/.claudio/packs/`）。若在这里把 app bundle 里的
            // `Resources/packs/` 传进去，就会认可一个 **`play` 根本看不见**的包 —— 一次假阴性，而这道
            // 判据存在的全部意义正是不放过假阴性。
            bundledPacksDirectory: nil),
        usablePackIDs: usablePackIDs(in: environment.userPacksDirectory)
    ) {
    case .keepExistingSelection:
        packSelection = .untouched

    case .selectDefault(let packID):
        switch selectPack(
            packID, configFile: environment.configFile,
            userPacksDirectory: environment.userPacksDirectory,
            lockFile: environment.configLockFile)
        {
        case .success(.selected(let id)): packSelection = .selectedDefault(packID: id)
        case .failure(let error): return .failure(.useFailure(error))
        }

    case .repairDeadSelection(let removed, let selected):
        switch selectPack(
            selected, configFile: environment.configFile,
            userPacksDirectory: environment.userPacksDirectory,
            lockFile: environment.configLockFile)
        {
        case .success(.selected(let id)):
            packSelection = .repairedDeadSelection(removed: removed, selected: id)
        case .failure(let error): return .failure(.useFailure(error))
        }

    case .failNoPackAtAll:
        return .failure(
            .noAvailablePack(
                reason:
                    "\(environment.userPacksDirectory.path) 里没有任何可用的声音包"
                    + "（app 包里的内置包可能缺失或损坏）。\(restoreBundledPacksHint)"))

    case .failDeadSelectionNoFallback(let packID):
        return .failure(
            .selectedPackUnresolvable(
                packID: packID,
                reason:
                    "\(environment.userPacksDirectory.appendingPathComponent(packID).path) "
                    + "解析不出来，而 \(environment.userPacksDirectory.path) 里也没有任何其它能用的包"
                    + "可以顶上。\(restoreBundledPacksHint)"))

    case .failConfigUnusable(let reason):
        return .failure(
            .configUnusable(
                reason:
                    "\(reason)。修好 \(environment.configFile.path)，或者直接删掉它"
                    + "（Claudio 会重新生成一份），然后再跑一次 setup。"
                    + "跑一次 \(environment.claudioBinaryDestination.path) doctor 可以看到更具体的诊断。"))
    }

    switch installClaudioHooks(
        settingsFile: environment.settingsFile,
        claudioBinaryPath: environment.claudioBinaryDestination.path,
        lockFile: environment.settingsLockFile
    ) {
    case .success(let hooksOutcome):
        return .success(
            .completed(
                copiedBinary: copiedBinary, copiedPacks: copiedPackIDs,
                salvaged: salvagedPacks, packSelection: packSelection,
                hooksOutcome: hooksOutcome))
    case .failure(let error):
        return .failure(.installFailure(error))
    }
}

// MARK: - 「能用的包」——与 `play` / `doctor` 同一条判据（T17e）

/// `userPacksDirectory` 里的候选目录 —— 排序后的、剔除点开头目录的那一份名单。
///
/// Deliberately scans `userPacksDirectory` fresh rather than reusing `copiedPackIDs`
/// (red team / `/ship` pre-landing review finding): `copiedPackIDs` only reflects packs copied
/// *this* invocation, so a pack that already exists from an earlier — possibly interrupted —
/// `setup` run (or one the user placed there manually) would never get selected, and
/// `alreadyInstalled` re-runs (which skip the copy step entirely) could never establish a default
/// pack at all. Scanning disk directly fixes both: any pack that's actually there and resolvable
/// is eligible, regardless of which run put it there.
///
/// 点开头的目录一律剔除：包复制的暂存目录（`.<id>.tmp-<pid>`）、被挪开的残骸（`.<id>.broken-<pid>`）、
/// 以及用户自己塞进来的任何隐藏目录，都永远不该成为默认选择。真实的包 id 从不以点开头。
///
/// ⚠️ **这份名单只是「候选」，不是「能用」** —— 它只回答「这里有个目录」。选包、以及失败信息里那句
/// 「你还能选什么」，都必须再过一道 ``isUsablePack(_:in:)``。上一版把两者混为一谈，代价是两个各自
/// 独立的 P1：setup 会**自己**选中一个读不出 manifest 的残骸目录、然后被自己的判据判死（全新机器
/// 直接装不上）；而失败信息会把**刚刚判死的那个坏包**当成出路推荐回去（一个指向自己的死循环）。
private func availablePackIDs(in userPacksDirectory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: userPacksDirectory.path)) ?? [])
        .sorted()
        .filter {
            !$0.hasPrefix(".")
                && directoryExists(at: userPacksDirectory.appendingPathComponent($0, isDirectory: true))
        }
}

/// **一个包「能用」，当且仅当 `play` 真的能从它里面读出东西来。**
///
/// 逐字复用 `play` 的解析链前两步（`resolvePackDirectory` → `loadPackManifest`）：安全 id、真的落在
/// `packs/` 里（不是一条逃出去的符号链接）、manifest 读得出来 / 解得开。绝不在这里另写一套判据 ——
/// 「可用」这个词在这个仓库里只能有一个定义，两套判据不一致的那一天，就是又一次静默失声的那一天。
///
/// `bundledPacksDirectory: nil` 与生产环境的 `claudio play`（`PlayEnvironment` 的默认值）逐字一致：
/// 一个只存在于 app bundle、没被复制进 `~/.claudio/packs/` 的包，`play` 根本看不见 —— 那就不算能用。
///
/// 音频文件在不在**不在此列**（那是「内容」，不是「管道」）：面板的四行覆盖度会把缺的那一行画成
/// `.unmapped` / `.broken`，用户看得见、拖一个文件进去就能修。一个刚建出来、还没导入任何声音的空包
/// 是产品明确支持的状态，它**能用**。
private func isUsablePack(_ id: String, in userPacksDirectory: URL) -> Bool {
    guard
        let packDirectory = resolvePackDirectory(
            id: id, userPacksDirectory: userPacksDirectory, bundledPacksDirectory: nil)
    else { return false }
    if case .success = loadPackManifest(in: packDirectory) { return true }
    return false
}

/// 磁盘上此刻**真正能用**的包（已排序）—— 选包与「你还能选什么」都只认这份名单。
private func usablePackIDs(in userPacksDirectory: URL) -> [String] {
    availablePackIDs(in: userPacksDirectory).filter { isUsablePack($0, in: userPacksDirectory) }
}

/// 一次有用的失败必须让用户**看得见出路**，而且那条出路必须是**真的**。
///
/// 这里只说一件事：从 app bundle 里跑一次 setup，它会把内置包补回来（`docs/distribution.md` 里
/// 记的就是这条命令）。刻意**不**说「重新安装 Claudio」—— `Casks/claudio.rb` 没有 `zap`，
/// `brew reinstall` 一个字节都不碰 `~/.claudio/`，而所有中毒态全都活在 `~/.claudio/` 里：
/// 那条建议对它被印出来的每一种情形都是确定无效的（T17e 完备性批评者命中）。
private let restoreBundledPacksHint =
    "从 app 里跑一次 setup 就能把内置包补回来："
    + "/Applications/Claudio.app/Contents/Resources/bin/claudio setup"

/// Copies the currently-running binary to its fixed destination and marks it executable.
/// Replaces an existing destination file (e.g. re-running `setup` after an app update) —
/// `~/.claudio/bin/claudio` holds no user data, so overwriting it is always safe.
///
/// ## 它是**原子发布**，不是「删了再拷」（`/codex review 3af8d5f`，Claude 侧红队）
///
/// 上一版逐字是：`removeItem(destination)` → `copyItem(source, destination)` →
/// `setAttributes(0o755)`。三步**直接落在最终路径上**，于是 `setup` 在这中间被 kill / 掉电，
/// `~/.claudio/bin/claudio` 会停在三种坏终态之一：**不存在**、**半截二进制**、或**存在但没有执行位**。
///
/// 而这条路径不是普通的文件复制 —— `settings.json` 里那四条 hook 命令逐字指向的就是它
/// （``claudioHookCommand``：`<root>/bin/claudio play <event>`）。所以那三种坏终态的用户可见形状是
/// 同一个：**Claude Code 每一次事件都去执行一个缺失 / 半截 / 不可执行的二进制**，而面板的探测
/// （`isRunnableHelperBinary`）此刻多半还说「已经接好了」。
///
/// 讽刺的是同一个文件 200 行之上的**包复制**（T17e）早就是对的：先写进点开头的暂存目录，成功之后
/// 再 rename 到最终名字。而 `AtomicWriteSuite` 当时豁免 `copyItem` / `moveItem` 的理由，白纸黑字
/// 写的正是「它们的原子性纪律是另一条（T17e 的 staging + rename）」—— 那句话对**这个调用点**是
/// 字面意义上的假话。豁免的理由必须对每一个被豁免的调用点都成立，否则它就只是一句托词。
///
/// 现在这里走同一条纪律：**暂存 → chmod → 同卷 rename**。终态只有两种：旧的那份（或没有），
/// 或者一份**完整且可执行**的新的。没有第三种。
///
/// `replaceItemAt` 底下就是 `rename(2)`（同卷、原子）。目标**不存在**时它会 throw，所以那一半走
/// `moveItem`（同样是 `rename(2)`）—— 两条路都不经过「最终路径上先空一下」那个窗口。
/// 覆盖一个**正在被执行**的二进制在 macOS 上正是要用 rename：老 inode 会被仍在跑的进程留住，
/// 而新的事件拿到的是新的那份（TODOS「helper 二进制永不刷新」那条里记着这句话）。
private func copySelfToFixedLocation(from source: URL, to destination: URL) -> Result<Void, SetupError> {
    let fileManager = FileManager.default
    // 暂存必须与目标**同目录**（同卷）—— rename(2) 不跨卷。名字带 pid：两个并发 setup 互不覆盖
    // 对方的暂存。点开头：万一真被中断留下，它**不会被当成那个二进制**（探测认的是 `bin/claudio`
    // 这个名字，`.claudio.tmp-…` 不匹配）。
    //
    // ⚠️ 它**不会被自动清掉**：下面 `:679` 的 `try? removeItem(at: staging)` 只删**当前 pid** 那一份，
    //    一次被 kill 的旧 setup 留下的 `.claudio.tmp-<别的 pid>` 会一直躺在 `~/.claudio/bin/` 里
    //    （`/codex review 3af8d5f` 红队实测）。危害为零——它是隐藏文件、不参与任何探测、不占用户
    //    可见空间——所以这里**不**顺手 glob 删 `.claudio.tmp-*`：那会把一个**并发存活**的 setup 的
    //    暂存删掉，用一条真实的竞态换一次无害的清扫。真要收垃圾，得先有「哪些 pid 还活着」的判据，
    //    那是另一件事。（同样的 pid 局限也在包路径 `:436` 上，那里的注释同此。）
    let staging = destination.deletingLastPathComponent()
        .appendingPathComponent(
            ".\(destination.lastPathComponent).tmp-\(ProcessInfo.processInfo.processIdentifier)")
    do {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: staging)
        try fileManager.copyItem(at: source, to: staging)
        // 执行位在**发布之前**打上。上一版是在 copy 到最终路径**之后**才 chmod，于是「存在但不可
        // 执行」是一个可达的终态；这里它不可达 —— 发布出去的那一刻它已经是 0o755 了。
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)

        // ⚠️ 判据必须用 **lstat 语义**（`attributesOfItem` 不跟随链接），不能用 `fileExists`
        // （它**跟随**链接）—— 而这恰恰是姊妹的包复制路径（`:403`）早就修好的那个 bug：一条
        // 指向真实文件的 symlink 会从 `fileExists` 的缝里漏过去、直奔 `replaceItemAt`，而
        // `replaceItemAt` 用 lstat 看得见那条链接、当场抛（实测：「The file "claudio" doesn't exist」）——
        // 于是 setup 返回 `.binaryCopyFailure`、二进制永不发布、hooks 永不写，**每一次重跑都一字不差
        // 地失败**。这个回归是「原子发布」那一刀引入的（`/codex review 3af8d5f` 红队实测），而它
        // 的修法在 270 行之上的包路径里逐字写着。（`bin/claudio` 是 symlink 永远不来自 Claudio 自己
        // 的操作——它只写常规文件——但外部/用户可能造出来，且 TODOS:58 计划让日后的 helper 升级都走
        // 这条路，敞口只会变大。）
        let existing = try? fileManager.attributesOfItem(atPath: destination.path)
        if existing?[.type] as? FileAttributeType == .typeRegular {
            // 常规文件（正常的「app 更新后重跑 setup」路径）→ **原子替换**。
            //
            // `.usingNewMetadataOnly` **不是可选的**：`replaceItemAt` 默认**保留原文件的元数据**，
            // 权限位在其中。实测（Darwin 25.5）目标 0644 + 暂存 0755 → 默认选项发布出去是 **0644**
            // （内容新、执行位旧）。不带它，上面那句「已经是 0o755 了」是假话，而「存在但不可执行」
            // 正是这次修复自称要消灭的三种坏终态之一（`SetupSuite` 里一条站在这条路上的行为测试
            // 当场逮住过它）。我们要的语义就是「用新的那份整个换掉旧的那份」，旧元数据一字节不留。
            _ = try fileManager.replaceItemAt(
                destination, withItemAt: staging, options: [.usingNewMetadataOnly])
        } else {
            // 目标要么不存在，要么是一条 symlink / 悬空链接 / 目录 —— `replaceItemAt` 对非常规文件会抛。
            // 先按 lstat 语义把它清掉（`removeItem` 用 `unlink`，删的是链接本身、不是它指向的东西），
            // 再 `moveItem`。这一分支与旧算法（`removeItem` + `copyItem`）在 symlink 这一格上行为一致，
            // 顺带把旧算法也会栽的悬空链接（EEXIST）一并修了。
            if existing != nil { try fileManager.removeItem(at: destination) }
            try fileManager.moveItem(at: staging, to: destination)
        }
        // NO quarantine strip here — deliberately. `copyItem` DOES carry `com.apple.quarantine`
        // across (see Quarantine.swift), but the strip AND the verification that it actually worked
        // both live in ``performFirstRunSetup``, in ONE place, unconditionally, and they run on the
        // *destination* — i.e. after this function has published it. A second strip here
        // is dead code: removing it changes no behavior and breaks no test (measured) — which is
        // exactly what "defense in depth" degenerates into when nobody checks: an untested line
        // pretending to be a safety net.
        return .success(())
    } catch {
        try? fileManager.removeItem(at: staging)
        return .failure(.binaryCopyFailure(reason: error.localizedDescription))
    }
}
