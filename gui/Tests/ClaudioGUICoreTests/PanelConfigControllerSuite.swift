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
        durationProbe: StubDurationProbe(fixedDuration: 1.0),
        // 见 ``injectedPacksLock(under:)``。⚠️ 这一行的**理由在 e278736 之后变了**，别照抄旧说法：
        // 那之前 `packsLockFile` 有一个指向真实 `~/.claudio/packs.lock` 的默认值，漏掉它是**静默**
        // 的（测试全绿，锁开在用户 home 上）；现在那个默认值已经拆掉，漏掉是**编译错误**。
        // 所以这一行今天防的不再是「忘记」，而是「递错」——递 `ClaudioPaths.packsLockFile` 依旧会去
        // 用户机器上开真锁，只是那一种是**响**的（写下这一行的人知道自己在写什么，且它出现在 diff 里）。
        packsLockFile: injectedPacksLock(besideUserPacks: userPacksDirectory))
}

/// 一份良构、`.operational` 的 config.json（`selected_pack` 有效、`master_volume` 是数字、`events` 空
/// → 四个事件全 enabled）。写路径对它可安全重写，读路径判成 `.operational`。
private let operationalConfigBytes =
    #"{ "selected_pack": "minimal-chime", "master_volume": 0.42, "events": {} }"#

