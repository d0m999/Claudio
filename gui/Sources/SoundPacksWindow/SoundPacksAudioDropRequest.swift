import AppKit

/// 将 Finder 拖放项解析为外部 source URL。内容、格式、大小和 target 仍由 owner 的
/// import permit 与既有审计边界验证；View 不持有或推导写入目标。
@MainActor
func loadSoundPacksDropURL(from provider: NSItemProvider) async -> URL? {
    return await withCheckedContinuation { continuation in
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            continuation.resume(returning: url)
        }
    }
}
