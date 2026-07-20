//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Foundation
import CoreGraphics
import Testing
@testable import leanring_buddy

struct leanring_buddyTests {

    @Test @MainActor func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test @MainActor func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test @MainActor func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func computerUseCheckpointRoundTripsPendingConfirmation() throws {
        let pendingToolCall = JarvisToolCall(
            toolName: "run_terminal_command",
            arguments: [
                "command": .string("swift test"),
                "working_directory": .string("/tmp/project")
            ],
            userVisibleSummary: "Run tests"
        )
        let checkpoint = JarvisComputerUseCheckpoint(
            userGoal: "Run the test suite",
            recentActionHistoryLines: ["Step 1: opened the project"],
            nextStepNumber: 2,
            pendingConfirmationToolCall: pendingToolCall,
            pendingConfirmationReason: "Terminal access requires confirmation.",
            hasApprovedTerminalAccessForTask: true
        )

        let encodedCheckpoint = try JSONEncoder().encode(checkpoint)
        let decodedCheckpoint = try JSONDecoder().decode(
            JarvisComputerUseCheckpoint.self,
            from: encodedCheckpoint
        )

        #expect(decodedCheckpoint == checkpoint)
    }

    @Test func olderCheckpointWithoutTerminalApprovalDecodesAsUnapproved() throws {
        let checkpoint = JarvisComputerUseCheckpoint(userGoal: "Continue the task")
        let encodedCheckpoint = try JSONEncoder().encode(checkpoint)
        var checkpointJSON = try #require(
            JSONSerialization.jsonObject(with: encodedCheckpoint) as? [String: Any]
        )
        checkpointJSON.removeValue(forKey: "hasApprovedTerminalAccessForTask")
        let legacyCheckpointData = try JSONSerialization.data(withJSONObject: checkpointJSON)

        let decodedCheckpoint = try JSONDecoder().decode(
            JarvisComputerUseCheckpoint.self,
            from: legacyCheckpointData
        )

