# SenseAudio 生产候选验收、证据身份与回滚台账

本文件是 `senseaudio-cn` 从受门禁实现走向生产暴露的唯一操作台账。领域与网络合同仍由
`CONTEXT.md`、ADR 0011、ADR 0014 和 `plan/PLAN-CONSUMER-TTS-EXECUTION.md` 拥有；本文件只规定如何构造
非分发验收候选、如何记录证据、何时允许 activation，以及如何安全回滚。

发布这份文档不会完成任何门禁。本文创建时没有使用真实 API Key、没有执行付费调用、没有联系
SenseAudio、没有构造非分发 app、没有完成原生键盘或 VoiceOver 验收，也没有授权 production
activation。默认 registry 仍只有既有四个 profile，`productionSenseAudioAssetPolicy` 必须保持
`nil`，默认 Provider 仍为 `elevenlabs-global`。

2026-09-15，ADR 0015 将 SenseAudio 凭据录入收口到 Claudio 内的掩码输入框和私有本地文件。
该路径不再依赖 Data Protection Keychain 签名权限。旧 Keychain 项保持原样；新候选须验证保存、
重启读取和生成取用，不沿用旧候选的凭据验收结论。本地存储不是加密存储或同用户进程隔离。

2026-09-14，项目所有者采用 ADR 0014 的“项目所有者接受的实测资源合同”，固定
`https://dynamic.senseaudio.cn:443` 与 `audio/mpeg`，并接受 URL 有效期和 host 轮换未知造成的可用性
风险。本次文档决定只解除“必须等待官方确认”这一外部依赖；它不把此前资源发现升级为正式 smoke，
也不完成非分发候选、原生验收或 production activation。

关联工作：总规格 #183；本台账 #188；外部与人工验收 #187；T8 门禁通过后的 activation #189。

## 状态词与当前基线

只使用以下状态，禁止用“基本完成”“看起来可用”代替：

- `NOT RUN`：没有在绑定身份上执行；
- `NOT AUTHORIZED`：需要真实 Key、付费、厂商联系或生产变更，但尚未取得单独授权；
- `NOT VERIFIED`：缺少满足本台账的证据；
- `BLOCKED EXTERNAL`：本地工作不能替代的外部合同或真实系统证据尚未取得；
- `RISK ACCEPTED`：项目所有者已明确接受一项有边界的剩余风险；它不代表对应真实 smoke 已通过；
- `CLOSED`：production policy 明确为 `nil`，profile 未进入默认 allowlist；
- `PREPARED LOCAL`：绑定 commit 上的 fixture、harness 与 build 已通过，仅证明本地准备；
- `PASSED` / `FAILED`：对应门禁在绑定身份上有完整、脱敏且可复核的记录；
- `ACTIVATED`：单独评审的 production policy 与 allowlist 变更已完成，且后续 Bundle 复验通过。

当前基线如下；后续只能在实际执行并填写证据引用后更新：

| 层级 | 当前状态 | 当前事实 |
|---|---|---|
| 本地实现聚合与自动门禁 | 历史 `PASSED`；修复后结果见第 24 节 | 第 19 节测试宿主同步及 GUI 9626/helper 3272 属于旧基线；审查后 ACL 与资源失败分类不沿用旧自动门禁 |
| production 暴露 | `CLOSED` | `productionSenseAudioAssetPolicy == nil`；`senseaudio-cn` 不在默认 allowlist |
| 实测资源合同决策 | `RISK ACCEPTED` | exact origin/MIME/匿名 GET/零 redirect 已固定；URL 有效期与 host 轮换未知作为可用性风险接受 |
| 正式付费 smoke | 历史 `PASSED`；修复后受影响项 `NOT VERIFIED` | 第 12/17/23 节的 3 TTS + 1 SFX 保留历史；第 24 节改变凭据校验和 SFX 失败语义，不能继续用旧 no-source-delta 理由覆盖新实现 |
| 非分发候选原生启动 | `PASSED`（窄项） | `e4b2b39` PID 42542 的实际设置窗口与历史三个编号候选已取得；第 20 节再次确认同一 app 的设置窗口，不覆盖完整键盘/VoiceOver |
| 原生听感 | `RISK ACCEPTED`（动物意图质量） | 中文 TTS/木琴听感通过；第 23 节所有者明确接受当前 animal 意图不匹配的质量风险，历史失败与根因未知保留，不认定模型为根因 |
| 原生键盘与生成冻结 | `PASSED`（所有者人工确认） | 第 21 节冻结、输入法及 Space/Return 取消恢复；第 23 节完整键盘焦点顺序人工确认通过，不冒充执行方观察 |
| partial 实际展示 | `RISK ACCEPTED`（未实测） | 第 23 节所有者因难以复现明确接受 1/3、2/3 可见面板未验证的风险；第 18 节隔离串联 147 checks 的工程证据保留，不等同实际 app 展示通过 |
| 异常恢复、失败保旧绑定与回滚 | `PASSED`（所有者人工确认） | 第 23 节所有者确认通过，结合第 18 节隔离串联证据；本轮执行方未操作真实凭据、绑定或 production |
| VoiceOver 人工验收 | `RISK ACCEPTED`（所有者豁免、未验证） | 第 22 节明确暂不纳入本轮 SenseAudio 必验门禁；不记为通过，不宣称完整旁白支持，已有实现保留 |
| T8 整体验收 | `RISK ACCEPTED`（本轮验收闭合） | 第 23 节绑定固定 e4 候选，未豁免项已有工程/真实 smoke/所有者人工通过证据；动物质量、partial 实际展示与 VoiceOver 风险明确接受，不宣称全部实测通过 |
| production activation | `NOT AUTHORIZED` / `NOT VERIFIED` | 历史 T8 按第 23 节闭合；第 24 节新实现的受影响证据、单独授权及最终 Bundle 复验仍是 #189 前置条件 |
| Release / distribution | `NOT RUN` | 没有签名 universal RC、notarization、双架构或正式批准 |

## 不可跳过的门禁顺序

```text
本地准备
  → 项目所有者接受的实测资源合同与精确 policy
  → 单独授权的付费 TTS/SFX smoke
  → 绑定同一非分发候选的听感与键盘（风险接受按第 22–23 节显式记录）
  → 单独评审的 activation
  → 最终 Bundle 复验
  → 独立 Release/分发流程
```

前一层成功不能替代后一层。TTS 成功不能证明 SFX；SFX 返回 URL 不能证明它符合固定 asset policy；HTTP 2xx
不能证明音频可播放；自动化不能证明原生键盘、VoiceOver 或真实听感；ad-hoc app 不能证明 Release。

## 1. 本地准备与非分发候选构造

### 1.1 聚合 commit

先在隔离 worktree 中汇总 #183 的已批准实现，工作树与 index 必须为空。记录完整 commit 和 tree
身份，不接受分支名、短 SHA 或未提交补丁作为候选身份：

```bash
git status --porcelain=v1
git rev-parse HEAD
git rev-parse HEAD^{tree}
```

在 production policy 仍为 `nil` 的该 commit 上执行仓库门禁：

```bash
swift run --package-path helper claudio-tests
swift run --package-path gui claudio-gui-tests
swift build -c debug --package-path gui --product ClaudioGUI
jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings
git diff --check
```

只有命令、完整 commit、环境和脱敏结果都记录后，才可把本层改为 `PREPARED LOCAL`。这仍然不证明
真实 Provider、资源合同、真实音频、原生 UI、签名、公证或 production readiness。

### 1.2 实测资源合同先于验收候选

非分发候选只能使用 ADR 0014 已固定的精确 HTTPS origin:443 与 MIME；随后正式 smoke 必须在同一
policy 上验证每个返回 URL 和 GET，才能继续原生验收与 activation。不得从后续响应、DNS 后缀或 URL
路径动态学习或扩大信任范围。返回值一旦偏离固定 policy，状态写 `FAILED` 并停止候选；不得改成任意
HTTPS、通配 host、自定义资源服务器或 TTS-only。

用于证据绑定的 policy 规范化字节固定为以下单行、key 排序的 UTF-8 JSON，并在行末追加一个 LF；
除该 LF 外没有空白：

```json
{"acceptable_mime_types":["audio/mpeg"],"allowed_origins":["https://dynamic.senseaudio.cn:443"],"profile_id":"senseaudio-cn"}
```

该规范化字节的 SHA-256 固定为
`6f570cf99d8fc8bfcf040c49ac4182afa1ab16d0baca74eb072a7f083e5d200d`。不得写入路径、签名 query、
示例完整 URL 或 credential。policy 内容或 digest 变化会使依赖它的 smoke、原生候选与 activation
证据失效。

### 1.3 构造非分发 app

真实 Provider 与原生验收需要一个显式标记为 `NON-DISTRIBUTION` 的隔离候选。2026-09-15 审查后，
后续候选从包含全部功能修复、合同与回归测试的干净聚合 commit 建立；再叠加 ADR 0014 固定的精确
asset policy、必要 activation/非分发标记及其门禁测试。该 patch 必须形成独立本地 commit，不夹带
其他功能或验收证据文件。证据文档另行提交并引用实际受测 candidate commit/tree，不将证据提交冒充
受测源码。第 9–23 节历史候选保持原记录，不按新构造规则重写历史。可分发分支中的
`productionSenseAudioAssetPolicy` 在 T8 全部门禁完成前仍必须为 `nil`。

验收候选不得上传 release、公开下载、发给未授权测试者或合入可分发分支。构建前再次确认工作树为空，
然后运行完整门禁和本地 bundle 构建：

```bash
bash scripts/dev-bundle.sh
bash scripts/check-release-size.sh dist/claudi0.app
```

`scripts/dev-bundle.sh` 只产生当前架构、ad-hoc signed 的本地 inspection app。它不是 universal、
Developer ID signed、notarized 或可分发 RC。候选 archive 应放在 Git 外的临时目录；它只用于固定本次
被测试字节，验收结束后可删除：

```bash
candidate_evidence_dir="$(mktemp -d)"
ditto -c -k --sequesterRsrc --keepParent \
  dist/claudi0.app "$candidate_evidence_dir/claudi0-NON-DISTRIBUTION.zip"
shasum -a 256 "$candidate_evidence_dir/claudi0-NON-DISTRIBUTION.zip"
```

每个候选必须记录以下身份；任一项待填都不能开始付费或原生验收。下表保留第 11–13 节上一正式
候选的身份；当前候选完整身份见第 17 节：

| 字段 | 值 |
|---|---|
| Candidate ID | `senseaudio-t8-20260915-1ef3c5d1-arm64` |
| 聚合 base commit / tree | `77b1513bf4b09e08912ef4c87c132bb9a06fcf2d` / `17a044b101a905ead173919c7a38352f15f5b1e2` |
| 候选 commit / tree | `1ef3c5d1838eaa889d83a2a1c117436d73834361` / `d9ef9c64971c2f81d9034cfaa67a3d83e07e0027` |
| base→candidate 精确 diff | 仅原 policy/activation、相应 registry 测试与非分发标记；8 文件，+63/-26；diff SHA-256 `71794f07e52a01a6c6cfbecf7b42b4cc1c442454f7070949695f63964b59a75d` |
| Policy 规范化 JSON / SHA-256 | 第 1.2 节固定 JSON；`6f570cf99d8fc8bfcf040c49ac4182afa1ab16d0baca74eb072a7f083e5d200d` |
| `CFBundleIdentifier` | `com.claudio.app` |
| `CFBundleShortVersionString` / `CFBundleVersion` | `0.0.0-dev` / `0.0.0-dev` |
| CPU / macOS | arm64 / macOS 26.6.2 (25G83) |
| signing identity / Team ID / CDHash | ad-hoc / 未设置 / `2e17679f9d0dd388a3cd115704bc1269589876f8` |
| 主 app executable SHA-256 | `25fd84ff3003c614f61de3f6e268d4da6430507fb0f44453bc00badd421cc97a` |
| helper / LoginItem executable SHA-256 | `1160b35d08ac163404196de7f0e863fea026db1ba97342ff65888582f1fba921` / `13f2ac6cff8ce1d2d97b5445626b7d22acb05c5335b570dfdb3372868bb5d28d` |
| 非分发 archive SHA-256 | `4cc4b0aa2ce77d055464d348919b50fdaf106676b1b270496e2c18b3ca967d0a`；archive 保持在 Git 外 |
| 自动门禁结果引用 | 第 11 节；同一干净候选的完整设置集成门禁退出 0 |

