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
    public let completeness: HostEventSourceCompleteness

    public init(
        projectLabel: String?,
        projectKey: String? = nil,
        sessionID: String?,
        sessionLabel: String? = nil,
        isParentSession: Bool = false,
        completeness: HostEventSourceCompleteness? = nil
    ) {
        self.projectLabel = projectLabel
        self.projectKey = projectKey
        self.sessionID = sessionID
        self.sessionLabel = sessionLabel
        self.isParentSession = isParentSession
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
    }

    private enum CodingKeys: String, CodingKey {
        case projectLabel = "project_label"
        case projectKey = "project_key"
        case sessionID = "session_id"
        case sessionLabel = "session_label"
        case isParentSession = "is_parent_session"
        case completeness
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

/// 宿主来源解析器只认识各 adapter 明确列入合同的字段。
public enum HostEventSourceParser {
    public static let maximumProjectLabelScalars = 128
    public static let maximumSessionIDBytes = 256
    public static let maximumDisplayBytes = 1 << 10

    public static func parse(host: HostID, data: Data?) -> HostEventSourceParseOutcome {
        guard let data, !data.isEmpty else {
            return .unavailable(reason: .empty, partial: nil)
        }
        guard data.count <= 64 * 1024 else {
            return .unavailable(reason: .oversized, partial: nil)
        }
        guard host == .claudeCode || host == .codex else {
            // WorkBuddy 的来源字段没有本次已核实的版本合同，宁可未知，不兼容猜测。
            return .unavailable(reason: .unsupportedHost, partial: nil)
        }
        guard !hasDuplicateTopLevelKeys(data) else {
            return .unavailable(reason: .duplicateField, partial: nil)
        }
        guard
            let object = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed]),
            let dictionary = object as? [String: Any]
        else {
            return .unavailable(reason: .invalidJSON, partial: nil)
        }

        let cwdResult = stringField(named: "cwd", in: dictionary)
        let sessionResult = stringField(named: "session_id", in: dictionary)
        let parentResult = parentSessionField(in: dictionary)

        if cwdResult == .invalid || sessionResult == .invalid || parentResult.invalid {
            let partial = makeSource(
                cwd: cwdResult.value,
                sessionID: sessionResult.value,
                isParentSession: parentResult.value)
            return .unavailable(reason: .invalidFieldType, partial: partial)
        }

        let projectInfo: (label: String, key: String)?
        if let cwd = cwdResult.value {
            guard let result = Self.project(from: cwd) else {
                let partial = makeSource(
                    cwd: nil, sessionID: sessionResult.value, isParentSession: parentResult.value)
                return .unavailable(reason: .unsafeField, partial: partial)
            }
            projectInfo = result
        } else {
            projectInfo = nil
        }

        let safeSession: String?
        if let sessionID = sessionResult.value {
            guard let sanitized = sanitizeIdentifier(sessionID, maximumBytes: maximumSessionIDBytes)
            else {
                let partial = makeSource(
                    project: projectInfo,
                    sessionID: nil,
                    isParentSession: parentResult.value)
                return .unavailable(reason: .unsafeField, partial: partial)
            }
            safeSession = sanitized
        } else {
            safeSession = nil
        }

        let source = HostEventSource(
            projectLabel: projectInfo?.label,
            projectKey: projectInfo?.key,
            sessionID: safeSession,
            isParentSession: parentResult.value,
            completeness: .forFields(
                hasProject: projectInfo != nil,
                hasSession: safeSession != nil))
        guard source.completeness != .unknown else {
            return .unavailable(reason: .empty, partial: nil)
        }
        guard HostEventSource.displayBytes(of: source) <= maximumDisplayBytes else {
            return .unavailable(reason: .oversized, partial: nil)
        }
        return .available(source)
    }

    private static func makeSource(
        cwd: String?,
        sessionID: String?,
        isParentSession: Bool,
        projectKey: String? = nil
    ) -> HostEventSource? {
        let projectInfo = cwd.flatMap { Self.project(from: $0) }
        return makeSource(
            project: projectInfo.map { (label: $0.label, key: projectKey ?? $0.key) },
            sessionID: sessionID,
            isParentSession: isParentSession)
    }

    private static func makeSource(
        project: (label: String, key: String)?,
        sessionID: String?,
        isParentSession: Bool
    ) -> HostEventSource? {
        let projectLabel = project?.label
        let projectKey = project?.key
        let safeSession = sessionID.flatMap {
            sanitizeIdentifier($0, maximumBytes: maximumSessionIDBytes)
        }
        guard projectLabel != nil || safeSession != nil else { return nil }
        // The default short session label is projected and localized GUI-side; the transport
        // field stays nil until an adapter earns an explicit trusted title (SPEC 来源合同).
        return HostEventSource(
            projectLabel: projectLabel,
            projectKey: projectKey,
            sessionID: safeSession,
            isParentSession: isParentSession)
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

    private static func parentSessionField(in object: [String: Any]) -> (value: Bool, invalid: Bool)
    {
        // `agent_id` identifies a child invocation in the Codex hook payload. It is deliberately
        // never used as the session ID or as a route target.
        if let value = object["agent_id"] {
            guard value is String else { return (false, true) }
            return (true, false)
        }
        for key in ["is_subagent", "subagent"] {
            if let value = object[key] {
                guard let bool = value as? Bool else { return (false, true) }
                return (bool, false)
            }
        }
        return (false, false)
    }

    private static func sanitizeIdentifier(_ value: String, maximumBytes: Int) -> String? {
        guard let normalized = HostEventSource.normalizeWhitespace(value) else { return nil }
        return prefixByUTF8Bytes(normalized, maximumBytes: maximumBytes)
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

    private static func prefixByUTF8Bytes(_ value: String, maximumBytes: Int) -> String? {
        var result = ""
        var count = 0
        for character in value {
            let bytes = character.utf8.count
            guard count + bytes <= maximumBytes else { break }
            result.append(character)
            count += bytes
        }
        return result.isEmpty ? nil : result
    }

    /// `JSONSerialization` collapses duplicate keys. Scan only the top-level object so the
    /// allowlisted source fields cannot be given two competing values by an untrusted hook.
    private static func hasDuplicateTopLevelKeys(_ data: Data) -> Bool {
        let bytes = Array(data)
        var index = 0
        skipWhitespace(bytes, &index)
        guard index < bytes.count, bytes[index] == 123 else { return false }
        index += 1
        var keys = Set<String>()
        while index < bytes.count {
            skipWhitespace(bytes, &index)
            if index < bytes.count, bytes[index] == 125 { return false }
            guard index < bytes.count, bytes[index] == 34,
                let key = parseJSONString(bytes, &index)
            else { return false }
            if !keys.insert(key).inserted { return true }
            skipWhitespace(bytes, &index)
            guard index < bytes.count, bytes[index] == 58 else { return false }
            index += 1
            guard skipJSONValue(bytes, &index) else { return false }
            skipWhitespace(bytes, &index)
            guard index < bytes.count else { return false }
            if bytes[index] == 125 { return false }
            guard bytes[index] == 44 else { return false }
            index += 1
        }
        return false
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
        sourceCompleteness: HostEventSourceCompleteness? = nil
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
    }
}
