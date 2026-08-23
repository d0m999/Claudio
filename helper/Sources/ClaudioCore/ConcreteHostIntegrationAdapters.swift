import Darwin
import Foundation

public struct ClaudeCodeIntegrationEnvironment: Sendable {
    public let settingsFile: URL
    public let lockFile: URL
    public let operationLockFile: URL
    public let backupFile: URL
    public let claudioBinaryPath: String
    public let claudioRoot: String
    public let receiptStore: HostHookReceiptStore
    public let availability: @Sendable () -> HostAvailability
    public let scopeFingerprint: @Sendable () -> String?

    public init(
        settingsFile: URL = ClaudioPaths.claudeSettingsFile,
        lockFile: URL = ClaudioPaths.claudeIntegrationLockFile,
        operationLockFile: URL? = nil,
        backupFile: URL? = nil,
        claudioBinaryPath: String = ClaudioPaths.claudioBinary.path,
        claudioRoot: String = ClaudioPaths.root.path,
        receiptStore: HostHookReceiptStore = HostHookReceiptStore(
            receiptsRoot: ClaudioPaths.receiptsDirectory,
            locksRoot: ClaudioPaths.receiptLocksDirectory,
            installationsRoot: ClaudioPaths.activeInstallationsDirectory,
            installationLocksRoot: ClaudioPaths.activeInstallationLocksDirectory),
        scopeFingerprint: (@Sendable () -> String?)? = nil,
        availability: @escaping @Sendable () -> HostAvailability = {
            let directory = ClaudioPaths.claudeSettingsFile.deletingLastPathComponent()
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue
                ? .available : .unavailable(reason: "未检测到 Claude Code 配置目录")
        }
    ) {
        self.settingsFile = settingsFile
        self.lockFile = lockFile
        self.operationLockFile =
            operationLockFile
            ?? lockFile.deletingLastPathComponent().appendingPathComponent(
                "\(HostID.claudeCode.rawValue)-operation.lock")
        self.backupFile =
            backupFile
            ?? settingsFile.deletingLastPathComponent().appendingPathComponent(
                settingsFile.lastPathComponent + ".claudio.bak")
        self.claudioBinaryPath = claudioBinaryPath
        self.claudioRoot = claudioRoot
        self.receiptStore = receiptStore
        self.scopeFingerprint = scopeFingerprint ?? HostActivationScope.claudeCode
        self.availability = availability
    }
}

public struct CodexIntegrationEnvironment: Sendable {
    public let hooksFile: URL
    public let lockFile: URL
    public let operationLockFile: URL
    public let backupFile: URL
    public let configFile: URL
    public let legacyNotifyWrapper: URL
    public let claudioBinaryPath: String
    public let claudioRoot: String
    public let receiptStore: HostHookReceiptStore
    public let availability: @Sendable () -> HostAvailability
    public let scopeFingerprint: @Sendable () -> String?
    /// Testable publication-boundary seam. Production uses the default no-op; regression tests
    /// inject a non-cooperating writer after staging is complete and before the final expected-byte
    /// check. Keeping it in the environment mirrors the existing injected host/filesystem facts.
    public let beforeLegacyWrapperFinalPublish: @Sendable () -> Void

    public init(
        hooksFile: URL = ClaudioPaths.codexHooksFile,
        lockFile: URL = ClaudioPaths.codexIntegrationLockFile,
        operationLockFile: URL? = nil,
        backupFile: URL? = nil,
        configFile: URL = ClaudioPaths.codexConfigFile,
        legacyNotifyWrapper: URL = ClaudioPaths.legacyCodexNotifyWrapper,
        claudioBinaryPath: String = ClaudioPaths.claudioBinary.path,
        claudioRoot: String = ClaudioPaths.root.path,
        receiptStore: HostHookReceiptStore = HostHookReceiptStore(
            receiptsRoot: ClaudioPaths.receiptsDirectory,
            locksRoot: ClaudioPaths.receiptLocksDirectory,
            installationsRoot: ClaudioPaths.activeInstallationsDirectory,
            installationLocksRoot: ClaudioPaths.activeInstallationLocksDirectory),
        scopeFingerprint: (@Sendable () -> String?)? = nil,
        availability: @escaping @Sendable () -> HostAvailability = {
            let directory = ClaudioPaths.codexHooksFile.deletingLastPathComponent()
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue
                ? .available : .unavailable(reason: "未检测到 Codex 配置目录")
        },
        beforeLegacyWrapperFinalPublish: @escaping @Sendable () -> Void = {}
    ) {
        self.hooksFile = hooksFile
        self.lockFile = lockFile
        self.operationLockFile =
            operationLockFile
            ?? lockFile.deletingLastPathComponent().appendingPathComponent(
                "\(HostID.codex.rawValue)-operation.lock")
        self.backupFile =
            backupFile
            ?? hooksFile.deletingLastPathComponent().appendingPathComponent(
                hooksFile.lastPathComponent + ".claudio.bak")
        self.configFile = configFile
        self.legacyNotifyWrapper = legacyNotifyWrapper
        self.claudioBinaryPath = claudioBinaryPath
        self.claudioRoot = claudioRoot
        self.receiptStore = receiptStore
        self.scopeFingerprint = scopeFingerprint ?? HostActivationScope.codex
        self.availability = availability
        self.beforeLegacyWrapperFinalPublish = beforeLegacyWrapperFinalPublish
    }
}

public struct ClaudeCodeIntegrationAdapter: HostIntegrationAdapter {
    public let environment: ClaudeCodeIntegrationEnvironment
    public var host: HostID { .claudeCode }
    public var capabilities: [HostCapabilityBinding] {
        HostCapabilityCatalog.bindings(for: .claudeCode)
    }