不得用 `dist/` 路径、分支名、窗口截图或“刚刚构建”替代这些身份字段。

### 1.4 受影响重验与已有证据继承

本节将台账统一到 CONTEXT、ADR 0011 与 ADR 0014 已有的“候选实质变化时重验受影响证据”决定。
2026-09-15，项目所有者在明确保留未受影响证据、只补缺失项的收尾方案后要求完成剩余项目并闭合 T8。
不能仅因 commit 或 Bundle digest 不同就把全部历史结果重置，也不能仅凭“没有改接口”豁免重验。

继承一项证据必须同时记录：

1. 原验收候选与当前候选的完整 commit/tree、policy digest、Bundle 身份、环境及原证据引用；
2. 两候选之间全部相关源码、localization、构建脚本与依赖定义的精确 diff 和 SHA-256；
3. 逐门禁说明影响范围。Provider、registry、请求编译、transport、下载或音频校验变化须重验受影响的
   真实生成/下载；凭据策略变化须重验凭据链；描述状态、视图、焦点或文案变化须重验受影响的原生交互；
4. 当前干净候选自身通过自动门禁，重新绑定实际 Bundle；不能继承旧 Bundle 的构建、签名或 size 结论。

只有原项已经实际 `PASSED` 且其行为不受 diff 影响时，才能写“`PASSED`，继承自指定候选与证据”。
原项为 `NOT VERIFIED`、`FAILED`，或仅有 fixture/资源发现/播放状态的，不能升级成真实 smoke 或
人工验收。无法证明影响边界时保持 `NOT VERIFIED`。原始失败、未听反馈和请求计数全部保留；
继承不产生新的请求次数，也不意味着 production activation、Issue 关闭或 Release。

## 2. 项目所有者接受的实测资源合同

项目所有者于 2026-09-14 接受以下固定合同及剩余风险。它是 Claudio 自己执行的信任边界，不是
SenseAudio 对未来行为的保证，也不因决策本身而取得真实 smoke 的 `PASSED`：

| 合同项 | 固定政策或已接受风险 |
|---|---|
| 下载 origin | 只允许 `https://dynamic.senseaudio.cn:443`；不含 path/query，不允许子域通配、IP 或其他端口 |
| MIME | 只允许 exact `audio/mpeg`；随后仍检查 MP3 magic、5 MiB 与 3 秒限制 |
| GET 认证 | 完全匿名；独立 asset fetcher 不发送 Bearer、Cookie 或 Referer |
| redirect / final URL | redirect 必须为零；final URL 必须与预检 URL 完全一致 |
| URL 生命周期 | 收到后只在当前显式生成中立即下载，不持久化完整 URL、path 或 query |
| URL 有效期与 host 轮换 | 未知，状态为 `RISK ACCEPTED`；任何漂移都作为可用性失败，不允许扩大 policy |

正式技术链路验证现为 `PASSED`，见第 12 节；凭固定候选源码门禁与实际成功下载证明执行接受，
未保留原始抓包。首次或受影响路线的真实 smoke 必须证明所有实际 URL 在首个 GET 前通过整批
preflight，且每个 GET 的 origin、MIME、认证、redirect、final URL 与音频校验均符合上表。任一项失败，
T8 写 `FAILED` 并保持 production 隐藏；若 activation 后观察到漂移，本次生成 fail closed，并按第 7 节
回滚，而不是运行时学习新 host。此前不绑定正式候选的资源发现只能作为该决策的输入，不能代替本层。

## 3. 首次付费 smoke

本节表格保留分阶段记录；当前候选的证据继承与最终收口以第 17、23 节为准，不把旧待填项当作
新付费调用的要求，也不虚构新的 probe 或生成次数。

#188 和本文件本身不授权真实 Key 或付费。执行前必须取得一次新的、明确的授权，内容至少包括测试账户、可撤销限额
Key、最大生成请求数、预计费用上限、候选身份和执行窗口。Key 只通过应用掩码输入进入 ADR 0015
规定的私有本地凭据文件；不得
进入 shell history、环境变量、文档、issue、日志、截图或 Git。

建议首次付费预算恰好为：

- TTS：3 次生成 POST，对应三个 numbered speech 候选；
- SFX：1 次 native-batch 生成 POST，`variants_count=3`；
- 合计：最多 4 次生成 POST。

`POST /v1/get_voice` 是保存 Key 所需的只读 probe，但必须另记网络尝试次数，不能把它称为已确认免费。
SFX asset GET 也要记录尝试数；它不是增加生成 POST 预算的理由。SenseAudio 生成 POST 一律不自动 retry。
任何失败后的第二轮生成、扩大预算或更换账户，都必须处于明确授权范围；授权可以预先覆盖本 session
后续付费调用，不必逐轮重复索取，但仍记录每轮次数、零 POST 自动 retry 与真实结果。asset GET 只能按既有合同执行同一
URL 最多一次限定瞬态 retry。

执行结果按路线独立记录：

| 检查 | 状态 | 脱敏证据引用 |
|---|---|---|
| required voice probe 可见 `female_0033_b` | `NOT RUN` | 待填 |
| TTS 三次 POST、零 retry | `PASSED` | 第 12 节；同候选 3 次 HTTP 200，零 retry |
| TTS 三个 MP3 均通过 5 MiB / 3 秒本地检查 | `PASSED` | 第 12 节；1.800 / 1.800 / 1.980 秒，均 0600 |
| SFX 单次 batch POST、零 retry | `PASSED` | 第 12 节；61856 ms / HTTP 200，零 retry |
| SFX 所有实际 URL 在首个 GET 前通过 exact policy preflight | `PASSED` | 第 12 节；固定源码先整批预检后顺序下载，3 个候选全部发布 |
| GET 无 credential、无 redirect、MIME 与 MP3 magic 匹配 | `PASSED` | 第 12 节；固定 fetcher 门禁接受 3 次真实 HTTP 200 下载，未留原始抓包 |
| complete/partial 与实际可播放候选数一致 | `NOT VERIFIED` | 第 12 节；complete 的 3/3 已核对，真实 partial 1/3 与 2/3 尚未验证 |
| `.mixed` / 非 `zh*` speech 在读 Key 与联网前失败 | `NOT RUN` | 待填（本地自动证据） |

真实 smoke 失败时保留失败状态与脱敏原因，不自动增加预算，不把 TTS 成功写成整个 profile 成功。

## 4. 原生与听感验收

下表保留早期逐项记录；第 21–23 节的所有者人工确认与风险接受是当前结论，历史未验证和失败
不追溯改写。当前闭合不代表每一个原生项目均由执行方实测通过。

本层受影响或尚未完成的项目必须在当前绑定的 app 字节、同一 policy 和同一 macOS/CPU 上完成。
已经通过且未受变化影响的项目只能按第 1.4 节显式继承，不静默改写候选身份。DEBUG gallery、fixture、
compiled SwiftUI tests 与源代码检查只能作准备证据，不代替实际听感、输入法或 VoiceOver。

| 流程 | 状态 | 必须观察 |
|---|---|---|
| profile 与披露 | `NOT RUN` | SenseAudio 名称、固定 voice 资格、`.cn` 非驻留承诺、费用/数据边界 |
| credential | `NOT RUN` | 保存只读 probe；invalid key 与 voice missing 分开；失败保留旧 active key |
| 本地凭据持久化 | `NOT VERIFIED` | 第 12 节：重启后已保存凭据供真实生成使用，权限与 metadata 核对；完整保存失败/导出等流程未在本候选重验 |
| 中文 speech | `NOT VERIFIED` | 第 12 节：恰好 3 个编号候选，均完成原生播放状态检查；不截断、不朗读 style 描述等待听感判定 |
| animal / soundEffect | `NOT VERIFIED` | 第 12 节：各一次真实 SFX 的生成、下载与播放状态通过；描述匹配等待听感判定 |
| SFX partial | `NOT RUN` | 1/3 与 2/3 的可见 banner、候选顺序；VoiceOver 数量摘要按第 22 节暂豁免 |
| unsupported | `NOT RUN` | `.mixed` 与非中文 speech 在读 Key/联网前明确失败并保留描述 |
| 键盘 | `NOT VERIFIED` | 第 12 节：名称框可聚焦；本机 keyboard mode 0，Tab 跳过候选按钮；未改变系统设置，完整焦点顺序未验证 |
| VoiceOver | `RISK ACCEPTED`（所有者豁免、未验证） | 第 22 节；本轮不要求人工验证编号、时长、播放/停止、partial、名称与采用动作旁白语义，已有实现保留 |
| 采用与回滚 | `NOT VERIFIED` | 第 13 节人工反馈一次采用成功；持久化读回、失败保留旧绑定与回滚仍未验证 |

听感记录只保存每个可见候选的 `pass/fail + 非敏感原因`。不得保存音频、台词、声音描述、响应正文或
可反推出内容的逐字转录。numbered 候选只评价可辨差异和意图匹配，不虚构 styled 标准。

## 5. 证据 allowlist 与禁区

### 允许写入台账、issue 或评审材料

- 完整 source commit/tree SHA、ticket/评审引用、执行时间、macOS 与 CPU；
- 固定 endpoint path、model、voice、HTTP status 与脱敏 request ID；
- 精确 asset origin（仅 scheme + hostname + port）、exact MIME、redirect 次数与 GET 是否带认证；
- 每项字节数、时长、容器/magic 结论、候选数量、`complete` / `partial`；
- 生成 POST / probe / asset GET 的尝试次数和批准预算是否用尽；
- policy 的规范化 JSON 与 SHA-256；
- Bundle identifier/version、架构、签名类型、Team ID/CDHash、可执行文件与 archive SHA-256；
- 自动门禁的命令、通过/失败摘要；人工项目的 `pass/fail + 非敏感原因`。

request ID 必须脱敏为不可用于查询原请求的摘要，例如只保留有标识的 SHA-256；不得保留原值。

### 禁止写入或附加

- API Key、Authorization、Cookie、Referer、Keychain 内容或任何可恢复 credential；
- 声音描述、prompt、台词、请求 body、响应 body、错误中的原始 payload；
- 完整 asset URL、path、签名 query、query 参数或 redirect target；
- 生成音频、波形、可反推出内容的转录或包含音频的 screen recording；
- 用户/账户标识、私有项目路径、临时目录、真实包名、manifest、receipt、日志原件；
- 可能露出上述内容的终端输出、网络抓包、截图或第三方 dashboard 导出。

若现有工具只能产出含禁区字段的原始文件，证据保留在受控本机且不进入仓库、issue 或评审附件；台账只
写人工复核后的 allowlist 摘要。不要先提交再删除，因为 Git 历史仍会保留秘密。

## 6. Activation 与最终 Bundle 绑定

只有第 1–4 层未豁免门禁全部 `PASSED`，且第 22–23 节三项风险接受有明确记录，#189 才可在单独分支中：

