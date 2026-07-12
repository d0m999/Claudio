import ClaudioCore
import Foundation

/// T17：把 onboarding 的三个 CTA（修复 / 接管 / 断开）真正接到磁盘上。
///
/// ## 这个文件在防的那个 bug
///
/// `performFirstRunSetup` 早就写好了 CTA 需要的全部动作（复制二进制 → 复制内置包 → 首次选包 →
/// 写 hooks），但它的 `SetupEnvironment.executablePath` 语义是**「正在执行 setup 的那个二进制
/// 自己」**，而且它**靠这条路径反推内置包目录**（去掉两级 → `Contents/Resources` → `+ packs`）。
///
/// GUI 进程的 `CommandLine.arguments[0]` 是 `Claudio.app/Contents/MacOS/Claudio` —— **SwiftUI
/// app 自己，不是 helper**。把它塞进 `SetupEnvironment` 会：
///   ① 把 GUI app 复制成 `~/.claudio/bin/claudio` → 此后每个 Claude Code 事件都去 exec 一个
///      SwiftUI app；
///   ② 内置包目录反推成 `Contents/packs`（不存在）→ 一个包都复制不出来。
///
/// 所以 GUI **必须显式去拿 bundle 里的 helper**（``bundledHelperBinary(in:)``），而不是拿自己。
/// 这个决定住在 ``takeOverHelperSource(environment:)`` 里 —— 一个纯函数，harness 测得到。
/// 它**不能**留在 `MenuBarController` 的 `Bundle.main` 那一行里：把那一行改成
/// `Bundle.main.executableURL`（= 字面意义上的本 bug），整套测试会**照样全绿**。

// MARK: - Intent（一颗 CTA 按钮「意味着什么」）

/// 每个 ``OnboardingState`` 的 CTA 到底会做什么。把它从「按钮文案」里分出来，是为了能写下这条
/// 不变式：**copy 里存在的每一颗按钮，都必须映射到一个 intent；每一个 intent，都必须有一颗按钮**
/// （见 `OnboardingActionsSuite`）。「有按钮、但什么都不做」正是 T17 要杀死的那个 bug ——
/// 它现在是一条结构性断言，而不是一次人工检查。
public enum OnboardingActionIntent: Sendable, Equatable {
    /// 接管 / 修复 —— 跑 ``performFirstRunSetup``（幂等：二进制已在位时只补包与 hooks）。
    case takeOver
    /// 重新检测 —— **一个字节都不写**。给 `.claudeCodeNotInstalled` / `.settingsNotWritable` /
    /// `.settingsParseFailure` 用：用户的配置文件坏了或没权限，替他做主去改只会把一次诚实的报错
    /// 换成一次静默的数据丢失（`Setup.swift` 的 `noPackHasEverBeenSelected` 已经为同一条原则
    /// 交过学费）。Claudio 只重新看一眼磁盘。
    case reDetect
    /// 断开连接 —— 摘掉 hooks（``uninstallClaudioHooks``），二进制与声音包原样留着。
    case disconnect
    /// 展开 / 收起「查看原因」—— 纯视图状态，不碰磁盘。
    case revealDetail

    /// 会写盘的那两个 —— ``OnboardingDiskAction`` 是执行器的**全部**定义域。
    /// `.reDetect` / `.revealDetail` 映射为 `nil`：它们由 view-model 就地处理，永远不进执行器，
    /// 所以执行器里没有一条死分支，也不存在「返回一个假的 outcome」这种事。
    public var diskAction: OnboardingDiskAction? {
        switch self {
        case .takeOver: .takeOver
        case .disconnect: .disconnect
        case .reDetect, .revealDetail: nil
        }
    }
}

/// 真正会动磁盘的两个动作 —— 执行器的定义域，一条死分支都没有。
public enum OnboardingDiskAction: Sendable, Equatable {
    case takeOver
    case disconnect
}

