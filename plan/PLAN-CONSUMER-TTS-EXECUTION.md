# PLAN — 描述式 AI 提示音（BYOK）执行计划

> 状态：**本地实现与自动验证已完成；真机无障碍、真实 Provider 与发布证据待单独验收**
>
> 日期：2026-08-26
>
> 范围：AI 提示音命名、描述生成、隐藏的内部声音方案、ElevenLabs BYOK 凭据管理、固定
> 双模型能力路由、3 候选试听与现有 `AudioImport` / manifest bind 闭环。
>
> 文件名沿用 `TTS` 以保持计划路径稳定；产品能力不再限定为文字转语音，也包括动物叫声、
> 简短音效和混合声音。
>
> 非 TTS 的 WorkBuddy、ChatGPT / Claude Desktop AX Beta、宿主能力矩阵和回执工作，见
> `plan/PLAN-CONSUMER-NON-TTS.md`。
>
> 本轮已完成本地 Swift 实现与 fixture 验证；仍未授权输入真实 key、发真实供应商请求、付费探测、
> 修改真实宿主配置、commit 或 push。

## 0. 目标与完成定义

用户先为一个现有 `Event` 描述想听到的声音。Claudio 在后台把描述规范化为内部声音方案，使用
用户自己的 API Key 请求固定的首发生成服务，返回 3 个不超过 3 秒的临时候选。候选完整展示后，
系统根据描述提供名称建议；用户试听、确认或修改名称并显式采用一个候选，最终音频才以该名称
保存到「我的提示音」，再绑定到该事件。

完成后的用户结果：

- API Key 只需在页面级生成服务设置中配置一次，不重复出现在每个事件表单里；
- 描述阶段不要求命名；候选阶段显示系统建议名称，并允许用户在采用前直接修改；
- 可见主流程只有“描述 → 3 个候选”，不再强制展示独立的“声音方案”重表单；
- 描述可覆盖语音、动物叫声、简短音效或混合声音，`spokenContent` 可以为空；
- 三个候选是同一待保存提示音的临时变体，不要求逐一命名；
- 候选阶段可只修改最终名称，不重新请求模型；修改声音描述才需要重新生成；
- 用户显式采用的候选继续经过现有 `AudioImport`、内容嗅探、大小/时长检查和 manifest bind；
- 任一失败都保留旧声音，不产生假刷新或部分发布。

### 0.1 已拍板决议

| 议题 | 决议 |
|---|---|
| 产品形态 | 单事件 AI 提示音；支持语音、动物叫声、音效和混合声音 |
| 可见流程 | 描述 → 3 个候选 + 命名 → 显式采用 |
| 声音方案 | 保留为内部必要模块；默认完全隐藏，不作为强制独立步骤 |
| 提示音名称 | 不进入生成表单或 provider request；候选阶段建议、确认或修改，采用时保存 |
| 首发调用路线 | **仅 BYOK**；用户输入自己的 API Key，本机直连 provider |
| Hosted 路线 | v1 不做账号、额度、支付、Hosted API 或自动 fallback |
| provider 范围 | v1 固定 ElevenLabs；一个 provider profile 内按声音类型固定路由两个官方模型，不允许自定义 base URL / model / voice |
| 凭据保存 | macOS Keychain only；配置文件、日志、回执和 manifest 均不保存 key |
| 候选约束 | 每次恰好 3 个，每个不超过 3 秒、5 MB；不自动播放 |
| 网络重试 | 三个子请求顺序执行；网络、5xx 和未知计费结果不重试；明确 429 至多重试一次 |
| 采用边界 | 明确 `surface + event + packID`；独立用户包内完整 `AudioImport` + manifest bind 成功后才替换旧绑定 |

### 0.2 固定 Provider 契约

首发固定为 ElevenLabs，认证 header 为 `xi-api-key`，不接受用户输入 endpoint、model 或 voice。
配置凭据时调用只读 `GET /v1/models`，同时验证 key 可用且返回两个必需 model ID：

