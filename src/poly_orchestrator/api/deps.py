from __future__ import annotations

from typing import Annotated

from fastapi import Depends

from poly_orchestrator.config import Settings, get_settings
from poly_orchestrator.orchestrator.engine import OrchestratorEngine

SettingsDep = Annotated[Settings, Depends(get_settings)]

# Engine is expensive to build (adapter introspection) — reuse the cached instance
_engine: OrchestratorEngine | None = None


def get_engine(settings: SettingsDep) -> OrchestratorEngine:
    global _engine
    if _engine is None:
        _engine = OrchestratorEngine(settings)
    return _engine


EngineDep = Annotated[OrchestratorEngine, Depends(get_engine)]
