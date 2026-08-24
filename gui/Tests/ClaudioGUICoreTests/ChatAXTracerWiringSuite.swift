import Foundation

private func chatAXWiringRepoRoot(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

private func chatAXWiringSource(_ relativePath: String) -> String? {
    try? String(
        contentsOf: chatAXWiringRepoRoot().appendingPathComponent(relativePath),
        encoding: .utf8)
}

private func chatAXTypechecksInDebugAndRelease(_ source: String) -> (
    succeeded: Bool, diagnostics: String
) {
    let fileManager = FileManager.default
    let fixtureDirectory = fileManager.temporaryDirectory.appendingPathComponent(
        "claudio-chat-ax-wiring-\(UUID().uuidString)", isDirectory: true)
    let fixture = fixtureDirectory.appendingPathComponent("Mutation.swift")

    do {
        try fileManager.createDirectory(
            at: fixtureDirectory, withIntermediateDirectories: true)
        try source.write(to: fixture, atomically: true, encoding: .utf8)
    } catch {
        return (false, "无法创建 mutation fixture：\(error)")
    }
    defer { try? fileManager.removeItem(at: fixtureDirectory) }

    var diagnostics: [String] = []
    for (configuration, compilerArguments) in [
        ("Debug", ["-DDEBUG"]),
        ("Release", []),
    ] {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments =
            ["swiftc", "-swift-version", "6", "-typecheck"] + compilerArguments
            + [fixture.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            diagnostics.append("\(configuration)：无法启动 swiftc：\(error)")
            continue
        }

        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let errorText = String(data: errorData, encoding: .utf8) ?? "无诊断信息"
            diagnostics.append(
                "\(configuration)：swiftc rc=\(process.terminationStatus)：\(errorText)")
        }
    }
    return (diagnostics.isEmpty, diagnostics.joined(separator: "\n"))
}

private enum ChatAXConditionalDirective {
    case debugIf
    case otherIf
    case elseifBranch
    case elseBranch
    case endif
    case invalid
    case notDirective
}

private struct ChatAXConditionalFrame {
    var isDirectDebugBranch: Bool
    var sawElse = false
}

private func chatAXPoundIdentifier(in line: String) -> (token: Substring, payload: Substring)? {
    guard line.first == "#" else { return nil }
    var tokenEnd = line.index(after: line.startIndex)
    while tokenEnd < line.endIndex {
        let character = line[tokenEnd]
        guard character.isLetter || character.isNumber || character == "_" else { break }
        tokenEnd = line.index(after: tokenEnd)
    }
    guard tokenEnd > line.index(after: line.startIndex) else { return nil }
    return (line[..<tokenEnd], line[tokenEnd...])
}

private func chatAXIsDirectDebugCondition(_ rawCondition: Substring) -> Bool {
    var condition = String(rawCondition).trimmingCharacters(in: .whitespacesAndNewlines)
    while condition.first == "(" && condition.last == ")" {
        condition = String(condition.dropFirst().dropLast())
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return condition == "DEBUG"
}

private func chatAXConditionalDirective(in rawLine: String) -> ChatAXConditionalDirective {
    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let directive = chatAXPoundIdentifier(in: line) else { return .notDirective }
    switch directive.token {
    case "#if":
        let condition = directive.payload
        guard !condition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .invalid
        }
        guard condition.first?.isWhitespace == true || condition.first == "(" else {
            return .invalid
        }
        return chatAXIsDirectDebugCondition(condition) ? .debugIf : .otherIf
    case "#elseif":
        let condition = directive.payload
        guard !condition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .invalid
        }
        guard condition.first?.isWhitespace == true || condition.first == "(" else {
            return .invalid
        }
        return .elseifBranch
    case "#else":
        return directive.payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .elseBranch : .invalid
    case "#endif":
        return directive.payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .endif : .invalid
    default:
        return .notDirective
    }
}

