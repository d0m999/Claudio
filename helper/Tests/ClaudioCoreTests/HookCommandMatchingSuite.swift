import ClaudioCore
import Foundation

// MARK: - matchedClaudioEvent(inHookCommand:) (T13): the structural predicate `uninstall`'s
// removal sweep keys off, so it can recognize a claudio hook command written at a path it
// was never told about in advance (a relocated/historical binary path), while never
// misfiring on a third-party tool's hook. See `SettingsInstaller.swift`'s adversarial
// argument in the doc comment above this function for the full "why this can't misfire"
// case; these tests pin every branch of that argument individually.

private let canonicalPath = "/Users/tester/.claudio/bin/claudio"

@MainActor
func runHookCommandMatchingSuites() {
    suite("matchedClaudioEvent: recognizes today's canonical path for every one of the 4 events") {
        for event in Event.allCases {
            let command = "\(canonicalPath) play \(event.cliName)"
            expect(
                matchedClaudioEvent(inHookCommand: command) == event,
                "expected \(event) for \"\(command)\", got"
                    + " \(String(describing: matchedClaudioEvent(inHookCommand: command)))")
        }
    }

    suite(
        "matchedClaudioEvent: recognizes a RELOCATED binary path under a different"
            + " subdirectory of the SAME .claudio/ namespace — the load-bearing case T13 exists"
            + " for (a future release moving bin/ -> libexec/, or any other subpath)"
    ) {
        let relocated = "/Users/tester/.claudio/libexec/claudio play stop"
        expect(
            matchedClaudioEvent(inHookCommand: relocated) == .stop,
            "a relocated-but-still-.claudio-namespaced path must still match, got"
                + " \(String(describing: matchedClaudioEvent(inHookCommand: relocated)))")
    }

    suite(
        "matchedClaudioEvent: recognizes the binary living directly at the .claudio/ root"
            + " (no subdirectory at all) — namespace membership doesn't require any"
            + " particular depth"
    ) {
        let atRoot = "/Users/tester/.claudio/claudio play notification"
        expect(
            matchedClaudioEvent(inHookCommand: atRoot) == .notification,
            "got \(String(describing: matchedClaudioEvent(inHookCommand: atRoot)))")
    }

    suite(
        "matchedClaudioEvent: rejects a basename mismatch — a DIFFERENT tool living inside"
            + " .claudio/ is not claudio, even with the right argv shape"
    ) {
        let lookalike = "/Users/tester/.claudio/bin/mytool play stop"
        expect(
            matchedClaudioEvent(inHookCommand: lookalike) == nil,
            "a non-\"claudio\"-named binary must never match, got"
                + " \(String(describing: matchedClaudioEvent(inHookCommand: lookalike)))")
    }

    suite(
        "matchedClaudioEvent: rejects a claudio-named binary OUTSIDE the .claudio/ namespace"
            + " — the task's own example of a user's unrelated tool"
    ) {
        let outside = "/usr/local/bin/claudio play stop"
        expect(
            matchedClaudioEvent(inHookCommand: outside) == nil,
            "a claudio-named binary outside .claudio/ must never match, got"
                + " \(String(describing: matchedClaudioEvent(inHookCommand: outside)))")

        let usersBin = "/Users/tester/bin/claudio play stop"
        expect(
            matchedClaudioEvent(inHookCommand: usersBin) == nil,
            "a user's own ~/bin/claudio, coincidentally named claudio, must never match, got"
                + " \(String(describing: matchedClaudioEvent(inHookCommand: usersBin)))")
    }

    suite(
        "matchedClaudioEvent: rejects `..` traversal that cancels the .claudio/ component out"
    ) {
        // A literal `.claudio` component is NOT the same fact as "resolves inside .claudio/".
        // Each path below contains one, yet lexically resolves outside the namespace — so a
        // component scan alone would hand uninstall (which takes no backup) an entry that is
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

            let command = "\(rawPath) play stop"
            expect(
                matchedClaudioEvent(inHookCommand: command) == nil,
                "a `..`-traversing path resolving OUTSIDE .claudio/ must never match, got"
                    + " \(String(describing: matchedClaudioEvent(inHookCommand: command)))")
        }

        // Guard the conservative direction explicitly: `..` is rejected even when the path
        // would still resolve inside the namespace. claudio has never written a `..`, so
        // refusing to sweep it leaves a harmless leftover rather than risking a wrong delete.
        let staysInside = "/Users/tester/.claudio/bin/../bin/claudio play stop"
        expect(
            (staysInside.split(separator: " ").map(String.init)[0] as NSString).standardizingPath
                == "/Users/tester/.claudio/bin/claudio",
            "premise: this path resolves back inside .claudio/")
        expect(
            matchedClaudioEvent(inHookCommand: staysInside) == nil,
            "any `..` component is rejected outright (fail-closed), got"
                + " \(String(describing: matchedClaudioEvent(inHookCommand: staysInside)))")
    }

    suite("matchedClaudioEvent: rejects an unrecognized event name") {
        let unknownEvent = "\(canonicalPath) play deploy"
        expect(
            matchedClaudioEvent(inHookCommand: unknownEvent) == nil,
            "\"deploy\" is not one of the 4 Event.cliName values, got"
                + " \(String(describing: matchedClaudioEvent(inHookCommand: unknownEvent)))")
    }

    suite("matchedClaudioEvent: rejects a command with an extra trailing argv segment") {
        let extraSegment = "\(canonicalPath) play stop --verbose"
        expect(
            matchedClaudioEvent(inHookCommand: extraSegment) == nil,
            "a 4-token command must never match (exactly 3 tokens required), got"
                + " \(String(describing: matchedClaudioEvent(inHookCommand: extraSegment)))")
    }

    suite("matchedClaudioEvent: rejects a command missing the event argument entirely") {
        let missingEvent = "\(canonicalPath) play"
        expect(
            matchedClaudioEvent(inHookCommand: missingEvent) == nil,
            "a 2-token command must never match, got"
                + " \(String(describing: matchedClaudioEvent(inHookCommand: missingEvent)))")
    }

    suite("matchedClaudioEvent: rejects a subcommand other than \"play\"") {
        let wrongSubcommand = "\(canonicalPath) run stop"
        expect(
            matchedClaudioEvent(inHookCommand: wrongSubcommand) == nil,
            "the second token must be exactly \"play\", got"
                + " \(String(describing: matchedClaudioEvent(inHookCommand: wrongSubcommand)))")
    }

    suite("matchedClaudioEvent: rejects a relative path even if it lexically contains .claudio/") {
        let relative = ".claudio/bin/claudio play stop"
        expect(
            matchedClaudioEvent(inHookCommand: relative) == nil,
            "every path claudio itself ever writes is absolute; a relative one must never"
                + " match, got \(String(describing: matchedClaudioEvent(inHookCommand: relative)))"
        )
    }

    suite("matchedClaudioEvent: rejects a completely unrelated third-party hook command") {
        expect(
            matchedClaudioEvent(inHookCommand: "vibe-island stop") == nil,
            "an unrelated 2-token third-party command must never match")
        expect(
            matchedClaudioEvent(inHookCommand: "block-no-verify") == nil,
            "an unrelated single-token third-party command must never match")
    }

    suite(
        "matchedClaudioEvent: tolerates cosmetic extra/leading/trailing whitespace — never"
            + " produced by claudioHookCommand itself, but harmless to accept"
    ) {
        let spaced = "   \(canonicalPath)   play   stop   "
        expect(
            matchedClaudioEvent(inHookCommand: spaced) == .stop,
            "extra whitespace must not block a real match, got"
                + " \(String(describing: matchedClaudioEvent(inHookCommand: spaced)))")
    }

    suite(
        "matchedClaudioEvent: does NOT expand $HOME — a variable-relative form is simply not"
            + " an absolute path and safely falls through as \"not ours\" (documented"
            + " limitation, not a bug)"
    ) {
        let withVariable = "$HOME/.claudio/bin/claudio play stop"
        expect(
            matchedClaudioEvent(inHookCommand: withVariable) == nil,
            "a $HOME-relative command must not match (no shell expansion performed), got"
                + " \(String(describing: matchedClaudioEvent(inHookCommand: withVariable)))")
    }

    suite(
        "matchedClaudioEvent: does NOT strip quotes around the path — claudio has never"
            + " written a quoted form (no spaces in ~/.claudio/), so a quoted command simply"
            + " doesn't match (documented limitation, not a bug)"
    ) {
        let quoted = "\"\(canonicalPath)\" play stop"
        expect(
            matchedClaudioEvent(inHookCommand: quoted) == nil,
            "a quoted path must not match today (no quote-stripping implemented), got"
                + " \(String(describing: matchedClaudioEvent(inHookCommand: quoted)))")
    }

    suite("matchedClaudioEvent: rejects an empty command string") {
        expect(
            matchedClaudioEvent(inHookCommand: "") == nil, "an empty string must never match")
    }
}
