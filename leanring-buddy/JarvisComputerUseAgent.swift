//
//  JarvisComputerUseAgent.swift
//  leanring-buddy
//
//  Local observe-act agent loop. Each iteration captures a fresh screenshot,
//  asks the local Qwen3-VL model for the single next action toward the user's
//  goal, maps the model's 1000x1000-grid coordinates to real screen
//  coordinates, runs the action through the safety policy, executes it, and
//  repeats until the model terminates, answers, hits the step cap, or the
//  user cancels. This replaces the old plan-everything-upfront pipeline so
//  Jarvis can see the result of each action and recover from misses.
//

import AppKit
import Foundation

/// How a full agent run ended. Every run ends in exactly one of these, so the
/// caller can always speak an explicit result instead of failing silently.
enum JarvisComputerUseAgentOutcome: Equatable {
    case completed(summaryMessage: String)
    case failed(failureMessage: String)
    case answered(answerText: String)
    case needsConfirmation(JarvisToolCall, reason: String)
    case stopped
}

/// Callbacks the owning manager supplies so it can mirror agent progress into
/// observable workflow state for the panel UI and the cursor overlay.
struct JarvisComputerUseAgentCallbacks {
    /// Checked before every step; returning true aborts the run ("jarvis stop").
    let isCancelled: @MainActor () -> Bool
    /// Called after safety approval, before the tool executes. The step number is 1-based.
    let onToolCallStarting: @MainActor (JarvisToolCall, Int) async -> Void
    /// Called after the tool finishes with its result.
    let onToolCallFinished: @MainActor (JarvisToolCall, JarvisToolResult, Int) -> Void
}

@MainActor
final class JarvisComputerUseAgent {
    /// Hard cap on loop iterations so a confused model cannot act forever.
    static let maximumStepCount = 15

    /// Only the most recent history lines are sent back to the model so later
    /// steps do not slow down from an ever-growing prompt.
    private static let maximumActionHistoryLineCount = 5

    /// The model reports coordinates on this fixed relative grid regardless of
    /// the actual screenshot or display resolution (Qwen3-VL convention).
    private static let modelCoordinateGridSize: Double = 768

    private let localLLMClient: JarvisLocalLLMClient
    private let toolRegistry: JarvisToolRegistry
    private let safetyPolicy: JarvisSafetyPolicy

    init(
        localLLMClient: JarvisLocalLLMClient,
        toolRegistry: JarvisToolRegistry,
        safetyPolicy: JarvisSafetyPolicy
    ) {
        self.localLLMClient = localLLMClient
        self.toolRegistry = toolRegistry
        self.safetyPolicy = safetyPolicy
    }

    // MARK: - Main loop