/// 主 CTA 的语义。与 ``onboardingCopy(for:)`` 的 `primaryActionTitle` **必须同生共死**
/// （`OnboardingActionsSuite` 逐 state 钉住）。
public func onboardingPrimaryIntent(for state: OnboardingState) -> OnboardingActionIntent? {
    switch state {
    case .helperMissing, .notInstalled: .takeOver
    // 这三个态刻意**不自动修**：用户的 Claude Code 没装 / 配置文件没权限 / 配置文件格式坏了 ——
    // 都不是 Claudio 该替他动手的东西。CTA 是「重新检测」，它什么都不写。
    case .claudeCodeNotInstalled, .settingsNotWritable, .settingsParseFailure: .reDetect
    case .installed: nil
    }
}

/// 次 CTA 的语义。
public func onboardingSecondaryIntent(for state: OnboardingState) -> OnboardingActionIntent? {
    switch state {
    case .settingsNotWritable, .settingsParseFailure: .revealDetail
    case .installed: .disconnect
    case .claudeCodeNotInstalled, .helperMissing, .notInstalled: nil
    }
}

// MARK: - 动作态（第五族状态，进 PreviewFixtures / state gallery）

/// CTA 动作本身的状态 —— 与 ``OnboardingState`` 正交的第五族状态。
///
/// **刻意是枚举，不是 `isPerforming: Bool` + `error: String?` 两个标量**（T14 的穷尽性契约）：
/// 两个正交标量结构上进不了 `PreviewFixtures`，于是 in-flight 与 failed 这两个新视觉态会**从来
/// 没有任何一帧渲染过**，而 `assertExhaustive()` 仍然全绿 —— 这与 `/ship` 收口记录 ③ 逮到的
/// 「穷尽性只覆盖 CoverageState × enabled、从没覆盖 Event」是同一类错。枚举顺带也消灭了
/// 「正在跑 **且** 已失败」这种不可能组合。
public enum OnboardingActionState: Sendable, Equatable {
    case idle
    case running(OnboardingDiskAction)
    /// `action` = **是哪个动作失败了**。它不是装饰：一次失败的「接管」与一次失败的「断开」渲染在
    /// **面板的两个不同分支里**（前者在 onboarding 卡，后者在运行态面板底部 —— 因为 `.installed`
    /// 根本不渲染 onboarding 卡）。不带这个标签的话，一次接管失败会在用户后来（用别的办法）装好之后，
    /// 永久挂在一张已经装好的面板底部；而一次断开失败会同时出现在两个地方。
    ///
    /// `message` 是安心叙事的人话（渲染在卡片正文，必须过 T7 禁词表）；`detail` 是工程原文
    /// （`SetupError` / `SettingsUpdateError` 的 `description`），只出现在「查看原因」披露之后。
    case failed(action: OnboardingDiskAction, message: String, detail: String?)
}

/// 这个 (state, actionState) 组合下，失败行自己该不该长出一颗「查看原因」。
///
/// **它必须是一个纯函数，而不是视图里的一个 `if`** —— T17 第一版正是在视图里合成了这颗按钮，
/// 而它的 action 走 `performSecondaryAction()` → `onboardingSecondaryIntent(.notInstalled)` = `nil`
/// → `perform(nil)` → 只 refresh。**点了什么都不会发生**：一颗真正的死按钮，正是这次提交要杀死的
/// 那一类 bug，在杀死它的那次提交里以另一种形状回来了。
///
/// 返回 `false` 的两种情形：① 压根没失败、或失败没带 detail（没有原因可看）；② 这个 state 的**次
/// CTA 本身就是**「查看原因」（`.settingsNotWritable` / `.settingsParseFailure`）—— 再长一颗就是
/// 两颗按钮做同一件事。
///
/// **它刻意不看 `action`，而这一点现在是对的**（T17c）：既然 ``onboardingVisibleFailure(actionState:)``
/// 让两个渲染点都无条件画「有没有失败」，那么「这条失败行在不在屏幕上」与「哪个动作失败了」就彻底
/// 无关了 —— 于是这个函数（决定**焦点序**里有没有那颗按钮）与那个函数（决定**渲染**）不可能再给出
/// 矛盾答案。上一版它们会：`.failed(.takeOver)` × `.installed` 时这里返回 `true`、把 `.revealDetail`
/// 塞进焦点序，而当时没有任何视图声明 `.focused(…, equals: .revealDetail)` —— 面板一打开，键盘焦点
/// 落进一个不存在的控件里。
public func onboardingShowsFailureDetailToggle(
    state: OnboardingState, actionState: OnboardingActionState
) -> Bool {
    guard case .failed(_, _, let detail) = actionState, detail != nil else { return false }
    return onboardingSecondaryIntent(for: state) != .revealDetail
}

