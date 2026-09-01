"""Per-request cost attribution."""

from app.telemetry import UsageCollector

RATES = {"input_per_1m": 4.50, "output_per_1m": 21.00}


def _collector(pricing=RATES, usage=None):
    c = UsageCollector(
        user="alice", model_alias="claude", inference_id="ep", stream=True,
        capture=False, pricing=pricing,
    )
    if usage is not None:
        c.usage = usage
    return c


def test_cost_computed_from_configured_rates():
    c = _collector(usage={"prompt_tokens": 1_000_000, "completion_tokens": 100_000})
    e = c.usage_event("success")
    assert e["input_cost"] == 4.50
    assert e["output_cost"] == 2.10
    assert e["cost"] == 6.60


def test_realistic_small_request_keeps_precision():
    c = _collector(usage={"prompt_tokens": 1200, "completion_tokens": 300})
    e = c.usage_event("success")
    # 1200/1e6*4.50 = 0.0054 ; 300/1e6*21 = 0.0063
    assert round(e["cost"], 6) == 0.0117


def test_unpriced_model_omits_cost_rather_than_writing_zero():
    """A missing rate must not look like free usage in a SUM aggregation."""
    e = _collector(pricing=None, usage={"prompt_tokens": 500, "completion_tokens": 50}).usage_event("success")
    assert "cost" not in e and "input_cost" not in e and "output_cost" not in e
    assert e["prompt_tokens"] == 500  # tokens still recorded


def test_no_token_counts_omits_cost():
    """Client errors never reach the model, so there is nothing to charge."""
    e = _collector(usage={}).usage_event("client_error")
    assert "cost" not in e


def test_partial_usage_counts_only_what_is_reported():
    e = _collector(usage={"prompt_tokens": 1_000_000}).usage_event("success")
    assert e["input_cost"] == 4.50
    assert e["output_cost"] == 0.0
    assert e["cost"] == 4.50


# --- prompt-size tiering ---------------------------------------------------
# Gemini 3.1 Pro steps up at 200K prompt tokens, GPT-5.4 at 272K; above the
# threshold BOTH input and output rates increase (see
# docs/reference/eis-pricing-2026-09-01.md).

GEMINI = {
    "input_per_1m": 3.00, "output_per_1m": 16.80,
    "tier_threshold_tokens": 200_000,
    "tier_input_per_1m": 6.00, "tier_output_per_1m": 25.20,
}


def test_below_threshold_uses_standard_rates():
    e = _collector(GEMINI, {"prompt_tokens": 199_999, "completion_tokens": 1_000}).usage_event("success")
    assert e["price_tier"] == "standard"
    assert round(e["input_cost"], 6) == round(199_999 / 1e6 * 3.00, 6)
    assert round(e["output_cost"], 6) == round(1_000 / 1e6 * 16.80, 6)


def test_above_threshold_escalates_both_rates():
    e = _collector(GEMINI, {"prompt_tokens": 200_001, "completion_tokens": 1_000}).usage_event("success")
    assert e["price_tier"] == "high"
    assert round(e["input_cost"], 6) == round(200_001 / 1e6 * 6.00, 6)
    # output rate steps up too, even though output volume is unchanged
    assert round(e["output_cost"], 6) == round(1_000 / 1e6 * 25.20, 6)


def test_exactly_at_threshold_is_standard():
    """Elastic's table reads '<=200K', so the boundary is the cheaper tier."""
    e = _collector(GEMINI, {"prompt_tokens": 200_000, "completion_tokens": 10}).usage_event("success")
    assert e["price_tier"] == "standard"


def test_untiered_model_never_escalates():
    e = _collector(RATES, {"prompt_tokens": 5_000_000, "completion_tokens": 10}).usage_event("success")
    assert e["price_tier"] == "standard"


def test_null_optional_rates_are_treated_as_absent():
    """Terraform emits JSON null for unset optional() fields; a null tier
    must not be read as a 0.0 rate (which would make everything free)."""
    pricing = {
        "input_per_1m": 3.00, "output_per_1m": 14.00,
        "tier_threshold_tokens": None,
        "tier_input_per_1m": None, "tier_output_per_1m": None,
    }
    e = _collector(pricing, {"prompt_tokens": 1_000_000, "completion_tokens": 0}).usage_event("success")
    assert e["price_tier"] == "standard"
    assert e["input_cost"] == 3.00


# --- readable prompt column ------------------------------------------------

from app.telemetry import UsageCollector as _UC  # noqa: E402

_latest = _UC._latest_user_prompt


def test_extracts_last_user_message_from_agentic_conversation():
    """The real shape: huge system prompt, an earlier question, tool traffic,
    then the actual current question last."""
    convo = [
        {"role": "system", "content": "You are OpenCode..." + "x" * 5000},
        {"role": "user", "content": "analyze and describe what this repository accomplishes"},
        {"role": "assistant", "content": "", "tool_calls": [{"id": "t1"}]},
        {"role": "tool", "content": "total 40 drwxr-xr-x ...", "tool_call_id": "t1"},
        {"role": "assistant", "content": "Here's the analysis..."},
        {"role": "user", "content": "Provide a short write-up to describe what I've built to my manager"},
    ]
    assert _latest(convo) == "Provide a short write-up to describe what I've built to my manager"


def test_tool_output_is_never_mistaken_for_a_user_prompt():
    convo = [
        {"role": "user", "content": "the real question"},
        {"role": "tool", "content": "some command output", "tool_call_id": "t1"},
    ]
    assert _latest(convo) == "the real question"


def test_extracts_text_parts_from_multimodal_content():
    convo = [{"role": "user", "content": [
        {"type": "text", "text": "what is in this image?"},
        {"type": "image_url", "image_url": {"url": "data:..."}},
    ]}]
    assert _latest(convo) == "what is in this image?"


def test_long_prompt_is_truncated():
    convo = [{"role": "user", "content": "y" * 9000}]
    assert len(_latest(convo)) == 2000


def test_no_user_message_yields_none():
    assert _latest([{"role": "system", "content": "sys"}]) is None
    assert _latest(None) is None


def test_conversation_renders_as_readable_transcript():
    convo = [
        {"role": "system", "content": "You are OpenCode..."},
        {"role": "user", "content": "analyze this repo"},
        {"role": "assistant", "content": "", "tool_calls": [
            {"id": "t1", "type": "function", "function": {"name": "bash", "arguments": "{\"cmd\":\"ls\"}"}}]},
        {"role": "tool", "content": "total 40", "tool_call_id": "t1"},
        {"role": "user", "content": "write it up for my manager"},
    ]
    out = _UC._readable_conversation(convo)
    lines = out.split("\n")
    # system prompt is excluded - it is identical boilerplate on every row
    assert not any(l.startswith("system:") for l in lines)
    assert lines[0] == "user: analyze this repo"
    # tool call summarized by name, not dumped as argument JSON
    assert lines[1] == "assistant: [calls: bash]"
    assert lines[2] == "tool: total 40"
    assert lines[3] == "user: write it up for my manager"


def test_long_turn_truncated_but_later_turns_survive():
    convo = [
        {"role": "tool", "content": "z" * 5000},
        {"role": "user", "content": "the question after the huge tool result"},
    ]
    out = _UC._readable_conversation(convo)
    assert "the question after the huge tool result" in out
    assert "…" in out
