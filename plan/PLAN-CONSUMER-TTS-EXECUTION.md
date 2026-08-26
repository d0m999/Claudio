# PLAN — 描述式 AI 提示音（BYOK、多 Provider）执行计划

> 状态：**ElevenLabs 单 Provider 基线的本地实现与自动验证已完成；多 Provider 扩展、迁入统一设置、真机无障碍、真实 Provider 与发布证据待单独验收**
>
> 日期：2026-08-26
>
> 范围：AI 提示音命名、描述生成、隐藏的内部声音方案、allowlisted provider profile、按能力路由的
> BYOK 凭据管理、3 候选试听与现有 `AudioImport` / manifest bind 闭环。首批 Provider 目标为
> ElevenLabs、MiniMax 和 Qwen TTS；不支持任意自定义 endpoint、model 或 voice。
>
> 文件名沿用 `TTS` 以保持计划路径稳定；产品能力不再限定为文字转语音，也包括动物叫声、
> 简短音效和混合声音。
>
> 非 TTS 的 WorkBuddy、ChatGPT / Claude Desktop AX Beta、宿主能力矩阵和回执工作，见
> `plan/PLAN-CONSUMER-NON-TTS.md`。
>
> 九个设置目的页、统一窗口、路由与视觉迁移的总规格见
> `plan/PLAN-SETTINGS-EXPERIENCE.md`；本文件只拥有 AI 提示音子域合同。
>
> 本轮已完成 ElevenLabs 基线的本地 Swift 实现与 fixture 验证，并按 2026-08-26 官方文档冻结
> MiniMax/Qwen 的首批 profile、凭据验证策略和 transport 合同；仍未授权输入真实 key、发真实
> 供应商请求、付费探测、修改真实宿主配置、commit 或 push。
>
> 兼容性说明：`docs/adr/0006-use-elevenlabs-byok-with-fixed-modality-routing.md` 仍记录当前单
> Provider 基线；多 Provider 目标只有在 TTS-MP-0 至 TTS-MP-5 和对应验收完成后才视为已实现。

## 0. 目标与完成定义

用户先为一个现有 `Event` 选择一个已注册的 Provider profile，并描述想听到的声音。Claudio 在后台把
描述规范化为内部声音方案，使用该 Provider 的用户自有 API Key 请求对应能力路线，返回 3 个不超过
3 秒的临时候选。候选完整展示后，
系统根据描述提供名称建议；用户试听、确认或修改名称并显式采用一个候选，最终音频才以该名称
保存到「我的提示音」，再绑定到该事件。

完成后的用户结果：

- API Key 只需在页面级生成服务设置中配置一次，不重复出现在每个事件表单里；
- 用户可以显式选择已支持的 Provider；每个 Provider/profile 独立显示凭据状态，不把一个 Provider 的
  key 当作另一个 Provider 的 key；
- 描述阶段不要求命名；候选阶段显示系统建议名称，并允许用户在采用前直接修改；
- 可见主流程只有“描述 → 3 个候选”，不再强制展示独立的“声音方案”重表单；
- 描述可覆盖语音、动物叫声、简短音效或混合声音，`spokenContent` 可以为空；
- 语音或混合声音必须由用户在描述中明确给出台词，例如 `清晰地说“任务完成”`；本地解释器不得
  猜测、补写或调用隐藏 LLM 生成要说的文字；
- Provider 不支持当前声音类型时，在本地能力检查阶段阻止请求并保留描述，不把 TTS 模型冒充成纯音效模型；
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
| provider 范围 | 首批 allowlisted profile 包含 ElevenLabs、MiniMax、Qwen TTS；按 provider 能力支持声音类型，不允许自定义 base URL / model / voice |
| provider 选择 | 用户显式选择 Provider/profile；切换会使未采用候选失效，不自动 fallback 或跨供应商重试 |
| model / voice | 每个 profile 使用应用内固定且可审计的 model/voice；UI 不接受任意 model ID、voice ID |
| region | 需要区域的 Provider 使用显式 allowlisted region profile；不自动跨区，不把不同区域 key 混用 |
| 凭据保存 | macOS Keychain only；按 registry-owned credential slot 隔离；配置文件、日志、回执和 manifest 均不保存 key |
| 凭据状态 | “已保存”只表示 Keychain 可读，不等价于在线验证成功；ElevenLabs/MiniMax 使用只读 probe，Qwen 延迟到用户显式生成时验证 |
| 旧 Keychain 兼容 | `elevenlabs-global` 继续映射现有 account `elevenlabs`；不复制、不改名、不双写、不删除旧 item |
| 候选约束 | 每次恰好 3 个，每个不超过 3 秒、5 MB；不自动播放 |
| 网络重试 | 三个子请求顺序执行；网络、5xx 和未知计费结果不重试；明确 429 至多重试一次 |
| 时间预算 | 单次 generation 从点击开始最多 60 秒；每个子请求和 429 retry 都必须消耗同一剩余预算 |
| 采用边界 | 明确 `surface + event + packID`；独立用户包内完整 `AudioImport` + manifest bind 成功后才替换旧绑定 |

### 0.2 Provider 目录与能力契约

首批目标不是让用户输入任意 API 地址，而是由应用维护一个可审计的 Provider/profile allowlist。
`providerID`、区域、endpoint、model、voice、认证方式、响应解码方式和可用声音类型均属于应用内
profile。用户只选择 profile 并输入对应的 key；实现前必须重新核对官方文档和当前 API 响应，不能把
下面的计划快照当成永久 API 保证。以下资料按 2026-08-26 初查：

| Provider/profile | 凭据策略与固定请求路线 | 固定 model / voice / 输出处理 | 初始能力 | 状态 |
|---|---|---|---|---|
| `elevenlabs-global` | `readOnlyProbe`：`GET https://api.elevenlabs.io/v1/models`；生成使用 `xi-api-key`；credential slot 固定为旧 account `elevenlabs` | speech：`eleven_v3` + voice `JBFqnCBsd6RMkjVDRZzb`；sound generation：`eleven_text_to_sound_v2`；直接 MP3 | `speech`、`mixed`、`animal`、`soundEffect` | 已有基线 adapter；迁入 registry 时保持 route、voice 和旧 key 回归兼容 |
| `minimax-global` | `readOnlyProbe`：`POST https://api.minimax.io/v1/get_voice`，body 固定为 `{"voice_type":"all"}`；生成使用 Bearer + `POST https://api.minimax.io/v1/t2a_v2` | `speech-2.8-hd` + voice `Chinese (Mandarin)_Reliable_Executive`；`output_format: hex`；32 kHz / 128 kbps / mono MP3；响应 `data.audio` 解 hex | 首批只开放 `speech` 和 `zh` / `zh-Hans`；sound tags / voice effects 不等价于纯音效生成 | 计划新增 unary adapter |
| `qwen-singapore` | `deferredUntilExplicitGeneration`；Bearer + `POST https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation`；`X-DashScope-SSE: enable` | `qwen3-tts-instruct-flash` + voice `Cherry`；SSE Base64 PCM，24 kHz / 16-bit / mono / little-endian，封装 WAV | 首批只开放 `speech`；locale 仅映射 `zh* → Chinese`、`en* → English` | 计划新增 SSE adapter；保存 key 时不发可计费请求 |
| `qwen-beijing` | `deferredUntilExplicitGeneration`；Bearer + `POST https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation`；独立 region key | 与 Singapore 相同的 model、voice、SSE 和 PCM 合同 | 与 `qwen-singapore` 相同，必须单独做地区 smoke | 计划新增独立 profile；不得隐式自动切换 |

能力规则：

- `speech` 是 TTS provider 的最低共同能力；`mixed` 只有在 adapter 能证明同时满足语音和混合声音
  语义时才可加入该 profile 的 `routes`。
- `animal` 和 `soundEffect` 不能因为请求文本里出现声音描述就自动降级到 TTS。首批仍由 ElevenLabs
  Sound Generation 提供；MiniMax/Qwen 只有在新增官方能力证据、请求/响应 fixture 和 3 秒输出测试
  全部通过后，才能单独开放对应 modality。
- MiniMax 的同步 T2A 会返回 JSON 中的 hex 音频；adapter 必须验证 `base_resp.status_code == 0`、
  `data.audio` 非空且可完整解码，并使用官方 metadata 作为诊断输入，不能直接信任 `audio_length`。
- MiniMax v1 固定 Mandarin system voice；非 `zh` locale 在本地拒绝，不让模型猜语言，也不临时切换
  voice。增加英语或其他语言必须新增独立、可审计的 profile。
