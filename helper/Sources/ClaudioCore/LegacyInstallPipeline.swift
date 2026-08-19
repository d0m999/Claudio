import Foundation

public enum LegacyInstallPipelineWarning: Sendable, Equatable {
    case unmapped(event: Event)
    case unplayable(event: Event, fileName: String)
}

public struct LegacyInstallPipelineReport: Sendable, Equatable {
    public let packID: String
    public let playableEvents: [Event]
    public let warnings: [LegacyInstallPipelineWarning]

    public init(
        packID: String,
        playableEvents: [Event],
        warnings: [LegacyInstallPipelineWarning]
    ) {
        self.packID = packID
        self.playableEvents = playableEvents
        self.warnings = warnings
    }
}

public enum LegacyInstallPipelineError: Error, Sendable, Equatable, CustomStringConvertible {
    case configMissing(path: String)
    case configUnreadable(reason: String)
    case packNotFound(packID: String)
    case manifestUnreadable(packID: String, reason: String)
    case noPlayableEvents(packID: String)

    public var description: String {
        switch self {
        case .configMissing(let path):
            return "尚未选择声音包（缺少 \(path)）；先运行 `claudi0 setup` 或 `claudi0 use <pack-id>`"
        case .configUnreadable(let reason):
            return "config.json 无法作为当前播放管线使用：\(reason)"
        case .packNotFound(let packID):
            return "当前声音包 \"\(packID)\" 不存在；拒绝写入一组注定静音的 legacy hooks"
        case .manifestUnreadable(let packID, let reason):
            return "当前声音包 \"\(packID)\" 的 manifest 无法读取：\(reason)；拒绝写入 legacy hooks"
        case .noPlayableEvents(let packID):
            return "当前声音包 \"\(packID)\" 没有任何非空、可安全定位的事件音频；拒绝写入一组注定静音的 legacy hooks"
        }
    }
}

/// `claudi0 install` 写宿主 hooks 前的真实播放管线门禁。它只检查正规非空文件，不声称完成音频解码。
public func legacyInstallPipelineReport(
    configFile: URL = ClaudioPaths.configFile,
    userPacksDirectory: URL = ClaudioPaths.packsDirectory,
    bundledPacksDirectory: URL? = nil
) -> Result<LegacyInstallPipelineReport, LegacyInstallPipelineError> {
    // This command writes only `settings.json`. Its gate must therefore match the tolerant
    // read path used by `playSoundEvent`, not the strict JSON round-trip policy reserved for
    // mutations of `config.json` itself.
    guard FileManager.default.fileExists(atPath: configFile.path) else {
        return .failure(.configMissing(path: configFile.path))
    }

    guard case .success(let configData) = readConfigFileBounded(at: configFile) else {
        return .failure(.configUnreadable(reason: "无法安全读取 \(configFile.path)"))
    }
    let config: ClaudioConfig
    do {
        config = try JSONDecoder().decode(ClaudioConfig.self, from: configData)
    } catch {
        return .failure(.configUnreadable(reason: error.localizedDescription))
    }
    guard let packDirectory = resolvePackDirectory(
        id: config.selectedPack,
        userPacksDirectory: userPacksDirectory,
        bundledPacksDirectory: bundledPacksDirectory)
    else {
        return .failure(.packNotFound(packID: config.selectedPack))
    }
    let manifest: PackManifest
    switch loadPackManifest(in: packDirectory) {
    case .success(let loaded): manifest = loaded
    case .failure(let error):
        return .failure(
            .manifestUnreadable(packID: config.selectedPack, reason: error.reason))
    }

    var playable: [Event] = []
    var warnings: [LegacyInstallPipelineWarning] = []
    for event in Event.allCases {
        guard let fileName = manifest.events[event.manifestKey] else {
            warnings.append(.unmapped(event: event))
            continue
        }
        guard let file = safePackFileURL(fileName, in: packDirectory),
            nonEmptyRegularFileExists(at: file)
        else {
            warnings.append(.unplayable(event: event, fileName: fileName))
            continue
        }
        playable.append(event)
    }
    guard !playable.isEmpty else {
        return .failure(.noPlayableEvents(packID: config.selectedPack))
    }
    return .success(
        LegacyInstallPipelineReport(
            packID: config.selectedPack,
            playableEvents: playable,
            warnings: warnings))
}

public func legacyInstallWarningMessages(
    _ warnings: [LegacyInstallPipelineWarning]
) -> [String] {
    warnings.map { warning in
        switch warning {
        case .unmapped(let event):
            return "⚠ \(event.cliName)：当前声音包没有映射该事件"
        case .unplayable(let event, let fileName):
            return "⚠ \(event.cliName)：\(fileName) 缺失、为空、不是正规文件或越出声音包目录"
        }
    }
}
