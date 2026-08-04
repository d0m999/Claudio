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
    /// `eventAction` 是手工试听；事件自动播放静音 (`enabled`) 与它正交。只要覆盖态存在安全文件，
    /// 试听焦点就是可操作的；主音量为零等运行期原因由 ``EventPreviewAvailability`` 在视图边界补充。
    /// `.unmapped` / `.broken` 的修复入口是每行最前面的 ``PanelFocusTarget/eventSound(_:)``
    /// 身份按钮，它会打开完整声音包编辑器并定位当前事件。
    public var eventActionOperable: Bool {
        coverage.previewEnabled
    }

    // `previewClaimsActionFocus` 已删（PLAN-SOUND-MANAGER.md §2.5/T2）—— 它存在的唯一理由是仲裁
    // 「试听 ▶ 与导入入口，两者之中谁在这一行拥有 `.eventAction`」（T16 review 修复⑥ 造它时，
    // `.unmapped`/`.broken` 的导入入口与 `.present` 的试听 ▶ 是**互斥的两个候选**，同时渲染时必须
    // 有一个不绑 `.eventAction`，否则 SwiftUI 的焦点解析未定义）。T2 把那个导入入口整个搬进了
    // ``PanelFocusTarget/eventSound(_:)``（事件身份 / 编辑路由的焦点身份）—— 于是 `.eventAction`
    // 从此在三态下都只剩**一个**候选（试听 ▶ 自己），仲裁不再有意义：`EventRowView` 现在无条件把
    // `.focused(_:equals: .eventAction(_))` 绑在 `previewButtonBody` 上，不再有第二个控件跟它抢。
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

    return packCoverage(manifest: manifest, packDirectory: packDirectory, config: config)
}

/// ``packCoverage(packID:config:environment:)`` 的下层：给一份**已经解析好的** pack 目录 + **已经
/// 解码好的** manifest，算出五条 ``EventRow``。上面那个按 `packID` 的入口现在只是它的薄包装
/// （解析目录 → 读 manifest → 委托给这里），coverage 逻辑本身仍然只有这一份实现。
///
/// 存在的理由（/ship 评审修复④，性能）：`PackGallery` 的每张卡片都要 (a) 每事件覆盖状态、
/// (b)「manifest 能不能解码」这个 broken 判定、(c) manifest 的原始 JSON（`name`/`license`）。
/// 只有按 `packID` 的入口时，这三个消费者各自触发一次「解析目录 + 读 manifest」——每个包
/// **3 次 manifest 读 + 2 次 realpath 目录解析**，而这一切由 `PanelView.refresh()` 在**主线程**、
/// 每次开面板和每次静音点击时跑一遍。有了这个下层入口，`PackGallery` 只解析一次目录、只读一次
/// manifest bytes，把同一份 `packDirectory` / `PackManifest` / `Data` 喂给三个消费者——同时**不**
/// 复制任何 coverage 逻辑（这正是它必须存在这里、而不是在 `PackGallery` 里另写一份的原因）。
public func packCoverage(
    manifest: PackManifest,
    packDirectory: URL,
    config: ClaudioConfig
) -> [EventRow] {
    Event.allCases.map { event in
        EventRow(
            event: event,
            coverage: coverageState(for: event, manifest: manifest, packDirectory: packDirectory),
            enabled: config.isEnabled(event))
    }
}

/// The single-event coverage computation described in ``CoverageState``'s doc comment:
/// unmapped when the manifest has no key for `event`; otherwise present/broken depending on
/// whether ``safePackFileURL(_:in:)`` resolves the declared filename to a real, contained,
/// on-disk **regular file**.
///
/// 「正规文件」这三个字是负重的，且必须和 helper 侧**逐字一致**：`doctor`（`Doctor.swift`）和
/// `play`（`Play.swift`）判的是 ``regularFileExists(at:)``（`stat(2)` + `S_IFREG`），而这里曾经用的是
/// `FileManager.fileExists(atPath:)` —— 它对**目录**、FIFO、socket、设备一律回答 `true`。两边于是
/// 互相打架：一个名叫 `stop.mp3` 的**目录**，面板显示 `.present`（文件名照常、试听键可点），而
/// `doctor` 说它缺失、`play` 拒播。用户看到的是一个「配好了却不响、而且 doctor 骂你」的包。
/// 现在两边同一个谓词，同一个答案。
///
/// `regularFileExists` 刻意用 `stat` 而非 `lstat`：**包内指向包内真实文件的合法符号链接仍然算在位**
/// （`safePackFileURL` 的 containment 检查已经放行了它，逃出包目录的链接更早一步就被挡掉了）——
/// 被拒的只是「链接的目标不是正规文件」。`CoverageStateSuite` 两头都钉了用例。
private func coverageState(
    for event: Event,
    manifest: PackManifest,
    packDirectory: URL
) -> CoverageState {
    guard let fileName = manifest.events[event.manifestKey] else { return .unmapped }
    guard let resolved = safePackFileURL(fileName, in: packDirectory),
        regularFileExists(at: resolved)
    else {
        return .broken(fileName: fileName)
    }
    return .present(fileName: fileName)
}
