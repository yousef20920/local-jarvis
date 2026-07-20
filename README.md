# Local Jarvis

Local Jarvis is a macOS assistant that lives on your machine and does work in front of you. You talk to it, it looks at the current screen, decides the next action, and uses the same basic controls a person would use: click, type, scroll, drag, open apps, press hotkeys, wait, and answer questions about what it sees.

The goal is to feel less like a chatbot and more like a secretary for your computer: ask it to book something, fill something out, find information, operate an app, or complete a long workflow, then watch it carry out the task step by step.

## What It Does

- Always listens after onboarding, automatically submitting speech after a short silence
- Keeps push-to-talk available through Control+Option
- Understands spoken or typed commands
- Grounds informational questions with a required live web search and shows clickable sources
- Captures every connected display before each computer-use action
- Uses OpenAI GPT-5.5 to choose the next UI action
- Executes macOS actions through mouse, keyboard, app, screenshot, and confirmation-gated terminal tools
- Saves long-running task checkpoints and can safely resume or discard them after an app restart
- Speaks back with a concise result
- Shows a floating cursor overlay while it works
- Keeps API keys out of the app by routing model calls through a Cloudflare Worker

## Current State

The app is a Swift/SwiftUI macOS prototype built from the original Clicky codebase and reshaped into a Jarvis-first computer-use assistant.

Jarvis now has a GPT-backed observe-act loop:

1. Capture a fresh screenshot.
2. Ask GPT-5.5 for one next action through the Worker.
3. Map model coordinates to the real macOS screen.
4. Check the action against the safety policy.
5. Execute the action.
6. Repeat until the task is done, GPT answers, the user stops it, or the 24-hour/10,000-action runaway guards are reached.

Informational questions and information-seeking requests use the Responses API's hosted web-search tool with live access required, and Jarvis refuses to present the answer as grounded unless cited URLs are returned. The panel shows those citations as clickable source links. Screen-specific questions still use a current screenshot. Deterministic routing uses whole command phrases, so names such as “OpenAI” and words such as “research” are not mistaken for Open or Search computer commands.

Fast screen-independent commands such as opening apps, typing text, pressing hotkeys, searching, and taking screenshots run through deterministic rules. Visual or multi-step tasks go through the GPT-backed computer-use loop.

Long computer-use runs can remain active for up to 24 hours and 10,000 actions. Jarvis prevents idle system sleep while a run is active, keeps listening for an interruption, and limits the panel to the latest 50 discovered actions so long workflows do not make the UI grow without bound. A side question gets its own short response task and does not cancel the computer work already underway; a second action is rejected until the current one finishes or the user says “Jarvis stop.”

Screen capture, cited web research, and transient GPT failures use bounded exponential retries. Computer-use retries cover observation and reasoning only—Jarvis never automatically replays a mouse, keyboard, submission, or terminal side effect because its result was interrupted.

Jarvis persists the current goal, recent action history, next step, and pending confirmation before each side effect. If the app closes or a run is interrupted, the panel offers Resume and Discard controls. Actions recorded as started are treated as potentially completed, so a resumed run observes the current machine state instead of blindly replaying them.

For coding, builds, tests, and scripts, the agent can propose an exact shell command and absolute working directory. The first command is shown verbatim in the panel. “Allow once” remains the default; for unattended vibe-coding runs, the user can instead choose the panel-only “Allow for task” option, which lets later terminal commands run without another prompt until that saved task finishes, is stopped, is discarded, or is replaced. Voice cannot grant terminal access for a task.

Jarvis can also complete consequential human workflows instead of stopping short. Final actions such as Send, Submit, Publish, Delete, Purchase, sharing private information, or changing account/system settings use dedicated confirmation-gated click or keyboard tools. The confirmation description must identify the exact action and relevant recipient, destination, item, or amount; preparatory navigation remains autonomous.

## Architecture

```text
leanring-buddy/          macOS Swift/SwiftUI app source
leanring-buddy.xcodeproj Xcode project
worker/                  Cloudflare Worker proxy for OpenAI, AssemblyAI, and ElevenLabs
scripts/                 Release/helper scripts from the upstream app
.github/workflows/       Ephemeral macOS compilation and unit-test CI
SOFTWARE_ONLY_PLAN.md    Current Jarvis implementation notes
OPENAI_RUNTIME.md        OpenAI Worker runtime setup
CLICKY_README.md         Short upstream Clicky attribution note
```

Core app pieces:

- Menu bar app with no Dock icon or main window
- Custom AppKit/SwiftUI floating panel for controls
- Global push-to-talk shortcut with a listen-only `CGEvent` tap
- User-controlled Always Listen mode that pauses during Jarvis speech and resumes automatically
- ScreenCaptureKit screenshots for every connected display on each agent iteration, with coordinates mapped per display
- Worker-backed GPT-5.5 agent for visual computer use
- Required Responses API web search for source-backed informational answers
- Durable computer-use checkpoints with restart-safe resume and discard controls
- Optional panel-approved terminal autonomy scoped to one saved task for unattended coding workflows
- Independent short-answer and long-running task lifetimes, so Jarvis can answer while it keeps working
- Bounded observation/model retries that never replay machine actions
- macOS tools for clicking, typing, scrolling, dragging, hotkeys, app launching, screenshots, confirmation-gated final UI actions, and user-confirmed terminal commands
- OpenAI Responses API, AssemblyAI transcription tokens, and ElevenLabs TTS through the Cloudflare Worker proxy
- Transparent overlay window for cursor animation, response text, and workflow feedback

## OpenAI Runtime

The macOS app does not store or call with an OpenAI API key directly. It calls the Cloudflare Worker route configured by `JarvisOpenAIResponsesProxyURL`.

For local Worker development, create `worker/.dev.vars`:

```bash
OPENAI_API_KEY=your_key_here
```

For deployed Worker production, store the key as a Cloudflare secret:

```bash
cd worker
npx wrangler secret put OPENAI_API_KEY
```

The non-secret model setting lives in `worker/wrangler.toml`:

```toml
[vars]
OPENAI_MODEL = "gpt-5.5"
```

## Build And Run

Open the project in Xcode:

```bash
open leanring-buddy.xcodeproj
```

Then select the `leanring-buddy` scheme, set the signing team, and run with `Cmd+R`.

Do not run `xcodebuild` from the terminal. It can invalidate macOS TCC permissions and force the app to re-request Screen Recording, Accessibility, and related permissions.

The repository includes a shared `leanring-buddy` scheme and a GitHub Actions workflow that compiles the app and runs unit tests on an ephemeral `macos-26` runner. That CI environment is isolated from the user's Mac and therefore does not affect local TCC permissions. Run the same tests locally through Xcode's Product > Test menu.

Known non-blocking warnings:

- Swift 6 concurrency warnings
- Deprecated `onChange` warning in `OverlayWindow.swift`

## Cloudflare Worker

Cloud-backed services go through `worker/src/index.ts`.

```bash
cd worker
npm install
npx wrangler deploy
```

Worker routes:

| Route | Purpose |
| --- | --- |
| `POST /responses` | OpenAI GPT-5.5 Responses API |
| `POST /chat` | Alias for `POST /responses` |
| `POST /tts` | ElevenLabs text-to-speech |
| `POST /transcribe-token` | Short-lived AssemblyAI streaming token |

## Project Direction

The north star is a fast Jarvis for macOS: a voice-first assistant that can safely operate the visible computer, adapt as the screen changes, and complete real workflows instead of only explaining what to do.

## Attribution

This project currently includes code from Clicky by Farza, licensed under MIT. Keep the included `LICENSE` notice with substantial copies or distributions of this software.
