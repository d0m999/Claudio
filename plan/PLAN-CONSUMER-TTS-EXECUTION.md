# PLAN — 描述式 TTS 执行计划

> 状态：**方案已拍板，尚未实施**
>
> 日期：2026-08-22
>
> 范围：描述式 TTS 接口层、本地确定性模拟器、SoundPacksWindow 交互、现有音频导入闭环，
> 以及 future Hosted / BYOK 的接口契约。
>
> 非 TTS 的 WorkBuddy、ChatGPT / Claude Desktop AX Beta、宿主能力矩阵和回执工作，见
> `plan/PLAN-CONSUMER-NON-TTS.md`。
>
> 本计划不授权真实供应商请求、账号/支付、外部服务部署、付费探测或真实宿主配置修改。

## 0. 目标与完成定义

本计划把自然语言描述转换为一个可确认、可试听、可安全采用的单事件语音提示音，同时保持
现有 claudi0 事件、声音包和音频导入边界不变。

完成后的用户结果：

- 用户选择一个现有 `Event`，输入自然语言需求；
- 系统先解释为可编辑的 spoken text、语言、风格和时长；
- 用户确认后展示 3 个不超过 3 秒的候选；
- 候选明确标注为本地模拟结果，不把模拟能力宣传成真实生成；
- 用户显式采用的候选经过现有 `AudioImport`、内容嗅探、大小/时长检查和 manifest bind；
- 任一失败都保留旧声音，不产生假刷新或部分发布。

### 0.1 已拍板决议

| 议题 | 决议 |
|---|---|
| TTS 产品形态 | 单事件语音提示音；自然语言需求 → 解释 → 用户确认 → 3 个 ≤3 秒候选 |
| TTS 首个里程碑 | 只做统一接口、状态机、真实 UI 和确定性模拟器；**不接真实供应商** |
| 后续供应商目标 | 同时支持一个国际供应商和一个中国大陆供应商 |
| 调用路线 | 同时设计 claudi0 Hosted 与 BYOK；首个里程碑两者都不发真实请求 |
| Hosted 商业阶段 | 账户 + Beta 赠送额度；首个里程碑不接支付 |
| 描述解释 | 先展示可编辑的 spoken text、语言、风格和时长，用户确认后才生成 |
| Hosted 默认留存 | 原始描述和 recipe 在候选完成后删除；候选音频保留 24 小时；账本只留去标识用量 |

### 0.2 共享事件边界

现有五个声音语义继续是唯一公共事件集，TTS 不新增、不改名，也不改变其含义：

| `Event` | 稳定 token | 含义 |
|---|---|---|
| `.taskStart` | `task_start` | 用户提交了一个新的任务或 prompt |
| `.stop` | `stop` | 宿主停止本轮响应；**不等价于业务成功** |
| `.stopFailure` | `stop_failure` | 宿主明确报告执行失败 |
| `.notification` | `notification` | 宿主明确发出通知；部分宿主只覆盖授权请求 |
| `.subagentStop` | `subagent_stop` | 子代理结束 |

TTS 只能绑定到已有事件。不得为了让候选或声音包矩阵更好看而把 session、tool、按钮消失或普通
UI 文案伪装成上述事件。

## 1. 首个里程碑的诚实边界

本期只交付：

- 可交互 UI；
- 稳定的请求、recipe、candidate、状态和错误类型；
- Hosted/BYOK transport seam；
- 确定性 fixture generator；
- future Hosted REST/OpenAPI 契约；
- 导入现有声音包的完整闭环。

本期不交付真实模型输出。fixture 入口只能通过内部 Preview/测试依赖注入打开，候选必须显示“模拟”；
production 默认不显示生成入口，不能把 bundled audio 冒充 AI 生成。

### 1.1 TTS 架构

~~~text
Natural-language request
          │
          ▼
CuePromptInterpreting ──► confirmed CueRecipe
                                  │
                                  ▼
      Fixture / future Hosted / future BYOK CueGenerating
                                  │
                                  ▼
                         3 temporary candidates
                                  │ explicit Use
                                  ▼
                    existing AudioImport + manifest bind
~~~

TTS 领域层只接收已确认的 recipe 和应用私有临时音频资产；UI、播放器和 `AudioImport` 不直接处理
provider URL 或原始服务响应。

## 2. 领域模型与深接口

### 2.1 领域类型

~~~swift
struct CueProviderID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

struct CueGenerationRequest: Sendable, Equatable {
    let event: Event
    let description: String
    let locale: String
    let candidateCount: Int          // v1 固定为 3
    let maximumDurationMilliseconds: Int // v1 固定为 3000
    let route: CueGenerationRoute
}

