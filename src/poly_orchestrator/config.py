from __future__ import annotations

from functools import lru_cache
from typing import Annotated

from pydantic import Field, RedisDsn, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
    )

    # Application
    app_env: str = "development"
    app_host: str = "0.0.0.0"
    app_port: int = 8000
    app_log_level: str = "INFO"
    app_secret_key: str = "change-me"

    # Database
    database_url: str = "postgresql+asyncpg://poly:poly_pass@localhost:5432/poly_orchestrator"
    database_pool_size: int = 10
    database_max_overflow: int = 20

    # Redis
    redis_url: str = "redis://localhost:6379/0"
    cache_ttl_seconds: int = 300

    # OpenAI
    openai_api_key: str = ""
    openai_model: str = "gpt-4o"

    # Anthropic
    anthropic_api_key: str = ""
    anthropic_model: str = "claude-sonnet-4-6"

    # Google
    google_api_key: str = ""
    google_model: str = "gemini-1.5-pro"

    # Perplexity
    perplexity_api_key: str = ""
    perplexity_model: str = "sonar-pro"

    # Groq
    groq_api_key: str = ""
    groq_model: str = "llama-3.3-70b-versatile"

    # Orchestrator
    enabled_adapters: str = "openai,anthropic,google,perplexity,groq"
    orchestrator_timeout_seconds: int = 30
    orchestrator_max_concurrency: int = 10

    # Monitoring
    prometheus_enabled: bool = True

    @property
    def enabled_adapter_list(self) -> list[str]:
        return [a.strip() for a in self.enabled_adapters.split(",") if a.strip()]

    @property
    def is_production(self) -> bool:
        return self.app_env == "production"


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
