import json
import os
from contextlib import contextmanager

import httpx
import pytest
from starlette.testclient import TestClient

TOKEN = "test-proxy-token"
AUTH = {"Authorization": f"Bearer {TOKEN}"}

os.environ.setdefault("ELASTIC_API_KEY", "test-key")
os.environ.setdefault("EIS_ENDPOINT_URL", "https://example-project.es.example.com")
os.environ.setdefault("PROXY_API_KEY", TOKEN)
os.environ.setdefault(
    "EIS_MODEL_MAP",
    json.dumps({"claude": "proj-chat-claude", "gemini": "proj-chat-gemini"}),
)

from app import main  # noqa: E402  (env vars must be set before Settings() is built)

SSE_BODY = (
    "event: message\n"
    'data: {"chat_completion":{"id":"chatcmpl-1","choices":[{"delta":{"content":"","role":"assistant"},"index":0}],"model":"anthropic-claude-5-sonnet","object":"chat.completion.chunk"}}\n'
    "\n"
    "event: message\n"
    'data: {"chat_completion":{"id":"chatcmpl-1","choices":[{"delta":{"content":"Hi there"},"index":0}],"model":"anthropic-claude-5-sonnet","object":"chat.completion.chunk"}}\n'
    "\n"
    "event: message\n"
    "data: [DONE]\n"
    "\n"
)


def _success_handler(request: httpx.Request) -> httpx.Response:
    return httpx.Response(
        200, text=SSE_BODY, headers={"content-type": "text/event-stream"}
    )


@contextmanager
def _client_with_handler(monkeypatch, handler):
    """Build a TestClient whose upstream httpx.AsyncClient is wired to `handler`.

    The proxy constructs its single AsyncClient once, in the FastAPI lifespan,
    so the handler must be patched in *before* the TestClient context (and
    therefore the lifespan) starts.
    """
    captured = {}
    telemetry_docs = []

    def recording_handler(request: httpx.Request) -> httpx.Response:
        # Telemetry writes share the proxy's httpx client, so they arrive
        # here too. Split them out: `captured` always holds the *inference*
        # request, and telemetry docs get their own list for assertions.
        if str(request.url).rstrip("/").endswith("/_doc"):
            telemetry_docs.append(
                {"url": str(request.url), "doc": json.loads(request.content)}
            )
            return httpx.Response(201, json={"result": "created"})
        captured["url"] = str(request.url)
        captured["headers"] = request.headers
        captured["body"] = request.content
        return handler(request)

    real_async_client = httpx.AsyncClient

    def fake_async_client(*args, **kwargs):
        kwargs["transport"] = httpx.MockTransport(recording_handler)
        return real_async_client(*args, **kwargs)

    monkeypatch.setattr(main.httpx, "AsyncClient", fake_async_client)

    with TestClient(main.app) as test_client:
        test_client.captured = captured
        test_client.telemetry_docs = telemetry_docs
        yield test_client


@pytest.fixture
def client(monkeypatch):
    with _client_with_handler(monkeypatch, _success_handler) as test_client:
        yield test_client


# --- auth -----------------------------------------------------------------


def test_health_is_unauthenticated_and_leaks_nothing(client):
    response = client.get("/health")
    assert response.status_code == 200
    # Must not disclose upstream project details to an unauthenticated caller.
    assert response.json() == {"status": "ok"}


@pytest.mark.parametrize("path", ["/v1/models", "/v1/chat/completions"])
def test_endpoints_reject_missing_token(client, path):
    response = client.request(
        "POST" if "chat" in path else "GET",
        path,
        json={"model": "claude", "messages": [{"role": "user", "content": "hi"}]},
    )
    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"


def test_endpoints_reject_wrong_token(client):
    response = client.get("/v1/models", headers={"Authorization": "Bearer nope"})
    assert response.status_code == 401


def test_unknown_model_is_not_disclosed_without_auth(client):
    """An unauthenticated caller must not learn the configured model aliases
    via the 400 'available models' message."""
    response = client.post(
        "/v1/chat/completions",
        json={"model": "bogus", "messages": [{"role": "user", "content": "hi"}]},
    )
    assert response.status_code == 401
    assert "claude" not in response.text


def test_list_models(client):
    response = client.get("/v1/models", headers=AUTH)
    assert response.status_code == 200
    body = response.json()
    assert body["object"] == "list"
    assert {m["id"] for m in body["data"]} == {"claude", "gemini"}


# --- request limits -------------------------------------------------------


