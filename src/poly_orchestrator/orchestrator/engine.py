from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from typing import TYPE_CHECKING

import structlog

from poly_orchestrator.adapters import ADAPTER_REGISTRY, AdapterResponse, BaseAdapter
from poly_orchestrator.orchestrator.analyzer import BrandAnalyzer, MentionResult

if TYPE_CHECKING:
    from poly_orchestrator.config import Settings

log = structlog.get_logger(__name__)


@dataclass
class OrchestratorResult:
    brand: str
    query: str
    adapter_responses: list[AdapterResponse] = field(default_factory=list)
    mention_results: list[MentionResult] = field(default_factory=list)

    @property
    def mention_rate(self) -> float:
        if not self.mention_results:
            return 0.0
        return sum(1 for m in self.mention_results if m.mentioned) / len(self.mention_results)

    @property
    def average_rank(self) -> float | None:
        ranks = [m.rank_position for m in self.mention_results if m.rank_position is not None]
        return sum(ranks) / len(ranks) if ranks else None

    @property
    def average_sentiment(self) -> float:
        scores = [m.sentiment_score for m in self.mention_results if m.mentioned]
        return sum(scores) / len(scores) if scores else 0.0

    @property
    def succeeded_adapters(self) -> list[str]:
        return [r.provider for r in self.adapter_responses if r.succeeded]

    @property
    def failed_adapters(self) -> list[str]:
        return [r.provider for r in self.adapter_responses if not r.succeeded]


class OrchestratorEngine:
    """Fans out a brand-visibility query to all enabled AI adapters concurrently."""

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._analyzer = BrandAnalyzer()
        self._adapters: dict[str, BaseAdapter] = self._build_adapters()

    def _build_adapters(self) -> dict[str, BaseAdapter]:
        s = self._settings
        adapter_configs: dict[str, dict] = {
            "openai": {"api_key": s.openai_api_key, "model": s.openai_model},
            "anthropic": {"api_key": s.anthropic_api_key, "model": s.anthropic_model},
            "google": {"api_key": s.google_api_key, "model": s.google_model},
            "perplexity": {"api_key": s.perplexity_api_key, "model": s.perplexity_model},
            "groq": {"api_key": s.groq_api_key, "model": s.groq_model},
        }
        adapters = {}
        for name in s.enabled_adapter_list:
            cls = ADAPTER_REGISTRY.get(name)
            cfg = adapter_configs.get(name)
            if cls and cfg and cfg["api_key"]:
                adapters[name] = cls(
                    api_key=cfg["api_key"],
                    model=cfg["model"],
                    timeout=s.orchestrator_timeout_seconds,
                )
            else:
                log.warning("adapter_skipped", adapter=name, reason="missing api_key or unknown")
        return adapters

    async def run(
        self,
        brand: str,
        query: str,
        adapters: list[str] | None = None,
        competitors: list[str] | None = None,
    ) -> OrchestratorResult:
        target_adapters = (
            {k: v for k, v in self._adapters.items() if k in adapters}
            if adapters
            else self._adapters
        )

        sem = asyncio.Semaphore(self._settings.orchestrator_max_concurrency)

        async def _bounded_query(name: str, adapter: BaseAdapter) -> AdapterResponse:
            async with sem:
                log.info("adapter_query_start", adapter=name, brand=brand)
                resp = await adapter.safe_query(query)
                log.info(
                    "adapter_query_done",
                    adapter=name,
                    latency_ms=round(resp.latency_ms),
                    error=resp.error,
                )
                return resp

        tasks = [_bounded_query(name, adapter) for name, adapter in target_adapters.items()]
        responses: list[AdapterResponse] = await asyncio.gather(*tasks)

        mention_results = [
            self._analyzer.analyze(
                brand=brand,
                provider=resp.provider,
                content=resp.content,
                competitors=competitors,
            )
            for resp in responses
            if resp.succeeded
        ]

        result = OrchestratorResult(
            brand=brand,
            query=query,
            adapter_responses=responses,
            mention_results=mention_results,
        )
        log.info(
            "orchestration_complete",
            brand=brand,
            mention_rate=result.mention_rate,
            avg_rank=result.average_rank,
            failed=result.failed_adapters,
        )
        return result
