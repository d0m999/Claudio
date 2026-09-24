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
            (
                .configPublishedButFailed(
                    reason: "private/path errno 13", recoveryPath: "/tmp/recovery"),
                .configPublishedButFailed
            ),
            (
                .configPublishedButFailed(reason: "private/path errno 13"),
                .configPublishedPathChanged
            ),
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
            (
                .configPublishedButFailed(reason: "secret", recoveryPath: "/tmp/recovery"),
                .configPublishedButFailed
            ),
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
            brokenPreview.surfaceSoundIssueCopyCategory == .configWriteFailure,
            "退役字段不参与解析；注入的写失败保留其分类")
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
            recoveryFile: URL(fileURLWithPath: "/tmp/.claudio-stage-second"),
            source: .packSwitch)
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

        let moved = panelWriteFailureItems(
            muteError: nil,
            packSwitchError: .configPublishedButFailed(reason: "目录已移动"),
            masterVolumeError: nil)
        guard let movedItem = moved.first else {
            expect(false, "目录换位后的失败必须显示")
            return
        }
        expect(
            !movedItem.reason.copyCategory.offersConfigRecovery,
            "目录换位后的发布结果位于被移动目录，不能把原配置路径当成恢复入口")
        for language in ClaudioAppLanguage.allCases {
            let copy = ClaudioL10n(language: language).text(
                movedItem.reason.copyCategory.key)
            expect(
                copy.contains(language == .zhHans ? "若目录被移动" : "if the directory moved"),
                "路径变化应给目录移动提供条件式指引，不断言目录一定移动：\(copy)")
        }
        let surfaceMoved = SurfaceSoundMutationError.configPublishedButFailed(reason: "入口改为符号链接")
        expect(
            !surfaceMoved.panelCopyCategory.offersConfigRecovery,
            "Surface 写者同样不能指向失效的原路径")
        let linkChanged = panelWriteFailureItems(
            muteError: nil,
            packSwitchError: .configPublishedButFailed(reason: "文件入口改为符号链接"),
            masterVolumeError: nil)
        expect(
            linkChanged.first?.reason.copyCategory == .configPublishedPathChanged,
            "首次发布后文件入口被替换也属于路径变化，不能预设为目录移动")
        for language in ClaudioAppLanguage.allCases {
            let copy = ClaudioL10n(language: language).text(
                PanelErrorCopyCategory.configPublishedPathChanged.key)
            expect(
                copy.contains(language == .zhHans ? "原路径" : "original path"),
                "入口替换时须提示核对原配置路径：\(copy)")
        }
    }

    suite("面板错误文案：不同 typed reason 各自可见，恢复文件仍完整保留") {
        let recoveryA = "/tmp/.claudio-stage-first"
        let recoveryB = "/tmp/.claudio-stage-second"
        let items = panelWriteFailureItems(
            muteError: .configReadFailure(reason: "events is an array"),
            packSwitchError: .configReadFailure(reason: "master_volume is a string"),
            masterVolumeError: nil)
        expect(items.count == 2, "类型化原因仍须各自保留")
        for language in ClaudioAppLanguage.allCases {
            let visible = panelWriteFailureRows(
                items: items, l10n: ClaudioL10n(language: language))
            expect(
                visible.map(\.reason) == items.map(\.reason),
                "不同 typed reason 必须各自可见并保留写者顺序：\(language)")
            guard visible.count == 2 else { continue }
            expect(visible[0].message != visible[1].message, "两个写者的失败行须可区分")
            expect(
                visible[0].message.hasPrefix(
                    language == .zhHans ? "事件静音：" : "Event mute: ")
                    && visible[1].message.hasPrefix(
                        language == .zhHans ? "声音包选择：" : "Sound pack selection: "),
                "相同类别的失败应标明各自的写操作：\(language)")
            expect(
                visible.allSatisfy {
                    !$0.message.contains("events is an array")
                        && !$0.message.contains("master_volume is a string")
                },
                "展示标签不能泄露底层技术原因")
        }

        let published = panelWriteFailureItems(
            muteError: .configPublishedButFailed(
                reason: "first conflict", recoveryPath: recoveryA),
            packSwitchError: .configPublishedButFailed(
                reason: "second conflict", recoveryPath: recoveryB),
            masterVolumeError: nil)
        let visible = panelWriteFailureRows(
            items: published, l10n: ClaudioL10n(language: .english))
        expect(visible.count == 2, "两个不同的发布冲突必须各自可见")
        expect(
            panelWriteFailureRecoveryFiles(items: published, surfaceRecoveryFile: nil).map(\.path)
                == [recoveryA, recoveryB],
            "保留独立失败行时仍须呈现两个不同的恢复文件入口")
    }
}