    public init(environment: ClaudeCodeIntegrationEnvironment = .init()) {
        self.environment = environment
    }

    public func inspect(runtime: SharedRuntimeHealth) async -> HostIntegrationSnapshot {
        inspectClaudeSnapshot(environment: environment, runtime: runtime)
    }

    public func connect(
        runtime: SharedRuntimeHealth
    ) async -> Result<HostIntegrationSnapshot, HostIntegrationActionError> {
        withHostIntegrationOperationLock(path: environment.operationLockFile) {
            connectLocked(runtime: runtime)
        }
    }

    private func connectLocked(
        runtime: SharedRuntimeHealth
    ) -> Result<HostIntegrationSnapshot, HostIntegrationActionError> {
        guard runtime == .ready else {
            return .failure(.runtimeUnavailable(reason: integrationRuntimeReason(runtime)))
        }
        if case .unavailable(let reason) = environment.availability() {
            return .failure(.hostUnavailable(reason: reason))
        }
        guard let scopeFingerprint = environment.scopeFingerprint() else {
            return .failure(
                .configuration(reason: "无法读取 Claude Code/Claudio 版本身份；已拒绝写入连接"))
        }
        let activeID = environment.receiptStore.currentInstallationID(host: .claudeCode)
        let reusableInstallationID =
            environment.receiptStore.currentInstallationScopeFingerprint(host: .claudeCode)
            == scopeFingerprint
            ? activeID : nil
        let transaction = ConfigFileTransaction(
            file: environment.settingsFile,
            lockFile: environment.lockFile,
            backupFile: environment.backupFile,
            symlinkPolicy: .preserveTarget)
        let requestedID = UUID()
        var transformError: HostHooksTransformError?
        var resultingInstallationID: UUID?
        let result = transaction.update { root in
            switch connectClaudeCodeHooks(
                root: root,
                claudioRoot: environment.claudioRoot,
                claudioBinaryPath: environment.claudioBinaryPath,
                installationID: requestedID,
                reusableInstallationID: reusableInstallationID,
                requiresReusableInstallationID: true)
            {
            case .failure(let error):
                transformError = error
                return .unchanged
            case .success(let mutation):
                if case .success(.configured(let id)) = inspectClaudeCodeHooks(
                    root: mutation.root,
                    claudioRoot: environment.claudioRoot,
                    claudioBinaryPath: environment.claudioBinaryPath)
                {
                    resultingInstallationID = id
                }
                return mutation.changed ? .replace(mutation.root) : .unchanged
            }
        }
        if let transformError {
            return .failure(.configuration(reason: transformError.description))
        }
        if case .failure(let error) = result { return .failure(.transaction(error)) }
        guard let installationID = resultingInstallationID else {
            return .failure(
                .configuration(reason: "Claude Code 写入后未形成完整的 claudi0 installation ID"))
        }
        if case .failure(let error) = environment.receiptStore.activate(
            host: .claudeCode,
            installationID: installationID,
            scopeFingerprint: scopeFingerprint)
        {
            return .failure(
                .configuration(reason: "Claude Code 当前连接代次发布失败：\(error.description)"))
        }
        return .success(inspectClaudeSnapshot(environment: environment, runtime: runtime))
    }

    public func disconnect(
        runtime: SharedRuntimeHealth
    ) async -> Result<HostIntegrationSnapshot, HostIntegrationActionError> {
        withHostIntegrationOperationLock(path: environment.operationLockFile) {
            disconnectLocked(runtime: runtime)
        }
    }

    private func disconnectLocked(
        runtime: SharedRuntimeHealth
    ) -> Result<HostIntegrationSnapshot, HostIntegrationActionError> {
        // Marker 是 hook 写回执时真正执行的当前代次闸门。若它与配置 ID 漂移，
        // 必须优先撤销 marker；否则按配置 ID 调 deactivate 会成功 no-op，随后删掉
        // 配置却留下仍能接受迟到回执的孤儿 marker。
        let installationID =
            environment.receiptStore.currentInstallationID(host: .claudeCode)
            ?? inspectClaudeSnapshot(environment: environment, runtime: runtime).installationID
        // 先撤销代次，再删配置。若回执锁忙，本次断开零配置写；
        // 一旦 marker 已撤销，任何迟到旧 hook 都不能再制造有效证据。
        if let installationID,
            case .failure(let error) = environment.receiptStore.deactivate(
                host: .claudeCode, installationID: installationID)
        {
            return .failure(
                .configuration(reason: "Claude Code 当前连接代次撤销失败：\(error.description)"))
        }
        guard FileManager.default.fileExists(atPath: environment.settingsFile.path) else {
            return .success(inspectClaudeSnapshot(environment: environment, runtime: runtime))
        }
        let transaction = ConfigFileTransaction(
            file: environment.settingsFile,
            lockFile: environment.lockFile,
            backupFile: nil,
            symlinkPolicy: .preserveTarget)
        var transformError: HostHooksTransformError?
        let result = transaction.update { root in
            switch disconnectClaudeCodeHooks(root: root, claudioRoot: environment.claudioRoot) {
            case .failure(let error):
                transformError = error
                return .unchanged
            case .success(let mutation):
                return mutation.changed ? .replace(mutation.root) : .unchanged
            }
        }
        if let transformError {
            return .failure(.configuration(reason: transformError.description))
        }
        if case .failure(let error) = result { return .failure(.transaction(error)) }
        return .success(inspectClaudeSnapshot(environment: environment, runtime: runtime))
    }
}

