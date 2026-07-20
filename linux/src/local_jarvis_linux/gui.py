from __future__ import annotations

import queue
import threading
from typing import Callable


def run_gui(
    command_runner_factory: Callable[
        [Callable[[str], None]],
        tuple[Callable[[str], str], Callable[[], None]],
    ]
) -> None:
    try:
        import tkinter as tk
        from tkinter import ttk
    except ImportError as error:
        raise RuntimeError(
            "Tkinter is required for the Linux window. Install python3-tk, or use local-jarvis without --gui."
        ) from error

    root_window = tk.Tk()
    root_window.title("Local Jarvis")
    root_window.geometry("520x330")
    root_window.minsize(420, 280)

    style = ttk.Style(root_window)
    if "clam" in style.theme_names():
        style.theme_use("clam")

    main_frame = ttk.Frame(root_window, padding=20)
    main_frame.pack(fill="both", expand=True)
    main_frame.columnconfigure(0, weight=1)
    main_frame.rowconfigure(3, weight=1)

    title_label = ttk.Label(main_frame, text="Local Jarvis", font=("Sans", 18, "bold"))
    title_label.grid(row=0, column=0, sticky="w")
    instruction_label = ttk.Label(
        main_frame,
        text="Tell Jarvis what to do on the display under your mouse pointer.",
    )
    instruction_label.grid(row=1, column=0, sticky="w", pady=(4, 14))

    command_entry = ttk.Entry(main_frame, font=("Sans", 12))
    command_entry.grid(row=2, column=0, sticky="ew")

    output_text = tk.Text(main_frame, height=8, wrap="word", state="disabled")
    output_text.grid(row=3, column=0, sticky="nsew", pady=(14, 12))

    status_variable = tk.StringVar(value="Ready")
    status_label = ttk.Label(main_frame, textvariable=status_variable)
    status_label.grid(row=4, column=0, sticky="w")

    event_queue: queue.Queue[tuple[str, str]] = queue.Queue()

    def report_progress(progress_message: str) -> None:
        event_queue.put(("progress", progress_message))

    command_runner, stop_command = command_runner_factory(report_progress)

    stop_window = tk.Toplevel(root_window)
    stop_window.title("Jarvis is working")
    stop_window.resizable(False, False)
    stop_window.attributes("-topmost", True)
    stop_window.withdraw()

    stop_frame = ttk.Frame(stop_window, padding=14)
    stop_frame.pack(fill="both", expand=True)
    stop_status_variable = tk.StringVar(value="Jarvis is working…")
    stop_status_label = ttk.Label(stop_frame, textvariable=stop_status_variable)
    stop_status_label.pack(anchor="w")

    def request_stop() -> None:
        stop_command()
        stop_status_variable.set("Stopping after the current model response…")
        stop_button.configure(state="disabled")

    stop_button = ttk.Button(
        stop_frame,
        text="Stop Jarvis",
        command=request_stop,
        cursor="hand2",
    )
    stop_button.pack(anchor="e", pady=(10, 0))
    stop_window.protocol("WM_DELETE_WINDOW", request_stop)

    def replace_output(message: str) -> None:
        output_text.configure(state="normal")
        output_text.delete("1.0", "end")
        output_text.insert("1.0", message)
        output_text.configure(state="disabled")

    def run_command_in_background(user_command: str) -> None:
        try:
            result_message = command_runner(user_command)
            event_queue.put(("result", result_message))
        except Exception as error:
            event_queue.put(("error", str(error)))

    def submit_command(_event=None) -> None:
        user_command = command_entry.get().strip()
        if not user_command:
            return
        command_entry.configure(state="disabled")
        submit_button.configure(state="disabled")
        status_variable.set("Starting…")
        replace_output("")
        # Hiding Jarvis keeps its own window out of the screenshots used to
        # ground model actions and returns focus to the user's desktop.
        root_window.withdraw()
        stop_status_variable.set("Jarvis is working…")
        stop_button.configure(state="normal")
        stop_window.update_idletasks()
        stop_window_width = stop_window.winfo_reqwidth()
        stop_window.geometry(
            f"+{root_window.winfo_screenwidth() - stop_window_width - 24}+24"
        )
        stop_window.deiconify()
        stop_window.lift()

        def start_background_thread() -> None:
            threading.Thread(
                target=run_command_in_background,
                args=(user_command,),
                daemon=True,
            ).start()

        root_window.after(200, start_background_thread)

    submit_button = ttk.Button(main_frame, text="Run command", command=submit_command, cursor="hand2")
    submit_button.grid(row=5, column=0, sticky="e", pady=(12, 0))
    command_entry.bind("<Return>", submit_command)

    def process_events() -> None:
        try:
            while True:
                event_type, event_message = event_queue.get_nowait()
                if event_type == "progress":
                    status_variable.set(event_message)
                    stop_status_variable.set(event_message)
                else:
                    replace_output(event_message)
                    status_variable.set("Done" if event_type == "result" else "Failed")
                    stop_window.withdraw()
                    root_window.deiconify()
                    root_window.lift()
                    command_entry.configure(state="normal")
                    submit_button.configure(state="normal")
                    command_entry.focus_set()
        except queue.Empty:
            pass
        root_window.after(80, process_events)

    command_entry.focus_set()
    process_events()
    root_window.mainloop()
