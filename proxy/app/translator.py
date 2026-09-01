"""Translate between the OpenAI chat-completions protocol and Elastic's
unified inference chat_completion API.

Elastic's streaming response already mirrors the OpenAI chunk shape
(`object: "chat.completion.chunk"`, `choices[].delta.content`), but each
event is wrapped one level deeper under a `chat_completion` key and framed
as SSE with an explicit `event: message` line, e.g.:

    event: message
    data: {"chat_completion": {"id": "...", "choices": [...], "object": "chat.completion.chunk"}}

    event: message
    data: [DONE]

This module unwraps `chat_completion` so the bytes we send back to OpenCode
are byte-for-byte what an OpenAI-compatible client expects.
"""

import json
from collections.abc import AsyncIterator, Callable

from app.schemas import ChatCompletionRequest

_DONE = b"data: [DONE]\n\n"

# Elastic's UnifiedCompletionRequest parses `messages` strictly and rejects the
# whole request if a message carries a field it doesn't know. OpenAI-compatible
# clients routinely attach vendor extensions - OpenCode sends Anthropic's
# `cache_control` on the system message - so forwarding messages verbatim
# produces:
#   [UnifiedCompletionRequest] failed to parse field [messages]
# Allowlist exactly what Elastic documents, and drop anything else.
# Source: specification/inference/_types/CommonTypes.ts (Message, ContentObject)
_ELASTIC_MESSAGE_FIELDS = frozenset(
    {"content", "role", "tool_call_id", "tool_calls", "reasoning", "reasoning_details"}
)
_ELASTIC_CONTENT_PART_FIELDS = frozenset({"type", "text", "image_url", "file"})
# ToolCall / ToolCallFunction. Sanitizing these matters as much as the message
# itself: the AI SDK carries `index` over from streaming tool-call deltas, and
# Elastic rejects the request for that one extra key - which broke every
# agentic tool-use turn while plain chat worked fine.
_ELASTIC_TOOL_CALL_FIELDS = frozenset({"id", "type", "function"})
_ELASTIC_TOOL_FUNCTION_FIELDS = frozenset({"name", "arguments"})


def _pick(source, allowed: frozenset):
    if not isinstance(source, dict):
        return source
    return {k: v for k, v in source.items() if k in allowed}


def _sanitize_content(content):
    """Strip unknown keys from array-style (multimodal) message content."""
    if not isinstance(content, list):
        return content
    return [_pick(part, _ELASTIC_CONTENT_PART_FIELDS) for part in content]


def _sanitize_tool_calls(tool_calls):
    if not isinstance(tool_calls, list):
        return tool_calls
    cleaned = []
    for call in tool_calls:
        entry = _pick(call, _ELASTIC_TOOL_CALL_FIELDS)
        if isinstance(entry, dict) and "function" in entry:
            entry["function"] = _pick(entry["function"], _ELASTIC_TOOL_FUNCTION_FIELDS)
        cleaned.append(entry)
    return cleaned


def _sanitize_message(message: dict) -> dict:
    clean = {k: v for k, v in message.items() if k in _ELASTIC_MESSAGE_FIELDS}
    if "content" in clean:
        clean["content"] = _sanitize_content(clean["content"])
    if "tool_calls" in clean:
        clean["tool_calls"] = _sanitize_tool_calls(clean["tool_calls"])
    return clean


def to_elastic_payload(request: ChatCompletionRequest) -> dict:
    """Map an OpenAI chat-completions request body to Elastic's unified schema.

    request.model is deliberately not forwarded: it's a client-facing alias
    (e.g. "claude") used only to pick which inference endpoint to call (see
    main.py) - the endpoint itself already pins an exact EIS model_id, and
    forwarding the alias as Elastic's `model` field would be meaningless to it.
    """
    payload: dict = {
        "messages": [
            _sanitize_message(message.model_dump(exclude_none=True))
            for message in request.messages
        ],
    }

    if request.temperature is not None:
        payload["temperature"] = request.temperature
    if request.top_p is not None:
        payload["top_p"] = request.top_p
    if request.max_tokens is not None:
        payload["max_completion_tokens"] = request.max_tokens
    if request.stop is not None:
        payload["stop"] = (
            request.stop if isinstance(request.stop, list) else [request.stop]
        )
    if request.tools is not None:
        payload["tools"] = request.tools
    if request.tool_choice is not None:
        payload["tool_choice"] = request.tool_choice

    return payload


