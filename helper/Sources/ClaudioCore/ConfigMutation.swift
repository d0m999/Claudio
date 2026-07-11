import Foundation

/// `config.json` 的**外科式读-改-写**：把文件当成一张原始 JSON 表（`[String: Any]`）读进来，
/// 只覆盖调用方真正拥有的那一个键，其余每一个顶层键——**包括这份 v1 模型根本不认识的键**——
/// 的**键与值**一律保留后写回。保的是**键与值，不是字节**：输出是规范化的（键排序、`prettyPrinted`
/// 缩进、数字最短渲染），不是原文件的字节级复刻——两条边界各有一节说明，见下与「数字规范化」。
/// `claudio use`（``selectPack``）与「静音钮」（``setEventEnabled``）是它
/// 仅有的两个调用方，共用这一条代码路径，而不是各写一遍。
///
/// ## 「保真」保的是键与值，不是**键顺序**（`/codex review` [P2]，判定为按现状）
///
/// 写回走 `[.prettyPrinted, .sortedKeys]`，所以整份 JSON 的顶层与嵌套键都会被**排序**——未知键的
/// **内容**逐字幸存，它们在文件里的**先后**不幸存。这不是本次引入的退化：`9b89650` 之前的
/// `JSONEncoder` 写路径同样是 `[.prettyPrinted, .sortedKeys]`，只是它还会把未知键整个 DROP 掉；
/// 换句话说这条路径在「保真」这件事上严格更好，只是没有好到字节级。
///
/// 刻意不修：JSON 对象本就无序，重排没有任何语义损失；确定性输出换来的是稳定 diff 与幂等写入，
/// 也是本仓库既定的写法（``SettingsInstaller`` 与 `gui` 的 `ManifestBinding` 同样 `.sortedKeys`）。
/// 真要保序，`JSONSerialization` 做不到（`[String: Any]` 无序），得手写一个 JSON 序列化器或对原始
/// 文本做外科手术——为零语义收益背一整个新的、需要重新审计的写路径，不划算。
///
/// ## 为什么绝不能 round-trip `ClaudioConfig`（Codable）
///
/// ``ClaudioConfig`` 只建模三个 v1 键（`selected_pack` / `master_volume` / `events`），而它的
/// `Encodable` 是编译器合成的——「解码成 `ClaudioConfig` 再重新编码」会静默 **DROP 掉每一个其他
/// 顶层键**。这是真实的数据丢失 bug，不是假设：`/ship` pre-landing 评审实证复现过——一份带
/// `night_dim` / `ui_theme` 的 config.json，用户点一次静音，两个键当场消失，而 CLI 报 SUCCESS。
/// `gui` 侧 `ManifestBinding.swift` 早已因为同一个理由拒绝 round-trip `PackManifest`；这里是把
/// 那个已经被评审确认正确的形状，从 `manifest.json` 移植到 `config.json`。
///
/// 更阴险的是 ``ClaudioConfig/init(from:)`` 是**宽松解码**：`master_volume` / `events` 解不出来
/// 就静默取默认值。它对 `play`/`doctor` 的**读**路径是对的（「config 损坏 → 退回默认，绝不让
/// hook 失败」），但对**写**路径是灾难——`{"master_volume": "0.35"}` 会被读成 0.8，然后把 0.8
/// 写回磁盘，用户的音量设置就这样被一次静音点击抹掉了，而且报的是成功。
///
/// ## 因此这里一律 fail closed
///
/// 任何我们**读不懂**的结构（顶层不是对象、`events` 不是对象、`events` 里有非布尔值、
/// `master_volume` 不是数字、`selected_pack` 缺失或不是字符串）都判定为「文件已损坏」，
/// ``ConfigMutationFailure/unreadable(reason:)`` 中止，**一个字节都不写**。刻意不做「只跳过坏的
/// 那一个键、其余照写」——那等于用一个我们没读懂的文件去覆盖用户的真实文件，是把数据丢失从
/// 「全丢」降级成「部分丢」，而不是修好它。

