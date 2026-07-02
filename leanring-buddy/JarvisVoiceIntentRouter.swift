//
//  JarvisVoiceIntentRouter.swift
//  leanring-buddy
//
//  Local LLM router for deciding whether a spoken transcript should be handled
//  as a Mac action, a screen-aware companion answer, or an action followed by
//  a screen-aware answer.
//

import Foundation

enum JarvisVoiceIntentRoute: String {
    case action
    case vision
    case actionThenVision = "action_then_vision"
}

struct JarvisVoiceIntentDecision {
    let route: JarvisVoiceIntentRoute
    let actionCommand: String
    let visionPrompt: String
    let reason: String
}

final class JarvisVoiceIntentRouter {
    private let localLLMClient: JarvisLocalLLMClient

    init(localLLMClient: JarvisLocalLLMClient = JarvisLocalLLMClient()) {
        self.localLLMClient = localLLMClient
    }

    func warmUp() async {
        do {
            let startTime = Date()
            _ = try await routeWithReliableModel(
                "do you see this page?"
            )
            let elapsed = Date().timeIntervalSince(startTime)
            JarvisDebugLogger.log("Route", "router warmup complete in \(String(format: "%.1f", elapsed))s")
        } catch {
            JarvisDebugLogger.log("Route", "router warmup skipped: \(error.localizedDescription)")
        }
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
            let responseText = try await routeWithReliableModel(trimmedTranscript)
            JarvisDebugLogger.logMultiline("Route", title: "router raw response:", body: responseText)
            let decision = Self.parseDecision(responseText: responseText, fallbackTranscript: trimmedTranscript)
            JarvisDebugLogger.log("Route", "\(decision.route.rawValue) — \(decision.reason)")
            return decision
        } catch {
            JarvisDebugLogger.log("Route", "router unavailable: \(error.localizedDescription) — defaulting to vision")
            return JarvisVoiceIntentDecision(
                route: .vision,
                actionCommand: trimmedTranscript,
                visionPrompt: trimmedTranscript,
                reason: "router unavailable"
            )
        }
    }

    private func routeWithReliableModel(_ trimmedTranscript: String) async throws -> String {
        try await localLLMClient.generateComputerUseTurn(
            systemPrompt: "You are the local voice intent router. Return only valid JSON.",
            userPrompt: Self.routerPrompt(transcript: trimmedTranscript),
            modelOverride: JarvisLocalLLMConfiguration.current.routerModel
        )
    }

    private static func routerPrompt(transcript: String) -> String {
        """
        Route one spoken command for a local Mac assistant.
        Return exactly one flat JSON object and nothing else.
        Required keys: route, action_command, vision_prompt, reason.
        Do not wrap the object inside another key. Do not include markdown.

        Routes:
        action = control the Mac: open, search, google, look up, navigate, type, press, click, tap, scroll.
        vision = answer/explain/opine/describe current screen without controlling the Mac.
        action_then_vision = do a Mac action first, then answer after it completes.

        Rules:
        Direct questions normally stay vision: facts, opinions, explanations, and "what is/what's/how/why/when/where/do you see" questions.
        Direct questions that require current/live information are action_then_vision: weather, current time in a city, prices, news, stocks, sports, exchange rates. Use action_command "search for <short query>" and vision_prompt as the user's original question.
        Do not convert a non-live direct question into a Mac action or browser search.
        If the transcript explicitly commands search/google/look up/open/navigate/type/press/click/tap/scroll, use action.
        Use action_then_vision only when the same transcript explicitly asks for an action and a follow-up answer after it, such as "and tell me", "then explain", or "after that what does it say".
        For action_then_vision, action_command is only the action part; vision_prompt is only the follow-up answer request.
        For action, action_command repeats the transcript exactly.

        Examples:
        what's the weather in Toronto today? -> {"route":"action_then_vision","action_command":"search for Toronto weather today","vision_prompt":"what's the weather in Toronto today?","reason":"live info lookup"}
        what's the time in San Francisco? -> {"route":"action_then_vision","action_command":"search for time in San Francisco","vision_prompt":"what's the time in San Francisco?","reason":"live info lookup"}
        what is better, skyscraper grey or dravit grey on a BMW? -> {"route":"vision","action_command":"","vision_prompt":"what is better, skyscraper grey or dravit grey on a BMW?","reason":"opinion"}
        search for a Porsche 911 white colour -> {"route":"action","action_command":"search for a Porsche 911 white colour","vision_prompt":"","reason":"search command"}
        search up cat and tell me what it says -> {"route":"action_then_vision","action_command":"search up cat","vision_prompt":"tell me what the current page says about cat","reason":"action plus answer"}
        open chrome and go to youtube.com -> {"route":"action","action_command":"open chrome and go to youtube.com","vision_prompt":"","reason":"control"}
        click on the Apple video -> {"route":"action","action_command":"click on the Apple video","vision_prompt":"","reason":"control"}
        do you see WWDC? -> {"route":"vision","action_command":"","vision_prompt":"do you see WWDC?","reason":"screen question"}

        Transcript:
        \(transcript)
        """
    }

    private static func parseDecision(
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
        let isLiveInfoQuestion = Self.isLiveInfoQuestion(normalizedFallback)
        let isDirectQuestion = Self.isDirectQuestion(normalizedFallback)

        switch route {
        case .action:
            if !hasExplicitControlCommand && isDirectQuestion {
                if isLiveInfoQuestion {
                    return JarvisVoiceIntentDecision(
                        route: .actionThenVision,
                        actionCommand: actionCommand.hasPrefix("search")
                            ? actionCommand
                            : "search for \(Self.searchQueryText(from: fallbackTranscript))",
                        visionPrompt: fallbackTranscript,
                        reason: reason.isEmpty
                            ? "live question corrected to search then answer"
                            : reason + " (live question — corrected to search then answer)"
                    )
                }

                return JarvisVoiceIntentDecision(
                    route: .vision,
                    actionCommand: "",
                    visionPrompt: fallbackTranscript,
                    reason: reason.isEmpty
                        ? "question corrected to vision"
                        : reason + " (question — corrected to vision)"
                )
            }

            return JarvisVoiceIntentDecision(
                route: .action,
                actionCommand: fallbackTranscript,
                visionPrompt: "",
                reason: reason
            )
        case .vision:
            return JarvisVoiceIntentDecision(
                route: .vision,
                actionCommand: "",
                visionPrompt: visionPrompt.isEmpty ? fallbackTranscript : visionPrompt,
                reason: reason
            )
        case .actionThenVision:
            if actionCommand.isEmpty {
                return JarvisVoiceIntentDecision(
                    route: .vision,
                    actionCommand: "",
                    visionPrompt: visionPrompt.isEmpty ? fallbackTranscript : visionPrompt,
                    reason: reason.isEmpty
                        ? "action_then_vision without action downgraded to vision"
                        : reason + " (no action — downgraded to vision)"
                )
            }

            if !hasExplicitControlCommand && !isLiveInfoQuestion {
                return JarvisVoiceIntentDecision(
                    route: .vision,
                    actionCommand: "",
                    visionPrompt: visionPrompt.isEmpty ? fallbackTranscript : visionPrompt,
                    reason: reason.isEmpty
                        ? "non-live question downgraded to vision"
                        : reason + " (non-live question — downgraded to vision)"
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

    private static func fallbackDecision(for transcript: String, reason: String) -> JarvisVoiceIntentDecision {
        let normalizedTranscript = transcript.lowercased()
        if isLiveInfoQuestion(normalizedTranscript) {
            return JarvisVoiceIntentDecision(
                route: .actionThenVision,
                actionCommand: "search for \(searchQueryText(from: transcript))",
                visionPrompt: transcript,
                reason: reason + " — live question fallback"
            )
        }

        if hasExplicitControlCommand(normalizedTranscript) {
            return JarvisVoiceIntentDecision(
                route: .action,
                actionCommand: transcript,
                visionPrompt: "",
                reason: reason + " — explicit command fallback"
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

    private static func hasExplicitControlCommand(_ normalizedTranscript: String) -> Bool {
        [
            "open", "search", "google", "look up", "lookup", "navigate",
            "go to", "type", "press", "click", "tap", "scroll"
        ].contains { normalizedTranscript.contains($0) }
    }

    private static func isLiveInfoQuestion(_ normalizedTranscript: String) -> Bool {
        [
            "weather", "current time", "time in", "price", "prices",
            "stock", "stocks", "news", "score", "scores", "sports",
            "exchange rate", "currency", "today", "right now"
        ].contains { normalizedTranscript.contains($0) }
    }

    private static func isDirectQuestion(_ normalizedTranscript: String) -> Bool {
        normalizedTranscript.contains("?")
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
    }

    private static func searchQueryText(from transcript: String) -> String {
        transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "?.!"))
    }
}
