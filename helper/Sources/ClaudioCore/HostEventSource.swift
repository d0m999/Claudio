import CoreFoundation
import CryptoKit
import Foundation

/// 来源字段的可读完整度。它描述当前 payload 中实际得到的字段，不代表宿主一定支持更多
/// 字段，也不允许 UI 用上一条记录补齐缺失值。
public enum HostEventSourceCompleteness: String, Codable, Sendable, Equatable {
    case complete
    case partial
    case unknown
}

public enum HostEventSourceUnavailableReason: String, Codable, Sendable, Equatable {
    case empty
    case invalidJSON = "invalid_json"
    case notObject = "not_object"
    case unsupportedHost = "unsupported_host"
    case duplicateField = "duplicate_field"
    case invalidFieldType = "invalid_field_type"
    case unsafeField = "unsafe_field"
    case oversized = "oversized"
}

/// 从宿主 hook 中提取的最少安全来源。原始 `cwd` 只在解析函数的局部变量中存在；
/// `projectKey` 是不可逆的内存匹配 key，不是可展示路径，也不会写入回执或配置。
public struct HostEventSource: Codable, Sendable, Equatable, Hashable {
    public let projectLabel: String?
    public let projectKey: String?
    public let sessionID: String?
    public let sessionLabel: String?
    public let isParentSession: Bool
    /// nil for legacy/incomplete input; false is not evidence of a main-session identity.
    public let mainSessionIsKnown: Bool?
    public let completeness: HostEventSourceCompleteness

    public init(
        projectLabel: String?,
        projectKey: String? = nil,
        sessionID: String?,
        sessionLabel: String? = nil,
        isParentSession: Bool = false,
        completeness: HostEventSourceCompleteness? = nil,
        mainSessionIsKnown: Bool? = nil
    ) {
        self.projectLabel = projectLabel
        self.projectKey = projectKey
        self.sessionID = sessionID
        self.sessionLabel = sessionLabel
        self.isParentSession = isParentSession
        self.mainSessionIsKnown = mainSessionIsKnown
        self.completeness =
            completeness
            ?? HostEventSourceCompleteness.forFields(
                hasProject: projectLabel != nil,
                hasSession: sessionID != nil)
    }

    /// Cross-process notices are decoded from an untrusted datagram. Keep the display identity
    /// bounded and free of control/bidi characters even when a caller bypasses the host parser.
    public var isSemanticallyValid: Bool {
        let projectIsValid =
            projectLabel.map { value in
                !value.isEmpty
                    && value.unicodeScalars.count
                        <= HostEventSourceParser.maximumProjectLabelScalars
                    && !Self.containsUnsafeScalar(value)
            } ?? true
        let keyIsValid =
            projectKey.map { value in
                !value.isEmpty
                    && value.utf8.count <= 256
                    && !Self.containsUnsafeScalar(value)
            } ?? true
        let sessionIsValid =
            sessionID.map { value in
                !value.isEmpty
                    && value.utf8.count <= HostEventSourceParser.maximumSessionIDBytes
                    && !Self.containsUnsafeScalar(value)
                    && !value.contains(where: { $0.isWhitespace })
            } ?? true
        let labelIsValid =
            sessionLabel.map { value in
                !value.isEmpty
                    && value.utf8.count <= HostEventSourceParser.maximumDisplayBytes
                    && !Self.containsUnsafeScalar(value)
            } ?? true
        let expectedCompleteness = HostEventSourceCompleteness.forFields(
            hasProject: projectLabel != nil,
            hasSession: sessionID != nil)
        return projectIsValid && keyIsValid && sessionIsValid && labelIsValid
            && completeness == expectedCompleteness
            && !(isParentSession && mainSessionIsKnown == true)
    }

    private enum CodingKeys: String, CodingKey {
        case projectLabel = "project_label"
        case projectKey = "project_key"
        case sessionID = "session_id"
        case sessionLabel = "session_label"
        case isParentSession = "is_parent_session"
        case mainSessionIsKnown = "main_session_is_known"
        case completeness
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        projectLabel = try values.decodeIfPresent(String.self, forKey: .projectLabel)
        projectKey = try values.decodeIfPresent(String.self, forKey: .projectKey)
        sessionID = try values.decodeIfPresent(String.self, forKey: .sessionID)
        sessionLabel = try values.decodeIfPresent(String.self, forKey: .sessionLabel)
        isParentSession = try values.decode(Bool.self, forKey: .isParentSession)
        completeness = try values.decode(HostEventSourceCompleteness.self, forKey: .completeness)
        mainSessionIsKnown = try? values.decode(Bool.self, forKey: .mainSessionIsKnown)
    }

