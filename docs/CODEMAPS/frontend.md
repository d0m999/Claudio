# Frontend Architecture

<!-- Generated: 2026-08-22 | Files scanned: 286 | Token estimate: ~680 -->

## Page / window tree

```text
ClaudioGUIApp (@main)
└─ ClaudioGUIAppDelegate
   └─ MenuBarController (@MainActor)
      ├─ NSPopover → PanelView
      │  ├─ PanelRows / EventRowView / MasterVolumeRow
      │  ├─ PanelPackSectionView / PackGalleryView
      │  └─ PanelQuitFooter / onboarding and state-driven notices
      ├─ retained IntegrationsWindowController
      │  └─ IntegrationsWindowView
      └─ retained SoundPacksWindowController
         └─ SoundPacksWindowView
```

`ClaudioGUIComponents` supplies `ClaudioTheme`, branding, failure rows, audio preview, and text
size controls. `ClaudioLocalization` owns the string catalog and explicit language store.

## State flow

```text
composition root
  → HostIntegrationManagerBridge (actor) → HostIntegrationPresentationState
  → SoundPackLibrary (actor) → SoundPackLibrarySnapshot
  → stores/models/coordinators → SwiftUI/AppKit views
```

- `HostIntegrationPresentationStore` publishes host rows; `IntegrationsWindowModel` owns actions,
  feedback, recovery, and retained-window state.
- `SoundPacksRefreshCoordinator` coordinates panel/window projections after config or pack writes.
- `PanelConfigController`, `MasterVolumeController`, `EventMuteController`, and onboarding models
  keep pure Foundation decisions outside SwiftUI.
- `PanelFocusCoordinator` and the two window controllers own popover/window focus handoff; views do
  not own the app lifetime of management windows.

## Source boundaries

- `ClaudioGUICore`: testable state, presentation, accessibility, pack import/restore, and layout
  decisions; no SwiftUI dependency.
- `ClaudioGUIComponents`: reusable SwiftUI visual primitives.
- `ClaudioGUI` / `SoundPacksWindow`: AppKit/SwiftUI rendering and lifecycle wiring only.
- Native menu-bar, VoiceOver, keyboard, audio, and focus behavior requires real macOS manual evidence
  in addition to executable harness checks.

## Key files

- `gui/Sources/ClaudioGUI/ClaudioGUIApp.swift`: composition root.
- `gui/Sources/ClaudioGUI/MenuBarController.swift`: status item, popover, retained windows.
- `gui/Sources/ClaudioGUICore/HostIntegrationManagerBridge.swift`: async core-to-UI seam.
- `gui/Sources/ClaudioGUICore/SoundPackLibrary.swift`: app-lifetime pack scan/cache actor.
- `gui/Sources/SoundPacksWindow/SoundPacksWindowController.swift`: standard window lifecycle.
