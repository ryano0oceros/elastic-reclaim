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
        # The embedded field is question AND answer together, not the
        # question alone. Tested against real history: developer questions
        # are often short and context-free ("rework the last slide"), so the
        # retrievable substance lives in the answer. Embedding only the
        # prompt returned confident nonsense.
        #
        # semantic_text chunks and embeds at ingest via the referenced
        # inference endpoint - no embedding code in the proxy, and queries
        # embed the search string with the same model automatically.
        memo = {
          type         = "semantic_text"
          inference_id = var.memory_inference_id
        }
        # Plain copies for display; `memo` is what retrieval scores against.
        # `topic` is the conversation's opening question, which is what makes
        # an anaphoric follow-up ("summarize that") intelligible on its own.
        topic    = { type = "text" }
        prompt   = { type = "text" }
        response = { type = "text" }
        # One user question drives many proxy requests inside an agent loop,
        # each carrying the same latest user turn. Rather than dedupe on
        # write (which would need cross-request state), searches collapse on
        # this hash so recall returns one row per question asked.
        prompt_hash  = { type = "keyword" }
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
