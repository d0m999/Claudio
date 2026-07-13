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
}
