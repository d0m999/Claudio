import Foundation

// MARK: - 把一张 JSON 表安全地写回磁盘：一个原语，两个调用方
//
// `config.json`（``updateConfigJSON(at:freshSelectedPack:mutate:)``）与 pack 的 `manifest.json`
// （`gui` 的 `bindEventToManifest(...)`）做的是**同一件事**：把一份用户磁盘上的 JSON 读进来、只改自己
// 拥有的那个键、再写回去，且不认识的键必须原样保住。既然是同一件事，它就只能有一份实现——否则两边
// 会各自长出一套「哪些值写得出去」的判断，然后其中一边慢慢腐烂。本轮 /ship 评审两边都中了招：
//
// - **`manifest.json` 少了数字规范化**（安全专家）：`JSONSerialization` 用 `%.17g` 渲染浮点，于是
//   一次绑定就能把一个未知键里干干净净的 `0.8` 写成 `0.80000000000000004`。config 早就修过这个洞，
//   manifest 没有。
// - **两边都会 abort**（Claude 对抗子代理，实测 exit 134）：`JSONSerialization` 的读与写**不对称**，
//   它解析得出来的东西不一定写得回去。见 ``firstUnwritableJSONValue(in:keyPath:depth:path:)``。
//
// 所以这两件事被收进 ``encodeJSONForWriting(_:path:)``：任何未来的读-改-写调用方，只要走它，就自动
// 同时拿到「不写脏数字」与「绝不 abort」两条保证。

/// JSON 里最多允许的嵌套层数。纯粹是给下面两个**递归**函数的栈兜底：`JSONSerialization` 乐意解析出
/// 任意深的嵌套，而一份病态嵌套的 config / manifest 会让它们在用户点一下静音钮时爆栈。真实文件的深度
/// 是 2（顶层 → `events`）；64 层给未来的 schema 留了三十倍余量，同时把栈溢出挡在门外。
let maxJSONNestingDepth = 64

/// ``encodeJSONForWriting(_:path:)`` 拒绝一份 JSON 的理由。`reason` 是**可执行的**，直接透传给用户。
public struct JSONWriteRejection: Error, Sendable, Equatable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

/// 规范化 + 校验 + 序列化：把 `json` 变成可以直接原子写回磁盘的字节，或者一句**可执行的**拒绝理由。
///
/// 一个字节都不写——写是调用方的事。这里只负责「这份东西能不能写、写出去干不干净」。
///
/// - Returns: 成功时是 `[.prettyPrinted, .sortedKeys]` 渲染的字节（键序稳定，diff 友好）；失败时是一句
///   直接可以透传给用户的原因。
func encodeJSONForWriting(
    _ json: [String: Any], path: String
) -> Result<Data, JSONWriteRejection> {
    if let reason = firstUnwritableJSONValue(in: json, keyPath: "", depth: 0, path: path) {
        return .failure(JSONWriteRejection(reason: reason))
    }

    let normalized = normalizedJSONNumbers(json)

    // 最后一道闸门：`JSONSerialization.data(withJSONObject:)` 对一个它写不出去的对象抛的是
    // **Objective-C 的 `NSInvalidArgumentException`**，不是 Swift 错误——`do/catch` 接不住它，进程当场
    // `abort()`。而它「写不出去」的判据，`isValidJSONObject` 只读地就能给：一行把「不可捕获的崩溃」
    // 降级成「一个可捕获的失败」。
    //
    // 上面那一问已经把**已知**的那一类（非有限数字）挡掉了，所以走到这里的对象本该都是可写的。这一道
    // 是为「我们还没想到的那一类」准备的：任何未来的 Foundation 行为差异、任何新的调用方，都不该有
    // 能力让菜单栏 app 在用户点一下静音钮时硬崩。
    guard JSONSerialization.isValidJSONObject(normalized) else {
        return .failure(
            JSONWriteRejection(
                reason: "\(path) 改完之后不是一份可序列化的 JSON（含 JSON 表达不了的值）。"
                    + "为避免写出半份坏文件，本次修改已放弃，磁盘上的文件一个字节都没动。"
                    + "请手工检查该文件。"))
    }

    do {
        return .success(
            try JSONSerialization.data(
                withJSONObject: normalized, options: [.prettyPrinted, .sortedKeys]))
    } catch {
        return .failure(
            JSONWriteRejection(reason: "\(path) 序列化失败：\(error.localizedDescription)"))
    }
}

