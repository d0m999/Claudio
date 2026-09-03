import ClaudioGUICore
import Foundation

@MainActor
func runLoginItemManagementSuites() {
    suite("Login item adapter：覆盖全部投影状态") {
        let states: [LoginItemRegistrationState] = [
            .disabled, .enabled, .requiresApproval, .unavailable,
        ]
        var state = states[0]
        let adapter = makeLoginItemServiceAdapter(
            status: { state },
            setEnabled: { _ in state })
        var projection = makeLoginItemSettingsProjection(registration: adapter.status())
        for projectedState in states {
            state = projectedState
            projection = makeLoginItemSettingsProjection(registration: adapter.status())
            expect(
                projection.registration == projectedState,
                "adapter 必须无损投影 \(projectedState)")
        }
        expect(
            LoginItemRegistrationState.enabled.isOn
                && LoginItemRegistrationState.requiresApproval.isOn
                && !LoginItemRegistrationState.disabled.isOn
                && !LoginItemRegistrationState.unavailable.canToggle,
            "等待批准必须保留已注册事实，不可用状态必须禁止虚假 toggle")
    }

    suite("Login item adapter：首次读取和刷新只投影系统事实") {
        var status = LoginItemRegistrationState.disabled
        var setCalls: [Bool] = []
        let adapter = makeLoginItemServiceAdapter(
            status: { status },
            setEnabled: { enabled in
                setCalls.append(enabled)
                return enabled ? .enabled : .disabled
            })
        var projection = makeLoginItemSettingsProjection(registration: adapter.status())

        expect(projection.registration == .disabled, "初始化必须只读未注册事实")
        expect(setCalls.isEmpty, "首次进入不得注册")
        status = .requiresApproval
        projection = makeLoginItemSettingsProjection(registration: adapter.status())
        expect(
            projection.registration == .requiresApproval
                && setCalls.isEmpty,
            "刷新必须投影等待批准且无副作用")
    }

    suite("Login item adapter：成功后采用返回事实，失败保留旧状态并可重试") {
        var shouldFail = true
        var calls: [Bool] = []
        let adapter = makeLoginItemServiceAdapter(
            status: { .disabled },
            setEnabled: { enabled in
                calls.append(enabled)
                if shouldFail {
                    throw LoginItemOperationFailureReason.systemRejected
                }
                return enabled ? .requiresApproval : .disabled
            })
        var projection = makeLoginItemSettingsProjection(registration: adapter.status())

        projection = projectLoginItemRequest(true, from: projection, using: adapter)
        expect(
            projection.registration == .disabled
                && projection.failure?.requestedEnabled == true
                && projection.failure?.reason == .systemRejected,
            "失败不得先翻转 toggle，必须保留可操作原因")
        shouldFail = false
        projection = projectLoginItemRequest(
            projection.failure?.requestedEnabled ?? false,
            from: makeLoginItemSettingsProjection(registration: projection.registration),
            using: adapter)
        expect(
            calls == [true, true]
                && projection.registration == .requiresApproval
                && projection.failure == nil,
            "重试成功后必须采用 adapter 返回的等待批准事实")
        projection = projectLoginItemRequest(false, from: projection, using: adapter)
        expect(
            calls == [true, true, false]
                && projection.registration == .disabled,
            "取消注册成功后才可投影关闭")
    }

    suite("Login item adapter：内嵌 helper 缺失错误保持原状态") {
        let adapter = makeLoginItemServiceAdapter(
            status: { .enabled },
            setEnabled: { _ in
                throw LoginItemOperationFailureReason.embeddedLoginItemMissing
            })
        var projection = makeLoginItemSettingsProjection(registration: adapter.status())
        projection = projectLoginItemRequest(false, from: projection, using: adapter)
        expect(
            projection.registration == .enabled
                && projection.failure?.reason == .embeddedLoginItemMissing,
            "损坏 bundle 不得伪装成已经关闭")
    }

    suite("Modern login item factory：注入调用覆盖注册、取消、恢复和错误") {
        let notRegisteredValue = 10
        let enabledValue = 20
        let requiresApprovalValue = 30
        let notFoundValue = 40
        var status = notRegisteredValue
        var registerCalls = 0
        var unregisterCalls = 0
        var shouldReject = false
        let adapter = makeModernLoginItemServiceAdapter(
            status: { status },
            notRegisteredValue: notRegisteredValue,
            enabledValue: enabledValue,
            requiresApprovalValue: requiresApprovalValue,
            notFoundValue: notFoundValue,
            register: {
                registerCalls += 1
                if shouldReject { throw LoginItemOperationFailureReason.systemRejected }
                status = requiresApprovalValue
            },
            unregister: {
                unregisterCalls += 1
                if shouldReject { throw LoginItemOperationFailureReason.systemRejected }
                status = notRegisteredValue
            })
        var projection = makeLoginItemSettingsProjection(registration: adapter.status())

        projection = projectLoginItemRequest(true, from: projection, using: adapter)
        expect(
            registerCalls == 1 && projection.registration == .requiresApproval,
            "modern register 成功后必须重读 requiresApproval 系统状态")
        shouldReject = true
        projection = projectLoginItemRequest(false, from: projection, using: adapter)
        expect(
            unregisterCalls == 1
                && projection.registration == .requiresApproval
                && projection.failure?.reason == .systemRejected,
            "modern unregister 错误必须保留先前系统状态")

        shouldReject = false
        projection = projectLoginItemRequest(
            projection.failure?.requestedEnabled ?? true,
            from: makeLoginItemSettingsProjection(registration: projection.registration),
            using: adapter)
        expect(
            unregisterCalls == 2 && projection.registration == .disabled,
            "modern unregister 重试成功后才可显示关闭")

        let projectedStatuses: [(Int, LoginItemRegistrationState)] = [
            (notRegisteredValue, .disabled),
            (enabledValue, .enabled),
            (requiresApprovalValue, .requiresApproval),
            (notFoundValue, .unavailable),
            (Int.max, .unavailable),
        ]
        for projectedStatus in projectedStatuses {
            status = projectedStatus.0
            projection = makeLoginItemSettingsProjection(registration: adapter.status())
            expect(
                projection.registration == projectedStatus.1,
                "modern factory 必须投影每个注入 raw status")
        }
    }

    suite("Legacy login item factory：只采用 launchd 注册事实并拒绝不一致结果") {
        withTempDirectory { root in
            let loginItem = writeValidLoginItemFixture(to: root)
            var registered: Bool? = false
            var setCalls: [(String, Bool)] = []
            var setterSucceeds = true
            var systemAppliesChange = true
            let adapter = makeLegacyLoginItemServiceAdapter(
                embeddedBundleURL: loginItem,
                registrationIsEnabled: { identifier in
                    expect(
                        identifier == claudioLegacyLoginItemBundleIdentifier,
                        "legacy 查询必须使用内嵌 helper identifier")
                    return registered
                },
                setEnabled: { identifier, enabled in
                    setCalls.append((identifier, enabled))
                    if setterSucceeds && systemAppliesChange { registered = enabled }
                    return setterSucceeds
                })
            var projection = makeLoginItemSettingsProjection(registration: adapter.status())

            expect(projection.registration == .disabled, "launchd 未注册必须显示关闭")
            projection = projectLoginItemRequest(true, from: projection, using: adapter)
            expect(
                setCalls.count == 1
                    && setCalls[0].0 == claudioLegacyLoginItemBundleIdentifier
                    && setCalls[0].1
                    && projection.registration == .enabled,
                "legacy 开启成功且系统查询一致后才可显示开启")

            setterSucceeds = false
            projection = projectLoginItemRequest(false, from: projection, using: adapter)
            expect(
                projection.registration == .enabled
                    && projection.failure?.reason == .systemRejected,
                "legacy 兼容 API 拒绝请求时必须保留旧状态")

            setterSucceeds = true
            systemAppliesChange = false
            projection = projectLoginItemRequest(
                projection.failure?.requestedEnabled ?? true,
                from: makeLoginItemSettingsProjection(registration: projection.registration),
                using: adapter)
            expect(
                setCalls.count == 3
                    && projection.registration == .enabled
                    && projection.failure?.reason == .systemRejected,
                "setter 返回成功但 launchd 仍是旧事实时必须失败关闭")

            registered = nil
            projection = projectLoginItemRequest(
                projection.failure?.requestedEnabled ?? true,
                from: makeLoginItemSettingsProjection(registration: projection.registration),
                using: adapter)
            expect(
                setCalls.count == 4
                    && projection.registration == .enabled
                    && projection.failure?.reason == .systemRejected,
                "setter 返回成功但 launchd 查询失败时必须保留旧状态")
            projection = makeLoginItemSettingsProjection(registration: adapter.status())
            expect(projection.registration == .unavailable, "查询失败必须显示不可用")
        }
    }

    suite("Production login item wiring：modern/legacy API 与 macOS 12 floor 完整") {
        let root = guiTestRepositoryRoot()
        let adapterURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUI/LoginItemServiceAdapter.swift")
        let packageURL = root.appendingPathComponent("gui/Package.swift")
        let helperURL = root.appendingPathComponent(
            "gui/Sources/ClaudioLoginItem/main.swift")
        guard let adapter = try? String(contentsOf: adapterURL, encoding: .utf8),
            let package = try? String(contentsOf: packageURL, encoding: .utf8),
            let helper = try? String(contentsOf: helperURL, encoding: .utf8)
        else {
            expect(false, "读不到 production LoginItem adapter、helper 或 Package.swift")
            return
        }

        expect(
            adapter.contains("SMAppService.mainApp")
                && adapter.contains("makeModernLoginItemServiceAdapter")
                && adapter.contains("register: { try service.register() }")
                && adapter.contains("unregister: { try service.unregister() }")
                && adapter.contains("SMAppService.openSystemSettingsLoginItems()")
                && adapter.contains("service.status.rawValue")
                && adapter.contains("SMAppService.Status.notRegistered.rawValue")
                && adapter.contains("SMAppService.Status.enabled.rawValue")
                && adapter.contains("SMAppService.Status.requiresApproval.rawValue")
                && adapter.contains("SMAppService.Status.notFound.rawValue"),
            "macOS 13+ 必须投影 mainApp 全状态并提供正确系统设置恢复动作")
        expect(
            adapter.contains("makeLegacyLoginItemServiceAdapter")
                && adapter.contains("SMLoginItemSetEnabled")
                && adapter.contains("SMCopyAllJobDictionaries(kSMDomainUserLaunchd)")
                && !adapter.contains("NSRunningApplication.runningApplications")
                && !adapter.contains("UserDefaults"),
            "macOS 12 必须通过兼容 API 写入并从 launchd 查询真实注册状态")
        expect(
            package.contains("platforms: [.macOS(.v12)]")
                && package.contains("name: \"ClaudioLoginItem\"")
                && helper.contains("NSWorkspace.shared.openApplication")
                && helper.contains("application.run()")
                && helper.contains("exit(error == nil ? EXIT_SUCCESS : EXIT_FAILURE)"),
            "最低版本必须保持 macOS 12，内嵌 helper 必须启动主 app 并在回调后退出")
    }

    suite("Settings 生命周期：从 Login Items 设置返回后刷新可见页面") {
        let root = guiTestRepositoryRoot()
        let controllerURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUI/SettingsWindowController.swift")
        guard let controller = try? String(contentsOf: controllerURL, encoding: .utf8) else {
            expect(false, "读不到 SettingsWindowController production wiring")
            return
        }
        let scanned = strippingComments(controller)
        let code = scanned.codeWithoutStringLiterals
        guard
            scanned.unmodeledConstructs.isEmpty,
            let keyHandler = bracedBlock(after: "func windowDidBecomeKey", in: code),
            let identityGuard = keyHandler.range(of: "keyWindow === window"),
            let refresh = keyHandler.range(of: "loginItemSettings.refresh()")
        else {
            expect(false, "必须能完整解析 Settings 重获 key 状态后的刷新接线")
            return
        }
        expect(
            identityGuard.lowerBound < refresh.lowerBound,
            "必须先确认单一 retained Settings window 重获 key 状态，再重读登录项系统事实")
    }

    suite("Login item 人工门禁：真实签名登录/重启与自动证据分离") {
        let root = guiTestRepositoryRoot()
        let distributionURL = root.appendingPathComponent("docs/distribution.md")
        guard let distribution = try? String(contentsOf: distributionURL, encoding: .utf8) else {
            expect(false, "读不到 distribution 人工验收记录")
            return
        }
        expect(
            distribution.contains("LoginItem 人工验收门禁")
                && distribution.contains("not_evaluated")
                && distribution.contains("ad-hoc")
                && distribution.contains("注销或重启"),
            "文档必须明确真实签名登录/重启仍待人工验证，不能由本地 ad-hoc 证据代替")
    }

    suite("Legacy LoginItem bundle validator：缺失和损坏必须失败关闭") {
        withTempDirectory { root in
            let loginItem = root.appendingPathComponent(claudioLegacyLoginItemBundleName)
            let contents = loginItem.appendingPathComponent("Contents", isDirectory: true)
            let executable =
                contents
                .appendingPathComponent("MacOS", isDirectory: true)
                .appendingPathComponent(claudioLegacyLoginItemExecutableName)
            let plist = contents.appendingPathComponent("Info.plist")

            expect(
                !embeddedLegacyLoginItemIsUsable(at: loginItem),
                "缺失 LoginItem 必须不可用")
            writeFixture("not a plist", to: plist)
            writeFixture("helper", to: executable)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path)
            expect(
                !embeddedLegacyLoginItemIsUsable(at: loginItem),
                "损坏 Info.plist 必须不可用")

            let validLoginItem = writeValidLoginItemFixture(
                to: root.appendingPathComponent("valid", isDirectory: true))
            expect(
                embeddedLegacyLoginItemIsUsable(at: validLoginItem),
                "正确 identifier、executable 和权限的内嵌 app 必须可用")
        }
    }
}

