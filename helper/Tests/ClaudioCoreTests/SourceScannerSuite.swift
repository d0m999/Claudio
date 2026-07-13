import Foundation

// MARK: - 扫描器**自己**的回归网（`/codex review be332ff` 的 P2）
//
// `LockSeparationSuite`（读 `helper/Sources`）与 `ViewWiringSuite`（读 `gui/Sources`）的兜底全是
// **负向**断言。于是这两套绊线共享同一个致命失效模式：**分析文本里少一段代码，它们只会更绿。**
// 而分析文本由 `strippingComments` 一个函数生产 —— 它是那两套绊线的**单点故障**，此前一条断言
// 都没有（它自己的正确性，靠的是它自己的 doc comment 说它对）。
//
// `be332ff` 意识到了这个洞，却把守卫写成了 `!codeOnly(path).contains("://")` —— 用**那个会截断的
// 函数的输出**去检查「有没有会导致截断的输入」。`://` 自带 `//`，它到达断言之前就已经被剪成
// `https:` 了：**那条守卫恒真**，而它的失败消息自称「真到了非放不可的那天会当场变红」。
//
// 这个 suite 是它的替代品，形状不同：**喂合成输入给扫描器，正向断言它的输出。** 它不可能恒真 ——
// 把 `strippingComments` 换回「第一个 `//` 处无条件截断」，下面**红 6 条**（变异 M1a 实测：
// 行内 URL ×2、转义引号、多行字符串、块注释、raw string 未记账 —— `✗ 6 of 1089`）。
//
// 顺带钉死另一半：注释**必须**被剥掉。`Use.swift` / `SettingsInstaller.swift` 的 doc comment 里
// 白纸黑字写着 `ClaudioPaths/playLockFile`（写的正是「我**不**用这把锁」）—— 不剥注释，
// `!contains("playLockFile")` 那几条负向断言会因为**谈论代码的散文**而假红。两个方向都得钉：
// 剥太少 → 假红（没人受得了，会被删掉）；剥太多 → **假绿**（没人看得见，洞永远开着）。

@MainActor
func runSourceScannerSuites() {

    suite("扫描器：字符串字面量里的 `//` 不是注释起点（be332ff 那条恒真守卫真正想守的东西）") {
        // 这**就是** `be332ff` 的元断言想拦、却因为自身恒真而拦不住的那一行输入。
        // 上一版扫描器把它剪成 `let hint = "锁的说明见 https:` —— 后半行那句
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
        // ⚠️ 这条的第一版**没有牙**（变异台账 M1a 当场发现）：它喂的输入里**一个 `//` 都没有**，
        // 于是任何一个「不会凭空发明注释」的实现都能过 —— 包括它要杀的那个朴素截断版。一条对它
        // 声称要防的缺陷永远红不了的断言，正是本 suite 存在的理由（`://` 那条恒真守卫）在**测试
        // 自己身上**的复刻。
        //
        // 现在行尾挂一条**真注释**：`""` 若被误读成「开了一个没关的串」，那么这一行剩下的一切
        // （包括那个 `//`）都会被当成**字符串内容**照抄进 `code` —— 注释文本活下来，下面第二条断言
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

    suite("扫描器：撞见它不认识的构造（raw string）要**记一笔**，而不是安静地给出一份不可信的文本") {
        let source = #"""
            let pattern = ##"a//b"##
            """#
        let scanned = strippingComments(source)
        expect(
            !scanned.unmodeledConstructs.isEmpty,
            "扫描器不建模 raw string。它必须自己说出来 —— 这张清单被两个 suite 各一条断言盯着。"
                + "不说 = 一份不可信的 `code` 被当成可信的，负向断言在上面假绿")
    }

    suite("扫描器：`hasPrefix(\"#\")` **不是** raw string（守卫必须位置感知，否则它自己会假红）") {
        // 这条不是洁癖，它挡的是一整类「守卫因为无害改动而红 → 被下一个人删掉 → 洞原样回来」：
        // `ClaudioColorHex.swift:206` / `ContrastRatio.swift:27` 里真的有 `hasPrefix("#")`，
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
}
