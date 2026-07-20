//
//  JarvisVoiceIntentRouter.swift
//  leanring-buddy
//
//  GPT-backed router for deciding whether a spoken transcript should be
//  handled as a Mac action, a screen-aware companion answer, or an action
//  followed by a screen-aware answer.
//

import Foundation

enum JarvisVoiceIntentRoute: String {
    case action
    case vision
    case webResearch = "web_research"
    case actionThenVision = "action_then_vision"
}

struct JarvisVoiceIntentDecision {
    let route: JarvisVoiceIntentRoute
    let actionCommand: String
    let visionPrompt: String
    let reason: String
}

final class JarvisVoiceIntentRouter {
    private let openAIClient: JarvisOpenAIClient

    init(openAIClient: JarvisOpenAIClient = JarvisOpenAIClient()) {
        self.openAIClient = openAIClient
    }

    func route(transcript: String) async -> JarvisVoiceIntentDecision {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            return JarvisVoiceIntentDecision(
                route: .vision,
                actionCommand: "",
                visionPrompt: "",
                reason: "empty transcript"
            )
        }

        JarvisDebugLogger.logVerbose("Route", "routing transcript: \"\(trimmedTranscript)\"")

        do {
            let responseText = try await routeWithGPT(trimmedTranscript)
            JarvisDebugLogger.logMultiline("Route", title: "router raw response:", body: responseText)
            let decision = Self.parseDecision(responseText: responseText, fallbackTranscript: trimmedTranscript)
            JarvisDebugLogger.log("Route", "\(decision.route.rawValue) — \(decision.reason)")
            return decision
        } catch {
            JarvisDebugLogger.log("Route", "router unavailable: \(error.localizedDescription) — using deterministic fallback")
            return Self.fallbackDecision(
                for: trimmedTranscript,
                reason: "router unavailable"
            )
        }
    }

    private func routeWithGPT(_ trimmedTranscript: String) async throws -> String {
        try await openAIClient.generateComputerUseTurn(
            systemPrompt: "You are the Jarvis voice intent router. Return only valid JSON.",
            userPrompt: Self.routerPrompt(transcript: trimmedTranscript)
        )
    }

    private static func routerPrompt(transcript: String) -> String {
        """
        Route one spoken command for a Mac assistant.
        Return exactly one flat JSON object and nothing else.
        Required keys: route, action_command, vision_prompt, reason.
        Do not wrap the object inside another key. Do not include markdown.

        Routes:
        action = control the Mac: open, search, google, look up, navigate, type, press, click, tap, scroll.
        vision = answer a question specifically about what is visible on the current screen.
        web_research = answer any informational, factual, explanatory, recommendation, opinion, or current-events question using internet sources.
        action_then_vision = do a Mac action first, then answer after it completes.

        Rules:
        Route every informational question to web_research, even when it is not time-sensitive. Jarvis must ground answers in internet sources instead of model memory.
        Use vision only when the user is explicitly asking about the visible screen, such as "what do you see", "what does this error say", or "where is the save button".
        For web_research, action_command is empty and vision_prompt is the user's complete original question.
        If the transcript explicitly commands search/google/look up/open/navigate/type/press/click/tap/scroll, use action.
        Use action_then_vision only when the same transcript explicitly asks for an action and a follow-up answer after it, such as "and tell me", "then explain", or "after that what does it say".
        For action_then_vision, action_command is only the action part; vision_prompt is only the follow-up answer request.
        For action, action_command repeats the transcript exactly.

        Examples:
        what's the weather in Toronto today? -> {"route":"web_research","action_command":"","vision_prompt":"what's the weather in Toronto today?","reason":"internet-grounded question"}
        what's the time in San Francisco? -> {"route":"web_research","action_command":"","vision_prompt":"what's the time in San Francisco?","reason":"internet-grounded question"}
        what is better, skyscraper grey or dravit grey on a BMW? -> {"route":"web_research","action_command":"","vision_prompt":"what is better, skyscraper grey or dravit grey on a BMW?","reason":"internet-grounded recommendation"}
        search for a Porsche 911 white colour -> {"route":"action","action_command":"search for a Porsche 911 white colour","vision_prompt":"","reason":"search command"}
        search up cat and tell me what it says -> {"route":"action_then_vision","action_command":"search up cat","vision_prompt":"tell me what the current page says about cat","reason":"action plus answer"}
        open chrome and go to youtube.com -> {"route":"action","action_command":"open chrome and go to youtube.com","vision_prompt":"","reason":"control"}
        click on the Apple video -> {"route":"action","action_command":"click on the Apple video","vision_prompt":"","reason":"control"}
        do you see WWDC? -> {"route":"vision","action_command":"","vision_prompt":"do you see WWDC?","reason":"screen question"}

        Transcript:
        \(transcript)
        """
    }

    static func parseDecision(
        responseText: String,
        fallbackTranscript: String
    ) -> JarvisVoiceIntentDecision {
        guard let data = responseText.data(using: .utf8),
              let rawJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let json = Self.routeObject(from: rawJSON),
              let routeText = json["route"] as? String,
              let route = JarvisVoiceIntentRoute(rawValue: routeText) else {
            return fallbackDecision(for: fallbackTranscript, reason: "invalid router response")
        }

        let actionCommand = (json["action_command"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let visionPrompt = (json["vision_prompt"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reason = (json["reason"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let normalizedFallback = fallbackTranscript.lowercased()
        let hasExplicitControlCommand = Self.hasExplicitControlCommand(normalizedFallback)
        let isInformationalRequest = Self.isInformationalRequest(normalizedFallback)

        switch route {
        case .action:
            if !hasExplicitControlCommand && isInformationalRequest {
                return JarvisVoiceIntentDecision(
                    route: .webResearch,
                    actionCommand: "",
                    visionPrompt: fallbackTranscript,
                    reason: reason.isEmpty
                        ? "question corrected to web research"
                        : reason + " (question — corrected to web research)"
                )
            }

            return JarvisVoiceIntentDecision(
                route: .action,
                actionCommand: fallbackTranscript,
                visionPrompt: "",
                reason: reason
            )
        case .vision:
            if isInformationalRequest && !Self.isScreenContextQuestion(normalizedFallback) {
                return JarvisVoiceIntentDecision(
                    route: .webResearch,
                    actionCommand: "",
                    visionPrompt: fallbackTranscript,
                    reason: reason.isEmpty
                        ? "informational question corrected to web research"
                        : reason + " (informational question — corrected to web research)"
                )
            }

            return JarvisVoiceIntentDecision(
                route: .vision,
                actionCommand: "",
                visionPrompt: visionPrompt.isEmpty ? fallbackTranscript : visionPrompt,
                reason: reason
            )
        case .webResearch:
            return JarvisVoiceIntentDecision(
                route: .webResearch,
                actionCommand: "",
                visionPrompt: visionPrompt.isEmpty ? fallbackTranscript : visionPrompt,
                reason: reason
            )
        case .actionThenVision:
            if actionCommand.isEmpty {
                if isInformationalRequest && !Self.isScreenContextQuestion(normalizedFallback) {
                    return JarvisVoiceIntentDecision(
                        route: .webResearch,
                        actionCommand: "",
                        visionPrompt: visionPrompt.isEmpty ? fallbackTranscript : visionPrompt,
                        reason: reason.isEmpty
                            ? "question corrected to web research"
                            : reason + " (no action — corrected to web research)"
                    )
                }

                return JarvisVoiceIntentDecision(
                    route: .vision,
                    actionCommand: "",
                    visionPrompt: visionPrompt.isEmpty ? fallbackTranscript : visionPrompt,
                    reason: reason.isEmpty
                        ? "action_then_vision without action downgraded to vision"
                        : reason + " (no action — downgraded to vision)"
                )
            }

            if !hasExplicitControlCommand {
                return JarvisVoiceIntentDecision(
                    route: .webResearch,
                    actionCommand: "",
                    visionPrompt: visionPrompt.isEmpty ? fallbackTranscript : visionPrompt,
                    reason: reason.isEmpty
                        ? "question corrected to web research"
                        : reason + " (question — corrected to web research)"
                )
            }

            // The model sometimes picks action_then_vision but leaves
            // vision_prompt empty (no actual follow-up question). Re-running
            // the whole transcript as the vision follow-up would answer the
            // command twice, so downgrade to a plain action instead.
            guard !visionPrompt.isEmpty else {
                return JarvisVoiceIntentDecision(
                    route: .action,
                    actionCommand: fallbackTranscript,
                    visionPrompt: "",
                    reason: reason.isEmpty
                        ? "action_then_vision without follow-up question downgraded to action"
                        : reason + " (no follow-up question — downgraded to action)"
                )
            }

            return JarvisVoiceIntentDecision(
                route: .actionThenVision,
                actionCommand: actionCommand.isEmpty ? fallbackTranscript : actionCommand,
                visionPrompt: visionPrompt,
                reason: reason
            )
        }
    }

    static func fallbackDecision(for transcript: String, reason: String) -> JarvisVoiceIntentDecision {
        let normalizedTranscript = transcript.lowercased()
        if hasExplicitControlCommand(normalizedTranscript) {
            return JarvisVoiceIntentDecision(
                route: .action,
                actionCommand: transcript,
                visionPrompt: "",
                reason: reason + " — explicit command fallback"
            )
        }

        if isInformationalRequest(normalizedTranscript) && !isScreenContextQuestion(normalizedTranscript) {
            return JarvisVoiceIntentDecision(
                route: .webResearch,
                actionCommand: "",
                visionPrompt: transcript,
                reason: reason + " — web research fallback"
            )
        }

        return JarvisVoiceIntentDecision(
            route: .vision,
            actionCommand: "",
            visionPrompt: transcript,
            reason: reason + " — vision fallback"
        )
    }

    private static func routeObject(from rawJSON: [String: Any]) -> [String: Any]? {
        if rawJSON["route"] is String {
            return rawJSON
        }

        if let wrappedJSON = rawJSON["json"] as? [String: Any],
           wrappedJSON["route"] is String {
            return wrappedJSON
        }

        for value in rawJSON.values {
            guard let nestedJSON = value as? [String: Any],
                  nestedJSON["route"] is String else {
                continue
            }
            return nestedJSON
        }

        return nil
    }

    static func hasExplicitControlCommand(_ normalizedTranscript: String) -> Bool {
        [
            "open", "search", "google", "look up", "lookup", "navigate",
            "go to", "type", "press", "click", "tap", "scroll"
        ].contains { commandPhrase in
            let escapedCommandPhrase = NSRegularExpression.escapedPattern(for: commandPhrase)
            return normalizedTranscript.range(
                of: #"\b"# + escapedCommandPhrase + #"\b"#,
                options: .regularExpression
            ) != nil
        }
    }

    private static func isScreenContextQuestion(_ normalizedTranscript: String) -> Bool {
        let hasExplicitScreenReference = [
            "what do you see", "can you see", "do you see", "on my screen",
            "on the screen", "this screen", "current screen", "this error",
            "this page", "this window", "this code", "selected text",
            "highlighted text", "what am i looking at"
        ].contains { normalizedTranscript.contains($0) }

        let asksWhere = normalizedTranscript.hasPrefix("where is")
            || normalizedTranscript.hasPrefix("where's")
        let namesVisibleInterfaceElement = [
            "button", "menu", "icon", "field", "tab", "setting", "option",
            "toolbar", "sidebar", "window"
        ].contains { normalizedTranscript.contains($0) }

        return hasExplicitScreenReference || (asksWhere && namesVisibleInterfaceElement)
    }

    static func isInformationalRequest(_ normalizedTranscript: String) -> Bool {
        let isDirectQuestion = normalizedTranscript.contains("?")
            || normalizedTranscript.hasPrefix("what ")
            || normalizedTranscript.hasPrefix("what's ")
            || normalizedTranscript.hasPrefix("whats ")
            || normalizedTranscript.hasPrefix("what is ")
            || normalizedTranscript.hasPrefix("how ")
            || normalizedTranscript.hasPrefix("why ")
            || normalizedTranscript.hasPrefix("when ")
            || normalizedTranscript.hasPrefix("where ")
            || normalizedTranscript.hasPrefix("do you ")
            || normalizedTranscript.hasPrefix("does ")
            || normalizedTranscript.hasPrefix("is ")
            || normalizedTranscript.hasPrefix("are ")
            || normalizedTranscript.hasPrefix("who ")
            || normalizedTranscript.hasPrefix("which ")
            || normalizedTranscript.hasPrefix("tell me ")
            || normalizedTranscript.hasPrefix("explain ")

        let isInformationSeekingImperative = [
            "give me information", "give me a summary", "give me the latest",
            "recommend ", "compare ", "summarize ", "research ", "find out ",
            "help me understand ", "get me the latest", "latest news",
            "news about ", "weather in ", "price of "
        ].contains { normalizedTranscript.hasPrefix($0) }

        return isDirectQuestion || isInformationSeekingImperative
    }

}