    func run(
        userGoal: String,
        callbacks: JarvisComputerUseAgentCallbacks
    ) async -> JarvisComputerUseAgentOutcome {
        var actionHistoryLines: [String] = []
        // Loop guard: tracks the last pointer action so the agent can detect
        // when the model keeps choosing the same coordinates without progress.
        var previousPointerActionSignature: String?
        var rejectedRepeatedPointerActionCount = 0

        JarvisDebugLogger.log("Agent", "run started: \"\(userGoal)\"")

        for stepNumber in 1...Self.maximumStepCount {
            JarvisDebugLogger.logVerbose("Agent", "── step \(stepNumber)/\(Self.maximumStepCount) ──")

            if callbacks.isCancelled() {
                JarvisDebugLogger.log("Agent", "cancelled before observe")
                return .stopped
            }

            // 1. Observe: capture the screen the user is working on.
            let screenCapture: CompanionScreenCapture
            do {
                let captures = try await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG()
                guard let cursorScreenCapture = captures.first(where: { $0.isCursorScreen }) ?? captures.first else {
                    return .failed(failureMessage: "I could not capture the screen.")
                }
                screenCapture = cursorScreenCapture
                JarvisDebugLogger.logVerbose(
                    "Agent",
                    "screenshot: \(screenCapture.screenshotWidthInPixels)x\(screenCapture.screenshotHeightInPixels)px jpeg=\(screenCapture.imageData.count) bytes"
                )
            } catch {
                JarvisDebugLogger.log("Agent", "screenshot capture FAILED: \(error.localizedDescription)")
                return .failed(failureMessage: "I could not capture the screen: \(error.localizedDescription)")
            }

            if callbacks.isCancelled() {
                JarvisDebugLogger.log("Agent", "cancelled after observe")
                return .stopped
            }

            // 2. Think: ask the model for the single next action.
            //
            // The screenshot is resized to exactly 768x768 pixels before it
            // is sent. Qwen-VL models ground clicks either on the official
            // relative grid or in the input image's pixel space
            // (local GGUF builds often do the latter). When the image itself
            // matches the grid, both conventions produce identical numbers, so
            // coordinates map correctly no matter which one the model uses.
            let modelScreenshotData = Self.resizeScreenshotToModelGrid(screenCapture.imageData)
                ?? screenCapture.imageData
            JarvisDebugLogger.logVerbose("Agent", "model input: \(Int(Self.modelCoordinateGridSize))x\(Int(Self.modelCoordinateGridSize))px")

            let userPrompt = Self.agentTurnPrompt(
                userGoal: userGoal,
                actionHistoryLines: actionHistoryLines,
                stepNumber: stepNumber
            )
            JarvisDebugLogger.logMultiline("Agent", title: "user prompt:", body: userPrompt)

            let modelResponseText: String
            do {
                modelResponseText = try await localLLMClient.generateComputerUseTurn(
                    systemPrompt: Self.agentSystemPrompt,
                    userPrompt: userPrompt,
                    screenshotBase64: modelScreenshotData.base64EncodedString()
                )
            } catch {
                JarvisDebugLogger.log("Agent", "model call FAILED: \(error.localizedDescription)")
                return .failed(failureMessage: "The local model is unavailable: \(error.localizedDescription)")
            }

            JarvisDebugLogger.logMultiline("Agent", title: "raw model response:", body: modelResponseText)

            guard let modelAction = Self.parseModelAction(from: modelResponseText) else {
                JarvisDebugLogger.log("Agent", "parse FAILED — response was not valid action JSON")
                actionHistoryLines.append("Step \(stepNumber): your previous response was not a valid action JSON object. Respond with exactly one action.")
                continue
            }

            Self.logParsedModelAction(modelAction, stepNumber: stepNumber)

            // 3. Terminal actions end the run without touching the machine.
            switch modelAction.actionName {
            case "answer":
                let answerText = modelAction.text ?? modelAction.message ?? "Done."
                JarvisDebugLogger.log("Agent", "answered: \"\(answerText)\"")
                return .answered(answerText: answerText)
            case "terminate":
                let message = modelAction.message ?? (modelAction.terminateStatus == "success" ? "Done." : "I could not finish that.")
                if modelAction.terminateStatus == "failure" {
                    JarvisDebugLogger.log("Agent", "failed: \(message)")
                    return .failed(failureMessage: message)
                }
                JarvisDebugLogger.log("Agent", "completed: \(message)")
                return .completed(summaryMessage: message)
            case "screenshot":
                JarvisDebugLogger.logVerbose("Agent", "screenshot action skipped — loop already observes each step")
                actionHistoryLines.append("Step \(stepNumber): took a fresh screenshot (the attached image is always current — no screenshot action is needed).")
                continue
            default:
                break
            }

            // 4. Map the model action to a concrete tool call.
            guard let toolCall = Self.toolCall(from: modelAction, screenCapture: screenCapture) else {
                JarvisDebugLogger.log("Agent", "tool mapping FAILED for action '\(modelAction.actionName)' — missing required fields")
                actionHistoryLines.append("Step \(stepNumber): action '\(modelAction.actionName)' was missing required fields or is not supported. Choose a supported action.")
                continue
            }

            JarvisDebugLogger.logToolArguments("Agent", toolName: toolCall.toolName, arguments: toolCall.arguments)

            // 4b. Loop guard: reject a pointer action aimed at (nearly) the
            // same coordinates as the previous one. A click that worked
            // changes the screen, so an identical follow-up click almost
            // always means the coordinate was wrong and the model is stuck.
            if let pointerActionSignature = Self.pointerActionSignature(for: modelAction) {
                if pointerActionSignature == previousPointerActionSignature {
                    rejectedRepeatedPointerActionCount += 1
                    JarvisDebugLogger.log(
                        "Agent",
                        "loop guard REJECTED repeat signature=\(pointerActionSignature) count=\(rejectedRepeatedPointerActionCount)"
                    )
                    // Two consecutive rejections of the same spot means the
                    // model is truly stuck on that coordinate.
                    if rejectedRepeatedPointerActionCount >= 2 {
                        JarvisDebugLogger.log("Agent", "run ended: stuck on same coordinates")
                        return .failed(failureMessage: "I kept choosing the same spot without making progress, so I stopped. Try rephrasing the command or doing this step manually.")
                    }
                    actionHistoryLines.append(
                        "Step \(stepNumber): REJECTED — you chose the same coordinates as your previous \(modelAction.actionName) and the screen did not change, so that coordinate is WRONG. Do not click there again. Prefer a keyboard route instead (for example: key command+l to focus the address bar, type, then key return), or pick a clearly different point, or terminate with status failure."
                    )
                    continue
                }
                // A new coordinate means the model adjusted course, so the
                // stuck counter starts over for this new spot.
                rejectedRepeatedPointerActionCount = 0
                previousPointerActionSignature = pointerActionSignature
                JarvisDebugLogger.logVerbose("Agent", "loop guard signature=\(pointerActionSignature)")
            } else {
                previousPointerActionSignature = nil
                rejectedRepeatedPointerActionCount = 0
            }

            if let gridCoordinate = modelAction.coordinate,
               let globalX = toolCall.arguments["x"]?.numberValue,
               let globalY = toolCall.arguments["y"]?.numberValue {
                let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
                let quartzY = primaryScreenHeight - globalY
                JarvisDebugLogger.logVerbose(
                    "Coord",
                    "grid (\(Int(gridCoordinate.x)), \(Int(gridCoordinate.y))) → AppKit (\(Int(globalX)), \(Int(globalY))) → Quartz (\(Int(globalX)), \(Int(quartzY)))"
                )
            }

            // 5. Safety gate.
            let toolDefinition = toolRegistry.tool(named: toolCall.toolName)?.definition
            switch safetyPolicy.evaluate(toolCall: toolCall, toolDefinition: toolDefinition) {
            case .allow:
                break
            case .requireConfirmation(let reason):
                JarvisDebugLogger.log("Agent", "needs confirmation: \(reason)")
                return .needsConfirmation(toolCall, reason: reason)
            case .block(let reason):
                JarvisDebugLogger.log("Agent", "blocked: \(reason)")
                return .failed(failureMessage: reason)
            }

            guard let tool = toolRegistry.tool(named: toolCall.toolName) else {
                JarvisDebugLogger.log("Agent", "tool not registered: \(toolCall.toolName)")
                return .failed(failureMessage: "Tool not registered: \(toolCall.toolName).")
            }

            // 6. Act.
            await callbacks.onToolCallStarting(toolCall, stepNumber)

            if callbacks.isCancelled() {
                JarvisDebugLogger.log("Agent", "cancelled before execute")
                return .stopped
            }

            let result = await tool.execute(
                arguments: toolCall.arguments,
                context: JarvisToolExecutionContext(originalUserCommand: userGoal, isDryRun: false)
            )
            let resultStatus = result.ok ? "ok" : "FAILED"
            JarvisDebugLogger.log("Agent", "step \(stepNumber): \(toolCall.userVisibleSummary) → \(resultStatus)")
            JarvisDebugLogger.logVerbose("Agent", "result message: \(result.message)")
            callbacks.onToolCallFinished(toolCall, result, stepNumber)

            // Record the grid coordinates in the history so the model can see
            // exactly where it acted and choose different coordinates if the
            // screen did not change as expected.
            let gridCoordinateSuffix = modelAction.coordinate.map { gridCoordinate in
                " at (\(Int(gridCoordinate.x)), \(Int(gridCoordinate.y)))"
            } ?? ""
            let historyLine = "Step \(stepNumber): \(toolCall.userVisibleSummary)\(gridCoordinateSuffix) → \(result.message) (\(result.ok ? "executed" : "FAILED"))"
            actionHistoryLines.append(historyLine)

            // A failed action does not end the run — the model sees the failure
            // in its history plus a fresh screenshot and can try another way.

            // 7. Let the UI settle before observing again so the next
            // screenshot reflects the result of this action.
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        JarvisDebugLogger.log("Agent", "max steps reached without finishing")
        return .failed(failureMessage: "I stopped after \(Self.maximumStepCount) steps without finishing. The task may be partially done.")
    }

    private static func logParsedModelAction(_ modelAction: JarvisComputerUseModelAction, stepNumber: Int) {
        var details: [String] = ["action=\(modelAction.actionName)"]
        if let reasoning = modelAction.reasoning { details.append("reasoning=\"\(reasoning)\"") }
        if let coordinate = modelAction.coordinate { details.append("coordinate=(\(Int(coordinate.x)), \(Int(coordinate.y)))") }
        if let startCoordinate = modelAction.startCoordinate { details.append("start=(\(Int(startCoordinate.x)), \(Int(startCoordinate.y)))") }
        if let label = modelAction.label { details.append("label=\"\(label)\"") }
        if let text = modelAction.text { details.append("text=\"\(text)\"") }
        if let keys = modelAction.keys { details.append("keys=[\(keys.joined(separator: "+"))]") }
        if let appName = modelAction.appName { details.append("app=\"\(appName)\"") }
        if let scrollDirection = modelAction.scrollDirection { details.append("scroll=\(scrollDirection)") }
        if let waitSeconds = modelAction.waitSeconds { details.append("wait=\(waitSeconds)s") }
        if let terminateStatus = modelAction.terminateStatus { details.append("status=\(terminateStatus)") }
        if let message = modelAction.message { details.append("message=\"\(message)\"") }
        JarvisDebugLogger.logVerbose("Agent", "step \(stepNumber) parsed: \(details.joined(separator: ", "))")
    }

    // MARK: - Prompts

    private static let agentSystemPrompt = """
    You are Jarvis, a computer-use agent controlling a macOS computer with a mouse and keyboard.
    Each turn you receive: the user's goal, the history of actions already taken, and a screenshot of the CURRENT screen.
    The screenshot is exactly 768x768 pixels and the screen's resolution is 768x768. All coordinates you output are pixel coordinates in this 768x768 image, with the origin at the top-left corner; x increases rightward and y increases downward.

    Respond with EXACTLY ONE JSON object describing the single next action. No markdown, no extra text.

    Supported actions:
    {"reasoning": "...", "action": "left_click", "coordinate": [x, y], "label": "short element name"}
    {"reasoning": "...", "action": "double_click", "coordinate": [x, y], "label": "short element name"}
    {"reasoning": "...", "action": "right_click", "coordinate": [x, y], "label": "short element name"}
    {"reasoning": "...", "action": "move_mouse", "coordinate": [x, y], "label": "short element name"}
    {"reasoning": "...", "action": "left_click_drag", "start_coordinate": [x, y], "coordinate": [x, y], "label": "what is being dragged"}
    {"reasoning": "...", "action": "scroll", "coordinate": [x, y], "scroll_direction": "up|down|left|right", "scroll_amount": 5}
    {"reasoning": "...", "action": "type", "text": "text to type into the focused field"}
    {"reasoning": "...", "action": "key", "keys": ["command", "t"]}
    {"reasoning": "...", "action": "open_app", "app_name": "Google Chrome"}
    {"reasoning": "...", "action": "wait", "seconds": 2}
    {"reasoning": "...", "action": "answer", "text": "spoken answer to the user's question"}
    {"reasoning": "...", "action": "terminate", "status": "success|failure", "message": "short summary of what happened"}

    Rules:
    - ONE action per turn. After it executes you will receive a fresh screenshot.
    - Always check the screenshot to verify your previous action worked before continuing. If the screen did NOT change after a click, your coordinate was wrong — NEVER click the same coordinate again. Pick a clearly different point on the actual target, scroll to reveal it, or use a different approach.
    - Click precisely on the center of the target element.
    - Before typing, make sure the correct field is focused (click it first if needed).
    - PREFER THE KEYBOARD over clicking whenever both work. The keyboard is reliable; clicking small targets is not.
    - To go to a website: key ["command", "l"] to focus the address bar, type the URL, then key ["return"]. To search the web: same, but type the search query. NEVER click autocomplete or search suggestions in a dropdown — they move and misclick easily. Type the full text and press return instead.
    - After typing into any search field or address bar, submit it with key ["return"]. Do not click a suggestion, a magnifying glass, or a "go" button.
    - If a text field already contains text you do not want, first select it all with key ["command", "a"], then type — typing replaces the selection. Typing without selecting APPENDS to what is already there.
    - Use "open_app" to launch or switch to an app instead of clicking through the Dock.
    - Use "wait" after actions that trigger loading (opening apps, loading pages).
    - Use "answer" when the user asked a question you can answer from the screen — do not perform machine actions for pure questions.
    - Use "terminate" with status "success" as soon as the goal is complete, with a short summary. Use status "failure" only when you cannot make progress.
    - Never invent destructive shortcuts. Do not delete files, send messages, or submit purchases.
    """

    private static func agentTurnPrompt(
        userGoal: String,
        actionHistoryLines: [String],
        stepNumber: Int
    ) -> String {
        let historySection: String
        if actionHistoryLines.isEmpty {
            historySection = "No actions taken yet. This is the first step."
        } else {
            let recentHistoryLines = actionHistoryLines.suffix(maximumActionHistoryLineCount)
            historySection = recentHistoryLines.joined(separator: "\n")
        }

        return """
        User goal:
        \(userGoal)

        Actions taken so far:
        \(historySection)

        This is step \(stepNumber) of at most \(maximumStepCount). The attached screenshot shows the current screen. Respond with the single next action as one JSON object.
        """
    }

    // MARK: - Model action parsing

    /// One parsed action from the model, before coordinate mapping.
    struct JarvisComputerUseModelAction {
        let actionName: String
        let reasoning: String?
        let coordinate: CGPoint?
        let startCoordinate: CGPoint?
        let text: String?
        let keys: [String]?
        let appName: String?
        let scrollDirection: String?
        let scrollAmount: Double?
        let waitSeconds: Double?
        let terminateStatus: String?
        let message: String?
        let label: String?
    }

    static func parseModelAction(from responseText: String) -> JarvisComputerUseModelAction? {
        guard let data = responseText.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Qwen3-VL's native computer-use convention wraps the action as
        // {"name": "computer_use", "arguments": {...}} — unwrap if present.
        if let wrappedArguments = json["arguments"] as? [String: Any] {
            let outerReasoning = json["reasoning"] as? String
            json = wrappedArguments
            if json["reasoning"] == nil, let outerReasoning {
                json["reasoning"] = outerReasoning
            }
        }

        guard let rawActionName = json["action"] as? String else {
            return nil
        }

        let normalizedActionName = normalizeActionName(rawActionName)

        return JarvisComputerUseModelAction(
            actionName: normalizedActionName,
            reasoning: json["reasoning"] as? String,
            coordinate: parseCoordinatePair(json["coordinate"]),
            startCoordinate: parseCoordinatePair(json["start_coordinate"]),
            text: json["text"] as? String,
            keys: parseKeyList(json["keys"]),
            appName: (json["app_name"] as? String) ?? (json["app"] as? String),
            scrollDirection: (json["scroll_direction"] as? String) ?? (json["direction"] as? String),
            scrollAmount: doubleValue(json["scroll_amount"]) ?? doubleValue(json["amount"]),
            waitSeconds: doubleValue(json["seconds"]) ?? doubleValue(json["time"]),
            terminateStatus: json["status"] as? String,
            message: json["message"] as? String,
            label: json["label"] as? String
        )
    }

    /// Maps the model's action vocabulary (and common aliases it may emit)
    /// onto the canonical action names the loop understands.
    private static func normalizeActionName(_ rawActionName: String) -> String {
        switch rawActionName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "left_click", "click", "tap":
            return "left_click"
        case "double_click", "double-click", "doubleclick":
            return "double_click"
        case "right_click", "right-click", "rightclick", "context_click":
            return "right_click"
        case "left_click_drag", "drag", "click_drag":
            return "left_click_drag"
        case "move_mouse", "mouse_move", "hover", "move_to":
            return "move_mouse"
        case "scroll", "swipe":
            return "scroll"
        case "type", "type_text", "input_text":
            return "type"
        case "key", "hotkey", "press_key", "keypress", "press":
            return "key"
        case "open_app", "launch_app", "open":
            return "open_app"
        case "wait", "sleep", "pause":
            return "wait"
        case "answer", "respond", "reply":
            return "answer"
        case "terminate", "finish", "finished", "done", "complete", "stop", "fail":
            return "terminate"
        case "screenshot", "take_screenshot":
            return "screenshot"
        default:
            return rawActionName.lowercased()
        }
    }

