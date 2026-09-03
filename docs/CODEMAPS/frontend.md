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
         ├─ SettingsWindowView
         │  ├─ ClaudioSettingsPresentation.LoginItemSettingsSection
         │  ├─ IntegrationsSettingsDestinationView
         │  ├─ EventSettingsWindowView
         │  └─ embedded SoundPacksWindowView
         ├─ SettingsPresentationSession (General/Login projection and typed actions)
         └─ one app-lifetime SoundPacksEditorOwner
```

`ClaudioGUIComponents` supplies `ClaudioTheme`, branding, failure rows, audio preview, and text
size controls, including the two-caller `SharedMasterVolumeSlider`. `ClaudioLocalization` owns the
string catalog and explicit language store. `ClaudioSettingsPresentation.SettingsRootView` is the
importable production-shape General/Login root used by the compiled harness; the retained
nine-destination production shell stays in `ClaudioGUI` until its later cutover.

## State flow

```text
composition root
  → HostIntegrationManagerBridge (actor) → HostIntegrationPresentationState
  → ClaudioPreferences + LoginItemSettingsModel
    → SettingsPresentationSession.state
      → LoginItemSettingsSection / SettingsRootView
      → SettingsPlatformAction → ClaudioGUI native adapter
  → SoundPackLibrary (actor) → SoundPackLibrarySnapshot
    → SoundPacksWindowModel (package implementation, owner-private)
      → SoundPacksEditorOwner.presentation
        → Settings route/announcement projection + embedded editor view
  → stores/models/coordinators → SwiftUI/AppKit views
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
- `SettingsPresentationSession` projects the real General/Login slice from non-optional existing
  owners. It owns neither Settings routing/window handback nor duplicate preference/login facts;
  native Login Items and Calendar effects are a closed typed action handled in `ClaudioGUI`.
- `PanelFocusCoordinator` and the retained Settings owner own popover/window focus handoff; views
  do not own the app lifetime of management windows.

## Source boundaries

- `ClaudioGUICore`: testable state, presentation, accessibility, pack import/restore, and layout
  decisions; no SwiftUI dependency.
- `ClaudioGUIComponents`: reusable SwiftUI visual primitives.
- `ClaudioSettingsPresentation`: resource-free SwiftUI presentation for the real General/Login
  slice, with no AppKit, ServiceManagement, system workspace, route, or window ownership.
- `ClaudioGUI` / `SoundPacksWindow`: executable native adapters plus AppKit/SwiftUI rendering and
  lifecycle wiring.
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
- `gui/Sources/ClaudioSettingsPresentation/SettingsPresentationSession.swift`: General/Login
  projection, typed actions, and semantic announcement debt.
- `gui/Sources/ClaudioSettingsPresentation/SettingsRootView.swift`: importable real-slice root.
- `gui/Sources/ClaudioGUI/SettingsPlatformActionsAdapter.swift`: exhaustive native adapter for the
  two Settings-only system effects.
- `gui/Sources/ClaudioGUI/SettingsWindowController.swift`: retained settings lifecycle and native
  semantic announcement acknowledgement.
