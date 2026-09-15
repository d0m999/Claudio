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
| 本地实现聚合与自动门禁 | `PREPARED LOCAL` | 2026-09-15 修复 SFX 响应头误超时后，新聚合 base 与非分发候选已绑定并复验；完整结果见第 9 节 |
| production 暴露 | `CLOSED` | `productionSenseAudioAssetPolicy == nil`；`senseaudio-cn` 不在默认 allowlist |
| 实测资源合同决策 | `RISK ACCEPTED` | exact origin/MIME/匿名 GET/零 redirect 已固定；URL 有效期与 host 轮换未知作为可用性风险接受 |
| 首次正式付费 smoke | `NOT AUTHORIZED` | 被取代候选完成 3 次 TTS，但唯一一次 SFX 在响应头前被客户端 10 秒计时器误取消；修复后的新候选需新授权重跑，见第 9 节 |
| 非分发候选原生启动 | `NOT RUN` | 被取代候选最终可启动；修复后的新 Bundle 尚未启动，旧启动证据不跨候选继承 |
| 原生听感、键盘、VoiceOver | `NOT RUN` | fixture、SwiftUI harness 或 build 不能替代 |
| production activation | `NOT VERIFIED` | 严格依赖 T8 其余层全部通过；由 #189 单独实施，本 ticket 不修改 policy/allowlist |
| Release / distribution | `NOT RUN` | 没有签名 universal RC、notarization、双架构或正式批准 |

## 不可跳过的门禁顺序

