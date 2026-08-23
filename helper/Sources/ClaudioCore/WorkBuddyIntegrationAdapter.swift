import Foundation

public struct WorkBuddyIntegrationEnvironment: Sendable {
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
        settingsFile: URL = ClaudioPaths.workBuddySettingsFile,
        lockFile: URL = ClaudioPaths.workBuddyIntegrationLockFile,
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
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: "/Applications/WorkBuddy.app", isDirectory: &isDirectory)
                && isDirectory.boolValue
                ? .available : .unavailable(reason: "未检测到 WorkBuddy Desktop")
        }
    ) {
        self.settingsFile = settingsFile
        self.lockFile = lockFile
        self.operationLockFile =
            operationLockFile
            ?? lockFile.deletingLastPathComponent().appendingPathComponent(
                "\(HostID.workBuddy.rawValue)-operation.lock")
        self.backupFile =
            backupFile
            ?? settingsFile.deletingLastPathComponent().appendingPathComponent(
                settingsFile.lastPathComponent + ".claudio.bak")
        self.claudioBinaryPath = claudioBinaryPath
        self.claudioRoot = claudioRoot
        self.receiptStore = receiptStore
        self.availability = availability
        self.scopeFingerprint =
            scopeFingerprint ?? {
                guard let bundle = Bundle(path: "/Applications/WorkBuddy.app"),
                    let version = bundle.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                    !version.isEmpty
                else { return nil }
                let bindingSchema = HostCapabilityCatalog.bindings(for: .workBuddy)
                    .filter(\.isAudibleCapability)
                    .map(\.id.rawValue)
                    .joined(separator: ",")
                return "app=\(version);runtime=\(ClaudioVersion.current);bindings=\(bindingSchema)"
            }
    }
}

public struct WorkBuddyIntegrationAdapter: HostIntegrationAdapter {
    public let environment: WorkBuddyIntegrationEnvironment
    public var host: HostID { .workBuddy }
    public var capabilities: [HostCapabilityBinding] {
        HostCapabilityCatalog.bindings(for: .workBuddy)
    }

    public init(environment: WorkBuddyIntegrationEnvironment = .init()) {
        self.environment = environment
    }

    public func inspect(runtime: SharedRuntimeHealth) async -> HostIntegrationSnapshot {
        inspectWorkBuddySnapshot(environment: environment, runtime: runtime)
    }

