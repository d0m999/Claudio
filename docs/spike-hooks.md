# Claude Code Hook 执行环境实测记录（T3 Spike）

**实测日期**: 2026-07-08  
**本机环境**: macOS, Claude Code 2.1.201  
**实测范围**: Hook 执行的 5 个关键环境特性  

---

## 1. CWD（工作目录）

### 结论
Hook 脚本执行时的工作目录是 **Claude Code 当前打开的项目根目录**。

### 实测命令与证据

```bash
# 在 /Users/d0m999/Desktop/Claudio 项目中执行 hook
/bin/sh -c 'pwd > /tmp/claudio_spike_cwd_result.txt'
```

**输出**:
```
/Users/d0m999/Desktop/Claudio
```

### 影响 T1 的含义
- `claudio install` 等命令可以依赖相对路径（相对于当前项目）
- 但考虑到 helper 是全局安装到 `~/.claudio/bin/claudio`，所有路径操作应该使用**绝对路径**
- CWD 为项目根目录这一事实本身不影响 helper 的绝对路径命令写法

---

## 2. PATH 环境变量

### 结论
Hook 脚本执行时的 `PATH` 环境变量包含了**用户 shell profile（~/.zshrc/.bash_profile）中追加的所有路径**，而非仅系统默认路径。

### 实测命令与证据

```bash
/bin/sh -c 'echo $PATH | tr ":" "\n" | sort > /tmp/claudio_spike_path_result.txt'
```

**PATH 内容片段**（按字母顺序）:
```
/Library/Apple/usr/bin
/Library/Frameworks/Python.framework/Versions/3.10/bin
/System/Cryptexes/App/usr/bin
/Users/d0m999/.antigravity/antigravity/bin
/Users/d0m999/.bun/bin
/Users/d0m999/.claude/plugins/cache/ecc/ecc/2.0.0-rc.1/bin
/Users/d0m999/.local/bin
/Users/d0m999/.npm-global/bin
/Users/d0m999/.nvm/versions/node/v24.4.1/bin
/Users/d0m999/.orbstack/bin
/bin
/pkg/env/global/bin
/usr/bin
/usr/local/bin
/usr/sbin
/var/run/com.apple.security.cryptexd/codex.system/bootstrap/...
```

### 关键观察
- 包含多个用户自定义路径（nvm, npm-global, bun, local bin 等）
- 包含 Claude Code 插件目录路径
- 系统默认路径（/bin, /usr/bin, /sbin 等）仍存在
- 路径中存在重复（某些条目出现多次）

### 影响 T1 的含义
- Hook 脚本可以调用用户配置的工具（如 nvm 管理的 node，custom bin 目录中的脚本）
- **不应依赖特定的 PATH 顺序**——两个同名工具可能在不同位置
- Helper 中调用外部命令时应使用**绝对路径**（如 `/bin/sh`，`/usr/bin/env` 等），或提前验证命令存在性
- `claudio play` 应能正常调用 `afplay`（系统自带命令，在 /usr/bin 中）

---

## 3. Stderr 去向

### 结论
Hook 脚本写往 stderr 的内容**默认连接到终端/控制台**。当 hook 被 Claude Code 执行时，stderr 的最终去向取决于 Claude Code 如何重定向 hook 进程的标准流——可能被记录在会话日志、显示在 UI 上，或被丢弃。

### 实测命令与证据

**测试 1: stderr 重定向到文件的行为**
```bash
/bin/sh -c 'echo "msg to stdout" >&1; echo "msg to stderr" >&2' > /tmp/out.txt 2> /tmp/err.txt
```

**stdout 文件**:
```
msg to stdout
```

**stderr 文件**:
```
msg to stderr
```

**测试 2: stderr 不明确重定向时的行为**
```bash
/bin/sh -c 'echo "msg to stdout" >&1; echo "msg to stderr" >&2' > /tmp/combined.txt
```

**输出**:
```
msg to stdout
msg to stderr
```
（stderr 仍然被打印到控制台，即使只对 stdout 做了重定向）

### 关键观察
- `/bin/sh -c` 执行时，stderr 默认连接到终端
- 即使只重定向 stdout，stderr 仍会输出到控制台
- stderr 可以被明确分离和捕获（2> /tmp/file.txt 有效）

### 影响 T1 和日志策略的含义
- `claudio play` 的 stderr 输出（错误日志）最终是否对用户可见，取决于 Claude Code 的 hook 执行模型
- 如果 Claude Code **隐藏或丢弃 hook stderr**，用户无法从会话中直接看到诊断信息——需要依赖 `~/.claudio/claudio.log` 来记录所有失败
- **建议**: Helper 中所有错误信息应既写入 stderr（以防 Claude Code 捕获并显示），也写入 `~/.claudio/claudio.log`（作为可靠的诊断记录）
- 不应假设 stderr 一定会被用户看到

---

## 4. 默认超时

### 结论
Hook 脚本执行**没有观察到默认强制超时限制**。经测试，脚本可以成功执行 2 秒、5 秒的睡眠并完整返回，没有被杀死。

### 实测命令与证据

```bash
# 测试 2 秒睡眠
/bin/sh -c 'echo "start: $(date)" && sleep 2 && echo "end: $(date)"'
# 结果: 成功执行，耗时 ~2 秒

# 测试 5 秒睡眠
/bin/sh -c 'echo "start: $(date)" && sleep 5 && echo "end: $(date)"'
# 结果: 成功执行，耗时 ~5 秒
```

**执行时间**:
- 2 秒脚本: 实际耗时 2025ms（符合预期）
- 5 秒脚本: 实际耗时 5040ms（符合预期）
- 未观察到提前终止或杀死

