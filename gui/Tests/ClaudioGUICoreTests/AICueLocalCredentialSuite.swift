import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Darwin
import Foundation

private actor LocalCredentialKeychainSpy: AICueCredentialVault {
    private(set) var slots: [AICueCredentialSlotID] = []
    func containsCredential(in slotID: AICueCredentialSlotID) -> Bool {
        slots.append(slotID)
        return false
    }
    func credential(in slotID: AICueCredentialSlotID) -> SensitiveCredentialInput? {
        slots.append(slotID)
        return nil
    }
    func replaceCredential(_ credential: SensitiveCredentialInput, in slotID: AICueCredentialSlotID)
    {
        slots.append(slotID)
    }
    func deleteCredential(in slotID: AICueCredentialSlotID) {
        slots.append(slotID)
    }
}

private actor LocalCredentialProbe: AICueCredentialValidating {
    private var rejected = false
    private(set) var calls = 0
    func reject() { rejected = true }
    func validateCredential(_ credential: SensitiveCredentialInput) throws {
        calls += 1
        if rejected { throw AICueProviderError.invalidCredential }
    }
}

private actor LocalCredentialMetadata: AICueCredentialMetadataStoring {
    private var values: [AICueProviderProfileID: AICueCredentialVerification] = [:]
    func verification(for profileID: AICueProviderProfileID) -> AICueCredentialVerification? {
        values[profileID]
    }
    func setVerification(
        _ verification: AICueCredentialVerification?, for profileID: AICueProviderProfileID
    ) {
        values[profileID] = verification
    }
}

