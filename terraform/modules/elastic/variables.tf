variable "project_name" {
  description = "Descriptive name for the Elastic Serverless Elasticsearch project."
  type        = string
}

variable "region_id" {
  description = "Elastic Cloud Serverless region id, e.g. \"aws-us-east-1\". Must be a region that supports Serverless projects."
  type        = string
}

variable "organization_id" {
  description = "Existing Elastic organization id that owns the subscription this project is provisioned under. Not sent as a direct API argument (the API key already scopes requests to your organization) - stored as a project tag for traceability."
  type        = string
}

variable "optimized_for" {
  description = "Elasticsearch project hardware profile. \"general_purpose\" is correct for the inference/search workload in this PoC."
  type        = string
  default     = "general_purpose"
}

variable "eis_models" {
  description = <<-EOT
    Map of friendly model alias -> EIS model_id. One chat_completion
    inference endpoint is created per entry; the alias is what OpenCode's
    model picker shows and what the proxy's EIS_MODEL_MAP routes on.
    Valid model_id values: https://www.elastic.co/docs/explore-analyze/elastic-inference/eis-supported-models
  EOT
  type        = map(string)
  default = {
    claude = "anthropic-claude-5-sonnet"
    gemini = "google-gemini-3.1-pro"
    gpt    = "openai-gpt-5.4"
  }
}

variable "memory_inference_id" {
  description = <<-EOT
    Inference endpoint used to embed agent-memory prompts. Defaults to
    Elastic's preconfigured EIS ELSER endpoint, so recall is billed to the
    same committed capacity as chat completion. Sparse (ELSER) rather than
    dense: it needs no dimension/similarity tuning and handles the short,
    jargon-heavy phrasing of developer questions well.
  EOT
  type        = string
  default     = ".elser-2-elastic"
}
