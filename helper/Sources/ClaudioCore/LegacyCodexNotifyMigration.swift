import Foundation

/// 旧 `codex-notify` 无法安全迁移时交给 adapter/UI 的稳定原因。
public enum LegacyCodexNotifyMigrationConflictReason: Error, Sendable, Equatable {
    case configNotUTF8
    case wrapperNotUTF8
    case configMalformed
    case configDoesNotReferenceWrapper
    case invalidCurrentPaths
    case unknownOrModifiedWrapper
    case differentClaudioBinary
}

public enum LegacyCodexNotifyMigrationDetection: Sendable, Equatable {
    case migratable
    case migrated(installationID: UUID)
    case notifierOnly
    case conflict(LegacyCodexNotifyMigrationConflictReason)
}

/// 已知 wrapper 的三种可恢复状态。三者都不是未知冲突：legacy/已迁移可替换 Claudio 行，
/// notifier-only 可在下次 connect 时重新插入该行。
public enum LegacyCodexNotifyWrapperState: Sendable, Equatable {
    case legacyPlayStop
    case migrated(installationID: UUID)
    case notifierOnly
}

/// 只检测，不读写任何文件。`configTOML` 只解析根表 `notify` 的 argv；trust 等其它键既不解释也不返回。
public func detectLegacyCodexNotifyMigration(
    configTOML: Data,
    wrapper: Data,
    claudioRoot: String,
    claudioBinaryPath: String
) -> LegacyCodexNotifyMigrationDetection {
    guard let config = String(data: configTOML, encoding: .utf8) else {
        return .conflict(.configNotUTF8)
    }
    guard let wrapperText = String(data: wrapper, encoding: .utf8) else {
        return .conflict(.wrapperNotUTF8)
    }
    return detectLegacyCodexNotifyMigration(
        configTOML: config,
        wrapper: wrapperText,
        claudioRoot: claudioRoot,
        claudioBinaryPath: claudioBinaryPath)
}

/// String 入口供已在上层完成有界读取的 adapter 使用。
public func detectLegacyCodexNotifyMigration(
    configTOML: String,
    wrapper: String,
    claudioRoot: String,
    claudioBinaryPath: String
) -> LegacyCodexNotifyMigrationDetection {
    switch inspectLegacyCodexNotify(
        configTOML: configTOML,
        wrapper: wrapper,
        claudioRoot: claudioRoot,
        claudioBinaryPath: claudioBinaryPath)
    {
    case .success(let inspected):
        switch inspected.state {
        case .legacyPlayStop: return .migratable
        case .migrated(let installationID):
            return .migrated(installationID: installationID)
        case .notifierOnly: return .notifierOnly
        }
    case .failure(let reason):
        return .conflict(reason)
    }
}

/// adapter 共用的纯状态读取；与 detection 相同地先验证 config 的真实引用关系。
public func inspectLegacyCodexNotifyWrapper(
    configTOML: Data,
    wrapper: Data,
    claudioRoot: String,
    claudioBinaryPath: String
) -> Result<LegacyCodexNotifyWrapperState, LegacyCodexNotifyMigrationConflictReason> {
    guard let config = String(data: configTOML, encoding: .utf8) else {
        return .failure(.configNotUTF8)
    }
    guard let wrapperText = String(data: wrapper, encoding: .utf8) else {
        return .failure(.wrapperNotUTF8)
    }
    return inspectLegacyCodexNotifyWrapper(
        configTOML: config,
        wrapper: wrapperText,
        claudioRoot: claudioRoot,
        claudioBinaryPath: claudioBinaryPath)
}

public func inspectLegacyCodexNotifyWrapper(
    configTOML: String,
    wrapper: String,
    claudioRoot: String,
    claudioBinaryPath: String
) -> Result<LegacyCodexNotifyWrapperState, LegacyCodexNotifyMigrationConflictReason> {
    inspectLegacyCodexNotify(
        configTOML: configTOML,
        wrapper: wrapper,
        claudioRoot: claudioRoot,
        claudioBinaryPath: claudioBinaryPath
    ).map(\.state)
}

