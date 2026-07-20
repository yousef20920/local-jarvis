//
//  JarvisOpenAIClient.swift
//  leanring-buddy
//
//  Worker-backed OpenAI Responses API client for Jarvis. The macOS app sends
//  prompts and screenshots to the Cloudflare Worker; the Worker owns the
//  OpenAI API key and model selection.
//

import Foundation

struct JarvisOpenAIConfiguration {
    static let modelDisplayName = "GPT-5.5"
    static let defaultResponsesProxyURL = "http://127.0.0.1:8787/responses"

    static var responsesProxyURL: String {
        AppBundleConfiguration.stringValue(forKey: "JarvisOpenAIResponsesProxyURL")
            ?? defaultResponsesProxyURL
    }
}

enum JarvisOpenAIClientError: LocalizedError {
    case invalidProxyURL
    case invalidResponse
    case httpError(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidProxyURL:
            return "The OpenAI Worker URL is invalid."
        case .invalidResponse:
            return "The OpenAI Worker returned an invalid response."
        case .httpError(let statusCode, let body):
            return "The OpenAI Worker returned HTTP \(statusCode): \(body)"
        case .emptyResponse:
            return "GPT returned an empty response."
        }
    }
}

struct JarvisInternetSource: Equatable, Identifiable {
    let title: String
    let url: URL

    var id: String {
        url.absoluteString
    }
}

struct JarvisWebGroundedAnswer: Equatable {
    let spokenAnswer: String
    let sources: [JarvisInternetSource]
}

final class JarvisOpenAIClient {
    private let responsesProxyURLString: String
    private let session: URLSession

