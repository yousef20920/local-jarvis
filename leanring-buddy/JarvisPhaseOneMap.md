# Jarvis Phase 1 Map

Phase 1 adds Jarvis software boundaries without changing the current app's runtime behavior.

## Existing App Responsibilities

| Jarvis Layer | Existing App Files | Current Role |
| --- | --- | --- |
| Input | `GlobalPushToTalkShortcutMonitor.swift`, `BuddyDictationManager.swift`, `BuddyTranscriptionProvider.swift` | Keyboard push-to-talk, microphone capture, provider-based transcription |
| Assistant | `CompanionManager.swift`, `ClaudeAPI.swift` | Owns the current transcript + screenshot + Claude response loop |
| Tools | `CompanionScreenCaptureUtility.swift`, `ElementLocationDetector.swift`, `OverlayWindow.swift`, macOS APIs used by managers | Screen capture, screen element detection, cursor pointing, overlay control |
| Output | `OverlayWindow.swift`, `CompanionResponseOverlay.swift`, `ElevenLabsTTSClient.swift`, `CompanionPanelView.swift` | Cursor overlay, response text, speech playback, menu bar panel |
| Configuration | `AppBundleConfiguration.swift`, `Info.plist`, `worker/src/index.ts` | Runtime config and cloud API proxy |

## New Jarvis Boundaries

| File | Purpose |
| --- | --- |
| `JarvisAssistantManager.swift` | Top-level Jarvis coordinator for planning, safety decisions, and future execution |
| `JarvisPlanner.swift` | Converts user commands into structured tool calls |
| `JarvisTool.swift` | Defines tool-call, result, and execution contracts |
| `JarvisToolRegistry.swift` | Holds available local macOS tools |
| `JarvisSafetyPolicy.swift` | Decides whether a planned action can run, needs confirmation, or is blocked |

## Phase 1 Runtime Status

Jarvis is scaffolded but not wired into `CompanionManager` yet. Existing launch, push-to-talk, Claude responses, overlay, and TTS behavior should remain unchanged.

The next phase should add a text-only debug command path that calls `JarvisAssistantManager.previewPlan(for:)` before any real tool execution is enabled.
