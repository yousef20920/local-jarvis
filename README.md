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

Phase 3 is complete. Jarvis now has both a text command loop in the macOS panel and a push-to-talk voice path using the same planner and tools.

Current text commands include:

1. `open Chrome`
2. `open Safari`
3. `type hello world`
4. `press command space`
5. `search for local LLMs for Mac`
6. `take screenshot`

The next phase is screen-aware actions, where Jarvis uses screenshot context before clicking or typing into specific UI elements.

## Attribution

This project currently includes code from Clicky by Farza, licensed under MIT. Keep the included `LICENSE` notice with substantial copies or distributions of this software.
