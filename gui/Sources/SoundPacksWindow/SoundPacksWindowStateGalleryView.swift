#if DEBUG
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// Production-shape gallery for the full mapping editor, including all library availability
/// states. All data is injected; no preview frame reads or writes user paths.
@MainActor
public struct SoundPacksWindowStateGalleryView: View {
    @StateObject private var languageStore = ClaudioLanguageStore()

    public init(language: ClaudioAppLanguage = .zhHans) {
        let store = ClaudioLanguageStore(defaults: UserDefaults())
        store.setLanguage(language)
        _languageStore = StateObject(wrappedValue: store)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            galleryFrame("内置包 · 正在查看 · 显示在面板 · 使用中") {
                window(model: builtinModel)
            }
            galleryFrame("自有包 · 可编辑 · 缺失映射 · 孤儿音频") {
                window(model: customModel())
            }
            galleryFrame("磁盘没有声音包 · 恢复入口") {
                window(model: emptyModel)
            }
            galleryFrame("首次读取中 · 未知事实不冒充空库") {
                window(model: loadingModel)
            }
            galleryFrame("后台刷新 · 继续显示上次结果") {
                window(model: customModel(libraryState: .refreshing))
            }
            galleryFrame("刷新失败 · 保留上次结果 · 可重试") {
                window(
                    model: customModel(
                        libraryState: .refreshFailed(reason: "磁盘暂不可用")))
            }
            galleryFrame("首次读取失败 · 无伪造空态 · 可重试") {
                window(model: loadFailedModel)
            }
        }
    }

    private func window(model: SoundPacksWindowModel) -> some View {
        SoundPacksWindowView(
            model: model,
            userPacksDirectory: previewEnvironment.userPacksDirectory,
            focusCoordinator: SoundPacksWindowFocusCoordinator(),
            languageStore: languageStore)
            .frame(width: 760, height: 560)
    }

    private func galleryFrame<Content: View>(
        _ caption: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(caption)
                .font(ClaudioTheme.font(.technical))
            content()
        }
    }

    private var builtinModel: SoundPacksWindowModel {
        let config = ClaudioConfig(
            selectedPack: "minimal-chime",
            masterVolume: 0.8,
            starredPacks: ["minimal-chime"])
        return SoundPacksWindowModel(
            previewConfig: config,
            packCards: [
                PackCard(
                    id: "minimal-chime", name: "极简铃", isCC0: true,
                    presentEvents: Set(Event.allCases), state: .complete, isSelected: true),
            ],
            selectedPackID: "minimal-chime",
            selectedEventRows: Event.allCases.map {
                EventRow(
                    event: $0,
                    coverage: .present(fileName: "\($0.cliName).mp3"),
                    enabled: true)
            },
            builtinPackIDs: ["minimal-chime"],
            starredPackIDs: ["minimal-chime"],
            environment: previewEnvironment,
            refreshCoordinator: SoundPacksRefreshCoordinator())
    }

    private func customModel(
        libraryState: SoundPackLibraryPresentationState = .ready
    ) -> SoundPacksWindowModel {
        let config = ClaudioConfig(selectedPack: "my-long-pack", masterVolume: 0.7)
        return SoundPacksWindowModel(
            previewConfig: config,
            packCards: [
                PackCard(
                    id: "minimal-chime", name: "极简铃", isCC0: true,
                    presentEvents: Set(Event.allCases), state: .complete, isSelected: false),
                PackCard(
                    id: "my-long-pack",
                    name: "My very long bilingual 自定义声音包名称",
                    isCC0: false,
                    presentEvents: [.stop, .notification],
                    state: .partial(present: 2, total: 5),
                    isSelected: true),
            ],
            selectedPackID: "my-long-pack",
            selectedEventRows: [
                EventRow(event: .stop, coverage: .present(fileName: "done.wav"), enabled: false),
                EventRow(event: .stopFailure, coverage: .unmapped, enabled: true),
                EventRow(
                    event: .notification,
                    coverage: .present(fileName: "permission-request.m4a"),
                    enabled: true),
                EventRow(
                    event: .subagentStop,
                    coverage: .broken(fileName: "missing.mp3"),
                    enabled: true),
            ],
            selectedAudioFiles: [
                PackAudioFile(fileName: "done.wav", isOrphan: false),
                PackAudioFile(fileName: "permission-request.m4a", isOrphan: false),
                PackAudioFile(fileName: "unused-long-audio-name.aiff", isOrphan: true),
            ],
            starredPackIDs: [],
            libraryPresentationState: libraryState,
            environment: previewEnvironment,
            refreshCoordinator: SoundPacksRefreshCoordinator())
    }

    private var emptyModel: SoundPacksWindowModel {
        SoundPacksWindowModel(
            previewConfig: ClaudioConfig(selectedPack: ""),
            packCards: [],
            selectedPackID: nil,
            selectedEventRows: [],
            environment: previewEnvironment,
            refreshCoordinator: SoundPacksRefreshCoordinator())
    }

    private var loadingModel: SoundPacksWindowModel {
        SoundPacksWindowModel(
            previewConfig: ClaudioConfig(selectedPack: ""),
            packCards: [],
            selectedPackID: nil,
            selectedEventRows: [],
            libraryPresentationState: .loading,
            environment: previewEnvironment,
            refreshCoordinator: SoundPacksRefreshCoordinator())
    }

    private var loadFailedModel: SoundPacksWindowModel {
        SoundPacksWindowModel(
            previewConfig: ClaudioConfig(selectedPack: ""),
            packCards: [],
            selectedPackID: nil,
            selectedEventRows: [],
            libraryPresentationState: .loadFailed(reason: "声音包目录没有读取权限"),
            environment: previewEnvironment,
            refreshCoordinator: SoundPacksRefreshCoordinator())
    }

    private var previewEnvironment: AudioImportEnvironment {
        AudioImportEnvironment(
            userPacksDirectory: URL(fileURLWithPath: "/dev/null/claudio-preview-packs"),
            durationProbe: PreviewDurationProbe(),
            packsLockFile: URL(fileURLWithPath: "/dev/null/claudio-preview-packs.lock"))
    }
}

private struct PreviewDurationProbe: AudioDurationProbing {
    func probeDuration(of fileURL: URL) -> TimeInterval? { 1 }
}

struct SoundPacksWindowStateGalleryView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            SoundPacksWindowStateGalleryView().preferredColorScheme(.light)
            SoundPacksWindowStateGalleryView().preferredColorScheme(.dark)
        }
    }
}
#endif
