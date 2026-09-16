import ClaudioCore
import Foundation

@MainActor
func runFileWriteWatchSuites() {
    suite("FileWriteWatch：原地恢复、原子替换、创建后删除均可观测") {
        withTempDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            let original = Data("before".utf8)
            try! original.write(to: file)
            let inPlace = FileWriteWatch(watching: file)
            expect(inPlace.isArmed, "原地写对照必须武装")
            try! Data("during".utf8).write(to: file)
            try! original.write(to: file)
            expect((try? Data(contentsOf: file)) == original, "对照终态需恢复原字节")
            expect(inPlace.observedWrite() == .written, "原地改写后恢复必须响")

            let atomic = FileWriteWatch(watching: file)
            expect(atomic.isArmed, "原子写对照必须武装")
            try! original.write(to: file, options: .atomic)
            expect(atomic.observedWrite() == .written, "相同字节的原子替换必须响")

            try! FileManager.default.removeItem(at: file)
            let createDelete = FileWriteWatch(watching: file)
            expect(createDelete.isArmed, "创建删除对照必须武装")
            try! original.write(to: file)
            try! FileManager.default.removeItem(at: file)
            expect(createDelete.observedWrite() == .written, "创建后删除必须响")
        }
    }

    suite("FileWriteWatch：只读探测和畸形 config 拒写无事件") {
        withTempDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            let lockFile = directory.appendingPathComponent("config.lock")
            let original = Data(#"{"selected_pack":"pika","events":{"stop":1}}"#.utf8)
            try! original.write(to: file)
            // Lock creation is a legitimate sibling write, so it must precede the watch.
            try! Data().write(to: lockFile)
            let probeWatch = FileWriteWatch(watching: file)
            expect(probeWatch.isArmed, "只读探测的观察器必须武装")
            guard case .malformed = probeConfigRewritable(configFile: file) else {
                expect(false, "fixture 必须被判为 malformed")
                return
            }
            expect((try? Data(contentsOf: file)) == original, "探测必须保留内容")
            expect(probeWatch.observedWrite() == .untouched, "探测必须没有写事件")

            let writeWatch = FileWriteWatch(watching: file)
            expect(writeWatch.isArmed, "拒写的观察器必须武装")
            let result = setEventEnabled(
                .stop, enabled: false, configFile: file, lockFile: lockFile)
            guard case .failure(.configReadFailure) = result else {
                expect(false, "畸形配置必须在写入前拒绝，got \(result)")
                return
            }
            expect((try? Data(contentsOf: file)) == original, "拒写必须保留内容")
            expect(writeWatch.observedWrite() == .untouched, "拒写必须没有写事件")
        }
    }
}
