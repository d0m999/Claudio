import ClaudioCore

/// Legacy fixture spelling retained only in the test target; production `Event` no longer owns
/// any host-native name. The lookup deliberately goes through adapter capability data.
extension Event {
    var settingsName: String {
        HostCapabilityCatalog.binding(host: .claudeCode, event: self)!.nativeEvent!
    }

    init?(settingsName: String) {
        guard let event = HostCapabilityCatalog.semanticEvent(
            host: .claudeCode, nativeEvent: settingsName)
        else { return nil }
        self = event
    }
}
