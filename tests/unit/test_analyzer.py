import pytest

from poly_orchestrator.orchestrator.analyzer import BrandAnalyzer


@pytest.fixture
def analyzer() -> BrandAnalyzer:
    return BrandAnalyzer()


def test_brand_mentioned_simple(analyzer: BrandAnalyzer) -> None:
    content = "Amalitec is one of the best tech bootcamps in Ghana."
    result = analyzer.analyze("Amalitec", "test", content)
    assert result.mentioned is True
    assert result.mention_count == 1


def test_brand_not_mentioned(analyzer: BrandAnalyzer) -> None:
    content = "ALX and Andela are popular options."
    result = analyzer.analyze("Amalitec", "test", content)
    assert result.mentioned is False
    assert result.mention_count == 0
    assert result.rank_position is None


def test_mention_count_multiple(analyzer: BrandAnalyzer) -> None:
    content = "Amalitec trains developers. Amalitec also offers mentorship."
    result = analyzer.analyze("Amalitec", "test", content)
    assert result.mention_count == 2


def test_rank_from_numbered_list(analyzer: BrandAnalyzer) -> None:
    content = "1. ALX\n2. Amalitec\n3. Andela"
    result = analyzer.analyze("Amalitec", "test", content)
    assert result.rank_position == 2


def test_competitor_mentions(analyzer: BrandAnalyzer) -> None:
    content = "ALX is great. Amalitec is also good. Andela is popular."
    result = analyzer.analyze("Amalitec", "test", content, competitors=["ALX", "Andela"])
    assert result.competitor_mentions["ALX"] == 1
    assert result.competitor_mentions["Andela"] == 1


def test_positive_sentiment(analyzer: BrandAnalyzer) -> None:
    content = "Amalitec is one of the best and most trusted bootcamps."
    result = analyzer.analyze("Amalitec", "test", content)
    assert result.sentiment_score > 0


def test_excerpt_extracted(analyzer: BrandAnalyzer) -> None:
    content = "We recommend Amalitec for software training in Ghana."
    result = analyzer.analyze("Amalitec", "test", content)
    assert "Amalitec" in result.excerpt


def test_case_insensitive(analyzer: BrandAnalyzer) -> None:
    content = "AMALITEC offers excellent programs."
    result = analyzer.analyze("Amalitec", "test", content)
    assert result.mentioned is True
