import Foundation

// Historical/relocated hook-command recognition — used by `uninstall` only (T13).
//
// ENGINEERING.md「其它折进计划」: "uninstall 识别历史命令格式（为将来路径变更）" — if a future
// claudio release ever moves the helper binary (today: `~/.claudio/bin/claudio`, see
// `ClaudioPaths.claudioBinary`), THIS build's `uninstall` must still be able to sweep up a
// stale hook entry a PAST release wrote, without ever having been told that old path ahead
// of time. `claudioHookCommand(for:claudioBinaryPath:)`'s exact-string compare (which
// `install`/`detectHookInstallStatus` keep using, unchanged) cannot do that by definition —
// it only recognizes the one path it's given.
//
// The fix is a STRUCTURAL match, not a hardcoded list of past string literals: today there
// is no second historical form to enumerate — claudio has never written any command shape
// other than the canonical one — so a literal registry of past strings would either be empty
// (pointless) or fabricated purely to make a test look thorough. Instead,
// `matchedClaudioEvent(inHookCommand:claudioRoot:)` recognizes any command that has claudio's
// shape *inside claudio's own root*, which covers the one form we have written AND any future
// relocation, without needing to know its exact path in advance.
//
// This file also owns `shellQuotedPath(_:)` — the writer-side inverse of the unquoting the
// matcher performs. They are a round-trip pair (pinned by a test), which is the only reason
// the matcher can be sure what shapes it must accept.

// MARK: - Writer-side quoting

/// Characters that change how `/bin/sh -c` parses a bare word, and therefore force the path
/// to be quoted before it is interpolated into a hook command.
///
/// Deliberately **minimal**. Every path that works unquoted right now must keep producing a
/// **byte-identical** command string, because `install`'s idempotency check and
/// ``detectHookInstallStatus(settingsFile:claudioBinaryPath:)`` both compare that string for
/// exact equality against what is already in `settings.json` — widening this set would make an
/// upgraded claudio fail to recognize its own previously-installed hook and append a duplicate.
/// So membership is decided by one question only: *does `/bin/sh -c` mangle a bare word
/// containing this character?* Each entry below was checked against the real `/bin/sh`
/// (bash 3.2 in POSIX mode) on 2026-07-10, as was each deliberate omission:
///
/// - **Omitted, verified literal mid-word**: `#` and `!` (comment / history expansion only
///   apply at word start, and history expansion is off non-interactively), `~` (tilde
///   expansion only at word start, and every path here begins with `/`), `]`, `=`, `%`, `+`,
///   `,`, and every non-ASCII scalar — so `/Users/张三/.claudio/bin/claudio` stays unquoted.
/// - **Included, verified to mangle**: whitespace and the classic metacharacters, plus:
///   - `{` `}` — brace expansion fires on `a{c,d}e` even in POSIX mode. Verified:
///     `sh -c '/tmp/a{c,d}e/prog'` execs `/tmp/ace/prog`, so the hook **silently never runs**.
///   - `*` `?` `[` — globbing does not merely "risk" the wrong path, it *takes* it. Verified:
///     with siblings `a!b` and `a*b` both present, `sh -c '/tmp/a*b/prog'` executed
///     `/tmp/a!b/prog` — **a different binary**. Quoting these is why they are here even
///     though a lucky unquoted path (no sibling matches, so the glob yields itself) would have
///     appeared to work, and will therefore pick up a duplicate hook entry on upgrade. Running
///     the wrong program is the worse failure; the duplicate is recoverable with
///     `claudio uninstall && claudio install` (the structural matcher sweeps both forms).
///
/// Net: quoting only ever engages for a path whose hook was already broken (space, `$`, `{`)
/// or already wrong (`*`), never for one that was silently fine.
private let shellUnsafeCharacters: Set<Character> = [
    " ", "\t", "\n", "\r",
    "\"", "'", "\\", "`", "$", "&", ";", "|", "<", ">", "(", ")", "*", "?", "[", "{", "}",
]

