import ClaudioGUICore
import Foundation

// MARK: - app bundle 布局契约：GUI 是消费者，release.yml 是生产者（T17）
//
// ``bundledHelperBinary(in:)`` 去 `Contents/Resources/bin/claudio` 找 helper，
// `performFirstRunSetup` 再从那条路径反推 `Contents/Resources/packs`。这条布局契约的**另一端**
// 在 `.github/workflows/release.yml` 的 "Assemble Claudio.app" 步骤里 —— 两边之间没有任何编译期
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
        // 第一版这条断言是 `yaml.contains("Contents/Resources/bin/claudio")` —— 而 release.yml 的
        // Release notes 与 cask caveats 里**也**印着这条路径。把真正的 `cp` 目标改成
        // `Resources/helper/`（也就是这条 suite 存在的全部理由那次变异），那两处散文照样让 grep 命中，
        // **652 全绿**。一条不可能失败的测试比没有测试更坏：它宣称自己在守着一件事。
        let copyLines = yaml.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("cp ") || $0.hasPrefix("cp -") }

        expect(!copyLines.isEmpty, "release.yml 里一条 `cp` 都没有？「Assemble Claudio.app」那步没了？")

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

        // GUI 自己的可执行文件在 Contents/MacOS/ —— 钉住「两者确实是两个不同的文件」，也就是 T17
        // 那个 bug 的前提。
        expect(
            copyLines.contains { $0.contains("Contents/MacOS/") },
            "release.yml 里没有任何一条 `cp` 往 Contents/MacOS/ 放 GUI 可执行文件 —— GUI 与 helper 必须"
                + "是两个不同的文件。实际的 cp 行：\(copyLines)")
    }

    suite("Casks/claudio.rb 递归解除隔离（-r），否则 bundle 里的 helper 仍带着章") {
        let cask = repositoryRoot().appendingPathComponent("Casks/claudio.rb")
        guard let data = try? Data(contentsOf: cask),
            let ruby = String(data: data, encoding: .utf8)
        else {
            expect(false, "读不到 \(cask.path)")
            return
        }

        // `xattr -d`（非递归）只剥 `.app` 目录本身那一层，`Contents/Resources/bin/claudio` 上的章
        // 原样留着。setup 现在会自己剥（`Quarantine.swift`，那才是 load-bearing 的那一道），这里是
        // 第二道：让 bundle 从一开始就是干净的。
        expect(
            ruby.contains("\"-dr\"") || ruby.contains("\"-rd\"") || ruby.contains("--recursive"),
            "cask 的 postflight 必须递归解除隔离 —— 非递归的 `xattr -d` 剥不掉嵌套的 helper，"
                + "而一个带 com.apple.quarantine 的 helper 会被 Gatekeeper 在每次 hook 执行时 SIGKILL（实测 exit=137）")
    }
}
