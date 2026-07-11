import ClaudioCore
import Foundation

/// Per-event sound coverage for a pack (ENGINEERING.md 决议① · codex 精修为三态; DESIGN.md
/// "事件行三态"). Computed purely from a pack's manifest + on-disk file presence —
/// `helper`'s runtime playback behavior is unchanged by this type existing at all (it's a
/// GUI-only read model, T16).
///
/// `broken` deliberately EXCLUDES audio-content corruption (2026-07-09 收窄, same source
/// as DESIGN.md): this only distinguishes "declared but the file isn't safely there" from
/// "declared and it is" — never whether the bytes actually decode as playable audio (that
/// would need an audio-lint pass this repo doesn't have; `doctor`/`play` don't have one
/// either, see `Doctor.swift`'s module-level note).
public enum CoverageState: Sendable, Equatable {
    /// The event is mapped in the manifest, and the declared file exists on disk, safely
    /// inside the pack directory (``safePackFileURL(_:in:)``'s containment check passed).
    case present(fileName: String)
    /// The manifest has no entry for this event at all — the documented silent-fallback
    /// case (``PackManifest/events``'s doc comment: "缺失 event key 表示...静默"), not a
    /// pack defect.
    case unmapped
    /// The event IS mapped in the manifest, but the declared file doesn't exist, or its
    /// resolved path fails containment (``safePackFileURL(_:in:)`` returned `nil`) — a real
    /// pack defect, distinct from ``unmapped``'s intentional silence (DESIGN.md: "真打包错误
    /// 不被伪装成正常静默").
    case broken(fileName: String)
}

extension CoverageState {
    /// Whether the row's 试听 (preview) control should be enabled — `true` only for
    /// ``present`` (DESIGN.md 事件行三态: both `unmapped` and `broken` disable 试听).
    public var previewEnabled: Bool {
        if case .present = self { return true }
        return false
    }

    /// Whether this state should surface as a pack defect via `doctor` — `true` only for
    /// ``broken`` (DESIGN.md: "`broken`...并入 `doctor`"; ``unmapped`` never does, since it's
    /// intentional silence, not a defect).
    public var entersDoctor: Bool {
        if case .broken = self { return true }
        return false
    }
}

/// One event row's complete render-ready state: which ``Event``, its computed
/// ``CoverageState``, and whether it's currently muted (the ORTHOGONAL "静音态" axis —
/// ``ClaudioConfig/isEnabled(_:)``, 决议③ — which overlays ``CoverageState`` rather than
/// replacing it; DESIGN.md: "此三态与正交的静音态...叠加，互不取代").
public struct EventRow: Sendable, Equatable {
    public let event: Event
    public let coverage: CoverageState
    public let enabled: Bool

    public init(event: Event, coverage: CoverageState, enabled: Bool) {
        self.event = event
        self.coverage = coverage
        self.enabled = enabled
    }
}

extension EventRow {
    /// Whether this row's ``PanelFocusTarget/eventAction(_:)`` slot currently renders as an
    /// OPERABLE control — the pure decision behind ``PanelView``'s `nonOperableActionEvents`,
    /// fed to ``panelFirstFocusTarget(_:nonOperableActionEvents:)`` so a panel never opens with
    /// keyboard focus parked on a dimmed control (ENGINEERING.md「无障碍规格」"打开焦点落首个
    /// 可操作项" — 可操作 is load-bearing).
    ///
    /// The only non-operable case is a `.present` row that is MUTED: there the row's action
    /// slot is the 试听 ▶ preview button, which `EventRowView` renders `.disabled(true)` when
    /// `!enabled`. On `.unmapped`/`.broken` the action slot is instead the always-enabled
    /// import affordance (the co-rendered disabled preview no longer owns `.eventAction` — see
    /// ``EventRowView``'s `previewButton(claimsActionFocus:)` dedup), so the slot is operable
    /// there regardless of `enabled`. `.present` + not muted is operable (the preview plays).
    public var eventActionOperable: Bool {
        if case .present = coverage { return enabled }
        return true
    }
}

/// Computes every ``Event/allCases``' ``EventRow`` for `packID` — the state gallery (T14)
/// and the real event-row panel (T15) both render straight off this, no other place is
/// allowed to recompute coverage independently (single source of truth, T16).
///
/// Reuses ``resolvePackDirectory(id:userPacksDirectory:bundledPacksDirectory:)`` (the same
/// symlink-safe, user-root-first lookup order `doctor`/`play` use) and
/// ``loadPackManifest(in:)`` (T16's shared manifest loader) — never a second, independent
/// resolution/parsing path.
///
/// If `packID` doesn't resolve to any pack directory (neither user nor bundled root), or
/// its `manifest.json` can't be loaded at all (missing/corrupt/symlink-escaping), **every**
/// event reports ``CoverageState/unmapped`` — deliberately the same "nothing configured yet"
/// signal a truly-unmapped single event gives, rather than inventing a fourth,
/// pack-level-failure case: from this function's caller's point of view, "there is no usable
/// manifest to read events from" and "this event isn't in the manifest" collapse to the same
/// observable fact ("this event has no sound"). A real pack-level defect (corrupt/missing
/// manifest) is still visible independently via `doctor`'s own `.manifestUnreadable`/
/// `.packNotFound` pack-integrity report (``checkPackIntegrity(configFile:userPacksDirectory:bundledPacksDirectory:)``)
/// — this function does not need to duplicate that reporting.
public func packCoverage(
    packID: String,
    config: ClaudioConfig,
    environment: AudioImportEnvironment
) -> [EventRow] {
    guard
        let packDirectory = resolvePackDirectory(
            id: packID, userPacksDirectory: environment.userPacksDirectory,
            bundledPacksDirectory: environment.bundledPacksDirectory),
        case .success(let manifest) = loadPackManifest(in: packDirectory)
    else {
        return Event.allCases.map {
            EventRow(event: $0, coverage: .unmapped, enabled: config.isEnabled($0))
        }
    }

    return Event.allCases.map { event in
        EventRow(
            event: event,
            coverage: coverageState(for: event, manifest: manifest, packDirectory: packDirectory),
            enabled: config.isEnabled(event))
    }
}

/// The single-event coverage computation described in ``CoverageState``'s doc comment:
/// unmapped when the manifest has no key for `event`; otherwise present/broken depending on
/// whether ``safePackFileURL(_:in:)`` resolves the declared filename to a real, contained,
/// on-disk file.
private func coverageState(
    for event: Event,
    manifest: PackManifest,
    packDirectory: URL
) -> CoverageState {
    guard let fileName = manifest.events[event.manifestKey] else { return .unmapped }
    guard let resolved = safePackFileURL(fileName, in: packDirectory),
        FileManager.default.fileExists(atPath: resolved.path)
    else {
        return .broken(fileName: fileName)
    }
    return .present(fileName: fileName)
}