1. 把 ADR 0014 固定且经正式 smoke 匹配的精确 policy 固化为非 `nil`；
2. 将完整 `senseaudio-cn` 加入默认 allowlist，同时保持默认 Provider 为 `elevenlabs-global`；
3. 不增加任意 endpoint/model/voice/region/origin，也不加入 TTS-only 或 fallback；
4. 运行全部自动门禁，构造新的最终 Bundle，并完成最低限度的 profile、credential、speech、SFX、
   partial、键盘与采用复验；VoiceOver、partial 实际展示和动物意图质量按第 22–23 节风险接受范围
   处理，不记为实测通过；
5. 记录最终 commit/tree、policy digest 和 Bundle identity，并与非分发候选逐项比较。

若最终 commit 与候选 commit 不同，必须记录相关路径的精确 diff。若 provider、registry、runtime、
transport、asset fetch、generation、credential、UI、localization、音频验证或构建脚本有任何实质变化，
受影响的付费、原生与 Bundle 证据必须重验；不能用“只是合并 commit”自行豁免。只有相关 source tree、
policy digest 与实际 Bundle 字节都完成绑定后，状态才可写 `ACTIVATED`。

本轮 VoiceOver、partial 实际展示及动物意图质量风险接受按第 22–23 节记录；相关实现未变化时
最终 Bundle 复验可沿用该有边界范围，实质 source delta 仍须重验，不自动继承风险或扩大安全政策。

Activation 仍不等于 Release。universal 架构、Developer ID、Hardened Runtime、notarization、staple、
Gatekeeper、DMG checksum、双架构真机与正式批准继续走独立 release 台账。非分发 ad-hoc 候选不能被
改名或复制成 RC。

## 7. 安全回滚

如果固定资源合同不再匹配、Provider 行为漂移、回归出现或上线后需要撤回：

1. 在单独评审的修复中把 production asset policy 恢复为 `nil` 并从默认 allowlist 移除
   `senseaudio-cn`，或分发上一已知安全版本；
2. 验证 production registry 恢复既有四 profile，默认仍是 `elevenlabs-global`，且不会自动改用其他
   Provider 重新生成；
3. 不删除或改写 `senseaudio-cn` 本地凭据文件或既有 Keychain item；是否删除凭据仍由用户显式决定；
4. 不删除已采用的本地音频、用户声音包或 manifest 绑定；它们已经是普通本地资产；
5. 只清理由当前 generation 拥有、尚未采用的私有临时候选，不触碰共享根、兄弟目录或历史资产；
6. 保留脱敏验收摘要与撤回原因，移除任何公开下载候选，但不伪造旧证据为“从未发生”。

回滚只关闭新的生成入口，不撤销用户已完成的本地采用，也不引入跨 Provider fallback。

## 8. 验收记录模板

以下字段全部绑定后才允许签字；不得预填成功：

| 字段 | 结果 |
|---|---|
| Candidate ID | 待填（`NOT VERIFIED`） |
| Source commit / tree | 待填 |
| Policy JSON / SHA-256 | 待填 |
| Bundle identity / executable digests | 待填 |
| 自动门禁 | `NOT RUN` |
| 实测资源合同决策 | `RISK ACCEPTED`；正式 policy smoke `NOT RUN` |
| 付费授权引用 / 预算 | `NOT AUTHORIZED` |
| TTS smoke | `NOT RUN` |
| SFX smoke | `NOT RUN` |
| 听感 | `NOT RUN` |
| 键盘 | `NOT RUN` |
| VoiceOver | `NOT RUN` |
| Activation commit / Bundle | `NOT VERIFIED`；严格依赖 T8 |
| Release | `NOT RUN` |
| 验收人 / 日期 / 结论 | 待填；当前不得写通过 |

## 9. 2026-09-15 本地凭据候选执行记录

本节是第 1.3 节候选的脱敏执行摘要，不授权 activation 或 Issue 关闭。两个无关 mockup 未进入
任何提交；可分发分支的 production policy 仍为 `nil`。验收摘要只更新在可分发分支的台账中，
不改变被测候选身份。

### 第一次正式 smoke 与根因

被取代候选 `senseaudio-t8-20260915-7588095e-arm64` 在重启后显示 SenseAudio 凭据“已保存 · 已验证”。
执行方没有读取、打印、导出或修改 Key，也没有访问旧 Keychain。候选在隔离的非全局声音作用域中
发出恰好 3 次 TTS POST，零 retry，并返回 3 个可播放 MP3；文件均为 0600、`audio/mpeg`、ID3 MP3，
字节数为 26825、26825、34313，探测时长为 1.656、1.656、2.124 秒。三个候选各播放一次；听感结论
仍需验收人确认，不能由文件检查替代。

同一候选随后发出唯一一次 SFX batch POST，零 retry。TLS 成功且 165-byte 请求体已发送，但
10.671 秒内没有收到响应头或响应字节，随后客户端返回 `NSURLErrorDomain Code=-999`；asset GET 为 0，
因此没有进入 `audio_url`、origin、MIME、redirect 或 MP3 校验。界面按设计未保存任何候选，也未执行
第二次生成。

脱敏系统网络记录与源码共同确认根因：通用 unary transport 从 `task.resume()` 起将
`connectionSeconds = 10` 误作“首个 HTTP 响应”计时器；SenseAudio SFX 是服务端先计算、后返回 JSON 的
长计算 POST，已完成 TLS 与请求发送仍会被该计时器取消。修复提交
`187c3f9b1153ec30d290e87ddb1184595781f2b3` 增加 route-owned `responseStartPolicy`：只有 SenseAudio SFX
在响应头前共享 60 秒 generation absolute deadline；voice probe、TTS 和其他路线保持原 connection
budget，所有响应在 headers 后仍执行 20 秒 inactivity、wire ceiling、redirect 和总 deadline 门禁。
回归用例先因接口不存在失败，修复后完整 GUI harness 通过 `9445/9445`。

该修复改变源码与 app executable，因此第一次正式候选的 TTS、启动和人工结果不能继承给新候选。

### 修复后正式候选自动证据

修复后聚合 base 为 `187c3f9b1153ec30d290e87ddb1184595781f2b3`，新 NON-DISTRIBUTION 候选为
`senseaudio-t8-20260915-62faf8ae-arm64`。候选 worktree/index 干净；base→candidate 仍只包含 8 个
policy/activation、相应 registry 测试和非分发标记文件。

| 检查 | 结果 |
|---|---|
| 完整设置门禁 | `PASSED`：helper 3272 / GUI 9446；`bash scripts/verify-settings-experience.sh 7640166bc1d04d084db0baee40434d297a16951c` 退出 0 |
| Debug/Release presentation 与 ClaudioGUI、Release helper/LoginItem | `PASSED` |
| localization JSON、diff check | `PASSED` |
| strict format baseline 比较 | `PASSED`：baseline/HEAD 均为 1315 条，无新增诊断 |
| 最终签名后 app executable / helper / LoginItem | `PASSED`：5608768 / 2862896 / 72192 B，均在各自上限内 |
| 最终签名后非可执行资源 / Bundle 正规文件合计 | `PASSED`：689969 / 9233825 B，上限分别为 1500000 / 11250000 B |
| dev-bundle、ad-hoc 签名验证、archive 身份 | `PASSED`；仍非 universal、Developer ID 或 notarized release |
| Node selector / Python candidate 回归 | `PASSED`：selector executable seam；11 项 Python 测试 |

门禁脚本的 format baseline 必须是候选历史祖先；候选为保留独立 NON-DISTRIBUTION 审计提交而先叠加
activation patch、后 cherry-pick 修复，故使用共同祖先 `7640166`。第 1.3 节另以修复后聚合 base
`187c3f9` 对候选做精确 tree diff，确认只有原 8 个候选文件。

### 当前未完成项

`62faf8ae` 候选现已启动并执行第二轮正式 smoke，结果见第 10 节；听感、键盘、VoiceOver、partial、
采用与回滚仍未完成。

结论：10 秒响应头误超时已修复，但该候选 SFX 又在 60 秒总预算内超时，T8 **未闭合**。
未 push、未修改 Issue、未启用 production；T9 仍保持阻塞。

## 10. 2026-09-15 60 秒正式 smoke 与 180 秒路线预算

`senseaudio-t8-20260915-62faf8ae-arm64` 于 `2026-09-15T03:37:20Z` 开始正式窗口。凭据文件执行前后
为普通文件、0600、67 bytes，inode/mtime 不变；执行方未回读、打印、导出或修改 Key，未访问旧
Keychain。恰好 3 次 TTS POST、零 retry、均 HTTP 200；得到 3 个 0600 MP3，分别为 26825 / 29129 /
32009 bytes，时长 1.656 / 1.800 / 1.980 秒，均满足 5 MiB / 3 秒，三个 numbered 候选各播放一次。
技术检查通过，听感结论仍待验收人给出。

唯一一次 SFX batch POST 已发送请求体、TLS/h2 成功，但 60643 ms 后以 `NSURLErrorDomain Code=-1001`
结束；响应状态 -1、首字节与响应 bytes 均为 0，没有 JSON 或 `audio_url`，asset GET = 0。因此这是
原 60 秒预算内无响应，不是资源 policy 拒绝；不能断言供应商或本机代理是唯一原因。未自动 retry、
未采用候选、未修改凭据、Issue 或 production。脱敏详情保存在 Git 外的 `run.md`，不保存音频、
台词、描述、响应正文或完整资源 URL。

项目所有者随后授权仅将 SenseAudio `animal` / `soundEffect` 改为 **180 秒 route-owned deadline**，
其他 Provider、SenseAudio speech 与 voice probe 保持 **60 秒**；同一点击起点贯穿 POST、顺序 GET、
限定 GET retry 与本地校验，headers 后 20 秒 inactivity 和 ADR 0014 全部下载边界不变。
本 session 后续付费调用已整体授权，执行方无需每轮重新请求付费批准；这不授权凭据导出/修改、
候选采用、production activation、push、发布或 Issue 关闭。新实现必须绑定新候选并记录真实结果，
不得把本节历史 TTS 成功当作新 Bundle 的 smoke 通过。

## 11. 180 秒候选准备证据

新聚合 base 为 `77b1513`，非分发候选 `senseaudio-t8-20260915-1ef3c5d1-arm64` 的完整身份已写入
第 1.3 节。base→candidate 仍仅原 8 个候选文件，未夹带实现或证据编辑；候选 worktree/index 干净，
main 的两个无关 mockup 未进入提交。production policy 仍为 `nil`。

`bash scripts/verify-settings-experience.sh 4e03a87` 在同一干净候选退出 0：helper 3272/3272，
GUI 9462/9462，Debug/Release presentation 与 ClaudioGUI、Release helper/LoginItem、bundle、
ad-hoc 签名、localization、diff 和 size 全通过；strict format baseline/HEAD 均 1315，无新增。
Node selector executable seam 与 Python candidate 11 项通过。最终签名后 app/helper/LoginItem 为
5608912 / 2862896 / 72192 bytes，非可执行资源 689969，Bundle 正规文件合计 9233969，全部在预算内。
archive 压缩校验通过；仍非 universal、Developer ID 或 notarized release。

新候选进程路径已确认；原生控制在没有可见窗口时曾返回 `timeoutReached`，随后项目所有者手动打开
「设置 → 事件与提示音」，真实执行结果见第 12 节。本 session 付费调用已获整体授权，
开窗等待不是付费授权门禁。未修改或导出凭据；未采用候选、push、启用 production 或更改 Issue。
完整脱敏 `run.md` 与 archive 保持在 Git 外。T8 尚未闭合。

## 12. 180 秒候选真实 smoke 与原生进度

本节只对应第 1.3 节绑定的 `senseaudio-t8-20260915-1ef3c5d1-arm64`，不继承旧候选结果。
项目所有者手动打开原生设置后，固定 Bundle 使用重启前已保存的凭据完成以下真实调用；
执行方未回读、打印、导出或修改凭据内容，也未访问旧 Keychain。

### soundEffect

