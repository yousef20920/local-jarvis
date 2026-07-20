from __future__ import annotations

import base64
from dataclasses import dataclass
from itertools import count
import json
from typing import Callable

from .desktop import ActionResult, DesktopBackend, ScreenCapture


MODEL_COORDINATE_GRID_SIZE = 768.0

AGENT_SYSTEM_PROMPT = """
You are Jarvis, a computer-use agent controlling a Linux computer with a mouse and keyboard.
Each turn you receive the user's goal, recent action history, and a screenshot of the CURRENT screen.
The screenshot is exactly 768x768 pixels. All coordinates you output are pixel coordinates in this image, with the origin at the top-left corner; x increases rightward and y increases downward.

Respond with EXACTLY ONE JSON object describing the single next action. No markdown, no extra text.

Supported actions:
{"reasoning":"...","action":"left_click","coordinate":[x,y],"label":"short element name"}
{"reasoning":"...","action":"double_click","coordinate":[x,y],"label":"short element name"}
{"reasoning":"...","action":"right_click","coordinate":[x,y],"label":"short element name"}
{"reasoning":"...","action":"move_mouse","coordinate":[x,y],"label":"short element name"}
{"reasoning":"...","action":"left_click_drag","start_coordinate":[x,y],"coordinate":[x,y],"label":"what is being dragged"}
{"reasoning":"...","action":"scroll","coordinate":[x,y],"scroll_direction":"up|down|left|right","scroll_amount":5}
{"reasoning":"...","action":"type","text":"text to type into the focused field"}
{"reasoning":"...","action":"key","keys":["ctrl","t"]}
{"reasoning":"...","action":"open_app","app_name":"Firefox"}
{"reasoning":"...","action":"wait","seconds":2}
{"reasoning":"...","action":"answer","text":"answer to the user's question"}
{"reasoning":"...","action":"terminate","status":"success|failure","message":"short summary"}

Rules:
- Return ONE action per turn. A fresh screenshot follows each executed action.
- Verify that the previous action worked. If a click did not change the screen, never click the same coordinate again.
- Click the center of the target. Focus a field before typing.
- Prefer keyboard navigation when it is reliable.
- Linux uses Ctrl where macOS uses Command. Use ["ctrl","l"] for a browser address bar, ["ctrl","a"] for select all, and ["enter"] to submit.
- Open apps with open_app instead of clicking a dock.
- Use wait after an action that triggers loading.
- Use answer for a question that can be answered from the screen.
- Terminate with success as soon as the goal is complete.
- A small Local Jarvis stop control may be visible. Ignore it and never click or type into it.
- Do not delete files, send messages, submit forms, make purchases, change security settings, expose private information, or run terminal commands. Terminate with failure if the goal requires one of those actions.
""".strip()


@dataclass(frozen=True)
class AgentOutcome:
    succeeded: bool
    message: str


@dataclass(frozen=True)
class ModelAction:
    action_name: str
    coordinate: tuple[float, float] | None = None
    start_coordinate: tuple[float, float] | None = None
    text: str | None = None
    keys: list[str] | None = None
    app_name: str | None = None
    scroll_direction: str | None = None
    scroll_amount: float | None = None
    wait_seconds: float | None = None
    terminate_status: str | None = None
    message: str | None = None
    label: str | None = None


