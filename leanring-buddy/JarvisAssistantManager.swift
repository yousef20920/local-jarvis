//
//  JarvisAssistantManager.swift
//  leanring-buddy
//
//  Jarvis coordinator. Screen-independent commands (open app, press hotkey,
//  type, screenshot) run through the deterministic rule planner for instant
//  execution. Everything else runs through the GPT-backed computer-use agent
//  loop, which observes the screen before every action and adapts as it goes.
//

import Combine
import Foundation

enum JarvisAssistantState: Equatable {
    case idle
    case planning
    case waitingForConfirmation(JarvisToolCall, reason: String)
    case executing(currentStep: Int, totalSteps: Int, summary: String)
    case completed(String)
    case failed(String)
}

@MainActor
final class JarvisAssistantManager: ObservableObject {
    typealias ToolVisualizationProvider = (JarvisToolCall) async -> Void

    @Published private(set) var state: JarvisAssistantState = .idle
    @Published private(set) var lastPlan: JarvisPlan?
    @Published private(set) var lastToolResults: [JarvisToolResult] = []
    @Published private(set) var currentWorkflow: JarvisWorkflowState?

    let toolRegistry: JarvisToolRegistry
    let safetyPolicy: JarvisSafetyPolicy
    private let ruleBasedFastPathPlanner = JarvisRuleBasedPlanner()
    private let computerUseAgent: JarvisComputerUseAgent
    private let toolVisualizationProvider: ToolVisualizationProvider?
    private var activeWorkflowID: UUID?

    init(
        toolVisualizationProvider: ToolVisualizationProvider? = nil
    ) {
        let toolRegistry = JarvisToolRegistry()
        JarvisPhaseTwoToolInstaller.registerTools(in: toolRegistry)
        self.toolRegistry = toolRegistry
        self.safetyPolicy = JarvisSafetyPolicy()
        self.computerUseAgent = JarvisComputerUseAgent(
            openAIClient: JarvisOpenAIClient(),
            toolRegistry: toolRegistry,
            safetyPolicy: safetyPolicy
        )
        self.toolVisualizationProvider = toolVisualizationProvider
    }

    init(
        toolRegistry: JarvisToolRegistry,
        safetyPolicy: JarvisSafetyPolicy,
        toolVisualizationProvider: ToolVisualizationProvider? = nil
    ) {
        self.toolRegistry = toolRegistry
        self.safetyPolicy = safetyPolicy
        self.computerUseAgent = JarvisComputerUseAgent(
            openAIClient: JarvisOpenAIClient(),
            toolRegistry: toolRegistry,
            safetyPolicy: safetyPolicy
        )
        self.toolVisualizationProvider = toolVisualizationProvider
    }

    @discardableResult
    func runTextCommand(_ userCommand: String) async -> String {
        let trimmedUserCommand = userCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserCommand.isEmpty else {
            return "Jarvis needs a command before it can act."
        }

        state = .planning
        lastPlan = nil
        lastToolResults = []
        currentWorkflow = nil

        JarvisDebugLogger.log("Manager", "command: \"\(trimmedUserCommand)\"")
        JarvisDebugLogger.logVerbose(
            "Manager",
            "needsScreenContext=\(JarvisRuleBasedPlanner.commandNeedsScreenContext(trimmedUserCommand))"
        )

        // Fast path: deterministic rules for screen-independent commands like
        // "open Chrome" or "press command space". Free and instant — no model
        // call needed. Screen-dependent commands (clicks, anything visual)
        // skip this and go straight to the agent so it grounds its own clicks.
        if !JarvisRuleBasedPlanner.commandNeedsScreenContext(trimmedUserCommand) {
            let planningContext = JarvisPlanningContext(
                availableTools: toolRegistry.definitions,
                shouldUseScreenContext: false,
                screenContext: nil,
                completedToolResults: []
            )
            let rulePlan = await ruleBasedFastPathPlanner.plan(userCommand: trimmedUserCommand, context: planningContext)
            if !rulePlan.toolCalls.isEmpty {
                JarvisDebugLogger.log("Manager", "fast path: \(rulePlan.toolCalls.count) step(s)")
                for (toolCallIndex, toolCall) in rulePlan.toolCalls.enumerated() {
                    JarvisDebugLogger.logVerbose("Manager", "  fast path[\(toolCallIndex + 1)]: \(toolCall.userVisibleSummary)")
                    JarvisDebugLogger.logToolArguments("Manager", toolName: toolCall.toolName, arguments: toolCall.arguments)
                }
                lastPlan = rulePlan
                return await executePlannedToolCalls(rulePlan)
            }
            JarvisDebugLogger.logVerbose("Manager", "rule planner returned no tool calls — falling through to agent")
        } else {
            JarvisDebugLogger.logVerbose("Manager", "command needs screen context — skipping rule fast path")
        }

        // Everything else: the observe-act computer-use agent loop.
        JarvisDebugLogger.log("Manager", "agent loop")
        return await runComputerUseAgentLoop(for: trimmedUserCommand)
    }

