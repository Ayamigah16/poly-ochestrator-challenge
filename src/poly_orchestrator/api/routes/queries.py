from __future__ import annotations

import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, HTTPException, status

from poly_orchestrator.api.deps import EngineDep
from poly_orchestrator.api.schemas import (
    AdapterResponseSchema,
    MentionResultSchema,
    QueryRequest,
    QueryResponse,
)

router = APIRouter(prefix="/api/v1/queries", tags=["queries"])


@router.post(
    "",
    response_model=QueryResponse,
    status_code=status.HTTP_200_OK,
    summary="Submit a brand-visibility query to all configured AI providers",
)
async def submit_query(body: QueryRequest, engine: EngineDep) -> QueryResponse:
    if not engine._adapters:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="No AI adapters are configured. Check your API keys in .env.",
        )

    result = await engine.run(
        brand=body.brand,
        query=body.query_template,
        adapters=body.adapters,
        competitors=body.competitors,
    )

    return QueryResponse(
        query_id=str(uuid.uuid4()),
        brand=result.brand,
        query=result.query,
        created_at=datetime.now(tz=timezone.utc),
        mention_rate=result.mention_rate,
        average_rank=result.average_rank,
        average_sentiment=result.average_sentiment,
        succeeded_adapters=result.succeeded_adapters,
        failed_adapters=result.failed_adapters,
        adapter_responses=[
            AdapterResponseSchema(
                provider=r.provider,
                model=r.model,
                latency_ms=r.latency_ms,
                succeeded=r.succeeded,
                error=r.error,
                prompt_tokens=r.prompt_tokens,
                completion_tokens=r.completion_tokens,
            )
            for r in result.adapter_responses
        ],
        mention_results=[
            MentionResultSchema(
                provider=m.provider,
                mentioned=m.mentioned,
                mention_count=m.mention_count,
                rank_position=m.rank_position,
                competitor_mentions=m.competitor_mentions,
                excerpt=m.excerpt,
                sentiment_score=m.sentiment_score,
            )
            for m in result.mention_results
        ],
    )
