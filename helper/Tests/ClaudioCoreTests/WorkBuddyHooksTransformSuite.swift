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
    suite("WorkBuddy connect：首发只写两条已实现 binding，并保留未知配置") {
        let original: [String: Any] = [
            "claw": ["opaque": true],
            "hooks": [
                "Stop": [
                    [
                        "matcher": "third",
                        "hooks": [["type": "command", "command": "echo keep"]],
                    ]
                ]
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
        expect(
            Set(owned.map(\.nativeEvent)) == ["UserPromptSubmit", "Stop"],
            "只能安装 task_start/stop，got \(owned.map(\.nativeEvent))")
        expect(owned.allSatisfy { $0.installationID == workBuddyTransformID }, "两条 hook 必须同代次")
        expect((mutation.root["claw"] as? [String: Any])?["opaque"] as? Bool == true, "未知顶层键必须保留")
        let stopGroups = ((mutation.root["hooks"] as? [String: Any])?["Stop"] as? [Any]) ?? []
        expect(stopGroups.count == 2, "第三方 Stop group 必须保留并追加 Claudio group")
        expect(
            hostIntegrationHookCommand(
                host: .workBuddy,
                nativeEvent: "StopFailure",
                installationID: workBuddyTransformID,
                claudioBinaryPath: workBuddyTransformBinary) == nil,
            "未实现的官方 binding 不得生成可执行命令")
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
        expect(workBuddyOwnedCommands(repaired.root).count == 2, "归一后只能保留两条 canonical hook")
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
        expect(disconnected.removedCount == 2, "断开必须精确移除两条自有 hook")
        expect(
            workBuddyOwnedCommands(disconnected.root).map(\.installationID) == [staleID],
            "断开只能删除当前 binary/host/installation，必须保留其它代次")
        expect((disconnected.root["sandbox"] as? [String: Any])?["keep"] as? Int == 1, "未知配置必须保留")
    }
}
