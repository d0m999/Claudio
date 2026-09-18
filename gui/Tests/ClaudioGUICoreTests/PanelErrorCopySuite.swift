import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

@MainActor
func runPanelErrorCopySuites() {
    suite("面板错误文案：三个写者的每类原因均映射为双语三句式") {
        let reasons: [(PanelWriteFailureReason, PanelErrorCopyCategory)] = [
            (.configReadFailure(reason: "private/path errno 13"), .configReadFailure),
            (.configWriteFailure(reason: "private/path errno 13"), .configWriteFailure),
            (.configPublishedButFailed(reason: "private/path errno 13"), .configPublishedButFailed),
            (.lockBusy, .lockBusy),
            (.lockFailed(errno: 13), .lockFailed),
            (.invalidPackID("../private"), .invalidPackID),
            (.packNotFound("private-id"), .packNotFound),
            (
                .manifestUnreadable(packID: "private-id", reason: "private/path errno 13"),
                .manifestUnreadable
            ),
        ]
        for (reason, category) in reasons {
            expect(reason.copyCategory == category, "typed reason 分类错误：\(reason)")
            for language in ClaudioAppLanguage.allCases {
                let copy = ClaudioL10n(language: language).text(reason.copyCategory.key)
                let sentenceEnd = language == .zhHans ? "。" : "."
                expect(
                    copy.components(separatedBy: sentenceEnd).count == 4,
                    "每类失败必须说明发生、影响与处理：\(category), \(language), \(copy)")
                expect(
                    !copy.contains("errno") && !copy.contains("private"),
                    "技术原因和私有路径不得进入 UI：\(copy)")
            }
        }

        let items = panelWriteFailureItems(
            muteError: .lockBusy,
            packSwitchError: .manifestUnreadable(
                packID: "private-id", reason: "private/path errno 13"),
            masterVolumeError: .lockBusy)
        expect(
            items.map(\.reason) == [
                .lockBusy,
                .manifestUnreadable(packID: "private-id", reason: "private/path errno 13"),
            ],
            "三个写者仍以 typed reason 合并，文案映射不得改变去重")
    }

    suite("面板错误文案：配置失败与 Surface 写失败按类型投影") {
        let malformed = PanelConfigState.malformed(reason: "/private/config.json errno 13")
        let unwritable = PanelConfigState.unwritable(reason: "/private/config.json errno 13")
        expect(malformed.errorCopyCategory == .configMalformed, "损坏配置应给修复文件指引")
        expect(unwritable.errorCopyCategory == .configUnwritable, "不可写配置应给权限指引")
        expect(PanelConfigState.needsPack.errorCopyCategory == nil, "先选包不是失败卡")

        let surfaceErrors: [(SurfaceSoundMutationError, PanelErrorCopyCategory)] = [
            (.configMissing, .configMissing),
            (.configReadFailure(reason: "secret"), .configReadFailure),
            (.configWriteFailure(reason: "secret"), .configWriteFailure),
            (.configPublishedButFailed(reason: "secret"), .configPublishedButFailed),
            (.lockBusy, .surfaceLockBusy),
            (.lockFailed(errno: 13), .surfaceLockFailed),
            (.invalidPackID("secret"), .invalidPackID),
            (.packNotFound("secret"), .packNotFound),
            (.manifestUnreadable(packID: "secret", reason: "secret"), .manifestUnreadable),
        ]
        for (error, category) in surfaceErrors {
            expect(error.panelCopyCategory == category, "Surface 类型分类错误：\(error)")
        }
        let pendingSurfaceWrite = SurfaceSoundIssue.writeFailure(
            message: "private/path errno 13", category: .surfaceLockFailed)
        expect(pendingSurfaceWrite.copyCategory == .surfaceLockFailed, "Surface 问题应保存类型化文案分类")
        expect(
            surfaceSoundIssueAfterReadBack(
                pendingSurfaceWrite,
                configState: .malformed(reason: "read back failed"),
                selectedSurface: .codex) == pendingSurfaceWrite,
            "读回不能把瞬时写失败重新分类或清除")
        let brokenPreviewConfig = ClaudioConfig(
            selectedPack: "global-pack",
            invalidSurfaceOverrideKeys: [HostSurfaceID.workBuddy.rawValue])
        let brokenPreview = PanelConfigController(
            previewConfigState: .operational(brokenPreviewConfig),
            selectedSurface: .workBuddy,
            surfaceSoundIssue: "technical gallery detail",
            environment: makeAudioImportEnvironment(
                userPacksDirectory: URL(fileURLWithPath: "/dev/null/packs")))
        expect(
            brokenPreview.surfaceSoundIssueCopyCategory == .surfaceOverrideMalformed,
            "State Gallery 损坏覆盖不能被误标成普通写失败")
        let published = UseError.configPublishedButFailed(
            reason: "published conflict",
            recoveryPath: "/tmp/.claudio-stage-fixture")
        let retained = panelWriteFailureItems(
            muteError: nil,
            packSwitchError: published,
            masterVolumeError: nil,
            configFailureReason: published.description)
        expect(
            retained.first?.recoveryFile?.path == "/tmp/.claudio-stage-fixture",
            "配置失败卡存在时也不能丢弃发布冲突的恢复文件入口")
        expect(
            retained.first?.reason.copyCategory == .configPublishedButFailed,
            "保留恢复文件不得改变发布失败分类")
        let surfacePublished = SurfaceSoundMutationError.configPublishedButFailed(
            reason: "published conflict", recoveryPath: "/tmp/.claudio-stage-surface-fixture")
        expect(
            surfacePublished.panelRecoveryFile?.path == "/tmp/.claudio-stage-surface-fixture",
            "Surface 发布冲突也必须把恢复文件作为类型化目标")
        let another = PanelWriteFailure(
            reason: .configPublishedButFailed(reason: "another conflict"),
            message: "another conflict",
            recoveryFile: URL(fileURLWithPath: "/tmp/.claudio-stage-second"))
        let recoveryFiles = panelWriteFailureRecoveryFiles(
            items: retained + [another],
            surfaceRecoveryFile: URL(fileURLWithPath: "/tmp/.claudio-stage-second"))
        expect(
            recoveryFiles.map(\.path)
                == ["/tmp/.claudio-stage-fixture", "/tmp/.claudio-stage-second"],
            "两个不同发布冲突都要有入口；重复路径只显示一次")
        for category in [
            PanelErrorCopyCategory.configMalformed, .configUnwritable,
            .surfaceOverrideMalformed, .configMissing, .surfaceLockBusy, .surfaceLockFailed,
        ] {
            for language in ClaudioAppLanguage.allCases {
                let copy = ClaudioL10n(language: language).text(category.key)
                let sentenceEnd = language == .zhHans ? "。" : "."
                expect(copy.components(separatedBy: sentenceEnd).count == 4, "配置卡也须为三句式：\(copy)")
                expect(!copy.contains("/private") && !copy.contains("errno"), "配置卡不得显示技术原因")
            }
        }
    }

    suite("面板错误文案：仅配置位置修复类提供访达恢复入口") {
        for category in [
            PanelErrorCopyCategory.configReadFailure, .configWriteFailure,
            .configPublishedButFailed, .lockFailed, .surfaceLockFailed,
            .configMalformed, .configUnwritable,
            .surfaceOverrideMalformed,
        ] {
            expect(category.offersConfigRecovery, "\(category) 应可打开配置位置")
        }
        for category in [
            PanelErrorCopyCategory.configMissing, .lockBusy, .surfaceLockBusy, .invalidPackID,
            .packNotFound, .manifestUnreadable,
        ] {
            expect(!category.offersConfigRecovery, "\(category) 不应提供无关的访达动作")
        }
    }
}
