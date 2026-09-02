# Settings source-scan replacement ledger

Baseline: issue #128 / Phase 0. This ledger records only assertions considered for deletion when
`ClaudioSettingsPresentation` becomes importable. It does not authorize deleting a scan in this
change. One row represents one current `expect` block (a compound `contains` expression remains one
assertion). Assertions outside the listed Settings seams are not proposed for deletion.

Status:

- `ready`: a compiled semantic owner exists now; deletion still waits for the importable target and
  the Phase 6 full-harness gate.
- `target`: the replacement must compile against the future production presentation target.
- `retain`: this is a composition, package, resource, or delivery fact that a view test cannot prove.

Deletion gate for every `ready` or `target` row: the replacement imports the owning library, drives
its public/package interface, fails for the corresponding behavior mutation, and passes the full GUI
harness. Native layout and accessibility still require the manual evidence named by the Settings
acceptance plan. No replacement may expose `SoundPacksWindowModel` as the Settings contract.

## Hard-coded path inventory

| Scan | Current paths read |
| --- | --- |
| `SettingsNavigationSuite` shell scan | `SettingsWindowController.swift`, `SettingsWindowView.swift`, `SoundPacksEditorOwner.swift`, `StateGalleryView.swift`, `MenuBarController.swift`, `ClaudioGUIApp.swift` |
| `IntegrationDestinationWiringSuite` | four Integration files in `ClaudioGUICore`, `IntegrationsSettingsDestinationView.swift`, Settings view/controller, menu composition, `StateGalleryView.swift`, `SettingsPreferences.swift`, settings gate/harness/acceptance doc |
| `ViewWiringSuite` Settings slices | `PanelView.swift`, `EventSettingsWindowView.swift`, `EventSettingsAICueView.swift`, `SettingsWindowView.swift`, `SettingsWindowController.swift`, `EventPreviewSequence.swift`, `MenuBarController.swift`; Sounds slices additionally read `SoundPacksWindowView.swift`, shared picker/player, editor owner, and `gui/Package.swift` |
| `HitTargetSuite` production scan | Events view, `PackGalleryView.swift`, `PanelRows.swift`, AI Cue view |
| adjacent scans | `GlobalShortcutsSuite` reads Settings controller and Events view; `SoundPacksWindowAccessibilitySuite` walks the SoundPacksWindow target and reads Settings controller/editor owner/Core a11y |

## `SettingsNavigationSuite.swift`

The pure assertions before the shell source guard remain compiled tests. The following IDs cover
each assertion inside the source-backed half of `Settings shell：尺寸、单滚动、焦点序、DEBUG
gallery 与生产通用页`.