def test_oversized_body_rejected(client):
    response = client.post(
        "/v1/chat/completions",
        headers={**AUTH, "Content-Length": str(main.settings.max_request_bytes + 1)},
        content=b"{}",
    )
    assert response.status_code == 413


# --- proxying -------------------------------------------------------------


def test_chat_completions_streaming_unwraps_elastic_payload(client):
    response = client.post(
        "/v1/chat/completions",
        headers=AUTH,
        json={
            "model": "claude",
            "stream": True,
            "messages": [{"role": "user", "content": "hi"}],
        },
    )

    assert response.status_code == 200
    body = response.text
    assert "chat_completion" not in body
    assert "Hi there" in body
    assert body.strip().endswith("data: [DONE]")

    assert client.captured["url"].endswith(
        "/_inference/chat_completion/proj-chat-claude/_stream"
    )
    assert client.captured["headers"]["authorization"] == "ApiKey test-key"

    sent_body = json.loads(client.captured["body"])
    assert "model" not in sent_body  # alias is routing-only, not forwarded upstream


def test_chat_completions_routes_by_model(client):
    response = client.post(
        "/v1/chat/completions",
        headers=AUTH,
        json={
            "model": "gemini",
            "stream": True,
            "messages": [{"role": "user", "content": "hi"}],
        },
    )

    assert response.status_code == 200
    assert client.captured["url"].endswith(
        "/_inference/chat_completion/proj-chat-gemini/_stream"
    )


def test_chat_completions_unknown_model_returns_400(client):
    response = client.post(
        "/v1/chat/completions",
        headers=AUTH,
        json={
            "model": "gpt",
            "stream": True,
            "messages": [{"role": "user", "content": "hi"}],
        },
    )

    assert response.status_code == 400
    assert "gpt" in response.json()["detail"]
    assert "claude" in response.json()["detail"]


def test_chat_completions_missing_model_returns_400(client):
    response = client.post(
        "/v1/chat/completions",
        headers=AUTH,
        json={"stream": True, "messages": [{"role": "user", "content": "hi"}]},
    )

    assert response.status_code == 400


def test_chat_completions_non_streaming_returns_single_json(client):
    response = client.post(
        "/v1/chat/completions",
        headers=AUTH,
        json={
            "model": "claude",
            "stream": False,
            "messages": [{"role": "user", "content": "hi"}],
        },
    )

    assert response.status_code == 200
    data = response.json()
    assert data["object"] == "chat.completion"
    assert data["choices"][0]["message"]["content"] == "Hi there"


# --- upstream error handling ----------------------------------------------
#
# Regression coverage for a fail-open bug: the streaming path used to raise
# from inside the StreamingResponse generator, by which point Starlette had
# already committed 200 OK. Callers saw an empty successful stream instead of
# an error. OpenCode always streams, so this was the only path that mattered.


@pytest.mark.parametrize("stream", [True, False])
def test_upstream_500_fails_closed_on_both_paths(monkeypatch, stream):
    def failing_handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, text="kaboom")

    with _client_with_handler(monkeypatch, failing_handler) as test_client:
        response = test_client.post(
            "/v1/chat/completions",
            headers=AUTH,
            json={
                "model": "claude",
                "stream": stream,
                "messages": [{"role": "user", "content": "hi"}],
            },
        )

    assert response.status_code == 500
    assert "kaboom" in response.text


@pytest.mark.parametrize("stream", [True, False])
def test_upstream_auth_failure_is_masked_as_502(monkeypatch, stream):
    """A bad *proxy* credential must not surface to the client as 401, which
    would wrongly implicate the client's own token."""

    def failing_handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(401, text='{"error":{"reason":"invalid api key"}}')

    with _client_with_handler(monkeypatch, failing_handler) as test_client:
        response = test_client.post(
            "/v1/chat/completions",
            headers=AUTH,
            json={
                "model": "claude",
                "stream": stream,
                "messages": [{"role": "user", "content": "hi"}],
            },
        )

    assert response.status_code == 502
    assert "invalid api key" not in response.text  # upstream detail stays in logs


def test_upstream_error_detail_is_truncated(monkeypatch):
    def failing_handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, text="x" * 10_000)

    with _client_with_handler(monkeypatch, failing_handler) as test_client:
        response = test_client.post(
            "/v1/chat/completions",
            headers=AUTH,
            json={
                "model": "claude",
                "stream": False,
                "messages": [{"role": "user", "content": "hi"}],
            },
        )

    assert response.status_code == 500
    assert len(response.json()["detail"]) < 1_000
