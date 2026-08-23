import Foundation

/// 验收证据的强度层级。只读 preflight 可以记录静态配置事实，但不能自行生成
/// Current Activation、RC 或人工正式验收证据。
public enum AcceptanceEvidenceLevel: String, Codable, Sendable, Equatable {
    case staticConfiguration = "static_configuration"
    case currentActivation = "current_activation"
    case releaseCandidate = "release_candidate"
    case manualAcceptance = "manual_acceptance"
}

public enum WorkBuddyEvidenceState: String, Codable, Sendable, Equatable {
    case recorded
    case partial
    case notObserved = "not_observed"
    case notEvaluated = "not_evaluated"
}

public enum WorkBuddyPreflightBindingState: String, Codable, Sendable, Equatable {
    case implementedNotActivated = "implemented_not_activated"
    case awaitingReceipt = "awaiting_receipt"
    case currentActivation = "current_activation"
    case notImplemented = "not_implemented"
}

/// WorkBuddy Desktop 的最小版本身份。只读取应用 bundle metadata，不读取宿主配置或 UI 内容。
public struct WorkBuddyApplicationIdentity: Codable, Sendable, Equatable {
    public let path: String
    public let bundleID: String?
    public let version: String?
    public let build: String?
    public let available: Bool

    public init(
        path: String,
        bundleID: String?,
        version: String?,
        build: String?,
        available: Bool
    ) {
        self.path = path
        self.bundleID = bundleID
        self.version = version
        self.build = build
        self.available = available
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case bundleID = "bundle_id"
        case version
        case build
        case available
    }

    public static func detect(
        at path: URL = URL(fileURLWithPath: "/Applications/WorkBuddy.app")
    ) -> WorkBuddyApplicationIdentity {
        let normalizedPath = path.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: normalizedPath, isDirectory: &isDirectory)
        let bundle = exists && isDirectory.boolValue ? Bundle(path: normalizedPath) : nil
        return WorkBuddyApplicationIdentity(
            path: normalizedPath,
            bundleID: bundle.flatMap { stringValue(for: "CFBundleIdentifier", in: $0) },
            version: bundle.flatMap { stringValue(for: "CFBundleShortVersionString", in: $0) },
            build: bundle.flatMap { stringValue(for: "CFBundleVersion", in: $0) },
            available: bundle != nil)
    }

    private static func stringValue(for key: String, in bundle: Bundle) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 本机身份只保留验收需要的 macOS 与 CPU 字段，不包含用户名、主机名或路径扫描结果。
public struct WorkBuddyMachineIdentity: Codable, Sendable, Equatable {
    public let macOSVersion: String
    public let cpuArchitecture: String

    public init(macOSVersion: String, cpuArchitecture: String) {
        self.macOSVersion = macOSVersion
        self.cpuArchitecture = cpuArchitecture
    }

    private enum CodingKeys: String, CodingKey {
        case macOSVersion = "macos_version"
        case cpuArchitecture = "cpu_architecture"
    }

    public static func current() -> WorkBuddyMachineIdentity {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let macOSVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        return WorkBuddyMachineIdentity(
            macOSVersion: macOSVersion,
            cpuArchitecture: currentCPUArchitecture())
    }

    private static func currentCPUArchitecture() -> String {
        #if canImport(Darwin)
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return "unknown" }
        return withUnsafeBytes(of: systemInfo.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        #else
        return "unknown"
        #endif
    }
}

public struct WorkBuddyPreflightObservation: Codable, Sendable, Equatable {
    public let available: String
    public let runtime: String
    public let writability: String
    public let configuration: String
    public let activation: String
    public let installationID: UUID?

    public init(
        available: String,
        runtime: String,
        writability: String,
        configuration: String,
        activation: String,
        installationID: UUID?
    ) {
        self.available = available
        self.runtime = runtime
        self.writability = writability
        self.configuration = configuration
        self.activation = activation
        self.installationID = installationID
    }

    private enum CodingKeys: String, CodingKey {
        case available
        case runtime
        case writability
        case configuration
        case activation
        case installationID = "installation_id"
    }
}

