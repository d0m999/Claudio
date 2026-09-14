---
status: accepted
---

# 为 SenseAudio 使用路线拥有的候选集合与受证据门禁的固定 profile

本 ADR 中要求 SenseAudio 官方确认资源合同后才能构造 asset policy 的门禁，已由
[ADR 0014](0014-accept-observed-senseaudio-asset-contract.md) 部分取代；route-owned 候选集合、
固定 profile、非分发候选、真实 smoke、人工验收与单独 activation 的其余决定继续有效。
SenseAudio 的 Keychain-only 存储要求另由 [ADR 0015](0015-use-local-file-credentials-for-senseaudio.md)
取代；只读 probe、失败保留旧 Key 和生成授权语义不变。

## 决策

AI 提示音的候选身份、请求数量和最少可接受数量由每条 `AICueProviderRoute` 的候选集合政策唯一拥有，
不再由生成引擎全局假定为三个 styled 候选。ElevenLabs 与 Qwen 保持 styled、请求 3、最少 3；MiniMax
speech 改为 numbered、请求 3、最少 3。现有逐候选 `AICueProvider` 通过顺序 compatibility adapter
进入候选集合接缝，其网络与全有或全无行为保持不变。

新增唯一固定的 `senseaudio-cn` profile 候选：`providerID` 为 `senseaudio`，credential slot 为
`senseaudio-cn`，`.cn` 固定路线只表示 endpoint 选择，不承诺数据驻留。该 profile 复用 Keychain-only
BYOK 和 read-only probe 原子替换：`POST https://api.senseaudio.cn/v1/get_voice` 固定查询全部音色，
只有 2xx、业务状态成功且账户可见 `female_0033_b` 时才替换 active key。仅 API origin 返回的 HTTP 401
表示凭据无效；业务错误、缺少所需音色和资源下载 401 不得错误废弃现有 key。

SenseAudio `speech` 固定调用 `POST https://api.senseaudio.cn/v1/t2a_v2`，使用
`sensenova-tts-2.0`、`female_0033_b` 和 32 kHz / 128 kbps / mono MP3，
只接受 `zh*`，在同一 60 秒 absolute deadline 内顺序发送三次且不自动重试生成 POST。三个 numbered
候选必须全部通过服务状态、bounded hex、MP3 magic、5 MiB 与 3 秒本地检查，才能以 `complete` 展示。

SenseAudio `animal` 与 `soundEffect` 共用
`POST https://api.senseaudio.cn/v1/sound-effects/generations` 和固定
`senseaudio-sfx-1.0-260626` native batch，一次请求
`variants_count=3`。远端 batch 的状态、唯一 `variant_index`、完成项与全部实际出现的 URL 必须在任何
下载前整体验证。资源 GET 经过不接收 credential 的独立 asset fetcher，只允许 registry 固定的精确
HTTPS origin、443 和 MIME，拒绝 IP、userinfo、fragment、redirect 与 final-URL 漂移；不发送
`Authorization`、Cookie 或 Referer，也不记录完整 URL/query。单项普通下载或音频校验失败后可继续，
至少一个有效 numbered 候选即可按路线政策以 `partial` 展示；取消、deadline、本地存储失败或零个有效
候选使整次生成失败并清理。`.mixed` 明确不支持。

生成完成度只描述临时候选集合，不放宽采用链：用户仍只能显式采用一个完整通过校验的候选，且
`AudioImport`、pack lock 和 manifest bind 仍必须完整成功，任何失败保留旧绑定。默认 Provider 仍为
`elevenlabs-global`，不做跨 Provider、跨区域或跨路线 fallback。

## 生产暴露门禁

SenseAudio SFX 使用 ADR 0014 的项目所有者接受实测资源合同：唯一允许的资源 origin 固定为
`https://dynamic.senseaudio.cn:443`，唯一允许的 MIME 固定为 `audio/mpeg`，GET 不携带 credential、
Cookie 或 Referer，禁止 redirect 与 final-URL 漂移，并只在当前显式生成中立即下载、不持久化 URL。
在以下证据全部齐备前，默认 `allowlistedProfiles` 不得注册 `senseaudio-cn`，
`productionSenseAudioAssetPolicy` 必须保持 `nil`，也不得发布 TTS-only 半成品：

1. 上述固定 policy 绑定到非分发候选，并计算规范化内容与 digest；
2. 经单独付费调用授权完成真实 TTS 与 SFX smoke，确认全部 SFX URL、GET、MIME 与音频均符合该 policy；
3. 完成三候选语音、SFX partial、真实听感、键盘和 VoiceOver 人工验收。

真实 Provider 与原生验收必须使用非分发验收候选。候选须绑定唯一的完整 source commit、精确 asset
policy 的规范化摘要与 digest，以及实际被测试 app 的 Bundle identifier、版本、架构、签名身份和可执行
文件 digest。验收候选可以在隔离分支中注入 ADR 0014 固定的精确 policy，但不得合入可分发分支、上传或
交付；它也不能把生产 policy 的 `nil` 门禁视为已经解除。只有上述证据全部通过后，才能在单独评审的
activation 变更中固化 policy 并加入 allowlist。activation 或最终 Bundle 身份与验收候选不一致时，
必须对受影响的合同重新验收，不能沿用旧候选结论。

如果任一资源 URL、MIME、认证要求或 redirect 行为偏离 ADR 0014 的固定 policy，SFX 验收失败；不得
退化成任意 HTTPS、通配域名、运行时学习 host 或用户自定义资源服务器。URL 有效期与 host 轮换未知是
项目所有者接受的可用性风险，不是放宽安全政策的理由。回滚只把 production policy 恢复为 `nil`、从
allowlist 移除 profile 或使用上一版本应用，不自动删除 Keychain 项、已采用音频或 manifest 绑定，也不
自动切换到其他 Provider。

## 取代范围

本 ADR 取代 ADR 0006 中“所有 Provider 都逐候选调用、恰好三个 styled 候选且全有或全无”的相关
条款，并保留其固定 profile、route-derived capability、Keychain-only、无自定义 endpoint/model/voice、
无自动 fallback 与真实 smoke 单独授权的其余决策。ADR 0007 的独立用户包与采用目标边界保持不变。

详细合同见 `plan/PLAN-CONSUMER-TTS-EXECUTION.md`；候选构造、证据字段、付费预算、激活与回滚台账见
`docs/senseaudio-production-acceptance.md`。
