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

private func hasSingleOccurrenceDirectlyInsideDebug(
    _ marker: String,
    in source: String
) -> Bool {
    guard !marker.isEmpty else { return false }
    let scanned = strippingComments(source)
    guard scanned.unmodeledConstructs.isEmpty else { return false }

    var conditionalStack: [Bool] = []
    var markerLocations: [Bool] = []
    for sourceLine in scanned.codeWithoutStringLiterals.split(
        separator: "\n", omittingEmptySubsequences: false
    ) {
        let line = String(sourceLine)
        let directive = line.trimmingCharacters(in: .whitespaces)
        if directive.hasPrefix("#if ") {
            conditionalStack.append(directive == "#if DEBUG")
            continue
        }
        if directive.hasPrefix("#elseif ") || directive == "#else" {
            guard !conditionalStack.isEmpty else { return false }
            conditionalStack[conditionalStack.count - 1] = false
            continue
        }
        if directive == "#endif" {
            guard conditionalStack.popLast() != nil else { return false }
            continue
        }

        let occurrenceCount = line.components(separatedBy: marker).count - 1
        markerLocations.append(
            contentsOf: repeatElement(
                conditionalStack == [true],
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
        let functionRegion = chatAXFunctionRegion(declaration, in: code)
    else {
        return false
    }
    return hasSingleOccurrenceDirectlyInsideDebug(marker, in: functionRegion)
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
        let typeRegion = chatAXBracedDeclarationRegion(typeDeclaration, in: code)
    else {
        return false
    }
    return hasSingleOccurrenceDirectlyInsideDebug(marker, in: typeRegion)
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
        let functionRegion = chatAXFunctionRegion(functionDeclaration, in: typeRegion)
    else {
        return false
    }
    return hasSingleOccurrenceDirectlyInsideDebug(marker, in: functionRegion)
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
