import Foundation

/// 读**第三方分发内容**（声音包）时用的文件系统原语。
///
/// 声音包是策展 / 第三方分发的（ENGINEERING.md：策展声音包——这是产品的核心分发模型），所以包目录
/// 里的任何一个条目都必须当成**不可信输入**：它可能根本不是一个普通文件，也可能大得离谱。
///
/// ## 这里到底在防什么（实测结论，不是传说）
///
/// 评审给出的原始结论是「`manifest.json` 做成 FIFO → `Data(contentsOf:)` 在主线程永久阻塞 → 开面板
/// 即挂死」。**在 Darwin 上实测：这一条对 `Data(contentsOf:)` 不成立**——Foundation 会直接拒绝非正规
/// 文件（读 FIFO 抛 `EACCES`），不阻塞。实测真的会**永久挂住**的是 `FileHandle(forReadingFrom:)`
/// （`open(2)` 在等一个永远不来的写端）。所以这道闸门真正的价值是这两条：
///
/// - **已证实、今天就能触发的洞：读取无大小上限。** 一个 500MB 的 `manifest.json` 会被
///   `Data(contentsOf:)` 整份读进来、再原样喂给 `JSONDecoder`——而一份四事件 manifest 实际不到 1 KB。
///   ``maxPackManifestBytes`` 这道上限是这个洞的正解（对应的回归测试变异验证时确实变红：超限文件被
///   完整读完，一路走到了解码器）。
/// - **正规文件白名单 = 不把安全性押在一个未文档化的实现细节上。** `Data(contentsOf:)` 今天恰好帮我们
///   挡住了 FIFO，但那是 Foundation 的实现细节，不是它的契约：换一个 Foundation 版本、或者哪天有人把
///   这行改写成 `FileHandle`/`InputStream`（实测会挂死），洞就当场回来了。`O_NONBLOCK` + `fstat` 判
///   `S_IFREG` 把「绝不阻塞、绝不读非正规文件」变成**我们自己的**、被测试钉死的契约，而不是一个借来的
///   巧合。
///
/// ``readRegularFileBounded(at:maxBytes:followSymlink:)`` 是 `gui` 侧 `AudioImport.swift` 的
/// `readRegularFileSource` 的同形复用（同样的 `fstat` 正规文件白名单 + 有上限的分块读）——那条路径
/// 读的是用户拖进来的音频文件，这条读的是包里的 manifest，威胁模型一模一样。`ClaudioCore` 在依赖图
/// 的下游（`gui` 依赖它，反之不成立），所以这里是这个形状在本模块内的落地，而不是第二套独立推理出来
/// 的方案。
///
/// ## 符号链接策略是一个**参数**，不是一个默认值
///
/// 两条读路径对「符号链接」的答案必须一致，否则同一个「包内合法符号链接」会被 manifest 那条路拒绝、
/// 被音频那条路放行——同一个合法性判断给出相反答案（本次评审的原始发现）。真正决定答案的不是这个
/// 函数，而是**调用方有没有先做过包含性校验**：
///
/// - `loadPackManifestData`（`PackManifest.swift`）先跑 `isReallyContained`（**解析**符号链接后再判
///   是否仍在包内），逃逸已经被挡死，所以它传 `followSymlink: true` ——包内一个指向同包内真实文件的
///   符号链接是合法的（与 ``regularFileExists(at:)`` 对音频文件的判断逐字相同）。
/// - 没有包含性护栏的调用方（例如 `gui` 读用户从任意路径拖进来的音频）必须传 `false`：那里
///   `O_NOFOLLOW` 是唯一挡住「链接目标可以任意大、可以指向任何地方」的东西。
///
/// 刻意**不给默认值**：这是一个安全决定，每个调用方都必须自己讲清楚它凭什么这么选。
///
/// 无论选哪一边，`O_NONBLOCK` + `fstat` 判 `S_IFREG` 这道闸门都照常生效——一个指向 FIFO / 目录的
/// 符号链接跟随之后仍然会被挡在正规文件白名单外，一个字节都不会读。

/// manifest.json 的大小上限：1 MiB。一份四事件 manifest 实际不到 1 KB，1 MiB 已经宽出三个数量级，
/// 任何越过它的东西都不是 manifest，是攻击载荷或事故。
let maxPackManifestBytes = 1 << 20