    public func connect(
        runtime: SharedRuntimeHealth
    ) async -> Result<HostIntegrationSnapshot, HostIntegrationActionError> {
        withHostIntegrationOperationLock(path: environment.operationLockFile) {
            guard runtime == .ready else {
                return .failure(.runtimeUnavailable(reason: workBuddyRuntimeReason(runtime)))
            }
            if case .unavailable(let reason) = environment.availability() {
                return .failure(.hostUnavailable(reason: reason))
            }
            guard let scopeFingerprint = environment.scopeFingerprint() else {
                return .failure(
                    .configuration(reason: "无法读取 WorkBuddy/Claudio 版本身份；已拒绝写入连接"))
            }
            let transaction = ConfigFileTransaction(
                file: environment.settingsFile,
                lockFile: environment.lockFile,
                backupFile: environment.backupFile,
                symlinkPolicy: .preserveTarget)
            let requestedInstallationID = UUID()
            var transformError: HostHooksTransformError?
            let result = transaction.update { root in
                switch connectWorkBuddyHooks(
                    root: root,
                    claudioRoot: environment.claudioRoot,
                    claudioBinaryPath: environment.claudioBinaryPath,
                    installationID: requestedInstallationID)
                {
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
            let installationID: UUID?
            switch loadWorkBuddyRoot(at: environment.settingsFile) {
            case .root(let root):
                if case .success(.configured(let id)) = inspectWorkBuddyHooks(
                    root: root,
                    claudioBinaryPath: environment.claudioBinaryPath)
                {
                    installationID = id
                } else {
                    installationID = nil
                }
            case .missing, .failure:
                installationID = nil
            }
            guard let installationID else {
                return .failure(
                    .configuration(reason: "WorkBuddy 写入后未形成完整的 claudi0 installation ID"))
            }
            if case .failure(let error) = environment.receiptStore.activate(
                host: .workBuddy,
                installationID: installationID,
                scopeFingerprint: scopeFingerprint)
            {
                return .failure(
                    .configuration(reason: "WorkBuddy 当前连接代次发布失败：\(error.description)"))
            }
            return .success(inspectWorkBuddySnapshot(environment: environment, runtime: runtime))
        }
    }

    public func disconnect(
        runtime: SharedRuntimeHealth
    ) async -> Result<HostIntegrationSnapshot, HostIntegrationActionError> {
        withHostIntegrationOperationLock(path: environment.operationLockFile) {
            let installationID =
                environment.receiptStore.currentInstallationID(host: .workBuddy)
                ?? inspectWorkBuddySnapshot(environment: environment, runtime: runtime)
                .installationID
            if let installationID,
                case .failure(let error) = environment.receiptStore.deactivate(
                    host: .workBuddy, installationID: installationID)
            {
                return .failure(
                    .configuration(reason: "WorkBuddy 当前连接代次撤销失败：\(error.description)"))
            }
            guard FileManager.default.fileExists(atPath: environment.settingsFile.path) else {
                return .success(
                    inspectWorkBuddySnapshot(environment: environment, runtime: runtime))
            }
            let transaction = ConfigFileTransaction(
                file: environment.settingsFile,
                lockFile: environment.lockFile,
                backupFile: nil,
                symlinkPolicy: .preserveTarget)
            var transformError: HostHooksTransformError?
            let result = transaction.update { root in
                switch disconnectWorkBuddyHooks(root: root, claudioRoot: environment.claudioRoot) {
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
            return .success(inspectWorkBuddySnapshot(environment: environment, runtime: runtime))
        }
    }
}

public func inspectWorkBuddySnapshot(
    environment: WorkBuddyIntegrationEnvironment,
    runtime: SharedRuntimeHealth
) -> HostIntegrationSnapshot {
    let availability = environment.availability()
    var configuration: HostConfigurationState
    var installationID: UUID?
    switch loadWorkBuddyRoot(at: environment.settingsFile) {
    case .missing:
        configuration = .notConfigured
    case .failure(let reason):
        configuration = .unreadable(reason: reason)
    case .root(let root):
        switch inspectWorkBuddyHooks(root: root, claudioBinaryPath: environment.claudioBinaryPath) {
        case .failure(let error):
            configuration = .unreadable(reason: error.description)
        case .success(.notConfigured):
            configuration = .notConfigured
        case .success(.configured(let id)):
            configuration = .configured
            installationID = id
        case .success(.partial(let id, let missing)):
            configuration = .incomplete(missingNativeEvents: missing)
            installationID = id
        case .success(.conflict(let reason)):
            configuration = .conflict(reason: reason)
        }
    }
    if configuration == .configured,
        environment.receiptStore.currentInstallationID(host: .workBuddy) == installationID
    {
        guard let currentScope = environment.scopeFingerprint() else {
            configuration = .conflict(reason: "无法读取 WorkBuddy/Claudio 版本身份，请修复连接")
            return makeIntegrationSnapshot(
                host: .workBuddy,
                runtime: runtime,
                availability: availability,
                configuration: configuration,
                installationID: installationID,
                file: environment.settingsFile,
                receiptStore: environment.receiptStore)
        }
        if environment.receiptStore.currentInstallationScopeFingerprint(host: .workBuddy)
            != currentScope
        {
            configuration = .conflict(reason: "WorkBuddy 或 Claudio 版本已变化，旧回执已失效；请修复连接")
        }
    }
    return makeIntegrationSnapshot(
        host: .workBuddy,
        runtime: runtime,
        availability: availability,
        configuration: configuration,
        installationID: installationID,
        file: environment.settingsFile,
        receiptStore: environment.receiptStore)
}

private enum WorkBuddyRootLoad {
    case missing
    case root([String: Any])
    case failure(String)
}

private func loadWorkBuddyRoot(at file: URL) -> WorkBuddyRootLoad {
    guard FileManager.default.fileExists(atPath: file.path) else { return .missing }
    guard
        case .success(let data) = readRegularFileBounded(
            at: file, maxBytes: 1 << 20, followSymlink: true)
    else {
        return .failure("WorkBuddy 配置文件无法安全读取：\(file.path)")
    }
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return .failure("WorkBuddy settings.json 顶层必须是 JSON object：\(file.path)")
    }
    return .root(root)
}

private func workBuddyRuntimeReason(_ health: SharedRuntimeHealth) -> String {
    switch health {
    case .ready: "已就绪"
    case .unavailable(let reason), .damaged(let reason): reason
    }
}
