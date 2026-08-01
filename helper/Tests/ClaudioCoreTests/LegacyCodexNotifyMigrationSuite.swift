import ClaudioCore
import Foundation

private let legacyMigrationRoot = "/Users/tester/.claudio"
private let legacyMigrationBinary = "/Users/tester/.claudio/bin/claudio"
private let legacyMigrationWrapper = "/Users/tester/.claudio/bin/codex-notify"
private let legacyMigrationID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
private let legacyNotifierLine =
    #""/Applications/Previous Notify.app/Contents/MacOS/previous-notify" --metadata '{"nested":["escaped value","previous-notify"]}' "$payload" >/dev/null 2>&1 &"#

private func knownLegacyWrapper(
    binaryWord: String = #""/Users/tester/.claudio/bin/claudio""#,
    notifierLine: String = legacyNotifierLine
) -> String {
    """
    #!/bin/sh
    # Codex 的 notify 只能配置一个外部命令；这里保留既有通知，并追加 Claudio 的完成音效。

    payload=${1-}

    \(notifierLine)
    \(binaryWord) play stop >/dev/null 2>&1 &

    exit 0

    """
}

@MainActor
func runLegacyCodexNotifyMigrationSuites() {
    suite("LegacyCodexNotifyMigration：已知 9 行 wrapper 可检测，迁移只替换 Claudio 分支") {
        // 路径通过 TOML unicode escape 表达，证明检测比较的是解码后的 argv，而不是裸子串。
        let config = #"""
            model = "gpt-5.6-sol"
            notify = ["\u002FUsers\u002Ftester\u002F.claudio\u002Fbin\u002Fcodex-notify"]

            [projects."/tmp/example"]
            trust_level = "trusted"
            trust_hash = "opaque-codex-notify-text-must-not-be-parsed"
            """#
        let wrapper = knownLegacyWrapper()

        expect(
            detectLegacyCodexNotifyMigration(
                configTOML: config,
                wrapper: wrapper,
                claudioRoot: legacyMigrationRoot,
                claudioBinaryPath: legacyMigrationBinary) == .migratable,
            "顶层 notify 确实引用当前 root 且 wrapper 精确匹配时才可迁移")

        let result = migrateLegacyCodexNotifyWrapper(
            configTOML: config,
            wrapper: wrapper,
            claudioRoot: legacyMigrationRoot,
            claudioBinaryPath: legacyMigrationBinary,
            installationID: legacyMigrationID)
        guard case .success(let migrated) = result else {
            expect(false, "显式迁移应返回纯变换后的 wrapper，got \(result)")
            return
        }
        let expectedClaudioLine =
            #""/Users/tester/.claudio/bin/claudio" hook codex Stop --installation-id "#
            + legacyMigrationID.uuidString + " >/dev/null 2>&1 &"
        let beforeLines = wrapper.components(separatedBy: "\n")
        let afterLines = migrated.components(separatedBy: "\n")
        expect(beforeLines.count == 10 && afterLines.count == 10, "尾随换行在内必须仍是已知 9 行形状")
        expect(afterLines[5] == legacyNotifierLine, "原 notifier 命令及其全部 argv 必须逐字保留")
        expect(afterLines[6] == expectedClaudioLine, "只把 legacy play stop 分支升级为带代次的 Codex Stop hook")
        expect(
            zip(beforeLines, afterLines).enumerated().allSatisfy { index, pair in
                index == 6 || pair.0 == pair.1
            },
            "除 Claudio 分支所在第 7 行外，一个字节都不能变")
    }

    suite("LegacyCodexNotifyMigration：nested/previous-notify 文本不是顶层 notify 引用") {
        let config = """
            previous-notify = ["\(legacyMigrationWrapper)"]
            note = "escaped reference: \\"\(legacyMigrationWrapper)\\""

            [profile.previous]
            notify = ["\(legacyMigrationWrapper)"]
            """
        expect(
            detectLegacyCodexNotifyMigration(
                configTOML: config,
                wrapper: knownLegacyWrapper(),
                claudioRoot: legacyMigrationRoot,
                claudioBinaryPath: legacyMigrationBinary)
                == .conflict(.configDoesNotReferenceWrapper),
            "previous-notify 键、普通字符串和 nested table 里的 notify 都不能冒充顶层引用")
    }

    suite("LegacyCodexNotifyMigration：真实 --previous-notify argv 严格 JSON 引用当前 wrapper") {
        let config = #"""
            notify = [
              "/Applications/Anonymous Notifier.app/Contents/MacOS/notifier",
              "turn-ended",
              "--previous-notify",
              "[\"\\/Users\\/tester\\/.claudio\\/bin\\/codex-notify\"]",
            ]

            [projects."/anonymous/worktree"]
            trust_hash = "opaque"
            """#
        expect(
            detectLegacyCodexNotifyMigration(
                configTOML: config,
                wrapper: knownLegacyWrapper(),
                claudioRoot: legacyMigrationRoot,
                claudioBinaryPath: legacyMigrationBinary) == .migratable,
            "--previous-notify 后一 argv 严格 JSON 解码为 [expectedWrapper] 时就是当前真实引用")

        let withoutFlag = config.replacingOccurrences(
            of: "\"--previous-notify\",", with: "\"--some-other-flag\",")
        expect(
            detectLegacyCodexNotifyMigration(
                configTOML: withoutFlag,
                wrapper: knownLegacyWrapper(),
                claudioRoot: legacyMigrationRoot,
                claudioBinaryPath: legacyMigrationBinary)
                == .conflict(.configDoesNotReferenceWrapper),
            "普通 argv 里即使出现同一段 JSON，也不能冒充 --previous-notify 引用")
    }

    suite("LegacyCodexNotifyMigration：已迁移可识别，disconnect 保留 notifier，随后可重连新代次") {
        let config = "notify = [\"\(legacyMigrationWrapper)\"]\n"
        let firstMigration = migrateLegacyCodexNotifyWrapper(
            configTOML: config,
            wrapper: knownLegacyWrapper(),
            claudioRoot: legacyMigrationRoot,
            claudioBinaryPath: legacyMigrationBinary,
            installationID: legacyMigrationID)
        guard case .success(let migrated) = firstMigration else {
            expect(false, "测试前提：legacy wrapper 必须先能迁移")
            return
        }
        expect(
            detectLegacyCodexNotifyMigration(
                configTOML: config,
                wrapper: migrated,
                claudioRoot: legacyMigrationRoot,
                claudioBinaryPath: legacyMigrationBinary)
                == .migrated(installationID: legacyMigrationID),
            "已迁移 wrapper 必须暴露其 installation ID，不能被误报未知修改")

        let disconnected = removeClaudioBranchFromLegacyCodexNotifyWrapper(
            configTOML: config,
            wrapper: migrated,
            claudioRoot: legacyMigrationRoot,
            claudioBinaryPath: legacyMigrationBinary)
        guard case .success(let notifierOnly) = disconnected else {
            expect(false, "disconnect 必须能纯变换移除 Claudio 分支")
            return
        }
        expect(notifierOnly.contains(legacyNotifierLine), "原 notifier 行及 argv 必须逐字活着")
        expect(!notifierOnly.contains(" hook codex Stop "), "disconnect 只能删除 Claudio 分支")
        expect(
            detectLegacyCodexNotifyMigration(
                configTOML: config,
                wrapper: notifierOnly,
                claudioRoot: legacyMigrationRoot,
                claudioBinaryPath: legacyMigrationBinary) == .notifierOnly,
            "known notifier-only wrapper 是可重连状态，不是永久 conflict")

        let nextID = UUID(uuidString: "99999999-8888-4777-8666-555555555555")!
        let reconnected = migrateLegacyCodexNotifyWrapper(
            configTOML: config,
            wrapper: notifierOnly,
            claudioRoot: legacyMigrationRoot,
            claudioBinaryPath: legacyMigrationBinary,
            installationID: nextID)
        guard case .success(let reconnectedWrapper) = reconnected else {
            expect(false, "notifier-only wrapper 必须能插入新的 Claudio installation")
            return
        }
        expect(reconnectedWrapper.contains(legacyNotifierLine), "重连仍不得改写原 notifier")
        expect(
            detectLegacyCodexNotifyMigration(
                configTOML: config,
                wrapper: reconnectedWrapper,
                claudioRoot: legacyMigrationRoot,
                claudioBinaryPath: legacyMigrationBinary)
                == .migrated(installationID: nextID),
            "重连必须写入并识别新的 installation ID")
    }

    suite("LegacyCodexNotifyMigration：未知修改、另一 root 与无法解码一律 fail closed") {
        let config = "notify = [\"\(legacyMigrationWrapper)\"]\n"
        let modified = knownLegacyWrapper().replacingOccurrences(
            of: "payload=${1-}", with: "payload=$1")
        expect(
            detectLegacyCodexNotifyMigration(
                configTOML: config,
                wrapper: modified,
                claudioRoot: legacyMigrationRoot,
                claudioBinaryPath: legacyMigrationBinary)
                == .conflict(.unknownOrModifiedWrapper),
            "任一固定行被修改都必须拒绝")

        let otherRoot = knownLegacyWrapper(
            binaryWord: #""/Users/other/.claudio/bin/claudio""#)
        expect(
            detectLegacyCodexNotifyMigration(
                configTOML: config,
                wrapper: otherRoot,
                claudioRoot: legacyMigrationRoot,
                claudioBinaryPath: legacyMigrationBinary)
                == .conflict(.differentClaudioBinary),
            "另一 Claudio root 的 play 分支绝不能被当前安装代次接管")

        expect(
            detectLegacyCodexNotifyMigration(
                configTOML: Data([0xFF]),
                wrapper: Data(knownLegacyWrapper().utf8),
                claudioRoot: legacyMigrationRoot,
                claudioBinaryPath: legacyMigrationBinary)
                == .conflict(.configNotUTF8),
            "config.toml 无法按 UTF-8 解码必须给上层明确冲突原因")
        expect(
            detectLegacyCodexNotifyMigration(
                configTOML: Data(config.utf8),
                wrapper: Data([0xFF]),
                claudioRoot: legacyMigrationRoot,
                claudioBinaryPath: legacyMigrationBinary)
                == .conflict(.wrapperNotUTF8),
            "wrapper 无法按 UTF-8 解码必须给上层明确冲突原因")
    }

    suite("LegacyCodexNotifyMigration：当前 binary 的其它合法 shell quoting 仍可精确识别") {
        let quotedRoot = "/Users/tester/Claudio Root/.claudio"
        let quotedBinary = "\(quotedRoot)/bin/claudio"
        let quotedWrapper = "\(quotedRoot)/bin/codex-notify"
        let config = "notify = ['\(quotedWrapper)']\n"
        let wrapper = knownLegacyWrapper(binaryWord: "'\(quotedBinary)'")
        expect(
            detectLegacyCodexNotifyMigration(
                configTOML: config,
                wrapper: wrapper,
                claudioRoot: quotedRoot,
                claudioBinaryPath: quotedBinary) == .migratable,
            "含空格路径的合法单引号 shell word 必须可识别")
    }

    suite("LegacyCodexNotifyMigration：双引号内非特殊反斜杠不能被误解码") {
        let config = "notify = [\"\(legacyMigrationWrapper)\"]\n"
        let shellDifferentBinary = #""/Users/tester/.claud\io/bin/claudio""#
        expect(
            detectLegacyCodexNotifyMigration(
                configTOML: config,
                wrapper: knownLegacyWrapper(binaryWord: shellDifferentBinary),
                claudioRoot: legacyMigrationRoot,
                claudioBinaryPath: legacyMigrationBinary)
                == .conflict(.differentClaudioBinary),
            #"shell 会保留双引号内 `\i` 的反斜杠，不能将它误判为 `.claudio`"#)
    }

    suite("LegacyCodexNotifyMigration：会被 shell 展开的路径必须引用，不能把 glob 当字面量") {
        let globRoot = "/Users/tester/Claudio*/.claudio"
        let globBinary = "\(globRoot)/bin/claudio"
        let config = "notify = [\"\(globRoot)/bin/codex-notify\"]\n"
        expect(
            detectLegacyCodexNotifyMigration(
                configTOML: config,
                wrapper: knownLegacyWrapper(binaryWord: globBinary),
                claudioRoot: globRoot,
                claudioBinaryPath: globBinary)
                == .conflict(.unknownOrModifiedWrapper),
            "未引用的 * 会被 shell 展开，绝不是当前 binary 的精确字面引用")
        expect(
            detectLegacyCodexNotifyMigration(
                configTOML: config,
                wrapper: knownLegacyWrapper(binaryWord: shellQuotedPath(globBinary)),
                claudioRoot: globRoot,
                claudioBinaryPath: globBinary) == .migratable,
            "同一路径经 Claudio 的 shell quoting 后应可精确识别")
    }
}