点击起点 `2026-09-15T04:44:59.817Z`。一次点击恰好 1 次 native-batch POST、零 retry，
实际 request/resource timeout 为 179.9 秒；61856 ms 后 HTTP 200，响应 2194 bytes。
该成功响应晚于旧 60 秒预算，证明 route-owned 180 秒在真实调用中生效。

随后恰好 3 次 asset GET，均 HTTP 200，transaction 451 / 401 / 335 ms，零 retry；
剩余 request/resource timeout 为 118.0 / 117.6 / 117.2 秒，未在下载时重新发放 180 秒。
3 个 MP3 均为 32929 bytes / 2.037500 秒 / 0600。完整 3/3 候选发布意味着同一固定源码的
整批 exact policy preflight 与逐项 MIME/magic/体积/时长/匿名/零 redirect 门禁均接受。
这不是原始抓包审计，不持久化 URL、headers、请求或响应正文。

### 中文 speech

点击起点 `2026-09-15T04:48:31.902Z`。一次点击恰好 3 次 TTS POST、零 retry，均 HTTP 200，
transaction 735 / 642 / 828 ms；request/resource timeout 为 59.9 / 59.1 / 58.5 秒，
speech 保持 60 秒共享预算。MP3 为 29129 / 29129 / 32009 bytes，1.800 / 1.800 / 1.980 秒，均 0600。
AX 显示候选 1/2/3，时长 1.8 / 1.8 / 2.0 秒。

### animal（补充原生路线轮次）

点击起点 `2026-09-15T04:50:46.643Z`。一次点击恰好 1 次 native-batch POST、零 retry，
实际 request/resource timeout 179.9 秒；61901 ms 后 HTTP 200，响应 2166 bytes。
随后 3 次 GET 均 HTTP 200，transaction 564 / 344 / 398 ms、零 retry；剩余 timeout 为
118.0 / 117.4 / 117.1 秒。3 个 MP3 均为 32929 bytes / 2.037500 秒 / 0600。
该轮另计，不改变正式 3 TTS + 1 SFX 轮次的计数。

### 原生与剩余门禁

正式轮次 6 个候选和 animal 补充轮次 3 个候选均逐个播放一次，原生按钮由「播放」变「停止」再恢复，未见 UI 错误；
没有把播放状态当作听感通过。关闭未采用的 composer 后临时文件计数回到 0，事件绑定未改变。
名称框可聚焦，但本机 `AppleKeyboardUIMode = 0` 时 Tab 跳到下一事件 identity，未进入候选按钮；
未擅自改变系统键盘设置，完整键盘验收尚未完成。听感、VoiceOver、真实 partial 1/3 与 2/3、
采用与回滚仍待完成。动物叫声按补充轮次另计。

正式轮次累计：voice probe 0、TTS POST 3、SFX POST 1、asset GET 3；POST/GET retry 0。
加上 animal 补充轮次：voice probe 0、TTS POST 3、SFX POST 2、asset GET 6；POST/GET retry 0。
另在 `2026-09-15T04:54:19.847Z` 验证 mixed 明确拒绝并保留描述，修改后错误清除；
`2026-09-15T04:54:34.493Z` 验证缺少台词引号的语音输入有明确引导并保留描述。
两次本地检查窗口内没有系统日志网络任务；读凭据前拒绝另由固定源码顺序与回归覆盖证明。
非 `zh*` speech 的原生检查尚未执行，不将中文 UI 输入英文台词等同于非中文 locale。
收尾凭据目录/文件仍为 0700/0600、67 bytes，inode/mtime 与执行前一致；未读明文。
app executable digest 复核一致，隔离候选 worktree/index 仍干净；所有测试 composer 均已关闭。
T8 未闭合，production policy 仍为 `nil`；未采用候选、push、变更 Issue 或启动 T9。

## 13. 人工生成反馈与描述冻结改进

项目所有者在绑定的 `1ef3c5d1` 原生候选上自行操作，并明确反馈“成功生成了声音，听完了，生成验证
成功，已经采用其中一个”。该反馈记录为一次手动生成、听感及采用成功；执行方没有代点采用、撤销
采用或改声音包绑定。原生状态查询只确认凭据仍显示已保存、已验证；采用 composer 已不在屏幕上，
没有据此声称取得采用文件或 manifest 的持久化读回证据。没有编号级反馈，不把先前未听的三个 TTS
或所有 animal/soundEffect 候选批量标记 `PASSED`；手动轮次调用数未复核，不混入第 12 节计数。

同日批准描述冻结改进：生成期间显示同外观的只读区域，状态层拒绝 `.generating` / `.adopting`
期间的描述修改；面板内主动取消走“取消”，关闭窗口、来源/profile 切换、deadline 与网络失败的
终止保护保持。实现、自动门禁和新候选证据另行记录；旧候选上的人工结果保留历史事实，受影响的
生成交互必须在新绑定字节上复验，不能把新代码构建成功写成原生验收通过。

T8 闭合审计仍缺：编号级中文 TTS 与 animal/soundEffect 听感、完整键盘与 VoiceOver、真实 partial
1/3 和 2/3、采用持久化读回/失败保旧绑定/回滚，以及本候选完整凭据管理流程。不得以单次可用、
fixture 或自动门禁替代；production policy 保持 `nil`，不启动 T9、不更改 Issue。

## 14. 描述冻结候选与受影响交互复验

本节为焦点修正前候选的历史记录；当前候选见第 15 节。第 1.3 节身份表与第 11–13 节保留为上一正式候选历史。该隔离分支继承上一
候选的八文件 exact policy/activation patch，仅加入已批准的描述冻结实现、回归与合同同步；
没有扩大 policy、改变生成预算、修改凭据实现或覆盖已采用音频。当前工作分支仍未提交；候选绑定
提交仅在隔离分支，不 push。

| 字段 | 当前冻结候选 |
|---|---|
| Candidate ID | `senseaudio-t8-20260915-93031a5b-arm64` |
| baseline commit / tree | `1ef3c5d1838eaa889d83a2a1c117436d73834361` / `d9ef9c64971c2f81d9034cfaa67a3d83e07e0027` |
| candidate commit / tree | `93031a5b2a479d9c7911fccba3ea3cec22a747c6` / `95160969cd90c8ced72b67efe1e52dbfdb1cad56` |
| baseline→candidate diff | 12 文件，+320/-38；`git diff --binary` SHA-256 `6790e6c8da50ac92ab4b70d336588dca941c6ad790f53deac6a33a9bb2248701` |
| policy SHA-256 | 第 1.2 节规范化字节不变：`6f570cf99d8fc8bfcf040c49ac4182afa1ab16d0baca74eb072a7f083e5d200d` |
| Bundle identifier / version / build | `com.claudio.app` / `0.0.0-dev` / `0.0.0-dev` |
| CPU / macOS / distribution | arm64 / macOS 26.6.2 (25G83) / `NON-DISTRIBUTION`、`SenseAudio-T8` |
| signing / Team / CDHash | ad-hoc / 未设置 / `8625676c734ac6864f593d3f6948990ea02f9f37` |
| app executable SHA-256 | `ef567d8e19177787dbbce09bb31f43899dfad91231ef3f166cf52e2835b09874` |
| helper executable SHA-256 | `1f2bd485c01cd902260c60d80b5bba805306d57cdd6fb5ae817465af42fcffd7` |
| LoginItem executable SHA-256 | `8895692c1d5accf357020e4df8332a45acb3014935b0351454ea930cc4fedea2` |
| archive SHA-256 | `ca5ac9b05a55ba52b00ad722884a3e5b83c7fc008ed5e8f419c56995a8ad00d5`；保持 Git 外 |

### 自动门禁

`bash scripts/verify-settings-experience.sh 1ef3c5d1838eaa889d83a2a1c117436d73834361` 在干净
候选 HEAD 上退出 0：helper 3272、GUI 9480 checks 全通过；GUI target/product Debug 与 Release、
helper/LoginItem Release、本地 Bundle 签名、size、localization、diff 全通过。正规文件总计
9250878 bytes / 11250000 bytes；严格格式 baseline/HEAD 均 1315 条，新增诊断 0。

先确认旧实现的状态回归与原生挂载回归失败，再实现保护并转绿。生成态生产 SwiftUI 树不再挂载
`NSTextView`，编辑态对照实际包含可编辑输入器；状态层覆盖冻结原描述、原请求内容/次数、显式
取消恢复、迟到结果清理、采用态保护。真实 runtime 的旧迟到测试改为先显式取消再修改描述，未删除
dispatcher/engine 清理断言。生成完成后的修改描述仍保留旧候选清理回归。

主工作树 GUI 复跑 9479 checks 全通过。首轮另有旧取消假设失败与两项声音库轮询超时；主工作树
helper 两次出现未改动的 NVM shim 探测失败，旧候选 helper 与干净当前候选的 3272 项均通过。
未确定这些环境敏感失败的根因、未修改无关 helper 或声音库实现，也未隐去失败记录。

### 原生与付费状态

旧候选无打开的 composer、无进行中生成时由原生退出，再启动当前固定 Bundle（PID 41762）。
原生控制前两次绑定超时；项目所有者手动开窗后取得当前进程的原生设置。在 Codex 作用域确认
凭据显示“已保存 · 已验证”，且所有者此前采用的用户发起事件音频映射在新进程中读回；结合正规
MP3 文件核对，记录一次采用的持久化读回，不把它等同于失败保旧绑定或完整回滚。

SFX 第一轮点击 `2026-09-15T06:11:05.994Z`：1 次生成 POST / 0 retry，request/resource timeout
179.9 秒；61932 ms 后 HTTP 200。3 次 GET 均 HTTP 200，248 / 335 / 265 ms / 0 retry，剩余 timeout
117.9 / 117.7 / 117.3 秒；3 个正规 MP3 均 32929 bytes / 2.037500 秒 / 0600，原生发布编号 1/2/3。
当前新候选累计 voice probe 0、TTS POST 0、SFX POST 1、asset GET 3；没有凭据录入、回读、
打印、导出或修改。

生成期间 AX 描述控件不再 settable，锁定 hint 和原描述均存在；尝试键盘字符与安全测试文本粘贴，
原描述未变、生成仍在进行，无额外生成请求。粘贴工具报“应用未读取剪贴板”，后续原生查询确认
测试文本未出现。第一轮删除键因工具键名不支持未真正派发，不能标记通过。该轮在尝试点击取消前已经
完成，不能把成功发布候选误记为取消恢复或迟到结果丢弃通过。当前 SFX 听感等待编号级人工反馈，
执行方暂停面板操作以便所有者逐项试听。所有者随后针对这三个当前候选明确反馈“听得到，符合意图”；
记录这组三个 SFX 的听到与意图匹配，不扩展为中文 TTS、animal 或 VoiceOver 的验收。

第二轮 SFX 为独立取消回归，点击 `2026-09-15T06:18:48.340Z`；1 次 POST、0 GET、0 retry，
179.9 秒预算。生成中真正派发 `BackSpace` 后原描述与 generating 均保持；点击“取消”约 10.6 秒后
网络任务以 `NSURLErrorCancelled (-999)` 结束，原生立即恢复可写描述框并保留原描述。
超过原响应约 62 秒观察点后，仍为编辑态、无候选复活，临时候选文件为 0。该轮不承诺远端停止计费。
新进程此前“修改描述”移除旧候选后，临时文件同样为 0；已采用事件绑定未改变。

焦点检查 `FAILED`：生成与恢复编辑时实际焦点均落回 task_start 事件行，不在取消/描述框；
恢复后未点描述框的粘贴不被接收，手动点描述框则能正常聚焦。确认不是只读冻结失败，
但尚不满足文档所承诺的焦点交互。采用挂载后请求焦点的修正，新字节见第 15 节。
本候选累计 voice probe 0、TTS POST 0、SFX POST 2、asset GET 3；POST/GET retry 0。

