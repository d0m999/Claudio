import ClaudioCore
import Foundation

private struct AcceptanceCommitCommandRunner: CommandRunning {
    let results: [String: CommandRunResult]

    func run(
        executablePath: String, arguments: [String], timeout: TimeInterval
    ) -> CommandRunResult {
        guard executablePath == "/usr/bin/git" else { return .launchFailed }
        return results[arguments.joined(separator: " ")] ?? .launchFailed
    }
}

private actor AcceptanceProbeCounter {
    private(set) var calls = 0

    func recordCall() {
        calls += 1
    }
}

private enum AcceptanceProbeError: Error {
    case invoked
}

@MainActor
func runWorkBuddyAcceptancePreflightSuites() async {
    suite("WorkBuddy 只读 preflight：commit 身份只能绑定当前 HEAD") {
        let head = "0123456789abcdef0123456789abcdef01234567"
        let matchingRunner = AcceptanceCommitCommandRunner(results: [
            "rev-parse --verify HEAD^{commit}": .completed(exitCode: 0, stdout: "\(head)\n"),
            "rev-parse --verify 0123456^{commit}": .completed(exitCode: 0, stdout: "\(head)\n"),
            "rev-parse --verify \(head)^{commit}": .completed(exitCode: 0, stdout: "\(head)\n"),
        ])
        expect(
            (try? AcceptanceCommitIdentity.resolve(
                expected: nil, commandRunner: matchingRunner)) == head,
            "省略期望 SHA 时必须返回规范化的当前 HEAD")
        expect(
            (try? AcceptanceCommitIdentity.resolve(
                expected: "0123456", commandRunner: matchingRunner)) == head,
            "匹配当前 HEAD 的短 SHA 必须规范化为完整 SHA")
        expect(
            (try? AcceptanceCommitIdentity.resolve(
                expected: head, commandRunner: matchingRunner)) == head,
            "匹配当前 HEAD 的完整 SHA 必须保持规范化身份")

        do {
            _ = try AcceptanceCommitIdentity.resolve(
                expected: "not-a-sha",
                commandRunner: AcceptanceCommitCommandRunner(results: [:]))
            expect(false, "格式错误的 SHA 必须失败关闭")
        } catch {
            expect(
                error as? AcceptanceCommitIdentityError == .malformedExpected("not-a-sha"),
                "格式错误的 SHA 必须在 git 探针前返回 typed malformedExpected")
        }

        do {
            _ = try AcceptanceCommitIdentity.resolve(
                expected: nil,
                commandRunner: AcceptanceCommitCommandRunner(results: [
                    "rev-parse --verify HEAD^{commit}": .timedOut
                ]))
            expect(false, "HEAD 探针超时必须失败关闭")
        } catch {
            expect(
                error as? AcceptanceCommitIdentityError == .currentCommitUnavailable,
                "HEAD 探针超时必须返回 typed currentCommitUnavailable")
        }

        let nonexistentRunner = AcceptanceCommitCommandRunner(results: [
            "rev-parse --verify HEAD^{commit}": .completed(exitCode: 0, stdout: "\(head)\n"),
            "rev-parse --verify deadbeef^{commit}": .completed(exitCode: 128, stdout: ""),
        ])
        do {
            _ = try AcceptanceCommitIdentity.resolve(
                expected: "deadbeef", commandRunner: nonexistentRunner)
            expect(false, "不存在的 SHA 必须失败关闭")
        } catch {
            expect(
                error as? AcceptanceCommitIdentityError
                    == .expectedCommitUnavailable("deadbeef"),
                "不存在的 SHA 必须返回 typed expectedCommitUnavailable")
        }

        let failedExpectedProbe = AcceptanceCommitCommandRunner(results: [
            "rev-parse --verify HEAD^{commit}": .completed(exitCode: 0, stdout: "\(head)\n"),
            "rev-parse --verify abcdef0^{commit}": .launchFailed,
        ])
        do {
            _ = try AcceptanceCommitIdentity.resolve(
                expected: "abcdef0", commandRunner: failedExpectedProbe)
            expect(false, "期望 commit 探针启动失败必须失败关闭")
        } catch {
            expect(
                error as? AcceptanceCommitIdentityError
                    == .expectedCommitUnavailable("abcdef0"),
                "期望 commit 探针启动失败必须返回 typed unavailable")
        }

        let other = "fedcba9876543210fedcba9876543210fedcba98"
        let mismatchedRunner = AcceptanceCommitCommandRunner(results: [
            "rev-parse --verify HEAD^{commit}": .completed(exitCode: 0, stdout: "\(head)\n"),
            "rev-parse --verify fedcba9^{commit}": .completed(exitCode: 0, stdout: "\(other)\n"),
        ])
        do {
            _ = try AcceptanceCommitIdentity.resolve(
                expected: "fedcba9", commandRunner: mismatchedRunner)
            expect(false, "非当前 commit 必须失败关闭")
        } catch {
            expect(
                error as? AcceptanceCommitIdentityError
                    == .expectedCommitMismatch(expected: other, current: head),
                "非当前 commit 必须返回规范化的 typed mismatch")
        }
    }

    await asyncSuite("WorkBuddy 只读 preflight：commit gate 必须先于宿主事实采集") {
        let head = "0123456789abcdef0123456789abcdef01234567"
        let counter = AcceptanceProbeCounter()
        let runner = AcceptanceCommitCommandRunner(results: [
            "rev-parse --verify HEAD^{commit}": .completed(exitCode: 0, stdout: "\(head)\n"),
            "rev-parse --verify deadbeef^{commit}": .completed(exitCode: 128, stdout: ""),
        ])
        do {
            _ = try await WorkBuddyAcceptancePreflightCollector.collect(
                expectedCommitSHA: "deadbeef", commandRunner: runner
            ) {
                await counter.recordCall()
                throw AcceptanceProbeError.invoked
            }
            expect(false, "不存在的 SHA 必须阻止 preflight")
        } catch {
            expect(
                error as? AcceptanceCommitIdentityError
                    == .expectedCommitUnavailable("deadbeef"),
                "collector 必须先返回 commit 身份错误")
        }
        let calls = await counter.calls
        expect(calls == 0, "commit 校验失败时宿主事实采集必须保持零调用")
    }

    suite("WorkBuddy 只读 preflight：记录脱敏基线与证据等级") {
        let snapshot = HostIntegrationSnapshot(
            host: .workBuddy,
            runtime: .ready,
            availability: .available,
            configuration: .notConfigured,
            writability: .writable,
            activation: .none)
        let report = WorkBuddyAcceptancePreflight(
            commitSHA: "fea13a0",
            claudioVersion: "0.0.0-dev",
            workBuddy: WorkBuddyApplicationIdentity(
                path: "/Applications/WorkBuddy.app",
                bundleID: "com.tencent.WorkBuddy",
                version: "1.2.3",
                build: "456",
                available: true),
            machine: WorkBuddyMachineIdentity(macOSVersion: "26.0.1", cpuArchitecture: "arm64"),
            inspectedSnapshot: snapshot,
            statusSnapshot: snapshot,
            workBuddyDoctor: .warning,
            overallDoctor: .warning,
            scopeFingerprint:
                "surface=workbuddy;host=app=short=1.2.3;build=456;claudio=0.0.0-dev;bindings=workbuddy:UserPromptSubmit:task_start:none:v1,workbuddy:Stop:stop:none:v1",
            collectedAt: Date(timeIntervalSince1970: 1))

        expect(report.inspect.available == .available, "Inspect 必须记录 WorkBuddy available")
        expect(report.inspect.runtime == .ready, "Inspect 必须记录 runtime ready")
        expect(report.inspect.writability == .writable, "Inspect 必须记录 writable")
        expect(report.inspect.configuration == .notConfigured, "Inspect 必须记录未配置基线")
        expect(report.inspect.activation == .none, "Inspect 必须记录 activation none")
        expect(
            report.scope.implementedBindingIDs.count == 2
                && report.scope.hostSurface == "workbuddy",
            "scope 必须绑定 WorkBuddy surface 与两条已实现 binding")
        expect(
            report.bindings.filter { $0.implementation == .implemented }.count == 2,
            "账本必须保留两条 implemented binding")
        expect(
            report.bindings.filter { $0.state == .notImplemented }.count == 3,
            "其余三条 binding 必须明确为 notImplemented")
        expect(
            report.soundResults.allSatisfy { $0.result == .notTested },
            "只读 preflight 不得自动试听")
        expect(
            report.evidence.currentActivation == .notObserved
                && report.evidence.releaseCandidate == .notEvaluated
                && report.evidence.manualAcceptance == .notEvaluated,
            "preflight 必须区分 Current Activation、RC 与人工验收")
        expect(
            report.cli.integrationsStatus == .collected
                && report.cli.workBuddyDoctor == .warning
                && report.gui.state == .notRun,
            "CLI/GUI 状态必须分别记录，不得把静态结果伪装成 GUI 验收")
        expect(
            report.safety.readOnly
                && report.safety.invokedMutatingActions.isEmpty
                && !report.safety.automaticAudioPreview
                && !report.safety.rawUserDataPersisted,
            "preflight 安全摘要必须证明没有写配置、试听或保存原始用户数据")

        let encoded = try! report.jsonData()
        let json = String(decoding: encoded, as: UTF8.self)
        expect(json.contains("workbuddy"), "JSON 必须包含稳定 WorkBuddy identity")
        expect(!json.contains("settings.json"), "JSON 不得包含真实宿主配置内容或路径")
        expect(!json.contains("prompt"), "JSON 不得包含 prompt 内容字段")
        expect(!json.contains("response"), "JSON 不得包含 response 内容字段")
        expect(json.contains(#""runtime" : "ready""#), "typed runtime 必须保持既有 JSON raw value")
        expect(
            json.contains(#""configuration" : "not_configured""#),
            "typed configuration 必须保持既有 JSON raw value")
        expect(
            json.contains(#""integrations_status" : "collected""#),
            "typed CLI collection state 必须保持既有 JSON raw value")
        let markdown = report.markdown()
        expect(markdown.contains("0.0.0-dev"), "Markdown 账本必须展开 Claudio 版本")
        expect(markdown.contains("not_implemented"), "Markdown 账本必须展开未实现 binding")
        expect(
            markdown.contains("| integrations status | `collected` | `static_configuration` |"),
            "默认 Markdown 必须输出 integrations status collection state")
        expect(
            markdown.contains("| overall doctor | `warning` | `static_configuration` |"),
            "默认 Markdown 必须输出 overall doctor severity")
        expect(
            markdown.contains("| WorkBuddy doctor | `warning` | `static_configuration` |"),
            "默认 Markdown 必须输出 WorkBuddy doctor severity")
        expect(
            markdown.contains("| GUI | `not_run` | `manual_acceptance` |"),
            "默认 Markdown 必须输出 GUI state 与人工证据等级")
        expect(markdown.contains("| `task_start` | `not_tested` |"), "声音状态必须输出 raw value")
        expect(!markdown.contains("\\("), "Markdown 账本不得泄漏 Swift 插值字面量")
    }

    suite("WorkBuddy 只读 preflight：当前回执只提升对应 binding 与声音结果") {
        let installationID = UUID(uuidString: "00000000-0000-4000-8000-000000000014")!
        let taskStart = HostCapabilityCatalog.binding(
            host: .workBuddy, nativeEvent: "UserPromptSubmit")!
        let stop = HostCapabilityCatalog.binding(host: .workBuddy, nativeEvent: "Stop")!
        let taskEvidence = HostReceiptEvidence(
            bindingID: taskStart.id,
            installationID: installationID,
            nativeEvent: "UserPromptSubmit",
            event: .taskStart,
            timestamp: Date(timeIntervalSince1970: 2),
            playbackResult: .played)
        let stopEvidence = HostReceiptEvidence(
            bindingID: stop.id,
            installationID: installationID,
            nativeEvent: "Stop",
            event: .stop,
            timestamp: Date(timeIntervalSince1970: 3),
            playbackResult: .muted)
        let snapshot = HostIntegrationSnapshot(
            host: .workBuddy,
            runtime: .ready,
            availability: .available,
            configuration: .configured,
            writability: .writable,
            activation: .observed(taskEvidence),
            bindingActivations: [
                taskStart.id: .observed(taskEvidence),
                stop.id: .observed(stopEvidence),
            ],
            latestReceipt: stopEvidence,
            installationID: installationID)
        let report = WorkBuddyAcceptancePreflight(
            commitSHA: "0123456789abcdef0123456789abcdef01234567",
            claudioVersion: "0.1.0",
            workBuddy: WorkBuddyApplicationIdentity(
                path: "/Applications/WorkBuddy.app",
                bundleID: "com.tencent.WorkBuddy",
                version: "1.2.3",
                build: "456",
                available: true),
            machine: WorkBuddyMachineIdentity(macOSVersion: "26.0.1", cpuArchitecture: "arm64"),
            inspectedSnapshot: snapshot,
            statusSnapshot: snapshot,
            workBuddyDoctor: .ok,
            overallDoctor: .ok,
            scopeFingerprint: "scope-v1",
            collectedAt: Date(timeIntervalSince1970: 4))

        expect(
            report.evidence.currentActivation == .recorded,
            "两条 current binding 都有回执时才可记录 Current Activation")
        expect(
            report.bindings.filter { $0.state == .currentActivation }.count == 2,
            "当前 activation 必须逐 binding 记录两条回执")
        expect(
            report.soundResults.map(\.result) == [.played, .muted],
            "声音结果必须来自脱敏回执且保留 played/muted 语义")
        expect(report.scope.installationID == installationID, "scope 必须绑定当前 installation")
    }

    suite("WorkBuddy 只读 preflight：doctor 总体等级由 Core 统一归类") {
        let ok = DoctorCheckResult(name: "ok", severity: .ok, message: "ok")
        let warning = DoctorCheckResult(name: "warning", severity: .warning, message: "warning")
        let failure = DoctorCheckResult(name: "failure", severity: .failure, message: "failure")
        expect(DoctorReport(results: [ok]).overallSeverity == .ok, "全 ok 必须归类为 ok")
        expect(
            DoctorReport(results: [ok, warning]).overallSeverity == .warning,
            "warning 必须高于 ok")
        expect(
            DoctorReport(results: [warning, failure]).overallSeverity == .failure,
            "failure 必须高于 warning")
    }
}
