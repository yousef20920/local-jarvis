//
//  JarvisPlanner.swift
//  leanring-buddy
//
//  Planner contracts for turning user commands into structured Jarvis tool
//  calls. Phase 1 defines the boundary without invoking a model or tools.
//

import Foundation

struct JarvisPlanningContext {
    let availableTools: [JarvisToolDefinition]
    let shouldUseScreenContext: Bool
    let screenContext: JarvisScreenContext?
    let completedToolResults: [JarvisToolResultRecord]
}

struct JarvisScreenContext: Equatable {
    let targetDescription: String
    let globalX: Double
    let globalY: Double
    let displayFrameX: Double
    let displayFrameY: Double
    let displayFrameWidth: Double
    let displayFrameHeight: Double
}

struct JarvisPlan: Equatable {
    let userCommand: String
    let toolCalls: [JarvisToolCall]
    let assistantMessage: String?

    static func empty(for userCommand: String, assistantMessage: String? = nil) -> JarvisPlan {
        JarvisPlan(userCommand: userCommand, toolCalls: [], assistantMessage: assistantMessage)
    }
}

struct JarvisToolResultRecord: Equatable {
    let toolCall: JarvisToolCall
    let result: JarvisToolResult
}

@MainActor
protocol JarvisPlanner {
    func plan(userCommand: String, context: JarvisPlanningContext) async -> JarvisPlan

    func continuationToolCalls(
        after resultRecord: JarvisToolResultRecord,
        currentWorkflow: JarvisWorkflowState,
        context: JarvisPlanningContext
    ) async -> [JarvisToolCall]
}

extension JarvisPlanner {
    func continuationToolCalls(
        after resultRecord: JarvisToolResultRecord,
        currentWorkflow: JarvisWorkflowState,
        context: JarvisPlanningContext
    ) async -> [JarvisToolCall] {
        []
    }
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
        let rawTrimmedUserCommand = userCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUserCommand = Self.stripContinuationPrefix(from: rawTrimmedUserCommand)
        let normalizedCommand = trimmedUserCommand.lowercased()

        if let clickTargetDescription = clickTargetDescription(from: trimmedUserCommand, normalizedCommand: normalizedCommand) {
            guard let screenContext = context.screenContext else {
                return JarvisPlan.empty(
                    for: trimmedUserCommand,
                    assistantMessage: "I need screen context before I can click \(clickTargetDescription)."
                )
            }

            return JarvisPlan(
                userCommand: trimmedUserCommand,
                toolCalls: [
                    JarvisToolCall(
                        toolName: "click_at",
                        arguments: [
                            "x": .number(screenContext.globalX),
                            "y": .number(screenContext.globalY),
                            "display_frame_x": .number(screenContext.displayFrameX),
                            "display_frame_y": .number(screenContext.displayFrameY),
                            "display_frame_width": .number(screenContext.displayFrameWidth),
                            "display_frame_height": .number(screenContext.displayFrameHeight),
                            "label": .string(screenContext.targetDescription)
                        ],
                        userVisibleSummary: "Click \(screenContext.targetDescription)"
                    )
                ],
                assistantMessage: "Clicking \(screenContext.targetDescription)."
            )
        }

        // "open apple.com and look for MacBook Pro" — instant keyboard path,
        // no vision model calls (~2s vs minutes in the agent loop).
        if let compoundBrowserNavigation = compoundBrowserNavigation(
            from: trimmedUserCommand,
            normalizedCommand: normalizedCommand
        ) {
            return compoundBrowserNavigationPlan(
                userCommand: trimmedUserCommand,
                urlText: compoundBrowserNavigation.urlText,
                searchQuery: compoundBrowserNavigation.searchQuery
            )
        }

        if let browserText = browserNavigationText(from: trimmedUserCommand, normalizedCommand: normalizedCommand) {
            return browserInputPlan(
                userCommand: trimmedUserCommand,
                text: browserText,
                inputSummary: isLikelyURL(browserText) ? "Type URL" : "Type search query",
                assistantMessage: isLikelyURL(browserText) ? "Opening \(browserText)." : "Searching for \(browserText)."
            )
        }

