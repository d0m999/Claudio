import Foundation

/// `com.apple.quarantine` —— Gatekeeper 给「从网上来的东西」盖的章。
///
/// ## 为什么这个文件必须存在（2026-07-12 T17 实测，不是推理）
///
/// v1 的分发形态是**未签名、未公证**的 DMG（ENGINEERING.md Outside Voice T3）。用户下载后，
/// `Claudio.app` 连同**里面每一个文件**都会被打上 `com.apple.quarantine` —— 包括
/// `Contents/Resources/bin/claudio` 这个我们要复制出去的 helper。
///
/// 而 `FileManager.copyItem` **会把这个 xattr 一起复制过去**（实测，Darwin 25.5）：
///
///     source xattrs      : ["com.apple.provenance", "com.apple.quarantine"]
///     destination xattrs : ["com.apple.provenance", "com.apple.quarantine"]
///
/// 于是 `~/.claudio/bin/claudio` 是一个带隔离章的二进制。而 Claude Code 执行 hook 的方式是
/// `/bin/sh -c '<abs>/claudio play stop'`（`SettingsInstaller.claudioHookCommand` 的 doc
/// comment 与 T3 spike 双源确认）。实测同一个二进制、同一条命令：
///
///     带 quarantine  → exit=137（SIGKILL，零输出、零 stderr —— Gatekeeper 直接杀掉）
///     剥掉 quarantine → 正常运行，exit=0
///
/// **这条失败链结构上不可观察**：`play` 是 fire-and-forget（「工程落地细节 ④」），拿不到
/// afplay 的退出码，更拿不到一个压根没跑起来的自己的退出码；`detectOnboardingState` 只查
/// 「正规文件 + 非空 + 可执行」，一个被隔离的二进制这三条全过。所以面板会亮绿点、说「已经接好了」，
/// `doctor` 会说「✓ claudio 二进制在位」，而用户**永远听不到一声响**。
///
/// 这正是 T17 存在的理由那句话——「装完后是哑的，装了但听不到声音」——的另一个版本，而且是
/// **接完线之后才会出现**的：在 T17 之前，用户得自己在 Terminal 里跑 `claudio setup`，那时
/// Gatekeeper 的弹窗至少还看得见；CTA 把这一步搬进 GUI 之后，连那点信号也没有了。
///
/// **不能指望别人替我们剥**：Homebrew cask 的 postflight 是 `xattr -d`（**非递归**，只剥
/// `.app` 目录本身，不剥里面的 helper）；DMG 拖拽路径压根没有 postflight；用户在「系统设置 >
/// 隐私与安全性 > 仍要打开」里的批准是**针对那个 app bundle** 的，一个被复制到
/// `~/.claudio/bin/` 的、脱离了 bundle 的孤立二进制继承不到它。
///
/// 所以：**谁复制，谁负责剥。** 剥完还要回头验一次（见 ``performFirstRunSetup``）——
/// 「剥了」和「剥干净了」是两回事，而这个仓库已经因为「断言断错了对象」交过一次学费。

/// The xattr name itself — one literal, not three (`HookCommandMatching` 的单一真相源纪律)。
public let quarantineAttributeName = "com.apple.quarantine"

/// Whether `url` currently carries `com.apple.quarantine`.
///
/// `XATTR_NOFOLLOW`: ask about the path itself, never a symlink's target — the same
/// "never follow a link out of the tree we think we're in" stance `readRegularFileBounded`
/// (`SafeFileRead.swift`) takes with `O_NOFOLLOW`.
public func hasQuarantineAttribute(at url: URL) -> Bool {
    getxattr(url.path, quarantineAttributeName, nil, 0, 0, XATTR_NOFOLLOW) >= 0
}

/// Strips `com.apple.quarantine` from `url`, and — if `url` is a directory — from everything
/// beneath it.
///
/// A missing attribute (`ENOATTR`) is **success, not failure**: the overwhelmingly common case
/// is a locally-built app that was never quarantined at all, and treating "there was nothing to
/// remove" as an error would make every developer build fail setup. Likewise `ENOENT` — a path
/// that isn't there has no attribute to strip.
///
/// Deliberately returns nothing: the caller must not be tempted to trust this function's word
/// for it. The only trustworthy check is asking the filesystem again afterwards
/// (``hasQuarantineAttribute(at:)``) — which is exactly what ``performFirstRunSetup`` does,
/// because "I called remove and it didn't complain" is not the same claim as "the attribute is
/// gone", and this codebase has already shipped one bug whose entire nature was asserting the
/// wrong one of those two.
public func stripQuarantineAttribute(at url: URL) {
    removexattr(url.path, quarantineAttributeName, XATTR_NOFOLLOW)

    // No `.skipsHiddenFiles`: a dot-prefixed file inside a copied pack is still a file macOS
    // will refuse to open on our behalf, and "we cleaned everything except the ones you can't
    // see" is precisely the shape of cleanup that comes back later as a mystery.
    guard let enumerator = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: nil, options: [], errorHandler: nil)
    else { return }

    for case let child as URL in enumerator {
        removexattr(child.path, quarantineAttributeName, XATTR_NOFOLLOW)
    }
}