private func hasSingleOccurrenceDirectlyInsideDebug(
    _ marker: String,
    in source: String
) -> Bool {
    guard !marker.isEmpty else { return false }
    let scanned = strippingComments(source)
    guard scanned.unmodeledConstructs.isEmpty else { return false }

    var conditionalStack: [ChatAXConditionalFrame] = []
    var markerLocations: [Bool] = []
    for sourceLine in scanned.codeWithoutStringLiterals.split(
        separator: "\n", omittingEmptySubsequences: false
    ) {
        let line = String(sourceLine)
        switch chatAXConditionalDirective(in: line) {
        case .debugIf:
            conditionalStack.append(ChatAXConditionalFrame(isDirectDebugBranch: true))
            continue
        case .otherIf:
            conditionalStack.append(ChatAXConditionalFrame(isDirectDebugBranch: false))
            continue
        case .elseifBranch:
            guard !conditionalStack.isEmpty, !conditionalStack[conditionalStack.count - 1].sawElse
            else { return false }
            conditionalStack[conditionalStack.count - 1].isDirectDebugBranch = false
            continue
        case .elseBranch:
            guard !conditionalStack.isEmpty, !conditionalStack[conditionalStack.count - 1].sawElse
            else { return false }
            conditionalStack[conditionalStack.count - 1].isDirectDebugBranch = false
            conditionalStack[conditionalStack.count - 1].sawElse = true
            continue
        case .endif:
            guard conditionalStack.popLast() != nil else { return false }
            continue
        case .invalid:
            return false
        case .notDirective:
            break
        }

        let occurrenceCount = line.components(separatedBy: marker).count - 1
        markerLocations.append(
            contentsOf: repeatElement(
                conditionalStack.count == 1
                    && conditionalStack[0].isDirectDebugBranch,
                count: occurrenceCount))
    }
    guard conditionalStack.isEmpty else { return false }
    return markerLocations == [true]
}

func chatAXBracedDeclarationRegion(_ declaration: String, in source: String) -> String? {
    guard
        source.components(separatedBy: declaration).count - 1 == 1,
        let declarationRange = source.range(of: declaration),
        let openingBrace = source[declarationRange.upperBound...].firstIndex(of: "{")
    else {
        return nil
    }
    var depth = 0
    var index = openingBrace
    while index < source.endIndex {
        switch source[index] {
        case "{":
            depth += 1
        case "}":
            depth -= 1
            if depth == 0 {
                return String(source[declarationRange.lowerBound...index])
            }
        default:
            break
        }
        index = source.index(after: index)
    }
    return nil
}

func chatAXFunctionRegion(_ declaration: String, in source: String) -> String? {
    chatAXBracedDeclarationRegion(declaration, in: source)
}

func chatAXFunctionContainsMarkersInOrder(
    _ markers: [String],
    inFunction declaration: String,
    source: String
) -> Bool {
    guard !markers.isEmpty else { return false }
    let scanned = strippingComments(source)
    guard scanned.unmodeledConstructs.isEmpty,
        let region = chatAXFunctionRegion(
            declaration, in: scanned.codeWithoutStringLiterals)
    else {
        return false
    }

    var searchStart = region.startIndex
    for marker in markers {
        guard !marker.isEmpty,
            let range = region.range(of: marker, range: searchStart..<region.endIndex)
        else {
            return false
        }
        searchStart = range.upperBound
    }
    return true
}

private func hasSingleOccurrenceDirectlyInsideDebug(
    _ marker: String,
    inFunction declaration: String,
    source: String
) -> Bool {
    guard !marker.isEmpty else { return false }
    let scanned = strippingComments(source)
    guard scanned.unmodeledConstructs.isEmpty else { return false }
    let code = scanned.codeWithoutStringLiterals
    guard code.components(separatedBy: marker).count - 1 == 1,
        let functionRegion = chatAXFunctionRegion(declaration, in: code),
        functionRegion.components(separatedBy: marker).count - 1 == 1
    else {
        return false
    }
    return hasSingleOccurrenceDirectlyInsideDebug(marker, in: code)
}

