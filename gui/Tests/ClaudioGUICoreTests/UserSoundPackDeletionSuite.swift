import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
func runUserSoundPackDeletionSuites() {
    suite("User Sound Pack 删除：确认后在共享锁内移出库且保留完整目录") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            let source = packs.appendingPathComponent("my-pack", isDirectory: true)
            let trash = root.appendingPathComponent("Trash", isDirectory: true)
            let manifest = #"{"id":"my-pack","events":{},"future":{"keep":true}}"#
            writeFixture(manifest, to: source.appendingPathComponent("manifest.json"))
            writeFixture("audio", to: source.appendingPathComponent("cue.mp3"))
            let environment = makeAudioImportEnvironment(userPacksDirectory: packs)
            let config = makeDeletionConfigFixture(in: root)

            let result = deleteUserSoundPack(
                packID: "my-pack",
                configFile: config.file,
                configLockFile: config.lock,
                environment: environment,
                moveToTrash: { source in
                    try FileManager.default.createDirectory(
                        at: trash,
                        withIntermediateDirectories: true)
                    let destination = trash.appendingPathComponent(source.lastPathComponent)
                    try FileManager.default.moveItem(at: source, to: destination)
                    return destination
                })

            expect(
                result
                    == .success(
                        UserSoundPackDeletionOutcome(
                            packID: "my-pack",
                            trashedPath: trash.appendingPathComponent("my-pack").path)),
                "成功必须报告可恢复目标，实得 \(result)")
            expect(
                !FileManager.default.fileExists(atPath: source.path),
                "成功后声音包必须离开可发现库根")
            expect(
                (try? String(
                    contentsOf: trash.appendingPathComponent("my-pack/manifest.json"),
                    encoding: .utf8)) == manifest,
                "移到废纸篓必须保留完整 manifest 与未知字段，不得重写用户内容")
            expect(
                regularFileExists(at: trash.appendingPathComponent("my-pack/cue.mp3")),
                "移到废纸篓必须保留包内音频")
        }
    }

    suite("User Sound Pack 删除：active、built-in、不安全 ID 与 symlink 全部 fail closed") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            let factory = root.appendingPathComponent("factory", isDirectory: true)
            writeFixture("{}", to: packs.appendingPathComponent("active/manifest.json"))
            writeFixture("{}", to: packs.appendingPathComponent("builtin/manifest.json"))
            writeFixture("{}", to: factory.appendingPathComponent("builtin/manifest.json"))
            let external = root.appendingPathComponent("external", isDirectory: true)
            writeFixture("keep", to: external.appendingPathComponent("secret.txt"))
            try? FileManager.default.createDirectory(
                at: packs,
                withIntermediateDirectories: true)
            try? FileManager.default.createSymbolicLink(
                at: packs.appendingPathComponent("linked"),
                withDestinationURL: external)
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: packs,
                factoryPacksDirectory: factory)
            let config = makeDeletionConfigFixture(
                in: root,
                config: ClaudioConfig(selectedPack: "active"))
            var trashCalls = 0
            let trash: @MainActor (URL) throws -> URL? = { _ in
                trashCalls += 1
                return nil
            }

            expect(
                deleteUserSoundPack(
                    packID: "active",
                    configFile: config.file,
                    configLockFile: config.lock,
                    environment: environment,
                    moveToTrash: trash) == .failure(.activePack(packID: "active")),
                "当前使用包必须拒绝删除")
            expect(
                deleteUserSoundPack(
                    packID: "builtin",
                    configFile: config.file,
                    configLockFile: config.lock,
                    environment: environment,
                    moveToTrash: trash) == .failure(.builtinReadOnly(packID: "builtin")),
                "内置包必须保持只读")
            expect(
                deleteUserSoundPack(
                    packID: "../escape",
                    configFile: config.file,
                    configLockFile: config.lock,
                    environment: environment,
                    moveToTrash: trash) == .failure(.unsafePackID(packID: "../escape")),
                "不安全 ID 必须在任何文件操作前拒绝")
            expect(
                deleteUserSoundPack(
                    packID: "linked",
                    configFile: config.file,
                    configLockFile: config.lock,
                    environment: environment,
                    moveToTrash: trash) == .failure(.unsafePackEntry(packID: "linked")),
                "symlink 包条目不得把外部目录送入废纸篓")
            expect(trashCalls == 0, "所有 fail-closed 路径都不得调用废纸篓写者")
            expect(
                regularFileExists(at: external.appendingPathComponent("secret.txt")),
                "symlink 拒绝后外部内容必须原样保留")
        }
    }

    suite("User Sound Pack 删除：默认组与任一工作区引用都阻止删除") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            let source = packs.appendingPathComponent("workspace-pack", isDirectory: true)
            writeFixture("{}", to: source.appendingPathComponent("manifest.json"))
            let environment = makeAudioImportEnvironment(userPacksDirectory: packs)
            var config = ClaudioConfig(selectedPack: "default-pack")
            config.workspaceRules = [
                WorkspaceSoundRule(
                    directory: WorkspaceDirectory(kind: .directory, path: root.path),
                    surfaces: [.codex],
                    profile: WorkspaceSoundProfile(selectedPack: "workspace-pack", volume: 0.8))
            ]
            let referenced = referencedSoundPackIDs(in: config)
            let configFixture = makeDeletionConfigFixture(in: root, config: config)
            var trashCalls = 0

            expect(
                referenced == ["default-pack", "workspace-pack"],
                "引用集合必须包含默认组与所有工作区")
            expect(
                deleteUserSoundPack(
                    packID: "workspace-pack",
                    configFile: configFixture.file,
                    configLockFile: configFixture.lock,
                    environment: environment,
                    moveToTrash: { _ in
                        trashCalls += 1
                        return nil
                    }) == .failure(.activePack(packID: "workspace-pack")),
                "其他工作区使用的包也必须拒绝删除")
            expect(trashCalls == 0, "任一声音作用域仍引用时不得进入隔离或 Trash")
            expect(
                regularFileExists(at: source.appendingPathComponent("manifest.json")),
                "跨声音作用域拒绝后原声音包必须保持可用")
        }
    }

    suite("User Sound Pack 删除：验证后路径被替换时不把替换项送进 Trash") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            let source = packs.appendingPathComponent("my-pack", isDirectory: true)
            let preserved = root.appendingPathComponent("preserved", isDirectory: true)
            writeFixture("original", to: source.appendingPathComponent("origin.txt"))
            let environment = makeAudioImportEnvironment(userPacksDirectory: packs)
            let config = makeDeletionConfigFixture(in: root)
            var trashCalls = 0

            let result = deleteUserSoundPack(
                packID: "my-pack",
                configFile: config.file,
                configLockFile: config.lock,
                environment: environment,
                beforeIsolation: { expected in
                    try FileManager.default.moveItem(at: expected, to: preserved)
                    writeFixture("replacement", to: expected.appendingPathComponent("other.txt"))
                },
                moveToTrash: { _ in
                    trashCalls += 1
                    return nil
                })

            expect(
                result == .failure(.unsafePackEntry(packID: "my-pack")),
                "隔离后的 inode 不同必须拒绝，实得 \(result)")
            expect(trashCalls == 0, "身份不匹配时不得调用路径式 Trash API")
            expect(
                regularFileExists(at: preserved.appendingPathComponent("origin.txt")),
                "竞态前验证过的原目录必须未被删除")
            expect(
                regularFileExists(at: source.appendingPathComponent("other.txt")),
                "替换项必须恢复到原路径，不得被误删")
            let hiddenEntries =
                ((try? FileManager.default.contentsOfDirectory(atPath: packs.path))
                ?? []).filter { $0.hasPrefix(".claudio-trash-") }
            expect(hiddenEntries.isEmpty, "成功回滚身份竞态后不得留下隔离目录")
        }
    }

    suite("User Sound Pack 删除：极端回滚失败信息按当前语言解析") {
        let isolation = SoundPacksWindowPackDeletionActionError.delete(
            .isolationChangedRetained(path: "/packs/.isolated/my-pack"))
        expect(
            isolation.statusText.resolve(language: .english)
                == "The sound pack entry changed during isolation. Nothing was sent to Trash; "
                + "the suspicious entry remains at /packs/.isolated/my-pack.",
            "隔离身份变化的 English 状态不得夹入中文 literal")
        expect(
            isolation.statusText.resolve(language: .zhHans)
                == "隔离时声音包目录发生变化，未将任何内容移到废纸篓；可疑条目保留在 "
                + "/packs/.isolated/my-pack。",
            "隔离身份变化必须有 zh-Hans 状态")

        let trash = SoundPacksWindowPackDeletionActionError.delete(
            .trashFailedRetained(reason: "permission denied", path: "/packs/.isolated/my-pack"))
        expect(
            trash.statusText.resolve(language: .english)
                == "Trash failed and claudi0 could not restore the original path (permission "
                + "denied). The sound pack remains at /packs/.isolated/my-pack.",
            "Trash 与回滚同时失败必须由 English catalog 组合原因与保留路径")
        expect(
            trash.statusText.resolve(language: .zhHans)
                == "移到废纸篓失败，且 claudi0 无法恢复原路径（permission denied）；声音包保留在 "
                + "/packs/.isolated/my-pack。",
            "Trash 与回滚同时失败必须有 zh-Hans 状态")
    }

    suite("User Sound Pack 删除：确认后新写入的 Global 引用在 config.lock 内复验") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            let source = packs.appendingPathComponent("my-pack", isDirectory: true)
            writeFixture("{}", to: source.appendingPathComponent("manifest.json"))
            let environment = makeAudioImportEnvironment(userPacksDirectory: packs)
            let config = makeDeletionConfigFixture(in: root)
            var trashCalls = 0

            // Confirmation-time UI still considers my-pack inactive. A cooperating config writer
            // then changes the authoritative file before the destructive action starts.
            writeFixture(
                try! JSONEncoder().encode(ClaudioConfig(selectedPack: "my-pack")),
                to: config.file)
            let result = deleteUserSoundPack(
                packID: "my-pack",
                configFile: config.file,
                configLockFile: config.lock,
                environment: environment,
                moveToTrash: { _ in
                    trashCalls += 1
                    return nil
                })

            expect(
                result == .failure(.activePack(packID: "my-pack")),
                "删除必须消费锁内当前 config，而不是确认时的缓存引用")
            expect(trashCalls == 0, "新引用成立后不得进入隔离或 Trash")
            expect(FileManager.default.fileExists(atPath: source.path), "被新引用的包必须原样保留")
        }
    }

    suite("User Sound Pack 删除：config.lock 争用与畸形引用事实均 fail closed") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            let source = packs.appendingPathComponent("my-pack", isDirectory: true)
            writeFixture("{}", to: source.appendingPathComponent("manifest.json"))
            let environment = makeAudioImportEnvironment(userPacksDirectory: packs)
            let config = makeDeletionConfigFixture(in: root)
            var trashCalls = 0
            let trash: @MainActor (URL) throws -> URL? = { _ in
                trashCalls += 1
                return nil
            }

            let outer = withNonBlockingLock(path: config.lock.path) {
                deleteUserSoundPack(
                    packID: "my-pack",
                    configFile: config.file,
                    configLockFile: config.lock,
                    environment: environment,
                    moveToTrash: trash)
            }
            guard case .ran(let contended) = outer else {
                expect(false, "测试前提：外层必须取得 config.lock")
                return
            }
            expect(contended == .failure(.lockBusy), "config.lock 争用必须立即失败")

            let validRule = WorkspaceSoundRule(
                directory: WorkspaceDirectory(kind: .directory, path: root.path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "my-pack", volume: 0.8))
            let validRuleData = try! JSONEncoder().encode(validRule)
            let validRuleJSON = try! JSONSerialization.jsonObject(with: validRuleData)
            writeFixture(
                try! JSONSerialization.data(withJSONObject: [
                    "selected_pack": "other",
                    "workspace_rules": [
                        validRule.id.uuidString: validRuleJSON,
                        UUID().uuidString: "broken",
                    ],
                ]),
                to: config.file)
            let decoded = try! JSONDecoder().decode(
                ClaudioConfig.self, from: Data(contentsOf: config.file))
            expect(
                decoded.workspaceRulesMalformed && decoded.workspaceRules.isEmpty,
                "一条损坏规则会掩盖同组内有效工作区引用")
            expect(
                deleteUserSoundPack(
                    packID: "my-pack",
                    configFile: config.file,
                    configLockFile: config.lock,
                    environment: environment,
                    moveToTrash: trash) == .failure(.configUnavailable),
                "无法穷尽全部工作区引用时必须失败关闭")
            expect(trashCalls == 0, "配置事实不可信时不得进入 Trash")
            expect(
                FileManager.default.fileExists(atPath: source.path),
                "所有配置失败路径都必须保留包")

            var incompleteRule = validRuleJSON as! [String: Any]
            var incompleteProfile = incompleteRule["profile"] as! [String: Any]
            incompleteProfile["events"] = ["stop": true]
            incompleteRule["profile"] = incompleteProfile
            writeFixture(
                try! JSONSerialization.data(withJSONObject: [
                    "selected_pack": "other",
                    "workspace_rules": [validRule.id.uuidString: incompleteRule],
                ]),
                to: config.file)
            let partiallyDecoded = try! JSONDecoder().decode(
                ClaudioConfig.self, from: Data(contentsOf: config.file))
            expect(
                !partiallyDecoded.workspaceRulesMalformed
                    && partiallyDecoded.workspaceRules.count == 1
                    && partiallyDecoded.workspaceRules[0].profile == nil,
                "规则可解码但声音配置损坏时引用仍不可穷尽")
            expect(
                deleteUserSoundPack(
                    packID: "my-pack",
                    configFile: config.file,
                    configLockFile: config.lock,
                    environment: environment,
                    moveToTrash: trash) == .failure(.configUnavailable),
                "声音配置损坏的工作区也必须失败关闭")
            expect(trashCalls == 0, "不完整工作区不得进入 Trash")
        }
    }

    suite("User Sound Pack 删除：退役的损坏 Surface 覆盖不阻止删除") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            let source = packs.appendingPathComponent("my-pack", isDirectory: true)
            let trash = root.appendingPathComponent("Trash", isDirectory: true)
            let trashedPack = trash.appendingPathComponent("my-pack", isDirectory: true)
            writeFixture("{}", to: source.appendingPathComponent("manifest.json"))
            let environment = makeAudioImportEnvironment(userPacksDirectory: packs)
            let legacyConfig = ClaudioConfig(
                selectedPack: "other",
                surfaceOverrides: [
                    HostSurfaceID.codex.rawValue: SurfaceSoundOverride(selectedPack: "my-pack")
                ])
            expect(
                referencedSoundPackIDs(in: legacyConfig) == ["other"],
                "有效的退役 Surface 覆盖也不再是声音包引用")
            let config = makeDeletionConfigFixture(in: root)
            writeFixture(
                #"{"selected_pack":"other","surface_overrides":"broken"}"#,
                to: config.file)

            let result = deleteUserSoundPack(
                packID: "my-pack",
                configFile: config.file,
                configLockFile: config.lock,
                environment: environment,
                moveToTrash: { isolated in
                    try FileManager.default.createDirectory(
                        at: trash, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: isolated, to: trashedPack)
                    return trashedPack
                })
            expect(
                result
                    == .success(
                        UserSoundPackDeletionOutcome(
                            packID: "my-pack", trashedPath: trashedPack.path)),
                "旧覆盖已退役，其损坏不应阻止未引用包移入废纸篓")
            expect(
                regularFileExists(at: trash.appendingPathComponent("my-pack/manifest.json")),
                "旧覆盖损坏时仍应保留可恢复的完整包")
        }
    }

    suite("User Sound Pack 删除：packs.lock 争用时不执行废纸篓动作") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            let source = packs.appendingPathComponent("my-pack", isDirectory: true)
            writeFixture("{}", to: source.appendingPathComponent("manifest.json"))
            let environment = makeAudioImportEnvironment(userPacksDirectory: packs)
            let config = makeDeletionConfigFixture(in: root)
            var trashCalls = 0

            let outer = withNonBlockingLock(path: environment.packsLockFile.path) {
                deleteUserSoundPack(
                    packID: "my-pack",
                    configFile: config.file,
                    configLockFile: config.lock,
                    environment: environment,
                    moveToTrash: { _ in
                        trashCalls += 1
                        return nil
                    })
            }
            guard case .ran(let result) = outer else {
                expect(false, "测试前提：外层必须取得 packs.lock")
                return
            }
            expect(result == .failure(.lockBusy), "争用必须立即返回 lockBusy，实得 \(result)")
            expect(trashCalls == 0, "lockBusy 时删除临界区不得运行")
            expect(
                FileManager.default.fileExists(atPath: source.path),
                "lockBusy 后用户声音包必须原样保留")
        }
    }

    suite("User Sound Pack 删除：Release 测试 seam 保持 Xcode 16.4 Sendable 合同") {
        let sourceURL = guiTestRepositoryRoot().appendingPathComponent(
            "gui/Sources/ClaudioGUICore/UserSoundPackDeletion.swift")
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            expect(false, "必须能读取 UserSoundPackDeletion.swift 以检查 Release 条件编译合同")
            return
        }
        let code = strippingComments(source).code.filter { !$0.isWhitespace }
        let explicitDeclaration =
            "letafterIsolation:@MainActor@Sendable(URL)throws->Void="

        // The DEBUG value gets its type from the injectable seam, while the Release no-op has no
        // such context. Xcode 16.4 rejects the latter if either branch returns to inferred type.
        expect(
            code.components(separatedBy: explicitDeclaration).count - 1 == 2,
            "DEBUG 与 Release 分支都必须显式声明同一个 @MainActor @Sendable hook 类型")
        expect(
            code.contains("afterIsolation:@MainActor@Sendable(URL)throws->Void"),
            "锁内 private callee 必须消费与条件编译两侧一致的 Sendable hook 类型")
    }
}

private struct DeletionConfigFixture {
    let file: URL
    let lock: URL
}

@MainActor
private func makeDeletionConfigFixture(
    in root: URL,
    config: ClaudioConfig = ClaudioConfig(selectedPack: "other-pack")
) -> DeletionConfigFixture {
    let file = root.appendingPathComponent("config.json")
    let lock = root.appendingPathComponent("config.lock")
    writeFixture(try! JSONEncoder().encode(config), to: file)
    return DeletionConfigFixture(file: file, lock: lock)
}