public struct WorkBuddyPreflightScopeIdentity: Codable, Sendable, Equatable {
    public let host: String
    public let hostSurface: String
    public let installationID: UUID?
    public let fingerprint: String?
    public let implementedBindingIDs: [String]

    public init(
        host: String,
        hostSurface: String,
        installationID: UUID?,
        fingerprint: String?,
        implementedBindingIDs: [String]
    ) {
        self.host = host
        self.hostSurface = hostSurface
        self.installationID = installationID
        self.fingerprint = fingerprint
        self.implementedBindingIDs = implementedBindingIDs
    }

    private enum CodingKeys: String, CodingKey {
        case host
        case hostSurface = "host_surface"
        case installationID = "installation_id"
        case fingerprint
        case implementedBindingIDs = "implemented_binding_ids"
    }
}

public struct WorkBuddyPreflightBinding: Codable, Sendable, Equatable {
    public let id: String
    public let nativeEvent: String?
    public let event: Event
    public let support: HostCapabilitySupport
    public let implementation: HostCapabilityImplementation
    public let state: WorkBuddyPreflightBindingState
    public let evidenceLevel: AcceptanceEvidenceLevel

    public init(
        id: String,
        nativeEvent: String?,
        event: Event,
        support: HostCapabilitySupport,
        implementation: HostCapabilityImplementation,
        state: WorkBuddyPreflightBindingState,
        evidenceLevel: AcceptanceEvidenceLevel
    ) {
        self.id = id
        self.nativeEvent = nativeEvent
        self.event = event
        self.support = support
        self.implementation = implementation
        self.state = state
        self.evidenceLevel = evidenceLevel
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case nativeEvent = "native_event"
        case event
        case support
        case implementation
        case state
        case evidenceLevel = "evidence_level"
    }
}

public struct WorkBuddyPreflightSoundResult: Codable, Sendable, Equatable {
    public let event: Event
    public let nativeEvent: String
    public let result: String
    public let evidenceLevel: AcceptanceEvidenceLevel

    public init(
        event: Event,
        nativeEvent: String,
        result: String,
        evidenceLevel: AcceptanceEvidenceLevel
    ) {
        self.event = event
        self.nativeEvent = nativeEvent
        self.result = result
        self.evidenceLevel = evidenceLevel
    }

    private enum CodingKeys: String, CodingKey {
        case event
        case nativeEvent = "native_event"
        case result
        case evidenceLevel = "evidence_level"
    }
}

public struct WorkBuddyPreflightCLIStatus: Codable, Sendable, Equatable {
    public let integrationsStatus: String
    public let doctor: String
    public let workBuddyDoctor: String
    public let evidenceLevel: AcceptanceEvidenceLevel

    public init(
        integrationsStatus: String,
        doctor: String,
        workBuddyDoctor: String,
        evidenceLevel: AcceptanceEvidenceLevel
    ) {
        self.integrationsStatus = integrationsStatus
        self.doctor = doctor
        self.workBuddyDoctor = workBuddyDoctor
        self.evidenceLevel = evidenceLevel
    }

    private enum CodingKeys: String, CodingKey {
        case integrationsStatus = "integrations_status"
        case doctor
        case workBuddyDoctor = "workbuddy_doctor"
        case evidenceLevel = "evidence_level"
    }
}

public struct WorkBuddyPreflightGUIStatus: Codable, Sendable, Equatable {
    public let state: String
    public let evidenceLevel: AcceptanceEvidenceLevel

    public init(state: String, evidenceLevel: AcceptanceEvidenceLevel) {
        self.state = state
        self.evidenceLevel = evidenceLevel
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case evidenceLevel = "evidence_level"
    }
}

public struct WorkBuddyPreflightEvidenceSummary: Codable, Sendable, Equatable {
    public let staticConfiguration: WorkBuddyEvidenceState
    public let currentActivation: WorkBuddyEvidenceState
    public let releaseCandidate: WorkBuddyEvidenceState
    public let manualAcceptance: WorkBuddyEvidenceState

