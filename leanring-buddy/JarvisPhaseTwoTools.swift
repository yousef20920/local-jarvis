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
                try? await Task.sleep(nanoseconds: 700_000_000)
                return .success("Opened \(appName).")
            }

            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appName) {
                _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
                try? await Task.sleep(nanoseconds: 700_000_000)
                return .success("Opened \(appName).")
            }

            _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/\(appName).app"), configuration: configuration)
            try? await Task.sleep(nanoseconds: 700_000_000)
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
