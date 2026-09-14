"""Agent memory: recall over the assistant's own past exchanges.

Exposed to OpenCode as an MCP tool, so the model decides when its own
history is relevant rather than every prompt paying to carry it. Retrieval
is semantic (`semantic_text` + ELSER on EIS), so a question phrased nothing
like the original still finds it - "credential rotation for API access"
matches "how do I rotate the bearer token".

The proxy is the natural home for this: it already holds the Elasticsearch
credential and already sees every exchange, so developers get recall without
any Elastic access of their own.
"""

import logging
from typing import Any

import httpx
from mcp.server.mcpserver import Context, MCPServer
from mcp.server.transport_security import TransportSecuritySettings

from app.config import Settings

logger = logging.getLogger("eis-proxy.memory")

MAX_RESULTS = 20


async def search_memory(
    client: httpx.AsyncClient,
    settings: Settings,
    *,
    user: str,
    query: str,
    limit: int,
) -> list[dict[str, Any]]:
    """Semantic search over one user's past exchanges, newest-first on ties."""
    url = f"{settings.eis_endpoint_url.rstrip('/')}/{settings.memory_data_stream}/_search"
    body = {
        "size": max(1, min(limit, MAX_RESULTS)),
        "query": {
            "bool": {
                "must": [{"semantic": {"field": "memo", "query": query}}],
                # Scoped to the caller. Recall is for your own history; one
                # developer's prompts are not another's to browse.
                "filter": [{"term": {"user": user}}],
            }
        },
        # One question produces many agent-loop requests; collapse so recall
        # returns distinct questions rather than the same one repeatedly.
        "collapse": {"field": "prompt_hash"},
        "_source": ["@timestamp", "topic", "prompt", "response", "model_alias"],
    }
    response = await client.post(
        url, json=body, headers={"Authorization": f"ApiKey {settings.elastic_api_key}"}
    )
    if response.status_code >= 300:
        detail = (await response.aread()).decode(errors="ignore")[:300]
        logger.warning("memory search failed: %s %s", response.status_code, detail)
        raise RuntimeError(f"memory search failed ({response.status_code})")
    hits = response.json().get("hits", {}).get("hits", [])
    return [
        {
            "when": h["_source"].get("@timestamp", "")[:19],
            "score": round(h.get("_score") or 0, 3),
            "model": h["_source"].get("model_alias"),
            # Surface the topic when the question itself is a follow-up,
            # so the row is intelligible without the rest of the thread.
            "topic": h["_source"].get("topic"),
            "you_asked": h["_source"].get("prompt"),
            "answer_excerpt": (h["_source"].get("response") or "")[:600],
        }
        for h in hits
    ]


def build_mcp_server(get_client, settings: Settings) -> MCPServer:
    """MCP server exposing recall. `get_client` defers to the app's shared
    httpx client, which only exists once the FastAPI lifespan has started."""
    mcp = MCPServer(
        name="eis-agent-memory",
        instructions=(
            "Searches this developer's own past conversations with the "
            "assistant. Use it when they refer to earlier work ('what did we "
            "decide', 'like last time', 'the approach I used before'), or "
            "before re-deriving something that sounds previously solved."
        ),
    )

    @mcp.tool(
        name="recall_past_work",
        description=(
            "Semantic search over your past conversations with this assistant. "
            "Returns prior questions and answer excerpts, most relevant first. "
            "Query in natural language describing the topic, not keywords."
        ),
    )
    async def recall_past_work(ctx: Context, query: str, limit: int = 5) -> str:
        # Client-supplied, exactly like X-EIS-User on the completions path -
        # it selects whose history to search, it does not authenticate. The
        # bearer token on the MCP endpoint is what authorizes the call.
        headers = ctx.headers or {}
        user = headers.get("x-eis-user", "unknown")
        client = get_client()
        if client is None:
            return "Memory is unavailable: the proxy is still starting up."
        try:
            results = await search_memory(
                client, settings, user=user, query=query, limit=limit
            )
        except Exception:
            logger.warning("recall_past_work failed", exc_info=True)
            return "Memory search failed; continue without it."
        if not results:
            return f"No past conversations found for {user!r} matching that topic."
        lines = [f"{len(results)} past exchange(s) for {user!r}:\n"]
        for r in results:
            topic = r.get("topic")
            context = (
                f"  In a conversation about: {topic}\n"
                if topic and topic != r["you_asked"]
                else ""
            )
            lines.append(
                f"[{r['when']} · {r['model']} · score {r['score']}]\n"
                f"{context}"
                f"  You asked: {r['you_asked']}\n"
                f"  Answer: {r['answer_excerpt']}\n"
            )
        return "\n".join(lines)

    return mcp


def build_mcp_asgi_app(get_client, settings: Settings):
    """ASGI app for the MCP endpoint, ready to mount at /mcp.

    Owns two transport details that are easy to get wrong:

    - `streamable_http_path="/"`, because the SDK defaults its route to
      "/mcp" and nesting that under our mount would serve /mcp/mcp.
    - DNS-rebinding protection. It defaults ON with an *empty* host
      allowlist, which rejects every Host header - including the load
      balancer's, so every real request 400s. That protection exists to stop
      a malicious web page reaching an MCP server bound to localhost; this
      is a remote service behind an ALB where the bearer token is the access
      control. Disabled deliberately rather than left silently broken, and
      re-enabled automatically if you set mcp_allowed_hosts for Host pinning
      as defence in depth.
    """
    return build_mcp_server(get_client, settings).streamable_http_app(
        streamable_http_path="/",
        transport_security=TransportSecuritySettings(
            enable_dns_rebinding_protection=bool(settings.mcp_allowed_hosts),
            allowed_hosts=list(settings.mcp_allowed_hosts),
        ),
    )
