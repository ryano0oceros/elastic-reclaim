"""Usage analytics for the EIS proxy.

Every completion emits one usage document (metadata only - user, model,
tokens, latency; never prompt content) to an Elasticsearch data stream in the
same Serverless project that serves inference. When CAPTURE_LLM_TRAFFIC is
enabled, a second document with the full request messages and assembled
response text goes to a separate captures stream with shorter retention.

Writes are fire-and-forget: a telemetry failure is logged and never blocks,
delays, or fails the completion the developer is waiting on.
"""

import asyncio
import json
import logging
import time
from datetime import datetime, timezone

import httpx

from app.config import Settings

logger = logging.getLogger("eis-proxy.telemetry")

# Keeps the readable prompt column usable when someone pastes a whole file.
_MAX_USER_PROMPT_CHARS = 2000
# conversation_text is for reading at a glance in Discover, not for archival -
# request_text keeps the exact payload. Per-message and overall caps stop one
# giant tool result from burying the rest of the exchange.
_MAX_TURN_CHARS = 400
_MAX_CONVERSATION_CHARS = 6000

# Keeps strong references to in-flight writes (create_task alone is not
# enough - the loop holds tasks weakly) and gives tests a drain() hook.
_pending: set[asyncio.Task] = set()


class UsageCollector:
    """Accumulates per-request analytics as response chunks stream past.

    Designed to observe the chunk dicts the translator already parses, so the
    streaming hot path does no extra JSON work. Response text is only
    accumulated when capture is enabled.
    """

    def __init__(
        self,
        *,
        user: str,
        model_alias: str | None,
        inference_id: str | None,
        stream: bool,
        capture: bool,
        request_messages: list[dict] | None = None,
        request_bytes: int = 0,
        pricing: dict[str, float] | None = None,
    ):
        self.user = user
        self.model_alias = model_alias
        self.inference_id = inference_id
        self.stream = stream
        self.capture = capture
        self.request_messages = request_messages if capture else None
        self.request_bytes = request_bytes
        self.pricing = pricing

        self._started = time.monotonic()
        self._first_chunk_at: float | None = None
        self.upstream_model: str | None = None
        self.usage: dict = {}
        self._tool_call_ids: set[str] = set()
        self._content_parts: list[str] = []

    def observe(self, chunk: dict) -> None:
        if self._first_chunk_at is None:
            self._first_chunk_at = time.monotonic()
        if chunk.get("model"):
            self.upstream_model = chunk["model"]
        if chunk.get("usage"):
            self.usage = chunk["usage"]
        for choice in chunk.get("choices", []):
            if not isinstance(choice, dict):
                continue
            delta = choice.get("delta") or {}
            for call in delta.get("tool_calls") or []:
                if isinstance(call, dict) and call.get("id"):
                    self._tool_call_ids.add(call["id"])
            if self.capture and isinstance(delta.get("content"), str):
                self._content_parts.append(delta["content"])

    def _cost_fields(self) -> dict:
        """Per-request spend, from the configured rate for this model.

        Returns {} when the model has no configured rate or the upstream
        reported no token counts - an absent field is excluded from SUM
        aggregations, so a missing rate shows up as a gap rather than as
        zero spend that quietly understates the bill.
        """
        if not self.pricing:
            return {}
        prompt = self.usage.get("prompt_tokens")
        completion = self.usage.get("completion_tokens")
        if prompt is None and completion is None:
            return {}
        # Several EIS models price by prompt size: above a context threshold
        # BOTH the input and output rate step up (Gemini 3.1 Pro at 200K,
        # GPT-5.4 at 272K). The tier is selected on prompt tokens, which is
        # what defines the context size being charged for.
        def rate(key: str) -> float:
            # `or 0.0` collapses both a missing key and an explicit null,
            # which Terraform emits for unset optional() fields.
            return self.pricing.get(key) or 0.0

        threshold = rate("tier_threshold_tokens")
        tiered = threshold > 0 and (prompt or 0) > threshold
        in_rate = rate("tier_input_per_1m" if tiered else "input_per_1m")
        out_rate = rate("tier_output_per_1m" if tiered else "output_per_1m")

        input_cost = (prompt or 0) / 1_000_000 * in_rate
        output_cost = (completion or 0) / 1_000_000 * out_rate
        return {
            "input_cost": round(input_cost, 8),
            "output_cost": round(output_cost, 8),
            "cost": round(input_cost + output_cost, 8),
            # Recorded so a spend spike can be traced to tier escalation
            # rather than to more traffic.
            "price_tier": "high" if tiered else "standard",
        }

    def usage_event(self, status: str) -> dict:
        now = time.monotonic()
        event = {
            "@timestamp": datetime.now(timezone.utc).isoformat(),
            "user": self.user,
            "model_alias": self.model_alias,
            "upstream_model": self.upstream_model,
            "inference_id": self.inference_id,
            "status": status,
            "stream": self.stream,
            "tool_call_count": len(self._tool_call_ids),
            "request_bytes": self.request_bytes,
            "latency_ms": round((now - self._started) * 1000, 1),
        }
        if self._first_chunk_at is not None:
            event["ttfb_ms"] = round((self._first_chunk_at - self._started) * 1000, 1)
        for key in ("prompt_tokens", "completion_tokens", "total_tokens"):
            if key in self.usage:
                event[key] = self.usage[key]
        event.update(self._cost_fields())
        return event

    @staticmethod
    def _latest_user_prompt(messages: list[dict] | None) -> str | None:
        """The most recent human turn, for at-a-glance reading in analytics.

        request_text holds the whole conversation, which for a coding agent
        is overwhelmingly system prompt and tool output - the actual question
        is invisible in it. Scans backwards for the last `user` message:
        during an agentic loop tool results come back as role `tool`, so the
        last `user` entry is reliably what the human typed.
        """
        for message in reversed(messages or []):
            if not isinstance(message, dict) or message.get("role") != "user":
                continue
            content = message.get("content")
            if isinstance(content, str):
                text = content
            elif isinstance(content, list):
                # Multimodal: keep the text parts, skip images/files.
                text = " ".join(
                    part.get("text", "")
                    for part in content
                    if isinstance(part, dict) and part.get("type") == "text"
                ).strip()
            else:
                continue
            if text:
                # Bounded so a pasted file cannot make the column unusable;
                # request_text still carries the untruncated original.
                return text[:_MAX_USER_PROMPT_CHARS]
        return None

    @staticmethod
    def _readable_conversation(messages: list[dict] | None) -> str | None:
        """A plain-text transcript of the exchange.

        request_text is the exact JSON payload, which is the right thing to
        keep but unreadable in a table cell. This renders the same content as
        `role: text` lines so the Query Analytics panel can be skimmed.
        Tool calls are summarized by name rather than dumped as argument
        JSON, which is what makes an agent transcript unreadable.
        """
        if not messages:
            return None
        lines: list[str] = []
        for message in messages:
            if not isinstance(message, dict):
                continue
            role = message.get("role", "?")
            # Skip the system prompt: it is static boilerplate, identical on
            # every request from a given client, and thousands of tokens long
            # - including it means every row in the table opens with the same
            # wall of text. Still present in request_text if needed.
            if role == "system":
                continue
            content = message.get("content")
            if isinstance(content, list):
                text = " ".join(
                    part.get("text", "")
                    for part in content
                    if isinstance(part, dict) and part.get("type") == "text"
                ).strip()
            elif isinstance(content, str):
                text = content.strip()
            else:
                text = ""
            calls = message.get("tool_calls") or []
            if calls:
                names = ", ".join(
                    (c.get("function") or {}).get("name", "?")
                    for c in calls
                    if isinstance(c, dict)
                )
                text = f"{text} [calls: {names}]".strip() if text else f"[calls: {names}]"
            if not text:
                continue
            if len(text) > _MAX_TURN_CHARS:
                text = text[:_MAX_TURN_CHARS] + "…"
            lines.append(f"{role}: {text}")
        transcript = "\n".join(lines)
        if len(transcript) > _MAX_CONVERSATION_CHARS:
            transcript = transcript[:_MAX_CONVERSATION_CHARS] + "\n…(truncated)"
        return transcript or None

    def capture_event(self) -> dict | None:
        if not self.capture:
            return None
        return {
            "@timestamp": datetime.now(timezone.utc).isoformat(),
            "user": self.user,
            "model_alias": self.model_alias,
            "upstream_model": self.upstream_model,
            "message_count": len(self.request_messages or []),
            # Searchable text rather than nested objects: query analytics
            # wants full-text search over prompts, not per-field aggregations.
            "user_prompt": self._latest_user_prompt(self.request_messages),
            "conversation_text": self._readable_conversation(self.request_messages),
            "request_text": json.dumps(self.request_messages or []),
            "response_text": "".join(self._content_parts),
            "total_tokens": self.usage.get("total_tokens"),
        }


