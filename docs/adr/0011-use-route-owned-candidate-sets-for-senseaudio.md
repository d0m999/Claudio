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

2026-09-15 审查后明确“普通”单项失败的边界：URL/origin、MIME、redirect、final URL 违约及
asset HTTP 401/403 按 ADR 0014 立即终止整批，不能降为 partial；普通资源不可用、限定重试耗尽和
MP3 magic/大小/时长淘汰可以继续。asset 401/403 不损坏现有 API Key 验证状态。取消、deadline、
本地存储与 retry-backoff 基础设施故障仍终止整批。这是实现与合同修订，旧 smoke 不自动证明新实现。

2026-09-15，项目所有者将 SenseAudio `animal` / `soundEffect` 的 generation absolute deadline
改为路线拥有的 **180 秒**。正式候选曾在 60.643 秒、零响应字节时超时；该证据只能证明原预算不足以
等到这次响应，不能保证 180 秒一定成功。其他 Provider、SenseAudio speech 与 voice probe 保持
**60 秒**。点击时先冻结单调时钟起点，再通过同一纯本地 planner/compiler 和固定 registry route
选择预算；无效输入不扩大预算，仍由 engine 在读取凭据或联网前拒绝。SFX POST、最多三项顺序
asset GET、允许的一次限定 GET retry、校验与落盘共享该起点和截止时刻；任何步骤不得重新起算。
Foundation 的 request/resource timeout 使用本次剩余预算，避免其默认 60 秒再次截断长计算路线。
SFX 响应头前仅受总 deadline；headers 后仍执行 20 秒 inactivity。生成 POST 零自动 retry、匿名 GET、
exact origin/MIME、零 redirect、3 秒/5 MiB 和取消后整批清理均不变。更长等待是可用性取舍，不是
放宽下载政策；实现与 Bundle 身份变化后必须重建候选并重验受影响证据。

生成完成度只描述临时候选集合，不放宽采用链：用户仍只能显式采用一个完整通过校验的候选，且
`AudioImport`、pack lock 和 manifest bind 仍必须完整成功，任何失败保留旧绑定。默认 Provider 仍为
`elevenlabs-global`，不做跨 Provider、跨区域或跨路线 fallback。

## 生产暴露门禁

2026-09-15，项目所有者授权 T9 本地启用与最终 Bundle 复验：正式源码的默认 optional-policy
builder 固化 ADR 0014 的唯一 policy，并按既有四个 profile 后追加完整 `senseaudio-cn`；默认
Provider 仍为 `elevenlabs-global`。显式 nil registry 继续返回四个 profile，不删除凭据或已采用
资产。fixture policy 保持独立；无 mixed、无 fallback、180/60 秒预算和所有安全门禁不变。
该决定只授权隔离分支的本地实现与验收，不授权 push、PR、合并、Issue 状态修改或分发。
真实“再次原生保存”未验证，经所有者同意不阻塞本轮；假 Key 隔离验证与重启后的应用内取用
分别记录。最终身份、受影响重验和历史继承见台账第 26 节。以下保留 T8 启用前的门禁与历史决定。

SenseAudio SFX 使用 ADR 0014 的项目所有者接受实测资源合同：唯一允许的资源 origin 固定为
`https://dynamic.senseaudio.cn:443`，唯一允许的 MIME 固定为 `audio/mpeg`，GET 不携带 credential、
Cookie 或 Referer，禁止 redirect 与 final-URL 漂移，并只在当前显式生成中立即下载、不持久化 URL。
T8 启用前要求以下证据齐备，期间默认 policy 为 `nil`、profile 隐藏；T9 本地决定见上文。
不得发布 TTS-only 半成品：

1. 上述固定 policy 绑定到非分发候选，并计算规范化内容与 digest；
2. 经单独付费调用授权完成真实 TTS 与 SFX smoke，确认全部 SFX URL、GET、MIME 与音频均符合该 policy；
3. 完成三候选语音、真实听感和键盘人工验收；VoiceOver、SFX partial 实际展示与动物音效意图
   匹配适用下述本轮有边界的风险接受，不得把豁免项记为实测通过。

2026-09-15，项目所有者明确决定“放弃VoiceOver验证，暂时不考虑这部分用户”。本轮 SenseAudio
接入验收暂不以 VoiceOver 人工验证作为阻塞项，记录为 `RISK ACCEPTED`（所有者豁免、未验证），
不记为 `PASSED`，不宣称已支持旁白完整操作。保留已有无障碍实现、标签及自动回归；不削减其他
Provider 的验收要求，也不豁免普通键盘、听感、partial、凭据、采用与回滚门禁。豁免记录和范围见
生产验收台账第 22 节；它本身不授权 activation、发布或关闭 Issue。

2026-09-15，项目所有者进一步明确接受当前动物音效不符合描述意图的质量风险，以及难以复现
SFX partial 1/3、2/3 导致实际展示未验证的风险。两项均记录为 `RISK ACCEPTED`，而非 `PASSED`；
保留动物听感失败和根因未确定的事实，不据此断言问题来自模型、排除本地代码问题或承诺音效质量。
partial 的隔离串联回归继续作为工程证据，现有数量提示、稳定编号、取消和清理实现不删除。
所有者同时人工确认完整键盘焦点与异常恢复/失败保旧绑定/回滚通过。当前候选的最终收口见台账
第 23 节。三项风险接受仅适用于本轮 SenseAudio 验收及 unchanged 相关实现的最终 Bundle 复验，
不自动扩展到其他 Provider，不放宽资源、凭据、音频、采用或网络安全门禁，也不授权 T9。

真实 Provider 与原生验收必须使用非分发验收候选。候选须绑定唯一的完整 source commit、精确 asset
policy 的规范化摘要与 digest，以及实际被测试 app 的 Bundle identifier、版本、架构、签名身份和可执行
文件 digest。验收候选可以在隔离分支中注入 ADR 0014 固定的精确 policy，但不得合入可分发分支、上传或
交付；T8 候选本身不能解除默认 policy 的门禁。只有上述未豁免门禁全部通过，且本轮
VoiceOver、partial 实际展示和动物意图质量风险接受均有明确记录后，才能在单独评审的 activation
变更中固化 policy 并加入 allowlist。
activation 或最终 Bundle 身份与验收候选不一致时，
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
