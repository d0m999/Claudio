import AppKit
import Foundation

@main
enum ClaudioLoginItem {
    private static let mainApplicationBundleIdentifier = "com.claudio.app"

    static func main() {
        let mainApplicationURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard mainApplicationURL.pathExtension == "app" else {
            exit(EXIT_FAILURE)
        }

        let runningMainApplications = NSRunningApplication.runningApplications(
            withBundleIdentifier: mainApplicationBundleIdentifier)
        guard runningMainApplications.isEmpty else {
            exit(EXIT_SUCCESS)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(
            at: mainApplicationURL,
            configuration: configuration
        ) { _, error in
            exit(error == nil ? EXIT_SUCCESS : EXIT_FAILURE)
        }

        // Keep a run loop only until NSWorkspace completes the launch request. The LoginItem is
        // a compatibility launcher, not a second app-lifetime process.
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        application.run()
    }
}