class JarvisComputerUseAgent:
    _maximum_action_history_line_count = 5
    _pointer_action_names = {
        "left_click",
        "double_click",
        "right_click",
        "move_mouse",
        "left_click_drag",
    }

    def __init__(
        self,
        openai_client,
        desktop_backend: DesktopBackend,
        maximum_step_count: int | None = None,
        progress_callback: Callable[[str], None] | None = None,
        cancellation_callback: Callable[[], bool] | None = None,
    ) -> None:
        self.openai_client = openai_client
        self.desktop_backend = desktop_backend
        self.maximum_step_count = maximum_step_count
        self.progress_callback = progress_callback or (lambda _message: None)
        self.cancellation_callback = cancellation_callback or (lambda: False)

    def run(self, user_goal: str) -> AgentOutcome:
        action_history_lines: list[str] = []
        previous_pointer_action_signature: str | None = None
        repeated_pointer_action_count = 0

        step_numbers = (
            count(start=1)
            if self.maximum_step_count is None
            else range(1, self.maximum_step_count + 1)
        )

        for step_number in step_numbers:
            if self.cancellation_callback():
                return AgentOutcome(False, "Stopped by the user.")

            self.progress_callback(f"Step {step_number}: observing the screen")
            try:
                screen_capture = self.desktop_backend.capture_cursor_display()
            except Exception as error:
                return AgentOutcome(False, f"I could not capture the screen: {error}")

            user_prompt = self._agent_turn_prompt(user_goal, action_history_lines, step_number)
            try:
                response_text = self.openai_client.generate_computer_use_turn(
                    system_prompt=AGENT_SYSTEM_PROMPT,
                    user_prompt=user_prompt,
                    screenshot_base64=base64.b64encode(screen_capture.jpeg_data).decode("ascii"),
                )
            except Exception as error:
                return AgentOutcome(False, f"GPT-5.5 is unavailable: {error}")

            # A synchronous Worker request cannot be interrupted safely, so a
            # stop requested during the call takes effect before any returned
            # action is allowed to touch the desktop.
            if self.cancellation_callback():
                return AgentOutcome(False, "Stopped by the user.")

            model_action = parse_model_action(response_text)
            if model_action is None:
                action_history_lines.append(
                    f"Step {step_number}: response was not valid action JSON. Return exactly one action."
                )
                continue

            if model_action.action_name == "answer":
                return AgentOutcome(True, model_action.text or model_action.message or "Done.")
            if model_action.action_name == "terminate":
                succeeded = model_action.terminate_status != "failure"
                default_message = "Done." if succeeded else "I could not finish that."
                return AgentOutcome(succeeded, model_action.message or default_message)
            if model_action.action_name == "screenshot":
                action_history_lines.append(f"Step {step_number}: captured a fresh screenshot.")
                continue

            pointer_action_signature = self._pointer_action_signature(model_action)
            if pointer_action_signature and pointer_action_signature == previous_pointer_action_signature:
                repeated_pointer_action_count += 1
                if repeated_pointer_action_count >= 2:
                    return AgentOutcome(
                        False,
                        "I kept choosing the same spot without making progress, so I stopped.",
                    )
                action_history_lines.append(
                    f"Step {step_number}: rejected the repeated pointer coordinate. Choose a different route."
                )
                continue

            previous_pointer_action_signature = pointer_action_signature
            repeated_pointer_action_count = 0
            try:
                action_summary, action_result = self._execute_action(model_action, screen_capture)
            except Exception as error:
                return AgentOutcome(False, f"The Linux desktop action failed: {error}")
            self.progress_callback(f"Step {step_number}: {action_summary}")
            action_history_lines.append(
                f"Step {step_number}: {action_summary} -> {action_result.message} "
                f"({'executed' if action_result.succeeded else 'FAILED'})"
            )

        return AgentOutcome(
            False,
            f"I reached the configured {self.maximum_step_count}-step limit before finishing.",
        )

    def _execute_action(
        self,
        model_action: ModelAction,
        screen_capture: ScreenCapture,
    ) -> tuple[str, ActionResult]:
        action_name = model_action.action_name
        label = model_action.label or "the target"

        if action_name in {"left_click", "double_click", "right_click", "move_mouse"}:
            if model_action.coordinate is None:
                return action_name, ActionResult(False, "The action did not include coordinates.")
            target_x, target_y = map_grid_coordinate(model_action.coordinate, screen_capture)
            if action_name == "left_click":
                return f"Click {label}", self.desktop_backend.click(target_x, target_y)
            if action_name == "double_click":
                return f"Double-click {label}", self.desktop_backend.click(
                    target_x,
                    target_y,
                    clicks=2,
                )
            if action_name == "right_click":
                return f"Right-click {label}", self.desktop_backend.click(
                    target_x,
                    target_y,
                    button="right",
                )
            return f"Move mouse to {label}", self.desktop_backend.move_mouse(target_x, target_y)

        if action_name == "left_click_drag":
            if model_action.start_coordinate is None or model_action.coordinate is None:
                return "Drag", ActionResult(False, "The drag did not include start and end coordinates.")
            start_x, start_y = map_grid_coordinate(model_action.start_coordinate, screen_capture)
            end_x, end_y = map_grid_coordinate(model_action.coordinate, screen_capture)
            return f"Drag {label}", self.desktop_backend.drag(start_x, start_y, end_x, end_y)

        if action_name == "scroll":
            direction = (model_action.scroll_direction or "").lower()
            if direction not in {"up", "down", "left", "right"}:
                return "Scroll", ActionResult(False, "The action did not include a valid scroll direction.")
            target_x: float | None = None
            target_y: float | None = None
            if model_action.coordinate is not None:
                target_x, target_y = map_grid_coordinate(model_action.coordinate, screen_capture)
            return f"Scroll {direction}", self.desktop_backend.scroll(
                direction,
                model_action.scroll_amount or 5,
                target_x,
                target_y,
            )

        if action_name == "type":
            if model_action.text is None:
                return "Type text", ActionResult(False, "The action did not include text.")
            return "Type text", self.desktop_backend.type_text(model_action.text)

        if action_name == "key":
            if not model_action.keys:
                return "Press hotkey", ActionResult(False, "The action did not include any keys.")
            return f"Press {' + '.join(model_action.keys)}", self.desktop_backend.press_hotkey(
                model_action.keys
            )

        if action_name == "open_app":
            if not model_action.app_name:
                return "Open app", ActionResult(False, "The action did not include an app name.")
            return f"Open {model_action.app_name}", self.desktop_backend.open_app(model_action.app_name)

        if action_name == "wait":
            return "Wait for the screen to settle", self.desktop_backend.wait(
                model_action.wait_seconds or 2
            )

        return action_name, ActionResult(False, f"Unsupported action: {action_name}.")

    def _agent_turn_prompt(
        self,
        user_goal: str,
        action_history_lines: list[str],
        step_number: int,
    ) -> str:
        recent_history = action_history_lines[-self._maximum_action_history_line_count :]
        history_section = "\n".join(recent_history) or "No actions taken yet. This is the first step."
        step_limit_description = (
            "with no automatic step limit"
            if self.maximum_step_count is None
            else f"of at most {self.maximum_step_count}"
        )
        return (
            f"User goal:\n{user_goal}\n\n"
            f"Actions taken so far:\n{history_section}\n\n"
            f"This is step {step_number} {step_limit_description}. "
            "The attached screenshot shows the current screen. Respond with one JSON action."
        )

    @classmethod
    def _pointer_action_signature(cls, model_action: ModelAction) -> str | None:
        if model_action.action_name not in cls._pointer_action_names or model_action.coordinate is None:
            return None
        coordinate_bucket_size = 20.0
        bucketed_x = round(model_action.coordinate[0] / coordinate_bucket_size)
        bucketed_y = round(model_action.coordinate[1] / coordinate_bucket_size)
        return f"{model_action.action_name}@{bucketed_x},{bucketed_y}"


