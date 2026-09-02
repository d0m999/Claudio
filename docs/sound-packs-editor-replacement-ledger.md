# Sound Pack editor Phase 0 replacement ledger

Issue: #127. Baseline: `b64336f` (the worktree starts at the empty architecture marker
`3e80d1d`). This ledger is a test migration contract for #129; it does not describe a production
interface as already implemented.

## Scope and seam

Phase 0 characterizes the currently available seams:

- `SoundPacksEditorOwner` for typed route application and shared announcement consumption.
- `SoundPacksWindowModel` for current editor read/write behavior.
- `SoundPacksRefreshCoordinator` for current cross-presentation refresh effects.
- `SoundPackLibrary` for the single app-lifetime disk-fact state stream.
- A temporary source seam for SwiftUI-owned confirmation disposal, because the baseline has no
  compiled confirmation capability yet.

The #129 replacement seam is the deep `SoundPacksEditorOwner` interface:
`SoundPacksEditorPresentation`, synchronous `send(_:)`, truly asynchronous `perform(_:)`, and
opaque action/confirmation/import/adoption capabilities. Tests must migrate to that interface
before legacy public model or source assertions are deleted.

## Red → green evidence

The first tracer bullet deliberately inverted the fresh-state gate: after mutating the model from
`.loading` to `.failed(previous: nil)`, it expected the missing route to resolve as overview. The
harness failed at `SoundPacksEditorCharacterizationSuite.swift:30` with:

```text
✗ MUTATION PROOF：无 fresh ready 时不应决议缺包
✗ 1 of 7719 checks FAILED
```

The committed test restores the real baseline expectation—without a fresh ready snapshot the
route remains pending—and adds the positive fresh-ready mutation. This proves the assertion reacts
to freshness rather than merely restating a fixture.

## Behavior ownership matrix

| Required behavior | Phase 0 executable evidence | #129 replacement owner |
|---|---|---|
| unloaded/loading/ready/failed(previous) projection | `SoundPacksEditorCharacterizationSuite`: real library snapshot plus injected state transitions | `SoundPacksEditorInterfaceSuite`: presentation library phase/freshness |
| pending deep link before fresh facts | new characterization suite; existing `SoundPacksEditorOwnerSuite` pending route case | `activate(.sounds(...))` presentation route state |
| fresh missing pack | new characterization suite locks b64336f overview fallback | #129 intentionally changes this to visible stale/unavailable failure, never successful overview |
| refresh failure retains previous facts | new characterization suite; `SoundPackLibrarySuite` five-state cases | coherent presentation retains cards and failure together |
| first-load failure has no invented facts | new characterization suite | coherent presentation hard-failure slice |
| malformed/stale Surface fail closed | `SoundPacksRefreshSuite` invalid scope cases; `AICueAdoptionSuite` malformed/future override cases | stale action rejection through `send`/`perform` |
| inspect does not write config | `SoundPacksRefreshSuite` Global/Surface scope case and `use` case | selection action changes presentation only |
| Global/Surface pack selection | `SoundPacksRefreshSuite` scope case | scoped use/select capabilities |
| global `master_volume` | `PanelConfigControllerSuite` surface profile case; `SoundPacksRefreshSuite` master-volume propagation | Events slice observes global value; no per-Surface mutation action |
| sparse override and unknown/future JSON preservation | `SoundPacksRefreshSuite` scope case; `PanelConfigControllerSuite` surface profile case | owner temp-directory mutation tests |
| star CAS preserves concurrent sibling update | `SoundPacksWindowStarredPacksSuite` stale-window toggle case | owner star action/capability test; requirement must not be dropped |
| default star materialization and panel display cap | `SoundPacksWindowStarredPacksSuite` | retain low-level compatibility tests; add owner projection test |
| stale destructive target | new characterization suite plus restore/delete drift cases in `SoundPacksRefreshSuite` | stale confirmation result through `send` |
| confirm/cancel disposal | new temporary view-source characterization; repeat delete mutation proves no second success | opaque confirmation is single-use; cancel consumes it without mutation |
| A→B→A generation | `SoundPacksRefreshSuite` async import case | operation capability bound to selection generation |
| import target/background/partial/rejection | `SoundPacksRefreshSuite` import cases; `SoundPackLibrarySuite` import-bind case | `perform(.importAudio(...))` outcomes |
| AI target capture and isolation | `AICueAdoptionSuite` eligibility and closed-loop cases | adoption permit binds Surface + Event + pack |
| AI invalidated before import | `AICueAdoptionSuite` fresh-refresh/damaged/identity cases | first validation in `perform` |
| AI invalidated before bind and orphan honesty | `AICueAdoptionSuite` import-time drift/identity cases | final validation plus typed orphan outcome |
| noChange/failure does not refresh | `SoundPacksRefreshSuite` coordinator failure/config-only cases and stale delete mutations | mutation result `.noChange` |
| changedDespiteFailure refreshes once and retains failure | restore publish/salvage cases in `SoundPacksRefreshSuite` | mutation result `.changedDespiteFailure` |
| exact invalidation and one shared refresh | `SoundPackLibrarySuite` production write chains and follow-up/invalidation cases | owner scanner-count integration tests |
| fork compound announcement and suppression | `SoundPacksRefreshSuite` fork case; `SoundPacksEditorOwnerSuite` selection decision | presentation announcement plus generation-bound suppression |
| hidden/non-key does not consume announcement | new owner characterization; accessibility tracker suite | `acknowledgeAnnouncement(id:didPost:)` |
| actual post succeeds before acknowledgement | new owner characterization; accessibility bridge/tracker suite | semantic announcement queue + native adapter ack |
| one coherent publication | baseline has no such seam; raw `@Published` order must not be locked as desired behavior | #129 must add a single-value publication test and a reentrant observer test |