/// ``shellUnsafeCharacters`` flattened to Unicode scalars. **Every** shell-word decision in this
/// file — the writer's quote-or-not in ``shellQuotedPath(_:)`` and the matcher's below-root scan
/// in ``isClaudioBinaryPath(_:claudioRoot:)`` — is taken at *scalar* granularity, because
/// `/bin/sh` reads bytes and a `Character` is not a byte.
///
/// A `Character`-level membership test silently misses every unsafe scalar that fuses with what
/// follows it into one extended grapheme cluster, and such a cluster equals none of the single-
/// scalar `Character`s in the set:
/// - `\r\n` — Swift fuses CR+LF into one `Character`, present in the set under neither bare `\r`
///   nor bare `\n`, yet `/bin/sh` still reads that byte pair as a line break that splits the
///   command.
/// - **any metacharacter followed by a combining mark** — `*` + U+0301 is one `Character` that is
///   not `*`, while `/bin/sh` still sees the `*` byte and globs. Verified 2026-07-10 against the
///   real `/bin/sh`: with siblings `a!<U+0301>b` and `a*<U+0301>b` present, an unquoted
///   `…/a*<U+0301>b/.claudio/bin/claudio play stop` **execs the binary under `a!<U+0301>b`** —
///   a different program. The same fusion hides a backtick (unterminated command substitution:
///   `sh` aborts with a syntax error and the hook never runs) and a `'` (which would otherwise
///   break the writer's own `'\''` escape).
///
/// Scanning scalars closes all of it at once, and is a strict superset of the `Character` check,
/// so every path that quoted before still quotes and — the invariant that actually matters —
/// every path that was **already shell-word-safe** still contains no unsafe scalar and is still
/// emitted verbatim. See ``shellQuotedPath(_:)``'s identity requirement.
private let shellUnsafeScalars: Set<Unicode.Scalar> = Set(
    shellUnsafeCharacters.flatMap { $0.unicodeScalars })

/// The two scalars the quoting round-trip is written in terms of, spelled in the scalar view the
/// writer and the decoder both operate on.
private let singleQuoteScalar: Unicode.Scalar = "'"
private let backslashScalar: Unicode.Scalar = "\\"

/// Scalar-view spellings of the three literals ``isClaudioBinaryPath(_:claudioRoot:)`` compares
/// against. That function decides path structure on Unicode *scalars* rather than `Character`s
/// or `String`s — see its doc comment for why `String` equality is the wrong tool here — so its
/// separator and its component literals have to live in the same view.
private let pathSeparatorScalar: Unicode.Scalar = "/"
private let parentDirectoryScalars = Array("..".unicodeScalars)
private let claudioBasenameScalars = Array("claudio".unicodeScalars)

/// Renders `path` as a single `/bin/sh` word: returned unchanged when it is already
/// shell-word-safe, otherwise wrapped in POSIX single quotes with any embedded `'` escaped as
/// `'\''` (the standard idiom — close the quote, emit an escaped literal quote, reopen).
///
/// `ClaudioPaths`'s whole design (决议 4) is to keep this a no-op: `~/.claudio/` was chosen
/// over `Application Support` precisely because it has no space. But `~` expands to
/// `/Users/<user>`, and **that** segment is outside claudio's control — a home directory
/// carrying a space (AD/network accounts, `dscl`-created accounts) made
/// `claudioHookCommand(for:claudioBinaryPath:)` emit a command the shell splits into pieces:
/// the hook never fired, and (before this) `uninstall` could not even recognize it to clean
/// it up. Quoting is what makes the T4 concern structurally impossible rather than merely
/// asserted about the happy path.
///
/// **Identity requirement.** For every path that already works unquoted — plain ASCII, CJK,
/// anything carrying no unsafe scalar — this must return `path` byte-for-byte, because `install`'s
/// idempotency check and ``detectHookInstallStatus(settingsFile:claudioBinaryPath:)`` compare the
/// emitted command for exact equality against what is already in `settings.json`. Widening the
/// quoted set beyond ``shellUnsafeScalars`` would make an upgraded claudio fail to recognize its
/// own hook and append a duplicate; narrowing it re-opens the mangling above.
///
/// Both the unsafe scan and the `'\''` escape run on ``String/unicodeScalars``, never on
/// `Character`s: a `'` fused with a following combining mark is one `Character` that is not `'`,
/// so a `Character`-level escape would emit the quote unescaped and produce a word `/bin/sh`
/// cannot parse — and a `Character`-level scan would not have quoted the path at all. See
/// ``shellUnsafeScalars``.
public func shellQuotedPath(_ path: String) -> String {
    guard path.isEmpty || path.unicodeScalars.contains(where: { shellUnsafeScalars.contains($0) })
    else { return path }

    var quoted = String.UnicodeScalarView()
    quoted.append(singleQuoteScalar)
    for scalar in path.unicodeScalars {
        guard scalar == singleQuoteScalar else {
            quoted.append(scalar)
            continue
        }
        // The standard idiom: close the quote, emit an escaped literal quote, reopen.
        quoted.append(contentsOf: "'\\''".unicodeScalars)
    }
    quoted.append(singleQuoteScalar)
    return String(quoted)
}