/// 此刻该被画出来的那条失败 —— **与是哪个动作失败了无关**。
///
/// ## 这个函数替换掉的那个 bug（T17c 对抗评审，实测复现）
///
/// 上一版是 `onboardingFailureBelongsHere(actionState:branch:)`：它按 `action` 把失败**分派**给
/// 两个渲染点之一（接管失败 → onboarding 卡；断开失败 → 运行态面板底部）。推理是对的（`.installed`
/// 只渲染 `operationalPanel`，onboarding 卡根本不在屏幕上），**结论是错的** —— 因为它默认了
/// 「哪个动作失败」与「失败之后 state 落在哪」是同一件事。它们不是：`runDiskAction` 在失败之后
/// **无条件重新探测磁盘**，而磁盘不欠我们这个人情。
///
/// 于是矩阵里有两个格子**没有任何视图认领**：
///
///     .failed(.takeOver)   × state == .installed   → 无人渲染
///     .failed(.disconnect) × state != .installed   → 无人渲染
///
/// 第一格是**可达的、且这次提交自己新造出来的**：quarantine 检测让一台「二进制被盖章」的机器
/// 报 `.helperMissing`（hooks 本来就在），用户点「修复」→ `performFirstRunSetup` 复制完二进制、
/// 解除隔离通过 → 在选默认包 / 写 hooks 那一步撞上 `play.lock`（TODOS 里那条 P1）→ 失败返回。
/// `refresh()` 一探测：二进制在位、没盖章、四条 hook 都在 → **`.installed`**。面板于是切到运行态、
/// 亮起绿点说「已经接好了」，而 `config.json` 压根没写、一个包都没选中 —— 用户永远听不到一声响，
/// 失败原因停在 `actionState` 里，没有任何一个像素属于它。
///
/// **这正是 T17 存在的理由那句话的第三个形状**：「装完后是哑的」。前两次是死按钮，这次是死错误。
///
/// ## 修法：不再分派，而是让「有失败就画」成为结构不变式
///
/// 两个渲染点（`OnboardingView` / `operationalPanel`）**互斥地占据屏幕** —— 任一时刻恰好有一个在。
/// 所以只要**两边都无条件渲染「当前是否有失败」**，「一个 `.failed` 必须有人画」就不再是一条需要
/// 人去维护的分派规则，而是一条不可能被违反的结构事实。`OnboardingActionsSuite` 遍历
/// `OnboardingState × OnboardingActionState` 的**全组合**把它钉住。
///
/// `.failed` 里的 `action` 标签因此不再承担分派职责，但它**留着**：进行态文案、state gallery
/// 的 caption、以及「是哪个动作失败了」这件事本身对调试与穷尽性都仍然是真信息。
///
/// 那条真实的顾虑 —— 「一条陈旧的接管失败永久挂在一张已经装好的面板上」（用户后来用 Terminal
/// 装好了）—— 改由**时效性**解决，而不是靠丢弃：``OnboardingViewModel/clearConsumedFailure()``
/// 在面板下一次重新打开时清掉它。失败从发生那一刻起可见，直到用户关掉面板再打开为止。
/// 用「什么时候该忘掉它」回答，而不是用「什么时候该看不见它」。
public func onboardingVisibleFailure(
    actionState: OnboardingActionState
) -> (message: String, detail: String?)? {
    guard case .failed(_, let message, let detail) = actionState else { return nil }
    return (message, detail)
}

/// 动作进行中时，那颗按钮上显示的字（VoiceOver 也播报它）。
public func onboardingActionRunningTitle(_ action: OnboardingDiskAction) -> String {
    switch action {
    case .takeOver: "正在接管…"
    case .disconnect: "正在断开…"
    }
}

// MARK: - 错误

