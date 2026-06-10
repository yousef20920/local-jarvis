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
    @Published private(set) var lastToolResults: [JarvisToolResult] = []

    let toolRegistry: JarvisToolRegistry
    let safetyPolicy: JarvisSafetyPolicy
    private let planner: any JarvisPlanner

    init() {
        let toolRegistry = JarvisToolRegistry()
        JarvisPhaseTwoToolInstaller.registerTools(in: toolRegistry)
        self.toolRegistry = toolRegistry
        self.safetyPolicy = JarvisSafetyPolicy()
        self.planner = JarvisRuleBasedPlanner()
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

    func runTextCommand(_ userCommand: String) async {
        let plan = await previewPlan(for: userCommand)
        guard !plan.toolCalls.isEmpty else { return }

        var executionResults: [JarvisToolResult] = []
        state = .executing

        for toolCall in plan.toolCalls {
            guard let tool = toolRegistry.tool(named: toolCall.toolName) else {
                let failureResult = JarvisToolResult.failure("Tool not registered: \(toolCall.toolName).")
                executionResults.append(failureResult)
                lastToolResults = executionResults
                state = .failed(failureResult.message)
                return
            }

            let safetyDecision = safetyPolicy.evaluate(toolCall: toolCall, toolDefinition: tool.definition)
            switch safetyDecision {
            case .allow:
                break
            case .requireConfirmation(let reason):
                lastToolResults = executionResults
                state = .waitingForConfirmation(toolCall, reason: reason)
                return
            case .block(let reason):
                let failureResult = JarvisToolResult.failure(reason)
                executionResults.append(failureResult)
                lastToolResults = executionResults
                state = .failed(reason)
                return
            }

            let result = await tool.execute(
                arguments: toolCall.arguments,
                context: JarvisToolExecutionContext(originalUserCommand: plan.userCommand, isDryRun: false)
            )
            executionResults.append(result)
            lastToolResults = executionResults

            guard result.ok else {
                state = .failed(result.message)
                return
            }
        }

        let completionMessage = executionResults.last?.message ?? plan.assistantMessage ?? "Done."
        state = .completed(completionMessage)
    }

    func previewPlan(for userCommand: String) async -> JarvisPlan {
        let trimmedUserCommand = userCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserCommand.isEmpty else {
            let emptyPlan = JarvisPlan.empty(
                for: userCommand,
                assistantMessage: "Jarvis needs a command before it can plan."
            )
            lastPlan = emptyPlan
            lastToolResults = []
            return emptyPlan
        }

        state = .planning
        lastToolResults = []

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
        lastToolResults = []
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