键盘字符/粘贴/删除冻结和显式取消恢复编辑已完成上述窄验证；实际输入法提交与实际 VoiceOver 朗读均 `NOT VERIFIED`，自动焦点为上述 `FAILED`；
原生挂载测试不代替这些实测。上一候选中所有者已采用资产的只读文件核对找到一个正规 MP3：
32929 bytes / 2.037500 秒 / 0600；与本节新进程事件映射读回对应，不覆盖完整回滚。

完整脱敏 `run.md`、`candidate-gate.txt` 与 archive 保持在 Git 外的本地验收证据目录。台账后续
写回不改变已固定候选字节。T8 尚未闭合；production 隐藏、默认 Provider 保持 ElevenLabs，
不启动 T9、不 push、不变更 Issue。

## 15. 挂载后焦点修正候选

当前候选 ID `senseaudio-t8-20260915-b9907e2e-arm64`。baseline 为第 14 节完整 commit；
candidate commit `b9907e2e75cffcdb08b87063d18648171dfff931`，tree
`51245bc1c97b9fd7e8cfdc8cf1e15ded9d42405d`。baseline→candidate 仅两个文件、+13/-7：
焦点请求改在条件控件挂载后的、可取消且检查当前 phase 的生命周期任务中执行；取消按钮显式
focusable。没有修改状态层描述门禁、Provider、deadline、asset policy、凭据或已采用绑定。
另一文件仅纠正 DESIGN 遗留“官方合同”措辞到已接受的 ADR 0014 实测合同。
精确 `git diff --binary` SHA-256 为
`eedbda4c264b1ae459be7b182a1da0b386e14160117da2e161c3b6b2e915ca1c`；policy digest 不变。

焦点回归先以真实 AX 控件稳定复现：恢复描述后 focus ID 不是描述框，直接粘贴不被接收；手动聚焦
对照成功。该实际 first-responder 行为仍须由原生回归判定，不能以隐藏窗口挂载或 compiled seam
冒充通过。修正后聚焦 GUI 回归 103 checks、0 failures。干净候选的完整设置门禁退出 0：
helper 3272、GUI 9480 checks 全通过，Debug/Release、localization、Bundle 签名、size、diff 均通过；
正规文件合计 9250878 bytes / 11250000 bytes，strict format baseline/HEAD 均 1315、新增 0。

| Bundle 字段 | 当前值 |
|---|---|
| identifier / version / build | `com.claudio.app` / `0.0.0-dev` / `0.0.0-dev` |
| CPU / macOS / class | arm64 / macOS 26.6.2 (25G83) / `NON-DISTRIBUTION`、`SenseAudio-T8` |
| signing / Team / CDHash | ad-hoc / 未设置 / `bb1c6fe3095ad4bcff342530e532492aa1bb63a9` |
| app SHA-256 | `2948d2322410a268289bbd0ce6e9bf0a8754005cd2cd786d7df418c91ce0002d` |
| helper SHA-256 | `1f2bd485c01cd902260c60d80b5bba805306d57cdd6fb5ae817465af42fcffd7` |
| LoginItem SHA-256 | `8895692c1d5accf357020e4df8332a45acb3014935b0351454ea930cc4fedea2` |
| archive SHA-256 | `7bddd7d11e9f7c5cd12c21430159f6e9c4b9933adae8afed088e2f42bd0bc427`；Git 外 |

旧候选已无在途任务、无临时文件并原生退出，再开始干净 HEAD 构建。门禁开始时新候选尚未启动，
voice probe/TTS/SFX/GET 均为 0；没有在 Bundle 身份完整前开始新原生或付费验收。

以上身份已完整；固定 Bundle 启动（PID 62434）后最初因没有可读窗口绑定超时。所有者手动打开设置后，
已取得该窗口的真实 AX 树：SenseAudio 显示已保存、已验证；Codex 用户发起事件保留上一采用映射。
打开 Stop 描述面板后，实际 AX 焦点仍为 `event-settings.event.task_start.identity`；不点击输入框的
已知安全文本粘贴未被应用读取，描述未改变、生成未开始。因此本候选原生自动焦点 `FAILED`，
不能以完整自动门禁通过覆盖。此轮 voice probe/TTS/SFX/GET 仍全部为 0；凭据文件 metadata 未变。

新增可选真实 key-window 回归入口 `--ai-cue-native-focus`，显式运行 AppKit event loop 并让出 MainActor；
初次编辑挂载通过，而生成→取消恢复编辑时真实 NSTextView 未成为 first responder，5 checks、1 failure。
只在替换控件的可取消 lifecycle task 中先 `Task.yield()`，再检查 phase 并请求焦点后，同一回归变为
5 checks、0 failures。它是新本地修正的证据，不是本节固定 Bundle 的通过记录；取消按钮 AX 焦点与
最终新 Bundle 的实际输入仍须复验。

记录保持在 Git 外焦点候选验收目录的 `run.md`、`candidate-gate.txt` 和 archive 中。T8 仍未闭合，
production 隐藏，不启动 T9、不 push、不变更 Issue。

## 16. phase 清焦点与替换控件请求排序修正候选

本节保留排序修正候选的历史；当前增加真实取消键处理的候选见第 17 节。

当前候选 ID `senseaudio-t8-20260915-2317a91-arm64`；baseline 为第 15 节完整 commit。
commit `2317a9175339350c3675eebe1cac0899d327b37c`，tree
`4dae08e986c5d991477a9c3ec86f8f6038e11f98`。仅 3 个相关文件、+61/-1：替换控件 focus task 先
`Task.yield()`，随后保留 phase 与 cancellation 检查；新增真实 key-window 描述焦点回归及可选入口。
精确 binary Git diff SHA-256
`46159f4c749074fdf679c64dde315f46824bc03119d1cc2e8b44b0f7f2b3dcba`。其他 Provider、deadline、
asset policy、凭据及已采用绑定均未修改，policy digest 仍为第 1.2 节固定值。

该回归先红后绿；独占原生窗口的 3 次复跑均为 5 checks、0 failures。候选 HEAD 上也为
5 checks、0 failures，覆盖初次编辑与生成→取消恢复编辑后的真实 NSTextView first responder。
一次与另一原生 app 操作重叠的运行失败于 key-window 前置条件，失败记录保留；没有记为通过。
进程内 AX getter 返回 SwiftUI scroll/proxy，不能用它冒充取消按钮的真实硬件键激活或 VoiceOver。
候选回归 stderr 中 IMK mach-port warning 已保留，也不扩展为实际输入法通过。

完整设置门禁退出 0：helper 3272、GUI 9480 checks 全通过，Debug/Release、localization、Bundle
签名、size、diff 均通过；正规文件合计 9250894 bytes / 11250000，strict format baseline/HEAD
均 1315、新增 0。主工作树的聚焦 harness 并行运行曾失败于 Provider 夹具 suspension 等待，
104 checks、1 failure；构建完成后独占复跑为 103 checks、0 failures，失败 log 与复跑 log 均保留。
没有改动无关 helper 或 runtime 逻辑来消除该失败。

| Bundle 字段 | 当前值 |
|---|---|
| identifier / version / build | `com.claudio.app` / `0.0.0-dev` / `0.0.0-dev` |
| CPU / macOS / class | arm64 / macOS 26.6.2 (25G83) / `NON-DISTRIBUTION`、`SenseAudio-T8` |
| signing / Team / CDHash | ad-hoc / 未设置 / `ff0e11158baa2fa58a8000e67ba0c2cbf8e95482` |
| app SHA-256 | `92cab4baa950a0711007f5721db7fac9fb3b03b396c189635cff7631b5ad2b39` |
| helper SHA-256 | `1f2bd485c01cd902260c60d80b5bba805306d57cdd6fb5ae817465af42fcffd7` |
| LoginItem SHA-256 | `8895692c1d5accf357020e4df8332a45acb3014935b0351454ea930cc4fedea2` |
| archive SHA-256 | `648746f4ddfd5f333fdd5a0fd351b526a69c4c022963cf1e452e7dd09e05e053`；Git 外 |

完整身份固定时 worktree/index 干净，voice probe/TTS/SFX/GET 仍为 0。运行中固定 Bundle 的
真实取消键激活、冻结与恢复粘贴、输入法、VoiceOver、正式 smoke 尚未验证。凭据 metadata 未变，
不回读或修改明文。证据保存于 Git 外 `senseaudio-description-focus-ordered-20260915.p87lyy` 的
`run.md`、`candidate-gate.txt`、原生 focus gate log、主工作树失败/复跑 log 及 archive。
T8 仍未闭合；Issue #187 实时只读查询为 `OPEN`、`ready-for-human`。production 保持隐藏，
不启动 T9、不 push、不发布或修改 Issue。

固定 Bundle 已从该路径启动为 PID 88155，但原生绑定因尚无可读设置窗口超时。可用 surface 清单没有
候选窗口或运行中的菜单栏控制入口；只读检查确认未配置打开设置/当前声音作用域的全局快捷键，
已有 app 也明确移除合成设置键。没有发送未知快捷键或读取剪贴板。需所有者手动打开新候选的
「设置 → 事件与提示音」再继续实际键盘/冻结/取消复验；不用重新输入 Key，也不重索付费授权。

## 17. 剩余验收收尾与键盘取消候选

2026-09-15，项目所有者要求完成剩余项目并关闭 T8。执行方按第 1.4 节保留已完成的历史证据，
不重复官方资源发现、不重新录入 Key、不启用 T9、不 push。检查期间聚合分支新增了本地提交
`f3b951defa6fcc2e2ed74e4b838dcf8330d93a70`，tree
`73946d4b0c8bd7a478e87f153ec2c114b441cce6`；它包含生成描述保护和空格/回车取消处理。
运行中的旧候选不含后一修正，因此只把该 UI/回归差异同步到隔离分支并重新绑定。

| 字段 | 当前固定身份 |
|---|---|
| Candidate ID | `senseaudio-t8-20260915-e4b2b39-arm64` |
| candidate commit / tree | `e4b2b391d7f08b29e561828d19d7a5a5c2d0319c` / `b83cc6472b610239247807dc45e8f8ea028ba1b0` |
| 上一焦点候选→当前 diff | baseline `2317a9175339350c3675eebe1cac0899d327b37c`；两文件 +99/-17；binary diff SHA-256 `3385e84636e48288f599b44d816f6c43cd157b6e7b762996c81045de374773ae` |
| 上一正式候选→当前 diff | baseline `1ef3c5d1838eaa889d83a2a1c117436d73834361`；binary diff SHA-256 `f72b85566a099373afdff0ae34ff03c6054bb008a846c3f18749f1af9f93baa2` |
| 聚合 source→候选 diff | baseline `f3b951defa6fcc2e2ed74e4b838dcf8330d93a70`；10 文件 +152/-46，仅原 NON-DISTRIBUTION policy/activation、标记及相关测试/文档差异；binary diff SHA-256 `0519ff3f7ad46ec962619f64fe9e1006ca87dcdbf9db30ac3f41eededbff38e5` |
| policy SHA-256 | 第 1.2 节规范化字节不变：`6f570cf99d8fc8bfcf040c49ac4182afa1ab16d0baca74eb072a7f083e5d200d` |
| Bundle identifier / version / build | `com.claudio.app` / `0.0.0-dev` / `0.0.0-dev` |
| CPU / macOS / class | arm64 / macOS 26.6.2 (25G83) / `NON-DISTRIBUTION`、`SenseAudio-T8` |
| signing / Team / CDHash | ad-hoc / 未设置 / `4c0e7fc2cc195e58a2f58d1a2e94d056f068baea` |
| app executable SHA-256 | `cecf028aa5a5cbf90604053594931b14e7c3749a0176db7ae50008c4e839e32c` |
| helper / LoginItem executable SHA-256 | `1f2bd485c01cd902260c60d80b5bba805306d57cdd6fb5ae817465af42fcffd7` / `8895692c1d5accf357020e4df8332a45acb3014935b0351454ea930cc4fedea2` |
| archive SHA-256 | `c6ab7b50e3357857c43280933f809ee876b3a5dc8288f977ffc74cb7216c69f9`；Git 外 |