/// ## fail closed 必须给出路（本轮评审）
///
/// 「读不懂就中止」是对的，但它把用户锁死了：一份**旧路径照常能读**的畸形 config（如
/// `{"master_volume":"0.8"}` 或 `{"events":{"stop":1}}`——宽松读路径今天工作得好好的，`play` /
/// `doctor` 一切正常）会让**所有写操作永久失败**：静音失败、切包也失败。而 `Setup.swift` 因为
/// config 已存在**不会重建它**，于是 App 内**没有任何自愈途径**。判定逻辑本身不放宽（放宽就是回到
/// 数据丢失），但错误信息必须是**可执行的指令**——它已经带了 path 和坏键名，只差告诉用户怎么修：
/// 「这个键必须是什么 / 当前是什么 / 手工改它，或删掉文件让 claudio 重建」。同一句话由
/// ``probeConfigRewritable(configFile:)`` 喂给 `claudio doctor`（诊断本来就是它的职责），所以用户不
/// 必先把 App 点到失败才能知道自己的 config 坏在哪。
///
/// 刻意**不**加 `--fix-config` 这类新命令：那是在给一份我们读不懂的文件做自动手术，超出「让错误可
/// 执行」的范围。

/// ``updateConfigJSON(at:freshSelectedPack:mutate:)`` 的失败原因。两个调用方各自把它映射成
/// 自己的 `configReadFailure` / `configWriteFailure`（`UseError` / `SetEventEnabledError`）。
enum ConfigMutationFailure: Error, Sendable, Equatable {
    /// 文件存在但读不出来，或读出来的内容不是一份我们能安全重写的 config（见类型注释里的
    /// fail-closed 规则）。带的 reason 直接透传给用户，且**必须是可执行的**（见上）。
    case unreadable(reason: String)
    /// 改完之后写回磁盘失败（父目录被一个普通文件占位、磁盘满、只读卷……）。
    case writeFailed(reason: String)

    /// 人话原因，不管是哪一种失败——`doctor` 与两个 CLI 调用方都只想要这一个字符串。
    var reason: String {
        switch self {
        case .unreadable(let reason): reason
        case .writeFailed(let reason): reason
        }
    }
}

/// `config.json` 当前是不是一份**写路径能安全重写**的文件——`claudio doctor` 的 config 检查
/// （`Doctor.swift`）与 `gui` 的诊断都读这一个判定，而不是各自再解析一遍。
public enum ConfigRewritability: Sendable, Equatable {
    /// 文件还不存在。这**不是**错误：写路径会新建一份最小 config（全新安装的正常状态）。
    case absent
    /// 读得懂，写路径可以安全地做外科式读-改-写。
    case rewritable
    /// 畸形。`reason` 是**可执行的**修复指令（哪个键、必须是什么、当前是什么、怎么修）。
    /// 注意这**不影响播放**：宽松读路径（`play` / `doctor` 的 `ClaudioConfig`）照常工作——坏的只是
    /// 「写」，也就是 App 里的静音钮与切包。
    case malformed(reason: String)
}

/// 只读探针：`configFile` 现在能不能被写路径安全重写。**一个字节都不写**，走的是 `updateConfigJSON`
/// 用的同一份 ``parseRewritableConfig(_:path:)``——「能不能写」的定义只有一个，不存在 doctor 说能、
/// 真去写又失败（或反过来）的可能。
public func probeConfigRewritable(configFile: URL = ClaudioPaths.configFile) -> ConfigRewritability {
    guard FileManager.default.fileExists(atPath: configFile.path) else { return .absent }
    guard let data = try? Data(contentsOf: configFile) else {
        return .malformed(reason: "无法读取 \(configFile.path)。请检查该文件的权限，\(configRebuildHint)。")
    }
    switch parseRewritableConfig(data, path: configFile.path) {
    case .success: return .rewritable
    case .failure(let failure): return .malformed(reason: failure.reason)
    }
}

