from __future__ import annotations

import time

import httpx
from tenacity import retry, stop_after_attempt, wait_exponential

from poly_orchestrator.adapters.base import AdapterResponse, BaseAdapter


class GroqAdapter(BaseAdapter):
    provider_name = "groq"
    _BASE_URL = "https://api.groq.com/openai/v1/chat/completions"

    @retry(stop=stop_after_attempt(3), wait=wait_exponential(min=1, max=8))
    async def query(self, prompt: str) -> AdapterResponse:
        start = time.monotonic()
        payload = {
            "model": self.model,
            "messages": [{"role": "user", "content": prompt}],
            "temperature": 0.3,
            "max_tokens": 1024,
        }
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
        }
        async with httpx.AsyncClient(timeout=self.timeout) as client:
            r = await client.post(self._BASE_URL, json=payload, headers=headers)
            r.raise_for_status()
            data = r.json()

        latency = (time.monotonic() - start) * 1000
        choice = data["choices"][0]["message"]["content"]
        usage = data.get("usage", {})
        return AdapterResponse(
            provider=self.provider_name,
            model=self.model,
            content=choice,
            latency_ms=latency,
            prompt_tokens=usage.get("prompt_tokens", 0),
            completion_tokens=usage.get("completion_tokens", 0),
            raw_metadata={
                "finish_reason": data["choices"][0].get("finish_reason"),
                "x_groq": data.get("x_groq", {}),
            },
        )