### 自动门禁与失败保留

初次完整设置脚本在未改动的 helper NVM shim 版本探测失败，3272 checks、1 failure；第一次
helper 复跑与 GUI harness 重叠，仍在同项失败。GUI 完成后的独立 helper 复跑为 3272 checks、
0 failures。根因未确认，未修改无关 helper；两次失败记录保留，不称初次脚本退出 0。

当前干净候选的 GUI harness 9480 checks 全通过。独占真实 key-window 的 opt-in 回归为
32 checks、0 failures：经实际 AppKit window event 派发验证空格/回车取消，普通或带修饰键输入
不误取消，取消保留原描述，真实 NSTextView 成为 first responder 且能继续输入。
这仍是 compiled native 回归，不替代运行中固定 app 的真实键盘、输入法或 VoiceOver 验收。

初次脚本未执行到的其余相同门禁单独补齐：presentation Debug/Release、ClaudioGUI
Debug/Release、dev-bundle（helper/LoginItem Release）、Bundle 签名、size、localization、
两种 diff check 与同一 baseline 的 strict-format 比较均退出 0。Bundle 正规文件总计
9253182 bytes / 11250000，format baseline/HEAD 均 1315、新增 0。完整命令与原始生成的自动
结果记录在 Git 外，不把分开采集伪称为初次脚本一次通过。

### 逐项继承边界

相对上一正式 180 秒候选，核心 source delta 仅为 `AICueGenerationViewModel` 的描述修改保护；
Provider、registry、请求编译、transport、asset fetch、音频校验、凭据、helper 与构建脚本均无
source delta。描述 view model、SwiftUI 视图、焦点和锁定说明的变化影响生成交互，须实测复验。

| 门禁 | 当前结论与来源 |
|---|---|
| 正式 3 TTS + 1 SFX、下载 policy 与音频技术检查 | `PASSED`；按第 1.4 节继承第 12 节正式候选的真实链路，不重新记调用次数，不代替最新交互 |
| animal 技术链 | `PASSED`；继承第 12 节独立 animal 轮次；听感不因 HTTP/播放状态升级 |
| 重启后保存凭据供生成使用 | `PASSED`；第 12 节实际重启生成事实与 unchanged 凭据实现；完整异常/删除 UI 不在此结论内 |
| 一次用户采用及持久化读回 | `PASSED`（窄项）；第 13 节人工采用、第 14 节新进程映射与正规文件读回；不覆盖失败保旧绑定或回滚 |
| 木琴三个候选听感 | `PASSED`（窄项）；第 14 节所有者明确反馈听到且符合意图；不覆盖中文 TTS/所有 animal 候选 |
| 生成中描述冻结 | `PASSED`（人工补充）；所有者明确回复“生成中不能修改描述，已经验证”；第 14 节实际冻结/取消清理证据保留 |
| 最新固定 app 取消键/完整焦点 | `NOT VERIFIED`；32 项 key-window 回归通过，固定 app 的键盘取消/恢复焦点尚未实测；不合并到描述冻结结果 |
| 中文 TTS 听感 | `PASSED`（人工补充确认）；所有者针对三个中文 TTS 是否逐个听过且无截断/多余描述的询问，明确回复“已逐个听过，全部符合预期”；是历史听感反馈，不虚构当前 Bundle 的新试听 |
| 当前 animal 三候选听感 | `FAILED`；所有者逐个试听反馈“三个都能听到，明显和描述意图不符”，模型能力只是所有者推测，根因未确定 |
| 实际输入法 / VoiceOver / 完整键盘 | `NOT VERIFIED`；不能以 AX 标签、synthetic event 或自动门禁代替 |
| 真实 partial 1/3、2/3 | `NOT VERIFIED`；已有 provider→engine fixtures 是准备证据；不反复付费赌供应商失败 |
| 完整凭据异常 UI、失败保旧绑定与回滚 | `NOT VERIFIED`；现有实际临时文件系统集成 tests 保留自动证据，不冒充当前 app 全流程 |

上述中文 TTS 补充反馈解除原“未听/等待反馈”的缺口，先前“未听”记录作为当时事实保留。
它不新增生成 POST，不要求重播相同听感验收，也不把其他人工项目一并标记通过。

固定 app 启动为 PID 42542，原生绑定初次因没有可读设置窗口超时，所有者随后打开设置。
执行方取得当前实际 AX 树时，所有者已自行发起 animal 生成；执行方没有取消或采用该轮结果。
初次树的描述控件不可写并带锁定 hint；在执行方开始键盘探测前生成已结束，因此没有虚构键盘/IME
探测通过。当前实际窗口发布候选 1/2/3，所有者按编号亲自试听并给出上述失败反馈。

该进程的脱敏 CFNetwork 记录包含两次 SFX POST 尝试，起点 `2026-09-15T07:57:08.115Z` 与
`2026-09-15T07:57:17.343Z`，均为 179.9 秒 route-owned 预算。前一尝试 7637 ms 后以
`NSURLErrorCancelled (-999)`、零响应字节结束，具体人工终止动作未记录，不声称键盘取消通过。
后一尝试 61698 ms / HTTP 200；3 次 GET 均 HTTP 200，392 / 252 / 1048 ms，剩余预算
118.2 / 117.8 / 117.5 秒。3 个正规 MP3 均 32929 bytes / 2.037500 秒 / 0600；固定 policy 与
音频技术门禁接受。这两轮不是执行方触发的付费调用；来源是所有者在当前窗口的自发操作。
POST 无自动 retry 的固定实现不变，未把两个独立尝试改写成“只调用一次”。当前新增 voice probe 0、
TTS POST 0、SFX POST 2、asset GET 3；未看到 GET retry。

只读比较发现三个临时 MP3 二进制内容均不同；解码到内存后也为三份不同 PCM，不是三行指向同一
音频的简单重复。未保存生成音频、PCM、hash、prompt、完整 URL 或响应。源码检查显示 planner
保留原声音描述，SFX `text` 只进行空白规范化；未发现本次改动改变 Provider 请求编译的 source delta。
这些检查不能单独证明“模型能力是根因”，也不能证明每个声音符合意图。听感失败后暂停追加付费测试。

凭据文件只核对 metadata，0700/0600、67 bytes、inode/mtime 与此前记录不变。
候选 source/index 干净，证据与 archive 保持在 Git 外
`senseaudio-final-native-20260915.bpWX5Z`。

#187 与其依赖的 #188、#190、#191 均只读核对；后三项为 CLOSED，#187 仍 OPEN。
当前 animal 听感门禁为 `FAILED`，原因待诊断；不把所有者的模型能力推测视为风险接受。
只有失败项解决且其余未完成门禁取得实际通过证据后，才关闭 T8；当前不关闭 Issue、不修改 production 或 T9。

## 18. 工程复跑与新增隔离串联验证

2026-09-15，项目所有者要求先补齐工程与隔离故障验证，并确认沿用既有生成、VM 和采用流程，
不新增生产接口。本轮没有发起真实 voice probe、TTS、SFX 或 asset GET，不操作真实凭据、Keychain、
已采用声音或当前三个未采用 animal 候选；不 commit/push，不修改 Issue、production 或 T9。

### 候选与测试补丁身份分开绑定

第 17 节固定候选 `senseaudio-t8-20260915-e4b2b39-arm64` 的 source/index 仍干净，commit/tree、
policy、Bundle 身份不变；再次核对 app executable SHA-256 为
`cecf028aa5a5cbf90604053594931b14e7c3749a0176db7ae50008c4e839e32c`。未重建或采用候选。
主工作树的无关 DESIGN 修改和两个 mockup 保留，不纳入测试补丁。

新增 tests-only overlay 位于聚合分支的未提交工作树：

| 字段 | 绑定值 |
|---|---|
| base commit / tree | `f3b951defa6fcc2e2ed74e4b838dcf8330d93a70` / `73946d4b0c8bd7a478e87f153ec2c114b441cce6` |
| 新 suite | `gui/Tests/ClaudioGUICoreTests/SenseAudioIsolationSuite.swift`；source SHA-256 `9c617d169128acd6fb370fcfc8d331fa73fdcb8a7e40255814904fb4563e052a` |
| harness 注册 | `gui/Tests/ClaudioGUICoreTests/main.swift`，+7/-0；source SHA-256 `c6a303938341f6fbd4641d761ca778146e14e8c85d7a1f7e93d0e7ae6461a8ba` |
| suite / registration binary patch SHA-256 | `05b4aef71c6dc7a83b888bfb4545f9922556adb20c18adbd5acc779a9d52873e` / `7586aeb68f92e6cfd244796a452be7f7cb5e8798698396162f366380ef657002` |
| UTF-8/LF test-overlay-identity.txt SHA-256 | `12fcf76e7f107864bb2d8d7903c5f5a647c611bd4873360913b2fa6ab9f75e0e`；是上述身份描述文件的 hash，不伪称为单份合并 diff digest |
| 新 GUI harness executable SHA-256 | `7017b1289745c1ab6e849c8aea3e7d3c0d61792b6eb560137e96ec41bff016a2` |

测试使用的 runtime/engine/dispatcher/VM/provider/asset/credential/file-vault/owner/importer/composer
production source 在 main `f3b951d` 与候选 `e4b2b39` 之间 diff 为空。默认 registry 的策略差异仍按
第 17 节绑定；本轮只通过既有 initializer 传入 exact policy，生产 policy 仍为 `nil`。
这些测试补丁和 executable **不是新正式候选或分发证据**。

### 实际串联范围与结果

`AICueRuntime` 装配真实 SenseAudio adapter、`AICueGenerationEngine`、dispatcher、credential manager、
URLSession transport/asset loader 与临时私有 file vault；结果经 `AICueGenerationViewModel` 发布。
采用路径为 VM 的既有 `adopt` → `SoundPacksEditorOwner.perform(.adoptAICue…)` → 真实 importer、
SoundPackLibrary 与临时独立用户声音包。此前提问中的 `AICueAdoptionService` 不是仓库已有类型，
没有为它新建生产 service。只受控网络响应、duration OS 边界、verification metadata 和既有
DEBUG finalize gate，不替代待测生产流程。

| 验证 | 本轮受控证据 |
|---|---|
| partial 1/3、2/3、zero | `PASSED`（隔离串联）；真实 URLSession→adapter→engine→VM，保留编号 [3]/[1,3]，文件与各自 GET 字节一致；zero typed 错误、保描述，丢弃/zero 整批清理；1/3 VM 能挂载生产 composer |
| 生成中拒写与主动取消 | `PASSED`（隔离串联）；真 POST 挂起后改描述无效，实际 body 保原描述/固定 model/variants 3、POST 1；主动取消 stopLoading、GET 0，释放迟到响应不复活 UI，取消后可编辑 |
| 401/503 与凭据异常 | `PASSED`（隔离串联）；401 仅拒绝验证状态，503 保 verified，假 Key 不删除；均 POST 1/GET 0、零 retry；缺失/0644 权限异常在网络前失败，保描述且不擅自修复权限/覆盖内容 |
| 成功采用与磁盘读回 | `PASSED`（隔离串联）；真生成候选→VM→owner→importer，读回 Event binding/audio_names/对应 GET 字节，保 unknown fields、Global 包与 Surface 配置，完成后清理临时候选 |
| 采用前漂移 | `PASSED`（隔离串联）；过期 permit 零写，旧 manifest/config 全字节保留，VM 保候选与描述，后续返回编辑清理 |
| 导入后取消/漂移 | `PASSED`（隔离串联）；文件已复制、绑定前注入，owner 返回 exact cancelled/targetChanged orphan，VM 显示 importedButNotBound；旧声音/旧绑定保留，只一个 recoverable orphan、一次 exact pack refresh，不伪造完全回滚 |
| 关闭隔离 registry gate | `PASSED`（隔离串联）；重建 runtime 后 SenseAudio engine 不存在、显式调用拒绝且网络 0；默认只读解析到 ElevenLabs，raw 偏好/假凭据/已采用字节与绑定保留 |

