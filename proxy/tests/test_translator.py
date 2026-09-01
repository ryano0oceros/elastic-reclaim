import json

import pytest

from app.schemas import ChatCompletionRequest, ChatMessage
from app.translator import (
    collect_non_streaming_response,
    stream_openai_chunks,
    to_elastic_payload,
)

# Verbatim example from Elastic's chat_completion inference API docs:
# https://www.elastic.co/guide/en/elasticsearch/reference/current/chat-completion-inference-api.html
ELASTIC_SSE_LINES = [
    "event: message",
    'data: {"chat_completion":{"id":"chatcmpl-Ae0T","choices":[{"delta":{"content":"","role":"assistant"},"index":0}],"model":"gpt-4o-2024-08-06","object":"chat.completion.chunk"}}',
    "",
    "event: message",
    'data: {"chat_completion":{"id":"chatcmpl-Ae0T","choices":[{"delta":{"content":"Elastic"},"index":0}],"model":"gpt-4o-2024-08-06","object":"chat.completion.chunk"}}',
    "",
    "event: message",
    'data: {"chat_completion":{"id":"chatcmpl-Ae0T","choices":[],"model":"gpt-4o-2024-08-06","object":"chat.completion.chunk","usage":{"completion_tokens":28,"prompt_tokens":16,"total_tokens":44}}}',
    "",
    "event: message",
    "data: [DONE]",
    "",
]


async def _aiter(lines: list[str]):
    for line in lines:
        yield line


def test_to_elastic_payload_maps_optional_fields():
    request = ChatCompletionRequest(
        model="claude",
        messages=[ChatMessage(role="user", content="hi")],
        temperature=0.2,
        top_p=0.9,
        max_tokens=128,
        stop="STOP",
        tools=[{"type": "function", "function": {"name": "noop"}}],
        tool_choice="auto",
    )

    payload = to_elastic_payload(request)

    assert payload["messages"] == [{"role": "user", "content": "hi"}]
    assert payload["temperature"] == 0.2
    assert payload["top_p"] == 0.9
    assert payload["max_completion_tokens"] == 128
    assert payload["stop"] == ["STOP"]
    assert payload["tools"][0]["function"]["name"] == "noop"
    assert payload["tool_choice"] == "auto"
    # request.model is a client-facing routing alias (resolved to an
    # inference_id in main.py), not something Elastic's API understands -
    # it must never be forwarded upstream.
    assert "model" not in payload


def test_to_elastic_payload_omits_unset_optional_fields():
    request = ChatCompletionRequest(messages=[ChatMessage(role="user", content="hi")])

    payload = to_elastic_payload(request)

    assert payload == {"messages": [{"role": "user", "content": "hi"}]}


async def test_stream_openai_chunks_unwraps_and_forwards_done():
    chunks = [
        chunk
        async for chunk in stream_openai_chunks(_aiter(ELASTIC_SSE_LINES))
    ]

    assert len(chunks) == 4
    assert chunks[-1] == b"data: [DONE]\n\n"

    first = json.loads(chunks[0].decode().removeprefix("data: ").strip())
    assert first["object"] == "chat.completion.chunk"
    assert first["choices"][0]["delta"]["role"] == "assistant"
    assert "chat_completion" not in first

    second = json.loads(chunks[1].decode().removeprefix("data: ").strip())
    assert second["choices"][0]["delta"]["content"] == "Elastic"

    third = json.loads(chunks[2].decode().removeprefix("data: ").strip())
    assert third["usage"]["total_tokens"] == 44


async def test_stream_openai_chunks_appends_done_if_upstream_omits_it():
    lines = ELASTIC_SSE_LINES[:6]  # only the first two data events, no [DONE]

    chunks = [chunk async for chunk in stream_openai_chunks(_aiter(lines))]

    assert chunks[-1] == b"data: [DONE]\n\n"
    assert len(chunks) == 3  # 2 real chunks + synthesized DONE


async def test_stream_openai_chunks_skips_malformed_json():
    lines = ["data: not-json", "data: [DONE]"]

    chunks = [chunk async for chunk in stream_openai_chunks(_aiter(lines))]

    assert chunks == [b"data: [DONE]\n\n"]


def test_collect_non_streaming_response_concatenates_content():
    unwrapped_chunks = [
        {
            "id": "chatcmpl-Ae0T",
            "model": "gpt-4o-2024-08-06",
            "object": "chat.completion.chunk",
            "choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}}],
        },
        {
            "id": "chatcmpl-Ae0T",
            "model": "gpt-4o-2024-08-06",
            "object": "chat.completion.chunk",
            "choices": [{"index": 0, "delta": {"content": "Elastic"}}],
        },
        {
            "id": "chatcmpl-Ae0T",
            "model": "gpt-4o-2024-08-06",
            "object": "chat.completion.chunk",
            "choices": [],
            "usage": {"completion_tokens": 28, "prompt_tokens": 16, "total_tokens": 44},
        },
    ]

    response = collect_non_streaming_response(unwrapped_chunks)

    assert response["object"] == "chat.completion"
    assert response["choices"][0]["message"]["content"] == "Elastic"
    assert response["choices"][0]["finish_reason"] == "stop"
    assert response["usage"]["total_tokens"] == 44


