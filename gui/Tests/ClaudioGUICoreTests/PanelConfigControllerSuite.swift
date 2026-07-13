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
                environment: makeEnvironment(root.appendingPathComponent("packs")))

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
                environment: makeEnvironment(root.appendingPathComponent("packs")))

            // 切到一个磁盘上根本不存在的包 → selectPack 失败（.packNotFound / 校验拒绝）。
            controller.switchPack(to: "this-pack-does-not-exist")

            expect(
                controller.packSwitchError != nil,
                "一次失败的切包必须把 error 记进 packSwitchError（面板据此上报）—— 它是 nil = error 被"
                    + "静默丢弃了（旧代码 `if case .success = result { … }` 的老毛病）。得到 nil")
        }
    }

    // switchPack **成功**路径（红队 b86ec0a #1/#3/#5 + 红队 round3 packCards/eventRows）。一次成功切包
    // 走全量 `reload()`，它重算**四个** @Published 读模型（configState / config / eventRows / packCards）
    // 外加清 packSwitchError + 跨-view-model 协调。这条测试把**每一个都断言到**——上一版只断言了 config/
    // configState，红队 round3 于是删掉 `packCards = availablePacks(...)`（画廊高亮停在旧包）与
    // `eventRows = packCoverage(...)`（事件行停在旧包覆盖）两条，测试照绿。
    //
    // 关键手法：pack-a 与 pack-b 的 manifest 映**不同的事件**（a→stop，b→notification），于是 eventRows
    // 的逐事件覆盖态在切包后**可观测地变了**（.stop 从 .present 掉成 .unmapped）——否则两个同构包切过去
    // eventRows 长得一样，删掉重算那行也看不出来。
    suite("PanelConfigController.switchPack 成功：reload 的全部四个读模型都反映新包 + 清错 + afterFullReload 收到新包") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let packsDir = root.appendingPathComponent("packs")
            // 初始 pack-a（映 stop）；磁盘上另有 pack-b（映 notification）。两包覆盖**不同**，好让 eventRows
            // 在切包后可观测地变化。两个都建真目录 + manifest，让 selectPack 的 resolvePackDirectory 放行。
            writeFixture(
                #"{ "selected_pack": "pack-a", "master_volume": 0.42, "events": {} }"#, to: configFile)
            writeFixture(
                #"{ "id": "pack-a", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("pack-a/manifest.json"))
            writeFixture("audio", to: packsDir.appendingPathComponent("pack-a/stop.mp3"))
            writeFixture(
                #"{ "id": "pack-b", "events": { "notification": "notification.mp3" } }"#,
                to: packsDir.appendingPathComponent("pack-b/manifest.json"))
            writeFixture("audio", to: packsDir.appendingPathComponent("pack-b/notification.mp3"))

            var afterFullReloadConfigs: [ClaudioConfig] = []
            let controller = PanelConfigController(
                configFile: configFile, lockFile: lockFile,
                environment: makeEnvironment(packsDir),
                afterFullReload: { afterFullReloadConfigs.append($0) })

            // 前提：初始 pack-a 时 .stop 是 .present（manifest 映了它、文件在）。切到 pack-b 后它该变。
            if case .present = controller.eventRows.first(where: { $0.event == .stop })?.coverage {} else {
                expect(false, "前提：pack-a 下 .stop 覆盖必须是 .present，得到 "
                    + "\(String(describing: controller.eventRows.first(where: { $0.event == .stop })?.coverage))")
            }

            // 先制造一次失败，让 packSwitchError 非 nil（清错要观测的正是它随后被清）。
            controller.switchPack(to: "this-pack-does-not-exist")
            expect(
                controller.packSwitchError != nil,
                "前提：一次失败切包必须先把 packSwitchError 置上（否则下面『清错』无从观测）")

            // 成功切到 pack-b。
            controller.switchPack(to: "pack-b")

            // ① 清错：成功必须清掉上一次失败留下的旧错，否则假警报挂在换过包的面板上（删 `packSwitchError = nil` → 红）。
            expect(
                controller.packSwitchError == nil,
                "成功切包必须清掉上一次失败留下的 packSwitchError —— 它还在 = 假警报挂在换过包的面板上。"
                    + "得到 \(String(describing: controller.packSwitchError))")

            // ② config：reload 重读了刚写盘的 config（删成功分支 `reload()` → 停在 pack-a → 红）。
            expect(
                controller.config.selectedPack == "pack-b",
                "成功切包后 controller.config 必须是 pack-b。得到 \(controller.config.selectedPack)")

            // ③ configState：顶部路由据它渲染。
            guard case .operational(let onDisk) = controller.configState else {
                expect(false, "成功切包后 configState 必须是 .operational(pack-b)，得到 \(controller.configState)")
                return
            }
            expect(onDisk.selectedPack == "pack-b", "configState 里的 config 也必须是 pack-b，得到 \(onDisk.selectedPack)")

            // ④ eventRows：全量 reload 必须**重算**逐事件覆盖。pack-b 不映 .stop → .stop 掉成 .unmapped。
            // 删 `eventRows = packCoverage(...)` → eventRows 停在 pack-a 的 .stop=.present → 这条红。
            if case .present = controller.eventRows.first(where: { $0.event == .stop })?.coverage {
                expect(false, "切到 pack-b（不映 stop）后，.stop 那行覆盖必须重算成非 .present —— 它还是 "
                    + ".present = eventRows 没重算，事件行停在旧包 pack-a。")
            }

            // ⑤ packCards：画廊高亮据 isSelected（= id == config.selectedPack）。删 `packCards = availablePacks(...)`
            // → packCards 停在旧包 → 画廊仍把 pack-a 高亮成当前包 → 这条红。
            expect(
                controller.packCards.first(where: { $0.isSelected })?.id == "pack-b",
                "成功切包后画廊的『当前选中』必须是 pack-b —— 它还是 pack-a = packCards 没重算，画廊对"
                    + "『哪个是当前包』撒谎。得到 "
                    + "\(String(describing: controller.packCards.first(where: { $0.isSelected })?.id))")

            // ⑥ afterFullReload 收到**重载后**的新 config（reload 两行对调 → 拿到旧 config pack-a → retarget 空操作 → 红）。
            expect(
                afterFullReloadConfigs.last?.selectedPack == "pack-b",
                "afterFullReload 必须收到重载后的 config（pack-b）—— 收到 pack-a = reload() 里 config 重载"
                    + "与 afterFullReload 顺序反了，retarget 打到旧包成空操作，后续拖拽/绑定落进旧包目录。"
                    + "得到 \(String(describing: afterFullReloadConfigs.last?.selectedPack))")
        }
    }

    // muteError 的 republish（红队 round3：这行是 e49f0bc 新写的，此前零行为覆盖）。#2 的结构修复堵死了
    // 「注入第二个 muteController 实例」，但**堵不住把 republish 写成常量**：删掉
    // `muteError = muteController.lastError`（或写成 `= nil`）→ muteError 恒 nil → 真·静音失败（.lockBusy /
    // 读写失败）的红色 errorNotice 永不渲染 = 静默吞错从另一扇门复活。这条测试逼真·失败经 republish 上浮。
    //
    // 用一份**存在但畸形**的 config 触发一个**非 .configMissing** 的失败（.configMissing 会被面板故意滤掉、
    // 且走 .full 重路由，测不到 republish 该带的那类「要给用户看」的错误）——畸形 config 存在，静音写盘会
    // fail closed 成读失败，muteError 必须带上它。
    suite("PanelConfigController.toggleMute 真失败：muteError 必须把非 .configMissing 的错误 republish 上来（红队 round3）") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            // config.json 存在、但 master_volume 是字符串（读得动结构、写路径 fail closed）——静音写盘会
            // 失败成一个**非 .configMissing** 的错误（要给用户看的那类），不是「文件不存在」。
            writeFixture(
                #"{ "selected_pack": "minimal-chime", "master_volume": "oops", "events": {} }"#, to: configFile)
            let controller = PanelConfigController(
                configFile: configFile, lockFile: lockFile,
                environment: makeEnvironment(root.appendingPathComponent("packs")))

            expect(controller.muteError == nil, "前提：还没点过静音，muteError 必须是 nil")

            controller.toggleMute(.stop)

            // republish 必须把这次真失败带上来。删掉那行 / 写成 nil → muteError 恒 nil → 这条红。
            guard let surfaced = controller.muteError else {
                expect(false, "一次真·静音失败（畸形 config，非 .configMissing）后，muteError 必须非 nil —— "
                    + "它还是 nil = republish 那行被删/掏空，面板永不渲染 errorNotice = 静默吞错复活")
                return
            }
            // 且它必须是要给用户看的那类，不是被面板滤掉的 .configMissing。
            expect(
                surfaced != .configMissing,
                "muteError 带上来的必须是要给用户看的真错误（读/写/锁失败），不是被面板故意滤掉的 "
                    + ".configMissing —— 得到 \(surfaced)")
        }
    }

    // muteError 的另一半：一次**成功**静音必须把上一次失败留下的 muteError 清成 nil（否则旧红字残留）。
    suite("PanelConfigController.toggleMute 成功：muteError 必须被清成 nil（不许旧失败的红字残留）") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(operationalConfigBytes, to: configFile)
            let controller = PanelConfigController(
                configFile: configFile, lockFile: lockFile,
                environment: makeEnvironment(root.appendingPathComponent("packs")))

            controller.toggleMute(.stop)  // 成功（operational config）

            expect(
                controller.muteError == nil,
                "一次成功静音后 muteError 必须是 nil —— 非 nil = republish 没在成功时清错，上一次失败的红字"
                    + "会残留在一次成功操作之后。得到 \(String(describing: controller.muteError))")
        }
    }
}