/// CTA 失败的原因。
///
/// **两个字段，不是一个**：`message` 走 T7 的安心叙事（会被渲染在 onboarding 卡正文），
/// `technicalDetail` 承载底层 `SetupError` / `SettingsUpdateError` 的原话，只在「查看原因」
/// 之后出现。直接把 `SetupError.description` 渲染进正文会一句话踩中禁词表两个词
/// （「settings.json」「hook」）—— `OnboardingCopy` 早就定下的纪律是：底层 reason 只能进
/// `detail`，"never inlined into body where it would break the reassurance tone"。
public enum OnboardingActionError: Error, Sendable, Equatable {
    /// 找不到可用的 helper 二进制来源 —— 既没有 app bundle 里的那份，`~/.claudio/bin/claudio`
    /// 也不在（或不是一个能跑的正规文件）。`swift run ClaudioGUI` 这种没有 bundle 的开发构建
    /// 走到这里。**绝不静默 no-op** —— 这正是 T17 之前那个 bug 的形状。
    case helperUnavailable(reason: String)
    case setupFailed(SetupError)
    case disconnectFailed(SettingsUpdateError)
    /// 从 `.installed` 点「断开」，却一条都没摘掉。
    ///
    /// 这是**结构性矛盾**，不是「没什么可做」：能走到 `.installed` 说明
    /// `detectHookInstallStatus` 刚刚证明了四条 hook 都在。所以 `.notInstalled` 这个 outcome
    /// 只可能意味着摘除逻辑没认出自己写下的东西（例如安装路径漂移）—— 必须响，绝不能报成功。
    case disconnectSweptNothing

    /// 用户看得见的那句话。过 T7 禁词表（无「settings.json」「hook」等工程语）。
    public var message: String {
        switch self {
        case .helperUnavailable:
            "没找到 Claudio 随身带的那个小助手，所以什么都没有改动。请从「应用程序」里打开 Claudio 再试一次。"
        // 刻意**不**承诺「没有留下半成品」（T17c 对抗评审 —— 上一版这么写，而那是假话）。
        // `performFirstRunSetup` 的顺序是：复制二进制 → 复制包 → 解隔离+回验 → 写 config → 写 hooks。
        // 最常见的失败点（`.installFailure`，包括 `play.lock` 争用）发生时，二进制、内置包、config.json
        // 都**已经在磁盘上了**。一个以「不撒谎」立身的产品，不能在它唯一一次报告失败的时候撒谎。
        // 能诚实承诺的是另一件事，而且它更有用：setup 是幂等的，再点一次会接着上次继续。
        case .setupFailed:
            "这一步没能完成。Claudio 已经停下，没有改动 Claude Code 的配置。看看下面的原因，或者再点一次 —— 它会接着上次继续，不会重复安装。"
        case .disconnectFailed:
            "没能断开，你的配置一个字都没动。看看下面的原因，或者稍后再试一次。"
        case .disconnectSweptNothing:
            "没能断开：Claudio 没能认出自己之前留下的设置，所以停手了，什么都没改。"
        }
    }

    /// 工程原文 —— 只在「查看原因」披露之后出现，永远不进正文。
    public var technicalDetail: String? {
        switch self {
        case .helperUnavailable(let reason): reason
        case .setupFailed(let error): error.description
        case .disconnectFailed(let error): error.description
        case .disconnectSweptNothing:
            "uninstallClaudioHooks 返回 .notInstalled（摘除 0 条），但 onboarding 状态是 .installed"
        }
    }
}

/// 动作成功后的产物。
public enum OnboardingActionOutcome: Sendable, Equatable {
    case tookOver(SetupOutcome)
    case disconnected(count: Int)
}

// MARK: - 环境

/// 内置 helper 在 app bundle 里的固定名字。``takeOverHelperSource(environment:)`` 拿它当
/// **结构性绊线**：GUI 自己的可执行文件叫 `Claudio`（大写 C），永远等不了这个字符串。
public let claudioHelperBinaryName = "claudio"

/// helper 在 app bundle 里的相对位置 —— `Contents/Resources/bin/claudio`。
///
/// ⚠️ 这条契约的**另一端在 `.github/workflows/release.yml`**（"Assemble Claudio.app" 那步的
/// `cp`）。两边没有任何编译期联系：把 release.yml 里的目标目录改个名，所有测试照样绿、CI 照样绿、
/// DMG 照常签发，而 CTA 会在**每一台用户机器上**报 `.helperUnavailable`。
/// `ReleaseLayoutSuite` 就是为此存在的——它真的去读那个 yml。
public let bundledHelperSubdirectory = "bin"

