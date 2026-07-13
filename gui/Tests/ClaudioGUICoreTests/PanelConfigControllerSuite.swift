import ClaudioCore
import ClaudioGUICore
import Foundation

// MARK: - PanelConfigController —— 从 PanelView 抽出来的 config 读模型 + 静音/切包写路径
//
// ## 这个 suite 存在的理由（红队 9cccc9c，worktree 实测 3 条存活变异）
//
// 这几段逻辑（`toggleMute` 的翻转+路由+刷新、`reload()` 的 configState 重载、`reloadEnabledFlags()`）
// 曾住在 `PanelView`（`@main` executableTarget，测试 import 不进来），唯一的守卫是 `ViewWiringSuite`
// 的文本绊线。红队实测三条「改坏真实行为、两套测试全绿」的变异：
//   1. **执行**：`refresh()` 正确被调，但函数体删掉 `configState` 重载 → 面板对磁盘上的删除永久失明。
//   2. **可达性**：路由 switch 前插早退，让某条 case 成死代码 → 绊线要的字符串一个不少（存在≠可达）。
//   3. **翻转**：`setEnabled(enabled: !currentlyEnabled)` 去掉 `!` → toggle 变死键。
//
// 搬进可实例化的 `PanelConfigController` 后，下面这些断言 **new 一个真的 controller、喂真磁盘 config、
// 调真方法、断言磁盘字节与读模型真的变**。三条变异各自当场变红（本文件末尾列了它们各对应哪条断言）。
// 这是文本绊线的天花板之上唯一的路：不是「代码在不在」，是「代码做了什么」。

@MainActor
private func makeEnvironment(_ userPacksDirectory: URL) -> AudioImportEnvironment {
    AudioImportEnvironment(
        userPacksDirectory: userPacksDirectory,
        bundledPacksDirectory: nil,
        durationProbe: StubDurationProbe(fixedDuration: 1.0))
}

/// 一份良构、`.operational` 的 config.json（`selected_pack` 有效、`master_volume` 是数字、`events` 空
/// → 四个事件全 enabled）。写路径对它可安全重写，读路径判成 `.operational`。
private let operationalConfigBytes =
    #"{ "selected_pack": "minimal-chime", "master_volume": 0.42, "events": {} }"#