```text
本地准备
  → 项目所有者接受的实测资源合同与精确 policy
  → 单独授权的付费 TTS/SFX smoke
  → 绑定同一非分发候选的听感、键盘与 VoiceOver
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

真实 Provider 与原生验收需要一个显式标记为 `NON-DISTRIBUTION` 的隔离候选。它从 1.1 的聚合 commit
建立，只允许加入 ADR 0014 固定的精确 asset policy 与让该固定 profile 可达所必需的 activation patch；
该 patch 必须形成独立本地 commit，不能夹带其他功能或证据文件。可分发分支中的
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

每个候选必须记录以下身份；任一项待填都不能开始付费或原生验收：

| 字段 | 值 |
|---|---|
| Candidate ID | `senseaudio-t8-20260915-62faf8ae-arm64` |
| 聚合 base commit / tree | `187c3f9b1153ec30d290e87ddb1184595781f2b3` / `179d733db88c1e78e9d6ff8dd7cc32abe9c58f5a` |
| 候选 commit / tree | `62faf8ae7d3ce6202a2310272e40a85bf27b612e` / `e2f0d8fc8ce868ac345c5d2c47400c1b7cdf9d8d` |
| base→candidate 精确 diff | 仅 policy/activation、相应 registry 测试与非分发标记；8 文件，+63/-26；diff SHA-256 `b692a106ce5ddc786907fc46ae5e0f89bf485cc73ba7fb99de61d3c9e28e97cb` |
| Policy 规范化 JSON / SHA-256 | 第 1.2 节固定 JSON；`6f570cf99d8fc8bfcf040c49ac4182afa1ab16d0baca74eb072a7f083e5d200d` |
| `CFBundleIdentifier` | `com.claudio.app` |
| `CFBundleShortVersionString` / `CFBundleVersion` | `0.0.0-dev` / `0.0.0-dev` |
| CPU / macOS | arm64 / macOS 26.6.2 (25G83) |
| signing identity / Team ID / CDHash | ad-hoc / 未设置 / `3beda6becb079914b63b00133952044a493e0b3e` |
| 主 app executable SHA-256 | `44cde0c6e90c8eabdc6b96baa68b33a59812aea7b45e3f699bcb48aa85e887f3` |
| helper / LoginItem executable SHA-256 | `d36e4f751cdd006215878efb3a325407728bc9ca7458b8060e5a127c0f36affe` / `0e9e4167b9ea4d881f96523bd7b6d227b4f0b6f5b6c87f1d5fab9357f9dde1c6` |
| 非分发 archive SHA-256 | `fcfedb576c99db39ebd1119f78a08ed4a54ba0d96cbf61eb9160e3e547baf30d`；archive 保持在 Git 外 |
| 自动门禁结果引用 | 第 9 节；同一干净候选的完整设置集成门禁退出 0 |

不得用 `dist/` 路径、分支名、窗口截图或“刚刚构建”替代这些身份字段。

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

正式验证状态仍为 `NOT RUN`。同一绑定候选的真实 smoke 必须证明所有实际 URL 在首个 GET 前通过整批
preflight，且每个 GET 的 origin、MIME、认证、redirect、final URL 与音频校验均符合上表。任一项失败，
T8 写 `FAILED` 并保持 production 隐藏；若 activation 后观察到漂移，本次生成 fail closed，并按第 7 节
回滚，而不是运行时学习新 host。此前不绑定正式候选的资源发现只能作为该决策的输入，不能代替本层。

## 3. 首次付费 smoke

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
任何失败后的第二轮生成、扩大预算或更换账户，都需要新的明确授权。asset GET 只能按既有合同执行同一
URL 最多一次限定瞬态 retry。

执行结果按路线独立记录：

| 检查 | 状态 | 脱敏证据引用 |
|---|---|---|
| required voice probe 可见 `female_0033_b` | `NOT RUN` | 待填 |
| TTS 三次 POST、零 retry | `NOT RUN` | 待填 |
| TTS 三个 MP3 均通过 5 MiB / 3 秒本地检查 | `NOT RUN` | 待填 |
| SFX 单次 batch POST、零 retry | `NOT RUN` | 待填 |
| SFX 所有实际 URL 在首个 GET 前通过 exact policy preflight | `NOT RUN` | 待填 |
| GET 无 credential、无 redirect、MIME 与 MP3 magic 匹配 | `NOT RUN` | 待填 |
| complete/partial 与实际可播放候选数一致 | `NOT RUN` | 待填 |
| `.mixed` / 非 `zh*` speech 在读 Key 与联网前失败 | `NOT RUN` | 待填（本地自动证据） |

真实 smoke 失败时保留失败状态与脱敏原因，不自动增加预算，不把 TTS 成功写成整个 profile 成功。

## 4. 原生与听感验收

本层必须在 1.3 绑定的同一 app 字节、同一 policy 和同一 macOS/CPU 上完成。DEBUG gallery、fixture、
compiled SwiftUI tests 与源代码检查只能作准备证据。

| 流程 | 状态 | 必须观察 |
|---|---|---|
| profile 与披露 | `NOT RUN` | SenseAudio 名称、固定 voice 资格、`.cn` 非驻留承诺、费用/数据边界 |
| credential | `NOT RUN` | 保存只读 probe；invalid key 与 voice missing 分开；失败保留旧 active key |
| 本地凭据持久化 | `NOT RUN` | 保存后重启可读取并供生成使用；目录/文件为 0700/0600；SenseAudio 的旧 Keychain 项无访问或迁移；文件不进入导出 |
| 中文 speech | `NOT RUN` | 恰好 3 个“候选 1/2/3”，均可播放、不截断、不朗读 style 描述 |
| animal / soundEffect | `NOT RUN` | 各一次真实 SFX；候选与描述匹配 |
| SFX partial | `NOT RUN` | 1/3 与 2/3 的可见 banner、候选顺序、VoiceOver 数量摘要 |
| unsupported | `NOT RUN` | `.mixed` 与非中文 speech 在读 Key/联网前明确失败并保留描述 |
| 键盘 | `NOT RUN` | profile、生成、候选、播放/停止、改名、采用、错误恢复的完整焦点顺序 |
| VoiceOver | `NOT RUN` | 编号、时长、播放/停止、partial、名称与采用动作语义稳定 |
| 采用与回滚 | `NOT RUN` | 采用走 `AudioImport`/bind；失败保留旧绑定；未采用候选清理 |

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

只有第 1–4 层全部 `PASSED`，#189 才可在单独分支中：

1. 把 ADR 0014 固定且经正式 smoke 匹配的精确 policy 固化为非 `nil`；
2. 将完整 `senseaudio-cn` 加入默认 allowlist，同时保持默认 Provider 为 `elevenlabs-global`；
3. 不增加任意 endpoint/model/voice/region/origin，也不加入 TTS-only 或 fallback；
4. 运行全部自动门禁，构造新的最终 Bundle，并完成最低限度的 profile、credential、speech、SFX、
   partial、键盘、VoiceOver 与采用复验；
5. 记录最终 commit/tree、policy digest 和 Bundle identity，并与非分发候选逐项比较。

若最终 commit 与候选 commit 不同，必须记录相关路径的精确 diff。若 provider、registry、runtime、
transport、asset fetch、generation、credential、UI、localization、音频验证或构建脚本有任何实质变化，
受影响的付费、原生与 Bundle 证据必须重验；不能用“只是合并 commit”自行豁免。只有相关 source tree、
policy digest 与实际 Bundle 字节都完成绑定后，状态才可写 `ACTIVATED`。

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

新候选 voice probe = **0**、TTS POST = **0**、SFX POST = **0**、asset GET = **0**，尚未启动。
第一次授权的 3 TTS + 1 SFX 预算已经用尽；新候选必须取得新授权后重跑 3 TTS + 1 SFX、资源下载、
播放与同候选人工验收。听感、键盘、VoiceOver、partial、采用与回滚仍未完成。

结论：根因已修复且新候选自动门禁通过，但新候选真实 smoke 与人工门禁尚未执行，T8 **未闭合**。
未 push、未修改 Issue、未启用 production；T9 仍保持阻塞。