    public init(
        staticConfiguration: WorkBuddyEvidenceState,
        currentActivation: WorkBuddyEvidenceState,
        releaseCandidate: WorkBuddyEvidenceState,
        manualAcceptance: WorkBuddyEvidenceState
    ) {
        self.staticConfiguration = staticConfiguration
        self.currentActivation = currentActivation
        self.releaseCandidate = releaseCandidate
        self.manualAcceptance = manualAcceptance
    }

    private enum CodingKeys: String, CodingKey {
        case staticConfiguration = "static_configuration"
        case currentActivation = "current_activation"
        case releaseCandidate = "release_candidate"
        case manualAcceptance = "manual_acceptance"
    }
}

public struct WorkBuddyPreflightSafety: Codable, Sendable, Equatable {
    public let readOnly: Bool
    public let invokedMutatingActions: [String]
    public let automaticAudioPreview: Bool
    public let rawUserDataPersisted: Bool

    public init(
        readOnly: Bool,
        invokedMutatingActions: [String],
        automaticAudioPreview: Bool,
        rawUserDataPersisted: Bool
    ) {
        self.readOnly = readOnly
        self.invokedMutatingActions = invokedMutatingActions
        self.automaticAudioPreview = automaticAudioPreview
        self.rawUserDataPersisted = rawUserDataPersisted
    }

    private enum CodingKeys: String, CodingKey {
        case readOnly = "read_only"
        case invokedMutatingActions = "invoked_mutating_actions"
        case automaticAudioPreview = "automatic_audio_preview"
        case rawUserDataPersisted = "raw_user_data_persisted"
    }
}

