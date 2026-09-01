# Pre-canned Kibana dashboards, provisioned as code via the typed
# elasticstack_kibana_dashboard resource (Kibana Dashboard API).
#
# History note: the first attempt used elasticstack_kibana_import_saved_objects
# with hand-authored Lens ndjson - serverless Kibana 500'd on the dashboard
# objects (saved-object migration of by-value Lens panels). The typed resource
# validates panel config against the Dashboard API schema instead, which turns
# shape mistakes into readable apply-time errors.
#
# The *_json snippets below spell out fields the API would otherwise default
# (axis, color, alignment, visible, click_filter, empty_as_null). That is
# deliberate: the Dashboard API normalizes configs on write, and if the sent
# JSON differs from the normalized echo the provider fails the apply with
# "Provider produced inconsistent result". The shapes here are copied verbatim
# from the API's normalized responses - keep them in sync when editing.

locals {
  usage_data_source = jsonencode({
    type          = "data_view_spec"
    index_pattern = "eis-proxy-usage*"
    time_field    = "@timestamp"
  })
  captures_data_source = jsonencode({
    type          = "data_view_spec"
    index_pattern = "eis-proxy-captures*"
    time_field    = "@timestamp"
  })

  kibana_connection = {
    endpoints = [ec_elasticsearch_project.this.endpoints.kibana]
    username  = ec_elasticsearch_project.this.credentials.username
    password  = ec_elasticsearch_project.this.credentials.password
  }

  # -- shared bucket operations (API passes these through unchanged) --
  op_date_hist = jsonencode({ operation = "date_histogram", field = "@timestamp", suggested_interval = "auto", use_original_time_range = false, include_empty_rows = true, drop_partial_intervals = false })
  terms_user   = jsonencode({ operation = "terms", fields = ["user"], limit = 10, rank_by = { type = "metric", metric_index = 0, direction = "desc" } })
  terms_model  = jsonencode({ operation = "terms", fields = ["model_alias"], limit = 10, rank_by = { type = "metric", metric_index = 0, direction = "desc" } })
  terms_status = jsonencode({ operation = "terms", fields = ["status"], limit = 5, rank_by = { type = "metric", metric_index = 0, direction = "desc" } })

  # -- XY y-axis metrics (normalized: axis/color, empty_as_null where the API adds it) --
  xy_count         = jsonencode({ empty_as_null = false, operation = "count", axis = "y", color = { type = "auto" } })
  xy_sum_tokens    = jsonencode({ field = "total_tokens", empty_as_null = false, operation = "sum", axis = "y", color = { type = "auto" } })
  xy_unique_users  = jsonencode({ field = "user", empty_as_null = false, operation = "unique_count", axis = "y", color = { type = "auto" } })
  xy_p95_latency   = jsonencode({ field = "latency_ms", operation = "percentile", percentile = 95, axis = "y", color = { type = "auto" } })
  xy_median_ttfb   = jsonencode({ field = "ttfb_ms", operation = "median", axis = "y", color = { type = "auto" } })
  xy_avg_messages  = jsonencode({ field = "message_count", operation = "average", axis = "y", color = { type = "auto" } })
  xy_avg_toolcalls = jsonencode({ field = "tool_call_count", operation = "average", axis = "y", color = { type = "auto" } })

  # -- datatable rows (normalized form adds visible/alignment/color/click_filter) --
  row_defaults   = { visible = true, alignment = "left", color = { type = "auto" }, click_filter = false }
  row_user_top25 = jsonencode(merge({ operation = "terms", fields = ["user"], limit = 25, rank_by = { type = "metric", metric_index = 1, direction = "desc" } }, local.row_defaults))
  row_model      = jsonencode(merge({ operation = "terms", fields = ["model_alias"], limit = 10, rank_by = { type = "metric", metric_index = 0, direction = "desc" } }, local.row_defaults))
  row_status     = jsonencode(merge({ operation = "terms", fields = ["status"], limit = 5, rank_by = { type = "metric", metric_index = 0, direction = "desc" } }, local.row_defaults))

  # -- datatable metrics (normalized form adds visible/color/alignment) --
  tbl_defaults       = { visible = true, color = { type = "auto" }, alignment = "right" }
  tbl_count          = jsonencode(merge({ empty_as_null = false, operation = "count" }, local.tbl_defaults))
  tbl_sum_tokens     = jsonencode(merge({ field = "total_tokens", empty_as_null = false, operation = "sum" }, local.tbl_defaults))
  tbl_sum_completion = jsonencode(merge({ field = "completion_tokens", empty_as_null = false, operation = "sum" }, local.tbl_defaults))
  tbl_avg_latency    = jsonencode(merge({ field = "latency_ms", operation = "average" }, local.tbl_defaults))

  # -- pie configs (API passes these through unchanged) --
  pie_sum_tokens = jsonencode({ field = "total_tokens", operation = "sum" })
  pie_count      = jsonencode({ empty_as_null = false, operation = "count" })

  # The concrete EIS model that served the request. Aliases are deliberately
  # version-free, so this is the only record of what actually ran - essential
  # once an alias is repointed at a newer model.
  terms_upstream   = jsonencode({ operation = "terms", fields = ["upstream_model"], limit = 15, rank_by = { type = "metric", metric_index = 0, direction = "desc" } })
  row_upstream     = jsonencode(merge({ operation = "terms", fields = ["upstream_model"], limit = 15, rank_by = { type = "metric", metric_index = 0, direction = "desc" } }, local.row_defaults))
  tbl_unique_users = jsonencode(merge({ field = "user", empty_as_null = false, operation = "unique_count" }, local.tbl_defaults))

  table_density = { density = { mode = "compact" } }

  # -- spend metrics (same normalized shapes as the others) --
  xy_sum_cost      = jsonencode({ field = "cost", empty_as_null = false, operation = "sum", axis = "y", color = { type = "auto" } })
  pie_sum_cost     = jsonencode({ field = "cost", operation = "sum" })
  tbl_sum_cost     = jsonencode(merge({ field = "cost", empty_as_null = false, operation = "sum" }, local.tbl_defaults))
  tbl_sum_in_cost  = jsonencode(merge({ field = "input_cost", empty_as_null = false, operation = "sum" }, local.tbl_defaults))
  tbl_sum_out_cost = jsonencode(merge({ field = "output_cost", empty_as_null = false, operation = "sum" }, local.tbl_defaults))
  tbl_avg_cost     = jsonencode(merge({ field = "cost", operation = "average" }, local.tbl_defaults))
  tbl_sum_prompt   = jsonencode(merge({ field = "prompt_tokens", empty_as_null = false, operation = "sum" }, local.tbl_defaults))
  tbl_sum_output   = jsonencode(merge({ field = "completion_tokens", empty_as_null = false, operation = "sum" }, local.tbl_defaults))
  # terms ranked by the *cost* metric (index 0) rather than count
  row_user_by_cost  = jsonencode(merge({ operation = "terms", fields = ["user"], limit = 25, rank_by = { type = "metric", metric_index = 0, direction = "desc" } }, local.row_defaults))
  row_model_by_cost = jsonencode(merge({ operation = "terms", fields = ["model_alias"], limit = 25, rank_by = { type = "metric", metric_index = 0, direction = "desc" } }, local.row_defaults))
}

