from __future__ import annotations

import re
from dataclasses import dataclass, field


@dataclass
class MentionResult:
    brand: str
    provider: str
    mentioned: bool
    mention_count: int
    rank_position: int | None  # ordinal position in response (1-indexed), None if not found
    competitor_mentions: dict[str, int] = field(default_factory=dict)
    excerpt: str = ""
    sentiment_score: float = 0.0  # -1.0 (negative) … +1.0 (positive)


_POSITIVE_SIGNALS = frozenset(
    [
        "best",
        "top",
        "excellent",
        "recommend",
        "leading",
        "trusted",
        "award",
        "popular",
        "reputable",
        "quality",
        "outstanding",
    ]
)
_NEGATIVE_SIGNALS = frozenset(
    [
        "avoid",
        "bad",
        "worst",
        "scam",
        "poor",
        "overpriced",
        "unreliable",
        "slow",
        "expensive",
        "disappointing",
    ]
)


class BrandAnalyzer:
    """Detects brand mentions in LLM-generated text and computes visibility scores."""

    def analyze(
        self,
        brand: str,
        provider: str,
        content: str,
        competitors: list[str] | None = None,
    ) -> MentionResult:
        competitors = competitors or []
        lower = content.lower()
        brand_lower = brand.lower()

        # Count occurrences
        count = len(re.findall(re.escape(brand_lower), lower))
        mentioned = count > 0

        # Find ordinal rank: which numeric list item or paragraph mentions the brand first
        rank = self._detect_rank(brand_lower, lower) if mentioned else None

        # Competitor mention counts
        comp_counts = {
            comp: len(re.findall(re.escape(comp.lower()), lower)) for comp in competitors
        }

        # Extract a short excerpt around first mention
        excerpt = self._extract_excerpt(brand, content) if mentioned else ""

        # Naive sentiment from surrounding 100-char window
        sentiment = self._score_sentiment(brand_lower, lower) if mentioned else 0.0

        return MentionResult(
            brand=brand,
            provider=provider,
            mentioned=mentioned,
            mention_count=count,
            rank_position=rank,
            competitor_mentions=comp_counts,
            excerpt=excerpt,
            sentiment_score=round(sentiment, 3),
        )

    def _detect_rank(self, brand_lower: str, content_lower: str) -> int | None:
        """Return the ordinal list position (1-indexed) where brand appears, or None."""
        # Match numbered list items: "1. Foo" or "1) Foo"
        pattern = re.compile(r"(\d+)[.)]\s+(.+?)(?=\n|$)")
        for match in pattern.finditer(content_lower):
            if brand_lower in match.group(2):
                return int(match.group(1))
        # Fall back to paragraph order
        paragraphs = [p for p in content_lower.split("\n") if p.strip()]
        for idx, para in enumerate(paragraphs, start=1):
            if brand_lower in para:
                return idx
        return None

    def _extract_excerpt(self, brand: str, content: str, window: int = 120) -> str:
        idx = content.lower().find(brand.lower())
        if idx == -1:
            return ""
        start = max(0, idx - 40)
        end = min(len(content), idx + window)
        return content[start:end].strip()

    def _score_sentiment(self, brand_lower: str, content_lower: str) -> float:
        idx = content_lower.find(brand_lower)
        window = content_lower[max(0, idx - 80) : idx + 200]
        words = set(window.split())
        positives = len(words & _POSITIVE_SIGNALS)
        negatives = len(words & _NEGATIVE_SIGNALS)
        total = positives + negatives
        if total == 0:
            return 0.0
        return (positives - negatives) / total
