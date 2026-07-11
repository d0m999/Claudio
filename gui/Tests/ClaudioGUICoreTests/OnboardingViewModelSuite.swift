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

    suite("refresh(): reflects a NEW environment if `environment` itself is reassigned") {
        withTempDirectory { root in
            let firstEnvironment = makeReadyEnvironment(in: root)  // helperMissing
            let viewModel = OnboardingViewModel(
                environment: firstEnvironment, actionRunner: ScriptedRunner())
            expect(viewModel.state == .helperMissing, "setup: must start as helperMissing")

            // A completely different fixture, already fully installed.
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

            viewModel.environment = secondEnvironment
            viewModel.refresh()
            expect(
                viewModel.state == .installed,
                "refresh() must use the reassigned `environment`, not the one passed to init")
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

            guard case .failed(let message, let detail) = viewModel.actionState else {
                expect(
                    false,
                    "失败必须落进 actionState —— 这个 codebase 已经被「写了但没有任何视图读」的静默失败"
                        + "咬过三次。得到 \(viewModel.actionState)")
                return
            }
            expect(!message.isEmpty, "必须有一句人话")
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
                previewState: .notInstalled, actionState: .failed(message: "m", detail: "d"))
            expect(!failed.isPerformingAction, "pin 成 .failed 不是 in-flight")
        }
    #endif
}
