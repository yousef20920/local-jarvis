//
//  JarvisLocalLLMClient.swift
//  leanring-buddy
//
//  Local Ollama-compatible LLM client used by Jarvis. Defaults to Qwen3-VL,
//  a single multimodal model that handles intent routing, computer-use agent
//  turns, and screen-aware companion responses through the native Ollama app.
//

import Foundation

struct JarvisLocalLLMConfiguration {
    let baseURL: URL
    /// Text-only model used by planner-style JSON calls.
    let model: String
    /// Model used for voice intent routing. Defaults to the same reliable
    /// instruction-tuned multimodal model as the agent; smaller text models
    /// are fast, but proved too error-prone for routing real commands.
    let routerModel: String
    /// Vision-capable model used for the computer-use agent loop and the
    /// screen-aware companion response.
    let visionModel: String

    // The bare "qwen3-vl:8b" tag is the *thinking* variant: it burns minutes
    // of thinking tokens per call and, with format=json, leaves the content
    // field empty. The -instruct variant answers directly in seconds.
    static let defaultModelName = "qwen3-vl:8b-instruct"
    static let defaultRouterModelName = defaultModelName

    /// Model tags from earlier phases that are no longer suitable for the
    /// computer-use agent (no GUI grounding, or thinking variants that leave
    /// JSON content empty). If one of these is still stored in UserDefaults
    /// from an old session, it silently overrides the new default and breaks
    /// the agent — so treat it as unset and remove it.
    private static let legacyModelNames: Set<String> = [
        "qwen2.5:7b", "llava:7b", "gemma4:e2b", "gemma4:e4b",
        "qwen3-vl:8b", "qwen3-vl:4b"
    ]
    private static let legacyRouterModelNames: Set<String> = [
        "qwen2.5:0.5b", "qwen2.5:1.5b", "qwen2.5:3b"
    ]

    /// Reads a stored model override, discarding (and deleting) legacy tags
    /// so old sessions cannot silently downgrade the agent's model.
    static func storedModelName(forKey userDefaultsKey: String) -> String? {
        guard let storedModelName = UserDefaults.standard.string(forKey: userDefaultsKey) else {
            return nil
        }
        if legacyModelNames.contains(storedModelName) {
            JarvisDebugLogger.log("LLM", "migrating legacy stored model \"\(storedModelName)\" (key=\(userDefaultsKey)) → \(defaultModelName)")
            UserDefaults.standard.removeObject(forKey: userDefaultsKey)
            return nil
        }
        return storedModelName
    }

    static func storedRouterModelName() -> String? {
        guard let storedModelName = UserDefaults.standard.string(forKey: "jarvisLocalRouterModel") else {
            return nil
        }
        if legacyRouterModelNames.contains(storedModelName) {
            JarvisDebugLogger.log("LLM", "migrating legacy router model \"\(storedModelName)\" → \(defaultRouterModelName)")
            UserDefaults.standard.removeObject(forKey: "jarvisLocalRouterModel")
            return nil
        }
        return storedModelName
    }

    static var current: JarvisLocalLLMConfiguration {
        let storedBaseURL = UserDefaults.standard.string(forKey: "jarvisLocalLLMBaseURL")
        let storedModel = storedModelName(forKey: "jarvisLocalLLMModel")
        let storedRouterModel = storedRouterModelName()
        let storedVisionModel = storedModelName(forKey: "jarvisLocalVisionModel")

        return JarvisLocalLLMConfiguration(
            // 127.0.0.1 avoids URLSession trying IPv6 ::1 first and waiting
            // on connection refused before falling back to IPv4.
            baseURL: URL(string: storedBaseURL ?? "http://127.0.0.1:11434")!,
            model: storedModel ?? defaultModelName,
            routerModel: storedRouterModel ?? defaultRouterModelName,
            visionModel: storedVisionModel ?? defaultModelName
        )
    }
}

