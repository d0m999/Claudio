import Foundation

@MainActor
func runLocalPreRCSuites() {
    suite("本机 pre-RC：公开入口把全部 gate 绑定到同一 clean HEAD") {
        let root = guiTestRepositoryRoot()
        let scriptURL = root.appendingPathComponent("scripts/local-pre-rc.sh")
        let contractURL = root.appendingPathComponent("scripts/local-pre-rc-contract.json")
        guard let script = try? String(contentsOf: scriptURL, encoding: .utf8),
            let contractData = try? Data(contentsOf: contractURL),
            let contract = try? JSONSerialization.jsonObject(with: contractData)
                as? [String: Any]
        else {
            expect(false, "读不到本机 pre-RC 入口或机器可读证据合同")
            return
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: scriptURL.path)
        let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        expect(permissions & 0o111 != 0, "本机 pre-RC 入口必须可执行")

        let invalidInvocation = runTestProcess(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [scriptURL.path, "--unexpected"])
        expect(
            invalidInvocation.status == 2 && invalidInvocation.output.contains("usage:"),
            "未知参数必须在构建或写报告前失败关闭：\(invalidInvocation.output)")

        let requiredCommands = [
            "swift run --package-path helper claudio-tests",
            "swift run --package-path gui claudio-gui-tests",
            "swift build -c debug --package-path gui --product ClaudioGUI",
            "jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings",
            "bash scripts/dev-bundle.sh",
            #"bash "$repo_root/scripts/check-release-size.sh" "$app_name""#,
            "git diff --check",
        ]
        expect(
            requiredCommands.allSatisfy(script.contains),
            "本机 pre-RC 入口必须逐项运行 issue #64 指定的六个 gate")
        expect(
            script.contains("git rev-parse --verify HEAD^{commit}")
                && script.contains("git status --porcelain --untracked-files=all")
                && script.contains("assert_checkout_identity")
                && script.contains("run_bound_step"),
            "每个 gate 前后都必须复验 HEAD 与 clean checkout，不能生成未绑定 commit 的报告")
        expect(
            script.contains("sw_vers -productVersion")
                && script.contains("uname -m")
                && script.contains("lipo -archs")
                && script.contains("Signature=adhoc")
                && script.contains("local-pre-rc-contract.json"),
            "报告必须采集 macOS/CPU，并实证 dev bundle 是当前单架构 ad-hoc 产物")
        expect(
            script.contains("unset CLAUDIO_GUI_BYTES_PER_ARCH")
                && script.contains("CLAUDIO_HELPER_BYTES_PER_ARCH")
                && script.contains("CLAUDIO_NON_EXECUTABLE_BUNDLE_BYTES")
                && script.contains("CLAUDIO_LIPO_BIN")
                && script.contains("CLAUDIO_VERSION"),
            "本机 pre-RC 必须清除可放宽 size gate 或改变 bundle 身份的环境覆盖")

        let staleRemoval = script.range(of: #"rm -f -- "$report_name""#)
        let toolPreflight = script.range(of: "for required_tool in")
        let staleRemovalIndex = staleRemoval?.lowerBound ?? script.endIndex
        let toolPreflightIndex = toolPreflight?.lowerBound ?? script.startIndex
        expect(
            staleRemovalIndex < toolPreflightIndex,
            "任何工具、合同或 HEAD 预检失败前都必须先删除旧成功报告")
        guard let reportMove = script.range(of: #"mv -f -- "$temporary_report" "$report_name""#),
            let finalIdentityCheck = script.range(
                of: #"assert_checkout_identity "$expected_commit""#,
                range: reportMove.upperBound..<script.endIndex)
        else {
            expect(false, "报告发布后必须再次复验 checkout identity")
            return
        }
        expect(
            finalIdentityCheck.lowerBound > reportMove.lowerBound
                && script.contains(#"rm -f -- "$report_name""#)
                && script.contains("report_is_current"),
            "报告发布后的 HEAD 漂移必须删除报告并失败关闭")

        expect(contract["schema"] as? Int == 1, "pre-RC 合同 schema 必须固定为 1")
        expect(
            contract["evidence_class"] as? String == "local_pre_rc"
                && contract["qualification"] as? String == "pre_rc_only"
                && contract["formal_release_candidate"] as? Bool == false,
            "本机报告必须只能归类为 pre-RC，不能成为 formal release candidate")
        guard let formalEvidence = contract["formal_evidence"] as? [String: String] else {
            expect(false, "pre-RC 合同缺少 formal_evidence")
            return
        }
        expect(
            formalEvidence
                == [
                    "universal": "not_satisfied",
                    "developer_id": "not_satisfied",
                    "notarization": "not_evaluated",
                    "stapling": "not_evaluated",
                    "gatekeeper": "not_evaluated",
                    "dmg_checksum": "not_evaluated",
                    "intel_hardware": "not_evaluated",
                ],
            "当前架构或 ad-hoc 结果不得提升任何正式 RC/Intel 验收项：\(formalEvidence)")
    }

    suite("本机 pre-RC：输出目录 symlink 在删除旧报告前失败关闭") {
        let fileManager = FileManager.default
        let sourceScript = guiTestRepositoryRoot()
            .appendingPathComponent("scripts/local-pre-rc.sh")
        let sourceHelper = guiTestRepositoryRoot()
            .appendingPathComponent("scripts/pinned-output-directory.sh")
        let fixtureRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "claudio-local-pre-rc-symlink-\(UUID().uuidString)")
        let fixtureRepository = fixtureRoot.appendingPathComponent("repository")
        let fixtureScripts = fixtureRepository.appendingPathComponent("scripts")
        let fixtureScript = fixtureScripts.appendingPathComponent("local-pre-rc.sh")
        let fixtureHelper = fixtureScripts.appendingPathComponent("pinned-output-directory.sh")
        let externalOutput = fixtureRoot.appendingPathComponent("external-output")
        let externalReport = externalOutput.appendingPathComponent("local-pre-rc-report.json")
        let reportSentinel = Data("external-report-must-survive".utf8)
        defer { try? fileManager.removeItem(at: fixtureRoot) }

        do {
            try fileManager.createDirectory(
                at: fixtureScripts, withIntermediateDirectories: true)
            try fileManager.createDirectory(
                at: externalOutput, withIntermediateDirectories: true)
            try fileManager.copyItem(at: sourceScript, to: fixtureScript)
            try fileManager.copyItem(at: sourceHelper, to: fixtureHelper)
            try reportSentinel.write(to: externalReport)
            try fileManager.createSymbolicLink(
                at: fixtureRepository.appendingPathComponent("dist"),
                withDestinationURL: externalOutput)
        } catch {
            expect(false, "无法建立输出目录 symlink 回归夹具：\(error)")
            return
        }

        let result = runTestProcess(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [fixtureScript.path],
            currentDirectoryURL: fixtureRepository)
        expect(
            result.status == 1
                && result.output.contains("output directory must not be a symbolic link"),
            "dist symlink 必须在任何删除或工具预检前失败关闭：\(result.output)")
        expect(
            (try? Data(contentsOf: externalReport)) == reportSentinel,
            "拒绝 dist symlink 时不得删除仓库外的旧报告")
    }

    suite("本机输出目录：验证后替换父路径仍只操作已钉住目录") {
        withTempDirectory { fixtureRoot in
            let repository = fixtureRoot.appendingPathComponent("repository")
            let output = repository.appendingPathComponent("dist")
            let movedOutput = repository.appendingPathComponent("original-dist")
            let externalOutput = fixtureRoot.appendingPathComponent("external-output")
            let reportName = "local-pre-rc-report.json"
            let localReport = output.appendingPathComponent(reportName)
            let movedLocalReport = movedOutput.appendingPathComponent(reportName)
            let externalReport = externalOutput.appendingPathComponent(reportName)
            let externalSentinel = Data("external-report-must-survive".utf8)
            let driver = fixtureRoot.appendingPathComponent("pin-output-driver.sh")
            let helper = guiTestRepositoryRoot()
                .appendingPathComponent("scripts/pinned-output-directory.sh")

            writeFixture("local-report-must-be-removed", to: localReport)
            writeFixture(externalSentinel, to: externalReport)
            writeFixture(
                #"""
                #!/bin/bash
                set -euo pipefail
                source "$PINNED_OUTPUT_HELPER"

                swap_output_and_remove_report() {
                    /bin/mv "$FIXTURE_REPOSITORY/dist" "$FIXTURE_REPOSITORY/original-dist"
                    /bin/ln -s "$EXTERNAL_OUTPUT" "$FIXTURE_REPOSITORY/dist"
                    /bin/rm -f -- "local-pre-rc-report.json"
                }

                claudio_with_pinned_output_directory \
                    "$FIXTURE_REPOSITORY" "dist" swap_output_and_remove_report
                """#,
                to: driver)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: driver.path)

            let result = runTestProcess(
                executableURL: URL(fileURLWithPath: "/bin/bash"),
                arguments: [driver.path],
                environmentOverrides: [
                    "EXTERNAL_OUTPUT": externalOutput.path,
                    "FIXTURE_REPOSITORY": repository.path,
                    "PINNED_OUTPUT_HELPER": helper.path,
                ])
            expect(
                result.status == 1
                    && result.output.contains("output directory changed after validation"),
                "路径替换必须在操作钉住目录后失败关闭：\(result.output)")
            expect(
                !FileManager.default.fileExists(atPath: movedLocalReport.path),
                "危险操作必须真的落在验证时钉住的原目录，而不是被跳过")
            expect(
                (try? Data(contentsOf: externalReport)) == externalSentinel,
                "验证后的父路径替换不得把删除重定向到仓库外报告")
        }
    }

    suite("本机输出目录：同路径重建普通目录仍视为身份已更换") {
        withTempDirectory { fixtureRoot in
            let repository = fixtureRoot.appendingPathComponent("repository")
            let output = repository.appendingPathComponent("dist")
            let movedOutput = repository.appendingPathComponent("original-dist")
            let replacementOutput = repository.appendingPathComponent("dist")
            let reportName = "local-pre-rc-report.json"
            let movedLocalReport = movedOutput.appendingPathComponent(reportName)
            let replacementReport = replacementOutput.appendingPathComponent(reportName)
            let replacementSentinel = Data("replacement-directory-must-survive".utf8)
            let driver = fixtureRoot.appendingPathComponent("replace-output-driver.sh")
            let helper = guiTestRepositoryRoot()
                .appendingPathComponent("scripts/pinned-output-directory.sh")

            writeFixture(
                "local-report-must-be-removed",
                to: output.appendingPathComponent(
                    reportName))
            writeFixture(
                #"""
                #!/bin/bash
                set -euo pipefail
                source "$PINNED_OUTPUT_HELPER"

                replace_output_with_new_directory() {
                    /bin/mv "$FIXTURE_REPOSITORY/dist" \
                        "$FIXTURE_REPOSITORY/original-dist"
                    /bin/mkdir "$FIXTURE_REPOSITORY/dist"
                    /usr/bin/printf '%s' "$REPLACEMENT_SENTINEL" \
                        > "$FIXTURE_REPOSITORY/dist/local-pre-rc-report.json"
                    /bin/rm -f -- "local-pre-rc-report.json"
                }

                claudio_with_pinned_output_directory \
                    "$FIXTURE_REPOSITORY" "dist" replace_output_with_new_directory
                """#,
                to: driver)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: driver.path)

            let result = runTestProcess(
                executableURL: URL(fileURLWithPath: "/bin/bash"),
                arguments: [driver.path],
                environmentOverrides: [
                    "FIXTURE_REPOSITORY": repository.path,
                    "PINNED_OUTPUT_HELPER": helper.path,
                    "REPLACEMENT_SENTINEL": String(decoding: replacementSentinel, as: UTF8.self),
                ])
            expect(
                result.status == 1
                    && result.output.contains("output directory changed after validation"),
                "同路径的新普通目录必须因 device/inode 不同而失败关闭：\(result.output)")
            expect(
                !FileManager.default.fileExists(atPath: movedLocalReport.path),
                "回调操作必须继续落在已钉住的原目录")
            expect(
                (try? Data(contentsOf: replacementReport)) == replacementSentinel,
                "身份复验不得改写或删除同路径重建目录中的报告")
        }
    }

    suite("本机 pre-RC：报告 trap 不得删除替换后目录中的外部报告") {
        withTempDirectory { fixtureRoot in
            let fileManager = FileManager.default
            let sourceRoot = guiTestRepositoryRoot()
            let repository = fixtureRoot.appendingPathComponent("repository")
            let scripts = repository.appendingPathComponent("scripts")
            let fakeBin = fixtureRoot.appendingPathComponent("fake-bin")
            let externalOutput = fixtureRoot.appendingPathComponent("external-output")
            let movedOutput = repository.appendingPathComponent("original-dist")
            let externalReport = externalOutput.appendingPathComponent(
                "local-pre-rc-report.json")
            let externalSentinel = Data("external-report-must-survive-trap".utf8)
            let fixedCommit = String(repeating: "a", count: 40)

            try? fileManager.createDirectory(at: scripts, withIntermediateDirectories: true)
            try? fileManager.createDirectory(at: fakeBin, withIntermediateDirectories: true)
            try? fileManager.createDirectory(
                at: externalOutput, withIntermediateDirectories: true)
            for name in [
                "local-pre-rc.sh", "pinned-output-directory.sh",
                "local-pre-rc-contract.json",
            ] {
                try? fileManager.copyItem(
                    at: sourceRoot.appendingPathComponent("scripts/\(name)"),
                    to: scripts.appendingPathComponent(name))
            }
            writeFixture(
                #"""
                #!/bin/bash
                mkdir -p dist/claudi0.app/Contents/MacOS \
                    dist/claudi0.app/Contents/Resources/bin
                : > dist/claudi0.app/Contents/MacOS/claudi0-app
                : > dist/claudi0.app/Contents/Resources/bin/claudi0
                """#,
                to: scripts.appendingPathComponent("dev-bundle.sh"))
            writeFixture(
                "#!/bin/bash\nexit 0\n",
                to: scripts.appendingPathComponent(
                    "check-release-size.sh"))
            writeFixture(
                #"""
                #!/bin/bash
                if [[ "$1" == "rev-parse" ]]; then
                    echo "$FIXED_COMMIT"
                fi
                exit 0
                """#,
                to: fakeBin.appendingPathComponent("git"))
            writeFixture(
                "#!/bin/bash\necho 15.6\n",
                to: fakeBin.appendingPathComponent(
                    "sw_vers"))
            writeFixture(
                "#!/bin/bash\necho arm64\n",
                to: fakeBin.appendingPathComponent(
                    "uname"))
            writeFixture("#!/bin/bash\nexit 0\n", to: fakeBin.appendingPathComponent("swift"))
            writeFixture("#!/bin/bash\necho arm64\n", to: fakeBin.appendingPathComponent("lipo"))
            writeFixture(
                "#!/bin/bash\necho Signature=adhoc\necho 'TeamIdentifier=not set'\n",
                to: fakeBin.appendingPathComponent("codesign"))
            writeFixture(
                #"""
                #!/bin/bash
                if [[ " $* " == *" --arg commit_sha "* ]]; then
                    /bin/mv "$FIXTURE_REPOSITORY/dist" \
                        "$FIXTURE_REPOSITORY/original-dist"
                    /bin/ln -s "$EXTERNAL_OUTPUT" "$FIXTURE_REPOSITORY/dist"
                    echo '{}'
                fi
                exit 0
                """#,
                to: fakeBin.appendingPathComponent("jq"))
            writeFixture(externalSentinel, to: externalReport)

            let executableFixtures = [
                scripts.appendingPathComponent("dev-bundle.sh"),
                scripts.appendingPathComponent("check-release-size.sh"),
                fakeBin.appendingPathComponent("git"),
                fakeBin.appendingPathComponent("sw_vers"),
                fakeBin.appendingPathComponent("uname"),
                fakeBin.appendingPathComponent("swift"),
                fakeBin.appendingPathComponent("lipo"),
                fakeBin.appendingPathComponent("codesign"),
                fakeBin.appendingPathComponent("jq"),
            ]
            for fixture in executableFixtures {
                try? fileManager.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: fixture.path)
            }

            let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            let result = runTestProcess(
                executableURL: URL(fileURLWithPath: "/bin/bash"),
                arguments: [scripts.appendingPathComponent("local-pre-rc.sh").path],
                currentDirectoryURL: repository,
                environmentOverrides: [
                    "EXTERNAL_OUTPUT": externalOutput.path,
                    "FIXED_COMMIT": fixedCommit,
                    "FIXTURE_REPOSITORY": repository.path,
                    "PATH": "\(fakeBin.path):\(inheritedPath)",
                ])
            expect(
                result.status == 1
                    && result.output.contains("output directory"),
                "报告生成后替换 dist 必须失败关闭：\(result.output)")
            expect(
                (try? Data(contentsOf: externalReport)) == externalSentinel,
                "EXIT trap 必须清理已钉住的原目录，不得删除替换后目录中的外部报告")
            let movedEntries =
                (try? fileManager.contentsOfDirectory(
                    at: movedOutput, includingPropertiesForKeys: nil)) ?? []
            expect(
                !fileManager.fileExists(
                    atPath: movedOutput.appendingPathComponent(
                        "local-pre-rc-report.json"
                    ).path)
                    && !movedEntries.contains(where: {
                        $0.lastPathComponent.hasPrefix(".local-pre-rc-report.")
                    }),
                "失败 trap 必须从已钉住的原目录清掉临时报告与未完成的最终报告")
        }
    }

    suite("dev-bundle：dist symlink 在清理旧 app 前失败关闭") {
        withTempDirectory { fixtureRoot in
            let fileManager = FileManager.default
            let sourceRoot = guiTestRepositoryRoot()
            let repository = fixtureRoot.appendingPathComponent("repository")
            let scripts = repository.appendingPathComponent("scripts")
            let devBundle = scripts.appendingPathComponent("dev-bundle.sh")
            let pinnedHelper = scripts.appendingPathComponent("pinned-output-directory.sh")
            let externalOutput = fixtureRoot.appendingPathComponent("external-output")
            let externalAppSentinel =
                externalOutput
                .appendingPathComponent("claudi0.app/Contents/Info.plist")
            let sentinel = Data("external-app-must-survive".utf8)

            try? fileManager.createDirectory(at: scripts, withIntermediateDirectories: true)
            try? fileManager.copyItem(
                at: sourceRoot.appendingPathComponent("scripts/dev-bundle.sh"),
                to: devBundle)
            let sourceHelper =
                sourceRoot
                .appendingPathComponent("scripts/pinned-output-directory.sh")
            if fileManager.fileExists(atPath: sourceHelper.path) {
                try? fileManager.copyItem(at: sourceHelper, to: pinnedHelper)
            }
            writeFixture(sentinel, to: externalAppSentinel)
            createSymlink(
                at: repository.appendingPathComponent("dist"),
                pointingTo: externalOutput)

            let result = runTestProcess(
                executableURL: URL(fileURLWithPath: "/bin/bash"),
                arguments: [devBundle.path],
                currentDirectoryURL: repository)
            expect(
                result.status == 1
                    && result.output.contains("output directory must not be a symbolic link"),
                "dev-bundle 必须在清旧 app 前拒绝 dist symlink：\(result.output)")
            expect(
                (try? Data(contentsOf: externalAppSentinel)) == sentinel,
                "dev-bundle 拒绝 dist symlink 时不得删除仓库外 app")
        }
    }

    suite("dev-bundle：进入 dist 后替换父路径仍不写仓库外 app") {
        withTempDirectory { fixtureRoot in
            let fileManager = FileManager.default
            let sourceRoot = guiTestRepositoryRoot()
            let repository = fixtureRoot.appendingPathComponent("repository")
            let scripts = repository.appendingPathComponent("scripts")
            let fakeBin = fixtureRoot.appendingPathComponent("fake-bin")
            let guiBin = fixtureRoot.appendingPathComponent("gui-bin")
            let helperBin = fixtureRoot.appendingPathComponent("helper-bin")
            let externalOutput = fixtureRoot.appendingPathComponent("external-output")
            let externalAppSentinel =
                externalOutput
                .appendingPathComponent("claudi0.app/Contents/Info.plist")
            let movedAppInfo =
                repository
                .appendingPathComponent("original-dist/claudi0.app/Contents/Info.plist")
            let swapMarker = fixtureRoot.appendingPathComponent("did-swap-output")
            let sentinel = Data("external-app-must-survive-late-swap".utf8)

            try? fileManager.createDirectory(at: scripts, withIntermediateDirectories: true)
            try? fileManager.createDirectory(at: fakeBin, withIntermediateDirectories: true)
            try? fileManager.createDirectory(at: guiBin, withIntermediateDirectories: true)
            try? fileManager.createDirectory(at: helperBin, withIntermediateDirectories: true)
            try? fileManager.createDirectory(
                at: guiBin.appendingPathComponent("Fixture_ClaudioGUI.bundle"),
                withIntermediateDirectories: true)
            try? fileManager.createDirectory(
                at: guiBin.appendingPathComponent("Fixture_ClaudioLocalization.bundle"),
                withIntermediateDirectories: true)
            try? fileManager.createDirectory(
                at: repository.appendingPathComponent("packs"),
                withIntermediateDirectories: true)
            try? fileManager.copyItem(
                at: sourceRoot.appendingPathComponent("scripts/dev-bundle.sh"),
                to: scripts.appendingPathComponent("dev-bundle.sh"))
            try? fileManager.copyItem(
                at: sourceRoot.appendingPathComponent("scripts/pinned-output-directory.sh"),
                to: scripts.appendingPathComponent("pinned-output-directory.sh"))

            writeFixture("gui-binary", to: guiBin.appendingPathComponent("ClaudioGUI"))
            writeFixture(
                "#!/bin/bash\necho 0.0.0-dev\n", to: helperBin.appendingPathComponent("claudio"))
            writeFixture(
                "#!/bin/bash\nexit 0\n",
                to: scripts.appendingPathComponent(
                    "copy-bundled-packs.sh"))
            writeFixture(
                "#!/bin/bash\nexit 0\n",
                to: scripts.appendingPathComponent(
                    "check-release-size.sh"))
            writeFixture(
                Data("fixture-icon".utf8),
                to: repository.appendingPathComponent("assets/branding/claudi0.icns"))
            writeFixture(sentinel, to: externalAppSentinel)
            writeFixture(
                #"""
                #!/bin/bash
                if [[ ! -e "$SWAP_MARKER" ]]; then
                    /bin/mv "$FIXTURE_REPOSITORY/dist" \
                        "$FIXTURE_REPOSITORY/original-dist"
                    /bin/ln -s "$EXTERNAL_OUTPUT" "$FIXTURE_REPOSITORY/dist"
                    : > "$SWAP_MARKER"
                fi
                if [[ " $* " == *" --show-bin-path "* ]]; then
                    if [[ " $* " == *" --product ClaudioGUI "* ]]; then
                        echo "$GUI_BIN"
                    else
                        echo "$HELPER_BIN"
                    fi
                fi
                exit 0
                """#,
                to: fakeBin.appendingPathComponent("swift"))
            writeFixture("#!/bin/bash\nexit 0\n", to: fakeBin.appendingPathComponent("strip"))
            writeFixture(
                "#!/bin/bash\nexit 0\n", to: fakeBin.appendingPathComponent("codesign"))
            writeFixture(
                "#!/bin/bash\necho arm64\n",
                to: fakeBin.appendingPathComponent(
                    "uname"))

            let executableFixtures = [
                scripts.appendingPathComponent("dev-bundle.sh"),
                scripts.appendingPathComponent("copy-bundled-packs.sh"),
                scripts.appendingPathComponent("check-release-size.sh"),
                helperBin.appendingPathComponent("claudio"),
                fakeBin.appendingPathComponent("swift"),
                fakeBin.appendingPathComponent("strip"),
                fakeBin.appendingPathComponent("codesign"),
                fakeBin.appendingPathComponent("uname"),
            ]
            for fixture in executableFixtures {
                try? fileManager.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: fixture.path)
            }

            let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            let result = runTestProcess(
                executableURL: URL(fileURLWithPath: "/bin/bash"),
                arguments: [scripts.appendingPathComponent("dev-bundle.sh").path],
                currentDirectoryURL: repository,
                environmentOverrides: [
                    "EXTERNAL_OUTPUT": externalOutput.path,
                    "FIXTURE_REPOSITORY": repository.path,
                    "GUI_BIN": guiBin.path,
                    "HELPER_BIN": helperBin.path,
                    "PATH": "\(fakeBin.path):\(inheritedPath)",
                    "SWAP_MARKER": swapMarker.path,
                ])
            expect(
                result.status == 1
                    && result.output.contains("output directory changed after validation"),
                "真实 dev-bundle 的验证后路径替换必须失败关闭：\(result.output)")
            expect(
                fileManager.fileExists(atPath: movedAppInfo.path),
                "真实 dev-bundle 必须把组装操作留在进入时钉住的原目录")
            expect(
                (try? Data(contentsOf: externalAppSentinel)) == sentinel,
                "真实 dev-bundle 不得把验证后的路径替换重定向到仓库外 app")
        }
    }

    suite("本机 pre-RC：贡献者文档只把报告描述为 pre-RC 证据") {
        let root = guiTestRepositoryRoot()
        let contributorURL = root.appendingPathComponent("docs/CONTRIBUTING.md")
        let distributionURL = root.appendingPathComponent("docs/distribution.md")
        guard let contributor = try? String(contentsOf: contributorURL, encoding: .utf8),
            let distribution = try? String(contentsOf: distributionURL, encoding: .utf8)
        else {
            expect(false, "读不到贡献者或分发文档")
            return
        }

        for source in [contributor, distribution] {
            expect(
                source.contains("bash scripts/local-pre-rc.sh")
                    && source.contains("dist/local-pre-rc-report.json"),
                "贡献者与分发文档都必须给出本机 pre-RC 入口和报告路径")
        }
        expect(
            distribution.contains("clean checkout")
                && distribution.contains("pre_rc_only")
                && distribution.contains("Developer ID")
                && distribution.contains("notarization")
                && distribution.contains("Gatekeeper")
                && distribution.contains("DMG checksum")
                && distribution.contains("Intel 真机"),
            "分发文档必须明确 clean HEAD 与全部正式证据边界")
    }
}
