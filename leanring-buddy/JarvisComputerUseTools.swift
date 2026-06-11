//
//  JarvisComputerUseTools.swift
//  leanring-buddy
//
//  Mouse, scroll, and timing tools that complete the human-equivalent action
//  set for the computer-use agent loop: double click, right click, drag,
//  move mouse, scroll, and wait. All coordinate-based tools accept AppKit
//  global coordinates (bottom-left origin) plus the display frame so they
//  can convert to Quartz coordinates (top-left origin) before posting events,
//  matching the existing click_at tool convention.
//

import AppKit
import CoreGraphics
import Foundation

@MainActor
enum JarvisComputerUseToolInstaller {
    static func registerTools(in toolRegistry: JarvisToolRegistry) {
        toolRegistry.register(JarvisDoubleClickTool())
        toolRegistry.register(JarvisRightClickTool())
        toolRegistry.register(JarvisDragTool())
        toolRegistry.register(JarvisMoveMouseTool())
        toolRegistry.register(JarvisScrollTool())
        toolRegistry.register(JarvisWaitTool())
    }
}

// MARK: - Shared coordinate conversion

/// Converts an AppKit global point (origin at the bottom-left of the primary
/// screen) to a Quartz global point (origin at the top-left of the primary
/// screen). Both coordinate systems share the same origin screen, so the
/// conversion is a single flip against the primary screen's height regardless
/// of which display the point is on.
@MainActor
private func quartzPoint(
    fromAppKitX appKitX: Double,
    appKitY: Double,
    arguments: [String: JarvisToolArgumentValue]
) -> CGPoint {
    guard let primaryScreenHeight = NSScreen.screens.first?.frame.height else {
        return CGPoint(x: appKitX, y: appKitY)
    }

    return CGPoint(
        x: appKitX,
        y: Double(primaryScreenHeight) - appKitY
    )
}

/// Shared display-frame argument names accepted by every coordinate-based tool.
private let displayFrameArgumentNames = [
    "display_frame_x", "display_frame_y", "display_frame_width", "display_frame_height"
]

// MARK: - Double Click

@MainActor
struct JarvisDoubleClickTool: JarvisTool {
    let definition = JarvisToolDefinition(
        name: "double_click",
        summary: "Move the pointer and double-click a global macOS screen coordinate.",
        requiredArgumentNames: ["x", "y"],
        optionalArgumentNames: ["label"] + displayFrameArgumentNames,
        defaultRequiresConfirmation: false
    )

    func execute(
        arguments: [String: JarvisToolArgumentValue],
        context: JarvisToolExecutionContext
    ) async -> JarvisToolResult {
        guard AXIsProcessTrusted() else {
            return .failure("Accessibility permission is required before Jarvis can click.")
        }

        guard let x = arguments["x"]?.numberValue,
              let y = arguments["y"]?.numberValue else {
            return .failure("Jarvis needs screen coordinates before it can double-click.")
        }

        let label = arguments["label"]?.stringValue ?? "the target"
        let clickPoint = quartzPoint(fromAppKitX: x, appKitY: y, arguments: arguments)
        JarvisDebugLogger.logClick(
            clickType: "DOUBLE_CLICK",
            label: label,
            appKitGlobalX: x,
            appKitGlobalY: y,
            quartzGlobalX: clickPoint.x,
            quartzGlobalY: clickPoint.y
        )
        CGWarpMouseCursorPosition(clickPoint)
        JarvisDebugLogger.logCursorPositionAfterWarp(expectedAppKitX: x, expectedAppKitY: y)

        // A real macOS double-click is two click pairs where the second pair
        // carries clickState 2. Posting two independent single clicks is not
        // recognized as a double-click by most apps.
        for clickState in [1, 2] {
            guard let mouseDownEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: clickPoint, mouseButton: .left),
                  let mouseUpEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: clickPoint, mouseButton: .left) else {
                return .failure("Jarvis could not create the double-click events.")
            }
            mouseDownEvent.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            mouseUpEvent.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            JarvisDebugLogger.logVerbose("Click", "posting double-click pair clickState=\(clickState) at Quartz=(\(Int(clickPoint.x)), \(Int(clickPoint.y)))")
            mouseDownEvent.post(tap: .cghidEventTap)
            mouseUpEvent.post(tap: .cghidEventTap)

            if clickState == 1 {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }

        return .success("Double-clicked \(label).")
    }
}

// MARK: - Right Click

@MainActor
struct JarvisRightClickTool: JarvisTool {
    let definition = JarvisToolDefinition(
        name: "right_click",
        summary: "Move the pointer and right-click a global macOS screen coordinate.",
        requiredArgumentNames: ["x", "y"],
        optionalArgumentNames: ["label"] + displayFrameArgumentNames,
        defaultRequiresConfirmation: false
    )

