import ClaudioGUICore
import Foundation

@MainActor
func runDynamicQuietPolicySuites() {
    suite("Dynamic Quiet refresh timer：common mode 在事件跟踪期间仍执行") {
        let trackingMode = RunLoop.Mode("DynamicQuietEventTrackingTestMode")
        CFRunLoopAddCommonMode(
            CFRunLoopGetMain(),
            CFRunLoopMode(rawValue: trackingMode.rawValue as CFString))
        let fireState = DynamicQuietTimerFireState()
        let refreshTimer = Timer(timeInterval: 0.01, repeats: false) { _ in
            MainActor.assumeIsolated {
                fireState.didFire = true
            }
        }
        let scheduledTimer = scheduleDynamicQuietRefreshTimer(refreshTimer)
        let deadline = Date().addingTimeInterval(0.5)
        repeat {
            _ = RunLoop.main.run(mode: trackingMode, before: deadline)
        } while !fireState.didFire && Date() < deadline
        scheduledTimer.invalidate()

        expect(
            fireState.didFire,
            "common-mode refresh timer 必须在事件跟踪 mode 中执行")
    }

    suite("Dynamic Quiet policy：两项默认关闭且只有对应显式 toggle-on 请求权限") {
        withTemporaryDynamicQuietDefaults { defaults in
            let focus = FocusQuietSystemBox(
                FocusQuietSystemState(authorization: .notRequested, isFocused: nil))
            let calendar = CalendarQuietSystemBox(
                CalendarQuietSystemState(authorization: .notRequested, events: nil))
            var focusRequests = 0
            var calendarRequests = 0
            var calendarReadModes: [Bool] = []
            var publications: [(Bool, Bool)] = []
            let controller = DynamicQuietPolicyController(
                defaults: defaults,
                readFocusState: { focus.state },
                requestFocusAuthorization: { completion in
                    focusRequests += 1
                    focus.state = FocusQuietSystemState(
                        authorization: .authorized,
                        isFocused: true)
                    completion(focus.state)
                },
                readCalendarState: { includeEvents in
                    calendarReadModes.append(includeEvents)
                    return calendar.state
                },
                requestCalendarAuthorization: { completion in
                    calendarRequests += 1
                    calendar.state = CalendarQuietSystemState(
                        authorization: .authorized,
                        events: [])
                    completion(calendar.state)
                },
                publish: { focusActive, calendarBusy, now in
                    publications.append((focusActive, calendarBusy))
                    return now.addingTimeInterval(12)
                },
                now: { Date(timeIntervalSince1970: 1_000) })

            expect(!controller.presentation.focusIsEnabled, "Focus 策略必须默认关闭")
            expect(!controller.presentation.calendarIsEnabled, "Calendar 策略必须默认关闭")
            expect(focusRequests == 0 && calendarRequests == 0, "初始化不得请求任何权限")
            expect(calendarReadModes == [false], "默认关闭时不得读取 Calendar 事件")

            controller.setFocusEnabled(true)
            expect(focusRequests == 1 && calendarRequests == 0, "Focus toggle 只能请求 Focus")
            expect(controller.presentation.currentReason == .focusActive, "Focus active 必须生效")
            expect(publications.last?.0 == true && publications.last?.1 == false, "只发布 Focus")

            controller.setCalendarEnabled(true)
            expect(focusRequests == 1 && calendarRequests == 1, "Calendar toggle 只能请求 Calendar")
            expect(calendarReadModes.last == true, "启用后才允许读取 Calendar 事件")
            expect(
                defaults.bool(forKey: DynamicQuietPolicyController.focusDefaultsKey)
                    && defaults.bool(forKey: DynamicQuietPolicyController.calendarDefaultsKey),
                "两项偏好必须使用独立 typed key 持久化")

            controller.setCalendarEnabled(false)
            expect(calendarReadModes.last == false, "关闭 Calendar 策略必须立即停止读取事件")
            expect(publications.last?.1 == false, "关闭策略必须立即清理 Calendar 原因")
        }
    }

    suite("Calendar EventKit seam：跨版本授权与 current-event query 可结果级注入") {
        let clock = DynamicQuietDateBox(Date(timeIntervalSince1970: 1_500))
        let access = CalendarQuietAccessBox(.fullAccess)
        let queries = CalendarQuietQueryBox()
        let currentBusyEvent = CalendarQuietEventFacts(
            startsAt: clock.value.addingTimeInterval(-300),
            endsAt: clock.value.addingTimeInterval(300),
            isAllDay: false,
            availability: .busy)
        let fullAccessAdapter = CalendarQuietEventAdapter(
            accessRequirement: .fullAccess,
            readAccessStatus: { access.value },
            readEvents: { query in
                queries.values.append(query)
                return [currentBusyEvent]
            },
            now: { clock.value })

        let fullAccessState = fullAccessAdapter.systemState(includeEvents: true)
        expect(fullAccessState.authorization == .authorized, "macOS 14 fullAccess 必须可读")
        expect(fullAccessState.events == [currentBusyEvent], "adapter 必须返回 privacy-safe facts")
        expect(
            queries.values == [
                CalendarQuietEventQuery(
                    startsAt: clock.value,
                    endsAt: clock.value.addingTimeInterval(1))
            ],
            "EventKit predicate 必须严格查询 [now, now+1)")
        expect(
            calendarQuietIsBusy(events: fullAccessState.events ?? [], at: clock.value),
            "跨越 now 的当前 busy 事件必须经 adapter 进入 reducer")

        access.value = .authorized
        expect(
            fullAccessAdapter.systemState(includeEvents: true).authorization == .denied,
            "macOS 14 旧 authorized 状态不得冒充 full access")
        access.value = .denied
        expect(
            fullAccessAdapter.systemState(includeEvents: true).authorization == .denied,
            "denied 必须如实 fail closed")
        access.value = .restricted
        expect(
            fullAccessAdapter.systemState(includeEvents: true).authorization == .restricted,
            "restricted 必须与 denied 分开呈现")
        expect(queries.values.count == 1, "无读取权限时不得触碰事件 query")

        access.value = .authorized
        let legacyAdapter = CalendarQuietEventAdapter(
            accessRequirement: .legacyRead,
            readAccessStatus: { access.value },
            readEvents: { query in
                queries.values.append(query)
                return [currentBusyEvent]
            },
            now: { clock.value })
        expect(
            legacyAdapter.systemState(includeEvents: false)
                == CalendarQuietSystemState(authorization: .authorized, events: []),
            "macOS 12-13 authorized 必须可读，但策略关闭时不得运行 query")
        expect(queries.values.count == 1, "includeEvents=false 必须保留授权状态但跳过读取")

        expect(
            calendarQuietAuthorization(accessStatus: .notDetermined, requirement: .fullAccess)
                == .notRequested
                && calendarQuietAuthorization(accessStatus: .writeOnly, requirement: .fullAccess)
                    == .denied
                && calendarQuietAuthorization(accessStatus: .fullAccess, requirement: .legacyRead)
                    == .denied,
            "未请求、write-only 与跨版本不匹配状态必须确定性 fail closed")
    }

    suite("Calendar busy reducer：半开时间边界、全天和非 busy 确定性 fail safe") {
        let start = Date(timeIntervalSince1970: 2_000)
        let end = Date(timeIntervalSince1970: 2_100)
        let busy = CalendarQuietEventFacts(
            startsAt: start,
            endsAt: end,
            isAllDay: false,
            availability: .busy)
        expect(calendarQuietIsBusy(events: [busy], at: start), "事件开始瞬间必须进入 busy")
        expect(
            calendarQuietIsBusy(events: [busy], at: end.addingTimeInterval(-0.001)),
            "结束前必须保持 busy")
        expect(!calendarQuietIsBusy(events: [busy], at: end), "事件结束瞬间必须恢复")
        expect(
            !calendarQuietIsBusy(
                events: [
                    CalendarQuietEventFacts(
                        startsAt: start,
                        endsAt: end,
                        isAllDay: true,
                        availability: .busy),
                    CalendarQuietEventFacts(
                        startsAt: start,
                        endsAt: end,
                        isAllDay: false,
                        availability: .free),
                    CalendarQuietEventFacts(
                        startsAt: end,
                        endsAt: start,
                        isAllDay: false,
                        availability: .busy),
                ],
                at: start),
            "全天、free 与倒置区间都不得制造静默")

        let labels = Set(Mirror(reflecting: busy).children.compactMap(\.label))
        expect(
            labels == ["startsAt", "endsAt", "isAllDay", "availability"],
            "Calendar seam 必须在类型层排除标题、位置、URL、参与人、正文与 Calendar 身份")
    }

    suite("Dynamic Quiet reducer：Focus、Calendar 与组合原因共用一次 publication") {
        withTemporaryDynamicQuietDefaults { defaults in
            defaults.set(true, forKey: DynamicQuietPolicyController.focusDefaultsKey)
            defaults.set(true, forKey: DynamicQuietPolicyController.calendarDefaultsKey)
            let now = Date(timeIntervalSince1970: 3_000)
            let focus = FocusQuietSystemBox(
                FocusQuietSystemState(authorization: .authorized, isFocused: true))
            let calendar = CalendarQuietSystemBox(
                CalendarQuietSystemState(
                    authorization: .authorized,
                    events: [
                        CalendarQuietEventFacts(
                            startsAt: now.addingTimeInterval(-10),
                            endsAt: now.addingTimeInterval(10),
                            isAllDay: false,
                            availability: .busy)
                    ]))
            var publications: [(Bool, Bool)] = []
            let controller = makeDynamicQuietController(
                defaults: defaults,
                focus: focus,
                calendar: calendar,
                publish: { focusActive, calendarBusy, publicationDate in
                    publications.append((focusActive, calendarBusy))
                    return publicationDate.addingTimeInterval(12)
                },
                now: { now })

            expect(
                controller.presentation.currentReason == .focusAndCalendarBusy,
                "两个有效原因必须投影组合状态")
            expect(
                publications.count == 1 && publications[0].0 && publications[0].1,
                "组合原因必须通过一次 publication 一起发布")

            calendar.state = CalendarQuietSystemState(
                authorization: .authorized,
                events: nil)
            controller.refresh()
            expect(controller.presentation.currentReason == .focusActive, "有效 Focus 仍须如实投影")
            expect(controller.presentation.hasObserverFailure, "Calendar observer failure 必须独立可见")
            expect(publications.last?.0 == true && publications.last?.1 == false, "故障原因 fail safe")

            focus.state = FocusQuietSystemState(authorization: .authorized, isFocused: false)
            controller.refresh()
            expect(
                controller.presentation.currentReason == .observerFailure,
                "没有有效原因时 observer failure 必须成为当前状态")

            calendar.state = CalendarQuietSystemState(authorization: .denied, events: nil)
            controller.refresh()
            expect(
                controller.presentation.currentReason == .permissionRequired,
                "撤权不得伪装成功或继续 Calendar 静默")
            expect(publications.last?.0 == false && publications.last?.1 == false, "撤权发布 false")
        }
    }

    suite("Dynamic Quiet snapshot health：失败在短 TTL 内可见，过期后明确恢复") {
        withTemporaryDynamicQuietDefaults { defaults in
            defaults.set(true, forKey: DynamicQuietPolicyController.focusDefaultsKey)
            let focus = FocusQuietSystemBox(
                FocusQuietSystemState(authorization: .authorized, isFocused: true))
            let calendar = CalendarQuietSystemBox(
                CalendarQuietSystemState(authorization: .authorized, events: []))
            let clock = DynamicQuietDateBox(Date(timeIntervalSince1970: 4_000))
            let publicationExpiry = DynamicQuietOptionalDateBox(
                Date(timeIntervalSince1970: 4_007))
            let controller = makeDynamicQuietController(
                defaults: defaults,
                focus: focus,
                calendar: calendar,
                publish: { _, _, _ in publicationExpiry.value },
                now: { clock.value })
            expect(controller.presentation.snapshotHealth == .current, "首个成功快照必须 current")

            publicationExpiry.value = nil
            clock.value = Date(timeIntervalSince1970: 4_005)
            controller.refresh()
            expect(
                controller.presentation.snapshotHealth == .publicationFailed,
                "旧快照仍在短 TTL 内时必须显示 publication failure")

            clock.value = Date(timeIntervalSince1970: 4_007)
            controller.refresh()
            expect(
                controller.presentation.snapshotHealth == .expired,
                "UI health 必须使用 publisher 返回的真实 expiry，而非另算固定 TTL")
        }
    }

    suite("Notifications wiring：单一组合 owner、跨版本 EventKit 与 privacy boundary") {
        guard
            let view = dynamicQuietSource("gui/Sources/ClaudioGUI/SettingsWindowView.swift"),
            let owner = dynamicQuietSource(
                "gui/Sources/ClaudioGUI/DynamicQuietSystemObserver.swift"),
            let settingsController = dynamicQuietSource(
                "gui/Sources/ClaudioGUI/SettingsWindowController.swift"),
            let preview = dynamicQuietSource(
                "gui/Sources/ClaudioGUIComponents/AudioPreviewPlayer.swift"),
            let play = dynamicQuietSource("helper/Sources/ClaudioCore/Play.swift"),
            let devBundle = dynamicQuietSource("scripts/dev-bundle.sh"),
            let release = dynamicQuietSource(".github/workflows/release.yml"),
            let englishPrivacy = dynamicQuietSource(
                "gui/AppResources/en.lproj/InfoPlist.strings"),
            let chinesePrivacy = dynamicQuietSource(
                "gui/AppResources/zh-Hans.lproj/InfoPlist.strings")
        else {
            expect(false, "缺少 Dynamic Quiet production wiring 源文件")
            return
        }

        expect(
            view.contains("settings.notifications.focus-toggle")
                && view.contains("dynamicQuietPolicy.setFocusEnabled($0)")
                && view.contains("settings.notifications.calendar-toggle")
                && view.contains("dynamicQuietPolicy.setCalendarEnabled($0)")
                && view.contains("settings.notifications.calendar-privacy")
                && view.contains("Privacy_Calendars")
                && !view.contains("ForEach(Event.allCases)"),
            "通知页必须提供两条策略与 Calendar 恢复动作，不得复制 Event 开关")
        expect(
            settingsController.contains("private let dynamicQuietObserver")
                && settingsController.contains("DynamicQuietSystemObserver()")
                && owner.contains("DynamicQuietSnapshotPublisher(")
                && owner.components(separatedBy: "DynamicQuietSnapshotPublisher(").count - 1 == 1,
            "Focus 与 Calendar 必须共用一个 app-lifetime owner 和 publisher")
        expect(
            owner.contains("requestFullAccessToEvents")
                && owner.contains("requestAccess(to: .event)")
                && owner.contains("if #available(macOS 14.0, *)")
                && owner.contains("CalendarQuietEventAdapter(")
                && owner.contains("withStart: query.startsAt")
                && owner.contains("end: query.endsAt"),
            "macOS 14+ 与 12–13 必须走各自 EventKit 授权 adapter")
        expect(
            owner.contains("EKEventStoreChanged")
                && owner.contains("NSWorkspace.didWakeNotification")
                && owner.contains("NSSystemTimeZoneDidChange")
                && owner.contains("NSApplication.didBecomeActiveNotification")
                && owner.contains("let refreshTimer = Timer(")
                && owner.contains("timer = scheduleDynamicQuietRefreshTimer(refreshTimer)")
                && !owner.contains("Timer.scheduledTimer("),
            "Calendar change、唤醒、时区、activation 与 common-mode 周期必须持续刷新短 TTL")
        for forbidden in [
            "event.title", "event.location", "event.url", "event.attendees", "event.notes",
            "event.calendar",
        ] {
            expect(!owner.contains(forbidden), "EventKit adapter 不得读取私人字段 \(forbidden)")
        }
        expect(
            play.contains("dynamicQuietDecision(environment:")
                && !preview.contains("DynamicQuiet")
                && !preview.contains("dynamicQuiet"),
            "Dynamic Quiet 只能进入 automatic playback，manual preview 保持独立")
        expect(
            devBundle.contains("NSCalendarsUsageDescription")
                && devBundle.contains("NSCalendarsFullAccessUsageDescription")
                && release.contains("NSCalendarsUsageDescription")
                && release.contains("NSCalendarsFullAccessUsageDescription")
                && devBundle.contains("gui/AppResources/en.lproj")
                && devBundle.contains("gui/AppResources/zh-Hans.lproj")
                && release.contains("gui/AppResources/en.lproj")
                && release.contains("gui/AppResources/zh-Hans.lproj"),
            "开发与发布 bundle 必须声明 Calendar 用途并复制双语 privacy 资源")
        expect(
            englishPrivacy.contains("NSCalendarsUsageDescription")
                && englishPrivacy.contains("NSCalendarsFullAccessUsageDescription")
                && chinesePrivacy.contains("NSCalendarsUsageDescription")
                && chinesePrivacy.contains("NSCalendarsFullAccessUsageDescription"),
            "两条 Calendar usage description 必须同时提供 en 与 zh-Hans")
    }
}

