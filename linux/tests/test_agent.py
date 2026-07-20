from __future__ import annotations

import json
import unittest

from local_jarvis_linux.agent import (
    JarvisComputerUseAgent,
    map_grid_coordinate,
    parse_model_action,
)
from local_jarvis_linux.desktop import ActionResult, ScreenCapture


class FakeOpenAIClient:
    def __init__(self, responses: list[dict]):
        self.responses = responses

    def generate_computer_use_turn(self, **_arguments) -> str:
        return json.dumps(self.responses.pop(0))


class FakeDesktopBackend:
    def __init__(self):
        self.actions: list[tuple] = []
        self.screen_capture = ScreenCapture(b"jpeg", 100, 200, 1536, 768)

    def capture_cursor_display(self) -> ScreenCapture:
        return self.screen_capture

    def click(self, x, y, button="left", clicks=1):
        self.actions.append(("click", x, y, button, clicks))
        return ActionResult(True, "Clicked the target.")

    def move_mouse(self, x, y):
        self.actions.append(("move_mouse", x, y))
        return ActionResult(True, "Moved the mouse.")

    def drag(self, start_x, start_y, end_x, end_y):
        self.actions.append(("drag", start_x, start_y, end_x, end_y))
        return ActionResult(True, "Dragged the target.")

    def scroll(self, direction, amount, x, y):
        self.actions.append(("scroll", direction, amount, x, y))
        return ActionResult(True, f"Scrolled {direction}.")

    def type_text(self, text):
        self.actions.append(("type", text))
        return ActionResult(True, "Typed text.")

    def press_hotkey(self, keys):
        self.actions.append(("key", keys))
        return ActionResult(True, "Pressed keys.")

    def open_app(self, app_name):
        self.actions.append(("open_app", app_name))
        return ActionResult(True, f"Opened {app_name}.")

    def wait(self, seconds):
        self.actions.append(("wait", seconds))
        return ActionResult(True, "Waited.")


class ModelActionParsingTests(unittest.TestCase):
    def test_parses_aliases_and_string_hotkeys(self):
        action = parse_model_action('{"action":"hotkey","keys":"ctrl+l"}')

        self.assertIsNotNone(action)
        self.assertEqual(action.action_name, "key")
        self.assertEqual(action.keys, ["ctrl", "l"])

    def test_preserves_zero_numeric_values(self):
        action = parse_model_action(
            '{"action":"scroll","scroll_direction":"down","scroll_amount":0}'
        )

        self.assertIsNotNone(action)
        self.assertEqual(action.scroll_amount, 0)

    def test_rejects_non_json_response(self):
        self.assertIsNone(parse_model_action("```json\n{}\n```"))

    def test_maps_model_grid_to_offset_monitor(self):
        screen_capture = ScreenCapture(b"jpeg", -1920, 50, 1920, 1080)

        global_coordinate = map_grid_coordinate((384, 384), screen_capture)

        self.assertEqual(global_coordinate, (-960, 590))


class ComputerUseAgentTests(unittest.TestCase):
    def test_executes_click_then_terminates(self):
        desktop_backend = FakeDesktopBackend()
        openai_client = FakeOpenAIClient(
            [
                {"action": "left_click", "coordinate": [384, 384], "label": "button"},
                {"action": "terminate", "status": "success", "message": "Finished."},
            ]
        )
        agent = JarvisComputerUseAgent(openai_client, desktop_backend)

        outcome = agent.run("Click the button")

        self.assertTrue(outcome.succeeded)
        self.assertEqual(outcome.message, "Finished.")
        self.assertEqual(desktop_backend.actions, [("click", 868, 584, "left", 1)])

    def test_stops_after_repeated_pointer_coordinates(self):
        desktop_backend = FakeDesktopBackend()
        repeated_click = {"action": "left_click", "coordinate": [100, 100]}
        openai_client = FakeOpenAIClient([repeated_click, repeated_click, repeated_click])
        agent = JarvisComputerUseAgent(openai_client, desktop_backend)

        outcome = agent.run("Click something")

        self.assertFalse(outcome.succeeded)
        self.assertIn("same spot", outcome.message)
        self.assertEqual(len(desktop_backend.actions), 1)

    def test_unlimited_run_can_continue_past_previous_fifteen_step_limit(self):
        desktop_backend = FakeDesktopBackend()
        openai_client = FakeOpenAIClient(
            [{"action": "wait", "seconds": 0.1} for _step_number in range(20)]
            + [
                {
                    "action": "terminate",
                    "status": "success",
                    "message": "Finished after twenty actions.",
                }
            ]
        )
        agent = JarvisComputerUseAgent(openai_client, desktop_backend)

        outcome = agent.run("Complete a long workflow")

        self.assertTrue(outcome.succeeded)
        self.assertEqual(outcome.message, "Finished after twenty actions.")
        self.assertEqual(len(desktop_backend.actions), 20)

    def test_cancellation_stops_before_another_model_action(self):
        desktop_backend = FakeDesktopBackend()
        openai_client = FakeOpenAIClient(
            [
                {"action": "wait", "seconds": 0.1},
                {"action": "wait", "seconds": 0.1},
            ]
        )
        agent = JarvisComputerUseAgent(
            openai_client,
            desktop_backend,
            cancellation_callback=lambda: len(desktop_backend.actions) >= 1,
        )

        outcome = agent.run("Keep working")

        self.assertFalse(outcome.succeeded)
        self.assertEqual(outcome.message, "Stopped by the user.")
        self.assertEqual(len(desktop_backend.actions), 1)


if __name__ == "__main__":
    unittest.main()
