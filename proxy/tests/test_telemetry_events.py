"""Usage-analytics behavior of the proxy.

These reuse test_main's harness: telemetry writes go through the same mocked
httpx client, get split into `telemetry_docs`, and the lifespan's
telemetry.drain() guarantees every in-flight write has landed by the time the
TestClient context exits - so assertions after the `with` block are
deterministic, no sleeps.
"""

import httpx

from tests.test_main import AUTH, _client_with_handler, _success_handler


def _usage_docs(docs):
    return [d["doc"] for d in docs if "eis-proxy-usage" in d["url"]]


def _capture_docs(docs):
    return [d["doc"] for d in docs if "eis-proxy-captures" in d["url"]]


def _chat(client, **overrides):
    body = {
        "model": "claude",
        "stream": True,
        "messages": [{"role": "user", "content": "hi"}],
    }
    body.update(overrides)
    return client.post("/v1/chat/completions", headers=AUTH, json=body)


def test_streaming_success_emits_usage_event(monkeypatch):
    with _client_with_handler(monkeypatch, _success_handler) as client:
        response = client.post(
            "/v1/chat/completions",
            headers={**AUTH, "X-EIS-User": "alice"},
            json={
                "model": "claude",
                "stream": True,
                "messages": [{"role": "user", "content": "hi"}],
            },
        )
        assert response.status_code == 200
        docs = client.telemetry_docs

    usage = _usage_docs(docs)
    assert len(usage) == 1
    event = usage[0]
    assert event["user"] == "alice"
    assert event["model_alias"] == "claude"
    assert event["upstream_model"] == "anthropic-claude-5-sonnet"
    assert event["inference_id"] == "proj-chat-claude"
    assert event["status"] == "success"
    assert event["stream"] is True
    assert event["latency_ms"] >= 0
    assert "ttfb_ms" in event
    # No prompt content in usage events, ever.
    assert "hi" not in str(event)


def test_missing_user_header_attributed_to_unknown(monkeypatch):
    with _client_with_handler(monkeypatch, _success_handler) as client:
        assert _chat(client).status_code == 200
        docs = client.telemetry_docs

    assert _usage_docs(docs)[0]["user"] == "unknown"


def test_non_streaming_success_emits_usage_event(monkeypatch):
    with _client_with_handler(monkeypatch, _success_handler) as client:
        assert _chat(client, stream=False).status_code == 200
        docs = client.telemetry_docs

    event = _usage_docs(docs)[0]
    assert event["status"] == "success"
    assert event["stream"] is False


def test_upstream_error_emits_error_event(monkeypatch):
    def failing(request):
        return httpx.Response(500, text="kaboom")

    with _client_with_handler(monkeypatch, failing) as client:
        assert _chat(client).status_code == 500
        docs = client.telemetry_docs

    assert _usage_docs(docs)[0]["status"] == "upstream_error"


def test_unknown_model_emits_client_error_event(monkeypatch):
    with _client_with_handler(monkeypatch, _success_handler) as client:
        assert _chat(client, model="bogus").status_code == 400
        docs = client.telemetry_docs

    event = _usage_docs(docs)[0]
    assert event["status"] == "client_error"
    assert event["model_alias"] == "bogus"


def test_no_capture_doc_when_capture_disabled(monkeypatch):
    with _client_with_handler(monkeypatch, _success_handler) as client:
        assert _chat(client).status_code == 200
        docs = client.telemetry_docs

    assert _capture_docs(docs) == []


def test_capture_doc_written_when_enabled(monkeypatch):
    from app import main

    monkeypatch.setattr(main.settings, "capture_llm_traffic", True)
    with _client_with_handler(monkeypatch, _success_handler) as client:
        assert _chat(client).status_code == 200
        docs = client.telemetry_docs

    captures = _capture_docs(docs)
    assert len(captures) == 1
    doc = captures[0]
    assert "hi" in doc["request_text"]
    assert doc["response_text"] == "Hi there"
    assert doc["message_count"] == 1


def test_telemetry_write_failure_does_not_break_completion(monkeypatch):
    def handler(request: httpx.Request) -> httpx.Response:
        if str(request.url).rstrip("/").endswith("/_doc"):
            return httpx.Response(503, text="es unavailable")
        return _success_handler(request)

    # Bypass the harness's _doc interception by using the raw handler: the
    # harness only diverts _doc URLs before calling `handler`, so use a
    # custom context that doesn't intercept.
    from contextlib import contextmanager

    from starlette.testclient import TestClient

    from app import main

    @contextmanager
    def raw_client():
        real = httpx.AsyncClient

        def fake(*args, **kwargs):
            kwargs["transport"] = httpx.MockTransport(handler)
            return real(*args, **kwargs)

        monkeypatch.setattr(main.httpx, "AsyncClient", fake)
        with TestClient(main.app) as tc:
            yield tc

    with raw_client() as client:
        response = _chat(client)
        assert response.status_code == 200
        assert "Hi there" in response.text
