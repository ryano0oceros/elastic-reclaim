"""Agent memory: what gets recorded, and who can read it back."""

import json

import httpx
import pytest

from app.config import Settings
from app.memory import search_memory
from app.telemetry import UsageCollector
from tests.test_main import AUTH, _client_with_handler, _success_handler


def _collector(capture=True, messages=None, content=("Use ELSER.",)):
    c = UsageCollector(
        user="alice", model_alias="claude-sonnet", inference_id="ep",
        stream=True, capture=capture,
        request_messages=messages if messages is not None else [
            {"role": "system", "content": "boilerplate"},
            {"role": "user", "content": "how should I embed the chat history?"},
        ],
    )
    c._content_parts = list(content)
    c.usage = {"total_tokens": 42}
    return c


def test_memory_event_keeps_question_and_answer_only():
    e = _collector().memory_event()
    assert e["prompt"] == "how should I embed the chat history?"
    assert e["response"] == "Use ELSER."
    assert e["user"] == "alice"
    # Deliberately narrower than a capture: no system prompt, no raw JSON.
    assert "request_text" not in e and "conversation_text" not in e


def test_no_memory_when_capture_disabled():
    assert _collector(capture=False).memory_event() is None


def test_exchange_with_no_answer_is_not_recorded():
    """An empty semantic_text field still costs an inference call to embed."""
    assert _collector(content=("",)).memory_event() is None


def test_exchange_with_no_user_turn_is_not_recorded():
    assert _collector(messages=[{"role": "system", "content": "x"}]).memory_event() is None


def test_long_answer_truncated():
    e = _collector(content=("y" * 9000,)).memory_event()
    assert len(e["response"]) == 2000


@pytest.mark.asyncio
async def test_search_is_scoped_to_the_calling_user():
    """Recall must never surface another developer's prompts."""
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["body"] = json.loads(request.content)
        seen["url"] = str(request.url)
        return httpx.Response(200, json={"hits": {"hits": [{
            "_score": 8.5,
            "_source": {"@timestamp": "2026-09-01T12:00:00Z", "prompt": "p",
                        "response": "r", "model_alias": "claude-sonnet"}}]}})

    settings = Settings(
        elastic_api_key="k", eis_endpoint_url="https://e.example.com",
        proxy_api_key="t", eis_model_map={"claude": "c"},
    )
    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as c:
        out = await search_memory(c, settings, user="alice", query="embeddings", limit=3)

    assert {"term": {"user": "alice"}} in seen["body"]["query"]["bool"]["filter"]
    assert seen["body"]["query"]["bool"]["must"][0]["semantic"]["field"] == "prompt"
    assert seen["url"].endswith("/eis-agent-memory/_search")
    assert out[0]["you_asked"] == "p"


@pytest.mark.asyncio
async def test_search_limit_is_capped():
    def handler(request: httpx.Request) -> httpx.Response:
        assert json.loads(request.content)["size"] == 20  # MAX_RESULTS
        return httpx.Response(200, json={"hits": {"hits": []}})

    settings = Settings(elastic_api_key="k", eis_endpoint_url="https://e.example.com",
                        proxy_api_key="t", eis_model_map={"claude": "c"})
    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as c:
        await search_memory(c, settings, user="alice", query="q", limit=9999)


def test_mcp_endpoint_requires_the_bearer_token(monkeypatch):
    """/mcp holds the same Elasticsearch credential as /v1 and must be
    guarded identically."""
    with _client_with_handler(monkeypatch, _success_handler) as client:
        assert client.post("/mcp/", json={}).status_code == 401
        assert client.post("/mcp/", json={}, headers={"Authorization": "Bearer wrong"}).status_code == 401
        # With a valid token the guard passes through to the MCP app, which
        # rejects a non-MCP body itself - anything but 401 proves auth passed.
        assert client.post("/mcp/", json={}, headers=AUTH).status_code != 401
