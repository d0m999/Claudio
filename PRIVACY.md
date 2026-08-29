# claudi0 Privacy Statement / 隐私说明

## English

claudi0's local helper and host-hook runtime have no telemetry, analytics, or cloud-upload path.
Sound packs, configuration, activation receipts, and the small rolling diagnostic log stay on this
Mac. Receipts contain a generated installation identifier, host/event identifiers, a timestamp, and
a redacted playback result. They do not contain prompts, responses, project paths, session content,
or absolute audio paths.

AI sound generation is an optional, explicit action in the claudi0 GUI. When you choose Generate,
your sound description and generation instructions are sent directly from this Mac to the selected
allowlisted provider profile. The current registry is:

- Profile `elevenlabs-global`: provider `ElevenLabs`; region `global`.
- Profile `minimax-global`: provider `MiniMax`; region `global`.
- Profile `qwen-singapore`: provider `Qwen / DashScope`; region `singapore`.
- Profile `qwen-beijing`: provider `Qwen / DashScope`; region `beijing`.

A provider may charge your account. Credential storage, retention, and model-improvement use follow
the per-profile disclosure shown before saving the credential and that provider account's settings
and terms; one provider's terms are not applied to another. Credentials are stored in the macOS
Keychain and are not included in copied diagnostics.

The About page's safe diagnostic summary contains only app version/build, architecture, macOS
versions, published Surface semantic states, and whether fixed app resources exist. It excludes path
values, receipt contents, credentials, sound descriptions, provider responses, calendar or Focus
data, personal sound-pack names, configuration contents, and log text.

## 简体中文

claudi0 的本地 helper 与宿主 hook runtime 没有遥测、分析或云端上传路径。声音包、配置、激活回执
和小型滚动诊断日志都保留在这台 Mac 上。回执只包含随机生成的安装标识、宿主/事件标识、时间戳和
脱敏后的播放结果，不包含提示词、回复、项目路径、会话内容或音频绝对路径。

AI 声音生成是 claudi0 GUI 中可选且必须由用户明确触发的动作。选择“生成”时，声音描述和生成指令
会由这台 Mac 直接发送给所选 allowlisted Provider profile。当前 registry 为：

- 配置 `elevenlabs-global`：Provider `ElevenLabs`；region `global`。
- 配置 `minimax-global`：Provider `MiniMax`；region `global`。
- 配置 `qwen-singapore`：Provider `Qwen / DashScope`；region `singapore`。
- 配置 `qwen-beijing`：Provider `Qwen / DashScope`；region `beijing`。

供应商可能向你的账户收费。凭据存储、数据留存及是否用于模型改进，以保存凭据前显示的逐 profile
披露、对应供应商账户设置和条款为准，不会把一个供应商的条款套用于另一个供应商。凭据保存在
macOS 钥匙串中，不会进入可复制的诊断摘要。

“关于”页的安全诊断只包含应用版本/构建、架构、macOS 版本、已发布 Surface 的语义状态，以及
固定应用资源是否存在。它排除路径值、回执内容、凭据、声音描述、供应商响应、日历或专注模式数据、
个人声音包名、配置内容和日志原文。
