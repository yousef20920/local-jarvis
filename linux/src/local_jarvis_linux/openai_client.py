from __future__ import annotations

import json
import urllib.error
import urllib.request


class JarvisOpenAIClientError(RuntimeError):
    pass


class JarvisOpenAIClient:
    def __init__(self, responses_proxy_url: str, request_timeout_seconds: float = 120.0):
        self.responses_proxy_url = responses_proxy_url
        self.request_timeout_seconds = request_timeout_seconds

    def generate_computer_use_turn(
        self,
        system_prompt: str,
        user_prompt: str,
        screenshot_base64: str,
    ) -> str:
        request_body = {
            "input": [
                {"role": "system", "content": system_prompt},
                {
                    "role": "user",
                    "content": [
                        {"type": "input_text", "text": user_prompt},
                        {
                            "type": "input_image",
                            "image_url": f"data:image/jpeg;base64,{screenshot_base64}",
                            "detail": "original",
                        },
                    ],
                },
            ],
            "reasoning": {"effort": "low"},
            "text": {
                "verbosity": "low",
                "format": {"type": "json_object"},
            },
        }
        encoded_request_body = json.dumps(request_body).encode("utf-8")
        request = urllib.request.Request(
            self.responses_proxy_url,
            data=encoded_request_body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )

        try:
            with urllib.request.urlopen(
                request,
                timeout=self.request_timeout_seconds,
            ) as response:
                response_body = response.read()
        except urllib.error.HTTPError as error:
            error_body = error.read().decode("utf-8", errors="replace")
            raise JarvisOpenAIClientError(
                f"The OpenAI Worker returned HTTP {error.code}: {error_body}"
            ) from error
        except urllib.error.URLError as error:
            raise JarvisOpenAIClientError(
                f"Could not reach the OpenAI Worker at {self.responses_proxy_url}: {error.reason}"
            ) from error

        try:
            response_json = json.loads(response_body)
        except json.JSONDecodeError as error:
            raise JarvisOpenAIClientError("The OpenAI Worker returned invalid JSON.") from error

        output_text = self._extract_output_text(response_json).strip()
        if not output_text:
            raise JarvisOpenAIClientError("GPT returned an empty response.")
        return output_text

    @staticmethod
    def _extract_output_text(response_json: dict) -> str:
        direct_output_text = response_json.get("output_text")
        if isinstance(direct_output_text, str):
            return direct_output_text

        text_parts: list[str] = []
        for output_item in response_json.get("output", []):
            if not isinstance(output_item, dict):
                continue
            for content_item in output_item.get("content", []):
                if not isinstance(content_item, dict):
                    continue
                text = content_item.get("text") or content_item.get("output_text")
                if isinstance(text, str):
                    text_parts.append(text)
        return "".join(text_parts)
