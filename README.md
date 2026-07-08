# Local Jarvis

Local Jarvis is a macOS assistant that lives on your machine and does work in front of you. You talk to it, it looks at the current screen, decides the next action, and uses the same basic controls a person would use: click, type, scroll, drag, open apps, press hotkeys, wait, and answer questions about what it sees.

The goal is to feel less like a chatbot and more like a secretary for your computer: ask it to book something, fill something out, find information, operate an app, or complete a long workflow, then watch it carry out the task step by step.

## What It Does

- Listens through push-to-talk from the macOS menu bar
- Understands spoken or typed commands
- Captures the current screen across connected displays
- Uses OpenAI GPT-5.5 to choose the next UI action
- Executes macOS actions through mouse, keyboard, app, and screenshot tools
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
6. Repeat until the task is done, GPT answers, or the run reaches its step limit.

Fast screen-independent commands such as opening apps, typing text, pressing hotkeys, searching, and taking screenshots run through deterministic rules. Visual or multi-step tasks go through the GPT-backed computer-use loop.

## Architecture

```text
leanring-buddy/          macOS Swift/SwiftUI app source
leanring-buddy.xcodeproj Xcode project
worker/                  Cloudflare Worker proxy for OpenAI, AssemblyAI, and ElevenLabs
scripts/                 Release/helper scripts from the upstream app
SOFTWARE_ONLY_PLAN.md    Current Jarvis implementation notes
OPENAI_RUNTIME.md        OpenAI Worker runtime setup
CLICKY_README.md         Short upstream Clicky attribution note
```

Core app pieces:

- Menu bar app with no Dock icon or main window
- Custom AppKit/SwiftUI floating panel for controls
- Global push-to-talk shortcut with a listen-only `CGEvent` tap
- ScreenCaptureKit screenshots for multi-monitor screen context
- Worker-backed GPT-5.5 agent for visual computer use
- macOS tools for clicking, typing, scrolling, dragging, hotkeys, app launching, and screenshots
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
