import ClaudioCore
import Foundation

@MainActor
func runWorkBuddyAcceptancePreflightSuites() {
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

        expect(report.inspect.available == "available", "Inspect 必须记录 WorkBuddy available")
        expect(report.inspect.runtime == "ready", "Inspect 必须记录 runtime ready")
        expect(report.inspect.writability == "writable", "Inspect 必须记录 writable")
        expect(report.inspect.configuration == "not_configured", "Inspect 必须记录未配置基线")
        expect(report.inspect.activation == "none", "Inspect 必须记录 activation none")
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
            report.soundResults.allSatisfy { $0.result == "not_tested" },
            "只读 preflight 不得自动试听")
        expect(
            report.evidence.currentActivation == .notObserved
                && report.evidence.releaseCandidate == .notEvaluated
                && report.evidence.manualAcceptance == .notEvaluated,
            "preflight 必须区分 Current Activation、RC 与人工验收")
        expect(
            report.cli.integrationsStatus == "collected"
                && report.cli.workBuddyDoctor == "warning"
                && report.gui.state == "not_run",
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
        let markdown = report.markdown()
        expect(markdown.contains("0.0.0-dev"), "Markdown 账本必须展开 Claudio 版本")
        expect(markdown.contains("not_implemented"), "Markdown 账本必须展开未实现 binding")
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
            report.soundResults.map(\.result) == ["played", "muted"],
            "声音结果必须来自脱敏回执且保留 played/muted 语义")
        expect(report.scope.installationID == installationID, "scope 必须绑定当前 installation")
    }
}
