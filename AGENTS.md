# Local Jarvis - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Cursor, Copilot, Gemini CLI, and other coding agents. -->

## Overview

Local Jarvis is a macOS and Linux assistant whose main goal is to behave like a local secretary for the user's computer. The user gives it a voice or text command, Jarvis sees the current screen, decides what to do next, and operates the desktop in front of the user by clicking, typing, scrolling, dragging, opening apps, pressing hotkeys, answering screen-aware questions, and carrying out longer workflows step by step.

The app lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Always Listen is enabled by default after onboarding and segments speech after a short silence; push-to-talk (ctrl+option) remains available. Informational transcripts route through visible Google Chrome research using the Jarvis computer-use loop, while screen questions use the screen-aware GPT response path. GPT-5.5 runs through the Cloudflare Worker proxy using the OpenAI Responses API. A blue cursor overlay can fly to and point at UI elements Jarvis references on any connected monitor.

The separate `linux/` Python client provides terminal and Tk window interfaces. It reuses the Worker and 768x768 observe-act protocol, captures the display under the pointer with MSS, and controls X11 through PyAutoGUI. Linux runs have no automatic step limit by default and expose a Stop Jarvis window for manual cancellation. Native Wayland control, voice input, the cursor overlay, and a tray indicator are not yet implemented on Linux.

All API keys live on a Cloudflare Worker proxy — nothing sensitive ships in the app.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat / Agent Reasoning**: OpenAI GPT-5.5 through the Cloudflare Worker proxy using the Responses API. Informational questions are researched by operating the user's local Google Chrome through visible browser actions before Jarvis answers.
- **Speech-to-Text**: Apple Speech by default; AssemblyAI real-time streaming remains available through the Worker token route
- **Text-to-Speech**: ElevenLabs (`eleven_flash_v2_5` model) via Cloudflare Worker proxy
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+). Screen-aware answers can stay scoped to the cursor display; the computer-use loop captures and labels every connected display before each action.
- **Voice Input**: Continuous hands-free listening and push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. Always Listen uses audio-power and transcript-aware silence segmentation, pauses during Jarvis speech, and automatically reopens transcription sessions. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: GPT embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: PostHog via `ClickyAnalytics.swift`
- **Linux Client**: Python 3.10+, Tkinter interface, MSS capture, and PyAutoGUI X11 automation

### API Proxy (Cloudflare Worker)

