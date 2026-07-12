import ClaudioCore
import ClaudioGUICore
import Foundation

// MARK: - T17: onboarding CTA 端到端接线
//
// ## 这个 suite 存在的意义：它必须抓得住那个真 bug
//
// T17 的真 bug 不是「执行器算错了」，而是**调用方递错了 URL** —— GUI 进程的
// `CommandLine.arguments[0]` 是 `Claudio.app/Contents/MacOS/Claudio`（SwiftUI app 自己），不是
// helper。如果那次查找留在 `MenuBarController` 的 `Bundle.main` 那一行里（AppKit，harness 够不到），
// 把它改成 `Bundle.main.executableURL` —— **字面意义上的本 bug** —— 整套测试会照样全绿：负例仍然
// 会拒绝一个 GUI 形状的 URL（当它被递进来时），e2e 仍然会给自己递一个正确的 URL。
//
// 所以查找本身被下沉进了 `ClaudioGUICore`（``bundledHelperBinary(in:)``），这个 suite 拿一个**真的
// 假 bundle** 去断言它解析出来的是哪一个文件。变异 → RED。
//
// ## 硬 fixture 规则（两条，各自都能造出一次假绿）
//
// 1. **绝不 `HOME=fixture`**：Darwin 上 `FileManager.homeDirectoryForCurrentUser` 忽略 `$HOME`，
//    会打到真实的 `~/.claude/settings.json`。一切都走注入的 temp 路径。
// 2. **destination 必须含字面 `.claudio` 分量**（`<tmp>/.claudio/bin/claudio`，不是仓库里其它
//    suite 惯用的 `dot-claudio/`）：`uninstallClaudioHooks` 的摘除锚点是
//    `claudioNamespaceRoot(forBinaryPath:)`，它 `components.firstIndex(of: ".claudio")` —— 拿
//    `dot-claudio` 会 fail-closed 返回 nil，于是 uninstall **摘 0 条却返回 `.success`**。
//    一个只断言「没报错」的断开测试会在什么都没测的情况下变绿。

// MARK: - Fixtures

/// 一个**真的** app bundle 布局：`<root>/Claudio.app/Contents/{MacOS/Claudio, Resources/bin/claudio,
/// Resources/packs/<id>/...}` —— 与 `.github/workflows/release.yml` 的 "Assemble Claudio.app" 逐字
/// 同构（`ReleaseLayoutSuite` 钉住这一点）。
@MainActor
private struct FixtureBundle {
    let appDirectory: URL
    /// `Contents/Resources/bin/claudio` —— 真 helper。
    let helperBinary: URL
    /// `Contents/MacOS/Claudio` —— GUI 自己的可执行文件。**T17 的 bug 就是把这个当成了 helper。**
    let guiBinary: URL
    let bundledPacksDirectory: URL

    static let helperMagicBytes = "#!/bin/sh\n# I am the real claudio helper\nexit 0\n"
    static let guiMagicBytes = "#!/bin/sh\n# I am the SwiftUI app, NOT the helper\nexit 0\n"

