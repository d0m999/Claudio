import ClaudioCore
import Foundation

@MainActor
func runAnchoredFileIOSuites() {
    suite("AnchoredFileIO：已有目标被外部删除后不得复活") {
        withTempDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            let original = Data("before".utf8)
            try! original.write(to: file)
            let io = try! AnchoredFileIO(file: file, preserveFinalSymlink: true)
            let snapshot = try! io.read(maxBytes: 1024)
            try! FileManager.default.removeItem(at: file)
            do {
                try io.publish(Data("ours".utf8), expected: snapshot)
                expect(false, "外部删除必须拒绝发布")
            } catch {}
            expect(!FileManager.default.fileExists(atPath: file.path), "已删除的 config 不得复活")
        }
    }

    suite("AnchoredFileIO：首次创建与外部创建竞争时不得覆盖") {
        withTempDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            let io = try! AnchoredFileIO(file: file, preserveFinalSymlink: true)
            let snapshot = try! io.read(maxBytes: 1024)
            let external = Data("external".utf8)
            try! external.write(to: file)
            do {
                try io.publish(Data("ours".utf8), expected: snapshot)
                expect(false, "外部首次创建必须拒绝覆盖")
            } catch {}
            expect((try? Data(contentsOf: file)) == external, "外部文件必须保留")
        }
    }

    suite("AnchoredFileIO：symlink 改指向与父目录换位都不得重定向") {
        withTempDirectory { root in
            let first = root.appendingPathComponent("first.json")
            let second = root.appendingPathComponent("second.json")
            let link = root.appendingPathComponent("config.json")
            try! Data("first".utf8).write(to: first)
            try! Data("second".utf8).write(to: second)
            try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
            let io = try! AnchoredFileIO(file: link, preserveFinalSymlink: true)
            let snapshot = try! io.read(maxBytes: 1024)
            try! FileManager.default.removeItem(at: link)
            try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
            do {
                try io.publish(Data("ours".utf8), expected: snapshot)
                expect(false, "改指向必须拒绝")
            } catch {}
            expect((try? Data(contentsOf: first)) == Data("first".utf8), "旧目标必须保留")
            expect((try? Data(contentsOf: second)) == Data("second".utf8), "新目标必须保留")

            let parent = root.appendingPathComponent("parent", isDirectory: true)
            let moved = root.appendingPathComponent("moved", isDirectory: true)
            try! FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            let originalFile = parent.appendingPathComponent("manifest.json")
            try! Data("old".utf8).write(to: originalFile)
            let pinned = try! AnchoredFileIO(file: originalFile, preserveFinalSymlink: false)
            let pinnedSnapshot = try! pinned.read(maxBytes: 1024)
            try! FileManager.default.moveItem(at: parent, to: moved)
            try! FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            try! Data("new".utf8).write(to: originalFile)
            do {
                try pinned.publish(Data("ours".utf8), expected: pinnedSnapshot)
                expect(false, "目录换位必须拒绝")
            } catch {}
            expect((try? Data(contentsOf: originalFile)) == Data("new".utf8), "新目录不得被重定向写入")
            expect(
                (try? Data(contentsOf: moved.appendingPathComponent("manifest.json")))
                    == Data("old".utf8), "旧目录原件必须保留")
        }
    }

    suite("AnchoredFileIO：成功交换保留链接；晚期外部替换保留恢复文件") {
        withTempDirectory { directory in
            let target = directory.appendingPathComponent("managed.json")
            let link = directory.appendingPathComponent("config.json")
            try! Data("before".utf8).write(to: target)
            try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let io = try! AnchoredFileIO(file: link, preserveFinalSymlink: true)
            let snapshot = try! io.read(maxBytes: 1024)
            try! io.publish(Data("ours".utf8), expected: snapshot)
            expect((try? Data(contentsOf: target)) == Data("ours".utf8), "原目标应被更新")
            expect(
                (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil,
                "链接入口必须保留")

            let next = try! io.read(maxBytes: 1024)
            let external = Data("external".utf8)
            do {
                try io.publish(
                    Data("ours-again".utf8), expected: next,
                    testingBeforeRename: { try! external.write(to: target, options: .atomic) })
                expect(false, "晚期外部替换必须有独立结果")
            } catch AnchoredFileError.publishedWithConflict(let recoveryPath) {
                expect(
                    (try? Data(contentsOf: URL(fileURLWithPath: recoveryPath))) == external,
                    "外部对象必须留在恢复路径")
                expect(
                    (try? Data(contentsOf: target)) == Data("ours-again".utf8),
                    "返回错误时也须承认发布已经发生")
            } catch {
                expect(false, "应为发布后冲突，got \(error)")
            }
        }
    }
}