// MARK: - Matcher

/// Whether `command` is a hook command claudio itself could plausibly have written **from the
/// `claudioRoot` namespace**, for any of the five sound events — returns the matched ``Event``,
/// or `nil` if it doesn't look like one of ours. This is the single source of truth
/// `removeHookEntries` (uninstall's removal sweep) keys off;
/// `install`/``detectHookInstallStatus(settingsFile:claudioBinaryPath:)`` deliberately do NOT
/// use this — they compare against the one exact, current
/// ``claudioHookCommand(for:claudioBinaryPath:)`` string, because onboarding/self-heal need to
/// know "does *today's* exact hook exist", not "does something claudio-shaped exist".
///
/// `claudioRoot` is claudio's own `.claudio` directory (``ClaudioPaths/root``), passed in
/// rather than read from the environment so this stays a pure predicate. `uninstall` derives
/// it from the binary path it was handed, via ``claudioNamespaceRoot(forBinaryPath:)``.
///
/// **Why this can never misfire on a third-party hook** (adversarial argument, not just an
/// assertion — every clause below is pinned by a case in `HookCommandMatchingSuite.swift`):
/// 1. **Exact trailing argv**: `command` must end with the literal ` play <event>`, where
///    `<event>` is one of the 5 real ``Event/cliName`` values. `mytool play deploy` fails; so
///    does anything with a trailing operator or extra argument (` play stop --verbose`,
///    ` play stop && rm -rf ~`), because that text is no longer the suffix.
/// 2. **Everything before that suffix is read as one word**, decoded via
///    ``shellQuotedPath(_:)``'s inverse. When that decoding fails or disagrees with the raw
///    text (a legacy entry whose path carries `'` or `\`), the raw text is tried too — see
///    ``shellWordContents(_:)``. Clause 3, not this one, is what makes the match safe.
/// 3. **That word must be `<claudioRoot>/…/claudio`**: literally prefixed by claudio's own
///    root, free of `..`, with a basename of exactly `claudio`, and — below that root — free of
///    any shell metacharacter (see ``isClaudioBinaryPath(_:claudioRoot:)``). It is *not* enough
///    for some component to be named `.claudio` — `/tmp/.claudio/bin/claudio play stop` and
///    `/Users/someone-else/.claudio/bin/claudio play stop` both fail, because neither is under
///    *this* user's root. That is the difference between "looks like claudio's namespace" and
///    "is claudio's namespace", and `uninstall` is the one destructive path in this codebase
///    that (unlike `install`) takes **no backup** before rewriting `settings.json`.
///
/// Combined, a false positive requires an entry whose command is literally
/// `<this user's ~/.claudio>/<anything>/claudio play <one of our 5 events>` — i.e. claudio's
/// own binary, under claudio's own directory. Sweeping that is the job, not a misfire. The
/// match stays deliberately loose about *which subdirectory* under the root (`bin/`, a future
/// `libexec/`, the root itself), which is exactly what survives a relocation.
///
/// **The `..` rejection is load-bearing, not hygiene.** `<root>/../claudio` is literally
/// prefixed by the root yet lexically resolves outside it. Rejecting `..` outright rather than
/// normalizing and re-checking is the conservative direction, and matches the existing
/// precedent in ``safePackFileURL(_:in:)``: claudio has never written a `..` into a hook
/// command, so a residue containing one is definitionally not ours, and refusing to sweep it
/// merely leaves a harmless leftover instead of risking someone else's hook.
///
/// **What this deliberately does NOT recognize** (documented limitations, not silent gaps):
/// - **No shell metacharacter below the root**: claudio's own subtree is always plain segments
///   (`bin/claudio`, a future `libexec/claudio`). A quote, backslash, `$`, backtick, whitespace,
///   or newline *below* the root is rejected outright, because on the raw-text candidate such a
///   character can hide a `..` traversal or a command substitution that resolves outside the root
///   (`…/.claudio/'..'/bin/claudio`, `…/.claudio/$(echo ..)/claudio`), or — a newline — split the
///   command so `/bin/sh` execs a different `argv[0]` entirely. Metacharacters in the *home*
///   segment are unaffected: that segment must match the root literally, so a legacy bare entry
///   under a `$`- or space-carrying home still sweeps.
/// - **No shell variable expansion** (`$HOME`, `~`): claudio always writes a fully-resolved
///   absolute path, so there is no real historical form using a variable. `$HOME/.claudio/…`
///   is not prefixed by the resolved root and simply falls through as "not ours".
/// - **No double quotes, and no backslash escape other than `\'`, are ever *decoded***:
///   ``shellQuotedPath(_:)`` emits neither, so interpreting them would only widen the
///   destructive match surface for a form we have never produced. Such a word is still matched
///   *literally* if it is prefixed by the root **and** carries no metacharacter below it (the
///   legacy fallback), never by giving the escape its shell meaning.
/// - **No internal-whitespace collapsing**: `<path>␣␣play␣␣stop` does not match. Tolerating
///   repeated inner spaces is *unrepresentable* alongside supporting a real path that contains
///   a space — the two are the same character. Leading/trailing whitespace is still trimmed,
///   since that cannot be part of a path claudio wrote.
public func matchedClaudioEvent(inHookCommand command: String, claudioRoot: String) -> Event? {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    for event in Event.allCases {
        let suffix = " play \(event.cliName)"
        guard trimmed.hasSuffix(suffix) else { continue }
        // No two `cliName`s can both suffix-match (none is a ` play `-preceded suffix of
        // another), so the first hit is the only candidate — a bad path here is a rejection,
        // not a reason to keep scanning.
        let rawWord = String(trimmed.dropLast(suffix.count))
        // Two candidates, not one. The decoded word is what today's writer meant; `rawWord` is
        // what a pre-quoting claudio literally wrote. A legacy path carrying `'` or `\` either
        // fails to decode (unbalanced quote) *or* decodes to the wrong string (`/Users/o'b'rien`
        // → `/Users/obrien`), and in both cases only the raw text is prefixed by the real root.
        // Both candidates are checked by the SAME `isClaudioBinaryPath`, whose below-root
        // metacharacter guard is what keeps the raw text from widening the match: neither a
        // quoted `..`, a `$`/backtick command substitution, nor an embedded newline can survive
        // below the root, on either candidate (the decoder strips none of the latter three). See
        // that function — this is *not* "the raw text is inherently safe because it is
        // root-prefixed", a claim that quoting and command substitution both falsify.
        let candidates = [shellWordContents(rawWord), rawWord].compactMap { $0 }
        guard candidates.contains(where: { isClaudioBinaryPath($0, claudioRoot: claudioRoot) })
        else { return nil }
        return event
    }
    return nil
}

