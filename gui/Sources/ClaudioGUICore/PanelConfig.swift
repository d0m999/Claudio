import ClaudioCore
import Darwin
import Foundation

/// D23 定稿：the panel's complete verdict on `config.json` — combining BOTH orthogonal axes
/// (``packSelection(configFile:)``'s "读" and ``probeConfigRewritable(configFile:)``'s "写")
/// into the one decision `PanelView` actually needs to route on. Neither axis alone is
/// enough: a config whose `selected_pack` parses fine but whose `master_volume` is a string
/// reads as "selected" yet is NOT safely rewritable — rendering the operational panel off the
/// read axis alone would show a full set of live controls that fail on every single click
/// (see ``probeConfigRewritable(configFile:)``'s doc comment on `ConfigMutation.swift`).
///
/// `PanelView` (`ClaudioGUI`, T15, compile-only) is this function's real caller; kept as a
/// free function here — not a method on a view-model — so the load/fallback DECISION itself
/// is independently unit-testable without any `ObservableObject`/SwiftUI ceremony around it.
public enum PanelConfigState: Sendable, Equatable {
    /// Both axes agree the file is safe: usable to read AND safe to rewrite. Carries the
    /// actually-decoded ``ClaudioConfig`` so the panel never has to re-derive it.
    case operational(ClaudioConfig)
    /// Nobody has chosen a pack yet (config missing entirely, or `selected_pack` is an empty
    /// string) — NOT an error. The self-heal path is already open: `availablePacks` doesn't
    /// depend on `config.json` at all, and picking a card runs ``selectPack`` (D23 定稿④),
    /// which creates a correct `config.json` from nothing.
    case needsPack
    /// The file itself is bad — unreadable, not a JSON object, or missing/malformed
    /// `selected_pack` — OR content that parses but contains a value the write path refuses
    /// (e.g. `master_volume` as a string). Not guessed at, not silently repaired: the reason
    /// is the exact, actionable string ``probeConfigRewritable(configFile:)``/
    /// ``packSelection(configFile:)`` already produced.
    case malformed(reason: String)
    /// The content is fine, but the directory it lives in isn't writable — a different
    /// problem with a different fix (chmod the directory, not edit the file).
    case unwritable(reason: String)
}

extension PanelConfigState {
    /// The ``ClaudioConfig`` this state's read models (``packCoverage(packID:config:environment:)``,
    /// ``availablePacks(config:environment:)``) should compute off of. `.operational` hands back
    /// the real, decoded config; every other case hands back an empty-selection default — the
    /// same "no pack selected" shape those read models already treat as "every event `.unmapped`,
    /// never crash" (``packCoverage``'s own empty-`packID` fixture). `PanelView` still renders a
    /// DIFFERENT top-level view per state (the empty-pack card, or the honest failure card) —
    /// this is only the config those computations need as input, not what the panel shows.
    public var resolvedConfig: ClaudioConfig {
        if case .operational(let config) = self { return config }
        return ClaudioConfig(selectedPack: "")
    }
}

/// The three shapes ``PanelView``'s operational-panel TOP region can take, as a pure function of
/// ``PanelConfigState`` (``PanelConfigState/topContent``). Extracted (/codex review f54d335 P1#1)
/// so the RENDER path (`operationalPanel`'s switch) and the OPENING-FOCUS derivation
/// (`applyFirstFocus`'s `hasMasterVolume` / `hasConfigFailureNotice` flags) read ONE classification
/// instead of two independent `switch panelModel.configState` reads. Before this, the two switches
/// were kept in agreement only by a `ViewWiringSuite` text tripwire *after the fact*; now both paths
/// read ONE classification, so DECISION-level drift — each path keying off a different
/// state→content mapping — is fenced by construction: change which state maps to `.configFailure`
/// here and BOTH paths follow automatically. What this does NOT fence is the PRESENTATION-level
/// render mapping: `operationalPanel`'s `switch` still hand-picks which subview each branch draws,
/// and no import unit test pins branch→on-screen-control (mis-wire a branch and both projections
/// stay green). That residual hole needs ViewInspector/XCTest — absent on this machine — so
/// `ViewWiringSuite` only text-probes the wiring line is still present (see TODOS.md
/// 「render 映射仍是手写 switch」).
///
/// - `.events`: the five event rows + the master-volume slider — the only state (`.operational`)
///   in which the slider is actually on screen, so it is exactly `hasMasterVolume`.
/// - `.needsPack`: the 先选包 empty-state card.
/// - `.configFailure(reason:)`: the honest-failure card, which carries the 在访达中显示 config.json
///   Reveal button — exactly `hasConfigFailureNotice`, and the reason it leads the focus order with
///   ``PanelFocusTarget/configReveal``. The `reason` is the exact actionable string
///   ``PanelConfigState`` already carries (`.malformed`/`.unwritable`), computed once here rather
///   than re-derived on the render side.
public enum PanelTopContent: Sendable, Equatable {
    case events
    case needsPack
    case configFailure(reason: String)
}

