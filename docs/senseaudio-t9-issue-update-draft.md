# Issue #189 更新草案

状态：本地草案，尚未发布或修改 GitHub Issue。相关修复与验收边界见
`senseaudio-production-acceptance.md` 第 24 节。

## Scope

Part of #183。历史 T8 #187 已按台账第 23 节的所有者有边界风险接受口径闭合，不能描述为全部实测
通过。资源合同来源是 ADR 0014 的所有者接受实测合同，不再等待供应商正式承诺 hostname/MIME。

只有审查后 ACL 与 SFX 资源失败分类修复的受影响证据按第 1.4、24 节重验，且获得独立 activation
授权后，才能固化 `productionSenseAudioAssetPolicy`、精确注册第五个 profile，并同步
privacy/Gallery/ADR/台账。对最终 commit 运行完整 harness、Release/bundle/size 与适用原生 smoke。

## Acceptance

- production 恰好五 profiles，默认 ElevenLabs，完整 TTS+SFX 同时暴露；无自动 fallback。
- exact origin/MIME、匿名 GET、零 redirect 和共享 deadline 不放宽。
- URL/origin、MIME、redirect、final URL 违约及 asset 401/403 立即整批失败；资源认证拒绝不损坏 Key。
- 候选从全部修复的开发基线创建，独立 activation patch 不夹带功能或证据文件；testing override 与
  NON-DISTRIBUTION 标记不进入发布构建。
- 新凭据链和受影响 SFX 生成/下载须在新候选上重验。policy digest 相同不代表实现证据可继承。
- 最终 commit/tree/policy/Bundle 与证据一致；每项继承有 source-delta 依据，行为变化重验受影响项。
- VoiceOver 未验证、partial 实际展示未验证、动物意图质量沿用已明确的有限风险接受，不能写 PASSED，
  不能扩展为凭据或网络安全豁免。
- 未满足上述前置条件时保持 production policy nil。T9 本地实现、activation 与 release 验收分别记录。
