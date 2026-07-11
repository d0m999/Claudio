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

        // ``bundledHelperBinary(in:)`` 用 `subdirectory: "bin"` 在 `Contents/Resources/` 里找，
        // 名字是 `claudio`（``claudioHelperBinaryName``）。生产者必须往同一个地方放。
        let helperDestination = "Contents/Resources/\(bundledHelperSubdirectory)/\(claudioHelperBinaryName)"
        expect(
            yaml.contains(helperDestination),
            "release.yml 里找不到 \"\(helperDestination)\" —— GUI 会去那里找 helper，生产者却把它放到了别处。"
                + "所有测试都会绿、CI 会绿、DMG 会照常签发，然后 CTA 在每一台用户机器上报「找不到小助手」。")

        // `performFirstRunSetup` 从 helper 路径去掉两级、拼 `packs` 反推内置包目录。
        expect(
            yaml.contains("Contents/Resources/packs"),
            "release.yml 里找不到 \"Contents/Resources/packs\" —— 内置包目录是从 helper 路径反推的"
                + "（去掉两级 + packs），放错地方会让 setup 一个包都复制不出来，而且**不报错**。")

        // GUI 自己的可执行文件在 Contents/MacOS/ —— 这条断言钉住的是「两者确实是两个不同的东西」，
        // 也就是 T17 那个 bug 的前提。
        expect(
            yaml.contains("Contents/MacOS/"),
            "release.yml 里找不到 Contents/MacOS/ —— GUI 可执行文件与 helper 必须是两个不同的文件")
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
