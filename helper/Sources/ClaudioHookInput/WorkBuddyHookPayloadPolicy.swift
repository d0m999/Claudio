import ClaudioCore
import Foundation

/// New WorkBuddy bindings require the native event identity from one bounded stdin frame before
/// playback or receipt creation. Only the two allowlisted Notification types can become audible.
/// No message, prompt, response, or API error field is accessed or retained.
public enum WorkBuddyHookPayloadPolicy {
    private static func isCandidateEvent(_ nativeEvent: String) -> Bool {
        switch nativeEvent {
        case "SubagentStop", "Notification", "StopFailure": true
        default: false
        }
    }

    public static func requiresValidation(nativeEvent: String) -> Bool {
        guard HostCapabilityCatalog.binding(host: .workBuddy, nativeEvent: nativeEvent) != nil
        else {
            return false
        }
        return isCandidateEvent(nativeEvent)
    }

    public static func accepts(nativeEvent: String, input: HookInputReadResult?) -> Bool {
        guard isCandidateEvent(nativeEvent) else { return true }
        guard let input, input.status == .data, let data = input.data,
            !data.isEmpty, data.count <= HookInputReader.defaultMaximumBytes,
            HostEventSourceParser.duplicateTopLevelKeys(data)
                .isDisjoint(with: ["hook_event_name", "notification_type"]),
            let dictionary = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            (dictionary["hook_event_name"] as? String) == nativeEvent
        else { return false }
        if nativeEvent == "Notification" {
            guard let kind = dictionary["notification_type"] as? String else { return false }
            return kind == "permission_prompt" || kind == "idle_prompt"
        }
        return true
    }
}
