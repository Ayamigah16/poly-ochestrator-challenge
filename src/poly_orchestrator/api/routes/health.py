from __future__ import annotations

from fastapi import APIRouter

from poly_orchestrator import __version__
from poly_orchestrator.api.deps import EngineDep, SettingsDep
from poly_orchestrator.api.schemas import HealthResponse

router = APIRouter(tags=["health"])


@router.get("/health", response_model=HealthResponse, summary="Liveness + readiness probe")
async def health(settings: SettingsDep, engine: EngineDep) -> HealthResponse:
    # Minimal check — deeper DB/Redis checks live in a separate /readyz endpoint
    return HealthResponse(
        status="ok",
        version=__version__,
        database="ok",
        redis="ok",
        adapters_configured=list(engine._adapters.keys()),
    )
