import CryptoKit
import Foundation

private struct ReleaseCandidateIdentity {
    let runID: String
    let runURL: String
    let artifactName: String
    let commitSHA: String
    let version: String

    var dmgName: String { "claudi0-\(version).dmg" }
}

private func runReleaseCandidateVerifier(
    artifactDirectory: URL,
    identity: ReleaseCandidateIdentity,
    environmentOverrides: [String: String] = [:]
) -> TestProcessResult {
    runTestProcess(
        executableURL: URL(fileURLWithPath: "/bin/bash"),
        arguments: [
            guiTestRepositoryRoot().appendingPathComponent(
                "scripts/verify-release-candidate.sh"
            ).path,
            "--artifact-dir", artifactDirectory.path,
            "--run-id", identity.runID,
            "--run-url", identity.runURL,
            "--artifact-name", identity.artifactName,
            "--commit-sha", identity.commitSHA,
            "--version", identity.version,
        ],
        environmentOverrides: environmentOverrides)
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func createZipArchive(from directory: URL, at archive: URL) -> Bool {
    runTestProcess(
        executableURL: URL(fileURLWithPath: "/usr/bin/zip"),
        arguments: ["-q", "-r", archive.path, "."],
        currentDirectoryURL: directory
    ).status == 0
}

private func fakeGitHubEnvironment(
    executable: URL,
    identity: ReleaseCandidateIdentity,
    archiveDigest: String,
    archive: URL,
    headSHA: String? = nil
) -> [String: String] {
    [
        "CLAUDIO_GH_BIN": executable.path,
        "FAKE_GH_HEAD_SHA": headSHA ?? identity.commitSHA,
        "FAKE_GH_RUN_URL": identity.runURL,
        "FAKE_GH_ARTIFACT_NAME": identity.artifactName,
        "FAKE_GH_ARTIFACT_DIGEST": archiveDigest,
        "FAKE_GH_ARCHIVE_PATH": archive.path,
    ]
}

@MainActor
func runReleaseCandidateArtifactSuites() {
    suite("下载的 RC artifact 必须与 run、artifact、commit、版本、DMG 和 SHA-256 同时匹配") {
        withTempDirectory { root in
            let artifactDirectory = root.appendingPathComponent("artifact", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: artifactDirectory, withIntermediateDirectories: true)
            let commitSHA = String(repeating: "a", count: 40)
            let runID = "123456789"
            let identity = ReleaseCandidateIdentity(
                runID: runID,
                runURL: "https://github.com/d0m999/Claudio/actions/runs/\(runID)",
                artifactName: "claudi0-rc-\(commitSHA)",
                commitSHA: commitSHA,
                version: "0.1.0")
            let dmgData = Data("signed-notarized-rc-fixture".utf8)
            let dmgSHA256 = sha256Hex(dmgData)
            let fakeGH = root.appendingPathComponent("fake-gh.sh")

            writeFixture(
                """
                #!/usr/bin/env bash
                set -euo pipefail
                if [[ "$1" == "run" ]]; then
                    printf '%s' '{"conclusion":"success","event":"workflow_dispatch",'
                    printf '"headSha":"%s","url":"%s","workflowName":"Release"}\n' \
                        "$FAKE_GH_HEAD_SHA" "$FAKE_GH_RUN_URL"
                elif [[ "$1" == "api" && "$2" == */zip ]]; then
                    cat "$FAKE_GH_ARCHIVE_PATH"
                elif [[ "$1" == "api" ]]; then
                    printf '%s' '{"artifacts":[{'
                    printf '"digest":"sha256:%s","expired":false,"id":42,' \
                        "$FAKE_GH_ARTIFACT_DIGEST"
                    printf '"name":"%s","workflow_run":{"head_sha":"%s"}}]}\n' \
                        "$FAKE_GH_ARTIFACT_NAME" "$FAKE_GH_HEAD_SHA"
                else
                    exit 64
                fi
                """,
                to: fakeGH)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: fakeGH.path)

            writeFixture(dmgData, to: artifactDirectory.appendingPathComponent(identity.dmgName))
            writeFixture(
                "\(dmgSHA256)  \(identity.dmgName)\n",
                to: artifactDirectory.appendingPathComponent("SHA256SUMS.txt"))
            writeFixture(
                """
                {
                  "schema": 1,
                  "workflow_name": "Release",
                  "workflow_event": "workflow_dispatch",
                  "workflow_run_id": "\(identity.runID)",
                  "workflow_run_url": "\(identity.runURL)",
                  "artifact_name": "\(identity.artifactName)",
                  "commit_sha": "\(identity.commitSHA)",
                  "version": "\(identity.version)",
                  "dmg_name": "\(identity.dmgName)",
                  "dmg_sha256": "\(dmgSHA256)",
                  "authorization_attested": true
                }
                """,
                to: artifactDirectory.appendingPathComponent("RC_MANIFEST.json"))
            let officialArchive = root.appendingPathComponent("official-artifact.zip")
            guard createZipArchive(from: artifactDirectory, at: officialArchive),
                let officialArchiveData = try? Data(contentsOf: officialArchive)
            else {
                expect(false, "无法创建 GitHub artifact ZIP fixture")
                return
            }
            let officialArchiveDigest = sha256Hex(officialArchiveData)

            let result = runReleaseCandidateVerifier(
                artifactDirectory: artifactDirectory,
                identity: identity,
                environmentOverrides: fakeGitHubEnvironment(
                    executable: fakeGH,
                    identity: identity,
                    archiveDigest: officialArchiveDigest,
                    archive: officialArchive))

            expect(
                result.status == 0 && result.output.contains("verified RC artifact"),
                "完整匹配的下载 artifact 应通过复验，实得 status=\(result.status): \(result.output)")

            let mismatchedArchiveDigest = runReleaseCandidateVerifier(
                artifactDirectory: artifactDirectory,
                identity: identity,
                environmentOverrides: fakeGitHubEnvironment(
                    executable: fakeGH,
                    identity: identity,
                    archiveDigest: String(repeating: "b", count: 64),
                    archive: officialArchive))
            expect(
                mismatchedArchiveDigest.status != 0,
                "GitHub artifact archive 的官方 digest 与下载 archive 不一致时必须失败关闭")

            let mismatchedRun = runReleaseCandidateVerifier(
                artifactDirectory: artifactDirectory,
                identity: identity,
                environmentOverrides: fakeGitHubEnvironment(
                    executable: fakeGH,
                    identity: identity,
                    archiveDigest: officialArchiveDigest,
                    archive: officialArchive,
                    headSHA: String(repeating: "b", count: 40)))
            expect(
                mismatchedRun.status != 0,
                "GitHub run 的 head SHA 与账本目标不一致时必须失败关闭")

            writeFixture(
                Data("tampered-after-download".utf8),
                to: artifactDirectory.appendingPathComponent(identity.dmgName))
            let tamperedDownload = runReleaseCandidateVerifier(
                artifactDirectory: artifactDirectory,
                identity: identity,
                environmentOverrides: fakeGitHubEnvironment(
                    executable: fakeGH,
                    identity: identity,
                    archiveDigest: officialArchiveDigest,
                    archive: officialArchive))
            expect(
                tamperedDownload.status != 0,
                "下载后 DMG 字节与 manifest/checksum 不一致时必须失败关闭")
        }
    }
}