| ID | Current assertion | Status | Compiled replacement owner |
| --- | --- | --- | --- |
| SN-00 | six production files are readable | target | target import plus `SettingsRootMountSuite` construction |
| SN-01 | controller/view are not DEBUG-only | target | release build imports and mounts `SettingsRootView` |
| SN-02 | `window ?? makeWindow()` reuses one window | retain | narrow executable `SettingsWindowAdapterCompositionSuite` |
| SN-03 | `isReleasedWhenClosed == false` | retain | executable AppKit adapter lifecycle test |
| SN-04 | presentation latch suppresses stale key callback | target | `SettingsAnnouncementLifecycleSuite` with a fake native announcement adapter |
| SN-05 | show ordering is latch → session → key → announce → unlatch | target | same lifecycle suite, ordered call recorder |
| SN-06 | first presentation alone owns responder setup | target | `SettingsNativeFocusSuite` under `NSHostingView` |
| SN-07 | retained re-front announces before unlatch | target | `SettingsAnnouncementLifecycleSuite` |
| SN-08 | controller consumes shared geometry constants | target | AppKit adapter window geometry test |
| SN-09 | shell has exactly one outer `ScrollView` | target | `SettingsRootMountSuite` native hierarchy probe plus gallery/manual layout evidence |
| SN-10 | Sounds embeds editor and refreshes route from fresh shared snapshot | target | `SettingsSoundsDestinationSuite` using editor context; never raw model |
| SN-11 | Integrations mount/focus/Events routing/phase wiring | target | `SettingsIntegrationsDestinationSuite`; phase reducer already covered by `IntegrationDestinationModelSuite` |
| SN-12 | Events scopes and Integration surfaces use their distinct availability sets | ready | `SettingsPresentationCharacterizationSuite` invalid/stale matrix plus future session availability fixture |
| SN-13 | Sounds selection/library/status publishers share active-key post/consume gate | ready | `SettingsPresentationCharacterizationSuite` announcement matrix and `SoundPacksWindowAccessibilitySuite` tracker tests |
| SN-14 | sidebar sections, move commands, title/first-action focus are wired | target | `SettingsNativeFocusSuite` |
| SN-15 | General language picker is the first action | target | `SettingsRootInteractionSuite` |
| SN-16 | General picker/recovery state have stable AX labels and hints | target | `SettingsNativeAccessibilitySuite` |
| SN-17 | each forbidden future preference is absent (three loop assertions) | target | exhaustive typed General mount fixture; no string absence scan |
| SN-18 | sidebar displays `claudi0` | target | production-root text/AX snapshot |
| SN-19 | route failure renders in the owning slot | ready | `SettingsPresentationCharacterizationSuite` exact-route matrix plus future mount assertion |
| SN-20 | no `EmptyView`/coming-soon placeholder | target | nine-destination exhaustive `SettingsRootMountSuite` |
| SN-21 | route gallery enumerates success and failure fixtures | target | gallery constructs production root for every `PreviewFixtures` route case |
| SN-22 | base gallery covers languages and four text sizes | target | deterministic gallery construction test; manual visual evidence remains separate |
| SN-23 | Events/AI gallery uses production views and fixed roster | target | gallery constructs the imported production root with deterministic dependencies |
| SN-24 | section card/sidebar/Escape/retry/announcement actions are wired | target | `SettingsRootInteractionSuite` under `NSHostingView` |
| SN-25 | menu composition has one Settings controller/editor owner/typed pending request | retain | narrow executable composition census |
| SN-26 | synthetic app Settings command is removed | retain | executable `@main`/command composition scan |
| SN-27 | panel and Carbon actions enter retained Settings | retain | executable composition scan; route semantics stay in `GlobalShortcutsSuite` |
| SN-28 | typed preferences drive title language update | target | AppKit adapter dependency and title-update test |

## `IntegrationDestinationWiringSuite.swift`

