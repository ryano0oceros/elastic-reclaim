import json
import logging
import secrets
import time
from contextlib import asynccontextmanager

import httpx
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app import telemetry
from app.config import settings
from app.schemas import ChatCompletionRequest
from app.translator import (
    collect_non_streaming_response,
    stream_openai_chunks,
    to_elastic_payload,
)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("eis-proxy")

# Upstream error text is echoed back to callers and written to CloudWatch;
# cap it so a large or noisy upstream body can't bloat logs or responses.
_MAX_UPSTREAM_ERROR_CHARS = 500

_client: httpx.AsyncClient | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _client
    _client = httpx.AsyncClient(timeout=settings.request_timeout_seconds)
    if not settings.require_auth:
        logger.warning(
            "Running with ALLOW_UNAUTHENTICATED=true - every caller that can "
            "reach this port can spend your Elastic inference budget."
        )
    try:
        yield
    finally:
        await telemetry.drain()
        await _client.aclose()


app = FastAPI(title="OpenAI-to-EIS Proxy", lifespan=lifespan)

# auto_error=False so a missing header produces our own 401 (with a
# WWW-Authenticate challenge) rather than FastAPI's default 403.
_bearer = HTTPBearer(auto_error=False)


async def require_client_auth(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
) -> None:
    """Authenticate the *inbound* caller (OpenCode), which is separate from the
    Elastic API key this proxy uses for its own upstream calls."""
    if not settings.require_auth:
        return

    presented = credentials.credentials if credentials else ""
    # compare_digest avoids leaking the key one byte at a time via timing.
    # settings.proxy_api_key is guaranteed non-None here: config.py refuses to
    # start when require_auth is on and the key is unset.
    if not secrets.compare_digest(presented, settings.proxy_api_key or ""):
        raise HTTPException(
            status_code=401,
            detail="Invalid or missing bearer token.",
            headers={"WWW-Authenticate": "Bearer"},
        )


@app.middleware("http")
async def limit_request_body(request: Request, call_next):
    """Reject oversized bodies up front.

    Content-Length is only a hint (a chunked request omits it), so this is a
    cheap first gate; Starlette still streams the body into memory afterwards.
    Put a proxy/ALB body limit in front for a hard guarantee.
    """
    content_length = request.headers.get("content-length")
    if content_length is not None:
        try:
            if int(content_length) > settings.max_request_bytes:
                return JSONResponse(
                    {"detail": "Request body too large."}, status_code=413
                )
        except ValueError:
            return JSONResponse(
                {"detail": "Invalid Content-Length header."}, status_code=400
            )
    return await call_next(request)


def _resolve_inference_id(model: str | None) -> str:
    if model is None or model not in settings.eis_model_map:
        available = ", ".join(sorted(settings.eis_model_map)) or "(none configured)"
        raise HTTPException(
            status_code=400,
            detail=f"Unknown model {model!r}. Available models: {available}",
        )
    return settings.eis_model_map[model]


def _elastic_url(inference_id: str) -> str:
    base = settings.eis_endpoint_url.rstrip("/")
    return f"{base}/_inference/chat_completion/{inference_id}/_stream"


def _elastic_headers() -> dict[str, str]:
    return {
        "Authorization": f"ApiKey {settings.elastic_api_key}",
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
    }


@app.get("/health")
async def health() -> dict:
    """Unauthenticated liveness probe - deliberately free of any detail about
    the upstream project (endpoint URL, inference ids) that would help someone
    who has merely found this port. Use /v1/models, which is authenticated, to
    see the configured models."""
    return {"status": "ok"}


@app.get("/v1/models", dependencies=[Depends(require_client_auth)])
async def list_models() -> dict:
    """OpenAI-compatible model listing, for clients that discover models
    this way instead of (or in addition to) static config."""
    created = int(time.time())
    return {
        "object": "list",
        "data": [
            {
                "id": alias,
                "object": "model",
                "created": created,
                "owned_by": "eis-proxy",
            }
            for alias in sorted(settings.eis_model_map)
        ],
    }