public struct CodexIntegrationAdapter: HostIntegrationAdapter {
    public let environment: CodexIntegrationEnvironment
    public var host: HostID { .codex }
    public var capabilities: [HostCapabilityBinding] {
        HostCapabilityCatalog.bindings(for: .codex)
    }

    public init(environment: CodexIntegrationEnvironment = .init()) {
        self.environment = environment
    }

    public func inspect(runtime: SharedRuntimeHealth) async -> HostIntegrationSnapshot {
        inspectCodexSnapshot(environment: environment, runtime: runtime)
    }

    public func connect(
        runtime: SharedRuntimeHealth
    ) async -> Result<HostIntegrationSnapshot, HostIntegrationActionError> {
        withHostIntegrationOperationLock(path: environment.operationLockFile) {
            connectLocked(runtime: runtime)
        }
    }

    private func connectLocked(
        runtime: SharedRuntimeHealth
    ) -> Result<HostIntegrationSnapshot, HostIntegrationActionError> {
        guard runtime == .ready else {
            return .failure(.runtimeUnavailable(reason: integrationRuntimeReason(runtime)))
        }
        if case .unavailable(let reason) = environment.availability() {
            return .failure(.hostUnavailable(reason: reason))
        }
        guard let scopeFingerprint = environment.scopeFingerprint() else {
            return .failure(
                .configuration(reason: "无法读取 Codex/Claudio 版本身份；已拒绝写入连接"))
        }
        let activeID = environment.receiptStore.currentInstallationID(host: .codex)
        let reusableInstallationID =
            environment.receiptStore.currentInstallationScopeFingerprint(host: .codex)
            == scopeFingerprint
            ? activeID : nil
        let wrapperContext = inspectLegacyWrapperContext(environment: environment)
        if case .conflict(let reason) = wrapperContext {
            return .failure(.migrationConflict(reason: reason))
        }
        let existingHooksData: Data?
        switch loadIntegrationData(at: environment.hooksFile) {
        case .missing: existingHooksData = nil
        case .data(let data): existingHooksData = data
        case .failure(let reason):
            return .failure(.configuration(reason: reason))
        }
        let plainStatus = CodexHooksTransform.inspect(
            existingHooksData,
            claudioRoot: environment.claudioRoot,
            claudioBinaryPath: environment.claudioBinaryPath)
        let requestedID = UUID()
        let wrapperPlan: LegacyWrapperPlan
        switch legacyWrapperPlan(
            context: wrapperContext, plainHooksStatus: plainStatus, requestedID: requestedID,
            reusableInstallationID: reusableInstallationID,
            environment: environment)
        {
        case .failure(.conflict(let reason)):
            return .failure(.migrationConflict(reason: reason))
        case .success(let plan):
            wrapperPlan = plan
        }
        var appliedWrapperMutation: AppliedLegacyWrapperMutation?
        if let replacement = wrapperPlan.replacement {
            switch atomicallyReplaceLegacyWrapper(
                file: environment.legacyNotifyWrapper,
                expected: wrapperPlan.expectedWrapper,
                replacement: replacement,
                lockFile: environment.lockFile,
                beforeFinalPublish: environment.beforeLegacyWrapperFinalPublish)
            {
            case .success:
                appliedWrapperMutation = AppliedLegacyWrapperMutation(
                    original: wrapperPlan.expectedWrapper, replacement: replacement)
            case .failure(.failed(let reason)):
                return .failure(.migrationConflict(reason: reason))
            }
        }

        let transaction = ConfigFileTransaction(
            file: environment.hooksFile,
            lockFile: environment.lockFile,
            backupFile: environment.backupFile,
            symlinkPolicy: .preserveTarget)
        var transformFailure: String?
        var resultingInstallationID: UUID?
        let result = transaction.update { root in
            guard let original = integrationJSONData(root) else {
                transformFailure = "Codex hooks.json 无法安全序列化"
                return .unchanged
            }
            var transformInput = original
            if reusableInstallationID == nil,
                let configuredID = plainStatus.installationID,
                configuredID != wrapperPlan.installationID
            {
                let swept = CodexHooksTransform.disconnect(
                    original, claudioRoot: environment.claudioRoot)
                guard swept.changed, let data = swept.data else {
                    transformFailure = "无法安全轮换 Codex installation ID"
                    return .unchanged
                }
                transformInput = data
            }
            let transformed = CodexHooksTransform.connect(
                transformInput,
                installationID: wrapperPlan.installationID,
                claudioBinaryPath: environment.claudioBinaryPath,
                claudioRoot: environment.claudioRoot,
                externallyManagedNativeEvents: wrapperPlan.externallyManagedEvents,
                externalInstallationID: wrapperPlan.externalInstallationID,
                reusableInstallationID: reusableInstallationID,
                requiresReusableInstallationID: true)
            if case .malformed(let reason) = transformed.status {
                transformFailure = reason
                return .unchanged
            }
            if case .conflictingInstallationIDs = transformed.status {
                transformFailure = "Codex hooks 含多个 claudi0 installation ID，已停止写入"
                return .unchanged
            }
            if case .conflict(let reason) = transformed.status {
                transformFailure = reason
                return .unchanged
            }
            resultingInstallationID = transformed.status.installationID
            guard transformed.changed else { return .unchanged }
            guard let data = transformed.data,
                let next = integrationJSONObject(data)
            else {
                transformFailure = "Codex hooks 变换结果无法解析"
                return .unchanged
            }
            return .replace(next)
        }
        if let transformFailure {
            return codexFailureAfterRollingBackWrapper(
                .configuration(reason: transformFailure),
                appliedMutation: appliedWrapperMutation,
                environment: environment)
        }
        if case .failure(let error) = result {
            return codexFailureAfterRollingBackWrapper(
                .transaction(error),
                appliedMutation: appliedWrapperMutation,
                environment: environment)
        }
        guard let installationID = resultingInstallationID else {
            return .failure(
                .configuration(reason: "Codex 写入后未形成完整的 claudi0 installation ID"))
        }
        if case .failure(let error) = environment.receiptStore.activate(
            host: .codex,
            installationID: installationID,
            scopeFingerprint: scopeFingerprint)
        {
            return .failure(
                .configuration(reason: "Codex 当前连接代次发布失败：\(error.description)"))
        }
        return .success(inspectCodexSnapshot(environment: environment, runtime: runtime))
    }

