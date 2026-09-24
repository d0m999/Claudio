import AppKit

/// Native focus selection for the retained Settings window and its sheets.
@MainActor
package func settingsWindowOwnsKeyFocus(_ window: NSWindow, keyWindow: NSWindow?) -> Bool {
    var focusedWindow = keyWindow
    while let focused = focusedWindow {
        if focused === window { return true }
        focusedWindow = focused.sheetParent
    }
    return false
}

@MainActor
package func settingsWindowRestorationTarget(_ window: NSWindow) -> NSWindow {
    var target = window
    while let sheet = target.attachedSheet {
        target = sheet
    }
    return target
}
