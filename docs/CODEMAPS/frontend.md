# Frontend Architecture

<!-- Updated: 2026-09-04 -->

## Page / window tree

```text
ClaudioGUIApp (@main)
└─ ClaudioGUIAppDelegate
   └─ MenuBarController (@MainActor)
      ├─ NSPopover → PanelView
      │  ├─ PanelRows / EventRowView / MasterVolumeRow
      │  ├─ PanelPackSectionView / PackGalleryView
      │  └─ PanelQuitFooter / onboarding and state-driven notices
      └─ retained SettingsWindowController
         ├─ ClaudioSettingsPresentation.SettingsRootView(session:)
         │  ├─ fixed nine-destination sidebar + exhaustive destination mount
         │  ├─ General / Notifications / Display / Usage / Shortcuts / About
         │  ├─ Integrations / Events & Sounds
         │  └─ embedded SoundPacksWindow view
         ├─ SettingsPresentationSession
         │  └─ typed route transaction / focus debt / destination lifecycle / announcement intent
         └─ native NSWindow / activation handback / accessibility post-and-ack adapter
```

`ClaudioGUIComponents` supplies `ClaudioTheme`, branding, failure rows, audio preview, and text
size controls, including the two-caller `SharedMasterVolumeSlider`. `ClaudioLocalization` owns the
string catalog and explicit language store. Production, the executable harness, and the DEBUG
state gallery all mount the same importable `ClaudioSettingsPresentation.SettingsRootView`.

## State flow

```text
composition root
  → HostIntegrationManagerBridge (actor) → HostIntegrationPresentationState
  → nonoptional SettingsPresentationDependencies
    → SettingsPresentationSession.state (one coherent published projection)
      → SettingsRootView → exhaustive typed destination mount
      → SettingsPlatformAction → ClaudioGUI native adapter
      → semantic announcement intent → SettingsWindowController native post + exact ack
  → SoundPackLibrary (actor) → SoundPackLibrarySnapshot
    → SoundPacksWindowModel (package implementation, owner-private)
      → SoundPacksEditorOwner.presentation
        → Settings route/announcement projection + embedded editor view
  → app-lifetime stores/models → session transaction → SwiftUI destination views
```

- `HostIntegrationPresentationStore` publishes host rows; `IntegrationDestinationModel` owns
  destination actions, feedback, recovery, and retained-window lifecycle facts.
- `SoundPacksRefreshCoordinator` coordinates panel/window projections after config or pack writes.
- `SoundPacksEditorOwner` is the common Sound Packs editor interface: callers observe one coherent
  immutable `presentation`, issue synchronous commands through `send`, and await disk-backed work
  through `perform`. Its raw `SoundPacksWindowModel` and directory/refresh details stay inside the
  owner implementation.
- `PanelConfigController`, `MasterVolumeController`, `EventMuteController`, and onboarding models
  keep pure Foundation decisions outside SwiftUI.
- `SettingsPresentationSession` is the single Settings presentation owner for typed route
  resolution/revision, window phase, focus debt, destination-local transient state, lifecycle
  transitions, and semantic announcement intent. Invalid or stale routes preserve the requested
  destination and typed failure without applying destination-specific domain mutation.
- Native Login Items/Calendar effects remain closed typed actions implemented by `ClaudioGUI`.
  `SettingsWindowController` owns only the retained `NSWindow`, app activation/handback, phase
  forwarding, and native accessibility post/ack.
- `PanelFocusCoordinator` owns panel focus. Settings focus debt belongs to the Settings session;
  destination views only consume and acknowledge the exact published request.

## Source boundaries

- `ClaudioGUICore`: testable state, presentation, accessibility, pack import/restore, and layout
  decisions; no SwiftUI dependency.
- `ClaudioGUIComponents`: reusable SwiftUI visual primitives.
- `ClaudioSettingsPresentation`: resource-free SwiftUI presentation for all nine Settings
  destinations. It owns the Settings presentation transaction but no native window, system API,
  resource bundle, Sound Pack disk fact, or host schema.
- `ClaudioGUI`: executable composition plus native adapters and the retained AppKit window.
- `SoundPacksWindow`: reusable editor rendering and native accessibility bridge; all editor facts
  and mutations remain behind `SoundPacksEditorOwner`.
- Native menu-bar, VoiceOver, keyboard, audio, and focus behavior requires real macOS manual evidence
  in addition to executable harness checks.

## Key files

- `gui/Sources/ClaudioGUI/ClaudioGUIApp.swift`: composition root.
- `gui/Sources/ClaudioGUI/MenuBarController.swift`: status item, popover, retained windows.
- `gui/Sources/ClaudioGUICore/HostIntegrationManagerBridge.swift`: async core-to-UI seam.
- `gui/Sources/ClaudioGUICore/SoundPackLibrary.swift`: app-lifetime pack scan/cache actor.
- `gui/Sources/ClaudioGUICore/SoundPacksEditorOwner.swift`: coherent editor presentation and typed
  command/operation boundary.
- `gui/Sources/ClaudioGUICore/SoundPacksWindowModel.swift`: package-local owner implementation for
  sound-pack projection and writes.
- `gui/Sources/ClaudioSettingsPresentation/SettingsPresentationSession.swift`: the coherent typed
  Settings transaction, lifecycle, focus, and semantic announcement owner.
- `gui/Sources/ClaudioSettingsPresentation/SettingsRootView.swift`: importable exhaustive
  nine-destination production root.
- `gui/Sources/ClaudioGUI/SettingsPlatformActionsAdapter.swift`: exhaustive native adapter for the
  two Settings-only system effects.
- `gui/Sources/ClaudioGUI/SettingsWindowController.swift`: retained native window,
  activation/handback, phase forwarding, and semantic announcement post/ack.