enum JarvisLocalLLMError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case httpError(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "The local LLM URL is invalid."
        case .invalidResponse:
            return "The local LLM returned an invalid response."
        case .httpError(let statusCode, let body):
            return "The local LLM returned HTTP \(statusCode): \(body)"
        case .emptyResponse:
            return "The local LLM returned an empty response."
        }
    }
}

final class JarvisLocalLLMClient {
    private let session: URLSession

    init(
        configuration: JarvisLocalLLMConfiguration = .current,
        session: URLSession = .shared
    ) {
        self.session = session
    }

    func generateJSON(prompt: String, imagesBase64: [String] = []) async throws -> String {
        try await generate(
            prompt: prompt,
            model: JarvisLocalLLMConfiguration.current.model,
            imagesBase64: imagesBase64,
            format: "json",
            numPredict: 256
        )
    }

    func generateRouterJSON(prompt: String) async throws -> String {
        try await generate(
            prompt: prompt,
            model: JarvisLocalLLMConfiguration.current.routerModel,
            format: "json",
            timeoutInterval: 12,
            numPredict: 96,
            numContext: 1024
        )
    }

    func generateVisionJSON(prompt: String, imagesBase64: [String]) async throws -> String {
        try await generate(
            prompt: prompt,
            model: JarvisLocalLLMConfiguration.current.visionModel,
            imagesBase64: imagesBase64,
            format: "json",
            timeoutInterval: 90
        )
    }

    func generate(prompt: String, imagesBase64: [String] = [], format: String? = nil) async throws -> String {
        try await generate(
            prompt: prompt,
            model: JarvisLocalLLMConfiguration.current.model,
            imagesBase64: imagesBase64,
            format: format
        )
    }

