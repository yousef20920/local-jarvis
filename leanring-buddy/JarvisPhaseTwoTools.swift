//
//  JarvisPhaseTwoTools.swift
//  leanring-buddy
//
//  First local macOS tools for the Phase 2 text-only Jarvis loop.
//

import AppKit
import CoreGraphics
import Foundation

@MainActor
enum JarvisPhaseTwoToolInstaller {
    static func registerTools(in toolRegistry: JarvisToolRegistry) {
        toolRegistry.register(JarvisOpenAppTool())
        toolRegistry.register(JarvisTypeTextTool())
        toolRegistry.register(JarvisPressHotkeyTool())
        toolRegistry.register(JarvisTakeScreenshotTool())
        toolRegistry.register(JarvisClickAtTool())
        toolRegistry.register(JarvisConfirmedClickAtTool())
        toolRegistry.register(JarvisConfirmedHotkeyTool())
        toolRegistry.register(JarvisRunTerminalCommandTool())
        JarvisComputerUseToolInstaller.registerTools(in: toolRegistry)
    }
}

@MainActor
struct JarvisRunTerminalCommandTool: JarvisTool {
    let definition = JarvisToolDefinition(
        name: "run_terminal_command",
        summary: "Run one shell command in an explicit working directory after user confirmation.",
        requiredArgumentNames: ["command", "working_directory"],
        optionalArgumentNames: [],
        defaultRequiresConfirmation: true
    )

