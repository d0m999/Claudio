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
    let configLockFile: URL
    let settingsLockFile: URL

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
        configLockFile = claudioRoot.appendingPathComponent("config.lock")
        settingsLockFile = claudioRoot.appendingPathComponent("settings.lock")
    }

    func environment(bundledHelperBinary: URL?) -> OnboardingActionEnvironment {
        OnboardingActionEnvironment(
            onboarding: onboarding, bundledHelperBinary: bundledHelperBinary,
            userPacksDirectory: userPacksDirectory, configFile: configFile,
            configLockFile: configLockFile, settingsLockFile: settingsLockFile)
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

/// `config.json` 里**真正被选中**的那个包（解析，不是子串匹配）。
///
/// `readString(configFile)?.contains("minimal-chime")` 说不出「选包那一步跑完了」——
/// `{"note":"minimal-chime"}`、半截写坏的 JSON、甚至一句提到包名的注释，都能让它为真。而用它的
/// 那几条断言，失败消息写的是「config.json 里得躺着**选中的包**」。措辞比覆盖范围大
/// （`/codex review 2f107b5` 的 P2）。这里断的是解析出来的 `selected_pack` 本人。
@MainActor
private func selectedPack(in configFile: URL) -> String? {
    guard let data = try? Data(contentsOf: configFile),
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return root["selected_pack"] as? String
}

/// 一个文件此刻的**字节**；文件不存在 = `nil`。
///
/// 「动作前后两次快照相等」逐字表达「一个字节都没被碰过，也没有被凭空创建出来」——
/// 而这正是几条持锁断言的失败消息一直声称、却从来没有真正检查过的那句话
/// （`/codex review 2f107b5` 的 P1）：
///
/// 它们检查的是 `hookCommands(in:).allSatisfy { !$0.contains(claudioBinaryPath) }`。
/// `hookCommands` 在**文件不存在 / JSON 坏掉 / 没有 `hooks` 键**时一律返回 `[:]`，而空数组的
/// `allSatisfy` **恒真** —— 一个被创建成 `{}`、被写成坏 JSON、或被写进无关内容的 settings.json，
/// 照样让它变绿，然后它在失败消息里说「一个字节都没被碰过」。
///
/// （它并非**恒真式**：`:402` 那条 happy-path 断言正向证明了 `hookCommands` 在同一套 fixture 下
/// 确实能返回非空、且含 `claudioBinaryPath`。它是**措辞过宽**，不是永远不会红。）
@MainActor
private func fileBytes(_ url: URL) -> Data? {
    try? Data(contentsOf: url)
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
            expect(
                selectedPack(in: targets.configFile) == "minimal-chime",
                "config.json 必须记下**选中的包** —— 断的是解析出来的 `selected_pack`，不是 "
                    + "`contains(\"minimal-chime\")`（后者在 `{\"note\":\"minimal-chime\"}` 上也为真）。"
                    + "得到：\(String(describing: selectedPack(in: targets.configFile)))，"
                    + "原文：\(readString(targets.configFile) ?? "<无文件>")")

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

    // MARK: - 锁分离：接管 / 断开这两条写盘路径，各自守的到底是**哪一把**锁
    //
    // ## 这四条在补的那个洞（`/review e7c38ea` 的 P1，变异实测）
    //
    // 锁从面板一路传到磁盘写，要过四手：
    //
    //     PanelView.lockFile → OnboardingActionEnvironment.configLockFile
    //                        → SetupEnvironment.configLockFile
    //                        → selectPack / installClaudioHooks
    //
    // 在这四条之前，**中间那一手一条断言都没有** —— `OnboardingActions.swift:589-596` 把
    // `OnboardingActionEnvironment` 的两把锁灌进 `SetupEnvironment` 的那个构造点。它掉在两套绊线
    // 中间的缝里：`LockSeparationSuite` 只 `codeOnly("helper/…")`，`ViewWiringSuite` 的
    // `guiSources()` 只扫 `gui/Sources/ClaudioGUI` —— **没有任何东西读 `ClaudioGUICore`**。
    //
    // 实测变异（在真实文件上跑的，不是推理）：
    //
    // ```swift
    // // OnboardingActions.swift:595
    // configLockFile: ClaudioPaths.playLockFile,
    // ```
    //
    // 用户点下「接管」之后那几秒，config.json 的写占住 `play` 的去抖锁 —— 他在**最需要听见反馈的
    // 那一刻**被静音，而那正是阶段 A 存在的**唯一**理由。`claudio-tests` 1064 + `claudio-gui-tests`
    // 1607，**全绿，零红**。
    //
    // ## 为什么这四条是**行为**断言，而不是又一条源码绊线
    //
    // 绊线绑的是**符号名的文本**（`lockFile: environment.configLockFile`），而那个符号的**值**是
    // 上一层灌进来的。于是每一种「文本没变、值变了」的写法都能从它底下走过去：
    //
    // - 成对交换两把锁（全文件计数、每一处的符号名，全都原样成立）；
    // - `ClaudioPaths.root.appendingPathComponent("play.lock")` —— 拿到的是同一把去抖锁，而标识符
    //   `playLockFile` 一次都没出现，`!contains("playLockFile")` 照样绿；
    // - 三元表达式 `lockFile: flag ? environment.configLockFile : …` —— 逐字包含那个 needle；
    // - `configLockFile:` 里那个**大写的 `L`** —— `contains("lockFile")` 是大小写敏感的。
    //
    // 下面四条绑的是**真实的锁文件路径**：把注入的那把锁**真的持住**，再断言写必须在**那一步**
    // 撞上 `.lockBusy`。上面每一种绕法在它们面前都当场变红 —— 因为它们根本不看源码长什么样。
    //
    // 接缝从第一天起就在（`FixtureTargets` 一直在注入 `configLockFile` / `settingsLockFile`），
    // 只是**从来没有一条断言去持有它们**。注入一个测试接缝却从不求值它，等于没有这个接缝 ——
    // 这与 `EventMuteControllerSuite` 的「a contended lock fails and records .lockBusy」是同一招，
    // 那一招在静音路径上立着，却没人把它搬到接管路径上来。力气全花在了**难测的那一半**
    // （helper 的 CLI 默认值不可求值，只能读源码文本），而**好测的那一半**（GUI 的锁本来就是
    // 注入的）被留在裸奔状态。
    //
    // ## ⚠️ 为什么断的是「停在**哪一步**」，而不是「失败了」
    //
    // 只断言「接管失败了」会被**成对交换**整体满足：两把锁互换之后，持住 config.lock 依然会让接管
    // 失败 —— 只不过挡住的是 settings 那一步。那正是 `/codex review 840ea37` 的 P1 教训（计数不绑
    // 调用点）在**行为层**的同一个形状。
    //
    // `SetupError` 分得开阶段，所以这里能断死：`.useFailure` = config.json 的写（`selectPack`，
    // `Setup.swift:512`/`:523`），`.installFailure` = settings.json 的写（`installClaudioHooks`，
    // `Setup.swift:563`）。接管的顺序是 复制二进制 → 复制包 → 解隔离+回验 → 写 config → 写 hooks，
    // 所以持哪把锁、该停在哪一步，是**唯一确定**的。
    //
    // ## ⚠️⚠️ 而「停在哪一步」**也不够** —— 错误码不绑执行顺序（`/codex review be332ff` 的 P1）
    //
    // 上面那段推理有个没说出口的前提：**「返回哪个错误码」== 「做到了哪一步」**。它不成立。
    // 把 `Setup.swift` 里 `installClaudioHooks` 那一整段**挪到** `selectPack` **之前** —— 两个调用点的
    // `lockFile:` 实参一个字都不用改，全文件计数、每一处的符号名、③ 那三条调用点断言，全都原样成立 ——
    //
    // - 持 config.lock：hooks 先写（成功），再撞 config.lock → 依然是 `.useFailure(.lockBusy)`；
    // - 持 settings.lock：hooks 先写就撞上 → 依然是 `.installFailure(.lockBusy)`。
    //
    // **四条错误码断言，一条都不红。** 而此刻：一次**失败**的接管在用户的 `~/.claude/settings.json` 里
    // 留下了四条指向 helper 的 hook，config.json 里却一个包都没选中 —— 每个事件都会去 exec 一个选不出包的
    // helper。`Setup.swift:491` 的注释亲口立过这条不变式（「一次注定不会响的安装，绝不允许在用户的
    // Claude Code 里留下新的痕迹」），在这批断言之前**没有任何东西背书它**。
    //
    // 这与「计数不绑调用点」（`840ea37`）、「`contains` 不是绑定」（`e7c38ea`）是**逐字同一个病**，
    // 第九次：断言绑的东西比它声称守的东西弱一层。所以下面每一条持锁 suite 除了错误码，还各自断言
    // **磁盘上到底发生了什么** —— settings.json 有没有被碰过、config.json 有没有真的写完、四条 hook
    // 是不是一条不少 / 一条不剩。错误码是执行器的自述，磁盘是事实。

    // MARK: 写观测器自己的两条正向对照 —— 没有它们，下面每一条「必须没被碰过」都可能是恒真
    //
    // `FileWriteWatch`（`TestSupport.swift`）是下面四条 suite 的地基：它们断言的是
    // **「这个文件一次都没被写过」**，而不是「它此刻的字节没变」。而一个**观测不到写**的观测器
    // 会安静地永远返回 `false` —— 于是那四条永远绿，还在失败消息里自称守着 `Setup.swift:491`
    // 的不变式。那与 `2f107b5` 那条恒真守卫（读的是被它守的那个函数的输出）是**逐字同一个形状**，
    // 只是升了一层：这一次恒真的不是断言，是**它赖以判断的那个工具**。
    //
    // 所以观测器的每一半都在这里被单独钉死，喂的正是**字节比较看不见的那两种写法**：

    suite("写观测器①：一次「写了又删掉」必须被看见 —— 终态逐字相同，字节比较一声不吭") {
        withTempDirectory { root in
            let targets = FixtureTargets(in: root)
            let settings = targets.onboarding.settingsFile

            let before = fileBytes(settings)
            let watch = FileWriteWatch(watching: settings)
            expect(
                watch.isArmed,
                "test setup: 观测器没能武装起来（目录 fd / kevent 注册失败）—— 它会永远返回 false，"
                    + "于是下面每一条「必须没被碰过」都恒绿")

            // 这**就是** codex 在 `ee026db` 上指出的那种实现：写 hooks → 撞上另一把锁 → 把
            // settings.json 删回去。终态干净，而那个窗口里用户的 Claude Code 真的读得到那四条 hook。
            try? Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"x"}]}]}}"#.utf8)
                .write(to: settings, options: .atomic)
            try? FileManager.default.removeItem(at: settings)

            let after = fileBytes(settings)
            expect(
                after == before,
                "test setup: 这次「写了又删掉」的终态必须与写之前逐字相同（都是「无文件」）——"
                    + "否则它证明不了「字节比较看不见这次写」，这条对照就白设了。"
                    + "前 \(before?.count.description ?? "<无文件>")，"
                    + "后 \(after?.count.description ?? "<无文件>")")
            expect(
                watch.observedWrite(),
                "磁盘上真的躺过一份 settings.json，而字节比较全程绿（前后都是「无文件」）。观测器的"
                    + "**目录**那一半必须看得见它 —— 看不见 = 下面四条「必须没被碰过」全是恒真断言")
            // 问第二遍必须还是同一个答案。kqueue 的 `EV_CLEAR` 会在事件被取走之后清掉它，所以
            // `observedWrite()` 里那段缓存是**必需**的 —— 而今天每个调用点都只问一次，于是那段缓存
            // 除了这一条之外**没有任何断言在钉它**：删掉缓存，全套测试照样绿，而下一个写「先读一次
            // 做诊断、再断言一次」的人会拿到一个凭空变绿的守卫。
            expect(
                watch.observedWrite(),
                "同一个观测器问第二遍，答案必须一样 —— `EV_CLEAR` 会把取走的事件清掉，`observedWrite()`"
                    + "必须自己把它记住。翻供 = 一条「问两遍就变绿」的守卫")
        }
    }

    suite("写观测器③：settings.json 是符号链接（dotfiles）时，穿过它写目标也必须被看见") {
        withTempDirectory { root in
            let targets = FixtureTargets(in: root)
            let settings = targets.onboarding.settingsFile
            // stow / chezmoi 会把 `~/.claude/settings.json` 做成一条指向 dotfiles 仓库的符号链接。
            // 目标住在**另一个目录**里 —— 于是穿过链接的那次写，`dot-claude/` 的目录项**一个都没动**。
            let dotfilesTarget = root.appendingPathComponent("dotfiles/settings.json")
            writeFixture(#"{"hooks":{}}"#, to: dotfilesTarget)
            createSymlink(at: settings, pointingTo: dotfilesTarget)

            let watch = FileWriteWatch(watching: settings)
            expect(watch.isArmed, "test setup: 观测器没能武装起来")
            expect(
                settings.resolvingSymlinksInPath().path
                    == dotfilesTarget.resolvingSymlinksInPath().path,
                "test setup: 链接没解析到目标，这条对照测的就不是「穿链接写」")

            // `SettingsInstaller.atomicWrite` 写的正是这条路径（它先 `resolvingSymlinksInPath()`，
            // 再 `.atomic` 写 —— 那一行有一段专门的注释解释为什么：直接对着链接原子写会把链接本身
            // 替换成正规文件，悄悄脱离 dotfiles 仓库）。这里逐字模拟它。
            try? Data(#"{"hooks":{"Stop":[]}}"#.utf8)
                .write(to: settings.resolvingSymlinksInPath(), options: .atomic)

            expect(
                watch.observedWrite(),
                "一次穿过符号链接写到目标的安装：`dot-claude/` 的目录项一个都没动（目录那一半全程安静），"
                    + "链接自己也纹丝未动 —— 让观测跟得上的是 `stat(2)` 的**跟随**语义（对着链接 stat，"
                    + "拿到的是**目标**的 ino/ctime）。换成 `lstat` 这条就红，而四条持锁 suite 一条都不会红："
                    + "一个把 settings.json 软链进 dotfiles 的用户，从此再没有任何东西守着他的那份配置")
        }
    }

    suite("写观测器②：一次「原地重写、内容与 mtime 都恢复」必须被看见 —— 只有 ctime 看得见它") {
        withTempDirectory { root in
            let targets = FixtureTargets(in: root)
            let settings = targets.onboarding.settingsFile
            writeFixture(#"{"hooks":{}}"#, to: settings)

            let before = fileBytes(settings)
            let watch = FileWriteWatch(watching: settings)
            expect(watch.isArmed, "test setup: 观测器没能武装起来")

            // 目录 watch 的**已知盲区**：非原子的原地重写不动任何目录项。这个 helper 会就地断言
            // 它把 inode / size / 内容 / mtime 全都按回了原样 —— 于是「观测器响了」只可能是 ctime。
            rewriteInPlaceRestoringContentAndModificationTime(settings)

            expect(
                fileBytes(settings) == before,
                "test setup: 内容必须被恢复成逐字相同，否则这条对照钉不到 ctime")
            expect(
                watch.observedWrite(),
                "一个「原地重写、再把内容与 mtime 都按回去」的写者：目录里一个条目都没动（目录那一半"
                    + "全程安静），字节也逐字相同 —— 只有 ctime 出卖了它，而 ctime 是 userspace 唯一"
                    + "伪造不了的字段。看不见 = 身份快照那一半是死的，`atomicWrite` 哪天不再原子，"
                    + "下面四条一条都不会红")
        }
    }

    suite("接管：持住 config.lock → 必须停在 config.json 的写上（.useFailure(.lockBusy)）") {
        withTempDirectory { root in
            let fixture = FixtureBundle(in: root)
            let targets = FixtureTargets(in: root)

            let holder = FileLock(path: targets.configLockFile.path)
            expect(holder.tryLock(), "test setup: holder 必须先拿到**被注入的**那把 config.lock")
            defer { holder.unlock() }

            let settingsBefore = fileBytes(targets.onboarding.settingsFile)
            let settingsWatch = FileWriteWatch(watching: targets.onboarding.settingsFile)
            expect(settingsWatch.isArmed, "test setup: settings.json 的写观测器没能武装起来")

            let result = performOnboardingDiskAction(
                .takeOver,
                environment: targets.environment(bundledHelperBinary: fixture.helperBinary))

            var stoppedAtConfigWrite = false
            if case .failure(.setupFailed(.useFailure(.lockBusy))) = result {
                stoppedAtConfigWrite = true
            }
            expect(
                stoppedAtConfigWrite,
                "接管写 config.json（selectPack）时必须撞上**被注入的那把** config.lock，得到 \(result) —— "
                    + "① 接管**成功**了 = 它守的根本不是这把锁（例如被写死成 play.lock：用户点下接管之后"
                    + "那几秒，他的每一声提示音被去抖锁静默吞掉）；② 停在 `.installFailure` = config 与 "
                    + "settings 两把锁被**成对交换**了（config.json 的写守着 settings.lock）。断的是"
                    + "**哪一步**被挡住，不只是「被挡住了」—— 只断言失败会被成对交换整体满足")

            // ## 副作用：**返回值说不出「做到哪一步」**（`/codex review be332ff` 的 P1-1）
            //
            // 上面那条只读 `result`。把 `Setup.swift` 里 `installClaudioHooks` 那一段**挪到**
            // `selectPack` **之前**（一次重排，两个调用点的 `lockFile:` 实参一个字都不用改）——
            // 持 config.lock 依然会停在 `.useFailure(.lockBusy)`，上面那条**原样绿**。而此刻
            // 用户的 `~/.claude/settings.json` 里已经躺着四条指向 helper 的 hook：一次**失败**的接管，
            // 在他的 Claude Code 里留下了痕迹，而 config.json 里没有任何包被选中 —— 每个事件都会去
            // exec 一个「选不出包」的 helper。
            //
            // `Setup.swift:491` 的注释亲口立过这条不变式（「一次注定不会响的安装，绝不允许在用户的
            // Claude Code 里留下新的痕迹」），而在这条断言之前，**没有任何东西背书它**。
            // 这就是「计数不绑调用点」（`/codex review 840ea37`）在**副作用层**的同一个形状：
            // 错误码不绑执行顺序。
            // ⚠️ 断的是「**有没有被写过**」，不是「此刻的字节还一样吗」（`/codex review ee026db` 的 P2）。
            //
            // `2f107b5` 那一版断的是「里面没有 claudio 的 hook」（`hookCommands(…).allSatisfy { !… }`
            // —— `hookCommands` 在文件不存在 / JSON 坏掉时返回 `[:]`，空数组的 `allSatisfy` **恒真**）。
            // `ee026db` 把它换成了**字节比较**，砍掉了恒真 —— 但没砍掉它紧接着那句自称：失败消息写的是
            // 「**一个字节都没被碰过**」，而字节比较只证明**终态相同**。
            //
            // 一个「写完再回滚」的实现（写 hooks → 撞上 config.lock → 把 settings.json 删回去）能让
            // before 与 after **都是「无文件」**，字节比较全程绿 —— 而那个窗口里，用户的
            // `~/.claude/settings.json` 里真的躺过四条指向 helper 的 hook。Claude Code 每个事件都读这个
            // 文件；进程若在窗口里崩掉，痕迹就永久留下。这条分支叫 `feat/lock-separation`，它整个存在的
            // 前提就是**这个文件有并发的读者与写者**：「窗口期」正是这个威胁模型里唯一算数的东西。
            // 措辞比覆盖范围大，第十一次 —— 而这一次，那句措辞是我自己在上一刀里写下的。
            //
            // 所以「没被碰过」现在由 `FileWriteWatch` **观测**（目录级 kqueue + 伪造不了的 ctime），
            // 而字节比较降级成它本来就是的那个东西：一条**终态**断言，外加一句好读的诊断。
            expect(
                !settingsWatch.observedWrite(),
                "config.json 的写被挡住了，那 settings.json 就必须**一次都没被写过** —— 不是「终态一样」，"
                    + "是**一个字节都没落过盘**。观测器响了 = 写 hooks 跑到了写 config **前面**（错误码一模"
                    + "一样，上面那条照样绿），或者它写完又把文件删/改了回去（**字节比较看不见这一种**）。"
                    + "两种都意味着：一次注定不会响的接管，在用户的 Claude Code 里留下过痕迹，而 config.json"
                    + "里一个包都没选中 —— 那个窗口里每个事件都会去 exec 一个选不出包的 helper。"
                    + "`Setup.swift:491` 亲口立过这条不变式")

            let settingsAfter = fileBytes(targets.onboarding.settingsFile)
            let hooks = hookCommands(in: targets.onboarding.settingsFile).values.flatMap { $0 }
            expect(
                settingsAfter == settingsBefore,
                "settings.json 的**终态**必须与接管前逐字相同（也不许被凭空创建出来）—— "
                    + "前 \(settingsBefore?.count.description ?? "<无文件>") 字节，"
                    + "后 \(settingsAfter?.count.description ?? "<无文件>") 字节，此刻里面的 hook：\(hooks)。"
                    + "上面那条观测器断言严格更强（它连「写了又擦回去」都看得见）；这一条留着，是因为"
                    + "它说得出**变成了什么样**，而观测器只说得出**被动过**")
            expect(
                selectedPack(in: targets.configFile) == nil,
                "config.json 的写正是被挡住的那一步，它不该留下任何选包结果。得到："
                    + "\(String(describing: selectedPack(in: targets.configFile)))，"
                    + "原文：\(readString(targets.configFile) ?? "<无文件>")")
        }
    }

    suite("接管：持住 settings.lock → config 那步必须放行，停在 hooks 的写上（.installFailure(.lockBusy)）") {
        withTempDirectory { root in
            let fixture = FixtureBundle(in: root)
            let targets = FixtureTargets(in: root)

            let holder = FileLock(path: targets.settingsLockFile.path)
            expect(holder.tryLock(), "test setup: holder 必须先拿到**被注入的**那把 settings.lock")
            defer { holder.unlock() }

            let settingsBefore = fileBytes(targets.onboarding.settingsFile)
            let settingsWatch = FileWriteWatch(watching: targets.onboarding.settingsFile)
            expect(settingsWatch.isArmed, "test setup: settings.json 的写观测器没能武装起来")

            let result = performOnboardingDiskAction(
                .takeOver,
                environment: targets.environment(bundledHelperBinary: fixture.helperBinary))

            var stoppedAtHooksWrite = false
            if case .failure(.setupFailed(.installFailure(.lockBusy))) = result {
                stoppedAtHooksWrite = true
            }
            expect(
                stoppedAtHooksWrite,
                "接管写 settings.json（installClaudioHooks）时必须撞上**被注入的那把** settings.lock，"
                    + "得到 \(result) —— ① 接管**成功**了 = settings.json 的写守的根本不是这把锁；"
                    + "② 停在 `.useFailure` = 两把锁被**成对交换**了（config.json 的写反而守着 "
                    + "settings.lock，于是被这个 holder 挡在了更早的那一步）。这一条与上面那条**成对**"
                    + "存在：单独任何一条都能被成对交换骗过，两条一起才把「谁守谁」钉死")

            // ## 「config 那步必须放行」—— 本 suite 标题的后半句，此前**一条断言都没有**
            // （`/codex review be332ff` 的 P1-1）
            //
            // 标题写着「config 那步必须放行，停在 hooks 的写上」，而上面那条只看得见后半句：它读的是
            // 错误码，而错误码说不出 config 那步**到底跑没跑**。把 `installClaudioHooks` 重排到
            // `selectPack` 之前 —— 持 settings.lock 依然停在 `.installFailure(.lockBusy)`，上面那条
            // **原样绿** —— 而 config.json 从头到尾没被写过：接管在**第一步**就死了，一个包都没选。
            // 措辞（「放行」）比覆盖范围（「错误码对」）大，第九次。这条把前半句也钉上。
            // 断的是**解析出来的 `selected_pack`**，不是 `contains("minimal-chime")`
            // （`/codex review 2f107b5` 的 P2）：后者在 `{"note":"minimal-chime"}`、在半截写坏的
            // JSON 上都为真 —— 它说不出「选包那一步真的跑完了」，而那正是这条失败消息声称的东西。
            expect(
                selectedPack(in: targets.configFile) == "minimal-chime",
                "settings.lock 与 config.json 的写毫无关系，config 那步必须**真的跑完** —— "
                    + "config.json 里得躺着**解析得出来的**那个包。得到："
                    + "\(String(describing: selectedPack(in: targets.configFile)))，"
                    + "原文：\(readString(targets.configFile) ?? "<无文件>")"
                    + " —— nil / 不是这个包 = 写 hooks 跑到了写 config 前面（错误码一模一样，上面那条"
                    + "照样绿），接管在第一步就被挡死了")

            // 同上一条 suite：断的是「**有没有被写过**」。这一条比那一条更要命 —— settings.json 的写
            // **正是**被挡住的那一步，所以「它有没有在被挡住之前先落一次盘」是这条 suite 的全部内容。
            // 一次 `.lockBusy` 之前就已经写下去的字节，字节比较在「写完又回滚」时**看不见**。
            expect(
                !settingsWatch.observedWrite(),
                "settings.json 的写正是被挡住的那一步 —— 它必须**一次都没被写过**。观测器响了 = 它在"
                    + "拿到锁之前（或者在报 lockBusy 之后回滚之前）已经往用户的 Claude Code 里落过字节。"
                    + "`installClaudioHooks` 的读-改-写整段都在 `withNonBlockingLock` 里面，这条断言就是"
                    + "那句话的磁盘证据")

            let settingsAfter = fileBytes(targets.onboarding.settingsFile)
            let hooks = hookCommands(in: targets.onboarding.settingsFile).values.flatMap { $0 }
            expect(
                settingsAfter == settingsBefore,
                "settings.json 的**终态**必须与接管前逐字相同（也不许被凭空创建出来）。"
                    + "前 \(settingsBefore?.count.description ?? "<无文件>") 字节，"
                    + "后 \(settingsAfter?.count.description ?? "<无文件>") 字节，此刻的 hook：\(hooks)")
        }
    }

    suite("断开：持住 settings.lock → 必须撞上它（.disconnectFailed(.lockBusy)）") {
        withTempDirectory { root in
            let fixture = FixtureBundle(in: root)
            let targets = FixtureTargets(in: root)
            let environment = targets.environment(bundledHelperBinary: fixture.helperBinary)

            // 先真的接管一次（此刻两把锁都空着），断开才有东西可摘。
            _ = performOnboardingDiskAction(.takeOver, environment: environment)
            expect(
                detectOnboardingState(environment: targets.onboarding) == .installed,
                "setup: 接管之后必须是 .installed，否则下面断开的是空气")

            let holder = FileLock(path: targets.settingsLockFile.path)
            expect(holder.tryLock(), "test setup: holder 必须先拿到**被注入的**那把 settings.lock")
            defer { holder.unlock() }

            let settingsWatch = FileWriteWatch(watching: targets.onboarding.settingsFile)
            expect(settingsWatch.isArmed, "test setup: settings.json 的写观测器没能武装起来")

            let result = performOnboardingDiskAction(.disconnect, environment: environment)

            var blockedBySettingsLock = false
            if case .failure(.disconnectFailed(.lockBusy)) = result { blockedBySettingsLock = true }
            expect(
                blockedBySettingsLock,
                "断开摘 hooks（uninstallClaudioHooks，`OnboardingActions.swift:607`）写的是 settings.json，"
                    + "必须撞上**被注入的那把** settings.lock，得到 \(result) —— 断开**成功**了，就说明"
                    + "这一处转发的是别的锁。它是接管路径之外**第二个** settings.json 的写者，此前同样"
                    + "一条断言都没有")

            // 副作用（`/codex review be332ff` 的 P1-1 同一类）：「它报了 lockBusy」说不出「它有没有先摘
            // 掉几条再报」。一次**被锁挡住**的断开必须是**原子**的 —— 四条 hook 一条不少地留在原地。
            // 摘一半再报错 = 用户的 Claude Code 里剩下几条半死的 hook，而面板告诉他「断开失败了」，
            // 他会以为什么都没发生。
            //
            // ⚠️ 而「四条还在」说不出「它一次都没写过」（`/codex review ee026db` 的 P2）：一个先摘完、
            // 撞上锁、再把原文写回去的实现，四条一条不少，字节也逐字相同 —— 而窗口期里读到那份
            // settings.json 的 Claude Code，看见的是一个**没有任何 claudio hook** 的配置。断开是这条
            // 路径上 settings.json 的**第二个**写者，它和接管适用同一条不变式。
            expect(
                !settingsWatch.observedWrite(),
                "被锁挡住的断开必须是**原子**的：settings.json 一次都不许被写过。观测器响了 = 它先动了手"
                    + "（摘了几条 / 整份重写）才报的错 —— 哪怕它事后把字节都擦回去，那个窗口里 Claude Code "
                    + "读到的就是一份少了 hook 的配置，而面板对用户说「断开失败，你的配置一个字都没动」")

            let survivors = hookCommands(in: targets.onboarding.settingsFile).values.flatMap { $0 }
                .filter { $0.contains(targets.onboarding.claudioBinaryPath.path) }
            expect(
                survivors.count == Event.allCases.count,
                "断开被锁挡住 = 一条都不许摘（四条 hook 原样在位），实得 \(survivors.count) 条："
                    + "\(survivors) —— 少了 = 它先动了手再报的错，用户看见「断开失败」，而他的 "
                    + "settings.json 里躺着几条被摘剩的 hook")
        }
    }

    suite("断开：持住 config.lock → 必须照常成功（它一个字节都不写 config.json）") {
        withTempDirectory { root in
            let fixture = FixtureBundle(in: root)
            let targets = FixtureTargets(in: root)
            let environment = targets.environment(bundledHelperBinary: fixture.helperBinary)

            _ = performOnboardingDiskAction(.takeOver, environment: environment)
            expect(
                detectOnboardingState(environment: targets.onboarding) == .installed,
                "setup: 接管之后必须是 .installed，否则下面断开的是空气")

            let holder = FileLock(path: targets.configLockFile.path)
            expect(holder.tryLock(), "test setup: holder 必须先拿到**被注入的**那把 config.lock")
            defer { holder.unlock() }

            // 本 suite 标题的**括号里那半句**（「它一个字节都不写 config.json」），此前一条断言都没有。
            //
            // 下面那两条断的是「摘干净了四条」——它们只说得出**断开做到了什么**，说不出**断开没做什么**。
            // 一个「顺手把 selected_pack 也清掉」的断开实现：若它**不**去拿 config.lock（这条分支拆开这
            // 几把锁，图的正是它们互不相干，于是「反正不冲突」听起来天经地义），那么持着 config.lock 的
            // 这个 holder 挡不住它，下面两条**照样全绿** —— 而用户按下「断开」之后，他挑了半年的那个包
            // 没了。config.json 的并发写者是静音开关与切包，一个不持锁的第三写者就是数据丢失。
            //
            // ⚠️ 这里观测的是 `.claudio/`（config.json 的父目录），而**接管**那两条 suite 里不能这么做：
            // 接管期间二进制、声音包、两把锁文件都在往 `.claudio/` 里落，目录那一半会假阳。断开跑在接管
            // **之后**，此刻 `.claudio/` 全程安静（`tryLock` 打开的是接管早已建好的那个 config.lock，
            // 不新增目录项），观测才成立。见 `TestSupport.swift` 里「它不兜什么」那一节。
            let configWatch = FileWriteWatch(watching: targets.configFile)
            expect(configWatch.isArmed, "test setup: config.json 的写观测器没能武装起来")

            let result = performOnboardingDiskAction(.disconnect, environment: environment)

            // 这是一条**正向**断言，而且它是上面那条的镜像：上面那条防「断开没拿 settings.lock」，
            // 这一条防「断开**多拿**了一把它根本不该碰的锁」。少了它，把 `:607` 写成
            // `lockFile: environment.configLockFile` 只会让上面那条变红一次——而红的原因会被读成
            // 「settings 锁没接上」，真正的病（断开跑去占 config 的锁，于是一次断开能把并发的
            // 静音 / 切包写全部挡掉）没人说得出来。
            // 断的是 `count`，不只是 `.success`：`uninstallClaudioHooks` 摘了 0 条也返回
            // `.success(.notInstalled)`（文件头规则 2 记着这次翻车）。一条只看 `.success` 的断言，
            // 会在「它其实什么都没摘」的情况下变绿 —— 而那正是这条要防的另一半。
            var sweptCount: Int?
            if case .success(.disconnected(let count)) = result { sweptCount = count }
            expect(
                sweptCount == Event.allCases.count,
                "断开只写 settings.json，config.lock 被别人持着与它毫无关系，必须照常**摘干净四条**，"
                    + "得到 \(result) —— ① 它**因为 config.lock 被持有而失败**，就说明这条路径拿了一把"
                    + "它根本不该拿的锁：那样一次断开会连带挡住并发的静音开关与切包（两者都写 config.json），"
                    + "而阶段 A 拆开这几把锁，图的正是它们互不相干；② 它成功了但只摘掉 "
                    + "\(String(describing: sweptCount)) 条 = 它「成功」得毫无内容")

            // 标题括号里那半句的磁盘证据：断开**一个字节都不写 config.json**。
            expect(
                !configWatch.observedWrite(),
                "断开只摘 settings.json 里的 hook —— 它一个字节都不许写 config.json。观测器响了 = 断开"
                    + "偷偷动了用户的选包（而它没拿 config.lock：持着这把锁的这个 holder 一点都没挡住它）。"
                    + "config.json 的另外两个写者是静音开关与切包 —— 一个不持锁的第三写者，就是数据丢失。"
                    + "下面那两条只断「摘干净了四条」，它们说得出断开**做到了什么**，说不出它**没做什么**")

            // 副作用：磁盘上真的干净了。`count` 是执行器**自报**的数字，这一条去问 settings.json 本人。
            let leftovers = hookCommands(in: targets.onboarding.settingsFile).values.flatMap { $0 }
                .filter { $0.contains(targets.onboarding.claudioBinaryPath.path) }
            expect(
                leftovers.isEmpty,
                "断开成功了，settings.json 里就不该再有任何指向 claudio 的命令。得到：\(leftovers)")
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
    // 用户点「修复」→ setup 在写 config / hooks 那一步撞上 config.lock / settings.lock → 失败 → refresh 探测到
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
            .reported(notices: [.salvagedPack(packID: "p", movedTo: "/tmp/p")]),
            .reported(notices: [.repairedDeadSelection(removed: "a", selected: "b")]),
            .reported(notices: [
                .salvagedPack(packID: "p", movedTo: "/tmp/p"),
                .repairedDeadSelection(removed: "a", selected: "b"),
            ]),
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
                case .idle, .running, .reported:
                    expect(visible == nil, "\(state) × \(actionState)：没失败就不该画失败行")
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // T17f：告知的孪生不变式。与上面那条**逐字同构**——因为它防的是同一个 bug 在成功路径上的重演。
    // ═══════════════════════════════════════════════════════════════════════════════
    suite("不变式：state × actionState 全组合下，任何一条告知都必须有视图画它（T17f）") {
        let allStates: [OnboardingState] = [
            .claudeCodeNotInstalled, .helperMissing, .notInstalled, .installed,
            .settingsNotWritable(reason: "r"), .settingsParseFailure(reason: "r"),
        ]
        let allActionStates: [OnboardingActionState] = [
            .idle,
            .running(.takeOver),
            .running(.disconnect),
            .failed(action: .takeOver, message: "接管失败了", detail: "d"),
            .reported(notices: [.salvagedPack(packID: "p", movedTo: "/tmp/p")]),
            .reported(notices: [.repairedDeadSelection(removed: "a", selected: "b")]),
            .reported(notices: [
                .salvagedPack(packID: "p", movedTo: "/tmp/p"),
                .repairedDeadSelection(removed: "a", selected: "b"),
            ]),
        ]

        for state in allStates {
            for actionState in allActionStates {
                let visible = onboardingVisibleNotices(actionState: actionState)
                switch actionState {
                case .reported(let notices):
                    expect(
                        visible == notices,
                        "\(state) × \(actionState)：一条告知没有任何视图画它。用户的包被换掉了 /"
                            + "他的目录被搬走了，而面板一声不吭 —— 这正是 T17e 立下「必须让他知道」"
                            + "之后，GUI 侧仍然违约的那个形状")
                case .idle, .running, .failed:
                    expect(visible.isEmpty, "\(state) × \(actionState)：没告知就不该画提示行")
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
            .operational(events: [], packCardIDs: [], hasDetailToggle: true, hasMasterVolume: true))
        // hasMasterVolume: true —— 这条测试关心的是 revealDetail/disconnect 的相对顺序，跟主音量
        // 无关，显式给 true 只是让这个 fixture 继续代表「滑块真的渲染在屏幕上」那一半（`/codex
        // review` P1 修复后，.masterVolume 不再是 .operational scope 里的恒定行为，见
        // PanelFocusOrderSuite 对 hasMasterVolume: false 那一半的测试）。排在 .dropZone 之前
        // ——PLAN-MASTER-VOLUME.md D41；零事件行只是 fixture，生产恒 4 行。
        expect(
            operational == [.masterVolume, .dropZone, .revealDetail, .disconnect],
            "运行态：失败行在「断开连接」之上。得到 \(operational)")

        let withoutToggle = panelFocusOrder(
            .operational(events: [], packCardIDs: [], hasDetailToggle: false, hasMasterVolume: true))
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

// ═══════════════════════════════════════════════════════════════════════════════════════
// T17f —— 「我替你做主」的告知：政策的真值表
//
// `setupNotices(for:)` 是政策，`onboardingActionState(afterSuccess:)` 是它唯一的出口。两者都是
// 纯函数，所以这里能像 `packSelectionPlan` 的真值表那样，一张表逐格钉死——而不是靠「跑一遍看看」。
// ═══════════════════════════════════════════════════════════════════════════════════════
@MainActor
func runSetupNoticeSuites() {
    /// 一个「一切正常」的 setup 结果——每条用例只改它的一两格，于是每条断言在测的到底是哪一格，
    /// 一眼可见。
    func outcome(
        salvaged: [SalvagedPack] = [],
        packSelection: PackSelectionOutcome = .untouched
    ) -> OnboardingActionOutcome {
        .tookOver(
            .completed(
                copiedBinary: true, copiedPacks: [], salvaged: salvaged,
                packSelection: packSelection, hooksOutcome: .installed))
    }

    // ── 真值表 ────────────────────────────────────────────────────────────────────────
    // 这四条把「哪些事算『我替你做主』」逐格钉死。前两条**必须**是空的：它们是这张表最容易被
    // 后人「顺手也报一下」而写坏的两格，而报了它们，真正要紧的两条就会淹在噪音里。
    suite("告知真值表 ①：选择好好的（.untouched）→ 无话可说") {
        expect(setupNotices(for: outcome()).isEmpty, "一个字节都没动，凭什么打扰用户")
        expect(
            onboardingActionState(afterSuccess: outcome()) == .idle,
            "无话可说 → .idle，绝不是一个长着零行的 .reported（那会是第二个『空提示区』视觉态）")
    }

    suite("告知真值表 ②：首次自举挑了默认包（.selectedDefault）→ 无话可说") {
        let o = outcome(packSelection: .selectedDefault(packID: "minimal-chime"))
        expect(
            setupNotices(for: o).isEmpty,
            "他按下「接管」时本来就在请求这件事——这不是『我替你做主』，是『我照你说的做了』")
        expect(onboardingActionState(afterSuccess: o) == .idle, "同上 → .idle")
    }

    suite("告知真值表 ③：他选的包没了、已替他换掉（.repairedDeadSelection）→ 必须说") {
        let o = outcome(packSelection: .repairedDeadSelection(removed: "pikachu", selected: "minimal-chime"))
        expect(
            setupNotices(for: o) == [.repairedDeadSelection(removed: "pikachu", selected: "minimal-chime")],
            "T17e 白纸黑字：『替他换上，并如实说出来』。CLI 说了，GUI 也必须说")
        expect(
            onboardingActionState(afterSuccess: o)
                == .reported(notices: [.repairedDeadSelection(removed: "pikachu", selected: "minimal-chime")]),
            "有话要说 → .reported")
    }

    suite("告知真值表 ④：读不出的包被原样搬走（.salvaged）→ 必须说，且必须带上路径") {
        let o = outcome(salvaged: [SalvagedPack(packID: "wobbuffet", movedTo: "/tmp/wobbuffet-aside")])
        expect(
            setupNotices(for: o) == [.salvagedPack(packID: "wobbuffet", movedTo: "/tmp/wobbuffet-aside")],
            "搬走一个用户目录是这次 setup 里代价最大的一个『我替你做主』")
        // 路径不是装饰：那个目录里可能装着他自己导入的、磁盘上唯一一份音频。不给路径 = 不给回头路。
        expect(
            setupNotices(for: o)[0].message.contains("/tmp/wobbuffet-aside"),
            "文案里必须有那条能把东西找回来的绝对路径")
        expect(
            setupNotices(for: o)[0].message.contains("一个文件都没删"),
            "用户此刻最想知道的不是我们发现了什么，而是他的东西还在不在")
    }

    suite("告知真值表 ⑤：搬走 + 换包同时发生 → 两条都说，顺序与 CLI 一字不差（先搬走，后换包）") {
        let o = outcome(
            salvaged: [SalvagedPack(packID: "wobbuffet", movedTo: "/tmp/w")],
            packSelection: .repairedDeadSelection(removed: "wobbuffet", selected: "minimal-chime"))
        expect(
            setupNotices(for: o) == [
                .salvagedPack(packID: "wobbuffet", movedTo: "/tmp/w"),
                .repairedDeadSelection(removed: "wobbuffet", selected: "minimal-chime"),
            ],
            "用户在面板上读到的顺序，必须与他 `claudio setup` 时读到的顺序相同")
    }

    suite("告知真值表 ⑥：多个包被搬走 → 一条都不许吞") {
        let o = outcome(salvaged: [
            SalvagedPack(packID: "a", movedTo: "/tmp/a"),
            SalvagedPack(packID: "b", movedTo: "/tmp/b"),
        ])
        expect(
            setupNotices(for: o) == [
                .salvagedPack(packID: "a", movedTo: "/tmp/a"),
                .salvagedPack(packID: "b", movedTo: "/tmp/b"),
            ],
            "两个目录被搬走就报两条——「只报第一条」是另一种形式的静默")
    }

    // ── 结构不变式 ────────────────────────────────────────────────────────────────────
    suite("不变式：断开（.disconnected）结构上产不出任何告知 —— 这是 .reported 不带 action 标签的依据") {
        for count in [0, 1, 4] {
            expect(
                setupNotices(for: .disconnected(count: count)).isEmpty,
                "摘 hooks 不碰包、不碰选包。若这条哪天不成立了，.reported 就必须重新长回 action 标签")
            expect(
                onboardingActionState(afterSuccess: .disconnected(count: count)) == .idle,
                "断开成功 → .idle")
        }
    }

    suite("不变式：.reported 的 notices 恒非空（空告知就是 .idle，不是一个长着零行的提示区）") {
        // `onboardingActionState(afterSuccess:)` 是 `.reported` 的唯一构造入口。穷举所有
        // 「无话可说」的输入，断言没有一个能造出 `.reported`。
        let silentOutcomes: [OnboardingActionOutcome] = [
            outcome(),
            outcome(packSelection: .selectedDefault(packID: "x")),
            .disconnected(count: 4),
        ]
        for o in silentOutcomes {
            if case .reported(let notices) = onboardingActionState(afterSuccess: o) {
                expect(false, "构造出了一个空告知的 .reported：\(notices) —— 这个视觉态没有人渲染过")
            }
        }
    }

    // ── 文案的**语义**：哪个包落在哪个角色上 ──────────────────────────────────────────
    //
    // ## 这组断言补的是我自己挖的一个坑（T17f 自评审 · 变异实测）
    //
    // 上面那些真值表断的是**枚举载荷**（`setupNotices(for:) == [.repairedDeadSelection(removed:…,
    // selected:…)]`），禁词表断的是**没有工程语**。两者都对，两者加起来仍然**漏掉了最要命的那一维**：
    // 那句话到底把哪个包说成「没了」、把哪个包说成「换上了」。
    //
    // 实测：把 `SetupNotice.message` 里的 `\(removed)` 与 `\(selected)` **对调**——于是面板会对用户说
    // 「你之前选的『minimal-chime』已经不在了，已替你换成『pikachu』」，而真相**恰好相反**——
    // **935 条断言全绿，一条都没响。**
    //
    // 而这个变异比「不显示告知」**更坏**：一条沉默的告知只是没帮上忙；一条**说反了的**告知会主动
    // 把用户推向错误的行动——他会去找一个其实好好的包，同时对一个真的没了的包放下心来。这个产品的
    // 立身之本是不撒谎，而这里是它唯一一次开口说话的地方。
    //
    // 所以角色绑定必须被逐字钉死。**这组断言是刻意「脆」的**：任何人改写这句文案都会让它变红，
    // 然后他必须回来重新声明「哪个包是没了的那个」——对一条正确性即全部意义的话来说，这不是负担，
    // 这就是它该有的样子。
    suite("告知文案的语义：说反了比不说更坏 —— 哪个包「没了」、哪个包「换上了」，逐字钉死") {
        let notice = SetupNotice.repairedDeadSelection(removed: "pikachu", selected: "minimal-chime")
        let message = notice.message

        // ① 角色绑定：消失的是 pikachu，顶上的是 minimal-chime。对调 → 这两条当场红。
        expect(
            message.contains("「pikachu」已经不在了"),
            "消失的那个包（removed = pikachu）必须被说成『没了』。实得：\(message)")
        expect(
            message.contains("换成了「minimal-chime」"),
            "顶上来的那个包（selected = minimal-chime）必须被说成『换上的』。实得：\(message)")

        // ② 顺序：先说没了的，再说换上的。这条对改写更宽容，但对**对调**同样致命 —— 双保险。
        guard let removedAt = message.range(of: "pikachu")?.lowerBound,
            let selectedAt = message.range(of: "minimal-chime")?.lowerBound
        else {
            expect(false, "两个包名必须都出现在文案里。实得：\(message)")
            return
        }
        expect(
            removedAt < selectedAt,
            "叙事顺序必须是「你的没了 → 我换了这个」。反过来讲，用户读到的就是一句反话。实得：\(message)")

        // ③ 可逆性必须说出口：这是一次未经请求的替换，用户有权知道他能换回去，
        //    而那个入口（声音包画廊）此刻就在这条提示的上方。
        expect(
            message.contains("换成别的"),
            "必须告诉用户这事是可逆的 —— 否则一次『我替你做主』就成了既成事实。实得：\(message)")
    }

    suite("告知文案的语义：搬走的包 —— 包名与去处不许错位") {
        let notice = SetupNotice.salvagedPack(
            packID: "wobbuffet", movedTo: "/Users/demo/.claudio/packs/wobbuffet-aside")
        let message = notice.message

        expect(
            message.contains("「wobbuffet」"),
            "必须点名是哪个包被搬走了。实得：\(message)")
        expect(
            message.contains("/Users/demo/.claudio/packs/wobbuffet-aside"),
            "必须给出那条能把东西找回来的绝对路径 —— 不给路径 = 不给回头路。实得：\(message)")
        // 包名不能被塞进「去处」那个位置（反之亦然）：路径在「搬到了」之后。
        guard let packAt = message.range(of: "「wobbuffet」")?.lowerBound,
            let pathAt = message.range(of: "/Users/demo")?.lowerBound
        else {
            expect(false, "包名与路径必须都在文案里。实得：\(message)")
            return
        }
        expect(packAt < pathAt, "叙事顺序：先说哪个包，再说搬到哪儿。实得：\(message)")
    }

    // ── 文案里不许有 Markdown（T17f 自评审 · 实测）──────────────────────────────────────
    //
    // `ActionNoticeRow` 走 `Text(message)`，而 `message` 是一个 `String` **变量** → Swift 选中
    // `Text.init<S: StringProtocol>(_:)` 这个**逐字**重载；会解析 Markdown 的 `LocalizedStringKey`
    // 重载**只有字符串字面量够得着**。所以文案里的 `**粗体**` 会被**原样印在屏幕上**，VoiceOver
    // 还会念出来。第一版的 salvage 文案真的带着 `**原样**` —— 在这个产品唯一一次开口说
    // 「我动了你的东西」的地方，屏幕上会印着四个星号。
    suite("告知文案里不许出现 Markdown 标记 —— Text(String) 是逐字渲染，星号会原样印给用户") {
        let allNotices: [SetupNotice] = [
            .salvagedPack(packID: "wobbuffet", movedTo: "/Users/demo/.claudio/packs/w-aside"),
            .repairedDeadSelection(removed: "pikachu", selected: "minimal-chime"),
        ]
        // 只扫会被 Markdown **解析掉**、从而在逐字渲染下暴露成噪音的那几个标记。
        // 中文全角标点（「」（））不在其列 —— 它们本来就是要原样显示的。
        let markdownMarkers = ["**", "__", "`", "*_", "](", "~~"]
        for notice in allNotices {
            for marker in markdownMarkers {
                expect(
                    !notice.message.contains(marker),
                    "告知文案里出现了 Markdown 标记「\(marker)」。`Text(String)` 不解析它 —— "
                        + "用户会原样读到那几个字符，VoiceOver 还会念出来。实得：\(notice.message)")
            }
        }
    }

    // ── 「下面的声音包」是一句关于布局的断言 ──────────────────────────────────────────
    //
    // 文案里那句指路必须与 `operationalPanel` 的真实排布一致。这条只钉得住**文案这一半**
    // （「它确实说了『下面的声音包』」）；另一半（「提示行真的排在画廊之前」）由
    // `ViewWiringSuite` 的顺序断言守着 —— 两条合起来才是完整的那句话。
    suite("换包告知必须把用户指向声音包画廊（而不是含糊其辞，也不是指向别处）") {
        let message = SetupNotice.repairedDeadSelection(removed: "a", selected: "b").message
        expect(
            message.contains("下面的声音包"),
            "必须明确指路 —— 一个刚被替换了选包的用户，最需要知道的就是去哪儿换回来。实得：\(message)")
        expect(
            !message.contains("断开"),
            "绝不能把他指向「断开连接」—— 那是卸载键，不是换包入口")
    }

    // ── 文案纪律（T7 禁词表，与 onboardingCopy 同一把尺）────────────────────────────────
    suite("告知文案必须过 T7 禁词表 —— 用户面前不出现「settings.json」「hook」这类工程语") {
        let forbidden = ["settings.json", "hook", "claudio install", "claudio play"]
        let allNotices: [SetupNotice] = [
            .salvagedPack(packID: "wobbuffet", movedTo: "/Users/demo/.claudio/packs/w-aside"),
            .repairedDeadSelection(removed: "pikachu", selected: "minimal-chime"),
        ]
        for notice in allNotices {
            let lowered = notice.message.lowercased()
            for word in forbidden {
                expect(
                    !lowered.contains(word.lowercased()),
                    "告知文案里出现了工程语「\(word)」：\(notice.message)")
            }
            expect(!notice.message.isEmpty, "一条空文案的告知等于没有告知")
        }
    }
}