    /// Single owner of the unsafe-scalar rule. The parser and cross-process validation both
    /// reuse it so an untrusted datagram can never meet a looser second copy.
    static func containsUnsafeScalar(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            let number = scalar.value
            return number <= 0x1F || number == 0x7F || (0x80...0x9F).contains(number)
                || [
                    0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                    0x2066, 0x2067, 0x2068, 0x2069,
                ].contains(Int(number))
        }
    }

    /// Single owner of the bounded display-size rule shared by the parser and notice validation.
    static func displayBytes(of source: HostEventSource) -> Int {
        [source.projectLabel, source.sessionLabel, source.sessionID]
            .compactMap { $0 }
            .reduce(0) { $0 + $1.utf8.count }
    }

    /// Shared sanitize preamble: fold line/tab breaks into spaces, reject unsafe scalars,
    /// collapse whitespace runs. Returns nil when nothing safe remains.
    static func normalizeWhitespace(_ value: String) -> String? {
        let folded = value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        guard !containsUnsafeScalar(folded) else { return nil }
        let normalized = folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}

extension HostEventSourceCompleteness {
    fileprivate static func forFields(hasProject: Bool, hasSession: Bool) -> Self {
        switch (hasProject, hasSession) {
        case (true, true): .complete
        case (true, false), (false, true): .partial
        case (false, false): .unknown
        }
    }
}

public enum HostEventSourceParseOutcome: Sendable, Equatable {
    case available(HostEventSource)
    case unavailable(reason: HostEventSourceUnavailableReason, partial: HostEventSource?)

    public var source: HostEventSource? {
        switch self {
        case .available(let source): source
        case .unavailable(_, let partial): partial
        }
    }

    public var completeness: HostEventSourceCompleteness {
        source?.completeness ?? .unknown
    }
}

public struct HostEventInput: Sendable, Equatable {
    public let source: HostEventSourceParseOutcome
    public let reason: HostEventNoticeReason?
}

/// 宿主来源解析器只认识各 adapter 明确列入合同的字段。
public enum HostEventSourceParser {
    public static let maximumProjectLabelScalars = 128
    public static let maximumSessionIDBytes = 256
    public static let maximumDisplayBytes = 1 << 10

    public static func parse(host: HostID, data: Data?) -> HostEventSourceParseOutcome {
        parseInput(host: host, nativeEvent: nil, data: data).source
    }

