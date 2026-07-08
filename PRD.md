# Local Jarvis PRD

## Goal

Build a macOS menu bar assistant that acts like a secretary for the user's computer. The user talks to Jarvis, Jarvis sees the current screen, decides what action to take next with GPT-5.5, and performs the task visibly through mouse, keyboard, app, screenshot, and waiting tools.

## Product Principles

- Voice-first: push-to-talk is the primary interaction.
- Visible execution: the user should be able to watch Jarvis work.
- Screen-aware: Jarvis uses screenshots to understand what is currently visible.
- Action-oriented: Jarvis should operate apps, not only explain what to do.
- Safe by default: destructive or sensitive actions are blocked or require confirmation.
- Key-safe: API keys live in the Cloudflare Worker, never in the macOS app.

## Core User Flow

1. User presses `ctrl+option`.
2. Jarvis records speech and transcribes it.
3. Jarvis routes the transcript as an action, screen-aware answer, or action followed by answer.
4. For actions, Jarvis captures the screen and asks GPT-5.5 for one next step.
5. Jarvis executes the step through macOS tools.
6. Jarvis repeats observe-act iterations until the task is done, blocked, or stopped.
7. Jarvis speaks a concise result.

## Required Capabilities

- Menu bar-only macOS app with no Dock icon.
- Floating companion panel with status, permissions, text command box, and model status.
- Push-to-talk voice capture.
- Apple Speech transcription by default.
- ScreenCaptureKit screenshot capture for the active display.
- GPT-5.5 via Cloudflare Worker using the OpenAI Responses API.
- Mouse tools: click, double-click, right-click, move, drag, scroll.
- Keyboard tools: type text and press hotkeys.
- App tools: open or switch to apps.
- Workflow state shown in the panel.
- Cursor overlay that points at targets before pointer actions.
- Stop command: "Jarvis stop".

## Non-Goals

- Shipping API keys in the app bundle.
- Running the assistant model inside the macOS app.
- Asking the user to manually do the next step when Jarvis can safely operate the app itself.
- Replacing macOS permission prompts or bypassing system privacy controls.

## Success Criteria

- User can issue a voice command and see Jarvis perform a multi-step task.
- Simple commands execute quickly through deterministic rules.
- Screen-dependent tasks use fresh screenshots each step.
- GPT-5.5 can answer screen questions and return `[POINT:x,y:label]` tags for visual guidance.
- All model calls route through the Worker.