enum CueGenerationRoute: Sendable, Equatable {
    case hosted
    case byok(providerID: CueProviderID)
    case fixture // 仅内部 Preview / tests
}

struct CueRecipe: Sendable, Equatable {
    let spokenText: String
    let languageTag: String
    let styleDescription: String
    let targetDurationMilliseconds: Int
}

struct TemporaryAudioAsset: Sendable, Equatable {
    let fileURL: URL
    let byteCount: Int
    let sniffedFormat: AudioFormat
}

struct CueCandidateProvenance: Sendable, Equatable {
    let route: CueGenerationRoute
    let providerID: CueProviderID?
    let modelID: String?
    let generationID: String
    let isFixture: Bool
}

struct CueCandidate: Identifiable, Sendable, Equatable {
    let id: UUID
    let asset: TemporaryAudioAsset
    let durationMilliseconds: Int
    let mediaType: String
    let provenance: CueCandidateProvenance
}

enum CueGenerationUpdate: Sendable, Equatable {
    case queued(generationID: UUID)
    case generating(generationID: UUID, progress: Double?)
    case ready(generationID: UUID, candidates: [CueCandidate])
}
~~~

`TemporaryAudioAsset` 只暴露已落入应用私有临时目录的本地 URL、byte count 和 sniffed format；
领域层不把任意 provider URL 直接交给播放器或 `AudioImport`。

`CueCandidateProvenance` 保存 route、opaque provider/model token、generation ID、是否 fixture；
不保存 API key、Authorization header 或原始服务响应。

### 2.2 深接口

~~~swift
protocol CuePromptInterpreting: Sendable {
    func interpret(_ request: CueGenerationRequest) async throws -> CueRecipe
}

protocol CueGenerating: Sendable {
    func generate(
        recipe: CueRecipe,
        request: CueGenerationRequest
    ) -> AsyncThrowingStream<CueGenerationUpdate, Error>

    func cancel(generationID: UUID) async
}

protocol AccountSessionProviding: Sendable { /* future bearer session */ }
protocol CreditBalanceProviding: Sendable { /* available/reserved snapshot */ }
protocol GenerationCredentialStore: Sendable { /* future Keychain locator only */ }
~~~

`CueGenerationUpdate` 只承载 queued、progress 和 ready；失败通过 throwing stream 抛出
`CueGenerationError`，取消通过 `CancellationError` 结束。view model 再把两者投影成 `.failed` /
`.cancelled`，避免同一次失败同时既是 stream value 又是 thrown error。一次 generation 只有一个终态。

`CueGenerationError` 至少覆盖：

- 空/过长描述、无法确认 spoken text、locale 不支持；
- 未登录、缺少 BYOK credential、额度不足；
- rate limited（包含 `retryAfter`）、provider unavailable、网络中断；
- provider audio 格式伪装、超过 5 MB、超过 3 秒、候选数不完整；
- 用户取消和临时文件写入失败。

## 3. 用户流程与状态

生成入口位于 `SoundPacksWindow`，一次只处理一个现有 `Event`：

1. 选择事件并输入自然语言需求。
2. `CuePromptInterpreting` 返回 recipe；用户可编辑 spoken text、语言、风格和时长。
3. 用户确认后才调用 `CueGenerating`。修改 recipe 会使旧确认失效。
4. 展示 3 个候选；不自动播放，同一时刻最多播放一个。
5. “用于此事件”先停止试听，再把候选作为普通 `AudioImportRequest` 送入现有导入链。
6. 只有导入与 manifest bind 都成功才显示完成；失败保留当前声音，不发布假刷新。

窗口状态固定为：

~~~text
idle → interpreting → reviewingRecipe → generating → candidatesReady
                                    ↘ failed / cancelled
candidatesReady → importing → applied
                         ↘ failed（旧绑定保持不变）
~~~

关闭窗口或重新生成时清理未采用的临时候选；已导入声音由现有包目录和 manifest 接管，不能被临时清理删除。

## 4. 音频导入与安全发布

候选不得绕过现有 `AudioImport`：

- 格式仅接受现有 allowlist：WAV、MP3、AIFF、M4A；
- 最大 5 MB；
- 最大 3 秒；
- 扩展名、magic bytes 和 duration probe 必须一致；
- source acquisition、symlink/regular-file 检查、唯一文件名、包锁和安全 publication 全部复用；
- 内置包仍只读，用户必须先复制为自有包再绑定生成结果。

采用流程必须复用现有音频入口、包锁、manifest bind 和刷新语义。导入成功但绑定失败、绑定成功后
刷新失败等部分成功，必须显示真实磁盘状态；不得假装整个操作已经完成。

## 5. Future Hosted / BYOK 契约

### 5.1 Hosted REST v1

本期只把下列契约写成 OpenAPI，不实现或部署 server：

