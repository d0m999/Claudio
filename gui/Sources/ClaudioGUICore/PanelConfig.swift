import ClaudioCore
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
public func loadPanelConfig(from configFile: URL) -> PanelConfigState {
    // 写这一半先问：内容合法但写不进去、或内容本身畸形，都让读这一半的答案作废——即便
    // `packSelection` 认为「选了」，一份写不动的 config 也绝不能被当成可以正常操作的面板。
    switch probeConfigRewritable(configFile: configFile) {
    case .malformed(let reason):
        return .malformed(reason: reason)
    case .unwritable(let reason):
        return .unwritable(reason: reason)
    case .absent, .rewritable:
        break
    }

    switch packSelection(configFile: configFile) {
    case .malformed(let reason):
        return .malformed(reason: reason)
    case .notSelected:
        return .needsPack
    case .selected:
        // 写这一半已经放行，读这一半也认得出一个选择——两者一致时，`loadClaudioConfig` 理应
        // 总是成功；仍然兜底成 `.needsPack` 而不是崩溃或强行解包一个不存在的值，防的是两条轴
        // 之间一个尚未想到的分歧（防御性，而不是假装这里"不可能"失败）。
        guard let config = loadClaudioConfig(from: configFile) else { return .needsPack }
        return .operational(config)
    }
}
