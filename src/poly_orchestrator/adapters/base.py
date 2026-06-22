from __future__ import annotations

import time
from abc import ABC, abstractmethod
from dataclasses import dataclass, field


@dataclass
class AdapterResponse:
    provider: str
    model: str
    content: str
    latency_ms: float
    prompt_tokens: int = 0
    completion_tokens: int = 0
    error: str | None = None
    raw_metadata: dict = field(default_factory=dict)

    @property
    def succeeded(self) -> bool:
        return self.error is None


class BaseAdapter(ABC):
    """Abstract base for every AI provider adapter."""

    provider_name: str = ""

    def __init__(self, api_key: str, model: str, timeout: int = 30) -> None:
        self.api_key = api_key
        self.model = model
        self.timeout = timeout

    @abstractmethod
    async def query(self, prompt: str) -> AdapterResponse:
        """Send *prompt* to the provider and return a structured response."""

    async def safe_query(self, prompt: str) -> AdapterResponse:
        """Wraps query() to always return an AdapterResponse, never raise."""
        start = time.monotonic()
        try:
            return await self.query(prompt)
        except Exception as exc:  # noqa: BLE001
            return AdapterResponse(
                provider=self.provider_name,
                model=self.model,
                content="",
                latency_ms=(time.monotonic() - start) * 1000,
                error=str(exc),
            )
