import ClaudioGUICore
import CryptoKit
import Foundation

// MARK: - app bundle 布局契约：GUI 是消费者，release.yml 是生产者（T17）
//
// ``bundledHelperBinary(in:)`` 去 `Contents/Resources/bin/claudi0` 找 helper，
// `performFirstRunSetup` 再从那条路径反推 `Contents/Resources/packs`。这条布局契约的**另一端**
// 在 `.github/workflows/release.yml` 的 "Assemble claudi0.app" 步骤里 —— 两边之间没有任何编译期
// 联系。
//
// 把 release.yml 里的目标目录改个名（`Resources/bin/` → `Resources/helper/`），会发生什么：
// 所有 Swift 测试**照样全绿**、CI **照样全绿**、DMG **照常签发** —— 然后 CTA 在**每一台用户机器上**
// 报 `.helperUnavailable`。这正是「装了但听不到声音」那一族失败，而 T17 存在的全部意义就是消灭它。
//
// 一个跨 yml 与二进制的生产者/消费者契约，只有一种回归网可能存在：**真的去读那个 yml**。
// harness 是一个可执行程序，它读得了文件。

/// 仓库根 —— 从 `#filePath` 推出来（编译期常量，确定性；不依赖 cwd，因为 harness 的工作目录
/// 取决于是谁在什么地方 `swift run` 的）。
/// `gui/Tests/ClaudioGUICoreTests/ReleaseLayoutSuite.swift` → 上溯三级。
private func repositoryRoot(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent()  // ClaudioGUICoreTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // gui/
        .deletingLastPathComponent()  // <repo root>
}

private struct ReleaseSizeProcessResult {
    let status: Int32
    let output: String
}

private func runReleaseSizeGate(
    app: URL,
    fakeLipo: URL,
    overrides: [String: String] = [:]
) -> ReleaseSizeProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
        repositoryRoot().appendingPathComponent("scripts/check-release-size.sh").path,
        app.path,
    ]
    var environment = ProcessInfo.processInfo.environment
    environment.merge([
        "CLAUDIO_GUI_BYTES_PER_ARCH": "100",
        "CLAUDIO_HELPER_BYTES_PER_ARCH": "80",
        "CLAUDIO_NON_EXECUTABLE_BUNDLE_BYTES": "1000",
        "CLAUDIO_LIPO_BIN": fakeLipo.path,
        "FAKE_GUI_ARCHS": "arm64 x86_64",
        "FAKE_HELPER_ARCHS": "arm64 x86_64",
        "FAKE_GUI_ARM64_BYTES": "100",
        "FAKE_GUI_X86_64_BYTES": "100",
        "FAKE_HELPER_ARM64_BYTES": "80",
        "FAKE_HELPER_X86_64_BYTES": "80",
    ]) { _, new in new }
    environment.merge(overrides) { _, new in new }
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return ReleaseSizeProcessResult(status: -1, output: error.localizedDescription)
    }
    let output =
        String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return ReleaseSizeProcessResult(status: process.terminationStatus, output: output)
}