# Data views so the streams are first-class in Discover/Lens for ad-hoc work.
resource "elasticstack_kibana_data_view" "usage" {
  data_view = {
    id              = "eis-proxy-usage-dv"
    name            = "EIS Proxy Usage"
    title           = "eis-proxy-usage*"
    time_field_name = "@timestamp"
  }
  kibana_connection {
    endpoints = local.kibana_connection.endpoints
    username  = local.kibana_connection.username
    password  = local.kibana_connection.password
  }
}

resource "elasticstack_kibana_data_view" "captures" {
  data_view = {
    id              = "eis-proxy-captures-dv"
    name            = "EIS Proxy Captures"
    title           = "eis-proxy-captures*"
    time_field_name = "@timestamp"
  }
  kibana_connection {
    endpoints = local.kibana_connection.endpoints
    username  = local.kibana_connection.username
    password  = local.kibana_connection.password
  }
}

# --- Dashboard 1: Usage & Adoption ------------------------------------------

resource "elasticstack_kibana_dashboard" "usage_adoption" {
  title       = "EIS Proxy - Usage & Adoption"
  description = "Who uses which model and how many tokens they consume. User attribution is self-reported (X-EIS-User header) until SSO."

  time_range       = { from = "now-7d", to = "now" }
  refresh_interval = { pause = false, value = 30000 }
  query            = { language = "kql", text = "" }

  panels = [
    {
      type = "vis"
      grid = { x = 0, y = 0, w = 12, h = 8 }
      vis_config = {
        by_value = {
          metric_chart_config = {
            title            = "Total tokens"
            data_source_json = local.usage_data_source
            query            = { expression = "" }
            metrics = [{
              config_json = jsonencode({
                field     = "total_tokens"
                format    = { compact = true, type = "number" }
                operation = "sum"
                type      = "primary"
              })
            }]
          }
        }
      }
    },
    {
      type = "vis"
      grid = { x = 12, y = 0, w = 12, h = 8 }
      vis_config = {
        by_value = {
          metric_chart_config = {
            title            = "Requests"
            data_source_json = local.usage_data_source
            query            = { expression = "" }
            metrics = [{
              config_json = jsonencode({
                format    = { compact = true, type = "number" }
                operation = "count"
                type      = "primary"
              })
            }]
          }
        }
      }
    },
    {
      type = "vis"
      grid = { x = 24, y = 0, w = 24, h = 8 }
      vis_config = {
        by_value = {
          xy_chart_config = {
            title       = "Daily active users"
            axis        = { y = { domain_json = jsonencode({ type = "fit" }) } }
            decorations = {}
            fitting     = { type = "none" }
            legend      = {}
            query       = { expression = "" }
            layers = [{
              type = "line"
              data_layer = {
                data_source_json = local.usage_data_source
                x_json           = local.op_date_hist
                y                = [{ config_json = local.xy_unique_users }]
              }
            }]
          }
        }
      }
    },
    {
      type = "vis"
      grid = { x = 0, y = 8, w = 24, h = 14 }
      vis_config = {
        by_value = {
          xy_chart_config = {
            title       = "Tokens over time by user"
            axis        = { y = { domain_json = jsonencode({ type = "fit" }) } }
            decorations = {}
            fitting     = { type = "none" }
            legend      = {}
            query       = { expression = "" }
            layers = [{
              type = "bar_stacked"
              data_layer = {
                data_source_json  = local.usage_data_source
                x_json            = local.op_date_hist
                breakdown_by_json = local.terms_user
                y                 = [{ config_json = local.xy_sum_tokens }]
              }
            }]
          }
        }
      }
    },
    {
      type = "vis"
      grid = { x = 24, y = 8, w = 24, h = 14 }
      vis_config = {
        by_value = {
          xy_chart_config = {
            title       = "Tokens over time by model"
            axis        = { y = { domain_json = jsonencode({ type = "fit" }) } }
            decorations = {}
            fitting     = { type = "none" }
            legend      = {}
            query       = { expression = "" }
            layers = [{
              type = "bar_stacked"
              data_layer = {
                data_source_json  = local.usage_data_source
                x_json            = local.op_date_hist
                breakdown_by_json = local.terms_model
                y                 = [{ config_json = local.xy_sum_tokens }]
              }
            }]
          }
        }
      }
    },
    {
      type = "vis"
      grid = { x = 0, y = 22, w = 16, h = 14 }
      vis_config = {
        by_value = {
          pie_chart_config = {
            title            = "Model mix (tokens)"
            donut_hole       = "s"
            legend           = { nested = false, size = "auto", truncate_after_lines = 1, visible = "auto" }
            data_source_json = local.usage_data_source
            query            = { expression = "" }
            metrics          = [{ config_json = local.pie_sum_tokens }]
            group_by         = [{ config_json = local.terms_model }]
          }
        }
      }
    },
    {
      type = "vis"
      grid = { x = 0, y = 36, w = 48, h = 14 }
      vis_config = {
        by_value = {
          datatable_config = {
            no_esql = {
              title            = "Models in use (alias -> actual EIS model)"
              data_source_json = local.usage_data_source
              query            = { expression = "" }
              styling          = local.table_density
              rows = [
                { config_json = local.row_model },
                { config_json = local.row_upstream },
              ]
              metrics = [
                { config_json = local.tbl_count },
                { config_json = local.tbl_sum_tokens },
                { config_json = local.tbl_unique_users },
              ]
            }
          }
        }
      }
    },
    {
      type = "vis"
      grid = { x = 16, y = 22, w = 32, h = 14 }
      vis_config = {
        by_value = {
          datatable_config = {
            no_esql = {
              title            = "Top users"
              data_source_json = local.usage_data_source
              query            = { expression = "" }
              styling          = local.table_density
              rows             = [{ config_json = local.row_user_top25 }]
              metrics = [
                { config_json = local.tbl_count },
                { config_json = local.tbl_sum_tokens },
                { config_json = local.tbl_sum_completion },
              ]
            }
          }
        }
      }
    },
  ]

  kibana_connection {
    endpoints = local.kibana_connection.endpoints
    username  = local.kibana_connection.username
    password  = local.kibana_connection.password
  }
}

