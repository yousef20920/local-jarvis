from __future__ import annotations

import argparse
import os
import sys
import threading
from typing import Callable

from .agent import JarvisComputerUseAgent
from .config import JarvisLinuxConfiguration
from .desktop import LinuxDesktopError, PyAutoGUILinuxDesktop
from .openai_client import JarvisOpenAIClient


def build_command_runner(
    configuration: JarvisLinuxConfiguration,
    progress_callback: Callable[[str], None],
) -> tuple[Callable[[str], str], Callable[[], None]]:
    cancellation_event = threading.Event()
    desktop_backend = PyAutoGUILinuxDesktop()
    openai_client = JarvisOpenAIClient(
        responses_proxy_url=configuration.responses_proxy_url,
        request_timeout_seconds=configuration.request_timeout_seconds,
    )
    agent = JarvisComputerUseAgent(
        openai_client=openai_client,
        desktop_backend=desktop_backend,
        maximum_step_count=configuration.maximum_step_count,
        progress_callback=progress_callback,
        cancellation_callback=cancellation_event.is_set,
    )

    def run_command(user_command: str) -> str:
        cancellation_event.clear()
        trimmed_user_command = user_command.strip()
        if not trimmed_user_command:
            return "Jarvis needs a command before it can act."
        return agent.run(trimmed_user_command).message

    return run_command, cancellation_event.set


def print_environment_check(configuration: JarvisLinuxConfiguration) -> int:
    session_type = os.environ.get("XDG_SESSION_TYPE", "unknown")
    display = os.environ.get("DISPLAY", "not set")
    print(f"Session type: {session_type}")
    print(f"DISPLAY: {display}")
    print(f"Worker: {configuration.responses_proxy_url}")

    try:
        desktop_backend = PyAutoGUILinuxDesktop()
        screen_capture = desktop_backend.capture_cursor_display()
    except Exception as error:
        print(f"Desktop control: unavailable ({error})")
        return 1

    print(
        "Desktop control: ready "
        f"({screen_capture.width}x{screen_capture.height} display at "
        f"{screen_capture.origin_x},{screen_capture.origin_y})"
    )
    return 0


def _terminal_progress_callback(progress_message: str) -> None:
    print(progress_message, file=sys.stderr)


def main() -> int:
    argument_parser = argparse.ArgumentParser(
        prog="local-jarvis",
        description="Run Local Jarvis on a Linux desktop.",
    )
    argument_parser.add_argument(
        "command",
        nargs="*",
        help="A command for Jarvis. Omit it to start an interactive prompt.",
    )
    argument_parser.add_argument(
        "--gui",
        action="store_true",
        help="Open the Local Jarvis desktop window.",
    )
    argument_parser.add_argument(
        "--check",
        action="store_true",
        help="Check Linux display capture and control prerequisites.",
    )
    arguments = argument_parser.parse_args()

    try:
        configuration = JarvisLinuxConfiguration.from_environment()
        if arguments.check:
            return print_environment_check(configuration)

        if arguments.gui:
            from .gui import run_gui

            run_gui(
                lambda progress_callback: build_command_runner(
                    configuration,
                    progress_callback,
                )
            )
            return 0

        command_runner, _stop_command = build_command_runner(
            configuration,
            _terminal_progress_callback,
        )
    except (LinuxDesktopError, RuntimeError, ValueError) as error:
        print(f"Local Jarvis could not start: {error}", file=sys.stderr)
        return 1

    if arguments.command:
        print(command_runner(" ".join(arguments.command)))
        return 0

    if not sys.stdin.isatty():
        print("Provide a command or use --gui.", file=sys.stderr)
        return 2

    print("Local Jarvis for Linux. Type 'quit' to stop.")
    while True:
        try:
            user_command = input("jarvis> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return 0
        if user_command.lower() in {"quit", "exit"}:
            return 0
        if user_command:
            print(command_runner(user_command))


if __name__ == "__main__":
    raise SystemExit(main())