| ID | Current assertion | Status | Compiled replacement owner |
| --- | --- | --- | --- |
| IDW-01 | each of four Core presentation files exists | target | target dependency graph compiles their types; delete file-name census |
| IDW-02 | legacy window view/model files do not exist | target | imported destination is the only constructible production presentation |
| IDW-03 | legacy focus file does not exist | target | exhaustive typed focus compilation |
| IDW-04 | Core model does not import AppKit | retain | SwiftPM target-dependency/import audit |
| IDW-05 | model injects refresh/action/clipboard seams | ready | `IntegrationDestinationModelSuite` fake handlers |
| IDW-06 | Settings mounts Integrations and routes Events | target | `SettingsIntegrationsDestinationSuite` action probe |
| IDW-07 | retained controller forwards visibility/key to one model | ready | `IntegrationDestinationModelSuite` phase tests plus future session transition test |
| IDW-08 | no second Integrations controller | retain | executable composition census |
| IDW-09 | handlers/store are injected at composition root | retain | executable composition scan |
| IDW-10 | scanner parsed source | target | disappears with source scanner |
| IDW-11 | one vertical/no horizontal scroll | target | imported native hierarchy/layout fixture |
| IDW-12 | max width and section-card layout | target | gallery/native geometry probe plus manual visual acceptance |
| IDW-13 | no Inspector/matrix/side-by-side/toolbar | target | typed production mount snapshot |
| IDW-14 | bottom-trailing semantic feedback | target | `SettingsIntegrationsDestinationSuite` feedback fixture |
| IDW-15 | generic and stale routes request typed title | target | `SettingsNativeFocusSuite` |
| IDW-16 | page-header source boundary exists | target | disappears; behavior is covered by native header test |
| IDW-17 | title is header + focusable + focused target | target | `SettingsNativeAccessibilitySuite` |
| IDW-18 | toggle/clear actions enter Core model | ready | `IntegrationDestinationModelSuite` |
| IDW-19 | copy/Events actions use distinct typed callbacks | target | `SettingsIntegrationsDestinationSuite` action recorder |
| IDW-20 | disconnect/clear use confirmation dialog | target | native action/confirmation test |
| IDW-21 | submit function source boundary exists | target | disappears with source scanner |
| IDW-22 | captured confirmation is consumed before async action | ready | `IntegrationDestinationModelSuite` confirmation identity/order characterization |
| IDW-23 | no automatic audio playback | target | typed dependency/action surface has no audio capability; interaction test verifies zero calls |
| IDW-24 | presentation consumes product surfaces/row kinds/mechanisms | ready | `IntegrationDestinationPresentationSuite` |
| IDW-25 | in-flight guard retains old snapshot then refreshes outcome | ready | `IntegrationDestinationModelSuite` |
| IDW-26 | feedback requires visible+key and five-second lifetime | ready | Integration model/presentation compiled suites |
| IDW-27 | gallery uses production view and in-flight fixture | target | production-root gallery construction test |
| IDW-28 | destination performs no direct file/defaults read | retain | target dependency/import audit; deterministic no-I/O fixture test supplements it |
| IDW-29 | preferences own stable last-Surface/recovery fields | ready | Settings preferences compiled suite |
| IDW-30 | host paths are injected only at composition root | retain | executable composition scan |
| IDW-31 | gate contains each current suite entrypoint (three loop assertions) | retain | delivery gate scan |
| IDW-32 | harness registers each suite (three loop assertions) | retain | executable-harness registration scan |
| IDW-33 | acceptance doc names each suite (three loop assertions) | retain | documentation delivery scan |
| IDW-34 | deleted legacy suite name is absent | retain | delivery gate/documentation scan |

## `ViewWiringSuite.swift` Settings slices

Only these assertion blocks are proposed for later extraction/deletion; unrelated panel, helper,
sound-file integrity, release, and Sound Pack domain scans remain outside this ledger.

