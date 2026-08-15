# Reference template only. The optional release job writes the effective cask to
# d0m999/homebrew-tap/Casks/claudi0.rb after a signed and notarized GitHub Release succeeds.
# Version and SHA-256 placeholders below are replaced by validated workflow outputs.

cask "claudi0" do
  version "0.0.0-ci-injected"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/d0m999/Claudio/releases/download/v#{version}/claudi0-#{version}.dmg"
  name "claudi0"
  desc "Semantic sound cues for Claude Code and Codex"
  homepage "https://github.com/d0m999/Claudio"

  depends_on macos: ">= :monterey"

  app "claudi0.app"

  caveats <<~EOS
    Open claudi0 and connect Claude Code and Codex from the menu bar panel.
    Uninstalling the cask intentionally preserves ~/.claudio and host configuration;
    disconnect hosts first if you want to remove Claudio's hook entries.
  EOS
end