/// 读 `configFile` → 校验 → 交给 `mutate` 只改它拥有的键 → 原子写回。
///
/// - Parameters:
///   - configFile: `~/.claudio/config.json`（测试注入临时目录）。
///   - freshSelectedPack: 文件**不存在**时新建的最小 config 用哪个 `selected_pack`。
///     `selectPack` 传它正要选中的 pack id；`setEventEnabled` 传空串——它没有任何 pack 上下文，
///     凭空编一个默认值等于伪造一次谁也没做过的选择。
///   - mutate: 只允许改调用方自己拥有的那个键。进来的 `[String: Any]` 要么是磁盘上那份文件的
///     **完整**顶层键集合（已通过下面的校验），要么是新建的最小 config；没被 `mutate` 碰过的键，
///     其**键与值**都会原封不动写回（**渲染**不保证逐字：键会排序、数字会被规范化，见类型注释）。
func updateConfigJSON(
    at configFile: URL,
    freshSelectedPack: String,
    mutate: (inout [String: Any]) -> Void
) -> Result<Void, ConfigMutationFailure> {
    var json: [String: Any]

    if FileManager.default.fileExists(atPath: configFile.path) {
        guard let data = try? Data(contentsOf: configFile) else {
            return .failure(
                .unreadable(
                    reason: "无法读取 \(configFile.path)。请检查该文件的权限，\(configRebuildHint)。"))
        }
        switch parseRewritableConfig(data, path: configFile.path) {
        case .success(let parsed): json = parsed
        case .failure(let failure): return .failure(failure)
        }
    } else {
        // 全新安装：这份文件的每一个键都是我们自己刚写下的，没有任何未知键需要保留。
        // 键集合与旧的 `JSONEncoder().encode(ClaudioConfig(...))` 完全一致（三个 v1 键）。
        json = [
            "selected_pack": freshSelectedPack,
            "master_volume": ClaudioConfig.defaultMasterVolume,
            "events": [String: Any](),
        ]
    }

    mutate(&json)

    do {
        try FileManager.default.createDirectory(
            at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: normalizedJSONNumbers(json), options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configFile, options: .atomic)
    } catch {
        return .failure(.writeFailed(reason: error.localizedDescription))
    }

    return .success(())
}

// MARK: - 数字规范化：不让「保真读改写」把干净的数字写脏

/// 把 `value` 里每一个**非整数**的 JSON 数字换成一个渲染成**最短往返形式**的 `NSDecimalNumber`，
/// 其余（布尔、整数、字符串、null、嵌套结构）原样递归穿过。
///
/// ## 为什么必须有这一步（本轮评审：我们自己引入的退化）
///
/// `JSONSerialization` 输出 `Double` 用 `%.17g`——实测：
/// ```
/// 新建     : "master_volume" : 0.80000000000000004   ← 旧的 JSONEncoder 路径写的是干净的 0.8
/// 读-改-写 : "master_volume" : 0.80000000000000004   ← 连原本干净的 0.8 也被改写
/// 0.35     : "master_volume" : 0.34999999999999998
/// ```
/// 于是「未被 mutate 碰过的键逐字保留」这句话对**数字键**是假的：每点一次静音，磁盘上的
/// `master_volume` 就脏一次；`Setup.swift` 首次装机（走 `selectPack`）当场就写出脏的 0.8，而
/// ENGINEERING.md 里写的是 `"master_volume": 0.8`。
///
/// 修法（实测）：`NSDecimalNumber(string:)` 会让 `JSONSerialization` 吐出干净的最短形式——
/// `"0.8"` → `0.8`，`"0.35"` → `0.35`，`"1.0"` → `1`，`"0.123456789"` → `0.123456789`。
/// 喂给它的字符串是 Swift 自己的 `Double` 描述，也就是**最短往返表示**。
///
/// ## 三条不容含糊的边界
///
/// - **绝不碰布尔。** JSON 里 `true`/`false` 桥成 `__NSCFBoolean`，而 `1`/`0` 桥成 `__NSCFNumber`；
///   把 Bool 误转成 `NSDecimalNumber` 会把 `"stop": true` 写成 `"stop": 1`——那不是修好，那是一个新的
///   数据损坏（而且正好是 ``isJSONBoolean(_:)`` 在读侧拼命要挡的那种）。复用同一个 `CFBoolean` 判定。
/// - **绝不碰整数。** `JSONSerialization` 本来就把整数渲染得又干净又精确（实测：`1` → `1`，
///   `9007199254740993` → 逐字不变）。而整数一旦走 `doubleValue`，超出 Double 精度的 Int64 就会当场
///   丢精度。既然它们从来没被弄脏过，最安全的处理就是**一个字节都不动**。
/// - **值永不改变，只改渲染。** 只有当 `NSDecimalNumber` 转回 `Double` 与原值**逐位相等**时才替换，
///   否则原样保留。这一条同时兜住了 `Decimal` 表示不了的极端值（`1e300`、`1e-320`——实测
///   `NSDecimalNumber(string:)` 对它们返回 NaN，而 `NaN == x` 恒假，所以自动落回原值，行为与规范化
///   之前逐字一致）。
///
/// **必须递归**：未知顶层键里可以嵌套任意深的对象 / 数组，里面照样有数字（`{"night_dim":
/// {"level": 0.35}}`）——只规范化 `master_volume` 等于承认「未知键会被写脏」，那正是要修的 bug。
private func normalizedJSONNumbers(_ value: Any) -> Any {
    if let object = value as? [String: Any] { return object.mapValues(normalizedJSONNumbers) }
    if let array = value as? [Any] { return array.map(normalizedJSONNumbers) }
    // 布尔优先：`__NSCFBoolean` 也能 `as? NSNumber` 成功，先判它才不会把 `true` 变成 `1`。
    guard !isJSONBoolean(value), let number = value as? NSNumber else { return value }
    guard isFloatingPointJSONNumber(number) else { return number }  // 整数原样保留（见上）

    let decimal = NSDecimalNumber(string: "\(number.doubleValue)")  // Swift = 最短往返表示
    guard decimal.doubleValue == number.doubleValue else { return number }  // 只改渲染，绝不改值
    return decimal
}

