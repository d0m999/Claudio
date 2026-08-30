---
status: accepted
---

# 使用 allowlisted 多 Provider BYOK 与按能力固定路由

## 决策

AI 提示音只允许用户从应用内注册的 Provider profile 中显式选择；首批 allowlist 固定为
`elevenlabs-global`、`minimax-global`、`qwen-singapore` 和 `qwen-beijing`。Claudio 本机使用用户
自备 API Key 直连对应固定 HTTPS origin/path。凭据只存 macOS Keychain；不内置共享 key，不接受
任意 provider、endpoint、model、voice 或 region，也不在失败后自动 fallback、跨区或跨 Provider
重试。

`routes.keys` 是 profile capability 的唯一真相。`supportedModalities` 必须从它派生，不维护第二份
能力列表。首批 route 冻结如下：

| Profile | Origin 与 path | Auth / credential slot / validation | 固定 model、voice 与输出 | `routes.keys` / locale |
|---|---|---|---|---|
| `elevenlabs-global` | `https://api.elevenlabs.io`；probe `GET /v1/models`；speech/mixed `POST /v1/text-to-speech/JBFqnCBsd6RMkjVDRZzb`；animal/soundEffect `POST /v1/sound-generation` | `xi-api-key`；旧 account `elevenlabs`；`readOnlyProbe` | speech/mixed：`eleven_v3` + `JBFqnCBsd6RMkjVDRZzb`；animal/soundEffect：`eleven_text_to_sound_v2`；直接 MP3 | `speech`、`mixed`、`animal`、`soundEffect`；`zh` / `zh-Hans` / `en` |
| `minimax-global` | `https://api.minimax.io`；probe `POST /v1/get_voice`；生成 `POST /v1/t2a_v2` | Bearer；slot `minimax-global`；`readOnlyProbe` | `speech-2.8-hd` + `Chinese (Mandarin)_Reliable_Executive`；32 kHz / 128 kbps / mono MP3；JSON hex | 仅 `speech`；`zh` / `zh-Hans` |
| `qwen-singapore` | `https://dashscope-intl.aliyuncs.com`；生成 `POST /api/v1/services/aigc/multimodal-generation/generation`；`X-DashScope-SSE: enable` | Bearer；slot `qwen-singapore`；`deferredUntilExplicitGeneration` | `qwen3-tts-instruct-flash` + `Cherry`；SSE Base64 PCM，24 kHz / 16-bit / mono / little-endian，封装 WAV | 仅 `speech`；`zh* -> Chinese`、`en* -> English` |
| `qwen-beijing` | `https://dashscope.aliyuncs.com`；path 和 SSE header 同 Singapore | Bearer；slot `qwen-beijing`；`deferredUntilExplicitGeneration` | 与 Singapore 相同 | 仅 `speech`；与 Singapore 相同 |

ElevenLabs/MiniMax 用不生成音频的 read-only probe 验证并原子保存或替换 key；probe 或 Keychain 写入
失败时旧 key 保持有效。Qwen 没有无费用的等价 probe：首次保存写入 stored-unverified active；只有已有
active 时，替换值才写入 pending slot。两者保存时都不发模型请求，并显示“已保存，待首次生成验证”。
下一次用户显式生成成功后，首次 active 标记为 verified，或把 pending 提升为 active；pending replacement
可取消并恢复原 active 的验证状态。失败不允许暗中改用旧 key 重试；只有 pending 明确收到 401/
invalid-credential 时才丢弃 pending 并保留旧 active。删除只影响当前 profile 的 active/pending key，
不删除其他 profile 凭据或已采用声音。

描述和生成所需元数据会从本机发送给当前 profile。界面必须逐 profile 披露供应商、地区、数据处理、
留存/模型改进规则、潜在费用与配额；不得把 ElevenLabs 条款推广到 MiniMax/Qwen，也不得统一承诺
zero retention。保存凭据不自动生成；任何可能计费的生成都由用户再次显式触发。

Provider 响应是不可信输入。所有候选仍须满足同一 3 候选、3 秒、5 MB、60 秒 generation deadline，
并经过固定 origin/redirect、wire/decoded 上限、编码和 magic bytes 校验，再进入现有 `AudioImport` 与
manifest bind。MiniMax 只接受成功 JSON 的 hex MP3；Qwen 只消费 SSE Base64 PCM 并本地封装 WAV，
末包 URL 不跟随。任一失败保留旧绑定。

## 后果

- 现有 ElevenLabs Keychain account `elevenlabs` 原样复用，不复制、不改名、不双写。
- MiniMax/Qwen 首批只有 `speech`；不支持的 modality/locale 在读取 key 或发网络前失败关闭。
- 增加 Provider 必须新增固定 profile、官方认证/地区/能力/费用证据、隔离 credential slot、确定性
  fixtures 和单独授权的真实 smoke；不能只增加一个枚举值。
- 原型、fixture、静态合同与本地构建不构成真实 key、付费请求、VoiceOver、签名、公证或发布证据。

详细领域、transport、凭据状态机和验证合同以
`plan/PLAN-CONSUMER-TTS-EXECUTION.md` 为准；统一设置投影以
`plan/PLAN-SETTINGS-EXPERIENCE.md` 为准。