    func execute(
        arguments: [String: JarvisToolArgumentValue],
        context: JarvisToolExecutionContext
    ) async -> JarvisToolResult {
        guard let command = arguments["command"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            return .failure("Jarvis needs a terminal command to run.")
        }

        guard let workingDirectoryPath = arguments["working_directory"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              (workingDirectoryPath as NSString).isAbsolutePath else {
            return .failure("Jarvis needs an explicit working directory before running a terminal command.")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectoryPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .failure("The working directory does not exist: \(workingDirectoryPath)")
        }

        let outputFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-command-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: outputFileURL.path, contents: nil),
              let outputFileHandle = try? FileHandle(forWritingTo: outputFileURL) else {
            return .failure("Jarvis could not create temporary command output storage.")
        }
        defer {
            try? outputFileHandle.close()
            try? FileManager.default.removeItem(at: outputFileURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectoryPath, isDirectory: true)
        process.standardOutput = outputFileHandle
        process.standardError = outputFileHandle

        let processResult: Result<Int32, Error> = await withTaskCancellationHandler {
            guard !Task.isCancelled else {
                return .failure(CancellationError())
            }
            await withCheckedContinuation { continuation in
                process.terminationHandler = { completedProcess in
                    continuation.resume(returning: .success(completedProcess.terminationStatus))
                }
                do {
                    // Install the termination handler before launch so even a
                    // very short command cannot finish before continuation is wired.
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(returning: .failure(error))
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }

        guard case .success(let terminationStatus) = processResult else {
            if case .failure(let error) = processResult {
                if error is CancellationError {
                    return .failure("The terminal command was cancelled.")
                }
                return .failure("Could not start the terminal command: \(error.localizedDescription)")
            }
            return .failure("Could not start the terminal command.")
        }

        try? outputFileHandle.synchronize()
        let commandOutput = Self.readOutputTail(from: outputFileURL, maximumByteCount: 16_384)
        let resultData: [String: JarvisToolArgumentValue] = [
            "exit_status": .number(Double(terminationStatus)),
            "output": .string(commandOutput)
        ]
        let summarizedCommandOutput = commandOutput.count > 2_000
            ? "..." + String(commandOutput.suffix(2_000))
            : commandOutput

        if terminationStatus == 0 {
            let summary = summarizedCommandOutput.isEmpty
                ? "Terminal command finished successfully."
                : "Terminal command finished successfully. Output: \(summarizedCommandOutput)"
            return .success(summary, data: resultData)
        }

        let failureSummary = summarizedCommandOutput.isEmpty
            ? "Terminal command failed with exit status \(terminationStatus)."
            : "Terminal command failed with exit status \(terminationStatus). Output: \(summarizedCommandOutput)"
        return .failure(failureSummary, data: resultData)
    }

    private static func readOutputTail(from outputFileURL: URL, maximumByteCount: UInt64) -> String {
        guard let outputReadHandle = try? FileHandle(forReadingFrom: outputFileURL) else {
            return ""
        }
        defer { try? outputReadHandle.close() }

        let fileByteCount = (try? outputReadHandle.seekToEnd()) ?? 0
        let startingOffset = fileByteCount > maximumByteCount
            ? fileByteCount - maximumByteCount
            : 0
        try? outputReadHandle.seek(toOffset: startingOffset)
        let outputData = (try? outputReadHandle.readToEnd()) ?? Data()
        return String(decoding: outputData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
struct JarvisOpenAppTool: JarvisTool {
    let definition = JarvisToolDefinition(
        name: "open_app",
        summary: "Open a macOS app by name.",
        requiredArgumentNames: ["name"],
        optionalArgumentNames: [],
        defaultRequiresConfirmation: false
    )

    func execute(
        arguments: [String: JarvisToolArgumentValue],
        context: JarvisToolExecutionContext
    ) async -> JarvisToolResult {
        guard let appName = arguments["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !appName.isEmpty else {
            return .failure("Jarvis needs an app name to open.")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        do {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier(for: appName)) {
                _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
                try? await Task.sleep(nanoseconds: 400_000_000)
                return .success("Opened \(appName).")
            }

            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appName) {
                _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
                try? await Task.sleep(nanoseconds: 400_000_000)
                return .success("Opened \(appName).")
            }

            _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/\(appName).app"), configuration: configuration)
            try? await Task.sleep(nanoseconds: 400_000_000)
            return .success("Opened \(appName).")
        } catch {
            return .failure("Could not open \(appName): \(error.localizedDescription)")
        }
    }

    private func bundleIdentifier(for appName: String) -> String {
        switch appName.lowercased() {
        case "google chrome", "chrome":
            return "com.google.Chrome"
        case "safari":
            return "com.apple.Safari"
        case "finder":
            return "com.apple.finder"
        case "terminal":
            return "com.apple.Terminal"
        case "notes":
            return "com.apple.Notes"
        case "messages":
            return "com.apple.MobileSMS"
        default:
            return appName
        }
    }
}

@MainActor
struct JarvisTypeTextTool: JarvisTool {
    let definition = JarvisToolDefinition(
        name: "type_text",
        summary: "Type text into the currently focused app.",
        requiredArgumentNames: ["text"],
        optionalArgumentNames: [],
        defaultRequiresConfirmation: false
    )

    func execute(
        arguments: [String: JarvisToolArgumentValue],
        context: JarvisToolExecutionContext
    ) async -> JarvisToolResult {
        guard AXIsProcessTrusted() else {
            return .failure("Accessibility permission is required before Jarvis can type.")
        }

        guard let text = arguments["text"]?.stringValue else {
            return .failure("Jarvis needs text to type.")
        }

        let pasteboard = NSPasteboard.general
        let previousPasteboardContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        postHotkey(["command", "v"])

        if let previousPasteboardContents {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                pasteboard.clearContents()
                pasteboard.setString(previousPasteboardContents, forType: .string)
            }
        }

        return .success("Typed text.")
    }
}

@MainActor
struct JarvisPressHotkeyTool: JarvisTool {
    let definition = JarvisToolDefinition(
        name: "press_hotkey",
        summary: "Press a keyboard shortcut.",
        requiredArgumentNames: ["keys"],
        optionalArgumentNames: [],
        defaultRequiresConfirmation: false
    )

    func execute(
        arguments: [String: JarvisToolArgumentValue],
        context: JarvisToolExecutionContext
    ) async -> JarvisToolResult {
        guard AXIsProcessTrusted() else {
            return .failure("Accessibility permission is required before Jarvis can press keys.")
        }

        guard let keyNames = arguments["keys"]?.stringArrayValue, !keyNames.isEmpty else {
            return .failure("Jarvis needs at least one key to press.")
        }

        guard postHotkey(keyNames) else {
            return .failure("Jarvis does not know that hotkey yet: \(keyNames.joined(separator: " + ")).")
        }

        return .success("Pressed \(keyNames.joined(separator: " + ")).")
    }
}

@MainActor
struct JarvisTakeScreenshotTool: JarvisTool {
    let definition = JarvisToolDefinition(
        name: "take_screenshot",
        summary: "Capture the connected displays through the existing screen capture utility.",
        requiredArgumentNames: [],
        optionalArgumentNames: [],
        defaultRequiresConfirmation: false
    )

    func execute(
        arguments: [String: JarvisToolArgumentValue],
        context: JarvisToolExecutionContext
    ) async -> JarvisToolResult {
        do {
            let screenshots = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            return .success(
                "Captured \(screenshots.count) display\(screenshots.count == 1 ? "" : "s").",
                data: ["display_count": .number(Double(screenshots.count))]
            )
        } catch {
            return .failure("Could not take a screenshot: \(error.localizedDescription)")
        }
    }
}

@MainActor
struct JarvisClickAtTool: JarvisTool {
    let definition = JarvisToolDefinition(
        name: "click_at",
        summary: "Move the pointer and click a global macOS screen coordinate.",
        requiredArgumentNames: ["x", "y"],
        optionalArgumentNames: ["label", "display_frame_x", "display_frame_y", "display_frame_width", "display_frame_height"],
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
            return .failure("Jarvis needs screen coordinates before it can click.")
        }

        let label = arguments["label"]?.stringValue ?? "the target"
        let appKitGlobalPoint = CGPoint(x: x, y: y)
        let clickPoint = quartzPoint(fromAppKitPoint: appKitGlobalPoint, arguments: arguments)

        JarvisDebugLogger.logClick(
            clickType: "LEFT_CLICK",
            label: label,
            appKitGlobalX: appKitGlobalPoint.x,
            appKitGlobalY: appKitGlobalPoint.y,
            quartzGlobalX: clickPoint.x,
            quartzGlobalY: clickPoint.y
        )
        CGWarpMouseCursorPosition(clickPoint)
        JarvisDebugLogger.logCursorPositionAfterWarp(
            expectedAppKitX: appKitGlobalPoint.x,
            expectedAppKitY: appKitGlobalPoint.y
        )

        guard let mouseDownEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: clickPoint, mouseButton: .left),
              let mouseUpEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: clickPoint, mouseButton: .left) else {
            return .failure("Jarvis could not create the click event.")
        }

        JarvisDebugLogger.logVerbose("Click", "posting leftMouseDown + leftMouseUp at Quartz=(\(Int(clickPoint.x)), \(Int(clickPoint.y)))")
        mouseDownEvent.post(tap: .cghidEventTap)
        mouseUpEvent.post(tap: .cghidEventTap)
        return .success("Clicked \(label).")
    }

    /// Converts an AppKit global point (origin at the bottom-left of the
    /// primary screen) to a Quartz global point (origin at the top-left of the
    /// primary screen). Only the primary screen's height matters — both
    /// coordinate systems share the same origin screen, so the conversion is
    /// a single flip regardless of which display the point is on.
    private func quartzPoint(
        fromAppKitPoint appKitPoint: CGPoint,
        arguments: [String: JarvisToolArgumentValue]
    ) -> CGPoint {
        guard let primaryScreenHeight = NSScreen.screens.first?.frame.height else {
            return appKitPoint
        }

        return CGPoint(
            x: appKitPoint.x,
            y: primaryScreenHeight - appKitPoint.y
        )
    }
}

/// Uses the same physical click implementation as an ordinary click, but its
/// separate tool identity forces the safety policy to pause before a final,
/// consequential UI action such as Send, Submit, Delete, or Purchase.
@MainActor
struct JarvisConfirmedClickAtTool: JarvisTool {
    let definition = JarvisToolDefinition(
        name: "confirm_click_at",
        summary: "Click a consequential UI control after explicit user confirmation.",
        requiredArgumentNames: ["x", "y", "label"],
        optionalArgumentNames: ["display_frame_x", "display_frame_y", "display_frame_width", "display_frame_height"],
        defaultRequiresConfirmation: true
    )

