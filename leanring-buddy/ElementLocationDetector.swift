//
//  ElementLocationDetector.swift
//  leanring-buddy
//
//  Uses the local Ollama model to identify visible UI element coordinates in
//  screenshots. No cloud LLM is used on the active Jarvis path.
//

import AppKit
import Foundation

class ElementLocationDetector {
    private let localLLMClient: JarvisLocalLLMClient

    private static let supportedVisionResolutions: [(width: Int, height: Int, aspectRatio: Double)] = [
        (1024, 768, 1024.0 / 768.0),
        (1280, 800, 1280.0 / 800.0),
        (1366, 768, 1366.0 / 768.0)
    ]

    init(localLLMClient: JarvisLocalLLMClient = JarvisLocalLLMClient()) {
        self.localLLMClient = localLLMClient
    }

    func detectElementLocation(
        screenshotData: Data,
        userQuestion: String,
        displayWidthInPoints: Int,
        displayHeightInPoints: Int
    ) async -> CGPoint? {
        let visionResolution = bestVisionResolution(
            forDisplayWidth: displayWidthInPoints,
            displayHeight: displayHeightInPoints
        )

        guard let resizedScreenshotData = resizeScreenshotForLocalVision(
            originalImageData: screenshotData,
            targetWidth: visionResolution.width,
            targetHeight: visionResolution.height
        ) else {
            print("⚠️ ElementLocationDetector: failed to resize screenshot")
            return nil
        }

        guard let visionCoordinate = await callLocalVisionModel(
            resizedScreenshotData: resizedScreenshotData,
            userQuestion: userQuestion,
            declaredDisplayWidth: visionResolution.width,
            declaredDisplayHeight: visionResolution.height
        ) else {
            return nil
        }

        let clampedX = max(0, min(visionCoordinate.x, CGFloat(visionResolution.width)))
        let clampedY = max(0, min(visionCoordinate.y, CGFloat(visionResolution.height)))

        let scaledX = (clampedX / CGFloat(visionResolution.width)) * CGFloat(displayWidthInPoints)
        let scaledYTopLeftOrigin = (clampedY / CGFloat(visionResolution.height)) * CGFloat(displayHeightInPoints)
        let scaledYBottomLeftOrigin = CGFloat(displayHeightInPoints) - scaledYTopLeftOrigin

        print("🎯 Local element detection: (\(Int(clampedX)), \(Int(clampedY))) in " +
              "\(visionResolution.width)x\(visionResolution.height) → " +
              "(\(Int(scaledX)), \(Int(scaledYBottomLeftOrigin))) display-local AppKit coords")

        return CGPoint(x: scaledX, y: scaledYBottomLeftOrigin)
    }

    private func bestVisionResolution(
        forDisplayWidth displayWidth: Int,
        displayHeight: Int
    ) -> (width: Int, height: Int) {
        let displayAspectRatio = Double(displayWidth) / Double(max(1, displayHeight))
        var bestWidth = 1280
        var bestHeight = 800
        var smallestAspectRatioDifference = Double.greatestFiniteMagnitude

        for resolution in Self.supportedVisionResolutions {
            let difference = abs(displayAspectRatio - resolution.aspectRatio)
            if difference < smallestAspectRatioDifference {
                smallestAspectRatioDifference = difference
                bestWidth = resolution.width
                bestHeight = resolution.height
            }
        }

        return (width: bestWidth, height: bestHeight)
    }

    private func callLocalVisionModel(
        resizedScreenshotData: Data,
        userQuestion: String,
        declaredDisplayWidth: Int,
        declaredDisplayHeight: Int
    ) async -> CGPoint? {
        let base64Screenshot = resizedScreenshotData.base64EncodedString()
        let prompt = """
        You are the local vision coordinate detector for a macOS assistant.
        The screenshot size is \(declaredDisplayWidth)x\(declaredDisplayHeight) pixels.
        The origin is the top-left corner. x increases right. y increases down.

        User command:
        \(userQuestion)

        Find the single visible UI element the user wants to interact with.
        For commands like "click on the Apple video", choose the center of the
        visible video tile, thumbnail, card, link, or button that best matches
        the user's words. If the exact label is not visible but there is an
        obvious matching visual item, return that item's center.
        Return only JSON.

        If found:
        {"found": true, "x": 123, "y": 456, "label": "search bar"}

        If no specific visible target exists:
        {"found": false}
        """

        do {
            let responseText = try await localLLMClient.generateVisionJSON(
                prompt: prompt,
                imagesBase64: [base64Screenshot]
            )
            return parseCoordinateFromResponse(responseText: responseText)
        } catch {
            print("⚠️ ElementLocationDetector: local vision request failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func parseCoordinateFromResponse(responseText: String) -> CGPoint? {
        guard let data = responseText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("⚠️ ElementLocationDetector: could not parse response JSON")
            return nil
        }

        guard (json["found"] as? Bool) == true,
              let x = json["x"] as? NSNumber,
              let y = json["y"] as? NSNumber else {
            print("🎯 ElementLocationDetector: no specific element detected")
            return nil
        }

        print("🎯 ElementLocationDetector: raw local coordinate (\(x.intValue), \(y.intValue))")
        return CGPoint(x: x.doubleValue, y: y.doubleValue)
    }

    private func resizeScreenshotForLocalVision(
        originalImageData: Data,
        targetWidth: Int,
        targetHeight: Int
    ) -> Data? {
        guard let originalImage = NSImage(data: originalImageData) else { return nil }

        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetWidth,
            pixelsHigh: targetHeight,
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

        bitmapRep.size = NSSize(width: targetWidth, height: targetHeight)

        NSGraphicsContext.saveGraphicsState()
        let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmapRep)
        NSGraphicsContext.current = graphicsContext
        graphicsContext?.imageInterpolation = .high
        originalImage.draw(
            in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
            from: NSRect(origin: .zero, size: originalImage.size),
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()

        return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