        // "open apple.com" — a URL/domain, not an app bundle name.
        if let urlText = urlToOpen(from: trimmedUserCommand, normalizedCommand: normalizedCommand) {
            return browserInputPlan(
                userCommand: trimmedUserCommand,
                text: urlText,
                inputSummary: "Type URL",
                assistantMessage: "Opening \(urlText)."
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

        if let fieldInput = fieldInputCommand(from: trimmedUserCommand, normalizedCommand: normalizedCommand) {
            guard let screenContext = context.screenContext else {
                return JarvisPlan.empty(
                    for: trimmedUserCommand,
                    assistantMessage: "I need screen context before I can type into \(fieldInput.targetDescription)."
                )
            }

            return JarvisPlan(
                userCommand: trimmedUserCommand,
                toolCalls: [
                    JarvisToolCall(
                        toolName: "click_at",
                        arguments: [
                            "x": .number(screenContext.globalX),
                            "y": .number(screenContext.globalY),
                            "display_frame_x": .number(screenContext.displayFrameX),
                            "display_frame_y": .number(screenContext.displayFrameY),
                            "display_frame_width": .number(screenContext.displayFrameWidth),
                            "display_frame_height": .number(screenContext.displayFrameHeight),
                            "label": .string(fieldInput.targetDescription)
                        ],
                        userVisibleSummary: "Click \(fieldInput.targetDescription)"
                    ),
                    JarvisToolCall(
                        toolName: "type_text",
                        arguments: ["text": .string(fieldInput.text)],
                        userVisibleSummary: "Type text"
                    )
                ],
                assistantMessage: "Typing \(fieldInput.text) into \(fieldInput.targetDescription)."
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
            assistantMessage: "I do not have a concrete local action for that yet."
        )
    }

    static func commandNeedsScreenContext(_ userCommand: String) -> Bool {
        let normalizedCommand = stripContinuationPrefix(from: userCommand)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedCommand.hasPrefix("click ")
            || normalizedCommand.hasPrefix("tap ")
            || normalizedCommand.hasPrefix("press the ")
            || normalizedCommand.contains(" search bar")
            || normalizedCommand.contains(" button")
            || normalizedCommand.contains(" field")
            || normalizedCommand.contains(" link")
    }

    private static func stripContinuationPrefix(from command: String) -> String {
        var trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["ok, ", "okay, ", "please ", "i want you to ", "and then ", "then ", "and ", "also "] {
            if trimmedCommand.lowercased().hasPrefix(prefix) {
                trimmedCommand = String(trimmedCommand.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return trimmedCommand
    }

    /// Words that indicate the text after "open" is a phrase or instruction,
    /// not an application name (e.g. "open a new tab on chrome which we are
    /// on right now"). If any of these appear, the command falls through to
    /// the computer-use agent instead of being misread as an app launch.
    private static let wordsThatAreNotAppNames: Set<String> = [
        "a", "an", "the", "new", "tab", "tabs", "window", "windows",
        "which", "that", "this", "on", "in", "to", "for", "of", "it",
        "we", "are", "right", "now", "my", "your", "up", "page", "file",
        "folder", "site", "website"
    ]

    private func appNameToOpen(from normalizedCommand: String) -> String? {
        let prefixes = ["open ", "launch ", "start "]

        guard let matchedPrefix = prefixes.first(where: { normalizedCommand.hasPrefix($0) }) else {
            return nil
        }

        let rawAppName = normalizedCommand.dropFirst(matchedPrefix.count).trimmingCharacters(in: .whitespacesAndNewlines)

        // Multi-step commands like "open chrome and type youtube.com" are not
        // fast-path material: splitting at the conjunction would silently drop
        // everything after it. Let the agent loop handle the whole command.
        for conjunction in [" and ", " then "] {
            if rawAppName.contains(conjunction) {
                return nil
            }
        }

        // Domains like "apple.com" are URLs, not app names.
        if looksLikeURLOrDomain(String(rawAppName)) {
            return nil
        }

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

            // Only accept short, app-like names ("visual studio code", not
            // "a new tab on chrome which we are on right now"). Anything that
            // looks like a phrase falls through to the agent loop.
            let appNameWords = rawAppName.split(separator: " ").map { String($0) }
            guard appNameWords.count <= 3,
                  !appNameWords.contains(where: { Self.wordsThatAreNotAppNames.contains($0) }) else {
                return nil
            }

            return appNameWords
                .map { word in word.prefix(1).uppercased() + word.dropFirst() }
                .joined(separator: " ")
        }
    }

    private func hotkeyNames(from normalizedCommand: String) -> [String]? {
        let prefixes = ["press ", "hit ", "send "]

        guard let matchedPrefix = prefixes.first(where: { normalizedCommand.hasPrefix($0) }) else {
            return nil
        }

        let rawHotkey = normalizedCommand
            .dropFirst(matchedPrefix.count)
            .replacingOccurrences(of: " + ", with: " ")
            .replacingOccurrences(of: "+", with: " ")
            .replacingOccurrences(of: "the ", with: "")
            .replacingOccurrences(of: "key", with: "")
            .replacingOccurrences(of: "shortcut", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let expandedHotkey = hotkeyAlias(rawHotkey) ?? rawHotkey
        let keyNames = expandedHotkey
            .split(separator: " ")
            .map { String($0) }

        return keyNames.isEmpty ? nil : keyNames
    }

    private func browserNavigationText(from userCommand: String, normalizedCommand: String) -> String? {
        let prefixes = [
            "open chrome and search for ",
            "open chrome and search up the internet for ",
            "open chrome and search up internet for ",
            "open chrome and search up ",
            "open google chrome and search for ",
            "open google chrome and search up the internet for ",
            "open google chrome and search up internet for ",
            "open google chrome and search up ",
            "open chrome and go to ",
            "open google chrome and go to ",
            "open chrome to ",
            "open google chrome to ",
            "search up the internet for ",
            "search up internet for ",
            "search the internet for ",
            "search internet for ",
            "search up ",
            "search for ",
            "google ",
            "look up ",
            "search ",
            "go to ",
            "navigate to ",
            "open website ",
            "open site ",
            "visit ",
            "open url "
        ]

        guard let matchedPrefix = prefixes.first(where: { normalizedCommand.hasPrefix($0) }) else {
            return nil
        }

        let searchQuery = cleanBrowserQuery(String(userCommand.dropFirst(matchedPrefix.count)))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return searchQuery.isEmpty ? nil : searchQuery
    }

    private func compoundBrowserNavigation(
        from userCommand: String,
        normalizedCommand: String
    ) -> (urlText: String, searchQuery: String)? {
        let urlPrefixes = ["open ", "go to ", "visit ", "navigate to "]
        let searchConjunctions = [
            " and look for ",
            " and search for ",
            " and find ",
            " then look for ",
            " then search for ",
            " then find "
        ]

        guard let matchedURLPrefix = urlPrefixes.first(where: { normalizedCommand.hasPrefix($0) }) else {
            return nil
        }

        let textAfterURLPrefix = String(userCommand.dropFirst(matchedURLPrefix.count))
        let normalizedTextAfterURLPrefix = textAfterURLPrefix.lowercased()

        for searchConjunction in searchConjunctions {
            guard let conjunctionRange = normalizedTextAfterURLPrefix.range(of: searchConjunction) else {
                continue
            }

            let urlText = String(textAfterURLPrefix[..<conjunctionRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let searchQuery = cleanBrowserQuery(String(textAfterURLPrefix[conjunctionRange.upperBound...]))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard looksLikeURLOrDomain(urlText), !searchQuery.isEmpty else {
                return nil
            }

            return (urlText: urlText, searchQuery: searchQuery)
        }

        return nil
    }

    private func urlToOpen(from userCommand: String, normalizedCommand: String) -> String? {
        let urlPrefixes = ["open ", "go to ", "visit ", "navigate to "]

        guard let matchedURLPrefix = urlPrefixes.first(where: { normalizedCommand.hasPrefix($0) }) else {
            return nil
        }

        let urlText = String(userCommand.dropFirst(matchedURLPrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !urlText.isEmpty,
              !normalizedCommand.contains(" and "),
              !normalizedCommand.contains(" then "),
              looksLikeURLOrDomain(urlText) else {
            return nil
        }

        return urlText
    }

    private func looksLikeURLOrDomain(_ text: String) -> Bool {
        let normalizedText = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedText.hasPrefix("http://")
            || normalizedText.hasPrefix("https://")
            || normalizedText.contains(".")
    }

    private func compoundBrowserNavigationPlan(
        userCommand: String,
        urlText: String,
        searchQuery: String
    ) -> JarvisPlan {
        JarvisPlan(
            userCommand: userCommand,
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
                    arguments: ["text": .string(urlText)],
                    userVisibleSummary: "Type URL"
                ),
                JarvisToolCall(
                    toolName: "press_hotkey",
                    arguments: ["keys": .stringArray(["return"])],
                    userVisibleSummary: "Press Return"
                ),
                JarvisToolCall(
                    toolName: "wait",
                    arguments: ["seconds": .number(2)],
                    userVisibleSummary: "Wait for page load"
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
            assistantMessage: "Opening \(urlText) and searching for \(searchQuery)."
        )
    }

    private func browserInputPlan(
        userCommand: String,
        text: String,
        inputSummary: String,
        assistantMessage: String
    ) -> JarvisPlan {
        JarvisPlan(
            userCommand: userCommand,
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
                    arguments: ["text": .string(text)],
                    userVisibleSummary: inputSummary
                ),
                JarvisToolCall(
                    toolName: "press_hotkey",
                    arguments: ["keys": .stringArray(["return"])],
                    userVisibleSummary: "Press Return"
                )
            ],
            assistantMessage: assistantMessage
        )
    }

    private func fieldInputCommand(
        from userCommand: String,
        normalizedCommand: String
    ) -> (text: String, targetDescription: String)? {
        guard normalizedCommand.hasPrefix("type ") else { return nil }

        let textAndTarget = String(userCommand.dropFirst("type ".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let separators = [" into the ", " into ", " in the ", " in ", " on the ", " on "]
        for separator in separators {
            guard let separatorRange = textAndTarget.lowercased().range(of: separator) else {
                continue
            }

            let text = String(textAndTarget[..<separatorRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let target = String(textAndTarget[separatorRange.upperBound...])
                .replacingOccurrences(of: " on top", with: "")
                .replacingOccurrences(of: " at the top", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty, !target.isEmpty else { return nil }
            return (text: text, targetDescription: target)
        }

        return nil
    }

    private func isLikelyURL(_ text: String) -> Bool {
        let normalizedText = text.lowercased()
        return normalizedText.hasPrefix("http://")
            || normalizedText.hasPrefix("https://")
            || normalizedText.contains(".com")
            || normalizedText.contains(".org")
            || normalizedText.contains(".net")
            || normalizedText.contains(".dev")
            || normalizedText.contains(".ai")
    }

    private func cleanBrowserQuery(_ rawQuery: String) -> String {
        let trimmedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = trimmedQuery.lowercased()
        let followUpSeparators = [
            " and tell me",
            " then tell me",
            " and what does",
            " then what does",
            " and read",
            " then read",
            " and describe",
            " then describe"
        ]

        for separator in followUpSeparators {
            if let separatorRange = normalizedQuery.range(of: separator) {
                return String(trimmedQuery[..<separatorRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return trimmedQuery
    }

    private func hotkeyAlias(_ hotkey: String) -> String? {
        switch hotkey {
        case "enter", "return":
            return "return"
        case "spotlight":
            return "command space"
        case "copy":
            return "command c"
        case "paste":
            return "command v"
        case "cut":
            return "command x"
        case "select all":
            return "command a"
        case "new tab":
            return "command t"
        case "close tab", "close window":
            return "command w"
        case "refresh", "reload":
            return "command r"
        default:
            return nil
        }
    }

    private func clickTargetDescription(from userCommand: String, normalizedCommand: String) -> String? {
        let prefixes = ["click on ", "click ", "tap on ", "tap "]
        guard let matchedPrefix = prefixes.first(where: { normalizedCommand.hasPrefix($0) }) else {
            return nil
        }

        let targetDescription = String(userCommand.dropFirst(matchedPrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return targetDescription.isEmpty ? "that element" : targetDescription
    }
}