/// 新版双宿主 hook 命令的结构化识别结果。只有完整匹配 Claudio 自有命名空间、
/// 已知宿主、该宿主真实支持的原生事件和合法 installation UUID 才会产生结果。
public struct MatchedHostHookCommand: Sendable, Equatable {
    public let host: HostID
    public let nativeEvent: String
    public let event: Event
    public let installationID: UUID

    public init(host: HostID, nativeEvent: String, event: Event, installationID: UUID) {
        self.host = host
        self.nativeEvent = nativeEvent
        self.event = event
        self.installationID = installationID
    }
}

/// 生成带安装代次的新版 hook 命令。未知事件和宿主不支持的事件失败关闭；特别是 Codex
/// `StopFailure` 与 `UserPromptSubmit` 永远不会被写成可执行 hook。
public func hostIntegrationHookCommand(
    host: HostID,
    nativeEvent: String,
    installationID: UUID,
    claudioBinaryPath: String
) -> String? {
    guard HostCapabilityCatalog.semanticEvent(host: host, nativeEvent: nativeEvent) != nil else {
        return nil
    }
    return "\(shellQuotedPath(claudioBinaryPath)) hook \(host.rawValue) \(nativeEvent)"
        + " --installation-id \(installationID.uuidString)"
}

/// 结构化匹配 Claudio namespace 内任意历史位置的新版 hook 命令。宽路径判定只供
/// disconnect/uninstall 清扫旧位置；连接状态必须使用 ``matchedCurrentHostHookCommand``，
/// 否则一个已经移除的 root 内旧 helper 会被误判成当前可听连接。
public func matchedHostHookCommand(
    inHookCommand command: String,
    claudioRoot: String
) -> MatchedHostHookCommand? {
    matchHostHookCommand(inHookCommand: command) {
        isClaudioBinaryPath($0, claudioRoot: claudioRoot)
    }
}

