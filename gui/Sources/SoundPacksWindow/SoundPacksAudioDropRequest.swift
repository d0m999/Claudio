import AppKit
import ClaudioGUICore

/// 将 Finder 拖放项解析为安全导入管线的纯值请求。文件内容、格式、大小和目标路径仍由
/// `importAudioFiles` 的既有审计边界验证；视图层不直接复制或绑定外部 URL。
@MainActor
func loadSoundPacksDropRequest(from provider: NSItemProvider) async -> AudioImportRequest? {
    let suggestedNameFallback = provider.suggestedName
    return await withCheckedContinuation { continuation in
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else {
                continuation.resume(returning: nil)
                return
            }
            continuation.resume(
                returning: AudioImportRequest(
                    sourceURL: url,
                    suggestedFileName: suggestedNameFallback ?? url.lastPathComponent))
        }
    }
}