# --- Dashboard 2: Reliability & Performance ---------------------------------

resource "elasticstack_kibana_dashboard" "reliability" {
  title       = "EIS Proxy - Reliability & Performance"
  description = "Errors and latency per model, as measured at the proxy."

  time_range       = { from = "now-7d", to = "now" }
  refresh_interval = { pause = false, value = 30000 }
  query            = { language = "kql", text = "" }

  panels = [
    {
      type = "vis"
      grid = { x = 0, y = 0, w = 24, h = 14 }
      vis_config = {
        by_value = {
          xy_chart_config = {
            title       = "Requests over time by outcome"
            axis        = { y = { domain_json = jsonencode({ type = "fit" }) } }
            decorations = {}
            fitting     = { type = "none" }
            legend      = {}
            query       = { expression = "" }
            layers = [{
              type = "bar_stacked"
              data_layer = {
                data_source_json  = local.usage_data_source
                x_json            = local.op_date_hist
                breakdown_by_json = local.terms_status
                y                 = [{ config_json = local.xy_count }]
              }
            }]
          }
        }
      }
    },
    {
      type = "vis"
      grid = { x = 24, y = 0, w = 24, h = 14 }
      vis_config = {
        by_value = {
          pie_chart_config = {
            title            = "Outcome breakdown"
            donut_hole       = "s"
            legend           = { nested = false, size = "auto", truncate_after_lines = 1, visible = "auto" }
            data_source_json = local.usage_data_source
            query            = { expression = "" }
            metrics          = [{ config_json = local.pie_count }]
            group_by         = [{ config_json = local.terms_status }]
          }
        }
      }
    },
    {
      type = "vis"
      grid = { x = 0, y = 14, w = 24, h = 14 }
      vis_config = {
        by_value = {
          xy_chart_config = {
            title       = "p95 latency by model (ms)"
            axis        = { y = { domain_json = jsonencode({ type = "fit" }) } }
            decorations = {}
            fitting     = { type = "none" }
            legend      = {}
            query       = { expression = "" }
            layers = [{
              type = "line"
              data_layer = {
                data_source_json  = local.usage_data_source
                x_json            = local.op_date_hist
                breakdown_by_json = local.terms_model
                y                 = [{ config_json = local.xy_p95_latency }]
              }
            }]
          }
        }
      }
    },
    {
      type = "vis"
      grid = { x = 24, y = 14, w = 24, h = 14 }
      vis_config = {
        by_value = {
          xy_chart_config = {
            title       = "Median time-to-first-byte by model (ms)"
            axis        = { y = { domain_json = jsonencode({ type = "fit" }) } }
            decorations = {}
            fitting     = { type = "none" }
            legend      = {}
            query       = { expression = "" }
            layers = [{
              type = "line"
              data_layer = {
                data_source_json  = local.usage_data_source
                x_json            = local.op_date_hist
                breakdown_by_json = local.terms_model
                y                 = [{ config_json = local.xy_median_ttfb }]
              }
            }]
          }
        }
      }
    },
    {
      type = "vis"
      grid = { x = 0, y = 28, w = 48, h = 12 }
      vis_config = {
        by_value = {
          datatable_config = {
            no_esql = {
              title            = "Requests by model and outcome"
              data_source_json = local.usage_data_source
              query            = { expression = "" }
              styling          = local.table_density
              rows = [
                { config_json = local.row_model },
                { config_json = local.row_status },
              ]
              metrics = [
                { config_json = local.tbl_count },
                { config_json = local.tbl_avg_latency },
              ]
            }
          }
        }
      }
    },
  ]

  kibana_connection {
    endpoints = local.kibana_connection.endpoints
    username  = local.kibana_connection.username
    password  = local.kibana_connection.password
  }
}