- Qwen 的非 streaming 模式返回 24 小时有效的音频 URL；本计划只用 SSE streaming 收集 Base64 PCM，
  丢弃末包 URL。PCM 固定按 24 kHz、signed 16-bit、mono、little-endian 生成合法 WAV 头，再做 magic
  bytes 与 duration probe；缺少、冲突或漂移的格式参数使 profile fail closed。
- `routes` 是 modality 的唯一真相：`supportedModalities` 必须从 `Set(routes.keys)` 计算，不能在 profile
  中维护第二份可漂移的 capability set。
- 每个 generation 仍顺序发出 A/B/C 三个独立子请求；provider 的同步、SSE 或编码差异不能改变统一
  的候选、60 秒 generation deadline、3 秒、5 MB 和全有或全无发布合同。

官方契约证据：

- [ElevenLabs Authentication](https://elevenlabs.io/docs/api-reference/authentication)
- [ElevenLabs List models](https://elevenlabs.io/docs/api-reference/models/list)
- [ElevenLabs Text to Speech](https://elevenlabs.io/docs/api-reference/text-to-speech/convert/)
- [ElevenLabs Prompting Eleven v3](https://elevenlabs.io/docs/best-practices/prompting)
- [ElevenLabs Sound Effects](https://elevenlabs.io/docs/api-reference/text-to-sound-effects/convert)
- [ElevenLabs API errors](https://elevenlabs.io/docs/eleven-api/resources/errors)
- [MiniMax Text to Speech (T2A) HTTP](https://platform.minimax.io/docs/api-reference/speech-t2a-http)
- [MiniMax Get Voice](https://platform.minimax.io/docs/api-reference/voice-management-get)
- [MiniMax API overview](https://platform.minimax.io/docs/api-reference/api-overview)
- [Qwen non-real-time speech synthesis](https://www.alibabacloud.com/help/en/model-studio/non-realtime-tts-user-guide)
- [Qwen-TTS voice list](https://www.alibabacloud.com/help/en/model-studio/qwen-tts-voice-list)
- [Model Studio regions and access domains](https://www.alibabacloud.com/help/en/model-studio/regions/)
- [Model Studio API key](https://www.alibabacloud.com/help/en/model-studio/get-api-key)

每个 Provider 的数据留存、模型改进、计费和地区规则分别披露；Claudio 不把 ElevenLabs 的条款
推广到 MiniMax/Qwen，也不对任何 Provider 统一承诺 zero retention。真实付费 smoke 仍需要单独授权。

### 0.2.1 新 Provider 的准入清单

以后增加 OpenAI、Google、Azure、CosyVoice 或其他 TTS API 时，不能只新增一个枚举值。每个 Provider
必须单独提交以下材料并通过同一门禁：

1. 官方认证、endpoint、region、model、voice、输出格式、限额、计费和数据处理链接；
2. 一个或多个 immutable profile、固定 routes/transport，并从 `routes.keys` 派生
   `supportedModalities`；
3. provider-neutral request 到实际 API body/header 的编译器，不把 provider 字段泄漏进领域模型；
4. 成功、空响应、畸形响应、认证/额度/限流/5xx、取消和输出过大 fixture；
5. 真实 provider smoke 的单独授权、可撤销限额 key、3 候选回执和未完成项记录。

Provider 只有在 `speech` 路线通过后才能显示为可用；纯音效、动物叫声、混合声音和声音克隆都是
独立 capability，不能从“有 TTS API”推导出来。

### 0.2.2 跨文档 SoT 对齐门禁

本计划拥有 AI 提示音领域、Provider、凭据和音频合同，但不单独拥有统一设置视觉、原型或 issue
拆分。任何多 Provider 实现 ticket 进入 agent 前，TTS-MP-0 必须让以下 SoT 同步指向同一合同：

1. ADR 0006 从 ElevenLabs-only 修订为 allowlisted multi-provider，并保留“无任意 URL/model/voice”；
2. `plan/PLAN-SETTINGS-EXPERIENCE.md` 明确 Provider/profile 选择、逐 profile 状态和差异化保存文案；
3. 当前原型增加 ElevenLabs、MiniMax、Qwen profile 和能力不支持状态；在此之前它只能证明
   ElevenLabs 核心闭环交互，不能作为多 Provider UI 验收 SoT；
4. GitHub #92 只承担统一设置中的 AI 提示音 UI 集成；provider-neutral foundation、credential policy、
   ElevenLabs 回归、MiniMax adapter、Qwen adapter 分成独立子 tickets，并按本计划依赖关系连接。

截至 2026-08-26，设置计划仍写死 ElevenLabs，原型仍显示“固定一个首发服务”，#92 虽带
`ready-for-agent` 但 body 仍是 ElevenLabs-only 的 `missing/configured/unavailable` 合同。本次授权只
修改本计划，所以上述 ADR、设置计划、原型和 issue 尚未同步。在 TTS-MP-0 完成前，#92 的现有 label
不得作为执行授权，也不得把 `TTS-MP-1...TTS-MP-5` 标记 ready-for-agent 或把单 Provider 原型描述成
多 Provider 已设计。

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
provider/profile selection + natural-language description + locale
          │
          ▼
AICueGenerationEngine
          │ local interpret + normalize with versioned hidden rules
          ▼
internal AICueSoundPlan
          │ capability check + provider-neutral A/B/C request compilation
          ▼
allowlisted AICueProviderRegistry
          ├── ElevenLabs adapter ──► fixed HTTPS endpoints
          ├── MiniMax adapter ─────► fixed HTTPS endpoint
          └── Qwen adapter/profile ─► fixed region HTTPS/SSE endpoint
          │
          ▼
3 private temporary candidates
          │ explicit Use + final display name + captured adoption target
          ▼
existing AudioImport + manifest bind
~~~

架构分为五个独立接缝：

1. `CredentialManager` 只管理 provider/profile 凭据状态、验证、替换和删除；UI 只看到状态。
2. `AICueGenerationEngine` 接收描述，通过确定性的 `AICueSoundPlanner` 在本地生成并保留内部
   `AICueSoundPlan`，但不发起额外 LLM
   “解释请求”，也不把方案投影成强制 UI。
3. `AICueProviderRegistry` 只返回应用内注册的 profile 和 adapter；它负责 provider/profile、区域、
   capability 与 adapter 的对应关系，不接受用户输入的 URL、model 或 voice。
4. `ProviderAdapter` 把 provider-neutral request 编译成自己的 HTTP、SSE 或编码格式；播放器和
   `AudioImport` 永远只接触已落入应用私有临时目录且经过初步校验的本地音频资产。
5. `AICueAdoptionTarget` 把 `surface + event + packID` 从可变 UI 选择中冻结出来；采用前重新验证目标
   仍隔离、可编辑且有效，再进入既有发布链。

隐藏生成指令是质量机制，不是安全边界。provider 的 models JSON、状态码、MIME 和音频响应体
一律视为不可信输入，仍需结构校验、流式字节边界和 `AudioImport` 全链防线。

## 2. 领域模型与深接口

### 2.1 领域类型

~~~swift
struct AICueProviderID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String

    static let elevenLabs = AICueProviderID(rawValue: "elevenlabs")
    static let miniMax = AICueProviderID(rawValue: "minimax")
    static let qwen = AICueProviderID(rawValue: "qwen")
}

struct AICueProviderProfileID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String

    // 只允许由 AICueProviderRegistry 创建和解析，不接受任意用户字符串。
    static let elevenLabsGlobal = AICueProviderProfileID(rawValue: "elevenlabs-global")
    static let miniMaxGlobal = AICueProviderProfileID(rawValue: "minimax-global")
    static let qwenSingapore = AICueProviderProfileID(rawValue: "qwen-singapore")
    static let qwenBeijing = AICueProviderProfileID(rawValue: "qwen-beijing")
}

struct AICueCredentialSlotID: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    // 兼容既有生产 Keychain account；profile ID 与 credential slot 不要求同名。
    static let legacyElevenLabs = AICueCredentialSlotID(rawValue: "elevenlabs")
    static let miniMaxGlobal = AICueCredentialSlotID(rawValue: "minimax-global")
    static let qwenSingapore = AICueCredentialSlotID(rawValue: "qwen-singapore")
    static let qwenBeijing = AICueCredentialSlotID(rawValue: "qwen-beijing")
}

enum AICueCredentialValidationPolicy: Sendable, Equatable {
    case readOnlyProbe
    case deferredUntilExplicitGeneration
}

struct AICuePCMFormat: Sendable, Equatable {
    let sampleRate: Int
    let bitsPerSample: Int
    let channels: Int
    let isLittleEndian: Bool
}

struct AICueProviderConstraints: Sendable, Equatable {
    let supportsInstructionControl: Bool
    let maximumDurationMilliseconds: Int
}

enum AICueProviderAudioTransport: Sendable, Equatable {
    case directContainer
    case hexEncodedContainer
    case ssePCM(AICuePCMFormat)
}

enum AICueProviderAuthentication: String, Sendable, Equatable {
    case elevenLabsAPIKeyHeader
    case bearerAPIKey
}

struct AICueProviderRoute: Sendable, Equatable {
    let modality: AICueModality
    let endpoint: URL // 由 registry 固定；不得来自用户输入
    let modelID: String
    let voiceID: String?
    let supportedLanguageTags: Set<String>
    let authentication: AICueProviderAuthentication
    let transport: AICueProviderAudioTransport
}

struct AICueProviderProfile: Sendable, Equatable {
    let id: AICueProviderProfileID
    let providerID: AICueProviderID
    let credentialSlotID: AICueCredentialSlotID
    let credentialValidationPolicy: AICueCredentialValidationPolicy
    let regionID: String?
    let displayName: String
    let routes: [AICueModality: AICueProviderRoute]
    let constraints: AICueProviderConstraints

    var supportedModalities: Set<AICueModality> { Set(routes.keys) }
}

struct AICueProviderRequest: Sendable, Equatable {
    let profileID: AICueProviderProfileID
    let modality: AICueModality
    let prompt: String
    let spokenContent: String?
    let languageTag: String?
    let targetDurationMilliseconds: Int
    let variant: AICueVariant
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
    let providerProfileID: AICueProviderProfileID // 来自 registry，不由用户输入

    init(
        description: String,
        locale: String,
        providerProfileID: AICueProviderProfileID
    ) throws
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
    let profileID: AICueProviderProfileID
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

enum AICueCredentialVerification: Sendable, Equatable {
    case verifiedByReadOnlyProbe
    case deferredUntilExplicitGeneration
    case explicitGenerationRejected
}

enum AICueCredentialStatus: Sendable, Equatable {
    case missing
    case stored(
        profileID: AICueProviderProfileID,
        verification: AICueCredentialVerification
    )
    case unavailable
}
~~~

`AICueDisplayName`、`AICueAdoptionTarget` 和 `Event` 都不属于 `AICueGenerationRequest`，也不得
发送给 provider；名称只在候选阶段随采用操作进入本地发布链。名称与文件身份必须分离：
`AICueDisplayName` 是用户可见 manifest 元数据；导入后的文件名继续由现有
唯一分配器生成，绝不把原始名称、描述或 provider 文件名直接变成路径。若同一用户包已有同名
提示音，发布前按现有包规则生成可见后缀（例如“ 2”），并在成功态显示最终名称。

`spokenContent` 和 `languageTag` 对动物叫声、纯音效必须为 `nil`；对 `.speech` / `.mixed`，
`spokenContent` 必须是用户明确写出的原文。不能因为“产品也支持无文字音效”就让语音 adapter 在没有
确切台词时猜测要说什么。

`AICueProviderProfileID` 是用户选择的已注册 profile，不是可拼接 URL 的自由字符串。Profile 可以
携带 provider、区域、固定 endpoint、model、voice、认证方法和响应解码策略，但这些值不进入可变
用户输入。`qwen-singapore` 与 `qwen-beijing` 是两个不同 credential scope；区域切换必须重新选择
profile 并使用对应的 key。`routes` 的 key 集合是生成前的唯一能力门禁，不能维护第二份
`supportedModalities` 后在 adapter 失败时偷偷把 `animal` / `soundEffect` 降级为 TTS。Registry
初始化必须验证 route key 与 `route.modality` 相同、每个 modality 恰好一条 route、endpoint origin
与 authentication policy 匹配，否则整个 profile 不注册。

### 2.2 深接口

~~~swift
protocol AICueCredentialProbing: Sendable {
    func probe(_ credential: SensitiveCredentialInput) async throws
}

protocol AICueProvider: Sendable {
    var profile: AICueProviderProfile { get }

    func generateCandidate(
        request: AICueProviderRequest,
        credential: SensitiveCredentialInput
    ) async throws -> AICueProviderAudioResponse
}

protocol AICueProviderRegistry: Sendable {
    func profiles() -> [AICueProviderProfile]
    func profile(for profileID: AICueProviderProfileID) throws -> AICueProviderProfile
    func provider(for profileID: AICueProviderProfileID) throws -> any AICueProvider
    func credentialProbe(
        for profileID: AICueProviderProfileID
    ) throws -> (any AICueCredentialProbing)?
}

protocol AICueGenerating: Sendable {
    func generate(
        description: String,
        locale: String,
        providerProfileID: AICueProviderProfileID
    ) async throws -> AICueGeneration
    func discard(generationID: UUID) async
    func discardAll() async
}

protocol AICueCredentialManaging: Sendable {
    func status(for profileID: AICueProviderProfileID) async -> AICueCredentialStatus
    func save(
        _ credential: SensitiveCredentialInput,
        for profileID: AICueProviderProfileID
    ) async throws -> AICueCredentialStatus
    func delete(for profileID: AICueProviderProfileID) async throws
    func cancelPendingReplacement(for profileID: AICueProviderProfileID) async throws
}
~~~

`AICueGenerationRequest` 的 initializer 和 `AICueGenerating.generate` 都必须接收选定的
`providerProfileID`，由 view model 从 registry 选择后传入；不能在 engine 内继续隐式写死 ElevenLabs。
`AICueSoundPlanner` 是无网络、确定性的值类型；`AICueProviderRequestCompiler` 把内部方案和选定
profile 编译为 provider-neutral 的 A/B/C 请求，adapter 再将其映射到自己的 HTTP、SSE 或编码格式，
不需要额外的解释模型。`SensitiveCredentialInput` 只能由凭据表单到
`AICueCredentialManaging` 的一次性调用创建，不得
实现 `Codable`、`Equatable`、`CustomStringConvertible` 或可日志化描述。真实 provider client 在其
私有实现中临时借用 Keychain 值并构造认证请求；公共生成请求、view model、错误和 provenance
都不能携带明文 key。

`AICueCredentialManager` 必须按 profile 从 registry 解析验证策略和可选 probe，不能继续注入一个
只会验证 ElevenLabs 的全局 validator：

- ElevenLabs 用 `GET /v1/models`，MiniMax 用 `POST /v1/get_voice` 做不生成音频的
  `readOnlyProbe`；probe 成功后才把新值原子替换为 active credential。
- Qwen 没有由 Model Studio API Key 自身完成的安全只读验证合同；保存时只做本地输入检查和 Keychain
  写入，返回 `.deferredUntilExplicitGeneration`，绝不为“验证”偷偷触发可计费生成。
- “已保存”只证明对应 Keychain slot 可读；UI 不得把 deferred 状态写成“连接已验证”。

Keychain service 继续固定为 `com.claudio.ai-cue.byok`；slot 由 registry 明确映射，不能简单由
profile ID 拼接。`elevenlabs-global` 继续读写现有 account `elevenlabs`，因此不做
rename/copy/delete/dual-write migration；MiniMax、Qwen Singapore、
Qwen Beijing 的 active account 分别固定为 `minimax-global`、`qwen-singapore`、`qwen-beijing`。
Qwen pending replacement 使用 registry 固定的 `<active>.pending` account，后缀不能来自用户输入。
删除某个 profile 只删除该 profile 的 active/pending item，随后生成进入
`.credentialRequired`，但已经导入的提示音不受影响。

替换 key 必须 fail closed。对 `readOnlyProbe` profile，probe 或 Keychain 原子替换失败时旧 active
credential 保持有效。对 deferred Qwen profile，已有 active key 时新值先写 pending slot；下一次用户
显式生成只试 pending，不自动 fallback。成功后提升为 active；只有明确 401/invalid-credential 才
丢弃 pending 并保留旧 active。403/模型权限、额度、429、5xx 或网络错误都不能证明 key 无效，保留
pending 与旧 active，允许用户重试或取消替换。没有旧 active 时，新值作为 stored-unverified active
保存；首次显式生成成功后标记已验证，失败则保留 key 并记录脱敏 verification 状态，等待用户替换或删除。

`AICueProvider` 是真实外部接缝；网络、Keychain、时间和 duration probe 只能通过 adapter 注入测试。
解释器、A/B/C prompt compiler、候选集合与采用目标验证保持 Foundation-only，测试不穿透私有
HTTP 或 Keychain 实现。

### 2.3 Unary 与 SSE transport seam

现有 transport 会对所有请求无条件注入 `xi-api-key` 并把完整响应缓冲为 `Data`，不能直接扩展为
Bearer 和 SSE。多 Provider 实现必须先拆成两个 transport seam，且公共 request value 不携带 secret：

~~~swift
struct AICueOrigin: Hashable, Sendable {
    let scheme: String // v1 只允许 https
    let host: String // lowercase ASCII host
    let effectivePort: Int // https 默认归一为 443
}

struct AICueSSEEvent: Sendable, Equatable {
    let dataLines: [String]
}

struct AICueTransportRequest: Sendable {
    let method: AICueHTTPMethod
    let url: URL
    let expectedOrigin: AICueOrigin
    let headers: [String: String] // 禁止 Authorization / xi-api-key
    let body: Data?
    let maximumWireBytes: Int
}

protocol AICueUnaryTransport: Sendable {
    func send(
        _ request: AICueTransportRequest,
        authentication: AICueProviderAuthentication,
        credential: SensitiveCredentialInput
    ) async throws -> AICueHTTPResponse
}

protocol AICueSSETransport: Sendable {
    func events(
        for request: AICueTransportRequest,
        authentication: AICueProviderAuthentication,
        credential: SensitiveCredentialInput
    ) -> AsyncThrowingStream<AICueSSEEvent, Error>
}
~~~

Transport 先验证 `scheme + host + effective port` 与 `expectedOrigin` 完全相同，再按非敏感
authentication enum 注入一次 credential；redirect 一律拒绝，adapter 不能自己拼认证 header。Unary
client 对 MiniMax JSON 和 ElevenLabs container 做有界读取；SSE client 增量解析 event，不把完整 stream
先收进内存。两者都使用 ephemeral、无 cookie/cache/URLCredentialStorage 的 `URLSession`，并把取消、
wire-byte ceiling、终态和 exact final URL 作为协议合同。

Qwen SSE parser 是独立 Foundation-only 值/actor seam。它必须处理任意 callback 分片、LF/CRLF、空行
事件边界、`data:` 行、Base64 跨 chunk、唯一 terminal `finish_reason == stop`、terminal 后数据、取消和
EOF-before-terminal；末包远端 URL 只解析后丢弃。不得把 ElevenLabs/MiniMax/Qwen adapter、registry、
SSE parser 和 transport 继续堆进同一个 `AICueProvider.swift`。

### 2.4 确定性语音文本语法

本地 planner 只接受用户明确写出的台词，不使用隐藏 LLM：

- 中文示例：`清晰、克制地说“任务完成”`、`先响木琴，再说「本轮结束」`；
- 英文示例：`Say "Task complete" in a calm voice`；
- `.speech` / `.mixed` 的 `spokenContent` 必须来自成对的 `“”`、`「」`、`『』` 或 `""`，trim 后非空；
- 描述含 `说` / `say` / `voice` 等语音意图却没有完整引号时，返回本地
  `.spokenContentRequired(example:)`，不读 key、不发网络；
- adapter 的实际 `text` 字段只取 `spokenContent`；style/instructions 来自其余描述并受 profile 的
  instruction 合同约束，不能把整个声音描述当作要朗读的文字。

描述输入旁显示简短帮助：“需要人声时，请用引号写出台词，例如：清晰地说‘任务完成’”。该语法既
避免模型猜台词，也保留动物叫声和无文字音效的自由描述。

## 3. 用户流程与状态

### 3.1 页面级凭据流程

1. “事件与提示音”页顶部显示全局“AI 声音生成服务 · 自备 API Key”状态卡。
2. 显示已注册的 Provider/profile 列表和当前选择；每项只显示 `missing`、`stored + verification`
   或 `unavailable`，不显示 key 内容。“已保存”与“已验证”必须是两个不同语义。
3. 默认选择 `elevenlabs-global` 以保持现有行为；用户可以显式切换到已注册的 MiniMax 或 Qwen
   profile。选择结果是非敏感偏好，不能包含 key、Authorization 或原始请求内容。
4. 未配置当前 profile 时显示该 Provider 的 key 表单；Qwen profile 还显示明确的 region 说明，
   但不接受自由 endpoint。ElevenLabs/MiniMax 的主按钮为“验证并保存”，只调用各自 read-only probe；
   Qwen 的主按钮为“保存 API Key”，辅助文案明确“将在你下一次点击生成时验证，保存不会产生模型
   调用或费用”。
5. 删除前二次确认，并明确“不能继续使用该 profile 生成，但已采用提示音不受影响”。删除一个
   profile 的 active/pending credential，不删除其他 profile 的 key。
6. 如果用户在未配置时点击“生成 3 个候选”，保留声音描述和 profile 选择，打开配置界面；保存后返回
   原表单，
   **不自动发起可能计费的生成请求**，仍由用户再次点击生成。
7. Qwen replacement 处于 pending 时显示“新 Key 待首次生成验证”，并提供“取消替换”；失败时不得
   暗中切回旧 key 重试，也不得把网络/额度错误误标为 key 无效。

原型中不得请求或持久化真实 key，只接受演示字符并明确标注。正式版用 `SecureField`、关闭拼写
检查和自动填充；不得提供“显示明文”或复制已保存 key 的能力。

### 3.2 单事件生成流程

1. 选择现有事件。
2. 选择已配置的 Provider/profile；切换 profile 时，任何未采用候选立即失效，但已经采用的提示音
   不受影响。切换会取消当前 generation；旧 profile 的迟到响应以 `generationID + profileID` 不匹配
   为由丢弃并清理，不能覆盖新选择的状态。
3. 描述想听到的声音；第一步不显示或要求“提示音名称”，描述不能为空。选择 speech-only profile
   时显示引号台词示例，但不新增“声音方案”表单。
4. 点击“生成 3 个候选”后，后台用版本化隐藏指令解释并规范化 `AICueSoundPlan`；先检查所选 profile
   的 route、语言和 spoken-content invariant，再读取对应 credential；不显示独立确认表单。
5. 如果 modality 不在 `routes.keys`、locale 不在 route allowlist，或 speech/mixed 缺少明确引号台词，
   直接显示可修正的本地错误，不读 key、不发网络；保留描述并允许修改或切换 profile。
6. 以点击时冻结的 `generationID + profileID + 60 秒 absolute deadline` 请求选定 provider，完整取得并
   校验 3 个候选后一次性展示；不自动播放，同一时刻最多播放一个。Qwen deferred key 只在这一步
   被真实验证，且绝不自动 fallback 到旧 key、其他 region 或其他 Provider。
7. 候选页用 `AICueSoundPlan.suggestedDisplayName` 预填“提示音名称”；名称是必填的最终保存元数据，
   但不属于任一候选的生成参数。
8. 用户可在试听期间直接修改名称；改名不重新生成，“修改描述”或切换 profile 才返回输入态并使旧
   候选失效。
9. “用于此事件”先校验名称并停止试听，再把候选与最终 `AICueDisplayName` 送入现有导入链。
10. 只有导入与 manifest bind 都成功才显示完成；失败保留当前声音，不发布假刷新。

凭据状态与生成状态正交，不把配置弹窗塞进 generation state machine：

~~~text
ProviderSelectionState:
selected(profileID) / unavailable

CredentialState (per profile):
missing / stored(verified | deferred | rejected) / unavailable
          └── probing / saving / pendingReplacement / deleting
              （独立 activity；失败时按 validation policy 保留 active/pending）

GenerationState:
editing → generating → candidatesReady → adopting → applied
   ↑          └── failed / cancelled ──┘       └── failed → candidatesReady
   └── 修改描述 / 切换 profile / 重新生成会使旧候选失效；迟到结果按 generation identity 丢弃
~~~

关闭窗口、修改描述或重新生成时清理未采用的临时候选；仅重命名不能清理或重新请求候选。已导入
声音由现有包目录和 manifest 接管，不能被临时清理删除。

## 4. BYOK 网络、隐私与凭据边界

- v1 由 Claudio 本机直接调用 allowlisted provider/profile；不经过 claudi0 Hosted server。
- 用户应在首次配置每个 profile 前看到对应 Provider 的数据边界：描述、隐藏规范化结果和生成所需
  元数据会发送给该 provider；其留存、模型改进、地区处理和计费规则受 provider 条款约束，Claudio
  不能承诺替 provider 删除。
- API endpoint 和 redirect host 必须按 profile allowlist 校验；不接受用户输入 base URL、model ID、
  voice ID 或远端下载 URL。Qwen 的计划路线使用 SSE 音频数据，避免把临时结果 URL 变成任意下载入口，
  防止 SSRF、凭据外送和任意网络访问。
- key 只存 macOS Keychain，且按 registry-owned credential slot 隔离；不得进入 `UserDefaults`、
  `config.json`、CLI 参数、环境变量、日志、analytics、receipt、crash metadata、生成请求值类型、
  音频 metadata 或 manifest。
- Qwen 的区域 key 不可互换；选择 `qwen-singapore` 或 `qwen-beijing` 时，只能读取该 profile 的
  credential。区域变更必须是用户显式动作，并使未采用候选失效。
- provider 请求/响应的 content logging 默认关闭。诊断只允许 provider ID、model ID、opaque request
  ID、profile/region ID、错误分类、latency、重试次数和字节/时长计量。
- 原始描述和内部 `AICueSoundPlan` 只驻留本次内存状态；关闭、改描述或取消后释放。首版正式落盘
  只保存最终提示音名称、音频和现有 manifest 绑定；候选 provenance 不持久化。
- 认证失败、额度不足、限流或 modality 不支持时，不得自动 fallback 到其他 provider、Hosted 路线、
  其他区域或其他 key；跨路线/供应商必须是用户新的显式选择。
- Qwen 的 `.deferredUntilExplicitGeneration` 是诚实状态，不是错误；只有用户点击生成后的认证/权限
  回应才能更新验证状态。保存、页面加载和后台刷新都不能发模型请求。
- 生成按钮可能触发用户供应商账户计费；UI 不得在保存 key 后自动生成或后台重试无限次。

## 5. Provider 输出与音频安全发布

provider 输出不得绕过现有 `AudioImport`：

- 网络层设置连接/请求 inactivity timeout、60 秒 generation absolute deadline、有限重试、exact-origin
  redirect rejection 和流式大小上限；取消与 429 retry 不能重置 generation deadline；
- 只接收现有 allowlist：WAV、MP3、AIFF、M4A；最大 5 MB、最大 3 秒；
- provider 状态码、MIME、响应体和声明格式均不可信，必须检查状态码、流式字节上限、magic bytes、
  sniffed format 和 duration probe；
- ElevenLabs adapter 继续只接收固定 endpoint 的直接音频响应；MiniMax adapter 只接受成功 JSON 中
  的 hex 音频并在内存中解码；Qwen adapter 只接受 allowlisted SSE 事件中的 Base64 PCM，并在本地
  生成带正确格式参数的 WAV。任何 provider 返回的 URL 默认拒绝，不得绕过下载 allowlist；
- 编码解码前后都执行独立上限，防止 hex/Base64 膨胀绕过限制：ElevenLabs 直接音频 wire/decoded
  均不超过 5 MiB；MiniMax JSON wire 不超过 10 MiB hex + 512 KiB envelope，decoded MP3 不超过
  5 MiB；Qwen SSE wire 不超过 256 KiB，累计 decoded PCM 不超过 144,000 bytes（24 kHz × 16-bit ×
  mono × 3 秒），封装后 WAV 不超过 144,044 bytes；
- Qwen PCM 的容器封装失败、格式冲突、Base64 非法、事件顺序异常或 EOF-before-terminal 时，整个
  候选失败；不能把原始 PCM 仅改名为 `.wav`；
- 响应先写入应用私有临时目录，使用唯一临时文件和安全权限，不跟随 symlink；
- 三个候选必须属于同一 generation 且完整通过校验后才进入 `candidatesReady`；不展示部分结果；
- 采用时继续复用 source acquisition、regular-file 检查、唯一文件名、包锁、安全 publication、
  manifest bind 和刷新语义；
- 内置包仍只读，用户必须先复制为自有包再保存生成结果；
- 导入成功但绑定失败、绑定成功后刷新失败等部分成功，必须显示真实磁盘状态，不能假装整体完成。

## 6. 实施顺序

| Task | 内容 | 主要依赖 | 当前状态 | 完成门槛 |
|---|---|---|---|---|
| TTS-0 | ElevenLabs 基线 provider/model、能力、隐私契约与本地 adapter | — | 已完成 | 原有 ElevenLabs 路线继续通过现有 fixture；其证据保留为回归基线 |
| TTS-1 | `AICueDisplayName`、`AICueSoundPlan`、generation/adoption target、candidate/error 与双状态机 | TTS-0 | 单 Provider 基线已完成；需 provider-neutral 修订 | profile 选择不进入采用目标；名称不进入 provider request；3 候选契约稳定 |
| TTS-2 | 单 Provider Keychain manager 与 adapter 基线 | TTS-0–TTS-1 | ElevenLabs fixture 已完成；多 profile 扩展待做 | 旧 key 可读；替换/删除 fail closed；无自定义 endpoint/model/voice |
| TTS-MP-0 | 冻结官方 API/地区/voice/格式/验证策略，并同步 ADR 0006、设置计划、原型与 #92 拆分 | TTS-0 | 本计划合同已冻结；其余 SoT 尚未同步，未完成 | 四个 profile 有 exact route、credential policy、能力/语言/费用/隐私/错误矩阵；ADR、设置计划、原型和 tickets 无冲突 |
| TTS-MP-1 | provider-neutral 领域类型、route-derived capability、registry、确定性语音文本语法与 request compiler | TTS-MP-0 | 待做 | 公共接口不依赖 `ElevenLabsAICueCompiledRequest`；profile 只能来自 registry；speech/mixed 无明确台词时本地失败 |
| TTS-MP-1T | hardened unary/SSE transports、exact-origin auth injection、增量 SSE parser、wire/decoded ceilings 与 generation deadline | TTS-MP-1 | 待做 | transport 不保存 secret；Bearer/xi-api-key 正确隔离；SSE fragmentation/cancel/terminal 与 60 秒 deadline 全覆盖 |
| TTS-MP-2 | registry-owned credential slots、read-only/deferred validation policy、Qwen pending replacement 与非敏感 profile/region 偏好 | TTS-MP-1 | 待做 | `elevenlabs-global → elevenlabs` 无迁移；region key 不混用；read-only/deferred 状态诚实；快照与日志无明文 |
| TTS-MP-3 | ElevenLabs adapter 接入 registry 并实现统一 response/provenance 合同 | TTS-MP-1T | 已有 adapter 待重接 | 固定 endpoint/model/voice、read-only probe、四类 route 和 3 候选回归通过；旧 account 兼容由 MP-2 覆盖 |
| TTS-MP-4 | MiniMax `speech-2.8-hd` unary T2A adapter | TTS-MP-1T | 待做 | Bearer、`get_voice` probe、固定 voice、JSON/hex、MP3、语言门禁、错误与 3 候选 fixture 全覆盖；只开放 `speech` |
| TTS-MP-5 | Qwen `qwen3-tts-instruct-flash` SSE adapter 与 region profiles | TTS-MP-1T | 待做 | 固定 host/path/header/model/voice、SSE/Base64 PCM、合法 WAV、取消/大小/终态校验；只开放 `speech`，地区 smoke 分开 |
| TTS-3 | 事件页 Provider/profile 选择、逐 profile 配置/管理 key、能力不支持提示、候选试听/采用 | TTS-MP-2–TTS-MP-5 | 单 Provider UI 已完成；多 Provider UI 待做；统一设置迁移与真机 AX 待验收 | 默认 ElevenLabs；切换不自动生成；不支持 modality 在网络前阻止；改名不重新生成；键盘/VoiceOver 可用 |
| TTS-4 | 临时候选 acquisition、`AudioImport`、manifest bind、名称投影和清理 | TTS-1–TTS-MP-1 | 已完成 fixture 验证 | 所有 adapter 输出走同一安全导入链；坏音频 fail closed；失败保留旧绑定；仅采用一个 |
| TTS-5 | 文档、按 Provider 的隐私/费用披露、自动/手工/真实 provider 分层验收 | TTS-MP-0–TTS-4 | ElevenLabs 自动层完成；多 Provider、手工/真实层待验收 | 不含 key/内容；每个 profile 的能力/地区/费用证据清楚；所有对应门禁通过 |

依赖关系：

~~~text
TTS-0 → TTS-MP-0 → TTS-MP-1 ─┬─→ TTS-MP-2 ────────────────────┐
                              └─→ TTS-MP-1T ─┬─→ TTS-MP-3 ────┤
                                             ├─→ TTS-MP-4 ────┤
                                             └─→ TTS-MP-5 ────┼─→ TTS-3 ─┐
TTS-MP-1 ──────────────────────────────────────────────────────┴─→ TTS-4 ─┤
TTS-1 ───────────────────────────────────────────────────────────────────┘
TTS-5 等待 TTS-MP-0...TTS-4
~~~

先冻结三家 Provider 的真实请求/响应和能力边界，再抽象公共接口，避免把某一家 API 的字段泄漏进
领域模型。Registry 稳定后，credential policy 与 unary/SSE transport 可并行；三个 adapter fixture
只依赖公共 contracts + transport，不依赖生产 Keychain，避免凭据工作阻塞 adapter 测试。UI 等待
credential 与三个 adapter 全部完成；统一候选导入链保持最后的 provider-independent 汇合点。TTS 与
非 TTS 宿主工作互不依赖；若同时触及
GUI tests、localization 或 `SoundPacksWindowModel`，共享文件必须顺序处理。真实 key、付费请求、
commit、push、release 或部署仍需分别授权。

### 6.1 文件落点与改动边界

| 文件 | 计划改动 |
|---|---|
| `gui/Sources/ClaudioGUICore/AICueDomain.swift` | 保留声音方案、候选与采用领域类型；加入明确台词 invariant 和 generation identity，不放 provider HTTP 字段 |
| `gui/Sources/ClaudioGUICore/AICueProviderContracts.swift`（新） | provider/profile/route、credential slot/policy、provider-neutral request/response 和 route-derived capability |
| `gui/Sources/ClaudioGUICore/AICueProviderRegistry.swift`（新） | 冻结四个 profile，校验 route/origin/auth/language/slot invariants；不接受用户 URL/model/voice |
| `gui/Sources/ClaudioGUICore/AICueHTTPTransport.swift`（新） | hardened unary URLSession、exact-origin 校验、认证注入、redirect rejection、wire ceiling 与取消 |
| `gui/Sources/ClaudioGUICore/AICueSSETransport.swift`（新） | 增量 SSE framing/parser、CRLF/LF、terminal/cancel、Base64/wire ceiling；不缓冲完整 stream |
| `gui/Sources/ClaudioGUICore/ElevenLabsAICueProvider.swift`（新） | 从现有 `AICueProvider.swift` 提取 ElevenLabs adapter；保持固定 model/voice/routes 与 fixture 回归 |
| `gui/Sources/ClaudioGUICore/MiniMaxAICueProvider.swift`（新） | `get_voice` probe、固定 T2A request、JSON/status/hex MP3 解码和脱敏错误 |
| `gui/Sources/ClaudioGUICore/QwenAICueProvider.swift`（新） | 两个 region profile 的固定 request、SSE/Base64 PCM 收集、WAV 封装和末包 URL 丢弃 |
| `gui/Sources/ClaudioGUICore/AICueProvider.swift` | 迁移期间只保留共享 compatibility typealias/错误；完成后删除重复 transport/adapter，不继续扩成总文件 |
| `gui/Sources/ClaudioGUICore/AICueCredentials.swift` | vault/manager 改为 registry-owned slot；复用旧 `elevenlabs` account；实现 read-only/deferred policy 和 pending replacement |
| `gui/Sources/ClaudioGUICore/AICueGenerationEngine.swift` | 冻结 profile/generation/deadline、route/language/台词门禁、调用 registry adapter；迟到结果 fail closed |
| `gui/Sources/ClaudioGUICore/AICueGenerationViewModel.swift` | 管理 profile、逐 profile stored/verification/pending 状态、切换取消和 provider-specific 脱敏错误 |
| `gui/Sources/ClaudioGUI/EventSettingsAICueView.swift` | 增加 Provider/profile 选择、差异化保存文案、region/能力/台词帮助；保持 `SecureField` 和显式 Generate |
| `gui/Sources/ClaudioGUI/MenuBarController.swift` | composition root 注入 registry、credential manager、unary/SSE transport 和三个 adapter；UI 无 provider 分支 |
| `gui/Tests/ClaudioGUICoreTests/AICueDomainSuite.swift` | profile-neutral domain、明确台词语法、unsupported modality/language 和 generation identity |
| `gui/Tests/ClaudioGUICoreTests/AICueCredentialSuite.swift` | slot mapping、无迁移 legacy account、read-only/deferred、pending promotion/cancel 和 region 隔离 |
| `gui/Tests/ClaudioGUICoreTests/AICueHTTPTransportSuite.swift`（新） | auth header 隔离、exact origin、redirect、unary wire ceiling、deadline 与取消 |
| `gui/Tests/ClaudioGUICoreTests/AICueSSETransportSuite.swift`（新） | 任意分片、CRLF/LF、Base64、terminal/EOF/cancel、wire/decoded ceiling |
| `gui/Tests/ClaudioGUICoreTests/ElevenLabsAICueProviderSuite.swift`（新） | 迁移现有 ElevenLabs provider fixtures，不改变 route/model/voice |
| `gui/Tests/ClaudioGUICoreTests/MiniMaxAICueProviderSuite.swift`（新） | probe、request、status/JSON/hex、语言和错误 fixtures |
| `gui/Tests/ClaudioGUICoreTests/QwenAICueProviderSuite.swift`（新） | region/header/request、SSE/PCM/WAV、末包 URL、取消和格式错误 fixtures |
| `gui/Tests/ClaudioGUICoreTests/AICueGenerationEngineSuite.swift` | registry 路由、3 候选、60 秒 deadline、profile switch late-result race 和统一导入限制 |
| `gui/Tests/ClaudioGUICoreTests/AICueGenerationViewModelSuite.swift` | profile 选择、差异化 key 流程、pending replacement、候选失效与保存后不自动生成 |
| `gui/Tests/ClaudioGUICoreTests/ViewWiringSuite.swift` | composition root、SecureField、provider selector、状态文案和禁止自定义 endpoint/model/voice |
| `gui/Sources/ClaudioLocalization/ClaudioLocalization.swift` 与 `gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings` | 增加 provider、地区、验证策略、台词/能力/编码错误和隐私费用的 English / `zh-Hans` 文案 |
| `docs/adr/0006-use-elevenlabs-byok-with-fixed-modality-routing.md` | 在 TTS-MP-0 中更新为“allowlisted multi-provider、按能力路由”；保留 ElevenLabs 作为基线，不把任意 URL/model/voice 开放给用户 |
| `plan/PLAN-SETTINGS-EXPERIENCE.md`、当前 HTML 原型、GitHub #92 | TTS-MP-0 对齐多 Provider 选择、状态和 ticket ownership；本次 plan-only 修改未触碰 |
| `plan/PLAN-CONSUMER-TTS-EXECUTION.md` | 本执行计划与验收合同；不把真实 key、prompt、响应或音频写入计划 |

不修改 `AudioImport`、manifest bind、现有五个 `Event` 或非 TTS 宿主集成，除非后续发现 provider 输出
无法满足既有导入合同并另行授权扩大范围。

### 6.2 估时与回滚

| 批次 | 预估人力 | 说明 |
|---|---:|---|
| TTS-MP-0 | 1–1.5 天 | 官方契约回查、ADR/设置计划/原型/#92 对齐和 fixture 设计 |
| TTS-MP-1–TTS-MP-1T | 2–3 天 | provider-neutral contracts、registry、语音语法、unary/SSE transport 和 parser |
| TTS-MP-2 | 1–1.5 天 | credential slot/policy、legacy account 直接复用和 Qwen pending replacement |
| TTS-MP-3 | 0.5–1 天 | ElevenLabs adapter 重接与全量回归 |
| TTS-MP-4 | 1–1.5 天 | MiniMax HTTP、JSON/hex 解码、错误映射和 fixture |
| TTS-MP-5 | 2–3 天 | Qwen SSE、PCM→WAV、region profile、取消和输出校验 |
| TTS-3、TTS-5 | 2–3 天 | 多 Provider UI、文案、AX、手工矩阵和证据整理；真实 smoke 时间另计 |

估时不包含真实 key 申请、供应商审批、付费等待、签名、公证或发布排队。回滚时从 registry 移除或
禁用 MiniMax/Qwen profile，恢复 `elevenlabs-global` 默认即可；不得删除已采用的音频、manifest 绑定
或用户的其他 profile key。`elevenlabs-global` 从始至终使用旧 account `elevenlabs`，没有迁移回滚步骤；
新 profile 的 active/pending key 即使在回滚后保留，也只能作为未使用的隔离 item，不能被旧代码误读
或自动 fallback。

## 7. 自动测试与回归命令

### 7.1 领域、凭据与 provider

- 空/过长描述；名称 trim、1...40 字符、控制字符和同名后缀；名称不得决定文件路径。
- speech / animal / soundEffect / mixed 四类 fixture；非语音时 `spokenContent == nil`，speech/mixed 时
  台词必须从完整引号中逐字提取。`说任务完成`、缺失右引号、空引号均本地失败且网络计数为 0。
- Provider/profile registry 只返回四个首批 profile：`elevenlabs-global`、`minimax-global`、
  `qwen-singapore`、`qwen-beijing`；未知 profile、未知 region 或自由 endpoint/model/voice 均拒绝。
- `supportedModalities == Set(routes.keys)`；route key/modality、origin/auth、credential slot、locale allowlist
  任一冲突时 registry 初始化失败，不存在第二份 capability 真相。
- 每个 profile 的 route matrix 都有显式正例和负例：MiniMax/Qwen 的 TTS 不能生成
  `animal` / `soundEffect`；不支持的 modality 在读取 key 或发网络前直接失败。
- 候选页获得稳定名称建议；手工名称覆盖建议；名称不进入 generation request，修改名称不增加请求计数。
- hidden instruction version 被记录为非敏感 token；内部计划不出现在强制 UI 状态。
- 缺少所选 profile credential 不发网络；保存 key 后不自动生成；删除某 profile key 后已采用声音仍可播放。
- credential save/replace/delete 使用 mock Keychain；ElevenLabs/MiniMax read-only probe 失败或写入失败
  时旧 key 保持有效；Qwen 保存计费请求数为 0，pending success、明确 401、403/权限、额度/429/5xx/
  network、cancel 分别覆盖；只有 401 丢弃 pending，不同 profile/region 的 key 永不交叉读取。
- `elevenlabs-global` 精确映射旧 account `elevenlabs`；测试禁止创建 `elevenlabs-global` account、复制、
  删除或双写旧 item。新安装与已有旧 item 都直接通过同一 slot。
- request、state、error、description、日志和 manifest 的快照扫描均不含 key 或 Authorization。
- 公共 transport request/header 不含 secret；hardened transport 只在 exact origin 校验后按 auth enum 注入
  `xi-api-key` 或 Bearer，拒绝 redirect、Authorization 预注入和远端下载 URL；认证失败不 fallback。
- ElevenLabs 请求验证 `xi-api-key`、固定 model/voice/endpoint；MiniMax 请求验证 Bearer header、固定
  `speech-2.8-hd` / Mandarin voice、`get_voice` probe、`data.audio` hex 解码和
  `base_resp.status_code`；Qwen 请求验证 Bearer、exact region host/path、`X-DashScope-SSE: enable`、
  model `qwen3-tts-instruct-flash`、voice `Cherry`、Base64 PCM 和 WAV 封装。
- 每个 adapter 都覆盖认证失败、权限/额度、限流、5xx、畸形 JSON、空音频、编码错误和响应过大；错误
  对外只返回统一脱敏分类，日志不含 prompt 或响应正文。
- 恰好返回 3 个稳定候选；partial result、late result、取消、限流和有限重试符合状态机。切换 profile
  后旧 generation 的成功/失败迟到结果均不能改变新状态或留下临时文件。
- 60 秒 generation deadline 覆盖三个顺序子请求和唯一 429 retry；子请求结束、retry 或网络 callback
  都不能重置预算，deadline 后任务取消且不发布 partial candidates。
- 候选替换、symlink、格式伪装、超时长、超大小和下载中断时采用 fail closed。
- Qwen SSE 覆盖 byte-by-byte 分片、JSON/Base64 跨 callback、LF/CRLF、空行、重复/缺失 terminal、
  terminal 后数据、EOF 和取消；任何异常不得发布候选。PCM 不是 24 kHz/16-bit/mono/little-endian、
  decoded 超过 144,000 bytes 或 WAV 超过 144,044 bytes 时拒绝。
- MiniMax 奇数长度/非法字符 hex、wire 超过 10 MiB + 512 KiB、decoded 超过 5 MiB、JSON 声明 MP3
  但 magic bytes 不匹配均拒绝；ElevenLabs direct container wire/decoded 超过 5 MiB 拒绝。
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

### 7.3 Provider-specific fixture matrix

| Provider | 请求 fixture | 成功响应 fixture | 必须拒绝的响应 |
|---|---|---|---|
| ElevenLabs | `GET /v1/models` probe；固定 TTS/Sound Generation route、model、voice、`xi-api-key` | 直接 MP3；记录 opaque request ID | 非 allowlist origin、缺模型、JSON/空音频、错误 MIME、redirect、>5 MiB |
| MiniMax | `POST /v1/get_voice` probe；`POST /v1/t2a_v2`、Bearer、固定 model/voice、`output_format: hex` | `base_resp.status_code == 0`、合法 hex MP3、`trace_id` | 非 0 状态、空/非法 hex、非 zh locale、wire/decoded 超限、magic bytes 不匹配 |
| Qwen Singapore / Beijing | exact region host/path、Bearer、SSE header、固定 model/voice；保存 key fixture 的网络计数为 0 | 分片 Base64 PCM → 24 kHz/16-bit/mono WAV；记录 region/profile | 跨区 key、畸形 SSE、缺/重复 terminal、远端 URL 跟随、格式/encoded/decoded/时长超限 |

fixture 必须只包含假 key、假 prompt 和脱敏音频字节；真实 provider smoke 不得替代 deterministic
fixture，也不得把真实 key、完整 prompt、响应正文或音频写入仓库。

## 8. 真机与手工验收

### 8.1 macOS UI 与音频

- 未配置状态：只输入描述并点击生成，配置窗打开且描述不丢失；关闭后不发生请求。
- 配置状态：SecureField、Provider/profile 选择、焦点、取消、替换失败保留旧 key、删除二次确认和
  删除后生成门禁；切换 profile 不显示或复制其他 profile 的 key。ElevenLabs/MiniMax 显示“已验证并
  保存”，Qwen 显示“已保存，待首次生成验证”，且保存 Qwen key 时无模型请求/费用。
- ElevenLabs 默认完成四类描述各一次 3 候选流程；MiniMax/Qwen 完成 `speech` 3 候选流程，尝试
  `animal` / `soundEffect` 时在网络前明确阻止并保留描述。
- Qwen Singapore 与 Beijing 若均启用，分别验证 region profile、对应 key 和 endpoint；切换地区不
  自动发请求，也不复用另一地区 credential。
- speech/mixed 描述使用引号时准确朗读引号内文字；缺引号时在本地给出示例并保留描述。动物叫声和
  无文字音效不要求台词；MiniMax/Qwen 遇到不支持 modality 或 locale 时在网络前阻止。
- 第一步没有名称字段；候选页可直接修改建议名称且不重新发请求；空名称不能采用；成功后事件行
  显示最终名称，用户包 manifest 保留名称与音频身份的映射。
- 采用前仍播放旧绑定；采用成功后新名称/音频持久；失败时旧绑定不变。
- 离开/重开统一设置的事件目的页后，已采用声音正常播放，其余临时候选已清理。
- 内置包路径要求先 fork；拒绝时原包不变。
- 键盘和 VoiceOver 完成配置、生成、试听、重命名、采用与错误恢复；焦点顺序与视觉顺序一致。

### 8.2 真实 provider 证据边界

自动测试使用 fake adapter 和测试 Keychain namespace，不需要真实 key。每个真实 provider/profile 的
smoke 必须另行授权，并使用用户主动提供、可撤销、限额的测试 key；不得把 key、Authorization、完整
prompt、响应正文或音频内容写进命令历史、文档、Git、issue、截图或日志。不同 provider 的成功不能
相互代替：ElevenLabs 的回执不能证明 MiniMax/Qwen 已可用，Singapore 的回执也不能证明 Beijing 已可用。

验收报告分开记录：

- 自动测试与 build；
- 本地 GUI / VoiceOver / 音频导入；
- 每个 provider/profile 的认证、请求、3 候选与错误回执；
- 未完成的地区、模型、纯音效能力、付费、双架构、签名 RC 或正式发布证据。

每个获得单独授权的真实 profile smoke 还必须执行音质 rubric，而不是只看 HTTP 200：

- 3 个候选都可播放、无截断、爆音、明显静音或错误背景声，且 duration/size 合同通过；
- speech 候选逐字包含用户给出的台词，语言、发音和固定 voice 可辨识，不能朗读 style 描述；
- 三个 variant 至少在速度、力度或克制程度上存在可听差异，同时都符合原始意图；
- 由人试听记录 `pass/fail + 非敏感原因`，不保存 prompt、真实音频或 provider 响应正文。

fixture 只能证明协议与防线，不能证明音质。没有真实 provider 回执和人工试听时，只能声明
adapter/fixture 已验证，不能升级为真实生成或用户可接受音质已完成。

## 9. 失败模式

| 路径 | 失败 | 防线 | 用户可见结果 |
|---|---|---|---|
| 命名 | 三候选被当成三个永久名字 | final display name 与 variant label 分离 | 只保存采用项和一个名称 |
| 自动命名 | 名称被直接用作路径 | `AICueDisplayName` 与唯一文件分配器分离 | 显示名称可编辑，路径安全生成 |
| BYOK key | key 进入状态、日志或配置 | Keychain-only slot + 非日志化输入 + 静态扫描 | UI 只显示 stored/verification 状态 |
| 验证语义 | Qwen 保存被伪装成“已在线验证”或偷偷计费 | per-profile read-only/deferred policy | 明确“已保存，待首次生成验证” |
| key 替换 | deferred 新 key 无效导致旧 key 丢失 | read-only 原子替换；Qwen pending promotion/cancel | 失败保留旧 active，不自动 fallback |
| legacy Keychain | 新 profile ID 导致既有 ElevenLabs key 消失 | registry 固定 `elevenlabs-global → elevenlabs` | 无迁移、无重复输入、旧版本兼容 |
| profile / region | Qwen 区域 key 或 endpoint 混用 | slot-scoped Keychain + 固定 region allowlist | 当前 profile 明确不可用，不跨区重试 |
| endpoint | 自定义 URL 外送 key / SSRF | provider/profile registry + endpoint/redirect allowlist | 拒绝非内置地址 |
| transport auth | 所有 Provider 被错误注入 `xi-api-key` | exact-origin 后按 auth enum 集中注入 | 请求在本地拒绝，不外送 key |
| provider 能力 | TTS 模型被宣传为可生音效 | 官方能力矩阵 + capability tests | 不支持类型在网络前明确阻止 |
| 语音台词 | 模型猜台词或把 style 整段朗读 | 明确引号语法 + speech invariant | 本地提示示例，保留用户描述 |
| provider 编码 | MiniMax hex 或 Qwen Base64 PCM 被当作普通音频 | adapter 专属解码、容器封装与 magic bytes 校验 | 候选拒绝，旧声音不变 |
| provider fallback | 一个 provider 失败后暗中改用另一 provider | provider selection 固定到 generation；无自动 fallback | 显示当前 provider 错误，由用户重新选择 |
| provider 输出 | MIME/响应体/声明格式伪装 | 私有 temp acquisition + sniff + AudioImport | 候选拒绝，旧声音不变 |
| 自动计费 | 保存 key 后自动生成/无限重试 | 二次显式 Generate + 有限重试 | 用户掌握每次请求时机 |
| 迟到结果 | 切换 profile 后旧请求覆盖新状态 | generationID/profileID snapshot + cancel/discard | 新选择和候选不被污染 |
| 总耗时 | 三个 45 秒子请求让用户等待超过 2 分钟 | 60 秒 generation absolute deadline | 超时统一失败，不展示 partial |
| partial publish | 导入或 bind 只完成一半 | 事务、回滚和真实磁盘状态投影 | 旧绑定保持，显示实际阶段 |

## 10. 明确不做

- 不新增或改名现有五个 `Event`，不修改 WorkBuddy 或其他宿主配置。
- v1 不做 claudi0 Hosted server、账号、额度、支付、订阅或 Hosted/BYOK 自动 fallback。
- 多 Provider 仅限应用内 allowlisted profile；不做自定义 API base URL、自定义模型 ID、任意 voice
  ID 或区域自动切换。
- 本计划首批只实现 MiniMax/Qwen 的 `speech` 路线；不因 TTS 支持而承诺 `animal`、`soundEffect` 或
  任意 `mixed` 语义。没有独立官方能力证据和输出验收时，保持 modality 不可用。
- 不做本地 Qwen/MiniMax 权重下载、Core ML/MLX 推理、离线模型管理或云 Provider 的自动选择器；
  这些是独立的本地推理计划。
- 不显示或恢复已保存 key 明文，不把 key 放进 CLI/env/config/日志/回执。
- 不为了 Qwen key 校验在保存时调用任何生成模型；也不引入 Alibaba Cloud AccessKey 来管理或查询
  用户的 Model Studio API Key。
- 不恢复可见的“声音方案”强制步骤；内部 `AICueSoundPlan` 仍保留。
- 不做声音克隆、用户本人音色训练、音频编辑器、裁剪时间线或归一化工作台。
- 不一次生成整个声音包，不生成超过 3 秒或 5 MB 的候选。
- 不改变当前 macOS 12 最低版本，不为新 UI 强行采用更高系统专属 API。
- 不把原型、fixture、静态契约或本地 hash 升格为真实 provider、正式发布或商业验收。

## 11. 绿灯

只有以下条件同时成立，多 Provider 扩展计划才算完成：

- ADR 0006、`PLAN-SETTINGS-EXPERIENCE.md`、交互原型和 #92/子 tickets 已通过 TTS-MP-0 对齐；
  ElevenLabs-only 原型不能单独作为多 Provider 验收依据。
- ElevenLabs、MiniMax、Qwen 首批 profile 都有官方能力、认证、隐私、地区、费用和错误契约门禁；
  未支持的 modality/locale 明确列出并在网络前阻止，`routes.keys` 是唯一 capability 真相。
- `AICueProviderRegistry`、provider-neutral request、unary/SSE transport 和 registry-owned Keychain
  slot 已替代公共 `ElevenLabsAICueCompiledRequest`/unconditional `xi-api-key` 依赖；现有 ElevenLabs
  route/voice 行为不变，旧 account `elevenlabs` 无迁移直接通过。
- MiniMax adapter 已通过 read-only probe、Bearer、固定 voice、hex→MP3、状态码、wire/decoded 上限和
  3 候选测试；Qwen adapter 已通过 exact region route、deferred validation、SSE fragmentation、
  Base64 PCM→WAV、terminal/取消、wire/decoded 上限和 3 候选测试。
- 可见 UI 只有“描述 → 候选与命名”，第一步没有名称字段，内部 `AICueSoundPlan` 不成为强制重表单。
- speech/mixed 只朗读用户引号内的明确台词；缺台词或不支持 locale 时不读 key、不发网络，动物叫声
  和无文字音效仍可自由描述。
- 候选阶段自动建议并可无成本改名；空名称不能采用，最终名称随采用项进入用户声音包和事件绑定。
- 每个 profile 的 API Key 可配置、替换和删除，Keychain-only，明文不越过凭据管理边界；
  read-only/deferred 状态诚实，Qwen pending replacement 可取消，保存 key 后不自动生成。
- 真实 adapter 返回并校验完整 3 候选；无自动播放；每次生成由用户显式触发；不支持 modality 不会
  发送请求或自动 fallback；全部子请求共享 60 秒 generation deadline，profile switch 的迟到结果
  不能污染新状态。
- 选中候选完整走现有 `AudioImport` 和 manifest bind，任何失败保留旧声音。
- helper/GUI test harness、显式 GUI debug build、xcstrings 校验和 `git diff --check` 全绿。
- 自动、GUI/VoiceOver/音频、真实 provider + 人工音质 rubric 和未完成发布证据分别报告。
- 实施不得覆盖计划开始前不相关的已有修改；commit/push 仍需用户另行明确授权。

## 12. 原型与复用边界

当前 ElevenLabs 核心闭环交互参考：

`mockups/ai-app-manager-native-macos.html?page=events&app=workbuddy&prototype=tts&stage=applied&credential=ready`

原型状态在内存中；`credential=missing|ready` 只用于演示配置状态，不代表真实 Keychain。当前页面
还没有体现多 Provider 选择、read-only/deferred 验证差异和 unsupported modality/locale，因此在
TTS-MP-0 更新前，它不是多 Provider UI SoT。多 Provider 工程合同以本计划为准；视觉和交互验收需等
原型与 `PLAN-SETTINGS-EXPERIENCE.md` 对齐后共同成立。原型不得接收真实 key 或冒充真实 provider 请求。

本计划继续复用现有：

- `Event` 的五个公共语义；
- `EventSettingsWindow` 中的作用域/事件投影、AI 状态机与 accessibility 入口；其独立 window ownership
  不再是目标架构，内容迁入统一设置的「事件与提示音」目的页；
- `SoundPacksWindowModel` 的包级写入 seams；`SoundPacksWindowController` 的独立窗口与 handback
  只保留到统一设置迁移完成，之后由唯一 settings owner 接管；
- `AudioImport` 的 source acquisition、内容嗅探、时长/大小限制、包锁、安全发布和 manifest bind；
- 内置只读包与用户自有包边界；
- 现有测试 harness、播放 facade 和失败/刷新语义。

本计划新增/修订 `AICueDisplayName`、隐藏 `AICueSoundPlan`、`AICueProviderProfile`、route-derived
capability registry、provider-neutral request、registry-owned credential slots/policies、unary/SSE
transport、ElevenLabs/MiniMax/Qwen BYOK adapters 和对应 UI 接缝；不得在 UI 或 adapter 中复制
`AudioImport`、包锁和 manifest 发布逻辑。

文档类型：AI 提示音子域工程执行计划，兼具内部接口 reference 与架构 explanation。AI 子域本地 Swift
实现与 ElevenLabs 基线已完成，但 provider-neutral 重构、MiniMax/Qwen adapter、统一设置视觉与窗口
迁移尚未完成；真实 provider 探测、commit、push、release 和部署都需要后续单独授权。