    /// Decode the bounded object once, then independently project source and notification reason.
    /// Neither projection reads message, title, prompt, response, or transcript contents.
    public static func parseInput(
        host: HostID, nativeEvent: String?, data: Data?
    ) -> HostEventInput {
        let fallback = normalizedReason(host: host, nativeEvent: nativeEvent, dictionary: nil)
        func unavailable(_ reason: HostEventSourceUnavailableReason) -> HostEventInput {
            HostEventInput(source: .unavailable(reason: reason, partial: nil), reason: fallback)
        }
        guard let data, !data.isEmpty else { return unavailable(.empty) }
        guard data.count <= HookInputReader.defaultMaximumBytes else {
            return unavailable(.oversized)
        }
        guard host == .claudeCode || host == .codex else { return unavailable(.unsupportedHost) }
        guard
            let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return unavailable(.invalidJSON) }
        guard let dictionary = object as? [String: Any] else { return unavailable(.notObject) }
        let duplicateKeys = duplicateTopLevelKeys(data)
        let reason = normalizedReason(
            host: host, nativeEvent: nativeEvent,
            dictionary: duplicateKeys.contains("notification_type")
                || duplicateKeys.contains("hook_event_name") ? nil : dictionary)
        let sourceKeys: Set<String> = [
            "cwd", "session_id", "agent_id", "is_subagent", "subagent", "hook_event_name",
        ]
        guard duplicateKeys.isDisjoint(with: sourceKeys) else {
            return HostEventInput(
                source: .unavailable(reason: .duplicateField, partial: nil), reason: reason)
        }
        return HostEventInput(
            source: parseSource(host: host, nativeEvent: nativeEvent, dictionary: dictionary),
            reason: reason)
    }

    private static func normalizedReason(
        host: HostID, nativeEvent: String?, dictionary: [String: Any]?
    ) -> HostEventNoticeReason? {
        guard let nativeEvent,
            let binding = HostCapabilityCatalog.binding(host: host, nativeEvent: nativeEvent),
            binding.event == .notification
        else { return nil }
        if host == .codex, nativeEvent == "PermissionRequest" { return .permission }
        guard host == .claudeCode, nativeEvent == "Notification" else { return .review }
        if let payloadEvent = dictionary?["hook_event_name"],
            (payloadEvent as? String) != nativeEvent
        {
            return .review
        }
        // Official Notification matcher contract, checked 2026-09-12:
        // https://code.claude.com/docs/en/hooks#notification
        switch dictionary?["notification_type"] as? String {
        case "permission_prompt": return .permission
        case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input": return .needsInput
        case "idle_prompt", "auth_success", "elicitation_complete", "elicitation_response",
            "agent_completed", "quota_auto_resume_fired":
            return .informational
        default: return .review
        }
    }

    private static func parseSource(
        host: HostID, nativeEvent: String?, dictionary: [String: Any]
    ) -> HostEventSourceParseOutcome {
        let cwdResult = stringField(named: "cwd", in: dictionary)
        let sessionResult = stringField(named: "session_id", in: dictionary)
        let parent = parentSessionField(host: host, nativeEvent: nativeEvent, in: dictionary)
        let projectInfo = cwdResult.value.flatMap { Self.project(from: $0) }
        // A malformed parent marker must not turn its parent session ID into a main target.
        let safeSession =
            parent.invalid
            ? nil
            : sessionResult.value.flatMap {
                sanitizeIdentifier($0, maximumBytes: maximumSessionIDBytes)
            }
        let source: HostEventSource? =
            projectInfo != nil || safeSession != nil
            ? HostEventSource(
                projectLabel: projectInfo?.label,
                projectKey: projectInfo?.key,
                sessionID: safeSession,
                isParentSession: parent.value,
                mainSessionIsKnown: parent.mainKnown ? true : nil)
            : nil
        if cwdResult == .invalid || sessionResult == .invalid || parent.invalid {
            return .unavailable(reason: .invalidFieldType, partial: source)
        }
        if (cwdResult.value != nil && projectInfo == nil)
            || (sessionResult.value != nil && safeSession == nil)
        {
            return .unavailable(reason: .unsafeField, partial: source)
        }
        guard let source else { return .unavailable(reason: .empty, partial: nil) }
        guard HostEventSource.displayBytes(of: source) <= maximumDisplayBytes else {
            return .unavailable(reason: .oversized, partial: nil)
        }
        return .available(source)
    }

    private static func project(from cwd: String) -> (label: String, key: String)? {
        guard cwd.hasPrefix("/"), let rawLabel = cwd.split(separator: "/").last else {
            return nil
        }
        guard
            let label = sanitizeLabel(String(rawLabel), maximumScalars: maximumProjectLabelScalars),
            !label.isEmpty
        else { return nil }
        let digest = SHA256.hash(data: Data(cwd.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined()
        return (label, key)
    }

    private enum StringFieldResult: Equatable {
        case absent
        case valid(String)
        case invalid

        var value: String? {
            if case .valid(let value) = self { return value }
            return nil
        }
    }

    private static func stringField(named name: String, in object: [String: Any])
        -> StringFieldResult
    {
        guard let value = object[name] else { return .absent }
        guard let string = value as? String else { return .invalid }
        return .valid(string)
    }

    private static func parentSessionField(
        host: HostID, nativeEvent: String?, in object: [String: Any]
    ) -> (value: Bool, mainKnown: Bool, invalid: Bool) {
        var child = nativeEvent == "SubagentStop"
        if let value = object["agent_id"] {
            guard let identifier = value as? String,
                sanitizeIdentifier(identifier, maximumBytes: maximumSessionIDBytes) != nil
            else { return (child, false, true) }
            child = true
        }
        // Retain conservative handling of legacy markers, but they alone never prove main scope.
        for key in ["is_subagent", "subagent"] {
            if let value = object[key] {
                guard let number = value as? NSNumber,
                    CFGetTypeID(number) == CFBooleanGetTypeID()
                else { return (child, false, true) }
                if number.boolValue { child = true }
            }
        }
        let payloadEvent = stringField(named: "hook_event_name", in: object)
        if payloadEvent == .invalid { return (child, false, true) }
        if let nativeEvent, let payloadName = payloadEvent.value, payloadName != nativeEvent {
            return (child, false, true)
        }
        let matched =
            nativeEvent != nil && nativeEvent == payloadEvent.value
            && HostCapabilityCatalog.binding(host: host, nativeEvent: nativeEvent ?? "") != nil
        return (child, matched && !child, false)
    }

    private static func sanitizeIdentifier(_ value: String, maximumBytes: Int) -> String? {
        // An identity is never shortened or whitespace-normalized: doing so aliases distinct
        // sessions and would export a different ID when the user copies it.
        guard !value.isEmpty, value.utf8.count <= maximumBytes,
            !HostEventSource.containsUnsafeScalar(value),
            !value.contains(where: { $0.isWhitespace })
        else { return nil }
        return value
    }

    private static func sanitizeLabel(_ value: String, maximumScalars: Int) -> String? {
        guard let normalized = HostEventSource.normalizeWhitespace(value) else { return nil }
        var scalarCount = 0
        var result = ""
        for character in normalized {
            let nextCount = character.unicodeScalars.count
            guard scalarCount + nextCount <= maximumScalars else { break }
            result.append(character)
            scalarCount += nextCount
        }
        return result.isEmpty ? nil : result
    }

    /// `JSONSerialization` collapses duplicate keys. Scan only the top-level object so the
    /// allowlisted source fields cannot be given two competing values by an untrusted hook.
    private static func duplicateTopLevelKeys(_ data: Data) -> Set<String> {
        let bytes = Array(data)
        var duplicates = Set<String>()
        var index = 0
        skipWhitespace(bytes, &index)
        guard index < bytes.count, bytes[index] == 123 else { return duplicates }
        index += 1
        var keys = Set<String>()
        while index < bytes.count {
            skipWhitespace(bytes, &index)
            if index < bytes.count, bytes[index] == 125 { return duplicates }
            guard index < bytes.count, bytes[index] == 34,
                let key = parseJSONString(bytes, &index)
            else { return duplicates }
            if !keys.insert(key).inserted { duplicates.insert(key) }
            skipWhitespace(bytes, &index)
            guard index < bytes.count, bytes[index] == 58 else { return duplicates }
            index += 1
            guard skipJSONValue(bytes, &index) else { return duplicates }
            skipWhitespace(bytes, &index)
            guard index < bytes.count else { return duplicates }
            if bytes[index] == 125 { return duplicates }
            guard bytes[index] == 44 else { return duplicates }
            index += 1
        }
        return duplicates
    }

    private static func skipWhitespace(_ bytes: [UInt8], _ index: inout Int) {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    private static func parseJSONString(_ bytes: [UInt8], _ index: inout Int) -> String? {
        guard index < bytes.count, bytes[index] == 34 else { return nil }
        let start = index
        index += 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if escaped {
                escaped = false
            } else if byte == 92 {
                escaped = true
            } else if byte == 34 {
                let raw = Data(bytes[start..<index])
                return try? JSONDecoder().decode(String.self, from: raw)
            }
        }
        return nil
    }

    private static func skipJSONValue(_ bytes: [UInt8], _ index: inout Int) -> Bool {
        skipWhitespace(bytes, &index)
        guard index < bytes.count else { return false }
        if bytes[index] == 34 {
            return parseJSONString(bytes, &index) != nil
        }
        var stack: [UInt8] = []
        var inString = false
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 92 {
                    escaped = true
                } else if byte == 34 {
                    inString = false
                }
                index += 1
                continue
            }
            switch byte {
            case 34:
                inString = true
            case 123, 91:
                stack.append(byte)
            case 125:
                if stack.last == 123 {
                    stack.removeLast()
                } else if stack.isEmpty {
                    return true
                } else {
                    return false
                }
            case 93:
                if stack.last == 91 { stack.removeLast() } else { return false }
            case 44 where stack.isEmpty:
                return true
            case 125 where stack.isEmpty:
                return true
            default:
                break
            }
            index += 1
            if stack.isEmpty, !inString {
                skipWhitespace(bytes, &index)
                if index >= bytes.count || bytes[index] == 44 || bytes[index] == 125 {
                    return true
                }
            }
        }
        return stack.isEmpty && !inString
    }
}