private func hasSingleOccurrenceDirectlyInsideDebug(
    _ marker: String,
    inType typeDeclaration: String,
    source: String
) -> Bool {
    guard !marker.isEmpty else { return false }
    let scanned = strippingComments(source)
    guard scanned.unmodeledConstructs.isEmpty else { return false }
    let code = scanned.codeWithoutStringLiterals
    guard code.components(separatedBy: marker).count - 1 == 1,
        let typeRegion = chatAXBracedDeclarationRegion(typeDeclaration, in: code),
        typeRegion.components(separatedBy: marker).count - 1 == 1
    else {
        return false
    }
    return hasSingleOccurrenceDirectlyInsideDebug(marker, in: code)
}

private func hasSingleOccurrenceDirectlyInsideDebug(
    _ marker: String,
    inFunction functionDeclaration: String,
    inType typeDeclaration: String,
    source: String
) -> Bool {
    guard !marker.isEmpty else { return false }
    let scanned = strippingComments(source)
    guard scanned.unmodeledConstructs.isEmpty else { return false }
    let code = scanned.codeWithoutStringLiterals
    guard code.components(separatedBy: marker).count - 1 == 1,
        let typeRegion = chatAXBracedDeclarationRegion(typeDeclaration, in: code),
        let functionRegion = chatAXFunctionRegion(functionDeclaration, in: typeRegion),
        functionRegion.components(separatedBy: marker).count - 1 == 1
    else {
        return false
    }
    return hasSingleOccurrenceDirectlyInsideDebug(marker, in: code)
}

