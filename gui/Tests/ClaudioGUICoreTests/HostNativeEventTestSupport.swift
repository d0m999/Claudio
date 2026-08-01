import ClaudioCore

/// Test-fixture shorthand only. Production native names live in HostCapabilityCatalog.
extension Event {
    var settingsName: String {
        HostCapabilityCatalog.binding(host: .claudeCode, event: self)!.nativeEvent!
    }
}
