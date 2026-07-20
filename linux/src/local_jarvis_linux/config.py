from __future__ import annotations

from dataclasses import dataclass
import os


@dataclass(frozen=True)
class JarvisLinuxConfiguration:
    responses_proxy_url: str
    maximum_step_count: int | None = None
    request_timeout_seconds: float = 120.0

    @classmethod
    def from_environment(cls) -> "JarvisLinuxConfiguration":
        responses_proxy_url = os.environ.get(
            "JARVIS_RESPONSES_URL",
            "http://127.0.0.1:8787/responses",
        )
        maximum_step_count_text = os.environ.get("JARVIS_MAXIMUM_STEPS", "unlimited").strip()

        if maximum_step_count_text.lower() in {"", "0", "none", "unlimited"}:
            maximum_step_count = None
        else:
            try:
                maximum_step_count = int(maximum_step_count_text)
            except ValueError as error:
                raise ValueError(
                    "JARVIS_MAXIMUM_STEPS must be a positive integer or 'unlimited'."
                ) from error

            if maximum_step_count < 1:
                raise ValueError(
                    "JARVIS_MAXIMUM_STEPS must be a positive integer or 'unlimited'."
                )

        return cls(
            responses_proxy_url=responses_proxy_url,
            maximum_step_count=maximum_step_count,
        )
