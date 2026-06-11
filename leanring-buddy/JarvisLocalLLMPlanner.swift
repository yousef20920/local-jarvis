//
//  JarvisLocalLLMPlanner.swift
//  leanring-buddy
//
//  Local-first planner: deterministic rules for common commands, then Ollama
//  for flexible JSON planning. No cloud LLM fallback is used on the active path.
//

import Foundation

@MainActor
final class JarvisLocalFirstPlanner: JarvisPlanner {
    private let localLLMClient: JarvisLocalLLMClient
    private let ruleBasedFallbackPlanner = JarvisRuleBasedPlanner()

    init(
        localLLMClient: JarvisLocalLLMClient = JarvisLocalLLMClient()
    ) {
        self.localLLMClient = localLLMClient
    }

    func plan(userCommand: String, context: JarvisPlanningContext) async -> JarvisPlan {
        // Tier 1: deterministic rule-based planner for common machine-control commands.
        let rulePlan = await ruleBasedFallbackPlanner.plan(userCommand: userCommand, context: context)
        if !rulePlan.toolCalls.isEmpty {
            print("📐 Jarvis planner: rule-based matched '\(userCommand)'")
            return rulePlan
        }

        if context.shouldUseScreenContext, context.screenContext == nil {
            print("📐 Jarvis planner: screen-context command had no detected target; skipping Ollama fallback")
            return rulePlan
        }

        // Tier 2: local Ollama model for flexible commands not covered by rules.
        if let ollamaPlan = await ollamaPlan(userCommand: userCommand, context: context),
           !ollamaPlan.toolCalls.isEmpty {
            print("🤖 Jarvis planner: Ollama produced \(ollamaPlan.toolCalls.count) tool call(s)")
            return ollamaPlan
        }

        // Both local tiers exhausted — return the rule planner's empty plan so the
        // assistant_message ("I do not have a concrete local action for that yet.")
        // reaches the user instead of a silent failure.
        return rulePlan
    }

    func continuationToolCalls(
        after resultRecord: JarvisToolResultRecord,
        currentWorkflow: JarvisWorkflowState,
        context: JarvisPlanningContext
    ) async -> [JarvisToolCall] {
        []
    }

    // MARK: - Tier 1: Ollama

    private func ollamaPlan(userCommand: String, context: JarvisPlanningContext) async -> JarvisPlan? {
        do {
            let responseText = try await localLLMClient.generateJSON(
                prompt: ollamaPlannerPrompt(userCommand: userCommand, context: context)
            )
            return parsePlanFromJSON(responseText: responseText, userCommand: userCommand)
        } catch {
            print("⚠️ Jarvis Ollama planner unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    private func ollamaPlannerPrompt(userCommand: String, context: JarvisPlanningContext) -> String {
        let toolNames = context.availableTools.map(\.name).joined(separator: ", ")
        let screenContextJSON: String
        if let screenContext = context.screenContext {
            screenContextJSON = """
            {
              "target_description": "\(screenContext.targetDescription)",
              "global_x": \(screenContext.globalX),
              "global_y": \(screenContext.globalY),
              "display_frame_x": \(screenContext.displayFrameX),
              "display_frame_y": \(screenContext.displayFrameY),
              "display_frame_width": \(screenContext.displayFrameWidth),
              "display_frame_height": \(screenContext.displayFrameHeight)
            }
            """
        } else {
            screenContextJSON = "null"
        }

        return """
        You are the local planner for a macOS assistant named Jarvis.
        Return only valid JSON. Do not include markdown.

        Available tools: \(toolNames)

        Supported tool schemas:
        - open_app: {"name": "Google Chrome"}
        - type_text: {"text": "hello"}
        - press_hotkey: {"keys": ["command", "space"]}
        - take_screenshot: {}
        - click_at: {"x": 100.0, "y": 200.0, "display_frame_x": 0.0, "display_frame_y": 0.0, "display_frame_width": 1512.0, "display_frame_height": 982.0, "label": "search bar"}

        Safety:
        - Do not invent tools.
        - For delete/send/purchase/install/terminal/system-settings actions, return no tool calls and explain that confirmation support is not implemented yet.
        - Prefer simple, direct plans.

        Screen context, if available:
        \(screenContextJSON)

        User command:
        \(userCommand)

        JSON shape:
        {
          "assistant_message": "short user-facing status",
          "tool_calls": [
            {
              "tool_name": "open_app",
              "arguments": {"name": "Google Chrome"},
              "summary": "Open Google Chrome"
            }
          ]
        }
        """
    }

    // MARK: - Shared JSON parsing

    private func parsePlanFromJSON(responseText: String, userCommand: String) -> JarvisPlan? {
        guard let data = responseText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let assistantMessage = json["assistant_message"] as? String
        guard let rawToolCalls = json["tool_calls"] as? [[String: Any]] else {
            return JarvisPlan.empty(for: userCommand, assistantMessage: assistantMessage)
        }

        let toolCalls = rawToolCalls.compactMap(parseToolCallFromRawDict)
        return JarvisPlan(userCommand: userCommand, toolCalls: toolCalls, assistantMessage: assistantMessage)
    }

    /// Converts a raw JSON dictionary from Ollama into a typed JarvisToolCall.
    private func parseToolCallFromRawDict(_ rawToolCall: [String: Any]) -> JarvisToolCall? {
        guard let toolName = rawToolCall["tool_name"] as? String else {
            return nil
        }

        let summary = rawToolCall["summary"] as? String ?? toolName
        let rawArguments = rawToolCall["arguments"] as? [String: Any] ?? [:]
        var arguments: [String: JarvisToolArgumentValue] = [:]

        for (key, value) in rawArguments {
            if let stringValue = value as? String {
                arguments[key] = .string(stringValue)
            } else if let booleanValue = value as? Bool {
                arguments[key] = .boolean(booleanValue)
            } else if let numberValue = value as? NSNumber {
                arguments[key] = .number(numberValue.doubleValue)
            } else if let stringArrayValue = value as? [String] {
                arguments[key] = .stringArray(stringArrayValue)
            }
        }

        return JarvisToolCall(
            toolName: toolName,
            arguments: arguments,
            userVisibleSummary: summary
        )
    }
}
