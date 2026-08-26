---
status: accepted
---

# 使用 ElevenLabs BYOK 与固定声音类型路由

首版 AI 提示音只支持用户自备 ElevenLabs API Key，由 macOS 原生客户端直接调用固定 HTTPS
端点。凭据只存 macOS Keychain；产品不内置共享 key，不提供自定义 provider、base URL、model ID
或自动 fallback。配置时通过只读的 `GET /v1/models` 验证认证与两个必需模型的可用性，验证或
Keychain 替换失败时保留原有凭据。

一个 provider profile 内固定两条能力路线：语音和语音混合声音使用 `eleven_v3` 的
`POST /v1/text-to-speech/{voice_id}`；动物叫声和纯音效使用 `eleven_text_to_sound_v2` 的
`POST /v1/sound-generation`。声音描述先在本地规范化为带版本的内部声音方案，再按类型编译为
请求。事件、surface、声音包 ID 和最终提示音名称都只属于本地采用上下文，不发送给 provider。
每次用户点击生成会顺序发出三个独立的、可计费子请求；三项全部通过格式、5 MB 和 3 秒校验后
才一起显示。网络或 5xx 的结果是否已计费不明确，因此不自动重试；只有带明确等待提示的 429
允许至多一次受限重试。

采用这一路线是因为单一传统 TTS 模型无法诚实覆盖产品承诺的动物叫声和纯音效，而两个固定
模型仍可由一个凭据、一个安全网络 adapter 和一套错误模型封装。代价是同一次生成包含三个请求，
且描述、编译后的生成文本和生成音频受 ElevenLabs 的留存与模型改进条款约束。配置 UI 必须在
首次保存 key 前披露直连、潜在费用和供应商数据边界；保存 key 后不得自动生成。