    public func disconnect(
        runtime: SharedRuntimeHealth
    ) async -> Result<HostIntegrationSnapshot, HostIntegrationActionError> {
        withHostIntegrationOperationLock(path: environment.operationLockFile) {
            disconnectLocked(runtime: runtime)
        }
    }

    private func disconnectLocked(
        runtime: SharedRuntimeHealth
    ) -> Result<HostIntegrationSnapshot, HostIntegrationActionError> {
        // 与 Claude 同一不变量：先撤销真正控制回执写入的 marker，即使它与
        // hooks.json 当前 ID 不一致；宿主级 operation lock 防止新连接在这里交错。
        let installationID =
            environment.receiptStore.currentInstallationID(host: .codex)
            ?? inspectCodexSnapshot(environment: environment, runtime: runtime).installationID
        let wrapperContext = inspectLegacyWrapperContext(environment: environment)
        if case .conflict(let reason) = wrapperContext {
            return .failure(.migrationConflict(reason: reason))
        }
        if let installationID,
            case .failure(let error) = environment.receiptStore.deactivate(
                host: .codex, installationID: installationID)
        {
            return .failure(
                .configuration(reason: "Codex 当前连接代次撤销失败：\(error.description)"))
        }
        var appliedWrapperMutation: AppliedLegacyWrapperMutation?
        if case .known(_, let configData, let wrapperData) = wrapperContext {
            switch removeClaudioBranchFromLegacyCodexNotifyWrapper(
                configTOML: configData,
                wrapper: wrapperData,
                claudioRoot: environment.claudioRoot,
                claudioBinaryPath: environment.claudioBinaryPath)
            {
            case .failure(let reason):
                return .failure(.migrationConflict(reason: legacyConflictText(reason)))
            case .success(let replacement) where replacement != wrapperData:
                switch atomicallyReplaceLegacyWrapper(
                    file: environment.legacyNotifyWrapper,
                    expected: wrapperData,
                    replacement: replacement,
                    lockFile: environment.lockFile,
                    beforeFinalPublish: environment.beforeLegacyWrapperFinalPublish)
                {
                case .success:
                    appliedWrapperMutation = AppliedLegacyWrapperMutation(
                        original: wrapperData, replacement: replacement)
                case .failure(.failed(let reason)):
                    return .failure(.migrationConflict(reason: reason))
                }
            case .success:
                break
            }
        }
        guard FileManager.default.fileExists(atPath: environment.hooksFile.path) else {
            return .success(inspectCodexSnapshot(environment: environment, runtime: runtime))
        }
        let transaction = ConfigFileTransaction(
            file: environment.hooksFile,
            lockFile: environment.lockFile,
            backupFile: nil,
            symlinkPolicy: .preserveTarget)
        var transformFailure: String?
        let result = transaction.update { root in
            guard let original = integrationJSONData(root) else {
                transformFailure = "Codex hooks.json 无法安全序列化"
                return .unchanged
            }
            let transformed = CodexHooksTransform.disconnect(
                original, claudioRoot: environment.claudioRoot)
            if case .malformed(let reason) = transformed.status {
                transformFailure = reason
                return .unchanged
            }
            guard transformed.changed else { return .unchanged }
            guard let data = transformed.data,
                let next = integrationJSONObject(data)
            else {
                transformFailure = "Codex hooks 断开结果无法解析"
                return .unchanged
            }
            return .replace(next)
        }
        if let transformFailure {
            return codexFailureAfterRollingBackWrapper(
                .configuration(reason: transformFailure),
                appliedMutation: appliedWrapperMutation,
                environment: environment)
        }
        if case .failure(let error) = result {
            return codexFailureAfterRollingBackWrapper(
                .transaction(error),
                appliedMutation: appliedWrapperMutation,
                environment: environment)
        }
        return .success(inspectCodexSnapshot(environment: environment, runtime: runtime))
    }
}

