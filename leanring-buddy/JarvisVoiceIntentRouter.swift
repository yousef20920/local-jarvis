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
            // Uses the /api/chat JSON call rather than /api/generate: with
            // qwen3-vl, generate+format=json returns an empty "response"
            // (the output lands in the "thinking" field), while chat reliably
            // returns the JSON in the message content.
            let responseText = try await localLLMClient.generateComputerUseTurn(
                systemPrompt: Self.routerSystemPrompt,
                userPrompt: "Transcript:\n\(trimmedTranscript)"
            )
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

    private static let routerSystemPrompt = """
        You are the local voice intent router for a Mac assistant named Jarvis.
        Classify the user's spoken transcript into exactly one route.
        Return only valid JSON. Do not include markdown.

        Routes:
        - "action": the user wants Jarvis to control the Mac, open apps, search/navigate, type, press keys, or click.
        - "vision": the user wants an answer, opinion, explanation, or screen-aware description. No Mac control should happen.
        - "action_then_vision": the user asks Jarvis to do a Mac action, then answer something after the action completes.

        Important:
        - General questions and opinions are "vision", even if they could be searched online.
        - Do not turn a question into a browser search unless the user explicitly asks to search, google, look up, open, navigate, type, press, click, or tap.
        - For action_then_vision, action_command should contain only the action portion, and vision_prompt should contain the follow-up question.
        - For action, action_command may repeat the transcript. Do not invent app/menu names, targets, or extra steps.
        - For vision, vision_prompt should be the user's question or request.

        Examples:
        User: "what's better, skyscraper grey or dravit grey on a BMW?"
        {"route":"vision","action_command":"","vision_prompt":"what's better, skyscraper grey or dravit grey on a BMW?","reason":"opinion question"}

        User: "search up cat and tell me what it says"
        {"route":"action_then_vision","action_command":"search up cat","vision_prompt":"tell me what the current page says about cat","reason":"search followed by screen answer"}

        User: "open chrome and go to youtube.com"
        {"route":"action","action_command":"open chrome and go to youtube.com","vision_prompt":"","reason":"explicit browser navigation"}

        User: "click on the Apple video"
        {"route":"action","action_command":"click on the Apple video","vision_prompt":"","reason":"explicit click command"}

        User: "do you see WWDC?"
        {"route":"vision","action_command":"","vision_prompt":"do you see WWDC?","reason":"screen-aware question"}

        JSON shape:
        {
          "route": "action",
          "action_command": "clean action command or empty string",
          "vision_prompt": "screen/question prompt or empty string",
          "reason": "short reason"
        }
        """

    private static func parseDecision(
        responseText: String,
        fallbackTranscript: String
    ) -> JarvisVoiceIntentDecision {
        guard let data = responseText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let routeText = json["route"] as? String,
              let route = JarvisVoiceIntentRoute(rawValue: routeText) else {
            return JarvisVoiceIntentDecision(
                route: .vision,
                actionCommand: fallbackTranscript,
                visionPrompt: fallbackTranscript,
                reason: "invalid router response"
            )
        }

        let actionCommand = (json["action_command"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let visionPrompt = (json["vision_prompt"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reason = (json["reason"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch route {
        case .action:
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
}
