# Data and Persistence Map

<!-- Generated: 2026-08-22 | Files scanned: 286 | Token estimate: ~620 -->

Claudio has no database, ORM, migrations, or server-side storage. Persistence is local files under
`~/.claudio/` plus the two host-owned configuration files.

## Logical records

```text
config.json ── selected_pack ──> packs/<id>/manifest.json ──> event audio files
config.json ── events/master_volume/starred_packs ──> panel + playback projection
host config ── installation ID ──> active marker ──> receipts/<host>/<event>.json
```

## Filesystem sources of truth

| Data | Path | Owner / contract |
|---|---|---|
| User settings | `~/.claudio/config.json` | GUI/CLI surgical JSON mutation; unknown keys preserved |
| User sound packs | `~/.claudio/packs/<id>/` | GUI import/manifest writes and setup restore; `packs.lock` serializes writers |
| Runtime binaries | `~/.claudio/bin/claudi0`, legacy `claudio` | shared bootstrap; release bundle publishes both names |
| Playback state | `play.lock`, `play.state` | legacy global debounce; host paths use per-host state |
| Host evidence | `integrations/receipts/`, `integrations/installations/` | 0600 receipts/markers, installation-bound activation |
| Bootstrap recovery | `bootstrap-journal.json`, `bootstrap-reports/` | journal before user-content changes; bounded report queue |
| Diagnostics | `claudio.log`, `claudio.log.lock` | redacted operational errors only |
| Claude Code | `~/.claude/settings.json` | Claude adapter-owned Claudio entries only |
| Codex | `~/.codex/hooks.json` | Codex adapter-owned command hooks only; `notify` is preserved |

## Bundled data

`packs/minimal-chime/manifest.json` and its MP3 files are copied into the app bundle during release
assembly by `scripts/copy-bundled-packs.sh`; `packs/LICENSES.md` is a required ledger.

## Write path

Reads are bounded and fail closed on malformed data. Writes use per-file locks, symlink checks,
compare-and-swap/backup rules, and same-directory atomic replacement. There is no migration history;
schema evolution is handled by preserved JSON fields and the explicit sound-pack manifest contract.