/// Claude Code adapter、doctor 与 GUI 共用的只读事实入口。
/// 调用方不得自行重解析 settings.json，以免配置/回执判定发生漂移。
public func inspectClaudeSnapshot(
    environment: ClaudeCodeIntegrationEnvironment,
    runtime: SharedRuntimeHealth
) -> HostIntegrationSnapshot {
    let availability = environment.availability()
    let rootResult = loadIntegrationJSONObject(at: environment.settingsFile)
    var configuration: HostConfigurationState
    var installationID: UUID?
    switch rootResult {
    case .missing:
        configuration = .notConfigured
    case .failure(let reason):
        configuration = .unreadable(reason: reason)
    case .root(let root):
        switch inspectClaudeCodeHooks(
            root: root,
            claudioRoot: environment.claudioRoot,
            claudioBinaryPath: environment.claudioBinaryPath)
        {
        case .failure(let error):
            configuration = .unreadable(reason: error.description)
        case .success(.notConfigured):
            configuration = .notConfigured
        case .success(.legacyConnected):
            configuration = .legacyConnected
        case .success(.configured(let id)):
            configuration = .configured
            installationID = id
        case .success(.partial(_, let missing, let hasLegacyEntries)):
            if hasLegacyEntries, missing.count < Event.allCases.count {
                configuration = .conflict(
                    reason:
                        "Claude Code modern 与 legacy hooks 同时存在，可能重复播放；"
                        + "请运行 `~/.claudio/bin/claudi0 integrations connect claude-code` 重新连接")
            } else {
                configuration = .incomplete(missingNativeEvents: missing)
            }
        case .success(.conflict(let reason)):
            configuration = .conflict(reason: reason)
        }
    }
    let currentScope = configuration == .configured ? environment.scopeFingerprint() : nil
    configuration = validatedActivationConfiguration(
        host: .claudeCode,
        configuration: configuration,
        installationID: installationID,
        currentScope: currentScope,
        receiptStore: environment.receiptStore)
    return makeIntegrationSnapshot(
        host: .claudeCode,
        runtime: runtime,
        availability: availability,
        configuration: configuration,
        installationID: installationID,
        file: environment.settingsFile,
        receiptStore: environment.receiptStore,
        scopeFingerprint: currentScope)
}

/// Codex adapter、doctor 与 GUI 共用的只读事实入口；包含 legacy codex-notify
/// 的精确检测，因此不能退化成只检查 hooks.json。
public func inspectCodexSnapshot(
    environment: CodexIntegrationEnvironment,
    runtime: SharedRuntimeHealth
) -> HostIntegrationSnapshot {
    let availability = environment.availability()
    let dataResult = loadIntegrationData(at: environment.hooksFile)
    let wrapperContext = inspectLegacyWrapperContext(environment: environment)
    let status = codexConfigurationStatus(
        dataResult: dataResult,
        wrapperContext: wrapperContext,
        claudioRoot: environment.claudioRoot,
        claudioBinaryPath: environment.claudioBinaryPath)
    var configuration: HostConfigurationState
    let installationID: UUID?
    switch status {
    case .absent:
        configuration = .notConfigured
        installationID = nil
    case .complete(let id):
        configuration = .configured
        installationID = id
    case .partial(let id, let missing):
        configuration = .incomplete(missingNativeEvents: missing)
        installationID = id
    case .conflictingInstallationIDs:
        configuration = .conflict(reason: "Codex hooks 含多个 claudi0 installation ID")
        installationID = nil
    case .conflict(let reason):
        configuration = .conflict(reason: reason)
        installationID = nil
    case .malformed(let reason):
        configuration = .unreadable(reason: reason)
        installationID = nil
    }
    let currentScope = configuration == .configured ? environment.scopeFingerprint() : nil
    configuration = validatedActivationConfiguration(
        host: .codex,
        configuration: configuration,
        installationID: installationID,
        currentScope: currentScope,
        receiptStore: environment.receiptStore)
    return makeIntegrationSnapshot(
        host: .codex,
        runtime: runtime,
        availability: availability,
        configuration: configuration,
        installationID: installationID,
        file: environment.hooksFile,
        receiptStore: environment.receiptStore,
        scopeFingerprint: currentScope)
}

private func codexConfigurationStatus(
    dataResult: IntegrationDataLoad,
    wrapperContext: LegacyWrapperContext,
    claudioRoot: String,
    claudioBinaryPath: String
) -> CodexHooksConfigurationStatus {
    if case .conflict(let reason) = wrapperContext {
        return .malformed(reason: reason)
    }

    let data: Data?
    switch dataResult {
    case .missing:
        data = nil
    case .failure(let reason):
        return .malformed(reason: reason)
    case .data(let loaded):
        data = loaded
    }

    switch wrapperContext {
    case .none, .known(.notifierOnly, _, _):
        return CodexHooksTransform.inspect(
            data,
            claudioRoot: claudioRoot,
            claudioBinaryPath: claudioBinaryPath)
    case .known(.migrated(let id), _, _):
        return CodexHooksTransform.inspect(
            data,
            claudioRoot: claudioRoot,
            claudioBinaryPath: claudioBinaryPath,
            externallyManagedNativeEvents: ["Stop"],
            externalInstallationID: id)
    case .known(.legacyPlayStop, _, _):
        let plain = CodexHooksTransform.inspect(
            data,
            claudioRoot: claudioRoot,
            claudioBinaryPath: claudioBinaryPath)
        switch plain {
        case .malformed(let reason):
            return .malformed(reason: reason)
        case .conflict(let reason):
            return .conflict(reason: reason)
        case .conflictingInstallationIDs(let ids):
            return .conflictingInstallationIDs(ids)
        default:
            return .malformed(
                reason: "检测到旧版 codex-notify；请显式升级连接以启用真实回执")
        }
    case .conflict(let reason):
        return .malformed(reason: reason)
    }
}

