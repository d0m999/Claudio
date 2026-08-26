import ClaudioGUICore
import Foundation

private enum CredentialFixtureError: Error, Sendable, Equatable {
    case rejected
    case writeFailed
}

private actor CredentialVaultFixture: AICueCredentialVault {
    private var configured: Bool
    private let failReplacement: Bool
    private(set) var replacementCount = 0
    private(set) var deletionCount = 0

    init(configured: Bool, failReplacement: Bool = false) {
        self.configured = configured
        self.failReplacement = failReplacement
    }

    func containsCredential(for providerID: AICueProviderID) async throws -> Bool {
        configured
    }

    func credential(for providerID: AICueProviderID) async throws -> SensitiveCredentialInput? {
        configured ? try! SensitiveCredentialInput("fixture-existing-key") : nil
    }

    func replaceCredential(
        _ credential: SensitiveCredentialInput,
        for providerID: AICueProviderID
    ) async throws {
        replacementCount += 1
        if failReplacement { throw CredentialFixtureError.writeFailed }
        configured = true
    }

    func deleteCredential(for providerID: AICueProviderID) async throws {
        deletionCount += 1
        configured = false
    }

    func facts() -> (configured: Bool, replacements: Int, deletions: Int) {
        (configured, replacementCount, deletionCount)
    }
}

private actor CredentialValidatorFixture: AICueCredentialValidating {
    private let result: Result<Void, CredentialFixtureError>
    private(set) var validationCount = 0

    init(result: Result<Void, CredentialFixtureError>) {
        self.result = result
    }

    func validateCredential(_ credential: SensitiveCredentialInput) async throws {
        validationCount += 1
        try result.get()
    }

    func count() -> Int { validationCount }
}

@MainActor
func runAICueCredentialSuites() async {
    await suite("AI 提示音凭据：状态只暴露 missing/configured，不返回明文") {
        let missingVault = CredentialVaultFixture(configured: false)
        let configuredVault = CredentialVaultFixture(configured: true)
        let validator = CredentialValidatorFixture(result: .success(()))
        let missing = AICueCredentialManager(vault: missingVault, validator: validator)
        let configured = AICueCredentialManager(vault: configuredVault, validator: validator)

        expect(
            await missing.status(for: .elevenLabs) == .missing,
            "没有 Keychain item 必须投影为 missing")
        expect(
            await configured.status(for: .elevenLabs) == .configured(providerID: .elevenLabs),
            "存在 Keychain item 只能投影 provider 状态")
    }

    await suite("AI 提示音凭据：验证成功后才原子替换") {
        let vault = CredentialVaultFixture(configured: false)
        let validator = CredentialValidatorFixture(result: .success(()))
        let manager = AICueCredentialManager(vault: vault, validator: validator)

        try! await manager.validateAndSave(
            try! SensitiveCredentialInput("fixture-new-key"),
            for: .elevenLabs)
        let facts = await vault.facts()
        expect(await validator.count() == 1, "保存前必须恰好验证一次")
        expect(facts.configured && facts.replacements == 1, "验证成功后必须恰好替换一次")
        expect(
            await manager.status(for: .elevenLabs) == .configured(providerID: .elevenLabs),
            "成功后状态必须来自 vault 的真实 item")
    }

    await suite("AI 提示音凭据：新 key 验证失败时旧 key 完整保留") {
        let vault = CredentialVaultFixture(configured: true)
        let validator = CredentialValidatorFixture(result: .failure(.rejected))
        let manager = AICueCredentialManager(vault: vault, validator: validator)

        var failed = false
        do {
            try await manager.validateAndSave(
                try SensitiveCredentialInput("fixture-rejected-key"),
                for: .elevenLabs)
        } catch CredentialFixtureError.rejected {
            failed = true
        } catch {}
        let facts = await vault.facts()
        expect(failed, "provider 拒绝必须原样失败")
        expect(facts.configured, "验证失败不能删除旧 key")
        expect(facts.replacements == 0, "验证失败不能触发 Keychain 写入")
    }

    await suite("AI 提示音凭据：Keychain 替换失败时旧 key 完整保留") {
        let vault = CredentialVaultFixture(configured: true, failReplacement: true)
        let validator = CredentialValidatorFixture(result: .success(()))
        let manager = AICueCredentialManager(vault: vault, validator: validator)

        var failed = false
        do {
            try await manager.validateAndSave(
                try SensitiveCredentialInput("fixture-valid-but-unwritable"),
                for: .elevenLabs)
        } catch CredentialFixtureError.writeFailed {
            failed = true
        } catch {}
        let facts = await vault.facts()
        expect(failed, "vault 写失败必须可见")
        expect(facts.configured, "替换失败不能先删除旧 key")
        expect(facts.replacements == 1, "经过验证后只尝试一次原子替换")
    }

    await suite("AI 提示音凭据：删除只影响后续生成，不返回或记录旧 key") {
        let vault = CredentialVaultFixture(configured: true)
        let validator = CredentialValidatorFixture(result: .success(()))
        let manager = AICueCredentialManager(vault: vault, validator: validator)

        try! await manager.delete(for: .elevenLabs)
        let facts = await vault.facts()
        expect(!facts.configured && facts.deletions == 1, "删除必须移除唯一 provider item")
        expect(await manager.status(for: .elevenLabs) == .missing, "删除后立即回到 missing")
    }

    suite("AI 提示音凭据：一次性输入拒绝空值/控制字符且默认描述不泄漏") {
        let secret = "fixture-secret-must-not-appear"
        let credential = try! SensitiveCredentialInput("  \(secret)  ")
        expect(
            !String(describing: credential).contains(secret)
                && !String(reflecting: credential).contains(secret),
            "默认描述和反射不得包含明文 key")
        expect(
            throwsCredentialInput { _ = try SensitiveCredentialInput("   ") },
            "空 key 必须在 provider 前拒绝")
        expect(
            throwsCredentialInput { _ = try SensitiveCredentialInput("line1\nline2") },
            "带换行/控制字符的 key 必须拒绝")
    }
}

private func throwsCredentialInput(_ body: () throws -> Void) -> Bool {
    do {
        try body()
        return false
    } catch is AICueCredentialInputError {
        return true
    } catch {
        return false
    }
}