/// 只接受 writer 当前会生成的 helper 绝对路径。helper 路径与最终 canonical command 都按
/// UTF-8 bytes 精确比较，不能让 Swift `String ==` 的 canonical equivalence 把 NFC/NFD 两个
/// 文件误认为同一代。inspect/connect 用它；路径迁移后的历史 command 不会冒充当前连接，
/// 显式 connect 也就能够补写新的 canonical command。
public func matchedCurrentHostHookCommand(
    inHookCommand command: String,
    claudioBinaryPath: String
) -> MatchedHostHookCommand? {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
        let match = matchHostHookCommand(
            inHookCommand: command,
            acceptsBinaryPath: { $0.utf8.elementsEqual(claudioBinaryPath.utf8) }),
        let canonical = hostIntegrationHookCommand(
            host: match.host,
            nativeEvent: match.nativeEvent,
            installationID: match.installationID,
            claudioBinaryPath: claudioBinaryPath),
        trimmed.utf8.elementsEqual(canonical.utf8)
    else { return nil }
    return match
}

private func matchHostHookCommand(
    inHookCommand command: String,
    acceptsBinaryPath: (String) -> Bool
) -> MatchedHostHookCommand? {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    let installationMarker = " --installation-id "
    guard let markerRange = trimmed.range(of: installationMarker, options: .backwards),
        markerRange.upperBound < trimmed.endIndex
    else { return nil }

    let uuidText = String(trimmed[markerRange.upperBound...])
    guard !uuidText.contains(where: { $0.isWhitespace }),
        let installationID = UUID(uuidString: uuidText)
    else { return nil }
    let commandWithoutID = String(trimmed[..<markerRange.lowerBound])

    for host in HostID.allCases {
        for binding in HostCapabilityCatalog.bindings(for: host) where binding.isAudibleCapability {
            guard let nativeEvent = binding.nativeEvent else { continue }
            let suffix = " hook \(host.rawValue) \(nativeEvent)"
            guard commandWithoutID.hasSuffix(suffix) else { continue }
            let rawWord = String(commandWithoutID.dropLast(suffix.count))
            let candidates = [shellWordContents(rawWord), rawWord].compactMap { $0 }
            guard candidates.contains(where: acceptsBinaryPath) else { return nil }
            return MatchedHostHookCommand(
                host: host,
                nativeEvent: nativeEvent,
                event: binding.event,
                installationID: installationID)
        }
    }
    return nil
}

/// The `.claudio` namespace root that `binaryPath` lives in — the prefix up to and including
/// its first `.claudio` component (`/Users/x/.claudio/bin/claudio` → `/Users/x/.claudio`), or
/// `nil` when `binaryPath` is relative, carries a `..`, or has no `.claudio` component at all.
///
/// `uninstall` calls this on the `claudioBinaryPath` it was handed rather than reading
/// ``ClaudioPaths/root`` directly, so the removal sweep is anchored to the *same* installation
/// the caller is talking about (and so every test can point it at a fixture root). A `nil`
/// return is fail-closed: `uninstall` then matches nothing rather than falling back to a
/// wider rule. It is unreachable in production, where the path defaults to
/// ``ClaudioPaths/claudioBinary``.
public func claudioNamespaceRoot(forBinaryPath binaryPath: String) -> String? {
    guard binaryPath.hasPrefix("/") else { return nil }
    let components = binaryPath.split(separator: "/", omittingEmptySubsequences: true)
        .map(String.init)
    guard !components.contains(".."), let index = components.firstIndex(of: ".claudio")
    else { return nil }
    return "/" + components[...index].joined(separator: "/")
}

