# Local Jarvis for Linux

The Linux client keeps the same Local Jarvis observe–act loop as the macOS app: it captures the display under the mouse pointer, sends a 768×768 screenshot to the existing Cloudflare Worker, executes one grounded mouse or keyboard action, and repeats with a fresh screenshot.

## Supported today

- Text commands from a terminal or a small desktop window
- Screen-aware questions and multi-step UI workflows
- Multiple monitors, including monitors with offset coordinates
- Left, right, and double click; move, drag, and scroll
- Text entry and Linux keyboard shortcuts
- Launching common installed applications
- Unlimited agent steps by default, with a visible Stop Jarvis control and repeated-click loop guard
- API keys remaining in the Cloudflare Worker

Voice push-to-talk, the animated cursor overlay, and a system tray indicator remain macOS-only for now.

## Requirements

- Python 3.10 or newer
- An X11 desktop session (an XWayland `DISPLAY` can work, but native Wayland blocks global input automation)
- A running or deployed Local Jarvis Cloudflare Worker
- On Debian/Ubuntu: `python3-venv python3-tk scrot xclip`

## Install

From the repository root:

```bash
sudo apt install python3-venv python3-tk scrot xclip
python3 -m venv .venv-linux
. .venv-linux/bin/activate
python3 -m pip install -e ./linux
```

Point the client at the Worker. The default is the local Wrangler URL:

```bash
export JARVIS_RESPONSES_URL="http://127.0.0.1:8787/responses"
```

For a deployed Worker, use its HTTPS `/responses` URL instead.

## Run

Check desktop capture and automation prerequisites:

```bash
local-jarvis --check
```

Open the desktop window:

```bash
local-jarvis --gui
```

Run one command directly:

```bash
local-jarvis "open Firefox and search for the weather"
```

Or start the interactive terminal prompt:

```bash
local-jarvis
```

Move the mouse onto the display Jarvis should control before starting a command. Moving the pointer to the upper-left corner triggers PyAutoGUI's emergency stop.

Jarvis continues until the model completes the task or you click **Stop Jarvis**. To restore an automatic cap, set `JARVIS_MAXIMUM_STEPS` to a positive integer before launching the client. `0`, `none`, and `unlimited` all select unlimited mode.

## Wayland

Wayland deliberately prevents ordinary applications from globally capturing input and injecting mouse or keyboard events. Local Jarvis fails with an actionable message when no X11/XWayland `DISPLAY` is available. For reliable control today, choose an Xorg session from the login screen. A future Wayland backend will need separate implementations for compositor portals, `ydotool`, or desktop-environment accessibility APIs.
