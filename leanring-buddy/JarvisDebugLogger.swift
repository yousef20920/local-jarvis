//
//  JarvisDebugLogger.swift
//  leanring-buddy
//
//  Console logging for the Jarvis pipeline. Every line uses the
//  "🐛 [Jarvis:<category>]" prefix so you can filter Xcode's console.
//
//  Verbosity:
//  - .normal (default): routing, agent step summaries, clicks, outcomes, errors
//  - .verbose: full prompts, raw model JSON, coordinate math, tool args, HTTP details
//

import AppKit
import Foundation

enum JarvisDebugLogger {
    enum Verbosity {
        case normal
        case verbose
    }

    static var isEnabled = true
    static var verbosity: Verbosity = .normal

    static func log(_ category: String, _ message: String) {
        guard isEnabled else { return }
        print("🐛 [Jarvis:\(category)] \(message)")
    }

    /// Detailed tracing — prompts, HTTP metadata, coordinate math, etc.
    static func logVerbose(_ category: String, _ message: String) {
        guard isEnabled, verbosity == .verbose else { return }
        print("🐛 [Jarvis:\(category)] \(message)")
    }

    static func logMultiline(_ category: String, title: String, body: String, maxCharacterCount: Int = 8000) {
        guard isEnabled, verbosity == .verbose else { return }
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let truncatedBody: String
        if trimmedBody.count > maxCharacterCount {
            truncatedBody = String(trimmedBody.prefix(maxCharacterCount)) + "\n… (truncated, \(trimmedBody.count) chars total)"
        } else {
            truncatedBody = trimmedBody
        }
        print("🐛 [Jarvis:\(category)] \(title)\n\(truncatedBody)")
    }

    static func logClick(
        clickType: String,
        label: String,
        appKitGlobalX: Double,
        appKitGlobalY: Double,
        quartzGlobalX: Double,
        quartzGlobalY: Double
    ) {
        guard isEnabled else { return }
        print(
            "🐛 [Jarvis:Click] \(clickType) label=\"\(label)\" " +
            "AppKit=(\(Int(appKitGlobalX.rounded())), \(Int(appKitGlobalY.rounded()))) " +
            "Quartz=(\(Int(quartzGlobalX.rounded())), \(Int(quartzGlobalY.rounded())))"
        )
    }

    static func logCursorPositionAfterWarp(expectedAppKitX: Double, expectedAppKitY: Double) {
        guard isEnabled, verbosity == .verbose else { return }
        let actualMouseLocation = NSEvent.mouseLocation
        let deltaX = Int((actualMouseLocation.x - expectedAppKitX).rounded())
        let deltaY = Int((actualMouseLocation.y - expectedAppKitY).rounded())
        let deltaSuffix = (deltaX == 0 && deltaY == 0)
            ? " (exact match)"
            : " (delta=\(deltaX), \(deltaY))"
        print(
            "🐛 [Jarvis:Click] cursor after warp: AppKit=(\(Int(actualMouseLocation.x.rounded())), \(Int(actualMouseLocation.y.rounded())))\(deltaSuffix)"
        )
    }

    static func logToolArguments(_ category: String, toolName: String, arguments: [String: JarvisToolArgumentValue]) {
        guard isEnabled, verbosity == .verbose else { return }
        let formattedArguments = arguments
            .sorted { $0.key < $1.key }
            .map { argumentKey, argumentValue in
                "\(argumentKey)=\(formatArgumentValue(argumentValue))"
            }
            .joined(separator: ", ")
        logVerbose(category, "tool=\(toolName) args={\(formattedArguments)}")
    }

    private static func formatArgumentValue(_ value: JarvisToolArgumentValue) -> String {
        switch value {
        case .string(let stringValue):
            return "\"\(stringValue)\""
        case .number(let numberValue):
            return String(numberValue)
        case .boolean(let booleanValue):
            return String(booleanValue)
        case .stringArray(let stringArrayValue):
            return "[\(stringArrayValue.joined(separator: ", "))]"
        }
    }
}
