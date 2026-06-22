from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import JSON, Boolean, DateTime, Float, Integer, String, Text
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


def _now() -> datetime:
    return datetime.now(tz=timezone.utc)


class Base(DeclarativeBase):
    pass


class QueryRecord(Base):
    """Persisted result of one orchestration run."""

    __tablename__ = "query_records"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    brand: Mapped[str] = mapped_column(String(200), nullable=False, index=True)
    query: Mapped[str] = mapped_column(Text, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)

    # Aggregate metrics
    mention_rate: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    average_rank: Mapped[float | None] = mapped_column(Float, nullable=True)
    average_sentiment: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)

    # Full JSON payloads stored for audit / replay
    adapter_responses: Mapped[dict] = mapped_column(JSON, nullable=False, default=dict)
    mention_results: Mapped[dict] = mapped_column(JSON, nullable=False, default=dict)
    competitors: Mapped[list] = mapped_column(JSON, nullable=False, default=list)

    # Derived flags
    succeeded_adapters: Mapped[list] = mapped_column(JSON, nullable=False, default=list)
    failed_adapters: Mapped[list] = mapped_column(JSON, nullable=False, default=list)


class BrandMetric(Base):
    """Rolling daily brand-visibility metric (materialised from QueryRecord)."""

    __tablename__ = "brand_metrics"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    brand: Mapped[str] = mapped_column(String(200), nullable=False, index=True)
    metric_date: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)

    total_queries: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    avg_mention_rate: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    avg_rank: Mapped[float | None] = mapped_column(Float, nullable=True)
    avg_sentiment: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    best_adapter: Mapped[str | None] = mapped_column(String(50), nullable=True)
