import ClaudioGUICore
import Foundation

private enum CredentialFixtureError: Error, Sendable, Equatable {
    case rejected
    case writeFailed
    case deleteFailed
}

private actor CredentialVaultFixture: AICueCredentialVault {
    private var items: [AICueCredentialSlotID: SensitiveCredentialInput]
    private let failingReplacements: Set<AICueCredentialSlotID>
    private let failingDeletions: Set<AICueCredentialSlotID>
    private(set) var reads: [AICueCredentialSlotID] = []
    private(set) var replacements: [AICueCredentialSlotID] = []
    private(set) var deletions: [AICueCredentialSlotID] = []

    init(
        items: [AICueCredentialSlotID: SensitiveCredentialInput] = [:],
        failingReplacements: Set<AICueCredentialSlotID> = [],
        failingDeletions: Set<AICueCredentialSlotID> = []
    ) {
        self.items = items
        self.failingReplacements = failingReplacements
        self.failingDeletions = failingDeletions
    }

    func containsCredential(in slotID: AICueCredentialSlotID) async throws -> Bool {
        reads.append(slotID)
        return items[slotID] != nil
    }

    func credential(in slotID: AICueCredentialSlotID) async throws -> SensitiveCredentialInput? {
        reads.append(slotID)
        return items[slotID]
    }

    func replaceCredential(
        _ credential: SensitiveCredentialInput,
        in slotID: AICueCredentialSlotID
    ) async throws {
        replacements.append(slotID)
        if failingReplacements.contains(slotID) { throw CredentialFixtureError.writeFailed }
        items[slotID] = credential
    }

    func deleteCredential(in slotID: AICueCredentialSlotID) async throws {
        deletions.append(slotID)
        if failingDeletions.contains(slotID) { throw CredentialFixtureError.deleteFailed }
        items.removeValue(forKey: slotID)
    }

    func item(in slotID: AICueCredentialSlotID) -> SensitiveCredentialInput? {
        items[slotID]
    }

    func facts() -> (
        reads: [AICueCredentialSlotID],
        replacements: [AICueCredentialSlotID],
        deletions: [AICueCredentialSlotID]
    ) {
        (reads, replacements, deletions)
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

private actor CredentialMetadataFixture: AICueCredentialMetadataStoring {
    private var values: [AICueProviderProfileID: AICueCredentialVerification]

    init(values: [AICueProviderProfileID: AICueCredentialVerification] = [:]) {
        self.values = values
    }

    func verification(
        for profileID: AICueProviderProfileID
    ) -> AICueCredentialVerification? {
        values[profileID]
    }

    func setVerification(
        _ verification: AICueCredentialVerification?,
        for profileID: AICueProviderProfileID
    ) {
        values[profileID] = verification
    }
}

@MainActor
func runAICueCredentialSuites() async {
    await suite("AI 提示音凭据：registry slot 直接复用 legacy account 并隔离地区") {
        let vault = CredentialVaultFixture(items: [
            .legacyElevenLabs: try! SensitiveCredentialInput("legacy-eleven-key"),
            .qwenSingapore: try! SensitiveCredentialInput("singapore-key"),
        ])
        let manager = makeCredentialManager(vault: vault)

        expect(
            await manager.status(for: .elevenLabsGlobal)
                == .stored(verification: .deferred, hasPendingReplacement: false),
            "旧安装必须直接读取 account elevenlabs，不能要求迁移")
        expect(
            await manager.status(for: .qwenSingapore)
                == .stored(verification: .deferred, hasPendingReplacement: false),
            "Singapore 必须只投影自己的 active slot")
        expect(
            await manager.status(for: .qwenBeijing) == .missing,
            "Beijing 不得交叉读取 Singapore key")
        let reads = await vault.facts().reads.map(\.rawValue)
        expect(reads.contains("elevenlabs"), "ElevenLabs 必须读取旧 account elevenlabs")
        expect(!reads.contains("elevenlabs-global"), "不得创建或读取新 account elevenlabs-global")
    }

    await suite("AI 提示音凭据：read-only profile probe 成功后才原子替换") {
        let old = try! SensitiveCredentialInput("old-minimax-key")
        let new = try! SensitiveCredentialInput("new-minimax-key")
        let vault = CredentialVaultFixture(items: [.miniMaxGlobal: old])
        let probe = CredentialValidatorFixture(result: .success(()))
        let manager = makeCredentialManager(
            vault: vault,
            validators: [.miniMaxGlobal: probe])

        let status = try! await manager.save(new, for: .miniMaxGlobal)
        expect(await probe.count() == 1, "MiniMax 保存前必须恰好执行一次只读 probe")
        expect(
            await vault.item(in: .miniMaxGlobal) === new,
            "probe 成功后必须原子替换 registry 固定 active slot")
        expect(
            status == .stored(verification: .verified, hasPendingReplacement: false),
            "只读 probe 成功后状态必须明确为 verified")
    }

    await suite("AI 提示音凭据：probe 或 Keychain 失败保留旧 active") {
        let old = try! SensitiveCredentialInput("old-eleven-key")
        let rejectedVault = CredentialVaultFixture(items: [.legacyElevenLabs: old])
        let rejectedProbe = CredentialValidatorFixture(result: .failure(.rejected))
        let rejectedManager = makeCredentialManager(
            vault: rejectedVault,
            validators: [.elevenLabsGlobal: rejectedProbe])
        do {
            _ = try await rejectedManager.save(
                try SensitiveCredentialInput("rejected-key"),
                for: .elevenLabsGlobal)
        } catch {}
        expect(
            await rejectedVault.item(in: .legacyElevenLabs) === old,
            "probe 拒绝不能触发旧 key 删除或覆盖")
        expect(
            await rejectedVault.facts().replacements.isEmpty,
            "probe 失败不得进入 Keychain 写入")

        let failingVault = CredentialVaultFixture(
            items: [.legacyElevenLabs: old],
            failingReplacements: [.legacyElevenLabs])
        let passingProbe = CredentialValidatorFixture(result: .success(()))
        let failingManager = makeCredentialManager(
            vault: failingVault,
            validators: [.elevenLabsGlobal: passingProbe])
        do {
            _ = try await failingManager.save(
                try SensitiveCredentialInput("valid-but-unwritable"),
                for: .elevenLabsGlobal)
        } catch {}
        expect(
            await failingVault.item(in: .legacyElevenLabs) === old,
            "Keychain 原子替换失败必须保留旧 active")
    }

    await suite("AI 提示音凭据：Qwen 首次保存 deferred 且不调用 probe") {
        let vault = CredentialVaultFixture()
        let accidentalProbe = CredentialValidatorFixture(result: .failure(.rejected))
        let manager = makeCredentialManager(
            vault: vault,
            validators: [.qwenSingapore: accidentalProbe])
        let key = try! SensitiveCredentialInput("first-qwen-key")

        let status = try! await manager.save(key, for: .qwenSingapore)
        expect(await accidentalProbe.count() == 0, "Qwen 保存不得发任何模型或 probe 请求")
        expect(await vault.item(in: .qwenSingapore) === key, "首次保存必须写 active slot")
        expect(await vault.item(in: .qwenSingaporePending) == nil, "首次保存不得制造 pending")
        expect(
            status == .stored(verification: .deferred, hasPendingReplacement: false),
            "首次 Qwen key 必须诚实显示 deferred")
    }

    await suite("AI 提示音凭据：Qwen replacement 只尝试 pending，成功后提升") {
        let old = try! SensitiveCredentialInput("old-qwen-key")
        let replacement = try! SensitiveCredentialInput("replacement-qwen-key")
        let vault = CredentialVaultFixture(items: [.qwenSingapore: old])
        let manager = makeCredentialManager(vault: vault)

        let pendingStatus = try! await manager.save(replacement, for: .qwenSingapore)
        expect(await vault.item(in: .qwenSingapore) === old, "保存 replacement 不能先改 active")
        expect(
            await vault.item(in: .qwenSingaporePending) === replacement,
            "replacement 必须进入 registry 固定 pending slot")
        expect(
            pendingStatus
                == .stored(verification: .deferred, hasPendingReplacement: true),
            "状态必须暴露 pending replacement 事实")

        let lease = try! await manager.credentialForGeneration(for: .qwenSingapore)
        expect(lease.credential === replacement, "下一次显式生成只能租用 pending key")
        try! await manager.generationDidValidate(lease)
        expect(await vault.item(in: .qwenSingapore) === replacement, "成功后必须提升为 active")
        expect(await vault.item(in: .qwenSingaporePending) == nil, "提升成功必须清除 pending")
        expect(
            await manager.status(for: .qwenSingapore)
                == .stored(verification: .verified, hasPendingReplacement: false),
            "生成成功后必须标记 verified")
    }

    await suite("AI 提示音凭据：pending promotion 写失败保留旧 active 与 pending") {
        let old = try! SensitiveCredentialInput("old-qwen-key")
        let pending = try! SensitiveCredentialInput("pending-qwen-key")
        let vault = CredentialVaultFixture(
            items: [.qwenSingapore: old, .qwenSingaporePending: pending],
            failingReplacements: [.qwenSingapore])
        let manager = makeCredentialManager(vault: vault)
        let lease = try! await manager.credentialForGeneration(for: .qwenSingapore)

        do { try await manager.generationDidValidate(lease) } catch {}
        expect(await vault.item(in: .qwenSingapore) === old, "promotion 写失败必须保留旧 active")
        expect(
            await vault.item(in: .qwenSingaporePending) === pending,
            "promotion 写失败必须保留 pending 供重试或取消")
    }

    await suite("AI 提示音凭据：pending slot 写失败不改变 active") {
        let old = try! SensitiveCredentialInput("old-qwen-key")
        let vault = CredentialVaultFixture(
            items: [.qwenSingapore: old],
            failingReplacements: [.qwenSingaporePending])
        let manager = makeCredentialManager(vault: vault)

        do {
            _ = try await manager.save(
                try SensitiveCredentialInput("unwritable-pending-key"),
                for: .qwenSingapore)
        } catch {}
        expect(await vault.item(in: .qwenSingapore) === old, "pending 写失败必须保留旧 active")
        expect(await vault.item(in: .qwenSingaporePending) == nil, "失败不得伪造 pending 事实")
    }

    await suite("AI 提示音凭据：孤立 pending fail closed 且保存不覆盖它") {
        let orphan = try! SensitiveCredentialInput("orphan-pending-key")
        let vault = CredentialVaultFixture(items: [.qwenSingaporePending: orphan])
        let manager = makeCredentialManager(vault: vault)

        expect(
            await manager.status(for: .qwenSingapore) == .unavailable,
            "pending 没有 active 是不一致状态，不能伪装为 missing")
        var failedClosed = false
        do {
            _ = try await manager.save(
                try SensitiveCredentialInput("new-active-key"),
                for: .qwenSingapore)
        } catch AICueCredentialManagerError.credentialUnavailable {
            failedClosed = true
        } catch {}
        expect(failedClosed, "不一致状态必须在新保存前失败关闭")
        expect(await vault.item(in: .qwenSingapore) == nil, "失败关闭不得制造新 active")
        expect(
            await vault.item(in: .qwenSingaporePending) === orphan,
            "失败关闭不得覆盖未知来源 pending")
    }

    await suite("AI 提示音凭据：只有 pending 明确 401 才丢弃 replacement") {
        let retainingErrors: [AICueProviderError] = [
            .forbidden, .insufficientCredits, .rateLimited(retryAfterSeconds: nil),
            .serviceUnavailable, .transportFailure, .cancelled,
        ]
        for error in retainingErrors {
            let old = try! SensitiveCredentialInput("old-qwen-key")
            let pending = try! SensitiveCredentialInput("pending-qwen-key")
            let vault = CredentialVaultFixture(items: [
                .qwenBeijing: old, .qwenBeijingPending: pending,
            ])
            let manager = makeCredentialManager(vault: vault)
            let lease = try! await manager.credentialForGeneration(for: .qwenBeijing)
            await manager.generation(lease, didFailWith: error)
            expect(await vault.item(in: .qwenBeijing) === old, "失败不得改用或覆盖旧 active")
            expect(
                await vault.item(in: .qwenBeijingPending) === pending,
                "非 401 失败必须保留 pending")
        }

        let old = try! SensitiveCredentialInput("old-qwen-key")
        let pending = try! SensitiveCredentialInput("invalid-pending-key")
        let vault = CredentialVaultFixture(items: [
            .qwenBeijing: old, .qwenBeijingPending: pending,
        ])
        let manager = makeCredentialManager(vault: vault)
        let lease = try! await manager.credentialForGeneration(for: .qwenBeijing)
        await manager.generation(lease, didFailWith: .invalidCredential)
        expect(await vault.item(in: .qwenBeijing) === old, "pending 401 仍必须保留旧 active")
        expect(await vault.item(in: .qwenBeijingPending) == nil, "明确 401 才能丢弃 pending")
    }

    await suite("AI 提示音凭据：取消 replacement 与删除严格限制当前 profile") {
        let vault = CredentialVaultFixture(items: [
            .legacyElevenLabs: try! SensitiveCredentialInput("eleven-key"),
            .qwenSingapore: try! SensitiveCredentialInput("sg-active"),
            .qwenSingaporePending: try! SensitiveCredentialInput("sg-pending"),
            .qwenBeijing: try! SensitiveCredentialInput("bj-active"),
        ])
        let manager = makeCredentialManager(vault: vault)

        try! await manager.cancelPendingReplacement(for: .qwenSingapore)
        expect(await vault.item(in: .qwenSingapore) != nil, "取消 replacement 不得删除 active")
        expect(await vault.item(in: .qwenSingaporePending) == nil, "取消只删除当前 pending")
        try! await manager.delete(for: .qwenSingapore)
        expect(await vault.item(in: .qwenSingapore) == nil, "删除必须清除当前 active")
        expect(await vault.item(in: .qwenBeijing) != nil, "删除 Singapore 不得触及 Beijing")
        expect(await vault.item(in: .legacyElevenLabs) != nil, "删除 Qwen 不得触及 ElevenLabs")
    }

    await suite("AI 提示音凭据：删除失败保留当前 profile 的旧 active") {
        let active = try! SensitiveCredentialInput("undeletable-active")
        let vault = CredentialVaultFixture(
            items: [.qwenSingapore: active],
            failingDeletions: [.qwenSingapore])
        let manager = makeCredentialManager(vault: vault)

        do { try await manager.delete(for: .qwenSingapore) } catch {}
        expect(
            await vault.item(in: .qwenSingapore) === active,
            "Keychain 删除失败不得谎报或丢失旧 active 事实")
    }

    await suite("AI 提示音凭据：active 401 保留 key 并投影 rejected") {
        let active = try! SensitiveCredentialInput("active-qwen-key")
        let vault = CredentialVaultFixture(items: [.qwenSingapore: active])
        let manager = makeCredentialManager(vault: vault)
        let lease = try! await manager.credentialForGeneration(for: .qwenSingapore)

        await manager.generation(lease, didFailWith: .invalidCredential)
        expect(await vault.item(in: .qwenSingapore) === active, "active 401 不能静默删除 key")
        expect(
            await manager.status(for: .qwenSingapore)
                == .stored(verification: .rejected, hasPendingReplacement: false),
            "active 明确 401 必须投影 rejected")
    }

    suite("AI 提示音凭据：一次性输入和 generation lease 的描述不泄漏") {
        let secret = "fixture-secret-must-not-appear"
        let credential = try! SensitiveCredentialInput("  \(secret)  ")
        let lease = AICueGenerationCredential(
            profileID: .qwenSingapore,
            credential: credential,
            source: .pending,
            revision: 0)
        expect(
            !String(describing: credential).contains(secret)
                && !String(reflecting: credential).contains(secret)
                && !String(describing: lease).contains(secret)
                && !String(reflecting: lease).contains(secret),
            "默认描述和反射不得包含明文 key")
        expect(
            throwsCredentialInput { _ = try SensitiveCredentialInput("   ") },
            "空 key 必须在 provider 前拒绝")
        expect(
            throwsCredentialInput { _ = try SensitiveCredentialInput("line1\nline2") },
            "带换行/控制字符的 key 必须拒绝")
    }
}

private func makeCredentialManager(
    vault: CredentialVaultFixture,
    validators: [AICueProviderProfileID: any AICueCredentialValidating] = [:]
) -> AICueCredentialManager {
    AICueCredentialManager(
        vault: vault,
        validators: validators,
        metadata: CredentialMetadataFixture())
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