/// `config.json` 的大小上限：64 KiB。一份真实 config（四个 v1 键 + 用户自定义字段）是几百字节；
/// 64 KiB 已经宽出两个数量级，任何越过它的东西都不是 config。
///
/// 这道上限**必须存在**，理由与 manifest 那道一模一样，而且更硬：`config.json` 被读的地方比 manifest
/// 多得多，且每一处都在最不能出事的路径上——`claudio play` 的**同步 hook 路径**（每一次 Claude Code
/// 事件都读一次）、菜单栏 app 的**主线程**（每一次开面板都读一次）。见 ``loadClaudioConfig(from:)``。
public let maxConfigFileBytes = 1 << 16

/// ``readRegularFileBounded(at:maxBytes:)`` 的结果：要么是文件的字节，要么是它被拒读的**具体**原因
/// （拒读原因分开带出来，是为了让调用方能把「这不是个正规文件」和「文件根本不存在」讲成不同的话，
/// 而不是糊成一句「读取失败」）。
public enum BoundedFileRead: Equatable {
    /// 一个普通文件，完整读完——不超过 `maxBytes` 字节。
    case success(Data)
    /// 打开的描述符不是正规文件：目录 / FIFO / socket / 设备（`followSymlink: false` 时，末段是一个
    /// 符号链接也算——`O_NOFOLLOW` 拒绝跟随；`followSymlink: true` 时符号链接被跟随，被判的是它
    /// **目标**的类型）。
    case notRegularFile
    /// 文件比 `maxBytes` 大。
    case oversize
    /// 其他任何原因打不开 / `fstat` / 读失败（不存在、没权限、符号链接成环……）。
    case unreadable
}

/// 读 `configFile` 的**唯一**入口：有界 + 正规文件闸门。返回它的字节，或它被拒读的具体原因。
///
/// ## 为什么 `config.json` 也必须走这道门（本轮 /ship 评审：三路独立命中）
///
/// 这个 diff 建了 ``readRegularFileBounded(at:maxBytes:followSymlink:)``，并用大段论证说明「无大小上限
/// 的读是已证实、今天就能触发的洞」——然后只把它用在了 `manifest.json` 上。`config.json` 的五处读全是
/// 裸的 `Data(contentsOf:)`：`play` 的 hook 路径、`doctor`、config 的读-改-写、以及 `gui` 面板。
///
/// 信任边界因此在同一个文件上自相矛盾：**写**路径把 `config.json` 当不可信输入（整套 fail-closed 闸门
/// 都是为它建的），**读**路径却完全信任它。
///
/// ### 真实的那一半：**读取无大小上限**
///
/// 一个 500MB 形状的 `config.json` 会被**整份读进内存**，而这两条路径是这个仓库最不能出事的地方：
/// `claudio play` 跑在 Claude Code 的**同步 hook 路径**上（每个事件一次），`gui` 的 `loadPanelConfig`
/// 跑在**主线程**上（每次开面板一次）。这条今天就能触发，`maxConfigFileBytes` 这道上限是它的正解。
///
/// ### 被证伪的那一半：FIFO **不会**让 `Data(contentsOf:)` 挂死
///
/// 本轮有两路评审（红队 / Codex 对抗）都断言「FIFO 形状的 config.json → `Data(contentsOf:)` 永久阻塞
/// → hook / 菜单栏挂死」。**实测：不成立**——Darwin 上 `Data(contentsOf: FIFO)` 在 0.0001s 内抛
/// `EACCES`，目录抛 `EISDIR`，都不阻塞。这与本文件顶部记录的、上一轮对 `manifest.json` 的**同一条**
/// 结论完全一致（那次也是评审说会挂、实测不挂）。**同一个伪命题被独立提出了两次，所以它值得在这里
/// 再钉一遍。**
///
/// 那为什么还要正规文件闸门？理由和上一轮一字不差：**不把安全性押在一个未文档化的 Foundation 实现
/// 细节上**。`Data(contentsOf:)` 今天恰好帮我们挡住了 FIFO，但这不是它的契约；一旦有人把读法重构成
/// `FileHandle(forReadingFrom:)` / `InputStream`（那**真的**会挂在 `open(2)` 上等一个永远不来的写端），
/// 洞就当场重开。`O_NONBLOCK` + `fstat` 判 `S_IFREG` 把「绝不阻塞、绝不读非正规文件」变成**我们自己
/// 的、有测试钉死的契约**，而不是一个借来的巧合。
///
/// 上限与闸门必须只有一个定义、两个模块共用（ENGINEERING.md T16「REUSE, do not reinvent」）——所以它
/// `public`，和 ``regularFileExists(at:)``、``loadPackManifestData(in:)`` 同理。
///
/// `followSymlink: true`：`config.json` 被指成一个符号链接是合法的（dotfile 管理器常这么干），且大小
/// 上限绑在**已打开的那个 fd** 上，跟随之后照样管用——被拒的是链接目标不是正规文件（FIFO / 目录）。
public func readConfigFileBounded(at configFile: URL) -> BoundedFileRead {
    readRegularFileBounded(at: configFile, maxBytes: maxConfigFileBytes, followSymlink: true)
}