执行入口 `swift run --package-path gui claudio-gui-tests --senseaudio-isolation`：两次最终独立运行
均 exit 0、147 checks、0 failures；完整 GUI harness exit 0、9626 checks 全通过，新增 suite
已加入默认 harness。新 suite 与 main 的 strict-format、localization、tracked diff check 均退出 0；
untracked 新文件的 no-index diff check 无 whitespace 诊断（exit 1 表示有新增 diff，不误称 exit 0）。
主工作树 Debug build exit 0，helper 最终复跑 exit 0、3272 checks 全通过且未与 GUI harness 重叠；
候选 e4 的已完成结果见下一段。

### 原生失败保留，不以复跑绿覆盖

本轮在干净 e4 候选 worktree 复跑普通 GUI/helper：9480/3272 checks 全通过，Debug/Release build、
Bundle 签名、size、localization、diff 均通过。Bundle 总计 9253182 / 11250000 bytes。
这仍是 arm64、ad-hoc 本地检查，不证明 universal、签名、公证或正式分发。

相同 opt-in `--ai-cue-native-focus` 初次 exit 1、30 checks/2 failures：生成态 keyCode 36 的
Return 激活后未恢复编辑态，随后的真实 NSTextView first-responder 检查也失败；Space 分支未失败。
随后两次独立运行各为 exit 0、32/0，第三次在 Release 完成后执行。本轮没有改相关生产代码，
根因未定位。`diagnosing-bugs` / `investigate` 的证据优先规则要求保留第一次失败；一红两绿不能
升级为稳定 `PASSED`，也不能单凭该测试断言实际 app 必现。当前窄项为 `FAILED`、需最小化复现
和事件/焦点追踪；没有尝试生产修复。

### 不提升的验收边界

所有新网络 request 被 URLProtocol 接管，未知 origin 也返回受控失败，不能落到真实网络。
fixture 只使用公开假 Key、私有随机临时目录与独立 UserDefaults suite；43-byte ID3 加受控 duration
证明字节/接缝，不证明实际 MP3 解码、听感或描述意图。取消用例证明 URLSession stopped 后不再
delivery；既有 suspension fixtures 另证 provider late-success 丢弃，不能混称。
逐片测试装配/编译错误与负向 control 原样保存，不称为生产 bug 修复。

真实 partial 1/3、2/3，实际 app 完整异常/失败恢复/回滚，真实输入法与 VoiceOver 的第 17 节
`NOT VERIFIED` 状态不提升。动物意图失败原因未确定，模型风险尚未获明确接受。T8 仍 `FAILED`，
不关闭 #187，不启用 production 或 T9。

现有真实凭据只 stat：目录 0700、文件 0600、67 bytes、inode 250447032、mtime 1789405161 与
本轮前一致，未读内容。全部命令、原始结果与补丁身份保存在 Git 外私有目录
`senseaudio-engineering-isolation-20260915.Ep5ba6` 的 `run.md` 和相邻文件。

## 19. 原生取消回归定位与收尾重验

2026-09-15，项目所有者要求开始剩余收尾。第 18 节未定位的回车取消回归现已取得因果对照：
首次生成态挂载、app active 且窗口 key 时，原测试在 actor sleep 100 ms 后直接 `NSWindow.sendEvent`，
仍可能早于 SwiftUI 焦点变更的布局同步。失败轮次没有收到取消键处理，焦点同步在派发后才完成。
只增加等待后的 `NSHostingView.layoutSubtreeIfNeeded()`，十次独立生成态回车场景为 130/0；
同一代码去掉布局同步的负向对照再次失败 11/2；完整三场景十轮为 320/0。
根因归于原生测试宿主未完成布局/焦点同步，不把它称为已证明的实际 app 取消故障。

永久改动仅在 `AICueDescriptionSuite.swift`：保留既有等待、显式完成后续布局；有界检查 app active
与 key window，前提不满足即失败且不继续派发按键；增加 stress / return-only 诊断入口。
没有修改生产焦点、取消、Provider 或生成接口；所有临时追踪、AX 探针与队列投递实验已移除。
一个静态 AX 焦点探针 exit 139，其他探针编译/观察失败及 timestamp receipt 实验错误均保留原记录，
不算生产修复，也不以无障碍标签冒充 VoiceOver。

最终复验：

- `--ai-cue-native-focus --ai-cue-native-focus-stress` 独立运行 exit 0、320/0；
- 原始默认入口 `--ai-cue-native-focus` 在其他 build/harness 完成后独立运行 exit 0、32/0；
- 完整 GUI harness exit 0、9626 checks；helper exit 0、3272 checks；
- Debug build、三个测试文件 strict-format、localization、diff check 均 exit 0。

另一次清理后 stress 为 exit 1、308/1：恰有一轮 active/key 前提不满足，guard 未派发该轮取消键，
其余执行场景没有取消断言失败。这次失败保留；同时尝试过原生连接，但不能确认其造成失焦。
上述通过只绑定满足真实 key-window 前提的指定测试运行，不证明所有外部焦点环境或固定 app 人工体验。

测试补丁 base commit/tree 仍为第 18 节 `f3b951d…` / `73946d4…`，新 suite 和注册字节未变。
本次原生 suite SHA-256 为 `0bdd6aee5cc4ff0e281adf2d780309bcda27ccfd1ab9d975e13f683cbcbe9c40`；
该文件相对 base 的 binary diff SHA-256 为
`0784470bfcc4518eb3074c10077307a21ec221681d89c5ab8f830d1f98b75a4a`（+21/-3）；
最终 GUI harness executable SHA-256 为
`a842eaf33d385bc9dfb76274662b3174612a12fbfb33c4e190dd72bdb136e9f6`。
这是未提交 tests-only overlay，不是新正式候选。固定 e4 app 未重建、worktree 干净，exe digest
仍为 `cecf028aa5a5cbf90604053594931b14e7c3749a0176db7ae50008c4e839e32c`。

原生控制选择固定 app 两次分别返回 ScreenCaptureKit `-3811` 与 timeout；备用窗口查询取得
PID 42542 但 window count 0，点击菜单栏项后的窗口查询仍为 0。不能凭返回的 click action
记录设置已打开。已请求所有者手动打开设置；本轮实际固定 app 的键盘、IME、VoiceOver、partial
与异常恢复没有新增通过证据，第 17 节这些 `NOT VERIFIED` 保持。

动物意图匹配仍 `FAILED`；供应商模型能力只是推测，尚未取得明确风险接受。T8 未闭合，
不关闭 #187、不启动 T9、production policy 仍 `nil`。真实付费 POST/asset GET、Keychain 调用均 0；
只核对真实凭据 metadata，不读内容、不修改；不采用声音、不 commit/push，保留无关 DESIGN/mockup。
原始结果与诊断过程保存在 Git 外私有目录 `senseaudio-native-recovery-20260915.5c7DoA` 的 `run.md`。

## 20. 所有者手动打开设置后的原生控制检查

2026-09-15，所有者明确反馈“已打开”。只读检查确认固定 e4 app PID 42542 仍存活、
exe SHA-256 与第 19 节一致；System Events 返回 window count 1、标题 `claudi0 · 设置`。
相关控件投影为 SenseAudio 中国 API、已保存且已验证；未读取输入框或凭据内容。
该事实只补充当前设置窗口已打开，不证明生成、键盘、IME 或 VoiceOver。

原生工具随后返回 native pipe startup failed；重置工具会话（未关闭 app）后返回
`CUA_REPL_ENABLED_SURFACES is required`。备用方式曾取得事件/来源控件标识，但后续定位不稳定；
尝试定位 task_start 的描述生成入口返回 action not reachable，未派发生成动作。
因此暂停自动输入与点击，不猜坐标、不把工具失败视为 Claudio 交互故障或通过。
本轮没有生成 POST/asset GET、采用、凭据修改、commit/push、Issue 或 production 变更；
真实凭据 metadata 未变。完整原生、partial/异常恢复和动物意图匹配状态保持第 19 节结论。

## 21. 所有者补充生成冻结与键盘取消的人工通过

2026-09-15，所有者针对第 20 节之后提供的三项人工步骤反馈：“1，2已经人工验证，并全部通过”；
第 3 项尚不理解 VoiceOver，未反馈通过。该反馈沿用固定候选
`senseaudio-t8-20260915-e4b2b39-arm64`，记录为所有者人工确认，不冒充执行方的原生观察。

- 第 1 项 `PASSED`（窄项）：生成中中文输入法输入、粘贴、删除不能改变描述；Space 激活取消后
  恢复编辑，并保留原描述。
- 第 2 项 `PASSED`（窄项）：再次生成时 Return 激活取消，随后恢复编辑。
- 第 3 项 VoiceOver `NOT VERIFIED`：尚未确认候选编号、时长、名称、播放/停止及采用按钮的
  实际旁白语义与导航。不能由前两项的键盘通过推导。

本次反馈不证明完整焦点顺序、partial、异常恢复/回滚，也未增加真实 POST/GET 次数的计数证据。
第 19 节动物意图不匹配及其他未验收项保留；T8 未闭合，不关闭 #187、不启动 T9，production
仍隐藏。仅补充验收记录，不修改凭据、候选或生产实现，不 commit/push。

## 22. 所有者暂时豁免 VoiceOver 人工验收

2026-09-15，所有者在了解 macOS 旁白及对应检查内容后，明确回复：
“放弃VoiceOver验证，暂时不考虑这部分用户”。据此，本轮 SenseAudio 接入验收的 VoiceOver
人工检查改为 `RISK ACCEPTED`（所有者豁免、未验证），不再作为 T8 闭合的阻塞项。
ADR 0011 与执行合同同步此例外；之前的 `NOT RUN` / `NOT VERIFIED` 保留为当时事实。

豁免仅覆盖旁白的导航、编号/时长、播放/停止、partial 数量摘要、名称和采用动作语义。
它也适用于基于本轮验收范围的最终 Bundle 复验，不授权实施 T9。已有无障碍代码、标签与自动
回归不删除；不宣称这些操作已通过 VoiceOver 验证。其他 Provider 或未来扩大验收范围不自动继承。

普通键盘/完整焦点、可见 partial 1/3 与 2/3、凭据异常、失败保留旧绑定、采用与回滚不在豁免内。
当前 animal 意图不匹配的失败与原因未确定也保持原记录，不能用本次决定接受模型风险。
第 21 节人工通过保持；其余缺口未闭合，T8 仍未闭合、production 隐藏。
本次只修改验收合同和台账，不发起付费调用、不操作凭据或候选、不 commit/push、不修改 Issue。

## 23. 所有者最终确认与 T8 风险接受闭合

2026-09-15，项目所有者针对执行方列出的四组剩余项逐项回复：

1. 动物音效意图不符：“明确接受这项质量风险”；
2. 完整键盘焦点顺序：“已确认”；
3. partial 实际展示：“难以复现，接受风险，通过”；
4. 凭据异常、失败保旧绑定与安全回滚：“通过”。

第 1、3 项记为 `RISK ACCEPTED`：动物意图听感失败、根因未确定，partial 1/3、2/3 的实际
app 展示未验证，不追溯改写为 `PASSED`。不认定供应商模型是根因或本地代码已被排除；不承诺
生成结果总符合描述。第 2、4 项记为 `PASSED`（所有者人工确认），不是执行方新增的原生观察；
具体操作轨迹未新增，保留第 18–21 节工程及人工证据。VoiceOver 延续第 22 节豁免、未验证。

