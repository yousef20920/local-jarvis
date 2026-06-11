//
//  JarvisWorkflowState.swift
//  leanring-buddy
//
//  Observable workflow progress for multi-step Jarvis commands.
//

import Foundation

enum JarvisWorkflowStepStatus: Equatable {
    case pending
    case running
    case succeeded
    case failed
}

struct JarvisWorkflowStep: Equatable, Identifiable {
    let id: UUID
    let index: Int
    let toolCall: JarvisToolCall
    var status: JarvisWorkflowStepStatus
    var resultMessage: String?

    init(index: Int, toolCall: JarvisToolCall) {
        self.id = toolCall.id
        self.index = index
        self.toolCall = toolCall
        self.status = .pending
        self.resultMessage = nil
    }
}

struct JarvisWorkflowState: Equatable {
    let id: UUID
    let userCommand: String
    var steps: [JarvisWorkflowStep]

    init(id: UUID = UUID(), userCommand: String, toolCalls: [JarvisToolCall]) {
        self.id = id
        self.userCommand = userCommand
        self.steps = toolCalls.enumerated().map { stepIndex, toolCall in
            JarvisWorkflowStep(index: stepIndex, toolCall: toolCall)
        }
    }

    var completedStepCount: Int {
        steps.filter { $0.status == .succeeded }.count
    }

    var totalStepCount: Int {
        steps.count
    }
}
