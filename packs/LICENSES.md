# packs/ 内置声音包 CC0 合规台账

> 对应 ENGINEERING.md 任务 T11。**这是项目核心价值，不是"顺手精选"**——随 app 分发的每个内置包、每个音频文件，必须逐文件核验为
> `CC0-1.0`（SPDX 标识符，等同 Creative Commons Zero 1.0 Universal / 公有领域贡献），机器可判定可商用、可再分发、免署名。
> 用户通过 GUI 拖入的自带音频**不在此台账范围**（该通道自负其责，见 `docs/pack-standard.md` 适用范围）。

## 核验方法

每个文件的 CC0 归属通过三重独立证据交叉核验，缺一不可：

1. **来源页面**——素材发布页明确标注 License，并附截图快照。
2. **来源包内随附的 License 文件**——下载得到的原始压缩包内自带的法律文本（比网页更不易变动/更权威）。
3. **CC0 官方文本快照**——License 指向的 `creativecommons.org/publicdomain/zero/1.0/` 页面本身也存一份快照，防止来源页的链接文字与实际授权不符。

三份证据均存放在 [`license-snapshots/`](./license-snapshots/)，文件名含快照日期。

## 内置包：minimal-chime（极简铃音）

- manifest: [`minimal-chime/manifest.json`](./minimal-chime/manifest.json)
- 来源发布方：**Kenney**（www.kenney.nl），素材包 *Interface Sounds*（version 1.0，创建日期 2020-02-11，据包内 License 文件）
- 来源发布页：<https://kenney.nl/assets/interface-sounds>（页面自证 `License: Creative Commons CC0`，该文字本身超链接指向 `https://creativecommons.org/publicdomain/zero/1.0/`）
- 下载地址（当时抓取到的直链）：`https://kenney.nl/media/pages/assets/interface-sounds/fa43c1dd4d-1677589452/kenney_interface-sounds.zip`
- 原始压缩包 SHA256：`f2193d072726d6758a5f7871b2dcc54dcce0d5c35c6f0a62f92549b327c81232`
- 署名：CC0 不强制署名；Kenney 包内 License 文件写"欢迎但非强制"credit，此处仍记一笔以示尊重来源：Kenney (kenney.nl)。
- **处理声明**：下表四个文件均为对上述 CC0 原始音效的**派生处理**（裁剪 + 峰值归一化 + 淡入淡出 + 转码），处理流程按 `docs/pack-standard.md` 客观标准执行。CC0（公有领域贡献）明确放弃包括"改编权"在内的一切权利，派生处理**不产生新的许可限制**，处理后文件的 SPDX 归属仍为 `CC0-1.0`。

| manifest event | 分发文件 | SHA256 | 源文件（同一 CC0 包内） | 处理摘要 |
|---|---|---|---|---|
| `stop` | `minimal-chime/stop.mp3` | `18785bf9ecc525587af04ef2ef66e69fa45f486bdb38169776e35b1c339170ee` | `Audio/confirmation_002.ogg` | 裁静音 → 峰值归一化 -1.15dBFS(实测真峰值 -1.14dBTP) → 8ms淡入/30ms淡出 → 单声道44.1kHz/192kbps mp3；时长 0.526s |
| `stop_failure` | `minimal-chime/stop_failure.mp3` | `d6325e76d1042caa3158f6d18bb7ec0cc9e357d65b1f53b12581cafe836e725f` | `Audio/error_006.ogg` | 同上；实测真峰值 -1.17dBTP；时长 0.223s |
| `notification` | `minimal-chime/notification.mp3` | `945076dd43e096d4e38e8fbd91b27006a8b4c321efe0740fd65406027c7ce019` | `Audio/question_001.ogg` | 同上；实测真峰值 -1.13dBTP；时长 0.484s |
| `subagent_stop` | `minimal-chime/subagent_stop.mp3` | `eb0c3d7321c2d978e4cf04669b65e6666d4e5b671ea7af027bc2bcf396b13e3a` | `Audio/tick_004.ogg` | 同上；实测真峰值 -1.17dBTP；时长 0.055s |

