import ClaudioCore
import Foundation

private let workBuddyTransformRoot = "/Users/tester/.claudio"
private let workBuddyTransformBinary = "\(workBuddyTransformRoot)/bin/claudio"
private let workBuddyTransformID = UUID(
    uuidString: "BBBBBBBB-1111-4222-8333-444444444444")!

private func workBuddyOwnedCommands(_ root: [String: Any]) -> [MatchedHostHookCommand] {
    guard let hooks = root["hooks"] as? [String: Any] else { return [] }
    return hooks.values.flatMap { ($0 as? [Any]) ?? [] }.flatMap {
        (($0 as? [String: Any])?["hooks"] as? [Any]) ?? []
    }.compactMap {
        (($0 as? [String: Any])?["command"] as? String).flatMap {
            matchedHostHookCommand(inHookCommand: $0, claudioRoot: workBuddyTransformRoot)
        }
    }.filter { $0.host == .workBuddy }
}

@MainActor
func runWorkBuddyHooksTransformSuites() {
    suite("WorkBuddy connect：只写四绑定、五条命令，并保留未知配置") {
        let original: [String: Any] = [
            "claw": ["opaque": true],
            "hooks": [
                "Stop": [
                    [
                        "matcher": "third",
                        "hooks": [["type": "command", "command": "echo keep"]],
                    ]
                ],
                "SubagentStop": [
                    ["hooks": [["type": "command", "command": "echo third-agent"]]]
                ],
            ],
        ]
        guard
            case .success(let mutation) = connectWorkBuddyHooks(
                root: original,
                claudioRoot: workBuddyTransformRoot,
                claudioBinaryPath: workBuddyTransformBinary,
                installationID: workBuddyTransformID)
        else {
            expect(false, "合法 WorkBuddy 配置必须可连接")
            return
        }
        expect(mutation.changed, "首次连接必须产生写入")
        let owned = workBuddyOwnedCommands(mutation.root)
        expect(owned.count == 5, "四个 binding 必须安装五条自有命令")
        expect(
            Set(owned.map(\.nativeEvent)) == [
                "UserPromptSubmit", "Stop", "SubagentStop", "Notification",
            ],
            "只能安装四类已证明的事件，got \(owned.map(\.nativeEvent))")
        expect(owned.allSatisfy { $0.installationID == workBuddyTransformID }, "五条 hook 必须同代次")
        expect((mutation.root["claw"] as? [String: Any])?["opaque"] as? Bool == true, "未知顶层键必须保留")
        let stopGroups = ((mutation.root["hooks"] as? [String: Any])?["Stop"] as? [Any]) ?? []
        expect(stopGroups.count == 2, "第三方 Stop group 必须保留并追加 Claudio group")
        let subagentGroups =
            ((mutation.root["hooks"] as? [String: Any])?["SubagentStop"] as? [Any]) ?? []
        expect(subagentGroups.count == 2, "第三方 SubagentStop group 必须保留")
        expect(
            hostIntegrationHookCommand(
                host: .workBuddy,
                nativeEvent: "StopFailure",
                installationID: workBuddyTransformID,
                claudioBinaryPath: workBuddyTransformBinary) == nil,
            "未实现的官方 binding 不得生成可执行命令")
    }

    suite("WorkBuddy Notification matcher：任一缺失为 incomplete，重复、错配和混代为 conflict") {
        let connected = try! connectWorkBuddyHooks(
            root: [:], claudioRoot: workBuddyTransformRoot,
            claudioBinaryPath: workBuddyTransformBinary, installationID: workBuddyTransformID
        ).get()
        let hooks = connected.root["hooks"] as! [String: Any]
        let notifications = hooks["Notification"] as! [[String: Any]]
        expect(
            notifications.compactMap { $0["matcher"] as? String } == WorkBuddyNotification.subtypes,
            "必须是两个独立、确定顺序的 matcher")
        expect(
            Set(
                workBuddyOwnedCommands(connected.root).filter { $0.nativeEvent == "Notification" }
                    .map(\.installationID)) == [workBuddyTransformID],
            "两个 matcher 必须共用一个 installation ID")
        for index in notifications.indices {
            var next = connected.root
            var partialHooks = hooks
            partialHooks["Notification"] = [notifications[index]]
            next["hooks"] = partialHooks
            expect(
                inspectWorkBuddyHooks(root: next, claudioBinaryPath: workBuddyTransformBinary)
                    == .success(
                        .partial(
                            installationID: workBuddyTransformID,
                            missingNativeEvents: ["Notification"])),
                "任一 matcher 缺失都必须显示 Notification 不完整")
        }
        for mode in ["duplicate", "wrong", "absent", "type", "generation", "misplaced"] {
            var next = connected.root
            var changedHooks = hooks
            var groups = notifications
            switch mode {
            case "duplicate": groups.append(notifications[0])
            case "wrong": groups[0]["matcher"] = "permission_prompt|idle_prompt"
            case "absent": groups[0].removeValue(forKey: "matcher")
            case "type": groups[0]["matcher"] = 42
            case "generation":
                groups[1]["hooks"] = [
                    [
                        "type": "command",
                        "command": hostIntegrationHookCommand(
                            host: .workBuddy, nativeEvent: "Notification", installationID: UUID(),
                            claudioBinaryPath: workBuddyTransformBinary)!,
                    ]
                ]
            default:
                changedHooks["Stop"] = groups
            }
            changedHooks["Notification"] = groups
            next["hooks"] = changedHooks
            if case .success(.conflict) = inspectWorkBuddyHooks(
                root: next, claudioBinaryPath: workBuddyTransformBinary)
            {
                expect(true, "\(mode) 正确拒绝")
            } else {
                expect(false, "\(mode) 必须成为 conflict")
            }
            let repaired = try! connectWorkBuddyHooks(
                root: next, claudioRoot: workBuddyTransformRoot,
                claudioBinaryPath: workBuddyTransformBinary, installationID: workBuddyTransformID
            ).get()
            expect(
                inspectWorkBuddyHooks(
                    root: repaired.root, claudioBinaryPath: workBuddyTransformBinary)
                    == .success(.configured(installationID: workBuddyTransformID)),
                "\(mode) 可经现有 repair 恢复")
        }
    }

    suite("WorkBuddy Notification：第三方同 matcher、未知字段与未来事件在连接及断开后保留") {
        let original: [String: Any] = [
            "unknown": ["enabled": true],
            "hooks": [
                "Notification": [
                    [
                        "matcher": "idle_prompt", "unknown": "keep",
                        "hooks": [["type": "command", "command": "echo third", "future": 42]],
                    ]
                ],
                "FutureEvent": [["hooks": [["type": "command", "command": "echo future"]]]],
            ],
        ]
        let connected = try! connectWorkBuddyHooks(
            root: original, claudioRoot: workBuddyTransformRoot,
            claudioBinaryPath: workBuddyTransformBinary, installationID: workBuddyTransformID
        ).get()
        expect(
            inspectWorkBuddyHooks(root: connected.root, claudioBinaryPath: workBuddyTransformBinary)
                == .success(.configured(installationID: workBuddyTransformID)),
            "第三方同 matcher 不算自有重复")
        let disconnected = try! disconnectWorkBuddyHooks(
            root: connected.root,
            claudioBinaryPath: workBuddyTransformBinary, installationID: workBuddyTransformID
        ).get()
        expect(disconnected.removedCount == 5, "断开必须精确移除五条自有命令")
        expect(NSDictionary(dictionary: disconnected.root).isEqual(to: original), "第三方与未知字段必须完整保留")
    }

    suite("WorkBuddy inspect：新增 binding 的缺失、重复与错误 matcher 失败关闭") {
        guard
            case .success(let connected) = connectWorkBuddyHooks(
                root: [:], claudioRoot: workBuddyTransformRoot,
                claudioBinaryPath: workBuddyTransformBinary,
                installationID: workBuddyTransformID)
        else {
            expect(false, "测试前提：五条 WorkBuddy hook 可生成")
            return
        }
        var root = connected.root
        var hooks = root["hooks"] as! [String: Any]
        let subagent = hooks["SubagentStop"] as! [Any]
        hooks.removeValue(forKey: "SubagentStop")
        root["hooks"] = hooks
        expect(
            inspectWorkBuddyHooks(root: root, claudioBinaryPath: workBuddyTransformBinary)
                == .success(
                    .partial(
                        installationID: workBuddyTransformID,
                        missingNativeEvents: ["SubagentStop"])),
            "缺少 SubagentStop 必须显式呈现 incomplete")

        hooks["SubagentStop"] = subagent + subagent
        root["hooks"] = hooks
        guard
            case .success(.conflict(let duplicateReason)) = inspectWorkBuddyHooks(
                root: root, claudioBinaryPath: workBuddyTransformBinary)
        else {
            expect(false, "重复自有 SubagentStop 必须冲突")
            return
        }
        expect(duplicateReason.contains("重复"), "重复冲突应可诊断")

        var wrong = subagent[0] as! [String: Any]
        wrong["matcher"] = "permission_prompt"
        hooks["SubagentStop"] = [wrong]
        root["hooks"] = hooks
        guard
            case .success(.conflict(let matcherReason)) = inspectWorkBuddyHooks(
                root: root, claudioBinaryPath: workBuddyTransformBinary)
        else {
            expect(false, "非 Notification 自有 hook 的 matcher 必须冲突")
            return
        }
        expect(matcherReason.contains("matcher"), "matcher 冲突应可诊断")
    }

    suite("WorkBuddy connect：完整 current 配置幂等，旧 helper 路径会归一") {
        guard
            case .success(let first) = connectWorkBuddyHooks(
                root: [:],
                claudioRoot: workBuddyTransformRoot,
                claudioBinaryPath: workBuddyTransformBinary,
                installationID: workBuddyTransformID),
            case .success(let second) = connectWorkBuddyHooks(
                root: first.root,
                claudioRoot: workBuddyTransformRoot,
                claudioBinaryPath: workBuddyTransformBinary,
                installationID: UUID())
        else {
            expect(false, "测试前提：WorkBuddy connect 必须成功")
            return
        }
        expect(!second.changed, "健康 current hooks 重连必须零写入")

        let relocatedBinary = "\(workBuddyTransformRoot)/libexec/claudio"
        guard
            case .success(let relocated) = connectWorkBuddyHooks(
                root: [:],
                claudioRoot: workBuddyTransformRoot,
                claudioBinaryPath: relocatedBinary,
                installationID: workBuddyTransformID),
            case .success(let repaired) = connectWorkBuddyHooks(
                root: relocated.root,
                claudioRoot: workBuddyTransformRoot,
                claudioBinaryPath: workBuddyTransformBinary,
                installationID: UUID())
        else {
            expect(false, "测试前提：relocated fixture 必须可生成并修复")
            return
        }
        expect(repaired.changed, "旧 helper 路径必须被归一")
        expect(workBuddyOwnedCommands(repaired.root).count == 5, "归一后只能保留五条 canonical hook")
    }

    suite("WorkBuddy inspect/disconnect：错位失败关闭，断开只删自有条目") {
        let stop = hostIntegrationHookCommand(
            host: .workBuddy,
            nativeEvent: "Stop",
            installationID: workBuddyTransformID,
            claudioBinaryPath: workBuddyTransformBinary)!
        let misplaced: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [["hooks": [["type": "command", "command": stop]]]]
            ]
        ]
        guard
            case .success(.conflict(let reason)) = inspectWorkBuddyHooks(
                root: misplaced,
                claudioBinaryPath: workBuddyTransformBinary)
        else {
            expect(false, "错位命令必须成为 conflict")
            return
        }
        expect(reason.contains("事件位置"), "conflict 必须可诊断")

        guard
            case .success(let connected) = connectWorkBuddyHooks(
                root: [
                    "hooks": [
                        "Stop": [["hooks": [["type": "command", "command": "echo keep"]]]]
                    ],
                    "sandbox": ["keep": 1],
                ],
                claudioRoot: workBuddyTransformRoot,
                claudioBinaryPath: workBuddyTransformBinary,
                installationID: workBuddyTransformID)
        else {
            expect(false, "连接 fixture 必须成功")
            return
        }
        let staleID = UUID(uuidString: "CCCCCCCC-1111-4222-8333-444444444444")!
        let staleStop = hostIntegrationHookCommand(
            host: .workBuddy,
            nativeEvent: "Stop",
            installationID: staleID,
            claudioBinaryPath: workBuddyTransformBinary)!
        var rootWithStaleGeneration = connected.root
        var hooks = rootWithStaleGeneration["hooks"] as! [String: Any]
        var stopGroups = hooks["Stop"] as! [Any]
        stopGroups.append([
            "hooks": [["type": "command", "command": staleStop]]
        ])
        hooks["Stop"] = stopGroups
        rootWithStaleGeneration["hooks"] = hooks
        guard
            case .success(let disconnected) = disconnectWorkBuddyHooks(
                root: rootWithStaleGeneration,
                claudioBinaryPath: workBuddyTransformBinary,
                installationID: workBuddyTransformID)
        else {
            expect(false, "精确断开 fixture 必须成功")
            return
        }
        expect(disconnected.removedCount == 5, "断开必须精确移除五条自有 hook")
        expect(
            workBuddyOwnedCommands(disconnected.root).map(\.installationID) == [staleID],
            "断开只能删除当前 binary/host/installation，必须保留其它代次")
        expect((disconnected.root["sandbox"] as? [String: Any])?["keep"] as? Int == 1, "未知配置必须保留")
    }
}
