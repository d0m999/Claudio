# Issue #189 更新草案

状态：本地草案，尚未发布或修改 GitHub Issue。T9 已按用户直接授权完成本地实现及最终 Bundle
复验，包含补录的实际听感确认；本地闭合为 `PASSED`。证据见
`senseaudio-production-acceptance.md` 第 26 节；第 24–25 节修复历史保留。

## Scope

Part of #183。历史 T8 #187 已按台账第 23 节的所有者有边界风险接受口径闭合，不能描述为全部实测
通过。资源合同来源是 ADR 0014 的所有者接受实测合同，不再等待供应商正式承诺 hostname/MIME。

从 main `8330a3cae95110858b1440eaa530904cc8c1d8cc` 创建隔离分支
`feat/senseaudio-production-activation`，不合并 T8 候选分支，不修改原目录的未提交工作。
最终受测源码为 `e9ff628438d6d6443bc86a41f33a6ce39a3ba4f0`，tree
`0ee80a2d31d94aa723d92f7d9d162eea83da5c4d`。源码提交与证据提交分开，受测 Bundle 没有 fixture
policy 注入；NON-DISTRIBUTION 仅在外部归档名称/台账标记。

## Acceptance

- 默认 registry 五 profiles，默认 ElevenLabs，已有 Provider 选择不改；完整 SenseAudio TTS+SFX，
  不支持 mixed、无自动 fallback。显式 nil 回滚 registry 四项，保留凭据和已采用资产。
- 唯一 `https://dynamic.senseaudio.cn:443` / `audio/mpeg`、匿名 GET、零 redirect、立即下载、
  URL 不持久化；digest `6f570cf99d8fc8bfcf040c49ac4182afa1ab16d0baca74eb072a7f083e5d200d`。
  SFX 180 秒、其他 60 秒，以及资源安全/401/403/未知基础设施整批失败合同不放宽。
- 默认合同回归旧实现 63 / 5；扩展字段/map 正控旧实现 75 / 25 → 最终 75 / 0。
  默认 runtime 五 generator/三 validator，构造零凭据/网络/文件写入；mixed/非中文 speech 网络前拒绝。
- 最终完整设置集成门禁通过：helper 3272 / 0、GUI 9869 / 0；Debug/Release、localization、selector、
  candidates 11 / 0、bundle、ad-hoc 签名与 size 通过；strict format 新增诊断 0。首轮 fixture/隐私名称
  合同失败及修复记录保留在台账，不能宣称首轮全绿。
- 最终 arm64 本地 Bundle 首轮真实重验 3 TTS POST + 1 SFX POST + 3 asset GET，七次 HTTP 200，
  零 probe/零 retry；三 TTS/三 SFX 均通过 MP3 大小/时长校验并触发原生播放。所有者明确当时错过
  TTS 后，另行确认已就位并授权同预算听感闭合轮次；第二轮同为七个 HTTP 200、零 probe/零 retry。
- 第二轮三个 TTS 均实际听到、预期台词完整且无多余内容；三个 SFX 均实际听到、均为短促木琴音效
  且完全没有人声。人工听感 `PASSED`，不由播放状态或 HTTP 200 代替。
- WorkBuddy × stop 在独立 CC0 测试包一次采用成功；重启原生/manifest/音频读回通过。
  完成后仅恢复原包选择，其他覆盖/原包 manifest/真实凭据元数据不变；测试包及已采用音频保留。
- 源码/policy/Bundle/executable/archive 摘要完整绑定；继承输入法/键盘证据有精确 source delta。
  ACL 与资源错误/deadline 改动通过隔离回归和新真实链路重验，不能由相同 digest 自动继承。
- 真实再次原生保存仍未验证，用户本轮计划明确豁免；假 Key 保存/重启/ACL/权限异常、替换失败保旧值
  与删除通过工程验证，不读取或重新录入真实 Key。
- VoiceOver 未验证、partial 实际展示未验证、动物意图质量沿用已明确的有限风险接受，不能写 PASSED，
  不能扩展为凭据或网络安全豁免。

## Remaining

首次 TTS 被错过及过早切换 SFX 的流程缺口保留在台账；第二轮已在所有者明确就位后逐类播放并先后
取得反馈。临时候选随后由正常生命周期清理；既有采用音频保留，WorkBuddy 原声音包与 Codex 界面
作用域均恢复，重启读回通过。
macOS 12–13、Intel、universal/Developer ID、公证及正式分发未验证；不声明生产就绪。
本草案不发布到 Issue。本变更合并后 main production 使用固定 policy 与默认五 profiles；未执行
Release、正式分发或 Issue 状态修改。
