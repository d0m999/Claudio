import ClaudioCore
import Foundation

/// Reads and decodes `configFile` into a ``ClaudioConfig``, falling back to a default,
/// no-pack-selected config if the file is missing, unreadable, or corrupt — the panel must
/// never crash or hang over a bad `config.json` (mirrors ``ClaudioConfig/init(from:)``'s own
/// lenient per-field fallback, applied here one level up, to the whole-file read). `PanelView`
/// (`ClaudioGUI`, T15, compile-only) is this function's real caller; kept as a free function
/// here — not a method on a view-model — so the load/fallback DECISION itself is
/// independently unit-testable without any `ObservableObject`/SwiftUI ceremony around it.
public func loadPanelConfig(from configFile: URL) -> ClaudioConfig {
    guard let data = try? Data(contentsOf: configFile),
        let decoded = try? JSONDecoder().decode(ClaudioConfig.self, from: data)
    else {
        return ClaudioConfig(selectedPack: "")
    }
    return decoded
}
