import ClaudioCore
import Foundation

// MARK: - install/uninstall: settings.json 接管 (ENGINEERING.md "settings.json 接管：追加而非
// 覆盖" + 工程落地细节 ①②③⑤, T2)
//
// Fixture-driven per T2 spec ("先写 fixture 测试"). Every fixture below is a realistic
// settings.json shape: another tool's hook group coexisting in the same event array
// (vibe-island-style, hangs off every event) and a PreToolUse/Bash hook (block-no-verify
// style) that claudio must never touch (T3 spike: both are real, not hypothetical).

private let testClaudioBinaryPath = "/Users/tester/.claudio/bin/claudio"
private let testClaudioRootPath = "/Users/tester/.claudio"

private func readRawString(at url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
}

private func readJSONObject(at url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func hooksArray(_ root: [String: Any]?, event: String) -> [[String: Any]]? {
    guard let hooks = root?["hooks"] as? [String: Any] else { return nil }
    return hooks[event] as? [[String: Any]]
}

private func commands(inGroup group: [String: Any]) -> [String] {
    guard let inner = group["hooks"] as? [[String: Any]] else { return [] }
    return inner.compactMap { $0["command"] as? String }
}

@MainActor
func runSettingsInstallerSuites() {
    suite("installClaudioHooks：完整现代 Claude 连接按幂等成功处理，不混装 legacy hook") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            let installationID = UUID(
                uuidString: "51515151-1111-4111-8111-111111111111")!
            let thirdParty: [String: Any] = [
                "hooks": [
                    "Stop": [[
                        "matcher": "third-party",
                        "hooks": [["type": "command", "command": "echo keep"]],
                    ]]
                ],
                "opaque": ["keep": true],
            ]
            guard case .success(let modern) = connectClaudeCodeHooks(
                root: thirdParty,
                claudioRoot: testClaudioRootPath,
                claudioBinaryPath: testClaudioBinaryPath,
                installationID: installationID)
            else {
                expect(false, "测试前提：必须能生成现代 Claude 配置")
                return
            }
            let data = try! JSONSerialization.data(
                withJSONObject: modern.root, options: [.prettyPrinted, .sortedKeys])
            try! data.write(to: settingsFile)
            let before = try! Data(contentsOf: settingsFile)

            let result = installClaudioHooks(
                settingsFile: settingsFile,
                claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)

            expect(
                result == .success(.modernConnectionPresent),
                "完整现代连接必须成功 no-op，并返回可区分结果，got \(result)")
            expect(
                (try? Data(contentsOf: settingsFile)) == before,
                "现代连接幂等 no-op 时 settings.json 必须逐字节不变")
            expect(
                !FileManager.default.fileExists(
                    atPath: settingsFile.appendingPathExtension("claudio.bak").path),
                "零写入 no-op 不能制造一次性备份")
        }
    }

    suite("installClaudioHooks：部分现代 Claude 配置失败关闭，不能用 legacy 补成混合连接") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            let installationID = UUID(
                uuidString: "52525252-2222-4222-8222-222222222222")!
            let stop = hostIntegrationHookCommand(
                host: .claudeCode,
                nativeEvent: "Stop",
                installationID: installationID,
                claudioBinaryPath: testClaudioBinaryPath)!
            let partial: [String: Any] = [
                "hooks": [
                    "Stop": [[
                        "hooks": [["type": "command", "command": stop]]
                    ]],
                    "PreToolUse": [[
                        "matcher": "third-party",
                        "hooks": [["type": "command", "command": "echo keep"]],
                    ]],
                ],
                "opaque": "keep",
            ]
            let data = try! JSONSerialization.data(
                withJSONObject: partial, options: [.prettyPrinted, .sortedKeys])
            try! data.write(to: settingsFile)
            let before = try! Data(contentsOf: settingsFile)

            let result = installClaudioHooks(
                settingsFile: settingsFile,
                claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)

            guard case .failure(let error) = result else {
                expect(false, "部分 modern 配置必须失败关闭，got \(result)")
                return
            }
            expect(
                error.description.contains("现代")
                    && error.description.contains("不完整")
                    && error.description.contains("integrations connect"),
                "失败理由必须解释 partial 状态与修复入口，got \(error.description)")
            expect(
                (try? Data(contentsOf: settingsFile)) == before,
                "partial 失败关闭时 settings.json 必须逐字节不变")
        }
    }

    suite("installClaudioHooks：冲突的现代 Claude 配置失败关闭且零写入") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            let installationID = UUID(
                uuidString: "52525252-3333-4333-8333-333333333333")!
            guard case .success(let modern) = connectClaudeCodeHooks(
                root: [:],
                claudioRoot: testClaudioRootPath,
                claudioBinaryPath: testClaudioBinaryPath,
                installationID: installationID)
            else {
                expect(false, "测试前提：必须生成完整现代 Claude 配置")
                return
            }
            var conflicting = modern.root
            var hooks = conflicting["hooks"] as! [String: Any]
            var stopGroups = hooks["Stop"] as! [Any]
            stopGroups.append(stopGroups.last!)
            hooks["Stop"] = stopGroups
            conflicting["hooks"] = hooks
            let data = try! JSONSerialization.data(
                withJSONObject: conflicting, options: [.prettyPrinted, .sortedKeys])
            try! data.write(to: settingsFile)
            let before = try! Data(contentsOf: settingsFile)

            let result = installClaudioHooks(
                settingsFile: settingsFile,
                claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)

            guard case .failure(let error) = result else {
                expect(false, "冲突的 modern 配置必须失败关闭，got \(result)")
                return
            }
            expect(
                error.description.contains("重复或不同安装代次")
                    && error.description.contains("integrations connect"),
                "冲突诊断必须保留 adapter 原因与修复入口，got \(error.description)")
            expect(
                (try? Data(contentsOf: settingsFile)) == before,
                "modern conflict 拒绝时 settings.json 必须逐字不变")
        }
    }

    suite("installClaudioHooks：现代 callback 旁有畸形 group 时失败关闭，不能绕过 inspect 追加 legacy") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            let installationID = UUID(
                uuidString: "54545454-4444-4444-8444-444444444444")!
            guard case .success(let modern) = connectClaudeCodeHooks(
                root: [:],
                claudioRoot: testClaudioRootPath,
                claudioBinaryPath: testClaudioBinaryPath,
                installationID: installationID)
            else {
                expect(false, "测试前提：必须生成完整现代 Claude 配置")
                return
            }
            var malformed = modern.root
            var hooks = malformed["hooks"] as! [String: Any]
            var stopGroups = hooks["Stop"] as! [Any]
            stopGroups.append(["matcher": "third-party-without-hooks-array"])
            hooks["Stop"] = stopGroups
            malformed["hooks"] = hooks
            let data = try! JSONSerialization.data(
                withJSONObject: malformed, options: [.prettyPrinted, .sortedKeys])
            try! data.write(to: settingsFile)
            let before = try! Data(contentsOf: settingsFile)

            let result = installClaudioHooks(
                settingsFile: settingsFile,
                claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)

            guard case .failure(let error) = result else {
                expect(
                    false,
                    "inspect 无法安全分类时 legacy installer 必须失败关闭，got \(result)")
                return
            }
            expect(
                error.description.contains("现代")
                    && error.description.contains("无法安全检查")
                    && error.description.contains("integrations connect"),
                "畸形 sibling 诊断必须说明检查失败与修复入口，got \(error.description)")
            expect(
                (try? Data(contentsOf: settingsFile)) == before,
                "inspect failure 后不得追加任何 legacy callback")
        }
    }

    suite("installClaudioHooks：modern 与 legacy 已混装时返回 typed repair error 且零写入") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            let installationID = UUID(
                uuidString: "55555555-5555-4555-8555-555555555555")!
            guard case .success(let modern) = connectClaudeCodeHooks(
                root: [:],
                claudioRoot: testClaudioRootPath,
                claudioBinaryPath: testClaudioBinaryPath,
                installationID: installationID)
            else {
                expect(false, "测试前提：必须生成完整现代 Claude 配置")
                return
            }
            var mixed = modern.root
            var hooks = mixed["hooks"] as! [String: Any]
            var stopGroups = hooks["Stop"] as! [Any]
            stopGroups.append([
                "hooks": [[
                    "type": "command",
                    "command": claudioHookCommand(
                        for: .stop, claudioBinaryPath: testClaudioBinaryPath),
                ]]
            ])
            hooks["Stop"] = stopGroups
            mixed["hooks"] = hooks
            let data = try! JSONSerialization.data(
                withJSONObject: mixed, options: [.prettyPrinted, .sortedKeys])
            try! data.write(to: settingsFile)
            let before = try! Data(contentsOf: settingsFile)

            let result = installClaudioHooks(
                settingsFile: settingsFile,
                claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)

            guard case .failure(let error) = result else {
                expect(false, "mixed modern/legacy 必须失败关闭，got \(result)")
                return
            }
            expect(
                error.description.contains("现代与 legacy")
                    && error.description.contains("重复播放")
                    && error.description.contains("integrations connect"),
                "mixed 诊断必须说明重复播放风险与 repair 入口，got \(error.description)")
            expect(
                (try? Data(contentsOf: settingsFile)) == before,
                "mixed repair error 必须保持原配置逐字不变")
        }
    }

    suite("installClaudioHooks：同 root 旧 helper modern callback 一律失败关闭，不能追加 legacy") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            let staleBinary = testClaudioRootPath + "/libexec/claudio"
            let staleID = UUID(
                uuidString: "53535353-3333-4333-8333-333333333333")!
            let staleStop = hostIntegrationHookCommand(
                host: .claudeCode,
                nativeEvent: "Stop",
                installationID: staleID,
                claudioBinaryPath: staleBinary)!
            let staleOnly: [String: Any] = [
                "hooks": [
                    "Stop": [
                        ["hooks": [["type": "command", "command": "echo keep"]]],
                        ["hooks": [["type": "command", "command": staleStop]]],
                    ]
                ]
            ]
            let staleData = try! JSONSerialization.data(
                withJSONObject: staleOnly, options: [.prettyPrinted, .sortedKeys])
            try! staleData.write(to: settingsFile)
            let staleBefore = try! Data(contentsOf: settingsFile)

            let staleResult = installClaudioHooks(
                settingsFile: settingsFile,
                claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            guard case .failure(let staleError) = staleResult else {
                expect(false, "只有旧路径 modern 时 legacy install 必须失败关闭，got \(staleResult)")
                return
            }
            expect(
                staleError.description.contains("旧 helper")
                    && staleError.description.contains("integrations connect"),
                "stale modern 失败必须说明路径迁移与修复入口，got \(staleError.description)")
            expect(
                (try? Data(contentsOf: settingsFile)) == staleBefore,
                "stale-only 拒绝时第三方与旧 callback 必须逐字不变")

            let currentID = UUID(
                uuidString: "53535353-4444-4444-8444-444444444444")!
            guard case .success(let current) = connectClaudeCodeHooks(
                root: [:],
                claudioRoot: testClaudioRootPath,
                claudioBinaryPath: testClaudioBinaryPath,
                installationID: currentID)
            else {
                expect(false, "测试前提：必须生成完整 current modern 配置")
                return
            }
            var currentPlusStale = current.root
            var hooks = currentPlusStale["hooks"] as! [String: Any]
            var stopGroups = hooks["Stop"] as! [Any]
            stopGroups.insert(["hooks": [["type": "command", "command": staleStop]]], at: 0)
            hooks["Stop"] = stopGroups
            currentPlusStale["hooks"] = hooks
            let mixedData = try! JSONSerialization.data(
                withJSONObject: currentPlusStale, options: [.prettyPrinted, .sortedKeys])
            try! mixedData.write(to: settingsFile)
            let mixedBefore = try! Data(contentsOf: settingsFile)

            let mixedResult = installClaudioHooks(
                settingsFile: settingsFile,
                claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            guard case .failure(let mixedError) = mixedResult else {
                expect(
                    false,
                    "current complete + stale 不能被掩盖成 modernConnectionPresent，got \(mixedResult)")
                return
            }
            expect(
                mixedError.description.contains("旧 helper")
                    && mixedError.description.contains("integrations connect"),
                "current+stale 也必须给出显式 repair 入口，got \(mixedError.description)")
            expect(
                (try? Data(contentsOf: settingsFile)) == mixedBefore,
                "current+stale 拒绝时 settings.json 必须逐字不变")
        }
    }

    suite("installClaudioHooks: fresh settings.json (none exists) installs all four events, no backup") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")

            let result = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(result == .success(.installed), "fresh install should report .installed, got \(result)")

            let json = readJSONObject(at: settingsFile)
            for event in Event.allCases {
                let groups = hooksArray(json, event: event.settingsName) ?? []
                expect(groups.count == 1, "\(event.settingsName): expected exactly 1 hook group, got \(groups.count)")
                expect(
                    commands(inGroup: groups.first ?? [:])
                        == [claudioHookCommand(for: event, claudioBinaryPath: testClaudioBinaryPath)],
                    "\(event.settingsName): command mismatch")
            }

            let backupFile = root.appendingPathComponent("settings.json.claudio.bak")
            expect(
                !FileManager.default.fileExists(atPath: backupFile.path),
                "no backup should be created when settings.json didn't exist before install")
        }
    }

    suite("installClaudioHooks: idempotent — second call makes no changes, no duplicate entries") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")

            let first = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(first == .success(.installed), "first install should be .installed")

            let second = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(
                second == .success(.alreadyInstalled),
                "second install should be .alreadyInstalled, got \(second)")

            let json = readJSONObject(at: settingsFile)
            for event in Event.allCases {
                let groups = hooksArray(json, event: event.settingsName) ?? []
                expect(
                    groups.count == 1,
                    "\(event.settingsName): idempotent install must not duplicate, got \(groups.count) groups")
            }
        }
    }

    suite(
        "installClaudioHooks: writes StopFailure unconditionally alongside the other three"
            + " events — install has NO Claude Code version awareness of any kind, so an old"
            + " client that doesn't understand StopFailure simply never fires that hook key,"
            + " harmlessly (T13 acceptance 3a — regression pin for existing behavior, not new)"
    ) {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")

            let result = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(result == .success(.installed), "install should succeed, got \(result)")

            let json = readJSONObject(at: settingsFile)
            let stopFailureGroups = hooksArray(json, event: "StopFailure") ?? []
            expect(
                stopFailureGroups.count == 1
                    && commands(inGroup: stopFailureGroups.first ?? [:])
                        == [
                            claudioHookCommand(
                                for: .stopFailure, claudioBinaryPath: testClaudioBinaryPath)
                        ],
                "StopFailure must be written just like the other 3 events — install performs"
                    + " no Claude Code version check whatsoever, got \(stopFailureGroups)")
            for event in Event.allCases {
                let groups = hooksArray(json, event: event.settingsName) ?? []
                expect(
                    groups.count == 1,
                    "\(event.settingsName) must also be written, got \(groups.count)")
            }
        }
    }

    suite("installClaudioHooks: appends alongside an existing other-tool hook without overwriting it") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            writeFixture(
                #"""
                {
                  "permissions": { "allow": ["Bash(git *)"] },
                  "hooks": {
                    "Stop": [ { "hooks": [ { "type": "command", "command": "vibe-island stop" } ] } ],
                    "PreToolUse": [
                      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "block-no-verify" } ] }
                    ]
                  }
                }
                """#, to: settingsFile)

            let result = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(result == .success(.installed), "install alongside other hooks should be .installed")

            let json = readJSONObject(at: settingsFile)

            let stopGroups = hooksArray(json, event: "Stop") ?? []
            expect(stopGroups.count == 2, "Stop should now have 2 groups (vibe-island + claudio), got \(stopGroups.count)")
            expect(
                stopGroups.contains { commands(inGroup: $0) == ["vibe-island stop"] },
                "vibe-island's Stop group must survive untouched")
            expect(
                stopGroups.contains {
                    commands(inGroup: $0)
                        == [claudioHookCommand(for: .stop, claudioBinaryPath: testClaudioBinaryPath)]
                },
                "claudio's own Stop group must be appended")

            let preToolUse = hooksArray(json, event: "PreToolUse") ?? []
            expect(preToolUse.count == 1, "PreToolUse (not one of claudio's 4 events) must be untouched")
            expect(
                (preToolUse.first?["matcher"] as? String) == "Bash",
                "PreToolUse matcher must survive untouched")
            expect(
                commands(inGroup: preToolUse.first ?? [:]) == ["block-no-verify"],
                "block-no-verify command must survive untouched")

            let permissions = json?["permissions"] as? [String: Any]
            expect(permissions != nil, "unrelated top-level 'permissions' key must survive untouched")
        }
    }

    suite("installClaudioHooks: backs up the pre-claudio original exactly once, never overwrites it") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            let backupFile = root.appendingPathComponent("settings.json.claudio.bak")
            let originalContent = #"{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "vibe-island stop" } ] } ] } }"#
            writeFixture(originalContent, to: settingsFile)

            let first = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(first == .success(.installed), "first install should be .installed")
            expect(
                readRawString(at: backupFile) == originalContent,
                "backup must hold the exact pre-claudio original bytes")

            // Simulate drift: settings.json changed on disk (one event's claudio hook
            // removed, unrelated content mutated) so the *next* install performs a real
            // second write — the backup must still reflect the very first original, not
            // this later state (ENGINEERING.md: "一次性备份").
            writeFixture(
                #"""
                { "MUTATED_MARKER": true, "hooks": {
                  "Stop": [ { "hooks": [ { "type": "command", "command": "vibe-island stop" } ] } ],
                  "StopFailure": [ { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: .stopFailure, claudioBinaryPath: testClaudioBinaryPath))" } ] } ]
                } }
                """#, to: settingsFile)

            let second = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(
                second == .success(.installed),
                "second install must perform a real write (missing events re-added), got \(second)")
            expect(
                readRawString(at: backupFile) == originalContent,
                "backup must remain the FIRST original even after a later real write ('一次性')")
        }
    }

    suite("installClaudioHooks: an atomic-publish-blocked parent aborts before backup, settings.json left untouched") {
        withTempDirectory { root in
            let settingsDir = root.appendingPathComponent("settings-dir", isDirectory: true)
            let settingsFile = settingsDir.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            let originalContent = #"{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "vibe-island stop" } ] } ] } }"#
            writeFixture(originalContent, to: settingsFile)

            // Strip write permission from the directory. Both the one-time backup and the final
            // staging+rename require sibling publication, so the read-only probe must now expose
            // this state before either write is attempted.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o500], ofItemAtPath: settingsDir.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: settingsDir.path)
            }

            let result = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            guard case .failure(.notWritable(let reason)) = result else {
                expect(false, "expected .notWritable when atomic publication is impossible, got \(result)")
                return
            }
            expect(reason.contains("原子替换"), "错误必须说明真实发布阻塞，got \(reason)")
            expect(
                readRawString(at: settingsFile) == originalContent,
                "settings.json must be left untouched when the backup step fails — a failed"
                    + " backup must never be silently ignored and let install overwrite anyway")
            expect(
                !FileManager.default.fileExists(
                    atPath: settingsDir.appendingPathComponent("settings.json.claudio.bak").path),
                "no partial/corrupt backup should exist after a failed backup attempt")
        }
    }

    suite("uninstallClaudioHooks: no settings.json at all → .notInstalled, no file created") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")

            let result = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(
                result == .success(.notInstalled),
                "uninstall with no settings.json should be .notInstalled, got \(result)")
            expect(
                !FileManager.default.fileExists(atPath: settingsFile.path),
                "uninstall must never create settings.json")
        }
    }

    suite("uninstallClaudioHooks: no claudio hooks present → .notInstalled, file left byte-identical") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            let originalContent = #"{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "vibe-island stop" } ] } ] } }"#
            writeFixture(originalContent, to: settingsFile)

            let result = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(
                result == .success(.notInstalled),
                "uninstall with no claudio hooks should be .notInstalled, got \(result)")
            expect(
                readRawString(at: settingsFile) == originalContent,
                "file must be left byte-identical when there is nothing to remove")
        }
    }

    suite("uninstallClaudioHooks: precisely removes claudio entries, preserves other-tool hooks") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            writeFixture(
                #"""
                { "hooks": {
                  "Stop": [
                    { "hooks": [ { "type": "command", "command": "vibe-island stop" } ] },
                    { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: .stop, claudioBinaryPath: testClaudioBinaryPath))" } ] }
                  ],
                  "Notification": [
                    { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: .notification, claudioBinaryPath: testClaudioBinaryPath))" } ] }
                  ],
                  "PreToolUse": [
                    { "matcher": "Bash", "hooks": [ { "type": "command", "command": "block-no-verify" } ] }
                  ]
                } }
                """#, to: settingsFile)

            let result = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(result == .success(.uninstalled(count: 2)), "expected 2 removed (Stop + Notification), got \(result)")

            let json = readJSONObject(at: settingsFile)

            let stopGroups = hooksArray(json, event: "Stop") ?? []
            expect(stopGroups.count == 1, "Stop should keep only vibe-island's group, got \(stopGroups.count)")
            expect(
                commands(inGroup: stopGroups.first ?? [:]) == ["vibe-island stop"],
                "vibe-island's Stop group must survive untouched")

            let hooksSection = json?["hooks"] as? [String: Any]
            expect(
                hooksSection?["Notification"] == nil,
                "Notification key must be removed entirely once its only group is emptied")

            let preToolUse = hooksArray(json, event: "PreToolUse") ?? []
            expect(preToolUse.count == 1, "PreToolUse must be untouched")
            expect(
                (preToolUse.first?["matcher"] as? String) == "Bash",
                "PreToolUse matcher must survive untouched")
        }
    }

    suite(
        "uninstallClaudioHooks: sweeps a relocated/historical claudio binary path (T13"
            + " acceptance 1: survives a future binary move) while never touching structural"
            + " look-alikes (basename mismatch / extra argv segment / outside .claudio"
            + " namespace / unknown event name) or an unrelated third-party hook — all in ONE"
            + " fixture"
    ) {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            // Simulates exactly the scenario T13 exists for: a PAST (or future) claudio
            // release placed the binary at a different subdirectory under the SAME
            // `.claudio/` namespace (`libexec/` instead of today's `bin/`). This
            // settings.json entry was written back then; `claudioBinaryPath` passed to
            // `uninstallClaudioHooks` below is TODAY's path, which does not textually equal
            // this stale entry at all — only the structural match can find it.
            let historicalPath = "/Users/tester/.claudio/libexec/claudio"
            writeFixture(
                #"""
                { "hooks": {
                  "Stop": [
                    { "hooks": [ { "type": "command", "command": "vibe-island stop" } ] },
                    { "hooks": [ { "type": "command", "command": "\#(historicalPath) play stop" } ] },
                    { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: .stop, claudioBinaryPath: testClaudioBinaryPath))" } ] },
                    { "hooks": [ { "type": "command", "command": "/Users/tester/.claudio/bin/mytool play stop" } ] },
                    { "hooks": [ { "type": "command", "command": "\#(testClaudioBinaryPath) play stop --verbose" } ] },
                    { "hooks": [ { "type": "command", "command": "/usr/local/bin/claudio play stop" } ] },
                    { "hooks": [ { "type": "command", "command": "/tmp/.claudio/bin/claudio play stop" } ] },
                    { "hooks": [ { "type": "command", "command": "/Users/someone-else/.claudio/bin/claudio play stop" } ] },
                    { "hooks": [ { "type": "command", "command": "\#(testClaudioBinaryPath) play deploy" } ] }
                  ]
                } }
                """#, to: settingsFile)

            let result = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(
                result == .success(.uninstalled(count: 2)),
                "expected exactly 2 removed (the historical relocated path + today's canonical"
                    + " path), got \(result)")

            let json = readJSONObject(at: settingsFile)
            let stopGroups = hooksArray(json, event: "Stop") ?? []
            let survivingCommands = Set(stopGroups.flatMap { commands(inGroup: $0) })
            expect(
                survivingCommands == [
                    "vibe-island stop",
                    "/Users/tester/.claudio/bin/mytool play stop",
                    "\(testClaudioBinaryPath) play stop --verbose",
                    "/usr/local/bin/claudio play stop",
                    // A `.claudio` directory that is not THIS installation's root. Sweeping
                    // these would mean `uninstall` — the one destructive path here, and the
                    // only one that takes no backup — deleting an entry it cannot prove is
                    // ours, on the strength of a directory *name*.
                    "/tmp/.claudio/bin/claudio play stop",
                    "/Users/someone-else/.claudio/bin/claudio play stop",
                    "\(testClaudioBinaryPath) play deploy",
                ],
                "every look-alike and the unrelated third-party hook must survive untouched,"
                    + " got \(survivingCommands)")
        }
    }

    suite(
        "uninstallClaudioHooks: a home directory with a space — sweeps BOTH today's quoted"
            + " entry and the legacy bare one a pre-quoting claudio left behind, and still"
            + " spares an identically-shaped entry under a different root"
    ) {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            let spacedBinary = "/Users/John Smith/.claudio/bin/claudio"

            // What today's `install` writes (quoted, actually runnable under `/bin/sh -c`)...
            let quoted = claudioHookCommand(for: .stop, claudioBinaryPath: spacedBinary)
            expect(
                quoted == "'/Users/John Smith/.claudio/bin/claudio' play stop",
                "premise: install must quote a space-carrying path, got \(quoted)")
            // ...versus what a pre-quoting claudio wrote: never runnable (the shell split it
            // at the space), but unambiguously ours, so uninstall must still remove it.
            let legacyBare = "/Users/John Smith/.claudio/bin/claudio play notification"

            writeFixture(
                #"""
                { "hooks": {
                  "Stop": [
                    { "hooks": [ { "type": "command", "command": "\#(quoted)" } ] }
                  ],
                  "Notification": [
                    { "hooks": [ { "type": "command", "command": "\#(legacyBare)" } ] },
                    { "hooks": [ { "type": "command", "command": "/Users/Jane Doe/.claudio/bin/claudio play notification" } ] }
                  ]
                } }
                """#, to: settingsFile)

            let result = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: spacedBinary, lockFile: lockFile)
            expect(
                result == .success(.uninstalled(count: 2)),
                "expected the quoted entry + the legacy bare one, got \(result)")

            let json = readJSONObject(at: settingsFile)
            let surviving = Set((hooksArray(json, event: "Notification") ?? []).flatMap {
                commands(inGroup: $0)
            })
            expect(
                surviving == ["/Users/Jane Doe/.claudio/bin/claudio play notification"],
                "another user's identically-shaped hook must survive, got \(surviving)")
        }
    }

    suite(
        "uninstallClaudioHooks: a claudioBinaryPath naming no .claudio root removes nothing and"
            + " never writes (fail-closed; unreachable in production, where the path defaults"
            + " to ClaudioPaths.claudioBinary)"
    ) {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            let original = #"""
                { "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "/Users/tester/.claudio/bin/claudio play stop" } ] } ] } }
                """#
            writeFixture(original, to: settingsFile)
            let before = try? String(contentsOf: settingsFile, encoding: .utf8)

            let result = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: "/usr/local/bin/claudio",
                lockFile: lockFile)
            expect(
                result == .success(.notInstalled),
                "a rootless binary path anchors nothing, so nothing matches, got \(result)")
            expect(
                (try? String(contentsOf: settingsFile, encoding: .utf8)) == before,
                "the file must be left byte-identical when nothing matched")
        }

        // ...but a rootless path must not MASK a real error: load + shape validation still run
        // first, so a corrupt settings.json reports the corruption instead of "nothing
        // installed". (The guard's position in performUninstall is what this pins.)
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            writeFixture("{ not json at all", to: settingsFile)

            let result = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: "/usr/local/bin/claudio",
                lockFile: lockFile)
            var surfacedParseFailure = false
            if case .failure(.parseFailure) = result { surfacedParseFailure = true }
            expect(
                surfacedParseFailure,
                "a corrupt settings.json must surface .parseFailure even when the binary path"
                    + " names no root, got \(result)")
        }
    }

    suite("uninstallClaudioHooks: removes only claudio's entry from a group shared with another tool") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            writeFixture(
                #"""
                { "hooks": {
                  "Stop": [
                    { "hooks": [
                        { "type": "command", "command": "vibe-island stop" },
                        { "type": "command", "command": "\#(claudioHookCommand(for: .stop, claudioBinaryPath: testClaudioBinaryPath))" }
                    ] }
                  ]
                } }
                """#, to: settingsFile)

            let result = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(result == .success(.uninstalled(count: 1)), "expected 1 removed, got \(result)")

            let json = readJSONObject(at: settingsFile)
            let stopGroups = hooksArray(json, event: "Stop") ?? []
            expect(stopGroups.count == 1, "the shared group itself must survive (not dropped), got \(stopGroups.count)")
            expect(
                commands(inGroup: stopGroups.first ?? [:]) == ["vibe-island stop"],
                "only claudio's entry must be removed from the shared inner hooks array")
        }
    }

    suite(
        "uninstallClaudioHooks: preserves a third-party group that was ALREADY empty before the"
            + " sweep — it must drop only a group WE emptied, never collaterally delete someone"
            + " else's empty `{ \"hooks\": [] }` artifact in this no-backup path"
    ) {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            // The Stop array holds a pre-existing EMPTY group (a third-party artifact) next to
            // claudio's own group. Sweeping must remove claudio's and leave the empty one exactly
            // as it was: `removeHookEntries` only drops a group whose inner array it just emptied
            // (innerHooks non-empty → filtered empty), never one that was empty to begin with.
            writeFixture(
                #"""
                { "hooks": {
                  "Stop": [
                    { "hooks": [] },
                    { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: .stop, claudioBinaryPath: testClaudioBinaryPath))" } ] }
                  ]
                } }
                """#, to: settingsFile)

            let result = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(
                result == .success(.uninstalled(count: 1)),
                "expected exactly claudio's 1 entry removed, got \(result)")

            let json = readJSONObject(at: settingsFile)
            let stopGroups = hooksArray(json, event: "Stop") ?? []
            expect(
                stopGroups.count == 1,
                "the already-empty third-party group must survive (only claudio's group dropped),"
                    + " got \(stopGroups.count) groups")
            expect(
                commands(inGroup: stopGroups.first ?? [:]).isEmpty,
                "the surviving group must still be the empty one, got"
                    + " \(commands(inGroup: stopGroups.first ?? [:]))")
        }
    }

    suite("installClaudioHooks: a leftover entry with our command but no \"type\" is not counted as installed — install self-heals with a real command hook") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            // A pre-existing Stop entry carries claudio's exact command string but is
            // missing its "type": "command" — Claude Code would never fire it. The
            // idempotency check (strict `groupContainsCommand`) must treat Stop as
            // not-yet-ours and append a proper, runnable entry (a real write → .installed),
            // rather than seeing the bare command string and skipping the fix.
            writeFixture(
                #"""
                { "hooks": {
                  "Stop": [ { "hooks": [ { "command": "\#(claudioHookCommand(for: .stop, claudioBinaryPath: testClaudioBinaryPath))" } ] } ]
                } }
                """#, to: settingsFile)

            let result = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(
                result == .success(.installed),
                "install must self-heal past a typeless leftover (a real write, not .alreadyInstalled), got \(result)")

            let json = readJSONObject(at: settingsFile)
            let stopGroups = hooksArray(json, event: "Stop") ?? []
            expect(
                stopGroups.count == 2,
                "Stop should keep the malformed leftover group and gain a freshly-appended proper one, got \(stopGroups.count)")
            let hasRunnableStop = stopGroups.contains { group in
                guard let inner = group["hooks"] as? [[String: Any]] else { return false }
                return inner.contains {
                    ($0["type"] as? String) == "command"
                        && ($0["command"] as? String)
                            == claudioHookCommand(for: .stop, claudioBinaryPath: testClaudioBinaryPath)
                }
            }
            expect(hasRunnableStop, "install must have appended a real { type: command } hook for Stop")

            expect(
                detectHookInstallStatus(
                    settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath) == .installed,
                "after self-heal, all four events must read back as .installed")
        }
    }

    suite("uninstallClaudioHooks: still removes a leftover entry carrying our command even without a \"type\" (loose, command-only match)") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            // The detect/install tightening must NOT make uninstall leave malformed cruft
            // behind: `removeHookEntries` matches on `command` alone, so a typeless leftover
            // carrying our command still gets cleaned up.
            writeFixture(
                #"""
                { "hooks": {
                  "Stop": [ { "hooks": [ { "command": "\#(claudioHookCommand(for: .stop, claudioBinaryPath: testClaudioBinaryPath))" } ] } ]
                } }
                """#, to: settingsFile)

            let result = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(
                result == .success(.uninstalled(count: 1)),
                "uninstall must remove the typeless leftover carrying our command, got \(result)")

            let json = readJSONObject(at: settingsFile)
            let hooksSection = json?["hooks"] as? [String: Any]
            expect(
                hooksSection?["Stop"] == nil,
                "Stop key must be removed once its only (malformed) claudio entry is gone")
        }
    }

    suite("corrupt JSON syntax: install and uninstall both abort without writing or backing up") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            let corrupt = "{ not valid json"
            writeFixture(corrupt, to: settingsFile)

            let installResult = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            if case .failure(.parseFailure) = installResult {
                // expected
            } else {
                expect(false, "expected .parseFailure from install, got \(installResult)")
            }
            expect(readRawString(at: settingsFile) == corrupt, "install must never touch a corrupt file")
            expect(
                !FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("settings.json.claudio.bak").path),
                "no backup must be created when parse fails")

            let uninstallResult = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            if case .failure(.parseFailure) = uninstallResult {
                // expected
            } else {
                expect(false, "expected .parseFailure from uninstall, got \(uninstallResult)")
            }
            expect(readRawString(at: settingsFile) == corrupt, "uninstall must never touch a corrupt file")
        }
    }

    suite("malformed hooks shape: \"hooks\" is not an object → abort without writing") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            let malformed = #"{ "hooks": "oops" }"#
            writeFixture(malformed, to: settingsFile)

            let result = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            if case .failure(.malformedHooksSection) = result {
                // expected
            } else {
                expect(false, "expected .malformedHooksSection, got \(result)")
            }
            expect(readRawString(at: settingsFile) == malformed, "malformed-shape file must be left untouched")
        }
    }

    suite("malformed hooks shape: an event's array is not an array → abort without writing") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            let malformed = #"{ "hooks": { "Stop": { "not": "an array" } } }"#
            writeFixture(malformed, to: settingsFile)

            let result = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            if case .failure(.malformedHooksSection) = result {
                // expected
            } else {
                expect(false, "expected .malformedHooksSection, got \(result)")
            }
            expect(readRawString(at: settingsFile) == malformed, "malformed-shape file must be left untouched")
        }
    }

    suite("installClaudioHooks: unwritable settings.json (read-only) aborts via the writability probe") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            let original = #"{ "hooks": {} }"#
            writeFixture(original, to: settingsFile)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o400], ofItemAtPath: settingsFile.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: settingsFile.path)
            }

            let result = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            if case .failure(.notWritable) = result {
                // expected
            } else {
                expect(false, "expected .notWritable, got \(result)")
            }
            expect(readRawString(at: settingsFile) == original, "read-only file must be left untouched")
        }
    }

    suite("installClaudioHooks: missing parent directory aborts via the writability probe, no crash") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("no-such-dir", isDirectory: true)
                .appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")

            let result = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            if case .failure(.notWritable) = result {
                // expected
            } else {
                expect(false, "expected .notWritable, got \(result)")
            }
            expect(
                !FileManager.default.fileExists(atPath: settingsFile.path),
                "install must not create anything when the parent directory is missing")
        }
    }

    suite("installClaudioHooks: a busy lock is reported as .lockBusy and never writes (non-blocking)") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            let holder = FileLock(path: lockFile.path)
            expect(holder.tryLock(), "holder should acquire the lock first")

            let result = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(result == .failure(.lockBusy), "expected .lockBusy while the lock is held, got \(result)")
            expect(
                !FileManager.default.fileExists(atPath: settingsFile.path),
                "install must not create settings.json when it can't acquire the lock")

            holder.unlock()
        }
    }

    suite("uninstallClaudioHooks: a busy lock is reported as .lockBusy and never writes (non-blocking)") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            let original = #"{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: .stop, claudioBinaryPath: testClaudioBinaryPath))" } ] } ] } }"#
            writeFixture(original, to: settingsFile)
            let holder = FileLock(path: lockFile.path)
            expect(holder.tryLock(), "holder should acquire the lock first")

            let result = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(result == .failure(.lockBusy), "expected .lockBusy while the lock is held, got \(result)")
            expect(readRawString(at: settingsFile) == original, "uninstall must not write while the lock is held")

            holder.unlock()
        }
    }

    suite(
        "installClaudioHooks: first-run production topology — settings.json's directory exists but"
            + " the lock file's directory (~/.claudio/ equivalent) never has, and install must still succeed"
    ) {
        withTempDirectory { root in
            // Real first-run shape (T4 review HIGH): `~/.claude/` (settings.json's parent)
            // already exists because Claude Code itself created it, but `~/.claudio/`
            // (the lock file's parent) has never been created by anything — this repo has
            // no code path that creates it up front. Modeled here as two *separate*
            // sibling roots so the settings.json parent pre-exists while the lock file's
            // parent starts out completely missing.
            let claudeDir = root.appendingPathComponent("dot-claude", isDirectory: true)
            try? FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            let settingsFile = claudeDir.appendingPathComponent("settings.json")

            let claudioDir = root.appendingPathComponent("dot-claudio", isDirectory: true)
            expect(
                !FileManager.default.fileExists(atPath: claudioDir.path),
                "sanity: the lock file's parent directory must not exist before install runs"
                    + " — this is exactly the never-run-before-onboarding gap (T4 review HIGH)")
            let lockFile = claudioDir.appendingPathComponent("settings.lock")

            let result = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(
                result == .success(.installed),
                "first-run install must succeed (not .lockFailed) even when the lock file's"
                    + " directory has never been created, got \(result)")
            expect(
                FileManager.default.fileExists(atPath: claudioDir.path),
                "installing must have self-healed the lock file's missing parent directory")
        }
    }

    suite(
        "uninstallClaudioHooks: first-run production topology — never-created lock directory"
            + " must not cause .lockFailed even when there's nothing to uninstall"
    ) {
        withTempDirectory { root in
            let claudeDir = root.appendingPathComponent("dot-claude", isDirectory: true)
            try? FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            let settingsFile = claudeDir.appendingPathComponent("settings.json")

            let claudioDir = root.appendingPathComponent("dot-claudio", isDirectory: true)
            let lockFile = claudioDir.appendingPathComponent("settings.lock")

            // Uninstall in a "never installed before" scenario is expected to report
            // .notInstalled — the point of this test is that it must reach that outcome
            // via the normal path, not fail earlier with .lockFailed just because
            // ~/.claudio/ was never created.
            let result = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(
                result == .success(.notInstalled),
                "uninstall with a never-created lock directory must reach .notInstalled,"
                    + " not .lockFailed, got \(result)")
        }
    }

    suite("install then uninstall round-trips: pre-existing hooks and unrelated keys survive both operations") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            writeFixture(
                #"""
                { "env": { "FOO": "bar" }, "hooks": {
                  "Stop": [ { "hooks": [ { "type": "command", "command": "vibe-island stop" } ] } ],
                  "StopFailure": [ { "hooks": [ { "type": "command", "command": "vibe-island stop_failure" } ] } ],
                  "Notification": [ { "hooks": [ { "type": "command", "command": "vibe-island notification" } ] } ],
                  "SubagentStop": [ { "hooks": [ { "type": "command", "command": "vibe-island subagent_stop" } ] } ],
                  "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "block-no-verify" } ] } ]
                } }
                """#, to: settingsFile)

            let installResult = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(installResult == .success(.installed), "install should succeed, got \(installResult)")

            let afterInstall = readJSONObject(at: settingsFile)
            for event in Event.allCases {
                let groups = hooksArray(afterInstall, event: event.settingsName) ?? []
                expect(groups.count == 2, "\(event.settingsName): expected vibe-island + claudio, got \(groups.count)")
            }

            let uninstallResult = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(
                uninstallResult == .success(.uninstalled(count: 4)),
                "uninstall should remove exactly the 4 claudio entries, got \(uninstallResult)")

            let afterUninstall = readJSONObject(at: settingsFile)
            for (event, expectedCommand) in [
                (Event.stop, "vibe-island stop"),
                (Event.stopFailure, "vibe-island stop_failure"),
                (Event.notification, "vibe-island notification"),
                (Event.subagentStop, "vibe-island subagent_stop"),
            ] {
                let groups = hooksArray(afterUninstall, event: event.settingsName) ?? []
                expect(
                    groups.count == 1 && commands(inGroup: groups.first ?? [:]) == [expectedCommand],
                    "\(event.settingsName): vibe-island's hook must survive the round trip untouched, got \(groups)")
            }

            let preToolUse = hooksArray(afterUninstall, event: "PreToolUse") ?? []
            expect(preToolUse.count == 1, "PreToolUse must survive the round trip untouched")
            expect(
                (preToolUse.first?["matcher"] as? String) == "Bash",
                "PreToolUse matcher must survive the round trip untouched")

            let env = afterUninstall?["env"] as? [String: String]
            expect(env == ["FOO": "bar"], "unrelated top-level 'env' key must survive the round trip untouched")
        }
    }

    suite(
        "installClaudioHooks: refuses a binary path that lives inside a .claudio namespace but is"
            + " not a shape that namespace's own uninstall could sweep, and writes NOTHING —"
            + " shellQuotedPath is strictly more permissive than matchedClaudioEvent, so without"
            + " this guard a future relocation into `lib exec/` would append a hook entry no"
            + " uninstall could ever remove, to the one file uninstall takes no backup of"
    ) {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            writeFixture(#"{ "hooks": {} }"#, to: settingsFile)
            let before = try? String(contentsOf: settingsFile, encoding: .utf8)

            let unsweepable = "/Users/tester/.claudio/lib exec/claudio"
            let result = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: unsweepable, lockFile: lockFile)

            expect(
                result == .failure(.unsweepableBinaryPath(path: unsweepable)),
                "expected .unsweepableBinaryPath, got \(result)")
            expect(
                (try? String(contentsOf: settingsFile, encoding: .utf8)) == before,
                "settings.json must be left byte-identical when install refuses the path")
            expect(
                !FileManager.default.fileExists(
                    atPath: settingsFile.path + ".claudio.bak"),
                "no backup may be created when install never writes")
        }
    }

    suite(
        "installClaudioHooks: still accepts a binary path that names NO .claudio namespace at all."
            + " uninstall fail-closes on such a path rather than claiming it could sweep it, so"
            + " there is no contradiction to refuse — and HookStatusSuite's stale-namespace /"
            + " self-heal coverage installs a `.claudio-OLD` entry through this very branch"
    ) {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            writeFixture(#"{ "hooks": {} }"#, to: settingsFile)

            let result = installClaudioHooks(
                settingsFile: settingsFile,
                claudioBinaryPath: "/Users/tester/.claudio-OLD/bin/claudio", lockFile: lockFile)
            expect(result == .success(.installed), "expected .installed, got \(result)")
        }
    }

    suite(
        "installClaudioHooks x uninstallClaudioHooks: the round trip holds for every home segment"
            + " shape claudio does not control — whatever install is willing to write for a path"
            + " inside our namespace, uninstall anchored at that same namespace must remove again."
            + " This is the invariant binaryPathContradictsItsNamespace exists to keep true"
    ) {
        let homes = [
            "/Users/tester",  // the plain case
            "/Users/John Smith",  // space: the AD/network-account case
            "/Users/o'brien",  // apostrophe: quoted, and lossily decoded
            "/Users/a$b",  // `$`: quoted, never expanded
            "/Users/张三",  // non-ASCII, unquoted
            "/Users/e\u{301}dith",  // NFD (e + COMBINING ACUTE): the scalar rewrite's raison d'être,
            //                          exercised end-to-end through settings.json, not just the predicate
        ]
        for home in homes {
            let binary = "\(home)/.claudio/bin/claudio"
            expect(
                !binaryPathContradictsItsNamespace(binary),
                "sanity: install must be willing to write \(binary)")

            withTempDirectory { root in
                let settingsFile = root.appendingPathComponent("settings.json")
                let lockFile = root.appendingPathComponent("settings.lock")
                writeFixture(#"{ "hooks": {} }"#, to: settingsFile)

                let installed = installClaudioHooks(
                    settingsFile: settingsFile, claudioBinaryPath: binary, lockFile: lockFile)
                expect(
                    installed == .success(.installed),
                    "install must succeed for home \(home), got \(installed)")

                let removed = uninstallClaudioHooks(
                    settingsFile: settingsFile, claudioBinaryPath: binary, lockFile: lockFile)
                expect(
                    removed == .success(.uninstalled(count: Event.allCases.count)),
                    "uninstall must sweep all \(Event.allCases.count) entries install wrote for"
                        + " home \(home), got \(removed)")
            }
        }
    }

    suite(
        "SettingsUpdateError.unsweepableBinaryPath: its user-facing description names the offending"
            + " path verbatim, so a future release that trips the guard gives an actionable message"
            + " rather than an opaque failure"
    ) {
        let path = "/Users/tester/.claudio/lib exec/claudio"
        let description = SettingsUpdateError.unsweepableBinaryPath(path: path).description
        expect(
            description.contains(path),
            "the description must echo the offending path, got: \(description)")
        expect(
            description.contains("claudio") && !description.isEmpty,
            "the description must be a non-empty human message, got: \(description)")
    }

    suite(
        "installClaudioHooks: the unsweepable-path guard is a pre-I/O precondition — it fires"
            + " BEFORE any read/write/lock, so an unsweepable path is refused as such even when"
            + " settings.json is absent or its directory is unwritable, never masked as a"
            + " write/probe failure. This pins the guard's POSITION, which the error-precedence a"
            + " caller sees depends on"
    ) {
        let unsweepable = "/Users/tester/.claudio/lib exec/claudio"

        // (a) settings.json ABSENT: a normal install would succeed here (loadRoot yields [:]),
        // so getting .unsweepableBinaryPath proves the guard ran before the load.
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            let result = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: unsweepable, lockFile: lockFile)
            expect(
                result == .failure(.unsweepableBinaryPath(path: unsweepable)),
                "an absent settings.json must still surface .unsweepableBinaryPath, got \(result)")
            expect(
                !FileManager.default.fileExists(atPath: settingsFile.path),
                "the guard must not have created settings.json")
        }

        // (b) settings.json in a NON-EXISTENT directory (its write/probe would fail): the guard
        // must still win, so the caller sees the real cause (bad binary path) not a probe failure.
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("no-such-dir/settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            let result = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: unsweepable, lockFile: lockFile)
            expect(
                result == .failure(.unsweepableBinaryPath(path: unsweepable)),
                "an unwritable target must still surface .unsweepableBinaryPath (guard precedes the"
                    + " writability probe), got \(result)")
        }
    }

    suite(
        "installClaudioHooks: refuses a `..` path INSIDE our own namespace, and the refusal is not"
            + " academic — the entry it would have written survives every uninstall anchored at the"
            + " true root. `claudioNamespaceRoot` returns nil for a `..` path exactly as it does for"
            + " `/usr/local/bin/claudio`, but only the latter is the no-namespace carve-out: this"
            + " one resolves back into `.claudio` through /bin/sh, so the hook fires"
    ) {
        let traversing = "/Users/tester/.claudio/bin/../bin/claudio"

        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            writeFixture(#"{ "hooks": {} }"#, to: settingsFile)
            let before = readRawString(at: settingsFile)

            let result = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: traversing, lockFile: lockFile)
            expect(
                result == .failure(.unsweepableBinaryPath(path: traversing)),
                "expected .unsweepableBinaryPath for a `..` path in our namespace, got \(result)")
            expect(
                readRawString(at: settingsFile) == before,
                "settings.json must be left byte-identical when install refuses the path")
            expect(
                !FileManager.default.fileExists(atPath: settingsFile.path + ".claudio.bak"),
                "no backup may be created when install never writes")
        }

        // Why the refusal has to happen at the writer: had install written this entry, NOTHING
        // could take it back out. Seed it by hand and let a normal uninstall — anchored at the
        // real production path, the only one a user ever passes — try.
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            let stranded = claudioHookCommand(for: .stop, claudioBinaryPath: traversing)
            let fixture = #"{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "\#(stranded)" } ] } ] } }"#
            writeFixture(fixture, to: settingsFile)

            let result = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(
                result == .success(.notInstalled),
                "uninstall cannot even see the `..` entry, got \(result)")
            expect(
                readRawString(at: settingsFile)?.contains(stranded) == true,
                "the `..` entry outlives uninstall — which is why install must never write it")
        }
    }

    // MARK: - Optimistic concurrency ([9]) and settings.json-as-symlink ([D])
    //
    // Both are load-bearing behaviors of `atomicWrite` that shipped with no regression net: a
    // change that dropped the re-read, or that stopped resolving the symlink, would have left
    // every other suite green. `betweenReadAndWrite` is the seam that makes the first one
    // deterministic (see `installClaudioHooks`'s doc comment).
    //
    // These three suites are the seam's only users; the seam is `#if DEBUG` (so the shipped
    // library keeps the 3-argument production signature), so they compile only in DEBUG too —
    // the harness always runs in DEBUG, and a bare `swift build -c release` (which also builds
    // this executable test target) must not trip over an API that release does not vend.
    #if DEBUG
    suite(
        "installClaudioHooks: aborts with .concurrentModification when another writer changes"
            + " settings.json between the read and the write, and leaves that writer's bytes"
            + " exactly as they were — this file has no restore path, so clobbering is permanent"
    ) {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            let original = #"{ "hooks": {} }"#
            writeFixture(original, to: settingsFile)

            // What Claude Code / the GUI / an editor does: a plain atomic overwrite that honors
            // no lock of ours.
            let intruder = #"{ "hooks": {}, "model": "opus" }"#
            let result = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile,
                betweenReadAndWrite: {
                    try? intruder.write(to: settingsFile, atomically: true, encoding: .utf8)
                })

            expect(
                result == .failure(.concurrentModification(path: settingsFile.path)),
                "expected .concurrentModification, got \(result)")
            // Byte-equality to the intruder's exact content fully pins "no hook appended": the
            // intruder JSON carries no claudio command, so any appended hook would break this.
            expect(
                readRawString(at: settingsFile) == intruder,
                "the concurrent writer's bytes must survive verbatim — install must not clobber")
            // The intruder now strikes in the read→backup window (the seam fires before the
            // backup), so this pins that `.claudio.bak` holds the bytes install READ, not a
            // fresh re-read of disk that would have captured the intruder's write. Revert the
            // backup to re-reading the file and this assertion goes RED. Pinned too because a
            // failed install leaves this artifact behind and the backup is one-shot: a later
            // successful install will not overwrite it.
            expect(
                readRawString(at: settingsFile.appendingPathExtension("claudio.bak")) == original,
                "the backup snapshots what install read, not what the intruder wrote")
        }
    }

    suite(
        "uninstallClaudioHooks: aborts with .concurrentModification too — it takes no backup at"
            + " all, so a clobber here is strictly worse than on the install path"
    ) {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            let stop = claudioHookCommand(for: .stop, claudioBinaryPath: testClaudioBinaryPath)
            writeFixture(
                #"{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "\#(stop)" } ] } ] } }"#,
                to: settingsFile)

            let intruder = #"{ "hooks": {}, "permissions": { "allow": [] } }"#
            let result = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile,
                betweenReadAndWrite: {
                    try? intruder.write(to: settingsFile, atomically: true, encoding: .utf8)
                })

            expect(
                result == .failure(.concurrentModification(path: settingsFile.path)),
                "expected .concurrentModification, got \(result)")
            expect(
                readRawString(at: settingsFile) == intruder,
                "uninstall must not clobber a concurrent write in a file it never backs up")
        }
    }

    suite(
        "installClaudioHooks: an unchanged settings.json is NOT a concurrent modification — the"
            + " guard compares bytes, so a writer that rewrites identical content (or no writer at"
            + " all) must not turn a normal install into a spurious abort the user has to retry"
    ) {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            let original = #"{ "hooks": {} }"#
            writeFixture(original, to: settingsFile)

            // Assert the seam actually ran, so this test also pins that the seam is WIRED — a
            // refactor that silently stopped invoking it would flip `ran` and fail here, rather
            // than passing as an ordinary install would.
            var ran = false
            let result = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile,
                betweenReadAndWrite: {
                    ran = true
                    try? original.write(to: settingsFile, atomically: true, encoding: .utf8)
                })
            expect(ran, "the betweenReadAndWrite seam must have been invoked")
            expect(result == .success(.installed), "a byte-identical rewrite must not abort, got \(result)")
        }
    }
    #endif  // DEBUG — seam-driven suites

    suite(
        "installClaudioHooks: a settings.json that IS a symlink (dotfiles: stow/chezmoi) has its"
            + " TARGET rewritten in place — the link survives, so the dotfiles repo keeps tracking"
            + " the file. Writing the link path with .atomic would temp+rename ON the link and"
            + " silently replace it with a regular file, diverging from the repo forever"
    ) {
        withTempDirectory { root in
            let target = root.appendingPathComponent("dotfiles/settings.json")
            let settingsFile = root.appendingPathComponent("claude/settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            let original = #"{ "hooks": {} }"#
            writeFixture(original, to: target)
            createSymlink(at: settingsFile, pointingTo: target)

            let result = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(result == .success(.installed), "expected .installed, got \(result)")

            expect(
                (try? FileManager.default.destinationOfSymbolicLink(atPath: settingsFile.path))
                    != nil,
                "settings.json must still BE a symlink after install, not a regular file")
            expect(
                readRawString(at: target)?.contains("claudio") == true,
                "the symlink's target — the file the dotfiles repo tracks — must carry the hooks")
            for event in Event.allCases {
                let expected = claudioHookCommand(
                    for: event, claudioBinaryPath: testClaudioBinaryPath)
                let groups = hooksArray(readJSONObject(at: target), event: event.settingsName)
                expect(
                    groups?.contains { commands(inGroup: $0).contains(expected) } == true,
                    "\(event.settingsName) must be installed in the target")
            }

            // The backup sits next to the LINK but must be a real content snapshot, not a second
            // symlink to the same target — otherwise it would track every later edit and back up
            // nothing.
            let backup = settingsFile.appendingPathExtension("claudio.bak")
            expect(
                (try? FileManager.default.destinationOfSymbolicLink(atPath: backup.path)) == nil,
                "the backup must be a regular file, not a symlink to the target")
            expect(
                readRawString(at: backup) == original,
                "the backup must hold the target's pre-install CONTENT, got"
                    + " \(String(describing: readRawString(at: backup)))")

            // And the round trip: uninstall rewrites the target too, link still intact.
            let removed = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(
                removed == .success(.uninstalled(count: Event.allCases.count)),
                "uninstall must sweep through the symlink, got \(removed)")
            expect(
                (try? FileManager.default.destinationOfSymbolicLink(atPath: settingsFile.path))
                    != nil,
                "settings.json must still be a symlink after uninstall")
            expect(
                readRawString(at: target)?.contains("claudio") != true,
                "the target must have the hooks removed")
        }
    }

    suite(
        "installClaudioHooks: a DANGLING settings.json symlink still installs. loadRoot's"
            + " fileExists follows the link and reports absent, so this is the ordinary fresh-install"
            + " path — pinned because the obvious hardening of atomicWrite's nil re-read (an `lstat`"
            + " that does NOT follow the link, and so sees the link node and calls it a concurrent"
            + " creation) would silently turn this into a permanent .concurrentModification"
    ) {
        withTempDirectory { root in
            let target = root.appendingPathComponent("dotfiles/settings.json")
            let settingsFile = root.appendingPathComponent("claude/settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            try? FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            createSymlink(at: settingsFile, pointingTo: target)
            expect(
                !FileManager.default.fileExists(atPath: settingsFile.path),
                "premise: the link dangles, so fileExists (which follows it) says absent")

            let result = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(
                result == .success(.installed),
                "a dangling settings.json symlink is an absent file, not a concurrent"
                    + " modification, got \(result)")
            expect(
                detectHookInstallStatus(
                    settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath)
                    == .installed,
                "the hooks must be readable back through the same path install was given")
        }
    }
}
