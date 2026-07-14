import ClaudioCore
import Foundation

/// 三个 `config.json` 写者（静音 / 切包 / 主音量）的失败 → 面板渲染的**一个**有序去重列表（PLAN-MASTER-VOLUME.md
/// Step 5，阶段 C2 · D3）。
///
/// ## 为什么要收拢成一个列表
///
/// `PanelView.operationalPanel` **曾**有两条并列的 `if let error = …, error != .configMissing { errorNotice(…) }`
/// （静音 / 切包）。那种形状里，每条 `if let` 各自只回答「这一个该不该显示」，从没人回答过「两条同时非 nil、
/// 且文案逐字相同（三个写者共享同一份 `config.json` / 同一把 `config.lock`，同时撞上 `.lockBusy` 不是理论情形）
/// 时该显示一遍还是两遍」。这个纯函数把「该不该显示 / 显示几遍 / 显示顺序」收拢成一个可测的决策点。
///
/// 阶段 D（8771946）落地后**并列的 `if let` 一条都不剩**：`SetMasterVolumeError` 成了第三个写者，面板侧改成
/// 单条 `ForEach(panelWriteFailures(muteError:packSwitchError:masterVolumeError:))`，只渲染这一个列表。
///
/// （此处原先用现在时写着「今天有两条并列的 `if let`」并附了裸行号 `PanelView.swift:560-564`。两句在阶段 D 当天
/// 就都成了假话，而裸行号还会静静指向别人的代码 —— `/codex review 8771946`。索引一律用符号名，不用行号。）
///
/// ## 三条不变式
///
/// - **互不顶替**：多条失败可以同时存在（一次失败的静音 + 一次失败的切包 + 一次失败的主音量），全部保留，
///   互不覆盖。
/// - **顺序稳定**：静音 → 切包 → 主音量，与三个参数的声明顺序一致，与哪几个存在无关（缺席的写者不留空位，
///   在场的几个保持相对顺序）。
/// - **同因去重，按 description 文案比较**：三个错误类型互不相同（`SetEventEnabledError` / `UseError` /
///   `SetMasterVolumeError`），编译期没有共同 case 可比；但三者的 `.lockBusy` / `.lockFailed(errno:)` /
///   `.configReadFailure(reason:)` / `.configWriteFailure(reason:)` 逐字共享同一份中文文案（同一把锁、同一份
///   文件，理应说同一句话）。「同因」按这份用户看得到的文案判定，而不是新造一套跨类型的错误分类法——两个写者
///   撞上不同的 `reason`（真的观测到了不同的磁盘真相）不会被误合并，因为 description 会带着那份 reason 一起
///   参与比较。
///
/// ## `.configMissing` 被排除（D43，两个写者，UseError 没有这个 case）
///
/// 静音与主音量共享同一份 D23 定稿①理由（config.json 不存在时 fail-closed，不新建）：它不面向用户——
/// `toggleMute` 与 `setMasterVolume`（阶段 D 已落地，不再是「未来的写路径」）在这个失败上会把 `configState`
/// 重路由到 `.needsPack`，「先选包」空态卡本身就是给用户的解释。再把 description 印一遍是重复且从未 QA 过的
/// 字符串。`UseError`（切包）从不产生这个 case——`selectPack` 是全仓唯一手上握着真实 pack id、因而有资格从无
/// 到有建出一份 config 的写者。
public func panelWriteFailures(
    muteError: SetEventEnabledError?,
    packSwitchError: UseError?,
    masterVolumeError: SetMasterVolumeError?
) -> [String] {
    var messages: [String] = []
    if let muteError, muteError != .configMissing {
        messages.append(muteError.description)
    }
    if let packSwitchError {
        messages.append(packSwitchError.description)
    }
    if let masterVolumeError, masterVolumeError != .configMissing {
        messages.append(masterVolumeError.description)
    }

    var seen: Set<String> = []
    return messages.filter { seen.insert($0).inserted }
}
