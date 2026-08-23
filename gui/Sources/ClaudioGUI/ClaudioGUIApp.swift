import AppKit
import ClaudioCore
import ClaudioGUICore
import SwiftUI

/// The real menu-bar app entry point (ENGINEERING.md T15 D2) — replaces T7's temporary
/// `WindowGroup { OnboardingView(...) }` scaffolding, whose own doc comment already flagged
/// it as disposable ("expected to be replaced wholesale once the menu bar skeleton lands").
/// A `Scene`-less `App` (`Settings {}` is the smallest legal placeholder `Scene` SwiftUI's
/// `App` protocol requires — it never actually shows a window; the app's real UI is the
/// `NSStatusItem`/`NSPopover` ``MenuBarController`` owns, driven entirely by
/// ``ClaudioGUIAppDelegate``) — a menu-bar-only app has no document window at all.
///
/// ⚠️ COMPILE-ONLY here (see ``MenuBarController``'s doc comment): the actual menu-bar
/// icon, popover open/close, and focus behavior are manual-verify on a real Mac.
@main
struct ClaudioGUIApp: App {
    @NSApplicationDelegateAdaptor(ClaudioGUIAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        // Take ⌘, back off the menu. `Settings` is only here because `App` demands a `Scene`,
        // but SwiftUI still synthesizes a "Settings…" item with a ⌘, key equivalent for it —
        // and `.accessory` only means the app's menu bar is not DISPLAYED, not that
        // `NSApp.mainMenu` is absent: key equivalents are dispatched in-process regardless.
        //
        // That was harmless only for as long as the app never became active. Since
        // ``MenuBarController/showPopover()`` started calling `NSApp.activate`, the panel
        // being open means Claudio is frontmost while the menu bar on screen still belongs to
        // the app the user was in — so a user reaching for ⌘, (meaning to open THAT app's
        // preferences) instead opens a blank "claudi0 Settings" window, which takes key and
        // shoves the transient popover out of existence.
        //
        // Only this one item is removed. `NSApp.mainMenu = nil` would take ⌘C/⌘V/⌘X/⌘A down
        // with it — AppKit text controls reach the pasteboard through those menu items' key
        // equivalents.
        .commands {
            CommandGroup(replacing: .appSettings) {}
        }
    }
}

/// Owns ``MenuBarController`` for the app's lifetime — an `NSApplicationDelegate`, not a
/// SwiftUI `Scene`, because the status item + popover are pure AppKit constructs with no
/// SwiftUI `Scene` counterpart (mirrors how every "menu bar only" SwiftUI app on macOS is
/// structured: `Scene` bodies model WINDOWS, and this app deliberately has none).
final class ClaudioGUIAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var hostIntegrationBridge: HostIntegrationManagerBridge?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `.accessory`: no Dock icon, no menu bar application menu — the correct activation
        // policy for a menu-bar-only utility (DESIGN.md「空间 / 同类」: menubar 工具类 app).
        NSApp.setActivationPolicy(.accessory)

        // Bundled packs stay out of the runtime lookup order (`bundledPacksDirectory == nil`).
        // The panel is always renderable now, including before either host is connected; the
        // manager-backed launch task separately runs SharedRuntimeBootstrap to publish bundled
        // packs into the user root, then refreshes this same injected environment.
        //
        // `factoryPacksDirectory` 回答一个不同的问题（``AudioImportEnvironment/factoryPacksDirectory``
        // 的 doc、PLAN-SOUND-MANAGER.md §2.3/T6）：不是「去哪查」（那是上面恒 `nil` 的
        // `bundledPacksDirectory`），而是「出厂包从哪拷来」—— 派生 `builtinPackIDs`（T6 只读闸门
        // 唯一判据）与 `forkPack` 的拷贝源。`Bundle.main` 是全 app 唯一允许说出
        // `Contents/Resources/packs` 这个真实路径的地方（T17「唯一一处 `Bundle.main`」的规矩，
        // 与下面 `bundledHelperBinary(in: .main)` 同一条纪律）—— release.yml 确实把
        // `minimal-chime` 打进了那个目录。这里若漏传、沿用默认值 `nil`，`builtinPackIDs` 在真实
        // 出货的 app 里恒为空集，T6 想关掉的「内置包被拖入静默覆盖」原样重开，且不会有任何测试
        // 断言变红（所有测试 fixture 都显式注入这个字段，只有这一个生产构造点会漏）。
        // `Bundle.main.resourceURL` 在 `swift run ClaudioGUI` 下也会指向一个非 app 目录，所以不能
        // 直接把 `resourceURL/packs` 当成已配置的必需根。纯函数只对真实 `.app` 返回
        // `Contents/Resources/packs`；开发态返回 nil，但正式 app 丢了 packs 目录仍会由
        // `SoundPackLibrary` fail closed，不会把损坏的分发包伪装成「没有内置包」。
        // `packsLockFile` 没有默认值（见 ``AudioImportEnvironment/packsLockFile`` 的 doc：漏传它
        // 的失败模式是**静默**的，所以由编译器执行而不是靠纪律）。这里是全 app 唯一一处说出真实
        // 路径的地方 —— 组装根说出它，比让一个默认值在三十几个 fixture 背后悄悄生效要好。
        let factoryPacksDirectory = applicationFactoryPacksDirectory(
            bundleURL: Bundle.main.bundleURL)
        let audioEnvironment = AudioImportEnvironment(
            factoryPacksDirectory: factoryPacksDirectory,
            durationProbe: AVFoundationAudioDurationProbe(),
            packsLockFile: ClaudioPaths.packsLockFile)

        // The shell starts from honest, fail-closed facts: both rows exist, neither is fabricated
        // as connected. A manager-backed provider can replace this matrix asynchronously without
        // changing either UI surface or teaching the views how to inspect host files. A dedicated
        // native probe build can inject a fixed state to exercise unequal natural card heights
        // without reading or mutating the user's real host configuration. The production build
        // does not compile that injection path.
