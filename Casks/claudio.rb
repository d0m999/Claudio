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
    system_command "/usr/bin/xattr",
                   args: ["-d", "com.apple.quarantine", "#{appdir}/Claudio.app"],
                   must_succeed: false
  end

  caveats do
    <<~EOS
      未签名 ad-hoc 构建（v1，无公证）。若被 Gatekeeper 拦截：
      系统设置 > 隐私与安全性 > 下滑找到被拦的 Claudio > 点"仍要打开"。

      首次打开后，Claudio 会自动把 hook 接入 Claude Code 的
      settings.json（追加、不覆盖，自动备份），全程无需手动编辑配置文件。
    EOS
  end
end
