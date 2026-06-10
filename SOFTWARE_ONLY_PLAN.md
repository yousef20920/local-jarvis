# Software-Only Jarvis Plan

## 1. Summary

Build the first Jarvis MVP entirely on this Mac. Skip Raspberry Pi hardware, external devices, wake-word hardware, and local network communication for now.

The goal is to turn the existing macOS app into a local desktop assistant that can be started with a keyboard shortcut, listen to the user, understand the screen, choose safe tool actions, control macOS, and speak or display the result.

```text
User presses keyboard shortcut
↓
Jarvis records voice
↓
Speech-to-text creates transcript
↓
Assistant planner decides what to do
↓
Local Jarvis desktop-control tools inspect and control macOS
↓
Jarvis speaks and/or displays the result
```

This gives us the full software loop before adding dedicated hardware later.

---

## 2. What Changes From The Original PRD

The original PRD assumes two devices:

1. Raspberry Pi assistant device.
2. Desktop agent running on the computer.

For this MVP, both sides collapse into one local macOS app:

```text
Original:
Raspberry Pi → local network → desktop agent

Software-only MVP:
macOS Jarvis app → local in-process desktop tools
```

We should still design the code as if the assistant brain and desktop tools are separate modules. That keeps the future Raspberry Pi path open, but avoids building networking, device setup, and hardware-specific workflows right now.

---

## 3. Existing Foundation

The imported macOS app already provides most of the macOS control surface:

1. Menu bar app lifecycle.
2. Global push-to-talk shortcut.
3. Microphone capture.
4. Speech-to-text provider abstraction.
5. Screen capture through ScreenCaptureKit.
6. Claude vision chat integration.
7. ElevenLabs text-to-speech.
8. Cursor overlay that can point at screen elements.
9. Cloudflare Worker proxy for cloud API keys.

The first Jarvis implementation should reuse this instead of starting from a separate Python desktop agent.

---

## 4. MVP Goal

The first successful demo should be:

```text
User presses Control + Option.
User says: "Jarvis, open Chrome and search for local LLMs for Mac."
Jarvis captures the screen and transcript.
Jarvis decides the required actions.
Jarvis opens Chrome.
Jarvis types the search query.
Jarvis presses Enter.
Jarvis says: "I searched for local LLMs for Mac."
```

No Raspberry Pi. No external microphone requirement. No wake word requirement. No separate desktop server.

---

## 5. Target Architecture

### macOS Jarvis App

The app should contain four logical layers:

```text
Input Layer
  - keyboard shortcut
  - microphone recording
  - optional typed command input

Assistant Layer
  - transcript handling
  - screen context gathering
  - conversation state
  - tool-call planning
  - safety checks

Tool Layer
  - screenshot
  - click
  - type
  - hotkey
  - scroll
  - open app
  - browser actions
  - file search/read

Output Layer
  - overlay text
  - text-to-speech
  - cursor pointing
  - action status/errors
```

The current macOS app code already has pieces of each layer, but they are oriented around asking Claude for conversational screen help. Jarvis needs a stricter tool-action loop.

---

## 6. Key Design Decision: Tool Calls First

Jarvis should not rely on free-form model text to control the machine.

The assistant should produce structured actions:

```json
{
  "action": "open_app",
  "arguments": {
    "name": "Google Chrome"
  },
  "requires_confirmation": false
}
```

Then the app executes the action through a local tool registry.

This makes actions easier to test, confirm, block, retry, and eventually move back to a Raspberry Pi controller if needed.

---

## 7. Local Tool Registry

Create a Jarvis tool layer with explicit tool definitions.

Initial tools:

1. `take_screenshot`
2. `open_app`
3. `type_text`
4. `press_hotkey`
5. `click_at`
6. `scroll`
7. `get_active_app`
8. `search_files`
9. `open_file`
10. `read_text_file`

Later tools:

1. `browser_open_url`
2. `browser_search`
3. `browser_click_text`
4. `browser_summarize_page`
5. `find_screen_element`
6. `drag`
7. `select_text`
8. `copy_selection`
9. `paste_text`

Each tool should return a structured result:

```json
{
  "ok": true,
  "message": "Opened Google Chrome.",
  "data": {}
}
```

---

## 8. Safety Rules

Jarvis must ask before risky actions.

Require confirmation before:

1. Deleting, moving, or overwriting files.
2. Sending emails, messages, comments, or posts.
3. Submitting forms.
4. Making purchases.
5. Running terminal commands.
6. Installing software.
7. Changing system settings.
8. Sharing private information.
9. Taking actions on financial, medical, legal, or account-security pages.

Always allow:

1. Taking a screenshot.
2. Opening an app.
3. Typing into an obvious search box.
4. Searching the web.
5. Reading user-approved local text files.

Add a stop path:

```text
"Jarvis, stop."
```

This should cancel active speech, clear pending tool calls, and stop any multi-step workflow.

---

## 9. Implementation Phases

### Phase 1: Document And Isolate The Jarvis Loop

Goal: add a clear Jarvis-specific path without disrupting existing app behavior.

Status: complete. The phase added Jarvis scaffolding under `leanring-buddy/` and mapped the current macOS app components in `JarvisPhaseOneMap.md`. The new manager is intentionally not wired into app launch yet.

Tasks:

1. Add Jarvis planning documentation.
2. Identify which existing app classes map to input, assistant, tools, and output.
3. Decide whether Jarvis is a mode inside the current app or a renamed fork.
4. Keep the current app runnable while adding Jarvis internals.

