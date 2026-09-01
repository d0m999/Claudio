import Foundation

private func runReleaseSignatureVerifier(
    kind: String,
    artifact: URL,
    teamID: String,
    fakeCodesign: URL,
    signatureDetails: String,
    verifyStatus: Int = 0
) -> TestProcessResult {
    runTestProcess(
        executableURL: URL(fileURLWithPath: "/bin/bash"),
        arguments: [
            guiTestRepositoryRoot().appendingPathComponent(
                "scripts/verify-release-signature.sh"
            ).path,
            kind,
            teamID,
            artifact.path,
        ],
        environmentOverrides: [
            "CLAUDIO_CODESIGN_BIN": fakeCodesign.path,
            "FAKE_CODESIGN_ARTIFACT_KIND": kind,
            "FAKE_CODESIGN_ARTIFACT": artifact.path,
            "FAKE_CODESIGN_DETAILS": signatureDetails,
            "FAKE_CODESIGN_VERIFY_STATUS": String(verifyStatus),
        ])
}

private func runDevBundleSignatureVerifier(
    app: URL,
    fakeCodesign: URL,
    entitlements: String,
    inspectStatus: Int = 0,
    verifyStatus: Int = 0
) -> TestProcessResult {
    runTestProcess(
        executableURL: URL(fileURLWithPath: "/bin/bash"),
        arguments: [
            guiTestRepositoryRoot().appendingPathComponent(
                "scripts/verify-dev-bundle-signature.sh"
            ).path,
            app.path,
        ],
        environmentOverrides: [
            "CLAUDIO_CODESIGN_BIN": fakeCodesign.path,
            "FAKE_CODESIGN_ARTIFACT": app.path,
            "FAKE_CODESIGN_ENTITLEMENTS": entitlements,
            "FAKE_CODESIGN_INSPECT_STATUS": String(inspectStatus),
            "FAKE_CODESIGN_VERIFY_STATUS": String(verifyStatus),
        ])
}