# --- Dashboard 3: Query Analytics --------------------------------------------

resource "elasticstack_kibana_dashboard" "query_analytics" {
  title       = "EIS Proxy - Query Analytics"
  description = "What developers actually ask. Content panels are empty unless capture_requests=true (off by default; 30-day retention)."

  time_range       = { from = "now-7d", to = "now" }
  refresh_interval = { pause = false, value = 30000 }
  query            = { language = "kql", text = "" }

  panels = [
    {
      type = "markdown"
      grid = { x = 0, y = 0, w = 48, h = 5 }
      markdown_config = {
        by_value = {
          title    = "About this dashboard"
          content  = <<-EOT
            ## Query analytics
            The **captured queries** panels below are populated only when the platform team sets `capture_requests = true` in Terraform (default **off**; 30-day retention). The tool-call panel uses always-on usage metadata and works regardless.
          EOT
          settings = { open_links_in_new_tab = true }
        }
      }
    },
    {
      type = "vis"
      grid = { x = 0, y = 5, w = 24, h = 12 }
      vis_config = {
        by_value = {
          xy_chart_config = {
            title       = "Avg messages per request (conversation depth)"
            axis        = { y = { domain_json = jsonencode({ type = "fit" }) } }
            decorations = {}
            fitting     = { type = "none" }
            legend      = {}
            query       = { expression = "" }
            layers = [{
              type = "line"
              data_layer = {
                data_source_json = local.captures_data_source
                x_json           = local.op_date_hist
                y                = [{ config_json = local.xy_avg_messages }]
              }
            }]
          }
        }
      }
    },
    {
      type = "vis"
      grid = { x = 24, y = 5, w = 24, h = 12 }
      vis_config = {
        by_value = {
          xy_chart_config = {
            title       = "Avg tool calls per request by model"
            axis        = { y = { domain_json = jsonencode({ type = "fit" }) } }
            decorations = {}
            fitting     = { type = "none" }
            legend      = {}
            query       = { expression = "" }
            layers = [{
              type = "line"
              data_layer = {
                data_source_json  = local.usage_data_source
                x_json            = local.op_date_hist
                breakdown_by_json = local.terms_model
                y                 = [{ config_json = local.xy_avg_toolcalls }]
              }
            }]
          }
        }
      }
    },
    {
      type = "discover_session"
      grid = { x = 0, y = 17, w = 48, h = 18 }
      discover_session_config = {
        by_value = {
          tab = {
            esql = {
              data_source_json = jsonencode({
                type = "esql"
                # user_prompt first: it is the readable question. request_text
                # holds the full conversation and is kept last so it does not
                # crowd out the columns people actually scan.
                query = "FROM eis-proxy-captures | KEEP @timestamp, user, model_alias, upstream_model, user_prompt, response_text, conversation_text | SORT @timestamp DESC | LIMIT 100"
              })
              column_order = ["@timestamp", "user", "model_alias", "upstream_model", "user_prompt", "response_text", "conversation_text"]
              row_height   = "3"
            }
          }
        }
      }
    },
  ]

  kibana_connection {
    endpoints = local.kibana_connection.endpoints
    username  = local.kibana_connection.username
    password  = local.kibana_connection.password
  }

  # The ES|QL discover panel queries the captures data stream by name; make
  # sure its backing template (and therefore mapping) exists first.
  depends_on = [elasticstack_elasticsearch_index_template.captures]
}


