from __future__ import annotations

from fastapi import APIRouter, Query

from poly_orchestrator.api.schemas import ReportSummary

router = APIRouter(prefix="/api/v1/reports", tags=["reports"])


@router.get(
    "",
    response_model=ReportSummary,
    summary="Aggregate visibility report for a brand (backed by DB in feature/data-storage)",
)
async def get_report(
    brand: str = Query(..., description="Brand name to report on"),
    limit: int = Query(default=10, ge=1, le=100),
) -> ReportSummary:
    # Stub: returns empty report until the DB layer is wired in feature/data-storage
    return ReportSummary(
        brand=brand,
        total_queries=0,
        overall_mention_rate=0.0,
        best_adapter=None,
        worst_adapter=None,
        avg_sentiment=0.0,
        queries=[],
    )
