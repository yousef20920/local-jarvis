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

private enum JarvisComputerUseCheckpointStore {
    private static let userDefaultsKey = "JarvisComputerUseCheckpoint.v1"

    static func load() -> JarvisComputerUseCheckpoint? {
        guard let checkpointData = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(JarvisComputerUseCheckpoint.self, from: checkpointData)
    }

    static func save(_ checkpoint: JarvisComputerUseCheckpoint) {
        guard let checkpointData = try? JSONEncoder().encode(checkpoint) else { return }
        UserDefaults.standard.set(checkpointData, forKey: userDefaultsKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }
}

enum JarvisAssistantState: Equatable {
    case idle
    case planning
    case paused(userGoal: String, nextStepNumber: Int)
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
    @Published private(set) var resumableCheckpoint: JarvisComputerUseCheckpoint? = nil

    let toolRegistry: JarvisToolRegistry
    let safetyPolicy: JarvisSafetyPolicy
    private let ruleBasedFastPathPlanner = JarvisRuleBasedPlanner()
    private let computerUseAgent: JarvisComputerUseAgent
    private let toolVisualizationProvider: ToolVisualizationProvider?
    private var activeWorkflowID: UUID?
    private var isConfirmedActionExecuting = false
    private var activeCommandRequestIdentifier: UUID?

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
        restoreSavedCheckpointState()
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
        restoreSavedCheckpointState()
    }

    @discardableResult
    func runTextCommand(_ userCommand: String) async -> String {
        let trimmedUserCommand = userCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserCommand.isEmpty else {
            return "Jarvis needs a command before it can act."
        }
        guard activeCommandRequestIdentifier == nil,
              activeWorkflowID == nil,
              !isConfirmedActionExecuting else {
            return "Jarvis is already running a task. Ask a question, or say Jarvis stop before starting another task."
        }
        let commandRequestIdentifier = UUID()
        activeCommandRequestIdentifier = commandRequestIdentifier
        defer {
            if activeCommandRequestIdentifier == commandRequestIdentifier {
                activeCommandRequestIdentifier = nil
            }
        }

        clearSavedCheckpoint()

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

    @discardableResult
    func runLocalChromeResearch(question: String) async -> String {
        await runTextCommand(Self.localChromeResearchCommand(for: question))
    }

    nonisolated static func localChromeResearchCommand(for question: String) -> String {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else { return "" }

        return """
        Click through Google Chrome on this Mac to research this question:
        \(trimmedQuestion)

        Use the visible Chrome interface for the entire research task. Open or switch to Google Chrome, type a useful search query into Chrome, submit it, inspect the results, click at least one relevant result, and scroll through the page to gather the answer. Do not use a hosted or API web-search tool, the terminal, or model memory as a substitute for browsing. Only answer after the requested browser interactions and after reading current information visible in Chrome.
        """
    }

    func stop() {
        JarvisDebugLogger.log("Manager", "stop() — cancelling active workflow")
        activeWorkflowID = nil
        activeCommandRequestIdentifier = nil
        clearSavedCheckpoint()
        state = .idle
        lastPlan = nil
        lastToolResults = []
        currentWorkflow = nil
    }

    @discardableResult
    func resumeSavedTask() async -> String {
        guard activeWorkflowID == nil, !isConfirmedActionExecuting else {
            return "Jarvis is already running a task."
        }
        guard let resumableCheckpoint else {
            state = .idle
            return "There is no saved Jarvis task to resume."
        }

        if let pendingToolCall = resumableCheckpoint.pendingConfirmationToolCall {
            let confirmationReason = resumableCheckpoint.pendingConfirmationReason
                ?? "This action needs confirmation before Jarvis can continue."
            state = .waitingForConfirmation(pendingToolCall, reason: confirmationReason)
            return "Confirmation required for \(pendingToolCall.userVisibleSummary). \(confirmationReason)"
        }

        state = .planning
        lastPlan = nil
        lastToolResults = []
        currentWorkflow = nil
        return await runComputerUseAgentLoop(
            for: resumableCheckpoint.userGoal,
            checkpoint: resumableCheckpoint
        )
    }

    @discardableResult
    func confirmPendingActionAndResume() async -> String {
        return await executePendingActionAndResume(shouldApproveTerminalAccessForTask: false)
    }

    @discardableResult
    func approveTerminalAccessForTaskAndResume() async -> String {
        return await executePendingActionAndResume(shouldApproveTerminalAccessForTask: true)
    }

    private func executePendingActionAndResume(
        shouldApproveTerminalAccessForTask: Bool
    ) async -> String {
        guard activeWorkflowID == nil, !isConfirmedActionExecuting else {
            return "Jarvis is already running a task."
        }
        guard var checkpoint = resumableCheckpoint,
              let pendingToolCall = checkpoint.pendingConfirmationToolCall else {
            return await resumeSavedTask()
        }
        if shouldApproveTerminalAccessForTask,
           pendingToolCall.toolName != "run_terminal_command" {
            return "Task-wide approval is only available for terminal work."
        }

        guard let tool = toolRegistry.tool(named: pendingToolCall.toolName) else {
            let failureMessage = "Tool not registered: \(pendingToolCall.toolName)."
            state = .failed(failureMessage)
            return failureMessage
        }
        isConfirmedActionExecuting = true

        if shouldApproveTerminalAccessForTask {
            checkpoint.hasApprovedTerminalAccessForTask = true
        }

        let confirmedStepNumber = checkpoint.nextStepNumber
        checkpoint.recentActionHistoryLines.append(
            "Step \(confirmedStepNumber): STARTED user-confirmed \(pendingToolCall.userVisibleSummary). If this task was resumed after interruption, completion is uncertain; inspect current state before repeating it."
        )
        checkpoint.recentActionHistoryLines = Array(checkpoint.recentActionHistoryLines.suffix(100))
        let inFlightHistoryLineIndex = checkpoint.recentActionHistoryLines.count - 1
        checkpoint.nextStepNumber = confirmedStepNumber + 1
        checkpoint.lastUpdatedAt = Date()
        checkpoint.pendingConfirmationToolCall = nil
        checkpoint.pendingConfirmationReason = nil
        saveCheckpoint(checkpoint)

        state = .executing(
            currentStep: confirmedStepNumber,
            totalSteps: JarvisComputerUseAgent.maximumStepCount,
            summary: pendingToolCall.userVisibleSummary
        )
        await toolVisualizationProvider?(pendingToolCall)
        let result = await tool.execute(
            arguments: pendingToolCall.arguments,
            context: JarvisToolExecutionContext(
                originalUserCommand: checkpoint.userGoal,
                isDryRun: false
            )
        )
        isConfirmedActionExecuting = false

        let historyResultMessage = result.message.count > 2_000
            ? String(result.message.prefix(1_997)) + "..."
            : result.message
        checkpoint.recentActionHistoryLines[inFlightHistoryLineIndex] =
            "Step \(confirmedStepNumber): user confirmed \(pendingToolCall.userVisibleSummary)\(shouldApproveTerminalAccessForTask ? " and approved terminal access for this task" : "") → \(historyResultMessage) (\(result.ok ? "executed" : "FAILED"))"
        checkpoint.lastUpdatedAt = Date()
        saveCheckpoint(checkpoint)

        lastToolResults = [result]
        guard !Task.isCancelled else {
            return "Stopped."
        }
        return await runComputerUseAgentLoop(
            for: checkpoint.userGoal,
            checkpoint: checkpoint
        )
    }

    func discardSavedTask() {
        JarvisDebugLogger.log("Manager", "discarding saved task")
        activeWorkflowID = nil
        activeCommandRequestIdentifier = nil
        clearSavedCheckpoint()
        state = .idle
        lastPlan = nil
        lastToolResults = []
        currentWorkflow = nil
    }

    // MARK: - Computer-use agent loop

    private func runComputerUseAgentLoop(
        for userGoal: String,
        checkpoint: JarvisComputerUseCheckpoint? = nil
    ) async -> String {
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
                // A day-long task can discover thousands of actions. Keep the
                // latest rows visible without letting panel rendering or memory
                // grow with the full run history.
                if updatedWorkflow.steps.count >= 50 {
                    updatedWorkflow.steps.removeFirst(updatedWorkflow.steps.count - 49)
                }
                var newStep = JarvisWorkflowStep(index: stepNumber - 1, toolCall: toolCall)
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
                if self.lastToolResults.count > 100 {
                    self.lastToolResults.removeFirst(self.lastToolResults.count - 100)
                }
            },
            onCheckpointUpdated: { [weak self] checkpoint in
                self?.saveCheckpoint(checkpoint)
            }
        )

