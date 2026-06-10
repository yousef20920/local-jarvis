# PRD: Local Jarvis Device with Raspberry Pi + Desktop Control

## 1. Summary

Build a small external AI assistant device using a Raspberry Pi 4. The device listens to the user, runs a local LLM, answers questions, and controls the user’s computer through a local desktop agent inspired by Clicky.

The Raspberry Pi acts as the assistant’s brain and voice. The computer-side agent acts as its eyes and hands.

```text
User speaks
↓
Raspberry Pi listens + runs local LLM
↓
Pi sends tool command to computer agent
↓
Computer agent sees screen, clicks, types, opens apps, searches files
↓
Pi speaks the result
```

---

## 2. Goals

1. Run the assistant locally on a Raspberry Pi 4.
2. Use a small local LLM instead of cloud AI.
3. Let the assistant control the user’s own computer.
4. Support voice commands, screen awareness, cursor control, typing, app launching, browser use, and file search.
5. Require confirmation before sensitive actions.

---

## 3. Non-Goals

1. No cloud LLM dependency for core functionality.
2. No bypassing OS permissions.
3. No controlling devices the user does not own.
4. No deleting files, sending messages, submitting forms, or running commands without confirmation.
5. No large model support on Raspberry Pi 4 for MVP.

---

## 4. Target User

A technical user who wants a private, local “Jarvis” device that can talk, answer questions, and control their computer hands-free.

---

## 5. Core Components

### Raspberry Pi Device

Responsibilities:

1. Wake word or push-to-talk.
2. Speech-to-text.
3. Local LLM reasoning.
4. Tool-call planning.
5. Text-to-speech.
6. Communication with the desktop agent.

Suggested hardware:

```text
Raspberry Pi 4
128GB microSD or USB SSD
USB microphone
Small speaker
Optional display
Cooling case/fan
```

### Local LLM

Use a small quantized model, ideally around 2B parameters.

Possible runtime:

```text
llama.cpp
Ollama if performance is acceptable
```

The model should output structured tool calls, not uncontrolled commands.

Example:

```json
{
  "tool": "open_app",
  "arguments": {
    "app_name": "Chrome"
  }
}
```

### Desktop Agent

A local app running on the user’s computer.

Responsibilities:

1. Take screenshots.
2. Read active window/app info.
3. Move cursor.
4. Click.
5. Type.
6. Press hotkeys.
7. Open apps.
8. Control browser.
9. Search/read files.
10. Return success/error results.

For MVP, this can be a Python agent. Later, it can evolve into a Clicky-style macOS app.

---

## 6. System Architecture

```text
Raspberry Pi
  - wake word
  - speech-to-text
  - local LLM
  - text-to-speech
  - tool planner

Local network

Desktop Agent
  - screen capture
  - mouse/keyboard control
  - app control
  - browser automation
  - file tools
```

Communication:

```text
Pi → HTTP/WebSocket → Desktop Agent
```

Example desktop API:

```text
POST /screenshot
POST /click
POST /type
POST /hotkey
POST /open-app
POST /search-files
POST /read-file
POST /browser/search
```

All requests must use local authentication.

---

## 7. MVP Features

### MVP 1: Text-Only Assistant

User types commands into the Pi terminal.

Success criteria:

1. Pi runs local LLM.
2. LLM responds to basic questions.
3. LLM can produce structured tool calls.

---

### MVP 2: Desktop Agent Connection

Pi connects to the computer agent.

Success criteria:

1. Pi can request a screenshot.
2. Pi can send a command.
3. Computer executes basic actions.
4. Computer returns a result.

---

### MVP 3: Mouse and Keyboard Control

Supported commands:

```text
“Click the search bar.”
“Type hello world.”
“Press command space.”
“Scroll down.”
```

Required tools:

1. Move mouse.
2. Click.
3. Type text.
4. Press hotkeys.
5. Scroll.

---

### MVP 4: App, Browser, and File Control

Supported commands:

```text
“Open Chrome.”
“Search for Raspberry Pi local LLM.”
“Find my resume.”
“Open my Downloads folder.”
```

Required tools:

1. Open apps.
2. Search web.
3. Navigate browser.
4. Search files.
5. Open files.
6. Read basic text files.

---

### MVP 5: Voice Interface

Supported flow:

```text
Wake word → record command → transcribe → LLM decides → tool executes → assistant speaks
```

Possible tools:

```text
openWakeWord
Whisper.cpp or Vosk
Piper TTS
```

