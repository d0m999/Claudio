import ClaudioCore
import Foundation

// MARK: - config.json 的读-改-写必须保真（/ship pre-landing 评审：已实证的数据丢失 bug）
//
// `selectPack` 与 `setEventEnabled` 都要「只改自己拥有的那个键、其余原样保留」。它们**曾经**是
// round-trip `ClaudioConfig`（Codable）实现的，而：
//   - `ClaudioConfig` 的 `Encodable` 是合成的，只写 3 个 v1 键 → 用户 config 里其余顶层键
//     （`night_dim`、`ui_theme`、未来字段……）被整片抹掉；
//   - `ClaudioConfig` 的解码器是**宽松**的 → 坏掉的 `master_volume` / `events` 被静默换成默认值
//     再写回磁盘；`performSetEventEnabled` 里那句 `guard ... else { return .configReadFailure }`
//     因此根本到不了。
// 两件事都还报 SUCCESS。这一组 suite 就是那张实证复现表，逐行钉死；修复方案见
// `ConfigMutation.swift`（外科式 `JSONSerialization` 读-改-写 + 读不懂就 fail closed）。
//
// 这些 suite 同时覆盖两个调用方：它们共用**同一份** `updateConfigJSON` 实现（编辑的是同一个文件，
// 「保真」的定义只能有一个），所以两边都必须表现出同一套契约。

/// 把 `url` 当作**原始 JSON 表**读出来——刻意不经过 `ClaudioConfig`：这组测试要证明的正是
/// 「`ClaudioConfig` 看不见的那些键也活下来了」，用它来断言等于用被告当证人。
@MainActor
private func readRawConfigJSON(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url),
        let parsed = try? JSONSerialization.jsonObject(with: data),
        let json = parsed as? [String: Any]
    else { return nil }
    return json
}

