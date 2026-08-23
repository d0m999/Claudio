import Foundation

/// Current Activation 的版本身份。调用方只能比较完整 fingerprint，不得拆开后自行放宽。
public enum HostActivationScope {
    public static func fingerprint(host: HostID, hostVersion: String) -> String? {
        let normalizedVersion = hostVersion.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalizedVersion.isEmpty, normalizedVersion.utf8.count <= 256 else { return nil }
        let bindingSchema = HostCapabilityCatalog.bindings(for: host)
            .filter(\.isAudibleCapability)
            .map(\.id.rawValue)
            .sorted()
            .joined(separator: ",")
        guard !bindingSchema.isEmpty else { return nil }
        return
            "surface=\(host.surfaceID.rawValue);host=\(normalizedVersion);"
            + "claudio=\(ClaudioVersion.current);bindings=\(bindingSchema)"
    }

    public static func claudeCode() -> String? {
        guard let version = commandVersion(command: "claude") else { return nil }
        return fingerprint(host: .claudeCode, hostVersion: version)
    }

    public static func codex() -> String? {
        guard let version = commandVersion(command: "codex") else { return nil }
        return fingerprint(host: .codex, hostVersion: "cli=\(version)")
    }

    public static func workBuddy() -> String? {
        guard let version = bundleVersion(at: "/Applications/WorkBuddy.app") else { return nil }
        return fingerprint(host: .workBuddy, hostVersion: "app=\(version)")
    }

    private static func bundleVersion(at path: String) -> String? {
        guard let bundle = Bundle(path: path) else { return nil }
        let shortVersion =
            (bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let buildVersion = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let components = [
            shortVersion.flatMap { $0.isEmpty ? nil : "short=\($0)" },
            buildVersion.flatMap { $0.isEmpty ? nil : "build=\($0)" },
        ].compactMap { $0 }
        return components.isEmpty ? nil : components.joined(separator: ";")
    }

    private static func commandVersion(command: String) -> String? {
        switch SystemCommandRunner().run(
            executablePath: "/usr/bin/env",
            arguments: [command, "--version"],
            timeout: 1.0)
        {
        case .completed(let exitCode, let stdout) where exitCode == 0:
            let normalized = stdout.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return normalized.isEmpty || normalized.utf8.count > 256 ? nil : normalized
        case .completed, .timedOut, .launchFailed:
            return nil
        }
    }
}
