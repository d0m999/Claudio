# Casks/claudio.rb — 参考模板，非本仓库直接生效的 Homebrew tap。
#
# Homebrew cask 必须活在一个名为 `homebrew-<tap>` 的独立仓库里（`brew install --cask
# <owner>/tap/claudio` 才认得到它）。本文件只是留仓库内供人审阅的"最后一次生成结果"预览，
# 不是安装源 —— 真正会被 `brew install` 用到的副本活在 <owner>/homebrew-tap 仓库的
# Casks/claudio.rb（该仓库需自行创建，见 .github/workflows/release.yml 的 update-cask job 注释）。
#
# 版本号 / 下载 URL 的 sha256 一律由 .github/workflows/release.yml 的 update-cask job 在
# push tag 触发的 CI 里注入（从 build job 的 outputs.version / outputs.sha256 读取），
# 不手改本文件的这两处 —— 手改也会在下一次 release 被 CI 覆盖。
#
# 下面这份内容形状与 CI 实际生成的完全一致，只是把变量换成了占位符，便于人工审阅 DSL 结构。

cask "claudio" do
  version "0.0.0-ci-injected" # 占位符 — CI 注入真实版本号，例如 "1.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000" # 占位符 — CI 注入该版本 DMG 的真实 sha256

  url "https://github.com/d0m999/Claudio/releases/download/v#{version}/Claudio-#{version}.dmg"
  name "Claudio"
  desc "Claude Code 语义化提示音 · 策展声音包"
  homepage "https://github.com/d0m999/Claudio"

  depends_on macos: ">= :monterey"

  app "Claudio.app"

  postflight do
    # `-dr`，不是 `-d`（T17）：非递归的 `-d` 只剥 .app 目录**自己**那一层，
    # `Contents/Resources/bin/claudio` 上的 com.apple.quarantine 原样留着。而那个 helper 会被
    # 复制成 ~/.claudio/bin/claudio，然后由 Claude Code 的 hook 经 /bin/sh -c 执行 —— 带着章的话
    # Gatekeeper 会直接 SIGKILL 它（实测 exit=137，零 stderr，`play` 又是 fire-and-forget，
    # 于是整条失败链一行日志都不留）。
    #
    # 真正 load-bearing 的那道闸在 `Setup.swift`（复制完自己剥、剥完回头验），因为 DMG 拖拽路径
    # 根本没有 postflight。这一行是第二道：让 bundle 从一开始就是干净的。
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Claudio.app"],
                   must_succeed: false
  end

  caveats do
    <<~EOS
      未签名 ad-hoc 构建（v1，无公证）。若被 Gatekeeper 拦截：
      系统设置 > 隐私与安全性 > 下滑找到被拦的 Claudio > 点"仍要打开"。

      打开 Claudio，点菜单栏面板里的「接管 Claude Code」即可 —— 它会装好放声音的小助手、
      复制内置声音包、并追加（不覆盖、自动备份）Claude Code 的 hook 配置。
      也可以在 Terminal 里跑 #{appdir}/Claudio.app/Contents/Resources/bin/claudio setup，
      两者做的是同一件事（详见 docs/distribution.md）。
    EOS
  end
end