# --- upstream field allowlist ---------------------------------------------
#
# Regression coverage for a real failure: OpenCode attaches Anthropic's
# `cache_control` to the system message, and Elastic rejected the entire
# request with "[UnifiedCompletionRequest] failed to parse field [messages]".
# curl-based tests never caught it because hand-written payloads don't carry
# vendor extensions.


def test_vendor_extensions_are_stripped_from_messages():
    request = ChatCompletionRequest(
        model="claude",
        messages=[
            ChatMessage.model_validate(
                {
                    "role": "system",
                    "content": "You are helpful.",
                    "cache_control": {"type": "ephemeral"},
                }
            )
        ],
    )

    message = to_elastic_payload(request)["messages"][0]

    assert "cache_control" not in message
    assert message == {"role": "system", "content": "You are helpful."}


def test_elastic_native_message_fields_are_preserved():
    """Stripping must not overreach - tool calling has to keep working."""
    request = ChatCompletionRequest(
        model="claude",
        messages=[
            ChatMessage.model_validate(
                {
                    "role": "assistant",
                    "content": None,
                    "tool_calls": [
                        {
                            "id": "call_1",
                            "type": "function",
                            "function": {"name": "get_weather", "arguments": "{}"},
                        }
                    ],
                }
            ),
            ChatMessage.model_validate(
                {"role": "tool", "content": "sunny", "tool_call_id": "call_1"}
            ),
        ],
    )

    messages = to_elastic_payload(request)["messages"]

    assert messages[0]["tool_calls"][0]["id"] == "call_1"
    assert messages[1]["tool_call_id"] == "call_1"


def test_unknown_keys_stripped_from_multimodal_content_parts():
    request = ChatCompletionRequest(
        model="claude",
        messages=[
            ChatMessage.model_validate(
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": "hi", "cache_control": {"x": 1}},
                        {"type": "image_url", "image_url": {"url": "data:..."}},
                    ],
                }
            )
        ],
    )

    parts = to_elastic_payload(request)["messages"][0]["content"]

    assert parts[0] == {"type": "text", "text": "hi"}
    assert parts[1] == {"type": "image_url", "image_url": {"url": "data:..."}}


def test_streaming_index_stripped_from_tool_calls():
    """The AI SDK carries `index` over from streaming tool-call deltas.
    Elastic's ToolCall schema has no such field and rejects the whole
    request, which broke every agentic tool-use turn."""
    request = ChatCompletionRequest(
        model="claude",
        messages=[
            ChatMessage.model_validate(
                {
                    "role": "assistant",
                    "content": "",
                    "tool_calls": [
                        {
                            "index": 0,
                            "id": "call_1",
                            "type": "function",
                            "function": {
                                "name": "read",
                                "arguments": "{}",
                                "parsed": {"a": 1},
                            },
                        }
                    ],
                }
            )
        ],
    )

    call = to_elastic_payload(request)["messages"][0]["tool_calls"][0]

    assert call == {
        "id": "call_1",
        "type": "function",
        "function": {"name": "read", "arguments": "{}"},
    }


# --- response-side tool-call normalization --------------------------------
#
# Deltas below are verbatim from a real EIS stream (openai-gpt-5.4). The
# `{"index": 0, "type": null}` filler made OpenCode reject the whole
# response: "expected object, received undefined" at
# choices.0.delta.tool_calls.0.function.

from app.translator import normalize_chunk  # noqa: E402


def _delta_tool_calls(chunk):
    return chunk["choices"][0]["delta"].get("tool_calls")


def test_filler_tool_call_delta_is_dropped():
    chunk = {"choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "type": None}]}}]}

    assert _delta_tool_calls(normalize_chunk(chunk)) is None


def test_null_type_stripped_but_payload_kept():
    chunk = {
        "choices": [
            {
                "index": 0,
                "delta": {
                    "tool_calls": [
                        {"index": 0, "function": {"arguments": '{"'}, "type": None}
                    ]
                },
            }
        ]
    }

    calls = _delta_tool_calls(normalize_chunk(chunk))

    # `index` must survive: clients use it to correlate argument fragments.
    assert calls == [{"index": 0, "function": {"arguments": '{"'}}]


def test_opening_tool_call_delta_is_untouched():
    chunk = {
        "choices": [
            {
                "index": 0,
                "delta": {
                    "tool_calls": [
                        {
                            "index": 0,
                            "id": "call_1",
                            "function": {"arguments": "", "name": "read"},
                            "type": "function",
                        }
                    ]
                },
            }
        ]
    }

    assert _delta_tool_calls(normalize_chunk(chunk)) == [
        {
            "index": 0,
            "id": "call_1",
            "function": {"arguments": "", "name": "read"},
            "type": "function",
        }
    ]


def test_normalize_leaves_plain_content_chunks_alone():
    chunk = {"choices": [{"index": 0, "delta": {"content": "hello"}}]}
    assert normalize_chunk(chunk) == chunk


def test_normalize_handles_usage_only_chunk_without_choices():
    chunk = {"choices": [], "usage": {"total_tokens": 5}}
    assert normalize_chunk(chunk) == chunk
