import CryptoKit
import Foundation

private struct ReleaseCandidateIdentity {
    let runID: String
    let runURL: String
    let artifactName: String
    let commitSHA: String
    let version: String
    let workflowID: String
    let workflowPath: String
    let workflowRef: String

    var dmgName: String { "claudi0-\(version).dmg" }
}

private func runReleaseCandidateVerifier(
    artifactDirectory: URL,
    ledger: URL,
    environmentOverrides: [String: String] = [:]
) -> TestProcessResult {
    runTestProcess(
        executableURL: URL(fileURLWithPath: "/bin/bash"),
        arguments: [
            guiTestRepositoryRoot().appendingPathComponent(
                "scripts/verify-release-candidate.sh"
            ).path,
            "--artifact-dir", artifactDirectory.path,
            "--ledger", ledger.path,
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
    headSHA: String? = nil,
    headBranch: String = "main",
    workflowID: String? = nil,
    workflowPath: String? = nil,
    workflowState: String = "active",
    artifactSize: Int? = nil
) -> [String: String] {
    let officialArchiveSize = (try? Data(contentsOf: archive).count) ?? 0
    return [
        "CLAUDIO_GH_BIN": executable.path,
        "FAKE_GH_HEAD_SHA": headSHA ?? identity.commitSHA,
        "FAKE_GH_HEAD_BRANCH": headBranch,
        "FAKE_GH_RUN_URL": identity.runURL,
        "FAKE_GH_WORKFLOW_ID": workflowID ?? identity.workflowID,
        "FAKE_GH_WORKFLOW_PATH": workflowPath ?? identity.workflowPath,
        "FAKE_GH_WORKFLOW_STATE": workflowState,
        "FAKE_GH_ARTIFACT_NAME": identity.artifactName,
        "FAKE_GH_ARTIFACT_DIGEST": archiveDigest,
        "FAKE_GH_ARTIFACT_SIZE": String(artifactSize ?? officialArchiveSize),
        "FAKE_GH_ARCHIVE_PATH": archive.path,
    ]
}

private func releaseAcceptanceLedger(
    identity: ReleaseCandidateIdentity,
    dmgSHA256: String
) -> String {
    """
    # RC acceptance ledger fixture

    | 字段 | 结果 |
    |---|---|
    | RC version | `\(identity.version)` |
    | Release workflow path | `\(identity.workflowPath)` |
    | Release workflow ID | `\(identity.workflowID)` |
    | Workflow ref | `\(identity.workflowRef)` |
    | Workflow inputs | `{"version":"\(identity.version)","target_commit":"\(identity.commitSHA)","release_authorized":true}` |
    | Commit SHA | `\(identity.commitSHA)` |
    | GitHub Actions run URL | `\(identity.runURL)` |
    | GitHub Actions run ID | `\(identity.runID)` |
    | Actions artifact 名称 | `\(identity.artifactName)` |
    | DMG 文件名 | `\(identity.dmgName)` |
    | DMG SHA-256 | `\(dmgSHA256)` |
    """
}

private func releaseCandidateManifest(
    identity: ReleaseCandidateIdentity,
    dmgSHA256: String,
    workflowRef: String? = nil
) -> String {
    """
    {
      "schema": 2,
      "workflow_name": "Release",
      "workflow_path": "\(identity.workflowPath)",
      "workflow_event": "workflow_dispatch",
      "workflow_ref": "\(workflowRef ?? identity.workflowRef)",
      "workflow_run_id": "\(identity.runID)",
      "workflow_run_url": "\(identity.runURL)",
      "artifact_name": "\(identity.artifactName)",
      "target_commit": "\(identity.commitSHA)",
      "commit_sha": "\(identity.commitSHA)",
      "version": "\(identity.version)",
      "dmg_name": "\(identity.dmgName)",
      "dmg_sha256": "\(dmgSHA256)",
      "authorization_attested": true
    }
    """
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
                version: "0.1.0",
                workflowID: "310455860",
                workflowPath: ".github/workflows/release.yml",
                workflowRef: "refs/heads/main")
            let dmgData = Data("signed-notarized-rc-fixture".utf8)
            let dmgSHA256 = sha256Hex(dmgData)
            let fakeGH = root.appendingPathComponent("fake-gh.sh")
            let ledger = root.appendingPathComponent("release-acceptance.md")

            writeFixture(
                """
                #!/usr/bin/env bash
                set -euo pipefail
                if [[ "$1" == "run" ]]; then
                    printf '%s' '{"conclusion":"success","event":"workflow_dispatch",'
                    printf '"headBranch":"%s","headSha":"%s",' \
                        "$FAKE_GH_HEAD_BRANCH" "$FAKE_GH_HEAD_SHA"
                    printf '"url":"%s","workflowDatabaseId":%s,"workflowName":"Release"}\n' \
                        "$FAKE_GH_RUN_URL" "$FAKE_GH_WORKFLOW_ID"
                elif [[ "$1" == "api" && "$2" == */zip ]]; then
                    cat "$FAKE_GH_ARCHIVE_PATH"
                elif [[ "$1" == "api" && "$2" == */actions/workflows/* ]]; then
                    printf '{"id":%s,"name":"Release","path":"%s","state":"%s"}\n' \
                        "$FAKE_GH_WORKFLOW_ID" "$FAKE_GH_WORKFLOW_PATH" \
                        "$FAKE_GH_WORKFLOW_STATE"
                elif [[ "$1" == "api" ]]; then
                    printf '%s' '{"artifacts":[{'
                    printf '"digest":"sha256:%s","expired":false,"id":42,"size_in_bytes":%s,' \
                        "$FAKE_GH_ARTIFACT_DIGEST" "$FAKE_GH_ARTIFACT_SIZE"
                    printf '"name":"%s","workflow_run":{"head_sha":"%s"}}]}\n' \
                        "$FAKE_GH_ARTIFACT_NAME" "$FAKE_GH_HEAD_SHA"
                else
                    exit 64
                fi
                """,
                to: fakeGH)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: fakeGH.path)

            let validLedger = releaseAcceptanceLedger(
                identity: identity, dmgSHA256: dmgSHA256)
            writeFixture(validLedger, to: ledger)

            writeFixture(dmgData, to: artifactDirectory.appendingPathComponent(identity.dmgName))
            writeFixture(
                "\(dmgSHA256)  \(identity.dmgName)\n",
                to: artifactDirectory.appendingPathComponent("SHA256SUMS.txt"))
            let manifest = artifactDirectory.appendingPathComponent("RC_MANIFEST.json")
            let validManifest = releaseCandidateManifest(
                identity: identity, dmgSHA256: dmgSHA256)
            writeFixture(validManifest, to: manifest)
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
                ledger: ledger,
                environmentOverrides: fakeGitHubEnvironment(
                    executable: fakeGH,
                    identity: identity,
                    archiveDigest: officialArchiveDigest,
                    archive: officialArchive))

            expect(
                result.status == 0 && result.output.contains("verified RC artifact"),
                "完整匹配的下载 artifact 应通过复验，实得 status=\(result.status): \(result.output)")

            let missingLedger = runReleaseCandidateVerifier(
                artifactDirectory: artifactDirectory,
                ledger: root.appendingPathComponent("missing-ledger.md"),
                environmentOverrides: fakeGitHubEnvironment(
                    executable: fakeGH,
                    identity: identity,
                    archiveDigest: officialArchiveDigest,
                    archive: officialArchive))
            expect(missingLedger.status != 0, "缺失的唯一验收账本必须在 GitHub 查询前失败关闭")

            let oversizedArtifact = runReleaseCandidateVerifier(
                artifactDirectory: artifactDirectory,
                ledger: ledger,
                environmentOverrides: fakeGitHubEnvironment(
                    executable: fakeGH,
                    identity: identity,
                    archiveDigest: officialArchiveDigest,
                    archive: officialArchive,
                    artifactSize: 26_214_401))
            expect(
                oversizedArtifact.status != 0
                    && oversizedArtifact.output.contains("25 MiB"),
                "GitHub API 声明超过 25 MiB 的 RC artifact 必须在下载前失败关闭")

            let mismatchedArchiveDigest = runReleaseCandidateVerifier(
                artifactDirectory: artifactDirectory,
                ledger: ledger,
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
                ledger: ledger,
                environmentOverrides: fakeGitHubEnvironment(
                    executable: fakeGH,
                    identity: identity,
                    archiveDigest: officialArchiveDigest,
                    archive: officialArchive,
                    headSHA: String(repeating: "b", count: 40)))
            expect(
                mismatchedRun.status != 0,
                "GitHub run 的 head SHA 与账本目标不一致时必须失败关闭")

            let nonMainRun = runReleaseCandidateVerifier(
                artifactDirectory: artifactDirectory,
                ledger: ledger,
                environmentOverrides: fakeGitHubEnvironment(
                    executable: fakeGH,
                    identity: identity,
                    archiveDigest: officialArchiveDigest,
                    archive: officialArchive,
                    headBranch: "review/rc"))
            expect(nonMainRun.status != 0, "非 main 的自洽 workflow run 不能冒充账本 RC")

            let wrongWorkflowID = runReleaseCandidateVerifier(
                artifactDirectory: artifactDirectory,
                ledger: ledger,
                environmentOverrides: fakeGitHubEnvironment(
                    executable: fakeGH,
                    identity: identity,
                    archiveDigest: officialArchiveDigest,
                    archive: officialArchive,
                    workflowID: "999999999"))
            expect(
                wrongWorkflowID.status != 0,
                "同名但 database ID 不同的 workflow 不能冒充正式 Release workflow")

            let wrongWorkflowPath = runReleaseCandidateVerifier(
                artifactDirectory: artifactDirectory,
                ledger: ledger,
                environmentOverrides: fakeGitHubEnvironment(
                    executable: fakeGH,
                    identity: identity,
                    archiveDigest: officialArchiveDigest,
                    archive: officialArchive,
                    workflowPath: ".github/workflows/lookalike-release.yml"))
            expect(
                wrongWorkflowPath.status != 0,
                "database ID 自洽但 path 漂移的 workflow 必须失败关闭")

            let inactiveWorkflow = runReleaseCandidateVerifier(
                artifactDirectory: artifactDirectory,
                ledger: ledger,
                environmentOverrides: fakeGitHubEnvironment(
                    executable: fakeGH,
                    identity: identity,
                    archiveDigest: officialArchiveDigest,
                    archive: officialArchive,
                    workflowState: "disabled_manually"))
            expect(inactiveWorkflow.status != 0, "已禁用的正式 workflow 不能成为 RC identity")

            let placeholderLedger = root.appendingPathComponent("placeholder-ledger.md")
            writeFixture(
                validLedger.replacingOccurrences(
                    of: "| Commit SHA | `\(identity.commitSHA)` |",
                    with: "| Commit SHA | 待填 |"),
                to: placeholderLedger)
            let placeholderResult = runReleaseCandidateVerifier(
                artifactDirectory: artifactDirectory,
                ledger: placeholderLedger,
                environmentOverrides: fakeGitHubEnvironment(
                    executable: fakeGH,
                    identity: identity,
                    archiveDigest: officialArchiveDigest,
                    archive: officialArchive))
            expect(placeholderResult.status != 0, "账本待填占位不得成为 RC identity")

            let duplicateLedger = root.appendingPathComponent("duplicate-ledger.md")
            writeFixture(
                validLedger + "\n| Commit SHA | `\(identity.commitSHA)` |\n",
                to: duplicateLedger)
            let duplicateResult = runReleaseCandidateVerifier(
                artifactDirectory: artifactDirectory,
                ledger: duplicateLedger,
                environmentOverrides: fakeGitHubEnvironment(
                    executable: fakeGH,
                    identity: identity,
                    archiveDigest: officialArchiveDigest,
                    archive: officialArchive))
            expect(duplicateResult.status != 0, "重复账本字段必须失败关闭，不能任取一项")

            let unauthorizedLedger = root.appendingPathComponent("unauthorized-ledger.md")
            writeFixture(
                validLedger.replacingOccurrences(
                    of: #""release_authorized":true"#,
                    with: #""release_authorized":false"#),
                to: unauthorizedLedger)
            let unauthorizedResult = runReleaseCandidateVerifier(
                artifactDirectory: artifactDirectory,
                ledger: unauthorizedLedger,
                environmentOverrides: fakeGitHubEnvironment(
                    executable: fakeGH,
                    identity: identity,
                    archiveDigest: officialArchiveDigest,
                    archive: officialArchive))
            expect(
                unauthorizedResult.status != 0,
                "账本未记录 release authorization attestation 时必须失败关闭")

            let duplicateInputKeyLedger = root.appendingPathComponent(
                "duplicate-input-key-ledger.md")
            writeFixture(
                validLedger.replacingOccurrences(
                    of:
                        #"{"version":"0.1.0","target_commit":"\#(identity.commitSHA)","release_authorized":true}"#,
                    with:
                        #"{"version":"9.9.9","version":"0.1.0","target_commit":"\#(identity.commitSHA)","release_authorized":true}"#
                ),
                to: duplicateInputKeyLedger)
            let duplicateInputKeyResult = runReleaseCandidateVerifier(
                artifactDirectory: artifactDirectory,
                ledger: duplicateInputKeyLedger,
                environmentOverrides: fakeGitHubEnvironment(
                    executable: fakeGH,
                    identity: identity,
                    archiveDigest: officialArchiveDigest,
                    archive: officialArchive))
            expect(
                duplicateInputKeyResult.status != 0,
                "Workflow inputs 含重复 JSON key 时必须失败关闭，不能采用 jq last-wins")

            let oversizedLedger = root.appendingPathComponent("oversized-ledger.md")
            writeFixture(String(repeating: "x", count: 131_073), to: oversizedLedger)
            let oversizedResult = runReleaseCandidateVerifier(
                artifactDirectory: artifactDirectory,
                ledger: oversizedLedger,
                environmentOverrides: fakeGitHubEnvironment(
                    executable: fakeGH,
                    identity: identity,
                    archiveDigest: officialArchiveDigest,
                    archive: officialArchive))
            expect(oversizedResult.status != 0, "超过 128 KiB 的账本必须在解析前失败关闭")

            let ledgerSymlink = root.appendingPathComponent("ledger-symlink.md")
            try? FileManager.default.createSymbolicLink(
                at: ledgerSymlink, withDestinationURL: ledger)
            let symlinkResult = runReleaseCandidateVerifier(
                artifactDirectory: artifactDirectory,
                ledger: ledgerSymlink,
                environmentOverrides: fakeGitHubEnvironment(
                    executable: fakeGH,
                    identity: identity,
                    archiveDigest: officialArchiveDigest,
                    archive: officialArchive))
            expect(symlinkResult.status != 0, "symlink 账本不得成为验收身份源")

            writeFixture(
                releaseCandidateManifest(
                    identity: identity,
                    dmgSHA256: dmgSHA256,
                    workflowRef: "refs/heads/review"),
                to: manifest)
            let mismatchedManifestArchive = root.appendingPathComponent(
                "mismatched-manifest-artifact.zip")
            guard createZipArchive(from: artifactDirectory, at: mismatchedManifestArchive),
                let mismatchedManifestArchiveData = try? Data(
                    contentsOf: mismatchedManifestArchive)
            else {
                expect(false, "无法创建 manifest 漂移 artifact ZIP fixture")
                return
            }
            let mismatchedManifestResult = runReleaseCandidateVerifier(
                artifactDirectory: artifactDirectory,
                ledger: ledger,
                environmentOverrides: fakeGitHubEnvironment(
                    executable: fakeGH,
                    identity: identity,
                    archiveDigest: sha256Hex(mismatchedManifestArchiveData),
                    archive: mismatchedManifestArchive))
            expect(
                mismatchedManifestResult.status != 0,
                "artifact manifest 的 workflow dispatch identity 漂移时必须失败关闭")
            writeFixture(validManifest, to: manifest)

            writeFixture(String(repeating: "x", count: 131_073), to: manifest)
            let oversizedManifestArchive = root.appendingPathComponent(
                "oversized-manifest-artifact.zip")
            guard createZipArchive(from: artifactDirectory, at: oversizedManifestArchive),
                let oversizedManifestArchiveData = try? Data(
                    contentsOf: oversizedManifestArchive)
            else {
                expect(false, "无法创建 oversized manifest artifact ZIP fixture")
                return
            }
            let oversizedManifestResult = runReleaseCandidateVerifier(
                artifactDirectory: artifactDirectory,
                ledger: ledger,
                environmentOverrides: fakeGitHubEnvironment(
                    executable: fakeGH,
                    identity: identity,
                    archiveDigest: sha256Hex(oversizedManifestArchiveData),
                    archive: oversizedManifestArchive))
            expect(
                oversizedManifestResult.status != 0
                    && oversizedManifestResult.output.contains("128 KiB"),
                "超过 128 KiB 的 artifact manifest 必须在 jq 解析前由显式边界失败关闭")
            writeFixture(validManifest, to: manifest)

            writeFixture(
                Data("tampered-after-download".utf8),
                to: artifactDirectory.appendingPathComponent(identity.dmgName))
            let tamperedDownload = runReleaseCandidateVerifier(
                artifactDirectory: artifactDirectory,
                ledger: ledger,
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
