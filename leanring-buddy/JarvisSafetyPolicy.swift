//
//  JarvisSafetyPolicy.swift
//  leanring-buddy
//
//  Central place for deciding whether planned Jarvis actions can run
//  immediately or must ask the user first.
//

import Foundation

enum JarvisSafetyDecision: Equatable {
    case allow
    case requireConfirmation(reason: String)
    case block(reason: String)
}

struct JarvisSafetyPolicy {
    private let confirmationRequiredToolNames: Set<String> = [
        "delete_file",
        "move_file",
        "overwrite_file",
        "send_message",
        "submit_form",
        "purchase",
        "confirm_click_at",
        "confirm_hotkey",
        "run_terminal_command",
        "install_software",
        "change_system_setting",
        "share_private_information"
    ]

    private let allowedToolNames: Set<String> = [
        "take_screenshot",
        "open_app",
        "type_text",
        "press_hotkey",
        "click_at",
        "double_click",
        "right_click",
        "drag",
        "move_mouse",
        "scroll",
        "wait",
        "get_active_app",
        "search_files",
        "open_file",
        "read_text_file",
        "browser_open_url",
        "browser_search"
    ]

    func evaluate(toolCall: JarvisToolCall, toolDefinition: JarvisToolDefinition?) -> JarvisSafetyDecision {
        if confirmationRequiredToolNames.contains(toolCall.toolName) {
            return .requireConfirmation(reason: "This action can change data, send information, or affect system state.")
        }

        if toolDefinition?.defaultRequiresConfirmation == true {
            return .requireConfirmation(reason: "This tool is configured to ask before running.")
        }

        if allowedToolNames.contains(toolCall.toolName) {
            return .allow
        }

        return .block(reason: "Jarvis does not know this tool yet.")
    }
}