### 固定身份与既有证据收口

本轮只记录验收结论，没有重建或采用候选。只读复核隔离 worktree 的 source/index 干净，完整
commit/tree 和 app executable 摘要与第 17 节一致：

| 字段 | 绑定值 |
|---|---|
| Candidate ID | `senseaudio-t8-20260915-e4b2b39-arm64` |
| source commit / tree | `e4b2b391d7f08b29e561828d19d7a5a5c2d0319c` / `b83cc6472b610239247807dc45e8f8ea028ba1b0` |
| policy SHA-256 | `6f570cf99d8fc8bfcf040c49ac4182afa1ab16d0baca74eb072a7f083e5d200d`；第 1.2 节 exact policy 不变 |
| Bundle identity | `com.claudio.app` / `0.0.0-dev` / arm64 / ad-hoc / `NON-DISTRIBUTION`；其余身份见第 17 节 |
| app executable SHA-256 | `cecf028aa5a5cbf90604053594931b14e7c3749a0176db7ae50008c4e839e32c` |
| 验收人 / 日期 / 结论 | 项目所有者 / 2026-09-15 / `RISK ACCEPTED`（本轮 T8 验收闭合，不是全部实测通过） |

第 3–4 节早期表中的待填项按证据层级收口，不虚构重验：

- 已验证并保存的本地凭据沿用所有者既有确认及第 9、12 节重启生成记录；固定 voice 可用由第 12 节
  真实 TTS 链路和 unchanged route 证明。无新增 probe，既有 probe 的完整响应或尝试数未补造。
- profile 名称/已保存已验证状态沿用第 20 节原生只读记录；固定 voice、费用/数据及 `.cn` 非驻留
  承诺的披露使用 registry 和 `LocalizationSuite` 的既有工程证据，不声称执行方本轮重开披露 UI。
- `.mixed` 本地拒绝沿用第 12 节实际 UI 检查；非 `zh*` speech 的网络前拒绝使用固定 registry
  `zh*` allowlist、engine 先 compile 后取凭据的源码顺序和 `AICueProviderContractsSuite` 通用 locale
  拒绝回归的组合工程证据，不声称新增 SenseAudio 专属负向调用或原生操作。
- 正式 3 TTS + 1 SFX、下载、中文 TTS/木琴听感、重启取用、一次采用与持久化读回，按第 17 节
  已记录的 source-delta 边界继承；输入冻结/输入法/Space 与 Return 取消恢复沿用第 21 节。

### 闭合范围与后续边界

本轮 T8 按上述所有者明确风险接受口径闭合，已满足此前“完成剩余项目，close T8”的收尾条件。
第 9–22 节的失败、未验证和当时未闭合结论作为历史保留，当前以本节为准。三项风险接受仅适用
本轮 SenseAudio 及相关实现 unchanged 的最终 Bundle 复验；其他 Provider 不自动继承。资源
origin/MIME、匿名 GET/零 redirect、生成 POST 零重试、deadline、大小/时长、凭据与采用安全
边界均不放宽，既有 partial/无障碍实现和回归不删除。

T9 #189 仍需单独授权实施；production policy 保持 `nil`，默认 registry 四 profile，默认
Provider 仍为 ElevenLabs。T8 闭合不授权启用、push、release 或 distribution。本轮生成 POST、
asset GET 和凭据/Keychain 操作均为 0；只同步本台账、ADR 0011 和执行合同，保留无关 DESIGN、
mockup 与现有 tests-only overlay，不 commit/push。Issue 关闭结果在实际执行并读回后另记。

按所有者此前明确的关闭要求，执行 `gh issue close 187` 附上述 allowlist 范围内的验收摘要；
随后实时读回 #187 为 `CLOSED`，`closedAt=2026-09-15T10:16:26Z`。闭合评论见
[GitHub #187 验收记录](https://github.com/d0m999/Claudio/issues/187#issuecomment-5678487568)。
仅关闭 #187；未修改 #189、production、凭据、候选、Git 提交或远端分支。

## 24. 审查后 ACL 与资源失败分类修复

2026-09-15，项目所有者要求执行审查后的修复计划。实现基线为
`8fef4aa5e88397eb80da7844b55b4c3754bca3a3`；本节是修复后工程与重验记录，不重写第 9–23 节历史
候选或 T8 闭合，不实施 production activation。修复源码 commit/tree 与最终门禁绑定如下。

### 合同与实现

- ADR 0015 明确私有目录和文件没有扩展 ACL 条目，查询故障 fail closed；已有不安全目标不修权限。
  staging 在写入 Key 字节前检查，故障清理自有 staging、保留旧值；同用户进程读取的已接受风险不变。
- ADR 0011/0014 与执行合同明确：URL/origin、MIME、redirect、final URL 违约和 asset 401/403
  立即整批失败、停止后续 GET，不发布 partial、不损坏 API Key。普通不可用、限定重试耗尽和音频
  校验淘汰仍可 partial。未知基础设施错误不能默许 partial。失败使用脱敏 `invalidAudioResponse`
  或 `transportFailure`，不含完整 URL/query/Key；安全回滚仍是显式操作。
- 隔离 runtime 显式注入拒绝请求的 SSE transport；带假 Qwen Key 实际到达该接缝，不能用缺凭据
  掩盖遗漏。unary/asset 使用全 origin URLProtocol；另有真实 Provider/engine/VM 的迟到成功丢弃用例。
- 默认 Provider、production policy、180/60 秒预算、POST 零重试、GET 窄重试、采用与 orphan 所有权不变。

### 工程验证与受影响证据

专项红绿结果：目录 ACL 58 checks/6 failures → 58/0；文件 ACL 72/10 → 72/0；staging/query
87/5 → 87/0；Provider 合同分类 164/12 → 164/0。最终隔离串联 229/0，包含资源违约停止后续 GET、
清理、保 Key、显式重新生成，以及取消后的 transport 实际成功交付。全部使用假 Key、隔离临时目录；
本轮没有读取真实凭据/剪贴板、操作 Keychain 或发起真实 Provider 请求。系统级 IP 出站阻断保留，本地
UNIX socket 可用；SwiftPM 在外层沙箱内使用 `--disable-sandbox`，依赖只从缓存解析。

最终 GUI full harness 为 **9761 checks / 0 failures**；helper 首轮 **3272 / 1**，失败是未改动的
`HostIntegrationModelSuite.swift:68` NVM shim version 用例。同一已构建 harness、相同 IP 出站阻断
与 PATH 的串行复跑为 **3272 / 0**。首轮失败未复现、根因未确认，不掩盖失败记录或新增域外修复。
Debug / Release GUI build、六个改动 Swift 文件的 strict format lint、localization JSON 与 `git diff --check`
均通过；selector executable seam 与 candidates Python suite（11 tests）通过。本机为 macOS 26.6.2
arm64，不由这些结果推定旧系统原生行为。
inspection 构建不是新 SenseAudio 非分发验收候选，不继承旧 Bundle 摘要。duration stub 与假 MP3
仍只证明工程行为。

`code-review` 的 Standards / Spec 两轴只读复审未发现新增实质缺陷；Darwin 无 ACL 的已打开假 fd
raw probe 为 `fstat=0`、`acl_get_fd_np=nil/ENOENT`，实际 ACL 回归通过。未把 generic man page
未列出的这个平台特例当作仅凭文档完成的验证。

专项复核入口如下；外层阻断 IP 出站，依赖使用本地缓存，不调用真实凭据或 Provider：

```bash
sandbox-exec -p '(version 1)(allow default)(deny network-outbound (remote ip "*:*"))' swift run --disable-sandbox --skip-update --package-path gui claudio-gui-tests --ai-cue-local-credentials
sandbox-exec -p '(version 1)(allow default)(deny network-outbound (remote ip "*:*"))' swift run --disable-sandbox --skip-update --package-path gui claudio-gui-tests --senseaudio-provider
sandbox-exec -p '(version 1)(allow default)(deny network-outbound (remote ip "*:*"))' swift run --disable-sandbox --skip-update --package-path gui claudio-gui-tests --senseaudio-isolation
```

### 源码与 inspection Bundle 身份

full harness 在提交前执行；提交后复核 GUI/helper 源码没有偏差。`scripts/dev-bundle.sh` 从以下
完整源码 commit 构建，构建前后 source/index 干净；临时 Swift wrapper 只在外层 IP 阻断内追加
`--disable-sandbox` / `--skip-update`，不改仓库脚本。后续证据提交只改本台账，不把证据提交的
tree 冒充构建源码 tree，也不要求自引用 commit SHA。

| 字段 | 本轮工程绑定值 |
|---|---|
| 修复 source commit | `4e10a1d6a79dbd6f748bb34d37de98182d9c5566` |
| 修复 source tree | `8fb0a725d679f942972a18e18d7adcc3efd9ad88` |
| Bundle identity | `com.claudio.app` / `0.0.0-dev` / arm64 / ad-hoc；普通 inspection，不是 SenseAudio 验收候选 |
| 签名后 app executable SHA-256 | `6753354fd22298c5208b6f942e088bba283bdd85cef1570f930006f8bb5dabe8` |
| 签名后 helper SHA-256 | `c9aa849b3ecf814d5cbe771d61325e26a362f5a58118748ae82b9b3b04fdbe08` |
| 签名后 LoginItem SHA-256 | `1895380c84b9e9c550dcce0c52069322404f49ee91fd7a7fc3fe676074e43214` |
| Bundle gates | Release GUI/helper/LoginItem build、签名后 size/export gate、ad-hoc signature verify 均通过 |
| 签名后 size | GUI `5627904 B`；helper `2862896 B`；LoginItem `72192 B`；非可执行 `689983 B`；正规文件合计 `9252975 B`（预算 `11250000 B`） |
| production gate | 默认四 profiles、默认 ElevenLabs、policy `nil`；没有独立 activation patch 或 testing override |

本轮没有启动 Bundle 或验证原生布局/焦点/真实音频，不证明 x86_64、Developer ID 签名、公证、
分发或正式验收。Bundle 不入 Git；新验收候选仍须按 §1.3 另建并绑定自己的身份。

| 项目 | 修复后状态与要求 |
|---|---|
| 固定 policy | JSON 与 SHA-256 `6f570cf99d8fc8bfcf040c49ac4182afa1ab16d0baca74eb072a7f083e5d200d` 不变；实现变化仍重验 |
| 凭据链 | `NOT VERIFIED`：新候选上的保存、重启取用、权限异常保旧值及恢复需授权后人工验证 |
| SFX 生成/下载 | `NOT VERIFIED`：Provider 失败语义变化，按 §1.4 在新候选上执行受影响真实 smoke |
| 新验收候选身份 | `NOT RUN`：按 §1.3 从全部修复的干净开发 commit 创建独立 activation patch，重新绑定 Bundle |
| 既有 TTS/键盘/听感 | 历史结果保留；逐项证明影响边界后继承，新凭据链不由旧 smoke 自动覆盖 |
| 三项风险接受 | VoiceOver、partial 实际展示、动物意图质量保留原有限范围；不写 PASSED、不扩展安全豁免 |
| macOS 12–13 取消键 | `NOT VERIFIED`：本轮没有旧系统原生复现，不据此新增兼容性修复 |
| T9 | `NOT AUTHORIZED` / `NOT VERIFIED`：本地 Issue 更新草案见 `senseaudio-t9-issue-update-draft.md`，尚未发布 |

本轮工程修复、两轴复审与 inspection 身份绑定完成，production 仍关闭；受影响真实/原生验收、
新验收候选身份与 T9 授权继续独立。