/// 递归找出 `value` 里第一个 **`JSONSerialization` 能读进来、却写不出去**的值，返回一句可执行的原因；
/// 全都写得出去时返回 `nil`。
///
/// ## 为什么需要这道闸门（本轮 /ship 对抗评审：一个会 abort 进程的 P0）
///
/// `JSONSerialization` 的读与写**不对称**——它解析得出来的东西，它自己不一定写得回去：
/// ```
/// {"master_volume": -1e400}  → 解析成功，得到 -inf（NSNumber, objCType "d"）
/// ```
/// 而 `-inf` 会穿过所有既有闸门：``isJSONNumber(_:)`` 只判「是 NSNumber 且不是布尔」，
/// ``normalizedJSONNumbers(_:)`` 的「只改渲染、绝不改值」守卫（`decimal.doubleValue == number.doubleValue`）
/// 因为 `NSDecimalNumber(string: "-inf")` 是 NaN、而 `NaN == -inf` 恒假，**恰恰把原值原样放行**。于是它
/// 一路走到 `JSONSerialization.data(withJSONObject:)`，后者抛出 Objective-C 的
/// `NSInvalidArgumentException`（"Invalid number value (infinite) in JSON write"）——**Swift 的
/// `do/catch` 接不住**，进程 `abort()`（实测 exit 134）。
///
/// 爆炸半径是用户点一下 GUI 的静音钮（`EventMuteController` → `setEventEnabled`）→ 菜单栏 app 硬崩；
/// `claudio use` 切包、以及给某个事件绑定音频（`bindEventToManifest`）同理。（`claudio play` 不写任何
/// JSON，所以「hook 绝不阻断 Claude Code」这条硬契约没被破。）
///
/// 不对称还有一层：正溢出 `1e400` 在**解析期**就被 Foundation 拒了，只有**负**溢出能穿进来。所以这里
/// 判的是 `isFinite`，而不是「负数」——`nan` 与将来任何别的不可写数字同样被这一句挡住。
///
/// 这一问必须在**读侧**也被问一遍（`parseRewritableConfig` 就是这么做的），而不能只靠写侧兜底：写侧
/// 那道 `isValidJSONObject` 只能防崩，防不了**假绿**——`probeConfigRewritable` 要是放行了，`doctor`
/// 就会对着一份写下去会崩的文件打印「✓ config.json 可安全重写」。
///
/// 顺带把递归深度也收在这里：见 ``maxJSONNestingDepth``。
func firstUnwritableJSONValue(
    in value: Any, keyPath: String, depth: Int, path: String
) -> String? {
    let here = keyPath.isEmpty ? "顶层" : keyPath

    guard depth <= maxJSONNestingDepth else {
        return "\(path) 的 \(here) 嵌套超过 \(maxJSONNestingDepth) 层。claudio 拒绝重写一份嵌套到这种"
            + "程度的文件（继续走下去会耗尽调用栈）。请手工精简该结构。"
    }

    if let object = value as? [String: Any] {
        // 键序无关：排序后遍历，同一份坏文件永远报同一个键（否则报错文案会随哈希序抖动）。
        for key in object.keys.sorted() {
            let childPath = keyPath.isEmpty ? key : "\(keyPath).\(key)"
            if let reason = firstUnwritableJSONValue(
                in: object[key]!, keyPath: childPath, depth: depth + 1, path: path)
            {
                return reason
            }
        }
        return nil
    }
    if let array = value as? [Any] {
        for (index, element) in array.enumerated() {
            if let reason = firstUnwritableJSONValue(
                in: element, keyPath: "\(keyPath)[\(index)]", depth: depth + 1, path: path)
            {
                return reason
            }
        }
        return nil
    }

    // 布尔优先（同 ``normalizedJSONNumbers(_:)``）：`__NSCFBoolean` 也能 `as? NSNumber` 成功。
    guard !isJSONBoolean(value), let number = value as? NSNumber else { return nil }
    guard !number.doubleValue.isFinite else { return nil }

    return "\(path) 的 \(here) 是一个 JSON 写不回去的数字（\(number)：无穷大或 NaN，通常来自 -1e400 这类"
        + "溢出的字面量）。claudio 拒绝重写这份文件——真去写会让进程崩溃。请把该值改成一个有限数字。"
}

