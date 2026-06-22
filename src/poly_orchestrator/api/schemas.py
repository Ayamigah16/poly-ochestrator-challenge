from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field, field_validator


# ── Request schemas ───────────────────────────────────────────────────────────

class QueryRequest(BaseModel):
    brand: str = Field(..., min_length=1, max_length=200, description="Brand name to track")
    query_template: str = Field(
        ...,
        min_length=10,
        max_length=2000,
        description="The query to send to each AI provider",
    )
    adapters: list[str] | None = Field(
        default=None,
        description="Subset of adapters to use; omit for all enabled adapters",
    )
    competitors: list[str] = Field(
        default_factory=list,
        description="Competitor brand names to count alongside the primary brand",
    )

    @field_validator("adapters")
    @classmethod
    def validate_adapters(cls, v: list[str] | None) -> list[str] | None:
        if v is None:
            return v
        allowed = {"openai", "anthropic", "google", "perplexity", "groq"}
        invalid = set(v) - allowed
        if invalid:
            raise ValueError(f"Unknown adapters: {sorted(invalid)}. Allowed: {sorted(allowed)}")
        return v


# ── Response schemas ──────────────────────────────────────────────────────────

class AdapterResponseSchema(BaseModel):
    provider: str
    model: str
    latency_ms: float
    succeeded: bool
    error: str | None = None
    prompt_tokens: int
    completion_tokens: int


class MentionResultSchema(BaseModel):
    provider: str
    mentioned: bool
    mention_count: int
    rank_position: int | None
    competitor_mentions: dict[str, int]
    excerpt: str
    sentiment_score: float


class QueryResponse(BaseModel):
    query_id: str
    brand: str
    query: str
    created_at: datetime
    mention_rate: float
    average_rank: float | None
    average_sentiment: float
    succeeded_adapters: list[str]
    failed_adapters: list[str]
    adapter_responses: list[AdapterResponseSchema]
    mention_results: list[MentionResultSchema]


# ── Report schemas ────────────────────────────────────────────────────────────

class ReportSummary(BaseModel):
    brand: str
    total_queries: int
    overall_mention_rate: float
    best_adapter: str | None
    worst_adapter: str | None
    avg_sentiment: float
    queries: list[QueryResponse]


# ── Health schemas ────────────────────────────────────────────────────────────

class HealthResponse(BaseModel):
    status: Literal["ok", "degraded", "unhealthy"]
    version: str
    database: Literal["ok", "error"]
    redis: Literal["ok", "error"]
    adapters_configured: list[str]