def normalize_chunk(chunk: dict) -> dict:
    """Clean up tool-call deltas on the way back to the client.

    EIS emits filler deltas like `[{"index": 0, "type": null}]` - no `function`
    object and a null `type`. Strict OpenAI-compatible clients reject those
    ("expected object, received undefined" at choices.0.delta.tool_calls.0
    .function), which broke tool use for some upstream models even though the
    surrounding stream was fine.

    Note the asymmetry with the request path: `index` is stripped going *up*
    (Elastic's ToolCall schema has no such field) but must be preserved coming
    *down*, since clients rely on it to correlate streamed argument fragments.
    """
    for choice in chunk.get("choices", []):
        if not isinstance(choice, dict):
            continue
        delta = choice.get("delta")
        if not isinstance(delta, dict) or not isinstance(
            delta.get("tool_calls"), list
        ):
            continue

        cleaned = []
        for call in delta["tool_calls"]:
            if not isinstance(call, dict):
                cleaned.append(call)
                continue
            entry = {k: v for k, v in call.items() if v is not None}
            # An entry carrying nothing but `index` conveys no state change.
            if set(entry) <= {"index"}:
                continue
            cleaned.append(entry)

        if cleaned:
            delta["tool_calls"] = cleaned
        else:
            delta.pop("tool_calls", None)
    return chunk


def _parse_sse_data_lines(raw: str) -> str | None:
    """Extract the payload of a `data: ...` SSE line, or None for non-data lines."""
    line = raw.strip()
    if not line.startswith("data:"):
        return None
    return line[len("data:") :].strip()


async def stream_openai_chunks(
    lines: AsyncIterator[str],
    observe: Callable[[dict], None] | None = None,
) -> AsyncIterator[bytes]:
    """Consume raw SSE lines from Elastic (httpx's aiter_lines(), already str) and
    yield OpenAI-compatible SSE bytes.

    `observe` is called with each parsed chunk dict (post-normalization) so
    telemetry can piggyback on the JSON parse this function already does,
    keeping the streaming hot path free of duplicate work.
    """
    async for raw_line in lines:
        data = _parse_sse_data_lines(raw_line)
        if data is None:
            continue

        if data == "[DONE]":
            yield _DONE
            return

        try:
            event = json.loads(data)
        except json.JSONDecodeError:
            continue

        chunk = normalize_chunk(event.get("chat_completion", event))
        if observe is not None:
            observe(chunk)
        yield f"data: {json.dumps(chunk)}\n\n".encode()

    # Elastic didn't send an explicit [DONE] before closing the connection.
    yield _DONE


def collect_non_streaming_response(chunks: list[dict]) -> dict:
    """Fold a list of already-unwrapped chat.completion.chunk dicts into a single
    non-streaming chat.completion response, for clients that set stream=false."""
    content_parts: list[str] = []
    completion_id = "chatcmpl-eis-proxy"
    model = None
    usage = None
    finish_reason = "stop"

    for chunk in chunks:
        completion_id = chunk.get("id", completion_id)
        model = chunk.get("model", model)
        if chunk.get("usage"):
            usage = chunk["usage"]
        for choice in chunk.get("choices", []):
            delta = choice.get("delta", {})
            if delta.get("content"):
                content_parts.append(delta["content"])
            if choice.get("finish_reason"):
                finish_reason = choice["finish_reason"]

    response = {
        "id": completion_id,
        "object": "chat.completion",
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": "".join(content_parts)},
                "finish_reason": finish_reason,
            }
        ],
    }
    if usage:
        response["usage"] = usage
    return response