| 方法 | 路径 | 语义 |
|---|---|---|
| `POST` | `/api/v1/cue-recipes` | 把自然语言描述解释为可编辑 recipe |
| `POST` | `/api/v1/cue-generations` | 确认 recipe 后创建异步 generation；要求 `Idempotency-Key` |
| `GET` | `/api/v1/cue-generations/{id}` | 获取 queued/generating/ready/failed/cancelled 状态 |
| `DELETE` | `/api/v1/cue-generations/{id}` | 取消未完成任务并释放预留额度 |
| `GET` | `/api/v1/cue-generations/{id}/candidates/{candidateID}/audio` | 下载经过服务端校验的候选音频 |
| `GET` | `/api/v1/account/credits` | 返回 available、reserved 和最近到期时间 |

公共规则：

- `/api/v1` path versioning；JSON 使用统一 `data` envelope 和结构化 `error`。
- Bearer session 是前置接口；具体采用 Sign in with Apple 还是 email 不在本里程碑决定。
- `POST /cue-generations` 的幂等键按 account + key 唯一。重复请求返回同一 generation，不重复预留额度。
- 创建任务先预留额度；取消/失败释放；完整 3 个候选校验成功后才结算。
- 语义错误返回 `422`；未认证 `401`；额度不足返回 `409 insufficient_credits`；限流 `429`
  并带 `Retry-After`；上游失败 `502`；暂时不可用 `503`。
- 不允许自动从 Hosted fallback 到 BYOK，或从中国大陆 provider fallback 到国际 provider；跨路线重试必须
  再次由用户确认。

### 5.2 数据边界

- 原始描述只用于 recipe 解释；recipe 只保留到该 generation 形成终态。
- generation 成功或失败后删除原始描述和 recipe 内容。
- 候选音频保留 24 小时，过期后下载返回明确的 expired error。
- 用量账本保留 account、generation ID、provider/model opaque token、字符/音频计量、额度变化和时间；
  不保留 spoken text、style 或音频。
- provider 请求/响应日志默认关闭 content；错误日志只存 code、latency、request ID 和重试次数。

### 5.3 BYOK

- 未来 BYOK adapter 从 macOS Keychain 读取 credential；view model 和领域请求都拿不到明文 key。
- key 不进入 `UserDefaults`、`config.json`、日志、回执、crash metadata 或 Hosted API。
- 首个里程碑不显示 key 输入框、不验证真实 key，也不发 provider probe。
- 每个真实 adapter 必须通过同一 contract suite，再进入 provider registry。

## 6. 实施顺序

| Task | 内容 | 主要依赖 | 完成门槛 |
|---|---|---|---|
| TTS-0 | `CueGeneration` 领域类型、错误、状态机、fixture generator | — | 确定性 3 候选；零网络；取消与临时清理可测 |
| TTS-1 | `SoundPacksWindow` 解释/确认/候选/采用流程 | TTS-0 | 选中候选完整复用 `AudioImport`；无自动播放；a11y 通过 |
| TTS-2 | Hosted OpenAPI、额度与留存 contract tests | TTS-0 | 幂等、错误 envelope、状态迁移和保留期 schema 完整 |
| TTS-3 | 文档、隐私声明和分层验收 | TTS-0–TTS-2 | 自动、build、音频与未完成项分开报告 |

依赖关系：

~~~text
TTS-0 → TTS-1
   └──→ TTS-2
TTS-3 等待所有 TTS 任务
~~~

TTS-0 与非 TTS 宿主工作互不依赖，但如果同时触及 GUI tests 或 localization，共享文件必须顺序处理。

## 7. 自动测试与回归命令

### 7.1 TTS 接口层

- 自然语言描述为空/过长、recipe 编辑使旧确认失效。
- fixture 恰好返回 3 个稳定候选，且每个 ≤3 秒、≤5 MB、格式在 allowlist。
- 状态只能按合法边迁移；取消后 late result 不复活 UI。
- 同时试听第二个候选时，第一个停止；无 autoplay。
- candidate 临时文件被替换、变成 symlink、格式伪装、超时长或超大小时，采用操作 fail closed。
- 导入成功但 bind 失败、bind 成功后 refresh 失败等部分成功必须显示真实磁盘状态，不能假成功。
- fixture/Preview 标识不能在 production 默认路径消失。
- OpenAPI schema 覆盖幂等、额度预留/释放/结算、429 retry、过期音频和标准错误 envelope。

### 7.2 回归命令

~~~bash
swift run --package-path helper claudio-tests
swift run --package-path gui claudio-gui-tests
swift build --package-path helper -c release --arch arm64 --product claudio
swift build --package-path gui -c release --arch arm64 --product ClaudioGUI
git diff --check
~~~

