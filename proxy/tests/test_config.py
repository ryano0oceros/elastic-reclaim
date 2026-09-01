import json

import pytest

from app.config import Settings, validate_startup

BASE_ENV = {
    "ELASTIC_API_KEY": "test-key",
    "EIS_ENDPOINT_URL": "https://example-project.es.example.com",
    "EIS_MODEL_MAP": json.dumps({"claude": "proj-chat-claude"}),
}


def _env(monkeypatch, **overrides):
    for key in (*BASE_ENV, "PROXY_API_KEY", "ALLOW_UNAUTHENTICATED"):
        monkeypatch.delenv(key, raising=False)
    for key, value in {**BASE_ENV, **overrides}.items():
        monkeypatch.setenv(key, value)


def test_requires_auth_by_default(monkeypatch):
    _env(monkeypatch)
    assert Settings().require_auth is True


def test_model_map_parsed_from_json_env_var(monkeypatch):
    _env(monkeypatch, PROXY_API_KEY="tok")
    assert Settings().eis_model_map == {"claude": "proj-chat-claude"}


def test_unauthenticated_requires_explicit_opt_in(monkeypatch):
    """Omitting PROXY_API_KEY must never silently disable auth."""
    _env(monkeypatch, ALLOW_UNAUTHENTICATED="true")
    settings = Settings()
    assert settings.require_auth is False
    assert settings.proxy_api_key is None
    validate_startup(settings)  # explicit opt-in is allowed to boot


def test_startup_refuses_auth_enabled_without_a_key(monkeypatch):
    """The dangerous default - auth on, no key - must fail closed at boot
    rather than serving an open proxy."""
    _env(monkeypatch)
    with pytest.raises(RuntimeError, match="PROXY_API_KEY"):
        validate_startup(Settings())


def test_startup_accepts_a_configured_key(monkeypatch):
    _env(monkeypatch, PROXY_API_KEY="tok")
    validate_startup(Settings())
