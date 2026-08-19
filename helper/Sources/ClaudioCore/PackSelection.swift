import Foundation

/// D23 定稿②「读」这半条正交轴：`config.json` 现在有没有一个「已经选中」的声音包——只读这一份
/// 文件本身，绝不触碰用户包目录 / manifest（那是
/// ``checkPackIntegrity(configFile:userPacksDirectory:bundledPacksDirectory:)`` 与
/// ``packSelectionPlan(status:usablePackIDs:)`` 的活，两者都比这里重得多：既要解析包目录、又要
/// 读 manifest、还要跟磁盘上「真正能用」的包集合做比对）。
///
/// 与「写」那半条正交轴 ``probeConfigRewritable(configFile:)`` 一起，才是面板路由需要的完整判据——
/// 少了任一半都会把用户导向一个骗人的态：一份 `{"selected_pack": "lofi", "master_volume": "0.35"}`
/// 这样的 config，这里会答 ``PackSelectionStatus/selected(packID:)``（selected_pack 好好的），但它
/// 的 `master_volume` 是字符串，写路径会 fail closed——只问「读」这一半会让面板以为一切正常，
/// 而用户点下去的每一次静音 / 切包都注定失败（见 ``probeConfigRewritable(configFile:)`` 的文档）。
public enum PackSelectionStatus: Sendable, Equatable, Codable {
    /// 文件不存在，或者存在但 `selected_pack` 是空串——两者是同一件事：还没有人选过包。
    case notSelected
    /// `selected_pack` 是一个非空字符串。这里**不**判断它是否真解析得出一个包目录——那是
    /// ``checkPackIntegrity(configFile:userPacksDirectory:bundledPacksDirectory:)`` 的活；这里
    /// 只回答「config.json 有没有记着一个选择」。
    case selected(packID: String)
    /// 文件读不出来，或者顶层不是一份我们认得的 config（不是 JSON 对象 / `selected_pack` 缺失 /
    /// `selected_pack` 不是字符串）——坏文件，不猜不重建。
    case malformed(reason: String)
}

/// 只读探针：`configFile` 现在记没记着一个「已选中」的声音包。**一个字节都不写**，且**不**枚举 /
/// 解析用户包目录——比 ``checkPackIntegrity(configFile:userPacksDirectory:bundledPacksDirectory:)``
/// 轻得多，专供只关心「config.json 自己怎么说」的调用方（面板路由）使用。
///
/// reason 文案与 ``checkPackIntegrity`` 的 `.configUnreadable` 逐字相同（都源自同一次
/// ``readConfigFileBounded(at:)`` + `JSONDecoder` 解码同一份 ``ClaudioConfig``），因为两者描述的
/// 是同一件事——config.json 读不出来——不该各自发明一套说法。
public func packSelection(configFile: URL = ClaudioPaths.configFile) -> PackSelectionStatus {
    guard FileManager.default.fileExists(atPath: configFile.path) else { return .notSelected }

    guard case .success(let data) = readConfigFileBounded(at: configFile) else {
        return .malformed(
            reason: "config.json 无法读取：\(configFile.path)"
                + "（须是不大于 \(maxConfigFileBytes) 字节的普通文件）")
    }

    let config: ClaudioConfig
    do {
        config = try JSONDecoder().decode(ClaudioConfig.self, from: data)
    } catch {
        return .malformed(reason: "config.json 解析失败：\(error.localizedDescription)")
    }

    return config.selectedPack.isEmpty ? .notSelected : .selected(packID: config.selectedPack)
}