    private func generate(
        prompt: String,
        model: String,
        imagesBase64: [String] = [],
        format: String? = nil,
        // First call after launch includes model load time, which can take
        // a minute or more for an 8B vision model. Generous timeout so the
        // first command after startup does not fail spuriously.
        timeoutInterval: TimeInterval = 120,
        numPredict: Int? = nil,
        numContext: Int? = nil
    ) async throws -> String {
        let configuration = JarvisLocalLLMConfiguration.current
        let generateURL = configuration.baseURL.appendingPathComponent("api/generate")
        var request = URLRequest(url: generateURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            // Qwen3 models are thinking-capable: without this flag their
            // output can land in the separate "thinking" field, leaving
            // "response" empty (especially with format=json).
            "think": false,
            "options": [
                "temperature": 0.0
            ],
            "keep_alive": "30m"
        ]

        if numPredict != nil || numContext != nil {
            var options: [String: Any] = [
                "temperature": 0.0
            ]
            if let numPredict {
                options["num_predict"] = numPredict
            }
            if let numContext {
                options["num_ctx"] = numContext
            }
            body["options"] = options
        }

        if !imagesBase64.isEmpty {
            body["images"] = imagesBase64
        }

        if let format {
            body["format"] = format
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        JarvisDebugLogger.logVerbose("LLM", "POST \(generateURL.absoluteString) model=\(model) format=\(format ?? "none") timeout=\(timeoutInterval)s")
        let requestStartTime = Date()

        let (data, response) = try await session.data(for: request)
        let elapsedSeconds = Date().timeIntervalSince(requestStartTime)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JarvisLocalLLMError.invalidResponse
        }

        JarvisDebugLogger.logVerbose("LLM", "generate HTTP \(httpResponse.statusCode) in \(String(format: "%.1f", elapsedSeconds))s")

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            JarvisDebugLogger.logMultiline("LLM", title: "generate error response:", body: body)
            throw JarvisLocalLLMError.httpError(httpResponse.statusCode, body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseText = json["response"] as? String else {
            throw JarvisLocalLLMError.invalidResponse
        }

        let trimmedResponse = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResponse.isEmpty else {
            if let thinkingText = json["thinking"] as? String, !thinkingText.isEmpty {
                JarvisDebugLogger.logMultiline("LLM", title: "response empty but thinking field present:", body: thinkingText, maxCharacterCount: 1000)
            }
            throw JarvisLocalLLMError.emptyResponse
        }

        return trimmedResponse
    }

    /// Sends one computer-use agent turn to the local Ollama vision model via
    /// /api/chat: a system prompt describing the action schema, a user prompt
    /// containing the goal plus the history of actions taken so far, and a
    /// fresh screenshot of the current screen. Enforces JSON output so the
    /// response can be parsed into a single next action.
    ///
    /// `screenshotBase64` is optional because text-only JSON callers (like the
    /// voice intent router) also use this method: with qwen3-vl, /api/generate
    /// plus format=json routes the model's output into the "thinking" field
    /// and leaves "response" empty, so /api/chat is the only reliable path.
    func generateComputerUseTurn(
        systemPrompt: String,
        userPrompt: String,
        screenshotBase64: String? = nil,
        modelOverride: String? = nil
    ) async throws -> String {
        let configuration = JarvisLocalLLMConfiguration.current
        let modelName = modelOverride ?? configuration.visionModel
        let chatURL = configuration.baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        // Vision turns can take tens of seconds, and the first call after
        // launch also includes loading the 8B model into memory. 240 seconds
        // keeps slow-but-progressing turns from timing out.
        request.timeoutInterval = 240
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let hasScreenshot = screenshotBase64 != nil
        JarvisDebugLogger.logVerbose(
            "LLM",
            "chat model=\(modelName) vision=\(hasScreenshot) timeout=\(Int(request.timeoutInterval))s"
        )
        JarvisDebugLogger.logMultiline("LLM", title: "system prompt:", body: systemPrompt, maxCharacterCount: 2000)
        JarvisDebugLogger.logMultiline("LLM", title: "user prompt:", body: userPrompt)

        let requestStartTime = Date()

        var currentUserMessage: [String: Any] = [
            "role": "user",
            "content": userPrompt
        ]
        if let screenshotBase64 {
            currentUserMessage["images"] = [screenshotBase64]
        }

        let messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            currentUserMessage
        ]

        let body: [String: Any] = [
            "model": modelName,
            "stream": false,
            "format": "json",
            // Disable Qwen3 thinking so the action JSON arrives in "content"
            // instead of the separate "thinking" field.
            "think": false,
            // Keep the model loaded in GPU memory between agent steps so
            // multi-step tasks do not pay reload latency every turn.
            "keep_alive": "30m",
            "messages": messages,
            "options": [
                "temperature": 0.0,
                // Agent turns are tiny JSON objects — cap generation so the
                // model does not ramble in "reasoning" and burn seconds.
                "num_predict": 256
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        JarvisDebugLogger.logVerbose("LLM", "request body size=\(request.httpBody?.count ?? 0) bytes")

        let (data, response) = try await session.data(for: request)
        let elapsedSeconds = Date().timeIntervalSince(requestStartTime)
        guard let httpResponse = response as? HTTPURLResponse else {
            JarvisDebugLogger.log("LLM", "response invalid after \(String(format: "%.1f", elapsedSeconds))s")
            throw JarvisLocalLLMError.invalidResponse
        }

        JarvisDebugLogger.logVerbose("LLM", "HTTP \(httpResponse.statusCode) in \(String(format: "%.1f", elapsedSeconds))s, \(data.count) bytes")

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "unknown"
            JarvisDebugLogger.logMultiline("LLM", title: "error response:", body: responseBody)
            throw JarvisLocalLLMError.httpError(httpResponse.statusCode, responseBody)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageDict = json["message"] as? [String: Any],
              let content = messageDict["content"] as? String else {
            let rawResponse = String(data: data, encoding: .utf8) ?? "unknown"
            JarvisDebugLogger.logMultiline("LLM", title: "unparseable response:", body: rawResponse)
            throw JarvisLocalLLMError.invalidResponse
        }

        let totalDurationMilliseconds = ((json["total_duration"] as? NSNumber)?.intValue ?? 0) / 1_000_000
        let evalTokenCount = (json["eval_count"] as? NSNumber)?.intValue ?? 0
        JarvisDebugLogger.logVerbose("LLM", "ollama total_duration=\(totalDurationMilliseconds)ms eval_count=\(evalTokenCount)")

        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            JarvisDebugLogger.log("LLM", "empty content in response")
            throw JarvisLocalLLMError.emptyResponse
        }

        let contentPreview = trimmedContent.count > 120
            ? String(trimmedContent.prefix(120)) + "…"
            : trimmedContent
        JarvisDebugLogger.log("LLM", "chat \(String(format: "%.1f", elapsedSeconds))s → \(contentPreview)")
        JarvisDebugLogger.logMultiline("LLM", title: "parsed content:", body: trimmedContent)
        return trimmedContent
    }

    /// Sends a vision + text request to the local Ollama model using the /api/chat
    /// endpoint, which supports both a system message and base64-encoded images in
    /// the same request. Used for companion voice responses that require reading
    /// the user's screen (e.g. "tell me what you see", "explain this code").
    ///
    /// - Parameter imageDataArray: Raw JPEG/PNG data for each screenshot to send.
    ///   The model receives all images simultaneously so it can reason across monitors.
    /// - Parameter conversationHistory: Prior (user, assistant) exchange pairs for
    ///   multi-turn context. Images are only attached to the current user message.
    func generateVisionChat(
        userPrompt: String,
        systemPrompt: String,
        imageDataArray: [Data],
        imageLabels: [String] = [],
        conversationHistory: [(userText: String, assistantText: String)] = []
    ) async throws -> String {
        let configuration = JarvisLocalLLMConfiguration.current
        let chatURL = configuration.baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        // Local vision models take tens of seconds per response, and the first
        // call after launch also includes loading the model into memory.
        request.timeoutInterval = 240
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var messages: [[String: Any]] = []

        // System prompt tells the model how to format its response and how to
        // embed [POINT:x,y:label] tags for cursor animation.
        messages.append(["role": "system", "content": systemPrompt])

        // Inject conversation history as plain text exchanges (no images in history
        // — only the current turn carries screenshots to keep the payload manageable).
        for (userText, assistantText) in conversationHistory {
            messages.append(["role": "user", "content": userText])
            messages.append(["role": "assistant", "content": assistantText])
        }

        // Encode each screenshot as a base64 string. Ollama's /api/chat accepts
        // an "images" array alongside "content" on the user message.
        let base64Images = imageDataArray.map { $0.base64EncodedString() }

        let imageContext: String
        if imageLabels.isEmpty {
            imageContext = ""
        } else {
            imageContext = "\n\nAttached screenshots:\n" + imageLabels.enumerated().map { index, label in
                "Image \(index + 1): \(label)"
            }.joined(separator: "\n")
        }

        var currentUserMessage: [String: Any] = [
            "role": "user",
            "content": userPrompt + imageContext
        ]
        if !base64Images.isEmpty {
            currentUserMessage["images"] = base64Images
        }
        messages.append(currentUserMessage)

        let body: [String: Any] = [
            "model": configuration.visionModel,
            "stream": false,
            // Disable Qwen3 thinking so the spoken reply arrives in "content"
            // instead of the separate "thinking" field.
            "think": false,
            "keep_alive": "30m",
            "messages": messages,
            "options": [
                "temperature": 0.3,
                "num_predict": 512
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw JarvisLocalLLMError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "unknown"
            throw JarvisLocalLLMError.httpError(httpResponse.statusCode, responseBody)
        }

        // /api/chat response: {"message": {"role": "assistant", "content": "..."}}
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageDict = json["message"] as? [String: Any],
              let content = messageDict["content"] as? String else {
            throw JarvisLocalLLMError.invalidResponse
        }

        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            throw JarvisLocalLLMError.emptyResponse
        }

        return trimmedContent
    }
}