/// Whether a hook command written for `binaryPath` would be an entry that this build's
/// `uninstall` — anchored at the very namespace `binaryPath` itself names — could never sweep
/// back out. `install` refuses such a path outright; see
/// ``SettingsUpdateError/unsweepableBinaryPath(path:)``.
///
/// The writer and the matcher are meant to be a pair, but they are not symmetric.
/// ``shellQuotedPath(_:)`` renders *any* path as one valid `/bin/sh` word — including
/// `<root>/lib exec/claudio` — while ``matchedClaudioEvent(inHookCommand:claudioRoot:)`` rejects
/// a below-root space, quote, or `$` (see ``isClaudioBinaryPath(_:claudioRoot:)``). Nothing in
/// production reaches that gap today: the path is always `<root>/bin/claudio`. But this file
/// exists so that a *future* relocation keeps working, and a relocation into `libexec dir/` — or
/// one that renames the binary to anything but `claudio` — would silently append a hook entry no
/// later `uninstall` could ever remove, to a file `uninstall` takes no backup of. Checking the
/// invariant at the writer turns a silent, permanent leak into a loud failure at the one moment
/// it could be introduced.
///
/// A `binaryPath` naming **no** `.claudio` namespace at all (`/usr/local/bin/claudio`, or a past
/// release's `.claudio-OLD/`) is not a contradiction and returns `false`.
/// ``claudioNamespaceRoot(forBinaryPath:)`` yields `nil` for it, so `uninstall` fail-closes and
/// never claimed it would sweep such an entry — the pre-existing, documented behavior that
/// ``detectHookInstallStatus(settingsFile:claudioBinaryPath:)``'s stale-namespace coverage
/// installs through on purpose. The invariant pinned here is the exact one, no wider: *if* a path
/// names a namespace, it must be a shape that namespace's own sweep accepts.
///
/// A `nil` root is therefore **not** by itself a licence to install.
/// ``claudioNamespaceRoot(forBinaryPath:)`` returns `nil` for three different shapes and only the
/// last is that carve-out: a relative path, a path carrying a `..` component, and a path with no
/// `.claudio` component. The first two *do* name this namespace — `/bin/sh` resolves
/// `<root>/bin/../bin/claudio` back to the real binary at exec time, so the hook they write really
/// fires — while ``matchedClaudioEvent(inHookCommand:claudioRoot:)`` rejects both outright (`..` is
/// refused fail-closed even when it resolves back *inside* the root; a relative path can never
/// clear the absolute-root prefix gate). Reading `nil` as "nothing to contradict" would install a
/// live hook that no `uninstall` — not even one anchored at the true root — could ever match back
/// out, which is the precise leak this guard exists to prevent.
///
/// This predicate is purely **lexical** — it neither resolves symlinks nor collapses `.` segments,
/// so two shapes slip past it, both unreachable in production and unclosable without touching the
/// filesystem at install time: a path reaching `.claudio` through a symlinked component
/// (`/Users/x/link/bin/claudio`, `link → .claudio`), and a `.`-decorated spelling above the
/// namespace (`/Users/x/./.claudio/bin/claudio`) whose derived root is non-canonical. Production
/// only ever passes the literal canonical path ``ClaudioPaths`` builds, so neither arises — the same
/// lexical limit the NFC/NFD normalization caveat on ``isClaudioBinaryPath(_:claudioRoot:)`` documents.
public func binaryPathContradictsItsNamespace(_ binaryPath: String) -> Bool {
    guard let claudioRoot = claudioNamespaceRoot(forBinaryPath: binaryPath) else {
        return binaryPath.split(separator: "/", omittingEmptySubsequences: true)
            .contains(".claudio")
    }
    return !isClaudioBinaryPath(binaryPath, claudioRoot: claudioRoot)
}

