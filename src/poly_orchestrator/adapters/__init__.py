from poly_orchestrator.adapters.anthropic_adapter import AnthropicAdapter
from poly_orchestrator.adapters.base import AdapterResponse, BaseAdapter
from poly_orchestrator.adapters.gemini_adapter import GeminiAdapter
from poly_orchestrator.adapters.groq_adapter import GroqAdapter
from poly_orchestrator.adapters.mistral_adapter import MistralAdapter
from poly_orchestrator.adapters.openai_adapter import OpenAIAdapter
from poly_orchestrator.adapters.perplexity_adapter import PerplexityAdapter

ADAPTER_REGISTRY: dict[str, type[BaseAdapter]] = {
    "openai": OpenAIAdapter,
    "anthropic": AnthropicAdapter,
    "google": GeminiAdapter,
    "perplexity": PerplexityAdapter,
    "groq": GroqAdapter,
    "mistral": MistralAdapter,
}

__all__ = [
    "AdapterResponse",
    "BaseAdapter",
    "OpenAIAdapter",
    "AnthropicAdapter",
    "GeminiAdapter",
    "PerplexityAdapter",
    "GroqAdapter",
    "MistralAdapter",
    "ADAPTER_REGISTRY",
]
