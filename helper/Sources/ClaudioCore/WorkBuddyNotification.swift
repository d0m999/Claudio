/// Desktop 回调已证明的通知范围。配置 matcher 与 stdin 校验共用这一事实。
public enum WorkBuddyNotification {
    private enum Subtype: String, CaseIterable {
        case permissionPrompt = "permission_prompt"
        case idlePrompt = "idle_prompt"

        var noticeReason: HostEventNoticeReason {
            switch self {
            case .permissionPrompt: .permission
            case .idlePrompt: .informational
            }
        }
    }

    public static let subtypes = Subtype.allCases.map(\.rawValue)

    static func noticeReason(for rawValue: String?) -> HostEventNoticeReason? {
        guard let rawValue, let subtype = Subtype(rawValue: rawValue) else { return nil }
        return subtype.noticeReason
    }
}
