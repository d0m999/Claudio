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
- **处理声明**：下表五个文件均为对上述 CC0 原始音效的**派生处理**（裁剪 + 音量调整 + 淡入淡出 + 转码）。CC0（公有领域贡献）明确放弃包括"改编权"在内的一切权利，派生处理**不产生新的许可限制**，处理后文件的 SPDX 归属仍为 `CC0-1.0`。

| manifest event | 分发文件 | SHA256 | 源文件（同一 CC0 包内） | 处理摘要 |
|---|---|---|---|---|
| `task_start` | `minimal-chime/task_start.mp3` | `c96fbbd8a2f34fe480e1f7b09ddd9392740fe44af43ca400889636ba802701d2` | `Audio/confirmation_003.ogg` | 裁至 0.290s → 8ms 淡入/30ms 淡出 → 音量下调 4dB → 单声道 44.1kHz/192kbps MP3；最终解码实测峰值 -6.5dBFS、平均 -20.0dBFS |
| `stop` | `minimal-chime/stop.mp3` | `18785bf9ecc525587af04ef2ef66e69fa45f486bdb38169776e35b1c339170ee` | `Audio/confirmation_002.ogg` | 裁静音 → 峰值归一化 -1.15dBFS(实测真峰值 -1.14dBTP) → 8ms淡入/30ms淡出 → 单声道44.1kHz/192kbps mp3；时长 0.526s |
| `stop_failure` | `minimal-chime/stop_failure.mp3` | `d6325e76d1042caa3158f6d18bb7ec0cc9e357d65b1f53b12581cafe836e725f` | `Audio/error_006.ogg` | 同上；实测真峰值 -1.17dBTP；时长 0.223s |
| `notification` | `minimal-chime/notification.mp3` | `945076dd43e096d4e38e8fbd91b27006a8b4c321efe0740fd65406027c7ce019` | `Audio/question_001.ogg` | 同上；实测真峰值 -1.13dBTP；时长 0.484s |
| `subagent_stop` | `minimal-chime/subagent_stop.mp3` | `eb0c3d7321c2d978e4cf04669b65e6666d4e5b671ea7af027bc2bcf396b13e3a` | `Audio/tick_004.ogg` | 同上；实测真峰值 -1.17dBTP；时长 0.055s |

**客观标准核验结果**（对照 `docs/pack-standard.md` 校验清单，全部通过）：

| # | 项目 | 门槛 | 五文件实测 |
|---|---|---|---|
| 1 | 单音时长 | ≤2.0s；`task_start` 额外要求 220–320ms | 0.055s – 0.526s；`task_start` 0.290s |
| 2 | 峰值 | 旧四音 -1.0dBFS ±0.3dB；`task_start` 不高于 -6dBFS | 旧四音 -1.15 ~ -1.18dBFS；`task_start` 最终解码 -6.5dBFS |
| 3 | 防削波 | 无采样点达 0dBFS | 全部通过；`task_start` 保留 ≥6dB 峰值余量 |
| 4 | 静音头尾裁剪 | 头≤50ms/尾≤80ms，淡入8ms/淡出30ms | 头部裁剪后未检出（<10ms）；尾部裁剪后 12.8ms/17.2ms（stop/stop_failure），notification/subagent_stop 未检出 |
| 5 | 声音可辨 | 各语义可由节奏/音高区分 | `task_start` 采用独立的 `confirmation_003` 短确认音；最终听感仍列入人工验收 |
| 6 | 容器/编码 | wav/mp3/aiff/m4a，≥22.05kHz，≤5MB | MP3，44.1kHz，单声道，192kbps；3.1KB–14.5KB |

**⚠️ 已知局限（best-effort，非数值项）**：节奏、上扬感、与现有四音的主观响度和辨识度属于**定性人耳判据**，自动分析不能替代真人试听。五个文件均按语义与客观音频指标选配；最终听感必须在 GUI ▶ 中人工核对。

## 来源下架 / 改证处理策略

CC0（Public Domain Dedication）在法律性质上是**不可撤销**的——作者一旦声明放弃版权，不能反悔收回已经授予公众的权利。这意味着：