@MainActor
private func makePackDirectory(at url: URL) {
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    writeFixture(#"{ "id": "test-pack", "events": {} }"#, to: url.appendingPathComponent("manifest.json"))
}

/// 磁盘上那份文件的**原始文本**——「逐字保留」这句话说的是字节，不是「解析回来相等」。
/// `0.80000000000000004` 和 `0.8` 解析回来是同一个 `Double`，用 `JSONSerialization` 去断言等于把要证的
/// 东西假设掉；这一组数字保真断言只认字节。
@MainActor
private func readRawText(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

/// 把 JSON 文本里所有空白挤掉，好让断言能钉死一个精确的字面量片段（`"curve":[0.8,1,false]`），
/// 而不是被 `.prettyPrinted` 的缩进/换行牵着走。
private func compacted(_ text: String) -> String {
    text.filter { !$0.isWhitespace }
}

/// 从原始 JSON 文本里抠出 `key` 那个键的**字面量**（逐字，不经任何 JSON 解析）。
/// 刻意做成「取到下一个 `,` / `}` / 换行为止」——足以精确区分 `0.8` 与 `0.80000000000000004`
/// （后者以前者为前缀，所以 `contains("0.8")` 这种断言是**假绿**）。
private func rawLiteral(of key: String, in text: String) -> String? {
    guard let keyRange = text.range(of: "\"\(key)\"") else { return nil }
    let afterKey = text[keyRange.upperBound...]
    guard let colonIndex = afterKey.firstIndex(of: ":") else { return nil }
    let afterColon = afterKey[afterKey.index(after: colonIndex)...]
    let literal = afterColon.prefix { $0 != "," && $0 != "\n" && $0 != "}" }
    return literal.trimmingCharacters(in: .whitespaces)
}

@MainActor
func runConfigMutationSuites() {

    // MARK: - setEventEnabled（点一次静音）

    suite(
        "setEventEnabled: 未知顶层键（night_dim / ui_theme）在一次静音后逐字幸存，绝不被合成的 Encodable 抹掉"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(
                #"{ "selected_pack": "pika", "night_dim": true, "ui_theme": "dark" }"#,
                to: configFile)

            let result = setEventEnabled(
                .stop, enabled: false, configFile: configFile, lockFile: lockFile)
            expect(
                result == .success(.updated(event: .stop, enabled: false)),
                "静音一个事件应当成功，got \(result)")

            let json = readRawConfigJSON(configFile)
            expect(
                json?["night_dim"] as? Bool == true,
                "`night_dim` 是 ClaudioConfig 根本不认识的键——它必须原样保留，而不是在一次静音里"
                    + " 消失（旧的 round-trip 实现会把它抹掉并报 SUCCESS），got"
                    + " \(String(describing: json?["night_dim"]))")
            expect(
                json?["ui_theme"] as? String == "dark",
                "`ui_theme` 同上：未知键不是损坏，只是不归 v1 模型管，got"
                    + " \(String(describing: json?["ui_theme"]))")
            expect(
                json?["selected_pack"] as? String == "pika",
                "静音钮不拥有 selected_pack，它必须纹丝不动")
            let events = json?["events"] as? [String: Any]
            expect(
                events?["stop"] as? Bool == false,
                "唯一该变的那一个键：events.stop == false，got \(String(describing: events?["stop"]))")
        }
    }

    suite(
        "setEventEnabled: master_volume 是字符串（损坏）→ fail closed，绝不静默换成默认 0.8 再写回"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            // 旧行为（实证复现）：宽松解码把 `"0.35"` 解不出来 → 取默认值 0.8 → 把 0.8 写回磁盘 →
            // 报 SUCCESS。用户手调的音量就这样被一次静音点击吃掉了。类型不对 = 文件损坏 = 中止。
            let original = #"{ "selected_pack": "pika", "master_volume": "0.35" }"#
            writeFixture(original, to: configFile)

            let result = setEventEnabled(
                .stop, enabled: false, configFile: configFile, lockFile: lockFile)
            guard case .failure(.configReadFailure(let reason)) = result else {
                expect(
                    false,
                    "类型不对的 master_volume 必须以 .configReadFailure 中止（fail closed），got \(result)")
                return
            }
            expect(
                reason.contains("master_volume"),
                "失败原因必须指出到底是哪个键读不懂，got \(reason)")
            expect(
                (try? String(contentsOf: configFile, encoding: .utf8)) == original,
                "fail closed 的含义是一个字节都不写——文件必须逐字保持原样")
        }
    }

    suite(
        "setEventEnabled: events 里有非布尔值（\"false\" 字符串）→ 整份文件按损坏处理，不只是跳过那一项"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            // 旧行为（实证复现）：`[String: Bool]` 解码失败 → 静默取 `[:]` → `notification` 和
            // `subagent_stop` 连同那个坏值一起被抹掉 → 报 SUCCESS。
            let original = #"""
                { "selected_pack": "pika", "events": { "stop": true, "notification": "false", "subagent_stop": false } }
                """#
            writeFixture(original, to: configFile)

            let result = setEventEnabled(
                .stop, enabled: false, configFile: configFile, lockFile: lockFile)
            guard case .failure(.configReadFailure(let reason)) = result else {
                expect(false, "events 里的非布尔值必须让整次写入 fail closed，got \(result)")
                return
            }
            expect(
                reason.contains("notification"),
                "失败原因必须指出是哪一个事件的值读不懂，got \(reason)")
            expect(
                (try? String(contentsOf: configFile, encoding: .utf8)) == original,
                "我们读不懂这份文件，就没有资格重写它——notification / subagent_stop 必须原样躺在磁盘上")
        }
    }

    suite(
        "setEventEnabled: events 的值是对象（更丰富的未来 schema）→ fail closed，绝不把整张表抹平"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            // 一份「未来版本 / 手写」的 config：每个事件带自己的音量。旧行为会把整张 events 表
            // 抹平成 `{"stop": false}` 并报 SUCCESS。
            let original = #"""
                { "selected_pack": "pika", "events": { "stop": { "enabled": true, "volume": 0.5 } } }
                """#
            writeFixture(original, to: configFile)

            let result = setEventEnabled(
                .stop, enabled: false, configFile: configFile, lockFile: lockFile)
            guard case .failure(.configReadFailure) = result else {
                expect(false, "对象形状的 events 值必须 fail closed，got \(result)")
                return
            }
            expect(
                (try? String(contentsOf: configFile, encoding: .utf8)) == original,
                "整张 events 表必须逐字幸存，绝不被抹平")
        }
    }

    suite(
        "setEventEnabled: 对照组——一份完全正常的 config.json，只翻目标事件，master_volume 与兄弟事件纹丝不动"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(
                #"""
                { "selected_pack": "pika", "master_volume": 0.35, "events": { "stop": true, "notification": false } }
                """#, to: configFile)

            let result = setEventEnabled(
                .stop, enabled: false, configFile: configFile, lockFile: lockFile)
            expect(
                result == .success(.updated(event: .stop, enabled: false)),
                "合法 config 上的静音必须成功，got \(result)")

            let json = readRawConfigJSON(configFile)
            expect(
                json?["master_volume"] as? Double == 0.35,
                "master_volume 必须**逐字**保留 0.35——不是被宽松解码换成默认 0.8，got"
                    + " \(String(describing: json?["master_volume"]))")
            expect(json?["selected_pack"] as? String == "pika", "selected_pack 必须纹丝不动")
            let events = json?["events"] as? [String: Any]
            expect(events?["stop"] as? Bool == false, "目标事件必须翻成 false")
            expect(
                events?["notification"] as? Bool == false,
                "兄弟事件的既有取值必须原样保留，got \(String(describing: events?["notification"]))")
            expect(
                events?.count == 2,
                "events 表里既不该多出、也不该少掉任何一项，got \(String(describing: events?.keys.sorted()))")
        }
    }

    suite(
        "setEventEnabled: events 的值是数字 1（NSNumber/Bool 桥接陷阱）→ fail closed，绝不被静默读成 true"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            // JSONSerialization 把 `true` 和 `1` 都还原成 NSNumber，而 `NSNumber(1) as? Bool` 会
            // 成功——一个天真的 `as? Bool` 会把 `{"notification": 1}` 悄悄当成 `true`。这正是
            // `isJSONBoolean` 用 CFBoolean 判定要挡住的静默强转。
            let original = #"{ "selected_pack": "pika", "events": { "notification": 1 } }"#
            writeFixture(original, to: configFile)

            let result = setEventEnabled(
                .stop, enabled: false, configFile: configFile, lockFile: lockFile)
            guard case .failure(.configReadFailure) = result else {
                expect(false, "数字形状的 events 值必须 fail closed（不是 truthy 强转），got \(result)")
                return
            }
            expect(
                (try? String(contentsOf: configFile, encoding: .utf8)) == original,
                "文件必须逐字保持原样")
        }
    }

    suite("setEventEnabled: master_volume 是布尔 true → fail closed（布尔不是数字，是坏文件）") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let original = #"{ "selected_pack": "pika", "master_volume": true }"#
            writeFixture(original, to: configFile)

            let result = setEventEnabled(
                .stop, enabled: false, configFile: configFile, lockFile: lockFile)
            guard case .failure(.configReadFailure) = result else {
                expect(
                    false,
                    "`master_volume: true` 不是「音量 1.0」，是一份坏文件——必须 fail closed，got \(result)")
                return
            }
            expect(
                (try? String(contentsOf: configFile, encoding: .utf8)) == original,
                "文件必须逐字保持原样")
        }
    }

    suite("setEventEnabled: 顶层不是 JSON 对象（是数组）→ fail closed") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let original = "[1, 2, 3]"
            writeFixture(original, to: configFile)

            let result = setEventEnabled(
                .stop, enabled: false, configFile: configFile, lockFile: lockFile)
            guard case .failure(.configReadFailure(let reason)) = result else {
                expect(false, "顶层不是对象的 JSON 必须 fail closed，got \(result)")
                return
            }
            expect(reason.contains("顶层"), "失败原因必须点明顶层形状不对，got \(reason)")
            expect(
                (try? String(contentsOf: configFile, encoding: .utf8)) == original,
                "文件必须逐字保持原样")
        }
    }

    suite("setEventEnabled: events 存在但不是对象（是数组）→ fail closed") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let original = #"{ "selected_pack": "pika", "events": ["stop"] }"#
            writeFixture(original, to: configFile)

            let result = setEventEnabled(
                .stop, enabled: false, configFile: configFile, lockFile: lockFile)
            guard case .failure(.configReadFailure(let reason)) = result else {
                expect(false, "数组形状的 events 必须 fail closed，got \(result)")
                return
            }
            expect(reason.contains("events"), "失败原因必须点名 events，got \(reason)")
            expect(
                (try? String(contentsOf: configFile, encoding: .utf8)) == original,
                "文件必须逐字保持原样")
        }
    }

    suite("selectPack: 全新安装写出的 config.json 恰好是三个最小必需键，没有多也没有少") {
        withTempDirectory { root in
            // 这条护住「文件不存在 → 新建最小 config」这个分支：它不再走 `JSONEncoder`，所以键集合
            // 必须由测试来钉死，而不是靠 Codable 顺带保证。这条以前挂在 `setEventEnabled` 名下——
            // D23 定稿①之后 `setEventEnabled` 对缺失的 config fail closed（见 `EventEnabledSuite.swift`），
            // 「新建最小 config」这个分支今天唯一的调用方是 `selectPack`，所以测试跟着搬过来，而不是
            // 让这条护住的分支悄悄失去覆盖。
            let configFile = root.appendingPathComponent("config.json")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            makePackDirectory(at: userPacks.appendingPathComponent("pika", isDirectory: true))
            let lockFile = root.appendingPathComponent("config.lock")

            let result = selectPack(
                "pika", configFile: configFile, userPacksDirectory: userPacks, lockFile: lockFile)
            expect(result == .success(.selected(packID: "pika")), "got \(result)")

            let json = readRawConfigJSON(configFile)
            expect(
                json?.keys.sorted() == ["events", "master_volume", "selected_pack"],
                "全新 config.json 的顶层键必须恰好是三个最小必需键（starred_packs 缺失有默认语义），got"
                    + " \(String(describing: json?.keys.sorted()))")
            expect(
                json?["master_volume"] as? Double == ClaudioConfig.defaultMasterVolume,
                "全新 config.json 拿到文档写定的默认 master_volume")
            expect(
                json?["selected_pack"] as? String == "pika",
                "全新 config.json 的 selected_pack 必须是这次选中的包")
        }
    }

    // MARK: - selectPack（切一次包）——同一份 updateConfigJSON，同一套契约

    suite("selectPack: 未知顶层键与 master_volume 在一次切包后逐字幸存") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            makePackDirectory(at: userPacks.appendingPathComponent("psyduck", isDirectory: true))
            writeFixture(
                #"""
                { "selected_pack": "pika", "master_volume": 0.35, "night_dim": true, "events": { "stop": false } }
                """#, to: configFile)

            let result = selectPack(
                "psyduck", configFile: configFile, userPacksDirectory: userPacks,
                lockFile: root.appendingPathComponent("config.lock"))
            expect(result == .success(.selected(packID: "psyduck")), "切包应当成功，got \(result)")

            let json = readRawConfigJSON(configFile)
            expect(json?["selected_pack"] as? String == "psyduck", "唯一该变的键")
            expect(
                json?["night_dim"] as? Bool == true,
                "切包也会吃掉未知键（只是触发频率比静音低）——它必须活下来，got"
                    + " \(String(describing: json?["night_dim"]))")
            expect(
                json?["master_volume"] as? Double == 0.35,
                "master_volume 必须逐字保留，got \(String(describing: json?["master_volume"]))")
            expect(
                (json?["events"] as? [String: Any])?["stop"] as? Bool == false,
                "既有的静音状态必须挺过一次切包")
        }
    }

    suite("selectPack: master_volume 是字符串（损坏）→ fail closed，文件逐字未动") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            makePackDirectory(at: userPacks.appendingPathComponent("psyduck", isDirectory: true))
            let original = #"{ "selected_pack": "pika", "master_volume": "0.35" }"#
            writeFixture(original, to: configFile)

            let result = selectPack(
                "psyduck", configFile: configFile, userPacksDirectory: userPacks,
                lockFile: root.appendingPathComponent("config.lock"))
            guard case .failure(.configReadFailure) = result else {
                expect(false, "类型不对的 master_volume 必须让切包 fail closed，got \(result)")
                return
            }
            expect(
                (try? String(contentsOf: configFile, encoding: .utf8)) == original,
                "两个写路径共用同一份实现 → 同样一个字节都不写")
        }
    }

    suite("selectPack: events 的值是对象（更丰富的未来 schema）→ fail closed，整张表逐字幸存") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            makePackDirectory(at: userPacks.appendingPathComponent("psyduck", isDirectory: true))
            let original = #"""
                { "selected_pack": "pika", "events": { "stop": { "enabled": true, "volume": 0.5 } } }
                """#
            writeFixture(original, to: configFile)

            let result = selectPack(
                "psyduck", configFile: configFile, userPacksDirectory: userPacks,
                lockFile: root.appendingPathComponent("config.lock"))
            guard case .failure(.configReadFailure) = result else {
                expect(false, "对象形状的 events 值必须让切包 fail closed，got \(result)")
                return
            }
            expect(
                (try? String(contentsOf: configFile, encoding: .utf8)) == original,
                "整张 events 表必须逐字幸存")
        }
    }

    // MARK: - 数字保真：「未被 mutate 碰过的键逐字保留」对**数字键**也必须是真的
    //
    // 上面那一整组只证明了「键还在、值解析回来相等」。但 `JSONSerialization` 输出 Double 用 `%.17g`：
    // 一个原本干净的 `0.8` 会被**读-改-写**成 `0.80000000000000004`，`0.35` 变成 `0.34999999999999998`。
    // 于是「逐字保留」这句话对数字是假的——每点一次静音，磁盘上的 master_volume 就脏一次；`Setup.swift`
    // 首次装机（走 `selectPack`）当场就写出脏的 0.8，而 ENGINEERING.md 写的是 `"master_volume": 0.8`。
    // 这一组断言只认**字节**（`rawLiteral` / `compacted`），不认「解析回来相等」——后者对这个 bug 是
    // 全绿的，正是它让 bug 溜了进来。修法见 `ConfigMutation.swift` 的 `normalizedJSONNumbers`。

    suite("selectPack: 全新安装写出的 master_volume 逐字是 0.8，不是 0.80000000000000004") {
        withTempDirectory { root in
            // 同上一条：这条以前挂在 `setEventEnabled` 名下，D23 定稿①之后「新建最小 config」这个
            // 分支唯一的调用方是 `selectPack`，测试跟着搬过来。
            let configFile = root.appendingPathComponent("config.json")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            makePackDirectory(at: userPacks.appendingPathComponent("pika", isDirectory: true))
            let lockFile = root.appendingPathComponent("config.lock")

            let result = selectPack(
                "pika", configFile: configFile, userPacksDirectory: userPacks, lockFile: lockFile)
            expect(result == .success(.selected(packID: "pika")), "got \(result)")

            let text = readRawText(configFile)
            expect(
                rawLiteral(of: "master_volume", in: text) == "0.8",
                "ENGINEERING.md 文档里写的就是 `\"master_volume\": 0.8`，旧的 JSONEncoder 路径写的也是"
                    + " 0.8——保真读-改-写不能反而把它写脏，got"
                    + " \(String(describing: rawLiteral(of: "master_volume", in: text)))")
            expect(
                !text.contains("0.80000000000000004"),
                "`%.17g` 的那串尾巴一个字符都不该出现在用户的 config.json 里，got \(text)")
        }
    }

    suite("setEventEnabled: 一份原本干净的 master_volume: 0.35，读-改-写之后磁盘上仍逐字是 0.35") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            // 静音钮**不拥有** master_volume：它连碰都没碰这个键，而旧实现照样把它改写了。
            writeFixture(
                #"{ "selected_pack": "pika", "master_volume": 0.35 }"#, to: configFile)

            let result = setEventEnabled(
                .stop, enabled: false, configFile: configFile, lockFile: lockFile)
            expect(result == .success(.updated(event: .stop, enabled: false)), "got \(result)")

            let text = readRawText(configFile)
            expect(
                rawLiteral(of: "master_volume", in: text) == "0.35",
                "没被 mutate 碰过的数字键必须逐字不变，got"
                    + " \(String(describing: rawLiteral(of: "master_volume", in: text)))")
            expect(
                !text.contains("0.34999999999999998"),
                "每点一次静音就把用户的音量写脏一点，是这次修复要杀死的退化，got \(text)")
        }
    }

    suite("setEventEnabled: 写回后 events 里的 true 仍是 true，绝不被数字规范化变成 1") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(
                #"{ "selected_pack": "pika", "events": { "notification": true } }"#, to: configFile)

            let result = setEventEnabled(
                .stop, enabled: false, configFile: configFile, lockFile: lockFile)
            expect(result == .success(.updated(event: .stop, enabled: false)), "got \(result)")

            let text = readRawText(configFile)
            // 数字规范化如果误把 `__NSCFBoolean` 当成 `__NSCFNumber`（JSON 的 `true` 和 `1` 桥接后
            // 只差这一个 CFTypeID），`"notification": true` 会被写成 `"notification": 1`——那不是修好，
            // 那是一个**新的**数据损坏，而且正好是读侧 `isJSONBoolean` 拼命要挡的那一种（写成 1 之后，
            // 下一次写就会 fail closed，用户当场被锁死）。
            expect(
                rawLiteral(of: "notification", in: text) == "true",
                "布尔必须逐字写回 true，绝不能变成 1，got"
                    + " \(String(describing: rawLiteral(of: "notification", in: text)))")
            expect(
                rawLiteral(of: "stop", in: text) == "false",
                "刚翻的那一位也必须是 false（不是 0），got"
                    + " \(String(describing: rawLiteral(of: "stop", in: text)))")
            // 而且它必须还能被自己的读路径读回来——一次写脏就会让下一次写 fail closed。
            expect(
                probeConfigRewritable(configFile: configFile) == .rewritable,
                "写完的文件必须仍然是自己读得懂的（否则第二次静音就永久失败了）")
        }
    }

    suite("setEventEnabled: 未知键里**嵌套**的数字（对象里、数组里）同样不被写脏") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            // 数字规范化必须**递归**：只处理顶层的 master_volume 等于承认「未知键里的数字会被写脏」,
            // 那正是这次要修的 bug 本身。这里的 `night_dim.level` / `curve[0]` 是 v1 模型完全不认识的
            // 键里的数字，它们必须和 master_volume 一样逐字幸存。
            writeFixture(
                #"""
                { "selected_pack": "pika", "night_dim": { "level": 0.35, "on": true }, "curve": [0.8, 1, false] }
                """#, to: configFile)

            let result = setEventEnabled(
                .stop, enabled: false, configFile: configFile, lockFile: lockFile)
            expect(result == .success(.updated(event: .stop, enabled: false)), "got \(result)")

            let compact = compacted(readRawText(configFile))
            expect(
                compact.contains(#""night_dim":{"level":0.35,"on":true}"#),
                "未知对象里的数字要逐字保留、布尔要保持布尔，got \(compact)")
            expect(
                compact.contains(#""curve":[0.8,1,false]"#),
                "未知**数组**里的数字/布尔同样要逐字保留（规范化必须递归进数组），got \(compact)")
        }
    }

    suite("setEventEnabled: 超出 Double 精度的大整数逐字保留（整数绝不走 doubleValue）") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            // 9007199254740993 == 2^53 + 1：Double 表示不了它（会变成 ...992）。整数本来就没被
            // `%.17g` 弄脏过，所以规范化对它们的正解是**一个字节都不动**——任何「统一走 doubleValue」
            // 的写法都会在这里当场丢精度。
            writeFixture(
                #"{ "selected_pack": "pika", "installed_at": 9007199254740993 }"#, to: configFile)

            let result = setEventEnabled(
                .stop, enabled: false, configFile: configFile, lockFile: lockFile)
            expect(result == .success(.updated(event: .stop, enabled: false)), "got \(result)")

            let text = readRawText(configFile)
            expect(
                rawLiteral(of: "installed_at", in: text) == "9007199254740993",
                "超出 Double 精度的整数必须逐字保留，got"
                    + " \(String(describing: rawLiteral(of: "installed_at", in: text)))")
        }
    }

    suite("setEventEnabled: 连点两次静音，第二次写出的字节与第一次完全一致（不会一次比一次脏）") {
        withTempDirectory { root in
            // 收敛性：真正的「保真」意味着写操作是**幂等**的——同样的输入写出同样的字节。旧行为里
            // 每一轮读-改-写都会让 0.8 再脏一点/维持脏，这条直接把「文件不再漂移」钉死。
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(
                #"{ "selected_pack": "pika", "master_volume": 0.8, "events": { "stop": true } }"#,
                to: configFile)

            _ = setEventEnabled(.stop, enabled: false, configFile: configFile, lockFile: lockFile)
            let afterFirst = readRawText(configFile)
            _ = setEventEnabled(.stop, enabled: false, configFile: configFile, lockFile: lockFile)
            let afterSecond = readRawText(configFile)

            expect(
                afterFirst == afterSecond,
                "同一次静音写两遍必须产出逐字相同的文件，got\n\(afterFirst)\n---\n\(afterSecond)")
            expect(
                rawLiteral(of: "master_volume", in: afterSecond) == "0.8",
                "两轮读-改-写之后 master_volume 仍然逐字是 0.8，got"
                    + " \(String(describing: rawLiteral(of: "master_volume", in: afterSecond)))")
        }
    }

    suite("selectPack: 首次装机（config 不存在，走 Setup → selectPack）写出的 master_volume 逐字是 0.8") {
        withTempDirectory { root in
            // `Setup.swift` 的首次装机就是走这条路（它调 `selectPack`）——所以「新机器上的第一份
            // config.json 就是脏的」正是这个退化最常见的现场。
            let configFile = root.appendingPathComponent("config.json")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            makePackDirectory(at: userPacks.appendingPathComponent("psyduck", isDirectory: true))

            let result = selectPack(
                "psyduck", configFile: configFile, userPacksDirectory: userPacks,
                lockFile: root.appendingPathComponent("config.lock"))
            expect(result == .success(.selected(packID: "psyduck")), "got \(result)")

            let text = readRawText(configFile)
            expect(
                rawLiteral(of: "master_volume", in: text) == "0.8",
                "首次装机写出的 config.json 必须和 ENGINEERING.md 里的一模一样，got"
                    + " \(String(describing: rawLiteral(of: "master_volume", in: text)))")
            expect(!text.contains("0.80000000000000004"), "got \(text)")
        }
    }

    // MARK: - fail closed 必须给出路：错误信息本身就是修复指令
    //
    // 判定不放宽（放宽就是回到数据丢失），但一份「某字段畸形、旧读路径照常能读」的 config（`play` /
    // `doctor` 一切正常，声音照响）会让**所有写操作永久失败**——静音失败、切包也失败——而 `Setup.swift`
    // 因为 config 已存在**不会重建它**。用户在 App 内没有任何自愈途径，那么这句错误信息就是他手上仅有
    // 的工具：它必须直接告诉他改哪个键、改成什么、以及第二条出路。

    suite("setEventEnabled: events.stop 是数字 1 → 失败原因是**可执行指令**（哪个键 / 必须是什么 / 当前是什么 / 怎么修）") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(#"{ "selected_pack": "pika", "events": { "stop": 1 } }"#, to: configFile)

            let result = setEventEnabled(
                .stop, enabled: false, configFile: configFile, lockFile: lockFile)
            guard case .failure(.configReadFailure(let reason)) = result else {
                expect(false, "got \(result)")
                return
            }
            expect(reason.contains("events.stop"), "必须点名是哪个键，got \(reason)")
            expect(reason.contains("true/false"), "必须说清它应该是什么，got \(reason)")
            expect(reason.contains("数字 1"), "必须说清它现在是什么，got \(reason)")
            expect(
                reason.contains("请手工修正该值") && reason.contains("删除该文件"),
                "必须给出两条真实出路——否则用户被永久锁死在一个既播得响、又写不进的 config 上，got \(reason)")
            expect(
                reason.contains("会丢失自定义字段"),
                "「删掉重建」的代价必须一起说，否则这是一句诱导用户丢数据的建议，got \(reason)")
            expect(reason.contains(configFile.path), "必须带上是哪个文件，got \(reason)")
        }
    }

    suite("setEventEnabled: master_volume 是字符串 → 原因带上当前值与两条出路") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(#"{ "selected_pack": "pika", "master_volume": "0.8" }"#, to: configFile)

            let result = setEventEnabled(
                .stop, enabled: false, configFile: configFile, lockFile: lockFile)
            guard case .failure(.configReadFailure(let reason)) = result else {
                expect(false, "got \(result)")
                return
            }
            expect(
                reason.contains("master_volume") && reason.contains("0.0–1.0"),
                "必须说清 master_volume 应该长什么样，got \(reason)")
            expect(
                reason.contains(#"字符串 "0.8""#),
                "必须把用户文件里当前那个值原样引回来（`\"0.8\"` 是字符串，不是数字——一眼可见），got \(reason)")
            expect(
                reason.contains("请手工修正该值") && reason.contains("删除该文件"),
                "got \(reason)")
        }
    }

    // MARK: - probeConfigRewritable：doctor / gui 的只读探针，与写路径同一份判定

    suite("probeConfigRewritable: 文件不存在 → .absent（全新安装，不是错误）") {
        withTempDirectory { root in
            expect(
                probeConfigRewritable(configFile: root.appendingPathComponent("config.json"))
                    == .absent,
                "还没有 config.json 只是「还没写过」，写路径会新建它——绝不能报成畸形")
        }
    }

    suite("probeConfigRewritable: 一份合法 config → .rewritable") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(
                #"{ "selected_pack": "pika", "master_volume": 0.35, "night_dim": true }"#,
                to: configFile)
            expect(
                probeConfigRewritable(configFile: configFile) == .rewritable,
                "未知键不是损坏——带 night_dim 的 config 照样可以被安全重写")
        }
    }

    suite("probeConfigRewritable: 畸形 config → .malformed，reason 与真去写时拿到的那一句**逐字相同**") {
        withTempDirectory { root in
            // 「能不能写」的定义只能有一个：doctor 说的话必须就是写路径真失败时说的话，否则用户会
            // 遇到「doctor 绿灯但静音失败」（或反过来）这种更糟的不一致。
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(#"{ "selected_pack": "pika", "events": { "stop": 1 } }"#, to: configFile)

            guard case .malformed(let probedReason) = probeConfigRewritable(configFile: configFile)
            else {
                expect(false, "畸形 config 必须探测为 .malformed")
                return
            }
            let writeResult = setEventEnabled(
                .stop, enabled: false, configFile: configFile, lockFile: lockFile)
            guard case .failure(.configReadFailure(let writeReason)) = writeResult else {
                expect(false, "got \(writeResult)")
                return
            }
            expect(
                probedReason == writeReason,
                "探针与写路径必须给出同一句话，got 探针=\(probedReason) / 写路径=\(writeReason)")
        }
    }

    suite("probeConfigRewritable: 只读探针——一个字节都不写") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let original = #"{ "selected_pack": "pika", "events": { "stop": 1 } }"#
            writeFixture(original, to: configFile)
            _ = probeConfigRewritable(configFile: configFile)
            expect(readRawText(configFile) == original, "诊断绝不能改用户的文件")
        }
    }

    suite("selectPack: 一份缺了 selected_pack 的 config.json 视为损坏 → fail closed（保持既有契约）") {
        withTempDirectory { root in
            // `selected_pack` 是 v1 config 唯一的必需键。缺了它的文件不是 claudio 写出来的东西——
            // 旧的 Codable 解码器也正是在这里 throw 的，这条把那个既有行为钉死，避免新的
            // JSONSerialization 路径把它悄悄放宽成「顺手补上」。
            let configFile = root.appendingPathComponent("config.json")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            makePackDirectory(at: userPacks.appendingPathComponent("psyduck", isDirectory: true))
            let original = #"{ "master_volume": 0.35 }"#
            writeFixture(original, to: configFile)

            let result = selectPack(
                "psyduck", configFile: configFile, userPacksDirectory: userPacks,
                lockFile: root.appendingPathComponent("config.lock"))
            guard case .failure(.configReadFailure(let reason)) = result else {
                expect(false, "缺少 selected_pack 的 config.json 必须 fail closed，got \(result)")
                return
            }
            expect(reason.contains("selected_pack"), "失败原因必须点名缺了哪个键，got \(reason)")
            expect(
                (try? String(contentsOf: configFile, encoding: .utf8)) == original,
                "文件必须逐字保持原样")
        }
    }

    // MARK: - 非有限数字（-1e400）绝不再让进程 abort（本轮 /ship 评审 P0，实测 exit 134）
    //
    // `{"selected_pack":"a","master_volume":-1e400}` 会被 `JSONSerialization` 解析成 `-inf`
    // （正溢出 `1e400` 在**解析期**就被 Foundation 拒了，只有**负**溢出能穿进来——实测钉在
    // `JSONSafeWrite.swift` 的注释里）。`-inf` 一路穿过既有闸门，直到 `JSONSerialization.data(withJSONObject:)`
    // 抛出**不可捕获**的 Objective-C `NSInvalidArgumentException`——`do/catch` 接不住，进程 `abort()`
    // （本机实测：exit 134）。见 `firstUnwritableJSONValue(in:keyPath:depth:path:)`。

    suite("setEventEnabled: master_volume 是 -1e400（解析成 -inf）→ fail closed，绝不 abort，文件逐字未动") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let original = #"{ "selected_pack": "pika", "master_volume": -1e400 }"#
            writeFixture(original, to: configFile)

            // 到达这一行本身就是这条测试的第一重断言：如果 fail-closed 闸门没接住，
            // `JSONSerialization.data(withJSONObject:)` 会抛出不可捕获的 ObjC 异常，
            // 整个测试进程会 SIGABRT（exit 134），这条 suite 后面的每一行、乃至同一次
            // `swift run` 里排在它之后的所有 suite 都不会再执行——「跑到这里」就是「没有 abort」。
            let result = setEventEnabled(
                .stop, enabled: false, configFile: configFile, lockFile: lockFile)
            guard case .failure(.configReadFailure(let reason)) = result else {
                expect(false, "-1e400（解析成 -inf）必须 fail closed，got \(result)")
                return
            }
            expect(
                reason.contains("master_volume"),
                "失败原因必须点名是 master_volume 这个键，got \(reason)")
            expect(
                reason.contains("有限数字"),
                "失败原因必须说清楚它该是一个有限数字，got \(reason)")
            expect(
                (try? String(contentsOf: configFile, encoding: .utf8)) == original,
                "fail closed 的含义是一个字节都不写——文件必须逐字保持原样")
        }
    }

    suite("selectPack: master_volume 是 -1e400（解析成 -inf）→ fail closed，绝不 abort，文件逐字未动") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            makePackDirectory(at: userPacks.appendingPathComponent("psyduck", isDirectory: true))
            let original = #"{ "selected_pack": "pika", "master_volume": -1e400 }"#
            writeFixture(original, to: configFile)

            let result = selectPack(
                "psyduck", configFile: configFile, userPacksDirectory: userPacks,
                lockFile: root.appendingPathComponent("config.lock"))
            guard case .failure(.configReadFailure(let reason)) = result else {
                expect(false, "-1e400（解析成 -inf）必须让切包 fail closed，got \(result)")
                return
            }
            expect(reason.contains("master_volume"), "got \(reason)")
            expect(
                (try? String(contentsOf: configFile, encoding: .utf8)) == original,
                "两个写路径共用同一份实现 → 同样一个字节都不写")
        }
    }

    suite(
        "setEventEnabled: -1e400 藏在一个未知顶层键的**对象**里（night_dim.level）→ 同样 fail closed"
    ) {
        withTempDirectory { root in
            // `night_dim` 是 v1 模型完全不认识的键——这条证明 firstUnwritableJSONValue 的递归
            // 会钻进未知键的嵌套对象里，而不是只查顶层的 master_volume。
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let original = #"{ "selected_pack": "pika", "night_dim": { "level": -1e400 } }"#
            writeFixture(original, to: configFile)

            let result = setEventEnabled(
                .stop, enabled: false, configFile: configFile, lockFile: lockFile)
            guard case .failure(.configReadFailure(let reason)) = result else {
                expect(false, "嵌套在未知键对象里的 -1e400 必须 fail closed，got \(result)")
                return
            }
            expect(
                reason.contains("night_dim.level"),
                "失败原因必须点名到具体的嵌套路径 night_dim.level，而不是只说「某处有问题」，got \(reason)")
            expect(
                (try? String(contentsOf: configFile, encoding: .utf8)) == original,
                "文件必须逐字保持原样")
        }
    }

    suite(
        "setEventEnabled: -1e400 藏在一个未知顶层键的**数组**里（x[0]）→ 同样 fail closed"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let original = #"{ "selected_pack": "pika", "x": [-1e400] }"#
            writeFixture(original, to: configFile)

            let result = setEventEnabled(
                .stop, enabled: false, configFile: configFile, lockFile: lockFile)
            guard case .failure(.configReadFailure(let reason)) = result else {
                expect(false, "嵌套在未知键数组里的 -1e400 必须 fail closed，got \(result)")
                return
            }
            expect(
                reason.contains("x[0]"),
                "失败原因必须点名到具体的数组下标 x[0]，got \(reason)")
            expect(
                (try? String(contentsOf: configFile, encoding: .utf8)) == original,
                "文件必须逐字保持原样")
        }
    }

    suite(
        "probeConfigRewritable: master_volume 是 -1e400 → .malformed（这是 doctor 假绿的另一半：写下去会 abort 的文件不能被诊断为可安全重写）"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(
                #"{ "selected_pack": "pika", "master_volume": -1e400 }"#, to: configFile)

            guard case .malformed(let reason) = probeConfigRewritable(configFile: configFile) else {
                expect(
                    false,
                    "-1e400 的 config 必须被探测为 .malformed，绝不能是 .rewritable，got"
                        + " \(probeConfigRewritable(configFile: configFile))")
                return
            }
            expect(reason.contains("master_volume"), "got \(reason)")
            expect(reason.contains("有限数字"), "got \(reason)")
        }
    }

    suite(
        "probeConfigRewritable 与 setEventEnabled 对 -1e400 给出的 reason 逐字相同（doctor 与写路径必须说同一句话）"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(
                #"{ "selected_pack": "pika", "master_volume": -1e400 }"#, to: configFile)

            guard case .malformed(let probedReason) = probeConfigRewritable(configFile: configFile)
            else {
                expect(false, "-1e400 的 config 必须探测为 .malformed")
                return
            }
            let writeResult = setEventEnabled(
                .stop, enabled: false, configFile: configFile, lockFile: lockFile)
            guard case .failure(.configReadFailure(let writeReason)) = writeResult else {
                expect(false, "got \(writeResult)")
                return
            }
            expect(
                probedReason == writeReason,
                "探针与写路径必须给出同一句话，got 探针=\(probedReason) / 写路径=\(writeReason)")
        }
    }

    suite(
        "setEventEnabled: JSON 嵌套超过 maxJSONNestingDepth（64）层 → fail closed，不炸栈"
    ) {
        withTempDirectory { root in
            // 一份病态嵌套的未知键（`x`）：真实文件的嵌套深度是 2（顶层 -> events），64 层给
            // 未来 schema 留了三十倍余量。这里刻意远超边界（100 层），只要证明「fail closed」，
            // 不需要钉死恰好第几层触发——递归函数本身如果没有深度闸门，这个层数足以在调试构建下
            // 观察到明显的调用栈增长，即便不一定真的 SIGSEGV。
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            var nested = "1"
            for _ in 0..<100 { nested = "{\"a\":\(nested)}" }
            let original = #"{ "selected_pack": "pika", "x": \#(nested) }"#
            writeFixture(original, to: configFile)

            let result = setEventEnabled(
                .stop, enabled: false, configFile: configFile, lockFile: lockFile)
            guard case .failure(.configReadFailure(let reason)) = result else {
                expect(false, "深度超限的 JSON 必须 fail closed（不是崩溃/挂起），got \(result)")
                return
            }
            expect(
                reason.contains("嵌套") && reason.contains("64"),
                "失败原因必须点明是嵌套深度问题，且提到具体的层数上限，got \(reason)")
            expect(
                (try? String(contentsOf: configFile, encoding: .utf8)) == original,
                "文件必须逐字保持原样")
        }
    }

    // MARK: - config.json 的有界 + 正规文件闸门：probeConfigRewritable 一侧
    //
    // `readConfigFileBounded` 用同一道 `O_NONBLOCK` + `fstat` 正规文件闸门 + 64 KiB 上限同时守着
    // `play` / `doctor` / `probeConfigRewritable` 三个读入口。`play`（PlaySuite.swift）与
    // `checkPackIntegrity`（DoctorSuite.swift）各有自己的一组；这里补上第三个读入口。

    suite("probeConfigRewritable: config.json 是一个目录 → .malformed，不是 .rewritable") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            try? FileManager.default.createDirectory(
                at: configFile, withIntermediateDirectories: true)

            guard case .malformed = probeConfigRewritable(configFile: configFile) else {
                expect(
                    false,
                    "目录形状的 config.json 必须探测为 .malformed，got"
                        + " \(probeConfigRewritable(configFile: configFile))")
                return
            }
        }
    }

    suite("probeConfigRewritable: config.json 是一个 FIFO → .malformed，且绝不挂起") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            makeFIFO(at: configFile)

            let started = Date()
            let result = probeConfigRewritable(configFile: configFile)
            let elapsed = Date().timeIntervalSince(started)

            guard case .malformed = result else {
                expect(false, "FIFO 形状的 config.json 必须探测为 .malformed，got \(result)")
                return
            }
            expect(elapsed < 5, "探测一个 FIFO 形状的 config.json 绝不能挂起，耗时 \(elapsed)s")
        }
    }

    suite(
        "probeConfigRewritable: 一份**合法、可完整解析**但超过 64 KiB 上限的 config.json → .malformed"
            + "（换一个不裸读大小上限的 Data(contentsOf:) 实现，这份文件会解析成功并报 .rewritable——"
            + "这条要钉的正是「上限本身在起作用」，而不是巧合地读到一份读不懂的文件）"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            // 刻意用一份**合法**的、只是被填充到超限的 JSON——其余每一处校验（selected_pack 是
            // 字符串、没有非有限数字……）都能过关。如果上限被拿掉，这份文件会被完整读入、解析成功、
            // 一路通过 parseRewritableConfig，报出 .rewritable。
            let padding = String(repeating: "x", count: (1 << 16) + 100)
            writeFixture(
                #"{ "selected_pack": "pika", "padding": "\#(padding)" }"#, to: configFile)

            guard case .malformed = probeConfigRewritable(configFile: configFile) else {
                expect(
                    false,
                    "超限的 config.json 必须探测为 .malformed（即使内容本身合法可解析），got"
                        + " \(probeConfigRewritable(configFile: configFile))")
                return
            }
        }
    }

    // MARK: - selected_pack 存在但类型不对（只测过「缺失」，没测过「类型错」）

    suite("setEventEnabled: selected_pack 是数字 42（不是字符串）→ fail closed，文件逐字未动") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let original = #"{ "selected_pack": 42 }"#
            writeFixture(original, to: configFile)

            let result = setEventEnabled(
                .stop, enabled: false, configFile: configFile, lockFile: lockFile)
            guard case .failure(.configReadFailure(let reason)) = result else {
                expect(false, "数字形状的 selected_pack 必须 fail closed，got \(result)")
                return
            }
            expect(reason.contains("selected_pack"), "失败原因必须点名 selected_pack，got \(reason)")
            expect(reason.contains("字符串"), "失败原因必须说清它该是字符串，got \(reason)")
            expect(
                (try? String(contentsOf: configFile, encoding: .utf8)) == original,
                "文件必须逐字保持原样")
        }
    }

    suite("selectPack: selected_pack 是数字 42（不是字符串）→ fail closed，文件逐字未动") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            makePackDirectory(at: userPacks.appendingPathComponent("psyduck", isDirectory: true))
            let original = #"{ "selected_pack": 42 }"#
            writeFixture(original, to: configFile)

            let result = selectPack(
                "psyduck", configFile: configFile, userPacksDirectory: userPacks,
                lockFile: root.appendingPathComponent("config.lock"))
            guard case .failure(.configReadFailure(let reason)) = result else {
                expect(false, "数字形状的 selected_pack 必须让切包 fail closed，got \(result)")
                return
            }
            expect(reason.contains("selected_pack") && reason.contains("字符串"), "got \(reason)")
            expect(
                (try? String(contentsOf: configFile, encoding: .utf8)) == original,
                "文件必须逐字保持原样")
        }
    }

    suite("setEventEnabled: selected_pack 是布尔 true（不是字符串）→ fail closed，文件逐字未动") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            // `true` 桥接成 NSNumber，一个天真的「不是字符串就当数字/别的」判断可能被它蒙混过去——
            // `selected_pack` 校验必须明确拒绝布尔，同 `isJSONBoolean` 在别处挡的那类静默强转。
            let original = #"{ "selected_pack": true }"#
            writeFixture(original, to: configFile)

            let result = setEventEnabled(
                .stop, enabled: false, configFile: configFile, lockFile: lockFile)
            guard case .failure(.configReadFailure(let reason)) = result else {
                expect(false, "布尔形状的 selected_pack 必须 fail closed，got \(result)")
                return
            }
            expect(reason.contains("selected_pack") && reason.contains("字符串"), "got \(reason)")
            expect(
                (try? String(contentsOf: configFile, encoding: .utf8)) == original,
                "文件必须逐字保持原样")
        }
    }

    suite("selectPack: selected_pack 是布尔 true（不是字符串）→ fail closed，文件逐字未动") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            makePackDirectory(at: userPacks.appendingPathComponent("psyduck", isDirectory: true))
            let original = #"{ "selected_pack": true }"#
            writeFixture(original, to: configFile)

            let result = selectPack(
                "psyduck", configFile: configFile, userPacksDirectory: userPacks,
                lockFile: root.appendingPathComponent("config.lock"))
            guard case .failure(.configReadFailure(let reason)) = result else {
                expect(false, "布尔形状的 selected_pack 必须让切包 fail closed，got \(result)")
                return
            }
            expect(reason.contains("selected_pack") && reason.contains("字符串"), "got \(reason)")
            expect(
                (try? String(contentsOf: configFile, encoding: .utf8)) == original,
                "文件必须逐字保持原样")
        }
    }

    // MARK: - probeConfigRewritable 必须验证父目录可写（`.unwritable`，与 `.malformed` 分开）
    //
    // 内容合法，但父目录只读（只读卷 / 权限被改）：原子写要求父目录可写，少了这一问 doctor
    // 会对着这种局面打印「✓ 可安全重写」，用户真去点静音钮时它一次次失败。

    suite(
        "probeConfigRewritable: 内容合法但父目录只读（chmod 0o500）→ .unwritable，不是 .rewritable；"
            + "configRewritabilityResult 报 warning；真实写也确实失败（探针与写路径必须一致）"
    ) {
        guard geteuid() != 0 else {
            print("  ⚠︎ 跳过：当前以 root 运行，chmod 只读目录挡不住 root 写入")
            return
        }
        withTempDirectory { root in
            let restrictedDirectory = root.appendingPathComponent("restricted", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: restrictedDirectory, withIntermediateDirectories: true)
            let configFile = restrictedDirectory.appendingPathComponent("config.json")
            writeFixture(
                #"{ "selected_pack": "pika", "master_volume": 0.5 }"#, to: configFile)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o500], ofItemAtPath: restrictedDirectory.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: restrictedDirectory.path)
            }

            guard case .unwritable(let probedReason) = probeConfigRewritable(configFile: configFile)
            else {
                expect(
                    false,
                    "内容合法但父目录只读的 config 必须探测为 .unwritable，got"
                        + " \(probeConfigRewritable(configFile: configFile))")
                return
            }
            expect(
                probedReason.contains(restrictedDirectory.path),
                "原因必须点名是哪个目录不可写，got \(probedReason)")

            let doctorResult = configRewritabilityResult(configFile: configFile)
            expect(
                doctorResult.severity == .warning,
                "目录不可写与内容畸形一样，都不该把一台声音一切正常的机器报成硬失败，got"
                    + " \(doctorResult.severity)")
            expect(
                doctorResult.message.contains("写不进去")
                    && doctorResult.message.contains(restrictedDirectory.path),
                "doctor 的措辞必须讲清楚是「目录写不进去」而不是「文件本身有问题」，got"
                    + " \(doctorResult.message)")

            // 探针与真实写路径必须给出同一个判断：这份文件内容没问题，但真去写确实会失败。
            let writeResult = setEventEnabled(
                .stop, enabled: false, configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"))
            guard case .failure(.configWriteFailure) = writeResult else {
                expect(
                    false,
                    "父目录只读时真去写也必须失败（探针与写路径必须一致），got \(writeResult)")
                return
            }
        }
    }
}