/// 这个 `NSNumber` 装的是不是一个**浮点**数（而不是整数）。`JSONSerialization` 把 JSON 里的整数还原成
/// 整型 `NSNumber`（`objCType` 为 `q` 等），把带小数点/指数的还原成 `d`；Swift 侧 `mutate` 塞进来的
/// `Double`（`ClaudioConfig.defaultMasterVolume`）也桥成 `d`。
private func isFloatingPointJSONNumber(_ number: NSNumber) -> Bool {
    let objCType = String(cString: number.objCType)
    return objCType == "d" || objCType == "f"
}

/// 把 `data` 解析成一张**可以被安全重写**的顶层 JSON 表，否则 fail closed。
///
/// 「可以被安全重写」= 我们认识的每一个键都长成我们认识的样子。不认识的键（`night_dim`、
/// 未来版本的字段、用户手写的注释字段……）一律放行并原样保留——它们不是损坏，只是不归我们管。
///
/// 每一条失败原因都是**可执行的**：哪个键、必须是什么、当前是什么、怎么修（见类型注释「fail closed
/// 必须给出路」）。fail closed 锁死的是唯一的写路径，用户在 App 里点不出第二条自愈途径——那么这句
/// 话就是他手上仅有的工具，它必须直接告诉他该敲什么。
private func parseRewritableConfig(
    _ data: Data, path: String
) -> Result<[String: Any], ConfigMutationFailure> {
    guard let parsed = try? JSONSerialization.jsonObject(with: data),
        let json = parsed as? [String: Any]
    else {
        return .failure(
            .unreadable(
                reason: "\(path) 的顶层必须是一个 JSON 对象（形如 {\"selected_pack\": \"...\"}）："
                    + "它现在要么不是合法 JSON，要么顶层是数组 / 标量。请手工修正该文件，"
                    + "\(configRebuildHint)。"))
    }

    // `selected_pack` 是 v1 config 唯一的必需键（`ClaudioConfig` 的解码器也这么要求）。缺了它，
    // 或者它不是字符串，这份文件就不是 claudio 写出来的东西——不去猜，直接中止。
    guard let rawSelectedPack = json["selected_pack"] else {
        return .failure(
            .unreadable(
                reason: "\(path) 缺少必需键 selected_pack（值应为声音包 id 字符串，"
                    + "如 \"minimal-chime\"）。请补上该键，\(configRebuildHint)。"))
    }
    guard rawSelectedPack is String else {
        return .failure(
            .unreadable(
                reason: "\(path) 的 selected_pack 必须是字符串声音包 id"
                    + "（当前是\(describeJSONValue(rawSelectedPack))）。请手工修正该值，"
                    + "\(configRebuildHint)。"))
    }

    // `master_volume` 存在但不是数字（`"0.35"` 这种字符串、`true`、对象……）：宽松解码会把它
    // 静默换成 0.8 再写回去，用户的音量就没了。这里当作损坏处理。
    if let rawVolume = json["master_volume"], !isJSONNumber(rawVolume) {
        return .failure(
            .unreadable(
                reason: "\(path) 的 master_volume 必须是 0.0–1.0 的数字（如 0.8）"
                    + "（当前是\(describeJSONValue(rawVolume))）。请手工修正该值，"
                    + "\(configRebuildHint)。"))
    }

    // `events` 存在但不是对象（数组、字符串……）：整表按损坏处理，绝不悄悄换成一张空表——那会
    // 把原本写在里面的东西全部抹掉，还报成功。
    if let rawEvents = json["events"] {
        guard let events = rawEvents as? [String: Any] else {
            return .failure(
                .unreadable(
                    reason: "\(path) 的 events 必须是 JSON 对象（形如 {\"stop\": true}）"
                        + "（当前是\(describeJSONValue(rawEvents))）。请手工修正该值，"
                        + "\(configRebuildHint)。"))
        }
        // `events` 里任何一个值不是布尔（数字 `1`、字符串 `"false"`、`{"enabled":true,...}`
        // 这种更丰富的未来 schema……）也一样：**整个文件**按损坏处理，而不是只跳过坏的那一项。
        // 我们没法安全地重写一份自己读不懂的文件——只跳过坏项等于把它连同它的兄弟一起写没了。
        for (key, value) in events where !isJSONBoolean(value) {
            return .failure(
                .unreadable(
                    reason: "\(path) 的 events.\(key) 必须是 true/false"
                        + "（当前是\(describeJSONValue(value))）。请手工修正该值，"
                        + "\(configRebuildHint)。"))
        }
    }

    return .success(json)
}