/// 显式纯变换：重新执行全部 fail-closed 检测，只返回替换后的 bytes，不实际写文件。
public func migrateLegacyCodexNotifyWrapper(
    configTOML: Data,
    wrapper: Data,
    claudioRoot: String,
    claudioBinaryPath: String,
    installationID: UUID
) -> Result<Data, LegacyCodexNotifyMigrationConflictReason> {
    guard let config = String(data: configTOML, encoding: .utf8) else {
        return .failure(.configNotUTF8)
    }
    guard let wrapperText = String(data: wrapper, encoding: .utf8) else {
        return .failure(.wrapperNotUTF8)
    }
    return migrateLegacyCodexNotifyWrapper(
        configTOML: config,
        wrapper: wrapperText,
        claudioRoot: claudioRoot,
        claudioBinaryPath: claudioBinaryPath,
        installationID: installationID
    ).map { Data($0.utf8) }
}

/// String 版本保持所有未替换行逐字符不变，并保留旧生成版本的尾随 LF。
public func migrateLegacyCodexNotifyWrapper(
    configTOML: String,
    wrapper: String,
    claudioRoot: String,
    claudioBinaryPath: String,
    installationID: UUID
) -> Result<String, LegacyCodexNotifyMigrationConflictReason> {
    switch inspectLegacyCodexNotify(
        configTOML: configTOML,
        wrapper: wrapper,
        claudioRoot: claudioRoot,
        claudioBinaryPath: claudioBinaryPath)
    {
    case .failure(let reason):
        return .failure(reason)
    case .success(let inspected):
        var lines = inspected.lines
        let hookLine = inspected.binaryWord
            + " hook codex Stop --installation-id \(installationID.uuidString)"
            + " >/dev/null 2>&1 &"
        switch inspected.state {
        case .notifierOnly:
            lines.insert(hookLine, at: 6)
        case .legacyPlayStop, .migrated:
            lines[6] = hookLine
        }
        return .success(lines.joined(separator: "\n"))
    }
}

/// disconnect 的纯变换：只删除已知 Claudio 分支，wrapper 中原 notifier 与 argv 原样保留。
public func removeClaudioBranchFromLegacyCodexNotifyWrapper(
    configTOML: Data,
    wrapper: Data,
    claudioRoot: String,
    claudioBinaryPath: String
) -> Result<Data, LegacyCodexNotifyMigrationConflictReason> {
    guard let config = String(data: configTOML, encoding: .utf8) else {
        return .failure(.configNotUTF8)
    }
    guard let wrapperText = String(data: wrapper, encoding: .utf8) else {
        return .failure(.wrapperNotUTF8)
    }
    return removeClaudioBranchFromLegacyCodexNotifyWrapper(
        configTOML: config,
        wrapper: wrapperText,
        claudioRoot: claudioRoot,
        claudioBinaryPath: claudioBinaryPath
    ).map { Data($0.utf8) }
}

public func removeClaudioBranchFromLegacyCodexNotifyWrapper(
    configTOML: String,
    wrapper: String,
    claudioRoot: String,
    claudioBinaryPath: String
) -> Result<String, LegacyCodexNotifyMigrationConflictReason> {
    switch inspectLegacyCodexNotify(
        configTOML: configTOML,
        wrapper: wrapper,
        claudioRoot: claudioRoot,
        claudioBinaryPath: claudioBinaryPath)
    {
    case .failure(let reason):
        return .failure(reason)
    case .success(let inspected):
        guard inspected.state != .notifierOnly else { return .success(wrapper) }
        var lines = inspected.lines
        lines.remove(at: 6)
        return .success(lines.joined(separator: "\n"))
    }
}

private struct InspectedLegacyCodexNotify {
    let lines: [String]
    let binaryWord: String
    let state: LegacyCodexNotifyWrapperState
}

private func inspectLegacyCodexNotify(
    configTOML: String,
    wrapper: String,
    claudioRoot: String,
    claudioBinaryPath: String
) -> Result<InspectedLegacyCodexNotify, LegacyCodexNotifyMigrationConflictReason> {
    guard let expectedWrapper = expectedLegacyWrapperPath(
        claudioRoot: claudioRoot, claudioBinaryPath: claudioBinaryPath)
    else {
        return .failure(.invalidCurrentPaths)
    }

    let notifyArguments: [String]
    switch rootNotifyArguments(in: configTOML) {
    case .failure:
        return .failure(.configMalformed)
    case .success(nil):
        return .failure(.configDoesNotReferenceWrapper)
    case .success(.some(let arguments)):
        notifyArguments = arguments
    }
    guard notifyArgumentsReferenceWrapper(notifyArguments, expectedWrapper: expectedWrapper) else {
        return .failure(.configDoesNotReferenceWrapper)
    }

    return inspectKnownWrapper(wrapper, claudioBinaryPath: claudioBinaryPath)
}

