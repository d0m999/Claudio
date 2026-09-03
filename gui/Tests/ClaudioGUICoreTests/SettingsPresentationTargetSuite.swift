import Foundation

@MainActor
func runSettingsPresentationTargetSuites() {
    suite("Settings presentation target：依赖方向、资源与导入边界固定") {
        let root = guiTestRepositoryRoot()
        let packageURL = root.appendingPathComponent("gui/Package.swift")
        let appURL = root.appendingPathComponent("gui/Sources/ClaudioGUI/ClaudioGUIApp.swift")
        let suiteURL = root.appendingPathComponent(
            "gui/Tests/ClaudioGUICoreTests/SettingsPresentationTargetSuite.swift")
        guard let package = try? String(contentsOf: packageURL, encoding: .utf8),
            let app = try? String(contentsOf: appURL, encoding: .utf8),
            let suiteSource = try? String(contentsOf: suiteURL, encoding: .utf8)
        else {
            expect(false, "读不到 Package、production composition 或 target suite")
            return
        }

        expect(
            package.contains("name: \"ClaudioSettingsPresentation\"")
                && package.contains("\"ClaudioSettingsPresentation\","),
            "Package 必须声明 ClaudioSettingsPresentation 并让 composition roots 直接依赖")
        expect(
            package.contains("\"ClaudioLocalization\"")
                && package.contains("\"ClaudioGUICore\"")
                && package.contains("\"ClaudioGUIComponents\"")
                && package.contains("\"SoundPacksWindow\"")
                && package.contains(".product(name: \"ClaudioCore\", package: \"helper\")"),
            "Settings target 必须直接声明五个既有下游依赖")
        expect(
            app.contains("import ClaudioSettingsPresentation")
                && suiteSource.contains("import ClaudioSettingsPresentation"),
            "production 与 compiled harness 必须 import 同一 Settings presentation module")
    }

    suite("Settings presentation target：共享 slider 与纯 Login model 已迁到正确 owner") {
        let root = guiTestRepositoryRoot()
        let componentURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUIComponents/SharedMasterVolumeSlider.swift")
        let oldSliderURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUI/SharedMasterVolumeSlider.swift")
        let modelURL = root.appendingPathComponent(
            "gui/Sources/ClaudioSettingsPresentation/LoginItemSettingsModel.swift")

        expect(
            FileManager.default.fileExists(atPath: componentURL.path)
                && !FileManager.default.fileExists(atPath: oldSliderURL.path),
            "SharedMasterVolumeSlider 必须由 Components 拥有且旧定义消失")
        guard let model = try? String(contentsOf: modelURL, encoding: .utf8) else {
            expect(false, "LoginItemSettingsModel 必须位于 Settings presentation target")
            return
        }
        expect(
            model.contains("final class LoginItemSettingsModel")
                && !model.contains("import AppKit")
                && !model.contains("import ServiceManagement")
                && !model.contains("SMAppService")
                && !model.contains("SMLoginItemSetEnabled"),
            "Login model 必须保持纯 presentation，不得泄漏 system adapter")
    }
}
