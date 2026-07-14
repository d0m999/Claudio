import ClaudioCore
import Dispatch
import Foundation

// MARK: - D7: 三个不同类型的 config.json 写者混跑，仍然互斥、永不撕裂
//
// `EventEnabledSuite.swift` 已经有一条单写者压力测试（`DispatchQueue.concurrentPerform(iterations:
// 50)` 反复调用同一个 `setEventEnabled`），证明的是「这一个函数自己跟自己竞争时不会撕裂文件」。这条
// 把它扩成**三个不同的写者**——`selectPack` / `setEventEnabled` / `setMasterVolume`——在同一把
// `config.lock` 上真·混跑，证明「三者共享同一把锁」这句话对三者都成立，不只是对其中两个各自的成对组合
// 成立。断言的形状完全照抄那条单写者压力测试：文件永远不撕裂、旧键永远不丢、每次调用要么真成功要么
// 各自的 `.lockBusy`，绝不静默损坏。

/// 三个写者各自的错误类型不同（`UseError` / `SetEventEnabledError` / `SetMasterVolumeError`），所以
/// 收集器把每次调用的结果先**折叠**成这一个共享形状，再统一断言——而不是给每个写者各配一套断言。
private enum ConcurrentWriteOutcome: Sendable, Equatable {
    case succeeded
    case lockBusy
    /// 任何不是「真成功」也不是「锁忙」的结果——config 损坏、写失败等等，在这条压力测试里**不应该
    /// 出现**（起始 fixture 是合法的，父目录全程可写）；出现了就是撕裂/损坏，测试必须能看见它，
    /// 而不是被三种不同的错误类型悄悄吸收掉。
    case otherFailure(String)
}

/// Thread-safe collector for the folded outcomes above. Mirrors `EventEnabledSuite.swift`'s
/// `SetEventEnabledOutcomeCollector` — file-scope `private` there too, so this file needs its own
/// copy over the shared ``ConcurrentWriteOutcome`` shape.
private final class ConcurrentOutcomeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _outcomes: [ConcurrentWriteOutcome] = []

    func append(_ outcome: ConcurrentWriteOutcome) {
        lock.lock()
        _outcomes.append(outcome)
        lock.unlock()
    }

    var outcomes: [ConcurrentWriteOutcome] {
        lock.lock()
        defer { lock.unlock() }
        return _outcomes
    }
}

@MainActor
func runConfigConcurrencySuites() {
    suite(
        "config.json: selectPack / setEventEnabled / setMasterVolume 混跑在同一把 config.lock 上"
            + "（D7）——文件永远不撕裂、旧键永远不丢，每次调用要么真成功要么各自的 .lockBusy"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: userPacks.appendingPathComponent("minimal-chime", isDirectory: true),
                withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(
                at: userPacks.appendingPathComponent("second-pack", isDirectory: true),
                withIntermediateDirectories: true)
            writeFixture(
                #"""
                { "selected_pack": "minimal-chime", "master_volume": 0.5, "night_dim": true, "events": { "stop": true } }
                """#, to: configFile)

            let collector = ConcurrentOutcomeCollector()
            let iterations = 60
            DispatchQueue.concurrentPerform(iterations: iterations) { index in
                switch index % 3 {
                case 0:
                    let packID = index % 2 == 0 ? "minimal-chime" : "second-pack"
                    let result = selectPack(
                        packID, configFile: configFile, userPacksDirectory: userPacks,
                        lockFile: lockFile)
                    switch result {
                    case .success: collector.append(.succeeded)
                    case .failure(.lockBusy): collector.append(.lockBusy)
                    case .failure(let error): collector.append(.otherFailure("selectPack: \(error)"))
                    }
                case 1:
                    let event = Event.allCases[index % Event.allCases.count]
                    let result = setEventEnabled(
                        event, enabled: index % 2 == 0, configFile: configFile, lockFile: lockFile)
                    switch result {
                    case .success: collector.append(.succeeded)
                    case .failure(.lockBusy): collector.append(.lockBusy)
                    case .failure(let error):
                        collector.append(.otherFailure("setEventEnabled: \(error)"))
                    }
                default:
                    let volume = Double(index % 11) / 10.0
                    let result = setMasterVolume(volume, configFile: configFile, lockFile: lockFile)
                    switch result {
                    case .success: collector.append(.succeeded)
                    case .failure(.lockBusy): collector.append(.lockBusy)
                    case .failure(let error):
                        collector.append(.otherFailure("setMasterVolume: \(error)"))
                    }
                }
            }

            let outcomes = collector.outcomes
            expect(
                outcomes.count == iterations,
                "every concurrent call must produce an outcome, got \(outcomes.count) of \(iterations)"
            )

            for (index, outcome) in outcomes.enumerated() {
                if case .otherFailure(let description) = outcome {
                    expect(
                        false,
                        "call \(index) must be either a real success or lockBusy — never a"
                            + " torn/corrupted write, got \(description)")
                }
            }

            // (a) 文件必须仍然是合法、可解析的 JSON——撕裂的写在这里会直接解析失败。
            guard let data = try? Data(contentsOf: configFile),
                let parsed = try? JSONSerialization.jsonObject(with: data),
                let json = parsed as? [String: Any]
            else {
                expect(
                    false,
                    "经过 \(iterations) 个三写者混跑之后，config.json 必须仍是一份合法、可解析的 JSON")
                return
            }
            // (b) + (c) 三个 v1 键与那个未知顶层键必须一个不少——三个写者混跑绝不能让任何一方的键
            // 集合丢失（`selectPack` 只碰 `selected_pack`，`setEventEnabled` 只碰 `events`，
            // `setMasterVolume` 只碰 `master_volume`，`night_dim` 谁都不碰）。
            expect(
                Set(json.keys) == Set(["selected_pack", "master_volume", "events", "night_dim"]),
                "混跑之后顶层键集合必须逐一保留（已知键 + 未知键），got \(json.keys.sorted())")
            expect(
                json["night_dim"] as? Bool == true,
                "未知顶层键的值必须原样幸存，got \(String(describing: json["night_dim"]))")
            let selectedPack = json["selected_pack"] as? String
            expect(
                selectedPack == "minimal-chime" || selectedPack == "second-pack",
                "selected_pack 必须仍是某一次 selectPack 调用真正写下的值，got"
                    + " \(String(describing: selectedPack))")
            let masterVolume = json["master_volume"] as? Double
            expect(
                masterVolume != nil && masterVolume! >= 0.0 && masterVolume! <= 1.0,
                "master_volume 必须仍在合法范围内，got \(String(describing: masterVolume))")
            let events = json["events"] as? [String: Any]
            expect(
                events != nil && !(events!.isEmpty),
                "events 表必须仍然存在且非空——并发写不能把它写没了")
        }
    }
}