/// app bundle 里的 helper CLI：`Claudio.app/Contents/Resources/bin/claudio`。
///
/// **住在 `ClaudioGUICore` 而不是 `ClaudioGUI`**，这是刻意的：把 `Bundle.main` 那次查找留在
/// AppKit 层，就等于把 T17 的**整个 bug** 留在 harness 够不到的地方 —— 把它改成
/// `Bundle.main.executableURL`（`Contents/MacOS/Claudio`，字面意义上的本 bug），整套测试仍然
/// 全绿。放在这里，harness 就能拿一个真的假 bundle 去断言它解析出的是哪个文件。
/// `MenuBarController` 那边因此只剩 `bundledHelperBinary(in: .main)` —— 一次无分支调用，
/// AppKit 里不再有任何决定。
///
/// `nil` = 这个进程压根不在一个带 `Resources/bin/claudio` 的 bundle 里跑（`swift run ClaudioGUI`
/// 的开发构建就是）。**不是**一个可以忽略的情况：它会一路变成面板上一句真的错误。
public func bundledHelperBinary(in bundle: Bundle) -> URL? {
    bundle.url(
        forResource: claudioHelperBinaryName, withExtension: nil,
        subdirectory: bundledHelperSubdirectory)
}

/// 这条路径上的东西，Claude Code 真的能把它当命令跑起来吗？
///
/// 「正规文件 + 非空 + 可执行」三条缺一不可 —— 从 ``detectOnboardingState(environment:)`` 里
/// 原样抽出来（它此前是内联的），让**探测**与**安装**用同一个谓词，而不是两份会各自漂移的拷贝。
/// `isRegularFile` 顺带盖掉了目录（`isExecutableFile` 对可搜索目录返回 true）；非空那一条挡的是
/// 一次半途而废的安装留下的 0 字节存根（执行位已经设好了）。
///
/// ⚠️ **`.isRegularFileKey` 是 lstat 语义 —— 对一个符号链接它返回 `false`**（实测，Darwin 25.5：
/// 一条指向真实可执行文件的 `claudio` 符号链接，`isRegularFile = false` 而 `isExecutableFile = true`）。
/// 这不是一条趣闻，它是 ``takeOverHelperSource(environment:)`` 把 `.resolvingSymlinksInPath()` 放在
/// 校验**之后**仍然安全的**唯一支柱**：一个 `Contents/Resources/bin/claudio` 符号链接（能把源解析到
/// bundle 之外）在这一关就被打掉了，根本走不到解析那一行。同理，`~/.claudio/bin/claudio` 若是一条
/// 符号链接，探测会报 `.helperMissing` —— 而 quarantine 的检查与剥离都带 `XATTR_NOFOLLOW`（问的是
/// 路径**自己**），若这里改成跟随符号链接的谓词（`fileExists`、或把这一条换成 `.isSymbolicLinkKey`
/// 取反），「检测跟随、剥离不跟随」就会当场分叉：链接自己从不带章 → 报「干净」→ 剥离对目标零作用
/// → 回验通过 → 写下 hooks → 目标二进制仍被 Gatekeeper 秒杀。**换掉这一条谓词之前，先读这段。**
public func isRunnableHelperBinary(at url: URL) -> Bool {
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values?.isRegularFile == true, (values?.fileSize ?? 0) > 0 else { return false }
    return FileManager.default.isExecutableFile(atPath: url.path)
}

/// ``performOnboardingDiskAction(_:environment:)`` 需要知道的一切。
///
/// **只有一个 initializer，而且它从 ``OnboardingEnvironment`` 里派生 `settingsFile` 与
/// `claudioBinaryDestination`** —— 于是「探测器在看哪个文件」和「安装器在写哪个文件」结构上
/// 不可能分叉。这与 `OnboardingEnvironment.claudeDirectory` 刻意做成派生属性（而不是第二个可独立
/// 注入的字段）是同一条纪律，同一个理由。
public struct OnboardingActionEnvironment: Sendable {
    /// `Claudio.app/Contents/Resources/bin/claudio`；没有 bundle 时为 `nil`。
    /// ⚠️ **永远不是** GUI 自己的可执行文件（见本文件头部）。
    public let bundledHelperBinary: URL?
    /// `~/.claudio/bin/claudio` —— 从 ``OnboardingEnvironment/claudioBinaryPath`` 派生。
    public let claudioBinaryDestination: URL
    /// `~/.claude/settings.json` —— 从 ``OnboardingEnvironment/settingsFile`` 派生。
    public let settingsFile: URL
    public let userPacksDirectory: URL
    public let configFile: URL
    public let lockFile: URL

