# 声音包客观标准（Pack Standard，T9）

> 对应 ENGINEERING.md 384/465（T9）："客观声音质量标准：单音时长上限（≤~2s）、响度归一化目标（峰值 -1 dBFS 或 -16
> LUFS）、峰值限制、静音头尾裁剪、三事件差异原则（音色/音高有别）；`master_volume`(0.0–1.0)→`afplay -v` 映射含默认值与越界钳制。"
>
> 本文档把上述每一条泛泛描述落实为**可核验的数值门槛**：具体阈值 + 判定方法（命令/公式），供策展声音包（`packs/`、`local-packs/`）
> 制作/校验时对照。v1 不随 app 附带自动化 lint 工具（doctor 只做"包完整性"只读检查，见 `Doctor.swift`），本文档是**人工/CI 脚本
> 均可执行**的规格来源；未来若要做 `claudio doctor --lint-pack` 之类的自动化校验器，也应以本文档的阈值为准，不再另立标准。

## 适用范围

- 适用对象：`packs/`（随 app 分发的策展包）与 `local-packs/`（IP 角色包，仅本机个人使用，见其 `SOURCES.md`）的四个 v1 事件
  音频文件：`stop` / `stop_failure` / `notification` / `subagent_stop`。
- 不适用：用户通过 GUI 拖入自带音频（T8, `gui/Sources/ClaudioGUICore/AudioImport.swift`）——那条通道是"合法皮卡丘的唯一通道"，
  走的是格式白名单 + 大小/时长上限的**技术兜底**（防滥用/防崩），不是这里的"策展音质标准"（音质好坏由用户自己承担）。两者数值
  刻意不必相同，见 §7"已知偏差"。

## 1. 单音时长上限

| 项目 | 数值门槛 | 判定方法 |
|---|---|---|
| 硬顶（含淡出尾巴） | **≤ 2.0s**，允许 ±0.02s 舍入容差（即读数 ≤ 2.02s 仍算通过，避免编码帧对齐带来的浮点误差误杀） | `ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 <file>` 读出的秒数须满足上限 |
| 推荐目标（非硬性） | ≤ 1.2s | 同上；四个事件里任一个逼近 2.0s 硬顶都建议重剪，高频事件（`subagent_stop`）尤其应短 |

理由：hook 是 Claude Code 响应路径上的同步调用，`claudio play` 本身立即返回（不等 afplay 退出，见 `Play.swift`），但用户体验上
声音仍需在合理时间内"说完"，且 ENGINEERING.md 92 的去抖窗口是 1.5s——单音明显长于去抖窗口会让"这次到底有没有响"更难判断。

## 2. 响度归一化目标

二选一，**同一个 pack 内四个事件必须用同一种目标**（不可混用峰值法和 LUFS 法，否则四个事件之间的主观响度会不一致）：

| 方法 | 数值门槛 | 判定方法 |
|---|---|---|
| 峰值归一化（peak normalize，**默认/推荐**，local-packs 处理链已验证） | 采样峰值目标 **-1.0 dBFS**，容差 ±0.3 dB（最终测得峰值须落在 **[-1.3, -0.7] dBFS**） | `ffmpeg -i <file> -af astats -f null - 2>&1 \| grep "Peak level dB"`；或 `sox <file> -n stat` 的 `Maximum amplitude` 换算 `dBFS = 20·log10(amplitude)` |
| 积分响度归一化（EBU R128 / LUFS，可选，用于要求跨包主观响度更一致的场景） | 积分响度目标 **-16 LUFS**，容差 ±1 LU（须落在 **[-17, -15] LUFS**） | `ffmpeg -i <file> -af loudnorm=print_format=json -f null - 2>&1`，核对 JSON 输出的 `input_i` 字段 |

## 3. 峰值限制（防削波 / 防有损编码 inter-sample 溢出）

| 项目 | 数值门槛 | 判定方法 |
|---|---|---|
| 真峰值（true peak，含 mp3 有损编码后可能出现的 inter-sample peak） | **≤ -1.0 dBTP** | `ffmpeg -i <file> -af astats=measure_overall=Peak_level:measure_perchannel=0 -f null -`，核对 `Peak_level` 字段 |
| 数字满量程削波 | 任何采样点 **< 0 dBFS**（不得达到或超过） | `ffmpeg -i <file> -af volumedetect -f null - 2>&1`，核对 `max_volume` 字段严格小于 `0.0 dB` |