@MainActor
private func writeValidLoginItemFixture(to root: URL) -> URL {
    let loginItem = root.appendingPathComponent(
        claudioLegacyLoginItemBundleName,
        isDirectory: true)
    let contents = loginItem.appendingPathComponent("Contents", isDirectory: true)
    let executable =
        contents
        .appendingPathComponent("MacOS", isDirectory: true)
        .appendingPathComponent(claudioLegacyLoginItemExecutableName)
    let plist = contents.appendingPathComponent("Info.plist")
    writeFixture("helper", to: executable)
    try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: executable.path)
    let validPlist: [String: Any] = [
        "CFBundleIdentifier": claudioLegacyLoginItemBundleIdentifier,
        "CFBundleExecutable": claudioLegacyLoginItemExecutableName,
        "CFBundlePackageType": "APPL",
    ]
    let data = try? PropertyListSerialization.data(
        fromPropertyList: validPlist,
        format: .xml,
        options: 0)
    try? data?.write(to: plist)
    return loginItem
}

private func bracedBlock(after marker: String, in source: String) -> String? {
    guard let markerRange = source.range(of: marker),
        let openingBrace = source[markerRange.upperBound...].firstIndex(of: "{")
    else {
        return nil
    }
    var depth = 0
    var index = openingBrace
    while index < source.endIndex {
        switch source[index] {
        case "{":
            depth += 1
        case "}":
            depth -= 1
            if depth == 0 {
                return String(source[openingBrace...index])
            }
        default:
            break
        }
        index = source.index(after: index)
    }
    return nil
}
