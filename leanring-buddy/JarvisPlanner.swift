//
//  JarvisPlanner.swift
//  leanring-buddy
//
//  Planner contracts for turning user commands into structured Jarvis tool
//  calls. Phase 1 defines the boundary without invoking an LLM or tools.
//

import Foundation

struct JarvisPlanningContext {
    let availableTools: [JarvisToolDefinition]
    let shouldUseScreenContext: Bool
}

struct JarvisPlan: Equatable {
    let userCommand: String
    let toolCalls: [JarvisToolCall]
    let assistantMessage: String?

    static func empty(for userCommand: String, assistantMessage: String? = nil) -> JarvisPlan {
        JarvisPlan(userCommand: userCommand, toolCalls: [], assistantMessage: assistantMessage)
    }
}

@MainActor
protocol JarvisPlanner {
    func plan(userCommand: String, context: JarvisPlanningContext) async -> JarvisPlan
}

@MainActor
final class JarvisPhaseOnePlanner: JarvisPlanner {
    func plan(userCommand: String, context: JarvisPlanningContext) async -> JarvisPlan {
        JarvisPlan.empty(
            for: userCommand,
            assistantMessage: "Jarvis planning is scaffolded. Tool execution is not enabled yet."
        )
    }
}

@MainActor
final class JarvisRuleBasedPlanner: JarvisPlanner {
    func plan(userCommand: String, context: JarvisPlanningContext) async -> JarvisPlan {
        let trimmedUserCommand = userCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCommand = trimmedUserCommand.lowercased()

        if let searchQuery = searchQuery(from: trimmedUserCommand, normalizedCommand: normalizedCommand) {
            return JarvisPlan(
                userCommand: trimmedUserCommand,
                toolCalls: [
                    JarvisToolCall(
                        toolName: "open_app",
                        arguments: ["name": .string("Google Chrome")],
                        userVisibleSummary: "Open Google Chrome"
                    ),
                    JarvisToolCall(
                        toolName: "press_hotkey",
                        arguments: ["keys": .stringArray(["command", "l"])],
                        userVisibleSummary: "Focus address bar"
                    ),
                    JarvisToolCall(
                        toolName: "type_text",
                        arguments: ["text": .string(searchQuery)],
                        userVisibleSummary: "Type search query"
                    ),
                    JarvisToolCall(
                        toolName: "press_hotkey",
                        arguments: ["keys": .stringArray(["return"])],
                        userVisibleSummary: "Press Return"
                    )
                ],
                assistantMessage: "Searching for \(searchQuery)."
            )
        }

        if let appName = appNameToOpen(from: normalizedCommand) {
            return JarvisPlan(
                userCommand: trimmedUserCommand,
                toolCalls: [
                    JarvisToolCall(
                        toolName: "open_app",
                        arguments: ["name": .string(appName)],
                        userVisibleSummary: "Open \(appName)"
                    )
                ],
                assistantMessage: "Opening \(appName)."
            )
        }

        if normalizedCommand.hasPrefix("type ") {
            let textToType = String(trimmedUserCommand.dropFirst("type ".count))
            return JarvisPlan(
                userCommand: trimmedUserCommand,
                toolCalls: [
                    JarvisToolCall(
                        toolName: "type_text",
                        arguments: ["text": .string(textToType)],
                        userVisibleSummary: "Type text"
                    )
                ],
                assistantMessage: "Typing that text."
            )
        }

        if let hotkeyNames = hotkeyNames(from: normalizedCommand) {
            return JarvisPlan(
                userCommand: trimmedUserCommand,
                toolCalls: [
                    JarvisToolCall(
                        toolName: "press_hotkey",
                        arguments: ["keys": .stringArray(hotkeyNames)],
                        userVisibleSummary: "Press \(hotkeyNames.joined(separator: " + "))"
                    )
                ],
                assistantMessage: "Pressing \(hotkeyNames.joined(separator: " + "))."
            )
        }

        if normalizedCommand == "screenshot" || normalizedCommand == "take screenshot" || normalizedCommand == "take a screenshot" {
            return JarvisPlan(
                userCommand: trimmedUserCommand,
                toolCalls: [
                    JarvisToolCall(
                        toolName: "take_screenshot",
                        userVisibleSummary: "Take a screenshot"
                    )
                ],
                assistantMessage: "Taking a screenshot."
            )
        }

        return JarvisPlan.empty(
            for: trimmedUserCommand,
            assistantMessage: "I can handle: open Chrome, open Safari, type text, press Command Space, search for something, or take a screenshot."
        )
    }

    private func appNameToOpen(from normalizedCommand: String) -> String? {
        let prefixes = ["open ", "launch ", "start "]

        guard let matchedPrefix = prefixes.first(where: { normalizedCommand.hasPrefix($0) }) else {
            return nil
        }

        let rawAppName = normalizedCommand.dropFirst(matchedPrefix.count).trimmingCharacters(in: .whitespacesAndNewlines)

        switch rawAppName {
        case "chrome", "google chrome":
            return "Google Chrome"
        case "safari":
            return "Safari"
        case "finder":
            return "Finder"
        case "terminal":
            return "Terminal"
        case "notes":
            return "Notes"
        case "messages":
            return "Messages"
        default:
            guard !rawAppName.isEmpty else { return nil }
            return rawAppName
                .split(separator: " ")
                .map { word in word.prefix(1).uppercased() + word.dropFirst() }
                .joined(separator: " ")
        }
    }

    private func hotkeyNames(from normalizedCommand: String) -> [String]? {
        let prefixes = ["press ", "hit "]

        guard let matchedPrefix = prefixes.first(where: { normalizedCommand.hasPrefix($0) }) else {
            return nil
        }

        let rawHotkey = normalizedCommand
            .dropFirst(matchedPrefix.count)
            .replacingOccurrences(of: " + ", with: " ")
            .replacingOccurrences(of: "+", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let keyNames = rawHotkey
            .split(separator: " ")
            .map { String($0) }

        return keyNames.isEmpty ? nil : keyNames
    }

    private func searchQuery(from userCommand: String, normalizedCommand: String) -> String? {
        let prefixes = [
            "search for ",
            "google ",
            "look up ",
            "open chrome and search for ",
            "open google chrome and search for "
        ]

        guard let matchedPrefix = prefixes.first(where: { normalizedCommand.hasPrefix($0) }) else {
            return nil
        }

        let searchQuery = String(userCommand.dropFirst(matchedPrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return searchQuery.isEmpty ? nil : searchQuery
    }
}