不得用裸 `swift build -c release` 代替显式 product build。

## 8. 真机与手工验收

自动测试不能证明 macOS UI、VoiceOver 和真实声音包状态已经完成闭环。

### 8.1 音频与生成原型

- 内部 Preview 中输入描述、编辑 recipe、生成三个模拟候选、逐个试听并采用一个。
- 关闭/重开窗口后，已采用声音仍由声音包正常播放；其余临时候选已清理。
- 内置包路径要求先 fork；拒绝时原包不变。
- 以键盘和 VoiceOver 完整完成一次流程；候选不自动播放，焦点顺序与视觉顺序一致。

### 8.2 分层证据

- 记录 fixture/Preview 标识、generation ID、候选数量、格式、大小和时长；
- 记录导入、manifest bind、刷新和失败时旧绑定保持情况；
- 明确区分自动测试、GUI/VoiceOver 手工证据和未来真实供应商证据；
- 没有真实 provider、网络、账号、key 或付费验证时，能力保持本地模拟，不升级为线上生成。

## 9. 失败模式

| 路径 | 失败 | 防线 | 用户可见结果 |
|---|---|---|---|
| TTS fixture | 模拟声音被当成真实模型结果 | internal flag + fixture provenance + 强制“模拟”标识 | production 默认无入口 |
| future generation retry | 重试重复扣额度 | account-scoped idempotency + reserve/commit ledger | 返回同一 job，不重复扣费 |
| provider 返回坏音频 | 扩展名看似合法但内容恶意/超限 | 私有 temp acquisition + 现有 `AudioImport` 全链 | 候选拒绝，旧声音不变 |
| BYOK key | key 被配置或日志持久化 | Keychain-only locator；领域层不接触明文 | 删除 key 后立即失效，无明文残留 |
| Hosted retention | 内容长期留存 | 终态删描述/recipe，audio TTL 24h | 过期给明确提示，可重新生成 |
| partial publish | 导入或 bind 只完成一半 | 事务、回滚和真实磁盘状态投影 | 旧绑定保持，用户看到实际失败阶段 |

## 10. 明确不做

- 不新增或改名现有五个 `Event`。
- 不把 `SessionStart`、`SessionEnd`、tool event 或普通 UI 文案伪装成缺失语义。
- 不接真实 TTS/LLM provider，不选定 OpenAI、MiniMax、ElevenLabs 或其他供应商。
- 不实现 Hosted server、账号签发、支付、Stripe、Apple IAP 或正式额度购买。
- 不收集真实 BYOK key，不做付费 smoke。
- 不做声音克隆、用户本人音色、非语音 sound effect、音频编辑/裁剪/归一化。
- 不一次生成整个声音包，不生成超过 3 秒的候选。
- 不改变当前 macOS 12 最低版本，不为新 UI 强行采用只在更高系统可用的 observation API。
- 不把自动测试、fixture、静态契约或 hash 升格为真实生成、正式发布或商业验收。
- 不修改 WorkBuddy、Codex、Claude 或其他宿主配置；宿主集成属于非 TTS 计划。

## 11. 绿灯

只有以下条件同时成立，TTS 计划才算完成：

- TTS Preview 有解释、确认、3 候选、试听、采用、取消和失败闭环，但 production 不冒充真实生成。
- 选中的候选完整走现有 `AudioImport` 和 manifest bind，旧声音在失败时保持不变。
- fixture 候选始终带模拟来源、generation ID、格式、大小和时长证据。
- Hosted/BYOK/OpenAPI 只有契约，没有网络、账号、key、部署或费用副作用。
- helper/GUI test harness、两个显式 release product build 和 `git diff --check` 全绿。
- 自动证据、GUI/VoiceOver/音频证据、未来真实 provider 状态分别报告。
- 实施 diff 不包含本计划开始前的其他已有修改；commit/push 仍需用户另行明确授权。

## 12. 计划来源与复用边界

本计划复用现有：

- `Event` 的五个公共语义；
- `SoundPacksWindow` retained window 与现有 accessibility presentation；
- `AudioImport` 的 source acquisition、内容嗅探、时长/大小限制、包锁、安全发布和 manifest bind；
- 现有声音包的只读内置包与用户自有包边界；
- 现有测试 harness、播放 facade 和失败/刷新语义。

本计划新增的是 `CuePromptInterpreting`、`CueGenerating`、recipe/candidate 状态和 UI 接缝，不在
UI 或 provider adapter 中复制 `AudioImport`、包锁和 manifest 发布逻辑。

文档类型：工程执行计划，兼具内部接口 reference 与架构 explanation。实现后再为最终用户补
tutorial/how-to；在真实 provider 和正式验收完成前，不提前写会让用户误以为功能已上线的使用教程。