§2 的峰值归一化目标（-1.0 dBFS）本身已经把峰值压在此限制之下；此条是对 §2 选择 LUFS 法（不直接控制峰值）时的**独立兜底**——无论
选哪种响度归一化方法，真峰值都不得突破 -1.0 dBTP。

## 4. 静音头尾裁剪

| 项目 | 数值门槛 | 判定方法 |
|---|---|---|
| 静音判定阈值 | 低于 **-50 dBFS** 的区间计为静音 | — |
| 起始静音保留量 | 裁剪至 **≤ 50ms**（保留极短缓冲防止咔哒声，而非裁到 0ms） | `ffmpeg -i <file> -af silencedetect=noise=-50dB:duration=0.02 -f null - 2>&1`，读出首个 `silence_end`（若音频以静音开头）距 0 的长度 |
| 结尾静音保留量 | 裁剪至 **≤ 80ms** | 同上，读出末个 `silence_start` 到文件结尾的长度 |
| 裁剪边界淡入 / 淡出（防咔哒声，local-packs 处理链已验证参数） | **淡入 8ms / 淡出 30ms** | 人工核对处理脚本参数（`ffmpeg -af "afade=t=in:d=0.008,afade=t=out:st=<dur-0.03>:d=0.03"` 或等效） |

## 5. 三/四事件音色·音高差异原则

四个事件（stop / stop_failure / notification / subagent_stop）**任两两之间**（共 C(4,2) = 6 对），必须在音高或音色上**至少一项**
可辨——满足下列任一判据即通过：

| 判据 | 数值门槛 | 判定方法 |
|---|---|---|
| 音高可辨（适用于有明确音高的音效） | 主导基频 f0 差异 **≥ 1 个半音**（`\|1200 · log2(f0_a / f0_b)\| ≥ 100 cents`，即比值 ≥ 2^(1/12) ≈ 1.0595） | 取该音频最响 100ms 窗口，用基频估计工具（如 `aubiopitch <file>`）取该窗口内 f0 的中位数，逐对比较 |
| 音色可辨（适用于打击/噪声类无明确音高的音效） | 频谱质心（spectral centroid）差异 **≥ 15%**（以两者中较低值为基准：`\|c_a − c_b\| / min(c_a, c_b) ≥ 0.15`） | `sox <file> -n stat -freq` 或脚本化时用 `librosa.feature.spectral_centroid`，取整段音频质心均值，逐对比较 |

定性锚点（呼应 DESIGN.md「动效跟随音高轮廓」——非可自动化的数值项，仅作设计意图人耳复核依据）：**Stop = 上扬两音、
StopFailure = 下沉且保持、Notification = 双击、SubagentStop = 单 blip**——四个事件的**时序包络形状**本身就应彼此不同；数值判据
（音高/音色）过关不代表包络形状对，制作时仍需按此对照试听。

## 6. 容器 / 编码规格

| 项目 | 数值门槛 | 判定方法 / 来源 |
|---|---|---|
| 容器白名单 | wav / mp3 / aiff / m4a 四选一 | 与拖入通道同一份 magic-byte 白名单：`gui/Sources/ClaudioGUICore/AudioFormat.swift` 的 `sniffAudioFormat`（按字节嗅探，不信任扩展名） |
| 采样率 | **≥ 22.05kHz** | `ffprobe -show_entries stream=sample_rate -of default=noprint_wrappers=1:nokey=1 <file>` |
| mp3 推荐编码参数（local-packs 处理链已验证，非强制但推荐，兼顾体积与音质） | 单声道 44.1kHz / 192kbps CBR | 人工核对编码命令参数（如 `ffmpeg ... -ac 1 -ar 44100 -b:a 192k -codec:a libmp3lame <out>.mp3`） |
| 文件大小上限 | **≤ 5MB**（已在拖入通道用代码强制，此处仅记录来源） | `gui/Sources/ClaudioGUICore/AudioImportEnvironment.swift` 的 `AudioImportLimits.maxFileSizeBytes` |

## 7. 已知偏差（非本次范围，留待后续对齐）

拖入通道（T8, `AudioImportLimits.maxDurationSeconds`，`gui/Sources/ClaudioGUICore/AudioImportEnvironment.swift:34`）当前时长上限是
**3.0s**，是 T9 之前定的占位值（ENGINEERING.md T8 非阻断遗留②已标注）。本文档 §1 把策展包的硬顶定为 **2.0s**，两者不一致。**本次 T9
范围只产出本文档 + `master_volume` 映射，不改动 `AudioImportLimits` 那个常量**——是否把拖入通道也收紧到 2.0s（或维持两条通道各自
独立的上限，因为拖入通道是"用户自带音频的技术兜底"而非"策展音质标准"）是一个独立的小任务，留给后续 `/plan-eng-review` 或专门
task 决定，此处仅记录偏差，不擅自变更该代码路径。

