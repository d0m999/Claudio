import ClaudioCore
import Darwin
import Foundation

package enum AICuePackDraftTransactionError: Error, Sendable, Equatable {
    case stagingFailed(reason: String)
    case destinationAlreadyExists(packID: String)
    case publishFailed(reason: String)
    case lockBusy
    case lockFailed(errno: Int32)
}

/// A hidden, not-yet-selectable draft tree. The caller imports and binds inside `payloadURL`, then
/// publishes only the completed `packDirectoryURL` with one exclusive rename.
package struct AICuePackDraftStage: Sendable, Equatable {
    package let rootURL: URL
    package let payloadURL: URL
    package let packDirectoryURL: URL
    package let finalDirectoryURL: URL

    package init(
        rootURL: URL,
        payloadURL: URL,
        packDirectoryURL: URL,
        finalDirectoryURL: URL
    ) {
        self.rootURL = rootURL
        self.payloadURL = payloadURL
        self.packDirectoryURL = packDirectoryURL
        self.finalDirectoryURL = finalDirectoryURL
    }
}

@MainActor
package func makeAICuePackDraftStage(
    _ draft: AICuePackDraft,
    environment: AudioImportEnvironment
) -> Result<AICuePackDraftStage, AICuePackDraftTransactionError> {
    do {
        try ensurePrivateDirectoryTree(at: environment.userPacksDirectory)
    } catch {
        return .failure(.stagingFailed(reason: error.localizedDescription))
    }

    let template = environment.userPacksDirectory.appendingPathComponent(
        ".\(draft.packID).tmp-XXXXXX")
    var templateBytes = Array(template.path.utf8CString)
    let created = templateBytes.withUnsafeMutableBufferPointer { buffer in
        mkdtemp(buffer.baseAddress!)
    }
    guard created != nil else {
        return .failure(
            .stagingFailed(reason: "无法创建隐藏暂存目录（errno \(errno)）"))
    }
    let createdPath = String(
        decoding: templateBytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
        as: UTF8.self)
    let root = URL(fileURLWithPath: createdPath, isDirectory: true)
    let payload = root.appendingPathComponent("payload", isDirectory: true)
    let pack = payload.appendingPathComponent(draft.packID, isDirectory: true)
    let final = environment.userPacksDirectory.appendingPathComponent(
        draft.packID, isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "id": draft.packID,
            "name": draft.name.value,
            "events": [String: String](),
            "audio_names": [String: String](),
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try data.write(
            to: pack.appendingPathComponent("manifest.json"),
            options: [.atomic])
    } catch {
        try? FileManager.default.removeItem(at: root)
        return .failure(.stagingFailed(reason: error.localizedDescription))
    }
    return .success(
        AICuePackDraftStage(
            rootURL: root,
            payloadURL: payload,
            packDirectoryURL: pack,
            finalDirectoryURL: final))
}

package func stagingEnvironment(
    for stage: AICuePackDraftStage,
    basedOn environment: AudioImportEnvironment
) -> AudioImportEnvironment {
    var staging = environment
    staging.userPacksDirectory = stage.payloadURL
    // A draft is not allowed to resolve a source through a bundled root. Its manifest is created
    // above and the only package identity it can expose is the generated safe draft ID.
    staging.bundledPacksDirectory = nil
    staging.factoryPacksDirectory = nil
    staging.beforeAICueDraftPublish = nil
    return staging
}

@MainActor
package func publishAICuePackDraft(
    _ stage: AICuePackDraftStage,
    importedFile: ImportedAudioFile,
    environment: AudioImportEnvironment
) -> Result<ImportedAudioFile, AICuePackDraftTransactionError> {
    guard importedFile.packID == stage.packDirectoryURL.lastPathComponent else {
        return .failure(.publishFailed(reason: "暂存音频的声音包标识不一致"))
    }
    guard (try? FileManager.default.attributesOfItem(atPath: stage.finalDirectoryURL.path)) == nil
    else {
        return .failure(
            .destinationAlreadyExists(packID: importedFile.packID))
    }

    let locked = withNonBlockingLock(path: environment.packsLockFile.path) {
        do {
            try environment.beforeAICueDraftPublish?(stage.finalDirectoryURL)
        } catch {
            return Result<Void, AICuePackDraftTransactionError>.failure(
                .publishFailed(reason: error.localizedDescription))
        }
        let result = renameatx_np(
            AT_FDCWD,
            stage.packDirectoryURL.path,
            AT_FDCWD,
            stage.finalDirectoryURL.path,
            UInt32(RENAME_EXCL))
        guard result == 0 else {
            let renameErrno = errno
            if renameErrno == EEXIST {
                return .failure(
                    .destinationAlreadyExists(packID: importedFile.packID))
            }
            return .failure(
                .publishFailed(
                    reason: "renameatx_np errno \(renameErrno): "
                        + String(cString: strerror(renameErrno))))
        }
        return .success(())
    }
    switch locked {
    case .skipped:
        return .failure(.lockBusy)
    case .failed(let errno):
        return .failure(.lockFailed(errno: errno))
    case .ran(let result):
        switch result {
        case .failure(let error): return .failure(error)
        case .success:
            let finalFile = stage.finalDirectoryURL.appendingPathComponent(
                importedFile.fileName,
                isDirectory: false)
            discardAICuePackDraftStage(stage)
            return .success(
                ImportedAudioFile(
                    packID: importedFile.packID,
                    destinationURL: finalFile,
                    fileName: importedFile.fileName,
                    format: importedFile.format,
                    fileSizeBytes: importedFile.fileSizeBytes,
                    duration: importedFile.duration))
        }
    }
}

@MainActor
package func discardAICuePackDraftStage(_ stage: AICuePackDraftStage) {
    try? FileManager.default.removeItem(at: stage.rootURL)
}
