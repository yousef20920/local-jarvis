//
//  JarvisTool.swift
//  leanring-buddy
//
//  Shared contracts for Jarvis desktop tools. Phase 1 only defines the
//  contracts; concrete tools are added after the assistant loop is isolated.
//

import Foundation

enum JarvisToolArgumentValue: Equatable, Codable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case stringArray([String])

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum ValueType: String, Codable {
        case string
        case number
        case boolean
        case stringArray
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let valueType = try container.decode(ValueType.self, forKey: .type)

        switch valueType {
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        case .number:
            self = .number(try container.decode(Double.self, forKey: .value))
        case .boolean:
            self = .boolean(try container.decode(Bool.self, forKey: .value))
        case .stringArray:
            self = .stringArray(try container.decode([String].self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .string(let value):
            try container.encode(ValueType.string, forKey: .type)
            try container.encode(value, forKey: .value)
        case .number(let value):
            try container.encode(ValueType.number, forKey: .type)
            try container.encode(value, forKey: .value)
        case .boolean(let value):
            try container.encode(ValueType.boolean, forKey: .type)
            try container.encode(value, forKey: .value)
        case .stringArray(let value):
            try container.encode(ValueType.stringArray, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self {
            return value
        }
        return nil
    }

    var booleanValue: Bool? {
        if case .boolean(let value) = self {
            return value
        }
        return nil
    }

    var stringArrayValue: [String]? {
        if case .stringArray(let value) = self {
            return value
        }
        return nil
    }
}

struct JarvisToolDefinition: Equatable {
    let name: String
    let summary: String
    let requiredArgumentNames: [String]
    let optionalArgumentNames: [String]
    let defaultRequiresConfirmation: Bool
}

struct JarvisToolCall: Codable, Equatable, Identifiable {
    let id: UUID
    let toolName: String
    let arguments: [String: JarvisToolArgumentValue]
    let userVisibleSummary: String

    init(
        id: UUID = UUID(),
        toolName: String,
        arguments: [String: JarvisToolArgumentValue] = [:],
        userVisibleSummary: String
    ) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
        self.userVisibleSummary = userVisibleSummary
    }
}

struct JarvisToolExecutionContext {
    let originalUserCommand: String
    let isDryRun: Bool
}

struct JarvisToolResult: Equatable {
    let ok: Bool
    let message: String
    let data: [String: JarvisToolArgumentValue]

    static func success(_ message: String, data: [String: JarvisToolArgumentValue] = [:]) -> JarvisToolResult {
        JarvisToolResult(ok: true, message: message, data: data)
    }

    static func failure(_ message: String, data: [String: JarvisToolArgumentValue] = [:]) -> JarvisToolResult {
        JarvisToolResult(ok: false, message: message, data: data)
    }
}

@MainActor
protocol JarvisTool {
    var definition: JarvisToolDefinition { get }

    func execute(
        arguments: [String: JarvisToolArgumentValue],
        context: JarvisToolExecutionContext
    ) async -> JarvisToolResult
}