/// Reverses ``shellQuotedPath(_:)``: decodes a single `/bin/sh` word into the literal string
/// the shell would pass as `argv[0]`, or `nil` when the word is not a shape claudio's writer
/// can emit (an unterminated quote, or a backslash escaping anything but `'`).
///
/// Unquoted whitespace is *kept*, not rejected: a legacy entry written before
/// ``shellQuotedPath(_:)`` existed embeds a space-carrying path bare
/// (`/Users/John Smith/.claudio/bin/claudio play stop`). That command never worked — the shell
/// split it — but it is unambiguously ours, and `uninstall` should still sweep it. Nothing is
/// widened by allowing it: the decoded word must still be literally prefixed by claudio's own
/// root and end in `/claudio`, so `rm -rf / ; <root>/bin/claudio play stop` decodes to a word
/// starting with `rm` and is rejected.
///
/// **Whitespace is not the only legacy character this must survive, and a `nil` here is not a
/// rejection.** `'` and `\` are the two members of ``shellUnsafeCharacters`` that this decoder
/// cannot round-trip out of a *bare* legacy word: an odd number of `'` leaves the scan inside a
/// quote (`nil`), and an even number silently *deletes* them (`/Users/o'b'rien` → `/Users/obrien`,
/// a path that is no longer prefixed by the real root). Both shapes were removable before the
/// writer started quoting — `main` compared hook commands for exact string equality, and this
/// file's first draft tokenized on whitespace alone, and `'`/`\` are neither. So
/// ``matchedClaudioEvent(inHookCommand:claudioRoot:)`` tries the raw word alongside whatever
/// this returns, rather than treating `nil` (or a lossy decode) as "not ours".
///
/// Scans ``String/unicodeScalars`` because ``shellQuotedPath(_:)`` *emits* scalars, and the two
/// are only a round-trip pair if they agree on what a quote is. On `Character`s they do not: in
/// the encoding of a path whose `'` is followed by a combining mark, the idiom's final quote fuses
/// with that mark into one cluster that compares unequal to `'`, so a `Character`-level scan would
/// leave the word's quote nesting unbalanced and hand back a string with a stray `'` in it. Every
/// all-ASCII word — i.e. every word this decoder has ever actually seen — decodes identically
/// under both views.
private func shellWordContents(_ rawWord: String) -> String? {
    var contents = String.UnicodeScalarView()
    var inSingleQuotes = false
    let scalars = Array(rawWord.unicodeScalars)
    var index = 0

    while index < scalars.count {
        let scalar = scalars[index]
        if scalar == singleQuoteScalar {
            inSingleQuotes.toggle()
            index += 1
            continue
        }
        if scalar == backslashScalar && !inSingleQuotes {
            // The only backslash `shellQuotedPath` ever emits is the `'\''` idiom's.
            let next = index + 1
            guard next < scalars.count, scalars[next] == singleQuoteScalar else { return nil }
            contents.append(singleQuoteScalar)
            index = next + 1
            continue
        }
        contents.append(scalar)
        index += 1
    }

    return inSingleQuotes ? nil : String(contents)
}

