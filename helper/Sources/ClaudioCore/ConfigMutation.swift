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
    /// 内容没问题，**但写不进去**：父目录不可写（只读卷、权限被改、目录属于别的用户……）。
    ///
    /// 与 ``malformed(reason:)`` 分开，是因为这两件事该讲的话完全不同：畸形是「你的文件里第 N 个键
    /// 写错了」，不可写是「你的文件没错，是它待的那个目录不让写」。把后者报成「畸形」会让用户去改一份
    /// 根本没毛病的文件（本轮 /ship 评审：`/codex review` [P2]）。
    case unwritable(reason: String)
}

/// 只读探针：`configFile` 现在能不能被写路径安全重写。**一个字节都不写**，走的是 `updateConfigJSON`
/// 用的同一份 ``parseRewritableConfig(_:path:)``——「能不能写」的定义只有一个，不存在 doctor 说能、
/// 真去写又失败（或反过来）的可能。
public func probeConfigRewritable(configFile: URL = ClaudioPaths.configFile) -> ConfigRewritability {
    guard FileManager.default.fileExists(atPath: configFile.path) else { return .absent }
    guard case .success(let data) = readConfigFileBounded(at: configFile) else {
        return .malformed(reason: unreadableConfigReason(path: configFile.path))
    }
    switch parseRewritableConfig(data, path: configFile.path) {
    case .failure(let failure): return .malformed(reason: failure.reason)
    case .success: break
    }

    // 内容过关，还差最后一问：这份文件所在的目录**让不让写**。
    //
    // 「能不能写」的定义只有一个（见上面的类型注释），而「解析得通过」只是它的一半。原子写（先在同一个
    // 目录里落一个临时文件、再 rename 盖上去）要的是**父目录**可写；父目录只读时，一份完全合法的
    // config 照样一个字节也写不进去。少了这一问，`doctor` 会对着这种局面打印「✓ config.json 可安全
    // 重写」，而用户真去点静音钮时它一次次失败——doctor 的整个存在意义就是不让用户遇到这种事
    // （本轮 /ship 评审：`/codex review` [P2]）。
    //
    // `access(2)` 语义的只读探针，一个字节都不写（`isWritableFile(atPath:)` 底下就是它）。
    let parentDirectory = configFile.deletingLastPathComponent()
    guard FileManager.default.isWritableFile(atPath: parentDirectory.path) else {
        return .unwritable(
            reason: "\(configFile.path) 的内容没问题，但它所在的目录 \(parentDirectory.path) 不可写，"
                + "所以 App 里的静音 / 切包一定会失败。请修正该目录的权限"
                + "（例如 chmod u+w \(parentDirectory.path)）。")
    }
    return .rewritable
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
        guard case .success(let data) = readConfigFileBounded(at: configFile) else {
            return .failure(.unreadable(reason: unreadableConfigReason(path: configFile.path)))
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

    // 规范化（不写脏数字）+ 校验（绝不 abort）+ 序列化，全在 ``encodeJSONForWriting(_:path:)`` 里，
    // 与 `gui` 的 manifest 绑定路径共用同一份实现——「哪些值写得出去」只有一个定义。
    let data: Data
    switch encodeJSONForWriting(json, path: configFile.path) {
    case .success(let encoded): data = encoded
    case .failure(let rejection):
        return .failure(.writeFailed(reason: "\(rejection.reason)\(configRebuildHint)。"))
    }

    do {
        try FileManager.default.createDirectory(
            at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: configFile, options: .atomic)
    } catch {
        return .failure(.writeFailed(reason: error.localizedDescription))
    }

    return .success(())
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

    // 最后：整棵树里不能有「读得进来、却写不出去」的值。见 ``firstUnwritableJSONValue(in:keyPath:depth:)``。
    // 这一条必须在**读侧**：写侧那道 `isValidJSONObject` 只能防崩，防不了假绿——`probeConfigRewritable`
    // 走的正是这个函数，它要是放行了，`doctor` 就会对着一份写下去会失败的文件打印「✓ 可安全重写」。
    if let reason = firstUnwritableJSONValue(in: json, keyPath: "", depth: 0, path: path) {
        // 与其余每一条 fail-closed 原因一样，必须带上**第二条**出路（见 ``configRebuildHint``）。
        return .failure(.unreadable(reason: "\(reason)\(configRebuildHint)。"))
    }

    return .success(json)
}

/// 每条 fail-closed 原因共用的收尾：**第二条**出路。手工改值是第一条；删掉文件让 claudio 重建是第二
/// 条——括号里那句代价（自定义字段会没）必须一起说，否则这就成了一句诱导用户丢数据的建议。
private let configRebuildHint = "或删除该文件让 claudio 重建（会丢失自定义字段）"

/// 「文件在那儿，但 ``readConfigFileBounded(at:)`` 不肯把它的字节交出来」这一类的统一说法：没权限、
/// 它其实是个目录 / FIFO、或者它大得离谱（> ``maxConfigFileBytes``）。
///
/// 只有一份文案，是因为只读探针（``probeConfigRewritable(configFile:)``）与真正的写路径
/// （``updateConfigJSON(at:freshSelectedPack:mutate:)``）**必须逐字说同一句话**——那正是「不存在
/// doctor 说能、真去写又失败」这条契约的形状，也是 `ConfigMutationSuite` 里那条「reason 与真去写时
/// 拿到的那一句逐字相同」断言钉住的东西。
private func unreadableConfigReason(path: String) -> String {
    "无法读取 \(path)。请检查它确实是一个可读的普通文件（不是目录 / FIFO / 符号链接指向它们），"
        + "且不大于 \(maxConfigFileBytes) 字节，\(configRebuildHint)。"
}

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


/// 这个值是不是一个 JSON 数字。刻意把布尔排除在外（见 ``isJSONBoolean(_:)``）：`master_volume:
/// true` 不是「音量 1.0」，是一份坏文件。
private func isJSONNumber(_ value: Any) -> Bool {
    value is NSNumber && !isJSONBoolean(value)
}
