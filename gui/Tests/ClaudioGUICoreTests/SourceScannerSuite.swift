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
// **「围栏」这个词只对得起其中一层，别读成整条都是。** 摊开说：
//
// · **枚举那一层是围栏**（认不出 ⇒ 红）：symlink、读不到、属性读不到、类型判不出、子树枚举出错、
//   根目录不在 —— 六处全部 fail-closed，各自有自证（见下面四条「围栏极性自证有牙」）。
// · **两条判定腿是探针，不是围栏**：@MainActor 腿只查正则认得出的 `public func`；并发腿只扫「含原语
//   名的那一个文件」里的 8 个已知 token。两条都是白名单，而白名单永远漏得掉下一个形状。
//
// 这不是假设，是两条**实测可编译**的逃逸（`/codex review 36fce57` 的 P1 之一、之二，已立项在
// `TODOS.md`「T3 内容围栏的两条判定腿仍是白名单探针」）：
//  ① 在 `ManifestBinding.swift` 里加一个**非 public** 的写原语 —— 文件照样被纳入，但 @MainActor 腿
//     只遍历**导出**的那几个，它一条断言都碰不到。`public extension` 里的成员同样逃逸。
//  ② 把 `Task.detached` 挪进**另一个不含原语名的文件** —— 那个文件根本不被纳入，而调用它的这个文件
//     里一个黑名单 token 都没有（`await` 不在清单里）。
//
// 所以这条东西诚实的名字是「**内容推导的纳入 + 两条已知形态的判定**」。`bannedConcurrencyTokens` 头上
// 那段一直是这么写的，而 suite 名和几轮 commit headline 一直叫它「内容围栏」—— 措辞比覆盖范围大，
// memory 里 `fence-polarity-and-self-recurrence` 那条的第八次应验，照例复发在「自称把探针升成围栏」
// 的那一刀上。改这个文件的人：先读这一段，再决定你要不要相信它挡得住你正在写的东西。
//
// **另一条仍然诚实的限度**：自证覆盖的是这个函数**里面**。消费边（把 findings 变成红）已经下沉进
// `enforceManifestConcurrencyFence` 并有端到端自证 + 接线自证（`36fce57` 的 P1 之三），但「有人另写一个
// 阉割过的入口并改接线」这类改法，最终仍然靠 code review 兜。别把这段注释写成绝对的。

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

/// 一个目录条目的**类型判定**结果。两个字段都是 `Bool?`，而 `nil` 一律读作**「判不出」**，
/// 绝不读作「不是」—— 围栏极性在这两个 optional 的解包处，不在注释里。
private struct EntryKind {
    let isSymbolicLink: Bool?
    let isRegularFile: Bool?
}

/// 读一个 URL 的类型属性。返回 `nil` = **这次读取本身失败了**（区别于「读到了但值是 nil」）。
///
/// ## 为什么这是个可注入的 seam，而不是直接内联 `try?`
/// `/codex review 36fce57` 的 P1 之四：上一版这里是一句裸 `try?`，失败落进 `values?.isSymbolicLink
/// == true` 的 `false` 分支，接着被 `guard url.pathExtension == "swift"` 静默 `continue` 掉 ——
/// 一个**没有后缀的目录 symlink** 只要属性读不到，就从三道闸门底下一路穿过去。fail-open，极性反了。
///
/// 但把它翻成 fail-closed 之后立刻撞上第二个问题：**这条分支没有任何输入能喂到它。** 实测
/// （scratchpad/probe2.swift，四种造法）：`FileManager.enumerator(at:includingPropertiesForKeys:)`
/// 会**预取**这两个键，于是枚举循环里这次 `resourceValues` 命中的是缓存 —— 枚举中途把文件删掉、
/// 把父目录 chmod 000、dangling symlink、自指 symlink，**四种全部返回 OK**，一次都逼不出失败。
/// （脱离枚举器直接读则确实会抛：删掉的文件 NSCocoa 260、000 目录里的文件 257。所以这不是一条
/// 假想的错误码，只是被枚举器的缓存挡住了。）
///
/// 所以走注入：真围栏用 ``realEntryKind``，自证注入一个失败版本，把这两条 fail-closed 分支的
/// **极性**钉成会响的断言。⚠️ 这条 seam 举证的是**分支极性**，不是端到端 —— 别把它读成
/// 「真枚举里这条路走过了」。真枚举里它（今天）走不到，这正是它需要注入才能被验证的原因。
private typealias EntryKindReader = (URL) -> EntryKind?

/// 枚举器**预取**的键，与 ``realEntryKind`` 读的键 —— **必须是同一份**，所以只有这一份。
///
/// ⚠️ 两处若各写各的会**静默漂移**出一个假红：枚举器预取 A，读取器要 B，那次读就不是命中缓存而是
/// 一次真 stat，权限/竞态下会抛 —— 于是围栏对一个完全正常的文件报「类型属性读不到」。
/// 本文件里 `exportedPublicFuncNames` / `hasMainActorIsolation` 两侧对齐那条注释记的是同一个道理：
/// 分成两份，漂移的那一半是没有人在看的那一半。
private let fenceResourceKeys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]