/// 读 + 解码 `configFile` 成一份 ``ClaudioConfig``；任何一步失败都折叠成 `nil`。
///
/// `play`（hook 路径）、`doctor`、以及 `gui` 的面板共用这一个函数——三边对「这份 config 能不能用」的
/// 答案因此不可能分叉。各自的**兜底策略**仍归各自：`play` 把 `nil` 折成静默不播，面板把 `nil` 折成
/// 一份「未选中任何包」的默认 config。见 ``readConfigFileBounded(at:)`` 讲的那两条硬契约。
public func loadClaudioConfig(from configFile: URL) -> ClaudioConfig? {
    guard case .success(let data) = readConfigFileBounded(at: configFile) else { return nil }
    return try? JSONDecoder().decode(ClaudioConfig.self, from: data)
}

/// 只打开 `url` 一次，且只在它确实是一个不大于 `maxBytes` 的**正规文件**时返回它的字节。正规文件
/// 白名单、大小上限、以及真正的读，全部绑定在**同一个文件描述符**上——open 之后再往这个路径上换什么
/// 东西，都改不了「被校验的」与「被读的」是不是同一个对象（这正是 `stat` 然后重新 open 的写法留下的
/// TOCTOU 窗口）。
///
/// - `followSymlink`：见文件头「符号链接策略是一个**参数**」。`false` 时加 `O_NOFOLLOW`，末段是符号
///   链接就直接 open 失败（`ELOOP`），永不跟随——没有包含性护栏时，链接目标可以任意大（绕过大小
///   上限）也可以指向任何地方。`true` 只允许给那些**已经**用 `isReallyContained`（解析符号链接后
///   判包含）确认过目标仍在信任目录内的调用方。
/// - `O_NONBLOCK`：打开一个没有写端的 FIFO、或一个设备，**立刻返回**而不是永久阻塞在这里；随后它们
///   会被下面的 `fstat` 正规文件闸门挡掉，一个字节都不会读。这一条就是「恶意包挂死菜单栏」的解药，
///   且与 `followSymlink` 无关——跟随之后落在 FIFO 上，一样立刻返回、一样被闸门拒绝。
/// - 有界读：内存里最多只持有 `maxBytes + 1` 字节。多读出的那 1 字节足以证明「它超限了」，而不需要把
///   一个任意大的（甚至还在增长的）文件整个读进来。
public func readRegularFileBounded(at url: URL, maxBytes: Int, followSymlink: Bool) -> BoundedFileRead {
    let openFlags = O_RDONLY | O_NONBLOCK | (followSymlink ? 0 : O_NOFOLLOW)
    let fd: Int32 = url.withUnsafeFileSystemRepresentation { pathPointer in
        guard let pathPointer else { return -1 }
        return open(pathPointer, openFlags)
    }
    guard fd >= 0 else {
        let openErrno = errno
        // socket（EOPNOTSUPP）是「这不是个正规文件」。ELOOP 有两种含义，取决于我们怎么 open 的：
        // `O_NOFOLLOW` 下它是「末段是一个符号链接」（= 不是正规文件）；跟随模式下它只可能是符号链接
        // **成环**——那不是「不是正规文件」，那就是诚实的「读不了」。其余（不存在、无权限）同理。
        if openErrno == EOPNOTSUPP { return .notRegularFile }
        if openErrno == ELOOP && !followSymlink { return .notRegularFile }
        return .unreadable
    }
    defer { close(fd) }

    var status = stat()
    guard fstat(fd, &status) == 0 else { return .unreadable }
    guard (status.st_mode & S_IFMT) == S_IFREG else { return .notRegularFile }
    // 元数据快速路径——绑定在已打开的这个正规文件上，所以量到的大小就是下面要读的那个对象的大小。
    if status.st_size > maxBytes { return .oversize }

    // 分块读，内存里永远不超过 `maxBytes + 1` 字节。`maxBytes == Int.max`（「实质无上限」）时
    // `maxBytes + 1` 会溢出陷阱，饱和处理即可：那种上限下没有文件能超限，读到 EOF 就是全部意图。
    let readCap = maxBytes == Int.max ? Int.max : maxBytes + 1
    var data = Data()
    data.reserveCapacity(Int(clamping: status.st_size))
    let chunkSize = 1 << 16  // 64 KiB
    var buffer = [UInt8](repeating: 0, count: chunkSize)
    while data.count < readCap {
        let want = min(chunkSize, readCap - data.count)
        let bytesRead = buffer.withUnsafeMutableBytes { raw -> Int in
            var result = read(fd, raw.baseAddress, want)
            while result < 0 && errno == EINTR { result = read(fd, raw.baseAddress, want) }
            return result
        }
        if bytesRead < 0 { return .unreadable }
        if bytesRead == 0 { break }  // EOF
        data.append(contentsOf: buffer[0..<bytesRead])
    }
    // `fstat` 之后被写大到超限的文件，在这里被那多读的 1 字节抓住——永不完整载入。
    if data.count > maxBytes { return .oversize }
    return .success(data)
}