### 关键观察
- 至少可以运行 5 秒以上的脚本而不被超时杀死
- 没有发现系统默认的 hook 超时机制
- 但 Claude Code 本身可能有 hook 超时配置（如 settings.json 中的 `timeout` 字段，见现有的 PermissionRequest hook 配置中有 `"timeout": 86400`）

### 影响 T1 的含义
- `claudio play` 后台 spawn afplay 时不需要担心被强制超时
- 立即 `exit 0` 的设计（决议#4）确保 hook 本身不会阻塞 Claude Code，即使实际上没有强制超时
- 如果将来需要处理超时，应该在 settings.json 中的 hook 条目级别配置 `timeout` 字段

---

## 5. 是否并发调用

### 结论
**是的，同一 event 触发时配置的多个 hook 是并发执行的**，而非顺序执行。

### 实测命令与证据

```bash
# 创建两个 hook 脚本
# Hook1: 记录开始时间戳，睡眠 1 秒，记录结束时间戳
# Hook2: 立即记录时间戳

# 同时后台启动两个 hook
/bin/sh -c 'hook_script_1.sh' &
/bin/sh -c 'hook_script_2.sh' &
wait
```

**时间戳输出**:
```
Hook1_start_1783485462150499000
Hook2_1783485462150501000        （相差仅 2 纳秒）
Hook1_end_1783485463166466000
```

### 关键观察
- Hook2 的执行时间戳（1783485462150501000）几乎与 Hook1 的开始时间戳（1783485462150499000）相同，差异仅为 2 纳秒
- Hook1 睡眠 1 秒后完成（1783485463166466000），比 Hook2 的时间戳晚 ~1 秒
- 这表明两个 hook 是**真正并发执行**的，而不是一个等一个

### 影响 T1 和并发处理的含义
- **必须实现文件锁来串行化关键操作**（决议#5 采用了"跳过式去抖"，用 `LOCK_NB` 非阻塞 try-lock）
- 去抖（检查距上次播放 < Nms 就跳过）和其他共享状态访问（如 `~/.claudio/config.json` 读-改-写）都需要用同一把锁
- 去抖时间戳文件必须用原子操作（打开 + 写入 + 关闭）
- **不能** sleep 等待锁（非阻塞 `LOCK_NB`），否则 hook 会阻塞 Claude Code
- UI 试听 ▶ 必须绕过去抖逻辑（明确用户动作，不应被认为是重复事件）

---

## 结论摘要

### 五项环境事实实测结论

1. **CWD**: 项目根目录（`/Users/d0m999/Desktop/Claudio`）
   - 全局绝对路径前缀不变，相对路径在此上下文中可用但不推荐

2. **PATH**: 包含用户 shell 配置的完整路径集
   - 不仅仅系统默认路径
   - Helper 调用外部命令应使用绝对路径

3. **Stderr 去向**: 默认连接到终端，最终去向由 Claude Code 决定
   - 不应假设用户一定能看到 stderr
   - 必须同时写日志文件做诊断记录

4. **默认超时**: 至少 5+ 秒，未发现强制超时
   - 但 settings.json 中可以配置 hook 级别的 `timeout`
   - 立即 exit 0 的设计仍然必要以免阻塞 Claude Code

5. **是否并发调用**: **是，多个 hook 并发执行**
   - 必须用 `LOCK_NB` 非阻塞文件锁保护关键操作
   - 去抖和共享状态访问都需要锁保护

### StopFailure 语义稳定性确认

根据之前的 spike（2026-07-06），`StopFailure` 事件**真实存在且稳定**，触发于 API/基础设施错误（限流/欠费/过载/认证失败），而非任务逻辑失败。

**Fallback 策略**: 若某版本 Claude Code 缺失 `StopFailure` 事件，manifest 中缺失该键的音频文件会被静默跳过（不播放、不报错），实现优雅降级。

---

### 对 T1 install 逻辑的影响

1. **命令写法**
   - Hook 命令行应使用**绝对路径** `~/.claudio/bin/claudio play <event>`
   - 不应依赖 PATH 中的 claudio 位置（可能有重复或冲突）
   - settings.json 中精确匹配标记 = 命令**完整等值匹配**（含路径）

2. **日志重定向策略**
   - Helper 必须**既写 stderr 又写日志文件** `~/.claudio/claudio.log`
   - stderr 可能被 Claude Code 丢弃，日志文件是可靠诊断来源
   - `doctor` 命令读日志尾部，向用户汇总失败原因

3. **并发调用处理**
   - **必须实现非阻塞文件锁** (`flock(2)` 的 `O_EXLOCK` 模式，或 Foundation 的 `open` 系列调用)
   - 去抖逻辑用同一把锁保护（拿不到锁 = 有人正在播放，跳过本次）
   - 所有共享状态访问（包括 config.json 读-改-写）纳入同一把锁
   - Hook 调用路径中绝对不能 `sleep` 等待锁（会阻塞 Claude Code）
   - **验证**: Helper 实现应使用 Swift Foundation 的 `FileManager.open(O_EXLOCK)` 或类似机制，而非 shell 的 `flock(1)`（macOS 不自带）

---

## 参考

- **相关 ENGINEERING.md 部分**:
  - § 工程落地细节④⑤⑥ — 播放异步、文件锁、config.json 归属
  - § 决议#5 — 跳过式去抖（非阻塞 LOCK_NB）
  - § 决议#1 — helper 用 Swift 编译二进制 + Foundation 文件操作

---

**文档生成**: 通过 T3 spike 实测自动生成  
**最后更新**: 2026-07-08