@MainActor
func runPanelConfigControllerSuites() {
    suite("PanelConfigController.selectedPackMetadata：当前包不在显示集时仍从该包 manifest 读到真名") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDir = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "selected_pack": "current-pack", "master_volume": 0.42, "events": {} }"#,
                to: configFile)
            writeFixture(
                #"{ "id": "current-pack", "name": "当前包真名", "events": {} }"#,
                to: packsDir.appendingPathComponent("current-pack/manifest.json"))
            writeFixture(
                #"{ "id": "starred-pack", "name": "面板显示包", "events": {} }"#,
                to: packsDir.appendingPathComponent("starred-pack/manifest.json"))

            let controller = PanelConfigController(
                configFile: configFile, lockFile: root.appendingPathComponent("config.lock"),
                environment: makeEnvironment(packsDir))

            // 模拟 T17 星标显示集：当前使用中的包未加星，所以显示集只剩另一行。
            let displayedCards = controller.packCards.filter { $0.id == "starred-pack" }
            expect(
                displayedCards.allSatisfy { !$0.isSelected },
                "前提：显示集中不得有当前包，否则这条测试没有覆盖『当前包未加星』")
            expect(
                controller.selectedPackMetadata.id == "current-pack",
                "selectedPackMetadata 必须绑定 config.selectedPack，不得从显示集反推")
            expect(
                controller.selectedPackMetadata.displayName == "当前包真名",
                "当前包不在显示集时仍必须从它自己的 manifest 读到真名，事件区标题与 header 才不会退化成 id")
        }
    }

    suite("SelectedPackMetadata.displayName：第三方包名压成单行并限制为 80 个 Character") {
        let metadata = SelectedPackMetadata(
            id: "fallback-pack",
            name: " \n 第一行\t第二行  " + String(repeating: "字", count: 100))
        let displayName = metadata.displayName

        expect(
            displayName.hasPrefix("第一行 第二行 "),
            "包名必须去掉首尾空白，并把换行、tab、连续空格统一压成一个空格；得到 \(displayName)")
        expect(
            !displayName.contains("\n") && !displayName.contains("\t")
                && !displayName.contains("  "),
            "进入标题和 VoiceOver 播报的包名必须是单行、无连续空白；得到 \(displayName)")
        expect(
            displayName.count == 80,
            "超长包名必须按 Swift Character 限制为 80 个；得到 \(displayName.count) 个")
        expect(
            displayName.last?.isWhitespace == false,
            "截断后的包名不得留下尾随空白；得到 \(displayName)")

        expect(
            SelectedPackMetadata(id: "fallback-pack", name: "\n \t ").displayName
                == "fallback-pack",
            "规范化后为空的 manifest name 必须继续回退到安全 pack id")
    }

    suite("SelectedPackMetadata.displayName：缺失 name 时回退 id 也必须单行化并截断") {
        let rawID = " \n fallback\tpack  " + String(repeating: "x", count: 100)
        let missingNameDisplay = SelectedPackMetadata(id: rawID, name: nil).displayName
        let blankNameDisplay = SelectedPackMetadata(id: rawID, name: "\n \t ").displayName

        for displayName in [missingNameDisplay, blankNameDisplay] {
            expect(
                displayName.hasPrefix("fallback pack "),
                "缺失或空白 name 的回退 id 必须折叠首尾、换行、tab 与连续空白；得到 \(displayName)")
            expect(
                !displayName.contains("\n") && !displayName.contains("\t")
                    && !displayName.contains("  "),
                "回退 id 进入标题和 VoiceOver 前也必须成为单行；得到 \(displayName)")
            expect(
                displayName.count == 80,
                "超长回退 id 也必须限制为 80 个 Character；得到 \(displayName.count) 个")
            expect(
                displayName.last?.isWhitespace == false,
                "截断后的回退 id 不得留下尾随空白；得到 \(displayName)")
        }
    }

    suite("SelectedPackMetadata.displayName：完整字素边界之外另限 256 个 Unicode 标量") {
        let family = "👨‍👩‍👧‍👦"
        let emojiDisplay = SelectedPackMetadata(
            id: "fallback-pack", name: String(repeating: family, count: 100)
        ).displayName
        expect(
            emojiDisplay.count <= 80,
            "组合 emoji 仍必须受 80 个 Character 上限约束；得到 \(emojiDisplay.count) 个")
        expect(
            emojiDisplay.unicodeScalars.count <= 256,
            "80 个复杂字素仍可能含大量标量，输出必须另受 256 标量上限约束；得到 "
                + "\(emojiDisplay.unicodeScalars.count) 个")
        expect(
            emojiDisplay.allSatisfy { $0 == "👨‍👩‍👧‍👦" },
            "标量预算必须在完整 Character 边界停止，不能拆开家庭 emoji；得到 \(emojiDisplay)")

        let oversizedCluster = "a" + String(repeating: "\u{0301}", count: 10_000)
        let manifestDisplay = SelectedPackMetadata(
            id: "fallback-pack", name: "Visible " + oversizedCluster
        ).displayName
        expect(
            manifestDisplay == "Visible",
            "单个超预算字素簇必须整体拒绝，且不得留下它前面的待定空格；得到 "
                + "\(manifestDisplay.unicodeScalars.count) 个标量")

        let fallbackDisplay = SelectedPackMetadata(id: oversizedCluster, name: nil).displayName
        expect(
            fallbackDisplay.unicodeScalars.count <= 256,
            "回退 id 自身是超大组合字素簇时也不得绕过标量上限；得到 "
                + "\(fallbackDisplay.unicodeScalars.count) 个")
    }

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

    // toggleMute 成功、**真包**、toggle 的是 .notification（不是 .stop）—— 红队 round4 逮到的两条零覆盖。
    // 上面那条成功测试有两个盲区：① 它 toggle 的永远是 .stop（全仓每处 toggleMute 都喂 .stop），于是把写者
    // 劫持成 `setEnabled(.stop, ...)` 对 .stop 恒等、对别的事件写错位，没人逮；② 它用空 packs 目录，coverage
    // 一律 .unmapped，于是 reloadEnabledFlags 里「coverage 原样带过来」这行改成 `.broken` 也看不出来。
    // 这条用一份**真包**（映了 stop + notification，两行都 .present）+ toggle .notification 同时钉死两样。
    suite("PanelConfigController.toggleMute 成功（真包）：翻**对**事件的位、不碰别的事件、coverage 原样带过（红队 round4）") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let packsDir = root.appendingPathComponent("packs")
            // 真包：stop + notification 都映到存在的文件 → 两行覆盖都是 .present（不是空 packs 的 .unmapped）。
            writeFixture(
                #"{ "selected_pack": "real-pack", "master_volume": 0.42, "events": {} }"#, to: configFile)
            writeFixture(
                #"{ "id": "real-pack", "events": { "stop": "stop.mp3", "notification": "notif.mp3" } }"#,
                to: packsDir.appendingPathComponent("real-pack/manifest.json"))
            writeFixture("audio", to: packsDir.appendingPathComponent("real-pack/stop.mp3"))
            writeFixture("audio", to: packsDir.appendingPathComponent("real-pack/notif.mp3"))
            let controller = PanelConfigController(
                configFile: configFile, lockFile: lockFile, environment: makeEnvironment(packsDir))

            // 前提：两事件都 enabled，两行覆盖都 .present。
            expect(controller.config.isEnabled(.stop) && controller.config.isEnabled(.notification),
                "前提：stop 与 notification 初始都必须 enabled")
            for event in [Event.stop, Event.notification] {
                if case .present = controller.eventRows.first(where: { $0.event == event })?.coverage {} else {
                    expect(false, "前提：\(event) 那行初始覆盖必须是 .present（真包映了它），得到 "
                        + "\(String(describing: controller.eventRows.first(where: { $0.event == event })?.coverage))")
                }
            }

            controller.toggleMute(.notification)  // ← 故意不是 .stop
            let onDisk = loadPanelConfig(from: configFile).resolvedConfig

            // ① 翻**对**事件：notification 的位必须翻成 false。把写者劫持成 `setEnabled(.stop, ...)` → 磁盘上
            //    notification 仍 true（错位写去了 stop）→ 这条红。
            expect(
                onDisk.isEnabled(.notification) == false,
                "toggleMute(.notification) 必须把 **notification** 的位翻成 disabled 并落盘 —— 它还 enabled = "
                    + "写者把事件参数劫持成了别的事件（红队实测：setEnabled(.stop,...)）。得到 isEnabled(.notification)="
                    + "\(onDisk.isEnabled(.notification))")
            // ② 不碰别的事件：stop 的位必须**原样不动**（还是 enabled）。劫持成 .stop → stop 被翻成 false → 这条红。
            expect(
                onDisk.isEnabled(.stop) == true,
                "toggleMute(.notification) **绝不能**碰 stop 的位 —— stop 变了 = 写者写错了事件（点 notification "
                    + "的静音钮却静音了 stop）。得到 isEnabled(.stop)=\(onDisk.isEnabled(.stop))")

            // ③ coverage 原样带过：轻量刷新（reloadEnabledFlags）只该翻 enabled 位，**不该动 coverage**
            //    （文档承诺「coverage 按定义不变」）。把 `coverage: row.coverage` 改成 `.broken(...)` → 两行覆盖
            //    都被谎报成 .broken（试听键被禁用、徽标错）→ 这两条红。
            for event in [Event.stop, Event.notification] {
                if case .present = controller.eventRows.first(where: { $0.event == event })?.coverage {} else {
                    expect(false, "一次静音之后 \(event) 那行覆盖必须**原样**还是 .present —— 它变了 = "
                        + "reloadEnabledFlags 没把 coverage 原样带过来（红队实测：改成 .broken）。整列事件行的"
                        + "覆盖态谎报成打包错误、试听键被禁用。得到 "
                        + "\(String(describing: controller.eventRows.first(where: { $0.event == event })?.coverage))")
                }
            }

            // ④ eventRows.enabled 的**两个方向**都钉（红队 round5）：被 toggle 的 .notification 那行读模型必须
            //    是 disabled，**没被碰的 .stop 那行必须原样 enabled**。上面 ① 查的是**磁盘**（onDisk.isEnabled），
            //    这里查的是**读模型**（eventRows.enabled，面板真正渲染的那个位）——两条正交。红队实测：把
            //    reloadEnabledFlags 的 `enabled: config.isEnabled(row.event)` 改成常量 `false`，磁盘/config 全对、
            //    但 eventRows 里**四行全变 muted 外观** → 点一个静音钮、面板谎报「全部静音」。而此前所有 toggleMute
            //    测试只往 true→false 一个方向翻，常量 false 从「本应保持 enabled」这个方向的盲区溜过。
            expect(
                controller.eventRows.first(where: { $0.event == .notification })?.enabled == false,
                "被 toggle 的 .notification 那行读模型 enabled 必须是 false。得到 "
                    + "\(String(describing: controller.eventRows.first(where: { $0.event == .notification })?.enabled))")
            expect(
                controller.eventRows.first(where: { $0.event == .stop })?.enabled == true,
                "**没被碰**的 .stop 那行读模型 enabled 必须**原样还是 true** —— 它变 false = reloadEnabledFlags 把"
                    + "非目标行的 enabled 也算错了（红队实测：常量 false → 点一个静音、面板四行全显示 muted）。"
                    + "得到 \(String(describing: controller.eventRows.first(where: { $0.event == .stop })?.enabled))")
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

    suite("PanelConfigController.reloadConfigOnly 遇到外部切包：升级为全量重载并 retarget 到新包") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDir = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "selected_pack": "pack-a", "master_volume": 0.42, "events": {}, "starred_packs": ["pack-a", "pack-b"] }"#,
                to: configFile)
            writeFixture(
                #"{ "id": "pack-a", "name": "包 A", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("pack-a/manifest.json"))
            writeFixture("audio", to: packsDir.appendingPathComponent("pack-a/stop.mp3"))
            writeFixture(
                #"{ "id": "pack-b", "name": "包 B", "events": { "notification": "notification.mp3" } }"#,
                to: packsDir.appendingPathComponent("pack-b/manifest.json"))
            writeFixture(
                "audio", to: packsDir.appendingPathComponent("pack-b/notification.mp3"))

            var afterFullReloadConfigs: [ClaudioConfig] = []
            let controller = PanelConfigController(
                configFile: configFile, lockFile: root.appendingPathComponent("config.lock"),
                environment: makeEnvironment(packsDir),
                afterFullReload: { afterFullReloadConfigs.append($0) })

            if case .present = controller.eventRows.first(where: { $0.event == .stop })?.coverage {
                // 前提成立：旧读模型确实属于 pack-a。
            } else {
                expect(false, "前提：pack-a 的 stop 必须是 .present")
            }
            expect(
                controller.packCards.first(where: { $0.isSelected })?.id == "pack-a",
                "前提：画廊初始必须选中 pack-a")

            // 模拟 CLI / 第二个实例在本实例一次轻量刷新前把 selected_pack 从 A 改为 B。
            writeFixture(
                #"{ "selected_pack": "pack-b", "master_volume": 0.42, "events": {}, "starred_packs": ["pack-a", "pack-b"] }"#,
                to: configFile)
            controller.reloadConfigOnly()

            expect(
                controller.config.selectedPack == "pack-b"
                    && controller.selectedPackMetadata.id == "pack-b"
                    && controller.selectedPackMetadata.displayName == "包 B",
                "外部切包后 config 与标题元数据必须共同指向 pack-b；得到 "
                    + "\(controller.config.selectedPack) / \(controller.selectedPackMetadata)")
            let notificationCoverage =
                controller.eventRows.first(where: { $0.event == .notification })?.coverage
            if case .present = notificationCoverage {
                // 新包覆盖已重算。
            } else {
                expect(
                    false,
                    "外部切到 pack-b 后 notification 必须按新 manifest 重算成 .present；得到 "
                        + "\(String(describing: notificationCoverage))")
            }
            if case .present =
                controller.eventRows.first(where: { $0.event == .stop })?.coverage
            {
                expect(false, "外部切到不映 stop 的 pack-b 后，stop 不得继续保留 pack-a 的 .present")
            }
            expect(
                controller.packCards.first(where: { $0.isSelected })?.id == "pack-b",
                "外部切包后画廊高亮必须重算为 pack-b，不能继续显示 pack-a")
            expect(
                afterFullReloadConfigs.map(\.selectedPack) == ["pack-b"],
                "检测到 selected_pack 变化后必须恰好执行一次 afterFullReload(pack-b)，让 drop zone 与"
                    + "每行 import view-model retarget 到真实编辑目标；得到 "
                    + "\(afterFullReloadConfigs.map(\.selectedPack))")
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

            // 构造后、**任何 switchPack 之前**：packSwitchError 必须是 nil（红队 round5）。
            // 这是六个 @Published 里唯一 init 值此前无断言守的（muteError 的 init nil 有断言、packSwitchError
            // 没有），而它比 packCards 危险：reload() **从不清** packSwitchError（只有成功 switchPack 清），
            // 所以 init 若非 nil，一条假的「切包失败」红字会**穿过每一次 popover 重开 / reload 存活**，直到
            // 用户碰巧成功切一次包。红队实测：把 init 的 `packSwitchError = nil` 改成 `.lockBusy`，下面每条
            // 断言都恒过（它们全在至少一次 switchPack 之后读），这条是唯一逮得住它的。
            expect(
                controller.packSwitchError == nil,
                "刚构造、还没切过任何包时 packSwitchError 必须是 nil —— 非 nil = 首次开面板就挂一条假的"
                    + "「切包失败」红字，且 reload 从不清它、会穿过每次重开存活。得到 "
                    + "\(String(describing: controller.packSwitchError))")

            // 切到一个磁盘上根本不存在的包 → selectPack 失败（.packNotFound / 校验拒绝）。
            controller.switchPack(to: "this-pack-does-not-exist")

            expect(
                controller.packSwitchError != nil,
                "一次失败的切包必须把 error 记进 packSwitchError（面板据此上报）—— 它是 nil = error 被"
                    + "静默丢弃了（旧代码 `if case .success = result { … }` 的老毛病）。得到 nil")
        }
    }

    // switchPack **成功**路径（红队 b86ec0a #1/#3/#5 + 红队 round3 packCards/eventRows）。一次成功切包
    // 走全量 `reload()`，它重算**五个** @Published 读模型（configState / config / eventRows /
    // packCards / selectedPackMetadata）
    // 外加清 packSwitchError + 跨-view-model 协调。这条测试把**每一个都断言到**——上一版只断言了 config/
    // configState，红队 round3 于是删掉 `packCards = availablePacks(...)`（画廊高亮停在旧包）与
    // `eventRows = packCoverage(...)`（事件行停在旧包覆盖）两条，测试照绿。
    //
    // 关键手法：pack-a 与 pack-b 的 manifest 映**不同的事件**（a→stop，b→notification），于是 eventRows
    // 的逐事件覆盖态在切包后**可观测地变了**（.stop 从 .present 掉成 .unmapped）——否则两个同构包切过去
    // eventRows 长得一样，删掉重算那行也看不出来。
    suite("PanelConfigController.switchPack 成功：reload 的全部五个读模型都反映新包 + 清错 + afterFullReload 收到新包") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let packsDir = root.appendingPathComponent("packs")
            // 初始 pack-a（映 stop）；磁盘上另有 pack-b（映 notification）。两包覆盖**不同**，好让 eventRows
            // 在切包后可观测地变化。两个都建真目录 + manifest，让 selectPack 的 resolvePackDirectory 放行。
            writeFixture(
                #"{ "selected_pack": "pack-a", "master_volume": 0.42, "events": {}, "starred_packs": ["pack-a", "pack-b"] }"#, to: configFile)
            writeFixture(
                #"{ "id": "pack-a", "name": "包 A", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("pack-a/manifest.json"))
            writeFixture("audio", to: packsDir.appendingPathComponent("pack-a/stop.mp3"))
            writeFixture(
                #"{ "id": "pack-b", "name": "包 B 真名", "events": { "notification": "notification.mp3" } }"#,
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

            // ⑥ 独立 selectedPackMetadata 也必须随全量 reload 走到新包，且从新包 manifest 读到真名。
            // 它不能靠 packCards 的 selected 行反推：T17 的星标显示集会合法地隐去当前包。
            expect(
                controller.selectedPackMetadata.id == "pack-b"
                    && controller.selectedPackMetadata.displayName == "包 B 真名",
                "成功切包后 selectedPackMetadata 必须重载成 pack-b 的真名，得到 "
                    + "\(controller.selectedPackMetadata)")

            // ⑦ afterFullReload 收到**重载后**的新 config（reload 两行对调 → 拿到旧 config pack-a → retarget 空操作 → 红）。
            expect(
                afterFullReloadConfigs.last?.selectedPack == "pack-b",
                "afterFullReload 必须收到重载后的 config（pack-b）—— 收到 pack-a = reload() 里 config 重载"
                    + "与 afterFullReload 顺序反了，retarget 打到旧包成空操作，后续拖拽/绑定落进旧包目录。"
                    + "得到 \(String(describing: afterFullReloadConfigs.last?.selectedPack))")
        }
    }

    // switchPack 失败 → .packNotFound → 全量刷新（.full）。这条此前只在 `PanelRefreshRouteSuite` 的纯函数
    // 层钉过（`packSwitchRefreshRoute(after: .packNotFound(...)) == .full`），从没在 controller 这一层被
    // 断言过：`switchPack` 的失败分支自己也有一个 `switch packSwitchRefreshRoute(after: error)`，
    // `.configOnly` / `.full` / `.noRefresh` 三条各调不同的刷新方法——而 `.full` 这一格从未单独被钉过
    // （上面「switchPack 失败：error 必须记进 packSwitchError」那条只查了 `packSwitchError != nil`，
    // 「switchPack 成功」那条虽然也调过一次 `.packNotFound`，但只用它当「制造一次失败」的前提，从没读过
    // 那一刻的 `afterFullReloadConfigs` 计数）。
    //
    // 覆盖率审计（本轮）实测：把 `switchPack` 失败分支里的 `case .full: reload()` 悄悄换成
    // `case .full: reloadConfigOnly()`，两套测试（gui 1779 条 + helper 1247 条）**全绿**——画廊上那张
    // 幽灵卡（切到一个磁盘上不存在的包）本该在下一次全量重扫时被抹掉，换成轻量刷新会让它继续挂在那儿，
    // 而没有任何断言逮到这一步。补上这条：钉死 `afterFullReloadCalls` 在这一格必须是 1（只有 `reload()`
    // 会调 `afterFullReload`，`reloadConfigOnly()` 不会）。
    suite(
        "PanelConfigController.switchPack 失败（.packNotFound）：必须走全量 .full（afterFullReload 被调），"
            + "不是轻量 .configOnly（覆盖率审计：mutation-tested 逮到的活缺口）"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let packsDir = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "selected_pack": "pack-a", "master_volume": 0.42, "events": {} }"#, to: configFile)
            writeFixture(
                #"{ "id": "pack-a", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("pack-a/manifest.json"))
            writeFixture("audio", to: packsDir.appendingPathComponent("pack-a/stop.mp3"))

            var afterFullReloadCalls = 0
            let controller = PanelConfigController(
                configFile: configFile, lockFile: lockFile, environment: makeEnvironment(packsDir),
                afterFullReload: { _ in afterFullReloadCalls += 1 })
            guard case .operational = controller.configState else {
                expect(false, "test setup：面板必须先以 .operational 打开，得到 \(controller.configState)")
                return
            }

            // 切到一个磁盘上真的不存在的包 —— selectPack 拒在 .packNotFound（不是校验层的 .invalidPackID：
            // 这个 id 是一个普通字符串，不空、不是 . / ..、不含路径分隔符）。
            controller.switchPack(to: "ghost-pack-not-on-disk")

            guard case .packNotFound = controller.packSwitchError else {
                expect(
                    false,
                    "test setup：这个包 id 必须真的解析不出目录，落在 .packNotFound，而不是别的失败 —— "
                        + "得到 \(String(describing: controller.packSwitchError))")
                return
            }
            expect(
                afterFullReloadCalls == 1,
                ".packNotFound 必须触发**全量** reload()（afterFullReload 被调一次）—— 画廊里挂着一张"
                    + "幽灵卡，只有全量重扫包库才能让它消失。走了轻量 .configOnly，afterFullReload 会是"
                    + "0 次；得到 \(afterFullReloadCalls) 次（mutation-tested：把这一格的 `reload()` 换成 "
                    + "`reloadConfigOnly()`，此前两套测试合计 3026 条全绿）")
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

    // ══ `/codex review` 两条 [P1]：诚实失败态没有接到**用户操作**这条 shipping 路径 ══════════════
    //
    // `.malformed` / `.unwritable` 这两个诚实失败态，此前**只**在 init 和全量 reload 里算得出来。而面板
    // 打开之后 config 被外部改坏时，唯一会撞上它的两条路 —— 点静音、点包卡 —— 都不 reload：
    //
    //   - 静音：`panelRefreshRoute` 把 `.configReadFailure` 判成 `.noRefresh`（理由是「config.json 原封
    //     未动」—— 那句话把「**我们**没写」偷换成了「**文件**没变」）。
    //   - 切包：失败分支只 `packSwitchError = error`，压根没有路由。
    //
    // 于是 `configState` 停在 `.operational`，面板一边用红字说「config.json 读取失败」，一边继续渲染四行
    // 活控件 —— 直到用户重开 popover 才自愈。
    //
    // ⚠️ **第一刀（1c65215）把同一个偷换概念原样犯了一遍**：它把 `.lockFailed` 也留在了「跳过」那一侧，
    // 理由同样是「锁都没拿到 ⇒ config.json 没被碰 ⇒ 读模型没变陈」。可读模型是**两根轴**（内容 + 目录
    // 可写性），而 `.lockFailed(EACCES)` 正是第二根轴出事时拿到的东西。[P1-d] 就是钉它的。
    //
    // 刷**哪一种**也跟着定稿了：这些失败一律走 `.configOnly`（重读 config.json + 目录探针），**不**走
    // `.full` —— config 坏了跟包库有没有变没有半点关系，全量刷新只会白扫一遍包库，还会拿一份 selectedPack
    // 为空的 config 去 `afterFullReload` retarget（污染 drop zone、抹掉画廊的选中卡高亮）。所以下面每条
    // 正钉都**同时**断言两件事：configState 真的翻到了诚实失败态（= 刷新真的跑了），且 afterFullReload
    // **一次都没被调**（= 没有白扫包库）。
    //
    // ⚠️ 反向对照为什么要在磁盘上放一份**坏** config：如果只是「持锁 + 好 config」，那么「configState 仍是
    // `.operational`」是**恒真**的 —— 一次刷新也会算出 `.operational`，断言区分不出刷新跑没跑。
    // 放一份坏 config，`.operational` 就只有在**确实没刷新**时才可能留住，断言这才真的在测东西。

    suite("[P1-a] toggleMute 撞上被外部改坏的 config：configState 必须翻到 .malformed") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(operationalConfigBytes, to: configFile)
            var afterFullReloadCalls = 0
            let controller = PanelConfigController(
                configFile: configFile, lockFile: lockFile,
                environment: makeEnvironment(root.appendingPathComponent("packs")),
                afterFullReload: { _ in afterFullReloadCalls += 1 })

            // 前提（不是背景板）：面板确实是以一份**有效** config 打开的。
            guard case .operational = controller.configState else {
                expect(false, "test setup：面板必须先以 .operational 打开，得到 \(controller.configState)")
                return
            }

            // 面板打开**之后**，外部（用户手改 / 同步工具 / 另一个进程）把它改坏：selected_pack 还读得动，
            // 但 master_volume 成了字符串 → 写路径拒写（D23 定稿②「读得动、写不动」）。
            writeFixture(
                #"{ "selected_pack": "minimal-chime", "master_volume": "loud" }"#, to: configFile)

            controller.toggleMute(.stop)

            guard case .configReadFailure = controller.muteError else {
                expect(
                    false,
                    "改坏的 config 必须让这次静音失败在 .configReadFailure 上（否则这条测试测的不是它自称"
                        + "在测的东西）。得到 \(String(describing: controller.muteError))")
                return
            }
            guard case .malformed(let reason) = controller.configState else {
                expect(
                    false,
                    "静音刚刚亲口承认 config.json 读不动，configState 却还停在 \(controller.configState)"
                        + " —— 面板会顶着四行活控件继续撒谎。必须翻到 .malformed，渲染诚实失败卡")
                return
            }
            expect(!reason.isEmpty, "诚实失败态必须带一条可行动的原因，得到空串")
            expect(
                afterFullReloadCalls == 0,
                "这条路必须走**轻量** .configOnly —— config 坏了跟包库有没有变没有半点关系。afterFullReload"
                    + " 被调了 \(afterFullReloadCalls) 次 = 走了 .full = 白扫一遍包库，还拿一份 selectedPack"
                    + "为空的 config 去 retarget（污染 drop zone、抹掉画廊选中卡高亮）")
        }
    }

    suite("[P1-b] switchPack 撞上被外部改坏的 config：configState 必须翻到 .malformed") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let packsDir = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "selected_pack": "pack-a", "master_volume": 0.42, "events": {} }"#, to: configFile)
            // 两个包都真的在磁盘上 —— 否则 selectPack 会停在 .packNotFound，这条测试就测不到 config 那一格。
            writeFixture(
                #"{ "id": "pack-a", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("pack-a/manifest.json"))
            writeFixture("audio", to: packsDir.appendingPathComponent("pack-a/stop.mp3"))
            writeFixture(
                #"{ "id": "pack-b", "events": { "notification": "notification.mp3" } }"#,
                to: packsDir.appendingPathComponent("pack-b/manifest.json"))
            writeFixture("audio", to: packsDir.appendingPathComponent("pack-b/notification.mp3"))

            var afterFullReloadCalls = 0
            let controller = PanelConfigController(
                configFile: configFile, lockFile: lockFile,
                environment: makeEnvironment(packsDir),
                afterFullReload: { _ in afterFullReloadCalls += 1 })

            guard case .operational = controller.configState else {
                expect(false, "test setup：面板必须先以 .operational 打开，得到 \(controller.configState)")
                return
            }

            writeFixture(#"{ "selected_pack": "pack-a", "master_volume": "loud" }"#, to: configFile)

            controller.switchPack(to: "pack-b")

            guard case .configReadFailure = controller.packSwitchError else {
                expect(
                    false,
                    "改坏的 config 必须让这次切包失败在 .configReadFailure 上（pack-b 真的在磁盘上，所以"
                        + "不该是 .packNotFound）。得到 \(String(describing: controller.packSwitchError))")
                return
            }
            guard case .malformed(let reason) = controller.configState else {
                expect(
                    false,
                    "切包刚刚亲口承认 config.json 读不动，configState 却还停在 \(controller.configState)"
                        + " —— 这正是 /codex review 第二条 [P1]：失败分支只记 error，从不 reload")
                return
            }
            expect(!reason.isEmpty, "诚实失败态必须带一条可行动的原因，得到空串")
            expect(
                afterFullReloadCalls == 0,
                "失败的切包同样只该走**轻量** .configOnly —— 一次**没成功**的切包不可能改变磁盘上有哪些包，"
                    + "重扫包库纯属白扫。afterFullReload 被调了 \(afterFullReloadCalls) 次 = 走了 .full。"
                    + "（`.packNotFound` 是唯一的例外，它由另一条 suite 守。）")
        }
    }

    suite("[P1-c] toggleMute 撞上写不动的目录：configState 必须翻到 .unwritable（不是 .malformed）") {
        guard geteuid() != 0 else {
            print("  ⚠︎ 跳过：当前以 root 运行，chmod 只读目录挡不住 root 写入")
            return
        }
        withTempDirectory { root in
            // config.json 和 config.lock 同住一个目录（生产里就是 ~/.claudio/）。lock 文件**先建出来**：
            // 生产里任何一次成功写盘都会留下它，而一个 r-x 目录里 open 一个**已存在**的文件仍然成功
            // （目录写权限管的是新建/删除条目，不是打开现有条目）—— 所以 flock 拿得到，失败会如实落在
            // 写那一步（.configWriteFailure），而不是提前变成 .lockFailed。
            let claudioDir = root.appendingPathComponent("claudio", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: claudioDir, withIntermediateDirectories: true)
            let configFile = claudioDir.appendingPathComponent("config.json")
            let lockFile = claudioDir.appendingPathComponent("config.lock")
            writeFixture(operationalConfigBytes, to: configFile)
            writeFixture("", to: lockFile)

            var afterFullReloadCalls = 0
            let controller = PanelConfigController(
                configFile: configFile, lockFile: lockFile,
                environment: makeEnvironment(root.appendingPathComponent("packs")),
                afterFullReload: { _ in afterFullReloadCalls += 1 })
            guard case .operational = controller.configState else {
                expect(false, "test setup：面板必须先以 .operational 打开，得到 \(controller.configState)")
                return
            }

            // 面板打开之后目录变成只读：内容还好好的，但原子写要在同目录落一个临时文件再 rename → 落不下去。
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o500], ofItemAtPath: claudioDir.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: claudioDir.path)
            }

            controller.toggleMute(.stop)

            // 红队实测点名：这条 suite 上一版**既不断言静音真的失败了、也不断言走了哪条刷新** —— 于是
            // 变异 M8（把刷新换成另一条）能从它身上完好无损地走过去。补上这两条，它才和两个兄弟一样硬。
            guard case .configWriteFailure = controller.muteError else {
                expect(
                    false,
                    "lock 文件**先建出来**了（生产里任何一次成功写盘都会留下它），r-x 目录里 open 一个**已存在**"
                        + "的文件仍然成功 → flock 拿得到 → 失败必须如实落在**写**那一步（.configWriteFailure），"
                        + "而不是提前变成 .lockFailed（那是 [P1-d] 守的另一格）。得到 "
                        + "\(String(describing: controller.muteError))")
                return
            }
            guard case .unwritable(let reason) = controller.configState else {
                expect(
                    false,
                    "内容合法但目录写不动，是一个**不同的**问题、一个**不同的**修法（chmod 目录，不是改"
                        + "文件）—— configState 必须落到 .unwritable。得到 \(controller.configState)")
                return
            }
            expect(
                reason.contains(claudioDir.path),
                "原因必须指名写不动的那个目录（用户照着它 chmod），得到 \(reason)")
            expect(
                afterFullReloadCalls == 0,
                "同样只该走轻量 .configOnly —— 目录写不动跟包库有没有变没关系。afterFullReload 被调了 "
                    + "\(afterFullReloadCalls) 次 = 走了 .full")
        }
    }

    // ── [P1-d] 第一刀（1c65215）自己漏掉的那一格：`.lockFailed` ──────────────────────────────────
    //
    // 第一刀把围栏内侧写成 `.lockBusy` / `.lockFailed`，理由是「锁都没拿到 ⇒ config.json 一个字节没读没写
    // ⇒ 读模型没变陈」。**这句话把「config.json 的字节」偷换成了「整个读模型」** —— 而 `PanelConfigState`
    // 是 `probeConfigRewritable` 的**两根轴**判定，第二根轴是**目录可写性**。同一个偷换概念，换了个 case
    // 原样复发在修它的那一刀上。
    //
    // 这条 fixture 与 [P1-c] 只差**一个字节**：[P1-c] 先把 config.lock 建出来（→ flock 成功 → 失败落在写
    // 那一步 → `.configWriteFailure`），这里**不建**（→ r-x 目录里 open(O_CREAT) 拿 EACCES → `.lockFailed`）。
    // 同一个物理局面（~/.claudio 写不动），只因为锁文件在不在，第一刀就把它分岔成了「诚实失败卡」和
    // 「假装没事」两种结局。而红字说的是「请稍后重试」—— 在目录权限变回来之前，重试**永远**不会成功。
    //
    // 「config.json 在、config.lock 不在」是真实可达的：锁文件是**惰性**创建的（0 字节，常被备份/同步工具
    // 跳过），用户看到「被占用」后手动 `rm ~/.claudio/*.lock` 也很自然。而只读卷（EROFS）连这个前提都不
    // 需要 —— 连**已存在**的锁文件都 open 不动，照样 `.lockFailed`。
    suite("[P1-d] toggleMute 撞上 .lockFailed（目录写不动、锁文件还没建出来）：configState 必须翻到 .unwritable") {
        guard geteuid() != 0 else {
            print("  ⚠︎ 跳过：当前以 root 运行，chmod 只读目录挡不住 root 写入")
            return
        }
        withTempDirectory { root in
            let claudioDir = root.appendingPathComponent("claudio", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: claudioDir, withIntermediateDirectories: true)
            let configFile = claudioDir.appendingPathComponent("config.json")
            let lockFile = claudioDir.appendingPathComponent("config.lock")
            writeFixture(operationalConfigBytes, to: configFile)
            // ⚠️ 与 [P1-c] 的唯一区别：**不**建 config.lock。

            var afterFullReloadCalls = 0
            let controller = PanelConfigController(
                configFile: configFile, lockFile: lockFile,
                environment: makeEnvironment(root.appendingPathComponent("packs")),
                afterFullReload: { _ in afterFullReloadCalls += 1 })
            guard case .operational = controller.configState else {
                expect(false, "test setup：面板必须先以 .operational 打开，得到 \(controller.configState)")
                return
            }

            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o500], ofItemAtPath: claudioDir.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: claudioDir.path)
            }

            controller.toggleMute(.stop)

            guard case .lockFailed = controller.muteError else {
                expect(
                    false,
                    "r-x 目录里 open(config.lock, O_CREAT) 必须拿 EACCES → .lockFailed（FileLock 只对 ENOENT"
                        + "自愈，其余 errno 直落 .failed）。不是这一格 = 这条测试测的不是它自称在测的东西。"
                        + "得到 \(String(describing: controller.muteError))")
                return
            }
            guard case .unwritable(let reason) = controller.configState else {
                expect(
                    false,
                    "静音刚刚因为「锁都建不出来」而失败，而此刻 loadPanelConfig 明明算得出 .unwritable + 一条"
                        + "精确的 chmod 指令 —— configState 却停在 \(controller.configState)。面板一边红字说"
                        + "「请稍后重试」（而重试永远不会成功），一边顶着四行活控件。这就是第一刀自己漏掉的"
                        + "那一格：`.lockFailed` 是一袋**未知** errno，它什么也证明不了，而围栏要的是"
                        + "「**证明没变**才敢不刷新」")
                return
            }
            expect(
                reason.contains(claudioDir.path),
                "原因必须指名写不动的那个目录（用户照着它 chmod），得到 \(reason)")
            expect(
                afterFullReloadCalls == 0,
                "只该走轻量 .configOnly —— 连锁都没拿到，包库更不可能变。afterFullReload 被调了 "
                    + "\(afterFullReloadCalls) 次 = 走了 .full")
        }
    }

    suite("[P1-d] switchPack 撞上 .lockFailed：同一格，另一条写路径") {
        guard geteuid() != 0 else {
            print("  ⚠︎ 跳过：当前以 root 运行，chmod 只读目录挡不住 root 写入")
            return
        }
        withTempDirectory { root in
            let claudioDir = root.appendingPathComponent("claudio", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: claudioDir, withIntermediateDirectories: true)
            let configFile = claudioDir.appendingPathComponent("config.json")
            let lockFile = claudioDir.appendingPathComponent("config.lock")
            let packsDir = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "selected_pack": "pack-a", "master_volume": 0.42, "events": {} }"#, to: configFile)
            // pack-b 真的在磁盘上 —— 否则 selectPack 会提前停在 .packNotFound（那一格**该**走 .full），
            // 这条测试就测不到锁那一步了。
            writeFixture(
                #"{ "id": "pack-a", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("pack-a/manifest.json"))
            writeFixture("audio", to: packsDir.appendingPathComponent("pack-a/stop.mp3"))
            writeFixture(
                #"{ "id": "pack-b", "events": { "notification": "notification.mp3" } }"#,
                to: packsDir.appendingPathComponent("pack-b/manifest.json"))
            writeFixture("audio", to: packsDir.appendingPathComponent("pack-b/notification.mp3"))

            var afterFullReloadCalls = 0
            let controller = PanelConfigController(
                configFile: configFile, lockFile: lockFile, environment: makeEnvironment(packsDir),
                afterFullReload: { _ in afterFullReloadCalls += 1 })
            guard case .operational = controller.configState else {
                expect(false, "test setup：面板必须先以 .operational 打开，得到 \(controller.configState)")
                return
            }

            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o500], ofItemAtPath: claudioDir.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: claudioDir.path)
            }

            controller.switchPack(to: "pack-b")

            guard case .lockFailed = controller.packSwitchError else {
                expect(
                    false,
                    "pack-b 真的在磁盘上，所以不该是 .packNotFound；r-x 目录里建不出锁文件 → 必须是 "
                        + ".lockFailed。得到 \(String(describing: controller.packSwitchError))")
                return
            }
            guard case .unwritable(let reason) = controller.configState else {
                expect(
                    false,
                    "切包因为「锁都建不出来」而失败，configState 却停在 \(controller.configState) —— 与静音"
                        + "那一半同一个洞，两条写路径必须给出同一个答案")
                return
            }
            expect(
                reason.contains(claudioDir.path),
                "原因必须指名写不动的那个目录，得到 \(reason)")
            expect(
                afterFullReloadCalls == 0,
                "只该走轻量 .configOnly —— afterFullReload 被调了 \(afterFullReloadCalls) 次")
        }
    }

    // ── 反向对照：围栏的**内**侧不许被顺手拆掉 ────────────────────────────────────────────────
    //
    // 上面三条把「失败 → reload」钉死了。但一个偷懒的修法是「失败**一律** reload」—— 它能让上面三条全绿，
    // 代价是每一次锁竞争（并发的 `claudio use` 持着 config.lock）都在主线程上白扫一遍整个包库。
    // 下面两条就是逮它的：锁被别人持着时，`setEventEnabled` / `selectPack` 在**读 config 之前**就返回
    // `.lockBusy`（`withNonBlockingLock` 包在最外层，EventEnabled.swift:84）—— config.json 一个字节都没读，
    // 这次失败**什么也没揭示**，不许 reload。

    suite("[反向对照-a] toggleMute 撞上 .lockBusy：不许 reload —— 哪怕磁盘上那份 config 此刻是坏的") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(operationalConfigBytes, to: configFile)
            var afterFullReloadCalls = 0
            let controller = PanelConfigController(
                configFile: configFile, lockFile: lockFile,
                environment: makeEnvironment(root.appendingPathComponent("packs")),
                afterFullReload: { _ in afterFullReloadCalls += 1 })
            guard case .operational = controller.configState else {
                expect(false, "test setup：面板必须先以 .operational 打开，得到 \(controller.configState)")
                return
            }

            // 磁盘上此刻是一份**坏** config —— 这是这条断言不恒真的全部理由：任何一次 reload 都会把
            // configState 翻成 .malformed。它仍是 .operational，就**证明**了那次 reload 没有发生。
            writeFixture(
                #"{ "selected_pack": "minimal-chime", "master_volume": "loud" }"#, to: configFile)
            let holder = FileLock(path: lockFile.path)
            expect(holder.tryLock(), "test setup：holder 必须先拿到 config.lock")

            controller.toggleMute(.stop)
            holder.unlock()

            expect(
                controller.muteError == .lockBusy,
                "锁被持着时这次静音必须停在 .lockBusy（config.json 一个字节都没读）。得到 "
                    + "\(String(describing: controller.muteError))")
            expect(
                afterFullReloadCalls == 0,
                "一次锁竞争不许触发全库重扫 —— afterFullReload 被调了 \(afterFullReloadCalls) 次。"
                    + "「失败了就 reload，反正更安全」不是保守，是把每一次并发写变成一次主线程全库扫描")
            guard case .operational = controller.configState else {
                expect(
                    false,
                    "锁没拿到 = 什么也没揭示 = 读模型不比点击之前更陈，configState 必须原样不动。它变成了"
                        + " \(controller.configState) —— 说明失败分支无条件 reload 了（磁盘上那份坏 config"
                        + "正是它被读进来的证据）")
                return
            }
        }
    }

    suite("[反向对照-b] switchPack 撞上 .lockBusy：不许 reload —— 同上，坏 config 在盘上做证") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let packsDir = root.appendingPathComponent("packs")
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

            var afterFullReloadCalls = 0
            let controller = PanelConfigController(
                configFile: configFile, lockFile: lockFile, environment: makeEnvironment(packsDir),
                afterFullReload: { _ in afterFullReloadCalls += 1 })
            guard case .operational = controller.configState else {
                expect(false, "test setup：面板必须先以 .operational 打开，得到 \(controller.configState)")
                return
            }

            writeFixture(#"{ "selected_pack": "pack-a", "master_volume": "loud" }"#, to: configFile)
            let holder = FileLock(path: lockFile.path)
            expect(holder.tryLock(), "test setup：holder 必须先拿到 config.lock")

            controller.switchPack(to: "pack-b")
            holder.unlock()

            expect(
                controller.packSwitchError == .lockBusy,
                "锁被持着时这次切包必须停在 .lockBusy。得到 "
                    + "\(String(describing: controller.packSwitchError))")
            expect(
                afterFullReloadCalls == 0,
                "锁竞争的切包不许触发全库重扫 —— afterFullReload 被调了 \(afterFullReloadCalls) 次")
            guard case .operational = controller.configState else {
                expect(
                    false,
                    "锁没拿到 = 什么也没揭示，configState 必须原样不动。它变成了 \(controller.configState)"
                        + " —— 说明切包的失败分支无条件 reload 了")
                return
            }
        }
    }

    // /ship pre-landing review（testing specialist）：switchPack 的其他 suite 全部预先写好一份 config.json
    // 再构造 controller，从没有一条从 configFile **真的不存在**开始——也就是从没测过全新安装唯一的自救
    // 动作本身：configState 以 .needsPack 构造，用户在画廊里点第一张卡，switchPack 必须把 config.json
    // 从无到有建出来、并把全部四个读模型（configState/config/eventRows/packCards）连同 afterFullReload
    // 一起翻到位。底层 `selectPack` 的「凭空建 config」早被 helper 的 UseSuite 钉过，但 controller 这一层
    // 的接线——从 .needsPack 出发——此前一条断言都没有。
    suite(
        "PanelConfigController.switchPack 冷启动：configFile 从不存在开始（.needsPack）→ "
            + "首次选包必须把 configState/config/eventRows/packCards 全部翻到 .operational"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let packsDir = root.appendingPathComponent("packs")
            // 真包，映 stop —— 与 needsPack 的空包默认值（全 .unmapped）形成可观测对比。
            writeFixture(
                #"{ "id": "pack-a", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("pack-a/manifest.json"))
            writeFixture("audio", to: packsDir.appendingPathComponent("pack-a/stop.mp3"))
            // ⚠️ 刻意不写 configFile —— 这是全新安装的真实起点：hooks 装好、还没有人选过包。

            var afterFullReloadConfigs: [ClaudioConfig] = []
            let controller = PanelConfigController(
                configFile: configFile, lockFile: lockFile, environment: makeEnvironment(packsDir),
                afterFullReload: { afterFullReloadConfigs.append($0) })

            // 前提：真的冷启动 —— configState 必须是 .needsPack（面板此刻显示「先选包」空态卡）。
            guard case .needsPack = controller.configState else {
                expect(
                    false,
                    "test setup：configFile 不存在，controller 必须以 .needsPack 构造，得到 "
                        + "\(controller.configState)")
                return
            }
            expect(controller.config.selectedPack == "", "前提：resolvedConfig 必须是空包默认值")

            // 用户在画廊里点第一张卡 —— 全新安装唯一的自救动作。
            controller.switchPack(to: "pack-a")

            guard case .operational(let onDisk) = controller.configState else {
                expect(
                    false,
                    "首次选包之后 configState 必须翻到 .operational —— 它停在 \(controller.configState)，"
                        + "面板会在用户点了卡片之后继续显示「先选包」空态卡，看起来像点击毫无反应")
                return
            }
            expect(onDisk.selectedPack == "pack-a", "得到 \(onDisk.selectedPack)")
            expect(controller.config.selectedPack == "pack-a", "得到 \(controller.config.selectedPack)")
            expect(
                controller.packCards.isEmpty,
                "首次选中个人包不会隐式加星：没有 starred_packs 且没有内置默认时，面板列表必须保持零行")
            if case .present = controller.eventRows.first(where: { $0.event == .stop })?.coverage {
            } else {
                expect(
                    false,
                    "首次选包之后 stop 那行覆盖必须重算成 .present（真包映了它），得到 "
                        + "\(String(describing: controller.eventRows.first(where: { $0.event == .stop })?.coverage))"
                )
            }
            expect(
                afterFullReloadConfigs.last?.selectedPack == "pack-a",
                "afterFullReload 必须收到新建出的 config（onboarding 重探 + import view-model retarget 都要用它）"
            )
        }
    }

    // ══ setMasterVolume（PLAN-MASTER-VOLUME.md 阶段 D，D27/D43）：镜像 toggleMute 的形状 ══════════
    //
    // 写、republish 错误、按 masterVolumeRefreshRoute 路由刷新——与静音那一半同一份接线，同一批变异
    // 关注点（执行 / 可达性 / 翻转不适用于这里，但「写成功后读模型真的重算」「.configMissing 真的
    // 重路由到 .needsPack」「.lockBusy 不触发白扫」三条与静音那一半是同一个问题）。

    suite("PanelConfigController.setMasterVolume 成功：落盘 + 返回落地值 + 读模型走轻量刷新（D27）") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(operationalConfigBytes, to: configFile)
            var afterFullReloadCalls = 0
            let controller = PanelConfigController(
                configFile: configFile, lockFile: lockFile,
                environment: makeEnvironment(root.appendingPathComponent("packs")),
                afterFullReload: { _ in afterFullReloadCalls += 1 })

            let landed = controller.setMasterVolume(0.35)

            expect(landed == 0.35, "一次干净的写盘必须返回落地值，得到 \(String(describing: landed))")
            expect(controller.masterVolumeError == nil, "成功之后 masterVolumeError 必须是 nil")
            expect(
                controller.config.masterVolume == 0.35,
                "controller.config 必须反映刚落盘的新音量（reloadConfigOnly 重读了 config）——它停在旧值 ="
                    + "读模型没重算。得到 \(controller.config.masterVolume)")
            let onDisk = loadPanelConfig(from: configFile).resolvedConfig
            expect(onDisk.masterVolume == 0.35, "config.json 本身必须落盘新值，得到 \(onDisk.masterVolume)")
            expect(
                afterFullReloadCalls == 0,
                "一次成功的音量写盘走 .configOnly（轻量刷新），不该触发全量 reload 的 afterFullReload —— "
                    + "触发了就是每拖一次滑块都在主线程上白扫整个包库。得到 \(afterFullReloadCalls) 次")
        }
    }

    suite("PanelConfigController.setMasterVolume + config 缺失：.configMissing 全量重路由到 .needsPack（D43）") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(operationalConfigBytes, to: configFile)
            var afterFullReloadCalls = 0
            let controller = PanelConfigController(
                configFile: configFile, lockFile: lockFile,
                environment: makeEnvironment(root.appendingPathComponent("packs")),
                afterFullReload: { _ in afterFullReloadCalls += 1 })

            guard case .operational = controller.configState else {
                expect(false, "test setup：面板必须先以 .operational 打开，得到 \(controller.configState)")
                return
            }

            try? FileManager.default.removeItem(at: configFile)

            let landed = controller.setMasterVolume(0.5)

            expect(landed == nil, "config.json 被外部删掉后写盘必须失败，得到 \(String(describing: landed))")
            expect(
                controller.masterVolumeError == .configMissing,
                "得到 \(String(describing: controller.masterVolumeError))")
            guard case .needsPack = controller.configState else {
                expect(
                    false,
                    "config 被外部删掉后，一次音量写盘必须让 configState 翻到 .needsPack（全量 reload 重载了"
                        + "它）—— 它停在 \(controller.configState) = 面板会继续顶着一个不存在的滑块撒谎")
                return
            }
            expect(
                afterFullReloadCalls == 1,
                ".configMissing 必须触发全量 reload（afterFullReload 恰好一次），自救入口是画廊、必须新鲜。"
                    + "得到 \(afterFullReloadCalls) 次")
        }
    }

    suite("PanelConfigController.setMasterVolume 撞上 .lockBusy：不许 reload（可证明什么也没揭示）") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(operationalConfigBytes, to: configFile)
            var afterFullReloadCalls = 0
            let controller = PanelConfigController(
                configFile: configFile, lockFile: lockFile,
                environment: makeEnvironment(root.appendingPathComponent("packs")),
                afterFullReload: { _ in afterFullReloadCalls += 1 })
            guard case .operational = controller.configState else {
                expect(false, "test setup：面板必须先以 .operational 打开，得到 \(controller.configState)")
                return
            }

            // 磁盘上此刻是一份坏 config —— 这是这条断言不恒真的全部理由：任何一次 reload 都会把
            // configState 翻成 .malformed。它仍是 .operational，就证明了那次 reload 没有发生。
            writeFixture(#"{ "selected_pack": "minimal-chime", "master_volume": "loud" }"#, to: configFile)
            let holder = FileLock(path: lockFile.path)
            expect(holder.tryLock(), "test setup：holder 必须先拿到 config.lock")

            let landed = controller.setMasterVolume(0.5)
            holder.unlock()

            expect(landed == nil, "锁被持着时写盘必须失败")
            expect(
                controller.masterVolumeError == .lockBusy,
                "得到 \(String(describing: controller.masterVolumeError))")
            expect(
                afterFullReloadCalls == 0,
                "一次锁竞争不许触发任何刷新（连 configOnly 都不该）—— afterFullReload 被调了"
                    + " \(afterFullReloadCalls) 次")
            guard case .operational = controller.configState else {
                expect(
                    false,
                    "锁没拿到 = 什么也没揭示，configState 必须原样不动。它变成了 \(controller.configState)")
                return
            }
        }
    }

    suite("PanelConfigController.setMasterVolume 撞上被外部改坏的 config：configState 翻到 .malformed（轻量刷新）") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(operationalConfigBytes, to: configFile)
            var afterFullReloadCalls = 0
            let controller = PanelConfigController(
                configFile: configFile, lockFile: lockFile,
                environment: makeEnvironment(root.appendingPathComponent("packs")),
                afterFullReload: { _ in afterFullReloadCalls += 1 })
            guard case .operational = controller.configState else {
                expect(false, "test setup：面板必须先以 .operational 打开，得到 \(controller.configState)")
                return
            }

            writeFixture(#"{ "selected_pack": "minimal-chime", "master_volume": "loud" }"#, to: configFile)

            let landed = controller.setMasterVolume(0.5)

            expect(landed == nil, "畸形 config 必须让写盘失败")
            guard case .configReadFailure = controller.masterVolumeError else {
                expect(
                    false,
                    "得到 \(String(describing: controller.masterVolumeError))")
                return
            }
            guard case .malformed(let reason) = controller.configState else {
                expect(
                    false,
                    "写盘刚刚亲口承认 config.json 读不动，configState 却还停在 \(controller.configState)"
                        + " —— 面板会顶着一个假装能用的滑块继续撒谎")
                return
            }
            expect(!reason.isEmpty, "诚实失败态必须带一条可行动的原因，得到空串")
            expect(
                afterFullReloadCalls == 0,
                "这条路必须走轻量 .configOnly —— config 坏了跟包库有没有变没有半点关系。afterFullReload"
                    + " 被调了 \(afterFullReloadCalls) 次")
        }
    }

    suite("PanelConfigController.setMasterVolume 成功：清掉上一次失败留下的 masterVolumeError（不许旧红字残留）") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(operationalConfigBytes, to: configFile)
            let controller = PanelConfigController(
                configFile: configFile, lockFile: lockFile,
                environment: makeEnvironment(root.appendingPathComponent("packs")))

            // ① 先真的造出一次失败 —— 这一步是整条用例的支点，不是背景铺垫。
            //
            // 上一版从一个干净的 controller 直接写一次成功，然后断言 masterVolumeError == nil：
            // 它测的是 nil → nil，而 `masterVolumeError` 从 init（:105）起本来就是 nil。变异体
            // 「`masterVolumeError = masterVolumeController.lastError` 改成 `if let e = …lastError
            // { masterVolumeError = e }`」—— 即成功时压根不清错、只在失败时写 —— 实测**存活**，
            // 1973 checks 全绿（/codex review 8771946 P1）。标题声称防的「旧红字残留」，恰恰是那个
            // 变异体制造的真 bug，而旧用例一个字也测不到它：它从没让红字存在过。
            let holder = FileLock(path: lockFile.path)
            expect(holder.tryLock(), "test setup：holder 必须先拿到 config.lock，否则下面这次写盘不会失败")
            _ = controller.setMasterVolume(0.2)
            holder.unlock()

            // ② 红字**真的在那儿** —— 没有这条断言，①「造失败」可能悄悄失效（比如 FileLock 语义变了），
            //    整条用例又会退回 nil → nil 的恒真形状而没人发现。
            expect(
                controller.masterVolumeError == .lockBusy,
                "test setup：这条用例要测的是「清掉一个真实存在的错误」，所以此刻必须真的有一个。"
                    + "得到 \(String(describing: controller.masterVolumeError))")

            // ③ 锁已放开 → 这次写盘成功，它必须把 ② 里那条红字清掉。
            let landed = controller.setMasterVolume(0.6)

            expect(landed == 0.6, "锁放开后这次写盘必须成功，得到 \(String(describing: landed))")
            expect(
                controller.masterVolumeError == nil,
                "一次成功写盘后 masterVolumeError 必须是 nil —— 非 nil = republish 没在成功时清错，上一次"
                    + "失败的红字会残留在一次成功操作之后。得到 \(String(describing: controller.masterVolumeError))")
        }
    }
}