/// 可提交到本地验收账本的脱敏 WorkBuddy preflight。它不携带配置 JSON、备份、prompt、
/// response、receipt 原文件或日志；真实回执只被压缩为 binding 与 playback result 摘要。
public struct WorkBuddyAcceptancePreflight: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public let schema: Int
    public let collectedAt: Date
    public let commitSHA: String
    public let claudioVersion: String
    public let workBuddy: WorkBuddyApplicationIdentity
    public let machine: WorkBuddyMachineIdentity
    public let scope: WorkBuddyPreflightScopeIdentity
    public let inspect: WorkBuddyPreflightObservation
    public let integrationsStatus: WorkBuddyPreflightObservation
    public let observationsAgree: Bool
    public let bindings: [WorkBuddyPreflightBinding]
    public let soundResults: [WorkBuddyPreflightSoundResult]
    public let cli: WorkBuddyPreflightCLIStatus
    public let gui: WorkBuddyPreflightGUIStatus
    public let evidence: WorkBuddyPreflightEvidenceSummary
    public let safety: WorkBuddyPreflightSafety

    private enum CodingKeys: String, CodingKey {
        case schema
        case collectedAt = "collected_at"
        case commitSHA = "commit_sha"
        case claudioVersion = "claudio_version"
        case workBuddy = "workbuddy"
        case machine
        case scope
        case inspect
        case integrationsStatus = "integrations_status"
        case observationsAgree = "observations_agree"
        case bindings
        case soundResults = "sound_results"
        case cli
        case gui
        case evidence
        case safety
    }

    public init(
        commitSHA: String,
        claudioVersion: String,
        workBuddy: WorkBuddyApplicationIdentity,
        machine: WorkBuddyMachineIdentity,
        inspectedSnapshot: HostIntegrationSnapshot,
        statusSnapshot: HostIntegrationSnapshot,
        workBuddyDoctor: DoctorSeverity,
        overallDoctor: DoctorSeverity,
        scopeFingerprint: String?,
        collectedAt: Date = Date()
    ) {
        let catalog = HostCapabilityCatalog.bindings(for: .workBuddy)
        let inspected = Self.observation(from: inspectedSnapshot)
        let status = Self.observation(from: statusSnapshot)
        let bindings = catalog.map { binding in
            Self.bindingSummary(binding: binding, snapshot: statusSnapshot)
        }
        let currentBindingCount = bindings.filter { $0.state == .currentActivation }.count
        let implementedBindingCount = bindings.filter { $0.implementation == .implemented }.count
        let currentActivation: WorkBuddyEvidenceState
        if currentBindingCount == implementedBindingCount, implementedBindingCount > 0 {
            currentActivation = .recorded
        } else if currentBindingCount > 0 {
            currentActivation = .partial
        } else {
            currentActivation = .notObserved
        }

        self.schema = Self.currentSchema
        self.collectedAt = collectedAt
        self.commitSHA = commitSHA
        self.claudioVersion = claudioVersion
        self.workBuddy = workBuddy
        self.machine = machine
        self.scope = WorkBuddyPreflightScopeIdentity(
            host: HostID.workBuddy.rawValue,
            hostSurface: HostSurfaceID.workBuddy.rawValue,
            installationID: statusSnapshot.installationID,
            fingerprint: scopeFingerprint,
            implementedBindingIDs:
                catalog
                .filter { $0.implementation == .implemented }
                .map(\.id.rawValue))
        self.inspect = inspected
        self.integrationsStatus = status
        self.observationsAgree = inspected == status
        self.bindings = bindings
        self.soundResults =
            catalog
            .filter(\.isAudibleCapability)
            .compactMap { Self.soundResult(binding: $0, snapshot: statusSnapshot) }
        self.cli = WorkBuddyPreflightCLIStatus(
            integrationsStatus: "collected",
            doctor: overallDoctor.rawValue,
            workBuddyDoctor: workBuddyDoctor.rawValue,
            evidenceLevel: .staticConfiguration)
        self.gui = WorkBuddyPreflightGUIStatus(
            state: "not_run", evidenceLevel: .manualAcceptance)
        self.evidence = WorkBuddyPreflightEvidenceSummary(
            staticConfiguration: .recorded,
            currentActivation: currentActivation,
            releaseCandidate: .notEvaluated,
            manualAcceptance: .notEvaluated)
        self.safety = WorkBuddyPreflightSafety(
            readOnly: true,
            invokedMutatingActions: [],
            automaticAudioPreview: false,
            rawUserDataPersisted: false)
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public func markdown() -> String {
        let bindingRows = bindings.map { binding in
            let nativeEvent = binding.nativeEvent ?? "—"
            return
                "| `\(binding.event.cliName)` | `\(nativeEvent)` | `\(binding.implementation.rawValue)` | `\(binding.state.rawValue)` |"
        }.joined(separator: "\n")
        let soundRows = soundResults.map { result in
            "| `\(result.event.cliName)` | `\(result.result)` | `\(result.evidenceLevel.rawValue)` |"
        }.joined(separator: "\n")
        return """
            # WorkBuddy read-only acceptance preflight

            - Schema: `\(schema)`
            - Collected at: `\(collectedAt.iso8601String())`
            - Commit SHA: `\(commitSHA)`
            - Claudio version: `\(claudioVersion)`
            - WorkBuddy: `\(workBuddy.bundleID ?? "unavailable")` `\(workBuddy.version ?? "unavailable")` build `\(workBuddy.build ?? "unavailable")`
            - macOS / CPU: `\(machine.macOSVersion)` / `\(machine.cpuArchitecture)`
            - Installation: `\(scope.installationID?.uuidString ?? "none")`
            - Scope fingerprint: `\(scope.fingerprint ?? "unavailable")`

            ## Read-only observations

            | Source | available | runtime | writability | configuration | activation |
            |---|---|---|---|---|---|
            | Inspect | `\(inspect.available)` | `\(inspect.runtime)` | `\(inspect.writability)` | `\(inspect.configuration)` | `\(inspect.activation)` |
            | integrations status | `\(integrationsStatus.available)` | `\(integrationsStatus.runtime)` | `\(integrationsStatus.writability)` | `\(integrationsStatus.configuration)` | `\(integrationsStatus.activation)` |

            Observations agree: `\(observationsAgree)`.

            ## Host Event Binding baseline

            | Event | Native event | Implementation | State |
            |---|---|---|---|
            \(bindingRows)

            ## Sound results

            | Event | Result | Evidence |
            |---|---|---|
            \(soundRows)

            ## Evidence levels

            - Static configuration: `\(evidence.staticConfiguration.rawValue)`
            - Current Activation: `\(evidence.currentActivation.rawValue)`
            - RC: `\(evidence.releaseCandidate.rawValue)`
            - Manual acceptance: `\(evidence.manualAcceptance.rawValue)`

            ## Safety boundary

            - Read-only: `\(safety.readOnly)`
            - Mutating actions invoked: `\(safety.invokedMutatingActions.isEmpty ? "none" : safety.invokedMutatingActions.joined(separator: ", "))`
            - Automatic audio preview: `\(safety.automaticAudioPreview)`
            - Raw user data persisted: `\(safety.rawUserDataPersisted)`
            """
    }

    private static func observation(
        from snapshot: HostIntegrationSnapshot
    ) -> WorkBuddyPreflightObservation {
        WorkBuddyPreflightObservation(
            available: availabilityStatus(snapshot.availability),
            runtime: runtimeStatus(snapshot.runtime),
            writability: writabilityStatus(snapshot.writability),
            configuration: configurationStatus(snapshot.configuration),
            activation: activationStatus(snapshot.activation),
            installationID: snapshot.installationID)
    }

    private static func bindingSummary(
        binding: HostCapabilityBinding,
        snapshot: HostIntegrationSnapshot
    ) -> WorkBuddyPreflightBinding {
        let state: WorkBuddyPreflightBindingState
        let evidenceLevel: AcceptanceEvidenceLevel
        if binding.implementation == .notImplemented {
            state = .notImplemented
            evidenceLevel = .staticConfiguration
        } else {
            switch snapshot.activation(for: binding) {
            case .none:
                state = .implementedNotActivated
                evidenceLevel = .staticConfiguration
            case .awaitingReceipt:
                state = .awaitingReceipt
                evidenceLevel = .staticConfiguration
            case .observed:
                state = .currentActivation
                evidenceLevel = .currentActivation
            }
        }
        return WorkBuddyPreflightBinding(
            id: binding.id.rawValue,
            nativeEvent: binding.nativeEvent,
            event: binding.event,
            support: binding.support,
            implementation: binding.implementation,
            state: state,
            evidenceLevel: evidenceLevel)
    }

    private static func soundResult(
        binding: HostCapabilityBinding,
        snapshot: HostIntegrationSnapshot
    ) -> WorkBuddyPreflightSoundResult? {
        guard let nativeEvent = binding.nativeEvent else { return nil }
        let result: String
        let evidenceLevel: AcceptanceEvidenceLevel
        switch snapshot.activation(for: binding) {
        case .observed(let evidence):
            result = evidence.playbackResult.rawValue
            evidenceLevel = .currentActivation
        case .none, .awaitingReceipt:
            result = "not_tested"
            evidenceLevel = .staticConfiguration
        }
        return WorkBuddyPreflightSoundResult(
            event: binding.event,
            nativeEvent: nativeEvent,
            result: result,
            evidenceLevel: evidenceLevel)
    }

    private static func availabilityStatus(_ availability: HostAvailability) -> String {
        switch availability {
        case .available: "available"
        case .unavailable: "unavailable"
        }
    }

    private static func runtimeStatus(_ runtime: SharedRuntimeHealth) -> String {
        switch runtime {
        case .ready: "ready"
        case .unavailable: "unavailable"
        case .damaged: "damaged"
        }
    }

    private static func writabilityStatus(_ writability: HostConfigWritability) -> String {
        switch writability {
        case .writable: "writable"
        case .notWritable: "not_writable"
        case .unknown: "unknown"
        }
    }

    private static func configurationStatus(_ configuration: HostConfigurationState) -> String {
        switch configuration {
        case .notConfigured: "not_configured"
        case .legacyConnected: "legacy_connected"
        case .configured: "configured"
        case .incomplete: "incomplete"
        case .unreadable: "unreadable"
        case .conflict: "conflict"
        }
    }

    private static func activationStatus(_ activation: HostActivationEvidence) -> String {
        switch activation {
        case .none: "none"
        case .awaitingReceipt: "awaiting_receipt"
        case .observed: "observed"
        }
    }
}

extension Date {
    fileprivate func iso8601String() -> String {
        ISO8601DateFormatter().string(from: self)
    }
}
