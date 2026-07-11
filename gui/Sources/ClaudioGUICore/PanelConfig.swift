import ClaudioCore
import Foundation

/// Reads and decodes `configFile` into a ``ClaudioConfig``, falling back to a default,
/// no-pack-selected config if the file is missing, unreadable, or corrupt — the panel must
/// never crash or hang over a bad `config.json` (mirrors ``ClaudioConfig/init(from:)``'s own
/// lenient per-field fallback, applied here one level up, to the whole-file read). `PanelView`
/// (`ClaudioGUI`, T15, compile-only) is this function's real caller; kept as a free function
/// here — not a method on a view-model — so the load/fallback DECISION itself is
/// independently unit-testable without any `ObservableObject`/SwiftUI ceremony around it.
///
/// 读**必须**走 ClaudioCore 的 ``loadClaudioConfig(from:)``（有界 + `O_NONBLOCK` + `fstat` 判 `S_IFREG`），
/// 不能是裸的 `Data(contentsOf:)`：这个函数跑在**主线程**、每开一次面板就跑一次，而裸读**没有任何大小
/// 上限**——一个 500MB 形状的 `~/.claudio/config.json` 会被整份读进内存（本轮 /ship 评审：红队 +
/// Claude 对抗独立命中）。上限与闸门与 `play` / `doctor` 同源，两个模块共用一个定义
/// （ENGINEERING.md T16「REUSE, do not reinvent」）。
///
/// 上面那句「绝不崩溃**或挂起**」里的「挂起」是**当时就已经成立**的，不是这次才修好的：评审断言
/// 「FIFO 会让 `Data(contentsOf:)` 永久阻塞」——**实测不成立**（Darwin 上立刻抛 `EACCES`）。闸门保留
/// 的理由是把「绝不阻塞」变成我们自己的契约，而不是继续依赖 Foundation 一个未文档化的行为——详见
/// `SafeFileRead.swift` 的 ``readConfigFileBounded(at:)``。
///
/// 兜底策略仍归本函数：Core 只回答「这份 config 能不能用」，「不能用时面板显示什么」是面板的事。
public func loadPanelConfig(from configFile: URL) -> ClaudioConfig {
    loadClaudioConfig(from: configFile) ?? ClaudioConfig(selectedPack: "")
}
