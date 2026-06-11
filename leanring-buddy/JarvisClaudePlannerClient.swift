//
//  JarvisClaudePlannerClient.swift
//  leanring-buddy
//
//  Natural-language fallback planner for Jarvis. Calls OpenAI (gpt-4o-mini)
//  directly when neither Ollama nor the rule-based planner can interpret the
//  user's voice command. Uses response_format: json_object to guarantee
//  well-formed JSON output without needing to strip markdown fences.
//
//  The OpenAI API key is read from UserDefaults (key: jarvisOpenAIFallbackAPIKey)
//  so it is never stored in source code or committed to git.
//

import Foundation

enum JarvisClaudePlannerError: LocalizedError {
    case missingAPIKey
    case httpError(Int, String)
    case invalidResponse
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No OpenAI API key configured. Set jarvisOpenAIFallbackAPIKey in UserDefaults."
        case .httpError(let statusCode, let body):
            return "OpenAI fallback planner returned HTTP \(statusCode): \(body)"
        case .invalidResponse:
            return "OpenAI fallback planner returned an unexpected response format."
        case .invalidJSON(let text):
            return "OpenAI fallback planner returned non-JSON text: \(text.prefix(120))"
        }
    }
}

/// Interprets natural-language voice commands as structured Jarvis tool calls
/// by calling OpenAI gpt-4o-mini with a strict JSON-only system prompt.
/// This is the final fallback when Ollama and the rule-based planner both fail.
final class JarvisClaudePlannerClient {
    private static let openAICompletionsURL = URL(string: "https://api.openai.com/v1/chat/completions")!

    // UserDefaults key where the OpenAI API key is stored at runtime.
    // Set via CompanionManager.configureOpenAIFallbackAPIKey(_:) — never hard-coded.
    static let openAIAPIKeyUserDefaultsKey = "jarvisOpenAIFallbackAPIKey"

    private let session: URLSession

    private static let plannerSystemPrompt = """
    You are the automation planner for a macOS voice assistant named Jarvis. \
    The user speaks commands naturally and you convert them into macOS tool calls.

    Return ONLY valid JSON — no prose, no explanation, nothing else.

    Available tools:
    - open_app       — open a macOS app by name
      arguments: {"name": "Google Chrome"}
    - type_text      — type text into the currently focused app
      arguments: {"text": "hello world"}
    - press_hotkey   — press a keyboard shortcut
      arguments: {"keys": ["command", "l"]}
    - take_screenshot — capture the screen
      arguments: {}

    Valid key names for press_hotkey: command, shift, option, control, return, \
    space, escape, tab, delete, and any single letter or digit.

    Multi-step rules:
    - Navigating to a URL or searching the web → open Google Chrome, \
    press command+l (focus address bar), type the URL or query, press return.
    - "I wanted to type X" / "type X" / "go to X" / "open X in the browser" \
    should be treated as browser navigation if X looks like a URL, \
    or as a web search if X is a phrase.
    - Opening an app that is not a website → single open_app step.
    - Typing text into the current app → single type_text step.

    If the command cannot be mapped to any tool, return an empty tool_calls \
    array and explain briefly in assistant_message.

    Do NOT invent tool names outside the list above.

    Required JSON shape (respond with this exact structure):
    {
      "assistant_message": "short user-facing confirmation, e.g. 'Opening Chrome'",
      "tool_calls": [
        {
          "tool_name": "open_app",
          "arguments": {"name": "Google Chrome"},
          "summary": "Open Google Chrome"
        }
      ]
    }
    """

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Sends `userCommand` to OpenAI gpt-4o-mini and returns a parsed plan payload.
    /// Throws `JarvisClaudePlannerError.missingAPIKey` if no key has been configured.
    func generatePlan(userCommand: String) async throws -> (assistantMessage: String?, rawToolCalls: [[String: Any]]) {
        guard let apiKey = UserDefaults.standard.string(forKey: Self.openAIAPIKeyUserDefaultsKey),
              !apiKey.isEmpty else {
            throw JarvisClaudePlannerError.missingAPIKey
        }

        var request = URLRequest(url: Self.openAICompletionsURL)
        request.httpMethod = "POST"
        // 15-second timeout: generous enough for a fresh gpt-4o-mini response
        // but short enough to not block the voice interaction for too long.
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestBody: [String: Any] = [
            "model": "gpt-4o-mini",
            // response_format: json_object forces valid JSON output — no markdown
            // fences or prose can leak through, so no post-processing is needed.
            "response_format": ["type": "json_object"],
            "temperature": 0,
            "max_completion_tokens": 512,
            "messages": [
                ["role": "system", "content": Self.plannerSystemPrompt],
                ["role": "user", "content": userCommand]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw JarvisClaudePlannerError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw JarvisClaudePlannerError.httpError(httpResponse.statusCode, body)
        }

        // OpenAI response: {"choices": [{"message": {"content": "{...json...}"}}]}
        guard let outerJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = outerJSON["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let responseText = message["content"] as? String else {
            throw JarvisClaudePlannerError.invalidResponse
        }

        guard let planData = responseText.data(using: .utf8),
              let planJSON = try? JSONSerialization.jsonObject(with: planData) as? [String: Any] else {
            throw JarvisClaudePlannerError.invalidJSON(responseText)
        }

        let assistantMessage = planJSON["assistant_message"] as? String
        let rawToolCalls = planJSON["tool_calls"] as? [[String: Any]] ?? []
        return (assistantMessage, rawToolCalls)
    }
}
