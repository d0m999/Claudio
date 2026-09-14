---
status: accepted
---

# 接受实测资源合同并固定 SenseAudio SFX 下载边界

本决定部分取代 ADR 0011 中“必须先取得 SenseAudio 官方资源合同才能构造 policy”的生产暴露门禁。
SenseAudio [官方音效生成接口](https://docs.senseaudio.cn/api-reference/endpoint/sfx/create)返回
`audio_url`，但没有正式承诺生产资源 hostname、MIME、免认证 GET、redirect、URL 有效期或 host 轮换；
2026-09-14，项目所有者决定不再等待这些外部承诺，而是接受一个严格、可本地执行的实测资源合同及其
剩余可用性风险。该决定不把实测结果表述为供应商保证，也不把资源发现调用升级为正式 smoke。

`senseaudio-cn` SFX 的固定资源政策只有以下内容：

- 唯一允许的 origin 是 `https://dynamic.senseaudio.cn:443`；不得接受子域通配、DNS 后缀匹配、IP、
  userinfo、fragment、其他端口或任意 HTTPS；
- 唯一允许的响应 MIME 是 `audio/mpeg`，并继续执行 MP3 magic、大小和时长本地校验；
- asset GET 必须匿名，独立 fetcher 不发送 `Authorization`、Cookie 或 Referer；
- redirect 数必须为零，最终 URL 必须与已预检的请求 URL 完全一致；
- `audio_url` 只在当前显式生成内立即下载，不进入配置、defaults、manifest、日志、回执、证据附件或
  其他持久化；完整 path/query 仍属于禁止记录内容。

每次真实响应中的全部 URL 必须在任何 GET 之前按上述 policy 整批预检。origin、MIME、认证要求、
redirect 或 final URL 任一漂移都 fail closed：activation 前保持 `productionSenseAudioAssetPolicy == nil`
且 profile 隐藏；activation 后本次生成失败，并进入 ADR 0011 的显式回滚流程，不自动放宽 policy、
切换 host、fallback 到其他 Provider 或删除 Keychain/已采用音频。

项目所有者明确接受 URL 有效期与 host 轮换未知造成的可用性风险：未来供应商更换资源域名、缩短有效期
或改变下载行为时，合法生成也可能被 Claudio 拒绝。该风险接受只替代“官方确认”这一证据来源，不替代
绑定同一非分发候选的真实 TTS/SFX smoke、音频校验、听感、键盘、VoiceOver、采用/回滚验收，也不授权
production activation。固定 policy 内容、digest 或实现发生变化时，受影响证据必须重验。
policy 的唯一规范化 JSON 与 SHA-256 由 `docs/senseaudio-production-acceptance.md` 第 1.2 节拥有。

## 未采用的替代方案

- 继续等待 SenseAudio 官方逐项确认：能降低未来可用性不确定性，但当前没有可复核承诺，且外部沟通
  不能替代本地 fail-closed 执行；
- 接受任意 HTTPS、通配域名或运行时学习 host：会把供应商响应直接变成信任政策，拒绝采用；
- 增加自有资源代理或让用户配置下载服务器：扩大秘密、运维和 SSRF 边界，不属于本次 T8/T9。

ADR 0011 的 route-owned candidate set、Keychain-only BYOK、固定 API origin/model/voice、无自动
fallback、非分发候选、人工验收和单独 activation 决定继续有效。