/// Immutable event notice. This is intentionally not a receipt and is never written to the
/// receipt store or activity summary.
public enum HostEventNoticeReason: String, Codable, Sendable, Hashable {
    case permission
    case needsInput = "needs_input"
    case informational
    case review
}

public struct HostEventNotice: Codable, Sendable, Equatable, Hashable, Identifiable {
    public static let currentSchema = 1

    public let schema: Int
    public let id: UUID
    public let receiverEpoch: UUID
    public let surface: HostSurfaceID
    public let bindingID: HostEventBindingID
    public let installationID: UUID
    public let nativeEvent: String
    public let event: Event
    public let occurredAt: Date
    public let source: HostEventSource?
    public let sourceCompleteness: HostEventSourceCompleteness
    public let reason: HostEventNoticeReason?
    /// Hook-local monotonic observation, never a host transaction timestamp.
    public let observedUptime: TimeInterval?

    public init(
        schema: Int = HostEventNotice.currentSchema,
        id: UUID = UUID(),
        receiverEpoch: UUID,
        surface: HostSurfaceID,
        bindingID: HostEventBindingID,
        installationID: UUID,
        nativeEvent: String,
        event: Event,
        occurredAt: Date,
        source: HostEventSource? = nil,
        sourceCompleteness: HostEventSourceCompleteness? = nil,
        reason: HostEventNoticeReason? = nil,
        observedUptime: TimeInterval? = nil
    ) {
        self.schema = schema
        self.id = id
        self.receiverEpoch = receiverEpoch
        self.surface = surface
        self.bindingID = bindingID
        self.installationID = installationID
        self.nativeEvent = nativeEvent
        self.event = event
        self.occurredAt = occurredAt
        self.source = source
        self.sourceCompleteness = sourceCompleteness ?? source?.completeness ?? .unknown
        self.reason = reason
        self.observedUptime = observedUptime.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decode(Int.self, forKey: .schema)
        id = try values.decode(UUID.self, forKey: .id)
        receiverEpoch = try values.decode(UUID.self, forKey: .receiverEpoch)
        surface = try values.decode(HostSurfaceID.self, forKey: .surface)
        bindingID = try values.decode(HostEventBindingID.self, forKey: .bindingID)
        installationID = try values.decode(UUID.self, forKey: .installationID)
        nativeEvent = try values.decode(String.self, forKey: .nativeEvent)
        event = try values.decode(Event.self, forKey: .event)
        occurredAt = try values.decode(Date.self, forKey: .occurredAt)
        source = try values.decodeIfPresent(HostEventSource.self, forKey: .source)
        sourceCompleteness = try values.decode(
            HostEventSourceCompleteness.self, forKey: .sourceCompleteness)
        reason = (try? values.decode(String.self, forKey: .reason)).flatMap(
            HostEventNoticeReason.init(rawValue:))
        let observation = try? values.decode(TimeInterval.self, forKey: .observedUptime)
        observedUptime = observation.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    public var host: HostID? { HostID(rawValue: surface.rawValue) }

    public var isSemanticallyValid: Bool {
        guard
            schema == Self.currentSchema,
            let host,
            let binding = HostCapabilityCatalog.binding(host: host, nativeEvent: nativeEvent)
        else { return false }
        guard binding.id == bindingID, binding.event == event, binding.host.surfaceID == surface
        else {
            return false
        }
        guard event == binding.event, nativeEvent.utf8.count <= 128 else { return false }
        let expectedCompleteness = source?.completeness ?? .unknown
        guard sourceCompleteness == expectedCompleteness else { return false }
        return source.map {
            $0.isSemanticallyValid
                && HostEventSource.displayBytes(of: $0) <= HostEventSourceParser.maximumDisplayBytes
        } ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case id = "event_id"
        case receiverEpoch = "receiver_epoch"
        case surface
        case bindingID = "binding_id"
        case installationID = "installation_id"
        case nativeEvent = "native_event"
        case event
        case occurredAt = "occurred_at"
        case source
        case sourceCompleteness = "source_completeness"
        case reason
        case observedUptime = "observed_uptime"
    }
}
