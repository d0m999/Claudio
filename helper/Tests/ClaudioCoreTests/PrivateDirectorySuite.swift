import ClaudioCore
import Darwin
import Foundation

@MainActor
func runPrivateDirectorySuites() {
    suite("ensurePrivateDirectoryTree：umask 000 下新建树仍为 0700，已有祖先权限不变") {
        withTempDirectory { scratch in
            try! FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scratch.path)
            let previous = Darwin.umask(0)
            defer { _ = Darwin.umask(previous) }
            let leaf = scratch.appendingPathComponent("claudio/integrations/receipts", isDirectory: true)
            try! ensurePrivateDirectoryTree(at: leaf)
            expect(privateDirectoryPermissions(scratch) == 0o755, "非 Claudio 祖先不得被 chmod")
            for relative in ["claudio", "claudio/integrations", "claudio/integrations/receipts"] {
                expect(
                    privateDirectoryPermissions(scratch.appendingPathComponent(relative)) == 0o700,
                    "\(relative) 必须是 0700")
            }
        }
    }

    suite("ensurePrivateDirectoryTree：已有最终目录会收紧到 0700，validate-only 入口保留显式只读权限") {
        withTempDirectory { scratch in
            let tightened = scratch.appendingPathComponent("tightened", isDirectory: true)
            try! FileManager.default.createDirectory(at: tightened, withIntermediateDirectories: false)
            try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tightened.path)
            try! ensurePrivateDirectoryTree(at: tightened)
            expect(privateDirectoryPermissions(tightened) == 0o700, "最终目录必须收紧为 0700")

            let preserved = scratch.appendingPathComponent("preserved", isDirectory: true)
            try! FileManager.default.createDirectory(at: preserved, withIntermediateDirectories: false)
            try! FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: preserved.path)
            try! ensurePrivateDirectoryExists(at: preserved)
            expect(privateDirectoryPermissions(preserved) == 0o500, "validate-only 不得偷偷恢复写权限")
        }
    }

    suite("ensurePrivateDirectoryTree：任一层 symlink 或非目录节点都失败关闭") {
        withTempDirectory { scratch in
            let target = scratch.appendingPathComponent("target", isDirectory: true)
            try! FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            let link = scratch.appendingPathComponent("link", isDirectory: true)
            createSymlink(at: link, pointingTo: target)
            do {
                try ensurePrivateDirectoryTree(at: link.appendingPathComponent("receipts"))
                expect(false, "symlink 中间层不得被跟随")
            } catch let error as PrivateDirectoryError {
                expect(error == .unsafeNode(path: link.path), "必须点名 symlink 层，got \(error)")
            } catch {
                expect(false, "必须保留 typed PrivateDirectoryError，got \(error)")
            }

            let file = scratch.appendingPathComponent("plain")
            try! Data("x".utf8).write(to: file)
            do {
                try ensurePrivateDirectoryTree(at: file)
                expect(false, "普通文件不得冒充私有目录")
            } catch let error as PrivateDirectoryError {
                expect(error == .unsafeNode(path: file.path), "必须点名普通文件节点，got \(error)")
            } catch {
                expect(false, "必须保留 typed PrivateDirectoryError，got \(error)")
            }
        }
    }
}

private func privateDirectoryPermissions(_ url: URL) -> Int? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.posixPermissions] as? NSNumber)?.intValue
}