@app.post("/v1/chat/completions", dependencies=[Depends(require_client_auth)])
async def chat_completions(request: ChatCompletionRequest, http_request: Request):
    if _client is None:
        raise HTTPException(status_code=503, detail="proxy not initialized")

    # Self-reported identity for per-user usage attribution (see the SSO
    # module stub for the later-phase authenticated replacement). Missing or
    # spoofed headers only mislabel analytics - auth is the bearer token.
    user = http_request.headers.get("x-eis-user", "unknown")

    payload = to_elastic_payload(request)
    collector = telemetry.UsageCollector(
        user=user,
        model_alias=request.model,
        inference_id=settings.eis_model_map.get(request.model or ""),
        stream=request.stream,
        capture=settings.capture_llm_traffic,
        request_messages=payload.get("messages"),
        request_bytes=len(json.dumps(payload)),
        pricing=settings.eis_model_pricing.get(request.model or ""),
    )

    try:
        inference_id = _resolve_inference_id(request.model)
    except HTTPException:
        telemetry.emit(_client, settings, collector, status="client_error")
        raise

    url = _elastic_url(inference_id)

    # Send with stream=True and inspect the status BEFORE handing anything to
    # StreamingResponse. Starlette commits 200 OK to the wire as soon as it
    # begins iterating a streaming body, so raising from inside the generator
    # is too late: the client would see a successful, empty stream instead of
    # the upstream error (a revoked Elastic key would look like "the model
    # said nothing"). Checking here keeps upstream failures fail-closed.
    upstream_request = _client.build_request(
        "POST", url, json=payload, headers=_elastic_headers()
    )
    response = await _client.send(upstream_request, stream=True)

    if response.status_code >= 400:
        telemetry.emit(_client, settings, collector, status="upstream_error")
        await _raise_for_upstream_error(response, payload)

    if request.stream:
        return StreamingResponse(
            _iter_upstream(response, collector),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-cache", "Connection": "keep-alive"},
        )

    try:
        chunks: list[dict] = []
        async for sse_bytes in stream_openai_chunks(
            response.aiter_lines(), observe=collector.observe
        ):
            text = sse_bytes.decode()
            if text.startswith("data: ") and "[DONE]" not in text:
                chunks.append(json.loads(text[len("data: ") :]))
    finally:
        await response.aclose()

    telemetry.emit(_client, settings, collector, status="success")
    return JSONResponse(collect_non_streaming_response(chunks))


async def _iter_upstream(
    response: httpx.Response, collector: telemetry.UsageCollector
):
    """Relay an already-validated upstream response, always closing it and
    emitting the usage event once the stream ends (however it ends)."""
    try:
        async for sse_bytes in stream_openai_chunks(
            response.aiter_lines(), observe=collector.observe
        ):
            yield sse_bytes
    finally:
        await response.aclose()
        telemetry.emit(_client, settings, collector, status="success")


def _payload_shape(payload: dict) -> str:
    """Summarize a request by structure only - roles and field names, never
    message text. Elastic rejects the whole request when a message carries a
    field it doesn't know, and the error names only the field ("failed to
    parse field [messages]"), so the offending *keys* are what's diagnostic.
    Deliberately excludes content so prompts stay out of the logs."""
    parts = []
    for message in payload.get("messages", []):
        keys = ",".join(sorted(k for k in message if k != "content"))
        content = message.get("content")
        shape = (
            f"content[{len(content)}]"
            if isinstance(content, list)
            else type(content).__name__
        )
        parts.append(f"{message.get('role')}({shape}{':' + keys if keys else ''})")
    top = ",".join(sorted(k for k in payload if k != "messages"))
    return f"messages=[{' '.join(parts)}] other=[{top}]"


async def _raise_for_upstream_error(
    response: httpx.Response, payload: dict | None = None
) -> None:
    body = await response.aread()
    await response.aclose()
    detail = body.decode(errors="ignore")[:_MAX_UPSTREAM_ERROR_CHARS]
    logger.error("EIS upstream error %s: %s", response.status_code, detail)
    if 400 <= response.status_code < 500 and payload is not None:
        logger.error("Rejected request shape: %s", _payload_shape(payload))

    # Don't relay upstream 401/403 as-is: to an OpenAI-compatible client that
    # reads as "your token is bad", when the real cause is the proxy's own
    # Elastic credential. It would also invite probing of the upstream's auth
    # state. Surface it as a server-side fault and keep the detail in the logs.
    if response.status_code in (401, 403):
        raise HTTPException(
            status_code=502,
            detail="Upstream authentication to Elastic failed; check the proxy's credentials.",
        )

    raise HTTPException(
        status_code=response.status_code,
        detail=f"EIS upstream error: {detail}",
    )
