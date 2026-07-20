# Local Jarvis PRD

## Goal

Build a macOS menu bar assistant that acts like a secretary for the user's computer. The user talks to Jarvis, Jarvis sees the current screen, decides what action to take next with GPT-5.5, and performs the task visibly through mouse, keyboard, app, screenshot, and waiting tools.

## Product Principles

- Voice-first: Always Listen is the default after onboarding, with push-to-talk available as an explicit override.
- Visible execution: the user should be able to watch Jarvis work.
- Screen-aware: Jarvis observes every connected display before choosing each action.
- Internet-grounded: informational answers come from a required live web search and expose their sources.
- Action-oriented: Jarvis should operate apps, not only explain what to do.
- Safe by default: destructive or sensitive actions are blocked or require confirmation.
- Recoverable: long tasks persist enough state to resume safely after an interruption or app restart.
- Interruptible, not disposable: a side question must not silently cancel the task Jarvis is already completing.
- Key-safe: API keys live in the Cloudflare Worker, never in the macOS app.

## Core User Flow

1. User speaks naturally, or presses `ctrl+option` for an explicit push-to-talk interaction.
2. Jarvis records speech, detects the end of the utterance, and transcribes it.
3. Jarvis routes the transcript as an action, internet-grounded answer, screen-aware answer, or action followed by answer.
4. For actions, Jarvis captures the screen and asks GPT-5.5 for one next step.
5. Jarvis executes the step through macOS tools.
6. Jarvis repeats observe-act iterations until the task is done, blocked, or stopped.
7. While that work continues, Jarvis can route and answer a side question without replacing the active task.
8. Jarvis speaks a concise result.

## Required Capabilities

- Menu bar-only macOS app with no Dock icon.
- Floating companion panel with status, permissions, text command box, and model status.
- Continuous hands-free voice capture with silence-based utterance detection and a persisted user toggle.
- Push-to-talk voice capture as an explicit override.
- Apple Speech transcription by default.
- ScreenCaptureKit screenshot capture for every connected display on each agent step, with display-local coordinate mapping.
- GPT-5.5 via Cloudflare Worker using the OpenAI Responses API.
- Required live web search for informational questions, with clickable cited sources in the panel.
- Whole-phrase intent safeguards keep factual product names and information-seeking imperatives on web research instead of misclassifying substrings as Mac commands.
- Mouse tools: click, double-click, right-click, move, drag, scroll.
- Keyboard tools: type text and press hotkeys.
- App tools: open or switch to apps.
- Workflow state shown in the panel.
- Cursor overlay that points at targets before pointer actions.
- Stop command: "Jarvis stop".
- Long-running computer workflows remain active for up to 24 hours/10,000 actions and prevent idle system sleep while executing.
- Durable checkpoints store the goal, bounded recent history, next step, and pending confirmation before an action executes.
- Saved workflows can be resumed or discarded from the panel or by voice; a possibly completed in-flight action is observed before any retry.
- Short web or screen answers have a separate task lifetime from active computer work; another action is refused until the current task finishes or is explicitly stopped.
- Temporary screen-capture, network, rate-limit, and server failures are retried with bounded backoff without retrying side-effecting tools.
- Consequential final UI actions—including Send, Submit, Publish, Delete, Purchase, private-data sharing, and account/system changes—use a distinct confirmed click or hotkey whose description identifies the exact action and relevant recipient, destination, item, or amount.
- Coding, build, test, and script work can use an exact terminal command in an absolute working directory only after panel review. The default is one-command approval; a separate panel-only “Allow for task” grant permits later terminal commands for that saved task and is revoked when the task finishes, stops, is discarded, or is replaced.
- A shared Xcode scheme and ephemeral macOS 26 CI job compile the app and run unit tests without launching voice/screen/login-item services or affecting a developer Mac's TCC permissions.

## Non-Goals

- Shipping API keys in the app bundle.
- Running the assistant model inside the macOS app.
- Asking the user to manually do the next step when Jarvis can safely operate the app itself.
- Replacing macOS permission prompts or bypassing system privacy controls.

## Success Criteria

- User can issue a voice command and see Jarvis perform a multi-step task.
- Factual questions and information-seeking imperatives still route to cited web research when the GPT router is unavailable or returns an incorrect action route.
- Simple commands execute quickly through deterministic rules.
- Screen-dependent tasks use fresh screenshots each step.
- Multi-monitor tasks can target the correct labeled display without assuming every action belongs on the cursor screen.
- An interrupted task appears after restart and resumes from a fresh observation without blindly replaying the last side effect.
- Asking an informational question during a long task does not cancel, replace, or erase that task.
- A transient model or capture failure retries the observation/reasoning request but does not duplicate the preceding machine action.
- Jarvis can prepare a consequential workflow autonomously but cannot activate its final commit control until the user confirms the precisely described action once.
- Terminal commands never execute before the exact command is visibly confirmed in the panel.
- An explicitly granted terminal-autonomous coding task can continue across commands and app restarts, while a new task and every consequential non-terminal action remain separately gated.
- A clean GitHub-hosted Mac can resolve packages, compile the application module, launch the isolated unit-test host, and pass the regression suite.
- GPT-5.5 can answer screen questions and return `[POINT:x,y:label]` tags for visual guidance.
- All model calls route through the Worker.