---

## 8. Safety Requirements

The assistant must ask for confirmation before:

1. Deleting or moving files.
2. Sending emails/messages.
3. Submitting forms.
4. Making purchases.
5. Running terminal commands.
6. Installing software.
7. Changing system settings.
8. Sharing private information.

Example:

```text
“I’m about to delete 3 files from Downloads. Should I continue?”
```

The system must also support:

```text
“Jarvis, stop.”
```

This immediately cancels the current action.

---

## 9. Security Requirements

1. Desktop agent only accepts requests from the trusted Pi.
2. Use a shared secret/token.
3. Do not expose the desktop agent to the public internet.
4. Show a visible indicator when the agent is active.
5. Store logs locally.
6. Avoid storing private transcripts by default.
7. Allow the user to disable the agent instantly.

---

## 10. Technical Stack

### Raspberry Pi

```text
Python
llama.cpp
openWakeWord
Whisper.cpp or Vosk
Piper TTS
FastAPI/WebSocket client
SQLite for settings/memory
```

### Desktop Agent

Fast prototype:

```text
Python
FastAPI
pyautogui
Playwright
pynput
screenshot/OCR tools
```

Later macOS version:

```text
Swift
ScreenCaptureKit
Accessibility API
AppKit
Clicky-style overlay
```

---

## 11. Build Plan

### Phase 1: Local LLM on Pi

1. Install llama.cpp.
2. Run a small quantized model.
3. Build a text-only CLI assistant.
4. Test basic question answering.
5. Test tool-call JSON output.

### Phase 2: Desktop Agent

1. Create local API server on computer.
2. Add authentication.
3. Add screenshot endpoint.
4. Add mouse/keyboard endpoints.
5. Add app/browser/file endpoints.

### Phase 3: Connect Pi to Computer

1. Pi sends tool calls to agent.
2. Agent executes commands.
3. Agent returns status.
4. Pi explains result.

### Phase 4: Add Voice

1. Add wake word or push-to-talk.
2. Add speech-to-text.
3. Add text-to-speech.
4. Connect voice to the existing assistant loop.

### Phase 5: Add Screen Awareness

1. Agent sends screenshot and active window info.
2. Add OCR or UI text extraction.
3. Assistant uses screen context before clicking.
4. Add “click the button/search bar/link” behavior.

### Phase 6: Add Safety Layer

1. Detect risky actions.
2. Ask for confirmation.
3. Add stop command.
4. Add allowlist/denylist for tools.

---

## 12. MVP Success Demo

The MVP is successful when this works:

```text
User: “Jarvis, open Chrome and search for Raspberry Pi local LLM.”

Assistant:
1. Wakes up.
2. Transcribes the command.
3. Local LLM creates tool calls.
4. Desktop agent opens Chrome.
5. Desktop agent types the search.
6. Desktop agent presses Enter.
7. Pi says: “I searched for Raspberry Pi local LLM.”
```

---

## 13. Main Risks

### Raspberry Pi 4 may be slow

Mitigation:

1. Use small quantized models.
2. Start text-only.
3. Use push-to-talk first.
4. Let the desktop agent handle screen/OCR work.

### Screen control may be unreliable

Mitigation:

1. Prefer browser automation over raw clicking.
2. Use OCR and window metadata.
3. Ask user to clarify when uncertain.
4. Use coordinate clicking only as fallback.

### Assistant may perform wrong actions

Mitigation:

1. Confirm sensitive actions.
2. Add stop command.
3. Show what the assistant is about to do.
4. Log actions locally.

---

## 14. Open Questions

1. Is the Raspberry Pi 4 2GB, 4GB, or 8GB?
2. Is the target computer macOS, Windows, or Linux?
3. Should the first desktop agent be Python or Swift?
4. Should MVP use wake word or push-to-talk?
5. Should the Pi have a screen?
6. Which folders should the assistant access?
7. Which actions should be fully blocked?

---

## 15. Recommended MVP Path

```text
1. Build Python desktop agent.
2. Run small local LLM on Pi.
3. Connect Pi to desktop agent.
4. Add text-only tool calling.
5. Add voice input/output.
6. Add screenshots and basic screen context.
7. Add safety confirmations.
8. Later migrate to Clicky-style macOS app.
```

## 16. Final Vision

A small private AI device on the desk that can hear you, think locally, speak back, see your computer screen, move the cursor, type, open apps, search files, browse the web, and help you use your machine hands-free.