extension PanelTopContent {
    public enum Kind: Sendable, Equatable {
        case events
        case needsPack
        case configFailure
    }

    /// 不包含错误文字的内容种类。焦点只在控件真正出现/消失时迁移，原因文字变化不应重置焦点。
    public var kind: Kind {
        switch self {
        case .events: return .events
        case .needsPack: return .needsPack
        case .configFailure: return .configFailure
        }
    }

    /// The operational events content — five event rows + the master-volume slider — is on screen,
    /// true only for `.events`. Drives both `visibleRows` (which rows are actually rendered into the
    /// opening-focus order) and `hasMasterVolume` (the slider is on screen exactly then).
    ///
    /// Hoisted here as a UNIT-TESTED projection rather than re-pattern-matched inside `PanelView`
    /// (/codex review f54d335 P1#1 follow-up): a value-level single source wasn't enough. When the
    /// View re-derived this with `if case .events = content { return true }`, the closure's RETURN
    /// value was pinned by no test — flipping it to `false` reintroduced the drift (slider renders
    /// but focus skips `.masterVolume`) with every test still green. As a projection on
    /// ``PanelTopContent``, its return is fenced by `PanelConfigSuite`; the View forwards it verbatim.
    public var showsEventContent: Bool { self == .events }

    /// The honest-failure card — carrying the 在访达中显示 config.json Reveal button (focus target
    /// ``PanelFocusTarget/configReveal``) — is on screen, true only for `.configFailure`. Same
    /// reasoning as ``showsEventContent``: a unit-tested projection the View forwards verbatim, so
    /// the render/focus agreement is fenced at the DECISION level, not just the value level.
    public var hasConfigFailureNotice: Bool {
        if case .configFailure = self { return true }
        return false
    }
}

/// 为顶部内容变化保留或迁移当前焦点。当前控件仍在下一份焦点序中时无论内容种类是否变化都
/// 保留；刷新重试消失时回到声音作用域，其余控件消失才优先落到有效的配置恢复按钮，
/// 再回到声音作用域或下一项可用控件。
public func panelFocusAfterTopContentChange(
    previous: PanelTopContent?,
    current: PanelTopContent,
    focusedTarget: PanelFocusTarget?,
    nextOrder: [PanelFocusTarget]
) -> PanelFocusTarget? {
    guard !nextOrder.isEmpty else { return nil }
    guard let focusedTarget else { return nil }
    if nextOrder.contains(focusedTarget) {
        return focusedTarget
    }
    if focusedTarget == .libraryRefreshRetry {
        return nextOrder.first(where: { $0 == .soundScope }) ?? nextOrder.first
    }
    // Only an existing target that disappeared needs a fallback. A reason-only publication
    // must not create focus when the panel had none.
    if previous?.kind == current.kind {
        return nextOrder.first(where: { $0 == .soundScope }) ?? nextOrder.first
    }
    if current.kind == .configFailure, nextOrder.contains(.configReveal) {
        return .configReveal
    }
    if nextOrder.contains(.soundScope) {
        return .soundScope
    }
    return nextOrder.first
}

extension PanelConfigState {
    /// What ``PanelView``'s operational panel renders at its top for this state — the SINGLE
    /// classification both the render switch and the opening-focus flag derivation read (see
    /// ``PanelTopContent``). `.malformed` and `.unwritable` collapse to the same `.configFailure`
    /// (same card, same Reveal control), carrying their own `reason`; `.operational` → `.events`;
    /// `.needsPack` → `.needsPack`.
    public var topContent: PanelTopContent {
        switch self {
        case .operational: return .events
        case .needsPack: return .needsPack
        case .malformed(let reason), .unwritable(let reason): return .configFailure(reason: reason)
        }
    }
}