    private static func parseCoordinatePair(_ rawValue: Any?) -> CGPoint? {
        if let coordinateArray = rawValue as? [Any], coordinateArray.count >= 2,
           let x = doubleValue(coordinateArray[0]),
           let y = doubleValue(coordinateArray[1]) {
            return CGPoint(x: x, y: y)
        }

        if let coordinateDict = rawValue as? [String: Any],
           let x = doubleValue(coordinateDict["x"]),
           let y = doubleValue(coordinateDict["y"]) {
            return CGPoint(x: x, y: y)
        }

        return nil
    }

    private static func parseKeyList(_ rawValue: Any?) -> [String]? {
        if let keyArray = rawValue as? [String], !keyArray.isEmpty {
            return keyArray
        }
        // The model sometimes emits "command+t" as a single string.
        if let keyString = rawValue as? String, !keyString.isEmpty {
            let separatedKeys = keyString
                .replacingOccurrences(of: "+", with: " ")
                .split(separator: " ")
                .map { String($0) }
            return separatedKeys.isEmpty ? nil : separatedKeys
        }
        return nil
    }

    private static func doubleValue(_ rawValue: Any?) -> Double? {
        if let numberValue = rawValue as? NSNumber {
            return numberValue.doubleValue
        }
        if let stringValue = rawValue as? String {
            return Double(stringValue)
        }
        return nil
    }