        #expect(!decodedCheckpoint.hasApprovedTerminalAccessForTask)
    }

    @Test @MainActor func terminalActionRequiresAnAbsoluteWorkingDirectory() {
        let relativeDirectoryAction = JarvisComputerUseAgent.parseModelAction(
            from: #"{"action":"run_terminal_command","command":"swift test","working_directory":"project"}"#
        )
        let screenCapture = CompanionScreenCapture(
            imageData: Data(),
            label: "test screen",
            isCursorScreen: true,
            displayWidthInPoints: 1920,
            displayHeightInPoints: 1080,
            displayFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 720
        )

        let toolCall = relativeDirectoryAction.flatMap { modelAction in
            JarvisComputerUseAgent.toolCall(
                from: modelAction,
                screenCapture: screenCapture
            )
        }

        #expect(toolCall == nil)
    }

    @Test @MainActor func terminalActionPreservesTheExactCommandForConfirmation() {
        let exactCommand = "swift test --filter Jarvis"
        let modelAction = JarvisComputerUseAgent.parseModelAction(
            from: #"{"action":"run_terminal_command","command":"swift test --filter Jarvis","working_directory":"/tmp/project"}"#
        )
        let screenCapture = CompanionScreenCapture(
            imageData: Data(),
            label: "test screen",
            isCursorScreen: true,
            displayWidthInPoints: 1920,
            displayHeightInPoints: 1080,
            displayFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 720
        )

        let toolCall = modelAction.flatMap { parsedModelAction in
            JarvisComputerUseAgent.toolCall(
                from: parsedModelAction,
                screenCapture: screenCapture
            )
        }

        #expect(toolCall?.toolName == "run_terminal_command")
        #expect(toolCall?.arguments["command"]?.stringValue == exactCommand)
        #expect(toolCall?.arguments["working_directory"]?.stringValue == "/tmp/project")
    }

    @Test @MainActor func pointerLoopSignatureIncludesTheTargetScreen() {
        let firstScreenAction = JarvisComputerUseAgent.parseModelAction(
            from: #"{"action":"left_click","screen_number":1,"coordinate":[200,300]}"#
        )
        let secondScreenAction = JarvisComputerUseAgent.parseModelAction(
            from: #"{"action":"left_click","screen_number":2,"coordinate":[200,300]}"#
        )

        let firstScreenSignature = firstScreenAction.flatMap {
            JarvisComputerUseAgent.pointerActionSignature(for: $0)
        }
        let secondScreenSignature = secondScreenAction.flatMap {
            JarvisComputerUseAgent.pointerActionSignature(for: $0)
        }

        #expect(firstScreenSignature != secondScreenSignature)
    }

    @Test @MainActor func transientModelFailureRetriesWithoutRepeatingAnAction() async throws {
        var operationAttemptCount = 0

        let operationResult: String = try await JarvisComputerUseAgent.performRetriableOperation(
            operationName: "test model request",
            maximumAttemptCount: 2,
            isCancelled: { false },
            shouldRetry: { _ in true },
            retryDelayNanosecondsProvider: { _ in 0 }
        ) {
            operationAttemptCount += 1
            if operationAttemptCount == 1 {
                throw URLError(.timedOut)
            }
            return "recovered"
        }

        #expect(operationResult == "recovered")
        #expect(operationAttemptCount == 2)
    }

    @Test @MainActor func modelRetryPolicyDoesNotRetryCredentialFailures() {
        #expect(JarvisComputerUseAgent.shouldRetryModelRequest(
            JarvisOpenAIClientError.httpError(429, "rate limited")
        ))
        #expect(!JarvisComputerUseAgent.shouldRetryModelRequest(
            JarvisOpenAIClientError.httpError(401, "unauthorized")
        ))
        #expect(!JarvisComputerUseAgent.shouldRetryModelRequest(
            JarvisOpenAIClientError.invalidProxyURL
        ))
    }

    @Test @MainActor func consequentialClickUsesTheConfirmationSafetyGate() throws {
        let modelAction = JarvisComputerUseAgent.parseModelAction(
            from: #"{"action":"confirm_click","screen_number":1,"coordinate":[640,420],"label":"send the email to alex@example.com"}"#
        )
        let screenCapture = CompanionScreenCapture(
            imageData: Data(),
            label: "test screen",
            isCursorScreen: true,
            displayWidthInPoints: 1920,
            displayHeightInPoints: 1080,
            displayFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 720
        )
        let toolCall = modelAction.flatMap { parsedModelAction in
            JarvisComputerUseAgent.toolCall(
                from: parsedModelAction,
                screenCapture: screenCapture
            )
        }

        let requiredToolCall = try #require(toolCall)
        #expect(requiredToolCall.toolName == "confirm_click_at")
        #expect(requiredToolCall.userVisibleSummary == "Approve send the email to alex@example.com")
        #expect(JarvisSafetyPolicy().evaluate(toolCall: requiredToolCall, toolDefinition: nil) == .requireConfirmation(
            reason: "This action can change data, send information, or affect system state."
        ))
    }

    @Test @MainActor func consequentialActionWithoutADescriptionIsRejected() {
        let modelAction = JarvisComputerUseAgent.parseModelAction(
            from: #"{"action":"confirm_key","keys":["command","return"]}"#
        )
        let screenCapture = CompanionScreenCapture(
            imageData: Data(),
            label: "test screen",
            isCursorScreen: true,
            displayWidthInPoints: 1920,
            displayHeightInPoints: 1080,
            displayFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 720
        )

        let toolCall = modelAction.flatMap { parsedModelAction in
            JarvisComputerUseAgent.toolCall(
                from: parsedModelAction,
                screenCapture: screenCapture
            )
        }

        #expect(toolCall == nil)
    }

    @Test func productNamesAndResearchRequestsAreNotMistakenForMacCommands() {
        #expect(!JarvisVoiceIntentRouter.hasExplicitControlCommand("what is openai?"))
        #expect(!JarvisVoiceIntentRouter.hasExplicitControlCommand("research the latest battery technology"))
        #expect(JarvisVoiceIntentRouter.hasExplicitControlCommand("open safari"))
        #expect(JarvisVoiceIntentRouter.hasExplicitControlCommand("please search for local restaurants"))
    }

    @Test func informationalImperativesUseLocalChromeResearchFallback() {
        let fallbackDecision = JarvisVoiceIntentRouter.fallbackDecision(
            for: "Research the latest battery technology",
            reason: "router unavailable"
        )

        #expect(fallbackDecision.route == .localChromeResearch)
        #expect(fallbackDecision.visionPrompt == "Research the latest battery technology")
    }

    @Test func factualOpenAIQuestionOverridesAnIncorrectActionRoute() {
        let correctedDecision = JarvisVoiceIntentRouter.parseDecision(
            responseText: #"{"route":"action","action_command":"What is OpenAI?","vision_prompt":"","reason":"incorrect model route"}"#,
            fallbackTranscript: "What is OpenAI?"
        )

        #expect(correctedDecision.route == .localChromeResearch)
        #expect(correctedDecision.visionPrompt == "What is OpenAI?")
    }

    @Test func localChromeResearchCommandRequiresVisibleBrowserInteractions() {
        let researchCommand = JarvisAssistantManager.localChromeResearchCommand(
            for: "Find the cheapest current price"
        )

        #expect(researchCommand.contains("Google Chrome"))
        #expect(researchCommand.contains("type a useful search query"))
        #expect(researchCommand.contains("click at least one relevant result"))
        #expect(researchCommand.contains("scroll through the page"))
        #expect(researchCommand.contains("Find the cheapest current price"))
        #expect(JarvisRuleBasedPlanner.commandNeedsScreenContext(researchCommand))
    }

    @Test func searchFollowedByAnAnswerUsesLocalChromeResearch() {
        let correctedDecision = JarvisVoiceIntentRouter.parseDecision(
            responseText: #"{"route":"action_then_vision","action_command":"search for current battery prices","vision_prompt":"tell me which is cheapest","reason":"search plus answer"}"#,
            fallbackTranscript: "Search for current battery prices and tell me which is cheapest"
        )

        #expect(correctedDecision.route == .localChromeResearch)
        #expect(correctedDecision.visionPrompt == "Search for current battery prices and tell me which is cheapest")
    }

    @Test @MainActor func taskTerminalApprovalDoesNotBypassOtherSafetyGates() {
        let terminalToolCall = JarvisToolCall(
            toolName: "run_terminal_command",
            userVisibleSummary: "Run tests"
        )
        let consequentialClickToolCall = JarvisToolCall(
            toolName: "confirm_click_at",
            userVisibleSummary: "Approve sending the email"
        )

        #expect(JarvisComputerUseAgent.isToolCallCoveredByTaskTerminalApproval(
            terminalToolCall,
            hasApprovedTerminalAccessForTask: true
        ))
        #expect(!JarvisComputerUseAgent.isToolCallCoveredByTaskTerminalApproval(
            consequentialClickToolCall,
            hasApprovedTerminalAccessForTask: true
        ))
        #expect(!JarvisComputerUseAgent.isToolCallCoveredByTaskTerminalApproval(
            terminalToolCall,
            hasApprovedTerminalAccessForTask: false
        ))
    }

}
