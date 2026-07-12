import ClaudioCore
import ClaudioGUICore
import Foundation

// MARK: - OnboardingViewModel: state + copy binding, transitions, CTA 执行（T7 + T17）

@MainActor
private func makeReadyEnvironment(in root: URL) -> OnboardingEnvironment {
    let claudeDirectory = root.appendingPathComponent("dot-claude", isDirectory: true)
    try? FileManager.default.createDirectory(
        at: claudeDirectory, withIntermediateDirectories: true)
    return OnboardingEnvironment(
        settingsFile: claudeDirectory.appendingPathComponent("settings.json"),
        // 字面 `.claudio` 分量（不是 `dot-claudio`）—— 见 `OnboardingActionsSuite` 文件头的硬
        // fixture 规则 2：`uninstallClaudioHooks` 的摘除锚点要求路径里真的有 `.claudio` 这一段，
        // 否则它 fail-closed 摘 0 条却返回 `.success`，断开测试会是一次假绿。
        claudioBinaryPath: root.appendingPathComponent(".claudio/bin/claudio"))
}

/// 一个可编排的 runner：记录被调用了什么、按剧本返回成功/失败、并且可以**真的挂起**。
///
/// 「真的挂起」不是装饰：view-model 的动作方法是 `async` 的，一个瞬时 fake 会在同一个调度回合里跑完，
/// 于是「in-flight 期间第二次点击真的被丢弃了吗」这类断言会**因为根本来不及观察而全绿**。挂起点让
/// harness 能停在动作中间。
///
/// `@unchecked Sendable`：`run` 全程 `@MainActor` 隔离，那些可变状态实际从不并发访问。
private final class ScriptedRunner: OnboardingActionRunning, @unchecked Sendable {
    private(set) var calls: [OnboardingDiskAction] = []
    var result: Result<OnboardingActionOutcome, OnboardingActionError> = .success(
        .disconnected(count: 4))
    var isGated = false
    private var gate: CheckedContinuation<Void, Never>?

    @MainActor
    func run(_ action: OnboardingDiskAction) async
        -> Result<OnboardingActionOutcome, OnboardingActionError>
    {
        calls.append(action)
        if isGated {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gate = continuation
            }
        }
        return result
    }

    @MainActor
    func openGate() {
        gate?.resume()
        gate = nil
    }
}