private func notifyArgumentsReferenceWrapper(
    _ arguments: [String],
    expectedWrapper: String
) -> Bool {
    // Swift String/Array equality applies Unicode canonical equivalence. Paths on a
    // normalization-sensitive home must instead name the exact UTF-8 bytes Codex executes.
    if arguments.count == 1,
        arguments[0].utf8.elementsEqual(expectedWrapper.utf8)
    {
        return true
    }

    let markers = arguments.indices.filter { arguments[$0] == "--previous-notify" }
    guard markers.count == 1 else { return false }
    let marker = markers[0]
    guard marker + 1 < arguments.count else { return false }
    let encodedPrevious = arguments[marker + 1]
    guard let data = encodedPrevious.data(using: .utf8),
        let decoded = try? JSONSerialization.jsonObject(with: data),
        let previousArguments = decoded as? [String]
    else { return false }
    return previousArguments.count == 1
        && previousArguments[0].utf8.elementsEqual(expectedWrapper.utf8)
}

private func expectedLegacyWrapperPath(
    claudioRoot: String,
    claudioBinaryPath: String
) -> String? {
    guard claudioRoot.hasPrefix("/"), claudioBinaryPath.hasPrefix("/") else { return nil }
    let root = claudioRoot.count > 1 && claudioRoot.hasSuffix("/")
        ? String(claudioRoot.dropLast()) : claudioRoot
    guard !root.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
        !claudioBinaryPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
        claudioBinaryPath.hasPrefix(root + "/"),
        URL(fileURLWithPath: claudioBinaryPath).lastPathComponent == "claudio"
    else { return nil }
    return root + "/bin/codex-notify"
}

private let knownLegacyComment =
    // Exact historical bytes are part of wrapper ownership detection. Keep the old brand
    // spelling here so an upgrade can still recognize and safely migrate existing wrappers.
    "# Codex 的 notify 只能配置一个外部命令；这里保留既有通知，并追加 Claudio 的完成音效。"
private let legacyNotifierSuffix = " \"$payload\" >/dev/null 2>&1 &"
private let legacyClaudioSuffix = " play stop >/dev/null 2>&1 &"
private let migratedClaudioMarker = " hook codex Stop --installation-id "
private let claudioRedirectSuffix = " >/dev/null 2>&1 &"

private func inspectKnownWrapper(
    _ wrapper: String,
    claudioBinaryPath: String
) -> Result<InspectedLegacyCodexNotify, LegacyCodexNotifyMigrationConflictReason> {
    // 已知生成版本为 9 行；disconnect 只删第 7 行后留下 8 行。两者都保留尾随 LF，
    // 所以 components 分别多一个结尾空元素。
    let lines = wrapper.components(separatedBy: "\n")
    let hasClaudioBranch: Bool
    if lines.count == 10, lines[9].isEmpty, lines[7].isEmpty, lines[8] == "exit 0" {
        hasClaudioBranch = true
    } else if lines.count == 9, lines[8].isEmpty, lines[6].isEmpty, lines[7] == "exit 0" {
        hasClaudioBranch = false
    } else {
        return .failure(.unknownOrModifiedWrapper)
    }
    guard
        lines[0] == "#!/bin/sh",
        lines[1] == knownLegacyComment,
        lines[2].isEmpty,
        lines[3] == "payload=${1-}",
        lines[4].isEmpty
    else {
        return .failure(.unknownOrModifiedWrapper)
    }

    guard lines[5].hasSuffix(legacyNotifierSuffix) else {
        return .failure(.unknownOrModifiedWrapper)
    }
    let notifierPrefix = String(lines[5].dropLast(legacyNotifierSuffix.count))
    guard let notifierArguments = decodeLiteralShellWords(notifierPrefix),
        !notifierArguments.isEmpty
    else {
        return .failure(.unknownOrModifiedWrapper)
    }

    guard hasClaudioBranch else {
        return .success(
            InspectedLegacyCodexNotify(
                lines: lines,
                binaryWord: shellQuotedPath(claudioBinaryPath),
                state: .notifierOnly))
    }

    let binaryWord: String
    let state: LegacyCodexNotifyWrapperState
    if lines[6].hasSuffix(legacyClaudioSuffix) {
        binaryWord = String(lines[6].dropLast(legacyClaudioSuffix.count))
        state = .legacyPlayStop
    } else if lines[6].hasSuffix(claudioRedirectSuffix) {
        let command = String(lines[6].dropLast(claudioRedirectSuffix.count))
        guard let marker = command.range(of: migratedClaudioMarker, options: .backwards),
            marker.upperBound < command.endIndex
        else { return .failure(.unknownOrModifiedWrapper) }
        binaryWord = String(command[..<marker.lowerBound])
        let idText = String(command[marker.upperBound...])
        guard !idText.contains(where: { $0.isWhitespace }),
            let installationID = UUID(uuidString: idText)
        else { return .failure(.unknownOrModifiedWrapper) }
        state = .migrated(installationID: installationID)
    } else {
        return .failure(.unknownOrModifiedWrapper)
    }
    guard let decodedBinary = decodeSingleLiteralShellWord(binaryWord) else {
        return .failure(.unknownOrModifiedWrapper)
    }
    guard decodedBinary.utf8.elementsEqual(claudioBinaryPath.utf8) else {
        return .failure(.differentClaudioBinary)
    }
    return .success(
        InspectedLegacyCodexNotify(lines: lines, binaryWord: binaryWord, state: state))
}