/// Whether `path` is claudio's own binary inside `claudioRoot`: literally prefixed by
/// `claudioRoot/`, free of `..` traversal, with a basename of exactly `claudio` — independent
/// of which subdirectory under the root a given release places the binary in (today:
/// `bin/`, see ``ClaudioPaths/binDirectory``).
///
/// **Every comparison below is on Unicode scalars, never `Character`s or `String`s**, and that
/// is what makes the word "literally" above true rather than merely intended. Swift's
/// `String`/`Character` equality is Unicode *canonical equivalence*, so `hasPrefix` answers
/// `true` for a path that is not bytewise under the root at all: spell the root NFD
/// (`/Users/e` + U+0301 + `/.claudio`) and the command NFC (`/Users/é/.claudio/bin/claudio`)
/// and `path.hasPrefix(claudioRoot + "/")` is `true` while `path.utf8.starts(with:)` is `false`.
/// On a normalization-*insensitive* volume (APFS, HFS+) those two spellings name the same
/// directory and sweeping the entry is correct; on a normalization-*sensitive* home — an NFS/SMB
/// network home, i.e. exactly the AD-account case ``shellQuotedPath(_:)`` exists for — they are
/// two different directories, and `uninstall` would delete a `settings.json` hook belonging to a
/// root that is not this one. A `String`'s scalar sequence is in bijection with its UTF-8 bytes,
/// so comparing on ``String/unicodeScalars`` is byte comparison, spelled in the view the
/// below-root metacharacter scan already needed.
///
/// The scalar view closes a second, subtler gap the `Character` view carried: a combining mark
/// immediately after the root's trailing `/` fuses with it into ONE grapheme cluster, so the old
/// `path.dropFirst(claudioRoot.count + 1)` silently ate that mark along with the slash — slicing
/// a different view than the one the prefix was checked on. Nothing exploitable rode on it (a
/// combining mark is never a shell metacharacter, and grapheme-wise `hasPrefix` rejected the
/// fused cluster anyway), but slicing the view you compared is the only version of this that
/// stays correct by construction instead of by argument.
///
/// **Fail-closed on a normalization mismatch is deliberate, and costs nothing real.** `install`
/// compares hook commands for *exact string* equality, so a release whose derived binary path
/// changed normalization would already be appending a duplicate entry rather than recognizing
/// its own — the divergence surfaces there, loudly, not here. A refused sweep leaves a harmless
/// leftover; a canonical-equivalence sweep deletes someone else's hook. Same direction as the
/// `..` rejection above, for the same reason.
private func isClaudioBinaryPath(_ path: String, claudioRoot: String) -> Bool {
    guard claudioRoot.hasPrefix("/"), !claudioRoot.hasSuffix("/"),
        !claudioRoot.split(separator: "/").contains("..")
    else { return false }
    // The trailing slash matters: without it, a sibling `~/.claudio-backup/…/claudio` would
    // pass as "inside the root".
    let rootPrefix = Array((claudioRoot + "/").unicodeScalars)
    let pathScalars = Array(path.unicodeScalars)
    guard pathScalars.starts(with: rootPrefix) else { return false }

    let relative = pathScalars.dropFirst(rootPrefix.count)
    // Below its own root, claudio's subtree is only ever plain path segments (`bin/claudio`, a
    // future `libexec/claudio`, or the bare `claudio`) — it has NEVER written a quote, backslash,
    // whitespace, newline, or shell metacharacter there. So any such character below the root
    // means this string is not one claudio wrote, and it is rejected *before* the `..`/basename
    // checks are trusted. This guard is load-bearing precisely because a candidate reaching here
    // can be the raw source text (not just the shell-decoded word): in the raw text a `'`, `"`,
    // `\`, `$`, or backtick can hide a `..` traversal or a command substitution that makes
    // `/bin/sh` exec a binary *outside* the root (`…/.claudio/'..'/bin/claudio` execs
    // `…/bin/claudio`; `…/.claudio/$(echo ..)/claudio` likewise), and an embedded newline splits
    // the command so `/bin/sh` runs an entirely separate, attacker-chosen `argv[0]`. The decoder
    // strips neither `$`/backtick nor a newline, so the decoded candidate is no safer here than
    // the raw one — which is why this lives in the shared predicate rather than on one branch.
    // The root segment itself is exempt, and now genuinely is: it had to match `claudioRoot`
    // scalar-for-scalar — i.e. UTF-8 byte-for-byte — to clear the prefix guard above, and
    // canonical equivalence (the one way two *different* scalar sequences compare equal in Swift,
    // and the reason that guard is not `hasPrefix`) never rewrites an ASCII scalar, so it cannot
    // smuggle a metacharacter into the root segment either. An attacker has no freedom there. A
    // `$` or space in the *home* directory of a legacy bare entry is still fine — it is above the
    // root, not below it.
    guard !relative.contains(where: { shellUnsafeScalars.contains($0) }) else { return false }
    let components = relative.split(
        separator: pathSeparatorScalar, omittingEmptySubsequences: true)
    guard !components.contains(where: { $0.elementsEqual(parentDirectoryScalars) }),
        let basename = components.last, basename.elementsEqual(claudioBasenameScalars)
    else { return false }
    return true
}
