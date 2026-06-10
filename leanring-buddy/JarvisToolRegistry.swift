//
//  JarvisToolRegistry.swift
//  leanring-buddy
//
//  Registry for local macOS tools Jarvis can execute after planning and safety
//  checks. It starts empty in Phase 1 so no new machine-control behavior is
//  enabled accidentally.
//

import Foundation

@MainActor
final class JarvisToolRegistry {
    private var toolsByName: [String: any JarvisTool] = [:]

    var definitions: [JarvisToolDefinition] {
        toolsByName.values
            .map(\.definition)
            .sorted { firstDefinition, secondDefinition in
                firstDefinition.name < secondDefinition.name
            }
    }

    func register(_ tool: any JarvisTool) {
        toolsByName[tool.definition.name] = tool
    }

    func tool(named name: String) -> (any JarvisTool)? {
        toolsByName[name]
    }

    func containsTool(named name: String) -> Bool {
        toolsByName[name] != nil
    }
}
