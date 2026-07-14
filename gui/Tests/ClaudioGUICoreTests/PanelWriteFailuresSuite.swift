import ClaudioCore
import ClaudioGUICore
import Foundation

// MARK: - `panelWriteFailures` —— 三个 config.json 写者的失败 → 面板渲染的一个有序去重列表
//
// ## 这个 suite 存在的理由（PLAN-MASTER-VOLUME.md Step 5，阶段 C2 · D3）
//
// `PanelView.operationalPanel` **曾**有两条并列的 `if let error = …, error != .configMissing { errorNotice(…) }`
// （静音 / 切包）。那种形状里每条 `if let` 各自决定「渲染不渲染」，却从来没人决定过「两条同时非 nil、且文案
// 逐字相同（比如都撞上 `.lockBusy`）时该显示一遍还是两遍」——因为三个写者共享同一把 `config.lock`、同一份
// `config.json`，**同时**撞上同一种失败不是理论情形。这个纯函数把「哪些该显示」「显示几遍」「显示顺序」
// 收拢成一个可测的决策点。
//
// 阶段 D（8771946）落地后主音量成了第三个写者，面板侧的并列 `if let` **一条不剩**，改成单条
// `ForEach(panelWriteFailures(muteError:packSwitchError:masterVolumeError:))`。（此处原用现在时写「今天有两条
// 并列的 if let」+「即将成为第三条」，两句在阶段 D 当天就都成了假话 —— `/codex review 8771946`。）
//
// ## 为什么 dedupe 按 description 字符串比较，不是按 case
//
// 三个错误类型互不相同（`SetEventEnabledError` / `UseError` / `SetMasterVolumeError`），编译期没有共同的
// case 可比。但三者的 `.lockBusy` / `.lockFailed(errno:)` / `.configReadFailure(reason:)` /
// `.configWriteFailure(reason:)` 逐字共享同一份中文文案（同一把锁、同一份文件，理应说同一句话）——
// 「同因去重」按这份用户看得到的文案比较，而不是新造一个跨类型的「同因」分类法。