#if CLAUDIO_NATIVE_HOST_CARD_PROBE
        let nativeProbeState = nativeHostCardProbeState()
#else
        let nativeProbeState: HostIntegrationPresentationState? = nil
#endif
        let disconnectedSnapshots = HostID.allCases.map {
            HostIntegrationSnapshot.disconnected(host: $0)
        }
        let hostCapabilities = Dictionary(
            uniqueKeysWithValues: HostID.allCases.map { host in
                (host, HostCapabilityCatalog.bindings(for: host))
            })
        let disconnectedMatrix = AudibilityMatrix.make(
            snapshots: disconnectedSnapshots,
            capabilities: hostCapabilities,
            soundCoverage: Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0, false) }),
            enabledEvents: Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0, true) }))
        let disconnectedIntegrationState = HostIntegrationPresentationState(
            snapshots: disconnectedSnapshots,
            matrix: disconnectedMatrix)
        let initialIntegrationState = nativeProbeState ?? disconnectedIntegrationState

        // The ONLY `Bundle.main` in the app (T17). Everything downstream of it — is this really
        // the helper? is it runnable? what gets copied where? — is a pure function in
        // `ClaudioGUICore`, unit-tested against a real fixture bundle. What is left here is a
        // single branchless token, `.main`, with no decision in it and nothing to get wrong.
        //
        // `nil` under `swift run ClaudioGUI` (no bundled helper) 也不伪造成功：bootstrapper
        // 会检查固定 helper 路径，不可用时通过动态 adapter snapshot 呈现 runtime 损坏。
        let bundledHelper = bundledHelperBinary(in: .main)
        let setupEnvironment = SetupEnvironment(
            executablePath: bundledHelper ?? ClaudioPaths.claudioBinary)
        let integrationManager = HostIntegrationManager(
            adapters: [
                ClaudeCodeIntegrationAdapter(), CodexIntegrationAdapter(),
                WorkBuddyIntegrationAdapter(),
            ],
            bootstrapper: SystemSharedRuntimeBootstrapper(environment: setupEnvironment))
        let integrationBridge = HostIntegrationManagerBridge(
            manager: integrationManager,
            configFile: ClaudioPaths.configFile,
            audioEnvironment: audioEnvironment)
        hostIntegrationBridge = integrationBridge

        let integrationMatrixProvider: HostIntegrationMatrixProvider
        if let nativeProbeState {
            // Keep both asynchronous entry points on the same fixture. Without this, the real
            // launch bootstrap could replace the injected rows before the popover is captured.
            integrationMatrixProvider = HostIntegrationMatrixProvider(
                refresh: { nativeProbeState },
                bootstrap: { nativeProbeState })
        } else {
            integrationMatrixProvider = HostIntegrationMatrixProvider(
                refresh: { await integrationBridge.refresh() },
                bootstrap: { await integrationBridge.bootstrapSharedRuntime() })
        }
        let integrationActionProvider = HostIntegrationActionProvider { action in
            try await integrationBridge.perform(action)
        }

        menuBarController = MenuBarController(
            audioEnvironment: audioEnvironment,
            hostIntegrationState: initialIntegrationState,
            integrationMatrixProvider: integrationMatrixProvider,
            integrationActionProvider: integrationActionProvider)
    }
}

#if CLAUDIO_NATIVE_HOST_CARD_PROBE
/// Fixed, side-effect-free state used only by the native host-card layout probe. The probe keeps
/// one host in `.ready` (no detail text) and the other in a multiline `.needsAttention` state so
/// removing equalization makes the screenshot assertion fail for the right reason.
private func nativeHostCardProbeState() -> HostIntegrationPresentationState? {
    guard ProcessInfo.processInfo.environment["CLAUDIO_TEST_HOST_CARD_STATE"] == "unequal" else {
        return nil
    }

    let installationID = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!
    guard
        let claudeBinding = HostCapabilityCatalog.binding(
            host: .claudeCode, event: .taskStart),
        let nativeEvent = claudeBinding.nativeEvent
    else {
        return nil
    }

    let receipt = HostReceiptEvidence(
        installationID: installationID,
        nativeEvent: nativeEvent,
        event: .taskStart,
        timestamp: Date(timeIntervalSince1970: 1),
        playbackResult: .played)
    let claudeSnapshot = HostIntegrationSnapshot(
        host: .claudeCode,
        runtime: .ready,
        availability: .available,
        configuration: .configured,
        writability: .writable,
        activation: .observed(receipt),
        latestReceipt: receipt,
        installationID: installationID)
    let codexSnapshot = HostIntegrationSnapshot(
        host: .codex,
        runtime: .ready,
        availability: .available,
        configuration: .conflict(
            reason: "native probe detail line one\n"
                + "native probe detail line two"),
        writability: .writable,
        activation: .none)
    let snapshots = [claudeSnapshot, codexSnapshot]
    let capabilities = Dictionary(
        uniqueKeysWithValues: HostID.allCases.map { host in
            (host, HostCapabilityCatalog.bindings(for: host))
        })
    let matrix = AudibilityMatrix.make(
        snapshots: snapshots,
        capabilities: capabilities,
        soundCoverage: Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0, true) }),
        enabledEvents: Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0, true) }))
    return HostIntegrationPresentationState(snapshots: snapshots, matrix: matrix)
}
#endif
