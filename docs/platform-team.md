# Platform team guide

You own the Elastic organization and the AWS account. This guide covers
standing the stack up, operating it, onboarding developers, and tearing it
down. Developers never need this document - hand them
[developer-onboarding.md](developer-onboarding.md) instead.

## What you are running

```
Developer (OpenCode terminal / VS Code)
      │  OpenAI protocol + bearer token + X-EIS-User header
      ▼
ALB (stable hostname, HTTP:80) ──► ECS Fargate: FastAPI proxy
      │                                   │ usage + capture docs
      │ ApiKey (scoped)                   ▼
      ▼                          eis-proxy-usage / eis-proxy-captures
Elastic Serverless project ◄──── (same project - Kibana dashboards)
      │ EIS inference endpoints (one per model alias)
      ▼
Claude / Gemini / GPT
```

Every LLM token a developer consumes is billed through your Elastic
subscription via EIS - that is the point: committed spend gets used instead
of forfeited. The analytics data streams and dashboards also live in the
same project.

## Prerequisites

- Terraform >= 1.6, Docker, AWS CLI, `git`
- AWS credentials (`aws configure` or env vars) for the target account
- An Elastic Cloud API key that can create Serverless projects:
  <https://cloud.elastic.co/account/keys>
- Your Elastic organization id: <https://cloud.elastic.co/account/members>

## First deployment

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in ec_api_key, ec_organization_id
terraform init
terraform apply        # creates Elastic project, EIS endpoints, AWS infra, dashboards
cd ..
scripts/deploy.sh      # builds + pushes the proxy image, rolls ECS, smoke tests
```

The first `terraform apply` starts ECS tasks before any image exists - they
fail to pull until `deploy.sh` pushes one. Expected, self-heals.

`scripts/deploy.sh` is also the routine deploy path for any proxy code
change: unique image tag per commit (ECR is immutable), Terraform-tracked
rollout, waits for stability, smoke test through the ALB.

## Managing the model catalog

`eis_models` in [terraform/variables.tf](../terraform/variables.tf) maps a
short alias (what developers see in the picker) to an EIS `model_id`
([supported models](https://www.elastic.co/docs/explore-analyze/elastic-inference/eis-supported-models)):

```hcl
eis_models = {
  claude-opus   = "anthropic-claude-5-opus"     # flagship
  claude-sonnet = "anthropic-claude-5-sonnet"   # balanced (default)
  gemini-pro    = "google-gemini-3.1-pro"       # flagship
  gemini-flash  = "google-gemini-3.6-flash"     # fast
  gpt-sol       = "openai-gpt-5.6-sol"          # flagship
  gpt-terra     = "openai-gpt-5.6-terra"        # balanced
}
```

**Naming convention:** `<provider>-<that provider's tier name>`, with no
version number. Bumping to a newer model is then a one-line change here that
does not churn every developer's config; the exact model_id is still visible
in the picker. `opus` / `pro` / `sol` are the flagship tier, `sonnet` /
`flash` / `terra` the balanced everyday drivers.

**New developers default to `default_model_alias`** (`claude-sonnet`), set
explicitly rather than derived - alphabetical order would hand everyone
`claude-opus` at $7.50/$35 per 1M tokens.

**Not every priced model is available to you.** `google-gemini-3.7-flash`
appears in the pricing table but EIS rejects it for this organization with
`Not authorized to use this model` (it is also absent from the
supported-models docs). If `terraform apply` fails creating an inference
endpoint, that 403 is the likely cause - fall back to the newest version
that is authorized.

### Adding a model to the developer picker

Four steps; the whole thing is one `terraform apply` plus re-issuing configs.

