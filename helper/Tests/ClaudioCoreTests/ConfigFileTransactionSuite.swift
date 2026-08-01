import ClaudioCore
import Darwin
import Foundation

@MainActor
func runConfigFileTransactionSuites() {
    suite("ConfigFileTransaction：外科式更新、一次备份、未知键与数组顺序保真") {
        withTempDirectory { directory in
            let file = directory.appendingPathComponent("hooks.json")
            let lock = directory.appendingPathComponent("hooks.lock")
            let backup = directory.appendingPathComponent("hooks.json.claudio.bak")
            let original = """
                {
                  "description": "third party",
                  "trust": {"opaque": "leave-me"},
                  "hooks": {"Stop": [{"matcher":"first"},{"matcher":"second"}]}
                }
                """.data(using: .utf8)!
            try! original.write(to: file)
            try! FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path)
            let transaction = ConfigFileTransaction(
                file: file, lockFile: lock, backupFile: backup, symlinkPolicy: .preserveTarget)

            let result = transaction.update { root in
                var next = root
                next["claudio"] = ["version": 1]
                return .replace(next)
            }
            expect(result == .success(.written), "第一次外科式更新必须写入")
            expect((try? Data(contentsOf: backup)) == original, "一次备份必须逐字等于写前字节")
            expect(transactionPermissions(at: backup) == 0o600, "备份不得把 0600 用户配置放宽成 0644")
            expect(transactionPermissions(at: file) == 0o600, "配置原子替换后必须保留原权限")

            let json = readTransactionJSONObject(at: file)
            expect((json["description"] as? String) == "third party", "未知顶层键必须保留")
            expect(
                ((json["trust"] as? [String: Any])?["opaque"] as? String) == "leave-me",
                "不透明 trust 数据必须保留")
            let groups = ((json["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]) ?? []
            expect(groups.compactMap { $0["matcher"] as? String } == ["first", "second"], "数组顺序必须保留")

            let firstBackup = try? Data(contentsOf: backup)
            _ = transaction.update { root in
                var next = root
                next["claudio"] = ["version": 2]
                return .replace(next)
            }
            expect((try? Data(contentsOf: backup)) == firstBackup, "已有一次备份绝不能被覆盖")
        }
    }

    suite("ConfigFileTransaction：空文件、畸形 JSON、只读与锁争用全部失败关闭") {
        withTempDirectory { directory in
            let file = directory.appendingPathComponent("hooks.json")
            let lock = directory.appendingPathComponent("hooks.lock")
            try! Data().write(to: file)
            let transaction = ConfigFileTransaction(file: file, lockFile: lock)
            let emptyBefore = try! Data(contentsOf: file)
            expect(
                transaction.update { _ in .unchanged }.failure?.isParseFailure == true,
                "空文件必须按 parse failure 失败关闭，不能当成空 object 覆盖")
            expect((try? Data(contentsOf: file)) == emptyBefore, "空文件失败后必须逐字未动")

            try! Data("[]".utf8).write(to: file)
            let arrayBefore = try! Data(contentsOf: file)
            expect(
                transaction.update { _ in .unchanged }.failure?.isMalformedTopLevel == true,
                "顶层 array 必须拒绝")
            expect((try? Data(contentsOf: file)) == arrayBefore, "畸形顶层失败后不得写")

            try! Data("{}".utf8).write(to: file)
            let holder = FileLock(path: lock.path)
            expect(holder.tryLock(), "fixture 必须先持有 transaction lock")
            expect(
                transaction.update { _ in .unchanged } == .failure(.lockBusy),
                "争用必须立即返回 lockBusy")
            holder.unlock()
        }
    }

    suite("ConfigFileTransaction：普通 symlink 保留链接节点并原子改写目标") {
        withTempDirectory { directory in
            let target = directory.appendingPathComponent("managed-hooks.json")
            let link = directory.appendingPathComponent("hooks.json")
            let lock = directory.appendingPathComponent("hooks.lock")
            try! Data("{\"third_party\":true}".utf8).write(to: target)
            try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let transaction = ConfigFileTransaction(
                file: link, lockFile: lock, symlinkPolicy: .preserveTarget)
            expect(
                transaction.update { root in
                    var next = root
                    next["claudio"] = true
                    return .replace(next)
                } == .success(.written),
                "允许的 dotfiles symlink 必须能更新")
            let attributes = try! FileManager.default.attributesOfItem(atPath: link.path)
            expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink, "写后 symlink 节点必须仍在")
            let json = readTransactionJSONObject(at: target)
            expect((json["third_party"] as? Bool) == true, "目标中的第三方键必须保留")
            expect((json["claudio"] as? Bool) == true, "更新必须落到 symlink 目标")
        }
    }

    suite("ConfigFileTransaction：dangling preserveTarget symlink 失败关闭且链接节点不变") {
        withTempDirectory { directory in
            let target = directory.appendingPathComponent("dotfiles/missing-hooks.json")
            let link = directory.appendingPathComponent("hooks.json")
            let lock = directory.appendingPathComponent("hooks.lock")
            let backup = directory.appendingPathComponent("hooks.json.claudio.bak")
            try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let originalDestination = try! FileManager.default.destinationOfSymbolicLink(
                atPath: link.path)
            let transaction = ConfigFileTransaction(
                file: link,
                lockFile: lock,
                backupFile: backup,
                symlinkPolicy: .preserveTarget)

            let result = transaction.update { root in
                var next = root
                next["claudio"] = true
                return .replace(next)
            }
            guard case .failure = result else {
                expect(false, "dangling symlink 不得被当作普通 missing 文件发布，got \(result)")
                return
            }
            expect(
                (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
                    == originalDestination,
                "失败后 dotfiles symlink 节点与目的字符串必须原样保留")
            expect(
                !FileManager.default.fileExists(atPath: target.path),
                "fail closed 不得越权创建原本不存在的 dotfiles 目标")
            expect(
                !FileManager.default.fileExists(atPath: backup.path),
                "零写入失败不得产生误导性备份")
        }
    }

    #if DEBUG
    suite("ConfigFileTransaction：初始 missing 在 CAS 前变成 dangling symlink 必须失败关闭") {
        withTempDirectory { directory in
            let file = directory.appendingPathComponent("hooks.json")
            let target = directory.appendingPathComponent("dotfiles/missing-hooks.json")
            let lock = directory.appendingPathComponent("hooks.lock")
            let transaction = ConfigFileTransaction(
                file: file, lockFile: lock, symlinkPolicy: .preserveTarget)

            let result = transaction.update(
                { root in
                    var next = root
                    next["claudio"] = true
                    return .replace(next)
                },
                betweenReadAndWrite: {
                    try! FileManager.default.createSymbolicLink(
                        at: file, withDestinationURL: target)
                })

            guard case .failure(.concurrentModification(let path)) = result else {
                expect(false, "新出现的 dangling symlink 必须触发 CAS 失败，got \(result)")
                return
            }
            expect(path == file.path, "CAS 错误必须指向原配置路径")
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            expect(
                attributes?[.type] as? FileAttributeType == .typeSymbolicLink,
                "失败后新出现的 symlink 节点必须仍在")
            expect(
                (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path))
                    == target.path,
                "失败后 symlink 目的字符串必须原样保留")
            expect(
                !FileManager.default.fileExists(atPath: target.path),
                "事务不得越权创建 dangling symlink 的目标")
        }
    }

    suite("ConfigFileTransaction：reject 策略必须在锁内重检后来出现的 symlink") {
        withTempDirectory { directory in
            let file = directory.appendingPathComponent("hooks.json")
            let target = directory.appendingPathComponent("managed-hooks.json")
            let lock = directory.appendingPathComponent("hooks.lock")
            let identical = Data("{\"owner\":\"same-bytes\"}".utf8)
            try! identical.write(to: file)
            try! identical.write(to: target)
            let transaction = ConfigFileTransaction(
                file: file, lockFile: lock, symlinkPolicy: .reject)

            let result = transaction.update(
                { root in
                    var next = root
                    next["claudio"] = true
                    return .replace(next)
                },
                betweenReadAndWrite: {
                    try! FileManager.default.removeItem(at: file)
                    try! FileManager.default.createSymbolicLink(
                        at: file, withDestinationURL: target)
                })

            expect(
                result == .failure(.symlinkRejected(path: file.path)),
                "reject 必须在持锁事务内识别同字节 regular→symlink 替换，got \(result)")
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            expect(
                attributes?[.type] as? FileAttributeType == .typeSymbolicLink,
                "reject 失败后外部创建的 symlink 节点必须仍在")
            expect((try? Data(contentsOf: target)) == identical, "reject 不得改写 symlink 目标")
        }
    }

    suite("ConfigFileTransaction：RENAME_EXCL 不受支持时用 link(2) 安全发布一次备份") {
        withTempDirectory { directory in
            let file = directory.appendingPathComponent("hooks.json")
            let lock = directory.appendingPathComponent("hooks.lock")
            let backup = directory.appendingPathComponent("hooks.json.claudio.bak")
            let original = Data("{\"third_party\":true}".utf8)
            try! original.write(to: file)
            let transaction = ConfigFileTransaction(
                file: file,
                lockFile: lock,
                backupFile: backup,
                testingExclusiveRename: { _, _ in
                    errno = ENOTSUP
                    return -1
                })

            let result = transaction.update { root in
                var next = root
                next["claudio"] = true
                return .replace(next)
            }
            expect(result == .success(.written), "不支持 RENAME_EXCL 的卷仍须完成安全备份和配置写入")
            expect((try? Data(contentsOf: backup)) == original, "link fallback 备份必须是写前原字节")
            expect(
                (readTransactionJSONObject(at: file)["claudio"] as? Bool) == true,
                "fallback 成功后配置事务必须继续提交")
        }
    }

    suite("ConfigFileTransaction：CAS 发现外部并发修改后绝不覆盖") {
        withTempDirectory { directory in
            let file = directory.appendingPathComponent("hooks.json")
            let lock = directory.appendingPathComponent("hooks.lock")
            try! Data("{\"owner\":\"before\"}".utf8).write(to: file)
            let transaction = ConfigFileTransaction(file: file, lockFile: lock)
            let external = Data("{\"owner\":\"external\"}".utf8)
            let result = transaction.update(
                { root in
                    var next = root
                    next["claudio"] = true
                    return .replace(next)
                },
                betweenReadAndWrite: { try! external.write(to: file) })
            expect(
                result == .failure(.concurrentModification(path: file.path)),
                "CAS 必须报告 concurrentModification")
            expect((try? Data(contentsOf: file)) == external, "外部写者字节必须原样存活")

            try! FileManager.default.removeItem(at: file)
            let missingTransaction = ConfigFileTransaction(file: file, lockFile: lock)
            let resultForConcurrentUnreadable = missingTransaction.update(
                { root in
                    var next = root
                    next["claudio"] = true
                    return .replace(next)
                },
                betweenReadAndWrite: {
                    try! FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
                })
            expect(
                resultForConcurrentUnreadable
                    == .failure(.concurrentModification(path: file.path)),
                "缺失文件在 CAS 前变成不可读对象也必须算外部修改，不能与 missing 混成 nil")
            var isDirectory: ObjCBool = false
            expect(
                FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue,
                "CAS 失败后外部创建的目录必须原样存活")
        }
    }

    suite("ConfigFileTransaction：staging 完成后的最终发布 CAS 仍拒绝外部新字节") {
        withTempDirectory { directory in
            let file = directory.appendingPathComponent("hooks.json")
            let lock = directory.appendingPathComponent("hooks.lock")
            let backup = directory.appendingPathComponent("hooks.json.claudio.bak")
            let original = Data("{\"owner\":\"before\"}".utf8)
            let external = Data("{\"owner\":\"after-staging\"}".utf8)
            try! original.write(to: file)
            let transaction = ConfigFileTransaction(
                file: file, lockFile: lock, backupFile: backup)

            let result = transaction.update(
                { root in
                    var next = root
                    next["claudio"] = true
                    return .replace(next)
                },
                betweenReadAndWrite: nil,
                beforeFinalPublish: {
                    // This seam runs only after the replacement staging file has been fully
                    // written/fsynced, immediately before the publication-boundary CAS.
                    try! external.write(to: file)
                })

            expect(
                result == .failure(.concurrentModification(path: file.path)),
                "最终 rename 边界必须重新执行 CAS，got \(result)")
            expect(
                (try? Data(contentsOf: file)) == external,
                "staging 之后到达的外部写者必须逐字节存活")
            expect(
                (try? Data(contentsOf: backup)) == original,
                "一次性备份即使已发布也只能保存事务最初读取的原字节")
        }
    }

    suite("ConfigFileTransaction：preserveTarget symlink 改指向时即使目标字节相同也必须 CAS 失败") {
        withTempDirectory { directory in
            let firstTarget = directory.appendingPathComponent("managed-a.json")
            let secondTarget = directory.appendingPathComponent("managed-b.json")
            let link = directory.appendingPathComponent("hooks.json")
            let lock = directory.appendingPathComponent("hooks.lock")
            let identical = Data("{\"owner\":\"same-bytes\"}".utf8)
            try! identical.write(to: firstTarget)
            try! identical.write(to: secondTarget)
            try! FileManager.default.createSymbolicLink(
                at: link, withDestinationURL: firstTarget)

            let transaction = ConfigFileTransaction(
                file: link, lockFile: lock, symlinkPolicy: .preserveTarget)
            let result = transaction.update(
                { root in
                    var next = root
                    next["claudio"] = true
                    return .replace(next)
                },
                betweenReadAndWrite: {
                    try! FileManager.default.removeItem(at: link)
                    try! FileManager.default.createSymbolicLink(
                        at: link, withDestinationURL: secondTarget)
                })

            expect(
                result == .failure(.concurrentModification(path: link.path)),
                "CAS 必须把 symlink 从 A 改指 B 视为外部修改，不能只比较目标字节")
            expect((try? Data(contentsOf: firstTarget)) == identical, "原目标 A 必须零写入")
            expect((try? Data(contentsOf: secondTarget)) == identical, "新目标 B 也必须零写入")
            expect(
                link.resolvingSymlinksInPath().standardizedFileURL
                    == secondTarget.standardizedFileURL,
                "外部写者的新 symlink 指向必须原样保留")
        }
    }

    suite("ConfigFileTransaction：symlink NFC/NFD 目标字节变化即使解析到同一文件也必须 CAS 失败") {
        withTempDirectory { directory in
            let nfdName = "managed-e\u{301}.json"
            let nfcName = "managed-\u{00E9}.json"
            expect(nfdName == nfcName, "测试前提：Swift String == 必须视两种规范化为等价")
            expect(
                !nfdName.utf8.elementsEqual(nfcName.utf8),
                "测试前提：两个 symlink 目标必须是不同 UTF-8 字节")

            let nfdTargetPath = directory.path + "/" + nfdName
            let nfcTargetPath = directory.path + "/" + nfcName
            expect(
                !nfdTargetPath.utf8.elementsEqual(nfcTargetPath.utf8),
                "测试前提：不得先经过 URL.path 把目标 payload 规范化")
            let nfdTarget = URL(fileURLWithPath: nfdTargetPath)
            let nfcTarget = URL(fileURLWithPath: nfcTargetPath)
            let link = directory.appendingPathComponent("hooks.json")
            let lock = directory.appendingPathComponent("hooks.lock")
            let identical = Data("{\"owner\":\"same-file-or-same-bytes\"}".utf8)
            try! identical.write(to: nfdTarget)
            if !FileManager.default.fileExists(atPath: nfcTarget.path) {
                try! identical.write(to: nfcTarget)
            }
            expect(
                Darwin.symlink(nfdTargetPath, link.path) == 0,
                "测试前提：必须以 POSIX API 原样创建 NFD symlink payload")

            let transaction = ConfigFileTransaction(
                file: link, lockFile: lock, symlinkPolicy: .preserveTarget)
            let result = transaction.update(
                { root in
                    var next = root
                    next["claudio"] = true
                    return .replace(next)
                },
                betweenReadAndWrite: {
                    try! FileManager.default.removeItem(at: link)
                    expect(
                        Darwin.symlink(nfcTargetPath, link.path) == 0,
                        "测试前提：必须以 POSIX API 原样创建 NFC symlink payload")
                })

            expect(
                result == .failure(.concurrentModification(path: link.path)),
                "raw symlink target 的 UTF-8 改变必须被 CAS 识别，got \(result)")
            expect((try? Data(contentsOf: nfdTarget)) == identical, "被钉住的旧目标不得写入")
            expect((try? Data(contentsOf: nfcTarget)) == identical, "外部改指的新目标不得写入")
            var finalBuffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
            let finalCount = link.withUnsafeFileSystemRepresentation { path -> Int in
                guard let path else { return -1 }
                return finalBuffer.withUnsafeMutableBytes { bytes in
                    Darwin.readlink(
                        path,
                        bytes.baseAddress!.assumingMemoryBound(to: CChar.self),
                        bytes.count)
                }
            }
            expect(
                finalCount >= 0
                    && Data(finalBuffer.prefix(finalCount)) == Data(nfcTargetPath.utf8),
                "外部写者的 NFC symlink payload 必须逐字节保留")
        }
    }
    #endif

    suite("ConfigFileTransaction：编码后超过 maximumBytes 必须拒绝且零写入") {
        withTempDirectory { directory in
            let file = directory.appendingPathComponent("hooks.json")
            let lock = directory.appendingPathComponent("hooks.lock")
            let backup = directory.appendingPathComponent("hooks.json.claudio.bak")
            let original = Data("{\"third_party\":true}".utf8)
            try! original.write(to: file)
            let transaction = ConfigFileTransaction(
                file: file,
                lockFile: lock,
                backupFile: backup,
                maximumBytes: 96)

            let result = transaction.update { root in
                var next = root
                next["claudio"] = String(repeating: "x", count: 256)
                return .replace(next)
            }
            if case .failure(.mutationRejected(let reason)) = result {
                expect(
                    reason.contains("maximumBytes") || reason.contains("上限"),
                    "超限拒绝理由必须明确指向编码大小上限，got \(reason)")
            } else {
                expect(false, "编码后超限必须返回 mutationRejected，got \(result)")
            }
            expect((try? Data(contentsOf: file)) == original, "超限后原配置必须逐字节未动")
            expect(
                !FileManager.default.fileExists(atPath: backup.path),
                "超限在发布前就应失败，不得留下误导性备份")
        }
    }
}

private func readTransactionJSONObject(at url: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: url),
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return root
}

private func transactionPermissions(at url: URL) -> Int? {
    guard
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
        let value = attributes[.posixPermissions] as? NSNumber
    else { return nil }
    return value.intValue
}

private extension Result where Success == ConfigFileTransactionOutcome, Failure == ConfigFileTransactionError {
    var failure: ConfigFileTransactionError? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}

private extension ConfigFileTransactionError {
    var isParseFailure: Bool {
        if case .parseFailure = self { return true }
        return false
    }

    var isMalformedTopLevel: Bool {
        if case .malformedTopLevel = self { return true }
        return false
    }
}
