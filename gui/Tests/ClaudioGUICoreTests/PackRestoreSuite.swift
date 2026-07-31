import ClaudioCore
import ClaudioGUICore
import Foundation

private enum InjectedFactoryRestoreFailure: Error, Sendable {
    case beforeSalvage
    case beforePublish
}

@MainActor
private func writeRestorePack(
    manifest: String,
    files: [String: String],
    to directory: URL
) {
    writeFixture(manifest, to: directory.appendingPathComponent("manifest.json"))
    for (fileName, contents) in files {
        writeFixture(contents, to: directory.appendingPathComponent(fileName))
    }
}

@MainActor
func runPackRestoreSuites() {
    suite(
        "restoreFactoryPack：即使已安装包可用也用出厂副本替换，原目录完整 salvage，恢复后重回 CC0"
    ) {
        withTempDirectory { root in
            let factory = root.appendingPathComponent("factory")
            let bundled = root.appendingPathComponent("bundled")
            let userPacks = root.appendingPathComponent("packs")
            let factoryPack = factory.appendingPathComponent("minimal-chime")
            let bundledPack = bundled.appendingPathComponent("minimal-chime")
            let installedPack = userPacks.appendingPathComponent("minimal-chime")
            let factoryManifest =
                #"{ "id": "minimal-chime", "name": "极简铃音", "license": "CC0-1.0", "events": { "stop": "stop.mp3" } }"#
            let modifiedManifest =
                #"{ "id": "minimal-chime", "name": "仍可用但已修改", "license": "CC0-1.0", "events": { "stop": "stop.mp3" } }"#

            writeRestorePack(
                manifest: factoryManifest,
                files: ["stop.mp3": "factory-audio"],
                to: factoryPack)
            writeRestorePack(
                manifest: factoryManifest,
                files: ["stop.mp3": "wrong-bundled-audio"],
                to: bundledPack)
            writeRestorePack(
                manifest: modifiedManifest,
                files: [
                    "stop.mp3": "user-modified-audio",
                    "my-extra.wav": "only-user-copy",
                ],
                to: installedPack)

            let environment = makeAudioImportEnvironment(
                userPacksDirectory: userPacks,
                bundledPacksDirectory: bundled,
                factoryPacksDirectory: factory)
            expect(
                factoryIntegrity(packID: "minimal-chime", environment: environment) == false,
                "前提：一个 manifest 可读、声明文件也存在的已安装包仍可被 factoryIntegrity 判为已修改")

            let result = restoreFactoryPack(
                id: "minimal-chime",
                environment: environment)

            guard case .success(let outcome) = result else {
                expect(false, "恢复可用但已修改的内置包应成功，实得 \(result)")
                return
            }
            expect(outcome.restoredPackID == "minimal-chime", "outcome 必须点名实际恢复的包")
            guard let salvaged = outcome.salvaged else {
                expect(false, "替换已存在目录必须返回 salvage 路径，不能静默丢掉告知数据")
                return
            }
            let salvagedDirectory = URL(fileURLWithPath: salvaged.movedTo, isDirectory: true)
            expect(
                salvaged.packID == "minimal-chime"
                    && salvagedDirectory.deletingLastPathComponent().standardizedFileURL.path
                        == userPacks.standardizedFileURL.path
                    && salvagedDirectory.lastPathComponent.hasPrefix(".minimal-chime."),
                "salvage 必须是 userPacksDirectory 的隐藏同级目录，实得 \(salvaged)")
            expect(
                (try? String(
                    contentsOf: salvagedDirectory.appendingPathComponent("my-extra.wav"),
                    encoding: .utf8)) == "only-user-copy",
                "用户自加文件必须随整个旧目录搬走，一个字节都不能删")
            expect(
                (try? String(
                    contentsOf: salvagedDirectory.appendingPathComponent("stop.mp3"),
                    encoding: .utf8)) == "user-modified-audio",
                "用户改过的声明音频也必须留在 salvage 目录")
            expect(
                (try? String(
                    contentsOf: installedPack.appendingPathComponent("stop.mp3"),
                    encoding: .utf8)) == "factory-audio",
                "最终可见目录必须来自 factoryPacksDirectory，而不是 bundledPacksDirectory 或旧目录")
            expect(
                !FileManager.default.fileExists(
                    atPath: installedPack.appendingPathComponent("my-extra.wav").path),
                "恢复后的可见包必须是干净出厂树；用户文件只能出现在已告知的 salvage 路径")
            expect(
                factoryIntegrity(packID: "minimal-chime", environment: environment) == true,
                "恢复完成后 factoryIntegrity 必须重新通过")
            let restoredCard = availablePacks(
                config: ClaudioConfig(selectedPack: "minimal-chime"),
                environment: environment
            ).first(where: { $0.id == "minimal-chime" })
            expect(
                restoredCard.map {
                    packRowMetaSlots(
                        isCC0: $0.isCC0,
                        state: $0.state,
                        factoryIntegrity: $0.factoryIntegrity
                    ).license
                } == .cc0,
                "恢复后的包行必须从「⚠ 已修改」回到 CC0")
        }
    }

    suite("restoreFactoryPack：已存在的同名 salvage 永不覆盖，下一份顺延且两份用户数据都保留") {
        withTempDirectory { root in
            let factory = root.appendingPathComponent("factory")
            let userPacks = root.appendingPathComponent("packs")
            let installed = userPacks.appendingPathComponent("minimal-chime")
            let occupiedSalvage = userPacks.appendingPathComponent(
                ".minimal-chime.pre-restore-\(ProcessInfo.processInfo.processIdentifier)")
            writeRestorePack(
                manifest: #"{ "id": "minimal-chime", "events": {} }"#,
                files: [:],
                to: factory.appendingPathComponent("minimal-chime"))
            writeRestorePack(
                manifest: #"{ "id": "minimal-chime", "events": {} }"#,
                files: ["newer-user.wav": "newer"],
                to: installed)
            writeFixture(
                "older",
                to: occupiedSalvage.appendingPathComponent("older-user.wav"))
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: userPacks,
                factoryPacksDirectory: factory)

            let result = restoreFactoryPack(id: "minimal-chime", environment: environment)

            guard case .success(let outcome) = result, let salvaged = outcome.salvaged else {
                expect(false, "salvage 名称冲突时仍应安全恢复，实得 \(result)")
                return
            }
            expect(
                salvaged.movedTo.hasSuffix("-2"),
                "当前 pid 的基础 salvage 已占用时必须顺延，不能覆盖，实得 \(salvaged.movedTo)")
            expect(
                (try? String(
                    contentsOf: occupiedSalvage.appendingPathComponent("older-user.wav"),
                    encoding: .utf8)) == "older",
                "旧 salvage 里的用户数据必须保持原样")
            expect(
                (try? String(
                    contentsOf: URL(fileURLWithPath: salvaged.movedTo)
                        .appendingPathComponent("newer-user.wav"),
                    encoding: .utf8)) == "newer",
                "本次旧安装必须完整落到顺延后的新 salvage")
        }
    }

    suite(
        "restoreFactoryPack：salvage 后、rename 前失败时不暴露残包，旧目录仍完整且错误携带可告知路径"
    ) {
        withTempDirectory { root in
            let factory = root.appendingPathComponent("factory")
            let userPacks = root.appendingPathComponent("packs")
            let factoryPack = factory.appendingPathComponent("minimal-chime")
            let installedPack = userPacks.appendingPathComponent("minimal-chime")
            writeRestorePack(
                manifest: #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                files: ["stop.mp3": "factory"],
                to: factoryPack)
            writeRestorePack(
                manifest: #"{ "id": "minimal-chime", "events": {} }"#,
                files: ["only-user.wav": "irreplaceable"],
                to: installedPack)

            let environment = AudioImportEnvironment(
                userPacksDirectory: userPacks,
                factoryPacksDirectory: factory,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: injectedPacksLock(besideUserPacks: userPacks),
                beforeFactoryPackRestorePublish: {
                    throw InjectedFactoryRestoreFailure.beforePublish
                })
            let result = restoreFactoryPack(
                id: "minimal-chime",
                environment: environment)

            guard
                case .failure(
                    .publishFailed(_, let salvaged?)) = result
            else {
                expect(false, "注入的 publish 前失败必须保留 salvage 路径，实得 \(result)")
                return
            }
            let salvagedDirectory = URL(fileURLWithPath: salvaged.movedTo, isDirectory: true)
            expect(
                (try? String(
                    contentsOf: salvagedDirectory.appendingPathComponent("only-user.wav"),
                    encoding: .utf8)) == "irreplaceable",
                "发布失败也不能删旧目录里的任何用户文件")
            expect(
                !FileManager.default.fileExists(atPath: installedPack.path),
                "注入点已在旧目录安全搬走之后；失败不得把半份 staging 暴露到最终路径")
            let entries =
                (try? FileManager.default.contentsOfDirectory(atPath: userPacks.path)) ?? []
            expect(
                !entries.contains(".minimal-chime.tmp-\(ProcessInfo.processInfo.processIdentifier)"),
                "捕获到的中途失败必须清理当前 pid staging，不留残包")
            expect(
                entries.allSatisfy { $0.hasPrefix(".") },
                "失败后只允许已告知的隐藏 salvage，不能出现非点前缀残包，实得 \(entries)")
        }
    }

    suite("restoreFactoryPack：salvage 搬移失败会清 staging，用户旧目录保持原位且不伪造告知路径") {
        withTempDirectory { root in
            let factory = root.appendingPathComponent("factory")
            let userPacks = root.appendingPathComponent("packs")
            let installedPack = userPacks.appendingPathComponent("minimal-chime")
            writeRestorePack(
                manifest: #"{ "id": "minimal-chime", "events": {} }"#,
                files: [:],
                to: factory.appendingPathComponent("minimal-chime"))
            writeRestorePack(
                manifest: #"{ "id": "minimal-chime", "events": {} }"#,
                files: ["only-user.wav": "irreplaceable"],
                to: installedPack)
            let environment = AudioImportEnvironment(
                userPacksDirectory: userPacks,
                factoryPacksDirectory: factory,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: injectedPacksLock(besideUserPacks: userPacks),
                beforeFactoryPackRestoreSalvage: {
                    throw InjectedFactoryRestoreFailure.beforeSalvage
                })

            let result = restoreFactoryPack(
                id: "minimal-chime",
                environment: environment)

            guard case .failure(.salvageFailed) = result else {
                expect(false, "注入的 salvage 搬移失败必须结构化返回，实得 \(result)")
                return
            }
            expect(
                (try? String(
                    contentsOf: installedPack.appendingPathComponent("only-user.wav"),
                    encoding: .utf8)) == "irreplaceable",
                "salvage 失败时用户旧目录必须保持原位，一个字节都不能删")
            let entries =
                (try? FileManager.default.contentsOfDirectory(atPath: userPacks.path)) ?? []
            expect(
                entries == ["minimal-chime"],
                "salvage 失败必须清理完整 staging，且不能伪造隐藏 salvage 路径，实得 \(entries)")
        }
    }

    suite("restoreFactoryPack：目标缺失时仍从 factory 安装，且诚实返回无内容需要 salvage") {
        withTempDirectory { root in
            let factory = root.appendingPathComponent("factory")
            let userPacks = root.appendingPathComponent("packs")
            writeRestorePack(
                manifest: #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                files: ["stop.mp3": "factory"],
                to: factory.appendingPathComponent("minimal-chime"))
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: userPacks,
                factoryPacksDirectory: factory)

            let result = restoreFactoryPack(id: "minimal-chime", environment: environment)

            guard case .success(let outcome) = result else {
                expect(false, "缺失的内置安装副本也应能从 factory 恢复，实得 \(result)")
                return
            }
            expect(outcome.salvaged == nil, "没有旧目录时不得伪造一条 salvage 告知")
            expect(
                factoryIntegrity(packID: "minimal-chime", environment: environment) == true,
                "首次从 factory 发布也必须得到逐字节一致的安装包")
        }
    }

    suite("restoreFactoryPack：unsafe id / 非内置 id 在任何磁盘写入前拒绝") {
        withTempDirectory { root in
            let factory = root.appendingPathComponent("factory")
            let userPacks = root.appendingPathComponent("packs")
            writeRestorePack(
                manifest: #"{ "id": "minimal-chime", "events": {} }"#,
                files: [:],
                to: factory.appendingPathComponent("minimal-chime"))
            writeRestorePack(
                manifest: #"{ "id": "my-pack", "events": {} }"#,
                files: ["mine.wav": "mine"],
                to: userPacks.appendingPathComponent("my-pack"))
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: userPacks,
                factoryPacksDirectory: factory)
            let entriesBefore =
                (try? FileManager.default.contentsOfDirectory(atPath: userPacks.path)) ?? []

            let unsafe = restoreFactoryPack(id: "../escape", environment: environment)
            let custom = restoreFactoryPack(id: "my-pack", environment: environment)

            if case .failure(.unsafePackID(packID: "../escape")) = unsafe {
                expect(true, "unsafe id 拒绝原因正确")
            } else {
                expect(false, "unsafe id 必须被明确拒绝，实得 \(unsafe)")
            }
            if case .failure(.notBuiltinPack(packID: "my-pack")) = custom {
                expect(true, "非内置 id 拒绝原因正确")
            } else {
                expect(false, "非内置包不能进入恢复出厂路径，实得 \(custom)")
            }
            expect(
                ((try? FileManager.default.contentsOfDirectory(atPath: userPacks.path)) ?? [])
                    == entriesBefore,
                "两种前置拒绝都不得创建 staging 或改动 userPacksDirectory")
            expect(
                (try? String(
                    contentsOf: userPacks.appendingPathComponent("my-pack/mine.wav"),
                    encoding: .utf8)) == "mine",
                "拒绝非内置包必须让用户文件保持原位")
        }
    }

    suite("restoreFactoryPack：factory symlink 不得被当拷贝源，安装目标保持原样") {
        withTempDirectory { root in
            let realFactoryElsewhere = root.appendingPathComponent("outside/factory-pack")
            let factory = root.appendingPathComponent("factory")
            let userPacks = root.appendingPathComponent("packs")
            let installed = userPacks.appendingPathComponent("linked-builtin")
            writeRestorePack(
                manifest: #"{ "id": "linked-builtin", "events": {} }"#,
                files: ["source.wav": "outside"],
                to: realFactoryElsewhere)
            createSymlink(
                at: factory.appendingPathComponent("linked-builtin"),
                pointingTo: realFactoryElsewhere)
            writeRestorePack(
                manifest: #"{ "id": "linked-builtin", "events": {} }"#,
                files: ["installed.wav": "stay"],
                to: installed)
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: userPacks,
                factoryPacksDirectory: factory)

            let result = restoreFactoryPack(id: "linked-builtin", environment: environment)

            if case .failure(.unsafeFactorySource(packID: "linked-builtin")) = result {
                expect(true, "factory symlink 必须由真实目录闸门拒绝")
            } else {
                expect(false, "factory symlink 不得被递归复制，实得 \(result)")
            }
            expect(
                (try? String(
                    contentsOf: installed.appendingPathComponent("installed.wav"),
                    encoding: .utf8)) == "stay",
                "不安全源被拒绝时，当前安装目录必须保持原样")
        }
    }

    suite("restoreFactoryPack：factory 内绝对音频 symlink 复制后会逃出 staging，必须在 salvage 前拒绝") {
        withTempDirectory { root in
            let factory = root.appendingPathComponent("factory")
            let userPacks = root.appendingPathComponent("packs")
            let factoryPack = factory.appendingPathComponent("minimal-chime")
            let installed = userPacks.appendingPathComponent("minimal-chime")
            let factoryAudio = factoryPack.appendingPathComponent("factory-stop.mp3")
            writeRestorePack(
                manifest:
                    #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                files: ["factory-stop.mp3": "factory"],
                to: factoryPack)
            createSymlink(
                at: factoryPack.appendingPathComponent("stop.mp3"),
                pointingTo: factoryAudio)
            writeRestorePack(
                manifest: #"{ "id": "minimal-chime", "events": {} }"#,
                files: ["only-user.wav": "irreplaceable"],
                to: installed)
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: userPacks,
                factoryPacksDirectory: factory)

            let result = restoreFactoryPack(id: "minimal-chime", environment: environment)

            if case .failure(.stagingFailed(let reason)) = result {
                expect(
                    reason.contains("stop.mp3"),
                    "staging 独立性失败必须点名复制后逃逸的声明音频，实得 \(reason)")
            } else {
                expect(
                    false,
                    "源端安全、复制后逃出 staging 的绝对 symlink 不得被发布并谎报成功，实得 \(result)")
            }
            expect(
                (try? String(
                    contentsOf: installed.appendingPathComponent("only-user.wav"),
                    encoding: .utf8)) == "irreplaceable",
                "staging 独立性验证失败必须发生在 salvage 前，用户旧目录保持原位")
            let entries =
                (try? FileManager.default.contentsOfDirectory(atPath: userPacks.path)) ?? []
            expect(
                entries == ["minimal-chime"],
                "staging 独立性失败必须清掉当前 pid 暂存且不得产生假 salvage，实得 \(entries)")
        }
    }

    suite("restoreFactoryPack：factory 内相对音频 symlink 复制后仍留在包内，可以安全恢复") {
        withTempDirectory { root in
            let factory = root.appendingPathComponent("factory")
            let userPacks = root.appendingPathComponent("packs")
            let factoryPack = factory.appendingPathComponent("minimal-chime")
            let relativeLink = factoryPack.appendingPathComponent("stop.mp3")
            writeRestorePack(
                manifest:
                    #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                files: ["factory-stop.mp3": "factory"],
                to: factoryPack)
            try? FileManager.default.createSymbolicLink(
                atPath: relativeLink.path,
                withDestinationPath: "factory-stop.mp3")
            expect(
                (try? FileManager.default.destinationOfSymbolicLink(
                    atPath: relativeLink.path)) == "factory-stop.mp3",
                "相对 symlink fixture 必须真实存在且保持相对目标，否则本用例没有覆盖重定位语义")
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: userPacks,
                factoryPacksDirectory: factory)

            let result = restoreFactoryPack(id: "minimal-chime", environment: environment)

            guard case .success(let outcome) = result else {
                expect(false, "包内相对 symlink 重定位后仍安全，不应被 staging 复验误拒，实得 \(result)")
                return
            }
            expect(outcome.salvaged == nil, "目标原本不存在，不得伪造 salvage 告知")
            expect(
                factoryIntegrity(packID: "minimal-chime", environment: environment) == true,
                "相对 symlink 随整树 rename 后仍应留在包内，恢复结果必须通过 factoryIntegrity")
        }
    }

    suite("restoreFactoryPack：factory manifest/声明文件不完整时在 salvage 前失败，旧安装保持原位") {
        withTempDirectory { root in
            let factory = root.appendingPathComponent("factory")
            let userPacks = root.appendingPathComponent("packs")
            let installed = userPacks.appendingPathComponent("minimal-chime")
            writeRestorePack(
                manifest:
                    #"{ "id": "minimal-chime", "events": { "stop": "missing-factory.mp3" } }"#,
                files: [:],
                to: factory.appendingPathComponent("minimal-chime"))
            writeRestorePack(
                manifest: #"{ "id": "minimal-chime", "events": {} }"#,
                files: ["my-extra.wav": "mine"],
                to: installed)
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: userPacks,
                factoryPacksDirectory: factory)

            let result = restoreFactoryPack(id: "minimal-chime", environment: environment)

            if case .failure(.invalidFactoryContents(let reason)) = result {
                expect(
                    reason.contains("missing-factory.mp3"),
                    "失败原因必须点名缺失的 factory 声明文件，实得 \(reason)")
            } else {
                expect(false, "不完整 factory 必须在替换前失败，实得 \(result)")
            }
            expect(
                (try? String(
                    contentsOf: installed.appendingPathComponent("my-extra.wav"),
                    encoding: .utf8)) == "mine",
                "factory 自身不完整时，旧安装不得被 salvage 或替换")
            let entries =
                (try? FileManager.default.contentsOfDirectory(atPath: userPacks.path)) ?? []
            expect(
                entries == ["minimal-chime"],
                "factory 验证失败不得产生 staging/salvage，实得 \(entries)")
        }
    }

    suite("restoreFactoryPack：目标是 symlink 时只搬链接本身，绝不触碰它指向的用户目录") {
        withTempDirectory { root in
            let factory = root.appendingPathComponent("factory")
            let userPacks = root.appendingPathComponent("packs")
            let external = root.appendingPathComponent("external-user-data")
            let destination = userPacks.appendingPathComponent("minimal-chime")
            writeRestorePack(
                manifest: #"{ "id": "minimal-chime", "events": {} }"#,
                files: ["factory.wav": "factory"],
                to: factory.appendingPathComponent("minimal-chime"))
            writeFixture("do-not-touch", to: external.appendingPathComponent("precious.wav"))
            createSymlink(at: destination, pointingTo: external)
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: userPacks,
                factoryPacksDirectory: factory)

            let result = restoreFactoryPack(id: "minimal-chime", environment: environment)

            guard case .success(let outcome) = result, let salvaged = outcome.salvaged else {
                expect(false, "目标 symlink 应被安全搬走后发布 factory，实得 \(result)")
                return
            }
            expect(
                (try? String(
                    contentsOf: external.appendingPathComponent("precious.wav"),
                    encoding: .utf8)) == "do-not-touch",
                "salvage 必须移动 symlink 目录项，绝不能移动/删除它指向的外部用户目录")
            let salvagedValues =
                try? URL(
                    fileURLWithPath: salvaged.movedTo
                ).resourceValues(forKeys: [.isSymbolicLinkKey])
            expect(
                salvagedValues?.isSymbolicLink == true,
                "salvage 路径必须保留原 symlink 本身，供用户检查")
            expect(
                (try? String(
                    contentsOf: destination.appendingPathComponent("factory.wav"),
                    encoding: .utf8)) == "factory",
                "最终路径必须是新的真实 factory 目录")
        }
    }
}
