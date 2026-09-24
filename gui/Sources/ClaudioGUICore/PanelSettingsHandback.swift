/// Remembers whether Settings owned key focus before a transient Panel took it.
/// Visibility alone cannot decide the handback: Settings may be behind another app.
public struct PanelSettingsHandback {
    private var settingsWasForeground = false

    public init() {}

    public mutating func begin(settingsWasForeground: Bool) {
        self.settingsWasForeground = settingsWasForeground
    }

    public mutating func takeSettingsRestoration() -> Bool {
        defer { settingsWasForeground = false }
        return settingsWasForeground
    }
}