// MARK: - Minimal TOML reader: root `notify = ["argv", ...]` only

private enum MinimalTOMLError: Error {
    case malformed
}

private func rootNotifyArguments(
    in config: String
) -> Result<[String]?, MinimalTOMLError> {
    let rawLines = config.components(separatedBy: "\n")
    var enteredTable = false
    var found: [String]?
    var collecting: String?

    for rawLine in rawLines {
        guard let uncommented = strippingTOMLComment(rawLine) else {
            return .failure(.malformed)
        }
        let trimmed = uncommented.trimmingCharacters(in: .whitespacesAndNewlines)
        if var value = collecting {
            value += "\n" + trimmed
            switch parseTOMLStringArray(value) {
            case .incomplete:
                collecting = value
            case .malformed:
                return .failure(.malformed)
            case .complete(let arguments):
                found = arguments
                collecting = nil
            }
            continue
        }
        if trimmed.isEmpty { continue }
        if trimmed.hasPrefix("[") {
            enteredTable = true
            continue
        }
        if enteredTable { continue }
        guard let equals = firstUnquotedEquals(in: trimmed) else { continue }
        let rawKey = String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
        guard decodedTOMLKey(rawKey) == "notify" else { continue }
        guard found == nil else { return .failure(.malformed) }
        let rawValue = String(trimmed[trimmed.index(after: equals)...])
            .trimmingCharacters(in: .whitespaces)
        switch parseTOMLStringArray(rawValue) {
        case .complete(let arguments):
            found = arguments
        case .incomplete:
            collecting = rawValue
        case .malformed:
            return .failure(.malformed)
        }
    }
    guard collecting == nil else { return .failure(.malformed) }
    return .success(found)
}

private func strippingTOMLComment(_ line: String) -> String? {
    var quote: Character?
    var escaping = false
    for index in line.indices {
        let character = line[index]
        if let activeQuote = quote {
            if activeQuote == "\"", escaping {
                escaping = false
            } else if activeQuote == "\"", character == "\\" {
                escaping = true
            } else if character == activeQuote {
                quote = nil
            }
            continue
        }
        if character == "\"" || character == "'" {
            quote = character
        } else if character == "#" {
            return String(line[..<index])
        }
    }
    return quote == nil && !escaping ? line : nil
}

private func firstUnquotedEquals(in line: String) -> String.Index? {
    var quote: Character?
    var escaping = false
    for index in line.indices {
        let character = line[index]
        if let activeQuote = quote {
            if activeQuote == "\"", escaping {
                escaping = false
            } else if activeQuote == "\"", character == "\\" {
                escaping = true
            } else if character == activeQuote {
                quote = nil
            }
        } else if character == "\"" || character == "'" {
            quote = character
        } else if character == "=" {
            return index
        }
    }
    return nil
}

private func decodedTOMLKey(_ raw: String) -> String? {
    if raw == "notify" { return raw }
    var index = 0
    let characters = Array(raw)
    guard let decoded = decodeTOMLString(characters, index: &index),
        index == characters.count
    else { return nil }
    return decoded
}

private enum TOMLArrayParse {
    case complete([String])
    case incomplete
    case malformed
}