@MainActor
func runAICueLocalCredentialSuites() async {
    await suite("SenseAudio 本地凭据：缺失查询不写盘，重建实例可读取，替换与删除仅影响自身") {
        await withTempDirectory { temporary in
            let root = temporary.resolvingSymlinksInPath().appendingPathComponent("Credentials")
            let vault = SenseAudioFileCredentialVault(directory: root)
            expect(try! await vault.containsCredential(in: .senseAudioChina) == false, "首次查询应为未配置")
            expect(try! await vault.credential(in: .senseAudioChina) == nil, "没有文件时不提供凭据")
            try! await vault.deleteCredential(in: .senseAudioChina)
            expect(!FileManager.default.fileExists(atPath: root.path), "查询和空删除不创建目录")

            let fake = "fixture-only-senseaudio-first"
            try! await vault.replaceCredential(
                try! SensitiveCredentialInput(fake), in: .senseAudioChina)
            let file = root.appendingPathComponent("senseaudio-cn.key")
            let attrs = try! FileManager.default.attributesOfItem(atPath: file.path)
            let rootAttrs = try! FileManager.default.attributesOfItem(atPath: root.path)
            expect(attrs[.posixPermissions] as? Int == 0o600, "凭据文件从创建起仅供当前用户读写")
            expect(rootAttrs[.posixPermissions] as? Int == 0o700, "凭据目录仅供当前用户访问")
            expect(try! Data(contentsOf: file) == Data(fake.utf8), "只保存规范化后的假 Key 字节")

            let reopened = SenseAudioFileCredentialVault(directory: root)
            expect(try! await reopened.containsCredential(in: .senseAudioChina), "重建实例不依赖内存缓存")
            let credential = try! await reopened.credential(in: .senseAudioChina)
            expect(credential != nil, "重启后文件能够还原凭据")
            expect(Mirror(reflecting: credential!).children.isEmpty, "凭据仍然不可通过反射打印")

            try! await reopened.replaceCredential(
                try! SensitiveCredentialInput("fixture-only-second"), in: .senseAudioChina)
            expect(try! Data(contentsOf: file) == Data("fixture-only-second".utf8), "替换发布完整新值")
            let sibling = root.appendingPathComponent("unrelated.txt")
            try! Data("preserved".utf8).write(to: sibling)
            try! await reopened.deleteCredential(in: .senseAudioChina)
            expect(try! await vault.containsCredential(in: .senseAudioChina) == false, "旧实例也立即看到删除")
            expect(try! String(contentsOf: sibling, encoding: .utf8) == "preserved", "删除不触碰其他文件")
            expect(
                try! FileManager.default.contentsOfDirectory(atPath: root.path) == [
                    "unrelated.txt"
                ],
                "成功写入和删除后没有遗留临时 Key 文件")
        }
    }

    await suite("SenseAudio 本地凭据：实际 manager 保存、重启与生成取用，不触碰 Keychain") {
        await withTempDirectory { temporary in
            let root = temporary.resolvingSymlinksInPath().appendingPathComponent("Credentials")
            let spy = LocalCredentialKeychainSpy()
            let fileVault = SenseAudioFileCredentialVault(directory: root)
            let vault = AICueAppCredentialVault(keychain: spy, senseAudio: fileVault)
            let registry = AICueProviderRegistry(
                evidenceGatedSenseAudioAssetPolicy: try! AICueAssetPolicy(
                    allowedOrigins: [
                        try! AICueAssetOrigin("https://dynamic.senseaudio.cn:443")
                    ],
                    acceptedMediaTypes: ["audio/mpeg"]))
            let probe = LocalCredentialProbe()
            let metadata = LocalCredentialMetadata()
            let manager = AICueCredentialManager(
                vault: vault, registry: registry, validators: [.senseAudioChina: probe],
                metadata: metadata)
            expect(await manager.status(for: .senseAudioChina) == .missing, "页面初始状态为未配置")
            let saved = try! await manager.save(
                try! SensitiveCredentialInput("fixture-only-approved"), for: .senseAudioChina)
            expect(
                saved == .stored(verification: .verified, hasPendingReplacement: false),
                "一次验证并保存进入可用状态")
            expect(await probe.calls == 1, "保存只执行一次 fake probe，不发生成请求")

            let restarted = AICueCredentialManager(
                vault: AICueAppCredentialVault(
                    keychain: spy, senseAudio: SenseAudioFileCredentialVault(directory: root)),
                registry: registry, validators: [.senseAudioChina: probe], metadata: metadata)
            expect(await restarted.status(for: .senseAudioChina) == saved, "重新装配 manager 后保持已保存状态")
            let lease = try! await restarted.credentialForGeneration(for: .senseAudioChina)
            expect(lease.profileID == .senseAudioChina, "真实生成管理接缝可取得相同 Provider 凭据")
            let request = AICueTransportRequest(
                method: .post, url: URL(string: "https://api.senseaudio.cn/v1/get_voice")!,
                expectedOrigin: try! AICueOrigin(
                    scheme: "https", host: "api.senseaudio.cn", port: 443),
                expectedPath: "/v1/get_voice", headers: [:], body: nil,
                acceptedMediaTypes: ["application/json"], maximumWireBytes: 1024,
                deadline: .startingNow())
            let authenticated = try! AICueTransportRequestBuilder.authenticatedURLRequest(
                from: request, authentication: .bearerAPIKey, credential: lease.credential)
            expect(
                authenticated.value(forHTTPHeaderField: "Authorization")
                    == "Bearer fixture-only-approved",
                "重启后的假 Key 正确进入请求编译；测试不发送请求")
            await probe.reject()
            do {
                _ = try await restarted.save(
                    try SensitiveCredentialInput("fixture-only-rejected"), for: .senseAudioChina)
                expect(false, "probe 失败必须拒绝替换")
            } catch {}
            expect(
                try! String(
                    contentsOf: root.appendingPathComponent("senseaudio-cn.key"), encoding: .utf8)
                    == "fixture-only-approved", "probe 失败保留已保存的假 Key")
            try! await restarted.delete(for: .senseAudioChina)
            expect(await spy.slots.isEmpty, "SenseAudio 的查询、保存、取用、替换和删除均不访问 Keychain")

            let otherSlots: [AICueCredentialSlotID] = [
                .legacyElevenLabs, .miniMaxGlobal, .qwenSingapore, .qwenBeijing,
                .qwenSingaporePending, .qwenBeijingPending,
            ]
            for slot in otherSlots { _ = try! await vault.containsCredential(in: slot) }
            expect(await spy.slots == otherSlots, "既有 Provider 和 pending slot 继续原样交给 Keychain")
        }
    }

    await suite("SenseAudio 本地凭据：拒绝不安全文件与父目录，错误不包含路径或值") {
        await withTempDirectory { temporary in
            let canonical = temporary.resolvingSymlinksInPath()
            let root = canonical.appendingPathComponent("Credentials")
            let file = root.appendingPathComponent("senseaudio-cn.key")
            let vault = SenseAudioFileCredentialVault(directory: root)
            let fake = try! SensitiveCredentialInput("fixture-only-old")
            try! await vault.replaceCredential(fake, in: .senseAudioChina)

            try! FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: file.path)
            await expectLocalCredentialFailure {
                _ = try await vault.credential(in: .senseAudioChina)
            }
            await expectLocalCredentialFailure {
                try await vault.replaceCredential(fake, in: .senseAudioChina)
            }
            expect(try! Data(contentsOf: file) == Data("fixture-only-old".utf8), "写入失败保留旧内容")
            try! FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path)

            for malformed in [
                Data(), Data(repeating: 65, count: 513), Data([0xff]), Data("bad\nkey".utf8),
            ] {
                try! malformed.write(to: file)
                await expectLocalCredentialFailure {
                    _ = try await vault.credential(in: .senseAudioChina)
                }
            }
            try! Data("fixture-only-old".utf8).write(to: file)
            let hardlink = canonical.appendingPathComponent("hardlink")
            try! FileManager.default.linkItem(at: file, to: hardlink)
            await expectLocalCredentialFailure {
                _ = try await vault.credential(in: .senseAudioChina)
            }
            try! FileManager.default.removeItem(at: hardlink)
            try! FileManager.default.removeItem(at: file)

            let outside = canonical.appendingPathComponent("outside")
            try! Data("untouched".utf8).write(to: outside)
            try! FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
            await expectLocalCredentialFailure {
                _ = try await vault.containsCredential(in: .senseAudioChina)
            }
            await expectLocalCredentialFailure {
                try await vault.replaceCredential(fake, in: .senseAudioChina)
            }
            await expectLocalCredentialFailure {
                try await vault.deleteCredential(in: .senseAudioChina)
            }
            expect(try! String(contentsOf: outside, encoding: .utf8) == "untouched", "链接目标未读取或覆盖")
            try! FileManager.default.removeItem(at: file)
            expect(mkfifo(file.path, 0o600) == 0, "创建 FIFO fixture")
            await expectLocalCredentialFailure {
                _ = try await vault.credential(in: .senseAudioChina)
            }
            try! FileManager.default.removeItem(at: file)

            let alias = canonical.appendingPathComponent("alias")
            try! FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
            let redirected = SenseAudioFileCredentialVault(
                directory: alias.appendingPathComponent("nested"))
            await expectLocalCredentialFailure {
                try await redirected.replaceCredential(fake, in: .senseAudioChina)
            }
            expect(
                !FileManager.default.fileExists(atPath: root.appendingPathComponent("nested").path),
                "父目录符号链接不产生写入")

            try! FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: root.path)
            await expectLocalCredentialFailure {
                try await vault.replaceCredential(fake, in: .senseAudioChina)
            }
            try! FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: root.path)
            await expectLocalCredentialFailure {
                try await vault.replaceCredential(fake, in: .miniMaxGlobal)
            }
            expect(
                try! FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty,
                "失败路径不留下临时凭据或其他 Provider 文件")
        }
    }

    suite("SenseAudio 本地凭据：如实披露存储与错误，不冒充 Keychain") {
        for language in ClaudioAppLanguage.allCases {
            let l10n = ClaudioL10n(language: language)
            let message = aiCueCredentialFailureText(
                .storageUnavailable, providerProfileID: .senseAudioChina,
                credentialStatus: .missing, l10n: l10n)
            expect(
                message == l10n.text(.aiCueErrorLocalCredentialUnavailable), "本地文件失败不要求解锁 Keychain")
            expect(!l10n.text(.aiCueCredentialLocalFile).isEmpty, "两种语言均有本地存储说明")
        }
        let registry = AICueProviderRegistry(
            evidenceGatedSenseAudioAssetPolicy: try! AICueAssetPolicy(
                allowedOrigins: [try! AICueAssetOrigin("https://dynamic.senseaudio.cn:443")],
                acceptedMediaTypes: ["audio/mpeg"]))
        expect(
            try! registry.profile(for: .senseAudioChina).credentialStorageDisclosureKey
                == .aiCueCredentialLocalFile,
            "SenseAudio 表单使用本地文件说明")
        for profile in AICueProviderRegistry().profiles() where profile.id != .senseAudioChina {
            expect(
                profile.credentialStorageDisclosureKey == .aiCueCredentialKeychain,
                "其他 Provider 保持 Keychain 说明")
        }
    }
}

@MainActor
private func expectLocalCredentialFailure(_ action: () async throws -> Void) async {
    do {
        try await action()
        expect(false, "不安全存储必须失败")
    } catch {
        expect(error as? AICueLocalCredentialError == .unavailable, "只返回无路径、无凭据的存储错误")
    }
}
