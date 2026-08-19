import Foundation

/// CLI 与 GUI 可共同验证的纯摘要函数；只消费 typed outcome，不读取磁盘。
public func legacyHooksOutcomeMessage(_ outcome: InstallOutcome) -> String {
    switch outcome {
    case .installed(let backup):
        let backupText: String
        switch backup {
        case .notNeeded:
            backupText = "原来没有 settings.json，因此无需创建备份"
        case .created(let path):
            backupText = "已创建一次性备份：\(path)"
        case .preservedExisting(let path):
            backupText = "已保留已有一次性备份：\(path)"
        }
        return "已连接 Claude Code legacy hooks（追加条目，未覆盖已有配置；\(backupText)）"
    case .alreadyInstalled:
        return "Claude Code legacy hooks 已存在，无需重复操作"
    case .modernConnectionPresent:
        return "Claude Code 已是现代连接；未追加 legacy hooks，请使用 `claudi0 integrations` 管理"
    }
}

public func setupSummaryLines(_ outcome: SetupOutcome) -> [String] {
    switch outcome {
    case .completed(
        let copiedBinary,
        let copiedPacks,
        let salvaged,
        let packSelection,
        let hooksOutcome
    ):
        var lines = ["✓ claudi0 首次安装自举完成"]
        lines.append(
            copiedBinary
                ? "  · runtime 已复制到 ~/.claudio/bin/claudio，并提供 ~/.claudio/bin/claudi0 命令"
                : "  · runtime 已在 ~/.claudio/bin/claudio，并已同步 ~/.claudio/bin/claudi0 命令")
        lines.append(
            copiedPacks.isEmpty
                ? "  · 没有发现需要复制的新内置声音包"
                : "  · 已复制内置声音包：\(copiedPacks.joined(separator: ", "))")
        for pack in salvaged {
            lines.append(
                "  ⚠ \(pack.packID) 读不出 manifest（多半是上次安装被中断留下的残骸，也可能是这个包的"
                    + " manifest 坏了）——已把它原样搬到 \(pack.movedTo)（一个文件都没删），"
                    + "并重新装了一份干净的")
        }
        switch packSelection {
        case .untouched:
            break
        case .selectedDefault(let packID):
            lines.append("  · 已默认选中声音包 \"\(packID)\"")
        case .repairedDeadSelection(let removed, let selected):
            lines.append(
                "  ⚠ 你之前选的声音包 \"\(removed)\" 已经不在了（或读不出来）——"
                    + "已替你选中 \"\(selected)\"，在面板的切包画廊里随时可以换")
        }
        lines.append("  · \(legacyHooksOutcomeMessage(hooksOutcome))")
        return lines
    }
}
