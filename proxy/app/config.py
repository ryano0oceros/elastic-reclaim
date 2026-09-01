from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    elastic_api_key: str
    eis_endpoint_url: str
    # JSON object mapping a client-facing model alias (e.g. "claude") to the
    # Elastic inference_id backing it, e.g. {"claude": "eis-proxy-poc-chat-claude"}.
    # pydantic-settings JSON-decodes this from the env var automatically.
    eis_model_map: dict[str, str]

    # Bearer token clients must present on /v1/* endpoints. The proxy holds a
    # real Elastic API key and bills real inference, so leaving this unset on
    # anything internet-reachable turns it into an open LLM relay - see
    # require_auth below, which fails closed rather than silently allowing all.
    proxy_api_key: str | None = None
    # Escape hatch for local development only. Must be set explicitly to run
    # without proxy_api_key; there is deliberately no way to end up
    # unauthenticated by omission.
    allow_unauthenticated: bool = False

    # Rejects request bodies larger than this (bytes) before they are buffered.
    # Coding agents legitimately send large contexts, so this is generous.
    max_request_bytes: int = 10 * 1024 * 1024

    # --- analytics ---------------------------------------------------------
    # Usage metadata (user, model, tokens, latency - never prompt content) is
    # always written to usage_data_stream in the same Elastic project that
    # serves inference. capture_llm_traffic additionally records full request
    # messages and response text to capture_data_stream - a deliberate,
    # documented privacy trade-off, so it defaults OFF and is surfaced to
    # developers in docs/developer-onboarding.md.
    capture_llm_traffic: bool = False
    usage_data_stream: str = "eis-proxy-usage"
    capture_data_stream: str = "eis-proxy-captures"

    # Cost attribution. Maps a model alias to its rate per 1M tokens, e.g.
    # {"claude": {"input_per_1m": 4.5, "output_per_1m": 21.0}}. Rates are
    # contract-specific, so they are configuration rather than constants -
    # see the model_pricing Terraform variable. An alias missing from this
    # map yields usage events with no cost fields at all, which is
    # deliberate: omitting the value keeps it out of SUM aggregations,
    # whereas writing 0.0 would silently understate spend.
    # float | None because Terraform serializes unset optional() fields as
    # JSON null; the collector treats a null rate as absent.
    eis_model_pricing: dict[str, dict[str, float | None]] = {}

    request_timeout_seconds: float = 60.0

    @property
    def require_auth(self) -> bool:
        return not self.allow_unauthenticated


def validate_startup(settings: Settings) -> None:
    """Fail fast on configurations that would be unsafe to serve.

    Kept separate from Settings so it can be exercised directly in tests
    rather than only as an import-time side effect.
    """
    if settings.require_auth and not settings.proxy_api_key:
        raise RuntimeError(
            "PROXY_API_KEY is not set. Set it to a strong random value, or set "
            "ALLOW_UNAUTHENTICATED=true for local development only. Refusing to "
            "start an unauthenticated proxy that holds a live Elastic API key."
        )


settings = Settings()
validate_startup(settings)
