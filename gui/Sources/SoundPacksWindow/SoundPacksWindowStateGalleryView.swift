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
    @StateObject private var languageStore = ClaudioPreferences()
    @StateObject private var fixture: SoundPacksWindowGalleryFixture

    public init(
        language: ClaudioAppLanguage = .zhHans,
        textSize: ClaudioInterfaceTextSize = .standard
    ) {
        let store = ClaudioPreferences(defaults: UserDefaults())
        store.setLanguage(language)
        store.setInterfaceTextSize(textSize)
        _languageStore = StateObject(wrappedValue: store)
        _fixture = StateObject(wrappedValue: SoundPacksWindowGalleryFixture())
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            galleryFrame("内置包 · 正在查看 · 显示在面板 · 使用中") {
                window(id: "builtin") { builtinOwner() }
            }
            galleryFrame("自有包 · 可编辑 · 缺失映射 · 孤儿音频") {
                window(id: "custom") { customOwner() }
            }
            galleryFrame("磁盘没有声音包 · 恢复入口") {
                window(id: "empty") { emptyOwner }
            }
            galleryFrame("首次读取中 · 未知事实不冒充空库") {
                window(id: "loading") { loadingOwner }
            }
            galleryFrame("后台刷新 · 继续显示上次结果") {
                window(id: "refreshing") {
                    customOwner(libraryState: .refreshing)
                }
            }
            galleryFrame("刷新失败 · 保留上次结果 · 可重试") {
                window(id: "refresh-failed") {
                    customOwner(libraryState: .refreshFailed(reason: "磁盘暂不可用"))
                }
            }
            galleryFrame("首次读取失败 · 无伪造空态 · 可重试") {
                window(id: "load-failed") { loadFailedOwner }
            }
            galleryFrame("100 个声音包 · 侧栏密度与稳定滚动") {
                window(id: "large") { largeLibraryOwner }
            }
            galleryFrame("损坏声音包 · 包级错误与损坏映射保持区分") {
                window(id: "broken") { brokenPackOwner }
            }
            galleryFrame("写入中 · owner activity 禁用重入写操作") {
                window(id: "writing") { writingOwner() }
            }
            galleryFrame("恢复失败 · 保留当前内容与可重试说明") {
                window(id: "restore-failed") {
                    builtinOwner(
                        windowStatuses: [restoreFailureStatus],
                        factoryRestoreActionError: restoreFailureError)
                }
            }
            galleryFrame("删除失败 · 保留声音包与失败结果") {
                window(id: "delete-failed") {
                    customOwner(windowStatuses: [deletionFailureStatus])
                }
            }
        }
    }

    private func window(
        id: String,
        makeOwner: @escaping @MainActor () -> SoundPacksEditorOwner
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Default window · 760×560")
                .font(ClaudioTheme.font(.technical))
            productionWindow(
                id: "\(id)-default",
                makeOwner: makeOwner
            )
            .frame(width: 760, height: 560)
            Text("Minimum window · 640×480")
                .font(ClaudioTheme.font(.technical))
            productionWindow(
                id: "\(id)-minimum",
                makeOwner: makeOwner
            )
            .frame(width: 640, height: 480)
        }
    }

    @ViewBuilder
    private func productionWindow(
        id: String,
        makeOwner: @escaping @MainActor () -> SoundPacksEditorOwner
    ) -> some View {
        SoundPacksWindowGalleryScene(
            id: id,
            makeOwner: makeOwner,
            languageStore: languageStore,
            nativeEffects: fixture.nativeEffects)
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

    private func builtinOwner(
        windowStatuses: [SoundPacksWindowStatus] = [],
        factoryRestoreActionError: SoundPacksWindowFactoryRestoreActionError? = nil
    ) -> SoundPacksEditorOwner {
        let config = ClaudioConfig(
            selectedPack: "minimal-chime",
            masterVolume: 0.8,
            starredPacks: ["minimal-chime"])
        return SoundPacksEditorOwner.stateGalleryFixture(
            previewConfig: config,
            packCards: [
                PackCard(
                    id: "minimal-chime", name: "极简铃", isCC0: true,
                    presentEvents: Set(Event.allCases), state: .complete, isSelected: true)
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
            windowStatuses: windowStatuses,
            factoryRestoreActionError: factoryRestoreActionError,
            environment: previewEnvironment)
    }

    private func customOwner(
        libraryState: SoundPackLibraryPresentationState = .ready,
        windowStatuses: [SoundPacksWindowStatus] = [],
        startsBusy: Bool = false
    ) -> SoundPacksEditorOwner {
        let config = ClaudioConfig(selectedPack: "my-long-pack", masterVolume: 0.7)
        return SoundPacksEditorOwner.stateGalleryFixture(
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
            windowStatuses: windowStatuses,
            libraryPresentationState: libraryState,
            environment: previewEnvironment,
            startsBusy: startsBusy)
    }

    private func writingOwner() -> SoundPacksEditorOwner {
        customOwner(startsBusy: true)
    }

    private var emptyOwner: SoundPacksEditorOwner {
        SoundPacksEditorOwner.stateGalleryFixture(
            previewConfig: ClaudioConfig(selectedPack: ""),
            packCards: [],
            selectedPackID: nil,
            selectedEventRows: [],
            environment: previewEnvironment)
    }

    private var loadingOwner: SoundPacksEditorOwner {
        SoundPacksEditorOwner.stateGalleryFixture(
            previewConfig: ClaudioConfig(selectedPack: ""),
            packCards: [],
            selectedPackID: nil,
            selectedEventRows: [],
            libraryPresentationState: .loading,
            environment: previewEnvironment)
    }

    private var loadFailedOwner: SoundPacksEditorOwner {
        SoundPacksEditorOwner.stateGalleryFixture(
            previewConfig: ClaudioConfig(selectedPack: ""),
            packCards: [],
            selectedPackID: nil,
            selectedEventRows: [],
            libraryPresentationState: .loadFailed(reason: "声音包目录没有读取权限"),
            environment: previewEnvironment)
    }

    private var largeLibraryOwner: SoundPacksEditorOwner {
        let cards = (0..<100).map { index in
            PackCard(
                id: "gallery-pack-\(index)",
                name: "Gallery Pack \(index + 1)",
                isCC0: index.isMultiple(of: 2),
                presentEvents: Set(Event.allCases),
                state: .complete,
                isSelected: index == 0)
        }
        return SoundPacksEditorOwner.stateGalleryFixture(
            previewConfig: ClaudioConfig(selectedPack: cards[0].id),
            packCards: cards,
            selectedPackID: cards[0].id,
            selectedEventRows: Event.allCases.map {
                EventRow(
                    event: $0,
                    coverage: .present(fileName: "\($0.cliName).mp3"),
                    enabled: true)
            },
            environment: previewEnvironment)
    }

    private var brokenPackOwner: SoundPacksEditorOwner {
        SoundPacksEditorOwner.stateGalleryFixture(
            previewConfig: ClaudioConfig(selectedPack: "broken-pack"),
            packCards: [
                PackCard(
                    id: "broken-pack",
                    name: "Broken Gallery Pack",
                    isCC0: false,
                    presentEvents: [],
                    state: .broken(reason: "manifest.json 解析失败"),
                    isSelected: true)
            ],
            selectedPackID: "broken-pack",
            selectedEventRows: Event.allCases.map {
                EventRow(
                    event: $0,
                    coverage: .broken(fileName: "\($0.cliName).mp3"),
                    enabled: true)
            },
            environment: previewEnvironment)
    }

    private var restoreFailureStatus: SoundPacksWindowStatus {
        SoundPacksWindowStatus(
            kind: .factoryRestore,
            severity: .failure,
            revision: 101,
            actionText: .localized(.soundPacksStatusRestoreFactory),
            messageText: .literal(
                languageStore.language == .english
                    ? "Could not restore the factory pack; the current contents were kept. Retry after checking disk permissions."
                    : "无法恢复出厂声音包；当前内容已保留。请检查磁盘权限后重试。"),
            recovery: .retryFactoryRestores(packIDs: ["minimal-chime"]))
    }

    private var restoreFailureError: SoundPacksWindowFactoryRestoreActionError {
        .restore(
            packID: "minimal-chime",
            error: .publishFailed(reason: "磁盘权限阻止发布", salvaged: nil),
            retainedSalvages: [])
    }

    private var deletionFailureStatus: SoundPacksWindowStatus {
        SoundPacksWindowStatus(
            kind: .packDeletion,
            severity: .failure,
            revision: 102,
            actionText: .localized(.soundPacksStatusDeletePack),
            messageText: .literal(
                languageStore.language == .english
                    ? "Could not move the sound pack to Trash; the installed pack was kept."
                    : "无法将声音包移到废纸篓；已安装声音包仍完整保留。"))
    }

    private var previewEnvironment: AudioImportEnvironment {
        AudioImportEnvironment(
            userPacksDirectory: fixture.root.appendingPathComponent(
                "packs", isDirectory: true),
            durationProbe: PreviewDurationProbe(),
            packsLockFile: fixture.root.appendingPathComponent("packs.lock"))
    }
}

@MainActor
private final class SoundPacksWindowGalleryFixture: ObservableObject {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "claudio-sound-packs-gallery-fixture-\(UUID().uuidString)", isDirectory: true)
    let nativeEffects: SoundPacksEditorNativeEffectsDispatcher

    init() {
        nativeEffects = SoundPacksEditorNativeEffectsDispatcher(
            adapter: GallerySoundPacksEditorNativeEffectsAdapter())
    }
}