def parse_model_action(response_text: str) -> ModelAction | None:
    try:
        response_json = json.loads(response_text)
    except json.JSONDecodeError:
        return None
    if not isinstance(response_json, dict):
        return None

    if isinstance(response_json.get("arguments"), dict):
        wrapped_arguments = response_json["arguments"]
        if "reasoning" not in wrapped_arguments and "reasoning" in response_json:
            wrapped_arguments["reasoning"] = response_json["reasoning"]
        response_json = wrapped_arguments

    raw_action_name = response_json.get("action")
    if not isinstance(raw_action_name, str):
        return None

    return ModelAction(
        action_name=normalize_action_name(raw_action_name),
        coordinate=_parse_coordinate(response_json.get("coordinate")),
        start_coordinate=_parse_coordinate(response_json.get("start_coordinate")),
        text=_optional_string(response_json.get("text")),
        keys=_parse_keys(response_json.get("keys")),
        app_name=_optional_string(_first_present(response_json, "app_name", "app")),
        scroll_direction=_optional_string(
            _first_present(response_json, "scroll_direction", "direction")
        ),
        scroll_amount=_optional_number(_first_present(response_json, "scroll_amount", "amount")),
        wait_seconds=_optional_number(_first_present(response_json, "seconds", "time")),
        terminate_status=_optional_string(response_json.get("status")),
        message=_optional_string(response_json.get("message")),
        label=_optional_string(response_json.get("label")),
    )


