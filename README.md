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

Phase 1 is complete. Jarvis has isolated scaffolding for:

1. assistant coordination
2. planner contracts
3. structured tool calls
4. tool registry
5. safety policy
6. mapping existing macOS app pieces to Jarvis layers

The next phase is the text-only Jarvis tool loop.

## Attribution

This project currently includes code from Clicky by Farza, licensed under MIT. Keep the included `LICENSE` notice with substantial copies or distributions of this software.
