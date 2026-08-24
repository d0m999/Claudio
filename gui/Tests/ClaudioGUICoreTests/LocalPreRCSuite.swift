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
            "bash scripts/check-release-size.sh dist/claudi0.app",
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

        let staleRemoval = script.range(of: #"rm -f -- "$report_path""#)
        let toolPreflight = script.range(of: "for required_tool in")
        let staleRemovalIndex = staleRemoval?.lowerBound ?? script.endIndex
        let toolPreflightIndex = toolPreflight?.lowerBound ?? script.startIndex
        expect(
            staleRemovalIndex < toolPreflightIndex,
            "任何工具、合同或 HEAD 预检失败前都必须先删除旧成功报告")
        guard let reportMove = script.range(of: #"mv -f -- "$temporary_report" "$report_path""#),
            let finalIdentityCheck = script.range(
                of: #"assert_checkout_identity "$expected_commit""#,
                range: reportMove.upperBound..<script.endIndex)
        else {
            expect(false, "报告发布后必须再次复验 checkout identity")
            return
        }
        expect(
            finalIdentityCheck.lowerBound > reportMove.lowerBound
                && script.contains(#"rm -f -- "$report_path""#)
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