@MainActor
func runChatAXTracerWiringSuites() {
    suite("Chat AX tracer wiring scanner：只接受直接 DEBUG region 内的真实代码") {
        let directDebug = """
            #if DEBUG
            let tracerOwner = makeTracer()
            #endif
            """
        expect(
            hasSingleOccurrenceDirectlyInsideDebug(
                "let tracerOwner = makeTracer()", in: directDebug),
            "直接 #if DEBUG region 内的代码必须命中")

        let parenthesizedElseifLifecycleLeak = """
            import AppKit
            final class ChatAXTracerSession {
                func guiWillTerminate() {}
            }
            func startExplicitChatAXTracerIfConfigured() -> ChatAXTracerSession? { nil }
            final class ClaudioGUIAppDelegate: NSObject, NSApplicationDelegate {
            #if DEBUG
            #elseif(!DEBUG)
            private var chatAXTracer: ChatAXTracerSession?
            #endif
            func applicationDidFinishLaunching(_ notification: Notification) {
            #if DEBUG
            #elseif(!DEBUG)
            chatAXTracer = startExplicitChatAXTracerIfConfigured()
            #endif
            }
            func applicationWillTerminate(_ notification: Notification) {
            #if DEBUG
            #elseif(!DEBUG)
            chatAXTracer?.guiWillTerminate()
            #endif
            }
            }
            """
        let delegateDeclaration =
            "final class ClaudioGUIAppDelegate: NSObject, NSApplicationDelegate"
        let alternateBranchTypecheck = chatAXTypechecksInDebugAndRelease(
            parenthesizedElseifLifecycleLeak)
        expect(
            alternateBranchTypecheck.succeeded,
            "alternate-branch mutation 必须能在 Debug/Release 下实际 typecheck："
                + alternateBranchTypecheck.diagnostics)
        expect(
            !hasSingleOccurrenceDirectlyInsideDebug(
                "private var chatAXTracer: ChatAXTracerSession?",
                inType: delegateDeclaration,
                source: parenthesizedElseifLifecycleLeak),
            "#elseif(!DEBUG) 内的 tracer owner 不得假冒 DEBUG-only wiring")
        expect(
            !hasSingleOccurrenceDirectlyInsideDebug(
                "chatAXTracer = startExplicitChatAXTracerIfConfigured()",
                inFunction: "func applicationDidFinishLaunching(_ notification: Notification)",
                inType: delegateDeclaration,
                source: parenthesizedElseifLifecycleLeak),
            "#elseif(!DEBUG) 内的 tracer start 不得假冒 DEBUG-only wiring")
        expect(
            !hasSingleOccurrenceDirectlyInsideDebug(
                "chatAXTracer?.guiWillTerminate()",
                inFunction: "func applicationWillTerminate(_ notification: Notification)",
                inType: delegateDeclaration,
                source: parenthesizedElseifLifecycleLeak),
            "#elseif(!DEBUG) 内的 tracer stop 不得假冒 DEBUG-only wiring")

        let alternateDirectiveVariants = [
            (
                "tab 分隔",
                parenthesizedElseifLifecycleLeak.replacingOccurrences(
                    of: "#elseif(!DEBUG)", with: "#elseif\t!DEBUG")
            ),
            (
                "块注释分隔",
                parenthesizedElseifLifecycleLeak.replacingOccurrences(
                    of: "#elseif(!DEBUG)", with: "#elseif/**/(!DEBUG)")
            ),
        ]
        for (label, mutation) in alternateDirectiveVariants {
            expect(
                !hasSingleOccurrenceDirectlyInsideDebug(
                    "private var chatAXTracer: ChatAXTracerSession?",
                    inType: delegateDeclaration,
                    source: mutation),
                "\(label)的 alternate branch owner 不得假冒 DEBUG-only wiring")
            expect(
                !hasSingleOccurrenceDirectlyInsideDebug(
                    "chatAXTracer = startExplicitChatAXTracerIfConfigured()",
                    inFunction:
                        "func applicationDidFinishLaunching(_ notification: Notification)",
                    inType: delegateDeclaration,
                    source: mutation),
                "\(label)的 alternate branch start 不得假冒 DEBUG-only wiring")
            expect(
                !hasSingleOccurrenceDirectlyInsideDebug(
                    "chatAXTracer?.guiWillTerminate()",
                    inFunction: "func applicationWillTerminate(_ notification: Notification)",
                    inType: delegateDeclaration,
                    source: mutation),
                "\(label)的 alternate branch stop 不得假冒 DEBUG-only wiring")
        }

        for directDebugVariant in [
            "#if(DEBUG)\nlet tracerOwner = makeTracer()\n#endif",
            "#if\tDEBUG\nlet tracerOwner = makeTracer()\n#endif",
        ] {
            expect(
                hasSingleOccurrenceDirectlyInsideDebug(
                    "let tracerOwner = makeTracer()", in: directDebugVariant),
                "括号或 tab 形式的直接 DEBUG condition 必须命中")
        }

        let directivePrefixDecoy = """
            #if DEBUG
            #ifAvailable()
            let tracerOwner = makeTracer()
            #endif
            """
        expect(
            hasSingleOccurrenceDirectlyInsideDebug(
                "let tracerOwner = makeTracer()", in: directivePrefixDecoy),
            "只共享 #if 文本前缀的 freestanding macro 不得污染条件栈")

        let duplicateElse = """
            #if DEBUG
            let tracerOwner = makeTracer()
            #else
            #else
            #endif
            """
        expect(
            !hasSingleOccurrenceDirectlyInsideDebug(
                "let tracerOwner = makeTracer()", in: duplicateElse),
            "重复 #else 的畸形条件结构必须 fail closed")

        let elseifAfterElse = """
            #if DEBUG
            let tracerOwner = makeTracer()
            #else
            #elseif(!DEBUG)
            #endif
            """
        expect(
            !hasSingleOccurrenceDirectlyInsideDebug(
                "let tracerOwner = makeTracer()", in: elseifAfterElse),
            "#else 后再出现 #elseif 的畸形条件结构必须 fail closed")

        for malformedDirective in ["#elseif!DEBUG", "#else()", "#endif()"] {
            let malformedStructure = """
                #if DEBUG
                let tracerOwner = makeTracer()
                \(malformedDirective)
                #endif
                """
            expect(
                !hasSingleOccurrenceDirectlyInsideDebug(
                    "let tracerOwner = makeTracer()", in: malformedStructure),
                "已知 conditional directive 的非法 payload 必须 fail closed")
        }

        let unterminatedDebug = """
            #if DEBUG
            let tracerOwner = makeTracer()
            """
        expect(
            !hasSingleOccurrenceDirectlyInsideDebug(
                "let tracerOwner = makeTracer()", in: unterminatedDebug),
            "未闭合条件栈必须 fail closed")

        let commentDecoy = """
            // #if DEBUG
            // let tracerOwner = makeTracer()
            """
        expect(
            !hasSingleOccurrenceDirectlyInsideDebug(
                "let tracerOwner = makeTracer()", in: commentDecoy),
            "注释中的 DEBUG 与 marker 不得假绿")

        let stringDecoy = "let note = \"#if DEBUG let tracerOwner = makeTracer() #endif\""
        expect(
            !hasSingleOccurrenceDirectlyInsideDebug(
                "let tracerOwner = makeTracer()", in: stringDecoy),
            "字符串中的 DEBUG 与 marker 不得假绿")

        let unrelatedDebug = """
            #if DEBUG
            let unrelated = true
            #endif
            let tracerOwner = makeTracer()
            """
        expect(
            !hasSingleOccurrenceDirectlyInsideDebug(
                "let tracerOwner = makeTracer()", in: unrelatedDebug),
            "无关 DEBUG block 不得替 block 外的 marker 假绿")

        let duplicateOutsideDebug = """
            #if DEBUG
            let tracerOwner = makeTracer()
            #endif
            let tracerOwner = makeTracer()
            """
        expect(
            !hasSingleOccurrenceDirectlyInsideDebug(
                "let tracerOwner = makeTracer()", in: duplicateOutsideDebug),
            "同一 marker 若也出现在 DEBUG 外必须失败")

        let wrongLifecycleFunction = """
            func applicationDidFinishLaunching() {}
            func unusedDebugHelper() {
            #if DEBUG
            startTracer()
            #endif
            }
            """
        expect(
            !hasSingleOccurrenceDirectlyInsideDebug(
                "startTracer()",
                inFunction: "func applicationDidFinishLaunching(",
                source: wrongLifecycleFunction),
            "把真实调用搬到未调用的 DEBUG helper 不得满足 launch lifecycle")

        let correctLifecycleFunction = """
            func applicationDidFinishLaunching() {
            #if DEBUG
            startTracer()
            #endif
            }
            """
        expect(
            hasSingleOccurrenceDirectlyInsideDebug(
                "startTracer()",
                inFunction: "func applicationDidFinishLaunching(",
                source: correctLifecycleFunction),
            "目标 lifecycle 函数自己的 DEBUG region 内调用必须命中")

        let outerAlternateBranchLifecycleRelocation = """
            import AppKit
            #if DEBUG
            #elseif(!DEBUG)
            final class ClaudioGUIAppDelegate: NSObject, NSApplicationDelegate {
            #if DEBUG
            private var chatAXTracer: ChatAXTracerSession?
            #endif
            func applicationDidFinishLaunching(_ notification: Notification) {
            #if DEBUG
            chatAXTracer = startExplicitChatAXTracerIfConfigured()
            #endif
            }
            func applicationWillTerminate(_ notification: Notification) {
            #if DEBUG
            chatAXTracer?.guiWillTerminate()
            #endif
            }
            }
            #endif
            """
        let relocationTypecheck = chatAXTypechecksInDebugAndRelease(
            outerAlternateBranchLifecycleRelocation)
        expect(
            relocationTypecheck.succeeded,
            "lifecycle relocation mutation 必须能在 Debug/Release 下实际 typecheck："
                + relocationTypecheck.diagnostics)
        expect(
            !hasSingleOccurrenceDirectlyInsideDebug(
                "private var chatAXTracer: ChatAXTracerSession?",
                inType: delegateDeclaration,
                source: outerAlternateBranchLifecycleRelocation),
            "外层 #elseif(!DEBUG) 中不可达的 DEBUG owner 不得假冒 lifecycle wiring")
        expect(
            !hasSingleOccurrenceDirectlyInsideDebug(
                "chatAXTracer = startExplicitChatAXTracerIfConfigured()",
                inFunction: "func applicationDidFinishLaunching(_ notification: Notification)",
                inType: delegateDeclaration,
                source: outerAlternateBranchLifecycleRelocation),
            "外层 #elseif(!DEBUG) 中不可达的 DEBUG start 不得假冒 lifecycle wiring")
        expect(
            !hasSingleOccurrenceDirectlyInsideDebug(
                "chatAXTracer?.guiWillTerminate()",
                inFunction: "func applicationWillTerminate(_ notification: Notification)",
                inType: delegateDeclaration,
                source: outerAlternateBranchLifecycleRelocation),
            "外层 #elseif(!DEBUG) 中不可达的 DEBUG stop 不得假冒 lifecycle wiring")

        let dummyOwnerType = """
            final class DummyDelegate {
            #if DEBUG
            private var chatAXTracer: ChatAXTracerSession?
            #endif
            func applicationDidFinishLaunching(_ notification: Notification) {
            #if DEBUG
            startTracer()
            #endif
            }
            }
            final class ClaudioGUIAppDelegate: NSObject, NSApplicationDelegate {
                func applicationDidFinishLaunching(_ notification: Notification) {}
            }
            """
        expect(
            !hasSingleOccurrenceDirectlyInsideDebug(
                "startTracer()",
                inFunction: "func applicationDidFinishLaunching(_ notification: Notification)",
                inType: "final class ClaudioGUIAppDelegate: NSObject, NSApplicationDelegate",
                source: dummyOwnerType),
            "前置 dummy type 不得替真实 AppDelegate lifecycle 接线假绿")

        let budgetedQuery = """
            func element() {
                guard prepareForMessaging(element) else { return }
                AXUIElementCopyAttributeValue(element)
            }
            """
        expect(
            chatAXFunctionContainsMarkersInOrder(
                ["prepareForMessaging(element)", "AXUIElementCopyAttributeValue("],
                inFunction: "func element(",
                source: budgetedQuery),
            "AX query 前的预算门禁必须命中")

        let lateBudget = """
            func element() {
                AXUIElementCopyAttributeValue(element)
                prepareForMessaging(element)
            }
            """
        expect(
            !chatAXFunctionContainsMarkersInOrder(
                ["prepareForMessaging(element)", "AXUIElementCopyAttributeValue("],
                inFunction: "func element(",
                source: lateBudget),
            "删掉 query 前门禁、只在之后留下 decoy 时必须失败")
    }

    suite("Chat AX tracer GUI wiring：owner、start 与 terminate 各自直接受 DEBUG 保护") {
        guard
            let app = chatAXWiringSource("gui/Sources/ClaudioGUI/ClaudioGUIApp.swift")
        else {
            expect(false, "必须能读取 ClaudioGUIApp.swift 才能验证 tracer wiring")
            return
        }

        let delegateDeclaration =
            "final class ClaudioGUIAppDelegate: NSObject, NSApplicationDelegate"
        expect(
            hasSingleOccurrenceDirectlyInsideDebug(
                "private var chatAXTracer: ChatAXTracerSession?",
                inType: delegateDeclaration,
                source: app),
            "chatAXTracer owner 必须且只能直接位于自己的 #if DEBUG region")
        expect(
            hasSingleOccurrenceDirectlyInsideDebug(
                "chatAXTracer = startExplicitChatAXTracerIfConfigured(",
                inFunction: "func applicationDidFinishLaunching(_ notification: Notification)",
                inType: delegateDeclaration,
                source: app),
            "tracer start 必须且只能位于 applicationDidFinishLaunching 的 #if DEBUG region")
        expect(
            hasSingleOccurrenceDirectlyInsideDebug(
                "chatAXTracer?.guiWillTerminate()",
                inFunction: "func applicationWillTerminate(_ notification: Notification)",
                inType: delegateDeclaration,
                source: app),
            "tracer stop 必须且只能位于 applicationWillTerminate 的 #if DEBUG region")
    }
}
