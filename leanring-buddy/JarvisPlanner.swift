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
