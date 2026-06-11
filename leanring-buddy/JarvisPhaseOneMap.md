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

## Runtime Status

Jarvis is scaffolded, the Phase 2 text command loop is wired into `CompanionPanelView`, Phase 3 routes finalized push-to-talk transcripts through the same Jarvis manager, Phase 4 adds screen-aware click/tap commands through `ElementLocationDetector` and `click_at`, Phase 5 adds explicit multi-step workflow state and result-aware continuation hooks, and Phase 6 swaps the active assistant path to local Gemma via Ollama plus Apple/macOS speech. The older Claude screenshot response pipeline still exists in `CompanionManager` but is no longer the default Jarvis route.

The next phase should make planner, speech-to-text, and text-to-speech replacement points clearer for local-first AI backends.