# --- Dashboard 4: Cost & Spend -----------------------------------------------
#
# Spend is derived at request time from var.model_pricing (see the proxy's
# telemetry module), not from an Elastic billing API - Elastic bills EIS per
# token and exposes no per-user attribution, so allocating spend to a
# developer requires computing it here. Requests whose model has no
# configured rate contribute tokens but no cost, so a rate gap shows up as
# missing spend rather than as free usage.
#
# Note this covers EIS *inference* spend only. The Serverless project's own
# VCU compute charge is billed separately and is not represented here.

resource "elasticstack_kibana_dashboard" "cost" {
  title       = "EIS Proxy - Cost & Spend (ECU)"
  description = "EIS inference spend by model and user, derived at the proxy from configured per-token rates. 1 ECU = $1.00. Excludes the Serverless project's separate VCU compute charge."

  time_range       = { from = "now-30d", to = "now" }
  refresh_interval = { pause = false, value = 30000 }
  query            = { language = "kql", text = "" }

  panels = [
    {
      type = "markdown"
      grid = { x = 0, y = 0, w = 48, h = 6 }
      markdown_config = {
        by_value = {
          title    = "How these numbers are produced"
          content  = <<-EOT
            Figures are in **ECU** (1 ECU = $1.00 nominal). They are **derived, not billed**: Elastic charges EIS per million tokens at the organization level with no per-developer attribution, so spend is computed at the proxy — where the user identity and the token counts are both known — using the rates in the `model_pricing` Terraform variable.

            **Two things to check before trusting these numbers.** First, the rates must match your contract: the shipped defaults are Elastic's published Managed LLM list price and are placeholders. Second, requests on a model with no configured rate record tokens but **no** cost, so they are missing from spend totals rather than counted as zero — compare "Requests" against token columns in the model table below to spot a rate gap.

            **Authoritative figures** live in Elastic Cloud billing under the `Inference` billing dimension (Billing Costs Analysis API, `getcostsbyitemsv2`). Reconcile against it periodically; this dashboard exists for the *attribution* that billing cannot give you. It also excludes the Serverless project's VCU compute charge.
          EOT
          settings = { open_links_in_new_tab = true }
        }
      }
    },
    {
      type = "vis"
      grid = { x = 0, y = 6, w = 12, h = 8 }
      vis_config = {
        by_value = {
          metric_chart_config = {
            title            = "Total spend (ECU)"
            data_source_json = local.usage_data_source
            query            = { expression = "" }
            metrics = [{
              config_json = jsonencode({
                field  = "cost", operation = "sum", type = "primary"
                format = { type = "number", decimals = 2 }
              })
            }]
          }
        }
      }
    },
    {
      type = "vis"
      grid = { x = 12, y = 6, w = 12, h = 8 }
      vis_config = {
        by_value = {
          metric_chart_config = {
            title            = "Input token spend (ECU)"
            data_source_json = local.usage_data_source
            query            = { expression = "" }
            metrics = [{
              config_json = jsonencode({
                field  = "input_cost", operation = "sum", type = "primary"
                format = { type = "number", decimals = 2 }
              })
            }]
          }
        }
      }
    },
    {
      type = "vis"
      grid = { x = 24, y = 6, w = 12, h = 8 }
      vis_config = {
        by_value = {
          metric_chart_config = {
            title            = "Output token spend (ECU)"
            data_source_json = local.usage_data_source
            query            = { expression = "" }
            metrics = [{
              config_json = jsonencode({
                field  = "output_cost", operation = "sum", type = "primary"
                format = { type = "number", decimals = 2 }
              })
            }]
          }
        }
      }
    },
    {
      type = "vis"
      grid = { x = 36, y = 6, w = 12, h = 8 }
      vis_config = {
        by_value = {
          metric_chart_config = {
            title            = "Avg spend per request (ECU)"
            data_source_json = local.usage_data_source
            query            = { expression = "" }
            metrics = [{
              config_json = jsonencode({
                field  = "cost", operation = "average", type = "primary"
                format = { type = "number", decimals = 4 }
              })
            }]
          }
        }
      }
    },
    {
      type = "vis"
      grid = { x = 0, y = 14, w = 32, h = 14 }
      vis_config = {
        by_value = {
          xy_chart_config = {
            title       = "Spend over time by model (ECU)"
            axis        = { y = { domain_json = jsonencode({ type = "fit" }) } }
            decorations = {}
            fitting     = { type = "none" }
            legend      = {}
            query       = { expression = "" }
            layers = [{
              type = "bar_stacked"
              data_layer = {
                data_source_json  = local.usage_data_source
                x_json            = local.op_date_hist
                breakdown_by_json = local.terms_model
                y                 = [{ config_json = local.xy_sum_cost }]
              }
            }]
          }
        }
      }
    },
    {
      type = "vis"
      grid = { x = 32, y = 14, w = 16, h = 14 }
      vis_config = {
        by_value = {
          pie_chart_config = {
            title            = "Spend share by model (ECU)"
            donut_hole       = "s"
            legend           = { nested = false, size = "auto", truncate_after_lines = 1, visible = "auto" }
            data_source_json = local.usage_data_source
            query            = { expression = "" }
            metrics          = [{ config_json = local.pie_sum_cost }]
            group_by         = [{ config_json = local.terms_model }]
          }
        }
      }
    },
    {
      type = "vis"
      grid = { x = 0, y = 28, w = 32, h = 14 }
      vis_config = {
        by_value = {
          xy_chart_config = {
            title       = "Spend over time by user (ECU)"
            axis        = { y = { domain_json = jsonencode({ type = "fit" }) } }
            decorations = {}
            fitting     = { type = "none" }
            legend      = {}
            query       = { expression = "" }
            layers = [{
              type = "bar_stacked"
              data_layer = {
                data_source_json  = local.usage_data_source
                x_json            = local.op_date_hist
                breakdown_by_json = local.terms_user
                y                 = [{ config_json = local.xy_sum_cost }]
              }
            }]
          }
        }
      }
    },
    {
      type = "vis"
      grid = { x = 32, y = 28, w = 16, h = 14 }
      vis_config = {
        by_value = {
          pie_chart_config = {
            title            = "Spend share by user (ECU)"
            donut_hole       = "s"
            legend           = { nested = false, size = "auto", truncate_after_lines = 1, visible = "auto" }
            data_source_json = local.usage_data_source
            query            = { expression = "" }
            metrics          = [{ config_json = local.pie_sum_cost }]
            group_by         = [{ config_json = local.terms_user }]
          }
        }
      }
    },
    {
      type = "vis"
      grid = { x = 0, y = 42, w = 48, h = 14 }
      vis_config = {
        by_value = {
          datatable_config = {
            no_esql = {
              title            = "Spend by user, ECU (chargeback)"
              data_source_json = local.usage_data_source
              query            = { expression = "" }
              styling          = local.table_density
              rows             = [{ config_json = local.row_user_by_cost }]
              metrics = [
                { config_json = local.tbl_sum_cost },
                { config_json = local.tbl_sum_in_cost },
                { config_json = local.tbl_sum_out_cost },
                { config_json = local.tbl_avg_cost },
                { config_json = local.tbl_count },
                { config_json = local.tbl_sum_tokens },
              ]
            }
          }
        }
      }
    },
    {
      type = "vis"
      grid = { x = 0, y = 56, w = 48, h = 14 }
      vis_config = {
        by_value = {
          datatable_config = {
            no_esql = {
              title            = "Spend by model and actual EIS model (rate sanity check)"
              data_source_json = local.usage_data_source
              query            = { expression = "" }
              styling          = local.table_density
              rows = [
                { config_json = local.row_model_by_cost },
                { config_json = local.row_upstream },
              ]
              metrics = [
                { config_json = local.tbl_sum_cost },
                { config_json = local.tbl_sum_prompt },
                { config_json = local.tbl_sum_output },
                { config_json = local.tbl_sum_in_cost },
                { config_json = local.tbl_sum_out_cost },
                { config_json = local.tbl_count },
              ]
            }
          }
        }
      }
    },
  ]

  kibana_connection {
    endpoints = local.kibana_connection.endpoints
    username  = local.kibana_connection.username
    password  = local.kibana_connection.password
  }
}