Success criteria:

1. We know where each Jarvis responsibility belongs.
2. Existing app behavior is not broken.

### Phase 2: Text-Only Tool Loop

Goal: make Jarvis work without voice first.

Status: complete. The existing panel now has a Jarvis text command box wired to `JarvisAssistantManager.runTextCommand(_:)`. A rule-based planner supports the first safe commands, and Phase 2 macOS tools can open apps, type text, press hotkeys, and capture screenshots.

Tasks:

1. Add a developer command input UI or temporary debug command path. Done.
2. Send typed text to the assistant planner. Done.
3. Return structured tool calls. Done.
4. Execute safe local tools. Done.
5. Display structured results in the overlay or panel. Done.

Success criteria:

```text
Typed command: "Open Chrome"
Jarvis action: open_app("Google Chrome")
Result: Chrome opens and Jarvis displays success.
```

Additional supported examples:

```text
open Safari
type hello world
press command space
search for local LLMs for Mac
take screenshot
```

### Phase 3: Keyboard Push-To-Talk Jarvis

Goal: use the existing push-to-talk shortcut as the main activation path.

Tasks:

1. Press and hold Control + Option to record.
2. Transcribe the command.
3. Send transcript to the Jarvis planner.
4. Execute returned tool calls.
5. Speak or display the result.

Success criteria:

```text
Voice command: "Open Chrome"
Jarvis opens Chrome.
Jarvis says or displays: "Opened Chrome."
```

### Phase 4: Screen-Aware Actions

Goal: let Jarvis use the screen before clicking or typing.

Tasks:

1. Capture screenshots before planning.
2. Include active display/window context.
3. Let the planner ask for `find_screen_element` before clicking.
4. Use the existing cursor overlay to point before acting when useful.
5. Ask the user to clarify if the target is uncertain.

Success criteria:

```text
Voice command: "Click the search bar"
Jarvis finds the likely search bar and clicks it.
```

### Phase 5: Multi-Step Workflows

Goal: support simple sequences of tool calls.

Tasks:

1. Add a workflow executor.
2. Run one tool call at a time.
3. Feed each result back into the planner.
4. Stop on errors or confirmation requirements.
5. Show progress in the overlay.

Success criteria:

```text
Voice command: "Open Chrome and search for local LLMs for Mac"
Jarvis opens Chrome, types the search, presses Enter, and reports completion.
```

### Phase 6: Local-First AI Replacement

Goal: make cloud dependencies replaceable with local modules, use one of the gemma 4 models, we want to test those models that can run on raspberry pi.

Tasks:

1. Keep Claude as the first planner because the current app already supports it.
2. Add a planner protocol so Claude can be swapped out later.
3. Add a local LLM backend after the tool loop works.
4. Keep AssemblyAI/OpenAI/Apple Speech behind the existing transcription provider abstraction.
5. Add local Whisper later if needed.
6. Keep ElevenLabs behind the TTS client and add local TTS later if needed.

Success criteria:

1. Jarvis can run with current cloud services.
2. Planner, STT, and TTS are modular enough to replace independently.

---

## 10. Recommended First Code Changes

Start small and keep the current app stable.

1. Add `JarvisAssistantManager`.
2. Add `JarvisTool` protocol.
3. Add `JarvisToolRegistry`.
4. Add basic tools for opening apps, typing text, pressing hotkeys, and screenshots.
5. Add a text-only debug command field in the existing panel.
6. Add a `JarvisPlanner` protocol.
7. Implement a simple rule-based planner for early commands:
   - "open Chrome"
   - "type ..."
   - "press command space"
   - "search for ..."
8. Wire voice transcripts into the same planner after the text loop works.

The rule-based planner is intentionally temporary. It lets us verify the desktop-control loop before spending time on model prompting and JSON parsing.

---

## 11. Suggested File Layout

Inside `leanring-buddy/`:

```text
JarvisAssistantManager.swift
JarvisPlanner.swift
JarvisTool.swift
JarvisToolRegistry.swift
JarvisToolExecutor.swift
JarvisSafetyPolicy.swift
JarvisWorkflowState.swift
JarvisDebugCommandView.swift
```

Possible tool files:

```text
JarvisAppTools.swift
JarvisKeyboardTools.swift
JarvisMouseTools.swift
JarvisScreenTools.swift
JarvisFileTools.swift
JarvisBrowserTools.swift
```

---

## 12. Open Questions

1. Should remaining internal names become Jarvis immediately, or should they be renamed gradually after the loop works?
2. Should cloud Claude remain acceptable for the first software-only MVP?
3. Should the first UI be a debug text box in the existing panel or a separate Jarvis panel?
4. Which keyboard shortcut should activate Jarvis long term?
5. Which folders should file tools be allowed to access?
6. Should browser control use accessibility/clicking first or Playwright/Chrome automation first?

---

## 13. Near-Term Definition Of Done

The software-only MVP is done when this works on this Mac:

```text
1. Press and hold a keyboard shortcut.
2. Speak a command.
3. Jarvis transcribes it.
4. Jarvis captures screen context if needed.
5. Jarvis creates structured tool calls.
6. Jarvis executes safe actions through local macOS tools.
7. Jarvis asks before risky actions.
8. Jarvis can be stopped immediately.
9. Jarvis reports what happened.
```

At that point, the Raspberry Pi version becomes a deployment change instead of a product discovery problem.