@MainActor
func runPanelWriteFailuresSuites() {
    suite("panelWriteFailures：三者皆 nil → 空列表") {
        let messages = panelWriteFailures(muteError: nil, packSwitchError: nil, masterVolumeError: nil)
        expect(messages.isEmpty, "没有任何写者失败时，面板不该渲染任何一条错误行。得到：\(messages)")
    }

    // ── .configMissing 排除（D43）──────────────────────────────────────────────────────────────
    //
    // 它不面向用户：`toggleMute` / 未来的主音量写路径在这个失败上会把 `configState` 重路由到
    // `.needsPack`，「先选包」空态卡本身就是给用户的解释。再把 description 印一遍是重复且从未 QA 过的字符串。
    suite("panelWriteFailures：muteError == .configMissing 被排除") {
        let messages = panelWriteFailures(
            muteError: .configMissing, packSwitchError: nil, masterVolumeError: nil)
        expect(messages.isEmpty, "静音撞上 .configMissing 时，「先选包」空态卡已经是解释——不该再印一条" + "重复的错误行。得到：\(messages)")
    }

    suite("panelWriteFailures：masterVolumeError == .configMissing 被排除") {
        let messages = panelWriteFailures(
            muteError: nil, packSwitchError: nil, masterVolumeError: .configMissing)
        expect(
            messages.isEmpty,
            "主音量写者与静音写者共享同一份 D23 定稿①理由（fail-closed，不新建）——.configMissing 同样"
                + "不面向用户，同样被路由到「先选包」空态卡解释。得到：\(messages)")
    }

    suite("panelWriteFailures：muteError 的其余 case 一律保留（只有 .configMissing 是例外）") {
        let nonConfigMissing: [(name: String, error: SetEventEnabledError)] = [
            ("lockBusy", .lockBusy),
            ("lockFailed", .lockFailed(errno: 13)),
            ("configReadFailure", .configReadFailure(reason: "master_volume is a string")),
            ("configWriteFailure", .configWriteFailure(reason: "directory not writable")),
        ]
        for failure in nonConfigMissing {
            let messages = panelWriteFailures(
                muteError: failure.error, packSwitchError: nil, masterVolumeError: nil)
            expect(
                messages == [failure.error.description],
                "`.\(failure.name)` 不是 .configMissing——必须如实渲染（项目铁律：绝不静默吞错）。得到：\(messages)"
            )
        }
    }

    suite("panelWriteFailures：masterVolumeError 的其余 case 一律保留（只有 .configMissing 是例外）") {
        let nonConfigMissing: [(name: String, error: SetMasterVolumeError)] = [
            ("lockBusy", .lockBusy),
            ("lockFailed", .lockFailed(errno: 13)),
            ("configReadFailure", .configReadFailure(reason: "master_volume is a string")),
            ("configWriteFailure", .configWriteFailure(reason: "directory not writable")),
        ]
        for failure in nonConfigMissing {
            let messages = panelWriteFailures(
                muteError: nil, packSwitchError: nil, masterVolumeError: failure.error)
            expect(
                messages == [failure.error.description],
                "`.\(failure.name)` 不是 .configMissing——必须如实渲染。得到：\(messages)")
        }
    }

    suite("panelWriteFailures：packSwitchError（UseError）没有 .configMissing case——全部保留") {
        let allCases: [(name: String, error: UseError)] = [
            ("invalidPackID", .invalidPackID("../etc")),
            ("packNotFound", .packNotFound("ghost")),
            ("lockBusy", .lockBusy),
            ("lockFailed", .lockFailed(errno: 13)),
            ("configReadFailure", .configReadFailure(reason: "master_volume is a string")),
            ("configWriteFailure", .configWriteFailure(reason: "directory not writable")),
        ]
        for failure in allCases {
            let messages = panelWriteFailures(
                muteError: nil, packSwitchError: failure.error, masterVolumeError: nil)
            expect(
                messages == [failure.error.description],
                "UseError 没有 D43 排除的 .configMissing case——`.\(failure.name)` 必须如实渲染。得到：\(messages)"
            )
        }
    }

    // ── 多条同时存在：全部保留，互不顶替 ────────────────────────────────────────────────────────
    //
    // 这条注释现在住在 PanelView.swift:546-548，逐字写着「两条都可能同时非 nil……所以两条都渲染，
    // 不互相顶替」。三个写者共享同一份 config.json，一次静音失败 + 一次切包失败完全可能同时挂着。
    suite("panelWriteFailures：三个写者同时失败、文案互不相同 → 全部保留，互不顶替") {
        let mute = SetEventEnabledError.lockBusy
        let pack = UseError.packNotFound("ghost")
        let volume = SetMasterVolumeError.configWriteFailure(reason: "directory not writable")
        let messages = panelWriteFailures(muteError: mute, packSwitchError: pack, masterVolumeError: volume)
        expect(
            messages == [mute.description, pack.description, volume.description],
            "三条失败文案互不相同——一条都不许被另一条顶替，也不许被误判成\"同因\"合并。得到：\(messages)")
    }

    // ── 顺序稳定 ────────────────────────────────────────────────────────────────────────────
    suite("panelWriteFailures：顺序稳定——静音、切包、主音量，与写者声明顺序一致") {
        let mute = SetEventEnabledError.configReadFailure(reason: "mute-reason")
        let pack = UseError.configReadFailure(reason: "pack-reason")
        let volume = SetMasterVolumeError.configReadFailure(reason: "volume-reason")

        let all = panelWriteFailures(muteError: mute, packSwitchError: pack, masterVolumeError: volume)
        expect(
            all == [mute.description, pack.description, volume.description],
            "三者同时存在时，顺序必须是 静音 → 切包 → 主音量。得到：\(all)")

        // 只缺中间那个：剩下两个的相对顺序必须原样保留，不是「谁在就往前挤」的意外副作用。
        let missingPack = panelWriteFailures(muteError: mute, packSwitchError: nil, masterVolumeError: volume)
        expect(
            missingPack == [mute.description, volume.description],
            "缺席的写者不留空位，但在场的两个必须保持相对顺序（静音先于主音量）。得到：\(missingPack)")

        // 重复调用同一组输入，顺序必须逐次一致——「稳定」不是「这一次凑巧对了」。
        let repeatCall = panelWriteFailures(muteError: mute, packSwitchError: pack, masterVolumeError: volume)
        expect(repeatCall == all, "同一组输入重复调用必须得到完全相同的顺序。得到：\(repeatCall)")
    }

    // ── 同因去重：不同写者撞上同一份文案时只显示一遍 ────────────────────────────────────────────
    //
    // 三个错误类型互不相同，编译期没有共同 case 可比——但 `.lockBusy` / `.lockFailed(errno:)` /
    // `.configReadFailure(reason:)` / `.configWriteFailure(reason:)` 在三者身上逐字共享同一份中文文案
    // （同一把锁、同一份文件）。两个写者同时撞上同一种失败时，用户不该看到两行一模一样的字。
    suite("panelWriteFailures：同因去重——两个写者撞上同一份 .lockBusy 文案 → 只保留一条") {
        let messages = panelWriteFailures(
            muteError: .lockBusy, packSwitchError: .lockBusy, masterVolumeError: nil)
        expect(
            messages == [SetEventEnabledError.lockBusy.description],
            "SetEventEnabledError.lockBusy 与 UseError.lockBusy 文案逐字相同——同一把 config.lock 被占用"
                + "只该说一遍，不是两行一模一样的字。得到：\(messages)")
    }

    suite("panelWriteFailures：同因去重——三个写者全部撞上 .lockBusy → 只保留一条") {
        let messages = panelWriteFailures(
            muteError: .lockBusy, packSwitchError: .lockBusy, masterVolumeError: .lockBusy)
        expect(
            messages.count == 1,
            "三个写者同时被同一把锁挡住是完全可能的真实并发场景——文案相同只显示一次。得到：\(messages)")
        expect(
            messages == [SetEventEnabledError.lockBusy.description],
            "去重后留下的必须是那一份共享文案本身，而不是任意占位。得到：\(messages)")
    }

    suite("panelWriteFailures：同因去重按 reason 精确匹配——理由不同的 configReadFailure 不合并") {
        // ⚠️ 负向对照：`.configReadFailure(reason:)` 带关联值，两个写者若读到**不同**的损坏原因，
        // 说明它们观测到了不同的磁盘真相，不该被误判成"同一个因"而丢掉一条。
        let mute = SetEventEnabledError.configReadFailure(reason: "master_volume is a string")
        let pack = UseError.configReadFailure(reason: "events is an array")
        let messages = panelWriteFailures(muteError: mute, packSwitchError: pack, masterVolumeError: nil)
        expect(
            messages == [mute.description, pack.description],
            "两个写者的 reason 文本不同——不是同一份文案，去重不该把其中一条吞掉。得到：\(messages)")
    }

    suite("panelWriteFailures：去重不吞掉 .configMissing 排除之外的合法重复——保留去重后的先到先得顺序") {
        // 静音先撞上 .lockBusy，主音量也撞上 .lockBusy（切包缺席）——保留的那一条必须是排在前面的静音那条
        // 的文案（虽然两者文案逐字相同，这里断言的是"结果只有一条、且等于共享文案"，不依赖具体是谁的实例）。
        let mute = SetEventEnabledError.lockBusy
        let volume = SetMasterVolumeError.lockBusy
        let messages = panelWriteFailures(muteError: mute, packSwitchError: nil, masterVolumeError: volume)
        expect(messages.count == 1, "静音与主音量撞上同一份 .lockBusy 文案——只保留一条。得到：\(messages)")
        expect(messages == [mute.description], "去重后剩下的一条必须等于那份共享文案。得到：\(messages)")
    }
}