    func execute(
        arguments: [String: JarvisToolArgumentValue],
        context: JarvisToolExecutionContext
    ) async -> JarvisToolResult {
        guard AXIsProcessTrusted() else {
            return .failure("Accessibility permission is required before Jarvis can click.")
        }

        guard let x = arguments["x"]?.numberValue,
              let y = arguments["y"]?.numberValue else {
            return .failure("Jarvis needs screen coordinates before it can right-click.")
        }

        let label = arguments["label"]?.stringValue ?? "the target"
        let clickPoint = quartzPoint(fromAppKitX: x, appKitY: y, arguments: arguments)
        JarvisDebugLogger.logClick(
            clickType: "RIGHT_CLICK",
            label: label,
            appKitGlobalX: x,
            appKitGlobalY: y,
            quartzGlobalX: clickPoint.x,
            quartzGlobalY: clickPoint.y
        )
        CGWarpMouseCursorPosition(clickPoint)
        JarvisDebugLogger.logCursorPositionAfterWarp(expectedAppKitX: x, expectedAppKitY: y)

        guard let mouseDownEvent = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: clickPoint, mouseButton: .right),
              let mouseUpEvent = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: clickPoint, mouseButton: .right) else {
            return .failure("Jarvis could not create the right-click events.")
        }

        JarvisDebugLogger.logVerbose("Click", "posting rightMouseDown + rightMouseUp at Quartz=(\(Int(clickPoint.x)), \(Int(clickPoint.y)))")
        mouseDownEvent.post(tap: .cghidEventTap)
        mouseUpEvent.post(tap: .cghidEventTap)

        return .success("Right-clicked \(label).")
    }
}

// MARK: - Drag

@MainActor
struct JarvisDragTool: JarvisTool {
    let definition = JarvisToolDefinition(
        name: "drag",
        summary: "Press the left mouse button at a start coordinate, drag to an end coordinate, and release.",
        requiredArgumentNames: ["start_x", "start_y", "x", "y"],
        optionalArgumentNames: ["label"] + displayFrameArgumentNames,
        defaultRequiresConfirmation: false
    )

    func execute(
        arguments: [String: JarvisToolArgumentValue],
        context: JarvisToolExecutionContext
    ) async -> JarvisToolResult {
        guard AXIsProcessTrusted() else {
            return .failure("Accessibility permission is required before Jarvis can drag.")
        }

        guard let startX = arguments["start_x"]?.numberValue,
              let startY = arguments["start_y"]?.numberValue,
              let endX = arguments["x"]?.numberValue,
              let endY = arguments["y"]?.numberValue else {
            return .failure("Jarvis needs start and end coordinates before it can drag.")
        }

        let startPoint = quartzPoint(fromAppKitX: startX, appKitY: startY, arguments: arguments)
        let endPoint = quartzPoint(fromAppKitX: endX, appKitY: endY, arguments: arguments)
        JarvisDebugLogger.logVerbose(
            "Tool",
            "drag: start AppKit(\(Int(startX)), \(Int(startY))) → Quartz(\(Int(startPoint.x)), \(Int(startPoint.y))) " +
            "end AppKit(\(Int(endX)), \(Int(endY))) → Quartz(\(Int(endPoint.x)), \(Int(endPoint.y)))"
        )

        CGWarpMouseCursorPosition(startPoint)

        guard let mouseDownEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: startPoint, mouseButton: .left) else {
            return .failure("Jarvis could not create the drag events.")
        }
        mouseDownEvent.post(tap: .cghidEventTap)

        // Interpolate intermediate dragged events so apps that track drag
        // motion (sliders, drag-and-drop targets) register the gesture.
        let interpolationStepCount = 12
        for stepIndex in 1...interpolationStepCount {
            let progress = CGFloat(stepIndex) / CGFloat(interpolationStepCount)
            let intermediatePoint = CGPoint(
                x: startPoint.x + (endPoint.x - startPoint.x) * progress,
                y: startPoint.y + (endPoint.y - startPoint.y) * progress
            )
            if let draggedEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: intermediatePoint, mouseButton: .left) {
                draggedEvent.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(nanoseconds: 16_000_000)
        }

        guard let mouseUpEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: endPoint, mouseButton: .left) else {
            return .failure("Jarvis could not finish the drag gesture.")
        }
        mouseUpEvent.post(tap: .cghidEventTap)

        let label = arguments["label"]?.stringValue ?? "the target"
        return .success("Dragged to \(label).")
    }
}

// MARK: - Move Mouse

@MainActor
struct JarvisMoveMouseTool: JarvisTool {
    let definition = JarvisToolDefinition(
        name: "move_mouse",
        summary: "Move the pointer to a global macOS screen coordinate without clicking.",
        requiredArgumentNames: ["x", "y"],
        optionalArgumentNames: ["label"] + displayFrameArgumentNames,
        defaultRequiresConfirmation: false
    )

