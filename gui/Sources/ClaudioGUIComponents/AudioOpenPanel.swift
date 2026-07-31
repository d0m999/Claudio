import AppKit
import UniformTypeIdentifiers

/// Shared picker allow-list. This narrows the chooser UX; the hardened Core import pipeline still
/// validates magic bytes, size, duration, path containment and publication independently.
private let audioOpenPanelContentTypes: [UTType] = [.wav, .mp3, .aiff, .mpeg4Audio]

/// The one native audio-file picker used by the panel and the standard Sound Packs window.
@MainActor
public func runAudioOpenPanel(allowsMultipleSelection: Bool) -> [URL] {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = audioOpenPanelContentTypes
    panel.allowsMultipleSelection = allowsMultipleSelection
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    guard panel.runModal() == .OK else { return [] }
    return panel.urls
}