    func stop() {
        JarvisDebugLogger.log("Manager", "stop() — cancelling active workflow")
        activeWorkflowID = nil
        state = .idle
        lastPlan = nil
        lastToolResults = []
        currentWorkflow = nil
    }

    // MARK: - Computer-use agent loop

    private func runComputerUseAgentLoop(for userGoal: String) async -> String {
        let workflow = JarvisWorkflowState(userCommand: userGoal, toolCalls: [])
        let workflowID = workflow.id
        activeWorkflowID = workflowID
        currentWorkflow = workflow

        // The agent appends steps as it discovers them, so currentWorkflow is
        // the single source of truth and the panel sees each step live.
        let callbacks = JarvisComputerUseAgentCallbacks(
            isCancelled: { [weak self] in
                self?.activeWorkflowID != workflowID
            },
            onToolCallStarting: { [weak self] toolCall, stepNumber in
                guard let self, var updatedWorkflow = self.currentWorkflow, updatedWorkflow.id == workflowID else { return }
                var newStep = JarvisWorkflowStep(index: updatedWorkflow.steps.count, toolCall: toolCall)
                newStep.status = .running
                updatedWorkflow.steps.append(newStep)
                self.currentWorkflow = updatedWorkflow
                self.state = .executing(
                    currentStep: stepNumber,
                    totalSteps: JarvisComputerUseAgent.maximumStepCount,
                    summary: toolCall.userVisibleSummary
                )
                await self.toolVisualizationProvider?(toolCall)
            },
            onToolCallFinished: { [weak self] toolCall, result, _ in
                guard let self, var updatedWorkflow = self.currentWorkflow, updatedWorkflow.id == workflowID else { return }
                if let stepIndex = updatedWorkflow.steps.firstIndex(where: { $0.toolCall.id == toolCall.id }) {
                    updatedWorkflow.steps[stepIndex].status = result.ok ? .succeeded : .failed
                    updatedWorkflow.steps[stepIndex].resultMessage = result.message
                }
                self.currentWorkflow = updatedWorkflow
                self.lastToolResults.append(result)
            }
        )

        let outcome = await computerUseAgent.run(userGoal: userGoal, callbacks: callbacks)

        // A newer command may have replaced this workflow while the agent ran.
        if activeWorkflowID == workflowID {
            activeWorkflowID = nil
        }

        switch outcome {
        case .completed(let summaryMessage):
            JarvisDebugLogger.log("Manager", "done: \(summaryMessage)")
            state = .completed(summaryMessage)
            return summaryMessage
        case .answered(let answerText):
            JarvisDebugLogger.log("Manager", "answered: \(answerText)")
            state = .completed(answerText)
            return answerText
        case .failed(let failureMessage):
            JarvisDebugLogger.log("Manager", "failed: \(failureMessage)")
            state = .failed(failureMessage)
            return failureMessage
        case .needsConfirmation(let toolCall, let reason):
            JarvisDebugLogger.log("Manager", "needs confirmation: \(reason)")
            JarvisDebugLogger.logToolArguments("Manager", toolName: toolCall.toolName, arguments: toolCall.arguments)
            state = .waitingForConfirmation(toolCall, reason: reason)
            return "That needs confirmation first: \(reason)"
        case .stopped:
            JarvisDebugLogger.logVerbose("Manager", "stopped")
            state = .idle
            return "Stopped."
        }
    }