## 8. `master_volume` → `afplay -v` 映射

对应 ENGINEERING.md 决议⑤（"主音量 → `afplay -v` 默认值 → 倾向默认 0.8，越界钳制 0.0–1.0"），**已实现**：

- **语义与取值范围恒等**：`config.json` 的 `master_volume` 是 0.0（静音）–1.0（正常音量）的用户面板拨杆值
  （`helper/Sources/ClaudioCore/ClaudioConfig.swift`），`afplay -v <value>` 原生就取同一个 `[0.0, 1.0]` 区间（`1.0` = 正常音量，更低值
  线性衰减，见 `man afplay`）——因此这个映射是**恒等函数 + 钳制**，不做任何倍数/对数缩放。
- **默认值单一来源**：**0.8**，定义于 `ClaudioConfig.defaultMasterVolume`
  （`helper/Sources/ClaudioCore/ClaudioConfig.swift:11`）。`master_volume` 字段缺失/类型错误时的 JSON 解码回退，以及映射层遇到
  非有限值时的回退，**均复用这同一个常量**，全仓库不存在第二处硬编码的 `0.8` 字面量。
- **越界钳制规则**（`helper/Sources/ClaudioCore/Volume.swift` 的 `AfplayVolume`）：
  - 有限值 `< 0.0` → 钳到 `0.0`；`> 1.0` → 钳到 `1.0`。
  - **非有限值**（`NaN` / `+infinity` / `-infinity`）→ 直接回退到默认值 `0.8`，而不是强行钳到 `0.0`/`1.0`——避免把"配置数值本身
    已损坏"误当成"用户主动调到最静/最响"。`ClaudioConfig` 自身的 JSON 解码理论上不会产生非有限 `Double`（解码失败已在
    `ClaudioConfig.init(from:)` 层面回退到默认值），但 `AfplayVolume` 是 `public` 纯函数，GUI 音量滑杆等其它调用方可能在写入
    `config.json` 之前就直接调用它，因此仍需防御。
- **整合点**：`playSoundEvent` 的 afplay spawn（`helper/Sources/ClaudioCore/Play.swift`）固定拼接
  `["-v", AfplayVolume.afplayArgument(forMasterVolume: config.masterVolume), audioFile.path]`——`-v` 与其值是两个独立的
  argv 元素，绝不拼成一个字符串（`Process.arguments` 数组每个元素各自成一个 argv token）。
- **字符串渲染**：`AfplayVolume.afplayArgument(forMasterVolume:)` 用 Swift 原生 `String(Double)`，恒用 `.` 作小数点，
  不受宿主 locale 影响（不同于 `NumberFormatter`/`String(format:)` 可能在某些 locale 下产出 `,`）。
- **测试覆盖**：
  - 纯函数边界：`helper/Tests/ClaudioCoreTests/VolumeSuite.swift`（负值/越界/精确边界 0.0-1.0/非有限值回退默认/字符串渲染无逗号）。
  - 端到端整合：`helper/Tests/ClaudioCoreTests/PlaySuite.swift`（自定义 `master_volume`、越界 `master_volume` 钳制、
    损坏/错类型 `master_volume` 回退默认——均通过 `RecordingSpawner` 断言真实 spawn `arguments` 含 `-v` + 映射值）。

## 校验清单速查

| # | 项目 | 数值门槛 |
|---|---|---|
| 1 | 单音时长 | ≤ 2.0s（推荐 ≤ 1.2s） |
| 2 | 响度归一化 | 峰值 -1.0 dBFS ±0.3dB **或** 积分响度 -16 LUFS ±1LU（四事件同一种方法） |
| 3 | 真峰值限制 | ≤ -1.0 dBTP，且无采样点达到 0 dBFS |
| 4 | 静音头尾裁剪 | 头部 ≤ 50ms；尾部 ≤ 80ms；淡入 8ms / 淡出 30ms |
| 5 | 事件间差异 | 每对事件：f0 差 ≥ 1 半音 **或** 频谱质心差 ≥ 15% |
| 6 | 容器/编码 | wav/mp3/aiff/m4a；≥22.05kHz；≤5MB；mp3 推荐单声道 44.1kHz/192kbps |
| 8 | `master_volume`→`afplay -v` | 默认 0.8（单一来源 `ClaudioConfig.defaultMasterVolume`）；越界钳 [0.0,1.0]；非有限值回退默认 |
