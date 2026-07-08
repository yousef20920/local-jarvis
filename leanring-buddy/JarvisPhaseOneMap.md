# Jarvis Component Map

| Layer | Current files | Purpose |
| --- | --- | --- |
| Input | `BuddyDictationManager.swift`, `BuddyTranscriptionProvider.swift`, `GlobalPushToTalkShortcutMonitor.swift`, `CompanionPanelView.swift` | Capture voice, text commands, shortcut state, and panel input. |
| Assistant | `CompanionManager.swift`, `JarvisVoiceIntentRouter.swift`, `JarvisAssistantManager.swift`, `JarvisComputerUseAgent.swift`, `JarvisOpenAIClient.swift` | Route user intent, ask GPT-5.5 for screen-aware decisions, manage workflow state, and speak results. |
| Tools | `JarvisPhaseTwoTools.swift`, `JarvisComputerUseTools.swift`, `JarvisToolRegistry.swift`, `JarvisSafetyPolicy.swift` | Register, safety-check, and execute macOS actions. |
| Screen | `CompanionScreenCaptureUtility.swift`, `OverlayWindow.swift`, `CompanionResponseOverlay.swift` | Capture the current display and visualize cursor movement, pointing, response text, and audio state. |
| Worker | `worker/src/index.ts` | Proxy GPT-5.5, transcription-token, and TTS calls without exposing secrets in the app. |
| Configuration | `Info.plist`, `worker/wrangler.toml`, `OPENAI_RUNTIME.md` | Configure Worker URL, model name, and runtime secret handling. |

Jarvis uses deterministic rule-based tools for fast screen-independent commands and GPT-5.5 observe-act turns for screen-dependent or multi-step work.
