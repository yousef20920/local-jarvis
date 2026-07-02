# Local Jarvis

Local Jarvis is a software-only macOS assistant prototype. The first MVP runs entirely on this Mac: press a keyboard shortcut, talk to Jarvis, let it inspect the screen, plan safe structured tool calls, control macOS, and report what happened.

The current implementation is built from the open-source Clicky macOS codebase and is being reshaped into a Jarvis-first app.

## Current Layout

```text
leanring-buddy/          # macOS Swift/SwiftUI app source
leanring-buddy.xcodeproj # Xcode project
worker/                  # Cloudflare Worker proxy for AI/STT/TTS services
scripts/                 # Release/helper scripts from the upstream app
PRD.md                   # Original hardware-oriented product plan
SOFTWARE_ONLY_PLAN.md    # Current software-only Jarvis plan
CLICKY_README.md         # Original upstream Clicky README
LICENSE                  # Upstream MIT license notice
```

## Current Phase

Jarvis now runs a fully local computer-use agent loop. Apple Speech transcribes voice, a small local Qwen text model routes intent, and Qwen3-VL looks at a fresh screenshot before visual actions, picks the next mouse/keyboard step, and adapts when something fails. macOS system speech speaks the result.

Simple screen-independent commands (`open Chrome`, `press command space`, `type hello world`, `take screenshot`, `search for local LLMs for Mac`) still execute instantly through deterministic rules. Everything else — clicks, multi-step tasks, screen questions — goes through the observe-act agent loop, which can click, double-click, right-click, drag, scroll, move the mouse, type, press hotkeys, open apps, and wait, up to 15 steps per command.

Local runtime setup (native Ollama — Docker has no GPU access on macOS, so the model server must run natively for usable speed):

```bash
brew install --cask ollama-app
open -a Ollama
ollama pull qwen3-vl:8b-instruct
```

Use `qwen3-vl:8b-instruct` for routing, vision, and the agent loop. The smaller Qwen text models are faster, but they were not reliable enough for deciding whether Jarvis should answer, search, click, or type. The bare `qwen3-vl:8b` tag is the thinking variant, which spends minutes on thinking tokens and returns empty content under JSON-enforced output. `qwen3-vl:4b-instruct` is available as a faster, smaller option in the in-app model picker. If your installed tag differs, update the picker or set the `jarvisLocalRouterModel`, `jarvisLocalLLMModel`, and `jarvisLocalVisionModel` app defaults.

## Attribution

This project currently includes code from Clicky by Farza, licensed under MIT. Keep the included `LICENSE` notice with substantial copies or distributions of this software.
