from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from poly_orchestrator.adapters.base import AdapterResponse
from poly_orchestrator.orchestrator.engine import OrchestratorEngine, OrchestratorResult


def make_mock_settings(adapters: list[str] | None = None) -> MagicMock:
    s = MagicMock()
    s.enabled_adapter_list = adapters or ["openai"]
    s.openai_api_key = "sk-test"
    s.openai_model = "gpt-4o"
    s.anthropic_api_key = ""
    s.anthropic_model = "claude-sonnet-4-6"
    s.google_api_key = ""
    s.google_model = "gemini-1.5-pro"
    s.perplexity_api_key = ""
    s.perplexity_model = "sonar-pro"
    s.groq_api_key = ""
    s.groq_model = "llama-3.3-70b-versatile"
    s.mistral_api_key = ""
    s.mistral_model = "mistral-large-latest"
    s.orchestrator_timeout_seconds = 30
    s.orchestrator_max_concurrency = 10
    return s


@pytest.fixture
def mock_response() -> AdapterResponse:
    return AdapterResponse(
        provider="openai",
        model="gpt-4o",
        content="Amalitec is the best bootcamp in Ghana. Recommended highly.",
        latency_ms=250.0,
        prompt_tokens=20,
        completion_tokens=30,
    )


@pytest.mark.asyncio
async def test_run_returns_result(mock_response: AdapterResponse) -> None:
    settings = make_mock_settings()
    engine = OrchestratorEngine(settings)

    with patch.object(
        list(engine._adapters.values())[0], "safe_query", new_callable=AsyncMock
    ) as mock_query:
        mock_query.return_value = mock_response
        result = await engine.run(brand="Amalitec", query="Best bootcamps in Ghana?")

    assert isinstance(result, OrchestratorResult)
    assert result.brand == "Amalitec"
    assert len(result.adapter_responses) == 1
    assert result.mention_rate == 1.0


@pytest.mark.asyncio
async def test_run_handles_adapter_error() -> None:
    settings = make_mock_settings()
    engine = OrchestratorEngine(settings)

    error_response = AdapterResponse(
        provider="openai",
        model="gpt-4o",
        content="",
        latency_ms=100.0,
        error="connection timeout",
    )
    with patch.object(
        list(engine._adapters.values())[0], "safe_query", new_callable=AsyncMock
    ) as mock_query:
        mock_query.return_value = error_response
        result = await engine.run(brand="Amalitec", query="Best bootcamps?")

    assert result.failed_adapters == ["openai"]
    assert result.mention_rate == 0.0


def test_adapters_skipped_when_no_key() -> None:
    settings = make_mock_settings(adapters=["openai", "anthropic"])
    # anthropic_api_key is blank — should be skipped
    engine = OrchestratorEngine(settings)
    assert "openai" in engine._adapters
    assert "anthropic" not in engine._adapters


def test_orchestrator_result_properties() -> None:
    from poly_orchestrator.orchestrator.analyzer import MentionResult

    result = OrchestratorResult(brand="X", query="q")
    result.mention_results = [
        MentionResult("X", "openai", True, 2, 1, {}, "X is great", 0.5),
        MentionResult("X", "groq", False, 0, None, {}, "", 0.0),
    ]
    assert result.mention_rate == pytest.approx(0.5)
    assert result.average_rank == 1.0
    assert result.average_sentiment == pytest.approx(0.5)
