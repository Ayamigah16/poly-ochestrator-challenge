from __future__ import annotations

from prometheus_client import Counter, Gauge, Histogram

# ── Counters ──────────────────────────────────────────────────────────────────
QUERY_TOTAL = Counter(
    "orchestrator_queries_total",
    "Total number of brand-visibility queries executed",
    labelnames=["brand", "adapter"],
)

ADAPTER_ERRORS = Counter(
    "orchestrator_adapter_errors_total",
    "Total adapter errors by provider",
    labelnames=["adapter"],
)

# ── Histograms ────────────────────────────────────────────────────────────────
QUERY_DURATION = Histogram(
    "orchestrator_query_duration_seconds",
    "Time taken for a single adapter query",
    labelnames=["adapter"],
    buckets=[0.1, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 30.0],
)

# ── Gauges ────────────────────────────────────────────────────────────────────
BRAND_MENTION_RATE = Gauge(
    "orchestrator_brand_mention_rate",
    "Latest mention rate (0–1) for a brand across all adapters",
    labelnames=["brand"],
)

BRAND_SENTIMENT = Gauge(
    "orchestrator_brand_sentiment_score",
    "Latest average sentiment score (-1 to 1) for a brand",
    labelnames=["brand"],
)

ACTIVE_ADAPTERS = Gauge(
    "orchestrator_active_adapters_total",
    "Number of configured and enabled AI adapters",
)


def record_query(
    brand: str,
    adapter: str,
    latency_seconds: float,
    succeeded: bool,
    mention_rate: float,
    sentiment: float,
) -> None:
    QUERY_TOTAL.labels(brand=brand, adapter=adapter).inc()
    QUERY_DURATION.labels(adapter=adapter).observe(latency_seconds)
    if not succeeded:
        ADAPTER_ERRORS.labels(adapter=adapter).inc()
    BRAND_MENTION_RATE.labels(brand=brand).set(mention_rate)
    BRAND_SENTIMENT.labels(brand=brand).set(sentiment)