## Source assertion replacement map

Every row below is replace-before-delete. “Compiled replacement” means behavior is observed via the
new owner interface, not a second source string asserting the same fact.

| Current assertion group | Compiled replacement required before deletion | Disposition |
|---|---|---|
| `SoundPacksEditorOwnerSuite`: `owner.model.managedSurface`, selection, config, event rows | activate Sounds/Events contexts and inspect their presentation slices | Replace in #129 |
| `SoundPacksEditorOwnerSuite`: forwarding of panel switch to coordinator | send typed panel-switch completion and observe resulting presentation | Replace in #129 |
| `SoundPacksEditorOwnerSuite`: two-retained-presentation announcement tracker | one presentation announcement ID, false/true ack, generation suppression | Replace in #129 |
| `SoundPacksRefreshSuite`: direct `panelReloadRevision` assertions for window writes | owner mutation result plus scanner count/presentation result | Replace high-level cases in #129; retain coordinator reducer unit cases |
| `SoundPacksRefreshSuite`: direct model delete/assign/clear/restore/retry/batch/fork/use calls | opaque actions and confirmations through `send` | Replace after each action is representable |
| `SoundPacksRefreshSuite`: direct async import plus `expectedPackID` | import permit through `perform`, including selection-generation drift | Replace in #129 |
| `ViewWiringSuite`: Events reads `soundPacksModel.packCards` and invokes raw adoption callback | Events presentation slice and adoption permit | Replace when caller migrates after #129 |
| `ViewWiringSuite`: Sounds mapping actions invoke raw model methods | compiled owner action tests plus `SoundPacksEditorViewSuite` | Replace after view migration |
| `ViewWiringSuite`: `expectedPackID`, foreground completion, direct preview strings | operation capability result and native-effect adapter tests | Replace after view migration |
| `ViewWiringSuite`: confirmation dialogs call `*AfterConfirmation` methods | single-use confirm/cancel owner tests | Replace after view migration |
| New characterization source check for three pending confirmation states | single-use confirm, cancel, dismiss/stale capability tests | Delete temporary source check in #129 or immediate caller migration |
| `ViewWiringSuite`: direct `ForEach(model.windowStatuses)` and controller publishers | presentation status/announcement ID tests | Replace after caller migration |
| `SoundPacksWindowAccessibilitySuite`: controller/model/bridge source strings | owner announcement queue plus recording native adapter | Replace behavior strings; retain single native post census |
| `SettingsNavigationSuite`: `soundPacksEditorOwner.model.$packCards` availability | Settings observes `editor.presentation.library` | Replace in Settings compiled phase |
| `SettingsNavigationSuite`: controller announcement subscriptions | one presentation subscription and acknowledgement behavior | Replace in Settings compiled phase |
| `SoundPacksRefreshSuite`: target kind, one owner construction, no standalone controller | no compiled behavioral seam proves package/composition census | Retain as narrow source checks |
| `ViewWiringSuite`: one picker/player/AX implementation and stable identifiers | recording adapter covers behavior, but uniqueness/resource delivery is composition evidence | Retain only the narrow census/identifier portions |

## Tests that remain below the editor module

These do not migrate to the owner interface because they protect lower-level invariants rather than
caller behavior:

- All `SoundPackLibrarySuite` actor scheduling, replay, fingerprint, inventory LRU, stable read,
  invalidation mailbox and 100-pack behavior.
- Config and manifest transaction tests for lock/CAS, unknown JSON retention and surgical writes.
- Path safety, symlink/FIFO rejection, bounded manifest/audio reads and factory integrity tests.
- `UserSoundPackDeletionSuite`, `PackRestoreSuite`, `PackForkSuite`, `ManifestBindingSuite`, and
  `AudioImportSuite` low-level file transaction cases.
- `PanelConfigControllerSuite` domain ownership for Event toggles, sparse Surface overrides and
  global `master_volume`.
- Benchmark and release/resource wiring checks.

The star requirement is split deliberately: low-level CAS/default materialization tests remain,
while the stale action and resulting presentation also gain owner-interface coverage in #129.

## Phase 0 reconciliation for #129

Two current behaviors are evidence, not the desired final architecture:

1. b64336f resolves a fresh missing Sounds deep link to overview. #129 must change the new
   presentation to a visible stale/unavailable failure while keeping the typed target; the baseline
   assertion must be replaced, not copied forward.
2. b64336f stores confirmation in SwiftUI state. Clearing that state makes confirm/cancel
   effectively single-use, but it is not a module invariant. #129 must move identity and
   single-use consumption into opaque owner capabilities before the source assertion is removed.

The baseline also exposes many independent `@Published` properties. No test claims their transient
ordering is desirable. #129 owns the first coherent-publication interface test; it must observe one
settled value per logical transition and must not use `combineLatest` to legitimize intermediate
states.

## Phase 0 exit audit

- New suite is registered with `await runSoundPacksEditorCharacterizationSuites()` in the executable
  harness.
- No production source, access level, target dependency or file location changes in #127.
- Every planned raw-model/source deletion above has a named replacement owner.
- Retained lower-level tests are explicitly separated from caller-facing replacement tests.
- #129 must preserve the one `SoundPackLibrary`, existing lock/CAS writers, precise invalidation,
  star/CAS behavior and one write path during delegation.
