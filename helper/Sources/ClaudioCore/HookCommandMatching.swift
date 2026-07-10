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
// `matchedClaudioEvent(inHookCommand:)` recognizes any command that has claudio's shape,
// which covers the one form we have written AND any future relocation, without needing to
// know its exact path in advance.
//
// Lives in its own file rather than inside `SettingsInstaller.swift` for the same reason
// `VersionCompatibility.swift` does: it is a self-contained predicate with its own
// adversarial argument, and folding it in pushed that file past the project's file-size
// convention.

/// Whether `command` is a hook command claudio itself could plausibly have written, for any
/// of the four core events — returns the matched ``Event``, or `nil` if it doesn't look like
/// one of ours. This is the single source of truth `removeHookEntries` (uninstall's removal
/// sweep) keys off; `install`/``detectHookInstallStatus(settingsFile:claudioBinaryPath:)``
/// deliberately do NOT use this — they compare against the one exact, current
/// ``claudioHookCommand(for:claudioBinaryPath:)`` string, because onboarding/self-heal need
/// to know "does *today's* exact hook exist", not "does something claudio-shaped exist".
///
/// **Why this can never misfire on a third-party hook** (adversarial argument, not just an
/// assertion — every clause below is pinned by a case in `HookCommandMatchingSuite.swift`):
/// 1. **Exact argv shape**: `command`, tokenized by ``tokenizeSimpleShellCommand(_:)``, must
///    be EXACTLY 3 tokens — `<path> play <event>`. Two tokens, four tokens, or anything
///    whose shell metacharacters would change the token count (pipes, `&&`, redirection) is
///    rejected outright. A third-party tool's hook would need to coincidentally have this
///    *exact* 3-token `X play Y` shape just to reach the next two checks.
/// 2. **`<event>` must be one of the 4 real ``Event/cliName`` values** (`Event(cliName:)`) —
///    `mytool play deploy` fails here even if `mytool` were somehow named `claudio`.
/// 3. **`basename(<path>)` must be exactly `"claudio"` AND `<path>` must be absolute,
///    traversal-free, and carry a path component exactly equal to `".claudio"`**
///    (``isClaudioNamespacedBinaryPath(_:)``) — claudio's own dotfolder namespace
///    (``ClaudioPaths/root``, ENGINEERING.md 决议 4). `/usr/local/bin/claudio play stop` (a
///    look-alike third-party tool) fails: no `.claudio` path component. `~/bin/claudio play
///    stop` (a user's own unrelated script, coincidentally named `claudio`) fails the same
///    way.
///
/// Combined: a false positive requires a third-party tool that is ITSELF named exactly
/// `claudio`, ITSELF installed under a directory literally named `.claudio`, AND ITSELF
/// implements a `play <one-of-our-4-event-names>` subcommand taking no other arguments — not
/// a realistic accident, and not narrower than necessary either (it still accepts any
/// subdirectory under `.claudio/`, which is exactly what survives a relocation from `bin/`
/// to some other future layout).
///
/// **What this deliberately does NOT recognize** (documented limitations, not silent gaps):
/// - **No shell variable expansion** (`$HOME`, `~`): ``claudioHookCommand(for:claudioBinaryPath:)``
///   always writes claudio's fully-resolved absolute path — never a `$HOME`-relative string
///   — so there is no real historical form using a variable to recognize. A command
///   literally containing the four characters `$HOME` is not an absolute path (does not
///   start with `/`) and simply falls through as "not ours" — never misidentified, just not
///   specially handled, because this string-level check never invokes a shell to expand it.
/// - **No quote-stripping**: `~/.claudio/`'s entire reason for existing (决议 4) is having no
///   space in its path, so claudio's own writer has never needed to quote it — there is no
///   real historical quoted form (`"$HOME/.claudio/bin/claudio" play stop`) to recognize.
///   Handling it would only widen the match surface for a form we never actually produced,
///   so a quoted command is left unmatched (pinned by a test) until a real future version
///   actually starts quoting.
/// - **No trailing shell operators** (`>`, `|`, `&&`): these change the token count away from
///   exactly 3, so they structurally fail to match — the conservative direction on purpose:
///   a real residue we fail to sweep is merely unswept (harmless leftover), whereas a false
///   match risks deleting someone else's hook entirely.
public func matchedClaudioEvent(inHookCommand command: String) -> Event? {
    let tokens = tokenizeSimpleShellCommand(command)
    guard tokens.count == 3, tokens[1] == "play" else { return nil }
    guard let event = Event(cliName: tokens[2]) else { return nil }
    guard isClaudioNamespacedBinaryPath(tokens[0]) else { return nil }
    return event
}

/// Splits `command` on runs of ASCII space/tab. Deliberately NOT a full shell grammar — no
/// quoting, no variable expansion, no operator awareness; see
/// ``matchedClaudioEvent(inHookCommand:)``'s doc comment for exactly why each of those is
/// out of scope. Collapsing repeated/extra whitespace is a purely cosmetic tolerance
/// `claudioHookCommand` itself never produces, but accepting it costs nothing and risks
/// nothing (it cannot widen a false match — the argv-count and per-token checks downstream
/// are unaffected by how much whitespace separated the tokens).
private func tokenizeSimpleShellCommand(_ command: String) -> [String] {
    command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
}

/// Whether `path` is claudio's own binary-namespace shape (``ClaudioPaths/root``): absolute,
/// free of `..` traversal, with a basename of exactly `"claudio"` and some path component
/// exactly equal to `".claudio"` — independent of which subdirectory under `.claudio/` a
/// given release places the binary in (today: `.claudio/bin/`, see
/// ``ClaudioPaths/binDirectory``).
///
/// **The `..` rejection is load-bearing, not hygiene.** A component scan alone asks only
/// "does the string contain a `.claudio` component", which is NOT the same question as "does
/// this path resolve inside `.claudio/`" the moment a `..` can cancel that component out:
/// `/Users/x/.claudio/../claudio` lexically resolves to `/Users/x/claudio`, comfortably
/// outside the namespace, yet still literally contains a `.claudio` component. Accepting it
/// would hand `uninstall` — the single destructive path in this file, and the one that
/// (unlike `install`) takes **no backup** before rewriting `settings.json` — a hook entry
/// that is provably not ours. Rejecting `..` outright, rather than lexically normalizing and
/// re-checking, is the conservative direction and matches the existing precedent in
/// ``safePackFileURL(_:in:)``: claudio has never written a `..` into a hook command, so a
/// residue containing one is definitionally not one of ours, and refusing to sweep it merely
/// leaves a harmless leftover instead of risking someone else's hook.
///
/// A relative path is rejected outright for the same reason — every path claudio itself has
/// ever written here is absolute (``ClaudioPaths`` is anchored at
/// `FileManager.default.homeDirectoryForCurrentUser`), so a relative string is definitionally
/// not one we wrote.
private func isClaudioNamespacedBinaryPath(_ path: String) -> Bool {
    guard path.hasPrefix("/") else { return false }
    let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !components.contains("..") else { return false }
    guard components.last == "claudio" else { return false }
    return components.contains(".claudio")
}
