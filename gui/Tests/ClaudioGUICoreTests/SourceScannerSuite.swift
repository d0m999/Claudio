import Foundation

// MARK: - 扫描器**自己**的回归网
//
// `LockSeparationSuite`（读 `helper/Sources`）与 `ViewWiringSuite`（读 `gui/Sources`）的兜底全是
// **负向**断言。于是这两套绊线共享同一个致命失效模式：**分析文本里少一段代码，它们只会更绿。**
// 而分析文本由 `strippingComments` 一个函数生产 —— 它是那两套绊线的**单点故障**。
//
// ## 这个 suite 的形状，以及它替掉的两代守卫
//
// - `be332ff` 想守这个洞，写的是 `!codeOnly(path).contains("://")` —— 用**那个会截断的函数的输出**
//   去检查「有没有会导致截断的输入」。`://` 自带 `//`，到达断言之前早已被剪成 `https:`。
//   **它恒真**，而它的失败消息自称「真到了非放不可的那天会当场变红」。
//
// - `2f107b5`（就是加这个 suite 的那个 commit）修对了扫描器的一半，然后把守卫换成
//   ``StrippedSwiftSource/unmodeledConstructs``「它知道自己不认识什么」。**那张清单当时只认得 raw
//   string 一样东西**，而扫描器还有第二个盲区：**插值**。于是 `"\(f("https://x"))"` 照样把状态机
//   带倒相、照样吃掉整行代码，而清单**是空的**，守卫一声不吭。措辞比覆盖范围大，复发在自称已经
//   治好它的那一刀里。
//
// 所以这个 suite 的形状是**唯一**不会退化成恒真式的那一种：**喂合成输入给扫描器，正向断言它的
// 输出**。喂的是它自己的输入，读的不是它自己的输出。白名单式的守卫（「我不认识 X」）永远漏得掉
// 下一个 X；**逐条钉死行为**漏不掉。
//
// 顺带钉死另一半：注释**必须**被剥掉。`Use.swift` / `SettingsInstaller.swift` 的 doc comment 里
// 白纸黑字写着 `ClaudioPaths/playLockFile`（写的正是「我**不**用这把锁」）—— 不剥注释，
// `!contains("playLockFile")` 那几条负向断言会因为**谈论代码的散文**而假红。两个方向都得钉：
// 剥太少 → 假红（没人受得了，会被删掉）；剥太多 → **假绿**（没人看得见，洞永远开着）。

/// 仓库根 —— 从 `#filePath` 推（编译期常量，不依赖 cwd）。
/// `<pkg>/Tests/<Module>Tests/SourceScannerSuite.swift` → 上溯 4 层。两个包同深度。
private func repoRoot(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

// MARK: - T3 内容围栏的**整条生产路径**（枚举 → 纳入判据 → 逐条判定）
//
// ⚠️ 这个 MARK 下面是一个函数，不是三个。这是 `/codex review 15ce131` P1 的修法，而那条 P1 打的
// 正是**上一版给这条围栏补的「自证有牙」**：上一版只把**枚举**抽成 helper，真围栏和自证 suite 各自
// 调它 —— 那是**两条平行的边，不是一条链**。改 helper 函数体（换回 `contentsOfDirectory`）自证会红 ✅；
// 而改**调用点**（在 `:747` 那一行后面加 `.filter { !$0.relativeSubpath.contains("/") }`）helper 原封
// 不动、自证**全绿**，`gui/Sources/ClaudioGUICore` 今天又是**平的**，真围栏也全绿 —— 围栏静默退回
// 非递归，零告警。
//
// 教训（记进 memory 的那条）：**「喂同一个函数」≠「喂同一条生产路径」。** 自证要钉的是从入口到判定
// 的**整条边**，不是其中一个可复用的零件。判据是问一句：「我能不能只改**调用点**、不碰被自证的函数，
// 就让围栏失效？」能 ⇒ 那条自证是零件级的，不是端到端。
//
// 所以枚举、纳入判据、三条判定腿**全部**下沉到这一个函数里，它只吃一个根目录、只吐诊断。调用点因此
// 退化成一行 `audit(under:)` + 对返回值的断言 —— 调用点上**没有枚举可以被改**。下面「自证有牙」那条
// suite 喂它一棵含**脏嵌套写者**的临时树，正向钉死「围栏对子目录写者真的开火」。
//
// **仍然诚实的限度**（别读成「不可能绕过」）：自证覆盖的是这个函数**里面**。有人在调用点对返回的
// `findings` 再 `.filter` 一道，仍然不会红 —— 那是抽取式自证的固有边界，只能靠把接缝做到最大（现在
// 调用点只剩一行）+ code review 兜。别把这段注释写成绝对的。

/// 一次 T3 内容围栏审计的**全部**产物。`findings` 非空 = 有违规或有**无从判定**的东西，
/// 两者都必须让调用方变红（围栏极性：认不出 ⇒ 红，不是 ⇒ 绿）。
private struct ManifestFenceAudit {
    /// 枚举到的所有正规 `.swift` 文件的相对子路径（**保留子目录前缀**），确定序。
    var enumeratedSubpaths: [String] = []
    /// 其中命中纳入判据（已剥注释的代码里出现 `mutateManifestJSON`）的那些，确定序。
    var enrolledSubpaths: [String] = []
    /// 违规 / 无从判定的诊断。空 = 全部清白。
    var findings: [String] = []
}

/// 对 `root` 底下**任意深度**的 `.swift` 源文件跑完整条 T3 内容围栏。
///
/// `pathPrefix` 只影响诊断消息里的路径显示（真围栏传 `gui/Sources/ClaudioGUICore/`，自证传空串），
/// 不影响任何判定 —— 判定一侧两边逐字同一条路径。
///
/// ## 为什么用 `enumerator` 而不是 `contentsOfDirectory`
/// SwiftPM 会**递归**编译 target 子目录里的源文件，所以一个落在 `ClaudioGUICore/Feature/PackWriter.swift`
/// 的 manifest 新写者也必须被纳入 —— 非递归会把它编译进去却漏出围栏（`/codex review 327d211` 的 P1）。
///
/// ## 三处 fail-closed（`/codex review 15ce131` 的 P1 之三）
/// 上一版这三处全是 fail-**open**，即「出问题 ⇒ 静默排除 ⇒ 更绿」，与围栏极性正好相反：
/// 1. `errorHandler:` —— 上一版**没传**。某棵子树枚举失败（权限/IO）会被静默跳过，而顶层
///    `ManifestBinding.swift` 仍在 ⇒ 非空检查和具名钉子照样绿，嵌套写者无声无息地漏掉。
/// 2. `isRegularFile` —— 上一版是 `(try? …) ?? false`，即**判不出类型的 `.swift` 条目被排除**。
///    「我判不出它是什么」绝不等于「它不是源文件」。现在判不出 ⇒ 记一条 finding。
/// 3. `enumerator == nil` —— 上一版 `?? []` 吞掉。真围栏那侧靠 `!enumeratedSubpaths.isEmpty`
///    接得住，但这个函数自己也得说话，否则自证喂它一棵坏树时读到的是「干净」。
///
/// ## symlink（同一轮 P1）
/// `FileManager.DirectoryEnumerator` **不下钻**指向目录的 symlink，而 SwiftPM 会跟随它发现源码 ——
/// 一个 `ClaudioGUICore/Feature -> ../elsewhere` 的目录链接，里面的写者会被编译、却漏出围栏。
/// 走廉价且正确的那条：**遇到任何 symlink 一律记 finding**（认不出 ⇒ 红）。今天 `gui/Sources` 底下
/// 一个 symlink 都没有（`find gui/Sources -type l` 为空），所以这条不会制造噪音；真有人加了一个，
/// 他会拿到一条写明该怎么办的红，而不是一片沉默的绿。
private func auditManifestConcurrencyFence(under root: URL, pathPrefix: String = "")
    -> ManifestFenceAudit
{
    var audit = ManifestFenceAudit()
    let basePath = root.standardizedFileURL.path
    let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]

    // 根目录本身不在 / 不是目录 ⇒ 红，**并且**给一条说得清是哪种毛病的诊断。
    //
    // ⚠️ 这条闸门**不是**安全性上必需的 —— 台账第二轮实测：拆掉它，下面 `errorHandler` 照样会为
    // 这个根目录报一条 finding，「目录不存在 ⇒ 红」这条行为**不会**破。（第一稿的注释在这里写着
    // 「enumerator 对不存在的路径返回非 nil，兜不住这一种，必须有前置闸门」—— 前半句是实测事实，
    // 后半句是我没验就写的假话，被 M11 存活当场逮到。措辞比覆盖范围大，又一次。）
    //
    // 它留下来只为**诊断精度**：把「目录被改名/移走了，去更新路径」与「某棵子树权限/IO 坏了」
    // 分成两条不同的话。所以自证那侧钉的也正是这一点 —— 断言 finding 里出现这条闸门**专有**的
    // 措辞，而不是笼统的「有红就行」（后者对拆掉闸门恒真，这正是 M11 第一次存活的原因）。
    var rootIsDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: basePath, isDirectory: &rootIsDirectory),
        rootIsDirectory.boolValue
    else {
        audit.findings.append(
            "\(root.path) 不存在、或者不是一个目录 —— 整条围栏一个文件都没看过。任何「每个纳入的"
                + "文件都得清白」都是对空集的恒真绿。目录被改名/移走了就把路径更新过去。")
        return audit
    }

    func display(_ subpath: String) -> String { "\(pathPrefix)\(subpath)" }
    func subpath(of url: URL) -> String {
        let full = url.standardizedFileURL.path
        return full.hasPrefix(basePath + "/")
            ? String(full.dropFirst(basePath.count + 1))
            : url.lastPathComponent
    }

    // ⚠️ **不传** `.skipsHiddenFiles`。它跳的是两类东西：点开头的名字，**以及带 BSD `UF_HIDDEN`
    // 标志的文件** —— 而 SwiftPM 只忽略前者，`UF_HIDDEN` 的 `.swift` 它照编译。红队实测（独立
    // SwiftPM 包，`chflags hidden Hidden.swift` 后 `swift build` 成功、符号解析得到；同一棵树喂
    // `.skipsHiddenFiles` 的枚举器只吐得出 `Visible.swift`）：一个 `chflags hidden` 的 manifest 写者
    // 会被编译进 app、却对整条围栏隐身。这正是本轮在修的那个 fail-open，而上一稿的注释还写着
    // 「隐藏路径两边也都忽略」—— 那句是我没验就写的假话。
    //
    // 所以改成自己按 SwiftPM 的真规则过滤：**只**跳点开头的路径分量（同一轮实测：点开头的
    // `.Dotted.swift` SwiftPM 不编译，引用它的符号报 `cannot find in scope`；点开头**目录**里的
    // 文件同样不编译）。
    guard
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: { url, error in
                audit.findings.append(
                    "枚举 \(url.path) 出错：\(error) —— 这棵子树没被走完。落在它下面的 manifest 写者"
                        + "对整条围栏隐身，而顶层文件仍在、非空检查照样绿。修好这棵子树的可读性，"
                        + "别让围栏在一次权限/IO 问题上静默缩小覆盖范围。")
                return true  // 继续走完其余子树 —— 但错误已经记账，不会静默
            })
    else {
        // ⚠️ 诚实标注：上面那条根目录闸门之后，本机 Darwin 上**没有任何已知输入**能让这里返回 nil
        // （实测：不存在的路径、甚至一个普通文件，`enumerator(at:)` 都返回非 nil）。所以这个分支是
        // **无对应 fixture 的兜底**，变异台账里它会作为「存活」出现 —— 那不是漏洞，是不可达。
        // 留着是因为删掉它就是 fail-open，而留着的成本是两行。别把它读成「已验证」。
        audit.findings.append(
            "为 \(root.path) 建不出目录枚举器 —— 整条围栏一个文件都没看过，下面所有「每个纳入的"
                + "文件都得清白」都是对空集的恒真绿。")
        return audit
    }

    for case let url as URL in enumerator {
        // SwiftPM 的真规则：点开头的文件/目录不编译（实测见上）。目录整棵剪掉，别白下钻。
        if url.lastPathComponent.hasPrefix(".") {
            enumerator.skipDescendants()
            continue
        }

        let values = try? url.resourceValues(forKeys: Set(resourceKeys))

        // symlink：枚举器不下钻，SwiftPM 会跟随 —— 认不出 ⇒ 红（见上面 doc comment）。
        // 这条**先于** `.swift` 后缀判断：一个 symlink **目录**没有后缀，但它里面全是源文件。
        if values?.isSymbolicLink == true {
            audit.findings.append(
                "\(display(subpath(of: url))) 是一个 symlink。`DirectoryEnumerator` 不会下钻指向目录的"
                    + " symlink，而 SwiftPM 会跟随它发现并编译源码 —— 落在链接目标里的 manifest 写者"
                    + "会被编译、却完全漏出这条围栏。要么把它改成真目录，要么在这里补一条带循环保护的"
                    + "跟随逻辑并给它加 fixture。别让它保持沉默的绿。")
            continue
        }

        guard url.pathExtension == "swift" else { continue }
        let relative = subpath(of: url)

        // 「判不出类型」≠「不是源文件」。上一版这里是 `?? false`（静默排除），极性反了。
        //
        // ⚠️ 诚实标注：这一条**没有 fixture**。实测逼不出来 —— chmod 000 的文件 `isRegularFile`
        // 照样读得到（值为 true），而 dangling symlink 会先被上面那条 symlink 闸门接走。变异台账里
        // 「把它改回 `?? false`」会**存活**，那是「无输入可喂」而不是「断言写错了」。极性是对的，
        // 别因为它没测就翻回 fail-open；也别把它算进「已验证」的那一栏。
        guard let isRegularFile = values?.isRegularFile else {
            audit.findings.append(
                "\(display(relative)) 判不出是不是正规文件（`resourceValues` 取不到 isRegularFile）——"
                    + "围栏对它无从判起。它若是个 manifest 写者就完全不设防。别把「我判不出」当成"
                    + "「它没事」。")
            continue
        }
        // 名字碰巧带 `.swift` 的**目录**：这是**已判定**的排除，不是「判不出」，所以不记 finding。
        guard isRegularFile else { continue }

        audit.enumeratedSubpaths.append(relative)

        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            audit.findings.append(
                "\(display(relative)) 枚举得到却读不到 —— 纳入判据对它无从判起，它若是个 manifest "
                    + "写者就完全不设防。别让围栏在一次文件权限/编码问题上静默漏掉一个文件。")
            continue
        }

        let scanned = strippingComments(text)
        // ⚠️ 这条**必须排在纳入闸门之前**，顺序不是随便写的。
        //
        // 纳入闸门读的是 `scanned.code` —— 正是这条检查要去验证其可信度的那个东西。排在闸门之后，
        // 就成了「用被守函数的输出去决定要不要守它」：扫描器一旦吃掉了那次 `mutateManifestJSON`
        // 调用（raw string 里的裸引号会让它在代码模式下撞上 `//`、开出假注释吃掉同行），文件就在
        // 闸门那一步**静默掉队**，永远走不到这条本该喊的检查。参见 memory 里
        // `guard-must-not-read-guarded-output` 记的那个病。
        //
        // ⚠️ 诚实标注（红队实测，别把这条写成「关掉了一个真实逃逸」）：把这个洞真正堵住的**不是**
        // 这里，而是 `ViewWiringSuite.swift:199` 那条既有的全局绊线 —— 它扫 `guiSources() +
        // guiCoreSources()`（两个 target，`enumerator(atPath:)` 本来就递归），任何一个文件出现
        // unmodeled 构造它都当场红。实测：把上述 raw-string PoC 写者塞进 `ClaudioGUICore`，**在
        // 本次重排之前**它就已经红了，逮它的正是那条姊妹绊线。所以本次重排是**纵深防御 + 极性
        // 正确**，不是补一个活着的洞。代价实测为零（重排后 2132 全绿，真仓库零假红）。
        if !scanned.unmodeledConstructs.isEmpty {
            audit.findings.append(
                "\(display(relative)) 里出现了扫描器不认识的构造：\(scanned.unmodeledConstructs) —— "
                    + "下面几条负向断言会在一份不可信的『code』上跑，形同虚设")
        }

        guard scanned.code.contains("mutateManifestJSON") else { continue }
        audit.enrolledSubpaths.append(relative)

        // 第一条腿：已知并发构造的黑名单（**不是**完备围栏，见 `bannedConcurrencyTokens` 头上那段）。
        // ⚠️ 命中清单用一个**专有措辞 + 逐字拼接**的形式（`命中 token：a, b`），不是数组的
        // `\(…)` 默认描述。理由同上一条腿：诊断末尾那句 `得到的代码：` 会把源码整段抄进来，而源码里
        // **本来就有**这些 token —— 台账第四轮实测，「只报第一个命中」这个变异靠那段回显照样满足
        // 「诊断里出现 Task」的断言而全绿。有了这个专有前缀，自证钉的就是**判据的输出**，不是回显。
        let concurrencyHits = bannedConcurrencyHits(in: scanned)
        if !concurrencyHits.isEmpty {
            audit.findings.append(
                "\(display(relative)) 的代码里出现了并发构造，命中 token："
                    + "\(concurrencyHits.joined(separator: ", ")) —— manifest.json 今天零锁，"
                    + "唯一的并发安全保证是「全同步 + 全在 @MainActor」（PLAN-SOUND-MANAGER.md "
                    + "§2.1）。任何一个 manifest 写函数一旦变成 async / 派发任务 / 上队列 / 起线程，"
                    + "这条不变式会在没有任何运行时报错的情况下静默失效 —— 这条源码绊线是它唯一的"
                    + "守卫，得到的代码：\(scanned.code)")
        }

        // 第二条腿（/codex review dcab3de,7e97bc4 的 P1）：上面那条挡「变异步」，挡不住「同步但脱离
        // 主 actor」——一个 `public func` 少写一个 @MainActor（或被人标了 `nonisolated`），任意后台
        // 线程就能同步调它，两个读-改-写交错、丢更新，零运行时报错。所以这里**正向**钉住。
        // ⚠️ 诊断消息里**不回显源码**。上一稿这里写的是 `得到的代码开头：\(scanned.code.prefix(200))`
        // —— 红队逮到：那段回显把**函数名原样带进了这条 finding**，于是自证 suite 里「@MainActor 腿
        // 必须对 deepWriter 开火」那条断言（按「路径 + 函数名」匹配）会被**这一条**满足。把 @MainActor
        // 整条腿掐死、只让枚举器返回空，自证照样全绿。诊断要能自证，就不能把别的腿的证据抄进来。
        let exported = exportedPublicFuncNames(in: scanned.codeWithoutStringLiterals)
        if exported.isEmpty {
            audit.findings.append(
                "\(display(relative)) 里一个 `public func` 都没枚举到 —— 它含 `mutateManifestJSON` 却"
                    + "枚举不出任何导出写函数：要么枚举器瞎了（`exportedPublicFuncNames` 认不出这里用的"
                    + "写法，比如 `public extension` 里的成员），要么这个写者根本不是 `public func` 形状。"
                    + "无论哪种，「每个都得 @MainActor」那条对它退化成恒真绿。")
        }
        for gap in missingMainActorIsolation(in: scanned) {
            audit.findings.append(
                "\(display(relative)) 的导出写函数 `\(gap.name)` 没有 @MainActor 隔离"
                    + "（导出 \(gap.exported) 个声明，带 @MainActor 的只有 \(gap.isolated) 个）—— "
                    + "manifest.json 零锁，并发安全靠「全同步 + 全在 @MainActor」两条腿。少了 @MainActor"
                    + "（或被标 nonisolated、或被一个同名重载洗白），它就能被后台线程同步调用，"
                    + "两个读-改-写交错丢更新且零运行时报错。给它加回 @MainActor"
                    + "（PLAN-SOUND-MANAGER.md §2.1 / 4c「并发不变式」）。")
        }
    }

    audit.enumeratedSubpaths.sort()
    audit.enrolledSubpaths.sort()
    return audit
}