private func realEntryKind(_ url: URL) -> EntryKind? {
    guard let values = try? url.resourceValues(forKeys: Set(fenceResourceKeys))
    else { return nil }
    return EntryKind(isSymbolicLink: values.isSymbolicLink, isRegularFile: values.isRegularFile)
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
/// ## 五处 fail-closed（`/codex review 15ce131` 的 P1 之三、`36fce57` 的 P1 之四）
/// 这几处一开始全是 fail-**open**，即「出问题 ⇒ 静默排除 ⇒ 更绿」，与围栏极性正好相反：
/// 1. `errorHandler:` —— 上一版**没传**。某棵子树枚举失败（权限/IO）会被静默跳过，而顶层
///    `ManifestBinding.swift` 仍在 ⇒ 非空检查和具名钉子照样绿，嵌套写者无声无息地漏掉。
/// 2. `isRegularFile` —— 上一版是 `(try? …) ?? false`，即**判不出类型的 `.swift` 条目被排除**。
///    「我判不出它是什么」绝不等于「它不是源文件」。现在判不出 ⇒ 记一条 finding。
/// 3. `enumerator == nil` —— 上一版 `?? []` 吞掉。真围栏那侧靠 `!enumeratedSubpaths.isEmpty`
///    接得住，但这个函数自己也得说话，否则自证喂它一棵坏树时读到的是「干净」。
/// 4. **属性读取本身失败**（`36fce57` P1）—— 上一版一句裸 `try?`，失败之后 `values?.isSymbolicLink
///    == true` 走 `false` 分支，紧接着被 `.swift` 后缀闸门静默 `continue`。于是一个**没有后缀的
///    目录 symlink** 只要属性读不到就整条穿过去。现在读不到 ⇒ 记一条 finding，**且排在后缀闸门
///    之前**（没有后缀的目录 symlink 正是要接住的那一种）。
/// 5. **`isSymbolicLink` 判不出**（同上）—— `== true` 把 `nil` 悄悄归进「不是 symlink」。同 2，
///    「判不出」不是「不是」。现在也排在后缀闸门之前。
///
/// 4 与 5 的举证靠 ``EntryKindReader`` 注入（真枚举器预取属性，实测四种造法都逼不出失败 ——
/// 详见那个 typealias 头上那段）。1/2/3 的举证见「围栏极性自证有牙」两条 suite。
///
/// ## symlink（同一轮 P1）
/// `FileManager.DirectoryEnumerator` **不下钻**指向目录的 symlink，而 SwiftPM 会跟随它发现源码 ——
/// 一个 `ClaudioGUICore/Feature -> ../elsewhere` 的目录链接，里面的写者会被编译、却漏出围栏。
/// 走廉价且正确的那条：**遇到任何 symlink 一律记 finding**（认不出 ⇒ 红）。今天 `gui/Sources` 底下
/// 一个 symlink 都没有（`find gui/Sources -type l` 为空），所以这条不会制造噪音；真有人加了一个，
/// 他会拿到一条写明该怎么办的红，而不是一片沉默的绿。
private func auditManifestConcurrencyFence(
    under root: URL,
    pathPrefix: String = "",
    readEntryKind: EntryKindReader = realEntryKind
) -> ManifestFenceAudit {
    var audit = ManifestFenceAudit()
    let basePath = root.standardizedFileURL.path
    // 与 ``realEntryKind`` 读的键同一份 —— 见 `fenceResourceKeys` 头上那段（两份会漂移出假红）。
    let resourceKeys = fenceResourceKeys

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

        // ⚠️ 下面三道**全部排在 `.swift` 后缀闸门之前**，顺序不是随便写的（`/codex review 36fce57`
        // 的 P1 之四）。后缀闸门是个 `continue`：任何在它之前没能定案的东西，到了它那里都会被
        // **静默丢掉**。而这一族里最要命的输入 —— 一个**没有后缀的目录 symlink** —— 恰好过不了
        // 后缀闸门。所以「判不出」必须在闸门之前就变成 finding，否则极性当场翻回 fail-open。
        guard let kind = readEntryKind(url) else {
            audit.findings.append(
                "\(display(subpath(of: url))) 的类型属性读不到（`resourceValues` 抛错）—— 围栏对它"
                    + "**无从判起**：它可能是个目录 symlink（SwiftPM 会跟进去编译里面的写者），也可能"
                    + "是个源文件。判不出就不许放行。别让围栏在一次权限/IO 问题上静默丢掉一个条目。")
            continue
        }

        // symlink：枚举器不下钻，SwiftPM 会跟随 —— 认不出 ⇒ 红（见上面 doc comment）。
        // 这条**先于** `.swift` 后缀判断：一个 symlink **目录**没有后缀，但它里面全是源文件。
        //
        // ⚠️ 解包写成 `guard let` 而不是 `== true`。`== true` 会把 `nil`（判不出）悄悄归进
        // 「不是 symlink」那一侧，接着被后缀闸门丢掉 —— 与上一条同一个病，同一个 fail-open。
        guard let isSymbolicLink = kind.isSymbolicLink else {
            audit.findings.append(
                "\(display(subpath(of: url))) 判不出是不是 symlink（属性读到了但这一项是 nil）—— "
                    + "围栏对它无从判起。它若是个指向别处的**目录** symlink，落在链接目标里的 manifest "
                    + "写者会被 SwiftPM 编译、却完全漏出这条围栏。别把「我判不出」当成「它不是」。")
            continue
        }
        if isSymbolicLink {
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
        // ⚠️ 诚实标注（`36fce57` 之后已改）：**真实文件系统**里逼不出这个 nil —— chmod 000 的文件
        // `isRegularFile` 照样读得到（值为 true），dangling symlink 会先被上面那条 symlink 闸门接走。
        // 所以它的举证走 ``EntryKindReader`` 注入（「围栏极性自证有牙之三」那条 suite），钉的是
        // **分支极性**：把它改回 `?? false`，那条 suite 当场红。这已经不是上一稿那个「无输入可喂、
        // 台账必然存活」的状态了 —— 但也别把它读成「真枚举里走过这条路」，真枚举里它走不到。
        guard let isRegularFile = kind.isRegularFile else {
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
        //
        // ⚠️ 这条诊断**不回显源码**（`/codex review 36fce57` 的 P2）。上一稿末尾挂着
        // `得到的代码：\(scanned.code)` —— 两个毛病，第二个才是真的：
        //  · 一份大文件整段抄进失败输出，日志爆量。
        //  · **回显是自证的污染源。** 源码里本来就有 `async` / `Task` 这些词，于是一条按「诊断里
        //    出现 Task」写的断言会被**回显**满足而不是被**判据**满足。台账第四轮实测：「只报第一个
        //    命中」这个变异靠那段回显照样全绿。姊妹腿（@MainActor）早就为同一个理由掐掉了回显。
        // 两道都留着：既掐掉回显，命中清单也用**专有措辞 + 逐字拼接**（`命中 token：a, b`），不是
        // 数组的 `\(…)` 默认描述 —— 断言钉的是判据的输出，任何一道单独失手都还有另一道。
        let concurrencyHits = bannedConcurrencyHits(in: scanned)
        if !concurrencyHits.isEmpty {
            audit.findings.append(
                "\(display(relative)) 的代码里出现了并发构造，命中 token："
                    + "\(concurrencyHits.joined(separator: ", ")) —— manifest.json 的读-改-写"
                    + "现在整段跑在 `~/.claudio/packs.lock` 里（`mutateManifestJSON(at:lockFile:_:)`），"
                    + "而这条腿守的是**那把锁的作用域**：`Task.detached { … write … }` / 改成 async 并在"
                    + "读与写之间插一个 `await` —— 两者都把真正的写**挪到锁释放之后**，锁当场形同虚设，"
                    + "而编译器一条诊断都不会给（`Data`/`URL` 都是 Sendable，`Data.write` 是 nonisolated；"
                    + "本轮实测：注入 `Task.detached` 包住那次 write，两个包都 Build complete、零警告）。"
                    + "锁与这条绊线不互相替代。")
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
        // 第三条腿（`/codex review 48cbc07` 的 P1 之一）：上面那条只在**一个都没枚举到**时开火，
        // 挡不住「文件里已经有正常的 public func，再混进一个识别器不认得的声明」。那种声明既不进
        // 下面的 @MainActor 检查、也不触发上面的 `exported.isEmpty` —— 认不出反而是绿的。这条把
        // 差额变成红：`func` 声明总数 ≠ 两台识别器认出来的数之和 ⇒ 有漏网的。
        //
        // ⚠️ 措辞必须与另外两条腿**不共享任何子串**。上一轮红队逮到的正是这种串味：一条 finding
        // 里回显了函数名，就把「@MainActor 腿必须对 deepWriter 开火」那条按「路径 + 函数名」匹配的
        // 断言给满足了，@MainActor 整条腿掐死也全绿。所以这条钉的是「声明形态不在识别清单里」，
        // 与「一个 `public func` 都没枚举到」「没有 @MainActor 隔离」逐字不相交。
        // 第三条腿之零：**标尺自己有没有漏数**。`func` 关键字数 ≠ 解析得出名字的声明数 ⇒ 有声明
        // 连名字都解析不出来（反引号转义标识符、运算符声明），三边同时看不见 ⇒ 差额恒为 0 ⇒ 下面
        // 那条会静默全绿。见 `funcKeywordCount(in:)` 头上那段（红队实测两条 fatal）。
        let keywordCount = funcKeywordCount(in: scanned.codeWithoutStringLiterals)
        let namedCount = allFuncDeclarationNames(in: scanned.codeWithoutStringLiterals).count
        if keywordCount < namedCount {
            // 负差额：**标尺自己数少了**。正确代码下不可达（名字解析每命中一次，那个位置上必然
            // 也有一次关键字命中 —— 两者现在共用 `funcKeywordLexeme`），所以这是一条**无 fixture
            // 的 fail-closed 兜底**，与 `enumerator == nil` 那条同类。但它**不是**纸面兜底：词素
            // 一旦漂移（有人给其中一台单独加限定），台账 M3-2 会经由它变红。
            //
            // 单独成腿的理由不只是诊断精度：负差额会去**抵消**一个真实漏网声明的正差额，把下面
            // 那条判定静默归零（`funcKeywordLexeme` 头上那段实测的 −1 / +1 抵消）。而上一版只有
            // 一条 `!=`，它在这种输入上印出的是「差的 **-1** 个声明连名字都认不出来」——一句字面
            // 为假的诊断，会把读日志的人指向完全错误的方向。
            audit.findings.append(
                "\(display(relative)) 里只数到 \(keywordCount) 个 `func` 关键字，却解析出 "
                    + "\(namedCount) 个函数名 —— **标尺自己数少了**。关键字词素比名字解析那一台更窄，"
                    + "两处对 `func` 的定义已经漂移。这个负差额会去**抵消**一个真实漏网声明的正差额，"
                    + "让「认不出的声明」那条判定静默归零。两处必须共用 `funcKeywordLexeme` 那一份词素。")
        } else if keywordCount != namedCount {
            audit.findings.append(
                "\(display(relative)) 里有 \(keywordCount) 个 `func` 关键字，但只解析得出 "
                    + "\(namedCount) 个函数名 —— 差的 \(keywordCount - namedCount) 个声明**连名字都"
                    + "认不出来**（反引号转义标识符 `func \\`default\\`()`、运算符声明 "
                    + "`func == (…)`，都是可编译的真代码）。名字解析不出来 ⇒ 它同时躲开导出枚举、"
                    + "文件内私有枚举、和「认不出的声明」那条差额判定，三边一起失明而差额恒为 0。"
                    + "围栏极性是「认不出 ⇒ 红」：这条报不出是谁，请自己 grep 本文件的 `func`，"
                    + "把那个声明改成普通标识符命名的 `public func` 并标 `@MainActor`。")
        }
        for name in unrecognizedFuncDeclarations(in: scanned) {
            audit.findings.append(
                "\(display(relative)) 里的 `\(name)` 声明形态不在识别清单里 —— 枚举器是**词法**的，"
                    + "只看紧贴 `func` 前面那一段修饰符 run，认得两类：`public` 打头（导出，逐个查"
                    + "隔离）和 `private` / `fileprivate` 打头（出不了本文件）。落到这里的形状（每一"
                    + "种都有 fixture 钉着）：不写修饰符的隐式 `internal`、`package`、`open`、"
                    + "`public extension` 里省略修饰符的成员、`private` / `fileprivate extension` 里"
                    + "省略修饰符的成员、`private struct` / `enum` / `final class` / `actor` 的无修饰符"
                    + "成员、以及函数体内的**局部 func**。"
                    + "围栏极性是「认不出 ⇒ 红」：认不出的声明不许静默跳过，因为 internal / package 的"
                    + "写者照样能被模块内任意后台线程同步调用，而它不在下面那条逐个查隔离的名单里。\n"
                    + "  怎么修：把修饰符写在**成员自己头上**（`private func \(name)()`），别只写在外层的 "
                    + "`extension` / 类型上 —— 词法识别器跨不过那个 `{`。真要导出，就补 `public` 并标 "
                    + "`@MainActor`（PLAN-SOUND-MANAGER.md §2.1）。\n"
                    + "  ⚠️ 别改成「认外层作用域」来消这条红：那需要一台括号匹配器，而红队实测一个裸 "
                    + "regex 字面量（`strippingComments` 不记 unmodeled、它自身括号配平）就能把匹配器"
                    + "带偏、吞掉整块 `public extension` 里的非 @MainActor 写者。要动，先给「括号嵌套」"
                    + "这根读模型轴造一条正向对照。")
        }
        for gap in missingMainActorIsolation(in: scanned) {
            audit.findings.append(
                "\(display(relative)) 的导出写函数 `\(gap.name)` 没有 @MainActor 隔离"
                    + "（导出 \(gap.exported) 个声明，带 @MainActor 的只有 \(gap.isolated) 个）—— "
                    + "manifest.json 的跨进程互斥已经交给 `~/.claudio/packs.lock`，而 @MainActor 守的是"
                    + "**进程内**那一半：少了它（或被标 nonisolated、或被一个同名重载洗白），这个写者就能"
                    + "被后台线程同步调用。删掉 `@MainActor` 是一次**放宽** —— 现存调用方本身都在主 actor "
                    + "上，放宽后调用依然合法，**编译器零诊断**（本轮实测：删掉原语的 @MainActor，"
                    + "`swift build` 直接 Build complete）。编译器强制的是注解的*后果*，从不是注解的*存在*，"
                    + "所以这条绊线是它唯一的守卫。给它加回 @MainActor"
                    + "（PLAN-SOUND-MANAGER.md §2.1 / 4c「并发不变式」）。")
        }
    }

    audit.enumeratedSubpaths.sort()
    audit.enrolledSubpaths.sort()
    return audit
}

/// 跑一次围栏，**并且把每一条 finding 变成一次红**。返回审计产物供调用方再做覆盖范围断言。
///
/// ## 为什么消费边必须在这个函数里，而不在调用点（`/codex review 36fce57` 的 P1 之三）
/// 上一版把消费留在调用点：
///
/// ```swift
/// let audit = auditManifestConcurrencyFence(under: scanRootURL, pathPrefix: …)
/// for finding in audit.findings { expect(false, finding) }        // ← 就是这里
/// ```
///
/// Codex 打的正是这一行：把它改成 `audit.findings.filter { _ in false }`，真围栏从此**不消费任何
/// finding** —— 枚举断言、覆盖范围断言、具名钉子、以及所有「自证有牙」的 suite **全部照绿**，因为
/// 那些 suite 直接调 `auditManifestConcurrencyFence`、从来不经过这条消费边。围栏静默失效，零告警。
///
/// 这是 `15ce131` 那个病的**同构复发**，只不过退了一层：上一轮把「枚举」下沉进函数、调用点只剩
/// 一行 `audit(under:)`，但那一行的**返回值还得有人消费**，于是可被改的东西从「枚举」变成了「消费」。
/// 抽取一层，接缝就往外挪一层 —— 只要调用点还剩一段**有语义的**代码，它就是下一个被改的地方。
///
/// 所以这一版把消费也吞进来，调用点退化成一句**没有任何可改语义**的调用。而这个函数自己的牙由
/// 「消费边自证有牙」那条 suite 钉住：它喂一棵必然产出 finding 的树、走**这个函数**、观测全局
/// `failures` 计数真的涨了 `findings.count` 那么多，然后把这几条**故意的**失败从计数里撤回。
/// 那是端到端的 —— 走的是生产同一个函数、用的是生产同一个 `expect`。
///
/// ⚠️ **仍然诚实的限度**：有人把调用点改回直接调 `auditManifestConcurrencyFence`、自己写一个
/// 阉割过的循环，这个函数拦不住。拦那一手的是「消费边接线自证」那条 suite（读本文件源码，钉死
/// 生产调用点那两行哨兵之间的内容**逐字全等**于预期的那一句调用）。两条合起来才是完整的。
///
/// ⚠️ 上一稿这里写的是「+ `expect(false, finding)` 全文件**只出现一次**」—— 那是第一版的设计，
/// 后来那条计数断言被删掉了（改成了哨兵区块全等），而这句散文留在了原地。**红队实测逮到的正是它**：
/// 一句描述着不存在的断言的注释。措辞比覆盖范围大，同一轮里第二次，长在自己的修复上。
@MainActor
private func enforceManifestConcurrencyFence(
    under root: URL,
    pathPrefix: String = "",
    readEntryKind: EntryKindReader = realEntryKind
) -> ManifestFenceAudit {
    let audit = auditManifestConcurrencyFence(
        under: root, pathPrefix: pathPrefix, readEntryKind: readEntryKind)
    // 一条 finding = 一次红。违规（并发 token / 缺 @MainActor / 扫描器不认识的构造）与**无从判定**
    // （symlink / 判不出类型 / 属性读不到 / 读不到文件 / 子树枚举出错）都在里面 —— 围栏极性是
    // 「认不出 ⇒ 红」，两类同等对待。
    for finding in audit.findings {
        expect(false, finding)
    }
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

// MARK: - T3 围栏生产调用点的哨兵（`/codex review 36fce57` 的 P1 之三）
//
// 「消费边接线自证」那条 suite 靠这两行把**生产调用点那一段**抽出来单独喂扫描器。
// 为什么不是整份文件：本文件前半段是扫描器自己的回归网，必然大量使用 raw string，而扫描器不建模
// 它 —— 整份文件的 `unmodeledConstructs` 永远非空，那条前提**不可满足**（第一版就是这么写的，实测
// 当场红）。抽一段就没这个问题，而且那一段里再出现 raw string 会被同一条断言当场逮住。
//
// ⚠️ 同 `scannerRegionBegin` 那对：按**整行精确匹配**，不是 `contains` —— 上面这段散文里就提到过
// 这两个 token，`contains` 会把散文当成哨兵、抽出几行注释就收工，而剥完注释是空串，下面那条
// 「非空白字符 > 40」会当场逮住它（那是那条断言存在的理由）。
private let fenceCallSiteBegin = "// claudio:manifest-fence-callsite:begin"
private let fenceCallSiteEnd = "// claudio:manifest-fence-callsite:end"

/// 围栏的扫描根（相对仓库根），与生产传给 `pathPrefix` 的那个串。**只有这一份。**
///
/// ⚠️ 消费边自证必须能喂出与生产**逐字相同**的 `pathPrefix`，所以这两个常量不能留在生产 suite 的
/// 局部作用域里。红队实测的那条逃逸就长在这根轴上：消费循环写成
/// `for finding in audit.findings where pathPrefix.isEmpty { … }` —— 自证走默认实参（空串）照样全红、
/// 四条断言全过，而生产传的是 `"gui/Sources/"`，消费边**在生产路径上被永久关掉**，
/// **生产调用点一个字符都不用改**，`git diff` 只显示函数体里多了个 `where`。
///
/// 教训（第三轮同构复发）：自证喂的必须是**同一条生产路径**上的**同一个实参向量**，不只是同一个
/// 函数。「函数有牙」只在它被举证过的那个向量上成立；任何「在自证向量下为真、在生产向量下为假」的
/// 谓词都能寄生在消费循环里。所以下面那条 suite 对**每一个**向量各跑一遍。
private let fenceScanRelativeRoot = "gui/Sources"
private let fencePathPrefix = "\(fenceScanRelativeRoot)/"

/// 形状表的**覆盖锁**（`/codex review ae494b1` 红队 confirmed 那条）。
///
/// ## 它治的病
/// 下面那条判定 suite 里有三张「形状表」：一个字面量元组数组 + 一个 `for`，每行钉一种被诊断串
/// **逐字列出**的声明形态。它们与 `fenceProofVectors` 是**同一台机器**：删掉任意一行，只是少跑两次
/// `expect`，总检查数从 2243 掉到 2241，**全绿零红** —— 而生产诊断串照旧逐字声称那个形状「每一种都有
/// fixture 钉着」。这正是本文件治了十一次的「措辞比覆盖范围大」，而 `ae494b1` 那一轮就是这么丢掉
/// `private enum` / `final class` / `actor` 三行的（当时只有 `private struct` 有 fixture）。
///
/// ## 为什么是「成员锁」不是 `count == N`
/// 第一版给 `fenceProofVectors` 写的是 `count == 2`，红队打掉了：`count == N` 唯一独占的触发面是
/// 表**变长**，而那是覆盖**改进**不是缺陷，且开火时印的诊断字面为假（说「少了 X」而 X 明明在）。
/// 拿到一条说自己没做的事的红，最省力的修法是删掉整条 expect —— 连真正承重的那半一起陪葬。
/// 所以这里只断言**必须覆盖**的那些键在表里，加行不受限制。
///
/// ## 诚实的限度（**不要**把它读成「表与诊断已同源」）
/// 它逮的是**单向**的：表里少了一行 ⇒ 红。它**逮不到**反向 —— 诊断串长出第五种形状而没人加行，
/// `mustCover` 与表两处一起停在旧的四种，照样全绿。要闭掉那一侧，得把表与诊断串做成同源
/// （诊断句子由表生成），见 TODOS「T3 形状表与诊断串未同源」。
/// 另：`mustCover` 与表本身是**两处字面量**，一起砍掉仍然能全绿 —— 它把「悄悄删一行」变成了
/// 「必须动两个地方」，是抬高门槛，不是证明。别把「抬高门槛」写成「锁死」。
@MainActor
private func expectShapeTableCovers(
    _ tableName: String, rows: [String], mustCover: [String], vectorLabel: String
) {
    for required in mustCover {
        expect(
            rows.contains(required),
            "【向量：\(vectorLabel)】形状表「\(tableName)」少了 `\(required)` 这一行（实得 \(rows)）—— "
                + "生产诊断串**逐字列出**了这个形状并声称「每一种都有 fixture 钉着」，表里却没有它。"
                + "**在这把锁存在之前**，删一行不会有任何断言变红（只是少跑几次 `expect`），措辞"
                + "就此比覆盖范围大 —— "
                + "`ae494b1` 那一轮丢掉三种私有形状走的正是这条路。要去掉一个形状，先去掉诊断串里"
                + "对它的措辞。")
    }
}

/// 一行形状表所声称的**声明形态**，写成可执行的判别式。三段合取，各钉一根轴：
///
/// · `declarator` —— fixture 里必须有**一行**，剥掉行首空白之后以它打头。
/// · `indented` —— 那一行该不该带行首缩进。**别把它读成排版偏好**：⑦⑧⑧b 的
///   `ImplicitInternal`（顶格 `func `）与 ⑧b 的 `PublicExtension`（缩进 `func `）判别词逐字相同，
///   把它们分开的**只有**这一位。台账实测：把 `shapeWitnessLine` 里这一段判定拿掉 ⇒ 红 2 条，
///   开火的正是 ⑦⑧⑧b 那一对。
///   ⚠️ 上一稿这段散文写的是「⑰ 的 `LocalNestedFunc` 与 ⑩ 的 `Operator` 全靠它跟同表其他行分开」，
///   **是假的，而且我自己的台账在写下这句之前就已经证伪了它**（那一轮红的是 ⑦⑧⑧b，不是这两行）：
///   这两行的判别词（`public static func == ` / 配合 `enclosedBy`）本就与同表兄弟不同形，
///   `indented` 在它们身上不承重。措辞按实测写，不按看着顺的写。
/// · `enclosedBy` —— 见证行**上方最近一条非空行**必须以它打头；`nil` = 不约束外层。
///   它治的是 `/codex review b0ce657` 红队那条 P1：`declarator` + `indented` 只约束**那一行自己**，
///   完全不管它嵌在什么里。⑰ 第 13 行声称的形状是「函数体内的局部 func」，而在它之前，把 fixture
///   改成 `public extension LNBatch { func lnInner() … }` —— 依然是一条缩进的 `func `、文件名与成员名
///   一字不改、生产诊断照旧报同一句（`public extension` 成员走的是同构路径）—— **2325 全绿**，
///   而「函数体内的局部 func」这根轴已经没了。这正是 b0ce657 那条 P1 在第 13 行原样存活。
///   ⚠️ 这里**不给默认值**：11 行写 `nil`、2 行写值，是为了让「不约束外层」是一个写下来的决定，
///   而不是一次省略。默认实参就是可改语义 —— 有人改掉默认值，11 行的语义会一起变而没有任何断言喊。
private struct ShapeWitness {
    let declarator: String
    let indented: Bool
    let enclosedBy: String?
}

/// `source` 里第一条满足 `witness` **三段合取**的行；没有 ⇒ `nil`（调用方当红处理）。
private func shapeWitnessLine(_ witness: ShapeWitness, in source: String) -> String? {
    let lines = source.components(separatedBy: "\n")
    for (index, line) in lines.enumerated() {
        let body = line.drop { $0 == " " || $0 == "\t" }
        guard body.hasPrefix(witness.declarator) else { continue }
        guard (body.count != line.count) == witness.indented else { continue }
        guard let enclosedBy = witness.enclosedBy else { return line }
        // 外层：上方最近一条**非空**行。用「最近非空」而不是「上一行」，是为了不被一行空行掀翻；
        // 用 `hasPrefix` 而不是全等，是因为外层声明行尾部还挂着 `{`、泛型参数、`: Equatable` 之类。
        guard
            let above = lines[..<index].last(where: {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }),
            above.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix(enclosedBy)
        else { continue }
        return line
    }
    return nil
}

/// 形状表的**见证锁**（`/codex review b0ce657` 那条 P1）。
///
/// ## 它治的病（覆盖锁治不到的那一半）
/// 上面那把覆盖锁锁的是**行还在不在**，而每一行的 `shape` / `modifier` 列是**纯散文**：锁读
/// `.map(\.0)`（fixture 文件名），循环体里的 `expect` 读文件名 + 成员名 + 一句诊断措辞 —— 唯一
/// 承载「这一行到底是哪种声明形态」的那一列，谁都不读。真正的形状写在几十行外 `writeFixture` 的
/// 字符串字面量里，两边没有任何东西接着。
///
/// 实测（`/codex review b0ce657` P1，两发都打过）：
///   · `PrivateEnum.swift` 的内容 `private enum` → `private struct`，文件名 / 成员名一字不改
///     ⇒ **2269 全绿零红**，而 `private enum` 这个形状已经从 fixture 集里彻底消失。
///   · `OpenWriter.swift` 的 `open func` → `package func` ⇒ 同样 **2269 全绿零红**。
/// 也就是说：覆盖锁把「悄悄删一行」抬成了「必须动两处」，但「留着行、把形状换掉」这条路一步都
/// 没抬高 —— 而后者正是让 `mustCover` 那几个键**逐个变成谎**的最省力走法。`ae494b1` 丢的是三行，
/// 这个洞丢的是三行背后的东西：同一个病往下走了一层。
///
/// ## 为什么读**磁盘**不读字面量
/// 见证读的是 `writeFixture` 已经落盘的那份字节（`writeFixture` 原样写、不加工），不是表里复制的
/// 第二份源文。少一份字面量就少一处可以跟着一起改的地方：想让见证说谎，你得把真正被扫描的输入
/// 也改成那个形状 —— 那时它已经不是「谎」了，是真换了形状，而换过去撞上的是下面那条互斥。
/// 读不出来（路径写错 / fixture 被挪走）⇒ **红**，不是跳过。
///
/// ## 三条断言，各自的靶子不同，别合并
/// · **正向**：这一行的三段判别式在它自己那份 fixture 里都成立。靶子 = 把 fixture 的形状换掉
///   （上面那两发，外加 ⑰ 第 13 行那发 `public extension` —— 那一发由 `enclosedBy` 接住）。
/// · **非空**：判别词不许是空串。靶子 = 把判别词削成恒真。
/// · **互斥**：这个判别词**不**在同表任何别的 fixture 里出现。靶子 = 把判别词**放宽**到撞上兄弟
///   （削成 `"private "` ⇒ 撞上同表另外三种私有类型 ⇒ 红）。
///
/// ⚠️ **「非空」为什么必须与「互斥」分开写，而不是让互斥去兜。** 上一稿把「削成 `""`」逐字写成
/// 互斥的靶子，并声称「没有这一条，正向那半可以被一个 `""` 一次性买通」。红队打掉了，实测坐实：
/// 互斥对 `indented: true` 的行是**结构性恒真**的 —— 同表兄弟里一条缩进行都没有（⑩ 的 `Backtick`
/// 与 ⑰ 那六份私有 fixture 都是两行顶格），于是 `shapeWitnessLine` 在第二段合取处就短路成 `nil`，
/// **`declarator` 取什么值根本进不了判别**。实测：`LocalNestedFunc` 与 `Operator` 的判别词各自削成
/// `""` ⇒ **2325 全绿零红**；同一手打在 `PrivateActor`（`indented: false`）⇒ 红 2。
/// 13 行里有 2 行，上一稿那句话是假的 —— 而**上一轮台账正好挑中了会红的那一行**，于是我以为这根轴
/// 钉住了。台账挑对自己有利的样本，比没有台账更坏。
///
/// 台账实测（每条都跑过，不是推理）：换形状 ⇒ 红 4；`indented` 两个方向各翻一次 ⇒ 各红 2；
/// 判别词削成 `"private "` ⇒ 红 2；`path` 写错 ⇒ 红 2（走读不出来那一支）；
/// 判别词收窄成更长的真前缀 ⇒ 全绿（负控：这把锁不是一碰就红）。
/// 把 `shapeWitnessLine` 里 `indented` 那一半判定拿掉（**数据没坏、判据坏了**）⇒ 红 2，
/// 开火的是**互斥**那条（`func ` 要求顶格一旦不再要求，它当场同时认得出 `PublicExtension.swift`）。
///
/// ## 诚实的限度（每一条都是实测出来的全绿，不是推理出来的担忧）
/// · **互斥在「同表唯一含缩进行」的那些行上恒真**，今天正是 ⑩ 的 `Operator` 与 ⑰ 的
///   `LocalNestedFunc` 两行。它们的判别词由**非空**那条与 `enclosedBy` 兜着，不是由互斥兜着。
///   要让互斥在这两行上真的有牙，得给这两张表各添一份**带缩进行、但形状不同**的兄弟 fixture ——
///   而表的每一行都必须是生产诊断逐字列出的形状，不能为了喂互斥凭空加行。见 TODOS。
/// · 互斥这一半的分辨力还来自**同表至少两行**。单行表上它恒真 —— 今天三张表分别是 4 / 2 / 7 行，
///   而行数掉不下去是**覆盖锁**保证的（`mustCover` 三张表分别 4 / 2 / 7 个键），不是这里保证的。
///   两把锁互补，谁也替不了谁。
/// · `enclosedBy` 只看**上方最近一条非空行**，不是一台括号匹配器。它分得开「函数体内」与
///   「`public extension` 块内」（这就够挡住红队那一发），但分不开更深的嵌套。要真的判「嵌在什么里」
///   得有括号配平，而本文件 ⑰ 上方那段已经实测论证过那台机器**现在不能造**。
/// · **`enclosedBy` 没有「守卫的守卫」。** `indented` 被掏空时互斥会替它喊（实测 R1：`func ` 一旦不再
///   要求顶格，当场撞上 `PublicExtension.swift` ⇒ 红 2）；`enclosedBy` 没有这层 —— 把
///   `shapeWitnessLine` 里那一段判定短路掉 ⇒ **2351 全绿**。原因是带 `enclosedBy` 的两行**恰好就是**
///   互斥恒真的那两行，两个洞是同一个洞。它的分辨力全部来自「改 fixture 的外层」这三发实测
///   （⇒ 各红 2），而**削弱判据本身自检不到** —— 这是台账的固有天花板，不是这里能补的，
///   别把它读成「已经守住」。
/// · **`shape` / `modifier` 那一列仍然是纯散文，这把锁没有碰它。** 它只进失败文案，没有任何断言读它。
///   实测：把 ⑰ 里 `PrivateEnum.swift` 那一行的 `shape` 改成「private struct 的无修饰符成员」而
///   判别词不动 ⇒ **2325 全绿**。这把锁钉死的是**判别词 ↔ fixture**这条边，不是**散文 ↔ 判别词**。
///   ⑦⑧⑧b 的措辞（「package」「不写修饰符（隐式 internal）」）与判别词本就不同形，想用
///   `shape.contains(declarator)` 一把捞是捞不住的 —— 别写一条只在 ⑰ 上成立的规则然后声称三张表都锁了。
/// · 调用点本身没被强制存在：把某一张表的 `expectShapeWitnesses(…)` 整段删掉 ⇒ **2317 全绿**
///   （少 8 条检查）。与 `mustCover` 同一类「两处字面量」限度 —— 抬高门槛，不是锁死。
/// · 它证的是「表里这一行与它自己那份 fixture 对得上」，**不是**「表与生产诊断串对得上」。诊断串
///   长出第六种私有形状而三处（诊断、表、`mustCover`）一起停在旧清单，照样全绿 —— 那一侧要靠
///   「诊断句子由表生成」才闭得掉，见 TODOS「T3 形状表与诊断串未同源」。**别把这把锁复述成
///   「形状表已经与诊断同源」。**
@MainActor
private func expectShapeWitnesses(
    _ tableName: String,
    rows: [(key: String, shape: String, path: String, witness: ShapeWitness)],
    under root: URL,
    vectorLabel: String
) {
    let sources: [(key: String, text: String?)] = rows.map { row in
        (row.key, try? String(contentsOf: root.appendingPathComponent(row.path), encoding: .utf8))
    }
    for (index, row) in rows.enumerated() {
        guard let text = sources[index].text else {
            expect(
                false,
                "【向量：\(vectorLabel)】形状表「\(tableName)」这一行（`\(row.key)`）的 fixture 读不出来"
                    + "（路径 `\(row.path)`）—— 见证锁没法证明这一行声称的「\(row.shape)」真的被扫描到过。"
                    + "路径写错、fixture 被挪走、或者压根没写，这里一律**当红处理**：认不出就红，"
                    + "不是跳过。")
            continue
        }
        // 正向：这一行声称的形状，在真正被扫描的那份输入里确实长成那样。
        expect(
            shapeWitnessLine(row.witness, in: text) != nil,
            "【向量：\(vectorLabel)】形状表「\(tableName)」的 `\(row.key)` 这一行声称的形状是"
                + "「\(row.shape)」，但它那份 fixture 里**没有**任何一行同时满足："
                + "\(row.witness.indented ? "带缩进" : "顶格")、以 `\(row.witness.declarator)` 打头"
                + (row.witness.enclosedBy.map { "、且上方最近一条非空行以 `\($0)` 打头" } ?? "")
                + " —— 行还在、文件名和成员名都对得上，形状却已经换掉了。这正是 "
                + "`/codex review b0ce657` 那条 P1 的形状（把 `private enum` 换成 `private struct`，"
                + "2269 条断言一条不红），而生产诊断串照旧逐字声称这个形状有 fixture 钉着。"
                + "要换形状，先换诊断串里的措辞。fixture 实际内容：\n\(text)")
        // 非空：判别词不许是空串。**这一条不能并进下面的互斥** —— 互斥对「同表唯一含缩进行」的行
        //      （今天是 ⑩ 的 Operator 与 ⑰ 的 LocalNestedFunc）结构性恒真，实测把它们的判别词削成
        //      `""` 是 2325 全绿。少了这一条，那两行的判别词可以直接归零而没有任何断言喊。
        expect(
            !row.witness.declarator.isEmpty,
            "【向量：\(vectorLabel)】形状表「\(tableName)」的 `\(row.key)` 这一行判别词是**空串** —— "
                + "空串对每一行都 `hasPrefix`，正向见证就此退化成「这份 fixture 里有没有一条"
                + "\(row.witness.indented ? "带缩进" : "顶格")的行」，与它声称的「\(row.shape)」再无关系。"
                + "别指望下面那条互斥兜住这一手：它对同表**没有可撞兄弟**的行恒真（实测两行全绿）。"
                + "判别词必须窄到只认得出自己那一份形状。")
        // 互斥：这个判别词只认得出自己那一份。靶子是把判别词**放宽**到撞上兄弟（如 `"private "`）。
        let collisions =
            zip(rows, sources)
            .filter { $0.0.key != row.key }
            .filter { _, source in
                source.text.map { shapeWitnessLine(row.witness, in: $0) != nil } ?? false
            }
            .map(\.0.key)
        expect(
            collisions.isEmpty,
            "【向量：\(vectorLabel)】形状表「\(tableName)」的 `\(row.key)` 这一行，判别词 "
                + "`\(row.witness.declarator)`（\(row.witness.indented ? "要求缩进" : "要求顶格")）"
                + "同时认得出同表的 \(collisions) —— 这两种形状在判别式眼里已经不可分了。放宽到这一步，"
                + "正向见证对撞上的每一行都为真：谁的 fixture 换成了对方那种形状都不会有人喊，而生产"
                + "诊断串还在逐字把它们当成**两种**形状、各自声称有 fixture 钉着。"
                + "判别词必须窄到只认得出自己那一份形状。")
    }
}

/// `relativePath` 里两行哨兵之间的那段文本（不含哨兵本身）。抽不到 ⇒ `nil`（调用方当作红处理）。
private func fenceCallSiteRegion(of relativePath: String) -> String? {
    guard
        let text = try? String(
            contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
    else { return nil }
    let lines = text.components(separatedBy: "\n")
    func indexOfSentinel(_ sentinel: String) -> Int? {
        lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == sentinel }
    }
    guard
        let begin = indexOfSentinel(fenceCallSiteBegin),
        let end = indexOfSentinel(fenceCallSiteEnd),
        begin < end
    else { return nil }
    return lines[(begin + 1)..<end].joined(separator: "\n")
}

/// `relativePath` 里两种哨兵**各自出现的行数**。读不到文件 ⇒ `(0, 0)`（调用方当作红处理）。
///
/// 上面那个抽取函数取的是 `firstIndex`，所以「有没有第二对」它一个字都不会说。红队实测的劫持手法：
/// 在真调用点**之前**插一对诱饵哨兵（写在块注释里、或多行字符串里都行 —— 抽取跑在**原始文本**上，
/// `strippingComments` 是抽完之后才施加的，所以诱饵与真哨兵逐字节无从区分），观测器就去读那段诱饵，
/// 真调用点降为第二处、从此不受任何检查。所以唯一性必须**单独**断言。
private func fenceCallSiteSentinelCounts(of relativePath: String) -> (begin: Int, end: Int) {
    guard
        let text = try? String(
            contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
    else { return (0, 0) }
    let trimmed = text.components(separatedBy: "\n").map {
        $0.trimmingCharacters(in: .whitespaces)
    }
    return (
        trimmed.filter { $0 == fenceCallSiteBegin }.count,
        trimmed.filter { $0 == fenceCallSiteEnd }.count
    )
}

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
// 并发 token 黑名单那条腿只挡「变异步」，挡不住「同步但脱离主 actor」。manifest.json 的跨进程
// 互斥现在由 `packs.lock` 给，而**进程内**那一半仍然靠「全同步 **且** 全在 @MainActor」，
// 黑名单只钉住了「全同步」那半。这两个 helper 让绊线
// 正向钉住第二条腿：文件里**每一个枚举得到的**导出写函数都得带 @MainActor —— 不是一份会忘记
// 更新的写死名字清单，新写者（forkPack / restoreFactoryPack）落地即自动纳入。
//
// ⚠️ 「每一个**枚举得到的**」这个限定词是认真的，别读成「每一个」——见下面 `exportedPublicFuncNames`
// 的已知盲区。这条腿是**探针，不是围栏**：它认不出的写函数形状是**静默跳过**，不是红。

/// `func` **关键字**的词素 —— **只有这一份**，四台识别器（关键字计数 / 名字解析 / 导出 /
/// 文件内私有 / @MainActor）全部共用。与 ``fenceResourceKeys`` 同一条纪律：分成两份，漂移的
/// 那一半是没有人在看的那一半。
///
/// `(?<!`)` 排除**反引号转义标识符**里的那个 `func` —— `let \`func\` = 0` 是合法 Swift
/// （`swiftc -swift-version 6 -typecheck` rc=0），它不是声明，却把关键字计数顶高一格而让
/// 「名字解析不出来」那条腿**假红**。
///
/// ## ⚠️ 只许 lookbehind，**绝不许**再加 lookahead `(?!`)`（红队实测两条 fatal，方向相反）
///  · **加 lookahead** ⇒ `func\`default\`()`（`func` 与反引号之间**没有空格**，swiftc rc=0，
///    合法）会**同时**从关键字计数与名字解析里消失 —— 两边一起失明、差额恒 0、静默绿。
///  · **只把 lookbehind 加在关键字计数这一台**（不加在名字解析那一台）更糟，它把一条**现存的
///    红变成绿**：裸 regex 字面量 `let p = /\`func mutate/`（swiftc rc=0；`strippingComments`
///    既不建模它、也不记进 `unmodeledConstructs`）给名字解析 +1 而给关键字 +0，凑出 **−1**；
///    它与一个运算符声明 `public static func == (…)` 天然给出的 **+1 精确抵消**，差额归零，
///    运算符声明整个隐身。实测三列（同一份输入）：
///      现状 kw=3 named=2 差 1（红） / 只加关键字 kw=2 named=2 差 0（**绿**） /
///      共用词素 kw=2 named=1 差 1（红）。
///    **一个 ±1 的错误抵消掉一个 ±1 的信号** —— 本文件反复在治的那个病，这一次长在「修它」
///    的那一刀自己身上。
///
/// ⚠️ Swift 字符串里写**裸反引号**，不是 `\``（后者不是合法转义，编译不过）。
private let funcKeywordLexeme = "(?<!`)\\bfunc\\b"

/// 一个访问修饰符（`public` / `private` / `@MainActor`…）与**它自己那个** `func` 之间允许出现
/// 的东西：空白、属性（`@foo`）、以及**已知修饰符词**。
///
/// 认得的形态：`public func` / `public static func` / `public final func` / `public class func` /
/// `public override func` / 换行排版 / `@_spi(X) public func`。
///
/// ## 为什么是白名单，而且白名单在这里是**安全**方向
/// run 里出现一个不认识的词 ⇒ run 断掉 ⇒ 这个声明不被任何一台识别器认领 ⇒ 落进
/// ``unrecognizedFuncDeclarations(in:)`` ⇒ **红**。也就是说收窄 = fail-closed，**放宽才是危险
/// 方向**。这与本文件其余地方「白名单不完整所以有罪」的判断不矛盾：那些地方的白名单放行即绿，
/// 这里的白名单放行即「交给别的腿继续查」，认不出即红。
///
/// ## 上一版 `[\sA-Za-z@_]*`（任意字母词）是一条**活着的 fail-open**（红队实测，本轮修掉）
/// 它跨得过任何**整条不含标点的声明**：
///
/// ```swift
/// private import Foundation                 // 整条声明零标点，run 一路跨过去
/// func mutate() { mutateManifestJSON() }    // 被 fileLocalFuncNames 当成「private 的」认领走
/// ```
///
/// `mutate` 是隐式 internal、模块内**任意后台线程都能同步调它**，却被白名单静默放行 —— 实测
/// `unrecognizedFuncDeclarations` 为 `[]`，四条腿一条都不响；把 `private import` 换成普通
/// `import` 的对照组则为 `["mutate"]`。`private import` 是 Swift 6 的 access-level import
/// （SE-0409），swiftc rc=0，是真代码不是构造出来的畸形。
///
/// ⚠️ 红队给这一条开的另一个方子（「按匹配**位置**认领，别按名字做差」）**实测修不好它**：
/// 这不是同一个声明被两台识别器双重认领，而是**一台**识别器认领了一个根本不归它管的声明，
/// 位置去重对它无效（实测 byName 与 byPosition 同为 `[]`）。修法只能是收窄 run 本身。
///
/// 收窄之后，真仓库与自证在用的形状**逐个实测仍被认出**（零假红）：`@MainActor public func` /
/// `public static func` / `@MainActor public static func` / `private func` / `@_spi(X) public func` /
/// `public final class func` / `public` 与 `func` 分行排版。
private let funcModifierWords = [
    "static", "final", "class", "override", "mutating", "nonmutating",
    "convenience", "required", "dynamic", "lazy", "indirect", "optional",
    "weak", "unowned", "open", "public", "internal", "package", "private", "fileprivate",
]
private let publicFuncModifierRun =
    "(?:\\s|@[A-Za-z_][A-Za-z0-9_]*|\\b(?:\(funcModifierWords.joined(separator: "|")))\\b)*"

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
/// ⚠️ 这台识别器**只认 `public`**，`package` / `open` / 不写修饰符（隐式 `internal`）都不在内。
/// 但「认不出」不再等于「静默跳过」—— 认不出的声明由 ``unrecognizedFuncDeclarations(in:)``
/// 当场变红（见那边）。这里保留的是**假红**那一侧的限度：靠 `@MainActor extension` 或类型级隔离、
/// 函数头上不带注解的写者，会被 ``hasMainActorIsolation`` 判成「未隔离」而假红（假红是安全侧，
/// 但它会招来「把绊线删掉」那种修法——真出现了，请扩 ``hasMainActorIsolation``，别删断言）。
private func exportedPublicFuncNames(in code: String) -> [String] {
    let pattern = "public\(publicFuncModifierRun)\(funcKeywordLexeme)\\s+([A-Za-z_][A-Za-z0-9_]*)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let text = code as NSString
    return regex
        .matches(in: code, range: NSRange(location: 0, length: text.length))
        .map { text.substring(with: $0.range(at: 1)) }
}

/// 一段**已剥注释**的代码里所有**文件内私有**（`private` / `fileprivate`）函数的名字。
///
/// 存在的唯一理由是给 ``unrecognizedFuncDeclarations(in:)`` 当**白名单的第二格**：真仓库
/// `ManifestBinding.swift` 里的 `resolveUserPackDirectory` 正是这个形状，少了这一格它会假红，
/// 而假红的守卫会被下一个人删掉（本文件开头记着这个病）。
///
/// ## ⚠️ 放行 `private` 的理由是**不完整**的，别把它读成一条证明
/// 上一稿这里写的是「私有函数出不了这个文件，而这个文件里每一个出得去的声明都已被
/// 『导出写函数都得 @MainActor』钉住 ⇒ 私有函数只可能从已隔离的代码里被调到」。
/// **那句推理是假的**，红队实测打穿（`/codex review 48cbc07` 之后那轮）：
///
/// ```swift
/// public let escapeHatch: () -> Void = { privateFlush() }   // 公开的闭包属性，把私有函数带出文件
/// private func privateFlush() { mutateManifestJSON() }      // 白名单放行，零 finding
/// ```
///
/// 闭包属性不是 `func`，不进任何一台识别器；它捕获的私有函数于是从**任意线程**都可达，
/// 而 `private` 这一格白纸黑字放它过去。实测该 fixture 产出 **0** 条 finding。
///
/// 保留这一格是**权衡**（不放行 ⇒ 真仓库假红 ⇒ 绊线被删），不是「私有一定安全」。
/// 这条缺口登记在 `TODOS.md`「`private` 白名单靠一条假前提」那一条，别在别处再引用那句假推理。
///
/// ⚠️ 用 `\b(?:fileprivate|private)\b` 而不是 `(?:private|fileprivate)`：后者在 `fileprivate`
/// 上会从第 5 个字符起匹配到里面那个 `private`，两种写法各自计数就不再等价。
private func fileLocalFuncNames(in code: String) -> [String] {
    let pattern =
        "\\b(?:fileprivate|private)\\b\(publicFuncModifierRun)\(funcKeywordLexeme)\\s+([A-Za-z_][A-Za-z0-9_]*)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let text = code as NSString
    return regex
        .matches(in: code, range: NSRange(location: 0, length: text.length))
        .map { text.substring(with: $0.range(at: 1)) }
}

/// 一段**已剥注释**的代码里**每一个** `func` 声明的名字（同名重载各计一次）。
///
/// 这是围栏极性那根**标尺**：上面两台识别器各自只认一组已知形态，它们的和若少于这里数到的总数，
/// 说明这个文件里有一个声明**没有任何一台识别器认得**。
private func allFuncDeclarationNames(in code: String) -> [String] {
    let pattern = "\(funcKeywordLexeme)\\s+([A-Za-z_][A-Za-z0-9_]*)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let text = code as NSString
    return regex
        .matches(in: code, range: NSRange(location: 0, length: text.length))
        .map { text.substring(with: $0.range(at: 1)) }
}

/// 一段**已剥注释**的代码里 `func` **关键字**出现了几次（不管后面跟的是什么）。
///
/// ## 为什么标尺自己还要一把标尺（红队实测，两条 fatal）
/// ``allFuncDeclarationNames(in:)`` 捞的是 `func` + **一个能当标识符首字符的名字**
/// （`[A-Za-z_]`）。于是「有 `func` 关键字、但名字不长那样」的声明，它一条都数不到 ——
/// 而这种声明**照样是可编译的真代码，照样能写 manifest**：
///
/// ```swift
/// func `default`() { mutateManifestJSON() }              // 反引号转义标识符
/// public static func == (l: K, r: K) -> Bool { … }        // 运算符声明，名字是 `==`
/// ```
///
/// 两者都**不被** `allFuncDeclarationNames` 数到，也**不被**两台识别器数到 —— 三边同时看不见，
/// 差额是 0，`unrecognizedFuncDeclarations` 全绿。实测确认：这两个 fixture 各自产出 **0** 条
/// finding（`/codex review 48cbc07` 之后那轮红队，四种形状里的两种）。
///
/// 修法是**再退一层**：数关键字。关键字数 ≠ 三边数得出名字的总数 ⇒ 有声明**连名字都解析不出来**
/// ⇒ 红。这条报不出是谁（正因为名字解析不出来），所以它报的是**计数差**，并让人自己去 grep
/// `func` —— 一条报不出名字的红，好过一条报不出来的绿。
private func funcKeywordCount(in code: String) -> Int {
    guard let regex = try? NSRegularExpression(pattern: funcKeywordLexeme) else { return 0 }
    let text = code as NSString
    return regex.numberOfMatches(in: code, range: NSRange(location: 0, length: text.length))
}

/// 一个纳入文件里**没有任何识别器认得**的 `func` 声明名，按名字去重后排序。空 = 全都认得。
///
/// ## 这条补的是什么洞（`/codex review 48cbc07` 的 P1 之一，红队实测确认）
/// 上一版判「枚举器瞎没瞎」只有一条 `exported.isEmpty` —— 它只在一个 `public func` 都**枚举不到**
/// 时才开火。于是文件里只要**已经有一个**正常的 `public func`（真仓库的 `ManifestBinding.swift`
/// 有三个），再加一个不写修饰符的写者：
///
/// ```swift
/// @MainActor public func mutateManifestJSON(…) { … }   // 枚举得到 → exported 非空
/// func sneakyWriter() { mutateManifestJSON() }          // 隐式 internal，两台识别器都不认得
/// ```
///
/// `exported` 非空 ⇒ 那条不开火；`missingMainActorIsolation` 只遍历**枚举得到的**名字 ⇒ 也不开火。
/// 一条 finding 都不产生，而 `sneakyWriter` 是 internal 的、模块内任意后台线程可以同步调它。
/// 「认不出 ⇒ 红」在这个形状上**反过来**了：认不出 ⇒ 绿。
///
/// 修法是**数**：`func` 声明的总数，必须等于两台识别器认出来的数之和。差额就是认不出的那些。
/// 按**计数**而不是按集合做差 —— 同名重载（`public func f` + 一个裸 `func f`）在集合语义下会被
/// 前者洗白，正是本文件已经被咬过一次的那个形状（见 ``mainActorIsolatedFuncNames(in:)``）。
///
/// ⚠️ 这台**没有**独立的第三份正则去认修饰符：它复用上面两台的输出做差。所以两台识别器任何一台
/// 变宽（比如有人给 `publicFuncModifierRun` 加上标点），这条会跟着一起变宽而不会报警。它守的是
/// 「有没有漏网的声明」，不是「识别器认得对不对」—— 后者由 `@MainActor 合成控制` 那条 suite 守。
///
/// ## ⚠️ 它把极性补上的是**哪一根轴**：`func` 声明的**修饰符形态**，仅此一根
/// 别把「认不出 ⇒ 红」读成「这个文件里不可能再有隐身的写者」。这台标尺数的是 `func` 声明，于是
/// **一切不是 `func` 的写入点它一个都看不见**。红队实测（本轮，跑完即删的临时探针）：
///
/// ```swift
/// @MainActor public func probeClean() { _ = 1 }
/// public var probeTrigger: Int { mutateManifestJSON(); return 1 }   // ← 计算属性
/// ```
///
/// 这个文件产出的 finding 数是 **0**：`unmodeledConstructs` 空、并发 token 空、`exported.isEmpty`
/// 为假（`probeClean` 顶着）、`func` 声明总数与识别数相等（只有 `probeClean` 一个 `func`）、
/// `missingMainActorIsolation` 只遍历枚举得到的名字。**四条腿一条都没响，而那句读-改-写就在
/// `probeTrigger` 的 getter 里。** 计算属性、`subscript`、`init` / `deinit`、`willSet` / `didSet`
/// 是同一根轴上的同一个洞，全部隐身。
///
/// 没在本轮修，是因为修它要换判据的**量纲**（从「数声明」变成「找出所有能含语句的括号块」），
/// 那是重设计而不是补一刀。登记在 `TODOS.md`「T3 判定腿只数 `func`」那条。
private func unrecognizedFuncDeclarations(in scanned: StrippedSwiftSource) -> [String] {
    let source = scanned.codeWithoutStringLiterals
    var counts: [String: Int] = [:]
    for name in allFuncDeclarationNames(in: source) { counts[name, default: 0] += 1 }
    for name in exportedPublicFuncNames(in: source) { counts[name, default: 0] -= 1 }
    for name in fileLocalFuncNames(in: source) { counts[name, default: 0] -= 1 }
    return counts.filter { $0.value > 0 }.map(\.key).sorted()
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
    let pattern =
        "@MainActor\(publicFuncModifierRun)\(funcKeywordLexeme)\\s+([A-Za-z_][A-Za-z0-9_]*)"
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

    // MARK: T3 并发绊线 —— 守的是 `~/.claudio/packs.lock` 的**作用域**，不再是「零锁」本身
    //
    // ⚠️ **这段自述被改写过一次，别照旧读。** 上一版逐字写的是「manifest.json 唯一的并发安全
    // 保证是「全同步 + 全在 @MainActor」，不是锁（`grep -iE 'lock' ManifestBinding.swift` 是
    // 空的）」。那句话已经**两头都假**了：
    //  · `manifest.json` 现在有锁了（`mutateManifestJSON(at:lockFile:_:)` 整段读-改-写跑在
    //    `packs.lock` 里），那句 grep 不再是空的；
    //  · 而它当年也从来不是「唯一」的写者 —— helper 的 `performFirstRunSetup` 以**目录粒度**
    //    发布整棵包目录（`Setup.swift` 的 `copyItem`→`moveItem`，还会把用户整个包目录挪走），
    //    当时零锁（本轮已一并上锁，与 GUI 侧共用 `packs.lock`），且这条围栏**两重**看不见它
    //    （只扫 `gui/Sources`；纳入判据又要求文件含
    //    `mutateManifestJSON` 这个 token）。GUI 自己还把 setup 派到主 actor 外
    //    （`OnboardingActions` 的 `Task.detached`）—— 所以「全部在 @MainActor」在本进程内也是假的。
    //  这是本文件治了十二次的那个病，第十三次：**长在它自己的立身理由上**，而且假了很久没人发现。
    //
    // 现在这条绊线的理由收窄成一句能站住的话：**它守的是那把锁的作用域。**
    //  · `Task.detached { … write … }`、或改成 async 并在读与写之间插一个 `await` —— 两者都把
    //    真正的写**挪到锁释放之后**，锁当场形同虚设。实测：注入 `Task.detached` 包住那次 write，
    //    两个包都 Build complete、**零警告**（`Data`/`URL` 都是 Sendable，`Data.write` 是 nonisolated）。
    //  · 删掉 `@MainActor` 是一次**放宽**，现存调用方本身都在主 actor 上，放宽后依然合法 ——
    //    实测同样 **Build complete、零诊断**。编译器强制的是注解的*后果*，从不是注解的*存在*。
    // 两条都是编译器原理上看不见的，锁也替不了 —— 所以这条绊线留着，理由换了，措辞跟着换。
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
        // ⚠️ 扫描根与 `pathPrefix` 用**文件级**的那一份（`fenceScanRelativeRoot` / `fencePathPrefix`），
        // 不在这里另起一个局部常量：消费边自证必须能喂出与生产**逐字相同**的实参向量，见那两个常量
        // 头上那段（红队实测的 `where pathPrefix.isEmpty` 逃逸就长在这根轴上）。
        let scanRelativeRoot = fenceScanRelativeRoot
        let coreRelativeDirectory = "gui/Sources/ClaudioGUICore"
        let scanRootURL = repoRoot().appendingPathComponent(scanRelativeRoot)

        // ⚠️ 这一行**就是**整条围栏，连同「把 finding 变成红」那一步在内。枚举、纳入判据、三条判定
        // 腿、以及消费边，全在 `enforceManifestConcurrencyFence` 里边（见它头上那段）：没有枚举可以
        // 在这里被改回非递归（`/codex review 15ce131` 的 P1），也没有消费循环可以在这里被 `.filter`
        // 掉（`36fce57` 的 P1）。
        //
        // ⚠️ **但别把这句读成「调用点上没有任何可改的语义」**（上一稿就是这么写的，红队实测打掉）：
        // 这个函数有**默认实参**，而默认实参就是可改语义 —— 在这里多传一个 `readEntryKind:` 桩，
        // 或多传一个新加的 `report: false`，都能让围栏在生产路径上失效。所以「消费边接线自证」那条
        // suite 钉的是这两行哨兵之间的**逐字全等**（不是子串），多一个实参就当场红。
        //
        // 下面那些 `expect` 全是**覆盖范围**断言（枚举到没有、扫了哪两个 target、纳入判据瞎没瞎），
        // 不是判定结果的消费 —— 判定结果已经在上面这一行里消费完了。别再往这里加 `audit.findings`
        // 的循环。
        // claudio:manifest-fence-callsite:begin
        let audit = enforceManifestConcurrencyFence(
            under: scanRootURL, pathPrefix: fencePathPrefix)
        // claudio:manifest-fence-callsite:end

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
                    + "  · 否 → 它绕开了原语，围栏漏得掉它 —— 而绕开原语也就绕开了 `packs.lock`"
                    + "（锁是在 `mutateManifestJSON(at:lockFile:_:)` 里取的，不是在文件系统那一层），"
                    + "manifest.json 就多了一个**既不设防、也不互斥**的写者。要么让它经原语，"
                    + "要么在这里补一条针对它的检查。\n"
                    + "（PLAN-SOUND-MANAGER.md §2.1 / 4c「并发不变式」）")
        }

        // ⚠️ 这里**曾经**有一圈 `for finding in audit.findings { expect(false, finding) }`。
        // 它已经下沉进 `enforceManifestConcurrencyFence`（`/codex review 36fce57` 的 P1 之三）——
        // 留在这里就是留一段可以被 `.filter` 掉、而所有自证照绿的语义。别把它加回来。
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

    // 围栏**消费边**自证有牙（`/codex review 36fce57` 的 P1 之三）。
    //
    // ## 被打穿的是哪一刀
    // 上一版真围栏那侧是两行：`let audit = auditManifestConcurrencyFence(…)`，然后
    // `for finding in audit.findings { expect(false, finding) }`。把第二行改成
    // `audit.findings.filter { _ in false }`，围栏从此不消费任何 finding —— 而**当时全部**自证 suite
    // 照绿，因为它们直接调 `auditManifestConcurrencyFence`，一条都不经过那行。围栏静默失效，零告警。
    //
    // ## 为什么这条逮得住
    // 它走**生产同一个函数**（`enforceManifestConcurrencyFence`）、用**生产同一个** `expect`、观测
    // **真的 `failures` 全局计数**。判据是「涨了多少」**等于**「该涨多少」——不是「涨了没有」，后者
    // 对「只报第一条」那类变异恒真（本文件已经在别处被这个形状咬过一次）。
    //
    // ## 那几行 ✗ 是证据，不是回归
    // 这条 suite **故意**制造真失败，然后把计数撤回。撤回的只是计数，已经打印出去的那几行 ✗ 撤不回，
    // 所以上下各打一句标注，读日志的人不会把它们当成真失败。
    // ## ⚠️ 为什么要对**每一个实参向量**各跑一遍（红队实测打穿的正是这里）
    // 上一稿只调 `enforceManifestConcurrencyFence(under: scanned)` —— 全部走**默认实参**。而生产传的
    // 是 `pathPrefix: fencePathPrefix`。于是任何「在自证向量下为真、在生产向量下为假」的谓词都能
    // 寄生在消费循环上，实测两种，两种都全绿：
    //  · `for finding in audit.findings where pathPrefix.isEmpty { … }` —— **生产调用点一个字符都不改**，
    //    `git diff` 只显示函数体里多了个 `where`。自证传空串照样全红，生产的 `"gui/Sources/"` 被静默关掉。
    //  · 新加一个 `report: Bool = true` 形参、生产调用点传 `report: false` —— 同理。
    // （后者另有一道：接线自证现在钉哨兵区块**逐字全等**，多一个实参当场红。前者接线断言看不见，
    //   只能靠这里把向量喂对。两道各挡一侧。）
    //
    // 教训：**「同一个函数」≠「同一条生产路径」的第三层。** 前两轮分别是「同一个 helper ≠ 同一条边」
    // 和「同一条边 ≠ 连消费一起」，这一轮是「同一个函数 ≠ 同一个**实参向量**」。函数的牙只在它被
    // 举证过的那个向量上成立。
    //
    // **仍然诚实的限度**：`root` 这根轴闭不上 —— 自证必须喂脏临时树，生产根恒为真仓库。所以
    // `where root.path.hasPrefix("/Users") { … }` 这类寄生仍然逃得掉。收窄了，没清零。
    suite("绊线（T3）围栏消费边自证有牙：findings 必须真的变成红，一条都不许少（含生产实参向量）") {
        // 逐个向量各跑一遍。`("生产向量", fencePathPrefix)` 与真围栏传的**逐字相同**。
        //
        // ⚠️ 下面这五条守卫（G1、G2、G3、G3b、G4）与穿线见证（W2）是 `/codex review abbf48e` 与
        // `ae494b1` 两轮补的：最早只有这个 `for` 和一个字面量数组，**没有任何东西**保证它真的跑了
        // 两圈、两圈真的不同、生产那个值真的在清单里、以及 `pathPrefix` 真的穿进了被调函数。少了
        // 它们，这个参数化可以被一行 `.prefix(1)` 或「把第二项改成空串」悄悄掏空，而每一条断言照样
        // 全绿。
        //
        // ⚠️ 标签说「空前缀」不说「默认」是**故意**的：这一项是**显式**传 `""`，不是省略实参。它与
        // 当前默认实参同值（两个 fence 函数的签名都是 `pathPrefix: String = ""`），但「同值」不是
        // 「同一条路径」—— 有人把默认实参改掉，这一项仍然测空前缀，只是不再代表「默认」。措辞按
        // 它**实际**举证的东西写，不按它顺便沾上的东西写。
        let fenceProofVectors: [(label: String, pathPrefix: String)] = [
            ("空前缀向量（显式传 \"\"）", ""),
            ("生产向量（pathPrefix 与真围栏逐字相同）", fencePathPrefix),
        ]
        // G1 常量形状（`!=` 那一项挡的是「少一个斜杠」那种改坏，只写 `!isEmpty` 会放它过去）。
        expect(
            !fencePathPrefix.isEmpty && fencePathPrefix != fenceScanRelativeRoot,
            "`fencePathPrefix`（\"\(fencePathPrefix)\"）不是一个真前缀 —— 两个「向量」会逐字相同，"
                + "参数化退化成把同一件事跑两遍。")
        // G2 互异（从被遍历的那个数组自己算，不是拿两个字面量比）。
        expect(
            Set(fenceProofVectors.map(\.pathPrefix)).count == fenceProofVectors.count,
            "实参向量清单里有重复的 pathPrefix（\(fenceProofVectors.map(\.pathPrefix))）—— 两圈跑的"
                + "是同一件事。")
        // G3 生产用的那个值真的在清单里。
        expect(
            fenceProofVectors.contains { $0.pathPrefix == fencePathPrefix },
            "实参向量清单里没有生产用的那个 pathPrefix（\"\(fencePathPrefix)\"）—— 消费边自证从没在"
                + "生产实参下跑过。清单：\(fenceProofVectors.map(\.pathPrefix))")
        // G3b 清单不许被砍。（`/codex review ae494b1` P2-1。）
        //    G4 见证的是「跑过的圈数 == 清单长度」—— 它对**清单自己缩水**恒真。把这个字面量数组砍成
        //    只剩生产那一项：G1 压根不引用数组、G2 是 `1 == 1`、G3 照样找得到生产值、G4 是
        //    `["gui/Sources/"] == ["gui/Sources/"]`、W2 也只见证那一圈 —— **五条守卫零响应**，而空前缀
        //    那根轴就此重新失守，`where pathPrefix.isEmpty { return [] }` 这类寄生谓词又能全身而过。
        //
        //    G4 与这一条覆盖的是**不相交**的变异集，互补，不是二选一：
        //      · `for … in fenceProofVectors.prefix(1)` ⇒ G4 红，这条恒真（清单还是两项）
        //      · 字面量数组砍成一项                      ⇒ 这条红，G4 恒真（跑满了「清单」）
        //    别照旧注释的读法把这条当成「G4 的弱化版」删掉 —— 那条注释只考虑了 `.prefix(1)` 那一侧。
        //
        //    ⚠️ 这条**只**断言「空前缀在清单里」，是 G3 的镜像（G3 钉生产值、它钉空串），**不**断言
        //    `count == 2`。第一版写的是 `count == 2 && contains{isEmpty}`，红队打掉：`count == 2`
        //    对 fail-open 方向零贡献（砍成一项由 `contains{isEmpty}` 独力逮住），它唯一独占的触发面
        //    是**清单变长** —— 而那是覆盖**改进**，不是缺陷。更坏的是它开火时印的诊断逐句为假
        //    （「空前缀那根轴没有被举证」而空前缀就在它自己印出的清单第一项）。``funcKeywordCount``
        //    的负差额诊断头上那段
        //    专门讲「字面为假的诊断把人指向错误方向」，而想加第三根轴的人拿到一条说他没做的事的红，
        //    最省力的修法是**把整条 expect 删掉** —— `contains{isEmpty}` 一起陪葬，上一轮 P1 的洞
        //    原地重开。守卫的措辞必须在它**每一种**开火情形下都为真，否则它自己就是下一个洞的入口。
        expect(
            fenceProofVectors.contains { $0.pathPrefix.isEmpty },
            "实参向量清单里没有空前缀向量（实得 \(fenceProofVectors.map(\.pathPrefix))）—— 空前缀那根轴"
                + "没有被举证。少了它，任何只在非空 pathPrefix 下才成立的寄生谓词（`where "
                + "pathPrefix.isEmpty { return [] }` 之流）都能穿过整条消费边自证，而 G1..G4 一条都不会"
                + "喊（它们各自都对「清单缩水」恒真）。加向量不受这条限制，删这一根轴才会红。")

        var executedVectors: [String] = []
        for vector in fenceProofVectors {
            let (vectorLabel, vectorPathPrefix) = (vector.label, vector.pathPrefix)
            withTempDirectory { root in
                let scanned = root.appendingPathComponent("scanned")
                // 三个脏写者、三种不同的违规形态，且分布在三层目录 —— 保证 finding 不止一条，
                // 「只报第一条」这类变异才有分辨力。
                //
                // ⚠️ 目录名照着**生产树的形状**取（`ClaudioGUICore/` / `ClaudioGUI/`）。上一版三个
                // fixture 全在 `scanned/` 与 `Nested/` 下，与生产树的目录命名空间**不相交**，于是
                // 一条 `where !finding.hasPrefix("gui/Sources/ClaudioGUICore")` 的寄生谓词能在生产上
                // 关掉整条消费而这里全绿。收窄了，没清零（见判定 suite 头上那段列的三根轴）。
                writeFixture(
                    "public func dirtyOne() async { mutateManifestJSON() }",
                    to: scanned.appendingPathComponent("DirtyOne.swift"))
                writeFixture(
                    "public func dirtyTwo() { mutateManifestJSON() }",
                    to: scanned.appendingPathComponent("ClaudioGUICore/DirtyTwo.swift"))
                writeFixture(
                    "@MainActor public func dirtyThree() { Task { mutateManifestJSON() } }",
                    to: scanned.appendingPathComponent("ClaudioGUI/Deep/DirtyThree.swift"))

                print("    ↓ 下面几行 ✗ 是这条 suite **故意**造的证据（\(vectorLabel)），稍后撤回，不是回归")
                let checksBefore = totalChecks
                let failuresBefore = failures
                let audit = enforceManifestConcurrencyFence(
                    under: scanned, pathPrefix: vectorPathPrefix)
                let raisedFailures = failures - failuresBefore
                let raisedChecks = totalChecks - checksBefore
                // 撤回：减掉**我造成的那么多**。撤多了的后果完全不对称 —— **撤多一条 = 把别的 suite 的
                // 一次真失败一起吞掉**，整个 run 变绿而那条回归无人知晓，比漏报更坏。
                failures -= raisedFailures
                totalChecks -= raisedChecks
                print("    ↑ 以上 \(raisedFailures) 行 ✗ 是证据，已撤回")

                // ⚠️ 落点检查的三步顺序（先取快照 → **无条件**归位 → 最后才断言）是台账第二轮 M20 逼
                // 出来的，别按「看着更简单」重排回去：
                //
                // 上一稿只有「断言落点 == 快照」这一条，没有中间那次无条件归位。把撤回改成
                // `-= raisedFailures + 1`，这条断言**确实开火了** —— 可它自己那次失败恰好让 `failures += 1`，
                // 与被多撤掉的那 1 **精确抵消**，全 run 照样绿。**一个 ±1 的信号抵消不掉一个 ±1 的错误。**
                // 本文件反复在治的那个病，这次长在这一轮新加的守卫自己身上。
                //
                // 现在判定读的是**归位之前**取的 `landed…` 快照，而归位那两行无条件执行：
                //  · 撤回被改坏 ⇒ landed ≠ 快照 ⇒ 归位把计数拉回快照 ⇒ 下面这条 expect 再 +1 ⇒ 全 run 红。
                //  · 归位被改坏 ⇒ landed 是对的、expect 不响 ⇒ 但计数停在非快照值 ⇒ 全 run 红。
                // 两条路都不自抵消。
                let landedFailures = failures
                let landedChecks = totalChecks
                failures = failuresBefore
                totalChecks = checksBefore

                expect(
                    landedFailures == failuresBefore && landedChecks == checksBefore,
                    "【向量：\(vectorLabel)】撤回没有精确回到快照（failures \(landedFailures) 应为 "
                        + "\(failuresBefore)，checks \(landedChecks) 应为 \(checksBefore)）—— 撤多了会把"
                        + "**别的 suite** 的真失败一起吞掉，整个 run 变绿而那条回归没有任何人看得见。"
                        + "撤少了则这条 suite 自己的证据会被当成回归。撤回必须精确。")

                // ── W2 向量穿线见证。与判定 suite 那条 W1 同一个理由：下面三条对账断言数的都是
                //    **条数**，对诊断文本里多没多出一个前缀完全瞎。忘了传 `pathPrefix:`（或被人改回
                //    默认实参），两圈跑出逐字相同的结果而三条对账照样全绿。只有这条看得见。
                expect(
                    audit.findings.contains { $0.hasPrefix("\(vectorPathPrefix)DirtyOne.swift ") },
                    "【向量：\(vectorLabel)】诊断路径没有以本向量的 pathPrefix（\"\(vectorPathPrefix)\"）"
                        + "打头 —— `pathPrefix:` 没穿进 `enforceManifestConcurrencyFence` 那次调用，两个"
                        + "向量跑的是同一件事，参数化形同虚设。下面三条对账只数条数，看不见这个。"
                        + "实际诊断首条：\(audit.findings.first ?? "（空）")")

                // 前提自钉：这棵树真的产出了 finding。缺了它，下面那条对账是 `0 == 0` 恒真。
                expect(
                    audit.findings.count >= 3,
                    "【向量：\(vectorLabel)】这棵脏树没产出足够的 finding（实得 \(audit.findings.count) "
                        + "条）—— 下面那条对账会在 `0 == 0` 上恒真，等于没测。实际诊断：\(audit.findings)")
                // 【关键腿】每一条 finding 都必须变成一次红，一条不少。
                expect(
                    raisedFailures == audit.findings.count,
                    "【向量：\(vectorLabel)】消费边漏了 finding：围栏产出 \(audit.findings.count) 条，只变红 "
                        + "\(raisedFailures) 次。"
                        + "有人在 `enforceManifestConcurrencyFence` 里把 findings `.filter` 掉了 / 只报第一条 / "
                        + "把 `expect(false, …)` 写成了 `expect(true, …)`。围栏看得见违规却不上报 —— 真文件"
                        + "那侧会静默全绿，这正是 `/codex review 36fce57` P1 打穿的那一刀。"
                        + "实际诊断：\(audit.findings)")
                // 撤回的对称性：每次红也得恰好是一次 check。对不上账 = 上面那条减法在数别的东西。
                expect(
                    raisedChecks == audit.findings.count,
                    "消费边调 `expect` 的次数与 finding 数对不上（check +\(raisedChecks) / finding "
                        + "\(audit.findings.count)）—— 撤回逻辑与消费逻辑不同源，上面那条减法数的不是它自称"
                        + "在数的东西。【向量：\(vectorLabel)】")

                // 这一圈真的跑到底了（必须是块的最后一行）。
                executedVectors.append(vector.pathPrefix)
            }
        }
        // G4 执行见证。用 `==` 连顺序一起钉。唯一挡得住 `.prefix(1)` / `.filter` / 提前退出的一条。
        expect(
            executedVectors == fenceProofVectors.map(\.pathPrefix),
            "实际跑过的实参向量与清单对不上（跑过 \(executedVectors)，清单 "
                + "\(fenceProofVectors.map(\.pathPrefix))）—— 循环被 `.prefix` / `.filter` 掉了，或者"
                + "循环体在某个向量上提前退出了。少跑一圈 = 那个向量下的消费从没被举证过。")
    }

    // 消费边的**接线**自证（同一条 P1 的另一半）。
    //
    // ## 上一条 suite 兜不住什么
    // 它证明的是「`enforceManifestConcurrencyFence` **这个函数**有牙」。它兜不住的是**接线**：有人
    // 把生产调用点改回 `auditManifestConcurrencyFence`（只审计、不消费的那个），那个函数依然有牙、
    // 上一条 suite 依然全绿，而真围栏已经不再经过它。
    // 「抽取一层，接缝就往外挪一层」—— 这已经是同一个病的第三轮，所以这一轮把**接线本身**也钉住。
    //
    // ## 为什么只读**一段**，不读整份文件
    // 第一版写的是「把整份文件喂 `strippingComments`，断言 `unmodeledConstructs` 为空」。**实测当场
    // 红**，而且红得对：本文件前半段是**扫描器自己的回归网**，它必须大量使用 raw string（`#"""…"""#`）
    // 来喂扫描器 —— 而扫描器不建模 raw string，于是整份文件永远被记进 `unmodeledConstructs`。
    // 那条前提**不可满足**，不是「今天碰巧不满足」。
    // 所以改成按哨兵抽出**生产调用点那一段**再喂扫描器：那一段由这条断言自己守着不许出现 raw
    // string（真出现了 ⇒ unmodeled 非空 ⇒ 红），而回归网那半边爱写多少 raw string 写多少。
    //
    // ## 为什么这一段够了（不需要再数「消费边全文件几处」）
    // 真正要守的不变式拆成两半，两半各有各的证据：
    //  · 「`enforce…` 会把每条 finding 变成红」—— 上一条 suite **行为**上钉死（观测真 `failures`）。
    //  · 「生产路径确实经过 `enforce…`」—— 这条 suite **源码**上钉死。
    // 合起来才是「生产路径上的 finding 真的会变成红」。而「有人在别处另写一圈阉割循环」不构成逃逸：
    // 只要生产调用点还接在 `enforce…` 上，那一圈就是多余代码，围栏照样开火。
    // 至于「把 `enforce…` 那一行整段删掉」——它的返回值 `audit` 被下面的覆盖范围断言用着，删了**编译
    // 不过**。这一条由编译器守，不需要断言。
    //
    // ## 判据读的是**剥注释 + 清空字符串**之后的源码，两侧都不是随便选的
    // · 剥注释：不剥的话，上面这段**谈论**接线形状的散文自己就满足了断言 —— 「用谈论代码的散文给
    //   代码背书」，本文件开头记着的那个病。
    // · 清空字符串：下面这些断言把要找的形状**写成字符串字面量**，不清空的话它们在 `code` 里原样
    //   出现、自己满足自己（`guard-must-not-read-guarded-output` 的镜像）。
    // 空白全部挤掉再比 —— 换行/缩进由 swift-format 说了算，把形状钉在格式上是给自己埋定时假红。
    suite("绊线（T3）围栏消费边接线自证：生产调用点必须接在会消费的那个入口上") {
        let selfPath = "gui/Tests/ClaudioGUICoreTests/SourceScannerSuite.swift"
        guard let region = fenceCallSiteRegion(of: selfPath) else {
            expect(
                false,
                "抽不出生产调用点那一段（\(selfPath) 里的 `\(fenceCallSiteBegin)` / "
                    + "`\(fenceCallSiteEnd)` 哨兵）—— 哨兵被删了/改了，下面每一条接线断言都会在空串上"
                    + "恒真。把哨兵放回围栏调用点两侧。")
            return
        }
        let regionScanned = strippingComments(region)
        let squashed = regionScanned.codeWithoutStringLiterals.filter { !$0.isWhitespace }

        // ── 观测器的正向对照。缺了这几条，一个抽到空串 / 抽错位置的观测器会让下面每条恒真。
        //    （memory 里那条：观测器必须自带正向对照，否则它静默失灵就把每条断言变成恒真。）
        expect(
            regionScanned.unmodeledConstructs.isEmpty,
            "扫描器读不懂生产调用点这一段（\(regionScanned.unmodeledConstructs)）—— 下面那条**负向**"
                + "断言（『不许出现 audit…』）会在一份不可信的 code 上跑，形同虚设。\n"
                + "  最常见的成因：有人往两个哨兵之间加了 raw string（扫描器不建模它）。挪出去，"
                + "或者改写成带转义的普通串。")
        expect(
            squashed.count > 40,
            "抽出来的这一段只剩 \(squashed.count) 个非空白字符 —— 哨兵之间是空的/几乎是空的，观测器"
                + "读到的不是它以为的东西，下面每条断言都在测空气。")

        // ── 【关键腿 0】哨兵**各自只能有一处**（红队实测的劫持手法）。
        //    `fenceCallSiteRegion` 用的是 `firstIndex` —— 在真调用点**之前**插一对诱饵哨兵（写在
        //    块注释里或多行串里都行，抽取跑在**原始文本**上，与真哨兵逐字节无从区分），观测器就会
        //    去读那段诱饵，真调用点降为第二处、永远不被检查。认不出 ⇒ 红。
        let sentinelLines = fenceCallSiteSentinelCounts(of: selfPath)
        expect(
            sentinelLines.begin == 1 && sentinelLines.end == 1,
            "调用点哨兵不是各一处（begin \(sentinelLines.begin) 处 / end \(sentinelLines.end) 处，"
                + "应当各 1 处）—— 抽取取的是**最先**命中的那一对，多出来的一对（哪怕写在块注释或"
                + "多行字符串里）会把观测器引去读一段诱饵，而真调用点从此不受任何检查。")

        // ── 【关键腿 1】哨兵之间**逐字全等**于预期的那一句调用。
        //    ⚠️ 这里是**全等**，不是 `contains`。上一稿用的是
        //    `squashed.contains("enforceManifestConcurrencyFence(under:scanRootURL")` —— 那是个**前缀
        //    子串**，实参表后面再挂多少个实参它都看不见。红队实测：给 enforce 加一个
        //    `report: Bool = true`、生产调用点传 `report: false`，围栏在生产路径上被永久关掉，而这条
        //    断言照过。默认实参就是可改语义，子串匹配对它是瞎的。
        //    全等的代价是「改调用点必须同时改这里」——那正是要的：这一行是安全边界，它该难改。
        let expectedCall =
            "letaudit=enforceManifestConcurrencyFence(under:scanRootURL,pathPrefix:fencePathPrefix)"
        expect(
            squashed == expectedCall,
            "生产调用点不是预期的那一句。围栏的整条判定 + 消费都在 `enforceManifestConcurrencyFence`"
                + "里，这两行哨兵之间只允许有那**一句**调用，多一个实参都不行 —— 默认实参是可改语义，"
                + "多传一个 `readEntryKind:` 桩或一个 `report: false` 就能让围栏在生产路径上静默失效。\n"
                + "  期望（挤掉空白后）：\(expectedCall)\n"
                + "  实得：\(squashed)\n"
                + "  真要改这一行，连这条断言一起改，并回头想清楚新实参会不会把围栏关掉。")

        // ⚠️ 上一稿这里还有一条「腿 2」：`!squashed.contains("auditManifestConcurrencyFence(")`。
        // 腿 1 升成**全等**之后它已被完全蕴含（全等就不可能再含别的东西），留着是一条永远不会独立
        // 开火的死断言 —— 而死断言会让人误以为这里的覆盖比实际更宽。删掉。
    }

    // @MainActor 那条腿的**判定精度**自证有牙。
    //
    // 这条 suite 整条来自 `/codex review 15ce131` 之后的红队（27 条提案 / 13 条扛过证伪）。它钉的五件
    // 事此前**一条 fixture 都没有** —— 也就是说 @MainActor 这条腿当时只对「一个文件里有且只有一个
    // 标准 `public func`、且不含任何字符串」这一种形状有过证据，而真实写者文件三条都不满足。
    // ## ⚠️ 为什么这条 suite 要对**每一个实参向量**各跑一遍（`/codex review abbf48e` 的 P1，实测坐实）
    // 上一版整条 suite 只调 `auditManifestConcurrencyFence(under: scanned)` —— 走**默认实参**
    // （`pathPrefix` 空串）。而生产传的是 `pathPrefix: fencePathPrefix`。实测：给下面那条
    // 「认不出的声明」判定加一个 `where pathPrefix.isEmpty`，**2179 条断言一条都不红**，而围栏在
    // 真仓库上整条死掉。这是「同一个函数 ≠ 同一个**实参向量**」这个病的第十次复发，且这一次长在
    // 上一轮**为了修它而新加的那条腿**上：上一轮把消费边自证做成了双向量，却没把新加的判定腿接
    // 上去（那条 suite 的 fixture 全是 `public func`，新腿在两个向量下都产出零条）。
    //
    // ## ⚠️ 这条 suite 关掉的是**哪一根轴**，别读大了（教条：措辞不许比覆盖范围大）
    // 关掉的只有「谓词**单独读 `pathPrefix` 这一个变量**」那一类寄生。**仍然开着**三根轴：
    //  ① `pathPrefix` 与 `subpath` **联合**读取 —— fixture 迁进 `ClaudioGUICore/` / `ClaudioGUI/`
    //     之后收窄到「谓词得认得出生产的**目录名**」这一层，**没有清零**（例：
    //     `where !relative.contains("ManifestBinding")` 仍然逃得掉）。
    //  ② `root` 轴 —— 自证恒为 `/var/folders/…/UUID`，生产恒为真仓库，
    //     `where root.path.hasPrefix("/Users")` 仍然逃得掉。这根轴结构上闭不上。
    //  ③ **被调函数**轴 —— 这条 suite 调 `auditManifestConcurrencyFence`（只审计），生产调
    //     `enforceManifestConcurrencyFence`（审计 + 消费）。那一根由「消费边自证」与「消费边接线
    //     自证」两条 suite 分别兜住，**不是**这里。别把这条 suite 读成「跑了生产路径」。
    //  另：`readEntryKind` 两侧都走默认实参而恰好一致，那是巧合不是设计。
    suite("绊线（T3）@MainActor 腿判定精度自证有牙：字符串不算注解、重载不互相洗白、多写者逐个查、非 public func 形状要喊（含生产实参向量）") {
        // ⚠️ 标签说「空前缀」不说「默认」是**故意**的：这一项**显式**传 `""`，不是省略实参。它与当前
        //    默认实参同值（`pathPrefix: String = ""`），但「同值」不是「同一条路径」。措辞按它实际
        //    举证的东西写。（同一段说明见消费边那条 suite。）
        let fenceProofVectors: [(label: String, pathPrefix: String)] = [
            ("空前缀向量（显式传 \"\"）", ""),
            ("生产向量（pathPrefix 与真围栏逐字相同）", fencePathPrefix),
        ]
        // G1 常量形状守卫。**诚实标注：它只挡常量被改坏，自己不证明任何东西。**
        //    `!= fenceScanRelativeRoot` 那一项不是凑数：只写 `!isEmpty` 的话，把 `fencePathPrefix`
        //    改成少一个斜杠的 `fenceScanRelativeRoot` 这条变异会**存活**。
        expect(
            !fencePathPrefix.isEmpty && fencePathPrefix != fenceScanRelativeRoot,
            "`fencePathPrefix`（\"\(fencePathPrefix)\"）不是一个真前缀 —— 它若是空串，下面两个"
                + "「向量」就逐字相同，整条参数化退化成把同一件事跑两遍，而任何 "
                + "`where pathPrefix.isEmpty` 的寄生谓词照样穿过去。")
        // G2 互异。**从被 `for` 遍历的那同一个数组自己算**，不是拿两个字面量比 —— 后者对
        //    「数组被改成两项相同」恒真。
        expect(
            Set(fenceProofVectors.map(\.pathPrefix)).count == fenceProofVectors.count,
            "实参向量清单里有重复的 pathPrefix（\(fenceProofVectors.map(\.pathPrefix))）—— 有人把生产"
                + "向量那一项改成了空串，两圈跑的是同一件事，参数化形同虚设。")
        // G3 生产用的那个值真的在清单里。（「生产**调用点**确实传它」是另一件事，由哨兵区块
        //    逐字全等那条 suite 兜住；这里只保证自证喂过它。）
        expect(
            fenceProofVectors.contains { $0.pathPrefix == fencePathPrefix },
            "实参向量清单里没有生产用的那个 pathPrefix（\"\(fencePathPrefix)\"）—— 自证从没在生产"
                + "实参下跑过这条判定。清单：\(fenceProofVectors.map(\.pathPrefix))")

        // G3b 清单不许被砍。（`/codex review ae494b1` P2-1。）
        //    ⚠️ 这一条**推翻了**上一版写在这儿的一句话。原话是：「**禁止**改写成
        //    `expect(fenceProofVectors.count == 2, …)` 那种清单断言：它对
        //    `for vector in fenceProofVectors.prefix(1)` 恒真。」——那句话本身没说错，错在它把「清单
        //    断言」与「执行见证」读成了**二选一**，于是两条都只留了一条，而它们各自的盲区**不相交**：
        //      · `for … in fenceProofVectors.prefix(1)` ⇒ G4 红，清单断言恒真（清单还是两项）
        //      · 字面量数组砍成一项                      ⇒ 清单断言红，G4 恒真（`[x] == [x]`，跑满了）
        //    两条都要。砍成一项那条变异在上一版是**五条守卫零响应**的（G1 不引用数组、G2 `1 == 1`、
        //    G3 找得到生产值、G4 自比、W1 只见证那一圈 —— 数一遍就是这五条，别写成六条），而它恰恰
        //    重开了上一轮 P1 治的那个洞：空前缀那根轴没人举证，`where pathPrefix.isEmpty` 这类寄生
        //    谓词全身而过。
        //
        //    ⚠️ 与消费边那条同款：这里**只**断言「空前缀在清单里」，是 G3 的镜像，**不**断言
        //    `count == 2`。理由写在消费边那条的注释里（`count == N` 只惩罚加向量这种覆盖改进，
        //    且开火时诊断字面为假，把维护者推向删掉整条 expect）。
        expect(
            fenceProofVectors.contains { $0.pathPrefix.isEmpty },
            "实参向量清单里没有空前缀向量（实得 \(fenceProofVectors.map(\.pathPrefix))）—— 空前缀那根轴"
                + "没有被举证。少了它，任何只在非空 pathPrefix 下才成立的寄生谓词（`where "
                + "pathPrefix.isEmpty` 之流）都能穿过整条判定自证，而 G1..G4 一条都不会喊（它们各自都对"
                + "「清单缩水」恒真）。加向量不受这条限制，删这一根轴才会红。")

        // G4 的证据收集。只有「真的跑过几圈」才挡得住 `.prefix` / `.filter` / 循环体里提前 return
        //    这三类变异 —— 上面那条 G3b 挡的是另一侧（清单自己缩水），两条互补。
        var executedVectors: [String] = []
        for vector in fenceProofVectors {
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

                // ⑦ **`/codex review 48cbc07` 的 P1 之一，逐字的攻击形状。** 关键在于这个文件里
                //    **已经有一个**枚举得到、且带 @MainActor 的干净写者 —— 于是 `exported.isEmpty`
                //    为假、那条兜底不开火；而 `missingMainActorIsolation` 只遍历**枚举得到的**名字，
                //    `sneakyWriter` 根本不在名单里，也不开火。上一版对这个文件产出**零条 finding**。
                //    ① 那个 fixture 抓不到它：那是「一个 public func 都没有」，这里有。
                writeFixture(
                    """
                    @MainActor public func cleanWriter() { mutateManifestJSON() }
                    func sneakyWriter() { mutateManifestJSON() }
                    """,
                    to: scanned.appendingPathComponent("ClaudioGUICore/ImplicitInternal.swift"))

                // ⑧ 同一个洞的另外两种修饰符。`package` / `open` 都不是 `public` 打头，
                //    上一版同样是零条 finding（`exportedPublicFuncNames` 头上那段自己写着「不在内」，
                //    但「不在内」当时的含义是**静默跳过**，不是红）。
                writeFixture(
                    """
                    @MainActor public func packageClean() { mutateManifestJSON() }
                    package func packageWriter() { mutateManifestJSON() }
                    """,
                    to: scanned.appendingPathComponent("PackageWriter.swift"))
                writeFixture(
                    """
                    @MainActor public func openClean() { mutateManifestJSON() }
                    open func openWriter() { mutateManifestJSON() }
                    """,
                    to: scanned.appendingPathComponent("ClaudioGUI/OpenWriter.swift"))

                // ⑧b **`public extension` 里省略修饰符的成员。** 这一条是照着**我自己那句 finding
                //    措辞**补的：诊断里逐字列了「`public extension` 里省略修饰符的成员」，而 ⑦⑧ 三个
                //    fixture 一个都没覆盖它 —— 措辞比覆盖范围大，memory 里记着的那条老病，这一轮长在
                //    本轮**自己的诊断文案**上。纸上推理说「`public` 与 `func` 被 `{` 隔开 ⇒ 正则不匹配
                //    ⇒ 落进认不出那一格」，但那条 doc comment 上一轮就是这么推的、也是这么错的，
                //    所以这里**实测**一遍。
                writeFixture(
                    """
                    public extension ManifestHelpers {
                        func extensionWriter() { mutateManifestJSON() }
                    }
                    """,
                    to: scanned.appendingPathComponent("PublicExtension.swift"))

                // ⑩ **名字解析不出来的两种声明**（红队实测的两条 fatal，都是可编译真代码）。
                //    两者都不被 `allFuncDeclarationNames` 数到、也不被两台识别器数到 —— 三边同时失明
                //    ⇒ 差额恒 0 ⇒ ⑦⑧ 那条判定静默全绿。逮它们的是**关键字计数**那条。
                writeFixture(
                    """
                    @MainActor public func btClean() { _ = 1 }
                    func `default`() { mutateManifestJSON() }
                    """,
                    to: scanned.appendingPathComponent("Backtick.swift"))
                writeFixture(
                    """
                    @MainActor public func opClean() { _ = 1 }
                    public struct K: Equatable {
                        public static func == (l: K, r: K) -> Bool { mutateManifestJSON(); return true }
                    }
                    """,
                    to: scanned.appendingPathComponent("Operator.swift"))

                // ⑪ **块注释是分词符。** `public/* MARK */func` 剥完若变成 `publicfunc`，`\bfunc` 的
                //    词边界就没了，三边一起失明。修在 `strippingComments`（补一个空格），这条钉住它：
                //    还原分词之后 `glued` 是个没带 @MainActor 的导出写者，@MainActor 腿必须对它开火。
                writeFixture(
                    "@MainActor public func cmClean() { _ = 1 }\npublic/* MARK */func glued() { mutateManifestJSON() }",
                    to: scanned.appendingPathComponent("CommentGlue.swift"))

                // ⑫ **目录布局轴的正向对照。** ⑦⑧⑧b⑩⑪ 全在 `scanned/` 平铺，于是一条
                //    `where !relative.contains("/")` 的寄生谓词能让这条腿只在平目录下开火、对**子目录**
                //    静默失效，而上面每一条断言照样全绿 —— memory `fence-polarity-and-self-recurrence`
                //    记着的「平目录下递归=非递归全绿」，同一个病换到判定腿上。所以这里**自造嵌套输入**。
                writeFixture(
                    """
                    @MainActor public func nestClean() { mutateManifestJSON() }
                    func nestedSneaky() { mutateManifestJSON() }
                    """,
                    to: scanned.appendingPathComponent("Deep/Nested/NestedInternal.swift"))

                // ⑨ **负控，而且是照着真仓库 `ManifestBinding.swift` 的形状抄的**：三个
                //    `@MainActor public func` + 一个 `private func` 辅助。这条钉的是
                //    `fileLocalFuncNames` 那一格白名单不许消失 —— 少了它，真仓库那个
                //    `resolveUserPackDirectory` 当场假红，而假红的守卫会被下一个人删掉。
                //    ⚠️ 这条负控**不能**只靠真仓库全绿来背书：真仓库跑的是生产根，这条 suite 跑的是
                //    临时树，两者走的是同一个判据但不同的输入轴（`root` 那根轴的老问题）。
                writeFixture(
                    """
                    @MainActor public func realShapeOne() { mutateManifestJSON() }
                    @MainActor public func realShapeTwo() { _ = 1 }
                    private func realShapeHelper() -> Int { 1 }
                    """,
                    to: scanned.appendingPathComponent("RealShape.swift"))

                // ⑬ **词素同步见证**（`/codex review abbf48e` 那一轮红队的 fatal 之一）。裸 regex 字面量
                //    是唯一能把一个反引号**贴到** `func` 左边的合法通道，而 `strippingComments` 既不建模
                //    它、也不把它记进 `unmodeledConstructs`（实测 `unmodeled=[]`）。于是它成了检验「关键字
                //    计数与名字解析是不是同一份词素」的试纸：
                //      · 两侧共用（现状）⇒ 两边都不数它 ⇒ 差额 0 ⇒ 这个文件零 finding。
                //      · 只给关键字那一台加 lookbehind ⇒ 名字 +1 / 关键字 +0 ⇒ **负差额 −1**，它会去
                //        抵消一个真实漏网声明的 +1，把「认不出的声明」那条判定静默归零。
                //      · 两侧都不排除反引号（回到旧版）⇒ 正差额 +1 ⇒ 报一个根本不存在的 `mutate`（假红）。
                //    `swiftc -swift-version 6 -typecheck` 实测 rc=0，是真代码不是畸形输入。
                writeFixture(
                    """
                    @MainActor public func lexClean() {
                        let lexProbe = /`func mutate/
                        _ = lexProbe
                        mutateManifestJSON()
                    }
                    """,
                    to: scanned.appendingPathComponent("LexemeSync.swift"))

                // ⑭ **`func` 与反引号之间没有空格**（swiftc rc=0，合法）。这条钉死「只许 lookbehind、
                //    绝不许再加 lookahead」那个决策：加了 lookahead，这个声明会**同时**从关键字计数与
                //    名字解析里消失，两边一起失明、差额恒 0、静默绿。
                //    ⚠️ ⑩ 那个**有空格**的 `Backtick.swift` 对这一手**零分辨力**（实测：加不加 lookahead
                //    它都红）。必须是无空格这一条才分得开。
                writeFixture(
                    """
                    @MainActor public func gluedClean() { _ = 1 }
                    func`default`() { mutateManifestJSON() }
                    """,
                    to: scanned.appendingPathComponent("GluedBacktick.swift"))

                // ⑮ **反引号转义标识符不是声明**（`let \\`func\\` = 0`，swiftc rc=0）。这条是 ⑭ 的反面：
                //    它必须**不**红。缺了它，关键字词素退回 `\\bfunc\\b` 这条变异不会被任何断言逮到，
                //    而那正是今天真实存在的一条假红。
                writeFixture(
                    """
                    @MainActor public func btIdentClean() { mutateManifestJSON() }
                    let `func` = 0
                    """,
                    to: scanned.appendingPathComponent("BacktickIdent.swift"))

                // ⑯ **`private import` 让一个裸 internal 写者隐身**（本轮红队挖出的现存 fail-open，
                //    `/codex review abbf48e` 不在提案里的那条）。`private import Foundation` 整条声明
                //    零标点，旧版那个 `[\\sA-Za-z@_]*` 的修饰符 run 一路跨过去，把下一个**隐式 internal**
                //    的写者当成「private 的」认领走 —— 实测四条腿一条都不响。
                //    详见 ``publicFuncModifierRun`` 头上那段（含「按位置去重修不好它」的实测反证）。
                //
                //    ⚠️ **这三行的顺序是承重的，别按「读起来更顺」重排**（台账第一轮实测逼出来的）：
                //    漏网写者必须紧跟在 `private import` 后面、干净写者排在**最后**。第一稿把干净写者
                //    夹在中间，于是贪婪的修饰符 run 认领的是**干净那个**（`-1`）而漏网那个照样 `+1` ——
                //    两个数落在**不同的名字**上、压根不抵消，于是新旧 run 都报，这条 fixture 对
                //    「run 退回任意字母词」那条变异**零分辨力**（M4-1 当场存活）。排成现在这样，旧 run 下
                //    `unrecognized=[]`、`exported.isEmpty` 为假（干净写者顶着）、隔离检查也满足 ——
                //    **整个文件零 finding**，这才是那条 fail-open 的真形状。
                //
                //    ⚠️⚠️ 上面那段此前**只是散文**。实测（`/codex review 899302a` 的 P1-2）：把干净写者
                //    挪到中间，**2269 条断言一条都不红**。所以下面把它做成可执行的 —— 但**不是**去钉
                //    「三行的顺序」这个代理量：红队打回了那一版，顺序原样不动、把首行改成
                //    `private import os.log`（SE-0409 合法，且这些 fixture 只被当文本扫、从不编译），
                //    旧 run 撞上 `.` 自己就断在那儿、`privImportSneaky` 新旧两版都被报 —— 分辨力同样
                //    归零，而顺序断言全绿。承重的是**两条**（零标点 + 顺序），钉一条就是措辞比覆盖大。
                //    所以直接钉**威胁本身**：把旧 run 就地重建一遍，要求它认领的**恰好是**漏网那个名字。
                //    一条就盖住重排、首行加标点、中间插 `private func`、`private` 换 `internal` 四种；
                //    正则抄漂了只会红、不会绿（fail-closed）。词素复用 `funcKeywordLexeme` 那一份。
                //    ⚠️ 这只证了差分的**一半**（「旧 run 会把它吞掉」）。另一半「新 run 必须报它」由下面
                //    ⑯ 的判定钉。两条合起来才是分辨力，缺一条都证不出。
                let privImportLiteral = """
                    private import Foundation
                    func privImportSneaky(_ n: Int) { mutateManifestJSON() }
                    @MainActor public func privImportClean() { mutateManifestJSON() }
                    """
                //    ⚠️ ⑯ 的自证**不在这里**，在下面那次 `auditManifestConcurrencyFence` 调用的正后方
                //    （搜「⑯ 自证」）。这里只落盘。为什么隔那么远：自证要读的是**生产扫描器实际吃进去的
                //    那份字节**，而生产是在下面 audit 那一刻才去枚举、读盘的。红队实测坐实两条 TOCTOU 绕过
                //    （`/codex review 3598e5e` 之后第二轮，两个独立视角各自撞到）：只要自证在写盘后**立刻**
                //    读、而 audit 在几百行之后才扫，中间任何一次 `writeFixture(…, to: …/PrivateImport.swift)`
                //    （R3：伪装成 ⑯b 变体的复制粘贴，把整份覆盖成没有干净写者的两行），或把这里的落盘目标
                //    改指扫描根外、由另一次 writeFixture 顶替 scanned 里那份（R4）—— 都能让「自证读到的三行」
                //    与「生产扫到的两行」分家：六条自证全绿、下游负控恒真，`✓ all 2359`。把自证挪到 audit
                //    正后方、且从 scanned 树里回读那唯一一份，才让「我证的字节」与「生产扫的字节」之间没有
                //    写者窗口。
                //    ⚠️ 不留 `privImportURL` 这个中间变量：留着它，「改这一行指向别处」就成了可改语义的接缝
                //    （R4 的入口）。落盘目标直接内联，改它就等于改真正被扫的那份、连正控一起带红。
                writeFixture(
                    privImportLiteral, to: scanned.appendingPathComponent("PrivateImport.swift"))

                // ⑰ **``unrecognizedFuncDeclarations`` 那条诊断逐字列出的形状，列了几种就得有几条
                //    fixture**（教条：措辞不许比覆盖
                //    范围大 —— 本文件已经栽过一次，见 ⑧b；`ae494b1` 那一轮又栽了一次，见下面三条
                //    `private enum` / `final class` / `actor`）。这七条**故意保持红**：红队实测过把它们
                //    白名单化的方案（认 `private extension` 块里的成员），结论是**不能做** —— 那需要一台
                //    括号匹配器，而一个裸 regex 字面量 `/^\\s*\\{/`（不记 unmodeled、括号配平为 0）就能
                //    把它带偏，吞掉整块 `public extension` 里的非 @MainActor 写者。教条「放宽白名单必须
                //    证明没有 masking 路径」在这里满足不了，所以保持红、把红修得**可执行**。
                writeFixture(
                    """
                    @MainActor public func peClean() { mutateManifestJSON() }
                    private extension ManifestHelpers { func peHelper() { mutateManifestJSON() } }
                    """,
                    to: scanned.appendingPathComponent("PrivateExtension.swift"))
                writeFixture(
                    """
                    @MainActor public func fpClean() { mutateManifestJSON() }
                    fileprivate extension ManifestHelpers { func fpHelper() { mutateManifestJSON() } }
                    """,
                    to: scanned.appendingPathComponent("FileprivateExtension.swift"))
                writeFixture(
                    """
                    @MainActor public func psClean() { mutateManifestJSON() }
                    private struct PSBatch { func psApply() { mutateManifestJSON() } }
                    """,
                    to: scanned.appendingPathComponent("PrivateStruct.swift"))
                // ⚠️ 下面三条是 `/codex review ae494b1` P2-2 补的。``unrecognizedFuncDeclarations``
                //    那条诊断逐字写的是
                //    「`private struct` / `enum` / `final class` / `actor` 的无修饰符成员」—— **四种**，
                //    而上一版只钉了 `struct` 一种。措辞比覆盖范围大，本文件治了十次的同一个病，这次
                //    长在「专门用来禁止这个病」的那张断言表自己身上。
                //
                //    这三种的读模型轴与 `private struct` **看着**同源（成员 `func` 紧贴的修饰符 run 都是
                //    空，`private` / `final` / `actor` 全长在外层类型声明行上，词法识别器跨不过那个 `{`），
                //    但「看着同源」正是这条教条要禁的推理 —— 所以造 fixture 实测，不写纸上论证。
                writeFixture(
                    """
                    @MainActor public func peEnumClean() { mutateManifestJSON() }
                    private enum PEBatch { func peEnumApply() { mutateManifestJSON() } }
                    """,
                    to: scanned.appendingPathComponent("PrivateEnum.swift"))
                writeFixture(
                    """
                    @MainActor public func pfcClean() { mutateManifestJSON() }
                    private final class PFCBatch { func pfcApply() { mutateManifestJSON() } }
                    """,
                    to: scanned.appendingPathComponent("PrivateFinalClass.swift"))
                writeFixture(
                    """
                    @MainActor public func paClean() { mutateManifestJSON() }
                    private actor PABatch { func paApply() { mutateManifestJSON() } }
                    """,
                    to: scanned.appendingPathComponent("PrivateActor.swift"))
                writeFixture(
                    """
                    @MainActor public func lnOuter() {
                        func lnInner() { mutateManifestJSON() }
                        lnInner()
                    }
                    """,
                    to: scanned.appendingPathComponent("LocalNestedFunc.swift"))

                let audit = auditManifestConcurrencyFence(
                    under: scanned, pathPrefix: vector.pathPrefix)

                // ⑯ 自证。读的是**生产 audit 这一刻刚扫过的那份**磁盘字节 —— 不是写盘后立刻读的、更不是
                //    源码字面量（见上面写盘处那段 TOCTOU 说明）。红队实测坐实的两条绕过都靠「自证读的字节 ≠
                //    生产扫的字节」：R3 在 audit 前把 `PrivateImport.swift` 覆盖成没有干净写者的两行；R4 把
                //    落盘改指扫描根外、由另一次 writeFixture 往 scanned 里塞两行顶替品。所以先证「scanned 树
                //    里那份唯一」，再从那唯一一份回读、在它上面验形状 —— 它与紧邻的这次 audit 之间没有写者。
                let privImportOnDiskURLs: [URL] = {
                    guard
                        let enumerator = FileManager.default.enumerator(
                            at: scanned, includingPropertiesForKeys: nil)
                    else { return [] }
                    return
                        enumerator
                        .compactMap { $0 as? URL }
                        .filter { $0.lastPathComponent == "PrivateImport.swift" }
                }()
                expect(
                    privImportOnDiskURLs.count == 1,
                    "【向量：\(vector.label)】scanned 树里叫 `PrivateImport.swift` 的文件不是恰好一份（实得 "
                        + "\(privImportOnDiskURLs.count) 份）—— ⑯ 的自证要在「生产实际扫描的那一份」上验形状。"
                        + "多一份就分不清验的是哪一份、少一份说明它压根没落进扫描树。红队 R4：把 ⑯ 落盘改指"
                        + "扫描根外、再由另一次 `writeFixture` 往 scanned 塞一份没有干净写者的两行版 —— 两份就"
                        + "是这么来的。实得：\(privImportOnDiskURLs.map(\.lastPathComponent))")
                let privImportOnDisk =
                    privImportOnDiskURLs.first.flatMap {
                        try? String(contentsOf: $0, encoding: .utf8)
                    }
                    ?? ""
                expect(
                    !privImportOnDisk.isEmpty,
                    "【向量：\(vector.label)】⑯ 生产扫的那份 `PrivateImport.swift` 一个字节都读不回来 —— 下面"
                        + "每一条自证都会跑在空串上，而生产也扫不到内容：⑯ 的正控与负控双双对空集恒真。")
                //    旧 run 就地重建（M4-1 分辨力）—— 跑在生产扫的那份字节上。
                let legacyWideRun = "[\\sA-Za-z@_]*"
                let legacyClaims: [String] = {
                    let pattern =
                        "\\b(?:fileprivate|private)\\b\(legacyWideRun)\(funcKeywordLexeme)"
                        + "\\s+([A-Za-z_][A-Za-z0-9_]*)"
                    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
                    let text = privImportOnDisk as NSString
                    return
                        regex
                        .matches(
                            in: privImportOnDisk,
                            range: NSRange(location: 0, length: text.length)
                        )
                        .map { text.substring(with: $0.range(at: 1)) }
                }()
                expect(
                    legacyClaims == ["privImportSneaky"],
                    "⑯ 的 fixture 对 M4-1（修饰符 run 退回任意字母词）失去分辨力了：就地重建的旧 run "
                        + "认领的是 \(legacyClaims)，要求恰好是 [\"privImportSneaky\"]。这条 fixture 的全部"
                        + "价值就在于「旧 run 跨过零标点的 `private import` 那行、把下一个隐式 internal "
                        + "写者当成 private 的认领走」。认领到别的名字（干净写者被挪到了中间）、或什么都"
                        + "认领不到（首行出现 `.` / `;` / `(` 这类标点，旧 run 自己断在那儿）—— 两种情况下"
                        + "新旧 run 的产出**逐字相同**，M4-1 当场存活，而下面 ⑯ 那两条判定照样全绿。"
                        + "fixture：\n\(privImportOnDisk)")
                //    ⚠️ 读模型：数「声明」不是数「含子串的行」，且喂 codeWithoutStringLiterals（注释被剥、
                //    字符串内容清空）—— 与生产 `auditManifestConcurrencyFence` 里 `strippingComments(text)`
                //    同一个读模型（`/codex review 3598e5e` P1，实测坐实：读原始文本时把干净写者注释掉，
                //    子串还在、`count == 1` 照样绿，而剥完注释那个声明已经不存在、下游负控当场恒真）。
                //    形状轴只钉「重排」一种（M9，实测全绿、下游兜不住）；另三种（掉 @MainActor / 掉 public /
                //    换 open）下游负控自己会红，不必在这里补。
                let privImportScanned = strippingComments(privImportOnDisk)
                expect(
                    privImportScanned.unmodeledConstructs.isEmpty,
                    "⑯ 的 fixture 里出现了 `strippingComments` 自己都说读不懂的构造："
                        + "\(privImportScanned.unmodeledConstructs) —— 下面那条「干净写者恰好一处」读的"
                        + "就是它剥出来的文本，剥错了，那条断言数的就是别的东西。实测坐实的坏法是**扩展 "
                        + "regex 字面量**（`#/…/#`）：`#` 后面是 `/`，不开字符串模式，里面的字符原样当代码"
                        + "流出去 —— 一个 `#/ … func privImportClean() … /#` 能让下面那条数到 1 而真声明"
                        + "根本不存在，下游负控照样恒真。fixture：\n\(privImportOnDisk)")
                expect(
                    !privImportOnDisk.contains("/"),
                    "⑯ 生产扫的那份 fixture 里出现了 `/` —— 这份 fixture 只该是三行朴素声明，一个斜杠都不该"
                        + "有。禁它是因为**裸** regex 字面量 `/…/` 是 `strippingComments` 既不建模、也**不记 "
                        + "unmodeled** 的那一种（⑬ / ⑰ 两处已实测坐实）：它的内容会原样当代码流进下面那份"
                        + "文本，于是「声明恰好一处」与「逐字形状」两条都能在**一个真声明都不存在**的 fixture "
                        + "上全绿，而下游负控照样恒真。落盘内容：\n\(privImportOnDisk)")
                let privImportCleanDecls =
                    allFuncDeclarationNames(in: privImportScanned.codeWithoutStringLiterals)
                    .filter { $0 == "privImportClean" }
                expect(
                    privImportCleanDecls.count == 1,
                    "⑯ 的 fixture 里 `privImportClean` 的声明不是恰好一处（在**生产扫描器看得见的那份文本**"
                        + "里实得 \(privImportCleanDecls.count) 处）—— 下面那条负控说的是「它**不许**被报」，"
                        + "被守的那个东西一旦不在扫描视野里，负控就恒真、连「收窄修饰符 run 收过头会让 "
                        + "`@MainActor public func` 假红」这条都不再守。删掉、改名、**注释掉**、**塞进字符串"
                        + "字面量**、以及 audit 前把整份覆盖掉，都会走到这里。fixture：\n\(privImportOnDisk)")
                //    形状轴上**唯一**下游兜不住的那一种：修饰符重排（M9，实测全绿）。逐字钉，别放宽成
                //    「含 `@MainActor` 且含 `public`」—— 那个宽形对重排恒真，等于没钉。
                let privImportCleanShape = "@MainActor public func privImportClean("
                expect(
                    privImportScanned.codeWithoutStringLiterals.contains(privImportCleanShape),
                    "⑯ 的 fixture 里那个干净写者不再是 `\(privImportCleanShape)…` 这个逐字形状 —— 下面那条"
                        + "负控点名要守的就是它（「收窄修饰符 run 收过头，`@MainActor public func` 这个真"
                        + "仓库天天在用的形状会当场假红」）。掉 `public` / 掉 `@MainActor` / 换 `open` 三种"
                        + "负控自己会红，那三种用不着这一条；**把两者重排成 `public @MainActor func` 不会**"
                        + " —— 在这条断言存在之前实测：全绿、负控一声不吭，而 fixture 已经不含负控点名的那"
                        + "个形状了。这一条就是为那一种存在的。fixture：\n\(privImportOnDisk)")

                // ── W1 向量穿线见证。**这条是整套参数化的命门。**
                //    下面每一条断言都是 `contains(basename)`，而 `pathPrefix` 只**前缀**在诊断路径上 ——
                //    于是它们对多出来的前缀**完全瞎**：忘了给上面那次调用传 `pathPrefix:`，两个向量会跑出
                //    逐字相同的结果，整套参数化退化成把同一件事跑两遍，而每一条断言照样全绿。
                //    只有这一条看得见。用 `hasPrefix` 不是 `contains`：每条 finding 的第 0 个字符就是
                //    `display(relative)`，所以前缀可判，且两个向量的期望值**互斥**（空串那圈期望
                //    `ClaudioGUICore/…` 打头，生产那圈期望 `gui/Sources/ClaudioGUICore/…` 打头）。
                //    末尾那个空格钉死边界，防止 `ClaudioGUICore/ImplicitInternal.swiftX` 这类误匹配。
                expect(
                    audit.findings.contains {
                        $0.hasPrefix("\(vector.pathPrefix)ClaudioGUICore/ImplicitInternal.swift ")
                    },
                    "【向量：\(vector.label)】诊断路径没有以本向量的 pathPrefix（\"\(vector.pathPrefix)\"）"
                        + "打头 —— 要么 `pathPrefix:` 根本没穿进上面那次 `auditManifestConcurrencyFence` "
                        + "调用（两个向量跑出逐字相同的结果，参数化形同虚设），要么 `display()` 不再拼 "
                        + "pathPrefix。下面每一条断言都是 `contains(basename)`，对前缀完全瞎，只有这条看得见。"
                        + "实际诊断首条：\(audit.findings.first ?? "（空）")")

                expect(
                    audit.findings.contains {
                        $0.contains("NoPublicFunc.swift") && $0.contains("一个 `public func` 都没枚举到")
                    },
                    "一个含原语却枚举不出导出写函数的文件被静默放过了 —— 「每个都得 @MainActor」对它退化"
                        + "成恒真绿。实际诊断：\(audit.findings)")

                // ⑦⑧⑧b 的判定。四个文件、四种形态，逐个钉 —— 只钉一个的话，「只报第一个漏网声明」
                // 那类变异照样全绿（本文件已经被这个形状咬过一次，见 ② 的注释）。
                // ⚠️ 干净写者的名字**逐个显式传进来**，不靠「名字里带 Clean」这种模式匹配：写成
                // `$0.contains("Clean`")` 的话，`cleanWriter`（小写 c）根本匹配不上，那条负控对
                // ImplicitInternal.swift 就是**恒真**的 —— 本轮自己写的断言，第一遍就恒真了一条。
                // ⚠️ `cleanWriter` 为空串的那一行（⑧b）**没有**干净兄弟可比，下面用 `!isEmpty` 显式
                // 跳过，而不是让 `contains("``")` 去当一条永远为真的负控 —— 那是同一个恒真病换个马甲。
                // ⚠️ `path` / `witness` 两列是 `/codex review b0ce657` P1 补的：在它们之前，`modifier`
                // 这一列是**纯散文**，没有任何断言读它 —— 把 `OpenWriter.swift` 的内容 `open func` 换成
                // `package func`，文件名和写者名一字不改，**2269 条断言一条不红**，而 `open` 这根轴已经
                // 从 fixture 集里消失。见 ``expectShapeWitnesses``。
                let nonPrivateShapeTable:
                    [(
                        fixture: String, writer: String, cleanWriter: String, modifier: String,
                        path: String, witness: ShapeWitness
                    )] = [
                        (
                            "ImplicitInternal.swift", "sneakyWriter", "cleanWriter",
                            "不写修饰符（隐式 internal）", "ClaudioGUICore/ImplicitInternal.swift",
                            ShapeWitness(declarator: "func ", indented: false, enclosedBy: nil)
                        ),
                        (
                            "PackageWriter.swift", "packageWriter", "packageClean", "package",
                            "PackageWriter.swift",
                            ShapeWitness(
                                declarator: "package func ", indented: false, enclosedBy: nil)
                        ),
                        (
                            "OpenWriter.swift", "openWriter", "openClean", "open",
                            "ClaudioGUI/OpenWriter.swift",
                            ShapeWitness(declarator: "open func ", indented: false, enclosedBy: nil)
                        ),
                        (
                            "PublicExtension.swift", "extensionWriter", "",
                            "public extension 里省略修饰符的成员", "PublicExtension.swift",
                            ShapeWitness(
                                declarator: "public extension ", indented: false, enclosedBy: nil)
                        ),
                    ]
                expectShapeTableCovers(
                    "⑦⑧⑧b 非私有的认不出形状",
                    rows: nonPrivateShapeTable.map(\.fixture),
                    mustCover: [
                        "ImplicitInternal.swift", "PackageWriter.swift", "OpenWriter.swift",
                        "PublicExtension.swift",
                    ],
                    vectorLabel: vector.label)
                expectShapeWitnesses(
                    "⑦⑧⑧b 非私有的认不出形状",
                    rows: nonPrivateShapeTable.map {
                        (key: $0.fixture, shape: $0.modifier, path: $0.path, witness: $0.witness)
                    },
                    under: scanned,
                    vectorLabel: vector.label)
                for (fixture, writer, cleanWriter, modifier, _, _) in nonPrivateShapeTable {
                    expect(
                        audit.findings.contains {
                            $0.contains(fixture) && $0.contains("`\(writer)`")
                                && $0.contains("声明形态不在识别清单里")
                        },
                        "\(fixture) 里那个 `\(modifier)` 的写者被**静默跳过**了 —— 这个文件里已经有一个"
                            + "枚举得到的干净 public 写者，于是 `exported.isEmpty` 不开火；而逐个查隔离"
                            + "只遍历枚举得到的名字，`\(writer)` 不在名单里也不开火。认不出反而是绿的，"
                            + "围栏极性在这个形状上是反的。实际诊断：\(audit.findings)")
                    // 负控的另一半：干净的那个兄弟**不许**被这条腿连坐。判据若退化成「只要文件里有
                    // 认不出的声明就把每个名字都报一遍」，下面这条当场红。
                    if !cleanWriter.isEmpty {
                        expect(
                            !audit.findings.contains {
                                $0.contains(fixture) && $0.contains("`\(cleanWriter)`")
                                    && $0.contains("声明形态不在识别清单里")
                            },
                            "\(fixture) 里那个枚举得到、带 @MainActor 的干净写者 `\(cleanWriter)` 被误报成"
                                + "「认不出」了（负控）—— 判据退化成了「文件里有漏网的就把每个名字都报一遍」。"
                                + "实际诊断：\(audit.findings)")
                    }
                }

                // ⑩ 的判定：名字解析不出来的声明，由**关键字计数**那条逮住。措辞与另外几条腿逐字不相交。
                // ⚠️ `witness` 这一列同 ⑦⑧⑧b。**别把 `Operator` 那行的 `indented: true` 读成「靠它跟
                // `Backtick` 分开」**（上一稿就是这么写的，红队打掉了）：两者的判别词本就不同形，
                // `indented` 在这里不承重。它真正的作用是配合 `enclosedBy: "public struct "` 钉住
                // 「运算符声明嵌在类型体里」这根轴 —— 而 `Operator` 是同表**唯一**含缩进行的 fixture，
                // 这恰恰让互斥那条在它身上恒真（实测：判别词削成 `""` 仍 2325 全绿），
                // 兜住它的是「非空」那条与 `enclosedBy`，不是互斥。
                let unnamedShapeTable: [(fixture: String, shape: String, witness: ShapeWitness)] = [
                    (
                        "Backtick.swift", "反引号转义标识符 `func `default`()`",
                        ShapeWitness(declarator: "func `", indented: false, enclosedBy: nil)
                    ),
                    (
                        "Operator.swift", "运算符声明 `func == (…)`",
                        ShapeWitness(
                            declarator: "public static func == ", indented: true,
                            enclosedBy: "public struct ")
                    ),
                ]
                expectShapeTableCovers(
                    "⑩ 名字解析不出来的形状",
                    rows: unnamedShapeTable.map(\.fixture),
                    mustCover: ["Backtick.swift", "Operator.swift"],
                    vectorLabel: vector.label)
                expectShapeWitnesses(
                    "⑩ 名字解析不出来的形状",
                    rows: unnamedShapeTable.map {
                        (key: $0.fixture, shape: $0.shape, path: $0.fixture, witness: $0.witness)
                    },
                    under: scanned,
                    vectorLabel: vector.label)
                for (fixture, shape, _) in unnamedShapeTable {
                    expect(
                        audit.findings.contains {
                            $0.contains(fixture) && $0.contains("连名字都") && $0.contains("认不出来")
                        },
                        "\(fixture) 里那个\(shape)被静默放过了 —— 它有 `func` 关键字，但名字不是 "
                            + "`[A-Za-z_]` 打头，于是 `allFuncDeclarationNames`、导出枚举、文件内私有枚举"
                            + "**三边同时**数不到它，差额恒为 0，「认不出的声明」那条判定退化成恒真绿。"
                            + "逮它的必须是关键字计数那条。实际诊断：\(audit.findings)")
                }

                // ⑭ 的判定：**无空格**的反引号声明必须**仍然**红（钉死「只许 lookbehind」那个决策）。
                expect(
                    audit.findings.contains {
                        $0.contains("GluedBacktick.swift") && $0.contains("连名字都")
                            && $0.contains("认不出来")
                    },
                    "【向量：\(vector.label)】`func\\`default\\`()`（`func` 与反引号之间**没有空格**，"
                        + "`swiftc -swift-version 6 -typecheck` 实测 rc=0，是合法 Swift）没被逮住 —— 有人给"
                        + "关键字词素加了 lookahead `(?!\\`)`：那一侧不再数它，而名字解析要 `\\s+` 也数不到"
                        + "它，**两边同时失明、差额恒 0、静默绿**。只许 lookbehind。⑩ 那个**有空格**的 "
                        + "`Backtick.swift` 对这一手零分辨力（实测加不加 lookahead 它都红）。"
                        + "实际诊断：\(audit.findings)")

                // ⑮ 的判定：反引号转义**标识符**不许假红。
                //    ⚠️ 先钉纳入 —— 没纳入的话下面那条否定是对空集的恒真绿。
                expect(
                    audit.enrolledSubpaths.contains("BacktickIdent.swift"),
                    "【向量：\(vector.label)】BacktickIdent.swift 没被纳入 —— fixture 里漏了 "
                        + "`mutateManifestJSON`，下面那条否定断言是对空集的恒真绿。"
                        + "实际纳入：\(audit.enrolledSubpaths)")
                //    ⚠️ 否定**只针对 L3a 那条腿的措辞**，不是笼统的「这个文件一条都不许报」：后者会被
                //    别的腿（比如 @MainActor）顺带满足而变成假红，归因也会串味。
                expect(
                    !audit.findings.contains {
                        $0.contains("BacktickIdent.swift") && $0.contains("连名字都")
                            && $0.contains("认不出来")
                    },
                    "【向量：\(vector.label)】`let \\`func\\` = 0`（反引号转义**标识符**，不是声明，"
                        + "swiftc rc=0）把关键字计数顶高了一格，标尺自查那条腿**假红**了 —— "
                        + "`allFuncDeclarationNames` 数不到它是**对的**，关键字词素必须带 `(?<!\\`)`。"
                        + "假红的守卫会被下一个人删掉。实际诊断：\(audit.findings)")

                // ⑬ 的判定：词素同步。裸 regex 字面量不是声明，一条都不许报。
                expect(
                    audit.enrolledSubpaths.contains("LexemeSync.swift"),
                    "【向量：\(vector.label)】LexemeSync.swift 没被纳入 —— fixture 里漏了 "
                        + "`mutateManifestJSON`，下面那条否定断言是对空集的恒真绿。"
                        + "实际纳入：\(audit.enrolledSubpaths)")
                //    这里用**宽形**否定是对的（负向断言越宽越严），恒真风险已由上面那条纳入见证消掉。
                expect(
                    !audit.findings.contains { $0.contains("LexemeSync.swift") },
                    "【向量：\(vector.label)】一个裸 regex 字面量 `/\\`func mutate/`（合法 Swift，swiftc "
                        + "rc=0；`strippingComments` 既不建模它也不记 unmodeled）被报了。两种坏法各一："
                        + "① 关键字词素与名字解析那一台**漂移**了，regex 里那个 `\\`func` 只被一侧数到，"
                        + "凑出一个**负差额**——它会去抵消真实漏网声明的正差额，把判定静默归零；"
                        + "② 两侧都不排除反引号，凑出正差额而报一个根本不存在的 `mutate`。"
                        + "两处必须共用 `funcKeywordLexeme` 那一份词素。实际诊断：\(audit.findings)")

                // ⑯ 的判定：`private import` 之后的裸 internal 写者必须红（本轮修掉的 fail-open）。
                expect(
                    audit.findings.contains {
                        $0.contains("PrivateImport.swift") && $0.contains("`privImportSneaky`")
                            && $0.contains("声明形态不在识别清单里")
                    },
                    "【向量：\(vector.label)】一个隐式 internal 的裸写者被 `private import` 洗白了 —— "
                        + "`private import Foundation` 整条声明不含任何标点，旧版那个 `[\\sA-Za-z@_]*` 的"
                        + "修饰符 run 一路跨过它，把下一行的写者当成「private 的」认领走，四条腿一条都不响，"
                        + "而它是模块内**任意后台线程都能同步调**的。run 必须只认已知修饰符词（未知词 ⇒ "
                        + "run 断掉 ⇒ 认不出 ⇒ 红）。实际诊断：\(audit.findings)")
                //    负控：同一个文件里那个干净的 public 写者不许被连坐。
                expect(
                    !audit.findings.contains {
                        $0.contains("PrivateImport.swift") && $0.contains("`privImportClean`")
                    },
                    "【向量：\(vector.label)】PrivateImport.swift 里那个带 @MainActor 的干净导出写者 "
                        + "`privImportClean` 被报了（负控）—— 收窄修饰符 run 收过头了，`@MainActor public "
                        + "func` 这个真仓库天天在用的形状会当场假红。实际诊断：\(audit.findings)")

                // ⑰ 的判定：``unrecognizedFuncDeclarations`` 那条诊断**逐字列出**的形状，列了几种
                //    就得有几条 fixture 钉着（教条：措辞
                //    不许比覆盖范围大）。这七条**故意保持红** —— 理由写在 fixture 上方。
                //    ⚠️ 诊断逐字列出的**四种私有类型**（`private struct` / `enum` / `final class` /
                //    `actor`）必须一种不缺地在这张表里各占一行（`ae494b1` 那一版只有 struct 一行，是
                //    `/codex review ae494b1` P2-2 打出来的）。加形状先加 fixture。
                //    ⚠️ **别把上面那句读成「这张表应当恰好四行」**（上一稿逐字写的就是「这里就得有
                //    四行」，而它紧挨着的表当时已经是七行 —— `/codex review b0ce657` P2）：诊断列出
                //    的八种形状分在**两张**表里，非私有的那四种在 ⑦⑧⑧b，这张表装的是四种私有类型 +
                //    两种 private/fileprivate extension + 局部 func，共七行。承重的是「一种都不许
                //    少」，不是行数相等 —— 后者从来就不成立。
                let privateShapeTable:
                    [(fixture: String, member: String, shape: String, witness: ShapeWitness)] = [
                        (
                            "PrivateExtension.swift", "peHelper",
                            "private extension 里省略修饰符的成员",
                            ShapeWitness(
                                declarator: "private extension ", indented: false, enclosedBy: nil)
                        ),
                        (
                            "FileprivateExtension.swift", "fpHelper",
                            "fileprivate extension 里省略修饰符的成员",
                            ShapeWitness(
                                declarator: "fileprivate extension ", indented: false,
                                enclosedBy: nil)
                        ),
                        (
                            "PrivateStruct.swift", "psApply", "private struct 的无修饰符成员",
                            ShapeWitness(
                                declarator: "private struct ", indented: false, enclosedBy: nil)
                        ),
                        (
                            "PrivateEnum.swift", "peEnumApply", "private enum 的无修饰符成员",
                            ShapeWitness(
                                declarator: "private enum ", indented: false, enclosedBy: nil)
                        ),
                        (
                            "PrivateFinalClass.swift", "pfcApply",
                            "private final class 的无修饰符成员",
                            ShapeWitness(
                                declarator: "private final class ", indented: false,
                                enclosedBy: nil)
                        ),
                        (
                            "PrivateActor.swift", "paApply", "private actor 的无修饰符成员",
                            ShapeWitness(
                                declarator: "private actor ", indented: false, enclosedBy: nil)
                        ),
                        (
                            "LocalNestedFunc.swift", "lnInner", "函数体内的局部 func",
                            ShapeWitness(
                                declarator: "func ", indented: true,
                                enclosedBy: "@MainActor public func ")
                        ),
                    ]
                // ``unrecognizedFuncDeclarations`` 那条诊断逐字列出的四种私有类型形状，一种都不许从
                // 表里消失。`ae494b1` 丢掉的正是 Enum / FinalClass / Actor 三种。
                expectShapeTableCovers(
                    "⑰ 私有类型 / extension / 局部 func 形状",
                    rows: privateShapeTable.map(\.fixture),
                    mustCover: [
                        "PrivateExtension.swift",
                        "FileprivateExtension.swift",
                        "PrivateStruct.swift",
                        "PrivateEnum.swift",
                        "PrivateFinalClass.swift",
                        "PrivateActor.swift",
                        "LocalNestedFunc.swift",
                    ],
                    vectorLabel: vector.label)
                expectShapeWitnesses(
                    "⑰ 私有类型 / extension / 局部 func 形状",
                    rows: privateShapeTable.map {
                        (key: $0.fixture, shape: $0.shape, path: $0.fixture, witness: $0.witness)
                    },
                    under: scanned,
                    vectorLabel: vector.label)
                for (fixture, member, shape, _) in privateShapeTable {
                    expect(
                        audit.findings.contains {
                            $0.contains(fixture) && $0.contains("`\(member)`")
                                && $0.contains("声明形态不在识别清单里")
                        },
                        "【向量：\(vector.label)】\(fixture) 里那个「\(shape)」没被报 —— 这是「认不出的声明」"
                            + "那条诊断**逐字列出**的形状之一，措辞列了就必须有 fixture 兜着。"
                            + "⚠️ 这条**故意保持红**：红队实测过把它白名单化的方案（认 `private extension` "
                            + "块里的成员），结论是不能做 —— 那需要一台括号匹配器，而一个裸 regex 字面量"
                            + "（不记 unmodeled、括号自身配平）就能把它带偏、吞掉整块 `public extension` 里的"
                            + "非 @MainActor 写者。要改它，先给「括号嵌套」这根新读模型轴造一条正向对照，"
                            + "别直接删腿。实际诊断：\(audit.findings)")
                }

                // ⑪ 的判定：块注释还原成分词符之后，`glued` 是个没带 @MainActor 的导出写者。
                //    这条**不是**钉「认不出」那条腿 —— 恰恰相反，钉的是它重新变得**认得出**了。
                expect(
                    audit.findings.contains {
                        $0.contains("CommentGlue.swift") && $0.contains("`glued`")
                            && $0.contains("没有 @MainActor 隔离")
                    },
                    "`public/* MARK */func glued()` 剥完粘成了 `publicfunc`，`\\bfunc` 的词边界没了，"
                        + "三边一起失明、差额恒 0、@MainActor 腿也枚举不到它 —— 整个文件零 finding。"
                        + "块注释在 Swift 里是分词符，`strippingComments` 必须补回一个空格。"
                        + "实际诊断：\(audit.findings)")

                // ⑫ 的判定：子目录里的漏网声明必须照样红（目录布局轴的正向对照）。
                expect(
                    audit.findings.contains {
                        $0.contains("Deep/Nested/NestedInternal.swift")
                            && $0.contains("`nestedSneaky`") && $0.contains("声明形态不在识别清单里")
                    },
                    "**子目录**里的漏网声明没被报 —— 这条腿只在平铺目录下开火，一条 "
                        + "`where !relative.contains(\"/\")` 的寄生谓词就能让它对整棵子树静默失效，"
                        + "而其余每一条断言（全在平目录）照样全绿。实际诊断：\(audit.findings)")

                // ⑨ 的判定：真仓库那个形状**一条都不许报**。
                //    ⚠️ 先钉纳入。上一版这里是一条**裸负控** —— fixture 一旦没被纳入（写文件失败、名字
                //    改了、`mutateManifestJSON` 被删），「一条都不许报」对空集恒真，负控静默失效。
                expect(
                    audit.enrolledSubpaths.contains("RealShape.swift"),
                    "【向量：\(vector.label)】RealShape.swift 没被纳入 —— 它是照着真仓库形状抄的负控，"
                        + "没纳入的话下面那条「一条都不许报」是对空集的恒真绿。"
                        + "实际纳入：\(audit.enrolledSubpaths)")
                expect(
                    !audit.findings.contains { $0.contains("RealShape.swift") },
                    "照着真仓库 `ManifestBinding.swift` 抄的形状（`@MainActor public func` ×2 + "
                        + "`private func` 辅助）被报了 —— `fileLocalFuncNames` 那一格白名单没了或者认不出 "
                        + "`private`，真仓库的 `resolveUserPackDirectory` 会当场假红，然后这条绊线会被"
                        + "下一个人删掉。实际诊断：\(audit.findings)")

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

                // 这一圈真的跑到底了。**必须是块的最后一行** —— 中途 return / throw 都会让它落不下。
                executedVectors.append(vector.pathPrefix)
            }
        }
        // G4 执行见证。用 `==` 不用 `Set`：连**顺序**一起钉住。这是唯一挡得住
        //    `for … in fenceProofVectors.prefix(1)`、`.filter { … }`、以及循环体提前退出的那一条。
        expect(
            executedVectors == fenceProofVectors.map(\.pathPrefix),
            "实际跑过的实参向量与清单对不上（跑过 \(executedVectors)，清单 "
                + "\(fenceProofVectors.map(\.pathPrefix))）—— 有人把循环 `.prefix` / `.filter` 掉了，"
                + "或者循环体在某个向量上提前退出了。少跑一圈 = 那个向量下的判定从没被举证过，"
                + "而上面每一条断言都只在**跑过的**那些圈里开火，一条都不会喊。")
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

    // 围栏极性自证有牙之三（`/codex review 36fce57` 的 P1 之四）：**属性读不到**、**判不出是不是
    // symlink**、**判不出是不是正规文件**，三种「无从判定」都得红，而且前两种必须在 `.swift` 后缀
    // 闸门**之前**就定案。
    //
    // ## 为什么这条走注入，而别的极性 suite 不用
    // 这三条腿在真实文件系统上**逼不出来**：`FileManager.enumerator(at:includingPropertiesForKeys:)`
    // 会预取这两个键，枚举循环里那次 `resourceValues` 命中的是缓存。实测四种造法（枚举中途删文件、
    // 父目录 chmod 000、dangling symlink、自指 symlink）**全部返回 OK**，一次都没抛。
    // （脱离枚举器直接读则确实会抛 —— 删掉的文件 NSCocoa 260、000 目录里的文件 257。所以这不是一条
    // 假想的错误码，只是被枚举器的缓存挡住了。假 fixture 会让台账验一个空气，这条不是。）
    //
    // ⚠️ 诚实标注：注入钉的是**分支极性**，不是端到端。别把它读成「真枚举里走过这条路」——
    // 真枚举里（今天）走不到，那正是它非注入不可的原因。
    suite("绊线（T3）围栏极性自证有牙之三：属性读不到 / 判不出类型，两条 fail-closed 分支必须真的开火") {
        withTempDirectory { root in
            let scanned = root.appendingPathComponent("scanned")
            // 一个正常的干净 `.swift` 写者。
            writeFixture(
                "@MainActor public func topWriter() { mutateManifestJSON() }",
                to: scanned.appendingPathComponent("TopWriter.swift"))
            // 一个**没有后缀**的条目 —— 真实世界里目录 symlink 就长这样。上一版的 fail-open 正是
            // 从这里漏的：`try?` 失败 → `== true` 判 false → `.swift` 后缀闸门静默 `continue`。
            // 所以下面两条腿拿**它**当判据，钉的就是「必须排在后缀闸门之前」。
            writeFixture(
                "@MainActor public func linkish() { mutateManifestJSON() }",
                to: scanned.appendingPathComponent("LooksLikeADirLink"))

            // ── 正向对照（必须先跑）：真读取器下这棵树是**干净**的。
            //    缺了它，下面三条「注入失败 ⇒ 有 finding」会在一个本来就恒红的世界里恒真。
            let baseline = auditManifestConcurrencyFence(under: scanned)
            expect(
                baseline.findings.isEmpty,
                "正向对照失败：真读取器下这棵树本该干净 —— 它不干净，下面三条注入断言就可能是被这些"
                    + "既有 finding 满足的，证明不了极性。实际诊断：\(baseline.findings)")
            expect(
                baseline.enumeratedSubpaths == ["TopWriter.swift"],
                "正向对照失败：真读取器下该枚举到且仅枚举到 TopWriter.swift（那个无后缀条目不是 "
                    + ".swift）。实际枚举：\(baseline.enumeratedSubpaths)")

            // ── 【关键腿 1】读取本身失败 ⇒ 红，且在后缀闸门之前。
            let readFails = auditManifestConcurrencyFence(
                under: scanned, readEntryKind: { _ in nil })
            expect(
                readFails.findings.contains {
                    $0.contains("LooksLikeADirLink") && $0.contains("类型属性读不到")
                },
                "属性读不到时，一个**没有后缀**的条目被静默跳过了 —— 这就是 fail-open 的原样：`try?` "
                    + "失败 →『不是 symlink』→ `.swift` 后缀闸门 `continue`。一个目录 symlink 就这样整条"
                    + "穿过去，而 SwiftPM 会跟进去编译里面的写者。这条检查必须排在后缀闸门之前。"
                    + "实际诊断：\(readFails.findings)")
            expect(
                readFails.enumeratedSubpaths.isEmpty,
                "属性读不到却还把条目当成源文件纳入了枚举 —— 判不出类型就不该继续往下判。"
                    + "实际枚举：\(readFails.enumeratedSubpaths)")

            // ── 【关键腿 2】读到了、但 `isSymbolicLink` 是 nil ⇒ 红，同样在后缀闸门之前。
            //    这一条钉的是解包写法：`== true` 会把 nil 悄悄归进「不是 symlink」。
            let symlinkUnknown = auditManifestConcurrencyFence(
                under: scanned,
                readEntryKind: { _ in EntryKind(isSymbolicLink: nil, isRegularFile: true) })
            expect(
                symlinkUnknown.findings.contains {
                    $0.contains("LooksLikeADirLink") && $0.contains("判不出是不是 symlink")
                },
                "`isSymbolicLink` 判不出时被当成了「不是 symlink」（`== true` 那个 nil 分支）——"
                    + "「我判不出」不等于「它不是」。实际诊断：\(symlinkUnknown.findings)")

            // ── 【关键腿 3】`isRegularFile` 判不出 ⇒ 红。这一条在后缀闸门**之后**（非 .swift 不关心），
            //    所以拿真的 `.swift` 文件当判据。上一版这里是 `?? false`，静默排除。
            let regularUnknown = auditManifestConcurrencyFence(
                under: scanned,
                readEntryKind: { _ in EntryKind(isSymbolicLink: false, isRegularFile: nil) })
            expect(
                regularUnknown.findings.contains {
                    $0.contains("TopWriter.swift") && $0.contains("判不出是不是正规文件")
                },
                "`isRegularFile` 判不出时，一个 `.swift` 条目被静默排除了（上一版的 `?? false`）——"
                    + "「我判不出它是什么」绝不等于「它不是源文件」。实际诊断：\(regularUnknown.findings)")

            // ── 负控：注入一个**转发到真实现**的读取器，三条 finding 一条都不许出现。
            //    缺了它，上面三条对一个「恒报」的坏围栏同样成立 —— 那种围栏真文件那侧永远假红，
            //    然后被下一个人整条删掉，洞比现在更大。
            let healthy = auditManifestConcurrencyFence(
                under: scanned, readEntryKind: { url in realEntryKind(url) })
            expect(
                healthy.findings.isEmpty,
                "注入一个转发到真实现的读取器，围栏却报了 finding —— 它在恒报，上面三条极性断言对它"
                    + "同样成立，等于没测。实际诊断：\(healthy.findings)")
            expect(
                healthy.enumeratedSubpaths == baseline.enumeratedSubpaths,
                "转发读取器与默认读取器枚举结果不一致（\(healthy.enumeratedSubpaths) vs "
                    + "\(baseline.enumeratedSubpaths)）—— 注入的 seam 改变了默认行为，上面的注入断言"
                    + "测的就不是生产那条路了。")
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