    func execute(
        arguments: [String: JarvisToolArgumentValue],
        context: JarvisToolExecutionContext
    ) async -> JarvisToolResult {
        await JarvisClickAtTool().execute(arguments: arguments, context: context)
    }
}

/// Keyboard equivalents of final submission buttons need the same semantic
/// safety boundary; otherwise Command+Return could bypass a confirmed click.
@MainActor
struct JarvisConfirmedHotkeyTool: JarvisTool {
    let definition = JarvisToolDefinition(
        name: "confirm_hotkey",
        summary: "Press a consequential keyboard shortcut after explicit user confirmation.",
        requiredArgumentNames: ["keys", "label"],
        optionalArgumentNames: [],
        defaultRequiresConfirmation: true
    )

    func execute(
        arguments: [String: JarvisToolArgumentValue],
        context: JarvisToolExecutionContext
    ) async -> JarvisToolResult {
        await JarvisPressHotkeyTool().execute(arguments: arguments, context: context)
    }
}

@MainActor
@discardableResult
private func postHotkey(_ rawKeyNames: [String]) -> Bool {
    let normalizedKeyNames = rawKeyNames.map { keyName in
        keyName
            .lowercased()
            .replacingOccurrences(of: "cmd", with: "command")
            .replacingOccurrences(of: "return", with: "enter")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var modifierFlags: CGEventFlags = []
    var regularKeyCodes: [CGKeyCode] = []

    for keyName in normalizedKeyNames {
        switch keyName {
        case "command":
            modifierFlags.insert(.maskCommand)
        case "shift":
            modifierFlags.insert(.maskShift)
        case "option", "alt":
            modifierFlags.insert(.maskAlternate)
        case "control", "ctrl":
            modifierFlags.insert(.maskControl)
        default:
            guard let keyCode = keyCode(for: keyName) else {
                return false
            }
            regularKeyCodes.append(keyCode)
        }
    }

    if regularKeyCodes.isEmpty {
        return false
    }

    for keyCode in regularKeyCodes {
        guard let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return false
        }

        keyDownEvent.flags = modifierFlags
        keyUpEvent.flags = modifierFlags
        keyDownEvent.post(tap: .cghidEventTap)
        keyUpEvent.post(tap: .cghidEventTap)
    }

    return true
}

private func keyCode(for keyName: String) -> CGKeyCode? {
    switch keyName {
    case "a": return 0
    case "s": return 1
    case "d": return 2
    case "f": return 3
    case "h": return 4
    case "g": return 5
    case "z": return 6
    case "x": return 7
    case "c": return 8
    case "v": return 9
    case "b": return 11
    case "q": return 12
    case "w": return 13
    case "e": return 14
    case "r": return 15
    case "y": return 16
    case "t": return 17
    case "1": return 18
    case "2": return 19
    case "3": return 20
    case "4": return 21
    case "6": return 22
    case "5": return 23
    case "=": return 24
    case "9": return 25
    case "7": return 26
    case "-": return 27
    case "8": return 28
    case "0": return 29
    case "]": return 30
    case "o": return 31
    case "u": return 32
    case "[": return 33
    case "i": return 34
    case "p": return 35
    case "l": return 37
    case "j": return 38
    case "'": return 39
    case "k": return 40
    case ";": return 41
    case "\\": return 42
    case ",": return 43
    case "/": return 44
    case "n": return 45
    case "m": return 46
    case ".": return 47
    case "`": return 50
    case "enter": return 36
    case "tab": return 48
    case "space": return 49
    case "delete", "backspace": return 51
    case "escape", "esc": return 53
    case "left": return 123
    case "right": return 124
    case "down": return 125
    case "up": return 126
    default: return nil
    }
}