    func execute(
        arguments: [String: JarvisToolArgumentValue],
        context: JarvisToolExecutionContext
    ) async -> JarvisToolResult {
        guard AXIsProcessTrusted() else {
            return .failure("Accessibility permission is required before Jarvis can move the mouse.")
        }

        guard let x = arguments["x"]?.numberValue,
              let y = arguments["y"]?.numberValue else {
            return .failure("Jarvis needs screen coordinates before it can move the mouse.")
        }

        let targetPoint = quartzPoint(fromAppKitX: x, appKitY: y, arguments: arguments)
        JarvisDebugLogger.logVerbose("Tool", "move_mouse: AppKit(\(Int(x)), \(Int(y))) → Quartz(\(Int(targetPoint.x)), \(Int(targetPoint.y)))")
        CGWarpMouseCursorPosition(targetPoint)

        // Post an explicit mouseMoved event so apps tracking hover state
        // (tooltips, hover menus) notice the new pointer position.
        if let mouseMovedEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: targetPoint, mouseButton: .left) {
            mouseMovedEvent.post(tap: .cghidEventTap)
        }

        let label = arguments["label"]?.stringValue ?? "the target"
        return .success("Moved the mouse to \(label).")
    }
}

// MARK: - Scroll

@MainActor
struct JarvisScrollTool: JarvisTool {
    let definition = JarvisToolDefinition(
        name: "scroll",
        summary: "Scroll the content under the pointer up, down, left, or right.",
        requiredArgumentNames: ["direction"],
        optionalArgumentNames: ["amount", "x", "y", "label"] + displayFrameArgumentNames,
        defaultRequiresConfirmation: false
    )

    func execute(
        arguments: [String: JarvisToolArgumentValue],
        context: JarvisToolExecutionContext
    ) async -> JarvisToolResult {
        guard AXIsProcessTrusted() else {
            return .failure("Accessibility permission is required before Jarvis can scroll.")
        }

        guard let direction = arguments["direction"]?.stringValue?.lowercased(),
              ["up", "down", "left", "right"].contains(direction) else {
            return .failure("Jarvis needs a scroll direction: up, down, left, or right.")
        }

        // Position the pointer over the scroll target first so the scroll
        // event lands on the intended view rather than wherever the cursor is.
        if let x = arguments["x"]?.numberValue,
           let y = arguments["y"]?.numberValue {
            let scrollOriginPoint = quartzPoint(fromAppKitX: x, appKitY: y, arguments: arguments)
            JarvisDebugLogger.logVerbose("Tool", "scroll: positioning at AppKit(\(Int(x)), \(Int(y))) → Quartz(\(Int(scrollOriginPoint.x)), \(Int(scrollOriginPoint.y)))")
            CGWarpMouseCursorPosition(scrollOriginPoint)
        }

        let lineCount = Int32((arguments["amount"]?.numberValue ?? 5).rounded())
        let clampedLineCount = max(1, min(lineCount, 40))
        JarvisDebugLogger.logVerbose("Tool", "scroll: direction=\(direction) lines=\(clampedLineCount)")

        // Positive wheel values scroll toward earlier content (up/left).
        var verticalLines: Int32 = 0
        var horizontalLines: Int32 = 0
        switch direction {
        case "up":
            verticalLines = clampedLineCount
        case "down":
            verticalLines = -clampedLineCount
        case "left":
            horizontalLines = clampedLineCount
        case "right":
            horizontalLines = -clampedLineCount
        default:
            break
        }

        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: verticalLines,
            wheel2: horizontalLines,
            wheel3: 0
        ) else {
            return .failure("Jarvis could not create the scroll event.")
        }

        scrollEvent.post(tap: .cghidEventTap)
        return .success("Scrolled \(direction).")
    }
}

// MARK: - Wait

@MainActor
struct JarvisWaitTool: JarvisTool {
    let definition = JarvisToolDefinition(
        name: "wait",
        summary: "Pause so the screen can finish loading or animating before the next action.",
        requiredArgumentNames: [],
        optionalArgumentNames: ["seconds"],
        defaultRequiresConfirmation: false
    )

    func execute(
        arguments: [String: JarvisToolArgumentValue],
        context: JarvisToolExecutionContext
    ) async -> JarvisToolResult {
        let requestedSeconds = arguments["seconds"]?.numberValue ?? 2.0
        let clampedSeconds = max(0.5, min(requestedSeconds, 10.0))
        try? await Task.sleep(nanoseconds: UInt64(clampedSeconds * 1_000_000_000))
        return .success("Waited \(String(format: "%.1f", clampedSeconds)) seconds.")
    }
}
