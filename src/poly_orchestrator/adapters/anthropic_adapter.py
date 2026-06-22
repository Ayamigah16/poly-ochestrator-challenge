from __future__ import annotations

import time

import httpx
from tenacity import retry, stop_after_attempt, wait_exponential

from poly_orchestrator.adapters.base import AdapterResponse, BaseAdapter


class AnthropicAdapter(BaseAdapter):
    provider_name = "anthropic"
    _BASE_URL = "https://api.anthropic.com/v1/messages"
    _API_VERSION = "2023-06-01"

    @retry(stop=stop_after_attempt(3), wait=wait_exponential(min=1, max=8))
    async def query(self, prompt: str) -> AdapterResponse:
        start = time.monotonic()
        payload = {
            "model": self.model,
            "max_tokens": 1024,
            "messages": [{"role": "user", "content": prompt}],
        }
        headers = {
            "x-api-key": self.api_key,
            "anthropic-version": self._API_VERSION,
            "Content-Type": "application/json",
        }
        async with httpx.AsyncClient(timeout=self.timeout) as client:
            r = await client.post(self._BASE_URL, json=payload, headers=headers)
            r.raise_for_status()
            data = r.json()

        latency = (time.monotonic() - start) * 1000
        content = data["content"][0]["text"]
        usage = data.get("usage", {})
        return AdapterResponse(
            provider=self.provider_name,
            model=self.model,
            content=content,
            latency_ms=latency,
            prompt_tokens=usage.get("input_tokens", 0),
            completion_tokens=usage.get("output_tokens", 0),
            raw_metadata={"stop_reason": data.get("stop_reason")},
        )