    init(in root: URL, packIDs: [String] = ["minimal-chime"]) {
        appDirectory = root.appendingPathComponent("Claudio.app", isDirectory: true)
        let contents = appDirectory.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        helperBinary = resources.appendingPathComponent("bin/claudio")
        guiBinary = contents.appendingPathComponent("MacOS/Claudio")
        bundledPacksDirectory = resources.appendingPathComponent("packs", isDirectory: true)

        writeExecutable(Self.helperMagicBytes, to: helperBinary)
        writeExecutable(Self.guiMagicBytes, to: guiBinary)

        for id in packIDs {
            let pack = bundledPacksDirectory.appendingPathComponent(id, isDirectory: true)
            let manifest = """
                {"schema":1,"id":"\(id)","name":"极简铃音","license":"CC0-1.0",
                 "events":{"stop":"stop.mp3","stop_failure":"stop_failure.mp3",
                           "notification":"notification.mp3","subagent_stop":"subagent_stop.mp3"}}
                """
            writeFixture(manifest, to: pack.appendingPathComponent("manifest.json"))
            for event in Event.allCases {
                writeFixture(
                    Data([0xFF, 0xFB, 0x00, 0x00]),
                    to: pack.appendingPathComponent("\(event.cliName).mp3"))
            }
        }

        // Info.plist — `Bundle(url:)` 需要它才认这是一个 bundle。
        writeFixture(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleExecutable</key><string>Claudio</string>
            <key>CFBundleIdentifier</key><string>com.claudio.app.fixture</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            </dict></plist>
            """, to: contents.appendingPathComponent("Info.plist"))
    }

    private func writeExecutable(_ contents: String, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: url.path, contents: Data(contents.utf8),
            attributes: [.posixPermissions: 0o755])
    }
}

/// 一份**注入的**、完全隔离的目标环境。`.claudio`（真的点）不是 `dot-claudio` —— 见文件头。
@MainActor
private struct FixtureTargets {
    let onboarding: OnboardingEnvironment
    let userPacksDirectory: URL
    let configFile: URL
    let lockFile: URL

    init(in root: URL) {
        let claudeDirectory = root.appendingPathComponent("dot-claude", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: claudeDirectory, withIntermediateDirectories: true)
        let claudioRoot = root.appendingPathComponent(".claudio", isDirectory: true)

        onboarding = OnboardingEnvironment(
            settingsFile: claudeDirectory.appendingPathComponent("settings.json"),
            claudioBinaryPath: claudioRoot.appendingPathComponent("bin/claudio"))
        userPacksDirectory = claudioRoot.appendingPathComponent("packs", isDirectory: true)
        configFile = claudioRoot.appendingPathComponent("config.json")
        lockFile = claudioRoot.appendingPathComponent("play.lock")
    }

    func environment(bundledHelperBinary: URL?) -> OnboardingActionEnvironment {
        OnboardingActionEnvironment(
            onboarding: onboarding, bundledHelperBinary: bundledHelperBinary,
            userPacksDirectory: userPacksDirectory, configFile: configFile, lockFile: lockFile)
    }
}

@MainActor
private func readString(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return String(data: data, encoding: .utf8)
}

/// settings.json 里每个事件下挂着的 hook 命令串。
///
/// **解析，不是子串匹配**：Foundation 的 `JSONSerialization` 把 `/` 写成 `\/`，于是对原始文本
/// `contains("/var/folders/...")` 永远为假 —— 一条断言会因为一个与被测行为毫无关系的理由而红
/// （或者更糟：一条 `!contains(...)` 会因此而**假绿**）。
@MainActor
private func hookCommands(in settingsFile: URL) -> [String: [String]] {
    guard let data = try? Data(contentsOf: settingsFile),
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let hooks = root["hooks"] as? [String: Any]
    else { return [:] }

    var result: [String: [String]] = [:]
    for (eventName, value) in hooks {
        guard let groups = value as? [[String: Any]] else { continue }
        result[eventName] = groups.flatMap { group -> [String] in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }
    return result
}

// MARK: - Suites

@MainActor
func runOnboardingActionsSuites() {

    // MARK: intent ↔ copy 不变式

    suite("每个 state：copy 里有几颗按钮，就有几个 intent —— 一颗按钮都不许是死的") {
        // 驱动源是 `PreviewFixtures.onboardingStates`（**唯一的**那份名册），不是本文件手抄的第二份：
        // `OnboardingState` 不是 `CaseIterable`（两个带 payload 的 case），所以「六个 case 都测到了」
        // 没有编译期保证，只有名册的单一来源能提供它。
        for state in PreviewFixtures.onboardingStates {
            let copy = onboardingCopy(for: state)
            let primary = onboardingPrimaryIntent(for: state)
            let secondary = onboardingSecondaryIntent(for: state)

            expect(
                (copy.primaryActionTitle != nil) == (primary != nil),
                "\(state): 主 CTA 的按钮与 intent 必须同生共死 —— 有按钮没 intent = 点了没反应（T17 的 bug 本身），"
                    + "有 intent 没按钮 = 一条用户按不到的写盘路径。title=\(String(describing: copy.primaryActionTitle))"
                    + " intent=\(String(describing: primary))")
            expect(
                (copy.secondaryActionTitle != nil) == (secondary != nil),
                "\(state): 次 CTA 的按钮与 intent 必须同生共死。"
                    + "title=\(String(describing: copy.secondaryActionTitle)) intent=\(String(describing: secondary))")
        }
    }

    suite("坏配置的三个态：CTA 是「重新检测」，一个字节都不写") {
        // 用户的 Claude Code 没装 / 配置文件没权限 / 格式坏了 —— 都不是 Claudio 该替他动手的东西。
        // 自动去改一份坏 config，是把一次诚实的报错换成一次静默的数据丢失。
        for state in [
            OnboardingState.claudeCodeNotInstalled,
            .settingsNotWritable(reason: "x"),
            .settingsParseFailure(reason: "x"),
        ] {
            expect(
                onboardingPrimaryIntent(for: state) == .reDetect,
                "\(state) 的主 CTA 必须是 .reDetect（只看，不写），得到 \(String(describing: onboardingPrimaryIntent(for: state)))")
            expect(
                onboardingPrimaryIntent(for: state)?.diskAction == nil,
                "\(state) 的主 CTA 绝不能碰磁盘")
        }
    }

    suite("会写盘的 intent 恰好是两个：takeOver 与 disconnect") {
        expect(OnboardingActionIntent.takeOver.diskAction == .takeOver, "")
        expect(OnboardingActionIntent.disconnect.diskAction == .disconnect, "")
        expect(OnboardingActionIntent.reDetect.diskAction == nil, ".reDetect 绝不写盘")
        expect(OnboardingActionIntent.revealDetail.diskAction == nil, ".revealDetail 是纯视图状态")
    }

    // MARK: bundle 查找 —— T17 的要害那一行

    suite("bundledHelperBinary(in:) 解析出 Contents/Resources/bin/claudio —— 不是 Contents/MacOS/Claudio") {
        withTempDirectory { root in
            let fixture = FixtureBundle(in: root)
            guard let bundle = Bundle(url: fixture.appDirectory) else {
                expect(false, "Bundle(url:) 认不出这个 fixture bundle —— 测试本身坏了，不是被测代码坏了")
                return
            }

            let resolved = bundledHelperBinary(in: bundle)
            expect(
                resolved?.resolvingSymlinksInPath() == fixture.helperBinary.resolvingSymlinksInPath(),
                "必须解析到 bundle 里的 helper，得到 \(String(describing: resolved?.path))")
            // 变异钉子：把 `bundledHelperBinary(in:)` 的实现换成 `bundle.executableURL`
            // （= T17 的 bug），下面这条立刻 RED。
            expect(
                resolved?.lastPathComponent == "claudio",
                "解析结果的文件名必须是 claudio（GUI 自己那个叫 Claudio，大写 C）")
            expect(
                resolved?.path.contains("/Contents/MacOS/") != true,
                "绝不能解析到 Contents/MacOS/ —— 那是 SwiftUI app 自己")
        }
    }

    suite("bundledHelperBinary(in:) 在没有 Resources/bin/ 的 bundle 上返回 nil（= 开发构建）") {
        withTempDirectory { root in
            // 只有 Info.plist + MacOS/Claudio，没有 Resources/bin —— `swift run ClaudioGUI` 的形状。
            let appDirectory = root.appendingPathComponent("Bare.app", isDirectory: true)
            let contents = appDirectory.appendingPathComponent("Contents", isDirectory: true)
            writeExecutableFile(at: contents.appendingPathComponent("MacOS/Claudio"))
            writeFixture(
                "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>"
                    + "<key>CFBundleIdentifier</key><string>x.y</string></dict></plist>",
                to: contents.appendingPathComponent("Info.plist"))

            guard let bundle = Bundle(url: appDirectory) else {
                expect(false, "Bundle(url:) 认不出这个 fixture bundle")
                return
            }
            expect(
                bundledHelperBinary(in: bundle) == nil,
                "没有 Resources/bin/claudio 时必须是 nil —— 它会一路变成面板上一句真错误，不是静默 no-op")
        }
    }

    // MARK: takeOverHelperSource —— 「哪个二进制会被复制」

    suite("takeOverHelperSource：bundle 里的 helper 胜出") {
        withTempDirectory { root in
            let fixture = FixtureBundle(in: root)
            let targets = FixtureTargets(in: root)
            let result = takeOverHelperSource(
                environment: targets.environment(bundledHelperBinary: fixture.helperBinary))
            switch result {
            case .success(.bundled(let url)):
                expect(
                    url.resolvingSymlinksInPath() == fixture.helperBinary.resolvingSymlinksInPath(),
                    "得到 \(url.path)")
            case .success(let other):
                expect(false, "期望 .bundled，得到 \(other)")
            case .failure(let error):
                expect(false, "不该失败：\(error)")
            }
        }
    }

    suite("takeOverHelperSource：递进来一个 GUI 形状的路径 → 大声拒绝，绝不悄悄回落") {
        withTempDirectory { root in
            let fixture = FixtureBundle(in: root)
            let targets = FixtureTargets(in: root)
            // 让 destination **也**是一个可用的二进制 —— 于是「悄悄回落到 destination」这条路是通的。
            // 它仍然必须拒绝：一个存在、但不叫 `claudio` 的 bundle 路径只可能是 T17 的 bug 本身，
            // 悄悄回落会把它藏起来。
            writeExecutableFile(at: targets.onboarding.claudioBinaryPath)

            let result = takeOverHelperSource(
                environment: targets.environment(bundledHelperBinary: fixture.guiBinary))
            switch result {
            case .failure(.helperUnavailable(let reason)):
                expect(
                    reason.contains(fixture.guiBinary.path),
                    "错误里要说清是哪条路径，得到：\(reason)")
            case .failure(let other):
                expect(false, "期望 .helperUnavailable，得到 \(other)")
            case .success(let source):
                expect(
                    false,
                    "递进来 Contents/MacOS/Claudio（GUI 自己）必须失败，却成功了：\(source) —— "
                        + "这正是 T17 的整个 bug：把 SwiftUI app 复制成 helper，此后每个事件都去 exec 一个 app")
            }
        }
    }

    suite("takeOverHelperSource：没有 bundle 但 helper 已装 → 用它自己（开发构建的 .notInstalled）") {
        withTempDirectory { root in
            let targets = FixtureTargets(in: root)
            writeExecutableFile(at: targets.onboarding.claudioBinaryPath)

            let result = takeOverHelperSource(
                environment: targets.environment(bundledHelperBinary: nil))
            switch result {
            case .success(.alreadyInstalled(let url)):
                expect(url == targets.onboarding.claudioBinaryPath, "得到 \(url.path)")
            case .success(let other):
                expect(false, "期望 .alreadyInstalled，得到 \(other)")
            case .failure(let error):
                expect(
                    false,
                    "helper 已经在位时，接管是一个完全可以满足的请求（performFirstRunSetup 的 alreadyInstalled "
                        + "分支跳过全部复制、只补选包与 hooks），不该硬报错：\(error)")
            }
        }
    }

    suite("takeOverHelperSource：既没 bundle、helper 也不在 → 一个真错误，不是静默 no-op") {
        withTempDirectory { root in
            let targets = FixtureTargets(in: root)
            let result = takeOverHelperSource(
                environment: targets.environment(bundledHelperBinary: nil))
            switch result {
            case .failure(.helperUnavailable): expect(true, "")
            case .failure(let other): expect(false, "期望 .helperUnavailable，得到 \(other)")
            case .success(let source): expect(false, "不该成功：\(source)")
            }
        }
    }

    suite("takeOverHelperSource：bundle 路径存在但是个 0 字节存根 → 拒绝") {
        withTempDirectory { root in
            let targets = FixtureTargets(in: root)
            let stub = root.appendingPathComponent("Claudio.app/Contents/Resources/bin/claudio")
            writeEmptyExecutableFile(at: stub)  // 名字对、执行位对，但是空的

            let result = takeOverHelperSource(
                environment: targets.environment(bundledHelperBinary: stub))
            switch result {
            case .failure(.helperUnavailable): expect(true, "")
            case .failure(let other): expect(false, "期望 .helperUnavailable，得到 \(other)")
            case .success: expect(false, "一次半途而废的复制留下的 0 字节存根不是一个可用的 helper")
            }
        }
    }

    // MARK: 端到端 —— 接管真的把正确的字节写到了正确的地方

    suite("接管（端到端）：装的是 helper 的字节，不是 GUI 的；包真的落了地；hooks 指向 destination") {
        withTempDirectory { root in
            let fixture = FixtureBundle(in: root)
            let targets = FixtureTargets(in: root)

            let result = performOnboardingDiskAction(
                .takeOver, environment: targets.environment(bundledHelperBinary: fixture.helperBinary))

            guard case .success(.tookOver(let outcome)) = result else {
                expect(false, "接管必须成功，得到 \(result)")
                return
            }
            guard case .completed(let copiedBinary, let copiedPacks, _, let packSelection, let hooks) = outcome
            else {
                expect(false, "outcome 形状不对：\(outcome)")
                return
            }
            expect(copiedBinary, "必须真的复制了二进制")
            expect(copiedPacks == ["minimal-chime"], "必须复制了内置包，得到 \(copiedPacks)")
            expect(packSelection == .selectedDefault(packID: "minimal-chime"), "首次必须挑一个默认包，得到 \(String(describing: packSelection))")
            expect(hooks == .installed, "必须真的写了 hooks，得到 \(hooks)")

            // ① **装进去的是哪个二进制** —— 这是 T17 的整个要害。断言字节，不是断言「文件存在」。
            let installed = readString(targets.onboarding.claudioBinaryPath)
            expect(
                installed == FixtureBundle.helperMagicBytes,
                "~/.claudio/bin/claudio 必须是 HELPER 的字节。如果它是 GUI 的字节，Claude Code 的每一个事件"
                    + "都会去 exec 一个 SwiftUI app。得到：\(String(describing: installed))")
            expect(
                installed != FixtureBundle.guiMagicBytes,
                "装进去的是 GUI 二进制 —— 这就是 T17 那个 bug，端到端复现了")
            expect(
                FileManager.default.isExecutableFile(atPath: targets.onboarding.claudioBinaryPath.path),
                "装好的 helper 必须可执行")

            // ② 包目录是从 executablePath 反推的（去掉两级 + packs）。递错 URL 时它会反推成
            //    `Contents/packs`（不存在）→ 一个包都复制不出来，且**不报错**。
            let landedManifest = targets.userPacksDirectory
                .appendingPathComponent("minimal-chime/manifest.json")
            expect(
                FileManager.default.fileExists(atPath: landedManifest.path),
                "内置包必须真的落进用户包根 —— 包目录是从 helper 路径反推的，递错 URL 时这里会是空的")

            // ③ config 真的选了包。
            let config = readString(targets.configFile) ?? ""
            expect(config.contains("minimal-chime"), "config.json 必须记下选中的包，得到：\(config)")

            // ④ hooks 真的指向 destination（而不是 bundle 里那份、或别的什么）。
            //
            // **解析 JSON，不做子串匹配**：Foundation 的 JSONSerialization 会把 `/` 转义成 `\/`，
            // 所以对着原始文本 `contains(path)` 会假红（第一版就是这么翻的）。
            let commands = hookCommands(in: targets.onboarding.settingsFile)
            for event in Event.allCases {
                expect(
                    commands[event.settingsName]?.isEmpty == false,
                    "settings.json 必须有 \(event.settingsName) 的 hook，得到 \(commands)")
            }
            let allCommands = commands.values.flatMap { $0 }
            expect(
                allCommands.allSatisfy { $0.contains(targets.onboarding.claudioBinaryPath.path) },
                "每条 hook 命令都必须指向装好的 destination 路径，得到：\(allCommands)")
            expect(
                allCommands.allSatisfy { !$0.contains(fixture.helperBinary.path) },
                "hook 绝不能指向 app bundle 里那份 —— 用户把 app 挪走 / 删掉，声音就全没了。得到：\(allCommands)")
        }
    }

    suite("接管（端到端）：装出来的 helper 没有 com.apple.quarantine —— 否则每个 hook 都被 SIGKILL") {
        withTempDirectory { root in
            let fixture = FixtureBundle(in: root)
            let targets = FixtureTargets(in: root)

            // 模拟「从未签名 DMG 下载下来的 app」：Gatekeeper 会给 bundle 里每个文件盖这个章。
            let quarantineValue = "0083;68713a00;Safari;\(UUID().uuidString)"
            _ = quarantineValue.withCString { pointer in
                setxattr(
                    fixture.helperBinary.path, "com.apple.quarantine", pointer, strlen(pointer), 0, 0)
            }
            expect(
                hasQuarantineAttribute(at: fixture.helperBinary),
                "setup: fixture 必须真的带上 quarantine，否则这个用例什么都没测")

            let result = performOnboardingDiskAction(
                .takeOver, environment: targets.environment(bundledHelperBinary: fixture.helperBinary))
            guard case .success = result else {
                expect(false, "接管必须成功，得到 \(result)")
                return
            }

            // `FileManager.copyItem` 会把 quarantine 一起复制过去（实测，Darwin 25.5）。而一个带
            // quarantine 的二进制，被 `/bin/sh -c` 执行时会被 Gatekeeper 直接 SIGKILL（实测 exit=137，
            // 零 stderr）。`play` 是 fire-and-forget，所以那条失败链**一行日志都不会留下**：面板亮绿点、
            // doctor 说「✓ 在位」、用户永远听不到一声响。
            expect(
                !hasQuarantineAttribute(at: targets.onboarding.claudioBinaryPath),
                "装好的 helper 仍带 com.apple.quarantine —— 它一被 hook 执行就会被系统杀掉，而且完全静默")
        }
    }

    suite("接管：幂等 —— 跑第二遍不重复写 hooks、不覆盖用户已有的同名包") {
        withTempDirectory { root in
            let fixture = FixtureBundle(in: root)
            let targets = FixtureTargets(in: root)
            let environment = targets.environment(bundledHelperBinary: fixture.helperBinary)

            _ = performOnboardingDiskAction(.takeOver, environment: environment)

            // 用户「改过」这个包 —— 第二遍绝不能把它覆盖掉。
            let userTouched = targets.userPacksDirectory
                .appendingPathComponent("minimal-chime/manifest.json")
            writeFixture("{\"id\":\"minimal-chime\",\"events\":{},\"USER\":\"touched\"}", to: userTouched)

            let second = performOnboardingDiskAction(.takeOver, environment: environment)
            guard case .success(.tookOver(.completed(_, let copiedPacks, _, _, let hooks))) = second else {
                expect(false, "第二遍必须成功，得到 \(second)")
                return
            }
            expect(copiedPacks.isEmpty, "第二遍不该再复制任何包，得到 \(copiedPacks)")
            expect(hooks == .alreadyInstalled, "第二遍不该重复写 hooks（会响两声），得到 \(hooks)")
            expect(
                readString(userTouched)?.contains("USER") == true,
                "用户自己改过的同名包必须原样保留")
        }
    }

    // MARK: 断开

    suite("断开：真的摘掉四条、保留第三方 hook、状态回落 .notInstalled") {
        withTempDirectory { root in
            let fixture = FixtureBundle(in: root)
            let targets = FixtureTargets(in: root)
            let environment = targets.environment(bundledHelperBinary: fixture.helperBinary)

            _ = performOnboardingDiskAction(.takeOver, environment: environment)
            expect(
                detectOnboardingState(environment: targets.onboarding) == .installed,
                "setup: 接管之后必须是 .installed")

            let result = performOnboardingDiskAction(.disconnect, environment: environment)
            // **断言 count，不只是 .success**：`uninstallClaudioHooks` 在摘了 0 条时也返回
            // `.success(.notInstalled)`。只断言「没报错」的测试会在什么都没摘的情况下变绿 ——
            // 而 fixture 路径里那个字面 `.claudio` 分量正是让它真的摘得掉的原因（见文件头规则 2）。
            guard case .success(.disconnected(let count)) = result else {
                expect(false, "断开必须成功且真的摘掉了东西，得到 \(result)")
                return
            }
            expect(count == Event.allCases.count, "必须摘掉四条，得到 \(count)")

            let remaining = hookCommands(in: targets.onboarding.settingsFile).values.flatMap { $0 }
            expect(
                remaining.allSatisfy { !$0.contains(targets.onboarding.claudioBinaryPath.path) },
                "settings.json 里不该再有任何指向 claudio 的命令，得到：\(remaining)")
            expect(
                detectOnboardingState(environment: targets.onboarding) == .notInstalled,
                "断开之后必须回落 .notInstalled（二进制还在，只是 hooks 摘了）")
        }
    }

    suite("断开：一条都没摘 → 报失败，绝不报成功") {
        withTempDirectory { root in
            let targets = FixtureTargets(in: root)
            // 二进制在、但 settings.json 里压根没有 claudio 的 hook。
            writeExecutableFile(at: targets.onboarding.claudioBinaryPath)
            writeFixture("{\"hooks\": {}}", to: targets.onboarding.settingsFile)

            let result = performOnboardingDiskAction(
                .disconnect, environment: targets.environment(bundledHelperBinary: nil))
            switch result {
            case .failure(.disconnectSweptNothing):
                expect(true, "")
            default:
                expect(
                    false,
                    "从 .installed 点断开却摘了 0 条，是结构性矛盾（探测器刚刚证明四条 hook 都在）——"
                        + "必须响。得到 \(result)")
            }
        }
    }

    suite("断开：只摘 claudio 自己的，第三方 hook 一条不动") {
        withTempDirectory { root in
            let fixture = FixtureBundle(in: root)
            let targets = FixtureTargets(in: root)
            let environment = targets.environment(bundledHelperBinary: fixture.helperBinary)

            writeFixture(
                #"""
                { "hooks": { "Stop": [ { "hooks": [
                    { "type": "command", "command": "/usr/local/bin/some-other-tool notify" }
                ] } ] } }
                """#, to: targets.onboarding.settingsFile)

            _ = performOnboardingDiskAction(.takeOver, environment: environment)
            _ = performOnboardingDiskAction(.disconnect, environment: environment)

            let remaining = hookCommands(in: targets.onboarding.settingsFile).values.flatMap { $0 }
            expect(
                remaining.contains { $0.contains("some-other-tool") },
                "第三方 hook 必须原样活下来（uninstall 是本仓库唯一的破坏性动作，而且它不做备份）。得到：\(remaining)")
        }
    }

    // MARK: 错误文案

    suite("OnboardingActionError.message 过 T7 禁词表；工程原话只进 technicalDetail") {
        let forbidden = ["settings.json", "hook", "claudio install", "claudio play"]
        let errors: [OnboardingActionError] = [
            .helperUnavailable(reason: "/x/Contents/MacOS/Claudio 不是小助手"),
            .setupFailed(.installFailure(.notWritable(reason: "settings.json 不可写"))),
            .setupFailed(.binaryQuarantined(reason: "隔离没解掉")),
            .disconnectFailed(.lockBusy),
            .disconnectSweptNothing,
        ]
        for error in errors {
            let lowered = error.message.lowercased()
            for word in forbidden {
                expect(
                    !lowered.contains(word.lowercased()),
                    "面板正文里出现了工程语「\(word)」：\(error.message) —— 底层 reason 只能进 detail")
            }
            expect(!error.message.isEmpty, "每个错误都必须有一句人话")
        }
        // 工程原话没有丢，只是搬到了披露之后。
        expect(
            OnboardingActionError
                .setupFailed(.installFailure(.notWritable(reason: "boom")))
                .technicalDetail?.contains("boom") == true,
            "technicalDetail 必须承载底层原因，否则用户永远查不出为什么")
    }
}

// MARK: - T17 修复批：死按钮 / 失败归属 / 隔离态（由 diff 对抗评审逼出来的）

@MainActor
func runOnboardingActionsFixSuites() {

    suite("【死按钮回归】面板上渲染出来的每一颗 CTA，都必须映射到一个非 nil 的 intent") {
        // T17 第一版在 `OnboardingView` 里**合成**了一颗「查看原因」：当 `copy.secondaryActionTitle`
        // 是 nil 且动作失败带 detail 时。而它的 action 走 `performSecondaryAction()` →
        // `onboardingSecondaryIntent(.notInstalled)` = **nil** → `perform(nil)` → 只 refresh。
        // **点了什么都不会发生。** 在杀死「有按钮但没动作」的那次提交里，把它以另一种形状复刻了。
        //
        // 原来那条不变式抓不到它，因为它断的是「**copy 里**的按钮 ↔ intent」—— 而这颗按钮压根不在
        // copy 里，是视图自己变出来的。所以这条断言升级为：遍历 **state × actionState** 的全部组合，
        // 断言此刻**会被渲染出来的每一颗控件**都有一个真的去处。
        let actionStates: [OnboardingActionState] = [
            .idle,
            .running(.takeOver),
            .failed(action: .takeOver, message: "m", detail: "d"),
            .failed(action: .takeOver, message: "m", detail: nil),
            .failed(action: .disconnect, message: "m", detail: "d"),
        ]
        for state in PreviewFixtures.onboardingStates {
            let copy = onboardingCopy(for: state)
            for actionState in actionStates {
                // 视图渲染的次按钮**只来自 copy** —— 不再合成。
                if copy.secondaryActionTitle != nil {
                    expect(
                        onboardingSecondaryIntent(for: state) != nil,
                        "\(state) × \(actionState)：copy 给了一颗次按钮，它必须有 intent")
                }
                if copy.primaryActionTitle != nil {
                    expect(
                        onboardingPrimaryIntent(for: state) != nil,
                        "\(state) × \(actionState)：copy 给了一颗主按钮，它必须有 intent")
                }
                // 而「查看原因」现在是**失败行自己**的一部分，有自己的入口（`toggleDetail()`）——
                // 它出现的条件由一个纯函数决定，且必须与「真的有原因可看」一致。
                let showsToggle = onboardingShowsFailureDetailToggle(
                    state: state, actionState: actionState)
                if showsToggle {
                    guard case .failed(_, _, let detail) = actionState, detail != nil else {
                        expect(false, "\(state) × \(actionState)：长出了一颗「查看原因」，却没有原因可看")
                        continue
                    }
                    expect(
                        onboardingSecondaryIntent(for: state) != .revealDetail,
                        "\(state)：次 CTA 本身就是「查看原因」了，失败行不该再长一颗 —— 两颗按钮做同一件事")
                }
            }
        }
    }

    suite("失败带 detail 时，「查看原因」必须出现 —— 否则文案在骗人（正文写着「看看下面的原因」）") {
        for state in [OnboardingState.notInstalled, .helperMissing, .installed] {
            expect(
                onboardingShowsFailureDetailToggle(
                    state: state,
                    actionState: .failed(action: .takeOver, message: "m", detail: "写不进去")),
                "\(state)：一次带 detail 的失败必须有办法展开它")
            expect(
                !onboardingShowsFailureDetailToggle(
                    state: state, actionState: .failed(action: .takeOver, message: "m", detail: nil)),
                "\(state)：没有 detail 就别长按钮")
            expect(
                !onboardingShowsFailureDetailToggle(state: state, actionState: .idle),
                "\(state)：没失败就别长按钮")
        }
        // 这两个态的次 CTA 本来就是「查看原因」，不重复给。
        for state in [
            OnboardingState.settingsNotWritable(reason: "x"), .settingsParseFailure(reason: "x"),
        ] {
            expect(
                !onboardingShowsFailureDetailToggle(
                    state: state,
                    actionState: .failed(action: .takeOver, message: "m", detail: "d")),
                "\(state)：次 CTA 已经是「查看原因」了，失败行不该再长一颗")
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // T17c：**每一个 `.failed` 都必须有人画** —— 遍历 state × actionState 的全组合。
    //
    // 上一版这里钉的是「接管的失败画在 onboarding 卡，断开的失败画在运行态面板 —— 绝不串台」，
    // 而那条断言**把 bug 钉住了**：它默认「哪个动作失败」与「失败之后 state 落在哪」是同一件事。
    // 它们不是 —— `runDiskAction` 在失败之后无条件重新探测磁盘。于是矩阵里有两个格子没有任何视图
    // 认领（`.failed(.takeOver)` × `.installed`，以及 `.failed(.disconnect)` × 非 `.installed`），
    // 而第一格是**可达的**：quarantine 检测让一台被盖章的机器报 `.helperMissing`（hooks 本来就在），
    // 用户点「修复」→ setup 在写 config / hooks 那一步撞上 play.lock → 失败 → refresh 探测到
    // 二进制在位 + 没盖章 + 四条 hook 都在 → `.installed` → 面板切到运行态、亮绿点说「已接好」，
    // 而那条失败一个像素都没有。用户永远听不到一声响。
    //
    // 现在的不变式不再是「分派对不对」，而是「**存不存在一个没人画的失败**」—— 一条结构性断言，
    // 加新 state / 新 action 都自动被它覆盖。
    // ═══════════════════════════════════════════════════════════════════════════════
    suite("不变式：state × actionState 全组合下，任何一条 .failed 都必须有视图画它（T17c）") {
        // 面板的两个渲染点互斥地占据屏幕：`.installed` → operationalPanel；其余 → OnboardingView。
        // 两者都调 `onboardingVisibleFailure(actionState:)`，所以「屏幕上画不画得出这条失败」
        // 就等价于这个纯函数返不返回 nil —— 与 state 无关，这正是修法的全部内容。
        let allStates: [OnboardingState] = [
            .claudeCodeNotInstalled,
            .helperMissing,
            .notInstalled,
            .installed,
            .settingsNotWritable(reason: "r"),
            .settingsParseFailure(reason: "r"),
        ]
        let allActionStates: [OnboardingActionState] = [
            .idle,
            .running(.takeOver),
            .running(.disconnect),
            .failed(action: .takeOver, message: "接管失败了", detail: "d"),
            .failed(action: .takeOver, message: "接管失败了", detail: nil),
            .failed(action: .disconnect, message: "断开失败了", detail: "d"),
            .failed(action: .disconnect, message: "断开失败了", detail: nil),
        ]

        for state in allStates {
            for actionState in allActionStates {
                let visible = onboardingVisibleFailure(actionState: actionState)
                switch actionState {
                case .failed(_, let message, _):
                    expect(
                        visible?.message == message,
                        "\(state) × \(actionState)：一条失败没有任何视图画它 —— 这正是 T17 要杀死的"
                            + "那类静默失败（第三个形状：死错误）。用户会看到一张一切正常的面板，"
                            + "而磁盘上什么都没成")
                case .idle, .running:
                    expect(visible == nil, "\(state) × \(actionState)：没失败就不该画失败行")
                }
            }
        }
    }

    suite("不变式：焦点序里的「查看原因」⟺ 屏幕上真的有那颗按钮（T17c）") {
        // 上一版这两者会分叉：`onboardingShowsFailureDetailToggle`（决定焦点序）是分支盲的，而
        // `onboardingFailureBelongsHere`（决定渲染）是分支感知的。于是
        // `.failed(.takeOver)` × `.installed` 时焦点序里被塞进一个 `.revealDetail`，而当时没有任何
        // 视图声明 `.focused(…, equals: .revealDetail)` —— 面板一打开，键盘焦点落进一个不存在的控件。
        let allStates: [OnboardingState] = [
            .claudeCodeNotInstalled, .helperMissing, .notInstalled, .installed,
            .settingsNotWritable(reason: "r"), .settingsParseFailure(reason: "r"),
        ]
        for state in allStates {
            for detail in [String?.some("d"), nil] {
                for action in [OnboardingDiskAction.takeOver, .disconnect] {
                    let actionState = OnboardingActionState.failed(
                        action: action, message: "m", detail: detail)
                    let showsToggle = onboardingShowsFailureDetailToggle(
                        state: state, actionState: actionState)
                    let rowIsOnScreen = onboardingVisibleFailure(actionState: actionState) != nil
                    let hasDetailToRead = detail != nil
                    let stateOwnsTheToggle =
                        onboardingSecondaryIntent(for: state) == .revealDetail

                    expect(
                        showsToggle
                            == (rowIsOnScreen && hasDetailToRead && !stateOwnsTheToggle),
                        "\(state) × \(actionState)：焦点序里有没有「查看原因」，必须与屏幕上有没有"
                            + "那颗按钮完全一致 —— 否则光标会落进一个不存在的控件（或够不到一个存在的）")
                }
            }
        }
    }

    suite("焦点：「查看原因」是一个真控件，必须在焦点序里（WCAG 2.1.1）") {
        let onboarding = panelFocusOrder(
            .onboarding(hasPrimaryAction: true, hasSecondaryAction: false, hasDetailToggle: true))
        expect(
            onboarding == [.revealDetail, .onboardingPrimaryAction],
            "失败行画在按钮上方，焦点序跟随视觉序。得到 \(onboarding)")

        let operational = panelFocusOrder(
            .operational(events: [], packCardIDs: [], hasDetailToggle: true))
        expect(
            operational == [.dropZone, .revealDetail, .disconnect],
            "运行态：失败行在「断开连接」之上。得到 \(operational)")

        let withoutToggle = panelFocusOrder(
            .operational(events: [], packCardIDs: [], hasDetailToggle: false))
        expect(
            !withoutToggle.contains(.revealDetail),
            "没有失败行时不该凭空多一个焦点位。得到 \(withoutToggle)")
    }

    suite("被隔离的 helper：面板绝不能报 .installed（doctor 已经硬失败了，面板不能继续撒谎）") {
        withTempDirectory { root in
            let fixture = FixtureBundle(in: root)
            let targets = FixtureTargets(in: root)
            _ = performOnboardingDiskAction(
                .takeOver, environment: targets.environment(bundledHelperBinary: fixture.helperBinary))
            expect(
                detectOnboardingState(environment: targets.onboarding) == .installed,
                "setup: 干净安装之后必须是 .installed")

            // 模拟一次「修复前的旧安装」留下的被隔离二进制。
            let value = "0083;68713a00;Safari;\(UUID().uuidString)"
            _ = value.withCString { pointer in
                setxattr(
                    targets.onboarding.claudioBinaryPath.path, "com.apple.quarantine", pointer,
                    strlen(pointer), 0, 0)
            }

            expect(
                detectOnboardingState(environment: targets.onboarding) == .helperMissing,
                "一个带 com.apple.quarantine 的二进制会被 Gatekeeper 在每次 hook 执行时 SIGKILL"
                    + "（实测 exit=137，零 stderr）。面板绝不能说「已经接好了」—— 那是撒谎，而且是最静默的"
                    + "那一种：用户永远听不到一声响，也永远不知道为什么。回落 .helperMissing 让「修复」"
                    + "这颗 CTA 出现，点它就会解除隔离。")

            // 而「修复」确实治得好它。
            _ = performOnboardingDiskAction(
                .takeOver, environment: targets.environment(bundledHelperBinary: fixture.helperBinary))
            expect(
                detectOnboardingState(environment: targets.onboarding) == .installed,
                "点一下「修复」必须真的把它治好（performFirstRunSetup 的无条件解除隔离那一步）")
        }
    }
}
