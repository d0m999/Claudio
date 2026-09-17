import ClaudioCore
import ClaudioHookInput
import Foundation

@MainActor
func runWorkBuddyHookPayloadPolicySuites() {
    func input(_ value: String) -> HookInputReadResult {
        HookInputReadResult(status: .data, data: Data(value.utf8))
    }

    suite("WorkBuddy stdin：只为已实证新增 binding 要求有界输入") {
        expect(
            WorkBuddyHookPayloadPolicy.requiresValidation(nativeEvent: "SubagentStop"),
            "已接入的 SubagentStop 必须校验真实 payload")
        expect(
            !WorkBuddyHookPayloadPolicy.requiresValidation(nativeEvent: "Notification")
                && !WorkBuddyHookPayloadPolicy.requiresValidation(nativeEvent: "StopFailure"),
            "缺 Desktop 证据的两个事件不得进入生产输入链")
        expect(
            WorkBuddyHookPayloadPolicy.accepts(
                nativeEvent: "SubagentStop",
                input: input(#"{"hook_event_name":"SubagentStop","message":"private"}"#)),
            "真实子代理事件名足以通过最小输入契约")
    }

    suite("WorkBuddy stdin：缺失、错位、重复和超限事件名不得播放") {
        for value in [
            #"{}"#,
            #"{"hook_event_name":"Stop"}"#,
            #"{"hook_event_name":7}"#,
            #"{"hook_event_name":"SubagentStop","hook_event_name":"Stop"}"#,
            #"{"hook_event_name":"SubagentStop""#,
        ] {
            expect(
                !WorkBuddyHookPayloadPolicy.accepts(
                    nativeEvent: "SubagentStop", input: input(value)),
                "无效 hook_event_name 必须失败关闭")
        }
        expect(
            !WorkBuddyHookPayloadPolicy.accepts(
                nativeEvent: "SubagentStop",
                input: HookInputReadResult(status: .tooLarge, bytesRead: 65_537)),
            "超限 stdin 不得产生回执")
    }

    suite("WorkBuddy Notification 预备合同：只允许两类 matcher，拒绝 auth_success") {
        for kind in ["permission_prompt", "idle_prompt"] {
            expect(
                WorkBuddyHookPayloadPolicy.accepts(
                    nativeEvent: "Notification",
                    input: input(
                        #"{"hook_event_name":"Notification","notification_type":"\#(kind)","message":"private"}"#
                    )),
                "\(kind) 是唯一允许的通知类型之一")
        }
        for kind in ["auth_success", "elicitation_dialog", "other"] {
            expect(
                !WorkBuddyHookPayloadPolicy.accepts(
                    nativeEvent: "Notification",
                    input: input(
                        #"{"hook_event_name":"Notification","notification_type":"\#(kind)"}"#)),
                "\(kind) 不得播放")
        }
        expect(
            !WorkBuddyHookPayloadPolicy.accepts(
                nativeEvent: "Notification",
                input: input(
                    #"{"hook_event_name":"Notification","notification_type":"idle_prompt","notification_type":"auth_success"}"#
                )),
            "重复 notification_type 必须失败关闭")
    }
}