        let outcome = await computerUseAgent.run(
            userGoal: userGoal,
            checkpoint: checkpoint,
            callbacks: callbacks
        )

        // A newer command may have replaced this workflow while the agent ran.
        if activeWorkflowID == workflowID {
            activeWorkflowID = nil
        }

        switch outcome {
        case .completed(let summaryMessage):
            JarvisDebugLogger.log("Manager", "done: \(summaryMessage)")
            state = .completed(summaryMessage)
            clearSavedCheckpoint()
            return summaryMessage
        case .answered(let answerText):
            JarvisDebugLogger.log("Manager", "answered: \(answerText)")
            state = .completed(answerText)
            clearSavedCheckpoint()
            return answerText
        case .failed(let failureMessage):
            JarvisDebugLogger.log("Manager", "failed: \(failureMessage)")
            state = .failed(failureMessage)
            return failureMessage
        case .needsConfirmation(let toolCall, let reason):
            JarvisDebugLogger.log("Manager", "needs confirmation: \(reason)")
            JarvisDebugLogger.logToolArguments("Manager", toolName: toolCall.toolName, arguments: toolCall.arguments)
            state = .waitingForConfirmation(toolCall, reason: reason)
            return "Confirmation required for \(toolCall.userVisibleSummary). \(reason)"
        case .stopped:
            JarvisDebugLogger.logVerbose("Manager", "stopped")
            state = .idle
            return "Stopped."
        }
    }

    private func restoreSavedCheckpointState() {
        guard let savedCheckpoint = JarvisComputerUseCheckpointStore.load() else { return }
        resumableCheckpoint = savedCheckpoint

        if let pendingToolCall = savedCheckpoint.pendingConfirmationToolCall {
            state = .waitingForConfirmation(
                pendingToolCall,
                reason: savedCheckpoint.pendingConfirmationReason
                    ?? "This action needs confirmation before Jarvis can continue."
            )
        } else {
            state = .paused(
                userGoal: savedCheckpoint.userGoal,
                nextStepNumber: savedCheckpoint.nextStepNumber
            )
        }
    }

    private func saveCheckpoint(_ checkpoint: JarvisComputerUseCheckpoint) {
        JarvisComputerUseCheckpointStore.save(checkpoint)
        resumableCheckpoint = checkpoint
    }

    private func clearSavedCheckpoint() {
        JarvisComputerUseCheckpointStore.clear()
        resumableCheckpoint = nil
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
                return "Confirmation required for \(toolCall.userVisibleSummary). \(reason)"
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