**客观标准核验结果**（对照 `docs/pack-standard.md` 校验清单，全部通过）：

| # | 项目 | 门槛 | 四文件实测 |
|---|---|---|---|
| 1 | 单音时长 | ≤2.0s | 0.055s – 0.526s，远低于硬顶 |
| 2 | 峰值归一化 | -1.0dBFS ±0.3dB | -1.15 ~ -1.18dBFS（同一方法：峰值法） |
| 3 | 真峰值 / 防削波 | ≤-1.0dBTP，无采样点达0dBFS | -1.13 ~ -1.17dBTP；`max_volume` 实测 -1.2dB |
| 4 | 静音头尾裁剪 | 头≤50ms/尾≤80ms，淡入8ms/淡出30ms | 头部裁剪后未检出（<10ms）；尾部裁剪后 12.8ms/17.2ms（stop/stop_failure），notification/subagent_stop 未检出 |
| 5 | 四事件音高可辨 | 每对 f0 差 ≥1 半音(≥100 cents) | 实测 f0：stop 1170Hz / stop_failure 110Hz / notification 1480Hz / subagent_stop 3611.5Hz；六对最小差距 407 cents，远超门槛 |
| 6 | 容器/编码 | wav/mp3/aiff/m4a，≥22.05kHz，≤5MB | mp3，44.1kHz，单声道，192kbps；3.1KB–14.5KB |

**⚠️ 已知局限（best-effort，非数值项）**：§5 的"双击/单blip/上扬两音/下沉且保持"时序包络形状判据是**定性人耳判据**，我（agent）无法真人试听。四个文件已按语义命名（confirmation/error/question/tick）与实测音高走势挑选，但最终包络"像不像"仍需人耳确认——建议下一步用 GUI ▶ 试听核对，如听感不对可在同一 CC0 包内换选替代文件（`Audio/` 目录下同类别还有 `confirmation_001/003/004`、`error_001~008`、`question_002~004`、`tick_001/002` 等备选，均已随 zip 下载于处理流程中核验过 CC0，未选用的文件本身也可直接复用，无需重新走授权核验）。

## 来源下架 / 改证处理策略

CC0（Public Domain Dedication）在法律性质上是**不可撤销**的——作者一旦声明放弃版权，不能反悔收回已经授予公众的权利。这意味着：

1. **来源页面下架/改版/404**：不影响已采集文件的合法性。`license-snapshots/` 下的三份快照（页面截图+文字、包内 License.txt、CC0 官方文本截图）就是"采集当时状态"的存证，届时以快照为准，无需因页面消失而下架已分发的文件。
2. **发布方事后改变"新素材"的授权方式**（如 Kenney 未来某个新包不再用 CC0）：**不溯及既往**——只影响之后要不要采集该来源的新文件；本台账已收录的文件不受影响。但也意味着**每次新增文件都必须重新核验该次下载当下的 License，不能假设"这个来源一直是 CC0"**。
3. **可信证据表明某个 CC0 声明本身是错误的**（例如该素材实际混入了他人未经许可的版权内容，发布方误标）——按下列步骤处理：
   1. 立即将涉事文件从 `packs/<pack-id>/` 与已发布的 app bundle/Release 移除（不等待调查结束）；
   2. 按本文档流程，从其它已核验 CC0 来源另选替代文件补位，保证四事件不缺位；
   3. 若涉事文件已随某个 Release 分发过，在 `CHANGELOG`/Release Notes 注明"移除并替换 XX 事件音效，原因：来源版权存疑"，避免用户静默拿到问题文件却不知情；
   4. 在本文档补一条 Changelog 记录事件经过（时间、涉事文件、处理结果），供未来审计追溯。
4. **哈希不匹配**：任何时候 `packs/minimal-chime/*.mp3` 的实际 SHA256 与本表不符，视为文件被意外改动或损坏，须先查清原因（误编辑/合并冲突/损坏）再决定是否需要重新走处理流程，不得直接改表"对齐"现状了事。

## Changelog

- 2026-07-10：首个内置包 `minimal-chime` 建台账，四文件全部源自 Kenney *Interface Sounds*（CC0-1.0），经处理后落地。