@MainActor
private func makeDynamicQuietController(
    defaults: UserDefaults,
    focus: FocusQuietSystemBox,
    calendar: CalendarQuietSystemBox,
    publish: @escaping @MainActor (Bool, Bool, Date) -> Date?,
    now: @escaping @MainActor () -> Date
) -> DynamicQuietPolicyController {
    DynamicQuietPolicyController(
        defaults: defaults,
        readFocusState: { focus.state },
        requestFocusAuthorization: { _ in },
        readCalendarState: { _ in calendar.state },
        requestCalendarAuthorization: { _ in },
        publish: publish,
        now: now)
}

@MainActor
private func withTemporaryDynamicQuietDefaults(_ body: (UserDefaults) -> Void) {
    let suiteName = "DynamicQuietPolicySuite.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    body(defaults)
}

private func dynamicQuietSource(_ relativePath: String) -> String? {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
}

@MainActor
private final class FocusQuietSystemBox {
    var state: FocusQuietSystemState

    init(_ state: FocusQuietSystemState) {
        self.state = state
    }
}

@MainActor
private final class CalendarQuietSystemBox {
    var state: CalendarQuietSystemState

    init(_ state: CalendarQuietSystemState) {
        self.state = state
    }
}

@MainActor
private final class DynamicQuietDateBox {
    var value: Date

    init(_ value: Date) {
        self.value = value
    }
}

@MainActor
private final class DynamicQuietOptionalDateBox {
    var value: Date?

    init(_ value: Date?) {
        self.value = value
    }
}

@MainActor
private final class DynamicQuietTimerFireState {
    var didFire = false
}

@MainActor
private final class CalendarQuietAccessBox {
    var value: CalendarQuietAccessStatus

    init(_ value: CalendarQuietAccessStatus) {
        self.value = value
    }
}

@MainActor
private final class CalendarQuietQueryBox {
    var values: [CalendarQuietEventQuery] = []
}