/// 每条 fail-closed 原因共用的收尾：**第二条**出路。手工改值是第一条；删掉文件让 claudio 重建是第二
/// 条——括号里那句代价（自定义字段会没）必须一起说，否则这就成了一句诱导用户丢数据的建议。
private let configRebuildHint = "或删除该文件让 claudio 重建（会丢失自定义字段）"

/// 把一个 JSON 值描述成用户能在自己文件里认出来的样子（「当前是数字 1」而不是「当前是 __NSCFNumber」）。
/// 布尔必须走在数字前面——`true` 桥成 `__NSCFBoolean`，而它 `as? NSNumber` 会成功（同 ``isJSONBoolean(_:)``）。
private func describeJSONValue(_ value: Any) -> String {
    if isJSONBoolean(value) {
        return "布尔 \((value as? NSNumber)?.boolValue == true ? "true" : "false")"
    }
    if let number = value as? NSNumber { return "数字 \(number)" }
    if let string = value as? String { return "字符串 \"\(string)\"" }
    if value is [Any] { return "数组" }
    if value is [String: Any] { return "对象" }
    if value is NSNull { return "null" }
    return "一个无法识别的值"
}

/// 这个值是不是一个**真正的 JSON 布尔**（`true`/`false`），而不是一个恰好能桥接成 `Bool` 的数字。
///
/// `JSONSerialization` 把 `true` 和 `1` 都还原成 `NSNumber`，而 `NSNumber(1) as? Bool` 会成功——
/// 于是一个天真的 `value as? Bool` 会把 `{"stop": 1}` 悄悄读成 `true`，正是这里要杜绝的那类静默
/// 强转。只有 `CFBoolean`（`true`/`false` 的真实还原类型）才算布尔。
private func isJSONBoolean(_ value: Any) -> Bool {
    CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
}

/// 这个值是不是一个 JSON 数字。刻意把布尔排除在外（见 ``isJSONBoolean(_:)``）：`master_volume:
/// true` 不是「音量 1.0」，是一份坏文件。
private func isJSONNumber(_ value: Any) -> Bool {
    value is NSNumber && !isJSONBoolean(value)
}