@MainActor
func runReleaseSignatureSuites() {
    suite("dev bundle signature verifier 拒绝 entitlement 与不可验证产物") {
        withTempDirectory { root in
            let fakeCodesign = root.appendingPathComponent("fake-codesign.sh")
            writeFixture(
                #"""
                #!/usr/bin/env bash
                set -euo pipefail
                if [[ "$1" == "-d" ]]; then
                    [[ "$#" -eq 4 && "$2" == "--entitlements" && "$3" == ":-" \
                        && "$4" == "$FAKE_CODESIGN_ARTIFACT" ]]
                    printf '%s' "$FAKE_CODESIGN_ENTITLEMENTS"
                    exit "$FAKE_CODESIGN_INSPECT_STATUS"
                fi
                [[ "$#" -eq 5 && "$1" == "--verify" && "$2" == "--deep" \
                    && "$3" == "--strict" && "$4" == "--verbose=2" \
                    && "$5" == "$FAKE_CODESIGN_ARTIFACT" ]]
                exit "$FAKE_CODESIGN_VERIFY_STATUS"
                """#,
                to: fakeCodesign)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: fakeCodesign.path)

            let app = root.appendingPathComponent("claudi0.app", isDirectory: true)
            try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

            let valid = runDevBundleSignatureVerifier(
                app: app, fakeCodesign: fakeCodesign, entitlements: "")
            expect(valid.status == 0, "无 entitlement 且严格签名有效的开发 app 必须通过")

            let restricted = runDevBundleSignatureVerifier(
                app: app,
                fakeCodesign: fakeCodesign,
                entitlements: "com.apple.developer.usernotifications.communication")
            expect(
                restricted.status != 0
                    && restricted.output.contains("must not contain entitlements"),
                "任意 entitlement 都必须让开发 app 失败关闭：\(restricted.output)")

            let inspectionFailure = runDevBundleSignatureVerifier(
                app: app, fakeCodesign: fakeCodesign, entitlements: "", inspectStatus: 1)
            expect(inspectionFailure.status != 0, "无法读取 entitlement payload 时必须失败关闭")

            let verificationFailure = runDevBundleSignatureVerifier(
                app: app, fakeCodesign: fakeCodesign, entitlements: "", verifyStatus: 1)
            expect(verificationFailure.status != 0, "严格 codesign 验证失败时必须失败关闭")
        }
    }

    suite("release signature verifier 统一核对 authority、team、runtime 与 timestamp") {
        withTempDirectory { root in
            let fakeCodesign = root.appendingPathComponent("fake-codesign.sh")
            writeFixture(
                """
                #!/usr/bin/env bash
                set -euo pipefail
                if [[ "$1" == "-d" ]]; then
                    [[ "$#" -eq 3 && "$2" == "--verbose=4" \
                        && "$3" == "$FAKE_CODESIGN_ARTIFACT" ]]
                    printf '%s\n' "$FAKE_CODESIGN_DETAILS" >&2
                    exit 0
                fi
                case "$FAKE_CODESIGN_ARTIFACT_KIND" in
                    executable)
                        [[ "$#" -eq 4 && "$1" == "--verify" && "$2" == "--strict" \
                            && "$3" == "--verbose=2" && "$4" == "$FAKE_CODESIGN_ARTIFACT" ]]
                        ;;
                    app)
                        [[ "$#" -eq 5 && "$1" == "--verify" && "$2" == "--deep" \
                            && "$3" == "--strict" && "$4" == "--verbose=2" \
                            && "$5" == "$FAKE_CODESIGN_ARTIFACT" ]]
                        ;;
                    dmg)
                        [[ "$#" -eq 3 && "$1" == "--verify" && "$2" == "--verbose=2" \
                            && "$3" == "$FAKE_CODESIGN_ARTIFACT" ]]
                        ;;
                    *) exit 64 ;;
                esac
                exit "$FAKE_CODESIGN_VERIFY_STATUS"
                """,
                to: fakeCodesign)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: fakeCodesign.path)

            let executable = root.appendingPathComponent("claudi0")
            let dmg = root.appendingPathComponent("claudi0-0.1.0.dmg")
            let app = root.appendingPathComponent("claudi0.app", isDirectory: true)
            writeFixture(Data("executable".utf8), to: executable)
            writeFixture(Data("dmg".utf8), to: dmg)
            try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

            let teamID = "ABCDE12345"
            let executableDetails = """
                Authority=Developer ID Application: Claudio Fixture (ABCDE12345)
                TeamIdentifier=ABCDE12345
                Timestamp=Aug 24, 2026 at 12:00:00
                flags=0x10000(runtime)
                """
            let validExecutable = runReleaseSignatureVerifier(
                kind: "executable",
                artifact: executable,
                teamID: teamID,
                fakeCodesign: fakeCodesign,
                signatureDetails: executableDetails)
            expect(
                validExecutable.status == 0,
                "完整 Developer ID executable 应通过统一 verifier：\(validExecutable.output)")

            let validApp = runReleaseSignatureVerifier(
                kind: "app",
                artifact: app,
                teamID: teamID,
                fakeCodesign: fakeCodesign,
                signatureDetails: executableDetails)
            expect(validApp.status == 0, "完整 Developer ID app 应通过统一 verifier")

            let executableAlias = root.appendingPathComponent("claudio")
            try? FileManager.default.createSymbolicLink(
                at: executableAlias, withDestinationURL: executable)
            let symlinkExecutable = runReleaseSignatureVerifier(
                kind: "executable",
                artifact: executableAlias,
                teamID: teamID,
                fakeCodesign: fakeCodesign,
                signatureDetails: executableDetails)
            expect(
                symlinkExecutable.status != 0,
                "共享 verifier 必须拒绝 symlink；workflow 应先精确核对 alias 再验证真实 Mach-O")

            let wrongTeam = runReleaseSignatureVerifier(
                kind: "executable",
                artifact: executable,
                teamID: "ZZZZZ99999",
                fakeCodesign: fakeCodesign,
                signatureDetails: executableDetails)
            expect(wrongTeam.status != 0, "错误 Developer ID team 必须失败关闭")

            let missingRuntime = runReleaseSignatureVerifier(
                kind: "executable",
                artifact: executable,
                teamID: teamID,
                fakeCodesign: fakeCodesign,
                signatureDetails: executableDetails.replacingOccurrences(
                    of: "flags=0x10000(runtime)", with: "flags=0x0(none)"))
            expect(missingRuntime.status != 0, "executable 缺少 hardened runtime 必须失败关闭")

            let missingAuthority = runReleaseSignatureVerifier(
                kind: "executable",
                artifact: executable,
                teamID: teamID,
                fakeCodesign: fakeCodesign,
                signatureDetails: executableDetails.replacingOccurrences(
                    of: "Authority=Developer ID Application: Claudio Fixture (ABCDE12345)\n",
                    with: ""))
            expect(missingAuthority.status != 0, "缺少 Developer ID Application authority 必须失败关闭")

            let missingTimestamp = runReleaseSignatureVerifier(
                kind: "app",
                artifact: app,
                teamID: teamID,
                fakeCodesign: fakeCodesign,
                signatureDetails: executableDetails.replacingOccurrences(
                    of: "Timestamp=Aug 24, 2026 at 12:00:00\n", with: ""))
            expect(missingTimestamp.status != 0, "app 缺少 secure timestamp 必须失败关闭")

            let disabledTimestamp = runReleaseSignatureVerifier(
                kind: "app",
                artifact: app,
                teamID: teamID,
                fakeCodesign: fakeCodesign,
                signatureDetails: executableDetails.replacingOccurrences(
                    of: "Timestamp=Aug 24, 2026 at 12:00:00",
                    with: "Timestamp=none"))
            expect(disabledTimestamp.status != 0, "显式 Timestamp=none 必须失败关闭")

            let dmgDetails = """
                Authority=Developer ID Application: Claudio Fixture (ABCDE12345)
                TeamIdentifier=ABCDE12345
                Timestamp=Aug 24, 2026 at 12:00:00
                """
            let validDMG = runReleaseSignatureVerifier(
                kind: "dmg",
                artifact: dmg,
                teamID: teamID,
                fakeCodesign: fakeCodesign,
                signatureDetails: dmgDetails)
            expect(validDMG.status == 0, "DMG 不要求 runtime flag，但必须通过其余签名门禁")

            let invalidSignature = runReleaseSignatureVerifier(
                kind: "dmg",
                artifact: dmg,
                teamID: teamID,
                fakeCodesign: fakeCodesign,
                signatureDetails: dmgDetails,
                verifyStatus: 1)
            expect(invalidSignature.status != 0, "codesign verify 失败必须原样失败关闭")
        }
    }
}