    // MARK: - Rule-based fast path execution

    private func executePlannedToolCalls(_ plan: JarvisPlan) async -> String {
        var executionResults: [JarvisToolResult] = []
        var workflow = JarvisWorkflowState(userCommand: plan.userCommand, toolCalls: plan.toolCalls)
        activeWorkflowID = workflow.id
        currentWorkflow = workflow

        for stepIndex in workflow.steps.indices {
            guard activeWorkflowID == workflow.id else {
                state = .idle
                return "Stopped."
            }

            let toolCall = workflow.steps[stepIndex].toolCall
            workflow.steps[stepIndex].status = .running
            currentWorkflow = workflow
            state = .executing(
                currentStep: stepIndex + 1,
                totalSteps: workflow.steps.count,
                summary: toolCall.userVisibleSummary
            )

            guard let tool = toolRegistry.tool(named: toolCall.toolName) else {
                let failureResult = JarvisToolResult.failure("Tool not registered: \(toolCall.toolName).")
                executionResults.append(failureResult)
                lastToolResults = executionResults
                workflow.steps[stepIndex].status = .failed
                workflow.steps[stepIndex].resultMessage = failureResult.message
                currentWorkflow = workflow
                state = .failed(failureResult.message)
                return failureResult.message
            }

            let safetyDecision = safetyPolicy.evaluate(toolCall: toolCall, toolDefinition: tool.definition)
            switch safetyDecision {
            case .allow:
                break
            case .requireConfirmation(let reason):
                lastToolResults = executionResults
                workflow.steps[stepIndex].status = .pending
                currentWorkflow = workflow
                state = .waitingForConfirmation(toolCall, reason: reason)
                return "That needs confirmation first: \(reason)"
            case .block(let reason):
                let failureResult = JarvisToolResult.failure(reason)
                executionResults.append(failureResult)
                lastToolResults = executionResults
                workflow.steps[stepIndex].status = .failed
                workflow.steps[stepIndex].resultMessage = reason
                currentWorkflow = workflow
                state = .failed(reason)
                return reason
            }

            await toolVisualizationProvider?(toolCall)

            let result = await tool.execute(
                arguments: toolCall.arguments,
                context: JarvisToolExecutionContext(originalUserCommand: plan.userCommand, isDryRun: false)
            )
            executionResults.append(result)
            lastToolResults = executionResults
            workflow.steps[stepIndex].status = result.ok ? .succeeded : .failed
            workflow.steps[stepIndex].resultMessage = result.message
            currentWorkflow = workflow

            guard result.ok else {
                state = .failed(result.message)
                return result.message
            }

            if stepIndex < workflow.steps.count - 1 {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }

        activeWorkflowID = nil
        let completionMessage = workflowCompletionMessage(for: plan, results: executionResults)
        state = .completed(completionMessage)
        return completionMessage
    }

    private func workflowCompletionMessage(for plan: JarvisPlan, results: [JarvisToolResult]) -> String {
        if plan.toolCalls.count <= 1 {
            return results.last?.message ?? plan.assistantMessage ?? "Done."
        }

        let successfulResultCount = results.filter(\.ok).count
        if let assistantMessage = plan.assistantMessage {
            return "\(assistantMessage) Completed \(successfulResultCount) steps."
        }

        return "Done. Completed \(successfulResultCount) steps."
    }
}