@MainActor
func runReleaseLayoutSuites() {
    suite("release.yml 真的把 helper 放在 GUI 会去找的那个位置") {
        let workflow = repositoryRoot()
            .appendingPathComponent(".github/workflows/release.yml")
        let packCopyScriptURL = repositoryRoot()
            .appendingPathComponent("scripts/copy-bundled-packs.sh")
        guard let data = try? Data(contentsOf: workflow),
            let yaml = String(data: data, encoding: .utf8),
            let packCopyScript = try? String(contentsOf: packCopyScriptURL, encoding: .utf8)
        else {
            expect(
                false,
                "读不到 \(workflow.path) —— 这个 suite 唯一的价值就是读它，读不到就等于没测。"
                    + "（`#filePath` 推仓库根失败了？）")
            return
        }

        // **只看真正的 `cp` 命令行，不看散文。**
        //
        // 第一版这条断言是 `yaml.contains("Contents/Resources/bin/claudi0")` —— 而 release.yml 的
        // Release notes 与 cask caveats 里**也**印着这条路径。把真正的 `cp` 目标改成
        // `Resources/helper/`（也就是这条 suite 存在的全部理由那次变异），那两处散文照样让 grep 命中，
        // **652 全绿**。一条不可能失败的测试比没有测试更坏：它宣称自己在守着一件事。
        let copyLines = yaml.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("cp ") || $0.hasPrefix("cp -") }

        expect(!copyLines.isEmpty, "release.yml 里一条 `cp` 都没有？「Assemble claudi0.app」那步没了？")

        let helperDestination =
            "Contents/Resources/\(bundledHelperSubdirectory)/\(claudioHelperBinaryName)"
        expect(
            copyLines.contains { $0.contains(helperDestination) },
            "release.yml 里没有任何一条 `cp` 把 helper 复制到 \"\(helperDestination)\"。"
                + "GUI 会去那里找它（`bundledHelperBinary(in:)`），生产者却把它放到了别处 —— "
                + "所有测试会绿、CI 会绿、DMG 会照常签发，然后 CTA 在每一台用户机器上报「找不到小助手」。"
                + "实际的 cp 行：\(copyLines)")

        // `performFirstRunSetup` 从 helper 路径去掉两级、拼 `packs` 反推内置包目录。发布流程通过
        // 独立脚本遍历所有 pack，而不是把当前唯一的 minimal-chime 写死在 workflow 里。
        expect(
            yaml.contains(
                #"bash scripts/copy-bundled-packs.sh packs "$APP/Contents/Resources/packs""#),
            "release.yml 必须把所有内置包交给 fail-closed 遍历脚本复制到 Contents/Resources/packs")
        expect(
            packCopyScript.contains(#"entries=("$SOURCE_ROOT"/*)"#)
                && packCopyScript.contains(#"cp -R "$entry" "$DESTINATION_ROOT/$entry_name""#)
                && packCopyScript.contains(
                    #"cp "$SOURCE_ROOT/LICENSES.md" "$DESTINATION_ROOT/LICENSES.md""#),
            "内置包脚本必须遍历全部顶层 pack，并把音频许可台账一起装入 app bundle")
        expect(
            yaml.contains("swift build -c release --arch arm64 --product claudio")
                && yaml.contains("swift build -c release --arch x86_64 --product claudio"),
            "helper Release 构建必须显式选择 claudio product，不能顺带编译测试 executable")

        // GUI 自己的可执行文件在 Contents/MacOS/ —— 钉住「两者确实是两个不同的文件」，也就是 T17
        // 那个 bug 的前提。
        expect(
            copyLines.contains { $0.contains("Contents/MacOS/") },
            "release.yml 里没有任何一条 `cp` 往 Contents/MacOS/ 放 GUI 可执行文件 —— GUI 与 helper 必须"
                + "是两个不同的文件。实际的 cp 行：\(copyLines)")

        expect(
            copyLines.contains { $0.contains("Contents/Resources/claudi0.icns") },
            "release.yml 必须把 Orbit Zero 的 claudi0.icns 放进 app Resources。实际的 cp 行：\(copyLines)")
        expect(
            yaml.contains("<key>CFBundleIconFile</key><string>claudi0.icns</string>"),
            "Info.plist 必须通过 CFBundleIconFile 指向 claudi0.icns")
        expect(
            yaml.contains("APP_NAME: claudi0"),
            "发布 app、DMG 与 Finder 显示名必须统一使用 claudi0")
        expect(
            yaml.contains("APP_EXECUTABLE: claudi0-app"),
            "GUI bundle 可执行文件必须使用 claudi0-app，与内置 claudi0 helper 明确分开")
        expect(
            yaml.contains("<key>CFBundleExecutable</key><string>$APP_EXECUTABLE</string>"),
            "Info.plist 必须把 CFBundleExecutable 绑定到 APP_EXECUTABLE")
        expect(
            yaml.contains("strip -x dist/bin/claudio")
                && yaml.contains("strip -x dist/app-bin/ClaudioGUI"),
            "release workflow 必须在组装 app 前移除两个 Release Mach-O 的非导出符号")
        expect(
            yaml.contains(#"ln -s claudi0 "$APP/Contents/Resources/bin/claudio""#),
            "legacy claudio bundle 入口必须链接到 claudi0，不能复制第二份 helper Mach-O")
        expect(
            yaml.contains("bash scripts/check-release-size.sh"),
            "release workflow 必须在签名前执行可执行负载体积门禁")
    }

    suite("HostIcons：SwiftPM、开发 bundle 与双架构 release 都 fail closed 复制同一资源 bundle") {
        let root = repositoryRoot()
        let packageURL = root.appendingPathComponent("gui/Package.swift")
        let eventRowURL = root.appendingPathComponent("gui/Sources/ClaudioGUI/EventRowView.swift")
        let devURL = root.appendingPathComponent("scripts/dev-bundle.sh")
        let releaseURL = root.appendingPathComponent(".github/workflows/release.yml")
        let resourceURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUI/Resources/HostIcons", isDirectory: true)
        guard
            let package = try? String(contentsOf: packageURL, encoding: .utf8),
            let eventRow = try? String(contentsOf: eventRowURL, encoding: .utf8),
            let dev = try? String(contentsOf: devURL, encoding: .utf8),
            let release = try? String(contentsOf: releaseURL, encoding: .utf8),
            let resources = try? FileManager.default.contentsOfDirectory(
                at: resourceURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
        else {
            expect(false, "读不到 HostIcons 的 Package、组装脚本或资源目录")
            return
        }

        expect(
            package.contains(#".process("Resources/HostIcons")"#),
            "ClaudioGUI executable target 必须显式声明 HostIcons SwiftPM 资源")
        expect(
            eventRow.contains("Bundle.main.bundleURL.pathExtension == \"app\"")
                && eventRow.contains("return .module")
                && eventRow.contains("Bundle.main.resourceURL")
                && eventRow.contains(#"hasSuffix("_ClaudioGUI.bundle")"#)
                && eventRow.contains("guard candidates.count == 1")
                && eventRow.contains("hostIconResourceBundle.image(forResource:")
                && eventRow.contains("image.isTemplate = true"),
            "只有真实 macOS app 才能从 Contents/Resources 解析唯一 GUI resource bundle；"
                + "Xcode Preview 与 SwiftPM 开发进程必须回退到 Bundle.module；改名 app 也必须可用")
        let pdfNames =
            resources
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .map(\.lastPathComponent)
            .sorted()
        expect(
            pdfNames == ["claude.pdf", "codex.pdf"],
            "运行时资源必须精确包含两枚 template PDF，实得 \(pdfNames)")
        expect(
            resources.map(\.lastPathComponent).sorted() == ["claude.pdf", "codex.pdf"],
            "HostIcons 运行时目录不得混入 SVG 或其它资源")
        for pdf in resources.filter({ $0.pathExtension.lowercased() == "pdf" }) {
            let data = try? Data(contentsOf: pdf)
            let pdfText = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            expect(
                data?.starts(with: Data("%PDF".utf8)) == true
                    && (data?.count ?? 0) > 100
                    && pdfText.contains("/Type /Page")
                    && pdfText.contains("/Count 1")
                    && pdfText.contains("/MediaBox [0 0 24 24]")
                    && pdfText.contains("%%EOF"),
                "\(pdf.lastPathComponent) 必须是有效单页 PDF，MediaBox 必须为 24×24pt")
        }

        let codexRuntimePDF = resourceURL.appendingPathComponent("codex.pdf")
        let codexPDFText = (try? String(contentsOf: codexRuntimePDF, encoding: .isoLatin1)) ?? ""
        expect(
            codexPDFText.contains("/Subtype /Form")
                && codexPDFText.contains("/S /Transparency")
                && !codexPDFText.contains("/Subtype /Image"),
            "codex.pdf 必须保留透明模板/矢量语义；不允许用无透明度整幅位图，否则 isTemplate 会把 24×24 画布染成实心方块")

        let codexSourceURL = root.appendingPathComponent("assets/host-icons/codex.svg")
        let hostIconReadmeURL = root.appendingPathComponent("assets/host-icons/README.md")
        guard
            let codexSourceData = try? Data(contentsOf: codexSourceURL),
            let codexSource = String(data: codexSourceData, encoding: .utf8),
            let hostIconReadme = try? String(contentsOf: hostIconReadmeURL, encoding: .utf8)
        else {
            expect(false, "读不到 Codex Blossom SVG 或 HostIcons 来源台账")
            return
        }
        let codexHash = SHA256.hash(data: codexSourceData)
            .map { String(format: "%02x", $0) }
            .joined()
        expect(
            codexHash == "2674292c146cd5c5c41819e19c6edb268bbba73832e088aa338750bfb92b8b4e",
            "codex.svg 必须固定为批准稿的 OpenAI 2025 Blossom 几何，实得 SHA-256 \(codexHash)")
        expect(
            codexSource.contains(
                #"fill="currentColor" height="24" viewBox="0 0 20 20" width="24""#)
                && codexSource.contains(#"<path d="M11.248 18.25q-.825 0-1.568-.314"#)
                && !codexSource.contains(#"M8.086.457"#)
                && !codexSource.contains("<rect")
                && !codexSource.contains("background"),
            "codex.svg 必须是 24×24 方形透明 SVG，并保留批准稿完整 OpenAI Blossom path")
        expect(
            hostIconReadme.contains(codexHash)
                && hostIconReadme.contains("OpenAI 2025 Blossom")
                && !hostIconReadme.contains("theSVG")
                && !hostIconReadme.contains("community"),
            "HostIcons 来源台账必须记录 OpenAI 2025 Blossom 的当前 SHA，并删除社区来源")

        for (name, source) in [("dev", dev), ("release", release)] {
            expect(
                source.contains("*_ClaudioGUI.bundle")
                    && source.contains("find_unique_gui_resource_bundle")
                    && source.contains("${#candidates[@]} -ne 1"),
                "\(name) 组装必须对 SwiftPM GUI resource bundle 做恰好一个候选的失败关闭校验")
            expect(
                source.contains("*_ClaudioLocalization.bundle")
                    && source.contains("find_unique_localization_bundle")
                    && source.contains("ClaudioLocalization"),
                "\(name) 组装必须对本地化 resource bundle 做恰好一个候选的失败关闭校验")
        }
        expect(
            dev.contains(#"cp -R "$GUI_RESOURCE_BUNDLE""#)
                && dev.contains(#"$APP/Contents/Resources/$(basename "$GUI_RESOURCE_BUNDLE")"#),
            "开发 app 必须把唯一 GUI resource bundle 复制到 Contents/Resources")
        expect(
            release.contains("gui/.build/arm64-apple-macosx/release")
                && release.contains("gui/.build/x86_64-apple-macosx/release")
                && release.contains(
                    #"diff -qr "$ARM_GUI_RESOURCE_BUNDLE" "$X86_GUI_RESOURCE_BUNDLE""#)
                && release.contains(#"cp -R "$ARM_GUI_RESOURCE_BUNDLE""#),
            "release 必须分别解析双架构资源 bundle、确认完全一致后再复制")
        expect(
            release.contains(#"diff -qr "$ARM_LOCALIZATION_BUNDLE" "$X86_LOCALIZATION_BUNDLE""#)
                && release.contains(#"cp -R "$ARM_LOCALIZATION_BUNDLE""#),
            "release 必须分别解析双架构本地化 bundle、确认内容一致后再复制")
    }

    suite("dev/release 分发源包含 minimal-chime 1.1.0、第五音频与 CC0 台账") {
        let root = repositoryRoot()
        let manifestURL = root.appendingPathComponent("packs/minimal-chime/manifest.json")
        let taskStartURL = root.appendingPathComponent("packs/minimal-chime/task_start.mp3")
        let licensesURL = root.appendingPathComponent("packs/LICENSES.md")
        let devBundleURL = root.appendingPathComponent("scripts/dev-bundle.sh")
        let packCopyScriptURL = root.appendingPathComponent("scripts/copy-bundled-packs.sh")

        guard
            let manifestData = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
            let events = manifest["events"] as? [String: String],
            let licenses = try? String(contentsOf: licensesURL, encoding: .utf8),
            let devBundle = try? String(contentsOf: devBundleURL, encoding: .utf8),
            let packCopyScript = try? String(contentsOf: packCopyScriptURL, encoding: .utf8)
        else {
            expect(false, "读不到内置包 manifest、许可证台账或 dev bundle 脚本")
            return
        }

        expect(manifest["schema"] as? Int == 1, "新增 task_start 不得升级 manifest schema")
        expect(manifest["version"] as? String == "1.1.0", "minimal-chime 必须以 1.1.0 分发")
        expect(
            Set(events.keys)
                == Set(["task_start", "stop", "stop_failure", "notification", "subagent_stop"]),
            "minimal-chime 必须精确映射五种事件，实得 \(events.keys.sorted())")
        expect(
            events["task_start"] == "task_start.mp3",
            "task_start 必须映射独立音频，不能 fallback 到其它事件")

        let taskStartValues = try? taskStartURL.resourceValues(forKeys: [
            .isRegularFileKey, .fileSizeKey,
        ])
        expect(
            taskStartValues?.isRegularFile == true && (taskStartValues?.fileSize ?? 0) > 0,
            "task_start.mp3 必须作为非空正规文件进入仓库")
        expect(
            licenses.contains("Audio/confirmation_003.ogg")
                && licenses.contains("https://kenney.nl/assets/interface-sounds")
                && licenses.contains("CC0-1.0")
                && licenses.contains(
                    "c96fbbd8a2f34fe480e1f7b09ddd9392740fe44af43ca400889636ba802701d2"),
            "LICENSES.md 必须绑定 task_start 的来源、许可与最终 SHA256")

        expect(
            devBundle.contains("bash scripts/copy-bundled-packs.sh")
                && packCopyScript.contains(#"entries=("$SOURCE_ROOT"/*)"#)
                && packCopyScript.contains("LICENSES.md")
                && !packCopyScript.contains("packs/minimal-chime")
                && devBundle.contains("--package-path helper --product claudio"),
            "dev bundle 必须遍历复制所有 pack 与许可证，并显式构建 claudio helper product")
        expect(
            devBundle.contains("strip -x")
                && devBundle.contains("bash scripts/check-release-size.sh")
                && devBundle.contains(#"ln -s claudi0 "$APP/Contents/Resources/bin/claudio""#),
            "dev bundle 必须与正式发布一样 strip 并执行体积门禁")
    }

    suite("release-size 门禁：逐架构边界、别名、架构与 bundle 总量都 fail closed") {
        withTempDirectory { root in
            let app = root.appendingPathComponent("fixture.app", isDirectory: true)
            let gui = app.appendingPathComponent("Contents/MacOS/claudi0-app")
            let helper = app.appendingPathComponent("Contents/Resources/bin/claudi0")
            let alias = app.appendingPathComponent("Contents/Resources/bin/claudio")
            writeFixture("g", to: gui)
            writeFixture("h", to: helper)
            try? FileManager.default.createSymbolicLink(
                atPath: alias.path, withDestinationPath: "claudi0")

            let fakeLipo = root.appendingPathComponent("fake-lipo.sh")
            writeFixture(
                #"""
                #!/bin/bash
                set -euo pipefail
                if [ "$1" = "-archs" ]; then
                  case "$(basename "$2")" in
                    claudi0-app) printf '%s\n' "$FAKE_GUI_ARCHS" ;;
                    claudi0) printf '%s\n' "$FAKE_HELPER_ARCHS" ;;
                    *) exit 2 ;;
                  esac
                  exit 0
                fi
                input="$1"
                arch="$3"
                output="$5"
                case "$(basename "$input"):$arch" in
                  claudi0-app:arm64) size="$FAKE_GUI_ARM64_BYTES" ;;
                  claudi0-app:x86_64) size="$FAKE_GUI_X86_64_BYTES" ;;
                  claudi0:arm64) size="$FAKE_HELPER_ARM64_BYTES" ;;
                  claudi0:x86_64) size="$FAKE_HELPER_X86_64_BYTES" ;;
                  *) exit 3 ;;
                esac
                /bin/dd if=/dev/zero of="$output" bs=1 count="$size" 2>/dev/null
                """#,
                to: fakeLipo)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: fakeLipo.path)

            let exact = runReleaseSizeGate(app: app, fakeLipo: fakeLipo)
            expect(
                exact.status == 0,
                "每个切片恰好等于预算必须通过，status=\(exact.status)：\(exact.output)")

            let asymmetric = runReleaseSizeGate(
                app: app,
                fakeLipo: fakeLipo,
                overrides: ["FAKE_GUI_X86_64_BYTES": "101"])
            expect(
                asymmetric.status != 0
                    && asymmetric.output.contains("claudi0-app [x86_64]")
                    && asymmetric.output.contains("101 B > 100 B"),
                "单个超预算切片不能被另一个小切片平均掉：\(asymmetric.output)")

            let mismatched = runReleaseSizeGate(
                app: app,
                fakeLipo: fakeLipo,
                overrides: ["FAKE_HELPER_ARCHS": "arm64"])
            expect(
                mismatched.status != 0 && mismatched.output.contains("架构不一致"),
                "GUI/helper 架构不一致必须拒绝：\(mismatched.output)")

            try? FileManager.default.removeItem(at: alias)
            try? FileManager.default.createSymbolicLink(
                atPath: alias.path, withDestinationPath: "wrong-helper")
            let wrongAlias = runReleaseSizeGate(app: app, fakeLipo: fakeLipo)
            expect(
                wrongAlias.status != 0 && wrongAlias.output.contains("精确指向"),
                "legacy alias 指错目标必须拒绝：\(wrongAlias.output)")
            try? FileManager.default.removeItem(at: alias)
            try? FileManager.default.createSymbolicLink(
                atPath: alias.path, withDestinationPath: "claudi0")

            let payload = app.appendingPathComponent("Contents/Resources/payload.bin")
            writeFixture(String(repeating: "x", count: 1_001), to: payload)
            let resourceOverflow = runReleaseSizeGate(app: app, fakeLipo: fakeLipo)
            expect(
                resourceOverflow.status != 0
                    && resourceOverflow.output.contains("非可执行资源超出体积预算")
                    && resourceOverflow.output.contains("1001 B > 1000 B"),
                "未使用的 Mach-O 余量不得补贴资源越界：\(resourceOverflow.output)")
            try? FileManager.default.removeItem(at: payload)

            writeFixture(String(repeating: "g", count: 1_000), to: gui)
            writeFixture(String(repeating: "h", count: 1_000), to: helper)
            let bundleOverflow = runReleaseSizeGate(app: app, fakeLipo: fakeLipo)
            expect(
                bundleOverflow.status != 0
                    && bundleOverflow.output.contains("app bundle 超出体积预算"),
                "逐切片与资源都合格时，总 bundle 上限仍必须独立生效：\(bundleOverflow.output)")
            writeFixture("g", to: gui)
            writeFixture("h", to: helper)

            try? FileManager.default.removeItem(at: helper)
            let missing = runReleaseSizeGate(app: app, fakeLipo: fakeLipo)
            expect(
                missing.status != 0 && missing.output.contains("缺少 Release 可执行文件"),
                "缺 helper 必须在任何预算计算前 fail closed：\(missing.output)")
        }
    }

    suite("release-size 默认预算与文档使用同一 2026-08-23 重基线") {
        let root = repositoryRoot()
        let gateURL = root.appendingPathComponent("scripts/check-release-size.sh")
        let environmentURL = root.appendingPathComponent("docs/ENV.md")
        let budgetURL = root.appendingPathComponent("docs/performance/release-size-budget.md")
        guard
            let gate = try? String(contentsOf: gateURL, encoding: .utf8),
            let environment = try? String(contentsOf: environmentURL, encoding: .utf8),
            let budget = try? String(contentsOf: budgetURL, encoding: .utf8)
        else {
            expect(false, "读不到 release-size 门禁或它的环境/基线文档")
            return
        }

        expect(
            gate.contains(
                #"GUI_BYTES_PER_ARCH="${CLAUDIO_GUI_BYTES_PER_ARCH:-5500000}""#)
                && gate.contains(
                    #"HELPER_BYTES_PER_ARCH="${CLAUDIO_HELPER_BYTES_PER_ARCH:-3250000}""#)
                && environment.contains("default `5500000`")
                && environment.contains("default `3250000`")
                && budget.contains("`5,500,000 B`")
                && budget.contains("`3,250,000 B`")
                && budget.contains("`4,223,128 B`")
                && budget.contains("`2,466,184 B`")
                && budget.contains("`435,818 B`")
                && budget.contains("`7,125,130 B`")
                && budget.contains("`4,348,424 B`")
                && budget.contains("`2,563,896 B`")
                && budget.contains("`14,055,562 B`"),
            "脚本默认值、ENV reference 与实测基线必须一起重定，不能只抬高门禁数字")
    }

    suite("Orbit Zero App 图标母版与 icns 都在仓库中") {
        let branding = repositoryRoot().appendingPathComponent("assets/branding", isDirectory: true)
        let svg = branding.appendingPathComponent("claudi0-app-icon.svg")
        let icns = branding.appendingPathComponent("claudi0.icns")
        let svgText = (try? String(contentsOf: svg, encoding: .utf8)) ?? ""
        let icnsData = try? Data(contentsOf: icns)

        expect(
            svgText.contains("<ellipse cx=\"512\" cy=\"512\" rx=\"170\" ry=\"300\""),
            "App 图标必须保留 Orbit Zero 的纵向 0 几何")
        expect(
            svgText.contains("rx=\"356\" ry=\"128\" transform=\"rotate(-16 512 512)\""),
            "App 图标必须保留穿过 0 的斜轨几何")
        expect(
            svgText.contains("<circle cx=\"755\" cy=\"303\" r=\"22\""),
            "App 图标必须保留右上信号点")
        expect(icnsData?.prefix(4) == Data("icns".utf8), "claudi0.icns 必须是有效的 icns 容器")
    }

    suite("release.yml 必须 Developer ID 签名、公证并失败关闭，不能回退 ad-hoc") {
        let yml = repositoryRoot().appendingPathComponent(".github/workflows/release.yml")
        guard let data = try? Data(contentsOf: yml),
            let yaml = String(data: data, encoding: .utf8)
        else {
            expect(false, "读不到 \(yml.path)")
            return
        }

        expect(
            yaml.contains("APPLE_DEVELOPER_ID_CERTIFICATE_BASE64")
                && yaml.contains("APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD")
                && yaml.contains("APPLE_NOTARY_API_KEY_BASE64")
                && yaml.contains("APPLE_NOTARY_KEY_ID")
                && yaml.contains("APPLE_NOTARY_ISSUER_ID")
                && yaml.contains("missing required Apple release credentials"),
            "签名或公证凭据缺失时 release 必须在构建前失败关闭")
        expect(
            yaml.contains("--options runtime")
                && yaml.contains("--timestamp")
                && yaml.contains("Developer ID Application")
                && yaml.contains("xcrun notarytool submit")
                && yaml.contains("xcrun stapler staple")
                && yaml.contains("xcrun stapler validate")
                && yaml.contains("spctl --assess"),
            "release 必须完成 hardened runtime 签名、容器公证、staple 与 Gatekeeper 验证")
        expect(
            !yaml.contains("codesign --force --deep --sign -")
                && !yaml.contains("/usr/bin/xattr")
                && !yaml.contains("com.apple.quarantine"),
            "正式发布不得回退 ad-hoc 签名，也不得靠清除 quarantine 绕过 Gatekeeper")
        expect(
            yaml.contains("SHA256SUMS.txt")
                && yaml.contains("HOMEBREW_TAP_ENABLED == 'true'")
                && yaml.contains("security delete-keychain"),
            "release 必须上传校验和、让 tap 保持可选，并始终清理临时 keychain")

        // GitHub expressions are evaluated before the shell starts. Keeping them out of every
        // run body prevents a tag-derived value from becoming shell source code.
        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var runBodyLines: [String] = []
        var runIndent: Int?
        for line in lines {
            let indent = line.prefix { $0 == " " }.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let activeIndent = runIndent {
                if !trimmed.isEmpty && indent <= activeIndent {
                    runIndent = nil
                } else {
                    runBodyLines.append(line)
                    continue
                }
            }
            if trimmed == "run: |" || trimmed.hasPrefix("run: ") {
                runIndent = indent
            }
        }
        expect(
            runBodyLines.allSatisfy { !$0.contains("${{") },
            "run 脚本体不得直接包含 GitHub expression；不可信值必须先经 env 传入并校验")
    }

    suite("开发、tag、CLI、Info.plist、DMG 与 CI 共用同一版本契约") {
        let root = repositoryRoot()
        let releaseURL = root.appendingPathComponent(".github/workflows/release.yml")
        let ciURL = root.appendingPathComponent(".github/workflows/ci.yml")
        let packageURL = root.appendingPathComponent("helper/Package.swift")
        let cliURL = root.appendingPathComponent("helper/Sources/claudio/Claudio.swift")
        guard
            let release = try? String(contentsOf: releaseURL, encoding: .utf8),
            let ci = try? String(contentsOf: ciURL, encoding: .utf8),
            let package = try? String(contentsOf: packageURL, encoding: .utf8),
            let cli = try? String(contentsOf: cliURL, encoding: .utf8)
        else {
            expect(false, "读不到版本源、CLI 或 CI/release workflow")
            return
        }

        expect(
            package.contains(#"?? "0.0.0-dev""#)
                && package.contains(#"environment["CLAUDIO_VERSION"]"#)
                && cli.contains("version: ClaudioVersion.current"),
            "开发默认版本必须只由 Package.swift 注入 ClaudioVersion，并由 CLI 直接消费")
        expect(
            release.contains(
                #"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#)
                && release.contains(#"echo "CLAUDIO_VERSION=$VERSION" >> "$GITHUB_ENV""#)
                && release.contains(
                    "<key>CFBundleShortVersionString</key><string>$CLAUDIO_VERSION</string>")
                && release.contains(#"DMG_NAME="$APP_NAME-$CLAUDIO_VERSION.dmg""#)
                && release.contains(#"--title "$APP_NAME $CLAUDIO_VERSION""#),
            "严格 tag 派生的同一版本必须进入构建环境、Info.plist、DMG 与 Release 标题")
        expect(
            release.contains(#"CLI_VERSION="$("$APP/Contents/Resources/bin/claudi0" --version)""#)
                && release.contains("release version mismatch"),
            "发布组装后必须执行 CLI/Info.plist 版本一致性门禁")
        expect(
            ci.contains("push:")
                && ci.contains("pull_request:")
                && ci.contains("swift run --package-path helper claudio-tests")
                && ci.contains("swift run --package-path gui claudio-gui-tests")
                && ci.contains("swift build -c debug --package-path gui --product ClaudioGUI")
                && ci.contains("swift build -c release --package-path gui --product ClaudioGUI")
                && ci.contains(
                    "jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings")
                && ci.contains("bash scripts/check-release-size.sh dist/claudi0.app")
                && ci.contains("git diff --check"),
            "push/PR CI 必须覆盖双 harness、双配置 GUI 构建、catalog、体积与 whitespace")

        let xcodeDeveloperDirectory =
            "DEVELOPER_DIR: /Applications/Xcode_16.4.app/Contents/Developer"
        let swift6VersionPattern = #"Apple\ Swift\ version\ 6\."#
        expect(
            ci.contains("name: Test and build\n    runs-on: macos-15")
                && release.contains(
                    "name: Build, sign, notarize, and verify\n    runs-on: macos-15")
                && ci.contains(xcodeDeveloperDirectory)
                && release.contains(xcodeDeveloperDirectory)
                && ci.contains(swift6VersionPattern)
                && release.contains(swift6VersionPattern)
                && ci.contains("::error::Swift 6 is required")
                && release.contains("::error::Swift 6 is required"),
            "CI 与 release 构建必须固定 macos-15/Xcode 16.4，并在执行 SwiftPM 前失败关闭非 Swift 6 工具链")
    }

    suite("Homebrew cask 保持可选、签名分发且卸载不删除用户数据") {
        let cask = repositoryRoot().appendingPathComponent("Casks/claudi0.rb")
        guard let data = try? Data(contentsOf: cask),
            let ruby = String(data: data, encoding: .utf8)
        else {
            expect(false, "读不到 \(cask.path)")
            return
        }

        expect(
            ruby.contains(#"depends_on macos: ">= :monterey""#)
                && ruby.contains(#"app "claudi0.app""#)
                && ruby.contains("claudi0-#{version}.dmg")
                && ruby.contains("sha256"),
            "cask 必须绑定真实版本化 DMG、SHA-256、macOS 12+ 与 app artifact")
        expect(
            !ruby.contains("xattr")
                && !ruby.contains("com.apple.quarantine")
                && !ruby.contains("zap trash:")
                && ruby.contains("preserves ~/.claudio"),
            "cask 不得绕过 Gatekeeper，也不得在卸载时删除 ~/.claudio 用户数据")
    }
}