1. **来源页面下架/改版/404**：不影响已采集文件的合法性。`license-snapshots/` 下的三份快照（页面截图+文字、包内 License.txt、CC0 官方文本截图）就是"采集当时状态"的存证，届时以快照为准，无需因页面消失而下架已分发的文件。
2. **发布方事后改变"新素材"的授权方式**（如 Kenney 未来某个新包不再用 CC0）：**不溯及既往**——只影响之后要不要采集该来源的新文件；本台账已收录的文件不受影响。但也意味着**每次新增文件都必须重新核验该次下载当下的 License，不能假设"这个来源一直是 CC0"**。
3. **可信证据表明某个 CC0 声明本身是错误的**（例如该素材实际混入了他人未经许可的版权内容，发布方误标）——按下列步骤处理：
   1. 立即将涉事文件从 `packs/<pack-id>/` 与已发布的 app bundle/Release 移除（不等待调查结束）；
   2. 按本文档流程，从其它已核验 CC0 来源另选替代文件补位，保证五事件不缺位；
   3. 若涉事文件已随某个 Release 分发过，在 `CHANGELOG`/Release Notes 注明"移除并替换 XX 事件音效，原因：来源版权存疑"，避免用户静默拿到问题文件却不知情；
   4. 在本文档补一条 Changelog 记录事件经过（时间、涉事文件、处理结果），供未来审计追溯。
4. **哈希不匹配**：任何时候 `packs/minimal-chime/*.mp3` 的实际 SHA256 与本表不符，视为文件被意外改动或损坏，须先查清原因（误编辑/合并冲突/损坏）再决定是否需要重新走处理流程，不得直接改表"对齐"现状了事。

## Changelog

- 2026-07-10：首个内置包 `minimal-chime` 建台账，四文件全部源自 Kenney *Interface Sounds*（CC0-1.0），经处理后落地。
- 2026-08-04：`minimal-chime` 升至 1.1.0；新增 `task_start.mp3`，源自同一 CC0 包的 `Audio/confirmation_003.ogg`，记录最终 MP3 哈希与解码后峰值。

## 历史试听候选包（已撤回）：2026-09-02

以下两组是上一轮随项目下载并整理的素材候选。它们因组内事件区分度不足而在本轮重设计前撤回，不再进入当前 `packs/` 或 App bundle；原始证据与历史哈希仍保留，便于追溯。当前有效候选见下方“重设计试听候选包”章节。

### soft-ui（柔和 UI）