@MainActor
private struct SoundPacksWindowGalleryScene: View {
    private let id: String
    @StateObject private var owner: SoundPacksEditorOwner
    @StateObject private var focusCoordinator = SoundPacksWindowFocusCoordinator()
    @ObservedObject var languageStore: ClaudioPreferences
    private let nativeEffects: SoundPacksEditorNativeEffectsDispatcher

    init(
        id: String,
        makeOwner: @escaping @MainActor () -> SoundPacksEditorOwner,
        languageStore: ClaudioPreferences,
        nativeEffects: SoundPacksEditorNativeEffectsDispatcher
    ) {
        self.id = id
        _owner = StateObject(wrappedValue: makeOwner())
        self.languageStore = languageStore
        self.nativeEffects = nativeEffects
    }

    var body: some View {
        SoundPacksWindowView(
            editorOwner: owner,
            focusCoordinator: focusCoordinator,
            languageStore: languageStore,
            nativeEffects: nativeEffects
        )
        .id(id)
    }
}

@MainActor
private final class GallerySoundPacksEditorNativeEffectsAdapter:
    SoundPacksEditorNativeEffectsAdapter
{
    func selectAudioFiles(allowsMultipleSelection: Bool) -> [URL] { [] }
    func playAudio(fileURL: URL, volume: Double) -> TimeInterval? { nil }
    func stopAudio() {}
    func revealInFinder(fileURL: URL) {}
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
