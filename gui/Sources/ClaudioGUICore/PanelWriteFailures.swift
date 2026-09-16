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
/// - **同因按 typed reason 去重**：三个错误类型互不相同（`SetEventEnabledError` / `UseError` /
///   `SetMasterVolumeError`），但它们的锁与 config 失败映射到同一个 `PanelWriteFailureReason`。关联的
///   `reason`/pack ID 保留在 typed identity 中，所以不同磁盘真相不会被误合并；用户看到的 description
///   只作为渲染文案，不再承担身份判定。
///
/// ## `.configMissing` 被排除（D43，两个写者，UseError 没有这个 case）
///
/// 静音与主音量共享同一份 D23 定稿①理由（config.json 不存在时 fail-closed，不新建）：它不面向用户——
/// `toggleMute` 与 `setMasterVolume`（阶段 D 已落地，不再是「未来的写路径」）在这个失败上会把 `configState`
/// 重路由到 `.needsPack`，「先选包」空态卡本身就是给用户的解释。再把 description 印一遍是重复且从未 QA 过的
/// 字符串。`UseError`（切包）从不产生这个 case——`selectPack` 是全仓唯一手上握着真实 pack id、因而有资格从无
/// 到有建出一份 config 的写者。
/// 跨三个 config 写者共享的原因身份。它与显示文案分离，避免把本地化文字误当成去重主键；
/// 同一锁/同一读写失败在不同写者之间会得到同一个原因，不同关联值仍保持独立。
public enum PanelWriteFailureReason: Sendable, Equatable, Hashable {
    case configReadFailure(reason: String)
    case configWriteFailure(reason: String)
    case lockBusy
    case lockFailed(errno: Int32)
    case invalidPackID(String)
    case packNotFound(String)
    case manifestUnreadable(packID: String, reason: String)
}

/// 一个可渲染的失败项。`id` 是稳定的类型化原因，不依赖语言或文案格式。
public struct PanelWriteFailure: Sendable, Equatable, Identifiable {
    public let reason: PanelWriteFailureReason
    public let message: String

    public var id: PanelWriteFailureReason { reason }

    public init(reason: PanelWriteFailureReason, message: String) {
        self.reason = reason
        self.message = message
    }
}

public func panelWriteFailureItems(
    muteError: SetEventEnabledError?,
    packSwitchError: UseError?,
    masterVolumeError: SetMasterVolumeError?,
    configFailureReason: String? = nil
) -> [PanelWriteFailure] {
    var candidates: [PanelWriteFailure] = []
    if let muteError, muteError != .configMissing,
        let item = PanelWriteFailure(error: muteError)
    {
        candidates.append(item)
    }
    if let packSwitchError {
        candidates.append(PanelWriteFailure(error: packSwitchError))
    }
    if let masterVolumeError, masterVolumeError != .configMissing {
        candidates.append(PanelWriteFailure(error: masterVolumeError))
    }

    // 配置失败卡已经显示当前磁盘原因；只有同一个原因才去掉下面的重复项。
    let configCardKey = configFailureReason.map { PanelConfigFailureKey($0) }
    var seen: Set<PanelWriteFailureReason> = []
    return candidates.filter { candidate in
        if let configCardKey, configCardKey.matches(candidate) { return false }
        return seen.insert(candidate.reason).inserted
    }
}

/// 兼容现有视图调用点的文案投影；真正的去重使用 ``panelWriteFailureItems`` 的 typed reason。
public func panelWriteFailures(
    muteError: SetEventEnabledError?,
    packSwitchError: UseError?,
    masterVolumeError: SetMasterVolumeError?,
    configFailureReason: String? = nil
) -> [String] {
    panelWriteFailureItems(
        muteError: muteError,
        packSwitchError: packSwitchError,
        masterVolumeError: masterVolumeError,
        configFailureReason: configFailureReason)
        .map(\.message)
}

private struct PanelConfigFailureKey {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    func matches(_ item: PanelWriteFailure) -> Bool {
        // Core read/write failures carry the same underlying reason after their stable prefix.
        // Accept the full user-facing message as well for callers that already have a typed
        // error's description (useful for a same-card projection test).
        item.message == rawValue
            || item.message.hasSuffix(rawValue)
            || rawValue.hasSuffix(item.message)
    }
}

private extension PanelWriteFailure {
    init?(error: SetEventEnabledError) {
        switch error {
        case .configMissing:
            return nil
        case .configReadFailure(let reason):
            self.init(
                reason: .configReadFailure(reason: reason),
                message: error.description)
        case .configWriteFailure(let reason):
            self.init(
                reason: .configWriteFailure(reason: reason),
                message: error.description)
        case .lockBusy:
            self.init(reason: .lockBusy, message: error.description)
        case .lockFailed(let errno):
            self.init(reason: .lockFailed(errno: errno), message: error.description)
        }
    }

    init(error: SetMasterVolumeError) {
        switch error {
        case .configMissing:
            preconditionFailure("configMissing must not become a panel write failure")
        case .configReadFailure(let reason):
            self.init(
                reason: .configReadFailure(reason: reason),
                message: error.description)
        case .configWriteFailure(let reason):
            self.init(
                reason: .configWriteFailure(reason: reason),
                message: error.description)
        case .lockBusy:
            self.init(reason: .lockBusy, message: error.description)
        case .lockFailed(let errno):
            self.init(reason: .lockFailed(errno: errno), message: error.description)
        }
    }

    init(error: UseError) {
        switch error {
        case .invalidPackID(let id):
            self.init(reason: .invalidPackID(id), message: error.description)
        case .packNotFound(let id):
            self.init(reason: .packNotFound(id), message: error.description)
        case .manifestUnreadable(let packID, let reason):
            self.init(
                reason: .manifestUnreadable(packID: packID, reason: reason),
                message: error.description)
        case .configReadFailure(let reason):
            self.init(
                reason: .configReadFailure(reason: reason),
                message: error.description)
        case .configWriteFailure(let reason):
            self.init(
                reason: .configWriteFailure(reason: reason),
                message: error.description)
        case .lockBusy:
            self.init(reason: .lockBusy, message: error.description)
        case .lockFailed(let errno):
            self.init(reason: .lockFailed(errno: errno), message: error.description)
        }
    }
}