/// Determines the panel's complete config verdict for `configFile` — the ONLY entry point
/// `PanelView` should call to decide what to render (D23 定稿②③). Composes both orthogonal
/// axes (see ``PanelConfigState``'s doc comment): the WRITE axis is checked first, because a
/// write-side problem (malformed content, an unwritable directory) makes the READ axis's
/// answer moot — even a `config.json` that reads as "a pack is selected" is not safe to treat
/// as operational if writing back to it would fail on the very next click.
///
/// 读**必须**走 ClaudioCore 的 ``loadClaudioConfig(from:)``（有界 + `O_NONBLOCK` + `fstat` 判 `S_IFREG`），
/// 不能是裸的 `Data(contentsOf:)`：这个函数跑在**主线程**、每开一次面板就跑一次，而裸读**没有任何大小
/// 上限**——一个 500MB 形状的 `~/.claudio/config.json` 会被整份读进内存（本轮 /ship 评审：红队 +
/// Claude 对抗独立命中）。上限与闸门与 `play` / `doctor` 同源，两个模块共用一个定义
/// （ENGINEERING.md T16「REUSE, do not reinvent」）。``packSelection``/``probeConfigRewritable`` 两条
/// 轴都走这同一道门，所以这里再调用它们不会打开第二个未设限的读入口。
///
/// 上面那句「绝不崩溃**或挂起**」里的「挂起」是**当时就已经成立**的，不是这次才修好的：评审断言
/// 「FIFO 会让 `Data(contentsOf:)` 永久阻塞」——**实测不成立**（Darwin 上立刻抛 `EACCES`）。闸门保留
/// 的理由是把「绝不阻塞」变成我们自己的契约，而不是继续依赖 Foundation 一个未文档化的行为——详见
/// `SafeFileRead.swift` 的 ``readConfigFileBounded(at:)``。
///
/// 兜底策略仍归本函数：Core 只回答「这份 config 能不能用」，「不能用时面板显示什么」是面板的事——
/// 这也是这个函数不再无条件回落成 `ClaudioConfig(selectedPack: "")` 的理由：那个回落曾经把「文件缺失
/// / 空串选择」（自救路径本来就通）与「文件畸形」（自救路径走不通，需要诚实告知 + 修复指令）混成了
/// 同一个样子，二者对用户的意义完全不同（D23 定稿）。
public func loadPanelConfig(
    from configFile: URL,
    reader: ConfigInspectionReader = readConfigFileBounded(at:)
) -> PanelConfigState {
    let inspection = inspectConfig(configFile: configFile, reader: reader)
    // 写这一半先问：内容合法但写不进去、或内容本身畸形，都让读这一半的答案作废——即便
    // `packSelection` 认为「选了」，一份写不动的 config 也绝不能被当成可以正常操作的面板。
    switch inspection.rewritability {
    case .malformed(let reason):
        return .malformed(reason: reason)
    case .unwritable(let reason):
        return .unwritable(reason: reason)
    case .absent, .rewritable:
        break
    }

    switch inspection.packSelection {
    case .malformed(let reason):
        return .malformed(reason: reason)
    case .notSelected:
        return .needsPack
    case .selected:
        // The decoded value belongs to the same bounded read. A decoder disagreement is a
        // malformed config, never evidence that no pack was selected.
        guard let config = inspection.decodedConfig else {
            return .malformed(reason: "config.json 解析失败：无法从已读取内容建立配置")
        }
        return .operational(config)
    }
}

/// 返回配置失败态的可用 Finder 恢复目标：文件或链接节点仍在时定位该节点，否则定位最近存在的目录。
/// 这是纯投影，不创建目录、不跟随写路径；真正的修复仍由用户或既有写入锁完成。
public func panelConfigRecoveryTarget(configFile: URL) -> URL? {
    let fileManager = FileManager.default
    let normalizedFile = configFile.standardizedFileURL
    var status = stat()
    let leafExists = normalizedFile.withUnsafeFileSystemRepresentation { path -> Bool in
        guard let path else { return false }
        return Darwin.lstat(path, &status) == 0
    }
    if leafExists {
        return normalizedFile
    }

    var directory = normalizedFile.deletingLastPathComponent()
    while true {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            return directory
        }
        let parent = directory.deletingLastPathComponent()
        guard parent.path != directory.path else { return nil }
        directory = parent
    }
}

/// A recovery-file action may point only at the actual regular file preserved by a write result.
/// Unlike the config action, it must never silently fall back to an ancestor directory.
public func panelExistingRecoveryFileTarget(_ recoveryFile: URL) -> URL? {
    let file = recoveryFile.standardizedFileURL
    var status = stat()
    let exists = file.withUnsafeFileSystemRepresentation { path -> Bool in
        guard let path else { return false }
        return Darwin.lstat(path, &status) == 0
    }
    return exists && (status.st_mode & S_IFMT) == S_IFREG ? file : nil
}
