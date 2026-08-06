import ClaudioGUICore
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
    let output = String(
        data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return ReleaseSizeProcessResult(status: process.terminationStatus, output: output)
}

@MainActor
func runReleaseLayoutSuites() {
    suite("release.yml 真的把 helper 放在 GUI 会去找的那个位置") {
        let workflow = repositoryRoot()
            .appendingPathComponent(".github/workflows/release.yml")
        guard let data = try? Data(contentsOf: workflow),
            let yaml = String(data: data, encoding: .utf8)
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

        let helperDestination = "Contents/Resources/\(bundledHelperSubdirectory)/\(claudioHelperBinaryName)"
        expect(
            copyLines.contains { $0.contains(helperDestination) },
            "release.yml 里没有任何一条 `cp` 把 helper 复制到 \"\(helperDestination)\"。"
                + "GUI 会去那里找它（`bundledHelperBinary(in:)`），生产者却把它放到了别处 —— "
                + "所有测试会绿、CI 会绿、DMG 会照常签发，然后 CTA 在每一台用户机器上报「找不到小助手」。"
                + "实际的 cp 行：\(copyLines)")

        // `performFirstRunSetup` 从 helper 路径去掉两级、拼 `packs` 反推内置包目录。
        expect(
            copyLines.contains { $0.contains("Contents/Resources/packs") },
            "release.yml 里没有任何一条 `cp` 把内置包复制进 \"Contents/Resources/packs\" —— 包目录是从"
                + "helper 路径反推出来的（去掉两级 + packs），放错地方会让 setup 一个包都复制不出来，"
                + "而且**不报错**。实际的 cp 行：\(copyLines)")
        expect(
            copyLines.contains {
                $0.contains("packs/LICENSES.md")
                    && $0.contains("Contents/Resources/packs/LICENSES.md")
            },
            "release.yml 必须把内置音频来源与 CC0 台账一起装入 app bundle。实际的 cp 行：\(copyLines)")
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
            yaml.contains("<key>CFBundleExecutable</key><string>${{ env.APP_EXECUTABLE }}</string>"),
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

    suite("dev/release 分发源包含 minimal-chime 1.1.0、第五音频与 CC0 台账") {
        let root = repositoryRoot()
        let manifestURL = root.appendingPathComponent("packs/minimal-chime/manifest.json")
        let taskStartURL = root.appendingPathComponent("packs/minimal-chime/task_start.mp3")
        let licensesURL = root.appendingPathComponent("packs/LICENSES.md")
        let devBundleURL = root.appendingPathComponent("scripts/dev-bundle.sh")

        guard
            let manifestData = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
            let events = manifest["events"] as? [String: String],
            let licenses = try? String(contentsOf: licensesURL, encoding: .utf8),
            let devBundle = try? String(contentsOf: devBundleURL, encoding: .utf8)
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

        let taskStartValues = try? taskStartURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        expect(
            taskStartValues?.isRegularFile == true && (taskStartValues?.fileSize ?? 0) > 0,
            "task_start.mp3 必须作为非空正规文件进入仓库")
        expect(
            licenses.contains("Audio/confirmation_003.ogg")
                && licenses.contains("https://kenney.nl/assets/interface-sounds")
                && licenses.contains("CC0-1.0")
                && licenses.contains("c96fbbd8a2f34fe480e1f7b09ddd9392740fe44af43ca400889636ba802701d2"),
            "LICENSES.md 必须绑定 task_start 的来源、许可与最终 SHA256")

        expect(
            devBundle.contains("cp -R packs/minimal-chime")
                && devBundle.contains("cp packs/LICENSES.md")
                && devBundle.contains("--package-path helper --product claudio"),
            "dev bundle 必须复制 1.1.0 包与许可证，并显式构建 claudio helper product")
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

    // ⚠️ **钉 `release.yml`，不是 `Casks/claudi0.rb`**（T17c 对抗评审）。
    //
    // 上一版这条断言读的是 `Casks/claudi0.rb` —— 而那个文件**自己的第 1 行**就写着「参考模板，
    // 非本仓库直接生效的 Homebrew tap」。真正 `brew install` 会用到的 cask，是下面这个 workflow 的
    // update-cask job 用 here-doc **生成并推到 tap 仓库**的那一份。于是：把 release.yml 里的 `-dr`
    // 改回 `-d` → 所有测试全绿、CI 全绿、DMG 照常签发 → 每一位 brew 用户拿到的 bundle 里，
    // 那个嵌套的 helper 仍然带着 com.apple.quarantine → 复制到 `~/.claudio/bin/` 之后被 Gatekeeper
    // 每次 SIGKILL（实测 exit=137，零 stderr）。
    //
    // 这个 suite 存在的全部理由，是它文件头写下的那句话：「一个跨 yml 与二进制的生产者/消费者契约，
    // 只有一种回归网可能存在 —— 真的去读那个 yml」。上一条 `cp` 断言做到了，这一条没有：它去读了
    // 一份仓库自己声明为「不是安装源」的模板。绊线钉在诱饵上，等于没钉。
    //
    // `Casks/claudi0.rb` 仍然一起钉 —— 它是人读的参考，漂了同样是 bug（这次评审正是先发现它的
    // caveats 与 release.yml 生成的那份已经反向漂移：一个说「点接管即可」，一个说「面板不会自动接管」）。
    suite("release.yml 生成的 cask（brew 真正装的那份）必须递归解除隔离（-dr）") {
        let yml = repositoryRoot().appendingPathComponent(".github/workflows/release.yml")
        guard let data = try? Data(contentsOf: yml),
            let yaml = String(data: data, encoding: .utf8)
        else {
            expect(false, "读不到 \(yml.path)")
            return
        }

        // 只看真正的 xattr 参数行，不做全文 grep —— 与上面 `cp` 那条同一条纪律：一次文本断言若不
        // 区分「代码」与「谈论代码的文字」（注释、release notes 的散文），它断的就不是代码。
        let xattrArgLines = yaml
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("args:") && $0.contains("com.apple.quarantine") }

        expect(
            !xattrArgLines.isEmpty,
            "release.yml 的 update-cask here-doc 里必须有一条 xattr 的 args: 行 —— 找不到它，"
                + "说明 cask 模板被改动过，这条断言已经失去了它要保护的对象")
        expect(
            xattrArgLines.allSatisfy {
                $0.contains("\"-dr\"") || $0.contains("\"-rd\"") || $0.contains("--recursive")
            },
            "release.yml 生成给 tap 的 cask，其 postflight 必须递归解除隔离 —— 非递归的 `xattr -d` "
                + "只剥 .app 目录自己那一层，剥不掉 Contents/Resources/bin/claudio 上的章，"
                + "而一个带 com.apple.quarantine 的 helper 会被 Gatekeeper 在每次 hook 执行时 SIGKILL"
                + "（实测 exit=137）。实际的 args 行：\(xattrArgLines)")

        // 这份 here-doc 的 caveats 是**每一位 brew 用户看到的第一屏引导**。T17 把 CTA 接线之后，
        // 它一度还在原样告诉用户「面板暂不会自动接管，需在 Terminal 跑 setup」—— 主分发渠道的
        // 第一句话与产品的实际行为相反，而且正是这次提交花了整个 T17 去消灭的那句话。
        expect(
            !yaml.contains("暂不会自动接管"),
            "release.yml 生成给 tap 的 cask，其 caveats 仍在告诉 brew 用户「菜单栏面板暂不会自动接管」"
                + " —— CTA 早已接线（T17）。这句话会印在主分发渠道的第一屏上")
    }

    suite("Casks/claudi0.rb（人读的参考模板）与 release.yml 生成的那份不得漂移") {
        let cask = repositoryRoot().appendingPathComponent("Casks/claudi0.rb")
        guard let data = try? Data(contentsOf: cask),
            let ruby = String(data: data, encoding: .utf8)
        else {
            expect(false, "读不到 \(cask.path)")
            return
        }

        expect(
            ruby.contains("\"-dr\"") || ruby.contains("\"-rd\"") || ruby.contains("--recursive"),
            "参考模板也必须写 -dr，否则它会教下一个人写错的那一版")

        // caveats 漂移过一次（T17c 逮到）：T17 把「点面板里的接管即可」写进了这份模板，却没写进
        // release.yml 那份 here-doc —— 于是真实的 brew 用户会被告知「面板暂不会自动接管，请去
        // Terminal 跑 setup」，正是这次提交花了整个 T17 去消灭的那句话。两份手写副本必然漂移，
        // 这条断言钉住的是它们**关于同一件事的说法**必须一致。
        expect(
            !ruby.contains("暂不会自动接管"),
            "参考模板的 caveats 仍在说「面板暂不会自动接管」—— CTA 早已接线（T17）")
    }
}