The app never calls external APIs directly. All requests go through a Cloudflare Worker (`worker/src/index.ts`) that holds the real API keys as secrets.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /responses` | `api.openai.com/v1/responses` | GPT-5.5 vision, routing, and agent turns |
| `POST /chat` | `api.openai.com/v1/responses` | Backward-compatible alias for `/responses` |
| `POST /tts` | `api.elevenlabs.io/v1/text-to-speech/{voiceId}` | ElevenLabs TTS audio |
| `POST /transcribe-token` | `streaming.assemblyai.com/v3/token` | Fetches a short-lived (480s) AssemblyAI websocket token |

Worker secrets: `OPENAI_API_KEY`, `ASSEMBLYAI_API_KEY`, `ELEVENLABS_API_KEY`
Worker vars: `OPENAI_MODEL`, `ELEVENLABS_VOICE_ID`

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Always Listen Lifecycle**: A persisted, user-visible toggle defaults on after onboarding. `CompanionManager` maintains the continuous transcription session, while `BuddyDictationManager` detects a completed utterance after recognized speech followed by 1.25 seconds of silence. The session pauses during Jarvis TTS so the assistant does not transcribe itself, and resumes automatically afterward. An explicit push-to-talk press temporarily takes priority.

**Transient Cursor Mode**: When "Show Clicky" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity. The user-facing name will be migrated to Jarvis in later phases.

**Jarvis Computer-Use Agent Loop**: Jarvis executes commands through an observe-act loop instead of planning everything upfront. Each iteration captures and labels every connected display, resizes each image to its own 768x768 coordinate grid, asks GPT-5.5 through the Worker for the single next action and target screen number, maps that display-local coordinate to a global screen point, gates the action through the safety policy, executes it, and repeats until GPT terminates, answers, the user cancels, or the 24-hour/10,000-action runaway guards are reached. The app prevents idle system sleep during the run. GPT-5.5 handles voice intent routing, agent turns, and screen-aware answers. Screen-independent commands (open app, hotkey, type, screenshot) still run instantly through the deterministic rule planner without any model call. Failed actions do not abort the run — GPT sees the failure in its history plus fresh screenshots and can try another way.

**Durable Agent Checkpoints**: Before each computer-use side effect, Jarvis stores the goal, a bounded recent history, the next step number, timestamps, any pending confirmation, and whether terminal access was explicitly granted for that saved task in `UserDefaults`. A started action is recorded as completion-uncertain before execution, so reopening or resuming observes current state instead of automatically replaying a click, submission, or command that may already have finished. The panel exposes Resume, Discard, Allow once, Allow for task, and Cancel task controls; voice can resume or discard, but cannot grant terminal access.

**Concurrent Secretary Interactions**: `CompanionManager` owns long-running computer work separately from the replaceable short-response task. Always Listen can answer a screen question without cancelling the computer task already in progress. Local Chrome research is computer work, so Jarvis refuses it and any other second action until the active task completes or the user explicitly says “Jarvis stop,” preventing two workflows from fighting over the same mouse and keyboard.

**Transient Failure Recovery**: Screen observation and retryable computer-use GPT requests use capped exponential backoff. Only capture and model inference are retried. Local tool actions remain outside the retry helper so uncertain clicks, submissions, keystrokes, and terminal commands are never automatically replayed.

**Consequential UI Confirmation**: The agent uses ordinary click and hotkey actions for reversible preparation, but must emit `confirm_click` or `confirm_key` for the final control that sends, submits, publishes, deletes, purchases, shares private data, or changes a system/account setting. These map to separate confirmation-required tools. Their label must precisely describe the effect and include the relevant recipient, destination, item, or amount, allowing Jarvis to complete broad secretary work without hiding an irreversible step inside a generic click.

**Confirmation-Gated Terminal Work**: GPT can propose `run_terminal_command` for coding, builds, tests, file operations, or scripts when the shell is more reliable than driving a terminal UI. The tool requires an absolute existing working directory, captures bounded output, and supports cancellation. The first command stops at the safety gate and is displayed verbatim. “Allow once” authorizes only that command; the explicit panel-only “Allow for task” choice records terminal authorization in the durable checkpoint and lets later terminal commands continue unattended. The grant applies only to `run_terminal_command`, survives restart with that task, and is cleared on completion, stop, discard, or replacement. Consequential GUI actions remain independently confirmed.

**Mac Test Isolation**: Hosted unit tests load the app executable but `CompanionAppDelegate` detects `XCTestConfigurationFilePath` and skips analytics, login-item registration, menu-bar construction, microphone capture, screen capture, and other runtime services. The shared scheme includes the app and unit-test target but excludes UI tests. GitHub Actions runs those unit tests on an ephemeral `macos-26` runner with signing disabled, which validates Swift compilation without touching a developer Mac's TCC database.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~97 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. Hosted unit-test launches are detected before runtime services start. |
| `CompanionManager.swift` | ~1417 | Central state machine. Owns continuous-listening maintenance, dictation, shortcut monitoring, screen capture, GPT-backed Jarvis voice routing, local Chrome research dispatch, saved-task voice controls, independent short-response and long-running task lifetimes, system speech responses, and overlay management. Tracks voice state, conversation history, selected OpenAI model display, and cursor visibility. Informational transcripts route through visible Chrome computer use, while screen questions use the screen-aware response path. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~1130 | SwiftUI panel content for the menu bar dropdown. Shows companion status, Always Listen controls, GPT-5.5 model status, Jarvis text command box with workflow progress, saved-task resume/discard controls, a persistent task-terminal-approval indicator, exact pending terminal commands with Allow once and Allow for task choices, permissions UI, DM feedback button, and quit button. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~152 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns deterministically ordered, labeled image data and AppKit display geometry for each connected display, with the cursor display first. |
| `BuddyDictationManager.swift` | ~946 | Voice capture pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, continuous-listening silence segmentation, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~100 | Protocol surface and provider factory for voice transcription backends. Defaults to Apple Speech based on `VoiceTranscriptionProvider` in Info.plist. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Streaming transcription provider. Fetches temp tokens from the Cloudflare Worker, opens an AssemblyAI v3 websocket, streams PCM16 audio, tracks turn-based transcripts, and delivers finalized text on key-up. Shares a single URLSession across all sessions. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `ElevenLabsTTSClient.swift` | ~81 | ElevenLabs TTS client. Sends text to the Worker proxy, plays back audio via `AVAudioPlayer`. Exposes `isPlaying` for transient cursor scheduling. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `ClickyAnalytics.swift` | ~121 | PostHog analytics integration for usage tracking. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `JarvisAssistantManager.swift` | ~519 | Jarvis coordinator. Screen-independent commands run through the deterministic rule planner for instant execution; everything else runs through the computer-use agent loop. It converts informational questions into explicit local Chrome research goals requiring typing, result clicks, and page scrolling. Rejects overlapping action workflows, persists and restores durable checkpoints, owns one-command and task-wide terminal confirmation plus resume/discard state, mirrors agent progress into observable workflow state, and returns explicit spoken results. |
| `JarvisComputerUseAgent.swift` | ~1056 | GPT-backed observe-act agent loop. Captures every connected display each step, asks GPT-5.5 for the single next action and screen number on per-display 768x768 grids, maps ordinary and confirmation-gated consequential actions, checkpoints before side effects and task-scoped terminal approval, applies the safety policy, and executes. Supports restart-safe continuation, bounded capture/model retries that exclude tool side effects, and runs up to 24 hours/10,000 actions while preventing idle sleep. Terminal actions: answer, terminate. |
| `JarvisComputerUseTools.swift` | ~340 | Mouse, scroll, and timing tools completing the human-equivalent action set: double_click, right_click, drag, move_mouse, scroll, and wait. CGEvent-based, converting AppKit global coordinates to Quartz before posting. |
| `JarvisDebugLogger.swift` | ~55 | Verbose console logging for the Jarvis pipeline. All lines use the `🐛 [Jarvis:<category>]` prefix for Xcode console filtering. |
| `JarvisPlanner.swift` | ~292 | Planner protocol plus the rule-based planner for screen-independent fast-path commands like open app, type text, press hotkey, search, and screenshot. |
| `JarvisOpenAIClient.swift` | ~232 | Worker-backed OpenAI Responses API client. Sends GPT-5.5 text, vision, and agent-turn requests to the Cloudflare Worker without exposing the API key in the app. |
| `JarvisVoiceIntentRouter.swift` | ~339 | GPT-backed router classifying requests as action, screen-aware vision, local Chrome research, or action-then-vision before dispatch. Deterministic corrections keep questions and information-seeking imperatives on the Chrome-research path, and whole-phrase command matching prevents names such as OpenAI or words such as research from being mistaken for Mac commands. |
| `JarvisWorkflowState.swift` | ~53 | Observable multi-step workflow model with per-step pending/running/succeeded/failed state. |
| `JarvisTool.swift` | ~147 | Shared Jarvis tool contracts: argument values, tool definitions, tool calls, execution context, structured results, and typed argument helpers. |
| `JarvisToolRegistry.swift` | ~35 | Registry for local macOS tools available to Jarvis. Phase 2 registers app, keyboard, screenshot, pointer, waiting, and confirmation-gated terminal tools through `JarvisPhaseTwoToolInstaller`. |
| `JarvisSafetyPolicy.swift` | ~68 | Central allow/confirm/block decisions for planned Jarvis tool calls, including distinct confirmation gates for consequential clicks, hotkeys, and terminal commands. |
| `JarvisPhaseTwoTools.swift` | ~534 | Core executable local tools for Jarvis: open app, type text, press hotkeys, take screenshots, click screen coordinates, execute separately confirmed consequential clicks/hotkeys, and run a user-confirmed cancellable terminal command with bounded output. Its installer also registers the computer-use tools from `JarvisComputerUseTools.swift`. |
| `JarvisPhaseOneMap.md` | ~29 | Maps existing macOS app components to the Jarvis input, assistant, tool, output, and configuration layers. |
| `leanring-buddy.xcodeproj/xcshareddata/xcschemes/leanring-buddy.xcscheme` | ~102 | Shared clean-machine Xcode scheme that builds the app and unit tests while excluding TCC-sensitive UI tests. |
| `.github/workflows/macos-unit-tests.yml` | ~45 | GitHub Actions workflow using an ephemeral `macos-26` runner to resolve packages, compile the app, and run `leanring-buddyTests` with code signing disabled. |
| `leanring-buddyTests/leanring_buddyTests.swift` | ~294 | Swift Testing regression suite covering permissions, checkpoint compatibility, terminal safety, retry behavior, multi-monitor action identity, consequential confirmations, and internet-routing corrections. |
| `worker/src/index.ts` | ~166 | Cloudflare Worker proxy. Routes: `/responses` and `/chat` (OpenAI GPT-5.5 Responses API), `/tts` (ElevenLabs), `/transcribe-token` (AssemblyAI temp token). |
| `linux/src/local_jarvis_linux/agent.py` | ~380 | Linux observe-act loop, model action parsing, coordinate mapping, and repeated-pointer loop guard. |
| `linux/src/local_jarvis_linux/desktop.py` | ~235 | Linux multi-monitor capture and X11 mouse, keyboard, clipboard, scrolling, and app-launching backend. |
| `linux/src/local_jarvis_linux/openai_client.py` | ~95 | Standard-library HTTP client for the existing Worker-backed Responses API route. |
| `linux/src/local_jarvis_linux/cli.py` | ~130 | Linux command-line entry point, interactive prompt, environment check, and GUI launcher. |
| `linux/src/local_jarvis_linux/gui.py` | ~155 | Small Tk command window with background agent execution, live step status, and manual cancellation control. |
| `linux/tests/` | ~225 | Linux unit tests for configuration, unlimited and cancelled agent runs, model parsing, coordinate mapping, loop guards, and Responses API output extraction. |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

The exception is `.github/workflows/macos-unit-tests.yml`, which runs on a disposable GitHub-hosted Mac and therefore cannot invalidate permissions on the user's Mac. Use Xcode's Product > Test locally.

### Linux

```bash
python3 -m venv .venv-linux
. .venv-linux/bin/activate
python3 -m pip install -e ./linux
export JARVIS_RESPONSES_URL="http://127.0.0.1:8787/responses"
local-jarvis --check
local-jarvis --gui
```

Linux desktop automation currently requires an X11 session or usable XWayland `DISPLAY`. See `linux/README.md` for distro packages and limitations.

## Cloudflare Worker

```bash
cd worker
npm install

# Add secrets
npx wrangler secret put OPENAI_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY

# Deploy
npx wrangler deploy

# Local dev (create worker/.dev.vars with your keys)
npx wrangler dev
```

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