@MainActor
func runOnboardingViewModelSuites() async {
    suite("init: state matches detectOnboardingState(environment:) for the given fixture") {
        withTempDirectory { root in
            let environment = makeReadyEnvironment(in: root)  // binary not yet created
            let viewModel = OnboardingViewModel(
                environment: environment, actionRunner: ScriptedRunner())
            expect(
                viewModel.state == .helperMissing,
                "initial state must reflect detection against the injected environment, got \(viewModel.state)"
            )
        }
    }

    suite("copy always matches onboardingCopy(for: state) — never drifts, even across refreshes") {
        withTempDirectory { root in
            let environment = makeReadyEnvironment(in: root)
            let viewModel = OnboardingViewModel(
                environment: environment, actionRunner: ScriptedRunner())
            expect(
                viewModel.copy == onboardingCopy(for: viewModel.state),
                "copy must equal onboardingCopy(for: state) right after init")

            writeExecutableFile(at: environment.claudioBinaryPath)
            viewModel.refresh()
            expect(
                viewModel.state == .notInstalled,
                "sanity: refresh must have transitioned state, got \(viewModel.state)")
            expect(
                viewModel.copy == onboardingCopy(for: viewModel.state),
                "copy must still equal onboardingCopy(for: state) after refresh() changed state")
        }
    }

    suite("refresh(): re-detects against the current environment (state machine's transition rule)") {
        withTempDirectory { root in
            let environment = makeReadyEnvironment(in: root)
            let viewModel = OnboardingViewModel(
                environment: environment, actionRunner: ScriptedRunner())
            expect(viewModel.state == .helperMissing, "setup: must start as helperMissing")

            writeExecutableFile(at: environment.claudioBinaryPath)
            viewModel.refresh()
            expect(
                viewModel.state == .notInstalled,
                "refresh() must transition helperMissing -> notInstalled once the binary appears")

            let path = environment.claudioBinaryPath.path
            let entries = Event.allCases.map { event in
                #"""
                "\#(event.settingsName)": [ { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: event, claudioBinaryPath: path))" } ] } ]
                """#
            }.joined(separator: ",\n")
            writeFixture("{ \"hooks\": { \(entries) } }", to: environment.settingsFile)
            viewModel.refresh()
            expect(
                viewModel.state == .installed,
                "refresh() must transition notInstalled -> installed once the hook is fully present")
        }
    }

    // T17c：`environment` 现在是 `let`，「换一个环境」= 重建 view-model。
    //
    // 上一版这里有一条 suite 叫「refresh(): reflects a NEW environment if `environment` itself is
    // reassigned」—— 它测的是一条**逃生舱**，而那条逃生舱会当场打破 `OnboardingActionEnvironment`
    // 文档里白纸黑字的承诺（「『探测器在看哪个文件』和『安装器在写哪个文件』**结构上不可能分叉**」）：
    // runner 在 init 时就把自己那份环境**按值**冻住了，`viewModel.environment = …` 只换掉探测那一半，
    // 于是探测读路径 A、安装写路径 B，零编译错误、零红灯 —— 正是那句承诺声称已经消灭的形状。
    //
    // `refresh()` 真正的契约（「磁盘变了就得看见」）由上面那条 suite 覆盖，不需要可变的 environment。
    suite("换环境 = 重建 view-model（environment 是 let，探测与安装不可能只换一半）") {
        withTempDirectory { root in
            let firstEnvironment = makeReadyEnvironment(in: root)  // helperMissing
            let first = OnboardingViewModel(
                environment: firstEnvironment, actionRunner: ScriptedRunner())
            expect(first.state == .helperMissing, "setup: must start as helperMissing")

            // 一份完全不同的、已经装好的 fixture。
            let secondRoot = root.appendingPathComponent("second-fixture", isDirectory: true)
            let secondEnvironment = makeReadyEnvironment(in: secondRoot)
            writeExecutableFile(at: secondEnvironment.claudioBinaryPath)
            let path = secondEnvironment.claudioBinaryPath.path
            let entries = Event.allCases.map { event in
                #"""
                "\#(event.settingsName)": [ { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: event, claudioBinaryPath: path))" } ] } ]
                """#
            }.joined(separator: ",\n")
            writeFixture("{ \"hooks\": { \(entries) } }", to: secondEnvironment.settingsFile)

            let second = OnboardingViewModel(
                environment: secondEnvironment, actionRunner: ScriptedRunner())
            expect(
                second.state == .installed,
                "为新环境重建的 view-model 必须探测新环境")
            expect(
                first.state == .helperMissing,
                "旧的那个不受影响 —— 每个 view-model 与它的 runner 绑定在同一份环境上，终身不变")
        }
    }

    // MARK: - T17：CTA 真的会跑，失败真的会说出来

    await suite("performPrimaryAction(): .helperMissing 真的调用 runner 的 .takeOver，并在之后重新探测") {
        await withTempDirectory { root in
            let environment = makeReadyEnvironment(in: root)
            let runner = ScriptedRunner()
            let viewModel = OnboardingViewModel(environment: environment, actionRunner: runner)
            expect(viewModel.state == .helperMissing, "setup: must start as helperMissing")

            // runner「成功」之后磁盘上该有的样子（模拟 takeOver 的副作用）。
            writeExecutableFile(at: environment.claudioBinaryPath)

            await viewModel.performPrimaryAction()

            expect(
                runner.calls == [.takeOver],
                "「修复」必须真的跑一次 takeOver —— 这正是 T17 之前那个 no-op。得到 \(runner.calls)")
            expect(
                viewModel.state == .notInstalled,
                "动作跑完必须 refresh()，把新的磁盘事实读进来。得到 \(viewModel.state)")
            expect(viewModel.actionState == .idle, "成功之后不该留下任何错误")
        }
    }

    await suite("performPrimaryAction(): 失败必须变成 .failed，绝不静默") {
        await withTempDirectory { root in
            let environment = makeReadyEnvironment(in: root)
            let runner = ScriptedRunner()
            runner.result = .failure(.setupFailed(.installFailure(.notWritable(reason: "boom"))))
            let viewModel = OnboardingViewModel(environment: environment, actionRunner: runner)

            await viewModel.performPrimaryAction()

            guard case .failed(let action, let message, let detail) = viewModel.actionState else {
                expect(
                    false,
                    "失败必须落进 actionState —— 这个 codebase 已经被「写了但没有任何视图读」的静默失败"
                        + "咬过三次。得到 \(viewModel.actionState)")
                return
            }
            expect(!message.isEmpty, "必须有一句人话")
            expect(
                action == .takeOver,
                "失败必须记住**是哪个动作**失败的 —— 接管失败与断开失败渲染在面板的两个不同分支里，"
                    + "不带这个标签的话，一次接管失败会永久挂在一张后来装好了的面板底部。得到 \(action)")
            expect(
                detail?.contains("boom") == true,
                "工程原话必须留在 detail 里，否则用户永远查不出为什么。得到 \(String(describing: detail))")
            expect(!viewModel.isPerformingAction, "失败之后不该还卡在 in-flight")
        }
    }

    await suite("重入守卫：动作跑到一半时的点击被丢弃（否则两个 setup 抢同一把 play.lock）") {
        await withTempDirectory { root in
            let environment = makeReadyEnvironment(in: root)
            let runner = ScriptedRunner()
            runner.isGated = true
            let viewModel = OnboardingViewModel(environment: environment, actionRunner: runner)

            let first = Task { await viewModel.performPrimaryAction() }
            while runner.calls.isEmpty { await Task.yield() }  // 跑到挂起点
            expect(viewModel.isPerformingAction, "第一次点击之后必须处于 in-flight")
            expect(viewModel.isRunning(.takeOver), "spinner 该画在「接管 / 修复」那颗按钮上")

            await viewModel.performSecondaryAction()
            await viewModel.performPrimaryAction()
            expect(
                runner.calls == [.takeOver],
                "in-flight 期间的点击必须被丢弃 —— 两个 performFirstRunSetup 抢同一把 play.lock，其中一个"
                    + "必然拿到 .lockBusy，用户会看到一条**他自己制造出来的**假失败。得到 \(runner.calls)")

            runner.openGate()
            await first.value
            expect(!viewModel.isPerformingAction, "动作跑完必须退出 in-flight")
        }
    }

    await suite("「重新检测」一个字节都不写：runner 一次都不该被调用") {
        await withTempDirectory { root in
            let environment = makeReadyEnvironment(in: root)
            try? FileManager.default.removeItem(at: environment.claudeDirectory)  // Claude Code 没装
            let runner = ScriptedRunner()
            let viewModel = OnboardingViewModel(environment: environment, actionRunner: runner)
            expect(viewModel.state == .claudeCodeNotInstalled, "setup: 得到 \(viewModel.state)")

            await viewModel.performPrimaryAction()

            expect(
                runner.calls.isEmpty,
                "「重新检测」绝不能碰磁盘 —— 用户的配置坏了 / 没权限时，替他做主去改只会把一次诚实的报错"
                    + "换成一次静默的数据丢失。得到 \(runner.calls)")
            expect(viewModel.state == .claudeCodeNotInstalled, "磁盘没变，状态也不该变")
        }
    }

    await suite("「查看原因」只翻一个 flag —— 不碰磁盘，且判定在 view-model 里（不在 SwiftUI 里）") {
        await withTempDirectory { root in
            let environment = makeReadyEnvironment(in: root)
            writeExecutableFile(at: environment.claudioBinaryPath)
            writeFixture("{ not json", to: environment.settingsFile)  // → .settingsParseFailure
            let runner = ScriptedRunner()
            let viewModel = OnboardingViewModel(environment: environment, actionRunner: runner)
            guard case .settingsParseFailure = viewModel.state else {
                expect(false, "setup: 期望 .settingsParseFailure，得到 \(viewModel.state)")
                return
            }
            expect(!viewModel.isShowingDetail, "初始必须是收起的")

            await viewModel.performSecondaryAction()
            expect(viewModel.isShowingDetail, "「查看原因」必须展开 detail")
            expect(runner.calls.isEmpty, "「查看原因」绝不碰磁盘，得到 \(runner.calls)")

            await viewModel.performSecondaryAction()
            expect(!viewModel.isShowingDetail, "再点一次必须收起")
        }
    }

    await suite("断开：.installed 的次 CTA 真的调用 runner 的 .disconnect") {
        await withTempDirectory { root in
            let environment = makeReadyEnvironment(in: root)
            writeExecutableFile(at: environment.claudioBinaryPath)
            let path = environment.claudioBinaryPath.path
            let entries = Event.allCases.map { event in
                #"""
                "\#(event.settingsName)": [ { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: event, claudioBinaryPath: path))" } ] } ]
                """#
            }.joined(separator: ",\n")
            writeFixture("{ \"hooks\": { \(entries) } }", to: environment.settingsFile)

            let runner = ScriptedRunner()
            let viewModel = OnboardingViewModel(environment: environment, actionRunner: runner)
            expect(viewModel.state == .installed, "setup: 得到 \(viewModel.state)")

            // runner「成功」之后磁盘上该有的样子：hooks 真的没了。
            writeFixture("{ \"hooks\": {} }", to: environment.settingsFile)

            await viewModel.performSecondaryAction()

            expect(runner.calls == [.disconnect], "「断开连接」必须真的跑一次 disconnect，得到 \(runner.calls)")
            expect(viewModel.state == .notInstalled, "断开之后必须回落 .notInstalled，得到 \(viewModel.state)")
        }
    }

    #if DEBUG
        await suite("预览实例：点 CTA 完全不动作（不会把 pin 住的状态重新探测掉）") {
            let viewModel = OnboardingViewModel(previewState: .notInstalled)
            await viewModel.performPrimaryAction()
            expect(
                viewModel.state == .notInstalled,
                "画廊里 pin 死的状态必须纹丝不动 —— 此前 performPrimaryAction() 会走到 refresh()，对着"
                    + " /dev/null 占位环境重新探测，把它静默改写成 .claudeCodeNotInstalled，"
                    + "而那个 init 的 doc comment 一直声称「nothing in the gallery ever calls refresh()」。"
                    + "得到 \(viewModel.state)")
            expect(viewModel.actionState == .idle, "预览实例不该跑出任何动作态")
        }

        suite("预览实例：actionState 也能被 pin（state gallery 靠它渲染 in-flight / failed）") {
            let running = OnboardingViewModel(
                previewState: .notInstalled, actionState: .running(.takeOver))
            expect(running.isPerformingAction, "pin 成 .running 必须表现为 in-flight")
            expect(running.isRunning(.takeOver), "spinner 该画在主 CTA 上")
            expect(!running.isRunning(.disconnect), "断开那颗不该转")

            let failed = OnboardingViewModel(
                previewState: .notInstalled,
                actionState: .failed(action: .takeOver, message: "m", detail: "d"))
            expect(!failed.isPerformingAction, "pin 成 .failed 不是 in-flight")
        }
    #endif
}

// MARK: - T17 修复批：toggleDetail 是一个独立入口（复用次 CTA 会再跑一次断开）

@MainActor
func runOnboardingViewModelDetailSuites() async {
    await suite("toggleDetail(): .installed 下展开断开失败的原因，绝不再跑一次断开") {
        await withTempDirectory { root in
            let claudeDirectory = root.appendingPathComponent("dot-claude", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: claudeDirectory, withIntermediateDirectories: true)
            let environment = OnboardingEnvironment(
                settingsFile: claudeDirectory.appendingPathComponent("settings.json"),
                claudioBinaryPath: root.appendingPathComponent(".claudio/bin/claudio"))
            writeExecutableFile(at: environment.claudioBinaryPath)
            let path = environment.claudioBinaryPath.path
            let entries = Event.allCases.map { event in
                #"""
                "\#(event.settingsName)": [ { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: event, claudioBinaryPath: path))" } ] } ]
                """#
            }.joined(separator: ",\n")
            writeFixture("{ \"hooks\": { \(entries) } }", to: environment.settingsFile)

            let runner = ScriptedRunner()
            runner.result = .failure(.disconnectFailed(.lockBusy))
            let viewModel = OnboardingViewModel(environment: environment, actionRunner: runner)
            expect(viewModel.state == .installed, "setup: 得到 \(viewModel.state)")

            await viewModel.performSecondaryAction()  // 断开 → 失败
            guard case .failed(let action, _, let detail) = viewModel.actionState else {
                expect(false, "断开必须失败，得到 \(viewModel.actionState)")
                return
            }
            expect(action == .disconnect, "失败必须记住是断开失败的，得到 \(action)")
            expect(detail?.isEmpty == false, "锁被占用这条必须带上可执行的 detail（「请稍后重试」）")
            expect(!viewModel.isShowingDetail, "初始收起")

            viewModel.toggleDetail()
            expect(viewModel.isShowingDetail, "「查看原因」必须能展开")
            expect(
                runner.calls == [.disconnect],
                "toggleDetail() 绝不能再跑一次断开 —— 这正是为什么它不能复用 performSecondaryAction()："
                    + "在 .installed 下那个 intent 是 .disconnect。得到 \(runner.calls)")

            viewModel.toggleDetail()
            expect(!viewModel.isShowingDetail, "再点一次收起")
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// T17d —— 失败的**寿命**（第四轮对抗评审 · Codex 独立发现）
//
// 上一版 `clearConsumedFailure()` 在整套 harness 里**一次都没被调用过**：它唯一的守卫是
// `ViewWiringSuite` 的一条文本绊线（「PanelView 里还有没有这个字符串」）。于是「面板重开 =
// 上一条失败已经被用户看过了」这个假定从来没有被任何一条断言检验过 —— 而它在最要命的那条
// 路径上是假的。下面这几条就是它欠的那些测试。
// ═══════════════════════════════════════════════════════════════════════════════

@MainActor
func runOnboardingFailureLifecycleSuites() async {
    /// 一个必定失败的 runner —— 复用现有失败 suite 的那条剧本。
    func makeFailingRunner() -> ScriptedRunner {
        let runner = ScriptedRunner()
        runner.result = .failure(.setupFailed(.installFailure(.notWritable(reason: "boom"))))
        return runner
    }

    await suite(
        "T17d【静默失败回归】面板关着时诞生的失败，下一次打开必须**露面**，绝不能被当成「看过了」清掉"
    ) {
        await withTempDirectory { root in
            let environment = makeReadyEnvironment(in: root)
            let viewModel = OnboardingViewModel(
                environment: environment, actionRunner: makeFailingRunner())

            // 真实时序，一步不省：
            // ① 用户打开面板
            viewModel.panelDidBecomeVisible()
            // ② 点「修复」；在几百毫秒的复制 + flock 期间…
            // ③ …他点到别的 app 上 —— `.transient` popover 当场关闭
            viewModel.panelDidHide()
            // ④ 而那个 `Task` 不随视图销毁而取消：它继续跑完，然后失败
            await viewModel.performPrimaryAction()

            guard case .failed = viewModel.actionState else {
                expect(false, "前提：这次动作必须失败，得到 \(viewModel.actionState)")
                return
            }
            expect(
                !viewModel.failureHasBeenSeen,
                "失败诞生在一块没人看的屏幕上 —— 它不该被标记成「看过了」")

            // ⑤ 用户回来，重新打开面板。**这是整个 bug 的那一刻。**
            viewModel.panelDidBecomeVisible()

            guard case .failed = viewModel.actionState else {
                expect(
                    false,
                    "❌ 静默失败复活了：一条从未渲染过的失败在用户第一次有机会看到它之前就被清掉了。"
                        + "用户点了「修复」、切走、回来，面板一切如常 —— 而接管其实失败了，"
                        + "他永远不会知道。得到 \(viewModel.actionState)")
                return
            }
            expect(
                viewModel.failureHasBeenSeen,
                "这一次打开就是它的第一次露面 —— 从现在起才算「看过」")
        }
    }

    await suite("T17d：露过一次面之后，下一次打开才把它忘掉（T17c 的「陈旧失败」顾虑仍然兑现）") {
        await withTempDirectory { root in
            let environment = makeReadyEnvironment(in: root)
            let viewModel = OnboardingViewModel(
                environment: environment, actionRunner: makeFailingRunner())

            viewModel.panelDidBecomeVisible()
            viewModel.panelDidHide()
            await viewModel.performPrimaryAction()

            viewModel.panelDidBecomeVisible()  // 第一次露面：留着
            guard case .failed = viewModel.actionState else {
                expect(false, "第一次重开必须还看得到它")
                return
            }

            viewModel.panelDidHide()
            viewModel.panelDidBecomeVisible()  // 第二次：看过了，忘掉
            expect(
                viewModel.actionState == .idle,
                "一条已经露过面的失败不该永久挂在面板上 —— 这是 T17c 那条顾虑，它仍然成立。"
                    + "得到 \(viewModel.actionState)")
            expect(!viewModel.isShowingDetail, "清掉失败时「查看原因」也必须收起")
            expect(!viewModel.failureHasBeenSeen, "清掉之后标记也要归零")
        }
    }

    await suite("T17d：面板**开着**时诞生的失败当场就算看过 —— 下一次打开直接忘掉，不会多留一轮") {
        await withTempDirectory { root in
            let environment = makeReadyEnvironment(in: root)
            let viewModel = OnboardingViewModel(
                environment: environment, actionRunner: makeFailingRunner())

            viewModel.panelDidBecomeVisible()
            // 面板全程开着，失败就在他眼皮底下发生 —— 两个渲染点都无条件画它（T17c 结构不变式）。
            await viewModel.performPrimaryAction()
            expect(
                viewModel.failureHasBeenSeen,
                "面板开着时诞生的失败，这一帧就在屏幕上 —— 当场算看过")

            viewModel.panelDidHide()
            viewModel.panelDidBecomeVisible()
            expect(
                viewModel.actionState == .idle,
                "他已经看过了，重开就该忘掉 —— 而不是再挂一轮。得到 \(viewModel.actionState)")
        }
    }

    await suite("T17d：panelDidHide() 绝不碰 actionState（碰了就是把「静默吞错」原地请回来）") {
        await withTempDirectory { root in
            let environment = makeReadyEnvironment(in: root)
            let viewModel = OnboardingViewModel(
                environment: environment, actionRunner: makeFailingRunner())

            viewModel.panelDidBecomeVisible()
            await viewModel.performPrimaryAction()
            let before = viewModel.actionState

            viewModel.panelDidHide()

            expect(
                viewModel.actionState == before,
                "关面板只是「面板不在屏幕上了」这一个事实，不是「这条失败可以扔了」。得到 \(viewModel.actionState)")
        }
    }

    #if DEBUG
        suite("T17d：pin 死的预览实例上，两个面板信号都是彻底的 no-op（画廊不该自己改写自己）") {
            let pinned = OnboardingViewModel(
                previewState: .notInstalled,
                actionState: .failed(action: .takeOver, message: "m", detail: "d"))

            pinned.panelDidBecomeVisible()
            pinned.panelDidBecomeVisible()
            pinned.panelDidHide()

            expect(
                pinned.actionState == .failed(action: .takeOver, message: "m", detail: "d"),
                "state gallery 里 pin 住的 .failed 帧必须原样活着 —— 渲染两次不该把它清掉。"
                    + "得到 \(pinned.actionState)")
            expect(
                !pinned.failureHasBeenSeen,
                "pin 死的实例连标记都不该动 —— 它压根不参与失败的寿命")
        }
    #endif
}
