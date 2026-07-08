# Software Implementation Plan

## Current Architecture

Local Jarvis is a software-only macOS app. The app runs in the menu bar, captures voice and screen context, and delegates model reasoning to GPT-5.5 through the Cloudflare Worker.

## Active Assistant Path

1. `BuddyDictationManager` captures push-to-talk audio.
2. `BuddyTranscriptionProviderFactory` defaults to Apple Speech.
3. `CompanionManager` receives the final transcript.
4. `JarvisVoiceIntentRouter` classifies the transcript with GPT-5.5.
5. `JarvisAssistantManager` runs deterministic fast-path commands when no screen context is needed.
6. `JarvisComputerUseAgent` runs the observe-act loop for visual and multi-step commands.
7. `JarvisOpenAIClient` sends GPT-5.5 Responses API requests to the Worker.
8. `JarvisPhaseTwoTools` and `JarvisComputerUseTools` execute macOS actions.
9. `OverlayWindow` visualizes pointer actions and response state.

## Worker Path

The Worker owns secrets and calls upstream services:

- `POST /responses`: OpenAI GPT-5.5 Responses API.
- `POST /chat`: Alias for `/responses`.
- `POST /tts`: ElevenLabs text-to-speech.
- `POST /transcribe-token`: AssemblyAI streaming token.

## Command Examples

- "Open Chrome and search for Toronto weather."
- "Click the Apple video."
- "Scroll down and tell me what the page says."
- "Book the first available appointment."
- "Type this reply into the focused text box."

## Verification Checklist

- Worker has `OPENAI_API_KEY` configured as a secret or in ignored `worker/.dev.vars`.
- Worker has non-secret `OPENAI_MODEL = "gpt-5.5"` in `wrangler.toml`.
- App `Info.plist` points `JarvisOpenAIResponsesProxyURL` at the desired Worker `/responses` URL.
- The app is run from Xcode, not terminal `xcodebuild`.
- Screen Recording, Accessibility, Microphone, and Screen Content permissions are granted.
- Voice route, action route, action-then-vision route, and stop command all work.
