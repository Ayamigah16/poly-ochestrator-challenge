from __future__ import annotations

from dataclasses import asdict

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from poly_orchestrator.api.schemas import QueryResponse
from poly_orchestrator.db.models import QueryRecord


class QueryRepository:
    """Data-access layer for QueryRecord persistence."""

    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def save(self, response: QueryResponse) -> QueryRecord:
        record = QueryRecord(
            id=response.query_id,
            brand=response.brand,
            query=response.query,
            created_at=response.created_at,
            mention_rate=response.mention_rate,
            average_rank=response.average_rank,
            average_sentiment=response.average_sentiment,
            adapter_responses=[r.model_dump() for r in response.adapter_responses],
            mention_results=[m.model_dump() for m in response.mention_results],
            competitors=[],
            succeeded_adapters=response.succeeded_adapters,
            failed_adapters=response.failed_adapters,
        )
        self._session.add(record)
        await self._session.commit()
        await self._session.refresh(record)
        return record

    async def get_by_id(self, query_id: str) -> QueryRecord | None:
        result = await self._session.execute(
            select(QueryRecord).where(QueryRecord.id == query_id)
        )
        return result.scalar_one_or_none()

    async def list_by_brand(self, brand: str, limit: int = 10) -> list[QueryRecord]:
        result = await self._session.execute(
            select(QueryRecord)
            .where(QueryRecord.brand == brand)
            .order_by(QueryRecord.created_at.desc())
            .limit(limit)
        )
        return list(result.scalars().all())

    async def brand_mention_rate(self, brand: str) -> float:
        result = await self._session.execute(
            select(func.avg(QueryRecord.mention_rate)).where(QueryRecord.brand == brand)
        )
        value = result.scalar_one_or_none()
        return float(value) if value is not None else 0.0

    async def brand_avg_sentiment(self, brand: str) -> float:
        result = await self._session.execute(
            select(func.avg(QueryRecord.average_sentiment)).where(QueryRecord.brand == brand)
        )
        value = result.scalar_one_or_none()
        return float(value) if value is not None else 0.0

    async def count_by_brand(self, brand: str) -> int:
        result = await self._session.execute(
            select(func.count()).where(QueryRecord.brand == brand)
        )
        return int(result.scalar_one() or 0)