| ID | Current assertion | Status | Compiled replacement owner |
| --- | --- | --- | --- |
| VW-01 | Panel open-Settings carries current typed scope | target | Panel action spy receiving `SettingsRoute.events` |
| VW-02 | Events consumes shared scope/event projections | ready | existing panel/event presentation compiled suites |
| VW-03 | per-event configure action carries same scope to Sounds | target | `SettingsEventsDestinationSuite` action recorder |
| VW-04 | stale scope keeps route, disables writes, never falls back | ready | `SettingsPresentationCharacterizationSuite` zero-write case and `EventSettingsDestinationCoordinatorSuite` |
| VW-05 | Events uses its own adaptive layout | target | imported-root native geometry fixture |
| VW-06 | missing-pack recovery action has focus and AX identity | target | `SettingsNativeAccessibilitySuite` |
| VW-07 | write failures render in place | target | production-root failure fixture |
| VW-08 | retained Settings pre-applies route and leaves Events | ready | characterization route transaction and `EventSettingsDestinationCoordinatorSuite` leave test; adapter wiring stays retained |
| VW-09 | exact scope/Event focus and disabled hints | target | `SettingsNativeFocusSuite` |
| VW-10 | one event owner/selection and no legacy controller | retain | executable composition census |
| VW-11 | Settings mounts Events and internally routes Sounds | target | `SettingsRootMountSuite` plus action recorder |
| VW-12 | Events controls/preview/pack/reset lifecycle wiring | ready | coordinator and low-level compiled suites; imported view interactions cover remaining controls |
| VW-13 | AI service/action consumes fail-closed adoption eligibility | target | imported Events interaction fixture plus existing AI adoption suite |
| VW-14 | BYOK sheet uses secure typed provider surface | target | imported AI view interaction/AX test; Keychain remains adapter-tested |
| VW-15 | AI description stage excludes name | target | deterministic imported composer state test |
| VW-16 | candidate stage contains name/three candidates/regenerate | target | deterministic imported composer state test |
| VW-17 | duration uses localized catalog | target | rendered localization fixture |
| VW-18 | adoption/leave/close/scope change clears preview and candidates | target | coordinator already compiles preview/AI end requests; keep this scan until a future session integration test also drives `endSession` and candidate cleanup |
| VW-19 | adoption crosses presentation boundary as one domain request | ready | `AICueAdoptionSuite`; future target compiler enforces dependency shape |
| VW-20 | fixed provider/Keychain/engine/adoption graph is composed | retain | executable composition scan |
| VW-21 | Sounds action bar/status source reads raw model | target | replace with `SettingsSoundsDestinationSuite` over editor context; do not preserve raw-model assertion |

## `HitTargetSuite.swift` and adjacent scans

The first three `HitTargetSuite` cases are already compiled `NSHostingView` probes and remain.

| ID | Current assertion | Status | Compiled replacement owner |
| --- | --- | --- | --- |
| HT-01 | Events rows name the full-row style | target | imported Events row hit probe |
| HT-02 | Pack gallery names the full-row style | target | Sound Packs presentation hit probe |
| HT-03 | onboarding row names the full-row style | retain | outside Settings target until that caller has an importable seam |
| HT-04 | AI close names compact style | target | imported composer 28pt boundary hit probe |
| GS-01 | Settings controller exposes shortcut route preparation | target | `SettingsPresentationCharacterizationSuite` explicit request plus future adapter invocation test |
| GS-02 | Events view renders unavailable shortcut reason | target | imported route-failure fixture; zero-write behavior is already compiled |
| SA-01 | SoundPacksWindow target avoids panel-only a11y types | retain | SwiftPM dependency/import audit |
| SA-02 | exactly one native `NSAccessibility.post` site | retain | native adapter composition census |
| SA-03 | Sounds focus/list/Finder bindings | target | imported Sounds native focus tests |
| SA-04 | text-size/detail reflow and control/AX bindings | target | native layout/AX fixture plus manual evidence |
| SA-05 | responder setup precedes announcement | target | `SettingsAnnouncementLifecycleSuite` ordered adapter recorder |
| SA-06 | bridge rechecks key state and reports post success | ready | tracker tests plus future fake bridge result test |
| SA-07 | all Sound actions share revision announcement facts | target | editor-context announcement fixture, never raw model |
| SA-08 | Sounds uses unified Settings geometry | target | AppKit adapter geometry test |
| SA-09 | re-key retries and successful post consumes revision | ready | `SettingsPresentationCharacterizationSuite` announcement matrix |

## Scans that deliberately remain

- The unique `@main`, single retained `SettingsWindowController`, single `SoundPacksEditorOwner`, and
  absence of parallel Settings/Integrations/Event controllers remain executable composition facts.
- `gui/Package.swift` dependency/resource declarations remain package scans; a successful local build
  does not prove the released bundle copied every resource.
- `ReleaseLayoutSuite`, bundle assembly/signing/notarization checks, localization catalog validation,
  gate-script registration, and acceptance-document checks remain delivery evidence.
- Source scans must not be kept merely to restate behavior already driven through an importable
  compiled seam. Phase 6 removes only rows marked `ready`/`target` after their deletion gate passes.