    // MARK: - Screenshot preparation

    /// Resizes a captured screenshot to exactly 768x768 pixels (the model's
    /// coordinate grid size). This intentionally ignores aspect ratio: when the
    /// image dimensions equal the grid dimensions, the model's coordinates map
    /// correctly whether it grounds on the relative grid or in the input
    /// image's pixel space. The aspect distortion is undone when grid
    /// coordinates are scaled back to the display's real width and height.
    private static func resizeScreenshotToModelGrid(_ originalImageData: Data) -> Data? {
        guard let originalImage = NSImage(data: originalImageData) else { return nil }

        let gridPixelSize = Int(modelCoordinateGridSize)
        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: gridPixelSize,
            pixelsHigh: gridPixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        bitmapRep.size = NSSize(width: gridPixelSize, height: gridPixelSize)

        NSGraphicsContext.saveGraphicsState()
        let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmapRep)
        NSGraphicsContext.current = graphicsContext
        graphicsContext?.imageInterpolation = .medium
        originalImage.draw(
            in: NSRect(x: 0, y: 0, width: gridPixelSize, height: gridPixelSize),
            from: NSRect(origin: .zero, size: originalImage.size),
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()

        // Lower quality shrinks the vision payload; coordinates use the same
        // square grid either way.
        return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.55])
    }

    // MARK: - Loop guard

    /// Pointer actions whose exact repetition signals the model is stuck.
    /// Scroll and wait are excluded because repeating them is legitimate
    /// (scrolling through a long page, waiting for a slow load).
    private static let pointerToolActionNames: Set<String> = [
        "left_click", "double_click", "right_click", "move_mouse", "left_click_drag"
    ]

    /// Builds a coarse signature for pointer actions so near-identical repeats
    /// are caught. Coordinates are bucketed to 20 grid units (~2% of the
    /// screen) because the model rarely reproduces the exact same pixel when
    /// it genuinely retargets, but lands in the same bucket when it is stuck.
    static func pointerActionSignature(for modelAction: JarvisComputerUseModelAction) -> String? {
        guard pointerToolActionNames.contains(modelAction.actionName),
              let gridCoordinate = modelAction.coordinate else {
            return nil
        }

        let coordinateBucketSize = 20.0
        let bucketedX = Int((Double(gridCoordinate.x) / coordinateBucketSize).rounded())
        let bucketedY = Int((Double(gridCoordinate.y) / coordinateBucketSize).rounded())
        return "\(modelAction.actionName)@\(bucketedX),\(bucketedY)"
    }

    // MARK: - Coordinate mapping

    /// Converts a point on the model's 1000x1000 grid (top-left origin) to a
    /// global AppKit point (bottom-left origin) on the captured display.
    static func globalAppKitPoint(
        fromGridPoint gridPoint: CGPoint,
        screenCapture: CompanionScreenCapture
    ) -> CGPoint {
        let clampedGridX = min(max(Double(gridPoint.x), 0), modelCoordinateGridSize)
        let clampedGridY = min(max(Double(gridPoint.y), 0), modelCoordinateGridSize)

        let displayWidth = Double(screenCapture.displayWidthInPoints)
        let displayHeight = Double(screenCapture.displayHeightInPoints)

        let localXFromTopLeft = clampedGridX / modelCoordinateGridSize * displayWidth
        let localYFromTopLeft = clampedGridY / modelCoordinateGridSize * displayHeight
        let localYFromBottomLeft = displayHeight - localYFromTopLeft

        return CGPoint(
            x: Double(screenCapture.displayFrame.origin.x) + localXFromTopLeft,
            y: Double(screenCapture.displayFrame.origin.y) + localYFromBottomLeft
        )
    }

    // MARK: - Tool call mapping

    /// Builds a concrete tool call from a parsed model action, mapping grid
    /// coordinates to global screen coordinates. Returns nil when required
    /// fields are missing or the action is unknown.
    static func toolCall(
        from modelAction: JarvisComputerUseModelAction,
        screenCapture: CompanionScreenCapture
    ) -> JarvisToolCall? {
        let displayFrameArguments: [String: JarvisToolArgumentValue] = [
            "display_frame_x": .number(Double(screenCapture.displayFrame.origin.x)),
            "display_frame_y": .number(Double(screenCapture.displayFrame.origin.y)),
            "display_frame_width": .number(Double(screenCapture.displayFrame.width)),
            "display_frame_height": .number(Double(screenCapture.displayFrame.height))
        ]
        let label = modelAction.label ?? "the target"

        switch modelAction.actionName {
        case "left_click", "double_click", "right_click", "move_mouse":
            guard let gridCoordinate = modelAction.coordinate else { return nil }
            let globalPoint = globalAppKitPoint(fromGridPoint: gridCoordinate, screenCapture: screenCapture)
            var arguments = displayFrameArguments
            arguments["x"] = .number(Double(globalPoint.x))
            arguments["y"] = .number(Double(globalPoint.y))
            arguments["label"] = .string(label)

            let toolName = modelAction.actionName == "left_click" ? "click_at" : modelAction.actionName
            let verb: String
            switch modelAction.actionName {
            case "left_click": verb = "Click"
            case "double_click": verb = "Double-click"
            case "right_click": verb = "Right-click"
            default: verb = "Move mouse to"
            }
            return JarvisToolCall(
                toolName: toolName,
                arguments: arguments,
                userVisibleSummary: "\(verb) \(label)"
            )

        case "left_click_drag":
            guard let startGridCoordinate = modelAction.startCoordinate,
                  let endGridCoordinate = modelAction.coordinate else { return nil }
            let globalStartPoint = globalAppKitPoint(fromGridPoint: startGridCoordinate, screenCapture: screenCapture)
            let globalEndPoint = globalAppKitPoint(fromGridPoint: endGridCoordinate, screenCapture: screenCapture)
            var arguments = displayFrameArguments
            arguments["start_x"] = .number(Double(globalStartPoint.x))
            arguments["start_y"] = .number(Double(globalStartPoint.y))
            arguments["x"] = .number(Double(globalEndPoint.x))
            arguments["y"] = .number(Double(globalEndPoint.y))
            arguments["label"] = .string(label)
            return JarvisToolCall(
                toolName: "drag",
                arguments: arguments,
                userVisibleSummary: "Drag \(label)"
            )

        case "scroll":
            guard let direction = modelAction.scrollDirection?.lowercased(),
                  ["up", "down", "left", "right"].contains(direction) else { return nil }
            var arguments = displayFrameArguments
            arguments["direction"] = .string(direction)
            arguments["amount"] = .number(modelAction.scrollAmount ?? 5)
            if let gridCoordinate = modelAction.coordinate {
                let globalPoint = globalAppKitPoint(fromGridPoint: gridCoordinate, screenCapture: screenCapture)
                arguments["x"] = .number(Double(globalPoint.x))
                arguments["y"] = .number(Double(globalPoint.y))
            }
            return JarvisToolCall(
                toolName: "scroll",
                arguments: arguments,
                userVisibleSummary: "Scroll \(direction)"
            )

        case "type":
            guard let text = modelAction.text, !text.isEmpty else { return nil }
            return JarvisToolCall(
                toolName: "type_text",
                arguments: ["text": .string(text)],
                userVisibleSummary: "Type text"
            )

        case "key":
            guard let keys = modelAction.keys, !keys.isEmpty else { return nil }
            return JarvisToolCall(
                toolName: "press_hotkey",
                arguments: ["keys": .stringArray(keys)],
                userVisibleSummary: "Press \(keys.joined(separator: " + "))"
            )

        case "open_app":
            guard let appName = modelAction.appName, !appName.isEmpty else { return nil }
            return JarvisToolCall(
                toolName: "open_app",
                arguments: ["name": .string(appName)],
                userVisibleSummary: "Open \(appName)"
            )

        case "wait":
            return JarvisToolCall(
                toolName: "wait",
                arguments: ["seconds": .number(modelAction.waitSeconds ?? 2)],
                userVisibleSummary: "Wait for the screen to settle"
            )

        default:
            return nil
        }
    }
}