/// `path` 上是不是真的躺着一个**正规文件**。
///
/// `FileManager.fileExists(atPath:)` 对**目录**、**FIFO**、socket、设备一律回答 `true`——于是一个
/// 名叫 `stop.mp3` 的目录会被判为「音频文件在位」：包显示 complete、`doctor` 通过、`play` 照样去
/// spawn afplay，而事件触发时根本没有声音（`/codex review` [P2]）。`fileExists(atPath:isDirectory:)`
/// 也只能排掉目录，排不掉 FIFO / socket / 设备，所以这里直接 `stat(2)` 判 `S_IFREG`。
///
/// 刻意用 `stat` 而不是 `lstat`：符号链接**跟随**。包内一个指向同包内真实文件的符号链接是合法的
/// （`isReallyContained` 会放行它，`gui` 的 coverage 也把它算作 `.present`），这里必须继续把它算作
/// 在位——被拒的是链接指向的**目标不是正规文件**（目录 / FIFO），以及所有逃出包目录的链接（那个由
/// ``safePackFileURL(_:in:)`` 在更早一步挡掉）。``loadPackManifestData(in:)`` 读 manifest 时用的是
/// 同一句话（`followSymlink: true` + `fstat` 判 `S_IFREG`），两条路对「包内合法符号链接」的答案因此
/// 是同一个。
///
/// `public`（与 ``loadPackManifestData(in:)`` 同理）：这是 `gui` 必须复用的**读原语**，不是 helper
/// 的内部细节。`gui` 侧的 coverage 判定（面板上「这个事件有没有声音」的那颗点）如果继续用
/// `FileManager.fileExists`，一个名叫 `stop.mp3` 的目录 / FIFO 会让面板显示 `.present`（文件名 + 试听
/// 可点），而 `doctor` 说缺失、`play` 拒播——**修完 helper 反而让两边互相打架**，比修之前两边一致地
/// 错更糟。正规文件这道门必须只有一个定义，两个模块共用（ENGINEERING.md T16「REUSE, do not reinvent」）。
public func regularFileExists(at url: URL) -> Bool {
    var status = stat()
    let statted = url.withUnsafeFileSystemRepresentation { pathPointer -> Bool in
        guard let pathPointer else { return false }
        return stat(pathPointer, &status) == 0
    }
    return statted && (status.st_mode & S_IFMT) == S_IFREG
}
