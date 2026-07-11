import ClaudioCore
import Foundation

// MARK: - com.apple.quarantine（T17，2026-07-12 实测）
//
// 这一族测试钉住的是一条**实测出来的、结构上不可观察的**发版级失败链：
//
//   未签名 DMG → Claudio.app 全身带 com.apple.quarantine
//   → `FileManager.copyItem` 把这个 xattr 一起复制到 ~/.claudio/bin/claudio（实测，Darwin 25.5）
//   → Claude Code 的 hook 用 `/bin/sh -c '<abs>/claudio play stop'` 执行它
//   → Gatekeeper SIGKILL（实测 exit=137，零输出、零 stderr）
//   → `play` 是 fire-and-forget，一行 claudio.log 都不会留下
//   → 面板亮绿点说「已经接好了」，doctor 说「✓ 二进制在位」，用户永远听不到一声响
//
// 剥掉之后，同一个二进制、同一条命令：正常运行，exit=0。

@MainActor
private func setQuarantine(at url: URL) {
    // Gatekeeper 给「从 Safari 下载的未签名东西」写的就是这个形状。
    let value = "0083;68713a00;Safari;\(UUID().uuidString)"
    _ = value.withCString { pointer in
        setxattr(url.path, "com.apple.quarantine", pointer, strlen(pointer), 0, 0)
    }
}

/// 一个非空、可执行的正规文件 —— 已装好的 `claudio` 二进制的现实替身。
/// （helper 侧 `TestSupport.swift` 里没有这个 helper；gui 侧有一个同名的，但那是另一个包的测试
/// 目标，按本仓库既有的「按包复制而非跨包共享测试 helper」约定不共享。）
@MainActor
private func writeExecutableFile(at url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(
        atPath: url.path, contents: Data("#!/bin/sh\nexit 0\n".utf8),
        attributes: [.posixPermissions: 0o755])
}

@MainActor
func runQuarantineSuites() {
    suite("stripQuarantineAttribute: 剥掉一个正规文件上的章") {
        withTempDirectory { root in
            let file = root.appendingPathComponent("claudio")
            writeExecutableFile(at: file)
            setQuarantine(at: file)
            expect(
                hasQuarantineAttribute(at: file),
                "setup: fixture 必须真的带上章，否则这个用例什么都没测（剥不剥都会「通过」）")

            stripQuarantineAttribute(at: file)
            expect(!hasQuarantineAttribute(at: file), "章必须被剥掉")
        }
    }

    suite("stripQuarantineAttribute: 递归 —— 目录、子目录、里面每个文件") {
        withTempDirectory { root in
            let pack = root.appendingPathComponent("minimal-chime", isDirectory: true)
            let nested = pack.appendingPathComponent("nested", isDirectory: true)
            let manifest = pack.appendingPathComponent("manifest.json")
            let audio = nested.appendingPathComponent("stop.mp3")
            writeFixture("{}", to: manifest)
            writeFixture("x", to: audio)
            for url in [pack, nested, manifest, audio] { setQuarantine(at: url) }
            for url in [pack, nested, manifest, audio] {
                expect(hasQuarantineAttribute(at: url), "setup: \(url.lastPathComponent) 必须带章")
            }

            stripQuarantineAttribute(at: pack)

            for url in [pack, nested, manifest, audio] {
                expect(
                    !hasQuarantineAttribute(at: url),
                    "\(url.lastPathComponent) 上的章没剥掉 —— 「除了你看不见的那些之外都清干净了」正是"
                        + "那种日后会以一桩悬案的形式回来的清理")
            }
        }
    }

    suite("stripQuarantineAttribute: 没有章 / 路径不存在 —— 不崩、不抱怨（ENOATTR / ENOENT 都是成功）") {
        withTempDirectory { root in
            let clean = root.appendingPathComponent("clean")
            writeExecutableFile(at: clean)
            stripQuarantineAttribute(at: clean)  // 本来就没有章：绝大多数开发构建的常态
            expect(!hasQuarantineAttribute(at: clean), "")

            stripQuarantineAttribute(at: root.appendingPathComponent("nope/nothing/here"))
            expect(true, "对一条不存在的路径调用它不该崩")
        }
    }

    suite("hasQuarantineAttribute: 只回答「这条路径上有没有章」，不跟随符号链接") {
        withTempDirectory { root in
            let target = root.appendingPathComponent("target")
            writeExecutableFile(at: target)
            setQuarantine(at: target)

            let link = root.appendingPathComponent("link")
            createSymlink(at: link, pointingTo: target)

            expect(hasQuarantineAttribute(at: target), "目标带章")
            expect(
                !hasQuarantineAttribute(at: link),
                "XATTR_NOFOLLOW：问的是链接自己，不是它指向的东西 —— 与 readRegularFileBounded 的"
                    + " O_NOFOLLOW 是同一条「绝不顺着链接走出我们以为在的那棵树」的纪律")
        }
    }
}