    public init(
        onboarding: OnboardingEnvironment,
        bundledHelperBinary: URL?,
        userPacksDirectory: URL = ClaudioPaths.packsDirectory,
        configFile: URL = ClaudioPaths.configFile,
        lockFile: URL = ClaudioPaths.lockFile
    ) {
        self.bundledHelperBinary = bundledHelperBinary
        self.claudioBinaryDestination = onboarding.claudioBinaryPath
        self.settingsFile = onboarding.settingsFile
        self.userPacksDirectory = userPacksDirectory
        self.configFile = configFile
        self.lockFile = lockFile
    }
}

// MARK: - 「哪个二进制会被复制成 ~/.claudio/bin/claudio」——T17 的全部要害

/// 接管时，作为 helper 源的那个二进制。
public enum TakeOverSource: Sendable, Equatable {
    /// app bundle 里的 `Contents/Resources/bin/claudio` —— 真实分发路径。
    case bundled(URL)
    /// 已经装好的 `~/.claudio/bin/claudio` 自己。``performFirstRunSetup`` 会认出
    /// `executablePath == claudioBinaryDestination`，走 `alreadyInstalled` 分支：**跳过全部复制**，
    /// 只补选包与 hooks。开发构建（`swift run ClaudioGUI`，没有 bundle）在 `.notInstalled` 态
    /// 下走这条 —— 那是一个完全可以满足的请求（二进制本来就在），不该被报成硬错误。
    case alreadyInstalled(URL)

    public var url: URL {
        switch self {
        case .bundled(let url), .alreadyInstalled(let url): url
        }
    }
}

/// **T17 的整个失败模式住在这个函数里**，所以它是一个纯函数，而不是 SwiftUI 里的一行。
///
/// 规则，按顺序：
/// 1. bundle 里给了一个 helper 路径 → 它**必须**叫 `claudio`（`claudioHelperBinaryName`），
///    而且必须是一个跑得起来的正规文件。**不满足就大声报错，绝不悄悄回落** —— 一个存在、
///    但不叫 `claudio` 的 bundle 路径，只可能是有人把 GUI 自己的可执行文件（`Claudio`，大写 C）
///    递了进来，也就是 T17 那个 bug 本身。悄悄回落会把它藏起来。
/// 2. bundle 里没有（`nil` = 不在 bundle 里跑）→ 如果 `~/.claudio/bin/claudio` 已经是一个跑得起来
///    的二进制，就用它自己（`alreadyInstalled` 分支，零复制）。
/// 3. 两条都不成立 → `.helperUnavailable`。**这是一个真错误，会被渲染到面板上**，不是一次静默的
///    no-op。
public func takeOverHelperSource(
    environment: OnboardingActionEnvironment
) -> Result<TakeOverSource, OnboardingActionError> {
    if let bundled = environment.bundledHelperBinary {
        guard bundled.lastPathComponent == claudioHelperBinaryName else {
            return .failure(
                .helperUnavailable(
                    reason:
                        "app 包里指向的不是小助手本身：\(bundled.path)"
                        + "（期望文件名 \(claudioHelperBinaryName)）。"
                        + "把 Claudio 自己的可执行文件复制成 helper 会让每一个事件都去执行一个 GUI app。"
                ))
        }
        guard isRunnableHelperBinary(at: bundled) else {
            return .failure(
                .helperUnavailable(
                    reason: "app 包里的小助手不是一个可执行的正规文件：\(bundled.path)"))
        }
        // `performFirstRunSetup` 靠这条路径反推内置包目录（去掉两级 + `packs`），所以先把符号链接
        // 解掉，跟 CLI 侧的 `currentExecutablePath()` 保持同一种形状。
        return .success(.bundled(bundled.resolvingSymlinksInPath()))
    }

    if isRunnableHelperBinary(at: environment.claudioBinaryDestination) {
        return .success(.alreadyInstalled(environment.claudioBinaryDestination))
    }

    return .failure(
        .helperUnavailable(
            reason:
                "既没有从 app 包里找到小助手（这个进程可能不是从 Claudio.app 启动的），"
                + "\(environment.claudioBinaryDestination.path) 也不在。"))
}