- 来源发布页：[Kenney UI Audio](https://kenney.nl/assets/ui-audio)，页面标注 Creative Commons CC0。
- 官方下载：[kenney_ui-audio.zip](https://kenney.nl/media/pages/assets/ui-audio/490d233f68-1677590494/kenney_ui-audio.zip)。本次下载 SHA256：`946fc23a63d535d693eb31b2eabb80c8c28d6351e2186b344ceb71b2cb1d5eb6`。
- 证据快照：[`kenney-ui-audio-2026-09-02.png`](./license-snapshots/kenney-ui-audio-2026-09-02.png)、[`kenney-ui-audio-2026-09-02.html`](./license-snapshots/kenney-ui-audio-2026-09-02.html)、[`kenney-ui-audio-package-License-2026-09-02.txt`](./license-snapshots/kenney-ui-audio-package-License-2026-09-02.txt)、[`cc0-1.0-deed-2026-09-02.png`](./license-snapshots/cc0-1.0-deed-2026-09-02.png)。

| event | 分发文件 | 原始成员 | 分发文件 SHA256 |
|---|---|---|---|
| `task_start` | `soft-ui/task_start.mp3` | `Audio/rollover1.ogg` | `ad0b4aea771482ec9bf2cd81e26f72cd60eb01fc4a757771eae2688227896602` |
| `stop` | `soft-ui/stop.mp3` | `Audio/switch18.ogg` | `0c63fbe3f39cc886583541d641aec11b1a16da1a7e171e1facb2dd5c8b6356c6` |
| `stop_failure` | `soft-ui/stop_failure.mp3` | `Audio/switch30.ogg` | `f5377da9e059be48e2f5d4abcf34e02bf2837edf910a0c8e480bc90fec569648` |
| `notification` | `soft-ui/notification.mp3` | `Audio/switch38.ogg` | `2945565ee5adb1cbf6e01c4029e17be814f1c98246ef0e74eb9e7511690dcb8f` |
| `subagent_stop` | `soft-ui/subagent_stop.mp3` | `Audio/click1.ogg` | `7a1109a83406edc8fca05280906d9836af6720833efe8ddad3bff9eb291ecc2a` |

### workbench-feedback（实体工作台）

- 来源发布页：[Kenney RPG Audio](https://kenney.nl/assets/rpg-audio)，页面标注 Creative Commons CC0。
- 官方下载：[kenney_rpg-audio.zip](https://kenney.nl/media/pages/assets/rpg-audio/8e99002d76-1677590336/kenney_rpg-audio.zip)。本次下载 SHA256：`6dbeaf8544da958d8f2adcb4a4a4b76c1ade34a05f8ab9edccd327da7375f38b`。
- 证据快照：[`kenney-rpg-audio-2026-09-02.png`](./license-snapshots/kenney-rpg-audio-2026-09-02.png)、[`kenney-rpg-audio-2026-09-02.html`](./license-snapshots/kenney-rpg-audio-2026-09-02.html)、[`kenney-rpg-audio-package-License-2026-09-02.txt`](./license-snapshots/kenney-rpg-audio-package-License-2026-09-02.txt)、[`cc0-1.0-deed-2026-09-02.png`](./license-snapshots/cc0-1.0-deed-2026-09-02.png)。

| event | 分发文件 | 原始成员 | 分发文件 SHA256 |
|---|---|---|---|
| `task_start` | `workbench-feedback/task_start.mp3` | `Audio/bookPlace3.ogg` | `86982f8563989cd48daef96bf7abad2d277b4b05529c80a69c41b2ab93c261c8` |
| `stop` | `workbench-feedback/stop.mp3` | `Audio/bookClose.ogg` | `4227fc088925279c57cdd648cc43da5e791c25bfbd1808b0d5bd7ee0f0a50cc0` |
| `stop_failure` | `workbench-feedback/stop_failure.mp3` | `Audio/metalLatch.ogg` | `49059d3c482c288b20be5454f5578e4dc93675d11a35310ed7cbd38bbb0dea42` |
| `notification` | `workbench-feedback/notification.mp3` | `Audio/handleCoins.ogg` | `864ae761bd73689d87f863ef69260339e15c0793a47b8bc5b2b5d7996657ac86` |
| `subagent_stop` | `workbench-feedback/subagent_stop.mp3` | `Audio/bookOpen.ogg` | `71951b55cee21f8ab825006dbc21399e2f7b7f1a9221f32c5371fe95c8521819` |

## 重设计试听候选包：2026-09-02

本轮根据盲听区分度反馈重做。当前试听集合为：现有 `minimal-chime` 基准、`pizzicato-cadence`、程序化合成的 `night-console` / `resonant-bowl`，以及真实乐器候选 `soft-mallet`。上一轮 UI click 候选已在上方明确标记为历史撤回，不会被打包脚本复制。

重设计普通事件统一采用：先裁剪或组合源素材，再淡入 8ms、淡出 30ms、响度校准、真峰值保护，最后编码为 44.1kHz 单声道 192kbps MP3；长尾疗愈例外改用连续自然释放并在末尾增加明确数字静音保护区。事件语法固定为：`task_start` 短上行启动；`stop` 上行完成收束；`stop_failure` 下行或暗尾；`notification` 分离双脉冲；`subagent_stop` 最短回应音。最终是否进入默认发行集合仍以试听页盲听为准。

发布组装只消费 [`bundled-pack-selection.json`](./bundled-pack-selection.json) 中显式批准的 ID；当前批准集合仍只有 `minimal-chime`。候选目录存在于策展工作区不代表获准作为 Factory Pack 分发。

### pizzicato-cadence（拨弦旋律，主方案）

- 来源发布页：[Kenney Music Jingles](https://kenney.nl/assets/music-jingles)，页面标注 Creative Commons CC0。
- 官方下载：[kenney_music-jingles.zip](https://kenney.nl/media/pages/assets/music-jingles/f37e530b9e-1677590399/kenney_music-jingles.zip)。本次下载 SHA256：`b729ba57959bd58793d2c5cafa348aaf2655d354f3da35ec4729e03ec77197b8`。
- 证据快照：[`kenney-music-jingles-2026-09-02.png`](./license-snapshots/kenney-music-jingles-2026-09-02.png)、[`kenney-music-jingles-2026-09-02.html`](./license-snapshots/kenney-music-jingles-2026-09-02.html)、[`kenney-music-jingles-package-License-2026-09-02.txt`](./license-snapshots/kenney-music-jingles-package-License-2026-09-02.txt)、[`cc0-1.0-deed-2026-09-02.png`](./license-snapshots/cc0-1.0-deed-2026-09-02.png)。
- manifest：[`pizzicato-cadence/manifest.json`](./pizzicato-cadence/manifest.json)。

| event | 分发文件 | 原始成员 / 处理 | 分发文件 SHA256 |
|---|---|---|---|
| `task_start` | `pizzicato-cadence/task_start.mp3` | `Audio/Pizzicato jingles/jingles_PIZZI04.ogg`，裁至 300ms | `e9200f9c873d86afd315748de34a647013b6154a0157e178fc6d0543e06117c0` |
| `stop` | `pizzicato-cadence/stop.mp3` | `Audio/Pizzicato jingles/jingles_PIZZI02.ogg`，保留上行旋律 | `e8cae9cdcb11a8f540f184d0dedda533f28f61ebf2b804671751aa94c64b5fa7` |
| `stop_failure` | `pizzicato-cadence/stop_failure.mp3` | `Audio/Pizzicato jingles/jingles_PIZZI01.ogg`，保留下行旋律 | `b3e2f1f0533d70c4a07b7642373a12582b806f6b84008718ea070107ee0932f9` |
| `notification` | `pizzicato-cadence/notification.mp3` | `Audio/Pizzicato jingles/jingles_PIZZI16.ogg` × 2，中间 120ms | `69a71034e2cd5b53a20adb935e32e5abd88337bbafccf2add2b8673beb539800` |
| `subagent_stop` | `pizzicato-cadence/subagent_stop.mp3` | `Audio/Pizzicato jingles/jingles_PIZZI00.ogg`，裁至 240ms | `8a04ad9837caf92e518a9314b61a43b57fb9c0ad42c023abd3045e8b80cbc05e` |

## Claude 默认候选：程序化合成候选（2026-09-02）

这一轮根据本机 Vibe Island 可观察到的产品选择重新设计：保留一个统一的合成音色，五个事件共享同一套语义骨架；通过音高方向、音符数量、停顿、音区和包络表达状态。本候选由项目自有确定性合成器生成，不含第三方录音或采样，渲染文件以 `CC0-1.0` 发布。

- 统一源记录：[`claude-default-synth-source-2026-09-02.html`](./license-snapshots/claude-default-synth-source-2026-09-02.html)
- 源包许可证声明：[`claude-default-synth-package-License-2026-09-02.txt`](./license-snapshots/claude-default-synth-package-License-2026-09-02.txt)
- 官方 CC0 文本快照：[`cc0-1.0-deed-2026-09-02.png`](./license-snapshots/cc0-1.0-deed-2026-09-02.png)
- 生成器：[`scripts/generate-claude-default-packs.py`](../scripts/generate-claude-default-packs.py)，SHA256：`799f11bbfb42a86fbea6069a645dc5da7b105191c55addac44509e63ad302644`

### night-console（夜间控制台）

- manifest：[`night-console/manifest.json`](./night-console/manifest.json)
- 设计：低音区、缓启动、少高次谐波；把“低扰动”落实到音色和音区，适合长时间运行。

| manifest event | 分发文件 | 事件配方 | SHA256 |
|---|---|---|---|
| `task_start` | `night-console/task_start.mp3` | G3 → B3，280ms，低位上行 | `f8d8e81d4645892b691ebf870f56f02c386e3470ac84e80a7d6a58096ba72b6e` |
| `stop` | `night-console/stop.mp3` | G3 → B3 → D4，720ms，低音解决 | `aa358aa43b911ec710200417d6a30fb9eee452b489511fa2bef225c4373f2335` |
| `stop_failure` | `night-console/stop_failure.mp3` | D4 → A#3 → G3，700ms，低位下行 | `16380a25e55dac81b3d1b4649e168a4e10cd0f7a13a22ce7abcc37327b9e6f77` |
| `notification` | `night-console/notification.mp3` | B3 × 2，间隔 330ms，490ms | `9d5fe331c93136f5822de8799b469eafaca9b2d478aaf0a665a9593c706ea53f` |
| `subagent_stop` | `night-console/subagent_stop.mp3` | D3 单音，205ms | `bf13d0a1b0adc742024c129e41e2bb4ba6464b7e28917038f64b4b81f720095c` |

**本组验收状态**：当前已通过 manifest、格式、时长、峰值和精确哈希校验；本组仍属于候选，是否“好听、耐听、适合 Claude”以用户试听为准，不自动改变正式默认选择。

- 2026-09-08：`night-console` 升至 0.1.1；把 `notification` 的无声占位尾部裁短，按标准命令测得尾静音约 55ms。

## resonant-bowl（共鸣钵音，程序化基准样片）：2026-09-02

这是根据“敲钵般的圆润共鸣、疗愈感和更长自然尾韵”制作的独立基准样片。它不是对某一段真实钵声录音的复制，而是由项目自有确定性合成器直接生成：柔和合成敲击、非整数共鸣泛音、轻微音高回落、事件专属阻尼和短房间回声。生成器不读取第三方录音或采样；本组渲染文件声明为 `CC0-1.0`。

- manifest：[`resonant-bowl/manifest.json`](./resonant-bowl/manifest.json)
- 源记录快照：[`resonant-bowl-source-2026-09-02.html`](./license-snapshots/resonant-bowl-source-2026-09-02.html)
- 源包许可证声明：[`resonant-bowl-package-License-2026-09-02.txt`](./license-snapshots/resonant-bowl-package-License-2026-09-02.txt)
- 官方 CC0 文本快照：[`cc0-1.0-deed-2026-09-02.png`](./license-snapshots/cc0-1.0-deed-2026-09-02.png)
- 生成器：[`scripts/generate-resonant-bowl.py`](../scripts/generate-resonant-bowl.py)，SHA256：`08dfd38d466900c71bafdb577fd0767b8e09e7e3e69385b1e9eec38f196f6d5b`
- 统一处理：44.1kHz、单声道、192kbps MP3；`task_start` 最终时长 1.15s，前 320ms 完成启动辨识，随后连续 260ms 自然释放并保留 40ms 数字静音收尾，峰值不高于 -6dBFS；其余事件保留 740ms–1.84s 的自然共鸣，以同一种峰值法归一化，并统一保留 8ms 淡入和 30ms 边界淡出。

| event | 分发文件 | 原始生成语法 | 分发文件 SHA256 |
|---|---|---|---|
| `task_start` | `resonant-bowl/task_start.mp3` | C4 轻触 → G4 共鸣展开，前 320ms 为启动触发，260ms 连续自然释放 + 40ms 数字静音，1.15s 总长 | `c24f76eb9ac82d6e49c8447ebefd20dda0f54d6b13b902a905d768c6a6026ab8` |
| `stop` | `resonant-bowl/stop.mp3` | D4 单次完整钵声长尾，1.84s | `d21623f4ce7a248ca536c40a3679894474d6bb8773a08fed1223c08e94fcc64e` |
| `stop_failure` | `resonant-bowl/stop_failure.mp3` | A4 → F4 → D4 阻尼下行，1.42s | `4a134ee15bf84426f455237ef0e59549b62d077396e6112718661e573b6254d9` |
| `notification` | `resonant-bowl/notification.mp3` | G4 × 2，间隔 390ms，1.38s | `c7c07735969c3d677e270b53bb608cbe386e8b229aaaffb5c0cb877eb1df2481` |
| `subagent_stop` | `resonant-bowl/subagent_stop.mp3` | G3 单回应，740ms | `e0baa3d465b7f2c2d0a93a2a912909eae23ee0f01736ab118b227e23cbceb63f` |

**本组客观核验**：5 个 MP3 均为 44.1kHz、单声道、192kbps；`task_start` 为 1.15s，符合长尾疗愈例外（前 320ms 完成启动触发，随后连续自然释放，最终尾静音约 72ms）；其它事件均低于 2.02s。四个 lifecycle 音统一按峰值法处理，最终解码采样峰值约 -1.07dBFS；`task_start` 约 -6.76dBFS。本组是基准样片，不自动替换 `minimal-chime` 或正式默认选择。

- 2026-09-02：`resonant-bowl` 升至 0.1.3；`task_start` 增加自然释放段并延长至 1.15s，按长尾疗愈例外保留前 320ms 的启动辨识段。
- 2026-09-02：`resonant-bowl` 升至 0.1.4；修复自然释放与边界淡出之间的电平回跳，改为连续 260ms 释放并增加 60ms 全零静音收尾。
- 2026-09-08：`resonant-bowl` 升至 0.1.5；逐 Tone 淡出改在混入共享缓冲前完成，消除 0.84s 电平跳变；四个 lifecycle 音统一峰值归一，并把最终尾静音收紧到约 72ms。

## soft-mallet（柔槌信号，真实乐器候选）：2026-09-04

这是针对前几轮“合成感重、组内像同一个音、难以长期使用”的反馈制作的真实录音候选。音源来自 Versilian Studios LLC 发布的 Versilian Community Sample Library（VCSL），只选同一击奏乐器家族中的马林巴、软槌颤音琴、狭缝鼓和手铃。五个事件分别通过材质、脉冲数、节奏和包络表达状态；没有合成振荡器、噪声发生器或第三方未登记采样。

- manifest：[`soft-mallet/manifest.json`](./soft-mallet/manifest.json)
- 来源发布方：**Versilian Studios LLC**
- 官方发布页：[Versilian Community Sample Library](https://versilian-studios.com/vcsl/)，页面明确说明整套录音采用 Creative Commons Zero、可用于商业软件且无需署名或版税。
- 原始源码包：[sgossner/VCSL](https://github.com/sgossner/VCSL)，固定提交：`c1ea7bcc3c7309650ab0da9d15c9cd1fbc4a4c7e`。该提交根目录的 `LICENSE` 是完整 CC0 1.0 Universal 法律文本，`README.md` 再次明确整套声音采用 CC0。
- 证据快照：[`vcsl-source-2026-09-04.png`](./license-snapshots/vcsl-source-2026-09-04.png)、[`vcsl-source-2026-09-04.html`](./license-snapshots/vcsl-source-2026-09-04.html)、[`vcsl-package-License-2026-09-04.txt`](./license-snapshots/vcsl-package-License-2026-09-04.txt)、[`vcsl-package-README-2026-09-04.md`](./license-snapshots/vcsl-package-README-2026-09-04.md)、[`cc0-1.0-deed-2026-09-02.png`](./license-snapshots/cc0-1.0-deed-2026-09-02.png)。
- 生成器：[`scripts/generate-soft-mallet.py`](../scripts/generate-soft-mallet.py)，SHA256：`40325e975283123cd073bc87cbc229eea9a9eb70cd5b161a45abd45190386e7b`。
- 统一处理：固定源文件哈希 → 合并为单声道 44.1kHz → 70Hz 高通和 4.2–6.5kHz 温和低通 → 最多三层真实录音节奏编排 → 8–18ms 起始柔化与逐击自然淡出 → 30ms 末端淡出 → 30ms 全零保护区 → 16-bit PCM WAV。普通事件按 `-16 LUFS ±1 LU` 校准；`task_start` 按峰值不高于 `-6dBFS` 的例外校准。

### 原始录音成员

| 代号 | VCSL 固定提交内路径 | 源文件 SHA256 |
|---|---|---|
| `C4` | `Idiophones/Struck Idiophones/Marimba/Marimba_hit_Outrigger_C4_soft_01.wav` | `4d03d005166e8b366e6a983b7a4a89e0847e1d58a6d34dda35ddf74289cace94` |
| `G4` | `Idiophones/Struck Idiophones/Marimba/Marimba_hit_Outrigger_G4_soft_01.wav` | `d3e23f018b091a60d91c3c93b38b605d02a9e26c7cf5830ffb866cfe84130cd0` |
| `F3` | `Idiophones/Struck Idiophones/Marimba/Marimba_hit_Outrigger_F3_soft_01.wav` | `6eb7ccf5fa10b1bdaf10f0cc7a50d8c42ef086636a9e88c6527fb3af58e5ee1f` |
| `VibeC5` | `Idiophones/Struck Idiophones/Vibraphone/Soft Mallets/Vibes_soft_C5_v1_rr1_Main.wav` | `be995c1164dcbbcf83688d095864a4abd0feaa68b71d1d2e78c35f62461fc03b` |
| `LogHi` | `Idiophones/Struck Idiophones/Slit Drum/LogDrumHi_MedM_v1_rr1_Sum.wav` | `6ca70964e7d1dd80daf6c67cff226db6e0cadbff3234944de9055c3ef1d7f4eb` |
| `LogLo` | `Idiophones/Struck Idiophones/Slit Drum/LogDrumLo_MedM_v1_rr1_Sum.wav` | `cb77b9a6e7fc560d03b45102632ee0be5d08158cb03f59d63dd6fd2c4443ba4f` |
| `ChimeE4` | `Idiophones/Struck Idiophones/Hand Chimes/sus_E4_r01_main.wav` | `7196b23009e1acc8e03591c35e54144487991c75cfe22413e84e0bbfeb478caf` |

### 分发文件

| event | 分发文件 | 真实录音语法 | 时长 / 响度 / 尾部 | 分发文件 SHA256 |
|---|---|---|---|---|
| `task_start` | `soft-mallet/task_start.wav` | 马林巴 C4 → G4，短上行双击 | 0.530s；峰值 -7.0dBFS；尾静音约 46ms | `77129919204ffcba7fe9c98a27719921846779b6b043abccdae53a2732e38a8b` |
| `stop` | `soft-mallet/stop.wav` | 马林巴 C4 → G4，落到软槌颤音琴 C5；前两击与最终落点局部峰值差低于 10dB | 1.010s；-16.0 LUFS；真峰值约 -8.2dBTP；尾静音约 41ms | `96904072281bfb5d46139cfed2897e393204e49d573073aa45e1fc3df478d4fd` |
| `stop_failure` | `soft-mallet/stop_failure.wav` | 狭缝鼓高音 → 低音，闷木双击下行 | 0.710s；-16.5 LUFS；真峰值约 -1.4dBTP；尾静音约 76ms | `5b4cc9a746fd5574583e3b0b69a5629eeb58dcb7c0c39e658687f0b34e639f84` |
| `notification` | `soft-mallet/notification.wav` | 手铃 E4 × 2，间隔 280ms | 0.730s；-17.0 LUFS；真峰值约 -7.5dBTP；尾静音约 40ms | `7b5b953ed7aa5fd0c2ca22087fa89c205572e565cf7feaf7edabac3474e72cac` |
| `subagent_stop` | `soft-mallet/subagent_stop.wav` | 马林巴 F3 单次低位回应 | 0.490s；-17.0 LUFS；真峰值约 -8.7dBTP；尾静音约 41ms | `d8ae9fc4a132357fa1275ee7d5a198d53cbb1047b561167af6d15ece67cfb240` |

- 2026-09-08：`soft-mallet` 升至 0.1.1；统一使用 30ms 末端淡出和 30ms 全零保护区，按标准命令将五个事件尾静音收紧到约 40–76ms。

**本组验收状态**：源授权、源文件哈希、格式、时长、响度、真峰值、末尾全零区和 10 对事件的频谱/时序差异已核验；真人“悦耳度”、随机盲辨和十分钟疲劳测试尚未完成。本组只加入试听页，不自动替换当前默认选择。
