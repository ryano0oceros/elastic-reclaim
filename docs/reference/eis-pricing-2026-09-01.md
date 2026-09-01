# Elastic Inference Service pricing — captured 2026-09-01

**Point-in-time snapshot.** Copied from the Elastic Cloud pricing table
(<https://cloud.elastic.co/cloud-pricing-table?productType=serverless>) on
**2026-09-01**. That table is behind the Cloud console and is not
machine-readable, so this file is the repo's reference copy — it does not
update itself.

All prices are **USD per 1M tokens**. 1 ECU = $1.00 nominal.
List prices; your contract may differ.

> **Re-check before trusting cost figures.** When you refresh this file, also
> update `model_pricing` in `terraform/terraform.tfvars` (or the default in
> `terraform/variables.tf`) and note the new capture date here.

## How this maps to our configuration

Only *Chat Completion* rows matter for this proxy. Three concepts appear in
the table that the configuration has to account for:

| Table concept | Handled? |
|---|---|
| **Input** / **Output** rates | Yes — `input_per_1m` / `output_per_1m` |
| **Token tier** (e.g. `<=200K` vs `>200K`) | Yes — `tier_threshold_tokens` + `tier_*_per_1m` |
| **Cache Read** / **Cache Write** rates | **No** — see below |

### Why cache rates are not modelled

Cache reads are dramatically cheaper (Claude 5 Sonnet: **$0.30** cache read
vs **$3.00** input — 10x). Two reasons they are not used here:

1. **EIS does not report them.** The streaming `usage` object returns only
   `prompt_tokens`, `completion_tokens`, `total_tokens` — verified against a
   live response. There is no cached-token count to bill differently.
2. **We disable caching upstream anyway.** The proxy strips `cache_control`
   from messages because Elastic's `UnifiedCompletionRequest` rejects unknown
   message fields (see README "Protocol compatibility notes"). OpenCode sends
   that hint on its system prompt; stripping it means no prompt caching
   occurs, so every input token is charged at the full input rate.

**Cost implication:** for a coding agent that resends a large context every
turn, input tokens dominate and caching would be the single biggest saving
available. Costing them at the full input rate is *accurate today*, but the
underlying spend is higher than it needs to be. Recovering that requires
Elastic to accept a caching directive on the unified API.

## Current model catalog rates

The three models wired into `eis_models`:

| Alias | EIS model | Input | Output | Tier |
|---|---|---|---|---|
| `claude` | Claude 5 Sonnet | $3.00 | $14.00 | none |
| `gemini` | Gemini 3.1 Pro | $3.00 (≤200K) / $6.00 (>200K) | $16.80 (≤200K) / $25.20 (>200K) | 200K |
| `gpt` | GPT-5.4 | $3.75 (≤272K) / $7.50 (>272K) | $21.00 (≤272K) / $31.50 (>272K) | 272K |

Note the earlier placeholder of $4.50/$21 for all three was the **General
Purpose LLM v1/v2** rate (the "Other" provider section), which is what the
default EIS endpoint uses — not the rate for any of these named models.

---

## Full table

### Elastic

| Model | Token tier | Price (USD / 1M) |
|---|---|---|
| ELSER - Sparse Text Embedding | | 0.0800 |
| Jina Clip v2 - Dense Embedding | | 0.1200 |
| Jina Embeddings v3 - Dense Text Embedding | | 0.1200 |
| Jina Embeddings v5 - Nano - Dense Text Embedding | | 0.0600 |
| Jina Embeddings v5 - Small - Dense Text Embedding | | 0.1000 |
| Jina Embeddings v5 Omni Nano - Dense Embeddings | | 0.1200 |
| Jina Embeddings v5 Omni Small - Dense Embeddings | | 0.1800 |
| Jina Reranker m0 - Rerank | | 0.0800 |
| Jina Reranker v2 Base Multilingual - Rerank | | 0.0800 |
| Jina Reranker v3 - Rerank | | 0.0800 |
| Jina Reranker v3.5 - Rerank | | 0.0800 |

### Anthropic

| Model | Token tier | Price (USD / 1M) |
|---|---|---|
| Claude 3.7 Sonnet - Input | | 4.5000 |
| Claude 3.7 Sonnet - Output | | 21.0000 |
| Claude 4.5 Haiku - Cache Read | | 0.1500 |
| Claude 4.5 Haiku - Cache Write (1h) | | 3.0000 |
| Claude 4.5 Haiku - Cache Write (5m) | | 1.8750 |
| Claude 4.5 Haiku - Input | | 1.5000 |
| Claude 4.5 Haiku - Output | | 7.0000 |
| Claude 4.5 Opus - Cache Read | | 0.7500 |
| Claude 4.5 Opus - Cache Write (1h) | | 15.0000 |
| Claude 4.5 Opus - Cache Write (5m) | | 9.3750 |
| Claude 4.5 Opus - Input | | 7.5000 |
| Claude 4.5 Opus - Output | | 35.0000 |
| Claude 4.5 Sonnet - Cache Read | <=200k | 0.4500 |
| Claude 4.5 Sonnet - Cache Read | >200k | 0.9000 |
| Claude 4.5 Sonnet - Cache Write (1h) | <=200k | 9.0000 |
| Claude 4.5 Sonnet - Cache Write (1h) | >200k | 18.0000 |
| Claude 4.5 Sonnet - Cache Write (5m) | <=200k | 5.6250 |
| Claude 4.5 Sonnet - Cache Write (5m) | >200k | 11.2500 |
| Claude 4.5 Sonnet - Input | <=200K | 4.5000 |
| Claude 4.5 Sonnet - Input | >200K | 9.0000 |
| Claude 4.5 Sonnet - Output | <=200K | 21.0000 |
| Claude 4.5 Sonnet - Output | >200K | 31.5000 |
| Claude 4.6 Opus - Cache Read | | 0.7500 |
| Claude 4.6 Opus - Cache Write (1h) | | 15.0000 |
| Claude 4.6 Opus - Cache Write (5m) | | 9.3750 |
| Claude 4.6 Opus - Input | | 7.5000 |
| Claude 4.6 Opus - Output | | 35.0000 |
| Claude 4.6 Sonnet - Cache Read | | 0.4500 |
| Claude 4.6 Sonnet - Cache Write (1h) | | 9.0000 |
| Claude 4.6 Sonnet - Cache Write (5m) | | 5.6250 |
| Claude 4.6 Sonnet - Input | | 4.5000 |
| Claude 4.6 Sonnet - Output | | 21.0000 |
| Claude 4.7 Opus - Cache Read | | 0.7500 |
| Claude 4.7 Opus - Cache Write (1h) | | 15.0000 |
| Claude 4.7 Opus - Cache Write (5m) | | 9.3750 |
| Claude 4.7 Opus - Input | | 7.5000 |
| Claude 4.7 Opus - Output | | 35.0000 |
| Claude 4.8 Opus - Cache Read | | 0.7500 |
| Claude 4.8 Opus - Cache Write (1h) | | 15.0000 |
| Claude 4.8 Opus - Cache Write (5m) | | 9.3750 |
| Claude 4.8 Opus - Input | | 7.5000 |
| Claude 4.8 Opus - Output | | 35.0000 |
| Claude 5 Opus - Cache Read | | 0.7500 |
| Claude 5 Opus - Cache Write (1h) | | 15.0000 |
| Claude 5 Opus - Cache Write (5m) | | 9.3750 |
| Claude 5 Opus - Input | | 7.5000 |
| Claude 5 Opus - Output | | 35.0000 |
| **Claude 5 Sonnet - Cache Read** | | **0.3000** |
| **Claude 5 Sonnet - Cache Write (1h)** | | **6.0000** |
| **Claude 5 Sonnet - Cache Write (5m)** | | **3.7500** |
| **Claude 5 Sonnet - Input** | | **3.0000** |
| **Claude 5 Sonnet - Output** | | **14.0000** |

### Google

| Model | Token tier | Price (USD / 1M) |
|---|---|---|
| Gemini 2.5 Flash - Cache Read | | 0.0450 |
| Gemini 2.5 Flash - Input | | 0.4500 |
| Gemini 2.5 Flash - Output | | 3.5000 |
| Gemini 2.5 Flash Lite - Cache Read | | 0.0150 |
| Gemini 2.5 Flash Lite - Input | | 0.1500 |
| Gemini 2.5 Flash Lite - Output | | 0.5600 |
| Gemini 2.5 Pro - Cache Read | <=200k | 0.1875 |
| Gemini 2.5 Pro - Cache Read | >200k | 0.3750 |
| Gemini 2.5 Pro - Input | <=200K | 1.8750 |
| Gemini 2.5 Pro - Input | >200K | 3.7500 |
| Gemini 2.5 Pro - Output | <=200K | 14.0000 |
| Gemini 2.5 Pro - Output | >200K | 21.0000 |
| Gemini 3 Pro - Input | | 3.0000 |
| Gemini 3 Pro - Output | | 16.8000 |
| Gemini 3.0 Flash - Cache Read | | 0.0750 |
| Gemini 3.0 Flash - Input | | 0.7500 |
| Gemini 3.0 Flash - Output | | 4.2000 |
| Gemini 3.1 Flash Lite - Cache Read | | 0.0375 |
| Gemini 3.1 Flash Lite - Input | | 0.3750 |
| Gemini 3.1 Flash Lite - Output | | 2.1000 |
| **Gemini 3.1 Pro - Cache Read** | <=200k | **0.3000** |
| **Gemini 3.1 Pro - Cache Read** | >200k | **0.6000** |
| **Gemini 3.1 Pro - Input** | <=200K | **3.0000** |
| **Gemini 3.1 Pro - Input** | >200K | **6.0000** |
| **Gemini 3.1 Pro - Output** | <=200K | **16.8000** |
| **Gemini 3.1 Pro - Output** | >200K | **25.2000** |
| Gemini 3.5 Flash - Cache Read | | 0.2250 |
| Gemini 3.5 Flash - Input | | 2.2500 |
| Gemini 3.5 Flash - Output | | 12.6000 |
| Gemini 3.5 Flash Lite - Cache Read | | 0.0450 |
| Gemini 3.5 Flash Lite - Input | | 0.4500 |
| Gemini 3.5 Flash Lite - Output | | 3.5000 |
| Gemini 3.6 Flash - Cache Read | | 0.2250 |
| Gemini 3.6 Flash - Input | | 1.1250 |
| Gemini 3.6 Flash - Output | | 5.2500 |
| Gemini 3.7 Flash - Cache Read | | 0.2250 |
| Gemini 3.7 Flash - Input | | 2.2500 |
| Gemini 3.7 Flash - Output | | 10.5000 |
| Gemini Embedding 001 - Dense Text Embedding | | 0.2250 |
| Gemini Embedding 2 - Audio | | 9.7500 |
| Gemini Embedding 2 - Document | | 0.6750 |
| Gemini Embedding 2 - Image | | 0.6750 |
| Gemini Embedding 2 - Text | | 0.3000 |
| Gemini Embedding 2 - Video | | 18.0000 |

### Microsoft

| Model | Token tier | Price (USD / 1M) |
|---|---|---|
| Multilingual E5 Large - Dense Text Embedding | | 0.0150 |

### OpenAI

| Model | Token tier | Price (USD / 1M) |
|---|---|---|
| GPT-4.1 - Input | | 3.0000 |
| GPT-4.1 - Output | | 11.2000 |
| GPT-4.1 Mini - Input | | 0.6000 |
| GPT-4.1 Mini - Output | | 2.2400 |
| GPT-5.2 - Cache Read | | 0.2625 |
| GPT-5.2 - Input | | 2.6250 |
| GPT-5.2 - Output | | 19.6000 |
| **GPT-5.4 - Cache Read** | <=272k | **0.3750** |
| **GPT-5.4 - Cache Read** | >272k | **0.7500** |
| **GPT-5.4 - Input** | <=272K | **3.7500** |
| **GPT-5.4 - Input** | >272K | **7.5000** |
| **GPT-5.4 - Output** | <=272K | **21.0000** |
| **GPT-5.4 - Output** | >272K | **31.5000** |
| GPT-5.4 Mini - Cache Read | | 0.1125 |
| GPT-5.4 Mini - Input | | 1.1250 |
| GPT-5.4 Mini - Output | | 6.3000 |
| GPT-5.4 Nano - Cache Read | | 0.0300 |
| GPT-5.4 Nano - Input | | 0.3000 |
| GPT-5.4 Nano - Output | | 1.7500 |
| GPT-5.4 Pro - Input | <=272K | 45.0000 |
| GPT-5.4 Pro - Input | >272K | 90.0000 |
| GPT-5.4 Pro - Output | <=272K | 252.0000 |
| GPT-5.4 Pro - Output | >272K | 378.0000 |
| GPT-5.5 - Cache Read | <=272k | 0.7500 |
| GPT-5.5 - Cache Read | >272k | 1.5000 |
| GPT-5.5 - Input | <=272K | 7.5000 |
| GPT-5.5 - Input | >272K | 15.0000 |
| GPT-5.5 - Output | <=272K | 42.0000 |
| GPT-5.5 - Output | >272K | 63.0000 |
| GPT-5.6 Luna - Cache Read | <=272k | 0.0300 |
| GPT-5.6 Luna - Cache Read | >272k | 0.0600 |
| GPT-5.6 Luna - Cache Write | <=272k | 0.3750 |
| GPT-5.6 Luna - Cache Write | >272k | 0.7500 |
| GPT-5.6 Luna - Input | <=272K | 0.3000 |
| GPT-5.6 Luna - Input | >272K | 0.6000 |
| GPT-5.6 Luna - Input | (untiered) | 1.5000 |
| GPT-5.6 Luna - Output | <=272K | 1.6800 |
| GPT-5.6 Luna - Output | >272K | 2.5200 |
| GPT-5.6 Luna - Output | (untiered) | 8.4000 |
| GPT-5.6 Sol - Cache Read | <=272k | 0.7500 |
| GPT-5.6 Sol - Cache Read | >272k | 1.5000 |
| GPT-5.6 Sol - Cache Write | <=272k | 9.3750 |
| GPT-5.6 Sol - Cache Write | >272k | 18.7500 |
| GPT-5.6 Sol - Input | <=272K | 7.5000 |
| GPT-5.6 Sol - Input | >272K | 15.0000 |
| GPT-5.6 Sol - Output | <=272K | 42.0000 |
| GPT-5.6 Sol - Output | >272K | 63.0000 |
| GPT-5.6 Terra - Cache Read | <=272k | 0.3000 |
| GPT-5.6 Terra - Cache Read | >272k | 0.6000 |
| GPT-5.6 Terra - Cache Write | <=272k | 3.7500 |
| GPT-5.6 Terra - Cache Write | >272k | 7.5000 |
| GPT-5.6 Terra - Input | <=272K | 3.0000 |
| GPT-5.6 Terra - Input | >272K | 6.0000 |
| GPT-5.6 Terra - Output | <=272K | 16.8000 |
| GPT-5.6 Terra - Output | >272K | 25.2000 |
| GPT-OSS 20B - Input | | 0.1050 |
| GPT-OSS 20B - Output | | 0.3500 |
| GPT-OSS-120B - Input | | 0.2250 |
| GPT-OSS-120B - Output | | 0.8400 |
| Text Embedding 003 Large | | 0.1950 |
| Text Embedding 003 Small | | 0.0300 |

### Other

Elastic's default/managed endpoints. This is the rate the placeholder
defaults used before the real table was captured.

| Model | Token tier | Price (USD / 1M) |
|---|---|---|
| General Purpose LLM v1 - Cache Read | | 0.4500 |
| General Purpose LLM v1 - Cache Write (1h) | | 9.0000 |
| General Purpose LLM v1 - Cache Write (5m) | | 5.6250 |
| General Purpose LLM v1 - Input | | 4.5000 |
| General Purpose LLM v1 - Output | | 21.0000 |
| General Purpose LLM v2 - Cache Read | | 0.4500 |
| General Purpose LLM v2 - Cache Write (1h) | | 9.0000 |
| General Purpose LLM v2 - Cache Write (5m) | | 5.6250 |
| General Purpose LLM v2 - Input | | 4.5000 |
| General Purpose LLM v2 - Output | | 21.0000 |

### Qwen

| Model | Token tier | Price (USD / 1M) |
|---|---|---|
| Qwen 3.8 2.4T A95B - Cache Read | | 0.3000 |
| Qwen 3.8 2.4T A95B - Input | | 3.0000 |
| Qwen 3.8 2.4T A95B - Output | | 8.4000 |
| Qwen3 Embedding 4B | | 0.0300 |
| Qwen3 Embedding 8B | | 0.0750 |

### Z.ai

| Model | Token tier | Price (USD / 1M) |
|---|---|---|
| GLM 5.2 - Cache Read | | 0.3900 |
| GLM 5.2 - Input | | 2.1000 |
| GLM 5.2 - Output | | 6.1600 |
| GLM 5.3 - Cache Read | | 0.3900 |
| GLM 5.3 - Input | | 2.1000 |
| GLM 5.3 - Output | | 6.1600 |