// MARK: - performFirstRunSetup 侧：装出来的东西必须跑得起来

@MainActor
func runSetupQuarantineSuites() {
    /// 一个「刚从未签名 DMG 里拖出来」形状的 bundle：helper + 内置包，全身带章。
    func makeQuarantinedBundle(in root: URL) -> URL {
        let binDirectory = root.appendingPathComponent(
            "Claudio.app/Contents/Resources/bin", isDirectory: true)
        let packsDirectory = root.appendingPathComponent(
            "Claudio.app/Contents/Resources/packs/minimal-chime", isDirectory: true)
        let executablePath = binDirectory.appendingPathComponent("claudio")
        try? FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try? Data("#!fake-binary-fixture".utf8).write(to: executablePath)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executablePath.path)
        writeFixture(
            #"{ "schema": 1, "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
            to: packsDirectory.appendingPathComponent("manifest.json"))

        setQuarantine(at: executablePath)
        setQuarantine(at: packsDirectory)
        setQuarantine(at: packsDirectory.appendingPathComponent("manifest.json"))
        return executablePath
    }

    func makeEnvironment(root: URL, executablePath: URL) -> SetupEnvironment {
        let claudioRoot = root.appendingPathComponent(".claudio", isDirectory: true)
        // `installClaudioHooks` 要求 settings.json 的父目录存在（`~/.claude/` 是 Claude Code 自己
        // 建的），否则它会 fail-closed —— 这是真实行为，不是 fixture 的瑕疵。
        try? FileManager.default.createDirectory(
            at: root.appendingPathComponent("dot-claude", isDirectory: true),
            withIntermediateDirectories: true)
        return SetupEnvironment(
            executablePath: executablePath,
            claudioBinaryDestination: claudioRoot.appendingPathComponent("bin/claudio"),
            userPacksDirectory: claudioRoot.appendingPathComponent("packs", isDirectory: true),
            configFile: claudioRoot.appendingPathComponent("config.json"),
            settingsFile: root.appendingPathComponent("dot-claude/settings.json"),
            lockFile: claudioRoot.appendingPathComponent("play.lock"))
    }

    suite("performFirstRunSetup: 从一个带隔离章的 bundle 装出来的 helper，必须是干净的") {
        withTempDirectory { root in
            let executablePath = makeQuarantinedBundle(in: root)
            let environment = makeEnvironment(root: root, executablePath: executablePath)
            expect(
                hasQuarantineAttribute(at: executablePath),
                "setup: 源二进制必须真的带章，否则这个用例什么都没测")

            let result = performFirstRunSetup(environment: environment)
            guard case .success = result else {
                expect(false, "setup 必须成功，得到 \(result)")
                return
            }

            expect(
                !hasQuarantineAttribute(at: environment.claudioBinaryDestination),
                "装好的 ~/.claudio/bin/claudio 仍带 com.apple.quarantine —— hook 用 /bin/sh -c 执行它时"
                    + "会被 Gatekeeper SIGKILL（实测 exit=137），而 play 是 fire-and-forget，"
                    + "整条失败链一行日志都不会留下：面板亮绿点、doctor 说在位、用户永远听不到一声响")
            expect(
                !hasQuarantineAttribute(
                    at: environment.userPacksDirectory.appendingPathComponent("minimal-chime")),
                "复制进来的包也不该留着章（不是 load-bearing，但半清不清的树只会招来下一桩悬案）")
        }
    }

    suite("performFirstRunSetup: 重跑（alreadyInstalled，跳过复制）也会把一个遗留的章清掉") {
        withTempDirectory { root in
            let claudioRoot = root.appendingPathComponent(".claudio", isDirectory: true)
            let destination = claudioRoot.appendingPathComponent("bin/claudio")
            // 一个「上一次（修复前的）安装留下的」被隔离的二进制。
            writeExecutableFile(at: destination)
            setQuarantine(at: destination)

            try? FileManager.default.createDirectory(
                at: root.appendingPathComponent("dot-claude", isDirectory: true),
                withIntermediateDirectories: true)
            // executablePath == destination → alreadyInstalled 分支：**整个复制步骤都被跳过**。
            let environment = SetupEnvironment(
                executablePath: destination,
                claudioBinaryDestination: destination,
                userPacksDirectory: claudioRoot.appendingPathComponent("packs", isDirectory: true),
                configFile: claudioRoot.appendingPathComponent("config.json"),
                settingsFile: root.appendingPathComponent("dot-claude/settings.json"),
                lockFile: claudioRoot.appendingPathComponent("play.lock"))

            let result = performFirstRunSetup(environment: environment)
            guard case .success = result else {
                expect(false, "重跑必须成功，得到 \(result)")
                return
            }
            expect(
                !hasQuarantineAttribute(at: destination),
                "「重跑 claudio setup 就能自愈」是 docs/distribution.md 对用户的承诺 —— 对这条失败也得成立。"
                    + "复制步骤被跳过时，剥离必须仍然发生（所以它在 `if !alreadyInstalled` 块之外）")
        }
    }

    suite("doctor: 一个带隔离章的二进制是硬失败，不是「✓ 在位」") {
        withTempDirectory { root in
            let binary = root.appendingPathComponent(".claudio/bin/claudio")
            writeExecutableFile(at: binary)

            func binaryCheck() -> DoctorCheckResult? {
                runDoctorChecks(
                    environment: DoctorEnvironment(
                        settingsFile: root.appendingPathComponent("dot-claude/settings.json"),
                        configFile: root.appendingPathComponent(".claudio/config.json"),
                        userPacksDirectory: root.appendingPathComponent(".claudio/packs"),
                        logFile: root.appendingPathComponent(".claudio/claudio.log"),
                        claudioBinaryPath: binary.path)
                )
                .results.first { $0.name == "claudio-binary" }
            }

            expect(
                binaryCheck()?.severity == .ok,
                "对照组：一个干净的二进制必须报 ok，否则下面那条断言可能因为别的原因而「通过」")

            setQuarantine(at: binary)
            guard let quarantined = binaryCheck() else {
                expect(false, "doctor 必须有一项 claudio-binary 检查")
                return
            }
            expect(
                quarantined.severity == .failure,
                "「在位」不等于「跑得起来」：`isExecutableFile` 对一个被隔离的二进制完全满意，而 hook 执行它时"
                    + "系统会直接杀掉它。对用户而言，后果与「二进制不在」一字不差 —— 每个事件都静默失声，"
                    + "所以它与后者同为硬失败。得到 \(quarantined.severity)")
            expect(
                quarantined.message.contains("隔离"),
                "错误信息必须说清是隔离，并给出可执行的修法。得到：\(quarantined.message)")
        }
    }
}