// MARK: - 执行器

/// 跑一个真正会写盘的 CTA 动作。同步、阻塞 —— 调用方（``DiskOnboardingActionRunner``）负责把它
/// 挪出主线程。
public func performOnboardingDiskAction(
    _ action: OnboardingDiskAction, environment: OnboardingActionEnvironment
) -> Result<OnboardingActionOutcome, OnboardingActionError> {
    switch action {
    case .takeOver:
        switch takeOverHelperSource(environment: environment) {
        case .failure(let error):
            return .failure(error)
        case .success(let source):
            let setupEnvironment = SetupEnvironment(
                executablePath: source.url,
                claudioBinaryDestination: environment.claudioBinaryDestination,
                userPacksDirectory: environment.userPacksDirectory,
                configFile: environment.configFile,
                settingsFile: environment.settingsFile,
                lockFile: environment.lockFile)
            switch performFirstRunSetup(environment: setupEnvironment) {
            case .success(let outcome): return .success(.tookOver(outcome))
            case .failure(let error): return .failure(.setupFailed(error))
            }
        }

    case .disconnect:
        switch uninstallClaudioHooks(
            settingsFile: environment.settingsFile,
            claudioBinaryPath: environment.claudioBinaryDestination.path,
            lockFile: environment.lockFile)
        {
        case .success(.uninstalled(let count)):
            return .success(.disconnected(count: count))
        case .success(.notInstalled):
            // 「没什么可摘」从 `.installed` 出发是不可能的 —— 见 `.disconnectSweptNothing`。
            return .failure(.disconnectSweptNothing)
        case .failure(let error):
            return .failure(.disconnectFailed(error))
        }
    }
}

// MARK: - Runner（view-model 注入这个，而不是注入一个可选闭包）

/// view-model 用来跑真实动作的东西。
///
/// **不是可选的**（``OnboardingViewModel`` 构造时必须给）。一个 `var runner: Runner?` 就是
/// T17 那个 bug 换了层皮：nil 时 `guard ... else { refresh() }` = 点了按钮、什么都没写、
/// 零错误 —— 与今天 `onPrimaryAction = nil` 的行为一字不差。构造注入之后，「忘了接线」是一个
/// **编译错误**，不是一次全绿的测试。
public protocol OnboardingActionRunning: Sendable {
    func run(_ action: OnboardingDiskAction) async
        -> Result<OnboardingActionOutcome, OnboardingActionError>
}

/// 生产实现：把同步磁盘 I/O（复制一个 universal 二进制 + 若干音频文件 + flock + 原子写）挪到
/// `@MainActor` 之外，否则点一下「接管」面板就冻住。
public struct DiskOnboardingActionRunner: OnboardingActionRunning {
    private let environment: OnboardingActionEnvironment

    public init(environment: OnboardingActionEnvironment) {
        self.environment = environment
    }

    public func run(_ action: OnboardingDiskAction) async
        -> Result<OnboardingActionOutcome, OnboardingActionError>
    {
        let environment = self.environment
        return await Task.detached(priority: .userInitiated) {
            performOnboardingDiskAction(action, environment: environment)
        }.value
    }
}

/// 预览 / 状态画廊专用：一个**声明式**的 no-op。
///
/// 它存在的意义正是「明确说出这里不接线」，而不是「忘了接线」—— 后者是 T17 的 bug 本身，
/// 前者是画廊的正确行为。（画廊里的 view-model 是 pin 死状态的，`perform` 压根不会走到这里；
/// 这个类型只是让 `actionRunner` 能保持非可选。）
public struct NoopOnboardingActionRunner: OnboardingActionRunning {
    public init() {}

    public func run(_ action: OnboardingDiskAction) async
        -> Result<OnboardingActionOutcome, OnboardingActionError>
    {
        .failure(.helperUnavailable(reason: "预览环境不执行真实动作"))
    }
}