@MainActor
func runPanelConfigControllerSuites() {
    // 变异 #3（翻转）+ #2（可达性）：一次成功的静音必须（a）把翻转后的 enabled 位**落盘**，
    // （b）**重算** eventRows / config 读模型让面板反映它。
    suite("PanelConfigController.toggleMute 成功：翻转位落盘 + 读模型重算（钉死红队 #3 翻转、#2 可达性）") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(operationalConfigBytes, to: configFile)
            let controller = PanelConfigController(
                configFile: configFile, lockFile: lockFile,
                environment: makeEnvironment(root.appendingPathComponent("packs")),
                muteController: EventMuteController(configFile: configFile, lockFile: lockFile))

            // 前提：stop 当前 enabled（events 空 → opt-out 默认 true）。
            expect(controller.config.isEnabled(.stop), "前提：stop 初始必须是 enabled")
            expect(
                controller.eventRows.first(where: { $0.event == .stop })?.enabled == true,
                "前提：stop 那行初始 enabled 必须是 true，得到 "
                    + "\(String(describing: controller.eventRows.first(where: { $0.event == .stop })?.enabled))")

            controller.toggleMute(.stop)

            // (a) 翻转真的落盘 —— 去掉 `!`（红队 #3）会把 currentlyEnabled(=true) 原样写回，这里就红。
            let onDisk = loadPanelConfig(from: configFile).resolvedConfig
            expect(
                onDisk.isEnabled(.stop) == false,
                "toggleMute 必须把 stop 从 enabled 翻成 disabled 并**落盘** —— 磁盘上 stop 仍 enabled = "
                    + "翻转逻辑没生效（红队实测：去掉那个 `!` 就是这个结果）。得到 isEnabled(.stop)="
                    + "\(onDisk.isEnabled(.stop))")

            // (b) 读模型真的重算 —— 让 `.enabledFlagsOnly` 那条 case 成死代码（红队 #2 早退）会让 config /
            // eventRows 停在翻转前的旧值，这两条就红。
            expect(
                controller.config.isEnabled(.stop) == false,
                "controller.config 必须反映刚落盘的翻转 —— 它停在旧值 = reloadEnabledFlags 没跑（那条 case"
                    + "被早退成了死代码）。得到 \(controller.config.isEnabled(.stop))")
            expect(
                controller.eventRows.first(where: { $0.event == .stop })?.enabled == false,
                "eventRows 里 stop 那行必须重算成 disabled —— 它还是 true = 读模型没重算，面板会顶着一个"
                    + "翻转前的旧开关。得到 "
                    + "\(String(describing: controller.eventRows.first(where: { $0.event == .stop })?.enabled))")
        }
    }

    // 变异 #1（执行）：面板打开着的时候 config.json 被外部删掉，点静音 → 写盘 fail closed（.configMissing）
    // → 路由 .full → reload() 必须重载 configState 让它从 .operational 翻到 .needsPack。删掉 reload() 里那行
    // configState 重载 → configState 停在陈旧的 .operational → 面板顶着四行活控件撒谎，这条当场红。
    suite("PanelConfigController.toggleMute + 外部删除：reload() 必须把 configState 翻到 .needsPack（钉死红队 #1 执行）") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(operationalConfigBytes, to: configFile)
            var afterFullReloadCalls: [String] = []
            let controller = PanelConfigController(
                configFile: configFile, lockFile: lockFile,
                environment: makeEnvironment(root.appendingPathComponent("packs")),
                muteController: EventMuteController(configFile: configFile, lockFile: lockFile),
                afterFullReload: { afterFullReloadCalls.append($0.selectedPack) })

            // 前提：初始是 .operational（四行活控件的态）。
            guard case .operational = controller.configState else {
                expect(false, "前提：初始 configState 必须是 .operational，得到 \(controller.configState)")
                return
            }

            // 面板已经打开之后，config.json 被外部删掉。
            try? FileManager.default.removeItem(at: configFile)

            controller.toggleMute(.stop)

            // configState 必须重路由到 .needsPack —— 这是「先选包」空态卡，用户唯一能看到的诚实解释。
            guard case .needsPack = controller.configState else {
                expect(
                    false,
                    "config 被外部删掉后，一次静音必须让 configState 翻到 .needsPack（reload() 重载了它）"
                        + " —— 它停在 \(controller.configState) = reload() 没重载 configState，面板会继续顶着"
                        + "四行活控件挂在一个不存在的文件上（正是这个 commit 要消除的『面板顶着绿点撒谎』）")
                return
            }

            // 顺带钉死跨-view-model 协调契约：.full 走的是全量 reload()，afterFullReload 必须被调一次
            // （带着重载后的 config —— 此刻 selectedPack 已回落成空）。
            expect(
                afterFullReloadCalls.count == 1,
                "全量 reload() 必须调用 afterFullReload 恰好一次（onboarding 重探 + import view-model"
                    + " retarget 就挂在这上面）。得到 \(afterFullReloadCalls.count) 次")
        }
    }

    // 整条链另一半：轻量路径（静音成功）**不**触发全量 reload —— afterFullReload 不该被调（那会在每次点
    // 静音钮时白扫一遍整个包库 + 重探 onboarding）。这条钉死「.enabledFlagsOnly 走的是轻量刷新」。
    suite("PanelConfigController.toggleMute 成功走轻量刷新：afterFullReload 不被调（钉死路由分流）") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(operationalConfigBytes, to: configFile)
            var afterFullReloadCalls = 0
            let controller = PanelConfigController(
                configFile: configFile, lockFile: lockFile,
                environment: makeEnvironment(root.appendingPathComponent("packs")),
                muteController: EventMuteController(configFile: configFile, lockFile: lockFile),
                afterFullReload: { _ in afterFullReloadCalls += 1 })

            controller.toggleMute(.stop)

            expect(
                afterFullReloadCalls == 0,
                "一次成功的静音走 .enabledFlagsOnly（轻量刷新），**不**该触发全量 reload 的 afterFullReload"
                    + " —— 触发了就是每点一次静音钮都在主线程上白扫整个包库 + 重探 onboarding。得到 "
                    + "\(afterFullReloadCalls) 次")
        }
    }

    // switchPack（同一条 config 写路径，一并从 PanelView 搬过来）：成功清 packSwitchError + 全量 reload；
    // 失败把 error 记进 packSwitchError，绝不丢弃（项目铁律：绝不静默吞错）。
    suite("PanelConfigController.switchPack 失败：error 必须记进 packSwitchError，不许静默丢弃") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(operationalConfigBytes, to: configFile)
            let controller = PanelConfigController(
                configFile: configFile, lockFile: lockFile,
                environment: makeEnvironment(root.appendingPathComponent("packs")),
                muteController: EventMuteController(configFile: configFile, lockFile: lockFile))

            // 切到一个磁盘上根本不存在的包 → selectPack 失败（.packNotFound / 校验拒绝）。
            controller.switchPack(to: "this-pack-does-not-exist")

            expect(
                controller.packSwitchError != nil,
                "一次失败的切包必须把 error 记进 packSwitchError（面板据此上报）—— 它是 nil = error 被"
                    + "静默丢弃了（旧代码 `if case .success = result { … }` 的老毛病）。得到 nil")
        }
    }
}