private func parseTOMLStringArray(_ source: String) -> TOMLArrayParse {
    let characters = Array(source)
    var index = 0
    skipTOMLWhitespace(characters, index: &index)
    guard index < characters.count, characters[index] == "[" else { return .malformed }
    index += 1
    var values: [String] = []
    while true {
        skipTOMLWhitespace(characters, index: &index)
        guard index < characters.count else { return .incomplete }
        if characters[index] == "]" {
            index += 1
            skipTOMLWhitespace(characters, index: &index)
            return index == characters.count ? .complete(values) : .malformed
        }
        guard let value = decodeTOMLString(characters, index: &index) else {
            // An unterminated string/array may be continued on the next config line.
            return source.last == "\"" || source.last == "'" ? .malformed : .incomplete
        }
        values.append(value)
        skipTOMLWhitespace(characters, index: &index)
        guard index < characters.count else { return .incomplete }
        if characters[index] == "," {
            index += 1
            continue
        }
        if characters[index] != "]" { return .malformed }
    }
}

private func skipTOMLWhitespace(_ characters: [Character], index: inout Int) {
    while index < characters.count, characters[index].isWhitespace { index += 1 }
}

private func decodeTOMLString(_ characters: [Character], index: inout Int) -> String? {
    guard index < characters.count,
        characters[index] == "\"" || characters[index] == "'"
    else { return nil }
    let quote = characters[index]
    index += 1
    var decoded = ""
    while index < characters.count {
        let character = characters[index]
        index += 1
        if character == quote { return decoded }
        if quote == "'" {
            guard character != "\n" && character != "\r" else { return nil }
            decoded.append(character)
            continue
        }
        guard character != "\n" && character != "\r" else { return nil }
        guard character == "\\" else {
            decoded.append(character)
            continue
        }
        guard index < characters.count else { return nil }
        let escape = characters[index]
        index += 1
        switch escape {
        case "b": decoded.append("\u{8}")
        case "t": decoded.append("\t")
        case "n": decoded.append("\n")
        case "f": decoded.append("\u{c}")
        case "r": decoded.append("\r")
        case "\"": decoded.append("\"")
        case "\\": decoded.append("\\")
        case "u", "U":
            let count = escape == "u" ? 4 : 8
            guard index + count <= characters.count else { return nil }
            let hex = String(characters[index..<(index + count)])
            guard let value = UInt32(hex, radix: 16), let scalar = UnicodeScalar(value) else {
                return nil
            }
            decoded.append(String(scalar))
            index += count
        default:
            return nil
        }
    }
    return nil
}

// MARK: - Literal shell argv reader

private func decodeLiteralShellWords(_ source: String) -> [String]? {
    var words: [String] = []
    var current = ""
    var quote: Character?
    var escaping = false
    var sawSyntax = false

    for character in source {
        if escaping {
            // POSIX shell 双引号内，反斜杠只会移除 `$`/`` ` ``/`"`/`\`
            // 前的特殊含义；其它字符前的反斜杠会保留。必须按真实 shell
            // 字面值比较 binary，否则会把另一条路径误认为当前 Claudio。
            if quote == "\"", !"$`\"\\".contains(character) {
                current.append("\\")
            }
            current.append(character)
            escaping = false
            sawSyntax = true
            continue
        }
        if let activeQuote = quote {
            if activeQuote == "'" {
                if character == "'" { quote = nil } else { current.append(character) }
            } else if character == "\"" {
                quote = nil
            } else if character == "\\" {
                escaping = true
            } else if character == "$" || character == "`" {
                return nil
            } else {
                current.append(character)
            }
            sawSyntax = true
            continue
        }
        if character == "'" || character == "\"" {
            quote = character
            sawSyntax = true
        } else if character == "\\" {
            escaping = true
            sawSyntax = true
        } else if character.isWhitespace {
            if sawSyntax {
                words.append(current)
                current = ""
                sawSyntax = false
            }
        } else if "$`;|&<>()*?[]!#{}~^".contains(character) {
            return nil
        } else {
            current.append(character)
            sawSyntax = true
        }
    }
    guard quote == nil, !escaping else { return nil }
    if sawSyntax { words.append(current) }
    return words
}

private func decodeSingleLiteralShellWord(_ source: String) -> String? {
    guard let words = decodeLiteralShellWords(source), words.count == 1 else { return nil }
    return words[0]
}
