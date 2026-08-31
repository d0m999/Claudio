import AppKit
import ClaudioGUICore

enum IntegrationDestinationClipboardAdapter {
    static let system = IntegrationDestinationClipboardWriter { text in
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