/// 把 `value` 里每一个**非整数**的 JSON 数字换成一个渲染成**最短往返形式**的 `NSDecimalNumber`，
/// 其余（布尔、整数、字符串、null、嵌套结构）原样递归穿过。
///
/// ## 为什么必须有这一步（保真读改写的必要条件）
///
/// `JSONSerialization` 输出 `Double` 用 `%.17g`——实测：
/// ```
/// 新建     : "master_volume" : 0.80000000000000004   ← 旧的 JSONEncoder 路径写的是干净的 0.8
/// 读-改-写 : "master_volume" : 0.80000000000000004   ← 连原本干净的 0.8 也被改写
/// 0.35     : "master_volume" : 0.34999999999999998
/// ```
/// 于是「未被 mutate 碰过的键逐字保留」这句话对**数字键**是假的：每点一次静音，磁盘上的
/// `master_volume` 就脏一次。`manifest.json` 的绑定路径原本也有同一个洞（本轮 /ship 评审：安全专家）。
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
///   之前逐字一致）。非有限值（`-inf`/`nan`）也会走到这条落回分支——它们由
///   ``firstUnwritableJSONValue(in:keyPath:depth:path:)`` 在更早一步整份拒掉，绝不会走到写。
///
/// **必须递归**：未知顶层键里可以嵌套任意深的对象 / 数组，里面照样有数字（`{"night_dim":
/// {"level": 0.35}}`）——只规范化 `master_volume` 等于承认「未知键会被写脏」，那正是要修的 bug。
/// 深度由上面那一问先行兜底，所以这里的递归不会爆栈。
func normalizedJSONNumbers(_ value: Any) -> Any {
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
/// 整型 `NSNumber`（`objCType` 为 `q` 等），把带小数点/指数的还原成 `d`；Swift 侧塞进来的 `Double`
/// （`ClaudioConfig.defaultMasterVolume`）也桥成 `d`。
func isFloatingPointJSONNumber(_ number: NSNumber) -> Bool {
    let objCType = String(cString: number.objCType)
    return objCType == "d" || objCType == "f"
}

/// 这个值是不是一个**真正的 JSON 布尔**（`true`/`false`），而不是一个恰好能桥接成 `Bool` 的数字。
///
/// `JSONSerialization` 把 `true` 和 `1` 都还原成 `NSNumber`，而 `NSNumber(1) as? Bool` 会成功——
/// 于是一个天真的 `value as? Bool` 会把 `{"stop": 1}` 悄悄读成 `true`，正是这里要杜绝的那类静默
/// 强转。只有 `CFBoolean`（`true`/`false` 的真实还原类型）才算布尔。
func isJSONBoolean(_ value: Any) -> Bool {
    CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
}

// MARK: - gui 侧的读-改-写入口
//
// `gui` 的 `bindEventToManifest(...)` 与 helper 的 `updateConfigJSON(...)` 必须共用上面那一套，否则
// 「哪些值写得出去」又会长出第二个定义。`public` 的理由与 ``regularFileExists(at:)`` /
// ``loadPackManifestData(in:)`` 完全一样：这是 `gui` 必须复用的**写原语**，不是 helper 的内部细节。

/// ``encodeJSONForWriting(_:path:)`` 的 `public` 门面，供 `gui`（`ClaudioGUICore`）复用。
public func encodeJSONObjectForWriting(
    _ json: [String: Any], path: String
) -> Result<Data, JSONWriteRejection> {
    encodeJSONForWriting(json, path: path)
}