**1. Confirm the model is available to you.** Pick a `model_id` from the
[EIS supported models list](https://www.elastic.co/docs/explore-analyze/elastic-inference/eis-supported-models).
Being in the pricing table is *not* sufficient - entitlement is separate.
Check before editing Terraform:

```bash
cd terraform
ES=$(terraform output -raw eis_endpoint_url)
# project credentials: terraform show -json | look up ec_elasticsearch_project.credentials
curl -u "$USER:$PASS" -X PUT "$ES/_inference/chat_completion/probe-tmp" \
  -H 'Content-Type: application/json' \
  -d '{"service":"elastic","service_settings":{"model_id":"<MODEL_ID>"}}'
curl -u "$USER:$PASS" -X DELETE "$ES/_inference/chat_completion/probe-tmp"
```

`403 Not authorized to use this model` means your organization is not
entitled to it - use an older version or ask Elastic to enable it. Anything
else that returns cleanly is safe to add.

**2. Add the alias** in `eis_models`. Follow the convention:
`<provider>-<that provider's tier name>`, **no version number**, so a later
upgrade does not churn developer configs.

```hcl
eis_models = {
  # ...existing...
  claude-haiku = "anthropic-claude-4.5-haiku"
}
```

**3. Add its rates** in `model_pricing`, from
[the pricing reference](reference/eis-pricing-2026-09-01.md). Use the
*Chat Completion - Input/Output* rows. If the model shows `<=200K` / `>200K`
style rows, include the tier fields; otherwise omit them.

```hcl
model_pricing = {
  # ...existing...
  claude-haiku = { input_per_1m = 1.50, output_per_1m = 7.00 }
}
```

Skipping this step is not fatal but the model records tokens with **no
cost**, showing as a gap in spend rather than as zero.

**4. Apply and re-issue configs.**

```bash
terraform apply                    # creates the inference endpoint
cd .. && scripts/dev-setup.sh <username>   # per developer, picks up the new alias
```

The proxy learns the catalog from `EIS_MODEL_MAP` at deploy time, so
`terraform apply` is enough - no image rebuild, no code change. Developers
need a regenerated `opencode.json` to see the new entry in `/models`.

**Removing a model** is the same in reverse: delete both entries and apply.
Historical usage data keeps its `model_alias` and `upstream_model`, so past
spend stays attributable after the endpoint is gone.

**Changing which model an alias points at** (e.g. bumping `claude-sonnet`
to a newer Sonnet) is a one-line change to `eis_models` plus its rates.
Developer configs do not change. The dashboards' `upstream_model` column is
what disambiguates before/after - see below.

## Onboarding a developer

```bash
scripts/dev-setup.sh alice
```

This generates `opencode.json` (model list pulled live from Terraform, so it
cannot drift) and `eis-proxy.env` (proxy URL + bearer token +
`X-EIS-User: alice`). Hand both files to the developer with
[developer-onboarding.md](developer-onboarding.md).

**Tell them explicitly to load the environment** - it is the single most
common setup failure. `opencode.json` resolves the proxy URL and token from
environment variables, so the developer must run, in every shell (and add to
their `~/.zshrc`):

```bash
set -a; source /full/path/to/eis-proxy.env; set +a
```

Skipping it produces a misleading error - OpenCode launches, the model picker
populates, then every request fails with `"/chat/completions" cannot be
parsed as a URL`, because the URL variable resolved to an empty string. The
script prints the exact commands with absolute paths; forward that output
verbatim.

**Attribution caveat**: `X-EIS-User` is self-reported. It makes the
per-user dashboards work, but nothing stops a developer sending someone
else's name. Fine for a trusted pilot; the authenticated fix is scoped in
[terraform/modules/sso](../terraform/modules/sso/README.md).

## Dashboards

Three dashboards are provisioned in the project's Kibana
(`terraform output elastic_kibana_endpoint`), under Analytics > Dashboards:

| Dashboard | Answers | Notes |
|---|---|---|
| **EIS Proxy - Usage & Adoption** | Who uses it, which models, how many tokens | Per-user via `X-EIS-User`; `unknown` = missing header |
| **EIS Proxy - Reliability & Performance** | Error rate, p95 latency, TTFB per model | Measured at the proxy, includes EIS time |
| **EIS Proxy - Query Analytics** | What developers ask, conversation depth, tool use | Content panels need `capture_requests=true` |
| **EIS Proxy - Cost & Spend (ECU)** | Inference spend by model and user, chargeback tables | Derived from `model_pricing`; set real rates first |

**Which model actually ran.** Aliases carry no version, so `model_alias`
alone cannot tell you what served a request once an alias is repointed.
Every usage and capture event also records `upstream_model` - the concrete
EIS model - and it is surfaced in three places: the "Models in use
(alias -> actual EIS model)" table on Usage & Adoption, the per-model
breakdown on Cost & Spend, and a column in the captured-queries panel. Use
it when comparing spend or quality across a model upgrade, or to confirm a
repoint actually took effect.

Raw data is in the `eis-proxy-usage*` / `eis-proxy-captures*` data views for
ad-hoc Discover/Lens work. Usage events carry metadata only (user, model,
tokens, latency, status) - never prompt content.

## Cost attribution (Cost & Spend dashboard)

Elastic bills EIS **per million tokens** at the organization level and has no
concept of which developer spent it. Spend is therefore *derived* at the
proxy, where the identity and token counts are both known, using rates you
supply. Figures are shown in **ECU** (1 ECU = $1.00 nominal).

**Rates are Elastic list prices captured 2026-09-01**, kept in
[docs/reference/eis-pricing-2026-09-01.md](reference/eis-pricing-2026-09-01.md) -
the repo's copy of the Cloud pricing table, which is behind the console and
not machine-readable. The defaults in `model_pricing` match that snapshot:

| Alias | Model | Input | Output | Tier |
|---|---|---|---|---|
| `claude-opus` | Claude 5 Opus | $7.50 | $35.00 | none |
| `claude-sonnet` | Claude 5 Sonnet | $3.00 | $14.00 | none |
| `gemini-pro` | Gemini 3.1 Pro | $3.00 / $6.00 | $16.80 / $25.20 | >200K |
| `gemini-flash` | Gemini 3.6 Flash | $1.125 | $5.25 | none |
| `gpt-sol` | GPT-5.6 Sol | $7.50 / $15.00 | $42.00 / $63.00 | >272K |
| `gpt-terra` | GPT-5.6 Terra | $3.00 / $6.00 | $16.80 / $25.20 | >272K |

Spread is wide - `gpt-sol` output costs 8x `gemini-flash`. Watch the Cost &
Spend dashboard's per-model table if spend climbs unexpectedly.

**Refresh them when prices or the model catalog change**, and when you do,
update the reference file's capture date too. Override in `terraform.tfvars`
if your contract differs from list:

```hcl
model_pricing = {
  claude = { input_per_1m = 3.00, output_per_1m = 14.00 }
  gemini = {
    input_per_1m = 3.00, output_per_1m = 16.80
    tier_threshold_tokens = 200000
    tier_input_per_1m = 6.00, tier_output_per_1m = 25.20
  }
}
```

Above `tier_threshold_tokens` prompt tokens, **both** input and output rates
step up; each request records which tier it was charged at as `price_tier`,
so a spend spike can be traced to tier escalation rather than volume.

Things worth knowing:

- **Rates apply going forward only.** Cost is computed and stored per request
  at the time it happens, so changing a rate does not restate history. That
  is intentional for chargeback, but it means the first requests after
  enabling pricing are the earliest ones with cost data.
- **An unpriced model records tokens but no cost**, so it is *absent* from
  spend totals rather than counted as zero. Zero would silently understate
  the bill. Watch for a model with requests and tokens but no spend in the
  "Spend by model" table - that is a missing rate.
- **Prompt caching is not modelled, and is currently not happening.** Cache
  reads are ~10x cheaper than input tokens (Claude 5 Sonnet: $0.30 vs
  $3.00), but EIS reports no cached-token counts, and the proxy strips
  `cache_control` because Elastic's unified API rejects unknown message
  fields. So every input token is charged at full rate - the costing is
  accurate, but for a coding agent resending a large context each turn this
  is the single biggest saving being left on the table.
- **Reading captured queries.** Three columns, increasing detail:
  `user_prompt` (the last human turn), `conversation_text` (a readable
  `role: text` transcript with the system prompt omitted and tool calls
  summarized by name), and `request_text` (the exact JSON payload, not shown
  by default - add it from the field list when structure matters). Note
  `opencode run "..."` wraps its argument in quote characters, so one-shot
  prompts appear quoted; the interactive TUI does not.
- **Historical detail.** The Query Analytics panel leads with
  `user_prompt` - the last human turn, extracted so the column shows the
  actual question rather than the system prompt that dominates an agent
  conversation. It is capped at 2000 characters; `request_text` (last
  column) still holds the full untruncated conversation for when you need
  the tool calls and intermediate turns. `user_prompt.keyword` groups
  repeated queries, for prompts under 256 chars.
- **Reconcile against actual billing.** The authoritative figure is in
  Elastic Cloud billing under the `Inference` billing dimension, available
  via the Billing Costs Analysis API (`getcostsbyitemsv2`). This dashboard
  exists for the per-user attribution billing cannot provide - not to
  replace it. The org-level billing API key is deliberately **not** given to
  the proxy; pull it separately if you want automated reconciliation.
- **Scope**: EIS inference only. The Serverless project's VCU compute charge
  is a separate line item and is not represented here.

## Request capture (query analytics)

Off by default. To record full request messages + response text:

```hcl
# terraform.tfvars
capture_requests = true
```

`terraform apply` (redeploys the task with `CAPTURE_LLM_TRAFFIC=true`).
Flip back to `false` and apply to stop capturing.

Before enabling, know what you're switching on:

- It stores **prompt and response content** - possibly proprietary code -
  in the `eis-proxy-captures` data stream.
- Retention is 30 days (enforced by the data stream lifecycle in
  [analytics.tf](../terraform/modules/elastic/analytics.tf)); usage
  metadata keeps 180 days.
- The developer doc promises developers are told when capture is on.
  Honor that.

## Routine operations

| Task | How |
|---|---|
| Deploy proxy change | `scripts/deploy.sh` |
| Proxy logs | CloudWatch group `/ecs/eis-proxy-poc-proxy` |
| Debug an Elastic 4xx | Proxy logs the rejected request's *shape* (field names, never content) |
| Rotate the bearer token | `terraform apply -replace=random_password.proxy_api_key`, then re-run `dev-setup.sh` for everyone |
| Rotate the Elastic org API key | Replace `ec_api_key` in tfvars, `terraform apply` |
| Verify a rate change took effect | Wait for `aws ecs wait services-stable` **before** testing - the ALB drains the old task for 60s, so a probe sent immediately after the new task appears can still be answered with the old rates |
| Health check | `curl $(terraform -chdir=terraform output -raw proxy_base_url | sed 's|/v1|/health|')` |

## Costs

- **Elastic Serverless project**: VCU-based, bills continuously while it
  exists - the dominant line item, and the one consuming committed spend.
- **EIS inference**: per-token, per-model.
- **AWS**: ALB ~$16/mo + Fargate ~$9/mo + Secrets Manager ~$0.80/mo.

Tear down everything: `terraform -chdir=terraform destroy`. That deletes the
Elastic project including all usage analytics - export dashboards/data
first if you need them.

## Known limitations / future work

- **TLS**: HTTP only. Bearer token and prompts cross the wire in clear.
  Needs a domain + ACM cert; see README "Future enhancements".
- **SSO**: shared token + self-reported identity; see
  [terraform/modules/sso](../terraform/modules/sso/README.md). TLS first.
- **Terraform state**: local, contains secrets. S3 backend before a second
  operator touches this; see README.
- **`ec_elasticsearch_project` and `elasticstack_kibana_dashboard` are
  technical-preview resources** - re-validate before provider upgrades.
