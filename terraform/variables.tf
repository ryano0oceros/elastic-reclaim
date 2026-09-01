variable "project_name" {
  description = "Prefix used for naming resources across both the Elastic and AWS modules."
  type        = string
  default     = "eis-proxy-poc"
}

# --- Elastic Cloud / Serverless -------------------------------------------

variable "ec_api_key" {
  description = "Elastic Cloud API key with permission to create Serverless projects under your organization. Generate at https://cloud.elastic.co/account/keys."
  type        = string
  sensitive   = true
}

variable "ec_region" {
  description = "Elastic Cloud Serverless region id, e.g. \"aws-us-east-1\"."
  type        = string
  default     = "aws-us-east-1"
}

variable "ec_organization_id" {
  description = "Existing Elastic Cloud organization id (found at https://cloud.elastic.co/account/members). Recorded as a project tag; your API key already scopes provisioning to this organization."
  type        = string
}

variable "eis_models" {
  description = <<-EOT
    Model catalog. Maps a short alias (what developers pick in OpenCode) to
    an EIS model_id. One chat_completion inference endpoint is created per
    entry.

    Naming convention: <provider>-<that provider's own tier name>. Aliases
    deliberately carry no version number, so bumping to a newer model is a
    one-line change here that does not churn every developer's config. The
    model_id is surfaced in the OpenCode picker alongside the alias, so the
    exact model in use is always visible.

    Tiers: opus / pro / sol are the flagship (most capable, most expensive);
    sonnet / flash / terra are the balanced everyday drivers.

    Valid model_id values:
    https://www.elastic.co/docs/explore-analyze/elastic-inference/eis-supported-models
    Rates for each live in var.model_pricing - update both together.
  EOT
  type        = map(string)
  default = {
    # Anthropic
    claude-opus   = "anthropic-claude-5-opus"
    claude-sonnet = "anthropic-claude-5-sonnet"
    # Google
    gemini-pro = "google-gemini-3.1-pro"
    # 3.7 Flash exists and is priced, but EIS rejects it for this org with
    # "Not authorized to use this model" - it is also absent from the
    # supported-models docs. 3.6 is the newest Flash actually available.
    gemini-flash = "google-gemini-3.6-flash"
    # OpenAI - Sol is the flagship, Terra the Claude-Sonnet-equivalent tier
    gpt-sol   = "openai-gpt-5.6-sol"
    gpt-terra = "openai-gpt-5.6-terra"
  }
}

# --- AWS ---------------------------------------------------------------

variable "aws_region" {
  description = "AWS region to provision the VPC/ECS Fargate infrastructure in."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the proxy's VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "container_port" {
  description = "Port the FastAPI proxy listens on."
  type        = number
  default     = 8000
}

variable "image_tag" {
  description = "Tag of the proxy image in ECR to deploy. The ECR repo is IMMUTABLE, so every build must use a new unique tag (e.g. a git SHA) rather than overwriting one."
  type        = string
  default     = "v1"
}

variable "desired_count" {
  description = "Number of Fargate tasks running the proxy."
  type        = number
  default     = 1
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach the proxy on container_port. Restrict this to your workstation/office CIDR before using real credentials."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "capture_requests" {
  description = "When true, the proxy records full request messages and response text to the eis-proxy-captures data stream (30-day retention) for the Query Analytics dashboard. Off by default: this is prompt content - tell your developers before enabling it."
  type        = bool
  default     = false
}

variable "model_pricing" {
  description = <<-EOT
    Per-model token rates for spend attribution, keyed by the same alias as
    eis_models. USD per 1,000,000 tokens; 1 ECU = $1.00 nominal.

    Rates are Elastic list prices captured 2026-09-01 - see
    docs/reference/eis-pricing-2026-09-01.md, the repo's copy of the Cloud
    pricing table. Re-check both when rates or the catalog change; your
    contract may differ from list.

    Optional tier_* fields model Elastic's prompt-size pricing: above
    tier_threshold_tokens BOTH the input and output rate step up. Omit for
    models with a single flat rate.

    An alias omitted here records tokens but no cost, appearing as a gap in
    spend rather than as zero, which would understate the bill.
  EOT
  type = map(object({
    input_per_1m          = number
    output_per_1m         = number
    tier_threshold_tokens = optional(number)
    tier_input_per_1m     = optional(number)
    tier_output_per_1m    = optional(number)
  }))
  default = {
    # Claude 5 Opus - flat
    claude-opus = {
      input_per_1m  = 7.50
      output_per_1m = 35.00
    }
    # Claude 5 Sonnet - flat
    claude-sonnet = {
      input_per_1m  = 3.00
      output_per_1m = 14.00
    }
    # Gemini 3.1 Pro - steps up above 200K prompt tokens
    gemini-pro = {
      input_per_1m          = 3.00
      output_per_1m         = 16.80
      tier_threshold_tokens = 200000
      tier_input_per_1m     = 6.00
      tier_output_per_1m    = 25.20
    }
    # Gemini 3.6 Flash - flat
    gemini-flash = {
      input_per_1m  = 1.125
      output_per_1m = 5.25
    }
    # GPT-5.6 Sol - steps up above 272K prompt tokens
    gpt-sol = {
      input_per_1m          = 7.50
      output_per_1m         = 42.00
      tier_threshold_tokens = 272000
      tier_input_per_1m     = 15.00
      tier_output_per_1m    = 63.00
    }
    # GPT-5.6 Terra - steps up above 272K prompt tokens
    gpt-terra = {
      input_per_1m          = 3.00
      output_per_1m         = 16.80
      tier_threshold_tokens = 272000
      tier_input_per_1m     = 6.00
      tier_output_per_1m    = 25.20
    }
  }
}

variable "default_model_alias" {
  description = <<-EOT
    Alias new developers get by default (scripts/dev-setup.sh writes it as
    the top-level `model` in opencode.json). Must be a key of eis_models.

    Set deliberately rather than derived: picking the first alias
    alphabetically would default everyone to claude-opus, the most expensive
    model in the catalog, and most work does not need it. Developers can
    still switch per-session with /models.
  EOT
  type        = string
  default     = "claude-sonnet"

  validation {
    condition     = contains(keys(var.eis_models), var.default_model_alias)
    error_message = "default_model_alias must be one of the eis_models keys."
  }
}
