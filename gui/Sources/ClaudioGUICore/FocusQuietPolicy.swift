import Combine
import Foundation

public enum FocusQuietAuthorization: String, Sendable, Equatable {
    case notRequested = "not_requested"
    case authorized
    case denied
    case restricted
}

/// `isFocused == nil` while authorized is an observer failure, not "Focus inactive".
public struct FocusQuietSystemState: Sendable, Equatable {
    public let authorization: FocusQuietAuthorization
    public let isFocused: Bool?

    public init(authorization: FocusQuietAuthorization, isFocused: Bool?) {
        self.authorization = authorization
        self.isFocused = isFocused
    }
}

public enum FocusQuietCurrentReason: String, Sendable, Equatable {
    case policyDisabled = "policy_disabled"
    case permissionRequired = "permission_required"
    case noDynamicQuiet = "no_dynamic_quiet"
    case focusActive = "focus_active"
    case observerFailure = "observer_failure"
}

public struct FocusQuietPresentation: Sendable, Equatable {
    public let isEnabled: Bool
    public let authorization: FocusQuietAuthorization
    public let currentReason: FocusQuietCurrentReason
    public let publicationFailed: Bool

    public init(
        isEnabled: Bool,
        authorization: FocusQuietAuthorization,
        currentReason: FocusQuietCurrentReason,
        publicationFailed: Bool
    ) {
        self.isEnabled = isEnabled
        self.authorization = authorization
        self.currentReason = currentReason
        self.publicationFailed = publicationFailed
    }
}

/// App-lifetime Focus 策略 owner 的 Foundation-only seam。系统 adapter 只提供当前授权/布尔状态；
/// 本类型决定何时请求权限、何时发布 false 清理旧状态，以及 observer failure 如何可见化。
@MainActor
public final class FocusQuietPolicyController: ObservableObject {
    public static let defaultsKey = "Claudio.Notifications.FocusQuietEnabled"

    @Published public private(set) var presentation: FocusQuietPresentation

    private let defaults: UserDefaults
    private let readSystemState: @MainActor () -> FocusQuietSystemState
    private let requestAuthorization:
        @MainActor (@escaping @MainActor (FocusQuietSystemState) -> Void) -> Void
    private let publish: @MainActor (Bool, Date) -> Bool
    private let now: @MainActor () -> Date

    public init(
        defaults: UserDefaults,
        readSystemState: @escaping @MainActor () -> FocusQuietSystemState,
        requestAuthorization:
            @escaping @MainActor (
                @escaping @MainActor (FocusQuietSystemState) -> Void
            ) -> Void,
        publish: @escaping @MainActor (Bool, Date) -> Bool,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.readSystemState = readSystemState
        self.requestAuthorization = requestAuthorization
        self.publish = publish
        self.now = now

        let enabled = defaults.object(forKey: Self.defaultsKey) as? Bool ?? false
        let systemState = readSystemState()
        presentation = FocusQuietPresentation(
            isEnabled: enabled,
            authorization: systemState.authorization,
            currentReason: .policyDisabled,
            publicationFailed: false)
        apply(systemState, enabled: enabled)
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled != presentation.isEnabled else { return }
        defaults.set(enabled, forKey: Self.defaultsKey)
        let systemState = readSystemState()
        apply(systemState, enabled: enabled)

        // 唯一授权请求点：用户刚刚显式把策略从 off 切到 on，且系统仍是未请求。
        guard enabled, systemState.authorization == .notRequested else { return }
        requestAuthorization { [weak self] authorizedState in
            guard let self, self.presentation.isEnabled else { return }
            self.apply(authorizedState, enabled: true)
        }
    }

    /// 由 app-lifetime system observer 的周期与 app activation 触发；页面切换/窗口关闭不参与。
    public func refresh() {
        apply(readSystemState(), enabled: presentation.isEnabled)
    }

    private func apply(_ state: FocusQuietSystemState, enabled: Bool) {
        let focusActive: Bool
        let reason: FocusQuietCurrentReason
        if !enabled {
            focusActive = false
            reason = .policyDisabled
        } else {
            switch state.authorization {
            case .notRequested, .denied, .restricted:
                focusActive = false
                reason = .permissionRequired
            case .authorized:
                if let isFocused = state.isFocused {
                    focusActive = isFocused
                    reason = isFocused ? .focusActive : .noDynamicQuiet
                } else {
                    focusActive = false
                    reason = .observerFailure
                }
            }
        }

        let published = publish(focusActive, now())
        presentation = FocusQuietPresentation(
            isEnabled: enabled,
            authorization: state.authorization,
            currentReason: reason,
            publicationFailed: !published)
    }
}
