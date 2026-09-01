# Usage analytics backend. The proxy writes:
#   eis-proxy-usage    - one metadata doc per completion (user, model, tokens,
#                        latency; never prompt content). Always on.
#   eis-proxy-captures - full request messages + response text. Only written
#                        when capture_requests=true; short retention because
#                        it is prompt content.
# Data streams are created lazily on the proxy's first write - these templates
# supply mappings + retention when that happens. The dashboards in
# dashboards.tf aggregate over both.

resource "elasticstack_elasticsearch_index_template" "usage" {
  name           = "${var.project_name}-usage"
  index_patterns = ["eis-proxy-usage*"]
  data_stream {}
  priority = 200

  template {
    lifecycle {
      data_retention = "180d"
    }
    mappings = jsonencode({
      properties = {
        "@timestamp"      = { type = "date" }
        user              = { type = "keyword" }
        model_alias       = { type = "keyword" }
        upstream_model    = { type = "keyword" }
        inference_id      = { type = "keyword" }
        status            = { type = "keyword" }
        stream            = { type = "boolean" }
        tool_call_count   = { type = "integer" }
        request_bytes     = { type = "long" }
        latency_ms        = { type = "float" }
        ttfb_ms           = { type = "float" }
        prompt_tokens     = { type = "long" }
        completion_tokens = { type = "long" }
        total_tokens      = { type = "long" }
        # Spend attribution. scaled_float keeps 6 decimal places exactly -
        # per-request costs are frequently sub-cent, and float rounding
        # error compounds badly across a SUM over thousands of requests.
        input_cost  = { type = "scaled_float", scaling_factor = 1000000 }
        output_cost = { type = "scaled_float", scaling_factor = 1000000 }
        cost        = { type = "scaled_float", scaling_factor = 1000000 }
        # "standard" | "high" - which prompt-size tier the request was
        # charged at, so a spend spike can be attributed to tier escalation
        # rather than to volume.
        price_tier = { type = "keyword" }
      }
    })
  }

  elasticsearch_connection {
    endpoints = local.elasticsearch_connection.endpoints
    username  = local.elasticsearch_connection.username
    password  = local.elasticsearch_connection.password
  }
}

resource "elasticstack_elasticsearch_index_template" "captures" {
  name           = "${var.project_name}-captures"
  index_patterns = ["eis-proxy-captures*"]
  data_stream {}
  priority = 200

  template {
    # Prompt/response content: retention deliberately short. Raise only with
    # an explicit privacy conversation - developers are told 30 days.
    lifecycle {
      data_retention = "30d"
    }
    mappings = jsonencode({
      properties = {
        "@timestamp"   = { type = "date" }
        user           = { type = "keyword" }
        model_alias    = { type = "keyword" }
        upstream_model = { type = "keyword" }
        message_count  = { type = "integer" }
        total_tokens   = { type = "long" }
        # The last human turn, extracted from the conversation so analytics
        # shows the actual question instead of a wall of system prompt. The
        # keyword subfield allows grouping on repeated queries; longer
        # prompts simply are not aggregatable (ignore_above), which is fine -
        # full-text search still covers them.
        user_prompt = {
          type   = "text"
          fields = { keyword = { type = "keyword", ignore_above = 256 } }
        }
        # Plain-text transcript for reading in Discover; request_text keeps
        # the exact JSON payload for when the precise structure matters.
        conversation_text = { type = "text" }
        request_text      = { type = "text" }
        response_text     = { type = "text" }
      }
    })
  }

  elasticsearch_connection {
    endpoints = local.elasticsearch_connection.endpoints
    username  = local.elasticsearch_connection.username
    password  = local.elasticsearch_connection.password
  }
}
