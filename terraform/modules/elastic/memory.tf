# Agent memory: the coding assistant's own past exchanges, made semantically
# searchable so it can recall prior work instead of re-deriving it.
#
# This is the same content class as eis-proxy-captures and is gated by the
# same capture_requests toggle - but it is a separate index rather than a
# projection of captures, because `semantic_text` needs its own mapping and
# data streams only apply template changes at rollover.
#
# The embedding runs on EIS (.elser-2-elastic), so retrieval is billed to the
# same committed Elastic capacity as chat completion - one credential, one
# budget, for both generation and recall.

resource "elasticstack_elasticsearch_index_template" "memory" {
  name           = "${var.project_name}-memory"
  index_patterns = ["eis-agent-memory*"]
  data_stream {}
  priority = 200

  template {
    lifecycle {
      # Longer than captures' 30d: memory is only useful if it reaches back
      # far enough to cover work you have genuinely forgotten. Still bounded,
      # because these documents contain prompt content.
      data_retention = "90d"
    }
    mappings = jsonencode({
      properties = {
        "@timestamp" = { type = "date" }
        user         = { type = "keyword" }
        model_alias  = { type = "keyword" }
        # semantic_text chunks and embeds at ingest via the referenced
        # inference endpoint - no embedding code in the proxy, and queries
        # embed the search string with the same model automatically.
        prompt = {
          type         = "semantic_text"
          inference_id = var.memory_inference_id
        }
        # Kept as plain text: the answer is what you read once the prompt has
        # matched, and embedding it too would roughly double ingest cost for
        # little retrieval gain on a coding-assistant corpus.
        response     = { type = "text" }
        total_tokens = { type = "long" }
      }
    })
  }

  elasticsearch_connection {
    endpoints = local.elasticsearch_connection.endpoints
    username  = local.elasticsearch_connection.username
    password  = local.elasticsearch_connection.password
  }
}