def normalize_action_name(raw_action_name: str) -> str:
    normalized_action_name = raw_action_name.strip().lower()
    action_aliases = {
        "click": "left_click",
        "tap": "left_click",
        "double-click": "double_click",
        "doubleclick": "double_click",
        "right-click": "right_click",
        "rightclick": "right_click",
        "context_click": "right_click",
        "drag": "left_click_drag",
        "click_drag": "left_click_drag",
        "mouse_move": "move_mouse",
        "hover": "move_mouse",
        "move_to": "move_mouse",
        "swipe": "scroll",
        "type_text": "type",
        "input_text": "type",
        "input": "type",
        "hotkey": "key",
        "press_key": "key",
        "keypress": "key",
        "press": "key",
        "launch_app": "open_app",
        "open": "open_app",
        "sleep": "wait",
        "pause": "wait",
        "respond": "answer",
        "reply": "answer",
        "finish": "terminate",
        "finished": "terminate",
        "done": "terminate",
        "complete": "terminate",
        "stop": "terminate",
        "fail": "terminate",
        "take_screenshot": "screenshot",
    }
    return action_aliases.get(normalized_action_name, normalized_action_name)


def map_grid_coordinate(
    grid_coordinate: tuple[float, float],
    screen_capture: ScreenCapture,
) -> tuple[float, float]:
    clamped_grid_x = min(max(grid_coordinate[0], 0), MODEL_COORDINATE_GRID_SIZE)
    clamped_grid_y = min(max(grid_coordinate[1], 0), MODEL_COORDINATE_GRID_SIZE)
    global_x = screen_capture.origin_x + clamped_grid_x / MODEL_COORDINATE_GRID_SIZE * screen_capture.width
    global_y = screen_capture.origin_y + clamped_grid_y / MODEL_COORDINATE_GRID_SIZE * screen_capture.height
    return global_x, global_y


def _parse_coordinate(raw_value: object) -> tuple[float, float] | None:
    if isinstance(raw_value, list) and len(raw_value) >= 2:
        x_value = _optional_number(raw_value[0])
        y_value = _optional_number(raw_value[1])
        if x_value is not None and y_value is not None:
            return x_value, y_value
    if isinstance(raw_value, dict):
        x_value = _optional_number(raw_value.get("x"))
        y_value = _optional_number(raw_value.get("y"))
        if x_value is not None and y_value is not None:
            return x_value, y_value
    return None


def _parse_keys(raw_value: object) -> list[str] | None:
    if isinstance(raw_value, list):
        key_names = [key_name for key_name in raw_value if isinstance(key_name, str)]
        return key_names or None
    if isinstance(raw_value, str):
        key_names = raw_value.replace("+", " ").split()
        return key_names or None
    return None


def _optional_string(raw_value: object) -> str | None:
    return raw_value if isinstance(raw_value, str) else None


def _optional_number(raw_value: object) -> float | None:
    if isinstance(raw_value, bool):
        return None
    if isinstance(raw_value, (int, float)):
        return float(raw_value)
    if isinstance(raw_value, str):
        try:
            return float(raw_value)
        except ValueError:
            return None
    return None


def _first_present(response_json: dict, primary_key: str, alternate_key: str) -> object:
    primary_value = response_json.get(primary_key)
    return primary_value if primary_value is not None else response_json.get(alternate_key)
