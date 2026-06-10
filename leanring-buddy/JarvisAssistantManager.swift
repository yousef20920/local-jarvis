//
//  JarvisAssistantManager.swift
//  leanring-buddy
//
//  Phase 1 coordinator for the software-only Jarvis loop. This is intentionally
//  not wired into CompanionManager yet, so existing app behavior stays the
//  same while the Jarvis architecture is introduced.
//

import Foundation

enum JarvisAssistantState: Equatable {
    case idle
    case planning
    case waitingForConfirmation(JarvisToolCall, reason: String)
    case executing
    case completed(String)
    case failed(String)
}

@MainActor
final class JarvisAssistantManager: ObservableObject {
    @Published private(set) var state: JarvisAssistantState = .idle
    @Published private(set) var lastPlan: JarvisPlan?

    let toolRegistry: JarvisToolRegistry
    let safetyPolicy: JarvisSafetyPolicy
    private let planner: any JarvisPlanner

    init() {
        self.toolRegistry = JarvisToolRegistry()
        self.safetyPolicy = JarvisSafetyPolicy()
        self.planner = JarvisPhaseOnePlanner()
    }

    init(
        toolRegistry: JarvisToolRegistry,
        safetyPolicy: JarvisSafetyPolicy,
        planner: any JarvisPlanner
    ) {
        self.toolRegistry = toolRegistry
        self.safetyPolicy = safetyPolicy
        self.planner = planner
    }

    func previewPlan(for userCommand: String) async -> JarvisPlan {
        let trimmedUserCommand = userCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserCommand.isEmpty else {
            let emptyPlan = JarvisPlan.empty(
                for: userCommand,
                assistantMessage: "Jarvis needs a command before it can plan."
            )
            lastPlan = emptyPlan
            return emptyPlan
        }

        state = .planning

        let planningContext = JarvisPlanningContext(
            availableTools: toolRegistry.definitions,
            shouldUseScreenContext: false
        )
        let plan = await planner.plan(userCommand: trimmedUserCommand, context: planningContext)
        lastPlan = plan

        if let firstConfirmationRequirement = firstConfirmationRequirement(in: plan) {
            state = .waitingForConfirmation(
                firstConfirmationRequirement.toolCall,
                reason: firstConfirmationRequirement.reason
            )
        } else {
            state = .completed(plan.assistantMessage ?? "Jarvis created a plan.")
        }

        return plan
    }

    func stop() {
        state = .idle
        lastPlan = nil
    }

    private func firstConfirmationRequirement(in plan: JarvisPlan) -> (toolCall: JarvisToolCall, reason: String)? {
        for toolCall in plan.toolCalls {
            let toolDefinition = toolRegistry.tool(named: toolCall.toolName)?.definition

            switch safetyPolicy.evaluate(toolCall: toolCall, toolDefinition: toolDefinition) {
            case .allow:
                continue
            case .requireConfirmation(let reason), .block(let reason):
                return (toolCall, reason)
            }
        }

        return nil
    }
}