def emit(
    client: httpx.AsyncClient | None,
    settings: Settings,
    collector: UsageCollector,
    status: str,
) -> None:
    """Queue the collector's document(s) for background indexing."""
    if client is None:
        return
    _submit(client, settings, settings.usage_data_stream, collector.usage_event(status))
    capture_doc = collector.capture_event()
    if capture_doc is not None and status == "success":
        _submit(client, settings, settings.capture_data_stream, capture_doc)


def _submit(
    client: httpx.AsyncClient, settings: Settings, data_stream: str, doc: dict
) -> None:
    task = asyncio.create_task(_write(client, settings, data_stream, doc))
    _pending.add(task)
    task.add_done_callback(_pending.discard)


async def _write(
    client: httpx.AsyncClient, settings: Settings, data_stream: str, doc: dict
) -> None:
    url = f"{settings.eis_endpoint_url.rstrip('/')}/{data_stream}/_doc"
    try:
        response = await client.post(
            url,
            json=doc,
            headers={"Authorization": f"ApiKey {settings.elastic_api_key}"},
        )
        if response.status_code >= 300:
            body = (await response.aread()).decode(errors="ignore")[:300]
            logger.warning(
                "telemetry write to %s failed: %s %s",
                data_stream,
                response.status_code,
                body,
            )
    except Exception:  # noqa: BLE001 - telemetry must never break completions
        logger.warning("telemetry write to %s failed", data_stream, exc_info=True)


async def drain() -> None:
    """Await all in-flight telemetry writes (used by tests and shutdown)."""
    while _pending:
        await asyncio.gather(*list(_pending), return_exceptions=True)
