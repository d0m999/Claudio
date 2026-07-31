import Foundation

/// The `~/.claudio/config.json` model — the single source of truth for user settings
/// (ENGINEERING.md「工程落地细节 ⑥ config.json 归属」: the GUI writes it, `claudio play`
/// only reads it — *not* 决议 6, which is the diagnostic-log decision).
///
/// v1 fields: `selected_pack` / `master_volume` / per-event `enabled` / `starred_packs` (决议 3 and
/// PLAN-SOUND-MANAGER.md §2.6).
/// **No `night_dim`** — deferred to v2 (Outside Voice T2).
public struct ClaudioConfig: Codable, Equatable, Sendable {
    /// `afplay -v` default when `master_volume` is absent from the file (Design
    /// Review 待解 ⑤: 倾向默认 0.8).
    public static let defaultMasterVolume = 0.8

    public var selectedPack: String
    public var masterVolume: Double
    /// Per-event mute state, keyed by ``Event/cliName``. An event absent from this map
    /// defaults to **enabled** — the control is opt-out ("静音钮"), not opt-in.
    public var eventsEnabled: [String: Bool]
    /// The optional star selection's three states are semantically distinct: a missing key is
    /// `nil` (use built-in defaults), while `[]` is the user's explicit zero-row choice. This
    /// lenient `(try? decode) ?? nil` deliberately folds a present malformed value into `nil` only
    /// on the panel route, where ``probeConfigRewritable(configFile:)`` has already stopped that
    /// malformed config before it can enter the read model. `play`/`doctor` do not consume stars.
    public var starredPacks: [String]?

    public init(
        selectedPack: String,
        masterVolume: Double = ClaudioConfig.defaultMasterVolume,
        eventsEnabled: [String: Bool] = [:],
        starredPacks: [String]? = nil
    ) {
        self.selectedPack = selectedPack
        self.masterVolume = masterVolume
        self.eventsEnabled = eventsEnabled
        self.starredPacks = starredPacks
    }

    private enum CodingKeys: String, CodingKey {
        case selectedPack = "selected_pack"
        case masterVolume = "master_volume"
        case eventsEnabled = "events"
        case starredPacks = "starred_packs"
    }

    /// Decodes leniently: `selected_pack` is the only required field. A missing or
    /// malformed `master_volume` / `events` falls back to the documented default
    /// rather than failing the whole decode — full "config 缺失/损坏 → 默认" recovery
    /// policy is owned by `claudio use`/install (T2); this is `doctor`'s read path.
    ///
    /// - Warning: **只读路径专用。任何写 `config.json` 的代码都绝不能 round-trip 这个类型。**
    ///   宽松解码在读侧是对的（config 损坏也不该让 hook 失败），但在写侧是数据丢失：坏掉的
    ///   `master_volume` 会被静默换成 0.8 再写回磁盘；而上面那个**合成的** `Encodable` 只会写
    ///   这四个 v1 键，用户 config 里其余的顶层键（`night_dim`、未来字段……）会被整片抹掉——
    ///   两件事都还报 SUCCESS。写路径一律走 `ConfigMutation.swift` 的
    ///   ``updateConfigJSON(at:onMissing:mutate:)``（外科式 `JSONSerialization` 读-改-写，
    ///   读不懂就 fail closed），`selectPack` / `setEventEnabled` / `setMasterVolume` /
    ///   `setStarredPacks` 都已经在那上面。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedPack = try container.decode(String.self, forKey: .selectedPack)
        masterVolume =
            (try? container.decode(Double.self, forKey: .masterVolume))
            ?? ClaudioConfig.defaultMasterVolume
        eventsEnabled = (try? container.decode([String: Bool].self, forKey: .eventsEnabled)) ?? [:]
        starredPacks = (try? container.decode([String].self, forKey: .starredPacks)) ?? nil
    }

    /// Whether `event` should play, honoring the opt-out default described above.
    public func isEnabled(_ event: Event) -> Bool {
        eventsEnabled[event.cliName] ?? true
    }
}