| 声音类型 | 固定模型与端点 | 固定输出 |
|---|---|---|
| `speech` / `mixed` | `eleven_v3`；`POST /v1/text-to-speech/JBFqnCBsd6RMkjVDRZzb` | `mp3_44100_128` |
| `animal` / `soundEffect` | `eleven_text_to_sound_v2`；`POST /v1/sound-generation` | MP3 |

`eleven_v3` 通过台词和官方 audio tags 覆盖语音及语音混合；Sound Effects API 覆盖动物叫声和
纯音效。每个 generation 顺序发出 A/B/C 三个子请求，因为单个同步请求不返回三个独立候选。
Sound Effects 的请求时长固定夹在 0.5...3 秒；所有响应仍以本地实测时长不超过 3 秒为准。

官方契约证据：

- [Authentication](https://elevenlabs.io/docs/api-reference/authentication)
- [List models](https://elevenlabs.io/docs/api-reference/models/list)
- [Text to Speech](https://elevenlabs.io/docs/api-reference/text-to-speech/convert/)
- [Prompting Eleven v3](https://elevenlabs.io/docs/best-practices/prompting)
- [Sound Effects](https://elevenlabs.io/docs/api-reference/text-to-sound-effects/convert)
- [API errors](https://elevenlabs.io/docs/eleven-api/resources/errors)
- [Zero Retention Mode](https://elevenlabs.io/docs/eleven-api/resources/zero-retention-mode)
- [Model improvement data setting](https://elevenlabs.io/docs/help-center/legal/is-my-data-used-to-improve-eleven-labs-ai-models)

普通账户不能由 Claudio 承诺 zero retention；非 Enterprise 数据还可能按用户 ElevenLabs 账户设置
用于模型改进。配置 UI 必须在保存 key 前披露这些供应商边界。真实付费 smoke 仍需要单独授权。

### 0.3 共享事件边界

现有五个声音语义继续是唯一公共事件集，本计划不新增、不改名，也不改变其含义：

| `Event` | 稳定 token | 含义 |
|---|---|---|
| `.taskStart` | `task_start` | 用户提交了一个新的任务或 prompt |
| `.stop` | `stop` | 宿主停止本轮响应；**不等价于业务成功** |
| `.stopFailure` | `stop_failure` | 宿主明确报告执行失败 |
| `.notification` | `notification` | 宿主明确发出通知；部分宿主只覆盖授权请求 |
| `.subagentStop` | `subagent_stop` | 子代理结束 |

AI 提示音只能绑定到已有事件。不得为了补齐声音矩阵而把 session、tool、按钮消失或普通 UI 文案
伪装成上述事件。

### 0.4 来源与声音包隔离

manifest 的事件映射是 pack-wide。首版入口因此只对明确的非全局 `HostSurfaceID` 开放，并要求
当前有效声音包为可编辑、已安装且未被全局或其他 surface 有效选择的独立用户包。全局作用域、
内置包、共享用户包或生成期间发生变化的目标全部 fail closed；不能用一条 pack 级写入承诺
“其他来源不受影响”。采用时必须重新验证 `surface + event + packID`，详见 ADR 0007。

## 1. 架构与信任边界

~~~text
页面级“AI 声音生成服务”设置
          │ validate / save / delete
          ▼
CredentialManager ──► macOS Keychain
          │ status only                （明文不进入 view model / domain request）
          │
natural-language description + locale
          │
          ▼
AICueGenerationEngine
          │ local interpret + normalize with versioned hidden rules
          ▼
internal AICueSoundPlan
          │ modality routing + A/B/C request compilation
          ▼
allowlisted ElevenLabs ProviderAdapter ──► fixed provider endpoints
          │
          ▼
3 private temporary candidates
          │ explicit Use + final display name + captured adoption target
          ▼
existing AudioImport + manifest bind
~~~

架构分为四个独立接缝：

1. `CredentialManager` 只管理 provider 凭据状态、验证、替换和删除；UI 只看到状态。
2. `AICueGenerationEngine` 接收描述，通过确定性的 `AICueSoundPlanner` 在本地生成并保留内部
   `AICueSoundPlan`，但不发起额外 LLM
   “解释请求”，也不把方案投影成强制 UI。
3. `ProviderAdapter` 按 `AICueSoundPlan.modality` 固定路由两个 ElevenLabs 模型并负责真实网络协议；
   播放器和 `AudioImport` 永远只接触已落入应用私有临时目录且经过初步校验的本地音频资产。
4. `AICueAdoptionTarget` 把 `surface + event + packID` 从可变 UI 选择中冻结出来；采用前重新验证目标
   仍隔离、可编辑且有效，再进入既有发布链。

隐藏生成指令是质量机制，不是安全边界。provider 的 models JSON、状态码、MIME 和音频响应体
一律视为不可信输入，仍需结构校验、流式字节边界和 `AudioImport` 全链防线。

## 2. 领域模型与深接口

### 2.1 领域类型

~~~swift
struct AICueProviderID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String
}

struct AICueDisplayName: Hashable, Sendable {
    let value: String // trim 后 1...40 个字符；不得用于直接拼接路径
}

enum AICueModality: String, Sendable, Equatable {
    case speech
    case animal
    case soundEffect
    case mixed
}

struct AICueGenerationRequest: Sendable, Equatable {
    let description: String
    let locale: String
    let candidateCount: Int // v1 固定为 3
    let maximumDurationMilliseconds: Int // v1 固定为 3000
    let providerID: AICueProviderID // v1 来自 allowlist，不由用户输入
}

struct AICueSoundPlan: Sendable, Equatable {
    let suggestedDisplayName: String
    let modality: AICueModality
    let soundDescription: String
    let spokenContent: String?
    let languageTag: String?
    let styleDescription: String
    let targetDurationMilliseconds: Int
    let instructionVersion: String
}

struct AICueTemporaryAudioAsset: Sendable, Equatable {
    let fileURL: URL
    let byteCount: Int
    let sniffedFormat: AudioFormat
}

struct AICueCandidateProvenance: Sendable, Equatable {
    let providerID: AICueProviderID
    let modelID: String
    let generationID: UUID
    let requestOrdinal: Int
    let providerRequestID: String?
}

enum AICueVariant: String, CaseIterable, Sendable, Equatable {
    case clear
    case brisk
    case restrained
}

struct AICueCandidate: Identifiable, Sendable, Equatable {
    let id: UUID
    let variant: AICueVariant // A / B / C 的试听身份，不是最终保存名称
    let asset: AICueTemporaryAudioAsset
    let durationMilliseconds: Int
    let mediaType: String
    let provenance: AICueCandidateProvenance
}

struct AICueAdoptionTarget: Sendable, Equatable {
    let surface: HostSurfaceID // 不允许 global / nil
    let event: Event
    let packID: String
}

enum AICueCredentialStatus: Sendable, Equatable {
    case missing
    case configured(providerID: AICueProviderID)
    case unavailable
}
~~~

`AICueDisplayName`、`AICueAdoptionTarget` 和 `Event` 都不属于 `AICueGenerationRequest`，也不得
发送给 provider；名称只在候选阶段随采用操作进入本地发布链。名称与文件身份必须分离：
`AICueDisplayName` 是用户可见 manifest 元数据；导入后的文件名继续由现有
唯一分配器生成，绝不把原始名称、描述或 provider 文件名直接变成路径。若同一用户包已有同名
提示音，发布前按现有包规则生成可见后缀（例如“ 2”），并在成功态显示最终名称。

`spokenContent` 和 `languageTag` 对动物叫声、纯音效可以为 `nil`。任何代码不得再以“必须有台词”
作为生成前置条件。

### 2.2 深接口

~~~swift
protocol AICueProvider: AICueCredentialValidating {
    func generateCandidate(
        request: ElevenLabsAICueCompiledRequest,
        credential: SensitiveCredentialInput
    ) async throws -> AICueProviderAudioResponse
}

protocol AICueGenerating: Sendable {
    func generate(description: String, locale: String) async throws -> AICueGeneration
    func discard(generationID: UUID) async
    func discardAll() async
}

protocol AICueCredentialManaging: Sendable {
    func status(for providerID: AICueProviderID) async -> AICueCredentialStatus
    func validateAndSave(
        _ credential: SensitiveCredentialInput,
        for providerID: AICueProviderID
    ) async throws
    func delete(for providerID: AICueProviderID) async throws
}
~~~

`AICueSoundPlanner` 是无网络、确定性的值类型；`ElevenLabsAICueRequestCompiler` 再把内部方案编译为
固定路由的 A/B/C 请求，不需要额外的解释模型。`SensitiveCredentialInput` 只能由凭据表单到
`AICueCredentialManaging` 的一次性调用创建，不得
实现 `Codable`、`Equatable`、`CustomStringConvertible` 或可日志化描述。真实 provider client 在其
私有实现中临时借用 Keychain 值并构造认证请求；公共生成请求、view model、错误和 provenance
都不能携带明文 key。

替换 key 必须 fail closed：新 key 验证或 Keychain 写入失败时，旧 credential 继续有效；只有新值
验证并安全写入后才切换状态。删除 key 后后续生成立即进入 `.credentialRequired`，但不删除已经
导入的提示音。

`AICueProvider` 是真实外部接缝；网络、Keychain、时间和 duration probe 只能通过 adapter 注入测试。
解释器、A/B/C prompt compiler、候选集合与采用目标验证保持 Foundation-only，测试不穿透私有
HTTP 或 Keychain 实现。

## 3. 用户流程与状态

### 3.1 页面级凭据流程

1. “事件与提示音”页顶部显示全局“AI 声音生成服务 · 自备 API Key”状态卡。
2. 未配置时显示“未配置”和“配置 API Key”；已配置时显示“已配置”和“管理”。
3. 首版只有一个固定 provider，因此不展示无意义的 provider 下拉，也不允许自定义 API 地址。
4. 用户输入 key 后执行“验证并保存”；成功后只向 UI 返回 `.configured(providerID:)`。
5. 删除前二次确认，并明确“不能继续生成，但已采用提示音不受影响”。
6. 如果用户在未配置时点击“生成 3 个候选”，保留声音描述，打开配置界面；保存后返回原表单，
   **不自动发起可能计费的生成请求**，仍由用户再次点击生成。

原型中不得请求或持久化真实 key，只接受演示字符并明确标注。正式版用 `SecureField`、关闭拼写
检查和自动填充；不得提供“显示明文”或复制已保存 key 的能力。

### 3.2 单事件生成流程

1. 选择现有事件。
2. 描述想听到的声音；第一步不显示或要求“提示音名称”，描述不能为空。
3. 点击“生成 3 个候选”后，后台用版本化隐藏指令解释并规范化 `AICueSoundPlan`；不显示独立确认表单。
4. 请求 provider，完整取得并校验 3 个候选后一次性展示；不自动播放，同一时刻最多播放一个。
5. 候选页用 `AICueSoundPlan.suggestedDisplayName` 预填“提示音名称”；名称是必填的最终保存元数据，
   但不属于任一候选的生成参数。
6. 用户可在试听期间直接修改名称；改名不重新生成，“修改描述”才返回输入态并使旧候选失效。
7. “用于此事件”先校验名称并停止试听，再把候选与最终 `AICueDisplayName` 送入现有导入链。
8. 只有导入与 manifest bind 都成功才显示完成；失败保留当前声音，不发布假刷新。

凭据状态与生成状态正交，不把配置弹窗塞进 generation state machine：

~~~text
CredentialState:
missing/configured/unavailable
          └── validating / deleting（独立 activity；失败时保留旧 key）

GenerationState:
editing → generating → candidatesReady → adopting → applied
   ↑          └── failed / cancelled ──┘       └── failed → candidatesReady
   └── 修改描述 / 重新生成会使旧候选失效
~~~

关闭窗口、修改描述或重新生成时清理未采用的临时候选；仅重命名不能清理或重新请求候选。已导入
声音由现有包目录和 manifest 接管，不能被临时清理删除。

## 4. BYOK 网络、隐私与凭据边界

- v1 由 Claudio 本机直接调用 allowlisted provider；不经过 claudi0 Hosted server。
- 用户应在首次配置前看到：描述、隐藏规范化结果和生成所需元数据会发送给该 provider；其留存与
  训练规则受 provider 条款约束，Claudio 不能承诺替 provider 删除。
- API endpoint 和 redirect host 必须在 adapter allowlist 中；首版只接收固定端点的直接音频响应，
  不接受用户输入 base URL 或远端下载 URL，
  防止 SSRF、凭据外送和任意网络访问。
- key 只存 macOS Keychain；不得进入 `UserDefaults`、`config.json`、CLI 参数、环境变量、日志、
  analytics、receipt、crash metadata、生成请求值类型、音频 metadata 或 manifest。
- provider 请求/响应的 content logging 默认关闭。诊断只允许 provider ID、model ID、opaque request
  ID、错误分类、latency、重试次数和字节/时长计量。
- 原始描述和内部 `AICueSoundPlan` 只驻留本次内存状态；关闭、改描述或取消后释放。首版正式落盘
  只保存最终提示音名称、音频和现有 manifest 绑定；候选 provenance 不持久化。
- 认证失败不得自动 fallback 到其他 provider、Hosted 路线或其他 key；跨路线/供应商必须是未来的
  显式产品选择。
- 生成按钮可能触发用户供应商账户计费；UI 不得在保存 key 后自动生成或后台重试无限次。

## 5. Provider 输出与音频安全发布

provider 输出不得绕过现有 `AudioImport`：

- 网络层设置连接/整体超时、有限重试、redirect allowlist 和流式大小上限；
- 只接收现有 allowlist：WAV、MP3、AIFF、M4A；最大 5 MB、最大 3 秒；
- provider 状态码、MIME、响应体和声明格式均不可信，必须检查状态码、流式字节上限、magic bytes、
  sniffed format 和 duration probe；
- 响应先写入应用私有临时目录，使用唯一临时文件和安全权限，不跟随 symlink；
- 三个候选必须属于同一 generation 且完整通过校验后才进入 `candidatesReady`；不展示部分结果；
- 采用时继续复用 source acquisition、regular-file 检查、唯一文件名、包锁、安全 publication、
  manifest bind 和刷新语义；
- 内置包仍只读，用户必须先复制为自有包再保存生成结果；
- 导入成功但绑定失败、绑定成功后刷新失败等部分成功，必须显示真实磁盘状态，不能假装整体完成。

## 6. 实施顺序

| Task | 内容 | 主要依赖 | 当前状态 | 完成门槛 |
|---|---|---|---|---|
| TTS-0 | 固定首发 provider/model 与官方能力/隐私契约 | — | 已完成 | 0.2 全部有一手证据；能力文案与模型能力一致 |
| TTS-1 | `AICueDisplayName`、`AICueSoundPlan`、generation/adoption target、candidate/error 与双状态机 | TTS-0 | 已完成 | `spokenContent` 可空；名称不进入生成请求且与路径分离；3 候选契约稳定 |
| TTS-2 | Keychain credential manager 与单一 allowlisted provider adapter | TTS-0–TTS-1 | 已完成 fixture 验证 | key 不越界；替换/删除 fail closed；无自定义 endpoint |
| TTS-3 | `EventSettingsWindow` 两步 UI、候选阶段命名、配置/管理 key、试听/采用 | TTS-1–TTS-2 | 已完成生产接线；真机 AX 待验收 | 第一步仅描述；无声音方案重表单；改名不重新生成；键盘/VoiceOver 可用 |
| TTS-4 | 临时候选 acquisition、`AudioImport`、manifest bind、名称投影和清理 | TTS-1–TTS-2 | 已完成 fixture 验证 | 坏音频 fail closed；失败保留旧绑定；仅采用一个 |
| TTS-5 | 文档、隐私披露、自动/手工/真实 provider 分层验收 | TTS-0–TTS-4 | 自动层完成；手工/真实层待验收 | 不含 key/内容；证据层级清楚；所有对应门禁通过 |

依赖关系：

~~~text
TTS-0 → TTS-1 → TTS-2 → TTS-3
                         └──→ TTS-4
TTS-5 等待 TTS-0...TTS-4
~~~

TTS 与非 TTS 宿主工作互不依赖；若同时触及 GUI tests、localization 或
`SoundPacksWindowModel`，共享文件必须顺序处理。本地实现已获授权并完成；真实 key、付费请求、
commit、push、release 或部署仍需分别授权。

## 7. 自动测试与回归命令

### 7.1 领域、凭据与 provider

- 空/过长描述；名称 trim、1...40 字符、控制字符和同名后缀；名称不得决定文件路径。
- speech / animal / soundEffect / mixed 四类 fixture；非语音时 `spokenContent == nil`。
- 候选页获得稳定名称建议；手工名称覆盖建议；名称不进入 generation request，修改名称不增加请求计数。
- hidden instruction version 被记录为非敏感 token；内部计划不出现在强制 UI 状态。
- 缺少 credential 不发网络；保存 key 后不自动生成；删除 key 后已采用声音仍可播放。
- credential save/replace/delete 使用 mock Keychain；新 key 验证/写入失败时旧 key 保持有效。
- request、state、error、description、日志和 manifest 的快照扫描均不含 key 或 Authorization。
- provider adapter 只访问 allowlisted endpoint，拒绝 redirect 和远端下载 URL；认证失败不 fallback。
- 恰好返回 3 个稳定候选；partial result、late result、取消、限流和有限重试符合状态机。
- 候选替换、symlink、格式伪装、超时长、超大小和下载中断时采用 fail closed。
- 同时试听第二个候选时第一个停止；无 autoplay。
- 导入/bind/refresh 部分失败显示真实状态，旧绑定保持不变。

### 7.2 回归命令

~~~bash
swift run --package-path helper claudio-tests
swift run --package-path gui claudio-gui-tests
swift build -c debug --package-path gui --product ClaudioGUI
jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings
git diff --check
~~~

不得用 `swift test` 代替两个项目测试入口。新增生产 UI 文案必须同时提供 English、`zh-Hans`，并
更新 `ClaudioL10nKey.allKnown`。

## 8. 真机与手工验收

### 8.1 macOS UI 与音频

- 未配置状态：只输入描述并点击生成，配置窗打开且描述不丢失；关闭后不发生请求。
- 配置状态：SecureField、焦点、取消、替换失败保留旧 key、删除二次确认和删除后生成门禁。
- 四类描述各完成一次 3 候选流程；候选不自动播放，同一时刻只试听一个。
- 第一步没有名称字段；候选页可直接修改建议名称且不重新发请求；空名称不能采用；成功后事件行
  显示最终名称，用户包 manifest 保留名称与音频身份的映射。
- 采用前仍播放旧绑定；采用成功后新名称/音频持久；失败时旧绑定不变。
- 关闭/重开窗口后已采用声音正常播放，其余临时候选已清理。
- 内置包路径要求先 fork；拒绝时原包不变。
- 键盘和 VoiceOver 完成配置、生成、试听、重命名、采用与错误恢复；焦点顺序与视觉顺序一致。

### 8.2 真实 provider 证据边界

自动测试使用 fake adapter 和测试 Keychain namespace，不需要真实 key。真实 provider smoke 必须另行
授权，并使用用户主动提供、可撤销、限额的测试 key；不得把 key、Authorization、完整 prompt、
响应正文或音频内容写进命令历史、文档、Git、issue、截图或日志。

验收报告分开记录：

- 自动测试与 build；
- 本地 GUI / VoiceOver / 音频导入；
- 真实 provider 的认证、请求、3 候选与错误回执；
- 未完成的地区、模型、付费、双架构、签名 RC 或正式发布证据。

没有真实 provider 回执时，只能声明 adapter/fixture 已验证，不能升级为真实生成已完成。

## 9. 失败模式

| 路径 | 失败 | 防线 | 用户可见结果 |
|---|---|---|---|
| 命名 | 三候选被当成三个永久名字 | final display name 与 variant label 分离 | 只保存采用项和一个名称 |
| 自动命名 | 名称被直接用作路径 | `AICueDisplayName` 与唯一文件分配器分离 | 显示名称可编辑，路径安全生成 |
| BYOK key | key 进入状态、日志或配置 | Keychain-only manager + 非日志化输入 + 静态扫描 | UI 只显示配置状态 |
| key 替换 | 新 key 无效导致旧 key 丢失 | validate/write 成功后原子切换 | 失败继续使用旧 key |
| endpoint | 自定义 URL 外送 key / SSRF | 单 provider registry + endpoint/redirect allowlist | 拒绝非内置地址 |
| provider 能力 | TTS 模型被宣传为可生音效 | TTS-0 官方能力门禁 + capability tests | 不支持类型明确阻止 |
| provider 输出 | MIME/响应体/声明格式伪装 | 私有 temp acquisition + sniff + AudioImport | 候选拒绝，旧声音不变 |
| 自动计费 | 保存 key 后自动生成/无限重试 | 二次显式 Generate + 有限重试 | 用户掌握每次请求时机 |
| partial publish | 导入或 bind 只完成一半 | 事务、回滚和真实磁盘状态投影 | 旧绑定保持，显示实际阶段 |

## 10. 明确不做

- 不新增或改名现有五个 `Event`，不修改 WorkBuddy 或其他宿主配置。
- v1 不做 claudi0 Hosted server、账号、额度、支付、订阅或 Hosted/BYOK 自动 fallback。
- v1 不做多 provider 选择、自定义 API base URL、自定义模型 ID 或区域自动切换。
- 不显示或恢复已保存 key 明文，不把 key 放进 CLI/env/config/日志/回执。
- 不恢复可见的“声音方案”强制步骤；内部 `AICueSoundPlan` 仍保留。
- 不做声音克隆、用户本人音色训练、音频编辑器、裁剪时间线或归一化工作台。
- 不一次生成整个声音包，不生成超过 3 秒或 5 MB 的候选。
- 不改变当前 macOS 12 最低版本，不为新 UI 强行采用更高系统专属 API。
- 不把原型、fixture、静态契约或本地 hash 升格为真实 provider、正式发布或商业验收。

## 11. 绿灯

只有以下条件同时成立，计划才算完成：

- 固定首发 provider/model 已通过官方能力、认证、隐私和错误契约门禁。
- 可见 UI 只有“描述 → 候选与命名”，第一步没有名称字段，内部 `AICueSoundPlan` 不成为强制重表单。
- 候选阶段自动建议并可无成本改名；空名称不能采用，最终名称随采用项进入用户声音包和事件绑定。
- API Key 可配置、替换和删除，Keychain-only，明文不越过凭据管理边界。
- 真实 adapter 返回并校验完整 3 候选；无自动播放；每次生成由用户显式触发。
- 选中候选完整走现有 `AudioImport` 和 manifest bind，任何失败保留旧声音。
- helper/GUI test harness、显式 GUI debug build、xcstrings 校验和 `git diff --check` 全绿。
- 自动、GUI/VoiceOver/音频、真实 provider 和未完成发布证据分别报告。
- 实施不得覆盖计划开始前不相关的已有修改；commit/push 仍需用户另行明确授权。

## 12. 原型与复用边界

当前交互原型 SoT：

`mockups/ai-app-manager-native-macos.html?page=events&app=workbuddy&prototype=tts&stage=applied&credential=ready`

原型状态在内存中；`credential=missing|ready` 只用于演示配置状态，不代表真实 Keychain。原型不得
接收真实 key 或冒充真实 provider 请求。

本计划继续复用现有：

- `Event` 的五个公共语义；
- `EventSettingsWindow` retained window、作用域/事件投影与 accessibility 入口；
- `SoundPacksWindowModel`、`SoundPacksWindowController` 的包级写入与 retained window handback；
- `AudioImport` 的 source acquisition、内容嗅探、时长/大小限制、包锁、安全发布和 manifest bind；
- 内置只读包与用户自有包边界；
- 现有测试 harness、播放 facade 和失败/刷新语义。

本计划新增 `AICueDisplayName`、隐藏 `AICueSoundPlan`、`AICueCredentialManaging`、单一 BYOK
`ElevenLabsAICueProvider` 和对应 UI 接缝；不得在 UI 或 adapter 中复制 `AudioImport`、包锁和 manifest
发布逻辑。

文档类型：工程执行计划，兼具内部接口 reference 与架构 explanation。本地 Swift 实现已完成；
真实 provider 探测、commit、push、release 和部署都需要后续单独授权。