/// 一份 `TestSupport.swift` 里两行哨兵之间的那段文本（含哨兵本身）。
///
/// ⚠️ 哨兵按**整行精确匹配**，不是 `contains` —— 区块内部的散文里就**提到过**这两个 token
/// （「到 …:end 为止的这一段」）。用 `contains` 会把那句散文当成结束哨兵，抽出三行注释就收工，
/// 而下面那条 `helperRegion == guiRegion` 会拿两坨同样的三行散文比出**恒真绿**。
/// 这不是假想：第一版就是 `contains` 写的，被本 suite 自己的正向控制当场逮住。
private let scannerRegionBegin = "// claudio:shared-scanner:begin"
private let scannerRegionEnd = "// claudio:shared-scanner:end"

private func sharedScannerRegion(of relativePath: String) -> String? {
    guard
        let text = try? String(
            contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
    else { return nil }
    let lines = text.components(separatedBy: "\n")
    func indexOfSentinel(_ sentinel: String) -> Int? {
        lines.firstIndex {
            $0.trimmingCharacters(in: .whitespaces) == sentinel
        }
    }
    guard let begin = indexOfSentinel(scannerRegionBegin),
        let end = indexOfSentinel(scannerRegionEnd),
        begin < end
    else { return nil }
    return lines[begin...end].joined(separator: "\n")
}

// MARK: - T3 @MainActor 正向绊线的两个原语（/codex review dcab3de,7e97bc4 的 P1）
//
// 并发 token 黑名单那条腿只挡「变异步」，挡不住「同步但脱离主 actor」。manifest.json 零锁的并发
// 安全靠「全同步 **且** 全在 @MainActor」两条腿，黑名单只钉住了「全同步」。这两个 helper 让绊线
// 正向钉住第二条腿：文件里**每一个枚举得到的**导出写函数都得带 @MainActor —— 不是一份会忘记
// 更新的写死名字清单，新写者（forkPack / restoreFactoryPack）落地即自动纳入。
//
// ⚠️ 「每一个**枚举得到的**」这个限定词是认真的，别读成「每一个」——见下面 `exportedPublicFuncNames`
// 的已知盲区。这条腿是**探针，不是围栏**：它认不出的写函数形状是**静默跳过**，不是红。

/// `public` 与 `func` 之间允许出现的东西：空白 / 修饰符（`static` `final` `class` `override`
/// `mutating`…）/ 其它属性。**全部是字母、空白、`@`、`_`** —— 一个标点都不含。
///
/// 这正是它作为围栏的依据：任意**函数体**或参数表都带 `(){}:,` 之类标点，于是这个 run
/// **跨不过**上一个声明，`public` 必须是**这一个** func 自己的修饰词才会匹配。
private let publicFuncModifierRun = "[\\sA-Za-z@_]*"

/// 一段**已剥注释**的代码里所有**导出**函数的名字。绊线要对每一个都断言 @MainActor。
///
/// 认 `public func` / `public static func` / `public final func` / `public class func` /
/// `public override func` / 换行排版 / `@_spi(X) public func` —— 即 `public` 与 `func` 之间
/// 只隔着修饰符与属性的**任何**形态（见 ``publicFuncModifierRun``）。
///
/// 上一版只逐字捞 `public func `，于是 `public static func` 的写者**不匹配、不报错、悄悄溜过**
/// ——而这个形态在本模块里**已经在用**（`PreviewFixtures.swift` / `VolumeDragSession.swift`）。
/// 一个 `public static func` 的**同步**写者不含任何被禁 token，两条腿会同时放行，而它不在
/// @MainActor 上、任意后台线程可以同步调它 —— 正是 `PLAN-SOUND-MANAGER.md` 点名那个「唯一
/// critical gap」的确切形状。红队实测：旧版下往 `ManifestBinding.swift` 塞一个这样的写者，
/// 2099 条断言**全绿**。所以这条从探针升成围栏。
///
/// ⚠️ 仍然诚实地留着的限度（**不是**围栏的部分，别读成「不可能漏」）：
/// - 只认 `public`。`package` / `open` 的写者不在内。
/// - 靠 `@MainActor extension` 或类型级隔离、函数头上不带注解的写者，会被
///   ``hasMainActorIsolation`` 判成「未隔离」而**假红**（假红是安全侧，但它会招来「把绊线删掉」
///   那种修法——真出现了，请扩 ``hasMainActorIsolation``，别删断言）。
private func exportedPublicFuncNames(in code: String) -> [String] {
    let pattern = "public\(publicFuncModifierRun)\\bfunc\\s+([A-Za-z_][A-Za-z0-9_]*)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let text = code as NSString
    return regex
        .matches(in: code, range: NSRange(location: 0, length: text.length))
        .map { text.substring(with: $0.range(at: 1)) }
}

// MARK: - T3 并发绊线的判据（一份，正反两侧共用）
//
// ⚠️ **这是一份「已知构造」的黑名单，不是完备围栏。** 它只认得下面枚举的这些 token；Swift 里
// 「离开主线程 / 引入并发」的写法远不止这些（自定义 `actor` 上的隔离、C 回调、Combine 的
// `subscribe(on:)`、`NSXPCConnection`、GCD 的 C API …… 都不在内）。别把它读成「本文件不可能变并发」。
//
// 另一条腿（`@MainActor`）**也不是**完备围栏，别把两条腿加起来读成「不可能漏」：它枚举写函数
// 靠逐字匹配 `public func `，认不出的形状（`public static func`、`extension` 里的类型级隔离……）
// 是**静默跳过**——详见 `exportedPublicFuncNames` 头上那段已知盲区。
//
// 所以诚实的说法是：**两条腿都是探针，各自覆盖一组已知形态，合起来仍有缺口。**
//  · 黑名单挡「变异步 / 派发 / 起线程」这组已知 token —— 这是 @MainActor 挡不住的形态
//    （`@MainActor public func f() async` 编译得过，跨 await 的读-改-写照样能交错）。
//  · @MainActor 挡「同步但脱离主 actor」，覆盖**枚举得到的**每个 `public func`。
// 真正兜底的不是这两条腿，是 code review 和「所有写者都必须经 `mutateManifestJSON`」这条纪律。
private let bannedConcurrencyTokens = [
    "async", "Task", "DispatchQueue", "Thread", "OperationQueue",
    ".detached", "withCheckedContinuation", "pthread",
]

/// 一段**已剥注释**的代码里命中的并发 token；空 = 清白。
///
/// 读 `codeWithoutStringLiterals`（字符串**内容**被清空、界定符与插值代码保留）而不是 `code`：
/// 这条断的是「代码里有没有并发构造」，而一句**写着** `"…async…"` 的错误消息 / 文案 / 测试
/// fixture 不是并发代码。用 `code` 会让真文件因为自己的一句提示文案假红，然后被下一个人删掉
/// ——本文件开头记的「剥太少 → 假红 → 守卫被删」，字符串这一侧是同一个病。
///
/// 真文件那条绊线与它的合成正向控制共用**这一个**函数、且都传整个 `StrippedSwiftSource`，
/// 所以连「读哪个字段」都不可能在两侧漂移。判据一旦静默失灵（token 拼错、`filter` 写反、
/// `strippingComments` 把代码吃光），`hits.isEmpty` 就是一句恒真绿，而下面那条自证有牙的 suite
/// ——逐 token 各一条手写脏 fixture、外加一条 token↔fixture 配平断言——会当场把它逮出来。
private func bannedConcurrencyHits(in scanned: StrippedSwiftSource) -> [String] {
    bannedConcurrencyTokens.filter { scanned.codeWithoutStringLiterals.contains($0) }
}

/// 一段**已剥注释**的代码里，名为 `name` 的 `public func` 是否带 @MainActor 隔离。
///
/// `@MainActor` 与 `func` 之间只允许空白 / 访问修饰符 / 其它属性（都落在 ``publicFuncModifierRun``），
/// 而任意函数体都含 `{}()` 之类标点 —— 于是这个 run **不可能跨过上一个函数体**：`name` 必须带
/// **它自己**那一个 @MainActor 才会匹配，前一个函数头上的 @MainActor 算不到它身上（下面那条合成
/// 控制里的 `naked` 反例逐字钉着这一点）。
///
/// 匹配到 `func` 而不是 `public func`，与 ``exportedPublicFuncNames`` 认的形态对齐：
/// `@MainActor public static func f` 里 `public` 与 `static` 都落在同一个 run 里。两边若不对齐，
/// 枚举器捞得到、隔离检查却匹配不上，每个 `static` 写者都会**假红**。
/// ⚠️ 这是 ``mainActorIsolatedFuncNames(in:)`` 的**薄包装**，不是第二台识别器。
///
/// 生产路径（``missingMainActorIsolation(in:)``）走的是那个按名字计数的枚举器。这个谓词唯一的用户
/// 是下面那条「@MainActor 合成控制」suite —— 让它包着真识别器，那批断言（带/不带、`static`、`final`、
/// 以及「前一个函数头上的 @MainActor 不许算到后一个身上」的 crosstalk 反例）就仍然钉在**实际在跑的
/// 那段代码**上。写成独立的第二份正则，两边会漂移，而漂移的那一半是没有人在看的那一半。
private func hasMainActorIsolation(funcName name: String, in code: String) -> Bool {
    mainActorIsolatedFuncNames(in: code).contains(name)
}

/// 一段代码里**带 @MainActor 的** `func NAME` 出现了几次（同名重载各计一次）。
///
/// 存在的理由（`/codex review 15ce131` 之后的红队，两条独立 finding 同一个根因）：
/// ``hasMainActorIsolation(funcName:in:)`` 是一次**全文件按名字**的 `contains`，不是逐声明检查。
/// 于是**一个**带 @MainActor 的同名重载，会把这个名字的**每一个**兄弟声明一起洗白：
///
/// ```swift
/// @MainActor
/// public func mutateManifestJSON(at d: URL, events: [String: String]) -> … { … }  // 这一个有
/// public func mutateManifestJSON(at d: URL, _ t: (inout [String: Any]) -> Void) -> … { … }  // 这一个没有，却也绿
/// ```
///
/// 实测：红队构造这个形状，`missingMainActor` 是空的、整条绊线全绿，而真正的读-改-写原语已经脱离
/// 主 actor。修法是**数**：同一个名字，导出声明有几个，带 @MainActor 的就必须有几个。少一个 ⇒ 红。
///
/// 与 ``exportedPublicFuncNames`` 一样，两边都必须喂 `codeWithoutStringLiterals`（见那边的说明）。
private func mainActorIsolatedFuncNames(in code: String) -> [String] {
    let pattern = "@MainActor\(publicFuncModifierRun)\\bfunc\\s+([A-Za-z_][A-Za-z0-9_]*)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let text = code as NSString
    return regex
        .matches(in: code, range: NSRange(location: 0, length: text.length))
        .map { text.substring(with: $0.range(at: 1)) }
}

/// 每个导出写函数**少了几个** @MainActor —— 空 = 全都带。`[(name, exported数, isolated数)]`。
///
/// 两个参数都读 `codeWithoutStringLiterals`（**不是** `code`）。这是红队逮到的一条 fail-open，而且
/// 是本文件开头记着的那个病的第三次复发：`code` **原样保留字符串字面量的内容**，于是一句
/// `let note = "@MainActor func mutateManifestJSON 见 §2.1"` 这样的**散文**，在这条正则眼里与一次
/// 真注解**完全同形** —— 把真注解删掉、留下这句字符串，`missingMainActor` 依然是空的（红队实测绿）。
/// 姊妹腿 ``bannedConcurrencyHits(in:)`` 早就为**同一个理由**读 `codeWithoutStringLiterals`，
/// 它头上那段还专门写了为什么；这条腿当时没跟上，两条腿对「什么算代码」的判断因此分叉，
/// 而分叉的那一侧恰好是 fail-open 的那一侧。
///
/// ⚠️ 两个枚举必须喂**同一个**字段，否则会假红：只把隔离那侧换成 blanked、导出那侧仍读 `code`，
/// 一句字符串里的 `public func ghost` 会被枚举成一个永远匹配不上的幽灵名字。
private func missingMainActorIsolation(in scanned: StrippedSwiftSource)
    -> [(name: String, exported: Int, isolated: Int)]
{
    let source = scanned.codeWithoutStringLiterals
    var exportedCounts: [String: Int] = [:]
    for name in exportedPublicFuncNames(in: source) { exportedCounts[name, default: 0] += 1 }
    var isolatedCounts: [String: Int] = [:]
    for name in mainActorIsolatedFuncNames(in: source) { isolatedCounts[name, default: 0] += 1 }
    return exportedCounts
        .compactMap { name, exported -> (name: String, exported: Int, isolated: Int)? in
            let isolated = isolatedCounts[name] ?? 0
            return isolated < exported ? (name, exported, isolated) : nil
        }
        .sorted { $0.name < $1.name }
}

@MainActor
func runSourceScannerSuites() {

    suite("扫描器：字符串字面量里的 `//` 不是注释起点（be332ff 那条恒真守卫真正想守的东西）") {
        // 这**就是** `be332ff` 的元断言想拦、却因为自身恒真而拦不住的那一行输入。
        // 朴素截断版把它剪成 `let hint = "锁的说明见 https:` —— 后半行那句
        // `lockFile: ClaudioPaths.playLockFile` 对整套锁分离断言**永久隐身**。
        let source = #"""
            let hint = "锁的说明见 https://claudio.dev/locks"; _ = write(lockFile: ClaudioPaths.playLockFile)
            """#
        let scanned = strippingComments(source)
        expect(
            scanned.code.contains("playLockFile"),
            "行内 URL 之后的**代码**必须活下来。它没活下来 = 扫描器又在 `//` 处无条件截断了，"
                + "而两个 suite 的负向兜底会因此**更绿**：一句藏在 URL 后面的 "
                + "`lockFile: ClaudioPaths.playLockFile` 对整套锁分离断言永久隐身。得到：\(scanned.code)")
        expect(
            scanned.code.contains("ClaudioPaths"),
            "整行都得在，不只是那个标识符。得到：\(scanned.code)")
    }

    // MARK: 插值 —— `/codex review 2f107b5` 的 P1，逐字是上面那个病的第二个入口

    suite("扫描器：插值里的**嵌套字符串**不结束外层串（2f107b5 那条守卫全程沉默的洞）") {
        // 这一行是合法 Swift。上一版扫描器把 `\(` 只当成一个转义对吞掉、模式仍停在 .string，
        // 于是插值内 `"https://…"` 的**开引号**被当成外层串的**闭引号** —— 状态机倒相回代码模式，
        // 紧接着 URL 的 `//` 成了注释起点，整行被剪成 `let hint = "\(fallback ?? "https:`。
        //
        // 而 `unmodeledConstructs` **是空的**：它只认得 raw string。两个包的守卫一个字都没说。
        let source = #"""
            let hint = "\(fallback ?? "https://claudio.dev/locks")"; _ = write(lockFile: ClaudioPaths.playLockFile)
            """#
        let scanned = strippingComments(source)
        expect(
            scanned.code.contains("playLockFile"),
            "插值里嵌套字符串之后的**代码**必须活下来。它没活下来 = `\\(…)` 里的那个 `\"` 被当成外层串"
                + "的结尾，状态机倒相，串内 URL 的 `//` 又成了注释起点 —— 同一个截断、同一个「锁永久"
                + "隐身」，而负向兜底只会更绿。得到：\(scanned.code)")
        expect(
            scanned.code.contains("claudio.dev"),
            "插值里那个字符串的**内容**是数据，必须原样留下（它不是注释）。得到：\(scanned.code)")
        expect(
            scanned.unmodeledConstructs.isEmpty,
            "插值是**被建模**的构造，不该记进「我不认识」的清单 —— 记了 = 两个 suite 的 unmodeled "
                + "守卫会在每一个用了插值的源文件上假红，然后被下一个人删掉。得到：\(scanned.unmodeledConstructs)")
    }

    // ## ⚠️⚠️ 下面四条的输入，第一版**全都没有牙**（变异台账 M2/M3/M4/M5 实测，第十一次）
    //
    // 它们当时喂的输入长这样：`"\(format(name, "https://a/b"))"; _ = write(lockFile: …playLockFile)`，
    // 断言 `code.contains("playLockFile")`。看着挺像回事 —— **而 M3（插值栈退化成标志位）与 M4
    // （括号不计数）两条变异，两个包 2776 条断言零红，双双存活。**
    //
    // 根因是一句必须写死在这里、否则下一个人还会再犯的话：
    //
    // > **状态机倒相成 `.string` 并不吃代码** —— 字符串内容照样 `code.append`。只有倒相进 `.code`
    // > **而且那个位置上有 `//`**，才会开出一条假注释、把整行剩下的代码吃掉。
    //
    // 上面那份输入里，误判区（正确实现在插值内、变异实现已弹回串内的那一段）**一个 `//` 都没有**，
    // 而且引号奇偶自我抵消 —— 变异版与原版的 `code` **逐字节相同**，`unmodeledConstructs` 都是 `[]`。
    // 一条断言若对它点名要杀的那个缺陷永远红不了，它就是恒真的；suite 名字与失败消息把因果写得
    // 越具体，越是在骗读它的人。
    //
    // 修法统一：**把 `//`（或一条真注释）放进误判区内部**，让「倒相」这件事真的有后果。
    // 每条的推演都写在各自的注释里 —— 它们现在全部经定向变异实测会红。

    suite("扫描器：插值里的括号要配平（第一个 `)` 不结束插值 —— 误判区内含 `//`）") {
        // 变异（`)` 无条件闭合插值，不数括号）下的推演：
        //   `\(` 进插值 → `prefix` → `(` → `name` → `)` **误判为插值结束**，弹回 .string
        //   → ` + ` 当串内容 → `"` **被当成串尾**，弹回 .code
        //   → 撞上 `//x` 里的 `//` → **开出一条假行注释**，吃掉整行剩下的代码
        //   → `playLockFile` 消失。
        // 正确实现：`)` 只把括号深度从 1 减到 0，插值继续；`"//x"` 是插值内的字符串字面量。
        //
        // 那个 `"//x"` 就是这条断言的牙。第一版没有它，M4 存活。
        let source = #"""
            let hint = "\(prefix(name) + "//x")"; _ = write(lockFile: ClaudioPaths.playLockFile)
            """#
        let scanned = strippingComments(source)
        expect(
            scanned.code.contains("playLockFile"),
            "插值里的括号必须配平之后才算闭合 —— 第一个 `)` 就弹回字符串，接着那个闭引号会把状态机"
                + "带回代码模式，`\"//x\"` 里的 `//` 当场开出一条假行注释，整行剩下的代码被吃掉，"
                + "而负向兜底只会更绿。得到：\(scanned.code)")
        expect(
            scanned.code.contains("//x"),
            "`\"//x\"` 是插值内的**字符串字面量**，是数据不是注释，必须原样留下。得到：\(scanned.code)")
    }

    suite("扫描器：嵌套插值 —— 插值栈不能是个标志位（误判区末尾挂一条真注释）") {
        // `"\(outer("\(inner)"))"` 是合法 Swift。变异（`enterInterpolation` 用**覆盖**而不是**压栈**）：
        //   外层 `\(` 记下一帧 → `(` 把深度记到 1 → 内层 `\(` **把那一帧连同深度一起覆盖掉**
        //   → 内层 `)` 弹回串内、栈空 → 之后的 `)` `)` 变成普通代码字符
        //   → 真正的闭引号 `"` **反而开了一个新串** → 行尾那条**真注释**于是落在「串内」，被当成数据留下。
        //
        // 所以这条的牙是行尾那条真注释，不是 `playLockFile`（它在变异下照样活着 —— 串内容也会被
        // append，这正是第一版没牙的原因）。同一个手法，`""` 那条 suite 已经用过一次。
        let source = #"""
            let hint = "\(outer("\(inner)"))"; _ = write(lockFile: ClaudioPaths.playLockFile)  // 这句注释必须被剥掉
            """#
        let scanned = strippingComments(source)
        expect(
            !scanned.code.contains("这句注释必须被剥掉"),
            "内层插值闭合之后，外层插值**必须还在**（它的括号深度不能被内层覆盖掉）—— 否则真正的闭"
                + "引号会被当成「开一个新串」，行尾那条真注释就落进了串内，被当成代码文本留下来。"
                + "注释文本活着 = 插值栈退化成了标志位。得到：\(scanned.code)")
        expect(
            scanned.code.contains("playLockFile"),
            "整行代码都得在。得到：\(scanned.code)")
    }

    suite("扫描器：多行字符串里的插值 —— 插值内是**代码**，那里的块注释必须被剥掉") {
        // 第一版这条完全没牙（M2 实测）：`.multilineString` 里单个 `"` 本就不是终止符，`\` 又会把
        // `(` 当转义对整对吞掉 —— 于是「不建模多行串插值」在一份只含嵌套字符串的输入上**毫无后果**，
        // 输出逐字节相同。它的名字（「多行串里的插值同样算数」）比它的杀伤力大。
        //
        // 真正能区分两个实现的，是**只在代码位置才成立**的事：插值表达式里的 `/* … */` 是**注释**，
        // 必须被剥掉；而不建模插值时，它落在多行串内部，会被当成**数据**原样留下。
        let source = #"""
            let help = """
                锁的说明见 \(base ?? "https://claudio.dev/locks" /* 这段块注释在插值里 —— 那是代码位置 */)
                """
            _ = write(lockFile: ClaudioPaths.playLockFile)
            """#
        let scanned = strippingComments(source)
        expect(
            !scanned.code.contains("这段块注释在插值里"),
            "多行字符串里的 `\\(…)` 内部是**代码**，那里的块注释必须被剥掉 —— 它活下来了，说明扫描器"
                + "根本没进插值，整段被当成多行串的内容照抄。得到：\(scanned.code)")
        expect(
            scanned.code.contains("claudio.dev"),
            "插值里那个**字符串字面量**的内容是数据，必须留下（剥的是注释，不是插值本身）。"
                + "得到：\(scanned.code)")
        expect(
            scanned.code.contains("playLockFile"),
            "多行串闭合之后必须回到代码模式。得到：\(scanned.code)")
    }

    suite("扫描器：`\\\\(` **不是**插值起点 —— 而那个 `//` 必须落在假插值**内部**") {
        // 反向的错：把 `\\(`（转义反斜杠 + 左括号）误当插值起点，就会在本该是**字符串内容**的地方
        // 进入代码模式。删掉 `.string` 的转义对处理正是这个后果 —— 第一个 `\` 被当普通字符吃掉，
        // **第二个 `\` 与它后面的 `(` 就凑成了 `\(`**，扫描器一头扎进假插值。
        //
        // 第一版把 `//` 放在假插值**配平之后**（`"\\(x) // …"`），于是它**行内自愈**：`)` 关掉假插值、
        // 弹回串内，`//` 仍是串内容 —— 输出逐字节相同，两条断言双双假绿（M5 实测）。
        // 现在 `//` 落在 `\\(` 与 `)` **之间**：假插值里那个 `//` 会开出一条真的行注释，吃掉整行。
        let source = #"""
            let literal = "\\(x // 这不是注释，它在串内) 串还没完"; _ = write(lockFile: ClaudioPaths.playLockFile)
            """#
        let scanned = strippingComments(source)
        expect(
            scanned.code.contains("playLockFile"),
            "`\\\\` 是**转义反斜杠**，它后面那个 `(` 只是普通字符 —— 把 `\\\\(` 读成插值起点，就会在"
                + "串内进入代码模式，那里的 `//` 当场开出一条假行注释，整行剩下的代码消失。"
                + "得到：\(scanned.code)")
        expect(
            scanned.code.contains("这不是注释，它在串内"),
            "那个 `//` 仍在**串内**，是数据不是注释，必须原样留下。得到：\(scanned.code)")
    }

    // MARK: 注释侧（剥太少 → 假红 → 守卫被删）

    suite("扫描器：真正的行尾注释仍然被剥掉（剥太少 → 负向断言假红 → 守卫被删）") {
        let source = #"""
            _ = write(lockFile: environment.configLockFile)  // 绝不是 ClaudioPaths.playLockFile
            """#
        let scanned = strippingComments(source)
        expect(
            scanned.code.contains("configLockFile"),
            "代码得留下。得到：\(scanned.code)")
        expect(
            !scanned.code.contains("playLockFile"),
            "行尾注释里**谈论** playLockFile 的散文必须被剥掉 —— 否则 `!contains(\"playLockFile\")` "
                + "会因为一句「我不用这把锁」的注释而假红。得到：\(scanned.code)")
    }

    suite("扫描器：整行 doc comment 里的 URL —— 不假红，也不吃掉下一行") {
        // 这条是「为什么不能把 ban 挪到 raw source」的可执行版本：注释里的 URL 完全无害，
        // 一条 `!raw.contains("://")` 会在第一个往 doc comment 里写 URL 的人手上红，
        // 然后被删掉，洞原样回来。
        let source = #"""
            /// 锁的完整说明见 https://claudio.dev/locks
            _ = write(lockFile: environment.settingsLockFile)
            """#
        let scanned = strippingComments(source)
        expect(
            !scanned.code.contains("claudio.dev"),
            "注释整行都该没了。得到：\(scanned.code)")
        expect(
            scanned.code.contains("settingsLockFile"),
            "注释里的 `//` 绝不能吃掉**下一行**的代码。得到：\(scanned.code)")
    }

    suite("扫描器：转义引号不结束字符串（`\"\\\" // …\"` 里那个 `//` 仍在串内）") {
        let source = #"""
            let quote = "他说 \" // 这不是注释"; _ = write(lockFile: ClaudioPaths.playLockFile)
            """#
        let scanned = strippingComments(source)
        expect(
            scanned.code.contains("playLockFile"),
            "转义引号被当成串尾 → 后面那个 `//` 被当成注释起点 → 整行剩下的代码消失。"
                + "得到：\(scanned.code)")
    }

    suite("扫描器：多行字符串里的 `//` 不截断，字符串结束之后的代码照常在") {
        let source = #"""
            let help = """
                锁的说明见 https://claudio.dev/locks
                """
            _ = write(lockFile: ClaudioPaths.playLockFile)
            """#
        let scanned = strippingComments(source)
        expect(
            scanned.code.contains("claudio.dev"),
            "多行字符串的**内容**是数据，不是注释，必须原样留下。得到：\(scanned.code)")
        expect(
            scanned.code.contains("playLockFile"),
            "多行字符串闭合之后的代码必须回到代码模式 —— 它没回来 = 文件剩下的部分被整份当成"
                + "字符串吞掉，而负向断言会因此**全部假绿**。得到：\(scanned.code)")
    }

    suite("扫描器：空字符串字面量 `\"\"` 不把后面的代码吞掉") {
        // ⚠️ 这条的第一版**没有牙**（变异台账当场发现）：它喂的输入里**一个 `//` 都没有**，
        // 于是任何一个「不会凭空发明注释」的实现都能过 —— 包括它要杀的那个朴素截断版。一条对它
        // 声称要防的缺陷永远红不了的断言，正是本 suite 存在的理由在**测试自己身上**的复刻。
        //
        // 现在行尾挂一条**真注释**：`""` 若被误读成「开了一个没关的串」，那么这一行剩下的一切
        // （包括那个 `//`）都会被当成**字符串内容**照抄进 `code` —— 注释文本活下来，第二条断言
        // 当场红。这才是这条断言真正守的那个缺陷。
        let source = #"""
            let empty = ""; _ = write(lockFile: ClaudioPaths.playLockFile)  // 这句注释必须被剥掉
            """#
        let scanned = strippingComments(source)
        expect(
            scanned.code.contains("playLockFile"),
            "`\"\"` 的第二个引号必须闭合第一个（而不是开启一个新串，把后面全吞掉）。"
                + "得到：\(scanned.code)")
        expect(
            !scanned.code.contains("这句注释必须被剥掉"),
            "`\"\"` 之后那个 `//` 必须仍然被当成注释起点 —— 注释文本活下来 = 扫描器把 `\"\"` 误读成"
                + "「开了一个没关的串」，于是这一行剩下的代码与注释全被当成字符串内容照抄。"
                + "得到：\(scanned.code)")
    }

    suite("扫描器：块注释被剥掉（`/* … */` 里的代码不算代码）") {
        let source = #"""
            /* let dead = ClaudioPaths.playLockFile */ let alive = ClaudioPaths.configLockFile
            """#
        let scanned = strippingComments(source)
        expect(
            !scanned.code.contains("playLockFile"),
            "块注释里的东西不是代码。得到：\(scanned.code)")
        expect(
            scanned.code.contains("configLockFile"),
            "块注释**之后**的代码必须回来。得到：\(scanned.code)")
    }

    suite("扫描器：行结构保住（顺序断言靠它 —— notePanelHidden 必须在 guard 之前）") {
        // `ViewWiringSuite` 有一条断言比的是两个 `range(of:)` 的相对位置。剥注释时若把换行也吞掉，
        // 相对位置还在、但行号全乱；更糟的是把整段代码折成一行，`components(separatedBy:)` 的计数
        // 会跟着变。这条钉的是「剥的是注释，不是行」。
        let source = #"""
            first()  // 注释一
            // 整行注释
            second()
            """#
        let scanned = strippingComments(source)
        expect(
            scanned.code.components(separatedBy: "\n").count
                == source.components(separatedBy: "\n").count,
            "行数必须与原文一致（剥的是注释，不是行）。原文 "
                + "\(source.components(separatedBy: "\n").count) 行，得到 "
                + "\(scanned.code.components(separatedBy: "\n").count) 行")
        guard let first = scanned.code.range(of: "first"),
            let second = scanned.code.range(of: "second")
        else {
            expect(false, "两句代码都该在：\(scanned.code)")
            return
        }
        expect(first.lowerBound < second.lowerBound, "顺序不能乱")
    }

    // MARK: 「我不认识」清单 —— 枚举盲区 + 结构性失步兜底

    suite("扫描器：撞见 raw string 要**记一笔**，而不是安静地给出一份不可信的文本") {
        let source = #"""
            let pattern = ##"a//b"##
            """#
        let scanned = strippingComments(source)
        expect(
            !scanned.unmodeledConstructs.isEmpty,
            "扫描器不建模 raw string（它能含裸 `//`）。它必须自己说出来 —— 这张清单被两个 suite 各一条"
                + "断言盯着。不说 = 一份不可信的 `code` 被当成可信的，负向断言在上面假绿")
    }

    suite("扫描器：扩展 regex 字面量 `#/…/#` 也要记一笔（它能含裸 `//`）") {
        // `#/https://x/#` 是合法 Swift，而扫描器不建模它：那个 `//` 会被当成注释起点，吃掉整行。
        // 仓库现在一个都没有 —— 但「现在没有」正是上一版对 raw string 说过、然后被插值打脸的话。
        let source = #"""
            let matcher = #/https://claudio.dev/#
            _ = write(lockFile: ClaudioPaths.playLockFile)
            """#
        let scanned = strippingComments(source)
        expect(
            !scanned.unmodeledConstructs.isEmpty,
            "扫描器不建模扩展 regex 字面量。不记账 = 它安静地吃掉那一行，负向兜底更绿。"
                + "得到：\(scanned.unmodeledConstructs)")
    }

    suite("扫描器：`hasPrefix(\"#\")` **不是** raw string（守卫必须位置感知，否则它自己会假红）") {
        // 这条不是洁癖，它挡的是一整类「守卫因为无害改动而红 → 被下一个人删掉 → 洞原样回来」：
        // `ClaudioColorHex.swift` / `ContrastRatio.swift` 里真的有 `hasPrefix("#")`，
        // 它逐字包含 `#"`。一条纯文本的 `#"` 守卫会在这两个文件上当场假红。
        let source = #"""
            if hexString.hasPrefix("#") { hexString.removeFirst() }
            """#
        let scanned = strippingComments(source)
        expect(
            scanned.unmodeledConstructs.isEmpty,
            "字符串**里面**的 `#\"` 不是 raw string 起点 —— 只有**代码位置**的才是。"
                + "得到：\(scanned.unmodeledConstructs)")
        expect(
            scanned.code.contains("hasPrefix"),
            "这一行是正常代码，必须原样留下。得到：\(scanned.code)")
    }

    suite("扫描器：结构性失步要记一笔 —— **四个** note 站点各一条 fixture，一个都不许漏") {
        // 这是清单的**第 2 类**来源：不靠「我们想得到是什么构造」。
        //
        // ⚠️ 它**不是**万能网，别再让措辞比覆盖范围大：一次在**行内**就重新同步回来的失步逃得过它
        // （2f107b5 那个插值 bug 就是 —— 它靠行尾的 `\n` 关掉误开的 lineComment，扫完文件稳稳停在
        // 代码模式，EOF 检查一声不吭）。它挡的只是把状态机**带出这一行**的那一类。真正杀掉插值那个
        // 洞的是上面那几条**正向**断言，不是这一条。
        //
        // ⚠️⚠️ 第一版只覆盖了**四个 note 站点里的两个**（变异台账 M8 实测）：`unterminated
        // multi-line string` 与 `unterminated string interpolation` **零 fixture** —— 单删这两个
        // 分支，两个包 2776 条断言**一条都不会红**。suite 的名字写着「结构性失步要记一笔」，而它
        // 只钉住了一半。措辞比覆盖范围大，复发在杀它的那一刀里。现在四个站点各一条。
        func unmodeled(_ source: String) -> [String] {
            strippingComments(source).unmodeledConstructs
        }

        let unterminatedBlock = "/* 这个块注释没有关\n_ = write(lockFile: ClaudioPaths.playLockFile)\n"
        expect(
            !unmodeled(unterminatedBlock).isEmpty,
            "块注释没闭合 = 它后面的**所有代码**都被当成注释吃掉了，而负向兜底会因此全部假绿。"
                + "扫描器必须记一笔。得到：\(unmodeled(unterminatedBlock))")

        let unterminatedString = "let x = \"没关的串\n_ = write(lockFile: ClaudioPaths.playLockFile)\n"
        expect(
            !unmodeled(unterminatedString).isEmpty,
            "单行字符串里撞见**裸换行**，在合法 Swift 里不可能 —— 出现了就说明状态机已经被带偏。"
                + "得到：\(unmodeled(unterminatedString))")

        let unterminatedMultiline = "let x = \"\"\"\n没关的多行串\n_ = write(lockFile: ClaudioPaths.playLockFile)\n"
        expect(
            !unmodeled(unterminatedMultiline).isEmpty,
            "多行字符串没闭合 = 文件剩下的部分被整份当成字符串内容 —— 那份 `code` 不再可信。"
                + "扫描器必须记一笔。得到：\(unmodeled(unterminatedMultiline))")

        let unterminatedInterpolation = "let x = \"\\(compute(\n"
        expect(
            !unmodeled(unterminatedInterpolation).isEmpty,
            "插值没闭合（扫完文件插值栈还非空）= 状态机被带偏了，之后的模式判断全不可信。"
                + "扫描器必须记一笔。得到：\(unmodeled(unterminatedInterpolation))")
    }

    suite("扫描器：正常源码**不**记账（兜底不能假红 —— 假红的守卫会被删掉）") {
        // 上面那两条兜底若太敏感，它会在每一个正常文件上红，然后被下一个人删掉，洞原样回来。
        // 这条是它们的反向控制：一份用满了「插值 / 嵌套插值 / 转义 / 多行串 / 注释」的正常源码，
        // 清单必须是**空的**。
        let source = #"""
            /// doc: 见 https://claudio.dev/locks
            func describe(_ items: [String], base: String?) -> String {
                let joined = items.joined(separator: ", ")  // 行尾注释
                let url = "\(base ?? "https://claudio.dev")/locks"
                let quoted = "他说 \"你好\""
                let block = """
                    多行：\(joined) 与 \(url)
                    """
                /* 块注释里也写点 https://x//y */
                return "\(quoted)\(block)"
            }
            """#
        let scanned = strippingComments(source)
        expect(
            scanned.unmodeledConstructs.isEmpty,
            "这是一份**完全正常**的 Swift 源码（插值 / 嵌套插值 / 转义引号 / 多行串 / 两种注释都有）。"
                + "在它身上记账 = 兜底假红，两个 suite 的 unmodeled 守卫会在真实源文件上一起红，"
                + "然后被下一个人删掉。得到：\(scanned.unmodeledConstructs)")
        expect(
            scanned.code.contains("joined(separator:"),
            "正常代码必须原样活着。得到：\(scanned.code)")
        expect(
            !scanned.code.contains("块注释里也写点"),
            "块注释必须被剥掉。得到：\(scanned.code)")
    }

    // MARK: `codeWithoutStringLiterals` —— 字符串内容清空、界定符与插值代码保留
    //
    // ⚠️ 上一版这个字段的行为**只**由 helper 包的 `AtomicWriteSuite` suite ③ 钉着（`/codex review
    // 3af8d5f` 红队命中）。而它是**共享**扫描器的输出：gui 包里逐字节相同的那一份，`AtomicWriteSuite`
    // 不在那儿跑 —— 于是共享扫描器的这半个契约，在 gui 包里一条正向断言都没有。这个 suite 是**共享**
    // 的（跟着哨兵区块一起复制进两个包），所以现在两个包各自都钉住了它。

    suite("扫描器：`codeWithoutStringLiterals` 清空字符串**内容**、但界定符与插值里的代码原样留下") {
        // 字符串内容清空：里面的 `(` 不许把「按配平括号取实参」的扫描带偏（`"pack (1.json"` 那个 bug）。
        let paren = strippingComments(#"let p = f("pack (1.json", .atomic)"#)
        expect(
            !paren.codeWithoutStringLiterals.contains("pack (1.json"),
            "字符串**内容**必须清空。得到：\(paren.codeWithoutStringLiterals)")
        expect(
            paren.codeWithoutStringLiterals.filter { $0 == "(" }.count
                == paren.codeWithoutStringLiterals.filter { $0 == ")" }.count,
            "清空之后括号必须配平（串里那个 `(` 不能留下）。得到：\(paren.codeWithoutStringLiterals)")
        // 界定符保留：开闭引号是**代码位置**，去掉它们会让引号奇偶倒相。
        expect(
            paren.codeWithoutStringLiterals.filter { $0 == "\"" }.count == 2,
            "开闭引号（界定符）必须留下，只清内容。得到：\(paren.codeWithoutStringLiterals)")

        // 一句写着 `.write(to:` 的**散文串**不许变成调用点。
        let prose = strippingComments(#"let hint = "改成 data.write(to: f) 就好了""#)
        expect(
            !prose.codeWithoutStringLiterals.contains("write(to: f)"),
            "字符串里的散文清空后不能再像一处调用。得到：\(prose.codeWithoutStringLiterals)")

        // 插值 `\(…)` 里面是**代码**，不是内容 —— 清空字符串绝不能把它一起吃掉
        // （`/codex review 2f107b5` 那个 P1 的形状：一处藏在插值里的写调用永久隐身）。
        let interp = strippingComments(##"log("wrote \(write(lockFile: ClaudioPaths.playLockFile)) ok")"##)
        expect(
            interp.codeWithoutStringLiterals.contains("playLockFile"),
            "插值里的代码是代码，必须活着 —— 把它一起清空 = 藏在插值里的写调用永久隐身。"
                + "得到：\(interp.codeWithoutStringLiterals)")
        // 而插值**外面**的串内容仍要清掉。
        expect(
            !interp.codeWithoutStringLiterals.contains("wrote"),
            "插值外的字符串内容仍要清空。得到：\(interp.codeWithoutStringLiterals)")

        // 换行保留：行结构塌掉会让失败消息里的行号变成谎话。
        let multiline = strippingComments("let a = \"x\"\nlet b = \"y\"")
        expect(
            multiline.codeWithoutStringLiterals.contains("\n"),
            "换行必须留下（行号 = 失败消息的可读性）。得到：\(multiline.codeWithoutStringLiterals)")
    }

    // MARK: 两个包里的那一份，逐字相同 —— 这条不再是注释里的承诺

    suite("扫描器：两个测试包里的哨兵区块**逐字节相同**（`/codex review 2f107b5` 的 P2）") {
        // 扫描器是跨包**复制**的（两个 package 的测试可执行文件互相 import 不到）。上一版在
        // doc comment 里写着「与另一包里的那一份逐字相同」—— 而**没有任何东西执行这句话**。
        // 只改一份，两个包的 census 就会跑在不同的扫描器语义上，而注释仍然声称它们是同一份。
        //
        // ⚠️ 这条守的是**漂移**，不是**正确性**：两份被同样地改错，它照样绿（行为由上面那一批
        // 正向断言守）。别把它读成比它更大的东西。
        let helperPath = "helper/Tests/ClaudioCoreTests/TestSupport.swift"
        let guiPath = "gui/Tests/ClaudioGUICoreTests/TestSupport.swift"

        guard let helperRegion = sharedScannerRegion(of: helperPath),
            let guiRegion = sharedScannerRegion(of: guiPath)
        else {
            expect(
                false,
                "两份 TestSupport.swift 里都必须有 `claudio:shared-scanner:begin` / `:end` 哨兵 —— "
                    + "抽不出来 = 下面那条 `==` 会拿两个空串比出恒真，**又一条永远不会红的守卫**")
            return
        }

        // ⚠️ 正向控制，这条不能省：少了它，哨兵被改名 / 区块被清空会让两边同时抽到空串，
        //    下面的 `==` **恒真**。这正是本文件通篇在杀的那个形状。
        for (path, region) in [(helperPath, helperRegion), (guiPath, guiRegion)] {
            expect(
                region.contains("func strippingComments"),
                "\(path) 的哨兵区块里必须真的装着扫描器本体 —— 抽到的不是它，下面那条逐字节比较"
                    + "就是在比两坨无关的文本（或两个空串）")
            expect(
                region.contains("func enterInterpolation"),
                "\(path) 的哨兵区块里必须装着**插值**那一段 —— 它是 `/codex review 2f107b5` P1 的修复"
                    + "本体。抽到一个没有它的区块 = 比较的不是我们以为在比的东西")
        }

        // 失败消息报**第一处不同的那一行**，不是字符数。
        // 变异台账 M10 逮到的可用性缺陷：等长漂移（改个词、换个等长的变量名）下，只报字符数会打印出
        // 「helper 8587 字符 / gui 8587 字符」—— 两个**相同**的数字后面跟着「它们不一样」，读消息的人
        // 会先怀疑守卫本身有 bug，而不是去看漂移。一条让人读不懂的失败消息，和一条不会红的断言，
        // 在「下一个人会把它删掉」这件事上是等价的。
        let helperLines = helperRegion.components(separatedBy: "\n")
        let guiLines = guiRegion.components(separatedBy: "\n")
        var firstDifference = "（找不到不同的行 —— 两份只在行数上不同）"
        for offset in 0..<min(helperLines.count, guiLines.count)
        where helperLines[offset] != guiLines[offset] {
            firstDifference =
                "哨兵区块第 \(offset + 1) 行：\n"
                + "      helper: \(helperLines[offset])\n"
                + "      gui   : \(guiLines[offset])"
            break
        }
        expect(
            helperRegion == guiRegion,
            "两个包里的扫描器已经不一样了 —— 只改一份，两套 census 就跑在不同语义上，而各自的 doc "
                + "comment 仍然声称它们是同一份。第一处不同：\(firstDifference)\n"
                + "    （helper \(helperLines.count) 行 / gui \(guiLines.count) 行）。改一份 = 两份一起改")
    }

    // MARK: T3 并发绊线 —— manifest.json 唯一的并发安全保证是「全同步 + 全在 @MainActor」，
    // 不是锁（PLAN-SOUND-MANAGER.md §2.1：`grep -iE 'lock' ManifestBinding.swift` 是空的）。
    // 本计划会往 manifest.json 上加三个新写者（`clearEventBinding` / 未来的 `forkPack` /
    // `restoreFactoryPack`）和一个新 UI 面（管理窗口）—— 一次善意的 `async` 重构会让这条无锁的
    // 读-改-写在并发绑定/清除下静默丢更新，而且**没有任何运行时会报错**。这是这一批改动里
    // 唯一没有运行时防护的 critical gap（§4c「并发不变式」表格最后一行），这条源码绊线是它
    // **唯一**的守卫——不是写在文档里的一句话，是一条会响的东西。
    //
    // 这条绊线只属于 gui 包：`ManifestBinding.swift` / `PackFork.swift` 是 gui 侧文件，helper
    // 没有对应物，所以不进两包共享的哨兵区块（上面那条「逐字节相同」钉的是 `TestSupport.swift`
    // 里的扫描器本体，不是这个文件，两个包的 `SourceScannerSuite.swift` 允许在这类内容上分叉）。
    suite(
        "绊线（T3）：gui/Sources（两个 target，递归）里**每个**经 mutateManifestJSON 的文件，其导出写"
            + "函数不带已知并发 token（黑名单，非完备）且逐个带 @MainActor；PackFork/PackRestore 未落地哨兵"
    ) {
        // 【纳入判据 —— 内容推导的围栏，不是路径白名单】
        //
        // 上一版（含本次修复的第一稿）是一份写死的**路径**清单。路径清单结构上不可能是围栏：
        // 任何一个 manifest 写者只要落在清单外的文件里，整条绊线一条断言都不跑，而且**没有
        // 任何东西认不出它**。这不是假想——`PLAN-SOUND-MANAGER.md:596` 白纸黑字把 T12 的
        // `restoreFactoryPack` 放在**新 `PackRestore.swift`** 里，而清单（和它上面那句自称
        // 守着 `forkPack` / `restoreFactoryPack` 的注释）只列了 `PackFork.swift`。措辞比覆盖
        // 范围大，第 N 次复发在自称治好它的那一刀里。
        //
        // 所以纳入判据改成**从内容推导**：`gui/Sources`（**含任意深度子目录，递归枚举**）里
        // 任何一个 `.swift` 文件，只要它的代码（已剥注释）里出现 `mutateManifestJSON` —— T3 定下的
        // **唯一** manifest 读-改-写原语，所有写者都必须经它 —— 就自动纳入这条绊线。
        // `PackFork.swift`、`PackRestore.swift`、以及今天还没有人命名的第三个文件（哪怕它落在
        // `ClaudioGUICore/Feature/` 这样的子目录里 —— SwiftPM 照样编译它），落地那天自动被检查，
        // 不需要谁记得回来改一份清单。
        //
        // ⚠️ 扫描根是 **`gui/Sources`（两个 target）**，不是只有 `ClaudioGUICore`。
        // 理由：`mutateManifestJSON` 是 **`public`**（`ManifestBinding.swift:99`），`ClaudioGUI`
        // 那个 executableTarget 依赖 `ClaudioGUICore`，所以一个 SwiftUI 文件**完全能**直接调它。
        // 把围栏钉死在一个 target 上，就是又一次「守的是一个目录，而不变式是全局的」—— 与
        // `/codex review 327d211` 逮到的「守的是一层目录，而 SwiftPM 递归编译」同型。
        // 实测代价为零：今天 `gui/Sources` 底下只有 `ClaudioGUICore/ManifestBinding.swift` 一个文件
        // 含这个 token（`grep -rn mutateManifestJSON gui/Sources`），放宽后纳入集合逐字不变。
        // 姊妹守卫 `ViewWiringSuite.sourcesUnder` 早就是「两个 target 都扫」，这条只是补上对齐。
        //
        // ⚠️ 枚举**必须递归**（`auditManifestConcurrencyFence` 用 `enumerator` 下钻，不是
        // `contentsOfDirectory` 只读一层）：/codex review 327d211 的 P1 —— 非递归时一个落在子目录
        // 的 manifest 写者会被编译却漏出围栏，围栏对它静默为绿，正是这里自称的「任意 .swift」比实际
        // 覆盖范围大的又一次复发。今天 `ClaudioGUICore` 是平的，递归与否产出同一批文件，所以这条
        // 不靠真实布局背书 —— 下面「内容围栏自证有牙」那条 suite 拿一棵含**脏嵌套写者**的临时树
        // 喂**同一个**函数，钉死「围栏对子目录写者真的开火」，改回非递归当场红。
        //
        // ⚠️ **已知限度**（写在这里，免得下一个人把它读成「不可能漏」）：
        // · **绕开原语**、自己 read-modify-write `manifest.json` 的写者不会被这条判据纳入。挡那一种
        //   的不是这里，是下面的哨兵组 + code review。这条围栏守的是「经原语的写者不许变并发」，
        //   不是「没有人能绕开原语」。
        // · 纳入的是**子目录**里的 `.swift`，判据比 SwiftPM 实际编译的集合**略宽**：SwiftPM 会忽略
        //   `.xcodeproj` / `.playground` / `.xcworkspace` 等 opaque 目录，这里会下钻它们
        //   （/codex review 15ce131 的 P2）。方向是**多扫 ⇒ 假红**，落在安全侧，故不修 —— 真出现
        //   一个 `Example.playground/Sources/Writer.swift` 让它假红，那时再排除，别提前加复杂度。
        // · `Package.swift` 今天没有 `sources:` / `exclude:` / 插件配置，所以「普通子目录全部递归」
        //   与 SwiftPM 的发现规则一致。哪天加了 `exclude:`，这条判据会比实际编译集合更宽 ——
        //   同样是假红，同样安全侧。
        // · **点开头**的文件/目录两边都忽略（实测，不是推测：`.Dotted.swift` 里的符号在 SwiftPM 下
        //   报 `cannot find in scope`）。但 **`UF_HIDDEN` 标志**两边**不**一致 —— SwiftPM 照编译，
        //   `.skipsHiddenFiles` 会跳过。所以本围栏**不用**那个 option，改自己按点开头过滤；
        //   见 `auditManifestConcurrencyFence` 里那段。上一稿这里写「隐藏路径两边也都忽略」，
        //   是没验就写的假话，被红队实测打掉。
        // ⚠️ 两个常量，**别合并**：`scanRelativeRoot` 是围栏的**覆盖范围**（放宽过一次），
        // `coreRelativeDirectory` 是今天已知写者所在的 target，只给下面的具名钉子和哨兵拼路径用。
        // 第一版把两者合成一个变量，放宽扫描根那一刀顺手把具名钉子也指到了 `gui/Sources/
        // ManifestBinding.swift`（不存在）—— 实测当场红。改覆盖范围时，跟着它走的东西也得一起改，
        // 分成两个常量就是让编译器/测试替人记住这件事。
        let scanRelativeRoot = "gui/Sources"
        let coreRelativeDirectory = "gui/Sources/ClaudioGUICore"
        let scanRootURL = repoRoot().appendingPathComponent(scanRelativeRoot)

        // ⚠️ 这一行**就是**整条围栏。枚举、纳入判据、三条判定腿全在 `auditManifestConcurrencyFence`
        // 里边（见它头上那段 MARK）—— 调用点上没有枚举可以被改回非递归，这正是 `/codex review 15ce131`
        // P1 的修法：上一版把枚举抽成 helper、真围栏与自证各自调它，改**调用点**就能让围栏静默退化。
        let audit = auditManifestConcurrencyFence(
            under: scanRootURL, pathPrefix: "\(scanRelativeRoot)/")

        // 目录枚举本身不许静默失明：目录被改名/移走 → 枚举出空数组 → 下面「每个纳入的文件都
        // 得清白」对空集恒真。这条把那种失明变成红。
        expect(
            !audit.enumeratedSubpaths.isEmpty,
            "\(scanRelativeRoot) 里一个 .swift 都没枚举到 —— 目录被改名/移走了，纳入判据"
                + "扫不到任何文件，整条绊线退化成对空集恒真。把目录路径更新到新位置。")

        // 覆盖范围本身要有东西钉住，否则「扫两个 target」这件事没有任何断言背书 —— 谁把
        // `scanRelativeRoot` 改回 `gui/Sources/ClaudioGUICore`，今天全部 2132 条照样全绿（唯一的
        // 写者就在 Core 里），围栏对 `ClaudioGUI` 静默失明而没有一条断言会响。这正是本轮修的那个
        // 病（覆盖范围缩水而措辞不变），所以扩范围的同一刀必须把新范围钉死。
        for target in ["ClaudioGUICore/", "ClaudioGUI/"] {
            expect(
                audit.enumeratedSubpaths.contains { $0.hasPrefix(target) },
                "枚举结果里一个 \(target) 下的文件都没有 —— 扫描根被收窄了（`scanRelativeRoot` 应当是 "
                    + "`gui/Sources`，覆盖两个 target）。`mutateManifestJSON` 是 public，`ClaudioGUI` "
                    + "完全能直接调它；只扫 Core 就是把全局不变式守成了一个目录。"
                    + "实际枚举到 \(audit.enumeratedSubpaths.count) 个文件。")
        }

        // 判据自身不许瞎：纳入集合空 = 「每个纳入的文件都得清白」对空集恒真，整条围栏是空话。
        // `mutateManifestJSON` 被改名、`strippingComments` 把代码吃光、`contains` 写反——任何
        // 一种都会走到这里。
        let enrolledPaths = audit.enrolledSubpaths.map { "\(scanRelativeRoot)/\($0)" }
        expect(
            !enrolledPaths.isEmpty,
            "纳入判据一个 manifest 写者文件都没逮到 —— 判据瞎了（`mutateManifestJSON` 被改名？"
                + "剥注释把代码吃光了？`contains` 写反了？）。下面『每个纳入的文件都得清白』因此"
                + "是一句对空集的恒真绿，整条围栏形同虚设。")

        // 再钉一条**具名**的：今天已知的那个写者文件得在里面。
        //
        // ⚠️ 这条红的时候有**两种**成因，别只报一种（消息里两条都写上）：判据真瞎了，或者这个
        // 文件被合法改名了。后者不是 bug——内容围栏会自动跟着改名后的文件走（实测：改名成
        // `ManifestWriters.swift` 后它照样被纳入、照样受检），只是这条具名的钉子需要有人更新。
        // 一次改名理应让人回来重读这条绊线，所以这个红是有意保留的，但它的诊断必须诚实。
        expect(
            enrolledPaths.contains("\(coreRelativeDirectory)/ManifestBinding.swift"),
            "纳入结果里没有 ManifestBinding.swift。两种可能，请自行分辨：\n"
                + "  · 它被改名/移走了 —— 内容围栏已经自动跟上（实际纳入见下），**不是**漏检；"
                + "把这条具名钉子里的文件名更新过去即可。\n"
                + "  · 判据瞎了 —— 若『实际纳入』也是空的或明显不对，那是 `mutateManifestJSON` "
                + "被改名 / 剥注释吃光了代码。\n"
                + "实际纳入：\(enrolledPaths)")

        // 【哨兵组】守的是上面那条围栏**唯一**盖不住的那件事：新写者**绕开原语**。
        //
        // 这两个文件是计划点名的未来 manifest 写者（`PLAN-SOUND-MANAGER.md:743` 的 T6
        // `PackFork.swift` / `:596` 的 T12 `PackRestore.swift`）。今天正向断言它们**尚不存在**；
        // 落地当天这条哨兵变红，逼一个人回来**确认新写者确实经 `mutateManifestJSON`**——确认了，
        // 它就已经被上面的围栏自动纳入，这条哨兵删掉即可；没经原语，围栏漏得掉它，得在这里补。
        // 哨兵不重复围栏的工作，它守的正是围栏的盲区。
        let pendingManifestWriterPaths = [
            "\(coreRelativeDirectory)/PackFork.swift",
            "\(coreRelativeDirectory)/PackRestore.swift",
        ]
        for relativePath in pendingManifestWriterPaths {
            let fileURL = repoRoot().appendingPathComponent(relativePath)
            expect(
                !FileManager.default.fileExists(atPath: fileURL.path),
                "\(relativePath) 出现了 —— 计划点名的一个 manifest 新写者落地了。回来确认一件"
                    + "上面那条内容围栏**盖不住**的事：它是不是真的经 `mutateManifestJSON` 写 "
                    + "manifest？\n"
                    + "  · 是 → 它已被自动纳入（并发 token + @MainActor 两条腿都在跑），把这条路径"
                    + "从 `pendingManifestWriterPaths` 删掉即可。\n"
                    + "  · 否 → 它绕开了原语，围栏漏得掉它，manifest.json 的零锁读-改-写多了一个"
                    + "不设防的写者。要么让它经原语，要么在这里补一条针对它的检查。\n"
                    + "（PLAN-SOUND-MANAGER.md §2.1 / 4c「并发不变式」）")
        }

        // 判定结果。诊断消息全在 `auditManifestConcurrencyFence` 里成文（真围栏与自证 suite 读的是
        // **同一批**消息），这里只负责把每一条变成一次红。
        //
        // 一条 finding = 一次 `expect(false, …)`：违规（并发 token / 缺 @MainActor / 扫描器不认识的
        // 构造）与**无从判定**（symlink / 判不出类型 / 读不到 / 子树枚举出错）都在里面 —— 围栏极性
        // 是「认不出 ⇒ 红」，两类同等对待。
        for finding in audit.findings {
            expect(false, finding)
        }
    }

    // 上面那条内容围栏**整条生产路径**的自证有牙（`/codex review 15ce131` 的 P1）。
    //
    // ## 为什么这条 suite 必须存在
    // 今天 `gui/Sources/ClaudioGUICore` 是**平的**，递归与非递归产出同一批文件 —— 真实布局给不了
    // 「递归确实在下钻」的任何背书。谁把枚举改回只读一层，真文件那条围栏**一条断言都不会变**。
    //
    // ## 为什么上一版这条 suite 不够（这次被 Codex 打穿的正是它）
    // 上一版只喂**枚举 helper**，断言「嵌套文件被枚举到」。那只覆盖了一个零件：改 helper 会红，
    // 改**调用点**（在真围栏那侧对结果 `.filter` 掉带 `/` 的项）helper 原封不动、这条 suite 全绿。
    // 现在整条路径（枚举 → 纳入判据 → 三条判定腿）都在 `auditManifestConcurrencyFence` 一个函数里，
    // 这条 suite 喂它一棵**含脏嵌套写者**的临时树，钉的不再是「文件被看见」，而是
    // **「围栏对子目录里的脏写者真的开火」**。
    //
    // ## 正负控制成对
    // 只断言「脏的会红」是不够的 —— 一个「见谁咬谁」的坏围栏也能满足它。所以每条正控都配一条负控：
    // 干净写者不许被报、非写者（不含原语）不许被纳入。两侧同时钉，围栏才既有牙又不乱咬。
    suite("绊线（T3）内容围栏自证有牙：整条生产路径对子目录里的脏 manifest 写者必须真的开火") {
        withTempDirectory { root in
            let scanned = root.appendingPathComponent("scanned")

            // ── 正控 1：顶层的**干净**写者。既是「基本流程没坏」的对照，也是负控（不许被报）。
            writeFixture(
                "@MainActor public func topWriter() { mutateManifestJSON() }",
                to: scanned.appendingPathComponent("TopWriter.swift"))
            // ── 正控 2【关键腿·并发】：子目录里的**脏**写者 —— 带 @MainActor 但是 async。
            //    纳入判据必须够到它，**并且**并发那条腿必须对它开火。
            //    刻意同时含 `async` 与 `Task` 两个 token：整条生产路径此前只对 `async` 有过端到端
            //    证据，其余七个只被那条**直喂判据**的 suite 走过（红队 finding #10）。
            writeFixture(
                "@MainActor public func nestedWriter() async { Task { mutateManifestJSON() } }",
                to: scanned.appendingPathComponent("Feature/NestedWriter.swift"))
            // ── 正控 3【关键腿·@MainActor】：更深一层、**缺 @MainActor** 的写者。
            //    递归不止下钻一层，且第二条腿也必须对子目录开火。
            writeFixture(
                "public func deepWriter() { mutateManifestJSON() }",
                to: scanned.appendingPathComponent("Feature/Deep/DeepWriter.swift"))
            // ── 负控 1：子目录里一个 async 的**非写者**（不含原语）。纳入判据必须放过它 ——
            //    否则「纳入」退化成「目录下所有文件」，而围栏自称是**内容**推导的。
            writeFixture(
                "@MainActor public func bystander() async { _ = 1 }",
                to: scanned.appendingPathComponent("Feature/Bystander.swift"))
            // ── 干扰项：非 .swift 文件、以及一个名字带 .swift 的**目录**。
            writeFixture("not swift", to: scanned.appendingPathComponent("Feature/README.md"))
            let bogusDirectory = scanned.appendingPathComponent("Bogus.swift")
            // ⚠️ 这里**不能**用 `try?` 吞掉（上一版就是）：创建失败 → 干扰项根本不存在 →
            // 下面那条「目录没被当成源文件」在一个不存在的东西上真空变绿（/codex review 15ce131 的 P2）。
            let bogusCreated =
                (try? FileManager.default.createDirectory(
                    at: bogusDirectory, withIntermediateDirectories: true)) != nil
            expect(
                bogusCreated,
                "建不出 Bogus.swift 这个**目录**干扰项 —— 下面那条『名字带 .swift 的目录不许被当成"
                    + "源文件』会在一个不存在的输入上真空变绿，等于没测。")

            let audit = auditManifestConcurrencyFence(under: scanned)

            // ── 枚举：递归真的在下钻，且相对路径带子目录前缀 ───────────────────────────
            expect(
                audit.enumeratedSubpaths.contains("TopWriter.swift"),
                "顶层 TopWriter.swift 没被枚举到 —— 枚举器整个瞎了。实际：\(audit.enumeratedSubpaths)")
            expect(
                audit.enumeratedSubpaths.contains("Feature/NestedWriter.swift"),
                "子目录里的 Feature/NestedWriter.swift 没被枚举到 —— 枚举退回了非递归（只读一层）。"
                    + "SwiftPM 会编译子目录源文件，落在那里的 manifest 写者会被围栏静默漏掉"
                    + "（/codex review 327d211 的 P1）。实际：\(audit.enumeratedSubpaths)")
            expect(
                audit.enumeratedSubpaths.contains("Feature/Deep/DeepWriter.swift"),
                "更深一层的 Feature/Deep/DeepWriter.swift 没被枚举到 —— 递归只下钻了一层。"
                    + "实际：\(audit.enumeratedSubpaths)")
            expect(
                !audit.enumeratedSubpaths.contains("NestedWriter.swift")
                    && !audit.enumeratedSubpaths.contains("DeepWriter.swift"),
                "子目录文件的相对路径被拍平成了 lastPathComponent（丢了子目录前缀）—— 两个不同目录下"
                    + "的同名文件会撞车，诊断消息指错地方。实际：\(audit.enumeratedSubpaths)")
            expect(
                !audit.enumeratedSubpaths.contains(where: { $0.hasSuffix("README.md") }),
                "非 .swift 文件混进来了。实际：\(audit.enumeratedSubpaths)")
            expect(
                !audit.enumeratedSubpaths.contains("Bogus.swift"),
                "一个名字带 .swift 的目录被当成源文件纳入了 —— 会在读取那步假红。"
                    + "实际：\(audit.enumeratedSubpaths)")

            // ── 纳入判据：由**内容**决定，且够得到子目录 ─────────────────────────────
            expect(
                audit.enrolledSubpaths.contains("Feature/NestedWriter.swift"),
                "子目录里的 manifest 写者没被纳入 —— 纳入判据够不到子目录，落在那里的写者不设防。"
                    + "实际纳入：\(audit.enrolledSubpaths)")
            expect(
                !audit.enrolledSubpaths.contains("Feature/Bystander.swift"),
                "一个**不含** `mutateManifestJSON` 的文件被纳入了 —— 纳入判据退化成『目录下所有文件』，"
                    + "而围栏自称是内容推导的。它会让无关文件因为一句 async 假红。"
                    + "实际纳入：\(audit.enrolledSubpaths)")

            // ── 判定：两条腿都必须对**子目录里**的脏写者真的开火 ──────────────────────
            //
            // 这是上一版整条缺掉的那一段：上一版只证明「文件被看见」，没证明「看见之后真的判了它」。
            //
            // ⚠️ 断言认的是**每条腿专有的措辞**，不是「路径 + 函数名」。红队逮到过一次：上一稿按
            // 「路径 + `deepWriter`」匹配，而当时 `exported.isEmpty` 那条 finding 的诊断里回显了
            // `scanned.code.prefix(200)` —— 源码里就有 `deepWriter` 这个词。于是把 @MainActor 整条腿
            // 掐死、只要枚举器返回空，这条断言会被**另一条腿的 finding** 满足而全绿。
            // 现在两侧都修了：诊断不再回显源码，断言也改钉专有措辞。两道各自独立。
            expect(
                audit.findings.contains {
                    $0.contains("Feature/NestedWriter.swift")
                        && $0.contains("命中 token：async, Task")
                },
                "子目录里那个 **async** 的 manifest 写者没让**并发**那条腿开火 —— 围栏看得见它却不判它，"
                    + "等于没有围栏。实际诊断：\(audit.findings)")
            expect(
                audit.findings.contains {
                    $0.contains("命中 token：async, Task")
                },
                "并发那条腿只对 `async` 有端到端证据。这个 fixture 同时含 `Task`，它必须一起被报出来 ——"
                    + "否则黑名单里除 `async` 外的七个 token 在**整条生产路径**上一次都没被走过，"
                    + "谁把它们从清单里删掉，只有那条直喂判据的 suite 会红，围栏这侧一声不吭。"
                    + "实际诊断：\(audit.findings)")
            expect(
                audit.findings.contains {
                    $0.contains("Feature/Deep/DeepWriter.swift")
                        && $0.contains("没有 @MainActor 隔离") && $0.contains("deepWriter")
                },
                "更深一层那个**缺 @MainActor** 的 manifest 写者没让 @MainActor 那条腿开火 —— 第二条腿"
                    + "对子目录失明。实际诊断：\(audit.findings)")
            // 负控（配合上一条）：那条 finding 必须是 @MainActor 腿报的，不能是「枚举器瞎了」顶包。
            expect(
                !audit.findings.contains {
                    $0.contains("Feature/Deep/DeepWriter.swift")
                        && $0.contains("一个 `public func` 都没枚举到")
                },
                "DeepWriter 的写者是标准 `public func` 形状，枚举器不该报「一个都没枚举到」—— 报了说明"
                    + "枚举器真的瞎了，上面那条 @MainActor 断言测的就不是它自称测的东西。"
                    + "实际诊断：\(audit.findings)")

            // ── 负控：围栏不许「见谁咬谁」（缺了这两条，一个恒报的坏围栏也能满足上面两条）──
            expect(
                !audit.findings.contains(where: { $0.contains("TopWriter.swift") }),
                "**干净**的写者被报了 —— 围栏在乱咬，真文件那侧会因此长期假红然后被人删掉。"
                    + "实际诊断：\(audit.findings)")
            expect(
                !audit.findings.contains(where: { $0.contains("Bystander") }),
                "一个非写者被报了 —— 判定跑到了纳入判据之外的文件上。实际诊断：\(audit.findings)")
        }
    }

    // @MainActor 那条腿的**判定精度**自证有牙。
    //
    // 这条 suite 整条来自 `/codex review 15ce131` 之后的红队（27 条提案 / 13 条扛过证伪）。它钉的五件
    // 事此前**一条 fixture 都没有** —— 也就是说 @MainActor 这条腿当时只对「一个文件里有且只有一个
    // 标准 `public func`、且不含任何字符串」这一种形状有过证据，而真实写者文件三条都不满足。
    suite("绊线（T3）@MainActor 腿判定精度自证有牙：字符串不算注解、重载不互相洗白、多写者逐个查、非 public func 形状要喊") {
        withTempDirectory { root in
            let scanned = root.appendingPathComponent("scanned")

            // ① 一个含原语、却**枚举不出任何导出写函数**的文件（`internal func` 形状）。
            //    `exported.isEmpty` 那条兜底此前零 fixture，删掉它全绿 —— 而它守的是
            //    `public extension` 里的成员这类真实重构（枚举器认不出 ⇒ 静默跳过）。
            writeFixture(
                "@MainActor func internalWriter() { mutateManifestJSON() }",
                to: scanned.appendingPathComponent("NoPublicFunc.swift"))

            // ② 一个文件里**两个**导出写函数，只有第二个缺 @MainActor。
            //    此前所有 fixture 都是「每文件一个 public func」，于是把逐个检查改成只查第一个
            //    （`exported.first`）照样全绿。
            writeFixture(
                """
                @MainActor public func firstWriter() { mutateManifestJSON() }
                public func secondWriter() { _ = 1 }
                """,
                to: scanned.appendingPathComponent("TwoWriters.swift"))

            // ③ **字符串里的散文不算注解。** 真注解被删、只留一句写着 @MainActor 的字符串 ——
            //    读 `code`（保留字符串内容）的守卫会被它满足，这是本文件开头记着那个病的第三次复发。
            //    ⚠️ decoy 里**故意不带 `public`**。台账第四轮实测：带 `public` 的 decoy
            //    （`"@MainActor public func decoyWriter"`）会让**导出**计数也 +1（1 真 + 1 幻影 = 2）
            //    而隔离只有 1，于是计数法自己就把它挡了 —— 那样这条 fixture 测的是计数法，不是
            //    「读哪个字段」，M12 变异照样全绿。不带 `public` 才只加隔离那一侧：真函数导出 1 /
            //    隔离 0，加上幻影隔离 1 → 1≥1，缺口消失、洗白成功。这才是真正的攻击形状。
            writeFixture(
                """
                public func decoyWriter() {
                    let note = "@MainActor func decoyWriter —— 见 PLAN-SOUND-MANAGER.md §2.1"
                    _ = note
                    mutateManifestJSON()
                }
                """,
                to: scanned.appendingPathComponent("DecoyString.swift"))

            // ④ **同名重载不互相洗白。** 一个带 @MainActor 的重载，不能替它那个没带的兄弟背书。
            writeFixture(
                """
                @MainActor public func overloaded(a: Int) { mutateManifestJSON() }
                public func overloaded(b: Int) { _ = b }
                """,
                to: scanned.appendingPathComponent("Overload.swift"))

            // ⑤ **BSD `UF_HIDDEN` 的文件 SwiftPM 照编译**（实测），所以围栏必须看得见它。
            //    `.skipsHiddenFiles` 会跳过它 —— 那正是本轮拆掉那个 option 的理由。
            var hidden = scanned.appendingPathComponent("HiddenFlagWriter.swift")
            writeFixture(
                "@MainActor public func hiddenFlagWriter() async { mutateManifestJSON() }", to: hidden)
            var hiddenValues = URLResourceValues()
            hiddenValues.isHidden = true
            let hiddenFlagSet = (try? hidden.setResourceValues(hiddenValues)) != nil

            // ⑥ 负控：**点开头**的文件 SwiftPM **不**编译（实测），所以围栏纳入它反而是假红。
            writeFixture(
                "public func dottedWriter() async { mutateManifestJSON() }",
                to: scanned.appendingPathComponent(".DottedWriter.swift"))

            let audit = auditManifestConcurrencyFence(under: scanned)

            expect(
                audit.findings.contains {
                    $0.contains("NoPublicFunc.swift") && $0.contains("一个 `public func` 都没枚举到")
                },
                "一个含原语却枚举不出导出写函数的文件被静默放过了 —— 「每个都得 @MainActor」对它退化"
                    + "成恒真绿。实际诊断：\(audit.findings)")

            expect(
                audit.findings.contains {
                    $0.contains("TwoWriters.swift") && $0.contains("`secondWriter`")
                        && $0.contains("没有 @MainActor 隔离")
                },
                "同一个文件里的**第二个**导出写函数没被查 —— 判定只看了第一个。实际诊断：\(audit.findings)")
            expect(
                !audit.findings.contains { $0.contains("`firstWriter`") },
                "带 @MainActor 的 firstWriter 被误报了（负控）。实际诊断：\(audit.findings)")

            expect(
                audit.findings.contains {
                    $0.contains("DecoyString.swift") && $0.contains("`decoyWriter`")
                        && $0.contains("没有 @MainActor 隔离")
                },
                "一句**写着** @MainActor 的字符串把一个没有 @MainActor 的写者洗白了 —— 判定读的是保留"
                    + "字符串内容的 `code`，散文与真注解同形。姊妹腿 `bannedConcurrencyHits` 早就为同一个"
                    + "理由读 `codeWithoutStringLiterals`，这条腿必须跟上。实际诊断：\(audit.findings)")

            expect(
                audit.findings.contains {
                    $0.contains("Overload.swift") && $0.contains("`overloaded`")
                        && $0.contains("没有 @MainActor 隔离")
                },
                "一个带 @MainActor 的同名重载把它没带的兄弟洗白了 —— 判定是全文件按名字 `contains`，"
                    + "不是逐声明。改成数：导出几个，带 @MainActor 的就得有几个。实际诊断：\(audit.findings)")

            if hiddenFlagSet {
                expect(
                    audit.enrolledSubpaths.contains("HiddenFlagWriter.swift"),
                    "带 BSD `UF_HIDDEN` 标志的 .swift 没被枚举到 —— 枚举用了 `.skipsHiddenFiles`，"
                        + "而 SwiftPM **照编译**这种文件（实测：chflags hidden 后 swift build 成功、符号"
                        + "解析得到）。一个 `chflags hidden` 的写者会被编译进 app 却对围栏隐身。"
                        + "实际纳入：\(audit.enrolledSubpaths)")
                expect(
                    audit.findings.contains {
                        $0.contains("HiddenFlagWriter.swift") && $0.contains("命中 token：async")
                    },
                    "UF_HIDDEN 文件被枚举到了却没被判 —— 半条腿。实际诊断：\(audit.findings)")
            } else {
                print("  ⚠ skipped: 这个文件系统不支持 UF_HIDDEN，跳过隐藏标志那两条")
            }

            expect(
                !audit.enumeratedSubpaths.contains(where: { $0.contains(".DottedWriter.swift") }),
                "点开头的文件被纳入了 —— SwiftPM **不**编译它（实测：引用它的符号报 cannot find in "
                    + "scope），纳入它就是纯假红。实际枚举：\(audit.enumeratedSubpaths)")
        }
    }

    // 围栏**极性**自证有牙（`/codex review 15ce131` 的 P1 之三）：「认不出 ⇒ 红」不是一句注释，
    // 是一条会响的东西。上一版这几处全是 fail-**open**（判不出 ⇒ 静默排除 ⇒ 更绿），方向正好反。
    //
    // symlink 是这一族里唯一能廉价、确定地造出来的输入（「resourceValues 取不到类型」「子树枚举
    // 出错」要靠 chmod/挂载花招，本机 root 权限下还不一定稳），所以拿它当这条极性的代表。
    suite("绊线（T3）围栏极性自证有牙：symlink 这种「枚举器看不进去」的东西必须变红，不是被静默跳过") {
        withTempDirectory { root in
            let scanned = root.appendingPathComponent("scanned")
            let outside = root.appendingPathComponent("outside")

            // 正常的干净写者：保证这棵树本身不是靠「什么都没有」变绿的。
            writeFixture(
                "@MainActor public func topWriter() { mutateManifestJSON() }",
                to: scanned.appendingPathComponent("TopWriter.swift"))
            // 链接目标里藏一个**脏**写者。`DirectoryEnumerator` 不下钻 symlink 目录，而 SwiftPM
            // 会跟随 —— 于是这个写者会被编译、却完全漏出围栏。
            writeFixture(
                "public func hiddenWriter() async { mutateManifestJSON() }",
                to: outside.appendingPathComponent("HiddenWriter.swift"))
            createSymlink(at: scanned.appendingPathComponent("Linked"), pointingTo: outside)

            let audit = auditManifestConcurrencyFence(under: scanned)

            // 先钉住这个 fixture 真的**制造了**那个洞：链接目标里的写者确实没被枚举到。
            // 缺了这条，下面那条「必须报 symlink」在一个枚举器其实下钻了的世界里也会绿，
            // 而那时它证明的就不是极性了。
            expect(
                !audit.enrolledSubpaths.contains(where: { $0.contains("HiddenWriter") }),
                "枚举器把 symlink 目录下钻了 —— 这条 suite 的前提不成立（它要钉的是「钻不进去时"
                    + "必须变红」）。实际纳入：\(audit.enrolledSubpaths)")
            // 【关键腿】钻不进去 ⇒ 必须**红**，不是静默跳过。
            expect(
                audit.findings.contains(where: { $0.contains("Linked") }),
                "一个 symlink 被静默跳过了 —— 围栏极性反了（认不出 ⇒ 绿）。落在链接目标里的 manifest "
                    + "写者会被 SwiftPM 编译、却完全漏出围栏，而整条绊线一声不吭。"
                    + "实际诊断：\(audit.findings)")
            // 负控：干净的真文件不受这条影响。
            expect(
                !audit.findings.contains(where: { $0.contains("TopWriter.swift") }),
                "干净的真文件被 symlink 这条误伤了。实际诊断：\(audit.findings)")
        }
    }

    // 围栏极性的其余两条腿（同一轮 P1）。变异台账第一轮实测：这两条在**补上这条 suite 之前全部
    // 存活** —— 也就是说 fail-open → fail-closed 那一刀本身当时一点背书都没有，编译得过、读着对、
    // 没有任何输入喂到它。这正是「第一轮台账逮出的是这一轮新写的断言恒真」的又一次。
    suite("绊线（T3）围栏极性自证有牙之二：根目录不在 / 文件读不到 / 子树枚举出错，三种「无从判定」都得红") {
        // ── 腿 1：根目录不在。**不**需要 root 权限，所以放在 geteuid 闸门之前。
        withTempDirectory { root in
            let audit = auditManifestConcurrencyFence(
                under: root.appendingPathComponent("no-such-directory"))
            expect(
                audit.enumeratedSubpaths.isEmpty,
                "一个不存在的目录居然枚举出了文件。实际：\(audit.enumeratedSubpaths)")
            expect(
                !audit.findings.isEmpty,
                "目录不存在时围栏报了「干净」—— 这是最阴的一种假绿：目录被改名/移走，整条围栏一个"
                    + "文件都没看过，而它对上层说「没问题」。")
            // ⚠️ 上面那条**单独**是不够的，它对「拆掉根目录闸门」恒真：`errorHandler` 会为这个根
            // 目录另报一条，红照样有（台账 M11 第一次存活就是这么来的）。闸门真正贡献的是**诊断
            // 精度** —— 「路径本身不对，去更新它」不能和「某棵子树权限坏了」混成一句话。所以这里
            // 钉它专有的措辞。
            expect(
                audit.findings.contains(where: { $0.contains("不存在、或者不是一个目录") }),
                "根目录闸门没开火 —— 「目录被改名/移走」退化成了一条泛泛的枚举错误，读它的人得自己"
                    + "去分辨是路径写错了还是磁盘出问题了。实际诊断：\(audit.findings)")
        }

        // ── 腿 1.5：扫描器**不认识**的构造，哪怕它因此让文件纳入不了，围栏也必须出声。
        //
        // 钉的是判定顺序：unmodeled 检查必须排在**纳入闸门之前**。闸门读的是 `scanned.code`，正是
        // 这条检查要验证其可信度的东西 —— 排在闸门之后，扫描器一旦吃掉那次原语调用，文件就在闸门
        // 那步静默掉队，永远走不到本该喊的检查（`guard-must-not-read-guarded-output` 那个病）。
        //
        // fixture 是**合法可编译**的 Swift：raw string 里允许裸引号，`#"a " b // "#` 中第二个 `"` 让
        // 不建模 raw string 的扫描器倒回代码模式，紧接着撞上 `//`、开出假注释、吃掉同行其余代码
        // （连同 `mutateManifestJSON()`）。
        //
        // ⚠️ 诚实标注：真正拦住这种文件的活防线是 `ViewWiringSuite.swift:199`（扫两个 target 的全局
        // unmodeled 绊线，实测：把这个 PoC 塞进 `gui/Sources`，**在本次重排之前**它就已经红了）。
        // 这条腿钉的是本围栏自己的纵深防御与判定顺序，不是补一个活着的洞。
        withTempDirectory { root in
            let scanned = root.appendingPathComponent("scanned")
            writeFixture(
                "@MainActor public func cleanWriter() { mutateManifestJSON() }",
                to: scanned.appendingPathComponent("CleanWriter.swift"))
            writeFixture(
                #"""
                public func poisonedWriter() async {
                    let note = #"a " b // "#; mutateManifestJSON()
                    _ = note
                }
                """#,
                to: scanned.appendingPathComponent("Poisoned.swift"))

            let audit = auditManifestConcurrencyFence(under: scanned)

            // 前提自钉：这个文件确实因为扫描器吃掉了原语调用而**没能纳入**（洞是真的）。
            expect(
                !audit.enrolledSubpaths.contains("Poisoned.swift"),
                "这个 fixture 没能制造出「原语调用被吃掉」的条件 —— 扫描器现在建模 raw string 了？"
                    + "那下面那条断言测的就不是它自称测的东西。实际纳入：\(audit.enrolledSubpaths)")
            // 【关键腿】纳入不了，围栏也必须出声。
            expect(
                audit.findings.contains {
                    $0.contains("Poisoned.swift") && $0.contains("不认识的构造")
                },
                "一个扫描器读不懂的文件在纳入闸门那步静默掉队了 —— unmodeled 检查排到了闸门之后，"
                    + "用被守函数的输出去决定要不要守它。把它挪到闸门之前。实际诊断：\(audit.findings)")
            expect(
                !audit.findings.contains(where: { $0.contains("CleanWriter.swift") }),
                "干净的写者被这条误伤了。实际诊断：\(audit.findings)")
        }

        // 下面两条腿靠 chmod 造「读不动」，而 root 无视 chmod —— 照本仓库既定约定跳过并出声。
        guard geteuid() != 0 else {
            print("  ⚠ skipped: running as root — chmod 挡不住 root 自己的读")
            return
        }

        // ── 腿 2：枚举得到、却读不到的 .swift 文件。
        withTempDirectory { root in
            let scanned = root.appendingPathComponent("scanned")
            writeFixture(
                "@MainActor public func topWriter() { mutateManifestJSON() }",
                to: scanned.appendingPathComponent("TopWriter.swift"))
            let locked = scanned.appendingPathComponent("Locked.swift")
            writeFixture(
                "@MainActor public func lockedWriter() { mutateManifestJSON() }", to: locked)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o000], ofItemAtPath: locked.path)
            defer {
                // 还原权限，否则 `withTempDirectory` 的 defer 清不掉这棵树，temp 里留垃圾。
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: locked.path)
            }

            let audit = auditManifestConcurrencyFence(under: scanned)

            // 先钉住 fixture 真的制造了那个条件（chmod 万一没生效，下面那条就是在测空气）。
            expect(
                !audit.enrolledSubpaths.contains("Locked.swift"),
                "chmod 000 没拦住读 —— 这条 suite 的前提不成立，下面那条断言在测空气。"
                    + "实际纳入：\(audit.enrolledSubpaths)")
            // 【关键腿】读不到 ⇒ 必须红。上一版这里是静默 `continue`。
            expect(
                audit.findings.contains(where: { $0.contains("Locked.swift") }),
                "一个读不到的 .swift 被静默跳过了 —— 围栏极性反了。它若是个 manifest 写者就完全"
                    + "不设防，而整条绊线一声不吭。实际诊断：\(audit.findings)")
            expect(
                !audit.findings.contains(where: { $0.contains("TopWriter.swift") }),
                "干净的真文件被这条误伤了。实际诊断：\(audit.findings)")
        }

        // ── 腿 3：整棵子树枚举失败（`errorHandler`）。上一版**根本没传** errorHandler。
        withTempDirectory { root in
            let scanned = root.appendingPathComponent("scanned")
            writeFixture(
                "@MainActor public func topWriter() { mutateManifestJSON() }",
                to: scanned.appendingPathComponent("TopWriter.swift"))
            let lockedDirectory = scanned.appendingPathComponent("LockedDir")
            writeFixture(
                "public func hiddenWriter() async { mutateManifestJSON() }",
                to: lockedDirectory.appendingPathComponent("HiddenWriter.swift"))
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o000], ofItemAtPath: lockedDirectory.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: lockedDirectory.path)
            }

            let audit = auditManifestConcurrencyFence(under: scanned)

            // 前提自钉：这棵子树确实进不去，里面那个**脏**写者确实漏掉了。
            expect(
                !audit.enrolledSubpaths.contains(where: { $0.contains("HiddenWriter") }),
                "chmod 000 的子目录居然被走进去了 —— 前提不成立。实际纳入：\(audit.enrolledSubpaths)")
            // 【关键腿】走不进去 ⇒ 必须红，不是静默缩小覆盖范围。
            expect(
                audit.findings.contains(where: { $0.contains("LockedDir") }),
                "一棵走不进去的子树被静默跳过了 —— 围栏在一次权限/IO 问题上悄悄缩小了覆盖范围，"
                    + "而顶层文件仍在、非空检查照样绿。落在这棵子树里的 manifest 写者完全不设防。"
                    + "实际诊断：\(audit.findings)")
            expect(
                !audit.findings.contains(where: { $0.contains("TopWriter.swift") }),
                "干净的真文件被这条误伤了。实际诊断：\(audit.findings)")
        }
    }

    // 上面那条**并发 token** 绊线自证有牙。缺了它，这条腿和 @MainActor 那条腿就不对称：
    // @MainActor 一直有合成控制（下面那条），而黑名单这条从落地起只有一次**手工**变异背书——
    // 手工变异不进 CI，判据明天静默失灵（token 拼错、`filter` 写反、`strippingComments` 把代码
    // 吃光）没有任何东西会响，真文件那条 `hits.isEmpty` 直接变成恒真绿。
    //
    // ⚠️ 脏 fixture 全部是**手写的字面量**，绝不由 `bannedConcurrencyTokens` 插值拼出来。
    // 拿清单自己去造输入，清单里写错的那一项（比如 `"asyncc"`）也会在 fixture 里原样出现、
    // 于是照样命中——那种「自证」是恒真的，正是本文件开头记着的那个病的又一次复发。
    suite("绊线（T3）并发 token 判据自证有牙：脏源码必须命中、清白必须放行、只在注释里提到不算") {
        // 正控：每一种并发写法都是独立手写的代码形状，并各自钉住**它自己那一个** token。
        //
        // （这些 fixture 只作为**文本**喂给扫描器，不参与编译，所以不要求可独立编译——形状取自
        // 真实写法即可。别把注释读成「这是能跑的代码」。）
        //
        // ⚠️ 断言是 `hits.contains(expected)`，**不是** `!hits.isEmpty`。后者太弱，会漏掉整整一类
        // 回归：`DispatchQueue.main.async { }` 这段 fixture 同时含 `DispatchQueue` **和** `async`，
        // 于是就算有人把 `DispatchQueue` 从清单里删掉，它也会靠 `async` 照样命中、照样绿 —— 那条
        // 「自证」只证明了「清单非空」，没证明「这一项还在」。逐项钉死才有每 token 的分辨力。
        //
        // `expected` 是照着 fixture 的意图**手写**的字面量，不是从 `bannedConcurrencyTokens` 取的
        // ——所以清单里某一项被写错（`"asyncc"`）时，对应 fixture 的 hits 会是空的、当场红。
        let dirtySamples: [(label: String, expected: String, source: String)] = [
            ("async 函数", "async", "@MainActor\npublic func writer() async { _ = 1 }"),
            ("Task 派发", "Task", "@MainActor\npublic func writer() { Task { _ = 1 } }"),
            (
                "DispatchQueue", "DispatchQueue",
                "@MainActor\npublic func writer() { DispatchQueue.main.async { _ = 1 } }"
            ),
            ("Thread", "Thread", "@MainActor\npublic func writer() { Thread.detachNewThread { _ = 1 } }"),
            (
                "OperationQueue", "OperationQueue",
                "@MainActor\npublic func writer() { OperationQueue.main.addOperation { } }"
            ),
            (".detached", ".detached", "@MainActor\npublic func writer() { let h = pool.detached; _ = h }"),
            (
                "withCheckedContinuation", "withCheckedContinuation",
                "@MainActor\npublic func writer() { _ = withCheckedContinuation { c in c.resume() } }"
            ),
            ("pthread", "pthread", "@MainActor\npublic func writer() { var t = pthread_t(); _ = t }"),
        ]
        for sample in dirtySamples {
            let scanned = strippingComments(sample.source)
            let hits = bannedConcurrencyHits(in: scanned)
            expect(
                hits.contains(sample.expected),
                "『\(sample.label)』这段脏源码必须命中 `\(sample.expected)` 这一项 —— 没命中 = 清单里"
                    + "这一项被删了/写错了，而真文件那条 `hits.isEmpty` 对这种并发写法就此恒真、"
                    + "整条「全同步」绊线对它是一句空话。实际命中：\(hits)，"
                    + "code：\(scanned.codeWithoutStringLiterals)")
        }

        // 配平围栏：清单里**每一个** token 都必须有一条属于自己的脏 fixture，反之亦然。
        //
        // 少了这条，上面那组逐项断言就只是一份**白名单**：明天有人往 `bannedConcurrencyTokens`
        // 里加第 9 个 token，不配 fixture 也全绿 —— 那一项拼没拼对、`strippingComments` 会不会
        // 把它吃掉，全无人验证，而它守的那种并发写法看着像「已经守住了」。认不出 ⇒ 红。
        //
        // 这条不构成自指：fixture 的 `source` 是手写的真实写法，配平只强制「每项都得有人举证」，
        // 举证本身仍由那段手写代码完成。
        expect(
            Set(dirtySamples.map(\.expected)) == Set(bannedConcurrencyTokens),
            "并发 token 清单与脏 fixture 没配平 —— 每个 token 必须有一条手写 fixture 证明它真的"
                + "会命中，否则那一项是没有任何控制的白名单条目。\n"
                + "  只在清单里、没有 fixture：\(Set(bannedConcurrencyTokens).subtracting(dirtySamples.map(\.expected)).sorted())\n"
                + "  只在 fixture 里、不在清单：\(Set(dirtySamples.map(\.expected)).subtracting(bannedConcurrencyTokens).sorted())")

        // 空集正控（对照 @MainActor 那条腿的 `exported.isEmpty`）：判据不许恒命中。
        // 恒命中 = 真文件永远假红 → 下一个人把整条绊线删掉，洞比现在更大。
        let clean = strippingComments("@MainActor\npublic func writer(x: Int) { _ = x }")
        expect(
            bannedConcurrencyHits(in: clean).isEmpty,
            "清白的同步写函数必须放行 —— 恒命中 = 真文件永远假红，绊线会被下一个人删掉。"
                + "得到命中：\(bannedConcurrencyHits(in: clean))")

        // 剥注释这一步必须真的发生：`ManifestBinding.swift` 的 doc comment 里白纸黑字写着
        // 「一条禁 async/Task/DispatchQueue」（它在描述这条绊线本身）。不剥注释，真文件当场假红。
        // 这条把「真文件今天为什么是绿的」钉成断言，而不是一个碰巧。
        let commentOnly = strippingComments(
            "/// 这条绊线禁 async / Task / DispatchQueue。\n@MainActor\npublic func writer() { _ = 1 }")
        expect(
            bannedConcurrencyHits(in: commentOnly).isEmpty,
            "只在注释里**谈论** async/Task/DispatchQueue 不算并发代码 —— 判成命中 = 真文件因为"
                + "自己的 doc comment 假红。得到命中：\(bannedConcurrencyHits(in: commentOnly))"
                + "，code：\(commentOnly.code)")
    }

    // 上面那条 @MainActor 绊线自证有牙：@MainActor 缺失 / 存在 / 挂在**别的**函数上，三种情形
    // `hasMainActorIsolation` 都要分辨对。少了这条合成控制，`hasMainActorIsolation` 一旦恒真（比如
    // 正则写错、恒返回 non-nil），真文件那条 for 循环永远不进 body，整条绊线就是一句恒真绿。
    suite("绊线（T3）@MainActor 检查自证有牙：缺失→未隔离、存在→已隔离、隔壁函数的不算数") {
        let missing = strippingComments("public func writerWithout(x: Int) { _ = x }")
        expect(
            exportedPublicFuncNames(in: missing.code) == ["writerWithout"],
            "枚举器必须逮到这个 public func。得到：\(exportedPublicFuncNames(in: missing.code))")
        expect(
            !hasMainActorIsolation(funcName: "writerWithout", in: missing.code),
            "没有 @MainActor 的 public func 必须被判为『未隔离』—— 判成 true = 真文件那条 for 循环"
                + "永远不进 body，整条 @MainActor 绊线恒真。得到 code：\(missing.code)")

        let present = strippingComments("@MainActor\npublic func writerWith(x: Int) { _ = x }")
        expect(
            hasMainActorIsolation(funcName: "writerWith", in: present.code),
            "带 @MainActor 的 public func 必须被判为『已隔离』—— 判成 false = 真文件永远假红，"
                + "然后被下一个人删掉。得到 code：\(present.code)")

        // `public static func` / `public final func` —— 红队实测逃过旧版枚举器的那两个形态
        // （旧版只逐字捞 `public func `，一个不带 @MainActor 的 `public static func` 写者塞进
        // ManifestBinding.swift，2099 条断言全绿）。枚举器必须捞到它们，隔离检查必须两侧对齐。
        let staticNaked = strippingComments("public static func staticWriter() { _ = 1 }")
        expect(
            exportedPublicFuncNames(in: staticNaked.code) == ["staticWriter"],
            "`public static func` 必须被枚举到 —— 捞不到 = 这个形状的写者对整条 @MainActor 腿隐身，"
                + "而它正是「同步但脱离主 actor」那个 critical gap 的确切形状。"
                + "得到：\(exportedPublicFuncNames(in: staticNaked.code))")
        expect(
            !hasMainActorIsolation(funcName: "staticWriter", in: staticNaked.code),
            "没有 @MainActor 的 `public static func` 必须判为『未隔离』。得到 code：\(staticNaked.code)")

        let staticIsolated = strippingComments(
            "@MainActor\npublic static func staticSafe() { _ = 1 }")
        expect(
            hasMainActorIsolation(funcName: "staticSafe", in: staticIsolated.code),
            "带 @MainActor 的 `public static func` 必须判为『已隔离』—— 判成 false = 每一个 static "
                + "写者都假红，绊线会被下一个人删掉。得到 code：\(staticIsolated.code)")

        let finalIsolated = strippingComments(
            "@MainActor\npublic final func finalSafe() { _ = 1 }")
        expect(
            exportedPublicFuncNames(in: finalIsolated.code) == ["finalSafe"]
                && hasMainActorIsolation(funcName: "finalSafe", in: finalIsolated.code),
            "`public final func` 两侧都得认。得到：\(exportedPublicFuncNames(in: finalIsolated.code))")

        // 反向：`public` 与 `func` 之间**隔着一个声明**（含标点）时绝不能误配。
        // 误配 = 一个非 public 的 func 被当成导出写者，绊线开始对私有实现细节假红。
        let notExported = strippingComments("public struct Box { func hidden() { _ = 1 } }")
        expect(
            exportedPublicFuncNames(in: notExported.code).isEmpty,
            "`public struct` 之后的**非 public** func 不许被算成导出写函数 —— `{` 是标点，修饰符 run "
                + "跨不过去。误算 = 绊线对私有实现假红。得到：\(exportedPublicFuncNames(in: notExported.code))")

        // 关键反例：@MainActor 挂在**上一个**函数上，中间隔着一个含 `{}` 的函数体，绝不能被算到
        // 下一个裸函数头上。误算 = 少写 @MainActor 的写函数从这个缝里溜过绊线。
        let crossTalk = strippingComments(
            "@MainActor\npublic func isolated() {}\npublic func naked() {}")
        expect(
            hasMainActorIsolation(funcName: "isolated", in: crossTalk.code),
            "`isolated` 自己带 @MainActor，必须判为已隔离。得到 code：\(crossTalk.code)")
        expect(
            !hasMainActorIsolation(funcName: "naked", in: crossTalk.code),
            "`naked` 自己没有 @MainActor —— 前一个函数的 @MainActor 隔着一个函数体（含 `{}`），不许"
                + "被算到它头上。误算 = 少写 @MainActor 的写函数溜过绊线。得到 code：\(crossTalk.code)")
    }
}