func makeIntegrationSnapshot(
    host: HostID,
    runtime: SharedRuntimeHealth,
    availability: HostAvailability,
    configuration: HostConfigurationState,
    installationID: UUID?,
    file: URL,
    receiptStore: HostHookReceiptStore,
    scopeFingerprint: String?
) -> HostIntegrationSnapshot {
    let writability: HostConfigWritability
    if leafNodeIsSymbolicLink(at: file),
        !FileManager.default.fileExists(atPath: file.path)
    {
        writability = .notWritable(reason: danglingIntegrationConfigReason(file))
    } else if case .unavailable = availability,
        !FileManager.default.fileExists(atPath: file.path)
    {
        writability = .unknown
    } else {
        switch probeSettingsWritable(settingsFile: file) {
        case .writable: writability = .writable
        case .notWritable(let reason): writability = .notWritable(reason: reason)
        }
    }

    let activation: HostActivationEvidence
    let bindingActivations: [HostEventBindingID: HostActivationEvidence]
    let latestReceipt: HostReceiptEvidence?
    if let installationID, let scopeFingerprint, configuration == .configured {
        let implementedBindings = HostCapabilityCatalog.bindings(for: host)
            .filter(\.isAudibleCapability)
        let evidenceByBinding = Dictionary(
            uniqueKeysWithValues: implementedBindings.map { binding in
                let evidence = binding.nativeEvent.flatMap { nativeEvent in
                    receiptStore.receiptEvidence(
                        host: host,
                        nativeEvent: nativeEvent,
                        installationID: installationID,
                        scopeFingerprint: scopeFingerprint)
                }
                return (
                    binding.id,
                    evidence.map(HostActivationEvidence.observed)
                        ?? .awaitingReceipt(installationID: installationID)
                )
            })
        bindingActivations = evidenceByBinding
        latestReceipt =
            implementedBindings
            .compactMap { binding in
                guard let nativeEvent = binding.nativeEvent else { return nil }
                return receiptStore.receiptEvidence(
                    host: host,
                    nativeEvent: nativeEvent,
                    installationID: installationID,
                    scopeFingerprint: scopeFingerprint)
            }
            .max { $0.timestamp < $1.timestamp }
        let taskStartNativeEvent = HostCapabilityCatalog.binding(host: host, event: .taskStart)?
            .nativeEvent
        let taskStartEvidence = taskStartNativeEvent.flatMap { nativeEvent in
            receiptStore.receiptEvidence(
                host: host,
                nativeEvent: nativeEvent,
                installationID: installationID,
                scopeFingerprint: scopeFingerprint)
        }
        activation =
            taskStartEvidence.map(HostActivationEvidence.observed)
            ?? .awaitingReceipt(installationID: installationID)
    } else {
        activation = .none
        bindingActivations = [:]
        latestReceipt = nil
    }
    return HostIntegrationSnapshot(
        host: host,
        runtime: runtime,
        availability: availability,
        configuration: configuration,
        writability: writability,
        activation: activation,
        bindingActivations: bindingActivations,
        latestReceipt: latestReceipt,
        installationID: installationID)
}

func validatedActivationConfiguration(
    host: HostID,
    configuration: HostConfigurationState,
    installationID: UUID?,
    currentScope: String?,
    receiptStore: HostHookReceiptStore
) -> HostConfigurationState {
    guard configuration == .configured else { return configuration }
    guard let installationID,
        receiptStore.currentInstallationID(host: host) == installationID
    else {
        return .conflict(reason: "\(host.displayName) 当前连接代次缺失或错位；请修复连接")
    }
    guard let currentScope else {
        return .conflict(reason: "无法读取 \(host.displayName)/Claudio 版本身份；请修复连接")
    }
    guard receiptStore.currentInstallationScopeFingerprint(host: host) == currentScope else {
        return .conflict(reason: "\(host.displayName) 或 Claudio 版本已变化，旧回执已失效；请修复连接")
    }
    return configuration
}

private enum IntegrationDataLoad {
    case missing
    case data(Data)
    case failure(String)
}

private enum IntegrationJSONObjectLoad {
    case missing
    case root([String: Any])
    case failure(String)
}

private func loadIntegrationData(at file: URL) -> IntegrationDataLoad {
    if leafNodeIsSymbolicLink(at: file),
        !FileManager.default.fileExists(atPath: file.path)
    {
        return .failure(danglingIntegrationConfigReason(file))
    }
    guard FileManager.default.fileExists(atPath: file.path) else { return .missing }
    switch readRegularFileBounded(at: file, maxBytes: 1 << 20, followSymlink: true) {
    case .success(let data): return .data(data)
    case .notRegularFile: return .failure("配置路径不是普通文件：\(file.path)")
    case .oversize: return .failure("配置文件超过 1 MiB 安全上限：\(file.path)")
    case .unreadable: return .failure("配置文件无法读取：\(file.path)")
    }
}

private func danglingIntegrationConfigReason(_ file: URL) -> String {
    "配置文件是目标不存在的符号链接，无法安全保留 dotfiles 链接：\(file.path)"
}

private func loadIntegrationJSONObject(at file: URL) -> IntegrationJSONObjectLoad {
    switch loadIntegrationData(at: file) {
    case .missing: return .missing
    case .failure(let reason): return .failure(reason)
    case .data(let data):
        guard let root = integrationJSONObject(data) else {
            return .failure("配置文件 JSON 顶层必须是 object：\(file.path)")
        }
        return .root(root)
    }
}

private func integrationJSONData(_ root: [String: Any]) -> Data? {
    guard JSONSerialization.isValidJSONObject(root) else { return nil }
    return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
}

