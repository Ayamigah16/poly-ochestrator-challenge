from __future__ import annotations

import time

import httpx
from tenacity import retry, stop_after_attempt, wait_exponential

from poly_orchestrator.adapters.base import AdapterResponse, BaseAdapter


class GeminiAdapter(BaseAdapter):
    provider_name = "google"

    def _endpoint(self) -> str:
        return (
            f"https://generativelanguage.googleapis.com/v1beta/models/"
            f"{self.model}:generateContent?key={self.api_key}"
        )

    @retry(stop=stop_after_attempt(3), wait=wait_exponential(min=1, max=8))
    async def query(self, prompt: str) -> AdapterResponse:
        start = time.monotonic()
        payload = {
            "contents": [{"parts": [{"text": prompt}]}],
            "generationConfig": {"temperature": 0.3, "maxOutputTokens": 1024},
        }
        async with httpx.AsyncClient(timeout=self.timeout) as client:
            r = await client.post(self._endpoint(), json=payload)
            r.raise_for_status()
            data = r.json()

        latency = (time.monotonic() - start) * 1000
        candidate = data["candidates"][0]
        content = candidate["content"]["parts"][0]["text"]
        usage = data.get("usageMetadata", {})
        return AdapterResponse(
            provider=self.provider_name,
            model=self.model,
            content=content,
            latency_ms=latency,
            prompt_tokens=usage.get("promptTokenCount", 0),
            completion_tokens=usage.get("candidatesTokenCount", 0),
            raw_metadata={"finish_reason": candidate.get("finishReason")},
        )
