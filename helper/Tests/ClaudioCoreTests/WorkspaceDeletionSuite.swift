import ClaudioCore
import Foundation

@MainActor
func runWorkspaceDeletionSuites() {
    suite("workspace delete: captured directory and UUID guard the locked transaction") {
        withTempDirectory { root in
            let first = root.appendingPathComponent("one/shared")
            let second = root.appendingPathComponent("two/shared")
            try! FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
            try! FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
            let id = UUID()
            let original = deletionRule(id: id, directory: first)
            let replacement = deletionRule(id: id, directory: second)
            let target = WorkspaceSoundDeleteTarget(rule: original)
            let file = root.appendingPathComponent("config.json")
            let lock = root.appendingPathComponent("config.lock")

            expect(
                target.id == id && target.name == "shared"
                    && target.directory == original.directory
                    && replacement.name == target.name,
                "confirmation captures stable UUID, display name and full directory despite same-name paths"
            )

            let replacementBytes = deletionConfigBytes(rule: replacement)
            try! replacementBytes.write(to: file)
            expect(
                deletionFailed(
                    mutateWorkspaceSound(
                        .remove(target), configFile: file, lockFile: lock
                    ), as: .staleRule),
                "same UUID rebound to another directory must be rejected inside the lock")
            expect(
                (try! Data(contentsOf: file)) == replacementBytes,
                "rejected replacement must preserve every config byte")

            let missingBytes = deletionConfigBytes(rule: nil)
            try! missingBytes.write(to: file)
            expect(
                deletionFailed(
                    mutateWorkspaceSound(
                        .remove(target), configFile: file, lockFile: lock
                    ), as: .staleRule)
                    && (try! Data(contentsOf: file)) == missingBytes,
                "missing captured target must leave Default Group and unknown fields untouched")

            try! deletionConfigBytes(rule: original).write(to: file)
            expect(
                deletionSucceeded(
                    mutateWorkspaceSound(
                        .remove(target), configFile: file, lockFile: lock
                    )),
                "exact captured target can be removed")
            let decoded = loadClaudioConfig(from: file)!
            let raw =
                try! JSONSerialization.jsonObject(with: Data(contentsOf: file))
                as! [String: Any]
            expect(
                decoded.workspaceRules.isEmpty && decoded.selectedPack == "default"
                    && decoded.masterVolume == 0.37 && !decoded.isEnabled(.stop),
                "deletion affects only the captured rule, never the Default Group")
            expect(
                (raw["future"] as? [String: String])?["keep"] == "yes"
                    && (raw["surface_overrides"] as? [String: String])?["future"] == "keep",
                "unknown and retired fields survive surgical deletion")
            let afterSuccess = try! Data(contentsOf: file)
            expect(
                deletionFailed(
                    mutateWorkspaceSound(
                        .remove(target), configFile: file, lockFile: lock
                    ), as: .staleRule)
                    && (try! Data(contentsOf: file)) == afterSuccess,
                "repeated confirmation cannot submit the same target again")
        }
    }

    suite("workspace delete: publication conflict is typed and current config remains readable") {
        withTempDirectory { root in
            let directory = root.appendingPathComponent("project")
            try! FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let rule = deletionRule(id: UUID(), directory: directory)
            let file = root.appendingPathComponent("config.json")
            let lock = root.appendingPathComponent("config.lock")
            try! deletionConfigBytes(rule: rule).write(to: file)
            let external = deletionConfigBytes(rule: rule, marker: "external")
            let result = mutateWorkspaceSound(
                .remove(WorkspaceSoundDeleteTarget(rule: rule)),
                configFile: file, lockFile: lock,
                testingBeforeRename: {
                    try! external.write(to: file, options: .atomic)
                })
            if case .failure(.publishedConflict(let recoveryPath)) = result,
                let recoveryPath
            {
                expect(
                    FileManager.default.fileExists(atPath: recoveryPath),
                    "post-publish conflict must retain the exact existing recovery file")
                if case .failure(let error) = result {
                    expect(
                        error.isPublishedConflict && error.recoveryPath == recoveryPath,
                        "upper layers can consume the typed conflict and original recovery path")
                }
            } else {
                expect(false, "post-publish race must carry its actual recovery path")
            }
            expect(
                WorkspaceSoundError.publishedConflict().recoveryPath == nil,
                "path-changed conflicts never invent a recovery file")
            expect(
                loadClaudioConfig(from: file) != nil,
                "after publication conflict, caller can read back the actual current config")
        }
    }
}

private func deletionFailed(
    _ result: Result<Void, WorkspaceSoundError>, as expected: WorkspaceSoundError
) -> Bool {
    if case .failure(let actual) = result { return actual == expected }
    return false
}

private func deletionSucceeded(_ result: Result<Void, WorkspaceSoundError>) -> Bool {
    if case .success = result { return true }
    return false
}

private func deletionRule(id: UUID, directory: URL) -> WorkspaceSoundRule {
    WorkspaceSoundRule(
        id: id,
        directory: WorkspaceDirectory(kind: .directory, path: directory.path),
        surfaces: [.codex],
        profile: WorkspaceSoundProfile(selectedPack: "workspace", volume: 0.8))
}

private func deletionConfigBytes(rule: WorkspaceSoundRule?, marker: String = "yes") -> Data {
    var json: [String: Any] = [
        "selected_pack": "default",
        "master_volume": 0.37,
        "events": ["stop": false],
        "sound_model_version": 2,
        "surface_overrides": ["future": "keep"],
        "future": ["keep": marker],
    ]
    if let rule {
        json["workspace_rules"] = [
            rule.id.uuidString:
                try! JSONSerialization.jsonObject(with: JSONEncoder().encode(rule))
        ]
    }
    return try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
}