private func integrationJSONObject(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func integrationRuntimeReason(_ health: SharedRuntimeHealth) -> String {
    switch health {
    case .ready: "已就绪"
    case .unavailable(let reason), .damaged(let reason): reason
    }
}

private enum LegacyWrapperContext {
    case none
    case known(LegacyCodexNotifyWrapperState, config: Data, wrapper: Data)
    case conflict(String)
}

private struct LegacyWrapperPlan {
    let installationID: UUID
    let externallyManagedEvents: Set<String>
    let externalInstallationID: UUID?
    let expectedWrapper: Data
    let replacement: Data?
}

private func inspectLegacyWrapperContext(
    environment: CodexIntegrationEnvironment
) -> LegacyWrapperContext {
    let configData: Data
    switch loadIntegrationData(at: environment.configFile) {
    case .missing:
        return .none
    case .failure(let reason):
        return FileManager.default.fileExists(atPath: environment.legacyNotifyWrapper.path)
            ? .conflict("旧 codex-notify 存在，但 config.toml \(reason)") : .none
    case .data(let data):
        configData = data
    }

    let wrapperData: Data
    switch readLegacyWrapperData(at: environment.legacyNotifyWrapper) {
    case .missing:
        // 用空 wrapper 只做引用判定：没引用就是无冲突；确实引用但文件丢失则 fail closed。
        switch inspectLegacyCodexNotifyWrapper(
            configTOML: configData,
            wrapper: Data(),
            claudioRoot: environment.claudioRoot,
            claudioBinaryPath: environment.claudioBinaryPath)
        {
        case .failure(.configDoesNotReferenceWrapper): return .none
        default: return .conflict("config.toml 仍引用旧 codex-notify，但 wrapper 文件不存在")
        }
    case .failure(let reason):
        return .conflict(reason)
    case .data(let data):
        wrapperData = data
    }

    switch inspectLegacyCodexNotifyWrapper(
        configTOML: configData,
        wrapper: wrapperData,
        claudioRoot: environment.claudioRoot,
        claudioBinaryPath: environment.claudioBinaryPath)
    {
    case .success(let state):
        return .known(state, config: configData, wrapper: wrapperData)
    case .failure(.configDoesNotReferenceWrapper):
        return .none
    case .failure(let reason):
        return .conflict(legacyConflictText(reason))
    }
}

private func legacyWrapperPlan(
    context: LegacyWrapperContext,
    plainHooksStatus: CodexHooksConfigurationStatus,
    requestedID: UUID,
    reusableInstallationID: UUID?,
    environment: CodexIntegrationEnvironment
) -> Result<LegacyWrapperPlan, LegacyWrapperPlanningError> {
    switch context {
    case .conflict(let reason):
        return .failure(.conflict(reason))
    case .none:
        return .success(
            LegacyWrapperPlan(
                installationID: requestedID,
                externallyManagedEvents: [],
                externalInstallationID: nil,
                expectedWrapper: Data(),
                replacement: nil))
    case .known(let state, let configData, let wrapperData):
        let chosenID: UUID
        switch state {
        case .migrated(let installationID):
            chosenID =
                installationID == reusableInstallationID ? installationID : requestedID
        case .legacyPlayStop:
            switch plainHooksStatus {
            case .absent:
                chosenID = requestedID
            case .partial(let existingID, let missing) where missing.contains("Stop"):
                chosenID = existingID == reusableInstallationID ? existingID : requestedID
            case .malformed(let reason):
                return .failure(.conflict(reason))
            case .conflict(let reason):
                return .failure(.conflict(reason))
            case .conflictingInstallationIDs:
                return .failure(.conflict("hooks.json 含多个 claudi0 installation ID"))
            case .complete, .partial:
                return .failure(
                    .conflict("旧 codex-notify 与 hooks.json 同时管理 Stop，可能重复播放"))
            }
        case .notifierOnly:
            switch plainHooksStatus {
            case .absent:
                chosenID = requestedID
            case .partial(let existingID, _), .complete(let existingID):
                chosenID = existingID == reusableInstallationID ? existingID : requestedID
            case .malformed(let reason):
                return .failure(.conflict(reason))
            case .conflict(let reason):
                return .failure(.conflict(reason))
            case .conflictingInstallationIDs:
                return .failure(.conflict("hooks.json 含多个 claudi0 installation ID"))
            }
        }

        let replacement: Data?
        let externallyManagedEvents: Set<String>
        let externalInstallationID: UUID?
        switch state {
        case .migrated(let existingID):
            if existingID == chosenID {
                replacement = nil
            } else {
                switch migrateLegacyCodexNotifyWrapper(
                    configTOML: configData,
                    wrapper: wrapperData,
                    claudioRoot: environment.claudioRoot,
                    claudioBinaryPath: environment.claudioBinaryPath,
                    installationID: chosenID)
                {
                case .success(let data): replacement = data
                case .failure(let reason):
                    return .failure(.conflict(legacyConflictText(reason)))
                }
            }
            externallyManagedEvents = ["Stop"]
            externalInstallationID = chosenID
        case .legacyPlayStop:
            switch migrateLegacyCodexNotifyWrapper(
                configTOML: configData,
                wrapper: wrapperData,
                claudioRoot: environment.claudioRoot,
                claudioBinaryPath: environment.claudioBinaryPath,
                installationID: chosenID)
            {
            case .success(let data): replacement = data
            case .failure(let reason):
                return .failure(.conflict(legacyConflictText(reason)))
            }
            externallyManagedEvents = ["Stop"]
            externalInstallationID = chosenID
        case .notifierOnly:
            let wrapperMustResumeManagingStop: Bool
            switch plainHooksStatus {
            case .absent:
                wrapperMustResumeManagingStop = true
            case .partial(_, let missing):
                wrapperMustResumeManagingStop = missing.contains("Stop")
            case .complete:
                wrapperMustResumeManagingStop = false
            case .malformed, .conflict, .conflictingInstallationIDs:
                // These states returned above while choosing the installation ID.
                return .failure(.conflict("hooks.json 状态无法安全规划"))
            }
            if wrapperMustResumeManagingStop {
                switch migrateLegacyCodexNotifyWrapper(
                    configTOML: configData,
                    wrapper: wrapperData,
                    claudioRoot: environment.claudioRoot,
                    claudioBinaryPath: environment.claudioBinaryPath,
                    installationID: chosenID)
                {
                case .success(let data): replacement = data
                case .failure(let reason):
                    return .failure(.conflict(legacyConflictText(reason)))
                }
                externallyManagedEvents = ["Stop"]
                externalInstallationID = chosenID
            } else {
                replacement = nil
                externallyManagedEvents = []
                externalInstallationID = nil
            }
        }
        return .success(
            LegacyWrapperPlan(
                installationID: chosenID,
                externallyManagedEvents: externallyManagedEvents,
                externalInstallationID: externalInstallationID,
                expectedWrapper: wrapperData,
                replacement: replacement))
    }
}

private enum LegacyWrapperPlanningError: Error {
    case conflict(String)
}

private enum LegacyWrapperRead {
    case missing
    case data(Data)
    case failure(String)
}

private func readLegacyWrapperData(at file: URL) -> LegacyWrapperRead {
    guard FileManager.default.fileExists(atPath: file.path) else { return .missing }
    switch readRegularFileBounded(at: file, maxBytes: 1 << 16, followSymlink: false) {
    case .success(let data): return .data(data)
    case .notRegularFile: return .failure("旧 codex-notify 不是普通文件或是符号链接")
    case .oversize: return .failure("旧 codex-notify 超过 64 KiB 安全上限")
    case .unreadable: return .failure("旧 codex-notify 无法读取")
    }
}

private enum LegacyWrapperWriteError: Error {
    case failed(String)
}

private struct AppliedLegacyWrapperMutation {
    let original: Data
    let replacement: Data
}

/// `hooks.json` 事务失败时把早一步的 wrapper 迁移精确回滚。回滚仍做
/// expected-bytes CAS：若外部在两步间修改了 wrapper，宁可暴露双重冲突也不
/// 覆盖用户新内容。宿主级 outer lock 防住其他 Claudio 进程；CAS 防住第三方。
private func codexFailureAfterRollingBackWrapper(
    _ failure: HostIntegrationActionError,
    appliedMutation: AppliedLegacyWrapperMutation?,
    environment: CodexIntegrationEnvironment
) -> Result<HostIntegrationSnapshot, HostIntegrationActionError> {
    guard let appliedMutation else { return .failure(failure) }
    switch atomicallyReplaceLegacyWrapper(
        file: environment.legacyNotifyWrapper,
        expected: appliedMutation.replacement,
        replacement: appliedMutation.original,
        lockFile: environment.lockFile,
        beforeFinalPublish: environment.beforeLegacyWrapperFinalPublish)
    {
    case .success:
        return .failure(failure)
    case .failure(.failed(let rollbackReason)):
        return .failure(
            .migrationConflict(
                reason:
                    "\(failure.description)；旧 codex-notify 回滚失败：\(rollbackReason)"))
    }
}

private func atomicallyReplaceLegacyWrapper(
    file: URL,
    expected: Data,
    replacement: Data,
    lockFile: URL,
    beforeFinalPublish: @Sendable () -> Void
) -> Result<Void, LegacyWrapperWriteError> {
    let locked = withNonBlockingLock(path: lockFile.path) {
        guard case .data(let current) = readLegacyWrapperData(at: file), current == expected else {
            return Result<Void, LegacyWrapperWriteError>.failure(
                .failed("旧 codex-notify 在检测与迁移之间发生变化，已停止写入"))
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0o700
        let directory = file.deletingLastPathComponent()
        let staging = directory.appendingPathComponent(
            ".codex-notify.tmp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try replacement.write(to: staging, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions], ofItemAtPath: staging.path)
        } catch {
            return .failure(.failed("旧 codex-notify staging 写入失败：\(error.localizedDescription)"))
        }
        // Third-party notifiers do not participate in Claudio's host lock. Re-read the expected
        // bytes only after staging is complete, immediately beside the final rename boundary.
        beforeFinalPublish()
        guard case .data(let finalCurrent) = readLegacyWrapperData(at: file),
            finalCurrent == expected
        else {
            return .failure(
                .failed("旧 codex-notify 在 staging 与最终迁移之间发生变化，已停止写入"))
        }
        let renamed = staging.withUnsafeFileSystemRepresentation { source in
            file.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination else { return Int32(-1) }
                return Darwin.rename(source, destination)
            }
        }
        guard renamed == 0 else {
            let code = errno
            return .failure(
                .failed("旧 codex-notify 原子替换失败：\(String(cString: strerror(code)))"))
        }
        return .success(())
    }
    switch locked {
    case .ran(let result): return result
    case .skipped: return .failure(.failed("Codex integration lock 正忙，请重试"))
    case .failed(let code):
        return .failure(.failed("Codex integration lock 获取失败（errno \(code)）"))
    }
}

private func legacyConflictText(_ reason: LegacyCodexNotifyMigrationConflictReason) -> String {
    switch reason {
    case .configNotUTF8: "config.toml 不是有效 UTF-8"
    case .wrapperNotUTF8: "旧 codex-notify 不是有效 UTF-8"
    case .configMalformed: "config.toml 的 notify 语法无法安全解析"
    case .configDoesNotReferenceWrapper: "config.toml 没有引用当前 codex-notify"
    case .invalidCurrentPaths: "claudi0 root 或 binary 路径不合法"
    case .unknownOrModifiedWrapper: "codex-notify 未知或已被修改，拒绝安装可能重复的 Stop hook"
    case .differentClaudioBinary: "codex-notify 指向另一 claudi0 binary"
    }
}

extension IntegrationDataLoad {
    fileprivate var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

extension LegacyWrapperWriteError {
    fileprivate var reason: String {
        if case .failed(let reason) = self { return reason }
        return "旧 codex-notify 写入失败"
    }
}