    init(responsesProxyURLString: String = JarvisOpenAIConfiguration.responsesProxyURL) {
        self.responsesProxyURLString = responsesProxyURLString

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration)
    }

    func generateComputerUseTurn(
        systemPrompt: String,
        userPrompt: String,
        screenshotBase64Array: [String] = [],
        screenshotLabels: [String] = []
    ) async throws -> String {
        var contentBlocks: [[String: Any]] = [
            ["type": "input_text", "text": userPrompt]
        ]

        for screenshotIndex in screenshotBase64Array.indices {
            let screenshotBase64 = screenshotBase64Array[screenshotIndex]
            guard !screenshotBase64.isEmpty else { continue }
            let screenshotLabel = screenshotIndex < screenshotLabels.count
                ? screenshotLabels[screenshotIndex]
                : "Screen \(screenshotIndex + 1)"
            contentBlocks.append(["type": "input_text", "text": screenshotLabel])
            contentBlocks.append([
                "type": "input_image",
                "image_url": "data:image/jpeg;base64,\(screenshotBase64)",
                "detail": "original"
            ])
        }

        let input: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": contentBlocks]
        ]

        return try await createResponse(
            input: input,
            requiresJSONOutput: true,
            reasoningEffort: "low",
            textVerbosity: "low"
        )
    }

    func generateVisionChat(
        userPrompt: String,
        systemPrompt: String,
        imageDataArray: [Data],
        imageLabels: [String],
        conversationHistory: [(userText: String, assistantText: String)]
    ) async throws -> String {
        var input: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]

        for historyEntry in conversationHistory {
            input.append(["role": "user", "content": historyEntry.userText])
            input.append(["role": "assistant", "content": historyEntry.assistantText])
        }

        var contentBlocks: [[String: Any]] = []
        for imageIndex in imageDataArray.indices {
            let imageLabel = imageIndex < imageLabels.count
                ? imageLabels[imageIndex]
                : "Screen \(imageIndex + 1)"

            contentBlocks.append(["type": "input_text", "text": imageLabel])
            contentBlocks.append([
                "type": "input_image",
                "image_url": "data:image/jpeg;base64,\(imageDataArray[imageIndex].base64EncodedString())",
                "detail": "original"
            ])
        }
        contentBlocks.append(["type": "input_text", "text": userPrompt])
        input.append(["role": "user", "content": contentBlocks])

        return try await createResponse(
            input: input,
            requiresJSONOutput: false,
            reasoningEffort: "low",
            textVerbosity: "low"
        )
    }

    /// Answers an informational question with a required live web search.
    /// Browser automation remains available for user-directed browsing tasks;
    /// this path is for fast, source-backed spoken answers.
    func generateWebGroundedAnswer(
        userPrompt: String,
        conversationHistory: [(userText: String, assistantText: String)]
    ) async throws -> JarvisWebGroundedAnswer {
        var input: [[String: Any]] = [
            [
                "role": "system",
                "content": """
                You are Jarvis, a concise voice assistant. You must use live web search before answering.
                Answer only with claims supported by the web results from this request. If the sources do not support a reliable answer, say that you could not verify it instead of filling gaps from memory.
                Write one or two natural spoken sentences unless the user asks for detail. Mention useful source or publication names naturally. Do not use markdown, bullet points, raw URLs, or citation markup because the answer will be spoken aloud. The app displays the clickable sources separately.
                """
            ]
        ]

        for historyEntry in conversationHistory.suffix(5) {
            input.append(["role": "user", "content": historyEntry.userText])
            input.append(["role": "assistant", "content": historyEntry.assistantText])
        }
        input.append(["role": "user", "content": userPrompt])

        let body: [String: Any] = [
            "input": input,
            "reasoning": ["effort": "low"],
            "text": ["verbosity": "low"],
            "tools": [[
                "type": "web_search",
                "external_web_access": true
            ]],
            // The product promise is that informational answers are grounded
            // in the internet, so searching cannot be left to model choice.
            "tool_choice": "required",
            "include": ["web_search_call.action.sources"]
        ]

        let responseJSON = try await sendResponseRequest(body: body)
        let answerText = Self.extractOutputText(from: responseJSON)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !answerText.isEmpty else {
            throw JarvisOpenAIClientError.emptyResponse
        }

        let internetSources = Self.extractInternetSources(from: responseJSON)
        guard !internetSources.isEmpty else {
            // A search call without cited evidence is not strong enough to
            // satisfy Jarvis' internet-grounding promise.
            throw JarvisOpenAIClientError.emptyResponse
        }

        return JarvisWebGroundedAnswer(
            spokenAnswer: Self.removingInlineCitationMarkers(from: answerText),
            sources: internetSources
        )
    }

    private func createResponse(
        input: [[String: Any]],
        requiresJSONOutput: Bool,
        reasoningEffort: String,
        textVerbosity: String
    ) async throws -> String {
        var textOptions: [String: Any] = ["verbosity": textVerbosity]
        if requiresJSONOutput {
            textOptions["format"] = ["type": "json_object"]
        }

        let body: [String: Any] = [
            "input": input,
            "reasoning": ["effort": reasoningEffort],
            "text": textOptions
        ]

        let responseJSON = try await sendResponseRequest(body: body)

        guard let outputText = Self.extractOutputText(from: responseJSON)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty else {
            throw JarvisOpenAIClientError.emptyResponse
        }

        JarvisDebugLogger.logVerbose("OpenAI", "response chars=\(outputText.count)")
        return outputText
    }

    private func sendResponseRequest(body: [String: Any]) async throws -> [String: Any] {
        guard let responsesProxyURL = URL(string: responsesProxyURLString) else {
            throw JarvisOpenAIClientError.invalidProxyURL
        }

        let requestBody = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: responsesProxyURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestBody

        let payloadMegabytes = Double(requestBody.count) / 1_048_576.0
        JarvisDebugLogger.logVerbose(
            "OpenAI",
            "Worker request: \(String(format: "%.1f", payloadMegabytes))MB"
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JarvisOpenAIClientError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "unknown"
            throw JarvisOpenAIClientError.httpError(httpResponse.statusCode, responseBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JarvisOpenAIClientError.invalidResponse
        }

        return json
    }

    private static func extractOutputText(from json: [String: Any]) -> String {
        if let outputText = json["output_text"] as? String {
            return outputText
        }

        guard let outputItems = json["output"] as? [[String: Any]] else {
            return ""
        }

        var textParts: [String] = []
        for outputItem in outputItems {
            guard let contentItems = outputItem["content"] as? [[String: Any]] else {
                continue
            }

            for contentItem in contentItems {
                if let text = contentItem["text"] as? String {
                    textParts.append(text)
                } else if let text = contentItem["output_text"] as? String {
                    textParts.append(text)
                }
            }
        }

        return textParts.joined()
    }

    private static func extractInternetSources(from json: [String: Any]) -> [JarvisInternetSource] {
        guard let outputItems = json["output"] as? [[String: Any]] else {
            return []
        }

        var sources: [JarvisInternetSource] = []
        var seenURLs = Set<String>()

        for outputItem in outputItems {
            guard let contentItems = outputItem["content"] as? [[String: Any]] else {
                continue
            }

            for contentItem in contentItems {
                guard let annotations = contentItem["annotations"] as? [[String: Any]] else {
                    continue
                }

                for annotation in annotations where annotation["type"] as? String == "url_citation" {
                    let citation = annotation["url_citation"] as? [String: Any] ?? annotation
                    guard let urlString = citation["url"] as? String,
                          let url = URL(string: urlString),
                          seenURLs.insert(urlString).inserted else {
                        continue
                    }

                    let citationTitle = (citation["title"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let displayTitle = citationTitle.flatMap { title in
                        title.isEmpty ? nil : title
                    } ?? url.host ?? "Source"
                    sources.append(JarvisInternetSource(
                        title: displayTitle,
                        url: url
                    ))
                }
            }
        }

        return Array(sources.prefix(5))
    }

    private static func removingInlineCitationMarkers(from answerText: String) -> String {
        let citationPatterns = [
            #"cite[^]*"#,
            #"【[^】]*】"#
        ]

        var spokenAnswer = answerText
        for citationPattern in citationPatterns {
            spokenAnswer = spokenAnswer.replacingOccurrences(
                of: citationPattern,
                with: "",
                options: .regularExpression
            )
        }

        return spokenAnswer
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
