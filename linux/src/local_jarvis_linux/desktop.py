from __future__ import annotations

from dataclasses import dataclass
from io import BytesIO
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
from typing import Protocol


@dataclass(frozen=True)
class ScreenCapture:
    jpeg_data: bytes
    origin_x: int
    origin_y: int
    width: int
    height: int


@dataclass(frozen=True)
class ActionResult:
    succeeded: bool
    message: str


class DesktopBackend(Protocol):
    def capture_cursor_display(self) -> ScreenCapture: ...
    def click(self, x: float, y: float, button: str = "left", clicks: int = 1) -> ActionResult: ...
    def move_mouse(self, x: float, y: float) -> ActionResult: ...
    def drag(self, start_x: float, start_y: float, end_x: float, end_y: float) -> ActionResult: ...
    def scroll(self, direction: str, amount: float, x: float | None, y: float | None) -> ActionResult: ...
    def type_text(self, text: str) -> ActionResult: ...
    def press_hotkey(self, keys: list[str]) -> ActionResult: ...
    def open_app(self, app_name: str) -> ActionResult: ...
    def wait(self, seconds: float) -> ActionResult: ...


class LinuxDesktopError(RuntimeError):
    pass


class PyAutoGUILinuxDesktop:
    _application_commands = {
        "chrome": ["google-chrome"],
        "google chrome": ["google-chrome"],
        "chromium": ["chromium"],
        "firefox": ["firefox"],
        "files": ["xdg-open", "."],
        "file manager": ["xdg-open", "."],
        "terminal": ["x-terminal-emulator"],
        "settings": ["gnome-control-center"],
        "text editor": ["gedit"],
        "visual studio code": ["code"],
        "vs code": ["code"],
        "vscode": ["code"],
    }

    def __init__(self) -> None:
        display_server = os.environ.get("XDG_SESSION_TYPE", "").lower()
        if display_server == "wayland" and not os.environ.get("DISPLAY"):
            raise LinuxDesktopError(
                "This session is native Wayland. Local Jarvis currently needs an X11 session "
                "or an XWayland DISPLAY for screen control. Log in with an Xorg session and try again."
            )
        if not os.environ.get("DISPLAY"):
            raise LinuxDesktopError(
                "DISPLAY is not set. Local Jarvis must run inside a graphical Linux desktop session."
            )

        # Authentication-free Xvfb sessions, including Replicas desktops, do
        # not create ~/.Xauthority. Python Xlib still tries to read that file
        # unless XAUTHORITY names an existing file, even when the X server does
        # not require a cookie.
        default_xauthority_path = Path.home() / ".Xauthority"
        if not os.environ.get("XAUTHORITY") and not default_xauthority_path.exists():
            os.environ["XAUTHORITY"] = os.devnull

        try:
            import mss
            import pyautogui
            from PIL import Image
        except ImportError as error:
            raise LinuxDesktopError(
                "Linux desktop dependencies are missing. Run: python3 -m pip install -e ./linux"
            ) from error

        pyautogui.PAUSE = 0.08
        pyautogui.FAILSAFE = True
        self._mss_module = mss
        self._pyautogui = pyautogui
        self._image_class = Image

    def capture_cursor_display(self) -> ScreenCapture:
        cursor_position = self._pyautogui.position()
        with self._mss_module.mss() as screenshot_capture:
            physical_monitors = screenshot_capture.monitors[1:]
            if not physical_monitors:
                raise LinuxDesktopError("No displays are available for screen capture.")

            cursor_monitor = next(
                (
                    monitor
                    for monitor in physical_monitors
                    if monitor["left"] <= cursor_position.x < monitor["left"] + monitor["width"]
                    and monitor["top"] <= cursor_position.y < monitor["top"] + monitor["height"]
                ),
                physical_monitors[0],
            )
            raw_screenshot = screenshot_capture.grab(cursor_monitor)

        screenshot_image = self._image_class.frombytes(
            "RGB",
            raw_screenshot.size,
            raw_screenshot.bgra,
            "raw",
            "BGRX",
        )
        model_image = screenshot_image.resize((768, 768), self._image_class.Resampling.LANCZOS)
        jpeg_buffer = BytesIO()
        model_image.save(jpeg_buffer, format="JPEG", quality=60, optimize=True)
        return ScreenCapture(
            jpeg_data=jpeg_buffer.getvalue(),
            origin_x=cursor_monitor["left"],
            origin_y=cursor_monitor["top"],
            width=cursor_monitor["width"],
            height=cursor_monitor["height"],
        )

    def click(self, x: float, y: float, button: str = "left", clicks: int = 1) -> ActionResult:
        self._pyautogui.click(x=x, y=y, button=button, clicks=clicks, interval=0.09)
        click_description = "Double-clicked" if clicks == 2 else f"{button.title()}-clicked"
        return ActionResult(True, f"{click_description} the target.")

    def move_mouse(self, x: float, y: float) -> ActionResult:
        self._pyautogui.moveTo(x=x, y=y, duration=0.2)
        return ActionResult(True, "Moved the mouse to the target.")

    def drag(self, start_x: float, start_y: float, end_x: float, end_y: float) -> ActionResult:
        self._pyautogui.moveTo(x=start_x, y=start_y, duration=0.15)
        self._pyautogui.dragTo(x=end_x, y=end_y, duration=0.4, button="left")
        return ActionResult(True, "Dragged the target.")

    def scroll(
        self,
        direction: str,
        amount: float,
        x: float | None,
        y: float | None,
    ) -> ActionResult:
        if x is not None and y is not None:
            self._pyautogui.moveTo(x=x, y=y, duration=0.12)
        clamped_amount = max(1, min(int(round(amount)), 40))
        if direction in {"up", "down"}:
            signed_amount = clamped_amount if direction == "up" else -clamped_amount
            self._pyautogui.scroll(signed_amount)
        else:
            signed_amount = clamped_amount if direction == "left" else -clamped_amount
            self._pyautogui.hscroll(signed_amount)
        return ActionResult(True, f"Scrolled {direction}.")

    def type_text(self, text: str) -> ActionResult:
        try:
            import pyperclip

            previous_clipboard_text = pyperclip.paste()
            pyperclip.copy(text)
            self._pyautogui.hotkey("ctrl", "v")
            time.sleep(0.15)
            pyperclip.copy(previous_clipboard_text)
        except Exception:
            if not text.isascii():
                return ActionResult(
                    False,
                    "Could not access the Linux clipboard, which is required for non-ASCII text.",
                )
            self._pyautogui.write(text, interval=0.01)
        return ActionResult(True, "Typed text.")

    def press_hotkey(self, keys: list[str]) -> ActionResult:
        normalized_keys = [self._normalize_key_name(key_name) for key_name in keys]
        self._pyautogui.hotkey(*normalized_keys)
        return ActionResult(True, f"Pressed {' + '.join(normalized_keys)}.")

    def open_app(self, app_name: str) -> ActionResult:
        normalized_app_name = app_name.strip().lower()
        configured_command = self._application_commands.get(normalized_app_name)
        command = list(configured_command) if configured_command is not None else None
        if command is None:
            candidate_command = re.sub(r"[^a-zA-Z0-9._+-]", "-", normalized_app_name)
            if candidate_command and shutil.which(candidate_command):
                command = [candidate_command]
            elif shutil.which("gtk-launch"):
                command = ["gtk-launch", candidate_command]
            else:
                return ActionResult(False, f"Could not find an installed app named {app_name}.")

        if not shutil.which(command[0]):
            fallback_commands = {
                "google-chrome": "chromium",
                "x-terminal-emulator": "gnome-terminal",
                "gnome-control-center": "systemsettings",
                "gedit": "kate",
            }
            fallback_command = fallback_commands.get(command[0])
            if fallback_command and shutil.which(fallback_command):
                command[0] = fallback_command
            else:
                return ActionResult(False, f"Could not find an installed app named {app_name}.")

        subprocess.Popen(
            command,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        time.sleep(0.4)
        return ActionResult(True, f"Opened {app_name}.")

    def wait(self, seconds: float) -> ActionResult:
        clamped_seconds = max(0.1, min(seconds, 10.0))
        time.sleep(clamped_seconds)
        return ActionResult(True, f"Waited {clamped_seconds:g} seconds.")

    @staticmethod
    def _normalize_key_name(key_name: str) -> str:
        normalized_key_name = key_name.strip().lower()
        aliases = {
            "command": "ctrl",
            "cmd": "ctrl",
            "control": "ctrl",
            "option": "alt",
            "return": "enter",
            "escape": "esc",
            "page up": "pageup",
            "page down": "pagedown",
            "arrow up": "up",
            "arrow down": "down",
            "arrow left": "left",
            "arrow right": "right",
        }
        return aliases.get(normalized_key_name, normalized_key_name)
